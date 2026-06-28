#!/bin/bash
#
# start.sh — bring NanoClaw's stack up after a Mac reboot (or any cold start).
#
# Why this exists: on macOS the podman VM does NOT auto-start at login (unlike
# Docker Desktop). After a reboot the launchd agents (nanoclaw host + watchdog)
# come back, but they can't reach any containers until the podman machine and
# the OneCLI gateway are up. This script starts everything in dependency order
# and is safe to re-run any time — every step is idempotent.
#
# Order:  podman machine  →  OneCLI pod (gateway+postgres)  →  nanoclaw host
#         →  podman watchdog.   Each step waits for the previous to be healthy.
#
# Usage:
#   ops/start.sh            # start everything, wait for health, print summary
#   ops/start.sh --status   # report current state only, change nothing
#
set -uo pipefail

# ── config ───────────────────────────────────────────────────────────────────
MACHINE="podman-machine-default"
ONECLI_POD="pod_onecli"
ONECLI_COMPOSE="$HOME/.onecli/docker-compose.yml"
GATEWAY_URL="http://127.0.0.1:10254"        # OneCLI dashboard — liveness probe
NANOCLAW_LABEL="com.nanoclaw-v2-679b4003"
NANOCLAW_PLIST="$HOME/Library/LaunchAgents/${NANOCLAW_LABEL}.plist"
# Watchdogs to keep loaded (label per line). podman = VM wedge; adapter = Slack WS.
WATCHDOG_LABELS=("com.user.podman-watchdog" "com.user.adapter-watchdog")

STATUS_ONLY=0
[ "${1:-}" = "--status" ] && STATUS_ONLY=1

# ── helpers ──────────────────────────────────────────────────────────────────
say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) &
  local watcher=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -TERM "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  [ "$rc" -eq 143 ] && rc=124
  return "$rc"
}

machine_state() {
  with_timeout 10 podman machine inspect --format '{{.State}}' "$MACHINE" 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' | tr -d '\n'
}
podman_responsive() { with_timeout 25 podman info >/dev/null 2>&1; }
launchd_loaded()    { launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1; }

wait_for() {  # wait_for <desc> <timeout-secs> <cmd...>
  local desc="$1" max="$2"; shift 2
  local waited=0
  until "$@"; do
    [ "$waited" -ge "$max" ] && return 1
    sleep 3; waited=$((waited + 3))
    printf '  ...waiting for %s (%ss)\r' "$desc" "$waited"
  done
  printf '\033[2K'   # clear the waiting line
  return 0
}

# ── status report ────────────────────────────────────────────────────────────
print_status() {
  step "Status"
  local st; st="$(machine_state)"
  say "podman machine : ${st:-unknown}"
  local podman_ok=0
  if podman_responsive; then
    podman_ok=1
    ok "podman API responsive"
    podman pod ps --filter name="$ONECLI_POD" --format '  onecli pod    : {{.Status}}' 2>/dev/null
  else
    warn "podman API not responsive"
  fi
  # The OneCLI pod + gateway run *inside* podman: if the API is down they cannot
  # be up, so don't probe at all. (A refused-connection curl prints "000" AND
  # exits non-zero; the old `|| echo 000` then appended a second "000", so the
  # !="000" test passed and falsely reported the gateway "responding".)
  if [ "$podman_ok" = "1" ]; then
    local code
    code=$(with_timeout 8 curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$GATEWAY_URL/" 2>/dev/null)
    code="${code:-000}"
    if [ "$code" != "000" ]; then ok "OneCLI gateway responding (HTTP $code)"; else warn "OneCLI gateway not responding (HTTP $code)"; fi
  else
    warn "OneCLI gateway: not checked (podman down -- gateway runs inside podman)"
  fi
  if launchd_loaded "$NANOCLAW_LABEL"; then ok "nanoclaw agent loaded"; else warn "nanoclaw agent NOT loaded"; fi
  for wl in "${WATCHDOG_LABELS[@]}"; do
    if launchd_loaded "$wl"; then ok "$wl loaded"; else warn "$wl NOT loaded"; fi
  done
}

if [ "$STATUS_ONLY" = "1" ]; then print_status; exit 0; fi

# ── 1. podman machine ─────────────────────────────────────────────────────────
step "1/4  podman machine"
state="$(machine_state)"
if [ "$state" = "running" ] && podman_responsive; then
  ok "already running and responsive"
else
  if [ "$state" = "running" ]; then
    warn "machine claims running but unresponsive — bouncing"
    with_timeout 90 podman machine stop "$MACHINE" >/dev/null 2>&1
    sleep 3
  fi
  say "starting $MACHINE..."
  with_timeout 150 podman machine start "$MACHINE" >/dev/null 2>&1 || true
  if wait_for "podman API" 90 podman_responsive; then
    ok "podman machine up and responsive"
  else
    err "podman machine did not become responsive — aborting"
    exit 1
  fi
fi

# ── 2. OneCLI gateway pod ─────────────────────────────────────────────────────
step "2/4  OneCLI gateway"
if podman pod ps --filter name="$ONECLI_POD" --format '{{.Status}}' 2>/dev/null | grep -qi running; then
  ok "onecli pod already running"
else
  say "starting onecli pod..."
  if ! with_timeout 30 podman pod start "$ONECLI_POD" >/dev/null 2>&1; then
    warn "pod start failed (pod may not exist) — bringing up via compose"
    with_timeout 90 podman compose -p onecli -f "$ONECLI_COMPOSE" up -d >/dev/null 2>&1 || true
  fi
fi
# Confirm the gateway actually answers.
if wait_for "OneCLI gateway" 60 bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 '$GATEWAY_URL/' 2>/dev/null)\" != '000' ]"; then
  ok "OneCLI gateway responding"
else
  warn "gateway not answering yet — it may still be starting; check 'podman logs onecli'"
fi

# ── 3. nanoclaw host ──────────────────────────────────────────────────────────
step "3/4  nanoclaw host"
if [ -f "$NANOCLAW_PLIST" ]; then
  if ! launchd_loaded "$NANOCLAW_LABEL"; then
    say "loading nanoclaw agent..."
    launchctl bootstrap "gui/$(id -u)" "$NANOCLAW_PLIST" 2>/dev/null || true
  fi
  # Kick it so it reconnects to freshly-started containers.
  if launchctl kickstart -k "gui/$(id -u)/$NANOCLAW_LABEL" 2>/dev/null; then
    ok "nanoclaw running (kicked to reconnect)"
  else
    warn "could not kick nanoclaw — check 'launchctl print gui/$(id -u)/$NANOCLAW_LABEL'"
  fi
else
  err "nanoclaw plist not found at $NANOCLAW_PLIST"
fi

# ── 4. watchdogs (podman VM + channel adapters) ───────────────────────────────
step "4/4  watchdogs"
for wl in "${WATCHDOG_LABELS[@]}"; do
  plist="$HOME/Library/LaunchAgents/${wl}.plist"
  if [ ! -f "$plist" ]; then
    warn "$wl plist not found (skipping)"
  elif launchd_loaded "$wl"; then
    ok "$wl already loaded"
  else
    say "loading $wl..."
    if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
      ok "$wl loaded"
    else
      warn "could not load $wl"
    fi
  fi
done

print_status
printf '\n\033[1mDone.\033[0m NanoClaw stack started.\n'

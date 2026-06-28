#!/bin/bash
#
# podman-watchdog.sh — auto-recover the podman VM when it wedges.
#
# Background: on this machine the applehv VM + gvproxy networking layer
# occasionally wedges hard — the VM reports "running" but every `podman`
# command hangs, so nanoclaw can't reach its containers and "nothing
# responds." The documented recovery (see ~/.onecli/upgrade.sh and the
# project CLAUDE.md) is `podman machine stop && start`, which resets gvproxy.
# Lives in <project>/ops/ alongside start.sh; logs to <project>/logs/.
#
# On 2026-06-05 the VM froze at ~20:53 and stayed dead ~40h until a manual
# restart. This watchdog turns that into a ~3-minute self-heal: launchd runs
# it every 2 minutes; if the VM is unresponsive it bounces the machine,
# brings the onecli pod back, and kicks nanoclaw to reconnect.
#
# Design notes:
#   - It ONLY acts on the "wedge" case: machine state == running but
#     `podman info` times out. A cleanly *stopped* machine is left alone —
#     that's a deliberate stop / mid-upgrade / pre-cold-start (start.sh's job),
#     and we must not fight those.
#   - A cooldown prevents bounce storms: if a bounce just happened and the VM
#     is wedged again, it logs and escalates instead of looping.
#   - A lock prevents overlapping runs (a bounce takes ~30-60s).
#
# Usage:
#   podman-watchdog.sh            # one health/recovery pass (what launchd runs)
#   podman-watchdog.sh --check    # report health only, never act (safe to test)
#   podman-watchdog.sh --dry-run  # log what it WOULD do, but don't bounce
#
set -uo pipefail

# ── config ───────────────────────────────────────────────────────────────────
# Self-locate the project root (this script lives in <project>/ops/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

MACHINE="podman-machine-default"
ONECLI_POD="pod_onecli"
ONECLI_COMPOSE="$HOME/.onecli/docker-compose.yml"
NANOCLAW_LABEL="com.nanoclaw-v2-679b4003"   # launchd label; kicked after recovery

INFO_TIMEOUT=25        # how long to wait for `podman info` before calling it wedged
STOP_TIMEOUT=90        # max wait for `podman machine stop`
START_TIMEOUT=150      # max wait for `podman machine start`
COOLDOWN=600           # seconds; don't bounce again within this window
LOCK_STALE=600         # seconds; steal a lock older than this

STATE_DIR="$PROJECT_DIR/data/.watchdog"     # runtime state (gitignored)
LOG_DIR="$PROJECT_DIR/logs"                 # project logs (gitignored)
LOG_FILE="$LOG_DIR/podman-watchdog.log"
LAST_BOUNCE_FILE="$STATE_DIR/last-bounce"
LOCK_FILE="$STATE_DIR/watchdog.lock"
LOG_MAX_BYTES=$((5 * 1024 * 1024))

# Safety guard: STATE_DIR must be a real, non-empty path under the project.
# This is what makes the `rm -f "$LOCK_FILE"` in release_lock safe — if the
# path derivation ever broke, we bail instead of removing something unexpected.
case "$STATE_DIR" in
  "" | "/" ) echo "FATAL: STATE_DIR unsafe ('$STATE_DIR')" >&2; exit 3 ;;
esac
case "$LOCK_FILE" in
  *"/data/.watchdog/watchdog.lock" ) : ;;   # expected shape only
  * ) echo "FATAL: LOCK_FILE unexpected ('$LOCK_FILE')" >&2; exit 3 ;;
esac

MODE="run"
case "${1:-}" in
  --check)   MODE="check" ;;
  --dry-run) MODE="dryrun" ;;
  "" )       MODE="run" ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

mkdir -p "$STATE_DIR" "$LOG_DIR"

# ── helpers ──────────────────────────────────────────────────────────────────
log() {
  local line; line="$(date '+%Y-%m-%d %H:%M:%S') [$MODE] $*"
  printf '%s\n' "$line" >> "$LOG_FILE"
  printf '%s\n' "$line"            # also to stdout (launchd captures it)
}

# Run a command with a hard timeout, portably (no coreutils `timeout` here).
# Returns the command's exit status, or 124 if it was killed for timing out.
with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) &
  local watcher=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill -TERM "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  # 143 = 128+SIGTERM (our killer fired) -> normalize to 124 "timed out"
  [ "$rc" -eq 143 ] && rc=124
  return "$rc"
}

rotate_log() {
  local sz
  sz=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi
}

# Remove the lock — only ever the one expected regular file, with rm -f (no -rf).
# Guards: var non-empty, path is the expected lock file, and it's a regular file.
remove_lock_file() {
  [ -n "$LOCK_FILE" ] || return 0
  [ "$LOCK_FILE" = "$STATE_DIR/watchdog.lock" ] || return 0
  [ -f "$LOCK_FILE" ] || return 0
  rm -f "$LOCK_FILE"
}

acquire_lock() {
  # Atomic create via noclobber: the redirect fails if the file already exists,
  # so only one process can win. No directory, no recursive removal anywhere.
  if ( set -o noclobber; printf '%s\n' "$$" > "$LOCK_FILE" ) 2>/dev/null; then
    return 0
  fi
  # Lock exists — steal it only if stale.
  local age now mtime
  now=$(date +%s)
  mtime=$(stat -f%m "$LOCK_FILE" 2>/dev/null || echo "$now")
  age=$(( now - mtime ))
  if [ "$age" -gt "$LOCK_STALE" ]; then
    log "WARN stealing stale lock (age ${age}s)"
    remove_lock_file
    if ( set -o noclobber; printf '%s\n' "$$" > "$LOCK_FILE" ) 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}
release_lock() { remove_lock_file; }

# ── health checks ────────────────────────────────────────────────────────────
machine_state() {
  with_timeout 10 podman machine inspect --format '{{.State}}' "$MACHINE" 2>/dev/null
}

podman_responsive() {
  with_timeout "$INFO_TIMEOUT" podman info >/dev/null 2>&1
}

ensure_onecli_pod() {
  # Idempotent: starting an already-running pod is a no-op success.
  if with_timeout 25 podman pod start "$ONECLI_POD" >/dev/null 2>&1; then
    log "onecli pod ensured up ($ONECLI_POD)"
  else
    log "WARN pod start failed; trying compose up"
    if with_timeout 60 podman compose -p onecli -f "$ONECLI_COMPOSE" up -d >/dev/null 2>&1; then
      log "onecli brought up via compose"
    else
      log "ERROR could not bring onecli up"
    fi
  fi
}

kick_nanoclaw() {
  # nanoclaw host keeps running under launchd KeepAlive, but a clean kick makes
  # it re-establish container connections immediately after a bounce.
  if launchctl kickstart -k "gui/$(id -u)/$NANOCLAW_LABEL" 2>/dev/null; then
    log "nanoclaw kicked ($NANOCLAW_LABEL)"
  else
    log "WARN could not kick nanoclaw (label loaded?)"
  fi
}

seconds_since_last_bounce() {
  [ -f "$LAST_BOUNCE_FILE" ] || { echo 999999; return; }
  local last now; last=$(cat "$LAST_BOUNCE_FILE" 2>/dev/null || echo 0)
  now=$(date +%s); echo $(( now - last ))
}

bounce() {
  log "WEDGE: machine running but podman unresponsive — bouncing $MACHINE"
  if [ "$MODE" = "dryrun" ]; then
    log "[dry-run] would: podman machine stop && start, ensure onecli, kick nanoclaw"
    return 0
  fi
  with_timeout "$STOP_TIMEOUT" podman machine stop "$MACHINE" 2>&1 | sed 's/^/  stop: /' | tee -a "$LOG_FILE" >/dev/null
  sleep 3
  with_timeout "$START_TIMEOUT" podman machine start "$MACHINE" 2>&1 | sed 's/^/  start: /' | tee -a "$LOG_FILE" >/dev/null
  sleep 5
  date +%s > "$LAST_BOUNCE_FILE"
  if podman_responsive; then
    log "RECOVERED: podman responsive after bounce"
    ensure_onecli_pod
    kick_nanoclaw
    return 0
  fi
  log "FATAL: still unresponsive after bounce — manual attention needed"
  return 1
}

# ── main ─────────────────────────────────────────────────────────────────────
rotate_log

if [ "$MODE" != "check" ] && ! acquire_lock; then
  log "another run holds the lock; skipping"
  exit 0
fi
trap 'release_lock' EXIT

state="$(machine_state)"
state="${state//$'\n'/}"
state_lc="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"

if [ "$state_lc" != "running" ]; then
  log "machine state='${state:-unknown}' (not running) — leaving alone; cold-start is start.sh's job"
  exit 0
fi

if podman_responsive; then
  # Healthy path. Keep the onecli pod honest, log a heartbeat.
  if [ "$MODE" = "check" ]; then
    log "OK: machine Running, podman responsive"
  else
    if ! with_timeout 15 podman pod ps --filter name="$ONECLI_POD" --format '{{.Status}}' 2>/dev/null | grep -qi running; then
      log "onecli pod not Running while VM healthy — restarting it"
      ensure_onecli_pod
    else
      log "OK: machine Running, podman responsive, onecli pod up"
    fi
  fi
  exit 0
fi

# Unresponsive while Running == wedged.
if [ "$MODE" = "check" ]; then
  log "UNHEALTHY: machine Running but podman unresponsive (would bounce)"
  exit 1
fi

since=$(seconds_since_last_bounce)
if [ "$since" -lt "$COOLDOWN" ]; then
  log "ESCALATE: wedged again ${since}s after last bounce (< ${COOLDOWN}s cooldown) — NOT re-bouncing; manual attention needed"
  exit 1
fi

bounce

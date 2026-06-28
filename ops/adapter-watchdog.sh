#!/bin/bash
#
# adapter-watchdog.sh — auto-recover a wedged channel adapter (esp. Slack).
#
# Background: the nanoclaw host keeps long-lived connections to chat platforms.
# Slack Socket Mode is a persistent WebSocket; intermittent network blips kill
# it and it flaps (disconnect/reconnect) or goes half-open (pong timeouts),
# which silently stops inbound DMs. On 2026-06-12 work-Quill was dead ~4 days
# this way while Telegram (stateless polling) shrugged the same blips off. The
# podman watchdog only checks the VM, so this class is invisible to it. The
# fix is a host restart, which re-establishes all adapter connections.
#
# This watchdog reads only the NEW bytes of the host logs each tick (byte
# offset, so it's cheap regardless of log size), counts Slack failure signals,
# and restarts the host when they're sustained or severe. Deterministic — no
# LLM, no tokens. Lives in <project>/ops/ alongside the podman watchdog.
#
# Signals (per ~120s tick):
#   - "pong wasn't received"        in logs/nanoclaw.error.log  (half-open WS)
#   - "Slack socket mode disconnected" in logs/nanoclaw.log     (flapping)
# Trips when a single tick is severe (burst) OR two consecutive ticks are bad.
# Cooldown prevents restart storms; a clean connection produces zero signals.
#
# Usage:
#   adapter-watchdog.sh            # one pass (what launchd runs)
#   adapter-watchdog.sh --check    # report counts only, never act
#   adapter-watchdog.sh --dry-run  # log what it would do, don't restart
#
set -uo pipefail

# ── config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Host launchd label + log paths. Overridable via env for testing only.
NANOCLAW_LABEL="${ADAPTER_NANOCLAW_LABEL:-com.nanoclaw-v2-679b4003}"
ERR_LOG="${ADAPTER_ERR_LOG:-$PROJECT_DIR/logs/nanoclaw.error.log}"
OUT_LOG="${ADAPTER_OUT_LOG:-$PROJECT_DIR/logs/nanoclaw.log}"
PONG_PAT="pong wasn't received"
DISC_PAT="Slack socket mode disconnected"

PONG_BAD=5          # >= this many new pong-timeouts in one tick = bad tick
PONG_BURST=15       # >= this many in one tick = act immediately (hard outage)
DISC_BAD=2          # >= this many new disconnects in one tick = bad tick (flapping)
STRIKES_TO_ACT=2    # consecutive bad ticks before restarting
COOLDOWN=600        # seconds; don't restart again within this window
LOCK_STALE=600

STATE_DIR="${ADAPTER_STATE_DIR:-$PROJECT_DIR/data/.watchdog}"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/adapter-watchdog.log"
STATE_FILE="$STATE_DIR/adapter-state"
LOCK_FILE="$STATE_DIR/adapter-watchdog.lock"
LOG_MAX_BYTES=$((5 * 1024 * 1024))

# Safety guards — make the later `rm -f "$LOCK_FILE"` provably safe: STATE_DIR
# must be a real, non-empty path and LOCK_FILE must be exactly that one file.
case "$STATE_DIR" in
  "" | "/" ) echo "FATAL: STATE_DIR unsafe ('$STATE_DIR')" >&2; exit 3 ;;
esac
[ "$LOCK_FILE" = "$STATE_DIR/adapter-watchdog.lock" ] || { echo "FATAL: LOCK_FILE unexpected ('$LOCK_FILE')" >&2; exit 3; }

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
  printf '%s\n' "$line"
}

rotate_log() {
  local sz; sz=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$LOG_MAX_BYTES" ]; then mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true; fi
}

state_get() { grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }

remove_lock_file() {
  [ -n "$LOCK_FILE" ] || return 0
  [ "$LOCK_FILE" = "$STATE_DIR/adapter-watchdog.lock" ] || return 0
  [ -f "$LOCK_FILE" ] || return 0
  rm -f "$LOCK_FILE"
}
acquire_lock() {
  if ( set -o noclobber; printf '%s\n' "$$" > "$LOCK_FILE" ) 2>/dev/null; then return 0; fi
  local now mtime age
  now=$(date +%s); mtime=$(stat -f%m "$LOCK_FILE" 2>/dev/null || echo "$now")
  age=$(( now - mtime ))
  if [ "$age" -gt "$LOCK_STALE" ]; then
    log "WARN stealing stale lock (age ${age}s)"
    remove_lock_file
    if ( set -o noclobber; printf '%s\n' "$$" > "$LOCK_FILE" ) 2>/dev/null; then return 0; fi
  fi
  return 1
}
release_lock() { remove_lock_file; }

file_size() { wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

# count_new <file> <prev_offset> <pattern>  -> prints "<count> <new_offset>"
# Reads only bytes after prev_offset (resets to 0 if the file was rotated).
count_new() {
  local file="$1" off="$2" pat="$3" cur cnt
  [ -f "$file" ] || { echo "0 0"; return; }
  cur=$(file_size "$file")
  case "$off" in ''|*[!0-9]*) off=0 ;; esac
  [ "$cur" -lt "$off" ] && off=0          # rotated/truncated
  if [ "$cur" -gt "$off" ]; then
    cnt=$(tail -c "+$((off + 1))" "$file" 2>/dev/null | grep -Fc "$pat")
  else
    cnt=0
  fi
  echo "$cnt $cur"
}

restart_host() {
  if [ "$MODE" = "dryrun" ]; then
    log "[dry-run] would kickstart host ($NANOCLAW_LABEL)"
    return 0
  fi
  if launchctl kickstart -k "gui/$(id -u)/$NANOCLAW_LABEL" 2>/dev/null; then
    log "RESTARTED host — adapter unhealthy, re-establishing connections"
  else
    log "ERROR could not kickstart host ($NANOCLAW_LABEL)"
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────
rotate_log

if [ "$MODE" != "check" ] && ! acquire_lock; then
  log "another run holds the lock; skipping"
  exit 0
fi
trap 'release_lock' EXIT

# Load prior state.
err_off="$(state_get err_off)"
out_off="$(state_get out_off)"
strikes="$(state_get strikes)"
last_restart="$(state_get last_restart)"
case "$strikes"      in ''|*[!0-9]*) strikes=0 ;; esac
case "$last_restart" in ''|*[!0-9]*) last_restart=0 ;; esac

# First-ever run (or no state): baseline to current EOF and do not act on history.
if [ -z "$err_off" ] && [ -z "$out_off" ] && [ ! -f "$STATE_FILE" ]; then
  err_now=$(file_size "$ERR_LOG"); out_now=$(file_size "$OUT_LOG")
  if [ "$MODE" != "check" ]; then
    { echo "err_off=$err_now"; echo "out_off=$out_now"; echo "strikes=0"; echo "last_restart=0"; } > "$STATE_FILE"
  fi
  log "baseline established (err_off=$err_now out_off=$out_now) — not acting on pre-existing history"
  exit 0
fi

# Count new failure signals since last tick.
read -r new_pong err_now < <(count_new "$ERR_LOG" "${err_off:-0}" "$PONG_PAT")
read -r new_disc out_now < <(count_new "$OUT_LOG" "${out_off:-0}" "$DISC_PAT")

bad=0
[ "$new_pong" -ge "$PONG_BAD" ] && bad=1
[ "$new_disc" -ge "$DISC_BAD" ] && bad=1
burst=0
[ "$new_pong" -ge "$PONG_BURST" ] && burst=1

if [ "$bad" -eq 1 ]; then
  strikes=$(( strikes + 1 ))
else
  strikes=0
fi

now=$(date +%s)
since_restart=$(( now - last_restart ))

if [ "$MODE" = "check" ]; then
  log "CHECK: new_pong=$new_pong new_disc=$new_disc strikes=$strikes burst=$burst since_restart=${since_restart}s"
  exit 0
fi

tripped=0
[ "$burst" -eq 1 ] && tripped=1
[ "$strikes" -ge "$STRIKES_TO_ACT" ] && tripped=1

if [ "$tripped" -eq 1 ] && [ "$since_restart" -ge "$COOLDOWN" ]; then
  log "TRIP: new_pong=$new_pong new_disc=$new_disc strikes=$strikes burst=$burst -> restarting host"
  restart_host
  last_restart="$now"
  strikes=0
  # Re-baseline offsets to current EOF so post-restart startup noise is ignored.
  err_now=$(file_size "$ERR_LOG"); out_now=$(file_size "$OUT_LOG")
elif [ "$tripped" -eq 1 ]; then
  log "HOLD: action condition met (strikes=$strikes burst=$burst) but in cooldown (${since_restart}s < ${COOLDOWN}s)"
elif [ "$new_pong" -eq 0 ] && [ "$new_disc" -eq 0 ]; then
  log "OK: no Slack failure signals this tick"
else
  log "NOTE: new_pong=$new_pong new_disc=$new_disc strikes=$strikes (below action threshold)"
fi

{ echo "err_off=$err_now"; echo "out_off=$out_now"; echo "strikes=$strikes"; echo "last_restart=$last_restart"; } > "$STATE_FILE"

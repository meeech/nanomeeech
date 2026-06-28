#!/bin/bash
#
# lock-on-boot.sh -- lock the screen right after an (auto-)login at boot.
#
# Route A of the unattended-power-failure-recovery setup. With FileVault OFF +
# auto-login, the Mac boots straight to the desktop so the launchd agents and
# the nanoclaw stack come up with no human present. This script then puts the
# display to sleep immediately; combined with "require password immediately
# after sleep" (set once via: sysadminctl -screenLock immediate -password -),
# waking the machine demands the account password. Net effect: the agent stack
# runs unattended and SSH stays reachable, but anyone at the physical machine
# hits a locked screen.
#
# Boot-only by two mechanisms:
#   1. launchd RunAtLoad -- with auto-login the only login event is boot, so
#      this fires once per boot and never re-locks an active session.
#   2. An uptime guard -- if the machine has been up longer than UPTIME_MAX it
#      assumes this is a manual run / launchd reload (NOT a fresh boot) and does
#      nothing. This is what lets us load the agent during a live session
#      without sleeping the screen out from under you.
#
# Fails OPEN by design: it only ever sleeps the display. If anything goes wrong
# it simply does not lock -- it can never lock you out, and SSH is unaffected.
#
# Usage:
#   lock-on-boot.sh            # what launchd runs (guarded + settle delay)
#   UPTIME_MAX=0 lock-on-boot.sh   # force the guard to treat this as a boot
#   lock-on-boot.sh --check    # report what it would do, never sleep the display
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/lock-on-boot.log"

# How long after boot we still consider "right after booting" (seconds).
# Generous enough to cover a slow boot or a human typing the FileVault password
# during the test phase, small enough that a manual run mid-session is skipped.
UPTIME_MAX="${UPTIME_MAX:-600}"
# Let the GUI session settle so the display-sleep request hits a ready
# WindowServer. Override for testing.
SETTLE="${SETTLE:-8}"

MODE="run"
[ "${1:-}" = "--check" ] && MODE="check"

mkdir -p "$LOG_DIR"

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$*" >> "$LOG_FILE"
}

# Seconds since the kernel booted. Empty string if it can't be determined.
uptime_seconds() {
  local boot now
  boot="$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null | sed -n 's/{ sec = \([0-9][0-9]*\).*/\1/p')"
  [ -n "$boot" ] || return 0
  now="$(date +%s)"
  printf '%s' "$(( now - boot ))"
}

up="$(uptime_seconds)"
if [ -n "$up" ] && [ "$up" -gt "$UPTIME_MAX" ]; then
  log "skip: uptime ${up}s > ${UPTIME_MAX}s (not a fresh boot; leaving screen alone)"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  log "would lock: uptime ${up:-unknown}s <= ${UPTIME_MAX}s (fresh boot)"
  exit 0
fi

sleep "$SETTLE"

if /usr/bin/pmset displaysleepnow >/dev/null 2>&1; then
  log "locked: display slept (uptime ${up:-unknown}s, settle ${SETTLE}s)"
else
  log "WARN: pmset displaysleepnow failed -- failing open, screen NOT locked"
fi

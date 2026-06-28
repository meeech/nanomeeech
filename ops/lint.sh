#!/bin/bash
#
# lint.sh — static checks for the shell scripts in ops/.
#
# Three layers, because no single tool catches everything:
#   1. bash -n       — syntax errors.
#   2. shellcheck    — the broad class of shell bugs (quoting, unset vars, etc.).
#   3. non-ASCII gate — shellcheck does NOT flag a Unicode char glued directly
#      onto a shell variable reference (e.g. a U+2026 ellipsis written with no
#      space after a "MACHINE" var), which under a non-UTF-8 locale folds the
#      multibyte bytes into the variable name -> "unbound variable". That bug
#      shipped once (2026-06-07). This layer is the guard against a repeat: it
#      hard-fails on any non-ASCII byte immediately following a var reference.
#
# Usage:  ops/lint.sh            # lint every ops/*.sh
#         ops/lint.sh <file...>  # lint specific files
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 2

if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  FILES=()
  for f in ops/*.sh; do [ -e "$f" ] && FILES+=("$f"); done
fi

rc=0

for f in "${FILES[@]}"; do
  printf '\n=== %s ===\n' "$f"

  # 1. syntax
  if bash -n "$f"; then echo "  bash -n: OK"; else echo "  bash -n: FAIL"; rc=1; fi

  # 2. shellcheck (if available)
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$f"; then echo "  shellcheck: OK"; else echo "  shellcheck: findings above"; rc=1; fi
  else
    echo "  shellcheck: not installed (brew install shellcheck)"
  fi

  # 3. HARD FAIL: a non-ASCII byte immediately after a $var reference. Uses
  #    perl (BSD grep has no -P / PCRE). This is the exact bug shellcheck misses.
  hits="$(perl -ne 'print "  line $.: $_" if /\$\{?[A-Za-z_]\w*\}?[^\x00-\x7F]/' "$f")"
  if [ -n "$hits" ]; then
    echo "  non-ASCII-after-var: FAIL (a multibyte char is glued to a \$variable — use ASCII or add a space)"
    printf '%s' "$hits"
    rc=1
  else
    echo "  non-ASCII-after-var: OK"
  fi
done

echo
if [ "$rc" -eq 0 ]; then echo "lint: PASS"; else echo "lint: FAIL"; fi
exit "$rc"

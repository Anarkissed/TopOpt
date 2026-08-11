#!/bin/sh
# R7 — no assertion may be weakened or deleted. Counts, then checks every
# message present on main is still present verbatim.
cd "$(dirname "$0")/../.." || exit 1
for f in core/tests/harness/levelset_probe.cpp core/tests/harness/plsm_probe.cpp; do
  n_main=$(git show main:$f | grep -c 'FATAL\|assert(')
  n_now=$(grep -c 'FATAL\|assert(' "$f")
  echo "$f: main=$n_main now=$n_now"
  [ "$n_now" -lt "$n_main" ] && echo "  ★ FAIL: count went DOWN"
  git show main:$f | grep -o 'FATAL[^"]*' | sort -u | while IFS= read -r m; do
    grep -qF "$m" "$f" || echo "  ★ CHANGED OR REMOVED: $m"
  done
done

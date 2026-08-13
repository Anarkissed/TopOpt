#!/bin/sh
# R6 — THE SHIPPED PATH IS UNTOUCHED, ASSERTED RATHER THAN CLAIMED.
#
# Everything this task built lives in `core/tests/harness/`, which is a test
# harness and is `EXCLUDE_FROM_ALL` in `core/CMakeLists.txt`. Not one line of
# `core/src`, `core/include` or `app/` moved, and `materials.json` is untouched
# (the brief forbids editing it explicitly).
set -e
cd "$(cd "$(dirname "$0")/../.." && pwd)"

fail=0
for P in core/src core/include app; do
  N=$(git diff main --stat -- "$P" | wc -l | tr -d ' ')
  if [ "$N" != "0" ]; then
    echo "FAIL: git diff main -- $P is not empty:"
    git diff main --stat -- "$P"
    fail=1
  else
    echo "ok: git diff main -- $P is 0 lines"
  fi
done

M=$(git diff main --stat -- core/src/materials/materials.json | wc -l | tr -d ' ')
if [ "$M" != "0" ]; then echo "FAIL: materials.json changed"; fail=1
else echo "ok: materials.json untouched"; fi

echo "--- what DID change ---"
git diff main --stat -- core/tests/harness core/CMakeLists.txt docs evidence

[ "$fail" = "0" ] || exit 1
echo "R6 PASS"

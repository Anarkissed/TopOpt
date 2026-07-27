#!/bin/zsh
# D5 — draft_quality OFF stays byte-identical, re-proven for Phase 2.
# Builds the branch lib (with the phase-2 fields), runs the B1 identity probe
# (draft OFF, references no draft field), records the checksum; then stashes the
# tracked core changes back to pre-phase2 (== origin/main), rebuilds, runs again;
# identical checksums prove draft-OFF is byte-for-byte unchanged by phase 2.
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
RULES="$ROOT/core/src/settings/rules.json"
FLAGS=(-std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 -DSETTINGS_RULES_PATH="\"$RULES\"")

build_and_hash() {
  cmake --build build --target topopt -j >/dev/null 2>&1
  c++ "${FLAGS[@]}" core/tests/harness/draft_b1_identity_probe.cpp build/libtopopt.a -o build/b1_probe
  ./build/b1_probe
}

echo "== branch (phase-2 applied), draft OFF =="
A="$(build_and_hash)"
echo "$A"

echo "== stashing tracked core changes (-> pre-phase2 == main) =="
git stash push -- core/include core/src >/tmp/d5_stash.log 2>&1
echo "== rebuilt on pre-phase2, draft OFF =="
B="$(build_and_hash)"
echo "$B"
git stash pop >/tmp/d5_unstash.log 2>&1

echo "== restored; rebuild branch lib =="
cmake --build build --target topopt -j >/dev/null 2>&1

echo "----"
echo "branch : $A"
echo "main   : $B"
if [[ "$A" == "$B" ]]; then echo "D5 PASS: draft-OFF byte-identical"; else echo "D5 FAIL"; fi

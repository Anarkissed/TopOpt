#!/usr/bin/env bash
# R1 -- BYTE-IDENTICAL WHEN OFF, by rebuild checksum, both binaries built from
# ONE folder (core/build), one arm after the other.
#
# S1 of this task changes no production file at all: the only tracked changes are
# a new EXCLUDE_FROM_ALL harness (core/tests/harness/boundary_cell_probe.cpp) and
# the CMake block that declares it. The claim is therefore IDENTITY, not
# difference -- which inverts the usual guard. A bar that expects identity passes
# vacuously when NO BUILD HAPPENED (make-topopt-cli-silently-noops, three
# occurrences), so this carries two guards instead of one:
#
#   GUARD 1  each arm must actually relink: the build log must contain a
#            "Linking CXX executable topopt-cli" line and the binary's mtime must
#            move.
#   GUARD 2  a NEGATIVE CONTROL arm with a deliberate one-character change to a
#            production source. If THAT arm also hashes identical the comparison
#            is blind and the bar is void -- the script prints R1 INVALID and
#            exits non-zero rather than reporting a pass it cannot support.
#
# NO `git stash` ANYWHERE. A stash that matches nothing pops somebody else's
# (memory: git-stash-pathspec-pops-someone-elses). Arm B is produced by checking
# out the merge-base's copy of the ONE tracked file this task changed and moving
# the new untracked harness aside by hand, both of which are exactly reversible.
#
#   ./evidence/2026-08-08-how-wrong-is-the-boundary-cell/r1_byte_identity.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$ROOT/core/build"
OUT="$HERE/R1_byte_identity.txt"
PROBE_SRC="$ROOT/core/tests/harness/boundary_cell_probe.cpp"
PARKED="$HERE/.r1_parked_probe.cpp"
CTRL="$ROOT/core/src/cli/main.cpp"
CTRL_BAK="$HERE/.r1_ctrl_backup"

exec > >(tee "$OUT") 2>&1
BASE="$(git -C "$ROOT" merge-base HEAD main)"
echo "R1 byte identity"
echo "  branch     : $(git -C "$ROOT" rev-parse --abbrev-ref HEAD) @ $(git -C "$ROOT" rev-parse --short HEAD)"
echo "  merge-base : $BASE"
echo "  build dir  : $BUILD (ONE folder, both arms)"
echo

echo "--- the whole tracked diff against main, in core/ and app/ ---"
git -C "$ROOT" diff --stat "$BASE" -- core app
echo
echo "--- R1's own statement: git diff main -- core/src core/include app/TopOptKit/Sources ---"
D="$(git -C "$ROOT" diff "$BASE" -- core/src core/include app/TopOptKit/Sources)"
if [ -z "$D" ]; then
  echo "  (empty -- S1 touched no production source)"
else
  echo "$D"
fi
echo

build_and_hash() {  # label -> prints sha256 on stdout, diagnostics on stderr
  local label="$1"
  local log="$HERE/r1_build_${label}.log"
  local before after rc
  before="$(stat -f %m "$BUILD/topopt-cli" 2>/dev/null || echo 0)"
  ( cd "$BUILD" && cmake .. >/dev/null && nice make topopt_cli -j10 ) > "$log" 2>&1
  rc=$?
  after="$(stat -f %m "$BUILD/topopt-cli" 2>/dev/null || echo 0)"
  if [ "$rc" -ne 0 ]; then echo "BUILD FAILED ($label), see $log" >&2; return 1; fi
  if ! grep -q "Linking CXX executable topopt-cli" "$log"; then
    echo "GUARD 1 FAILED ($label): no relink line in $log -- make no-opped." >&2
    return 1
  fi
  if [ "$after" = "$before" ]; then
    echo "GUARD 1 FAILED ($label): binary mtime did not move." >&2
    return 1
  fi
  shasum -a 256 "$BUILD/topopt-cli" | awk '{print $1}'
}

restore() {
  [ -f "$PARKED" ] && mv -f "$PARKED" "$PROBE_SRC"
  [ -f "$CTRL_BAK" ] && { cp "$CTRL_BAK" "$CTRL"; rm -f "$CTRL_BAK"; }
  git -C "$ROOT" checkout --quiet HEAD -- core/CMakeLists.txt 2>/dev/null || true
}
trap restore EXIT

echo "--- arm A: this branch, as committed"
A="$(build_and_hash A)" || exit 1
echo "  topopt-cli  $A"

echo
echo "--- arm B: the merge-base's core/CMakeLists.txt, harness parked aside"
mv "$PROBE_SRC" "$PARKED"
git -C "$ROOT" checkout "$BASE" -- core/CMakeLists.txt
B="$(build_and_hash B)" || exit 1
echo "  topopt-cli  $B"
git -C "$ROOT" checkout --quiet HEAD -- core/CMakeLists.txt
mv "$PARKED" "$PROBE_SRC"

echo
echo "--- arm C: NEGATIVE CONTROL -- one production string changed"
cp "$CTRL" "$CTRL_BAK"
/usr/bin/sed -i '' 's/ONE FEA analysis solve/ONE FEA analysiz solve/' "$CTRL"
grep -q "analysiz" "$CTRL" || { echo "R1 INVALID: negative-control edit did not apply."; exit 1; }
C="$(build_and_hash C)" || exit 1
echo "  topopt-cli  $C"
cp "$CTRL_BAK" "$CTRL"; rm -f "$CTRL_BAK"

echo
echo "--- arm A2: back to the branch, rebuilt (reproducibility)"
A2="$(build_and_hash A2)" || exit 1
echo "  topopt-cli  $A2"

echo
echo "== VERDICT =="
printf "  A  (branch)           %s\n" "$A"
printf "  B  (merge-base)       %s\n" "$B"
printf "  C  (negative control) %s\n" "$C"
printf "  A2 (branch, rebuilt)  %s\n" "$A2"
echo
if [ "$C" = "$A" ]; then
  echo "  R1 INVALID -- the negative control did NOT change the binary, so"
  echo "                identity between A and B proves nothing."
  exit 1
fi
echo "  negative control DIFFERS from A: the comparison can see a change."
if [ "$A" != "$A2" ]; then
  echo "  R1 INVALID -- the build is not reproducible within this branch (A != A2)."
  exit 1
fi
echo "  A == A2: the build is reproducible in this folder."
if [ "$A" = "$B" ]; then
  echo "  R1 PASS -- topopt-cli is BYTE-IDENTICAL to the merge-base."
else
  echo "  R1 FAIL -- topopt-cli differs from the merge-base. S1 was supposed to"
  echo "             touch no production file; find out what did."
  exit 1
fi

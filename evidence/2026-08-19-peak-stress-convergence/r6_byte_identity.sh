#!/usr/bin/env bash
# R6 — NO PRODUCTION DEFAULT MOVES, by rebuild checksum. Adapted from
# `evidence/2026-08-08-how-wrong-is-the-boundary-cell/r1_byte_identity.sh`, whose
# two guards it keeps verbatim in spirit.
#
# This task changes no production file: the only tracked changes are two new
# EXCLUDE_FROM_ALL harnesses (`smooth_convergence_probe.cpp`,
# `cavity_convergence_probe.cpp`) and the CMake blocks that declare them. The
# claim is therefore IDENTITY, not difference — which inverts the usual guard,
# because a bar that expects identity PASSES VACUOUSLY when no build happened
# (memory: make-topopt-cli-silently-noops). So:
#
#   GUARD 1  each arm builds FROM SCRATCH into a wiped folder; the log must carry
#            a "Linking CXX executable topopt-cli" line and the binary's mtime
#            must move. An incremental build is not good enough: this task's only
#            tracked source change is an EXCLUDE_FROM_ALL target, so
#            `make topopt_cli` legitimately has nothing to do and would hash a
#            binary no arm produced.
#   GUARD 2  a NEGATIVE CONTROL arm with a deliberate one-character change to a
#            production source. If THAT arm also hashes identical, the comparison
#            is blind and the bar is void — the script says R6 INVALID and exits
#            non-zero rather than reporting a pass it cannot support.
#
# ★★ IT SNAPSHOTS `core/CMakeLists.txt` AND RESTORES THE SNAPSHOT, rather than
# `git checkout HEAD --` it. The version this was adapted from restored with
# `git checkout HEAD -- core/CMakeLists.txt`, which SILENTLY DISCARDS an
# UNCOMMITTED change to that file — and this task's CMake change was uncommitted
# when it first ran, so the script's own cleanup deleted the thing it had just
# proved harmless. A restore must return the tree to what it found, not to what
# some commit says.
#
# ★ IT BUILDS IN `core/build-r6`, NOT `core/build`. The measurement binaries live
# in `core/build` and wiping that folder mid-task would destroy the sweep's own
# provenance. NO `git stash` anywhere (memory: git-stash-pathspec-pops-someone-
# elses): arm B checks out the merge base's copy of the one tracked file and
# moves the untracked harnesses aside by hand, both exactly reversible.
#
#   ./evidence/2026-08-19-peak-stress-convergence/r6_byte_identity.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$ROOT/core/build-r6"
OUT="$HERE/R6_byte_identity.txt"
P1="$ROOT/core/tests/harness/smooth_convergence_probe.cpp"
P2="$ROOT/core/tests/harness/cavity_convergence_probe.cpp"
K1="$HERE/.r6_parked_1.cpp"
K2="$HERE/.r6_parked_2.cpp"
CTRL="$ROOT/core/src/cli/main.cpp"
CTRL_BAK="$HERE/.r6_ctrl_backup"
CML="$ROOT/core/CMakeLists.txt"
CML_BAK="$HERE/.r6_cmakelists_backup"
cp "$CML" "$CML_BAK"

exec > >(tee "$OUT") 2>&1
BASE="$(git -C "$ROOT" merge-base HEAD origin/main)"
echo "R6 byte identity"
echo "  branch     : $(git -C "$ROOT" rev-parse --abbrev-ref HEAD) @ $(git -C "$ROOT" rev-parse --short HEAD)"
echo "  merge-base : $BASE   (against origin/main, NOT a moving head)"
echo "  build dir  : $BUILD (ONE folder, every arm)"
echo

echo "--- the whole tracked diff against the merge base, in core/ and app/ ---"
git -C "$ROOT" diff --stat "$BASE" -- core app
echo
echo "--- R6's own statement: git diff <merge-base> -- core/src core/include app/TopOptKit/Sources ---"
D="$(git -C "$ROOT" diff "$BASE" -- core/src core/include app/TopOptKit/Sources)"
if [ -z "$D" ]; then
  echo "  (empty — this task touched no production source)"
else
  echo "$D"
fi
echo

CMAKE_ARGS=(-DCMAKE_BUILD_TYPE=Release -DTOPOPT_REQUIRE_DEPS=ON
  -DOpenCASCADE_DIR=/opt/homebrew/lib/cmake/opencascade
  -DEigen3_DIR=/opt/homebrew/share/eigen3/cmake
  -Dlib3mf_DIR=/Users/nadim/dev/TopOpt/TopOpt/.vcpkg/installed/arm64-osx-dynamic/share/lib3mf
  -DCMAKE_PREFIX_PATH=/Users/nadim/dev/TopOpt/TopOpt/.vcpkg/installed/arm64-osx-dynamic)

build_and_hash() {  # label -> sha256 on stdout, diagnostics on stderr
  local label="$1"
  local log="$HERE/r6_build_${label}.log"
  local before after rc
  before="$(stat -f %m "$BUILD/topopt-cli" 2>/dev/null || echo 0)"
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
  ( cd "$BUILD" && cmake .. "${CMAKE_ARGS[@]}" >/dev/null && nice make topopt_cli -j10 ) > "$log" 2>&1
  rc=$?
  after="$(stat -f %m "$BUILD/topopt-cli" 2>/dev/null || echo 0)"
  if [ "$rc" -ne 0 ]; then echo "BUILD FAILED ($label), see $log" >&2; return 1; fi
  if ! grep -q "Linking CXX executable topopt-cli" "$log"; then
    echo "GUARD 1 FAILED ($label): no relink line in $log — make no-opped." >&2
    return 1
  fi
  if [ "$after" = "$before" ]; then
    echo "GUARD 1 FAILED ($label): binary mtime did not move." >&2
    return 1
  fi
  shasum -a 256 "$BUILD/topopt-cli" | awk '{print $1}'
}

restore() {
  [ -f "$K1" ] && mv -f "$K1" "$P1"
  [ -f "$K2" ] && mv -f "$K2" "$P2"
  [ -f "$CTRL_BAK" ] && { cp "$CTRL_BAK" "$CTRL"; rm -f "$CTRL_BAK"; }
  # ★ the SNAPSHOT, not `git checkout HEAD` — see the header.
  [ -f "$CML_BAK" ] && { cp "$CML_BAK" "$CML"; rm -f "$CML_BAK"; }
}
trap restore EXIT

echo "--- arm A: this branch, as it stands"
A="$(build_and_hash A)" || exit 1
echo "  topopt-cli  $A"

echo
echo "--- arm B: the merge base's core/CMakeLists.txt, both harnesses parked aside"
mv "$P1" "$K1"
mv "$P2" "$K2"
git -C "$ROOT" checkout "$BASE" -- core/CMakeLists.txt
B="$(build_and_hash B)" || exit 1
echo "  topopt-cli  $B"
cp "$CML_BAK" "$CML"
mv "$K1" "$P1"
mv "$K2" "$P2"

echo
echo "--- arm C: NEGATIVE CONTROL — one production string changed"
cp "$CTRL" "$CTRL_BAK"
/usr/bin/sed -i '' 's/ONE FEA analysis solve/ONE FEA analysiz solve/' "$CTRL"
grep -q "analysiz" "$CTRL" || { echo "R6 INVALID: negative-control edit did not apply."; exit 1; }
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
printf "  B  (merge base)       %s\n" "$B"
printf "  C  (negative control) %s\n" "$C"
printf "  A2 (branch, rebuilt)  %s\n" "$A2"
echo
if [ "$C" = "$A" ]; then
  echo "  R6 INVALID — the negative control did NOT change the binary, so"
  echo "               identity between A and B proves nothing."
  exit 1
fi
echo "  negative control DIFFERS from A: the comparison can see a change."
if [ "$A" != "$A2" ]; then
  echo "  R6 INVALID — the build is not reproducible within this branch (A != A2)."
  exit 1
fi
echo "  A == A2: the build is reproducible in this folder."
if [ "$A" = "$B" ]; then
  echo "  R6 PASS — topopt-cli is BYTE-IDENTICAL to the merge base."
else
  echo "  R6 FAIL — topopt-cli differs from the merge base. This task was"
  echo "            supposed to touch no production file; find out what did."
  exit 1
fi

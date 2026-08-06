#!/usr/bin/env bash
# S2 / R2 — THE MISSED-CALL-SITE FAILURE, REPRODUCED.
#
#   ./S2_missed_call_site_tripwire.sh
#
# R2 asks for a failing test first for "the missed-call-site risk in S2". A value
# test can only assert about sites that exist, so the guard is a source walk
# (StrutLineWidthTests.testNoLatticeLineWidthSiteReadsAWallBead). This script proves
# the guard is not vacuous, in BOTH directions:
#
#   PROBE 1  revert ONE lattice site to the wall bead — the silent-revert failure.
#   PROBE 2  wire the strut width into a WALL-LOOP consumer — the wall-ring
#            corruption failure.
#
# Each probe edits a source file, runs the two guard tests, prints the failure, and
# restores the file. Run from the repo root; leaves the tree exactly as it found it.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG="$REPO/app/TopOptKit"
WP="$PKG/Sources/TopOptFlows/WorkspacePlaceholder.swift"
PS="$PKG/Sources/TopOptFlows/PrintParamsSheet.swift"
FILTER='StrutLineWidthTests/testNoLatticeLineWidthSiteReadsAWallBead|StrutLineWidthTests/testWallLoopConsumersStillCarryTheWallBead'

restore() { [ -f "$WP.bak" ] && mv "$WP.bak" "$WP"; [ -f "$PS.bak" ] && mv "$PS.bak" "$PS"; }
trap restore EXIT

runguards() {
  ( cd "$PKG" && swift test --filter "$FILTER" 2>&1 ) \
    | grep -E "error:|passed \(|failed \(|Executed .* tests" | sed 's/^/    /'
}

echo "=== CONTROL — the tree as committed ==="
runguards
echo

echo "=== PROBE 1 — one lattice site reverted to the WALL bead ==="
echo "    WorkspacePlaceholder.swift, the re-lattice receipt echo."
cp "$WP" "$WP.bak"
perl -0pi -e 's/(        \/\/ The STRUT width, matching the job this receipt describes\.\n            let echo = project\.lattice\.runSpec\()/$1/' "$WP"
perl -pi -e 's/^(\s+)lineWidthMM: project\.printParams\.strutLineWidthMM,(\s*)$/$1lineWidthMM: project.printParams.wallLineWidthOuterMM,$2/ if $. > 2100' "$WP"
echo "    edited line(s):"
grep -n "lineWidthMM: project.printParams" "$WP" | sed 's/^/      /'
runguards
mv "$WP.bak" "$WP"
echo

echo "=== PROBE 2 — the strut width wired into a WALL-LOOP consumer ==="
echo "    PrintParamsSheet.swift, the outer-wall stepper."
cp "$PS" "$PS.bak"
perl -pi -e 's/project\.printParams\.wallLineWidthOuterMM = project\.printParams\.steppingOuterLineWidth\(by: steps\)/project.printParams.strutLineWidthMM = project.printParams.steppingOuterLineWidth(by: steps)/' "$PS"
echo "    edited line(s):"
grep -n "strutLineWidthMM" "$PS" | sed 's/^/      /'
runguards
mv "$PS.bak" "$PS"
echo

echo "=== RESTORED — the tree as committed, guards green again ==="
runguards

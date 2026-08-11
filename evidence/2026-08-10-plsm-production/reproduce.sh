#!/bin/sh
# Regenerates every measurement in
# docs/handoffs/2026-08-10-plsm-production.md.
#
# ★ SET SCRATCH FIRST, to a directory OUTSIDE the repository (R9). The fields
# these runs write are large and are not committed; what this directory keeps is
# the MEASUREMENTS.
#
# ★ THREE THREADS THROUGHOUT, and every wall clock that is compared against
# another was measured with nothing else running.
#
# ORDER MATTERS IN ONE PLACE: S4 needs a finished parametric run to lattice, so
# it takes PLSM_RUN from the S2 arm that ships. And R1 stashes the working tree
# and rebuilds in place, so it runs LAST — a rebuild mid-campaign would leave two
# arms measured on two binaries.
#
# Cost on the machine of record (10 cores, 3 threads to the solver):
#   ~5 min    build
#   ~10 min   S0, the three header moves (includes building the pre-task commit)
#   ~100 min  S3, the solver win on SIMP: four arms x four rungs
#   ~60 min   S2, the knot-lattice frontier: four lattices at rung 0.68
#   ~25 min   S4, latticing a parametric design against SIMP's
#   ~20 min   R1, the byte-identity control
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
: "${SCRATCH:?set SCRATCH to a directory outside the repository}"
export SCRATCH
cd "$REPO"

cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j6

# S0 — the three header moves into core are no-ops.
sh "$HERE/run_s0_core_move.sh"

# S3(b) — the solver win on the SHIPPED ladder. First, because it is the result
# that is worth something independently of the whole representation track.
sh "$HERE/run_s3_simp.sh"

# S2 — the knot lattice, and the point on the frontier that ships.
sh "$HERE/run_s2_frontier.sh"

# S4 — it must still lattice. `PLSM_RUN` names the arm S2 chose; edit it if a
# re-run picks a different point on the frontier.
PLSM_RUN="${PLSM_RUN:-$SCRATCH/s2_K2}" sh "$HERE/run_s4_lattice.sh"

# R8 — no assertion and no refusal disappeared.
sh "$HERE/assertion_census.sh" > "$HERE/r8_assertion_census.txt" 2>&1
cat "$HERE/r8_assertion_census.txt"

# The suite.
cmake --build build -j6
ctest --test-dir build --output-on-failure > "$HERE/ctest.txt" 2>&1 || true
tail -5 "$HERE/ctest.txt"

# R1 — LAST. It stashes the working tree and rebuilds in place.
sh "$HERE/run_r1_byte_identity.sh"

echo "REPRODUCE_DONE"

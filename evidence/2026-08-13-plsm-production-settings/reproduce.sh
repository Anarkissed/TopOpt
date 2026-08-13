#!/bin/sh
# Regenerates everything in this directory. Nothing is cloned and nothing is
# downloaded; the only inputs are his STEP, his captured job document, and this
# repository's own sources.
#
# ★ SET SCRATCH FIRST, to a directory OUTSIDE the repository (R8). The fields
# these runs write are large and are not committed; what this directory keeps is
# the MEASUREMENTS.
#
# ★ 6 THREADS, STRICTLY SERIAL, AND 6 IS PRODUCTION'S OWN NUMBER (his run of
# record reports `matfree_threads: 6`). Every wall clock that is compared with
# another was measured with nothing else running — this Mac's own A/B offset is
# larger than 10%, so two arms sharing the host cannot be timed against each
# other.
#
# ORDER MATTERS IN TWO PLACES. R2 runs BEFORE the arms, so the gradient is
# verified before four hours of state solves are spent on it — and in this task
# that ordering paid for itself: it found the compliance weight wrong by 45-56%
# and the arms ran on the corrected one. R1 stashes the working tree and rebuilds
# in place, so it runs LAST; a rebuild mid-campaign would leave two arms measured
# on two binaries.
#
# Cost on the machine of record (10 cores, 6 to the solver):
#   ~5 min    build
#   ~1 min    the suite's plsm unit test
#   ~40 min   R2, the finite differences (21 tight state solves)
#   ~6 h      the four arms, four rungs each
#   ~10 min   the measurements
#   ~40 min   R1, the byte-identity control
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
: "${SCRATCH:?set SCRATCH to a directory outside the repository}"
export SCRATCH
cd "$REPO"

cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6

# ── 0. R7: no assertion and no refusal disappeared.
sh "$HERE/assertion_census.sh" > "$HERE/r7_assertion_census.txt" 2>&1 || true
tail -20 "$HERE/r7_assertion_census.txt"

# ── 1. ★ R2, FIRST. The production volume-fraction sensitivity against a central
# difference, on BOTH functionals, with the CONTINUUM weight differenced beside
# the discrete one on the same solves. This is what found the second wrong
# gradient, and it found it before the arms were spent.
mkdir -p "$HERE/fd/frac"
./build/plsm_frac_fd_probe \
    "$REPO/evidence/2026-08-09-reference-implementation-bakeoff/M2_verticalStand.step" \
    core/src/materials/materials.json "$HERE/fd/frac" \
    --threads 6 --dirs 2 --coeffs 3 --compliance > "$HERE/fd/frac.txt" 2>&1
sed -n '/== the design ==/,$p' "$HERE/fd/frac.txt"

# ── 2. R3(e) — what the shipped stopping rule would have chosen on every margin
# curve this line of work has published. Pure replay of the shipped logic; no
# solver.
python3 "$HERE/replay_stop_rule.py" > "$HERE/replay_stop_rule.txt"
cat "$HERE/replay_stop_rule.txt"

# ── 3. THE FOUR ARMS. One variable between consecutive arms; every arm walks the
# whole ladder, so both rungs R3 names come out of the same run.
sh "$HERE/run_arms.sh"

# ── 4. the measurements: the surface table (one probe invocation, SIMP in the
# same run), the sealed void by the manufacturing definition, and the
# certificates out of each arm's own receipt.
sh "$HERE/measure.sh"

# ── 5. the suite.
ctest --test-dir build --output-on-failure > "$HERE/ctest.txt" 2>&1 || true
tail -5 "$HERE/ctest.txt"

# ── 6. R1 — LAST. It stashes the working tree and rebuilds in place.
sh "$HERE/run_r1_byte_identity.sh"

echo REPRODUCE_DONE

#!/bin/sh
# The measurement queue, in the order the pre-registration fixes (r0_preregistration.md
# §2) and STRICTLY SERIAL — he needs his Mac, and two of these at once would each
# measure the other's contention rather than the mechanism.
#
# ★ 3 THREADS THROUGHOUT. It cannot change an answer: the matrix-free apply threads
# a deterministic 8-colour partition whose accumulation order is set by the colour
# scheme and not by the thread count (fea.hpp, fea_set_matfree_threads).
#
# ★ WHAT ONE ROW COSTS, MEASURED BEFORE THE QUEUE WAS SIZED: one certification of
# his part in production's ISOLATED posture (recycling off, GenEO off, FP64, the
# tight cg_tolerance — `ScopedLadderSolverIsolation`, which is what production
# itself certifies in) is TENS OF MINUTES of matrix-free CG on this machine at 3
# threads. That is why the assignment table names a region subset instead of
# sweeping all of them, and the probe PRINTS the regions it skipped.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

STEP=evidence/2026-08-09-reference-implementation-bakeoff/M2_verticalStand.step
MAT=core/src/materials/materials.json
REF=evidence/2026-08-09-reference-implementation-bakeoff/s2_simp_baseline/design.bin
PROBE=./build/frozen_lattice_probe

# ── R1 FIRST. It is a BAR and a BLOCKED-STOP: if Lattice(f = 1.0) is not
# byte-identical to Solid the material model is wrong and no result after it can be
# trusted.
#
# ★ IT IS A CTEST, NOT A RUN ON HIS PART. "Byte-identical" is a statement about
# WHICH BRANCHES THE CODE TAKES, and a synthetic wall exercises the same pins,
# material law, volume budget, ladder, certification and receipt as a 468k-voxel
# import. Running it on his part costs a pair of ladder runs — measured at 2h17m
# on a shared machine — to learn the same bit. As a ctest it runs in seconds on
# EVERY build instead of once by hand, and it carries its own positive control so
# it cannot pass by the feature doing nothing.
( cd "$REPO/build" && ctest -R frozen_lattice_c0 --output-on-failure ) || {
  echo "BLOCKED-STOP: R1 failed. Nothing below is trustworthy." >&2
  exit 4
}
echo "R1 ok"

# ── M1, both rungs. One certification each; the strain energy and the per-region
# validity are re-read off it, so this costs one solve per rung and not five.
mkdir -p "$HERE/m1"
for RUNG in 0.68 0.26; do
  # ★ --regions provenance (the default) keys a region on WHICH DECLARATION froze
  # it. `connectivity` reproduces the superseded first cut, which fused face 16's
  # collar with the load-face pads — kept only so the fusion can be seen.
  "$PROBE" "$STEP" "$MAT" "$REF" "$HERE/m1" --stage regions --rung "$RUNG" \
      --cell 2 --threads 3 --regions provenance \
      > "$HERE/m1/regions_provenance_r${RUNG}.txt" 2>&1
  echo "M1 rung $RUNG ok"
done

# ── M2, the assignment table, BOTH RUNGS (bar R3 / §4b). Proposal 1 §3 measured the
# margin spread at rung 0.7973 at 1.1% across ten arms, so a table measured only at
# the shipped rung would show every assignment passing.
#
# The region subset and the density set are named on the command line so the cap is
# in the record, not in a default.
mkdir -p "$HERE/m2"
for RUNG in 0.68 0.26; do
  "$PROBE" "$STEP" "$MAT" "$REF" "$HERE/m2/r${RUNG}" --stage assign --rung "$RUNG" \
      --cell 2 --threads 3 --densities "${M2_DENSITIES:-0.30,0.45,0.60}" \
      ${M2_REGIONS:+--only-regions "$M2_REGIONS"} \
      > "$HERE/m2/assign_r${RUNG}.txt" 2>&1
  echo "M2 rung $RUNG ok"
done

echo QUEUE_DONE

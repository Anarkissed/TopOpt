#!/bin/sh
# ARM 2 — the parametric level set, run on HIS job, rung 0.68, 3 threads.
#
# ★ SERIALLY, ONE ARM AT A TIME. Each arm reports a wall clock and this machine's
# run-to-run offset under contention swallows the comparison
# (evidence/2026-08-09-reference-implementation-bakeoff/host_contention.txt).
#
# Every arm is SEEDED FROM HIS CONVERGED SIMP RUNG, exactly as PR 322/323/324/325
# were, so the costs below are additive to SIMP's and comparable to theirs.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

run() {
  name=$1; iters=$2; shift 2
  mkdir -p "$HERE/arm2/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/arm2/$name" \
      --rung 0.68 --iters "$iters" --threads 3 --snapshot-every 5 \
      --plsm-export 1 --plsm-export 2 --plsm-export 3 "$@" \
      > "$HERE/arm2/$name.log" 2>&1
  echo "$name done: $(grep -c '^it ' "$HERE/arm2/$name.log") iterations"
}

# ── A1 — THE PARAMETRIC ARM. Wendland C2 CSRBF, knots every 2 voxels PER AXIS,
# support 2x the spacing, MMA on the coefficients. Nothing else: no
# Hamilton-Jacobi, no CFL sub-stepping, no gamma damper, no reinitialisation, no
# Hilbertian extension. This is the representation change and only that.
run A1_mma_w2 40 --plsm-mma --plsm-knots 2,2,2 --plsm-support 2

# ── A2 — MAX EFFORT. Everything there is reason to believe helps, at once:
#   * the GLOBAL-SUPPORT basis (iPLSM's), 3-sigma truncated — ARM 1 measured it
#     with the lowest CAD deviation of any fit and the second-best cut roughness;
#   * the literature's APPROXIMATE RE-INITIALISATION — re-distance phi on the
#     grid and re-project onto the basis — because ARM 1 measured | |grad phi|-1 |
#     at 0.32 on the seed, and the ersatz maps phi LINEARLY through the band, so a
#     32% gradient error mis-places the iso surface by that much inside the band;
#   * MMA.
run A2_max 40 --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
    --plsm-support 2 --plsm-refit-every 5

# ── the ablations, so A1 and A2 are ATTRIBUTED and not merely celebrated ─────
# A3: steepest descent instead of MMA — the update rule alone.
run A3_descent_w2 20 --plsm --plsm-knots 2,2,2 --plsm-support 2
# A4: the Hilbertian extension put BACK. Tests the literature's claim that the
#     RBF support already extends the velocity and no scheme is needed.
run A4_hilb 20 --plsm-mma --plsm-knots 2,2,2 --plsm-support 2 --plsm-hilb
# A5: the PER-AXIS knot lattice ARM 1 put on the frontier (4,2,4), 19x
#     compression against A1's 5.5x — does a smaller design space still descend?
run A5_a424 20 --plsm-mma --plsm-knots 4,2,4 --plsm-support 2

echo ARM2_DONE

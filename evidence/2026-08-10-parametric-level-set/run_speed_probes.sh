#!/bin/sh
# S17 — THE THREE SPEED PROBES, measured rather than recommended.
#
# ★ 99.5% OF AN ITERATION IS THE STATE SOLVE. Measured: 25.412 s of 25.526, with
# the entire parametric machinery — basis evaluation, two sparse applies, MMA over
# 85,680 variables, the volume bisection — costing 0.114 s. So there is nothing to
# win in the representation and every idea below attacks the solve or the number
# of solves. NONE of them touches a line of production code.
#
# ★ AND THE COMBINATION IS THE RESULT. Warm starting alone is worth 4% and
# loosening alone is worth 44%; together they are 76%, because a tight solve is
# dominated by its TAIL, which a good starting point does not help, and loosening
# removes the tail. Measuring either alone badly undersells the pair.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"; REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"
BASE="--rung 0.68 --threads 3 --snapshot-every 0 --plsm-mma --plsm-knots 2,2,2 --plsm-support 2 --hj-steps 24"
mkdir -p "$HERE/speed"
run() { name=$1; iters=$2; shift 2
  mkdir -p "$HERE/speed/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/speed/$name" --iters "$iters" \
      $BASE "$@" > "$HERE/speed/$name.log" 2>&1 || echo "   ($name exited non-zero)"
  echo "$name: $(grep -c '^it ' "$HERE/speed/$name.log") iterations"; }

# PROBE 2 — INEXACT EARLY SOLVES. Cheapest, best payoff, and the ONLY one of the
# three that needs no production change to deploy: the tolerance is already an
# argument, and the CERTIFICATION is a separate call that keeps 1e-8 regardless.
run P2_baseline 8
for t in 1e-5 1e-4 1e-3; do run "P2_tol${t}" 8 --cg-tol-early "$t" --cg-tol-until 8; done

# PROBE 1 — WARM START, on the paths that HONOUR it. `simp_compliance` has taken
# an `initial_guess` since it was written and core has a `PenalizedSolver` that
# warm-starts itself; NEITHER reaches MultigridCG_Matfree, which is what runs. So
# --warm-start on the production path is a measured no-op, and these arms are what
# wiring one in would be worth.
run P1_jacobi_cold 5 --solver-kind 0
run P1_jacobi_warm 5 --solver-kind 0 --warm-start
run P1_cached      5 --solver-kind 0 --penalized-solver
# ★ and the two together, which is the finding
run P1b_loose_cold 5 --solver-kind 0 --cg-tol-early 1e-3 --cg-tol-until 5
run P1b_loose_warm 5 --solver-kind 0 --cg-tol-early 1e-3 --cg-tol-until 5 --warm-start

# PROBE 3 — L-BFGS on the coefficients against MMA. This lever exists ONLY because
# the representation is parametric: 85,680 variables can carry curvature, 468,224
# voxels cannot.
run P3_mma    12
run P3_lbfgs8 12 --plsm-lbfgs 8
echo SPEED_DONE

#!/bin/sh
# ARM 3 — ★ CAN IT REPLACE SIMP, RATHER THAN SIT ON TOP OF IT?
#
# Every arm in PR 322/323/324/325 and every arm in ARM 2 above is SEEDED FROM A
# CONVERGED SIMP RUNG, so its cost is ADDITIVE to SIMP's and it cannot replace
# anything. ★ THAT WAS A CHOICE, NOT A REQUIREMENT, and it was made to isolate a
# question about surfaces: seed both methods with the same topology and the only
# thing that differs is the representation.
#
# The classic level-set objection is that it cannot NUCLEATE HOLES — the
# interface can only move, so a 3D run is stuck with whatever topology it starts
# with, and SIMP is the cheapest way to get a good one. ★ THE PARAMETRIC FORM IS
# SPECIFICALLY CLAIMED TO FIX THAT. Wei, Li, Wang & Gao's abstract, of the very
# method ARM 2 implements: it "has less dependency on initial designs due to its
# capability in nucleation of new holes inside the material domain."
#
# A coefficient far from the interface can be driven negative by its own
# sensitivity and open a hole where there was solid — something a Hamilton-Jacobi
# advection of a per-voxel phi cannot do, because its velocity is zero away from
# the band. So the claim is structural, not incidental.
#
# This arm tests it on HIS part: the same optimiser, the same rung, the same
# certification, started from `--seed holes` — a regular array of holes with no
# SIMP anywhere in the pipeline. If it converges and certifies, the parametric
# level set is a REPLACEMENT and its cost stops being additive. If it does not,
# the seeding is a real dependency and the honest cost stays SIMP + this.
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
  mkdir -p "$HERE/arm3/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/arm3/$name" \
      --rung 0.68 --iters "$iters" --threads 3 --snapshot-every 10 \
      --plsm-export 1 --plsm-export 2 "$@" \
      > "$HERE/arm3/$name.log" 2>&1
  echo "$name done: $(grep -c '^it ' "$HERE/arm3/$name.log") iterations"
}

# B1 — from scratch, in the configuration ARM 2 found actually behaves: the
# global-support basis, the approximate re-initialisation that keeps |grad phi|
# near 1 (and with it the volume measure honest), MMA, and the step that matches
# what one state solve buys. 60 iterations: SIMP's own rung 0.68 converged in 27,
# and a from-scratch level set has more to do than one that was handed a topology.
run B1_scratch_max 60 --seed holes --plsm-mma --plsm-basis gaussian \
    --plsm-knots 2,2,2 --plsm-support 2 --plsm-refit-every 5 --hj-steps 24

# ── B2 — ★ THE LEVER THE DATA POINTS AT, AND IT EXISTS ONLY BECAUSE THE DESIGN
# IS PARAMETRIC. B1 came out ROUGHER than SIMP, and the instrument says why: its
# CAD population reads 7.81 against SIMP's 7.58 — essentially identical — while
# its CARVED population reads 14.11 against 7.55, and its carved SHARE more than
# doubles (79,679 triangles of internal surface against SIMP's 26,191). Roughness
# tracks ADDED SURFACE, so the problem is that a 85,680-coefficient basis has
# enough freedom to nucleate very fine structure.
#
# A COARSER BASIS CANNOT EXPRESS IT. Smoothness becomes a property of the
# representation rather than a rule policed afterwards — and there is no
# equivalent knob on a per-voxel level set at all. 24,480 coefficients, per axis.
run B2_scratch_coarse 60 --seed holes --plsm-mma --plsm-basis gaussian \
    --plsm-knots 4,2,4 --plsm-support 2 --plsm-refit-every 5 --hj-steps 24

mkdir -p "$HERE/s23_scratch" "$HERE/s25_coarse"
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/s23_scratch" \
    "SCRATCH-voxel=$HERE/arm3/B1_scratch_max/rho" \
    "SCRATCH-analytic-f2=$HERE/arm3/B1_scratch_max/plsm_f2" \
    > "$HERE/s23_scratch.txt" 2>&1
mv "$HERE/s23_scratch/s2_reference_impl_vs_simp.csv" "$HERE/s23_curves.csv"
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/s25_coarse" \
    "COARSE-voxel=$HERE/arm3/B2_scratch_coarse/rho" > "$HERE/s25_coarse.txt" 2>&1
mv "$HERE/s25_coarse/s2_reference_impl_vs_simp.csv" "$HERE/s25_curves.csv"

echo ARM3_DONE

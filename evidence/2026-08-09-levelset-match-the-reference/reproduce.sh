#!/bin/sh
# Regenerates every measurement in
# docs/handoffs/2026-08-09-levelset-match-the-reference.md.
#
# Everything here is IN THIS REPOSITORY. Nothing is cloned and no third-party
# toolchain is installed: the level set runs on our own solver and the SIMP
# baseline is our own shipped ladder.
#
# ★ THREE THREADS THROUGHOUT. He needs his Mac during the day, and a 3-thread
# level set beside a 6-thread SIMP is not a comparison — so the SIMP baseline is
# RE-MEASURED here at the same count rather than quoted from PR 321/322. The
# matrix-free apply is bit-identical at any thread count (production.hpp: the
# 8-colour partition fixes the accumulation order), so this changes wall clocks
# and nothing else.
#
# Cost on the machine of record: ~3 min to build, ~15 min for the SIMP baseline,
# ~2 h for the level set, ~20 min for the roughness curve.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"

STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"
RULES="core/src/settings/rules.json"

cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j6 --target levelset_probe external_field_surface_probe

# ── S1: the 3-THREAD SIMP BASELINE ──────────────────────────────────────────
# The SHIPPED ladder — core's own `minimize_plastic`, the entry `topopt-cli run`
# calls at run_job.cpp:8254 — narrowed to the single rung under test and run in
# this process's posture. Not one line of the optimizer is restated in the probe.
# Its s/iteration is the ONLY number the level set's s/iteration may be compared
# against, because it is the only one measured at the same thread count on the
# same machine.
mkdir -p "$HERE/s1_simp_3thread"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s1_simp_3thread" \
    --rung 0.68 --threads 3 --simp --rules "$RULES" \
    > "$HERE/s1_simp_3thread.log" 2>&1

# ── S2: the level set with all five differences ─────────────────────────────
# ★ ONE ARM AT A TIME, and NOT alongside S1: the deliverable is a wall time per
# iteration and this machine's run-to-run offset under contention is large enough
# to swallow the comparison (evidence/2026-08-09-reference-implementation-bakeoff/
# host_contention.txt). Do not parallelise these.
#
# Every flag here is a DEFAULT, spelled out so the run of record is legible:
#   --eta 2.0        (5) their eta_coeff
#   --gamma 0.1 --hj-steps 6   (3) their gamma and floor(order*min(el_size)/5)
#   --alpha-coeff 2.4          (4) their 4*max_steps*gamma
#   --traj-penalty 1.0         (2) their LINEAR I(phi)
# Difference (1), the surface delta, is not a flag — it is the scheme.
mkdir -p "$HERE/s2_levelset"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s2_levelset" \
    --rung 0.68 --iters 300 --threads 3 --snapshot-every 10 \
    --eta 2.0 --gamma 0.1 --hj-steps 6 --alpha-coeff 2.4 --traj-penalty 1.0 \
    > "$HERE/s2_levelset.log" 2>&1

# ── S5: alpha ALONE, the single-variable test of the mechanism ──────────────
# S2's cut roughness rises after iteration 30 while compliance barely improves.
# The paper names alpha "the so-called REGULARISATION LENGTH SCALE" and says it
# sets "the number of elements over which we regularise the gradient". This arm
# changes ONLY alpha, so the mechanism is tested and not asserted.
mkdir -p "$HERE/s5_alpha8"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s5_alpha8" \
    --rung 0.68 --iters 300 --threads 3 --snapshot-every 10 --alpha-coeff 8.0 \
    > "$HERE/s5_alpha8.log" 2>&1

# ── S6: THEIR RULE, CORRECTED FOR A SLAB, PLUS THEIR GAMMA DAMPER ───────────
# Two changes, both straight out of arXiv 2405.10478:
#
#  (a) --gridap-auto max. Their rule is
#          max_steps = floor(order*minimum(el_size)/10), DOUBLED in 3D
#          alpha     = 4*max_steps*gamma*maximum(el_delta)
#      With gamma = 0.1 the regularisation length in VOXELS is 0.4*max_steps:
#          their 2D 200x200       -> 20 steps -> alpha  8.0
#          their 3D 150x150x150   -> 30 steps -> alpha 12.0
#          his part 128 x 31 x118 ->  6 steps -> alpha  2.4   ← the thin axis
#      `minimum(el_size)` is a proxy for MESH REFINEMENT on their cubic meshes;
#      on a 4:1 slab it returns the thin axis and under-regularises by 5x.
#      Keying the same formula to the resolution axis gives 24 steps and
#      alpha 9.6 — inside their own 8-12 range.
#
#  (b) --damp. Their §4.1.8: "If oscillations are detected we reduce the CFL
#      number gamma for the Hamilton-Jacobi evolution equation by 25%." Our
#      gamma was otherwise fixed at 0.1 for the whole run.
#
# `--gridap-auto min` is the POSITIVE CONTROL: it must print max_steps 6 and
# alpha 2.4, i.e. reproduce S2's parameters exactly from the paper's formula.
mkdir -p "$HERE/s6_corrected"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s6_corrected" \
    --rung 0.68 --iters 300 --threads 3 --snapshot-every 10 \
    --gridap-auto max --damp \
    > "$HERE/s6_corrected.log" 2>&1

# ── S3: THE ROUGHNESS CURVE, on the SAME binary that produced PR 321/322's ──
# `external_field_surface_probe` is INVOKED, never retyped (R2): it reads an
# external occupancy on his lattice and puts it through
#   extract -> PR 307's CAD/cut classifier -> PR 299's oblique mask ->
#   deviation_from_cad + dihedral_rms_deg -> PR 306's controls
# The reference design.bin supplies HIS grid and contributes the four SIMP rows
# ITSELF, so this run carries its own baseline and no row is compared against a
# remembered number.
#
# Every 10th-iteration snapshot goes in as its own arm, which is how the CURVE —
# the task's actual deliverable — gets measured without a second implementation
# of a roughness metric existing anywhere.
set -- "$REF" "$STEP" "$HERE" "LS-final=$HERE/s2_levelset/rho" \
       "A8-final=$HERE/s5_alpha8/rho" "S6-final=$HERE/s6_corrected/rho"
for f in "$HERE"/s2_levelset/snap/it*.meta; do
  [ -e "$f" ] || continue
  stem="${f%.meta}"
  set -- "$@" "LS-$(basename "$stem")=$stem"
done
for f in "$HERE"/s5_alpha8/snap/it*.meta; do
  [ -e "$f" ] || continue
  stem="${f%.meta}"
  set -- "$@" "A8-$(basename "$stem")=$stem"
done
for f in "$HERE"/s6_corrected/snap/it*.meta; do
  [ -e "$f" ] || continue
  stem="${f%.meta}"
  set -- "$@" "S6-$(basename "$stem")=$stem"
done
./build/external_field_surface_probe "$@" > "$HERE/s3_surface_probe.txt" 2>&1
# That probe names its own CSV after the task it was written for; this task's row
# set is the same columns, so it is only renamed, never rewritten.
mv "$HERE/s2_reference_impl_vs_simp.csv" "$HERE/s3_levelset_vs_simp.csv"

# ── the bars ────────────────────────────────────────────────────────────────
# R4: the shipped path is untouched. This must print 0.
git diff main -- core/src core/include app/ ':!core/tests' | tee /dev/stderr | wc -l
cmake --build build -j6 && ctest --test-dir build --output-on-failure \
    > "$HERE/ctest.txt" 2>&1
echo "REPRODUCE_DONE"

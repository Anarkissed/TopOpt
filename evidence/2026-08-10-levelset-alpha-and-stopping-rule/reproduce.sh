#!/bin/sh
# Regenerates every measurement in
# docs/handoffs/2026-08-10-levelset-alpha-and-stopping-rule.md.
#
# Everything is IN THIS REPOSITORY. Nothing is cloned.
#
# ★ THREE THREADS THROUGHOUT, and the SIMP baseline is RE-MEASURED here at the
# same count rather than quoted — a 3-thread level set beside a 6-thread SIMP is
# not a comparison. The matrix-free apply is bit-identical at any thread count
# (production.hpp), so this changes wall clocks and nothing else.
#
# Cost on the machine of record: ~3 min to build, ~6 min for the SIMP baseline,
# ~28 min for the alpha-min arm, ~17 min for the alpha-max arm, ~20 min for the
# surface measurement, ~13 min for the per-iterate certifications.
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

# ── S1: the three runs. ONE AT A TIME — each reports a wall time and this
# machine's run-to-run offset under contention swallows the comparison
# (evidence/2026-08-09-reference-implementation-bakeoff/host_contention.txt).
mkdir -p "$HERE/s1_simp_3thread" "$HERE/s2_alpha_min" "$HERE/s3_alpha_max"

# The 3-thread SIMP baseline: core's own `minimize_plastic`, the entry
# `topopt-cli run` calls, ladder narrowed to the single rung under test.
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s1_simp_3thread" \
    --rung 0.68 --threads 3 --simp --rules "$RULES" \
    > "$HERE/s1_simp_3thread.log" 2>&1

# ARM A — their rule AS WRITTEN. `--gridap-auto min` evaluates
#     max_steps = 2*floor(order*minimum(el_size)/10)
#     alpha     = 4*max_steps*gamma*maximum(el_delta)
# on the real grid; on his 128 x 31 x 118 it must return max_steps 6 and
# alpha 2.4 voxels, reproducing PR 323's run of record. ★ THAT IS THE POSITIVE
# CONTROL: if it stops returning 6 / 2.4, something else moved.
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s2_alpha_min" \
    --rung 0.68 --iters 300 --threads 3 --snapshot-every 5 --gridap-auto min \
    > "$HERE/s2_alpha_min.log" 2>&1

# ARM B — the same rule keyed to the RESOLUTION axis instead of the thin one:
# 24 steps, alpha 9.6 voxels, inside the paper's own 8-12 band, with the coupling
# alpha = 4*max_steps*gamma*h preserved. Plus their gamma oscillation damper.
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s3_alpha_max" \
    --rung 0.68 --iters 300 --threads 3 --snapshot-every 5 --gridap-auto max --damp \
    > "$HERE/s3_alpha_max.log" 2>&1

# ── S1c + S3: the curves and the LIKE-FOR-LIKE column ───────────────────────
# `external_field_surface_probe` is INVOKED, never retyped (R2). It carries its
# own four SIMP baseline rows from the reference design.bin, so no row is
# compared against a remembered number.
#
# ★ S3's column. `dihedral_cut_deg` restricts each arm to the triangles THAT
# ARM's classifier called CUT, and the two arms do not have the same cut
# population (PR 323: 18.4% for SIMP, 36.2% for the level set on iteration 1).
# `dihedral_refcut_deg` measures every arm over the SAME REGION OF SPACE — the
# voxels the REFERENCE's cut surface passes through, dilated one voxel — so the
# column compares like with like. Both are reported; neither replaces
# `dihedral_all_deg`, which is population-independent already.
set -- "$REF" "$STEP" "$HERE" \
       "MIN-final=$HERE/s2_alpha_min/rho" "MAX-final=$HERE/s3_alpha_max/rho"
for pfx in MIN:s2_alpha_min MAX:s3_alpha_max; do
  tag=${pfx%%:*}; dir=${pfx#*:}
  for f in "$HERE/$dir"/snap/it*.meta; do
    [ -e "$f" ] || continue
    stem="${f%.meta}"
    set -- "$@" "$tag-$(basename "$stem")=$stem"
  done
done
./build/external_field_surface_probe "$@" > "$HERE/s4_surface_probe.txt" 2>&1
mv "$HERE/s2_reference_impl_vs_simp.csv" "$HERE/s4_curves.csv"

# ── S2: WHERE THE MARGIN SATURATES, for BOTH arms ───────────────────────────
# PR 323 certified only one trajectory. Both are certified here, every 5
# iterations, by `analyze_fixed_design` at the PRODUCTION penalty, isolated
# exactly as production isolates a re-certification.
#
# `--certify-field` is repeatable and ONE process certifies a whole trajectory:
# each invocation pays ~40 s to import the STEP, voxelize and build the load case
# before it can certify anything, and a margin curve needs twenty-odd of them.
# The certifications are independent and identical to one-per-process — the
# posture is disarmed the same way and `analyze_fixed_design` carries no state
# once recycling and GenEO are off. Each run writes `margin_curve.csv`.
for pfx in MIN:s2_alpha_min MAX:s3_alpha_max; do
  tag=${pfx%%:*}; dir=${pfx#*:}
  mkdir -p "$HERE/s5_margin_curve/$tag"
  set -- "$STEP" "$MATS" "$REF" "$HERE/s5_margin_curve/$tag" --threads 3
  for f in "$HERE/$dir"/snap/it*.meta; do
    [ -e "$f" ] || continue
    set -- "$@" --certify-field "${f%.meta}"
  done
  ./build/levelset_probe "$@" >> "$HERE/s5_margin_curve.log" 2>&1
done

# ── the bars ────────────────────────────────────────────────────────────────
# R5: the shipped path is untouched. This must print 0.
git diff main -- core/src core/include app/ ':!core/tests' | tee /dev/stderr | wc -l
cmake --build build -j6 && ctest --test-dir build --output-on-failure \
    > "$HERE/ctest.txt" 2>&1
echo "REPRODUCE_DONE"

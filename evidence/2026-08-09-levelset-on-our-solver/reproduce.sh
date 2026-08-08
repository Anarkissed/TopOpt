#!/bin/sh
# Regenerates every measurement in
# docs/handoffs/2026-08-09-levelset-on-our-solver.md.
#
# Everything here is IN THIS REPOSITORY. Unlike the bakeoff this task follows
# from (evidence/2026-08-09-reference-implementation-bakeoff), no third-party
# library is cloned and no Julia environment is built: the level set runs on our
# own solver, which is the entire point.
#
# Cost on the machine of record: ~3 min to build, ~50 min for the FP64 arm,
# ~50 min for the FP32 arm, ~2 min for the surface measurement.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"

STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j8 --target levelset_probe external_field_surface_probe

# ── S2/S3: the level set on our solver, his part, rung 0.68 ─────────────────
# ★ ONE ARM AT A TIME. The deliverable is a WALL TIME PER ITERATION, and this
# machine's run-to-run offset under contention is large enough to swallow the
# comparison (evidence/2026-08-09-reference-implementation-bakeoff/
# host_contention.txt). Do not parallelise these two.
mkdir -p "$HERE/s2_ls_fp64"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s2_ls_fp64" \
    --rung 0.68 --iters 120 > "$HERE/s2_ls_fp64.log" 2>&1

# ── S1: the same run with the opt-in FP32 V-cycle armed ─────────────────────
mkdir -p "$HERE/s1_ls_fp32"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s1_ls_fp32" \
    --rung 0.68 --iters 120 --fp32 > "$HERE/s1_ls_fp32.log" 2>&1

# S1's ANSWER is this comparison, not the two wall clocks: the V-cycle never
# engages on his part, so the FP32 branch is never taken and the design is
# bit-for-bit the same. Both lines must say the files are identical.
cmp -s "$HERE/s2_ls_fp64/rho.f64"    "$HERE/s1_ls_fp32/rho.f64" \
    && echo "rho.f64    BYTE-IDENTICAL" || echo "rho.f64    DIFFERS"
cmp -s "$HERE/s2_ls_fp64/design.bin" "$HERE/s1_ls_fp32/design.bin" \
    && echo "design.bin BYTE-IDENTICAL" || echo "design.bin DIFFERS"

# ── R2: the roughness row, on the SAME binary that produced PR 321's ────────
# The reference design.bin supplies HIS grid and contributes the four SIMP rows
# itself, so this run carries its own baseline and no row is compared against a
# remembered number.
gunzip -kf "$HERE/s2_ls_fp64/rho.f64.gz" 2>/dev/null || true
./build/external_field_surface_probe "$REF" "$STEP" "$HERE" \
    "LS-OURS=$HERE/s2_ls_fp64/rho" \
    "LS-OURS-FP32=$HERE/s1_ls_fp32/rho" > "$HERE/s3_surface_probe.txt" 2>&1
# That probe names its own CSV after the task it was written for; this task's
# row set is the same columns, so it is only renamed, never rewritten.
mv "$HERE/s2_reference_impl_vs_simp.csv" "$HERE/s3_levelset_vs_simp.csv"

# ── the bars ────────────────────────────────────────────────────────────────
# R3: the shipped path is untouched. This must print nothing at all.
git diff main -- core/src core/include app/ ':!core/tests' | tee /dev/stderr | wc -l
cmake --build build -j8 && ctest --test-dir build --output-on-failure \
    > "$HERE/ctest.txt" 2>&1
echo "REPRODUCE_DONE"

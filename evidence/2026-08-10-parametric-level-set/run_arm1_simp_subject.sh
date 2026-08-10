#!/bin/sh
# ★ ARM 1, RE-RUN WITH SIMP AS THE SUBJECT, NOT ONLY AS THE BASELINE.
#
# ARM 1 as first run fitted an analytic phi to designs produced by the DISCARDED
# voxel level set. That was the right controlled experiment — same design, two
# representations — but it means the whole story is told about a process that is
# no longer run. This arm removes it: the subject is HIS OWN SIMP RUNG 0.68, the
# design the shipped ladder actually produces. Baseline and subject are now the
# same method, and every comparison is SIMP against SIMP-refitted.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

mkdir -p "$HERE/simpfit"
./build/plsm_probe "$HERE/sources/simp/rung_0.68" "$HERE/simpfit" --threads 3 \
    --emit-factor 1 --emit-factor 2 --emit-factor 3 --emit-source \
    --fit W2:wendland:2,2,2:2 --fit G2:gaussian:2,2,2:2 \
    --fit A424:wendland:4,2,4:2 --fit W4:wendland:4,4,4:2 \
    > "$HERE/s14_fit_SIMP.txt" 2>&1

mkdir -p "$HERE/s15_simpfit"
set -- "$REF" "$STEP" "$HERE/s15_simpfit"
for F in 1 2 3; do
  set -- "$@" "SF-src-f$F=$HERE/simpfit/SRC_f$F" "SF-band-f$F=$HERE/simpfit/SRCPHI_f$F"
done
for L in W2 G2 A424 W4; do for F in 1 2 3; do
  set -- "$@" "SF-$L-f$F=$HERE/simpfit/${L}_vm_f$F"; done; done
./build/external_field_surface_probe "$@" > "$HERE/s15_simpfit.txt" 2>&1
mv "$HERE/s15_simpfit/s2_reference_impl_vs_simp.csv" "$HERE/s15_curves.csv"

mkdir -p "$HERE/s16_simpfit_margin"
set -- "$STEP" "$MATS" "$REF" "$HERE/s16_simpfit_margin" --threads 3 --respect-frozen
for L in W2 G2 A424 W4; do
  set -- "$@" --certify-field "$HERE/simpfit/${L}_vm_f1"; done
set -- "$@" --certify-field "$HERE/sources/simp/rung_0.68"
./build/levelset_probe "$@" > "$HERE/s16_simpfit_margin.log" 2>&1
echo SIMPFIT_DONE

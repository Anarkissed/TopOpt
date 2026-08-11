#!/bin/sh
# THE LAST MEASUREMENT BATCH.
#
#   F1  ★ THE MATCHED-ITERATION SURFACE TABLE. Every arm at iteration 60, from
#       its snapshot — NOT from `rho`. `levelset_probe` writes the
#       BEST-COMPLIANCE iterate, which is iteration 9 for one arm here and 60
#       for another, so a table built off `rho` compares arms at different
#       points in their own lives. PR 324 §6 documented exactly this trap for
#       its ablations and I walked into it anyway.
#   F2  the eta arm's and the mask arm's margin curves (they ran after `measure.sh`).
#   F3  ★ THE MARGIN VARIANCE. Every iterate of `A4_mask`'s converged tail,
#       certified. This is the error bar every "costs X% of margin" in this task
#       is quoted against, and until now it did not exist.
#   F4  S2's certification, which `measure.sh` lost to a missing directory.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

ALL="RB1_volcount S0_seed16 P1_c1 P2_c2 P3_c4 P4_c8 PR_c4_ramp N1_c4_norefit \
     A2_all A3_seed16_perim E1_c1_eta1 A4_mask"

# ── F1 — matched iteration 60, one invocation, SIMP in the same run (R2).
mkdir -p "$HERE/m3"
set --
for A in $ALL; do
  [ -f "$HERE/arms/$A/snap/it0060.f64" ] && set -- "$@" "$A=$HERE/arms/$A/snap/it0060"
done
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/m3" "$@" \
    > "$HERE/m3_matched.txt" 2>&1
cp "$HERE/m3/s2_reference_impl_vs_simp.csv" "$HERE/m3_matched.csv"
echo "F1 done -> m3_matched.csv"

# ── F2 + F3 — the two late arms' curves, and the VARIANCE on A4's tail.
# ★ ONE PROCESS for all of it: the STEP import and load-case build cost ~40 s
# and are paid once rather than eighty times.
mkdir -p "$HERE/m4"
set --
for A in E1_c1_eta1 A4_mask; do
  for S in "$HERE/arms/$A"/snap/it00[123456]0.f64; do
    [ -f "$S" ] || continue
    set -- "$@" --certify-field "${S%.f64}"
  done
done
# ★ EVERY iterate of A4's tail. 41 through 60 — past the compliance plateau, so
# these are twenty certifications of ONE converged design's neighbourhood.
for i in 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
  S="$HERE/arms/A4_mask/snap/it00$i"
  [ -f "$S.f64" ] && set -- "$@" --certify-field "$S"
done
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/m4" --rung 0.68 \
    --threads 3 "$@" > "$HERE/m4_margin.txt" 2>&1
[ -s "$HERE/m4/margin_curve.csv" ] || { echo "FAIL: m4/margin_curve.csv empty"; exit 1; }
echo "F2+F3 done -> m4/margin_curve.csv"

# ── F4 — S2's certification (S2(b): the load path, on the CAD-boolean field).
for A in RB1_volcount; do
  [ -f "$HERE/s2/$A-cad/ALPHA_vm_f1.f64" ] || continue
  mkdir -p "$HERE/s2/$A-cert"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s2/$A-cert" --rung 0.68 \
      --threads 3 \
      --certify-field "$HERE/s2/$A-tags/ALPHA_vm_f1" \
      --certify-field "$HERE/s2/$A-cad/ALPHA_vm_f1" \
      > "$HERE/s2_${A}_cert.txt" 2>&1
  cp "$HERE/s2/$A-cert/margin_curve.csv" "$HERE/s2_${A}_cert.csv"
  echo "F4 done -> s2_${A}_cert.csv"
done

echo FINAL_DONE

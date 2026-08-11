#!/bin/sh
# THE MEASUREMENTS. ★ EVERY NUMBER FROM OUR OWN INSTRUMENTS, INVOKED (R2).
#
#   roughness / surface / CAD error / midpoint share / enclosed volume
#       -> external_field_surface_probe, ONE invocation per table, with the
#          SIMP row produced IN THE SAME RUN at the SAME extraction factor.
#   margin / mass / load path / verdict
#       -> analyze_fixed_design, through `levelset_probe --certify-field`.
#
# ★ EVERY ROW AT A MATCHED ITERATION, FROM ITS OWN SNAPSHOT. `levelset_probe`
# writes the BEST-COMPLIANCE iterate to `rho`, which across PR 326's twelve arms
# landed on iterations 9, 20, 40, 55, 57 and 60 — so a table built off `rho`
# compares arms at different points in their own lives. That is PR 326's P11 and
# it reversed one of its conclusions. Nothing here reads `rho`.
#
# ★ AND THE SNAPSHOTS ARE THE H_eta OCCUPANCY IN BOTH ARMS. The exact-fraction
# arm changes what the OPTIMISER sees, not what is printed: `occ` is
# H_eta(-phi) at the cell centre in both, so a snapshot comparison is a
# comparison of two DESIGNS through one unchanged extraction. The fraction
# EXPORT is measured separately, in (3), as a named second axis.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

ARMS=${ARMS:-"H1_heaviside F1_frac4 A2_all"}

# ★ THE MATCHED ITERATION IS THE LAST ONE *EVERY* ARM REACHED, DERIVED RATHER
# THAN ASSUMED. An arm can stop early on the compliance plateau, and hard-coding
# 0120 would then silently drop it from the table — which reads as "the arm was
# not run" instead of "the arm stopped at 90". This picks the highest snapshot
# index present in ALL arms, and prints it, so the table's own header says which
# iteration it is a table of. `LAST=` in the environment overrides.
if [ -z "${LAST:-}" ]; then
  LAST=""
  for S in "$HERE/arms/$(echo "$ARMS" | cut -d' ' -f1)"/snap/it*.f64; do
    [ -f "$S" ] || continue
    IT=$(basename "$S" .f64); IT=${IT#it}
    OK=1
    for A in $ARMS; do
      [ -f "$HERE/arms/$A/snap/it$IT.f64" ] || OK=0
    done
    [ "$OK" = "1" ] && LAST=$IT
  done
  [ -n "$LAST" ] || { echo "FAIL: no snapshot iteration is present in every arm"; exit 1; }
fi
echo "matched iteration: $LAST"

# ── (1) THE MATCHED-ITERATION SURFACE TABLE, one invocation, SIMP in the run.
mkdir -p "$HERE/m1"
set --
for A in $ARMS; do
  [ -f "$HERE/arms/$A/snap/it$LAST.f64" ] && set -- "$@" "$A=$HERE/arms/$A/snap/it$LAST"
done
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/m1" "$@" \
    > "$HERE/m1_matched.txt" 2>&1
cp "$HERE/m1/s2_reference_impl_vs_simp.csv" "$HERE/m1_matched.csv"
echo "(1) done -> m1_matched.csv"

# ── (2) THE MARGIN CURVE. Every snapshot of every arm, certified, in ONE
# process — the STEP import and load-case build cost ~40 s and are paid once
# rather than once per certificate. ★ THE CURVE IS THE DELIVERABLE, not the
# endpoint: R3 asks for the settling iteration, and PR 326 measured the margin
# settling far later than the compliance.
mkdir -p "$HERE/m2"
set --
for A in $ARMS; do
  for S in "$HERE/arms/$A"/snap/it*.f64; do
    [ -f "$S" ] || continue
    set -- "$@" --certify-field "${S%.f64}"
  done
done
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/m2" --rung 0.68 \
    --threads 3 "$@" > "$HERE/m2_margin.txt" 2>&1
[ -s "$HERE/m2/margin_curve.csv" ] || { echo "FAIL: m2/margin_curve.csv empty"; exit 1; }
cp "$HERE/m2/margin_curve.csv" "$HERE/m2_margin.csv"
echo "(2) done -> m2_margin.csv"

# ── (3) ★ THE EXPORT CONVENTION, AS A SEPARATE AXIS. The SAME design emitted
# three ways: the F=1 voxel occupancy (the row of record above), the F=2
# ANALYTIC H_eta field, and the F=2 VOLUME-FRACTION field. Identical
# coefficients, identical lattice, identical frozen stamp — only the number each
# fine cell carries changes. ★ R2's constant-extraction-factor rule means the
# F=2 rows may be compared with each other and NOT with the F=1 rows;
# `dihedral_rms_deg` scales like kappa*h and falls with the lattice on any field.
mkdir -p "$HERE/m3"
set --
for A in $ARMS; do
  [ -f "$HERE/arms/$A/plsm_f2.f64" ] && set -- "$@" "${A}_hev_f2=$HERE/arms/$A/plsm_f2"
  [ -f "$HERE/arms/$A/plsmfrac_f2.f64" ] && set -- "$@" "${A}_frac_f2=$HERE/arms/$A/plsmfrac_f2"
done
if [ $# -gt 0 ]; then
  ./build/external_field_surface_probe "$REF" "$STEP" "$HERE/m3" "$@" \
      > "$HERE/m3_export.txt" 2>&1
  cp "$HERE/m3/s2_reference_impl_vs_simp.csv" "$HERE/m3_export.csv"
  echo "(3) done -> m3_export.csv"
fi

# ── (4) the export fields' own certificates, so a mass and a margin sit beside
# every roughness number in (3) — R3, and the reason PR 323's volume finding
# exists at all.
mkdir -p "$HERE/m4"
set --
for A in $ARMS; do
  [ -f "$HERE/arms/$A/plsm_f1.f64" ] && set -- "$@" --certify-field "$HERE/arms/$A/plsm_f1"
  [ -f "$HERE/arms/$A/plsmfrac_f1.f64" ] && set -- "$@" --certify-field "$HERE/arms/$A/plsmfrac_f1"
done
if [ $# -gt 0 ]; then
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/m4" --rung 0.68 \
      --threads 3 "$@" > "$HERE/m4_export_cert.txt" 2>&1
  cp "$HERE/m4/margin_curve.csv" "$HERE/m4_export_cert.csv"
  echo "(4) done -> m4_export_cert.csv"
fi

echo MEASURE_DONE

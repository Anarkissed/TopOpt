#!/bin/sh
# THE MEASUREMENTS. R2 — every instrument INVOKED, never retyped.
#
#   M1  ★ THE SURFACE TABLE AT MATCHED ITERATION 50, from each arm's own
#       snapshot. NOT from `rho`, which is the arm's BEST-COMPLIANCE iterate and
#       differs between arms by tens of iterations — the error PR 326 §2 records
#       and which reversed one of its conclusions. SIMP's rows come from the
#       same invocation at the same extraction factor (R2, and the brief's S(d)).
#   M2  the margin CURVES, from `analyze_fixed_design` via `--certify-field` on
#       every snapshot, with mass, achieved vf and the load-path walk (R3).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
PR324="$REPO/evidence/2026-08-10-parametric-level-set"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

ARMS="$*"
if [ -z "$ARMS" ]; then
  ARMS=""
  for s in "$HERE"/arms/*/summary.txt; do
    [ -f "$s" ] || continue
    b=$(basename "$(dirname "$s")")
    if [ "${b#C0_}" = "$b" ]; then ARMS="$ARMS $b"; fi
  done
fi
echo "arms: $ARMS"

mkdir -p "$HERE/sources"
for f in simp/rung_0.68 designmask; do
  b=$(basename "$f")
  [ -f "$HERE/sources/$b.f64" ] || {
    gunzip -c "$PR324/sources/$f.f64.gz" > "$HERE/sources/$b.f64"
    cp "$PR324/sources/$f.meta" "$HERE/sources/$b.meta"; }
done

# ── M1 — matched iteration 60, one invocation, SIMP in the same run.
mkdir -p "$HERE/m1"
set --
for A in $ARMS; do
  # ★ ITERATION 50, NOT 60, AND THE CONTROL ARM IS WHY. `F0_none` stopped at
  # 56 on the SHIPPED COMPLIANCE PLATEAU (window 10, tol 1e-3) and so has no
  # it0060 snapshot at all. Different arms plateau at different iterations, so
  # 60 is not a matched point — 50 is the last snapshot every arm reaches.
  # ★ AND THE EARLY STOP IS ITSELF A FINDING: F0's margin went 3195 -> 3395
  # between iterations 40 and 50, i.e. it was still climbing when a
  # COMPLIANCE-based rule stopped it. That is precisely what the brief's S(c)
  # warns about, met in the first arm of the task.
  [ -f "$HERE/arms/$A/snap/it0050.f64" ] && set -- "$@" "$A=$HERE/arms/$A/snap/it0050"
done
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/m1" "$@" \
    > "$HERE/m1_surface.txt" 2>&1
cp "$HERE/m1/s2_reference_impl_vs_simp.csv" "$HERE/m1_matched.csv"
echo "M1 done -> m1_matched.csv"

# ── M2 — the margin curves. ★ mkdir FIRST: `--certify-field` opens
# <out>/margin_curve.csv WITHOUT creating <out>, and fails silently if it is
# absent. That cost PR 326 a run.
mkdir -p "$HERE/m2"
set --
for A in $ARMS; do
  for S in "$HERE/arms/$A"/snap/it*.f64; do
    [ -f "$S" ] || continue
    set -- "$@" --certify-field "${S%.f64}"
  done
done
set -- "$@" --certify-field "$HERE/sources/rung_0.68"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/m2" --rung 0.68 \
    --threads 3 "$@" > "$HERE/m2_margin.txt" 2>&1
[ -s "$HERE/m2/margin_curve.csv" ] || { echo "FAIL: m2/margin_curve.csv empty"; exit 1; }
echo "M2 done -> m2/margin_curve.csv ($(( $(wc -l < "$HERE/m2/margin_curve.csv") - 1 )) certifications)"
echo MEASURE_DONE

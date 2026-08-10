#!/bin/sh
# S11 — ARM 2 measured and certified on the SAME instruments as ARM 1 and as
# every arm since PR 322. Nothing about a roughness number or a margin is
# computed here: `external_field_surface_probe` and `levelset_probe
# --certify-field` are INVOKED (R2).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

# ── S11a: THE SURFACE ───────────────────────────────────────────────────────
#
# ★ EACH ARM APPEARS TWICE, AND THE TWO ROWS ANSWER DIFFERENT QUESTIONS.
#
#   <arm>-voxel     the design SAMPLED ONTO THE VOXEL GRID and extracted at
#                   factor 2 tricubic. This is how SIMP, PR 322, PR 323, PR 324,
#                   PR 325 and GridapTopOpt were every one of them measured, so
#                   it is the ONLY row that belongs in the handoff's §0 table.
#   <arm>-analytic  the zero set of the FUNCTION, evaluated on a refined lattice
#                   and extracted with `factor 1` / `interp none`. This is what a
#                   parametric level set is actually FOR, and it is not
#                   comparable to a factor-2 voxel row — a finer extraction
#                   lattice lowers `dihedral_rms_deg` on any field. It is
#                   comparable to ARM 1's F=2 and F=3 columns, which carry their
#                   own voxel controls at the same lattice.
mkdir -p "$HERE/s11_surface"
set -- "$REF" "$STEP" "$HERE/s11_surface"
for A in A1_mma_w2 A2_max A3_descent_w2 A4_hilb A5_a424 A4b_hilb_descent A6_step24 A7_max_step24; do
  [ -f "$HERE/arm2/$A/rho.f64" ] || continue
  set -- "$@" "${A}-voxel=$HERE/arm2/$A/rho"
  if [ -f "$HERE/arm2/$A/plsm_f2.f64" ]; then
    set -- "$@" "${A}-analytic-f2=$HERE/arm2/$A/plsm_f2"
  fi
done
# ★ WHAT IS DELIBERATELY NOT MEASURED, ON THE RECORD RATHER THAN IMPLIED: the
# F=3 analytic export is measured for the two arms that reach the frontier and
# not for the other six, and the roughness CURVE is sampled every 10 iterations
# rather than every 5. Marching cubes on a 1.3e7-sample lattice is minutes per
# arm and the omitted rows add nothing the columns below do not already show.
for A in A1_mma_w2 A6_step24; do
  if [ -f "$HERE/arm2/$A/plsm_f3.f64" ]; then
    set -- "$@" "${A}-analytic-f3=$HERE/arm2/$A/plsm_f3"
  fi
done
# the roughness CURVE, every 10 iterations, on the arms long enough to have one
for A in A1_mma_w2 A2_max A6_step24 A7_max_step24; do
  for it in 0001 0010 0020 0030 0040; do
    f="$HERE/arm2/$A/snap/it$it"
    if [ -e "$f.meta" ]; then set -- "$@" "${A}-it$it=$f"; fi
  done
done
./build/external_field_surface_probe "$@" > "$HERE/s11_surface.txt" 2>&1
mv "$HERE/s11_surface/s2_reference_impl_vs_simp.csv" "$HERE/s11_curves.csv"

# ── S11b: THE MARGIN CURVE (R3 — a curve, never a point) ────────────────────
# Every snapshot of A1 and A2, and the final iterate of every arm. No
# `--respect-frozen`: these fields were produced by `build_fields`, which stamps
# the mask on every iteration, so they already carry it. That is precisely the
# difference from ARM 1's fitted fields, and it is why these certify and those
# did not.
mkdir -p "$HERE/s12_margin"
set -- "$STEP" "$MATS" "$REF" "$HERE/s12_margin" --threads 3
# ★ EVERY ARM'S EVERY SNAPSHOT, NOT JUST THE LONG ARMS'. The ablations A3/A4/A5
# ran 20 iterations and A1/A2 ran 40, so their FINAL margins are not comparable —
# a 50% margin gap between A1 and A3 would be reporting the iteration count. The
# snapshots are the same construction on every arm, so certifying all of them lets
# the ablation be read at a MATCHED iteration.
for A in A1_mma_w2 A2_max A3_descent_w2 A4_hilb A5_a424 A4b_hilb_descent A6_step24 A7_max_step24; do
  for f in "$HERE/arm2/$A"/snap/it*.meta; do
    [ -e "$f" ] || continue
    set -- "$@" --certify-field "${f%.meta}"
  done
  if [ -f "$HERE/arm2/$A/rho.f64" ]; then
    set -- "$@" --certify-field "$HERE/arm2/$A/rho"
  fi
done
./build/levelset_probe "$@" > "$HERE/s12_margin.log" 2>&1

# ── S11c: ★ THE BAND CONTROL FOR THE STRESS, which the roughness control does
# not cover. ARM 1's fitted fields carry 4.6x more gray voxels than their source
# (89260 against 19250), and a more diffuse density field lowers peak von Mises
# for reasons that have nothing to do with geometry. `--binarize` thresholds the
# field at the iso BEFORE certifying, so both sides become pure geometry with no
# band at all. Any peak-stress difference that survives is the shape.
mkdir -p "$HERE/s13_binarize"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s13_binarize" \
    --threads 3 --respect-frozen --binarize \
    --certify-field "$HERE/sources/C2it25" \
    --certify-field "$HERE/sources/simp/rung_0.68" \
    --certify-field "$HERE/fields/G2_vm_f1" \
    --certify-field "$HERE/fields/A424_vm_f1" \
    --certify-field "$HERE/fields/W2_vm_f1" \
    --certify-field "$HERE/fields/W8_vm_f1" \
    > "$HERE/s13_binarize.log" 2>&1

echo MEASURE_ARM2_DONE

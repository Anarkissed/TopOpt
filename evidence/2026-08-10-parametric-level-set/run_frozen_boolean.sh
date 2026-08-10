#!/bin/sh
# S18-S22 — ★ THE FROZEN SET AS A BOOLEAN, NOT A STAMP.
#
# The first pass measured roughness on fitted fields with NO frozen mask — which
# is exactly why every one of them was REJECTED on the load path. Stamping the
# mask back in is what production does, but stamping 40,216 voxels to hard 0/1
# over an analytic phi is a staircase by construction and costs most of the win.
#
# With solid = {phi < 0}, UNION is `min` and INTERSECTION is `max`, so
#     phi_eff = max( min(phi, phi_frozen_solid), -phi_frozen_void )
# is the same object with no tags surviving into it — and the frozen material is
# negative BY CONSTRUCTION, so the load path cannot break.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"; REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

# the mask as a FIELD, so it can be turned into a function
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s18_masked" --threads 3 \
    --dump-mask "$HERE/sources/designmask" \
    --certify-field "$HERE/sources/simp/rung_0.68" > "$HERE/s18_maskdump.log" 2>&1

# S18/S19 — the STAMPED object, which is what certifies today
mkdir -p "$HERE/masked" "$HERE/s19_masked_surface"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s18_masked" --threads 3 \
    --respect-frozen --dump-masked "$HERE/masked" \
    --certify-field "$HERE/fields/G2_vm_f1" --certify-field "$HERE/fields/A424_vm_f1" \
    --certify-field "$HERE/fields/W2_vm_f1" --certify-field "$HERE/sources/C2it25" \
    --certify-field "$HERE/sources/simp/rung_0.68" > "$HERE/s18_masked.log" 2>&1
set -- "$REF" "$STEP" "$HERE/s19_masked_surface"
for spec in "MK-SIMP rung_0.68" "MK-SRC C2it25" "MK-G2 G2_vm_f1" \
            "MK-A424 A424_vm_f1" "MK-W2 W2_vm_f1"; do
  set -- "$@" "$(echo $spec | cut -d' ' -f1)=$HERE/masked/$(echo $spec | cut -d' ' -f2)"
done
./build/external_field_surface_probe "$@" > "$HERE/s19_masked.txt" 2>&1
mv "$HERE/s19_masked_surface/s2_reference_impl_vs_simp.csv" "$HERE/s19_curves.csv"

# S20-S22 — the SMOOTH BOOLEAN, measured in the SHIPPED convention so it sits
# beside SIMP's own row without a caveat
mkdir -p "$HERE/boolean" "$HERE/boolean_shipped" "$HERE/s22_bs"
./build/plsm_probe "$HERE/sources/C2it25" "$HERE/boolean" --threads 3 \
    --emit-factor 1 --emit-factor 2 --frozen-mask "$HERE/sources/designmask" \
    --fit G2:gaussian:2,2,2:2 --fit A424:wendland:4,2,4:2 > "$HERE/s20_boolean.txt" 2>&1
for L in G2 A424; do
  rm -f "$HERE/boolean_shipped/$L.f64"
  cp "$HERE/boolean/${L}_vm_f1.f64" "$HERE/boolean_shipped/$L.f64"
  sed -e 's/^factor .*/factor 2/' -e 's/^interp .*/interp tricubic/' \
      "$HERE/boolean/${L}_vm_f1.meta" > "$HERE/boolean_shipped/$L.meta"
done
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/s22_bs" \
    "BS-G2=$HERE/boolean_shipped/G2" "BS-A424=$HERE/boolean_shipped/A424" \
    > "$HERE/s22_bs.txt" 2>&1
mv "$HERE/s22_bs/s2_reference_impl_vs_simp.csv" "$HERE/s22_curves.csv"

# S26/S27 — ★ THE HEADLINE ROW: SIMP as subject, frozen set as a boolean,
# measured AND certified so the roughness carries a margin beside it.
mkdir -p "$HERE/simpbool" "$HERE/simpbool_shipped" "$HERE/s26_simpbool" "$HERE/s27_simpbool_margin"
./build/plsm_probe "$HERE/sources/simp/rung_0.68" "$HERE/simpbool" --threads 3 \
    --emit-factor 1 --frozen-mask "$HERE/sources/designmask" \
    --fit G2:gaussian:2,2,2:2 --fit A424:wendland:4,2,4:2 --fit W2:wendland:2,2,2:2 \
    > "$HERE/s26_simpbool.txt" 2>&1
for L in G2 A424 W2; do
  rm -f "$HERE/simpbool_shipped/$L.f64"
  cp "$HERE/simpbool/${L}_vm_f1.f64" "$HERE/simpbool_shipped/$L.f64"
  sed -e 's/^factor .*/factor 2/' -e 's/^interp .*/interp tricubic/' \
      "$HERE/simpbool/${L}_vm_f1.meta" > "$HERE/simpbool_shipped/$L.meta"
done
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/s26_simpbool" \
    "SB-G2=$HERE/simpbool_shipped/G2" "SB-A424=$HERE/simpbool_shipped/A424" \
    "SB-W2=$HERE/simpbool_shipped/W2" > "$HERE/s26_bool.txt" 2>&1
mv "$HERE/s26_simpbool/s2_reference_impl_vs_simp.csv" "$HERE/s26_curves.csv"
./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s27_simpbool_margin" --threads 3 \
    --certify-field "$HERE/simpbool/G2_vm_f1" --certify-field "$HERE/simpbool/A424_vm_f1" \
    --certify-field "$HERE/simpbool/W2_vm_f1" \
    --certify-field "$HERE/sources/simp/rung_0.68" > "$HERE/s27_simpbool_margin.log" 2>&1
echo FROZEN_BOOLEAN_DONE

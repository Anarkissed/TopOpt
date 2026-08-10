#!/bin/sh
# ★ THE eta PROBE — ONE FIXED DESIGN, FOUR BAND WIDTHS.
#
# eta has been held at 2 voxels through this whole line of work and never swept.
# It matters here for two reasons that are worth separating:
#
#  (1) ★ THE PERIMETER FUNCTIONAL CONTAINS IT. Per = ∫ DH_eta(phi)|grad phi| dΩ,
#      so S3's weight sweep is conditional on eta = 2. Answering THAT needs
#      optimiser runs and is out of budget here; the scope limit is stated in
#      the handoff §3 instead.
#
#  (2) ★ THE TRIANGLE CLASSIFICATION MAY MOVE WITH IT, AT FIXED GEOMETRY. If a
#      wider band demotes triangles from CAD to CUT without the shape changing,
#      then part of the "carved share" this task is chasing is a measurement
#      artefact rather than extra structure. THAT is answerable with no
#      optimiser at all: take ONE design's coefficients and emit it at several
#      eta. The geometry is identical by construction — only the band moves.
#
# ★ AND `n_cad` IS REPORTED BESIDE `n_cut` ON EVERY ROW, because
# `output.project_cad_faces` makes a CAD-ATTRIBUTED vertex exact on its face:
# eta cannot defeat projection, but it CAN starve it by demoting vertices out of
# the population that gets projected. Flat n_cad with moving eta means the
# classification is not the story; moving n_cad means it is.
#
# ★ THE VOLUME IS HELD BY CONSTRUCTION. The volume match counts #{phi_eff < 0},
# which does not involve eta, so all four rows enclose the same voxel count and
# the only thing that differs between them is the band.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
A="${ETA_ARM:-RB1_volcount}"
FACES=16,18,20,1,4,19,21,22,25,26,27,32,41,42,43,44,45,46,47,49,75,76,24,31

mkdir -p "$HERE/eta"
set --
for E in 0.5 1 2 4; do
  D="$HERE/eta/e$E"
  if [ ! -f "$D/ALPHA_vm_f2.f64" ]; then
    ./build/plsm_probe "$HERE/arms/$A/plsm_f1" "$D" --threads 2 \
        --emit-factor 2 --eta "$E" --alpha "$HERE/arms/$A/alpha" \
        --frozen-cad "$STEP" --frozen-faces "$FACES" --frozen-depth 3 \
        > "$HERE/eta/e$E.txt" 2>&1
  fi
  set -- "$@" "eta$E=$D/ALPHA_vm_f2"
done
mkdir -p "$HERE/eta/m"
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/eta/m" "$@" \
    > "$HERE/eta_probe.txt" 2>&1
cp "$HERE/eta/m/s2_reference_impl_vs_simp.csv" "$HERE/eta_probe.csv"
echo "ETA_PROBE_DONE -> eta_probe.csv"

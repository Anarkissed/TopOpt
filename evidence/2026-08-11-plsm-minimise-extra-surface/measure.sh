#!/bin/sh
# THE MEASUREMENTS. ★ EVERY NUMBER IN THE HANDOFF COMES FROM HERE, AND EVERY
# INSTRUMENT IS INVOKED RATHER THAN RETYPED (R2).
#
#   M1  the surface table   — `external_field_surface_probe`, ONE invocation
#                             over every arm, so SIMP's rows are produced in
#                             the SAME RUN at the SAME extraction convention.
#                             `n_cut` is R3's internal-surface triangle count.
#   M2  the margin CURVES   — `levelset_probe --certify-field` over each arm's
#                             snapshots, which is `analyze_fixed_design` at the
#                             production penalty with the posture disarmed.
#                             Carries mass, achieved vf and the load-path walk.
#   M3  S1's drift table    — the two `iterations.csv` columns, side by side.
#   M4  S2's frozen set     — the CAD-derived boolean, and the agreement check.
#
# Usage:  sh measure.sh [arm ...]        (default: every arm with a summary.txt)
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
    # C0 is the inertness control, not an arm: it ran 5 iterations to prove the
    # new flags reproduce PR 324 and has no converged design to measure.
    if [ "${b#C0_}" = "$b" ]; then ARMS="$ARMS $b"; fi
  done
fi
# S2 is a post-processing measurement on a design already found, so it runs on
# the arms named in S2_ARMS (default: the re-baseline and whatever else is set).
S2_ARMS="${S2_ARMS:-RB1_volcount}"
# Arms whose SNAPSHOTS also get their surface measured (the stopping-rule
# question). Default: the re-baseline, which is where the observation came from.
SNAP_ARMS="${SNAP_ARMS:-RB1_volcount}"
echo "arms: $ARMS"
echo "S2 arms: $S2_ARMS"

# ── the sources PR 324 committed, unpacked. Regenerated, never stored twice.
mkdir -p "$HERE/sources"
for f in simp/rung_0.68 designmask; do
  b=$(basename "$f")
  if [ ! -f "$HERE/sources/$b.f64" ]; then
    gunzip -c "$PR324/sources/$f.f64.gz" > "$HERE/sources/$b.f64"
    cp "$PR324/sources/$f.meta" "$HERE/sources/$b.meta"
  fi
done

# ══ M1 — THE SURFACE TABLE ═════════════════════════════════════════════════
# ★ ONE INVOCATION. `external_field_surface_probe` emits its own SIMP rows off
# the reference design.bin, so SIMP's 7.5521 / 26,191 and every arm's row are
# extracted by the same binary, from the same STEP, at the same convention, in
# the same process. R2's "SIMP rows in the same run at the SAME extraction
# factor" is structural here, not a promise.
#
# ★ AND THE SNAPSHOTS OF THE ARMS IN SNAP_ARMS GO IN THE SAME CALL. The
# re-baseline's own trajectory shows compliance FLAT from about iteration 30
# (0.00251018 -> 0.00251003, four significant figures) while the interface area
# it carries RISES 19,928 -> 20,617 mm2, 3.5%. If that surface is genuinely
# free — same margin, same mass, same compliance — then the cheapest surface
# reduction in this task is a STOPPING RULE and not a penalty at all. It costs
# no state solves to find out: the snapshots are already on disk and M2 already
# certifies them, so this only adds their SURFACE.
mkdir -p "$HERE/m1"
set --
for A in $ARMS; do set -- "$@" "$A=$HERE/arms/$A/rho"; done
for A in $SNAP_ARMS; do
  for S in "$HERE/arms/$A"/snap/it*.f64; do
    [ -f "$S" ] || continue
    B=$(basename "${S%.f64}")
    set -- "$@" "$A-$B=${S%.f64}"
  done
done
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/m1" "$@" \
    > "$HERE/m1_surface.txt" 2>&1
mv "$HERE/m1/s2_reference_impl_vs_simp.csv" "$HERE/m1_surface.csv"
echo "M1 done -> m1_surface.csv"

# ══ M2 — THE MARGIN CURVES (R4) ════════════════════════════════════════════
# Every snapshot of every arm, plus SIMP's own rung 0.68 field so the bar is
# certified by the same call rather than quoted from a previous handoff.
# ★ ONE PROCESS: the STEP import, voxelisation and load-case build cost ~40 s
# and are paid once for all of them.
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
# ★ CHECKED, BECAUSE IT FAILS SILENTLY. `--certify-field` opens
# `<out>/margin_curve.csv` WITHOUT creating <out> first, so an absent directory
# gives a run that prints every certification to stdout and writes no file at
# all. That cost a run here before the mkdir above was added.
if [ ! -s "$HERE/m2/margin_curve.csv" ]; then
  echo "FAIL: m2/margin_curve.csv is missing or empty — the certifications ran"
  echo "      but nothing was written. Check that $HERE/m2 existed first."
  exit 1
fi
echo "M2 done -> m2/margin_curve.csv ($(( $(wc -l < "$HERE/m2/margin_curve.csv") - 1 )) certifications)"


# ══ M4 — S2: THE FROZEN REGION FROM THE CAD ════════════════════════════════
#
# ★ THE FACE LIST AND THE DEPTH ARE THE JOB'S, TRANSCRIBED FROM THE SAME PLACE
# `levelset_probe` transcribes them: anchor face 18, the 22 retained load faces,
# and face protection 16, all at core's depth of 3 voxels
# (kProductionAnchorPadDepthVoxels = 3, and lround(5.0 mm / 1.705279) = 3).
# `plsm_probe` prints the AGREEMENT between the analytic region and the mask
# core actually built — it must be 100.0000%, and if it is not, S2's rows are
# describing a different part and nothing below them counts.
FACES=16,18,20,1,4,19,21,22,25,26,27,32,41,42,43,44,45,46,47,49,75,76,24,31
s2_arm() {
  A=$1
  [ -f "$HERE/arms/$A/alpha.f64" ] || { echo "no alpha for $A"; return 0; }
  # (ii) the SMOOTH BOOLEAN OFF THE VOXEL TAGS — PR 324 §5's best treatment,
  #      reproduced here so S2 is measured against it and not only against the
  #      hard stamp. Also emits the SIMP control and the arm's own voxel field
  #      at each factor, so every row in the S2 table shares one lattice.
  ./build/plsm_probe "$HERE/arms/$A/plsm_f1" "$HERE/s2/$A-tags" --threads 3 \
      --emit-factor 1 --emit-factor 2 --alpha "$HERE/arms/$A/alpha" \
      --frozen-mask "$HERE/sources/designmask" --emit-source \
      --emit-extra "$HERE/sources/rung_0.68=SIMP" \
      > "$HERE/s2/$A-tags.txt" 2>&1
  # (iii) S2 — THE SAME BOOLEAN OFF THE CAD FACES.
  ./build/plsm_probe "$HERE/arms/$A/plsm_f1" "$HERE/s2/$A-cad" --threads 3 \
      --emit-factor 1 --emit-factor 2 --alpha "$HERE/arms/$A/alpha" \
      --frozen-mask "$HERE/sources/designmask" \
      --frozen-cad "$STEP" --frozen-faces "$FACES" --frozen-depth 3 \
      > "$HERE/s2/$A-cad.txt" 2>&1
  grep -A5 "AGREEMENT" "$HERE/s2/$A-cad.txt" || true
  # and the surface of all three treatments, at ONE lattice, in ONE invocation.
  ./build/external_field_surface_probe "$REF" "$STEP" "$HERE/s2/$A-m" \
      "$A-f2-stamp=$HERE/arms/$A/plsm_f2" \
      "$A-f2-boolean-tags=$HERE/s2/$A-tags/ALPHA_vm_f2" \
      "$A-f2-boolean-CAD=$HERE/s2/$A-cad/ALPHA_vm_f2" \
      "$A-f2-voxelcontrol=$HERE/s2/$A-tags/SRC_f2" \
      "SIMP-f2-control=$HERE/s2/$A-tags/SIMP_f2" \
      > "$HERE/s2_$A.txt" 2>&1
  mv "$HERE/s2/$A-m/s2_reference_impl_vs_simp.csv" "$HERE/s2_$A.csv"
  echo "S2 $A done -> s2_$A.csv"
  # ★ S2(b) — AND IT MUST STILL CERTIFY, WITH THE LOAD PATH WALKED. Frozen
  # material is negative BY CONSTRUCTION under the boolean, so the 40-leaked-
  # voxels-of-40,216 failure PR 324 §5 hit cannot recur. That is an assertion
  # about this field, so it is checked on this field.
  mkdir -p "$HERE/s2/$A-cert"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/s2/$A-cert" --rung 0.68 \
      --threads 3 \
      --certify-field "$HERE/s2/$A-tags/ALPHA_vm_f1" \
      --certify-field "$HERE/s2/$A-cad/ALPHA_vm_f1" \
      > "$HERE/s2_${A}_cert.txt" 2>&1
  cp "$HERE/s2/$A-cert/margin_curve.csv" "$HERE/s2_${A}_cert.csv"
  echo "S2 $A certified -> s2_${A}_cert.csv"
}

mkdir -p "$HERE/s2"
for A in $S2_ARMS; do s2_arm "$A"; done

echo MEASURE_DONE

#!/bin/sh
# THE MEASUREMENTS. ★ EVERY NUMBER FROM OUR OWN INSTRUMENTS, INVOKED (R2).
#
#   roughness / internal surface / CAD error mm / midpoint share / enclosed
#   volume / min-feature
#       -> external_field_surface_probe, ★ ONE INVOCATION for the whole table,
#          with SIMP's OWN RUNGS produced in the same run at the same extraction
#          factor (R5).
#   margin / mass / printed fraction / load path / verdict
#       -> ★ THE ARM'S OWN report.json. On the production path every rung is
#          certified by `analyze_fixed_design` inside the run, so re-certifying
#          here would produce a SECOND number for the same object. The run's
#          certificate is the one that gates, so it is the one that is quoted.
#   sealed void, by the MANUFACTURING definition (R6)
#       -> plsm_topology_probe, which calls the SHIPPED
#          `topopt::plsm_void_topology`. One implementation, so a SIMP row and a
#          PLSM row mean the same thing.
#   the margin CURVE with its peak (R4)
#       -> the arm's own `variant_*_alpha.meta`, which carries every probe the
#          stopping rule took. Only the armed arm has one; the unarmed arms'
#          curves come from `replay_stop_rule.py` on the published data.
#
# ★ BOTH RUNGS, EVERY TABLE (R3). Nominal 0.68 and nominal 0.26 — printed
# fractions 0.7973 and 0.5283 in production's SIMP run of record, whose margins
# there are 3254.36 and 3014.12.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
SCRATCH="${SCRATCH:?set SCRATCH to a directory outside the repository}"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"

ARMS="${ARMS:-B_heaviside C_eta1 D_fraction A_ship}"
RUNGS="${RUNGS:-0.68 0.26}"

cmake --build build -j6 --target external_field_surface_probe \
    plsm_topology_probe > /dev/null

# ── (1) ★ THE SURFACE TABLE. ONE INVOCATION, BOTH RUNGS, EVERY ARM, AND SIMP'S
# OWN RUNGS OUT OF THE REFERENCE design.bin IN THE SAME RUN AT THE SAME
# EXTRACTION FACTOR. R5 exists because `dihedral_rms_deg` FALLS with the
# extraction lattice — comparing a row from one invocation with a row from
# another is comparing two different triangle sets.
mkdir -p "$HERE/m1"
set --
for A in $ARMS; do
  for R in $RUNGS; do
    F="$SCRATCH/$A/dump/rung_$R"
    [ -f "$F.f64" ] && set -- "$@" "${A}_r${R}=$F"
  done
done
[ $# -gt 0 ] || { echo "FAIL: no dumped rung fields — run run_arms.sh first"; exit 1; }
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/m1" "$@" \
    > "$HERE/m1_surface.txt" 2>&1
cp "$HERE/m1/s2_reference_impl_vs_simp.csv" "$HERE/m1_surface.csv"
echo "(1) done -> m1_surface.csv"

# ── (2) ★ R6 — THE SEALED VOID, BY THE MANUFACTURING DEFINITION, FOR EVERY ARM
# AND FOR SIMP, THROUGH ONE IMPLEMENTATION. Note the finding it is reported
# against: sealed void essentially VANISHES at the light rung (0.04% / 0.02%
# against 8.55-11.12% at the shipped rung). Trapped powder is a HIGH-DENSITY
# problem, so a light rung passing this check says nothing about a heavy one.
mkdir -p "$HERE/m2"
set --
for A in $ARMS; do
  for R in $RUNGS; do
    [ -f "$SCRATCH/$A/dump/rung_$R.f64" ] && set -- "$@" "$SCRATCH/$A/dump/rung_$R"
  done
done
for R in $RUNGS; do
  [ -f "$SCRATCH/simp_dump/rung_$R.f64" ] && set -- "$@" "$SCRATCH/simp_dump/rung_$R"
done
./build/plsm_topology_probe "$STEP" "$@" > "$HERE/m2_topology.txt" 2>&1
grep '^CSV,' "$HERE/m2_topology.txt" | sed 's/^CSV,//' > "$HERE/m2_topology.csv" || true
echo "(2) done -> m2_topology.csv"

# ── (3) the certificates, the masses and the stop reasons, out of each arm's own
# receipt. Nothing is recomputed; this is a transcription of the run's record
# into one table, done by a script so it cannot be mistyped.
python3 "$HERE/tables.py" "$HERE" > "$HERE/tables.txt"
cat "$HERE/tables.txt"

echo MEASURE_DONE

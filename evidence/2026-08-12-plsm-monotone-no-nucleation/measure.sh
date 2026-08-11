#!/bin/sh
# THE MEASUREMENTS. R2 — every instrument INVOKED, never retyped.
#
#   M0  ★ THE MATCHED ITERATION IS COMPUTED, NOT CHOSEN. Twice now I have
#       published a comparison table with arms read at different iterations
#       (PR 326 §2, and plsm-restriction-operator, where it flipped a verdict).
#       Both times the cause was a hardcoded number that some arm never reached.
#       This script takes the HIGHEST snapshot index present in EVERY arm and
#       prints it. If arms disagree, the table is built at their intersection.
#   M1  the surface table at that iteration, one invocation, SIMP in the same
#       run at the same extraction factor.
#   M2  the margin curves via --certify-field on every snapshot.
#   M3  ★ the topology curves — components, Euler characteristic, cavities,
#       tunnels, genuinely-new components and split delta, per iteration, per
#       arm. This is the task's headline and it comes straight from
#       iterations.csv, which every arm now writes whether or not --monotone
#       is set.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
PR324="$REPO/evidence/2026-08-10-parametric-level-set"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"

ARMS="$*"
if [ -z "$ARMS" ]; then
  ARMS=""
  for s in "$HERE"/arms/*/summary.txt; do
    [ -f "$s" ] || continue
    ARMS="$ARMS $(basename "$(dirname "$s")")"
  done
fi
[ -n "$ARMS" ] || { echo "FATAL: no finished arm has a summary.txt"; exit 1; }
echo "arms: $ARMS"

# ── M0 — the matched iteration, computed.
MATCH=""
for IT in 60 50 40 30 20 10; do
  ok=1
  for A in $ARMS; do
    [ -f "$HERE/arms/$A/snap/it00$IT.f64" ] || ok=0
  done
  [ $ok -eq 1 ] && { MATCH=$IT; break; }
done
[ -n "$MATCH" ] || { echo "FATAL: no snapshot index is present in every arm"; exit 1; }
echo "★ matched iteration (computed, present in EVERY arm): $MATCH"
echo "$MATCH" > "$HERE/matched_iteration.txt"
for A in $ARMS; do
  echo "   $A: snapshots $(ls "$HERE/arms/$A/snap"/it*.f64 2>/dev/null | wc -l | tr -d ' ')"
done

mkdir -p "$HERE/sources"
for f in simp/rung_0.68 designmask; do
  b=$(basename "$f")
  [ -f "$HERE/sources/$b.f64" ] || {
    gunzip -c "$PR324/sources/$f.f64.gz" > "$HERE/sources/$b.f64"
    cp "$PR324/sources/$f.meta" "$HERE/sources/$b.meta"; }
done

# ── M1 — the surface table at the matched iteration.
mkdir -p "$HERE/m1"
set --
for A in $ARMS; do set -- "$@" "$A=$HERE/arms/$A/snap/it00$MATCH"; done
./build/external_field_surface_probe "$REF" "$STEP" "$HERE/m1" "$@" \
    > "$HERE/m1_surface.txt" 2>&1
cp "$HERE/m1/s2_reference_impl_vs_simp.csv" "$HERE/m1_matched.csv"
echo "M1 done -> m1_matched.csv (iteration $MATCH)"

# ── M2 — the margin curves. mkdir FIRST: --certify-field opens
# <out>/margin_curve.csv WITHOUT creating <out> and fails silently if absent.
mkdir -p "$HERE/m2"
set --
for A in $ARMS; do
  for s in "$HERE/arms/$A"/snap/it*.f64; do
    [ -f "$s" ] && set -- "$@" "${s%.f64}"
  done
done
set -- "$@" "$HERE/sources/rung_0.68"
./build/levelset_probe "$STEP" "$REPO/core/src/materials/materials.json" "$REF" \
    "$HERE/m2" --certify-field "$@" > "$HERE/m2_margin.txt" 2>&1
[ -s "$HERE/m2/margin_curve.csv" ] || { echo "FATAL: margin_curve.csv empty"; exit 1; }
echo "M2 done -> m2/margin_curve.csv ($(( $(wc -l < "$HERE/m2/margin_curve.csv") - 1 )) certifications)"

# ── M3 — the topology curves.
python3 "$HERE/topology_tables.py" $ARMS > "$HERE/m3_topology.txt"
echo "M3 done -> m3_topology.txt"
echo "MEASURE_DONE"

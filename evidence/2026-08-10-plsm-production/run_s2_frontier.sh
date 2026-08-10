#!/bin/sh
# S2 — ★ THE KNOT LATTICE IS THE FEATURE-SCALE CONTROL. THE FRONTIER, AND THE
# POINT ON IT THAT SHIPS.
#
# PR 324's from-scratch arm came out ROUGHER than SIMP on the CARVED surfaces
# (12.51 deg against 7.55) and its §6 refuted two explanations: it is not the
# voxelised frozen faces (the CAD population reads 7.81 against SIMP's 7.58 —
# essentially identical, so ALL the excess is in the carved surfaces), and it is
# not "give it fewer coefficients" measured as a one-off (24,480 instead of
# 85,680 moved the carved share 42.9% -> 40.9% and HALVED the margin).
#
# ★ ITS phi IS ALREADY ANALYTIC, so its roughness is NOT representational — it is
# DESIGN roughness, the same fine-structure growth PR 323 diagnosed when alpha was
# sized 5x too small. IN A PARAMETRIC LEVEL SET THE ANALOGUE OF alpha IS THE KNOT
# SPACING: the basis bandwidth IS the feature-scale control, a coarser lattice
# CANNOT represent fine structure by construction, and unlike alpha it is
# STRUCTURAL rather than a regularisation parameter.
#
# ★ THIS IS MEASURED ON THE PRODUCTION PATH, NOT ON THE PROBE, AND THE REASON IS
# THE MASS COLUMN. PR 324's probe targets `rung x part_solid` over every non-Empty
# voxel; `simp_optimize`'s mask-aware overload — and therefore the shipped ladder —
# targets `volume_fraction x n_active` with the frozen solid OUTSIDE the budget.
# On his job those are 75,281 and 88,424 printed voxels at the same nominal rung
# 0.68 — 462.9 g and 543.6 g, the two masses PR 324's section 0 put side by side. So the probe's arms and SIMP's rungs were never at the same mass, and a
# frontier measured there could not be read against the 543.7 g bar. The
# production path uses simp's convention, so a rung means the same thing on both.
#
# ★ FOUR LATTICES, PER AXIS, AND NONE OF THEM DERIVED FROM A MINIMUM (R4).
#
#   K2    2, 2, 2   85,680 coefficients  — PR 324's Arm 2, and the production rule
#   K424  4, 2, 4   24,480               — PR 324's B2_scratch_coarse; per-axis,
#                                          finer on the THIN axis, which is the
#                                          shape a slab wants and the shape a
#                                          minimum(el_size) rule can never produce
#   K4    4, 4, 4   14,688               — the one "between" the task asks for
#   K8    8, 8, 8    3,040               — the coarsest that still fits
#
# Every run is identical in EVERY other respect: same job document, same seed,
# same iteration cap, same solver posture, three threads. Only the knot spacing
# moves.
#
# ★ THE FULL LADDER, AND AN ITERATION CAP, BOTH STATED. A loadcase job may not
# carry a `margin_stop` key — the schema refuses it, because in loadcase mode the
# production ladder and margin apply — so there is no way to ask for one rung.
# Each arm therefore walks all four rungs, and `plsm.max_iterations` is capped at
# $ITERS (default 40) so four arms fit. PR 324's from-scratch arm ran 60, so rung
# 0.68 here is NOT fully converged and the frontier is read as a comparison
# BETWEEN arms at an identical budget rather than as four converged designs.
# Raise ITERS to close that; it costs about 30 s per iteration per arm.
#
# Every number below is read from `design.bin` — which carries every evaluated
# rung — via `design_rung_dump` and then `external_field_surface_probe`. Both are
# INVOKED, not retyped (R2), and the surface probe emits SIMP's own four rungs
# from the reference design.bin in the same run at the same extraction factor.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
SCRATCH="${SCRATCH:?set SCRATCH to a directory outside the repository}"
ITERS="${ITERS:-40}"
cd "$REPO"

STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"
OUT="$HERE/s2_frontier"
mkdir -p "$OUT" "$SCRATCH/s2jobs"
cp "$STEP" "$SCRATCH/s2jobs/"

cmake --build build -j6 --target topopt-cli design_rung_dump \
    external_field_surface_probe > /dev/null

python3 - "$BAKE/job_simp.json" "$SCRATCH/s2jobs" "$ITERS" <<'PY'
import json, sys
src, dst, iters = sys.argv[1], sys.argv[2], int(sys.argv[3])
base = json.load(open(src))
# ★ THREE NUMBERS PER LATTICE. The schema offers no scalar form.
arms = {"K2": [2, 2, 2], "K424": [4, 2, 4], "K4": [4, 4, 4], "K8": [8, 8, 8]}
for name, knots in arms.items():
    j = dict(base)
    j["plsm"] = {"enabled": True, "basis": "gaussian", "knots": knots,
                 "support": 2, "seed": "holes", "max_iterations": iters,
                 "refit_every": 5}
    json.dump(j, open(f"{dst}/plsm_{name}.json", "w"), indent=1)
print("wrote", len(arms), "job documents at", iters, "iterations")
PY

ARMS="K2 K424 K4 K8"
for arm in $ARMS; do
  rm -rf "$SCRATCH/s2_$arm"
  ./build/topopt-cli run "$SCRATCH/s2jobs/plsm_$arm.json" \
      --out "$SCRATCH/s2_$arm" --materials "$MATS" --threads 3 \
      > "$OUT/$arm.log" 2>&1 || echo "$arm exited nonzero (see the log)"
  cp "$SCRATCH/s2_$arm/iterations.csv" "$OUT/$arm.iterations.csv" 2>/dev/null || true
  cp "$SCRATCH/s2_$arm/run_info.json" "$OUT/$arm.run_info.json" 2>/dev/null || true
  # The design as a field, from the run's own design.bin. `design_rung_dump` is
  # INVOKED; nothing about the format change is retyped here.
  mkdir -p "$SCRATCH/s2_$arm/dump"
  ./build/design_rung_dump "$SCRATCH/s2_$arm/design.bin" "$SCRATCH/s2_$arm/dump" \
      > "$OUT/$arm.dump.txt" 2>&1
  for m in "$SCRATCH/s2_$arm/dump"/rung_*.meta; do
    cp "$m" "$OUT/$arm.$(basename "$m")"
  done
  echo "$arm done"
done

# ── THE SURFACE ROWS, ALL FOUR ARMS AND SIMP, IN ONE INVOCATION ────────────
# One call, so every row is extracted at the SAME factor by the SAME binary and
# SIMP's four rungs come out of the reference design.bin beside them. R2.
set -- "$REF" "$STEP" "$OUT/surface"
for arm in $ARMS; do
  set -- "$@" "$arm=$SCRATCH/s2_$arm/dump/rung_0.68"
done
./build/external_field_surface_probe "$@" > "$OUT/surface.txt" 2>&1
cp "$OUT/surface/s2_reference_impl_vs_simp.csv" "$OUT/curves.csv"

python3 "$HERE/s2_table.py" "$OUT" > "$OUT/verdict.txt"
cat "$OUT/verdict.txt"

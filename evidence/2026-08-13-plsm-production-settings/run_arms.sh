#!/bin/sh
# THE FOUR ARMS. ★ ONE VARIABLE CHANGES BETWEEN CONSECUTIVE ARMS (R5), AND
# EVERY ARM WALKS THE WHOLE LADDER, SO BOTH RUNGS R3 NAMES COME OUT OF THE SAME
# RUN.
#
# ★★ THIS IS THE PRODUCTION PATH, NOT A PROBE, AND THAT IS THE POINT. PR 327's
# arms ran in `levelset_probe`, whose volume convention targets `rung *
# part_solid` over every non-Empty voxel; the shipped ladder targets
# `volume_fraction * n_active` with the frozen solid OUTSIDE the budget. On his
# job those are 75,281 and 88,424 printed voxels at the SAME nominal rung 0.68.
# So a probe arm and a SIMP rung were never at the same mass, and nothing
# measured there can be read against production's own run of record. Everything
# below is `topopt-cli run` on his captured job.
#
# ★ THE TWO RUNGS R3 NAMES ARE NOMINAL 0.68 AND NOMINAL 0.26. Production's SIMP
# run of record (evidence/2026-08-10-plsm-production/s3_simp/base.report.json)
# reports their PRINTED FRACTIONS as 0.7973 and 0.5283 and their margins as
# 3254.36 and 3014.12. Those are the numbers in the handoff's tables; the rung
# labels are what the job document carries.
#
#   B_heaviside   the PREVIOUS production posture, exactly: H_eta at the cell
#                 centre, eta = 2 voxels, the CONTINUUM compliance weight,
#                 cap 60, no margin probe.
#   C_eta1        + eta = 1.                            ITEM 1, ALONE.
#   D_fraction    + the exact volume fraction (k = 4) and the sensitivity that
#                 matches it.                           ITEM 2, AT A MATCHED
#                                                        60-ITERATION BUDGET.
#   A_ship        + the margin-plateau stop, cadence 10, window 3, cap 120.
#                                                        ITEM 3, AND THE
#                                                        POSTURE THAT SHIPS.
#
# ★ B -> C -> D ARE ALL AT CAP 60 SO THE BUDGET IS NOT A SECOND VARIABLE. Only
# D -> A changes it, and changing it IS item 3.
#
# ★★ THE COMPLIANCE WEIGHT IS ISOLATED BY R2, NOT BY A FIFTH ARM, AND THAT IS
# THE STRONGER ISOLATION. `plsm_frac_fd_probe` differences BOTH weights against
# the SAME two state solves on the SAME design — the continuum one reads +56.0%
# and +45.0% on two random directions, the discrete one −0.31% and +0.97%, flat
# across a factor of ten in step size. An arm would have shown a different
# design; the finite difference shows WHICH GRADIENT IS RIGHT, which is the
# question. `D_fraction` therefore carries the ersatz, the measure and the weight
# together, as item 2 ships them.
#
# ★ 6 THREADS, STRICTLY SERIAL, AND 6 IS PRODUCTION'S OWN NUMBER — his run of
# record reports `matfree_threads: 6`. Serial because two arms sharing a host
# cannot have comparable wall clocks (this Mac's own A/B offset is larger than
# 10%), and item 2(e) asks for the fraction's COST on this path. The designs are
# deterministic and do not depend on the thread count; only the wall clocks do.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
: "${SCRATCH:?set SCRATCH to a directory outside the repository}"
cd "$REPO"

STEP="$BAKE/M2_verticalStand.step"
MATS="core/src/materials/materials.json"
OUT="$HERE/arms"
mkdir -p "$OUT" "$SCRATCH/jobs"
cp "$STEP" "$SCRATCH/jobs/"

cmake --build build -j6 --target topopt-cli design_rung_dump \
    external_field_surface_probe > /dev/null

python3 - "$BAKE/job_simp.json" "$SCRATCH/jobs" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
base = json.load(open(src))
common = {"enabled": True, "basis": "gaussian", "support": 2,
          "seed": "inherit", "refit_every": 5}
arms = {
  # the previous production posture, verbatim
  "B_heaviside": {**common, "ersatz": "heaviside", "sens_weight": "continuum",
                  "eta_voxels": 2.0, "max_iterations": 60,
                  "margin_probe_every": 0},
  # item 1, alone
  "C_eta1":      {**common, "ersatz": "heaviside", "sens_weight": "continuum",
                  "eta_voxels": 1.0, "max_iterations": 60,
                  "margin_probe_every": 0},
  # item 2, at the SAME budget: the ersatz, the measure and the weight
  "D_fraction":  {**common, "ersatz": "fraction", "sens_weight": "discrete",
                  "eta_voxels": 1.0, "frac_samples": 4, "max_iterations": 60,
                  "margin_probe_every": 0},
  # item 3, and the posture that ships
  "A_ship":      {**common, "ersatz": "fraction", "sens_weight": "discrete",
                  "eta_voxels": 1.0, "frac_samples": 4, "max_iterations": 120,
                  "margin_probe_every": 10, "margin_plateau_probes": 3},
}
for name, plsm in arms.items():
    j = dict(base)
    j["plsm"] = plsm
    json.dump(j, open(f"{dst}/plsm_{name}.json", "w"), indent=1)
print("wrote", len(arms), "job documents")
PY

# ★ ORDER: the control FIRST, so a campaign that is interrupted still has the
# thing everything else is measured against.
ARMS="${ARMS:-B_heaviside C_eta1 D_fraction A_ship}"
for arm in $ARMS; do
  if [ -f "$OUT/$arm.run_info.json" ]; then
    echo "$arm already present, skipping"
    continue
  fi
  rm -rf "$SCRATCH/$arm"
  ./build/topopt-cli run "$SCRATCH/jobs/plsm_$arm.json" \
      --out "$SCRATCH/$arm" --materials "$MATS" --threads 6 \
      > "$OUT/$arm.log" 2>&1 || echo "$arm exited nonzero (see the log)"
  for f in iterations.csv run_info.json report.json; do
    cp "$SCRATCH/$arm/$f" "$OUT/$arm.$f" 2>/dev/null || true
  done
  # The analytic sidecars carry the per-rung stop reason, the margin-probe CURVE
  # and the topology counters. Copied, not retyped.
  for m in "$SCRATCH/$arm"/variant_*_alpha.meta; do
    [ -f "$m" ] && cp "$m" "$OUT/$arm.$(basename "$m")"
  done
  # The design as a field, from the run's own design.bin — every evaluated rung.
  mkdir -p "$SCRATCH/$arm/dump"
  ./build/design_rung_dump "$SCRATCH/$arm/design.bin" "$SCRATCH/$arm/dump" \
      > "$OUT/$arm.dump.txt" 2>&1 || true
  echo "$arm done: $(date '+%H:%M:%S')"
done

echo ARMS_DONE

#!/bin/sh
# S4 — ★ IT MUST STILL LATTICE. His whole goal is TO PLUS LATTICE; a smoother,
# lighter part he cannot lattice is not the thing he asked for.
#
# ★ THE SAME JOB DOCUMENT ON BOTH SIDES, DIFFERING ONLY IN WHICH design.bin IT
# NAMES. `lattice-variant` restores a finished variant, RE-CERTIFIES it (and
# REFUSES unless the run's recorded margin reproduces inside the band —
# run_job.cpp's margin_reproduces gate), grades it from its OWN recovered stress
# field, emits the latticed mesh and certifies the composite. So this measures
# whether the grading law, the boundary rule, the cells-per-member floor and the
# sub-floor predicate behave the same on a parametric field as on a SIMP one —
# and if any of them does not, the refusal names it.
#
# The lattice + grading blocks are HIS, lifted verbatim from
# evidence/2026-08-07-lattice-recipe-not-triangles/job_his_2mm_skinnone.json, so
# this is the recipe he actually runs and not one invented for the comparison.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
RECIPE="$REPO/evidence/2026-08-07-lattice-recipe-not-triangles/job_his_2mm_skinnone.json"
SCRATCH="${SCRATCH:?set SCRATCH to a directory outside the repository}"
PLSM_RUN="${PLSM_RUN:?set PLSM_RUN to the PLSM run directory holding design.bin}"
cd "$REPO"

MATS="core/src/materials/materials.json"
OUT="$HERE/s4_lattice"
mkdir -p "$OUT" "$SCRATCH/s4jobs"
cp "$BAKE/M2_verticalStand.step" "$SCRATCH/s4jobs/"

python3 - "$RECIPE" "$SCRATCH/s4jobs" "$PLSM_RUN/design.bin" \
         "$BAKE/s2_simp_baseline/design.bin" <<'PY'
import json, sys
recipe, dst, plsm_design, simp_design = sys.argv[1:5]
r = json.load(open(recipe))
for name, design in (("plsm", plsm_design), ("simp", simp_design)):
    j = {
        "model": "M2_verticalStand.step",
        "material": r["material"],
        "mode": "lattice_variant",
        "resolution": r["resolution"],
        "output": {"report": "report.json", "mesh_format": "stl",
                   "mesh_prefix": "variant"},
        # HIS lattice and grading blocks, verbatim.
        "lattice": r["lattice"],
        "grading": r["grading"],
        "loads": r["loads"],
        # Rung 0.68 by its REQUESTED fraction, so the two sides name the same
        # rung by the same key and neither can silently pick a different one.
        "variant": {"design": design, "volume_fraction": 0.68},
    }
    json.dump(j, open(f"{dst}/lat_{name}.json", "w"), indent=1)
print("wrote 2 lattice_variant job documents")
PY

for side in plsm simp; do
  rm -rf "$SCRATCH/s4_$side"
  ./build/topopt-cli lattice-variant "$SCRATCH/s4jobs/lat_$side.json" \
      --out "$SCRATCH/s4_$side" --materials "$MATS" --threads 3 \
      > "$OUT/$side.log" 2>&1 || echo "$side exited nonzero (see the log)"
  for f in lattice_variant_report.json lattice_variant.json report.json \
           run_info.json loadcase.json; do
    cp "$SCRATCH/s4_$side/$f" "$OUT/$side.$f" 2>/dev/null || true
  done
  cp "$SCRATCH/s4_$side"/variant_*_lattice.report.json \
     "$OUT/$side.lattice.report.json" 2>/dev/null || true
  ls -la "$SCRATCH/s4_$side" > "$OUT/$side.artifacts.txt" 2>&1 || true
  echo "$side done"
done

python3 "$HERE/s4_table.py" "$OUT" > "$OUT/verdict.txt"
cat "$OUT/verdict.txt"

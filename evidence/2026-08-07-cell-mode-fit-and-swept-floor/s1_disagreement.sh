#!/usr/bin/env bash
# S1 — ESTABLISH BEFORE FIXING (bars S1a / S1b / S1d).
#
#   ./s1_disagreement.sh <branch-build-dir> <base-build-dir> <out-dir>
#
# (a) WHICH FUNCTION produced "planned cell 4.931378498 mm" in his refusal?
# (b) Does `plan_cell_sizes` apply the same floor, a different one, or none?
# (d) THE FAILING TEST FIRST: a swept job declaring `cell_min_mm: 1.173` on his
#     geometry — refused today, running after.
#
# The decisive measurement is BYTE EQUALITY of the two refusals: if a declared 1.173 mm
# minimum produced output character-for-character identical to `cell_mode: "auto"`,
# the declared number reached nothing.
set -euo pipefail
BR="$(cd "${1:?usage: s1_disagreement.sh <branch-build> <base-build> <out>}" && pwd)/topopt-cli"
BASE="$(cd "${2:?}" && pwd)/topopt-cli"
mkdir -p "${3:?}"
OUT="$(cd "$3" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MATS="$REPO/core/src/materials/materials.json"
RULES="$REPO/core/src/settings/rules.json"
cp "$REPO/evidence/2026-08-05-smoothing-must-actually-smooth/WallMount_ShelfBracket.stl" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
radii = [1.4142135623730951]*3 + [2.0]*3 + [3.0]*3
regions = [{"role": "include", "kind": "bolt",
            "geometry": {"axis_point": [50.0, -180.0 + 21.0*i, 10.0],
                         "axis_dir": [1.0, 0.0, 0.0],
                         "radius_mm": r, "half_length_mm": 20.0}}
           for i, r in enumerate(radii)]
def job(g):
    return {"model": "WallMount_ShelfBracket.stl", "material": "PLA",
            "mode": "minimize_plastic", "resolution": 64,
            "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.0}],
            "gravity": {"direction": [0.0, 1.0, 0.0], "magnitude_mm_s2": 9810.0},
            "ladder": [0.6], "margin_stop": 0.0, "simp": {"max_iterations": 1},
            "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                        "regions": regions},
            "grading": dict({"topology": "octet",
                             "min_extrudable_width_mm": 0.45}, **g),
            "output": {"report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant"}}
json.dump(job({"cell_mode": "auto"}),
          open(os.path.join(out, "auto.json"), "w"), indent=1)
json.dump(job({"cell_mode": "swept", "cell_min_mm": 1.173, "cell_max_mm": 9.384}),
          open(os.path.join(out, "swept.json"), "w"), indent=1)
PY

run() { # run <cli> <job> <tag>
  set +e
  ( cd "$OUT" && "$1" run "$2" --out "o_$3" --materials "$MATS" --rules "$RULES" \
      > "$3.log" 2>&1 )
  echo $? > "$OUT/$3.rc"
  set -e
  grep -E '^\[lattice\]|^topopt-cli:|^SET |^Why:|^  ' "$OUT/$3.log" > "$OUT/$3.msg" || true
}

echo "=============================================================================="
echo "S1a — WHICH FUNCTION PRODUCED \"planned cell 4.931378498 mm\""
echo "=============================================================================="
cat <<'TXT'
  core/src/cli/run_job.cpp, the PRE-FLIGHT block, on origin/main line 6059:

      else if (pf_mode == CellSizeMode::Swept)
        cell_mm = std::max(job.grading.cell_min_mm, floor_mm);

  where `floor_mm` is lattice_cell_printability_floor_mm(octet, 0.45) = 4.931378498.
  His job was cell_mode "auto", which takes the same `floor_mm` on line 6058 — the
  swept arm one line below reports the identical number for a DIFFERENT reason, and
  that is what this bar is about.

  It is NOT `multiscale_floor_cell_mm` (origin/main run_job.cpp:761-785). That is a
  SECOND COPY of the same switch, carrying the same swept arm on line 773, and it is
  read only when `lattice.multiscale` is armed. Both copies were wrong; only the
  pre-flight one is on his path.

S1b — DOES plan_cell_sizes APPLY THE SAME FLOOR, A DIFFERENT ONE, OR NONE?

  NONE.  core/src/simp/cell_plan.cpp:

      P.base_cell_mm = params.min_cell_size_mm;          // verbatim, no max(), no floor

  and grading.cpp passes the job's `cell_min_mm` straight through
  (run_job.cpp: `gp.min_cell_size_mm = job.grading.cell_min_mm`). The only
  printability rule the planner applies is PER BASE CELL — `need[c]`, the smallest
  dyadic level whose strut at THAT cell's own rho still prints — and a cell whose
  `need` exceeds its `cap` is dropped to solid.

  SO THE PRE-FLIGHT AND THE PLANNER ALREADY DISAGREED, and by a factor of 4.2 on his
  numbers: forecast 4.9314 mm, plan 1.173 mm. That is the defect; the one-line change
  was not the fix. Both now read `cell_plan_finest_printable_cell_mm`, which IS the
  planner's ladder — the first rung at or above w/phi(rho_max).
TXT
echo
echo "=============================================================================="
echo "S1d — THE FAILING TEST FIRST, on the UNFIXED binary"
echo "=============================================================================="
run "$BASE" auto.json  base_auto
run "$BASE" swept.json base_swept
echo "  base, cell_mode auto            : exit $(cat "$OUT/base_auto.rc")"
echo "  base, cell_mode swept @1.173 mm : exit $(cat "$OUT/base_swept.rc")"
a=$(shasum -a 256 "$OUT/base_auto.msg"  | cut -d' ' -f1)
b=$(shasum -a 256 "$OUT/base_swept.msg" | cut -d' ' -f1)
echo "  sha256 of the auto  message: $a"
echo "  sha256 of the swept message: $b"
if [ "$a" = "$b" ]; then
  echo "  ★ IDENTICAL. Declaring cell_min_mm 1.173 changed NOT ONE CHARACTER of the"
  echo "    refusal: the number was raised to 4.931378498 mm and discarded."
else
  echo "  the two messages differ — re-check the fixture before reading anything else"
fi
echo
echo "  the refusal he would have seen (base, swept):"
sed -n '/^topopt-cli:/,$p' "$OUT/base_swept.log" | sed -n '1,6p' | sed 's/^/    /'
echo
echo "=============================================================================="
echo "S1d — THE SAME TWO JOBS ON THE FIXED BINARY"
echo "=============================================================================="
run "$BR" auto.json  br_auto
run "$BR" swept.json br_swept
echo "  branch, cell_mode auto            : exit $(cat "$OUT/br_auto.rc")  (still refuses — auto IS the light floor, deliberately)"
echo "  branch, cell_mode swept @1.173 mm : exit $(cat "$OUT/br_swept.rc")  (RUNS)"
a2=$(shasum -a 256 "$OUT/br_auto.msg"  | cut -d' ' -f1)
b2=$(shasum -a 256 "$OUT/br_swept.msg" | cut -d' ' -f1)
echo "  sha256 of the auto  message: $a2"
echo "  sha256 of the swept message: $b2"
[ "$a2" != "$b2" ] && echo "  ★ they now DIFFER — the declared minimum reaches the forecast."
echo
echo "  what the swept job now says:"
sed -n '1,8p' "$OUT/br_swept.msg" | sed 's/^/    /'

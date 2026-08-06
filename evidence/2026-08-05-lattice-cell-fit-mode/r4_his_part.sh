#!/usr/bin/env bash
# R4 — HIS OWN PART, END TO END, ALL FOUR RUNGS.
#
#   ./r4_his_part.sh <branch-build-dir> <out-dir> [resolution]
#
# WallMount_ShelfBracket.stl — the part from his overnight run — with SEVEN include
# regions, each 4 mm across its thinnest dimension, over his own ladder. Run twice:
# `auto` (what he has) and `fit`.
#
# ★ THE STATED WIDTH IS 0.42 mm AND THAT IS DELIBERATE: it is
# PrintParams.wallLineWidthOuterMM — his OUTER extrusion bead — which is the field the
# app sends as `min_extrudable_width_mm` at every call site (LatticePage.swift:140,180;
# AppModel.swift:269; WorkspacePlaceholder.swift:1974). It is NOT a nozzle bore: see
# PrintParams.swift:44-46. His INNER bead (`wall_line_width_mm`) is 0.45 and is NOT what
# this key receives. The sensitivity to that choice is measured at both widths in
# q1_width_provenance.md and r2_flip_probe.txt.
#
# ★ DEFAULT RESOLUTION IS 128 — his. At 64 the voxel is ~3.24 mm and a 4 mm wall spans
# ~1.2 voxels, so the instrument cannot tell a 4 mm wall from a 7 mm one.
#
# The per-region table this prints is the R4 deliverable: measured thinnest extent,
# derived cell, derived density, strut diameter, cells per member, cells emitted, and
# which floor was in force.
set -euo pipefail
BUILD="$(cd "${1:?usage: r4_his_part.sh <build-dir> <out-dir> [resolution]}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
RES="${3:-128}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cp "$REPO/evidence/2026-08-05-smoothing-must-actually-smooth/WallMount_ShelfBracket.stl" "$OUT/"

python3 - "$OUT" "$RES" <<'PY'
import json, os, sys
out, res = sys.argv[1], int(sys.argv[2])
# Seven 4 mm slabs stacked along the part's long axis, each spanning it in plane —
# the shape of his declared regions (a 4 mm face slab), seven of them, on the real
# part. y from -196.79 to 10.57, so these land on material.
regions = [{"role": "include", "kind": "face",
            "geometry": {"origin": [0.0, -180.0 + 27.0 * i, 10.0],
                         "normal": [0.0, 1.0, 0.0],
                         "half_u_mm": 300.0, "half_w_mm": 300.0,
                         "depth_mm": 4.0}}
           for i in range(7)]
# HIS loads block, verbatim from
# evidence/2026-08-05-smoothing-must-actually-smooth/job.json — including
# "minimize_plastic": false, which selects the GROWTH ladder, and the three bolt
# clearances. Only the lattice/grading blocks and the mode are added.
loads = {"groups": [{"face_ids": [0], "force": [0, -155.6879425048828, 0]}],
         "infill_percent": 35, "wall_loops": 5,
         "anchor_face_ids": [8, 14, 12],
         "wall_line_width_outer_mm": 0.42, "wall_line_width_mm": 0.45,
         "build_dir": [0, 1, 0], "minimize_plastic": False,
         "clearances": [
           {"kind": "bolt",
            "geometry": {"half_length_mm": 3.674999237060547,
                         "radius_mm": 1.9999998101538858,
                         "axis_point": [97.5999984741211, -181.88799512584953,
                                        9.99999999994251],
                         "axis_dir": [1, 0, 0]}},
           {"kind": "bolt", "concentric_margin_mm": 4.75,
            "geometry": {"half_length_mm": 3.674999237060547,
                         "axis_dir": [1, 0, 0],
                         "axis_point": [97.5999984741211, -90.18873513872929,
                                        9.99999999994251],
                         "radius_mm": 1.9999998101538858}},
           {"kind": "bolt", "concentric_margin_mm": 4.75,
            "axial_clearance_mm": 70,
            "geometry": {"axis_point": [52.8434648222632, -82.40121782294213,
                                        10.000000567815748],
                         "half_length_mm": 3.674999237060547,
                         "radius_mm": 1.9999998101538858,
                         "axis_dir": [1, 0, 0]}}]}
design_box = {"min": [-99.92500305175781, -196.7901153564453,
                      -21.721759796142578],
              "max": [101.2750015258789, 10.574999809265137,
                      41.72175979614258]}
def job(mode):
    return {
      "model": "WallMount_ShelfBracket.stl", "material": "PLA",
      "mode": "minimize_plastic", "resolution": res,
      # ★ HIS DESIGN BOX IS OMITTED, and not by choice. run_job.cpp:5665 refuses a
      # "grading" block alongside a "design_box" — a PRE-EXISTING guard (it is in the
      # stack base verbatim), because the cell plan is chosen before the
      # added-material policy runs. So NO graded mode, fit included, is reachable on
      # his job while it carries a box. Reported in the handoff; not fixed here.
      "bake_build_orientation": "off",
      # CAPPED so the run finishes on a shared machine. The cap changes how
      # converged each rung is; it changes nothing about the cell DERIVATION,
      # which is arithmetic on the declared geometry. Stated in the handoff.
      "simp": {"max_iterations": 30},
      "loads": loads,
      "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                  "min_extrudable_width_mm": 0.42, "regions": regions},
      "grading": {"topology": "octet", "cell_mode": mode,
                  "min_extrudable_width_mm": 0.42},
      "output": {"report": "report.json", "mesh_format": "stl",
                 "mesh_prefix": "variant"}
    }
json.dump(job("auto"), open(os.path.join(out, "his_auto.json"), "w"), indent=1)
json.dump(job("fit"),  open(os.path.join(out, "his_fit.json"),  "w"), indent=1)
PY

run() {
  rm -rf "${OUT:?}/$2"
  set +e
  ( cd "$OUT" && /usr/bin/time -p "$BUILD/topopt-cli" run "$1" --out "$2" > "$2.log" 2>&1 )
  echo $?
  set -e
}

echo "=== his part, resolution $RES, four rungs, cell_mode auto ==="
rc=$(run his_auto.json auto); echo "exit code: $rc"
grep -E "FORECAST|refus|planned cell" "$OUT/auto.log" | head -4 || true
echo
echo "=== his part, resolution $RES, four rungs, cell_mode fit ==="
rc=$(run his_fit.json fit); echo "exit code: $rc"
grep -E "^\[lattice\] FIT" "$OUT/fit.log" | head -12 || true
echo
echo "=== R4 TABLE — per region, per rung ==="
python3 - "$OUT" <<'PY'
import glob, json, os, sys
out = sys.argv[1]
for sub in ("auto", "fit"):
    d = os.path.join(out, sub)
    ri = os.path.join(d, "run_info.json")
    print(f"--- {sub} ---")
    if not os.path.exists(ri):
        print("    no run_info.json (the run refused or did not finish); see "
              f"{sub}.log")
        continue
    info = json.load(open(ri))
    g = info.get("grading") or {}
    print(f"    cell_mode {g.get('cell_mode')}  cell_size_mm {g.get('cell_size_mm')}  "
          f"printability_floor {g.get('printability_floor_mm')}")
    print(f"    region_voxels {g.get('region_voxels')}  latticed {g.get('latticed_voxels')}  "
          f"solid_fallback {g.get('solid_fallback_voxels')}")
    fit = g.get("fit")
    if fit:
        print(f"    finest printable cell {fit.get('min_printable_cell_mm')} mm; "
              f"distinct cells emitted {fit.get('distinct_cells')}; "
              f"out-of-regime voxels {fit.get('out_of_regime_voxels')}; "
              f"density raised on {fit.get('density_raised_for_print_voxels')} voxels")
        print("    region | extent mm | cell mm | rho     | strut mm | cells/member | floor in force")
        for r in fit.get("regions", []):
            floor = ("PERCOLATION (accuracy unreachable)" if r["out_of_regime"]
                     else "ACCURACY")
            if not r["feasible"]:
                floor = "NONE — refused, kept solid"
            print("    {:>6} | {:>9.4f} | {:>7.4f} | {:>7.4f} | {:>8.4f} | {:>12.2f} | {}"
                  .format(r["region_index"], r["extent_mm"], r["cell_mm"],
                          r["relative_density"], r["strut_mm"],
                          r["cells_per_member"], floor))
    for f in sorted(glob.glob(os.path.join(d, "*_lattice.report.json"))):
        j = json.load(open(f))
        gen = j.get("generation") or {}
        print(f"    {os.path.basename(f)}: cell_mm={j.get('cell_mm')} "
              f"latticed_cells={gen.get('latticed_cells')} "
              f"triangles={gen.get('triangles')}")
    rep = os.path.join(d, "report.json")
    if os.path.exists(rep):
        R = json.load(open(rep))
        for v in (R.get("variants") or []):
            print("    rung {}: verdict {} margin {} mass {}".format(
                v.get("volume_fraction"), v.get("verdict"),
                v.get("margin"), v.get("mass_g")))
PY

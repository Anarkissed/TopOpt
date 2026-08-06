#!/usr/bin/env bash
# R4 — HIS OWN NINE-REGION CASE, END TO END, AT BOTH SETTINGS.
#
#   ./r4_his_case.sh <branch-build-dir> <out-dir> [resolution]
#
# WallMount_ShelfBracket.stl — his part — with NINE bolt include regions: three at
# 2.828 mm, three at 4.000 mm and three at 6.000 mm across their thinnest dimension.
# Run three ways: `auto` (what he had, which REFUSES), `swept` with his declared
# minimum, and `fit`.
#
# ★ THE STRUT LINE WIDTH IS 0.45 mm and that is his: task
# 2026-08-06-strut-line-width-field made the lattice read max(outer, inner), and his
# job carries wall_line_width_outer_mm 0.42 / wall_line_width_mm 0.45. It is what makes
# the light floor 4.9314 mm and the frontier 1.1732 mm — the two numbers in his refusal.
#
# ★★ TWO DELIBERATE DEVIATIONS FROM HIS CAPTURED JOB, STATED RATHER THAN HIDDEN:
#   1. His `loads` block is replaced by fixture_faces + gravity + a one-rung ladder.
#      The loads path REFUSES `ladder`/`margin_stop` and `simp.max_iterations` does not
#      bind the MMA plateau there, so his own job runs the full production ladder —
#      hours. The lattice law, the regions and the cell derivation are untouched by
#      this; only how many rungs are solved changes.
#   2. `skin` is "none", not his "rim". A rim on a voxel-silhouette part emits zero
#      triangles and PR 302 made that an abort, so "rim" would fail on that rule
#      instead of this task's. (Handoff 2026-08-05-lattice-cell-fit-mode.)
#   3. His `design_box` is dropped: `grading` + `design_box` is refused outright
#      (run_job.cpp), so no graded mode is reachable on his saved job while it carries
#      one. That is a pre-existing gate, filed and unchanged here.
set -euo pipefail
BUILD="$(cd "${1:?usage: r4_his_case.sh <build-dir> <out-dir> [resolution]}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
RES="${3:-128}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$BUILD/topopt-cli"
MATS="$REPO/core/src/materials/materials.json"
RULES="$REPO/core/src/settings/rules.json"
cp "$REPO/evidence/2026-08-05-smoothing-must-actually-smooth/WallMount_ShelfBracket.stl" "$OUT/"

python3 - "$OUT" "$RES" <<'PY'
import json, os, sys
out, res = sys.argv[1], int(sys.argv[2])
radii = [1.4142135623730951]*3 + [2.0]*3 + [3.0]*3
regions = [{"role": "include", "kind": "bolt",
            "geometry": {"axis_point": [50.0, -180.0 + 21.0*i, 10.0],
                         "axis_dir": [1.0, 0.0, 0.0],
                         "radius_mm": r, "half_length_mm": 20.0}}
           for i, r in enumerate(radii)]

def job(grading):
    g = dict({"topology": "octet", "min_extrudable_width_mm": 0.45,
              # The per-region receipt. Decision-free — it changes no mask, cell,
              # density or verdict; it is what lets this table report candidates and
              # latticed voxels per declared region.
              "report_region_cells": True}, **grading)
    return {"model": "WallMount_ShelfBracket.stl", "material": "PLA",
            "mode": "minimize_plastic", "resolution": res,
            "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.0}],
            "gravity": {"direction": [0.0, 1.0, 0.0], "magnitude_mm_s2": 9810.0},
            "ladder": [0.6], "margin_stop": 0.0, "simp": {"max_iterations": 8},
            "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                        "regions": regions},
            "grading": g,
            "output": {"report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant"}}

json.dump(job({"cell_mode": "auto"}),
          open(os.path.join(out, "his_auto.json"), "w"), indent=1)
json.dump(job({"cell_mode": "swept", "cell_min_mm": 1.173, "cell_max_mm": 9.384}),
          open(os.path.join(out, "his_swept.json"), "w"), indent=1)
json.dump(job({"cell_mode": "fit"}),
          open(os.path.join(out, "his_fit.json"), "w"), indent=1)
PY

for tag in auto swept fit; do
  rm -rf "$OUT/run_$tag"
  set +e
  ( cd "$OUT" && "$CLI" run "his_$tag.json" --out "run_$tag" \
      --materials "$MATS" --rules "$RULES" > "$tag.log" 2>&1 )
  echo $? > "$OUT/$tag.rc"
  set -e
done

echo "resolution: $RES"
for tag in auto swept fit; do
  echo
  echo "########################################################################"
  echo "# cell_mode \"$tag\"   exit=$(cat "$OUT/$tag.rc")"
  echo "########################################################################"
  grep -E '^\[lattice\]|^topopt-cli:|^SET |^ARM |^NOTHING |^Why:|^  ' "$OUT/$tag.log" \
    | sed -n '1,40p' || true
  python3 - "$OUT/run_$tag" "$tag" <<'PY'
import json, os, sys
d, tag = sys.argv[1], sys.argv[2]
p = os.path.join(d, "run_info.json")
if not os.path.exists(p):
    print("\n  (no run_info.json — this job was REFUSED before any solve)")
    raise SystemExit
ri = json.load(open(p))
g = ri.get("grading", {})
lx = ri.get("lattice_export", {})
print()
print("  PER REGION")
fit = g.get("fit", {})
rows = fit.get("regions", [])
if rows:
    print("  %-4s %-9s %-9s %-8s %-8s %-7s %-11s %-9s" %
          ("reg", "thinnest", "cell mm", "density", "strut", "cells", "candidates",
           "latticed"))
    for r in rows:
        print("  %-4s %-9.3f %-9.4f %-8.4f %-8.4f %-7.2f %-11d %-9d%s" %
              (r["region_index"], r["extent_mm"], r["cell_mm"],
               r["relative_density"], r["strut_mm"], r["cells_per_member"],
               r.get("candidate_voxels", 0), r.get("latticed_voxels", 0),
               "  OUT OF REGIME" if r.get("out_of_regime") else "  certifiable"))
    print("  printed OUTSIDE every declared region: %d voxels" %
          fit.get("printed_outside_regions", 0))
else:
    # SWEPT/AUTO carry no per-region derivation — the cell is part-wide, so the
    # per-region facts that exist are the receipt's candidate/latticed counts.
    regs = g.get("subfloor", {}).get("regions") or g.get("regions") or []
    print("  (this mode derives ONE part-wide cell; per-region rows below are the")
    print("   receipt's own counts, and the cell/density/strut are the plan's)")
    print("  plan base cell   : %s mm" % g.get("cell_base_mm"))
    print("  plan levels      : %s" % [(l["level"], l["cell_size_mm"], l["cells"])
                                       for l in g.get("cell_levels", [])])
    print("  density band used: %s .. %s" % (g.get("rho_min_used"),
                                             g.get("rho_max_used")))
    print("  strut diameter   : %s .. %s mm" % (g.get("min_strut_diameter_mm"),
                                                g.get("max_strut_diameter_mm")))
    print("  min cells/member : %s" % g.get("min_cells_per_member"))
    if regs:
        print("  %-4s %-11s %-9s %-9s" % ("reg", "candidates", "latticed", "solid"))
        for r in regs:
            print("  %-4s %-11s %-9s %-9s" %
                  (r.get("region_id"), r.get("candidate_voxels"),
                   r.get("retained_voxels", r.get("latticed_voxels", "-")),
                   r.get("below_floor_voxels", "-")))
print()
print("  RUN TOTALS: region_voxels=%s latticed_cells=%s triangles=%s" %
      (lx.get("region_voxels"), lx.get("latticed_cells"), lx.get("triangles")))
print("  forecast: %s of %s regions too thin; required member %s mm; thinnest %s mm" %
      (lx.get("forecast_region_too_thin"), lx.get("forecast_include_regions"),
       lx.get("forecast_required_member_mm"), lx.get("forecast_thinnest_region_mm")))
lat = ri.get("lattice", {})
print("  certificate: margin_worst_case=%s accepted=%s strut_out_of_regime=%s "
      "min_cells_per_member=%s" %
      (lat.get("margin_worst_case"), lat.get("accepted"),
       lat.get("strut_out_of_regime"), lat.get("strut_min_cells_per_member")))
PY
done

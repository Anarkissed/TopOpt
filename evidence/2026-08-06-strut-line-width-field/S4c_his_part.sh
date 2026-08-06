#!/usr/bin/env bash
# S4(c) — HIS OWN PART, AT RESOLUTION 128, AT BOTH STRUT WIDTHS, SIDE BY SIDE.
#
#   ./S4c_his_part.sh <branch-build-dir> <out-dir> [resolution]
#
# WallMount_ShelfBracket.stl with his loads block verbatim and seven include regions
# each 4 mm across their thinnest dimension — the same fixture
# evidence/2026-08-05-lattice-cell-fit-mode/r4_his_part.sh built, so the 0.42 mm
# column here is directly comparable with the table committed there.
#
# ★ WHAT MOVED SINCE THAT RUN. r4_his_part.sh stated 0.42 mm and said so out loud,
# because 0.42 mm was `PrintParams.wallLineWidthOuterMM` — the field the app sent as
# `min_extrudable_width_mm` at every lattice call site. This task gives the strut its
# own field, whose default is max(outer, inner) = 0.45 mm on the shipped profile. So
# the column that describes what his device will now send is the 0.45 mm one, and the
# 0.42 mm column is what it used to send. Both are printed; no figure appears without
# the width it was computed at (bar R3).
#
# ★ THE ANALYZE PATH, NOT THE OPTIMIZE LADDER, and that is a limitation this file
# states rather than hides. `topopt-cli run` on this job cannot be bounded: the job's
# `simp.max_iterations` is parsed and dropped on the loadcase path (root-caused in
# evidence/2026-08-05-lattice-cell-fit-mode/q3c_max_iterations_ignored.md, still true
# at this commit), so the three-rung growth ladder runs to the MMA plateau. The
# per-region DERIVATION — cell, density, strut, cells per member, candidates,
# latticed — is arithmetic on the declared geometry and core's constants, and the
# analyze path exercises it end to end on the real voxelization at his resolution.
# The blocked-stop this section exists to test ("does a VERDICT move on his part from
# the width alone?") is answered from the analyze receipt's own verdict, which is the
# gate applied to the same printed design under the same declared load.
#
# ★ HIS DESIGN BOX IS OMITTED, and not by choice: run_job refuses a "grading" block
# alongside a "design_box" — a pre-existing guard, unchanged here — so no graded cell
# mode is reachable on his job while it carries a box. Same caveat as r4_his_part.sh.
set -euo pipefail
BUILD="$(cd "${1:?usage: S4c_his_part.sh <build-dir> <out-dir> [resolution]}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
RES="${3:-128}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cp "$REPO/evidence/2026-08-05-smoothing-must-actually-smooth/WallMount_ShelfBracket.stl" "$OUT/"

python3 - "$OUT" "$RES" <<'PY'
import json, os, sys
out, res = sys.argv[1], int(sys.argv[2])
regions = [{"role": "include", "kind": "face",
            "geometry": {"origin": [0.0, -180.0 + 27.0 * i, 10.0],
                         "normal": [0.0, 1.0, 0.0],
                         "half_u_mm": 300.0, "half_w_mm": 300.0,
                         "depth_mm": 4.0}}
           for i in range(7)]
# HIS loads block, verbatim from
# evidence/2026-08-05-smoothing-must-actually-smooth/job.json. NOTE that the two WALL
# beads here are his own 0.42 outer / 0.45 inner and are NOT the strut width — they
# are the field S0 restored, and they are unchanged by this task.
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
def job(strut_w):
    return {
      "model": "WallMount_ShelfBracket.stl", "material": "PLA",
      "mode": "analyze", "resolution": res,
      "bake_build_orientation": "off",
      "loads": loads,
      # emit_stl must be true: the schema refuses a lattice block that asks for
      # neither STL nor 3MF. The mesh is a by-product here; the per-region
      # derivation in run_info.json is what this file is for.
      "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                  "min_extrudable_width_mm": strut_w, "regions": regions},
      "grading": {"topology": "octet", "cell_mode": "fit",
                  "min_extrudable_width_mm": strut_w},
      "output": {"report": "report.json", "mesh_format": "stl",
                 "mesh_prefix": "variant"}
    }
json.dump(job(0.42), open(os.path.join(out, "his_042.json"), "w"), indent=1)
json.dump(job(0.45), open(os.path.join(out, "his_045.json"), "w"), indent=1)
PY

run() { # run <name>
  rm -rf "${OUT:?}/$1"
  set +e
  ( cd "$OUT" && "$BUILD/topopt-cli" analyze "his_$1.json" --out "$1" > "$1.log" 2>&1 )
  local rc=$?
  set -e
  echo "$rc"
}
echo "=== his part, resolution $RES, analyze path ==="
echo "at a 0.42 mm stated strut width (what the app USED to send): exit $(run 042)"
echo "at a 0.45 mm stated strut width (what it sends NOW):         exit $(run 045)"
echo
grep -hE "^\[lattice\] FIT" "$OUT/042.log" | head -2 | sed 's/^/  @0.42mm  /' || true
grep -hE "^\[lattice\] FIT" "$OUT/045.log" | head -2 | sed 's/^/  @0.45mm  /' || true
echo

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]

def load(sub):
    p = os.path.join(out, sub, "run_info.json")
    return json.load(open(p)) if os.path.exists(p) else None

def verdict(sub):
    """(ACCEPTED/REJECTED, worst-case margin, effective margin, peak von Mises MPa,
    voxel mass g) from the analyze receipt. The gate result lives on the one
    pseudo-variant, which sits in `rejected_variants` when it fails — reading only
    `variants` would report None for a REJECTED run, which is the case that matters."""
    p = os.path.join(out, sub, "analysis.json")
    q = os.path.join(out, sub, "analysis_report.json")
    if not (os.path.exists(p) and os.path.exists(q)):
        return None
    A = json.load(open(p))
    R = json.load(open(q))
    rows = (R.get("variants") or []) + (R.get("rejected_variants") or [])
    if not rows:
        return None
    v = rows[0]
    return ("ACCEPTED" if v.get("accepted") else "REJECTED",
            (v.get("margin") or {}).get("worst_case"),
            v.get("margin_effective"),
            A.get("max_stress_mpa"),
            A.get("voxel_mass_grams"))

rows = {}
for sub, w in (("042", 0.42), ("045", 0.45)):
    info = load(sub)
    if info is None:
        print(f"  at a {w:.2f} mm stated strut width: no run_info.json — see {sub}.log")
        continue
    g = info.get("grading") or {}
    fit = g.get("fit") or {}
    rows[w] = (g, fit)
    print(f"=== at a {w:.2f} mm stated strut width ===")
    print(f"  cell_mode {g.get('cell_mode')}   finest printable cell "
          f"{fit.get('min_printable_cell_mm')} mm   distinct cells "
          f"{fit.get('distinct_cells')}")
    print(f"  region_voxels {g.get('region_voxels')}   latticed {g.get('latticed_voxels')}"
          f"   solid_fallback {g.get('solid_fallback_voxels')}"
          f"   no_derivation {fit.get('no_derivation_voxels')}"
          f"   printed_outside_regions {fit.get('printed_outside_regions')}")
    print(f"  density_raised {fit.get('density_raised_for_print_voxels')}   "
          f"out_of_regime_voxels {fit.get('out_of_regime_voxels')}")
    print("  region | extent mm | cell mm | rho     | strut mm | cells/member | "
          "candidates | latticed | floor in force")
    for r in fit.get("regions", []):
        floor = ("PERCOLATION (accuracy unreachable)" if r["out_of_regime"]
                 else "ACCURACY")
        if not r["feasible"]:
            floor = "NONE — refused, kept solid"
        print("  {:>6} | {:>9.4f} | {:>7.4f} | {:>7.4f} | {:>8.4f} | {:>12.2f} | "
              "{:>10} | {:>8} | {}".format(
                  r["region_index"], r["extent_mm"], r["cell_mm"],
                  r["relative_density"], r["strut_mm"], r["cells_per_member"],
                  r["candidate_voxels"], r["latticed_voxels"], floor))
    v = verdict(sub)
    print(f"  VERDICT (verdict, worst-case margin, effective margin, peak vM MPa, "
          f"voxel mass g): {v}")
    print()

print("=== ★ THE BLOCKED-STOP CHECK: DID THE VERDICT MOVE? ===")
print("  (verdict, worst-case margin, effective margin, peak von Mises MPa, voxel mass g)")
v42, v45 = verdict("042"), verdict("045")
print(f"  at a 0.42 mm stated strut width: {v42}")
print(f"  at a 0.45 mm stated strut width: {v45}")
if v42 is None or v45 is None:
    print("  NOT ESTABLISHED — one side produced no receipt.")
elif v42[0] == v45[0]:
    print(f"  the verdict did NOT move: {v42[0]} at both widths, as expected — a 4 mm")
    print("  wall is out of regime and latticed at either width (3.65 cells per member")
    print("  at 0.42 mm, 3.41 at 0.45 mm).")
else:
    print(f"  ★★ THE VERDICT MOVED: {v42[0]} at 0.42 mm -> {v45[0]} at 0.45 mm.")
    print("  THIS IS A BLOCKED-STOP. Stop and report it.")

if 0.42 in rows and 0.45 in rows:
    g42, f42 = rows[0.42]; g45, f45 = rows[0.45]
    c42 = f42["regions"][0]["cell_mm"] if f42.get("regions") else None
    c45 = f45["regions"][0]["cell_mm"] if f45.get("regions") else None
    if c42 and c45:
        print(f"\n  his 4 mm wall's derived cell: {c42:.6f} mm at a 0.42 mm strut width"
              f" -> {c45:.6f} mm at 0.45 mm  ({100.0 * (c45 / c42 - 1.0):.2f} % coarser)")
PY

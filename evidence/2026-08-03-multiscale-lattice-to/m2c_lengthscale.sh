#!/bin/sh
# M2c — DOES LENGTH-SCALE CONTROL RESCUE MULTISCALE?
#
# Three configurations, one fixture, one ladder. The fixture is the M2b positive
# control: region fully reachable (frozen_solid = 0), ceiling admits 10,002 of
# 10,040 voxels, so nothing here is excused by geometry.
#
#   twostep      — the shipping pipeline (rho^3, lattice derived from stress).
#   multiscale   — C(rho) in the loop, filter radius left at the production
#                  min_feature (2.5 mm -> 1.67 voxels). Measured at 0.8 % latticed.
#   multiscale+ls— C(rho) in the loop AND the filter radius derived from the
#                  cells-per-member floor: min_feature = floor_cells * cell / 2
#                  = 5 * 2.5 / 2 = 6.25 mm -> 4.17 voxels. Sub-floor members
#                  become INEXPRESSIBLE rather than merely unrewarded.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EV="$ROOT/evidence/2026-08-03-multiscale-lattice-to"
W="$EV/m2c"; rm -rf "$W"; mkdir -p "$W"
cp "$ROOT/evidence/2026-07-28-lattice-generation-production/l-bracket.step" "$W/"
mk() {
cat > "$W/job_$2.json" <<JSON
{
  "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 40,
  "fixture_faces": [{ "kind": "cylindrical", "radius_mm": 2.5 }],
  "gravity": { "direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0 },
  "ladder": [0.6, 0.45], "margin_stop": 1.5,
  "output": { "report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant" },
  "lattice": { "topology": "octet", "min_extrudable_width_mm": 0.12,
               "emit_stl": true, "multiscale": $1 },
  "grading": { "topology": "octet", "cell_mm": 2.5,
               "min_extrudable_width_mm": 0.12, "demand_exponent": 1.0 }
}
JSON
}
mk false twostep
mk true multiscale
# msrun  = the build WITHOUT the length-scale lever (kept for the middle row)
# msrun2 = the build WITH it
"$ROOT/build/msrun"  run "$W/job_twostep.json"    --out "$W/out_twostep"     > "$W/twostep.log" 2>&1
"$ROOT/build/msrun"  run "$W/job_multiscale.json" --out "$W/out_multiscale"  > "$W/multiscale.log" 2>&1
"$ROOT/build/msrun2" run "$W/job_multiscale.json" --out "$W/out_multiscale_ls" > "$W/multiscale_ls.log" 2>&1
python3 - "$W" <<'PY' | tee "$EV/m2c_lengthscale.txt"
import glob, json, os, sys
W = sys.argv[1]
print("M2c - DOES LENGTH-SCALE CONTROL RESCUE MULTISCALE?")
print("     l-bracket res 40, spacing 1.500 mm, cell 2.500 mm, floor 5 cells")
print("     => floor member width 12.50 mm => min_feature 6.25 mm = 4.17 voxels")
print()
print("%-16s %-12s %8s %9s %10s %10s %9s" % ("config","variant","region","latticed","latticed%","fallback","margin"))
tot = {}
for c in ("twostep", "multiscale", "multiscale_ls"):
    d = os.path.join(W, "out_" + c)
    for f in sorted(glob.glob(os.path.join(d, "*_lattice.report.json"))):
        r = json.load(open(f)); g = r["grading"]
        name = os.path.basename(f).replace("_lattice.report.json", "")
        rv, lv = g["region_voxels"], g["latticed_voxels"]
        m = r.get("lattice_margin_worst_case", 0.0)
        print("%-16s %-12s %8d %9d %9.1f%% %10d %9.4g" % (c, name, rv, lv, 100.0*lv/max(1,rv), g["solid_fallback_voxels"], m))
        a, b = tot.get(c, (0, 0)); tot[c] = (a + rv, b + lv)
print()
for c in ("twostep", "multiscale", "multiscale_ls"):
    if c in tot:
        rv, lv = tot[c]
        print("%-16s TOTAL  latticed %6d / %6d = %5.1f%%" % (c, lv, rv, 100.0*lv/max(1,rv)))
print()
for c in ("multiscale", "multiscale_ls"):
    p2 = os.path.join(W, "out_" + c, "run_info.json")
    if not os.path.exists(p2): continue
    m = json.load(open(p2)).get("multiscale", {})
    print("%s: min_feature used %.3f mm (implied %.3f)" % (c, m.get("min_feature_used_mm", 0), m.get("min_feature_implied_mm", 0)))
    for R in m.get("rungs", []):
        print("   vf %.2f  void %d band %d solid %d | below-floor %d/%d min_cells %.2f" % (
            R["volume_fraction"], R["voxels_void"], R["voxels_band"], R["voxels_solid"],
            R["floor_below_voxels"], R["floor_measured_voxels"], R["floor_min_cells_per_member"]))
        print("      histogram:", R["floor_histogram"])
PY

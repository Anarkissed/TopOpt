#!/bin/sh
# M2b — THE POSITIVE CONTROL: does the mechanism work where it CAN work?
#
# M2 measures the maintainer's own job. If that job's lattice region turns out to
# be unreachable (pinned solid by the design mask) or ungradeable (every member
# below the cells-per-member floor at the printability-floored cell), then a low
# latticed fraction says nothing about whether multiscale works — it says the
# region could not have been latticed by anything. That is a real and useful
# finding, but on its own it leaves the question "does the formulation deliver?"
# unanswered.
#
# So: the SAME two configurations on a fixture where the region IS reachable and
# the floor IS satisfiable — whole part latticed (no role regions, so nothing is
# frozen by a protection collar), and a min_extrudable_width small enough that the
# printability floor lets the cell fit inside the part's members.
#
# ONE key differs between the two jobs: "multiscale": true.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EV="$ROOT/evidence/2026-08-03-multiscale-lattice-to"
W="$EV/m2b"; rm -rf "$W"; mkdir -p "$W"
cp "$ROOT/evidence/2026-07-28-lattice-generation-production/l-bracket.step" "$W/"

mk() {  # $1 = multiscale true|false, $2 = out name
cat > "$W/job_$2.json" <<JSON
{
  "model": "l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 40,
  "fixture_faces": [{ "kind": "cylindrical", "radius_mm": 2.5 }],
  "gravity": { "direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0 },
  "ladder": [0.6, 0.45],
  "margin_stop": 1.5,
  "output": { "report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant" },
  "lattice": { "topology": "octet", "min_extrudable_width_mm": 0.12,
               "emit_stl": true, "multiscale": $1 },
  "grading": { "topology": "octet", "cell_mm": 2.5,
               "min_extrudable_width_mm": 0.12, "demand_exponent": 1.0 }
}
JSON
}
mk true multiscale
mk false twostep

for c in twostep multiscale; do
  "$ROOT/build/msrun" run "$W/job_$c.json" --out "$W/out_$c" > "$W/$c.log" 2>&1
done

python3 - "$W" > "$EV/m2b_positive_control.txt" <<'PY'
import glob, json, os, sys
W = sys.argv[1]
print("M2b — POSITIVE CONTROL: the same fixture, the same ladder, ONE key different")
print("     l-bracket, 128^3-equivalent detail at resolution 40, whole part latticed,")
print("     min_extrudable_width 0.12 mm so the printability floor admits a 2.5 mm cell.")
print()
print("%-11s %-9s %10s %10s %9s %10s %9s" % (
    "config", "variant", "region", "latticed", "latticed%", "fallback", "margin"))
rows = {}
for c in ("twostep", "multiscale"):
    for f in sorted(glob.glob(os.path.join(W, "out_" + c, "*_lattice.report.json"))):
        r = json.load(open(f))
        g = r["grading"]
        name = os.path.basename(f).replace("_lattice.report.json", "")
        rv, lv = g["region_voxels"], g["latticed_voxels"]
        m = r.get("lattice", {}).get("margin", {}).get("worst_case")
        if m is None:
            m = r.get("lattice_margin_worst_case", 0.0)
        print("%-11s %-9s %10d %10d %8.1f%% %10d %10.4g" % (
            c, name, rv, lv, 100.0 * lv / max(1, rv), g["solid_fallback_voxels"], m))
        rows.setdefault(c, []).append((name, rv, lv))
print()
for c in rows:
    tr = sum(x[1] for x in rows[c]); tl = sum(x[2] for x in rows[c])
    print("%-11s TOTAL  latticed %d / %d = %.1f%%" % (c, tl, tr, 100.0 * tl / max(1, tr)))
PY
cat "$EV/m2b_positive_control.txt"

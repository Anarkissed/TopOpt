#!/usr/bin/env bash
# S1 / R2 — THE FAILING CASE, BEFORE AND AFTER.
# (task 2026-08-05-lattice-void-reaches-exterior)
#
#   ./s1_sealed_cavity_before_after.sh <cli> <out-dir>
#
# THE PART. The demo l-bracket, resolution 48, ladder [1.0] so the optimizer
# keeps the whole part (a fully solid design is the cleanest way to build a
# cavity that is genuinely walled in). Its foot is a slab x = -30..30,
# y = -20..20, z = 0..8.33 mm with two small bores near y = 0 at x ~ -18.5 and
# x ~ +8.5.
#
# ONE lattice include region: a face slab centred at (-5, 0), 16 x 16 mm in
# plan, spanning z = 3..6 — i.e. the MIDDLE of the foot's 8.33 mm thickness,
# clear of both bores. Include semantics do the rest: only material inside the
# include union is latticed and the REST of the printed part stays SOLID, so the
# latticed pocket is surrounded by solid material with no path out.
#
# The OPEN control is THE SAME SLAB with half_w widened from 8 mm to 40 mm, so
# it runs out through the part's y faces. One number changes, and it is the one
# that decides whether the pore space reaches the outside.
#
# THREE RUNS, and each is an assertion:
#
#   BEFORE  the option ABSENT. The run SUCCEEDS, writes a latticed STL and a
#           receipt that says `lattice_accepted: true`. That is the defect: a
#           file a slicer will happily open, containing a lattice pocket nothing
#           can ever be emptied from, and not one word about it anywhere.
#
#   AFTER   the option ARMED. The run REFUSES the rung, names the cells, the
#           volume and the bounding box, and writes NO latticed STL for it.
#
#   OPEN    the option ARMED, the SAME part, the include region moved so the
#           lattice reaches the surface. It must still PASS — the rule permits
#           interior lattice, it forbids SEALED interior lattice. Without this
#           run the bar above would also be met by a check that refused
#           everything.
set -euo pipefail

CLI="${1:?usage: s1_sealed_cavity_before_after.sh <cli> <out-dir>}"
OUT="${2:?}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$OUT"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]

def job(region, armed):
    j = {"model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
         "resolution": 48,
         "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
         "gravity": {"direction": [0, 0, -1.0], "magnitude_mm_s2": 9810.0},
         "ladder": [1.0], "margin_stop": 0.0, "simp": {"max_iterations": 3},
         "output": {"report": "report.json", "mesh_format": "stl",
                    "mesh_prefix": "variant"},
         "lattice": {"topology": "octet", "cell_mm": 8.0, "strut_radius_mm": 1.2,
                     "emit_stl": True, "skin": "none",
                     "regions": [region]}}
    if armed:
        j["lattice"]["require_lattice_void_reaches_exterior"] = True
    return j

# BURIED: the middle third of the foot's thickness, 16 x 16 mm in plan, clear
# of both bores. Solid material above, below and on all four sides.
sealed = {"role": "include", "kind": "face",
          "geometry": {"origin": [-5.0, 0.0, 6.0], "normal": [0.0, 0.0, -1.0],
                       "half_u_mm": 8.0, "half_w_mm": 8.0, "depth_mm": 3.0}}
# OPEN: THE SAME SLAB, half_w widened 8 -> 40 mm so it runs out through the
# part's y faces and the pore space opens onto the free surface.
opened = {"role": "include", "kind": "face",
          "geometry": {"origin": [-5.0, 0.0, 6.0], "normal": [0.0, 0.0, -1.0],
                       "half_u_mm": 8.0, "half_w_mm": 40.0, "depth_mm": 3.0}}

json.dump(job(sealed, False), open(os.path.join(out, "job_sealed_off.json"), "w"), indent=1)
json.dump(job(sealed, True),  open(os.path.join(out, "job_sealed_on.json"), "w"), indent=1)
json.dump(job(opened, True),  open(os.path.join(out, "job_open_on.json"), "w"), indent=1)
PY

run() {  # run <job> <subdir>  — never aborts the script; the exit code IS evidence
  rm -rf "${OUT:?}/$2"
  ( cd "$OUT" && "$CLI" run "$1" --out "$2" > "$2.log" 2>&1 ) || true
}

fail=0

echo "############################################################"
echo "# BEFORE — the option ABSENT. This is what ships today."
echo "############################################################"
run job_sealed_off.json before
python3 - "$OUT/before" "$OUT/before.log" <<'PY' || fail=1
import glob, json, os, sys
d, log = sys.argv[1], sys.argv[2]
stls = sorted(glob.glob(os.path.join(d, "*_lattice.stl")))
rcpts = sorted(glob.glob(os.path.join(d, "*_lattice.report.json")))
for s in stls:
    print(f"  WROTE  {os.path.basename(s)}  {os.path.getsize(s)} bytes")
ok = bool(stls) and bool(rcpts)
for f in rcpts:
    r = json.load(open(f))
    print(f"  {os.path.basename(f)}: lattice_accepted={r['lattice_accepted']} "
          f"lattice_voxels={r['lattice_voxels']} "
          f"lattice_margin_worst_case={r['lattice_margin_worst_case']}")
    if "void_escape" in r:
        print("  UNEXPECTED: the un-armed run wrote a void_escape block")
        ok = False
    ok = ok and r["lattice_accepted"] is True
print()
print("  BEFORE " + ("PASS — the sealed cavity is exported and CERTIFIED with no"
      "\n         complaint anywhere. That is the defect this task closes."
      if ok else "FAIL — expected today's build to accept it."))
sys.exit(0 if ok else 1)
PY
echo

echo "############################################################"
echo "# AFTER — the option ARMED, the same part."
echo "############################################################"
run job_sealed_on.json after
echo "  --- the refusal, verbatim from stderr ---"
grep -F "NO LATTICE EMITTED" "$OUT/after.log" | fold -s -w 78 | sed 's/^/  /' || true
python3 - "$OUT/after" "$OUT/after.log" <<'PY' || fail=1
import glob, json, os, sys
d, log = sys.argv[1], sys.argv[2]
txt = open(log).read()
stls = sorted(glob.glob(os.path.join(d, "*_lattice.stl")))
ok = True
if stls:
    print(f"  FAIL: a latticed STL was written anyway: {stls}")
    ok = False
else:
    print("  no latticed STL was written — the refusal happens BEFORE the "
          "generator runs")
if "does not reach the exterior" not in txt:
    print("  FAIL: no refusal on stderr")
    ok = False
ri = json.load(open(os.path.join(d, "run_info.json")))
ve = (ri.get("lattice_export") or {}).get("void_escape")
if not ve:
    print("  FAIL: run_info carries no void_escape record")
    ok = False
else:
    print(f"  run_info.lattice_export.void_escape: sealed={ve['sealed']} "
          f"sealed_variants={ve['sealed_variants']} cells={ve['sealed_cells']} "
          f"voxels={ve['sealed_voxels']} volume_mm3={ve['sealed_volume_mm3']} "
          f"bfs_visits={ve['bfs_visits']} wall_seconds={ve['wall_seconds']}")
    ok = ok and ve["sealed"] is True and ve["sealed_variants"] == 1
print()
print("  AFTER " + ("PASS — refused, with the counts, the volume and the box."
      if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
echo

echo "############################################################"
echo "# OPEN — the option ARMED, the lattice reaching the surface."
echo "# The rule must PERMIT what he actually wants."
echo "############################################################"
run job_open_on.json open
python3 - "$OUT/open" <<'PY' || fail=1
import glob, json, os, sys
d = sys.argv[1]
rcpts = sorted(glob.glob(os.path.join(d, "*_lattice.report.json")))
ok = bool(rcpts)
if not ok:
    print("  FAIL: the open case produced no latticed variant at all")
for f in rcpts:
    v = json.load(open(f))["void_escape"]
    print(f"  {os.path.basename(f)}: sealed={v['sealed']} "
          f"latticed_voxels={v['latticed_voxels']} "
          f"reached={v['latticed_voxels_reached']} "
          f"escape_depth_voxels={v['escape_depth_voxels']} "
          f"escape_faces={v['escape_faces']} "
          f"reachable_void_volume_mm3={v['reachable_void_volume_mm3']}")
    ok = ok and v["sealed"] is False and v["ran"] is True
stls = sorted(glob.glob(os.path.join(d, "*_lattice.stl")))
for s in stls:
    print(f"  WROTE  {os.path.basename(s)}  {os.path.getsize(s)} bytes")
ok = ok and bool(stls)
print()
print("  OPEN " + ("PASS — an interior lattice pocket that reaches the surface "
      "is\n       exported, and the receipt SAYS which way out it found."
      if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
echo

if [ "$fail" = "0" ]; then
  echo "S1 PASS — today's build accepts a sealed lattice-filled cavity; the armed"
  echo "          check refuses it before a triangle is written; and an OPEN"
  echo "          interior lattice pocket still passes."
  exit 0
fi
echo "S1 FAIL."
exit 1

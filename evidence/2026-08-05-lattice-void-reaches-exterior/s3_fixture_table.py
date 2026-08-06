#!/usr/bin/env python3
"""S3 — WHAT THE RULE WOULD REFUSE, MEASURED BEFORE HE ARMS IT.
(task 2026-08-05-lattice-void-reaches-exterior)

    ./s3_fixture_table.py <cli> <out-dir>

Every lattice-shaped job this repo owns, run with
`lattice.require_lattice_void_reaches_exterior` ARMED, tabulated: would it
refuse, and why.

EVERY ROW SETS `"skin": "none"`. On a voxel-silhouette part the rim/diagrid
finish rides pairs of ANALYTIC boundary faces and there are none, so a non-"none"
finish emits nothing and run_job REFUSES it (run_job.cpp M4, task
lattice-cell-fit-mode). That is a DIFFERENT rule from this one and it would mask
this one. The one exception is the freeform `outer_finish: "skin"` row, which
requires `skin: "diagrid"` by schema and rides the voxel surface itself.

THE ROWS mirror the lattice fixtures the test suite actually exercises — the
uniform whole-part lattice, the graded SWEPT ladder, the self-weight mesh job,
each of the two role regions, the freeform "skin" outer finish, and the
maintainer's own WallMount part at his 8 mm uniform cell — plus the two
DELIBERATE controls:

    SEALED  a lattice-filled cavity buried in the l-bracket's foot. It MUST
            refuse. A table where nothing refuses is not evidence that the
            fixtures are clean; it is evidence that the check was never tested.
    OPEN    the SAME cavity with one dimension widened so it reaches the
            surface. It MUST pass, or the check is refusing on something other
            than sealing.

Both controls are asserted, not merely reported: this script exits non-zero if
either goes the wrong way.
"""
import json, os, shutil, subprocess, sys, time

CLI = sys.argv[1] if len(sys.argv) > 1 else "topopt-cli"
OUT = sys.argv[2] if len(sys.argv) > 2 else "s3_out"
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DEMO = os.path.join(REPO, "core", "tests", "fixtures", "demo")
MESH = os.path.join(REPO, "core", "tests", "fixtures", "mesh")

os.makedirs(OUT, exist_ok=True)
for src in (os.path.join(DEMO, "l-bracket.step"),
            os.path.join(MESH, "plate_bore.stl"),
            os.path.join(MESH, "WallMount_ShelfBracket.stl")):
    shutil.copy(src, OUT)
OUT = os.path.abspath(OUT)


def arm(j):
    j["lattice"]["require_lattice_void_reaches_exterior"] = True
    return j


def bracket_loadcase(res=48, iters=12):
    return {"model": "l-bracket.step", "material": "PLA",
            "mode": "minimize_plastic", "resolution": res,
            "simp": {"max_iterations": iters},
            "loads": {"anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
                      "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]},
            "output": {"report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant"}}


def plate_selfweight(res=32, iters=8, ladder=(0.6,)):
    return {"model": "plate_bore.stl", "material": "PLA",
            "mode": "minimize_plastic", "resolution": res,
            "fixture_faces": [{"kind": "cylindrical", "radius_mm": 3.0}],
            "gravity": {"direction": [0, 0, -1.0], "magnitude_mm_s2": 9810.0},
            "ladder": list(ladder), "margin_stop": 0.0,
            "simp": {"max_iterations": iters},
            "output": {"report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant"}}


def foot_slab(half_w):
    return {"role": "include", "kind": "face",
            "geometry": {"origin": [-5.0, 0.0, 6.0], "normal": [0.0, 0.0, -1.0],
                         "half_u_mm": 8.0, "half_w_mm": half_w, "depth_mm": 3.0}}


# ── the rows ────────────────────────────────────────────────────────────────
ROWS = []

j = bracket_loadcase()
j["lattice"] = {"topology": "octet", "cell_mm": 8.0, "strut_radius_mm": 1.2,
                "emit_stl": True, "skin": "none"}
ROWS.append(("uniform whole-part lattice (l-bracket, 4-rung ladder)", arm(j), None))

j = bracket_loadcase()
j["lattice"] = {"topology": "octet", "emit_stl": True, "skin": "none",
                "min_extrudable_width_mm": 0.42}
j["grading"] = {"topology": "octet", "cell_mode": "swept", "cell_min_mm": 3.0,
                "cell_max_mm": 12.0, "min_extrudable_width_mm": 0.42}
ROWS.append(("graded SWEPT lattice (l-bracket, dyadic cell ladder)", arm(j), None))

j = bracket_loadcase()
j["lattice"] = {"topology": "octet", "cell_mm": 8.0, "strut_radius_mm": 1.2,
                "emit_stl": True, "skin": "diagrid",
                "min_extrudable_width_mm": 0.42, "outer_finish": "skin"}
ROWS.append(("freeform SKIN outer finish (no solid shell)", arm(j), None))

j = plate_selfweight()
j["lattice"] = {"topology": "octet", "cell_mm": 3.0, "strut_radius_mm": 0.45,
                "emit_stl": True, "skin": "none"}
ROWS.append(("self-weight mesh job, uniform lattice (plate_bore.stl)", arm(j), None))

j = plate_selfweight()
j["lattice"] = {"topology": "octet", "cell_mm": 3.0, "strut_radius_mm": 0.45,
                "emit_stl": True, "skin": "none",
                "regions": [{"role": "exclude", "kind": "bolt", "geometry": {
                    "axis_point": [8.0, 0.0, 2.0], "axis_dir": [0.0, 0.0, 1.0],
                    "radius_mm": 3.0, "half_length_mm": 5.0}}]}
ROWS.append(("... + EXCLUDE bolt region (kept solid)", arm(j), None))

j = plate_selfweight()
j["lattice"] = {"topology": "octet", "cell_mm": 3.0, "strut_radius_mm": 0.45,
                "emit_stl": True, "skin": "none",
                "regions": [{"role": "include", "kind": "face", "geometry": {
                    "origin": [-12.0, 0.0, 2.0], "normal": [1.0, 0.0, 0.0],
                    "half_u_mm": 50.0, "half_w_mm": 50.0, "depth_mm": 14.0}}]}
ROWS.append(("... + INCLUDE slab region (only it is latticed)", arm(j), None))

j = {"model": "WallMount_ShelfBracket.stl", "material": "PLA",
     "mode": "minimize_plastic", "resolution": 64,
     # radius 2.0 is the bore this part actually has — 3.0 matches no face and
     # the run refuses at face selection, which is a fixture fact, not a finding.
     "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.0}],
     "gravity": {"direction": [0, 0, -1.0], "magnitude_mm_s2": 9810.0},
     "ladder": [0.6], "margin_stop": 0.0, "simp": {"max_iterations": 8},
     "output": {"report": "report.json", "mesh_format": "stl",
                "mesh_prefix": "variant"},
     "lattice": {"topology": "octet", "cell_mm": 8.0, "strut_radius_mm": 1.2,
                 "emit_stl": True, "skin": "none"}}
ROWS.append(("maintainer's WallMount part, uniform 8 mm cell", arm(j), None))

j = bracket_loadcase(res=48, iters=3)
del j["loads"]
j.update({"fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
          "gravity": {"direction": [0, 0, -1.0], "magnitude_mm_s2": 9810.0},
          "ladder": [1.0], "margin_stop": 0.0})
j["lattice"] = {"topology": "octet", "cell_mm": 8.0, "strut_radius_mm": 1.2,
                "emit_stl": True, "skin": "none", "regions": [foot_slab(8.0)]}
ROWS.append(("★ CONTROL, SEALED: cavity buried in the l-bracket foot",
             arm(j), True))

j = json.loads(json.dumps(j))
j["lattice"]["regions"] = [foot_slab(40.0)]
ROWS.append(("★ CONTROL, OPEN: the same cavity, run out to the y faces",
             j, False))


# ── run ─────────────────────────────────────────────────────────────────────
def summarize(sub, job, expect):
    d = os.path.join(OUT, sub)
    shutil.rmtree(d, ignore_errors=True)
    json.dump(job, open(os.path.join(OUT, sub + ".json"), "w"), indent=1)
    t0 = time.time()
    r = subprocess.run([CLI, "run", sub + ".json", "--out", sub], cwd=OUT,
                       capture_output=True, text=True)
    dt = time.time() - t0
    open(os.path.join(OUT, sub + ".log"), "w").write(r.stdout + r.stderr)
    ri_path = os.path.join(d, "run_info.json")
    if r.returncode != 0 or not os.path.exists(ri_path):
        return {"verdict": "RUN FAILED", "why": r.stderr.strip().splitlines()[-1:] ,
                "wall": dt}
    ri = json.load(open(ri_path))
    ve = (ri.get("lattice_export") or {}).get("void_escape")
    if ve is None:
        return {"verdict": "no lattice emitted", "why": "no lattice_export record",
                "wall": dt}
    return {"verdict": "REFUSE" if ve["sealed"] else "pass", "ve": ve, "wall": dt,
            "expect": expect}


print(f"{'fixture':<56} {'verdict':<8} {'sealed cells':>12} "
      f"{'sealed mm3':>11} {'latticed cells':>14} {'reached':>9} "
      f"{'depth':>6} {'faces':<14} {'bfs':>9} {'check s':>8} {'run s':>7}")
print("-" * 175)
bad = False
for i, (name, job, expect) in enumerate(ROWS):
    s = summarize(f"row{i:02d}", job, expect)
    if "ve" not in s:
        print(f"{name:<56} {s['verdict']:<8} {'-':>12} {'-':>11} {'-':>14} "
              f"{'-':>9} {'-':>6} {'-':<14} {'-':>9} {'-':>8} {s['wall']:>7.1f}")
        if expect is not None:
            print("   *** CONTROL DID NOT RUN — this row is the whole point ***")
            bad = True
        continue
    v = s["ve"]
    print(f"{name:<56} {s['verdict']:<8} {v['sealed_cells']:>12} "
          f"{v['sealed_volume_mm3']:>11.1f} {v['latticed_cells']:>14} "
          f"{v['latticed_voxels_reached']:>9} {v['escape_depth_voxels']:>6} "
          f"{v['escape_faces'] or '-':<14} {v['bfs_visits']:>9} "
          f"{v['wall_seconds']:>8.4f} {s['wall']:>7.1f}")
    if expect is True and s["verdict"] != "REFUSE":
        print("   *** CONTROL FAILED: the deliberately sealed cavity was NOT "
              "refused ***")
        bad = True
    if expect is False and s["verdict"] != "pass":
        print("   *** CONTROL FAILED: the OPEN cavity was refused — the check is "
              "not measuring sealing ***")
        bad = True

print()
print("READING THIS TABLE. 'depth' is the geodesic distance in 6-connected escape")
print("steps from the design grid's boundary planes to the nearest reached")
print("latticed voxel — how far under the surface the drain path runs; 0 means the")
print("lattice itself lies on a boundary plane. 'faces' names the grid faces the")
print("open lattice's escape network touches. 'check s' is the fill's own wall")
print("time, summed over the run's rungs, and is NOT part of gen_seconds.")
print()
print("S3 " + ("PASS — both controls went the way they had to."
      if not bad else "FAIL — a control went the wrong way."))
sys.exit(1 if bad else 0)

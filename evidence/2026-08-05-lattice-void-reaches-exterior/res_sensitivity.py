#!/usr/bin/env python3
"""RESOLUTION SENSITIVITY — stated rather than filed.
(task 2026-08-05-lattice-void-reaches-exterior)

    ./res_sensitivity.py <cli> <out-dir>

The check is EXACT on the voxel field it is given. What is not
resolution-independent is the ANSWER, because the answer is a property of the
DISCRETISED part: a cavity whose wall is one or two voxels thick can change
verdict with the grid.

Two constructions on the same part, swept across resolution:

  MARGINAL  a bolt cylinder r = 3 mm at (15, ., 5) in the l-bracket's foot. The
            foot is 8.33 mm thick, so the 6 mm cylinder leaves ~1 mm of wall
            above and below. This one FLIPS.
  SHIPPED   the face slab used by the s1 evidence and by the ctest fixture:
            z = 3..6 in the middle of the foot, 16 x 16 mm in plan, clear of
            both bores — >= 2 voxels of solid on every side at every resolution
            here. This one is SEALED at every resolution, and its OPEN twin
            (half_w 8 -> 40 mm) is open at every resolution.

The point of printing the marginal row is that it is honest about where the
verdict comes from. The point of printing the shipped rows is that the fixture
the tests rest on was chosen for stability, not found by luck.
"""
import json, os, shutil, subprocess, sys, time

CLI = sys.argv[1] if len(sys.argv) > 1 else "topopt-cli"
OUT = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "res_out")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DEMO = os.path.join(REPO, "core", "tests", "fixtures", "demo")

os.makedirs(OUT, exist_ok=True)
shutil.copy(os.path.join(DEMO, "l-bracket.step"), OUT)

RESOLUTIONS = [32, 40, 48, 56, 64, 72]

MARGINAL = {"role": "include", "kind": "bolt",
            "geometry": {"axis_point": [15.0, 0.0, 5.0], "axis_dir": [0, 1.0, 0],
                         "radius_mm": 3.0, "half_length_mm": 12.0}}
def slab(half_w):
    return {"role": "include", "kind": "face",
            "geometry": {"origin": [-5.0, 0.0, 6.0], "normal": [0.0, 0.0, -1.0],
                         "half_u_mm": 8.0, "half_w_mm": half_w, "depth_mm": 3.0}}


def job(res, region):
    return {"model": "l-bracket.step", "material": "PLA",
            "mode": "minimize_plastic", "resolution": res,
            "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
            "gravity": {"direction": [0, 0, -1.0], "magnitude_mm_s2": 9810.0},
            "ladder": [1.0], "margin_stop": 0.0, "simp": {"max_iterations": 3},
            "output": {"report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant"},
            "lattice": {"topology": "octet", "cell_mm": 8.0,
                        "strut_radius_mm": 1.2, "emit_stl": True, "skin": "none",
                        "require_lattice_void_reaches_exterior": True,
                        "regions": [region]}}


def measure(tag, region, expect):
    print(f"--- {tag} ---")
    print(f"{'resolution':>10} {'spacing mm':>11} {'verdict':>8} "
          f"{'sealed cells':>12} {'sealed mm3':>11} {'reached':>9} {'depth':>6} "
          f"{'faces':<18} {'run s':>7}")
    bad = False
    for res in RESOLUTIONS:
        sub = f"{tag.split()[0].lower()}_{res}"
        shutil.rmtree(os.path.join(OUT, sub), ignore_errors=True)
        json.dump(job(res, region), open(os.path.join(OUT, sub + ".json"), "w"),
                  indent=1)
        t0 = time.time()
        r = subprocess.run([CLI, "run", sub + ".json", "--out", sub], cwd=OUT,
                           capture_output=True, text=True)
        dt = time.time() - t0
        open(os.path.join(OUT, sub + ".log"), "w").write(r.stdout + r.stderr)
        ri = os.path.join(OUT, sub, "run_info.json")
        if r.returncode != 0 or not os.path.exists(ri):
            print(f"{res:>10}  RUN FAILED"); bad = True; continue
        ve = (json.load(open(ri)).get("lattice_export") or {}).get("void_escape")
        if ve is None:
            print(f"{res:>10}  no lattice emitted"); continue
        v = "REFUSE" if ve["sealed"] else "pass"
        print(f"{res:>10} {60.0/res:>11.4f} {v:>8} {ve['sealed_cells']:>12} "
              f"{ve['sealed_volume_mm3']:>11.1f} "
              f"{ve['latticed_voxels_reached']:>9} "
              f"{ve['escape_depth_voxels']:>6} "
              f"{(ve['escape_faces'] or '-'):<18} {dt:>7.1f}")
        if expect is not None and (v == "REFUSE") != expect:
            print("    *** this row contradicts what this construction is for ***")
            bad = True
    print()
    return bad


bad = False
bad |= measure("MARGINAL bolt cylinder — the verdict FLIPS with the grid",
               MARGINAL, None)
bad |= measure("SHIPPED slab, buried — must be SEALED at every resolution",
               slab(8.0), True)
bad |= measure("SHIPPED slab, OPEN twin — must PASS at every resolution",
               slab(40.0), False)

print("The marginal row is reported, not asserted: it is the CAVITY that is")
print("marginal, not the check. The shipped fixture was chosen because it is")
print("stable across every resolution above, and both of its rows are asserted.")
print()
print("RESULT " + ("PASS" if not bad else "FAIL"))
sys.exit(1 if bad else 0)

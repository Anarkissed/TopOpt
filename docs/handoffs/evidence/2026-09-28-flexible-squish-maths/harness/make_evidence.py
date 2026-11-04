#!/usr/bin/env python3
"""Evidence harness for task 2026-09-28-flexible-squish-maths (C1).

Writes three scenario jobs on box STLs it generates, rasterises the built-in stamps
from docs/design/flexibles/data/stamps.json into pressure grids (the app's job in
production -- core never reads a shape), runs `topopt-cli flexible` on each, and
checks the receipts for the facts each scenario is meant to show.

    python3 make_evidence.py --cli <path to topopt-cli> [--out <evidence dir>]

Face ids: the STL is written bottom, top, -Y, +X, +Y, -X (two triangles each), and
the importer seeds pseudo-faces in triangle order, so the faces are 0..5 in that
order. Every scenario asserts it from the receipt (the top face's load is -Z and its
stack exits through face 0), so a change in the importer cannot pass silently.
"""
import argparse
import json
import math
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
STAMPS = os.path.join(REPO, "docs", "design", "flexibles", "data", "stamps.json")
G = 9.81


def box_stl(path, L, W, H):
    P = lambda x, y, z: (x, y, z)
    quads = [
        (P(0, 0, 0), P(0, W, 0), P(L, W, 0), P(L, 0, 0)),  # 0 bottom -Z
        (P(0, 0, H), P(L, 0, H), P(L, W, H), P(0, W, H)),  # 1 top +Z
        (P(0, 0, 0), P(L, 0, 0), P(L, 0, H), P(0, 0, H)),  # 2 front -Y
        (P(L, 0, 0), P(L, W, 0), P(L, W, H), P(L, 0, H)),  # 3 right +X
        (P(L, W, 0), P(0, W, 0), P(0, W, H), P(L, W, H)),  # 4 back +Y
        (P(0, W, 0), P(0, 0, 0), P(0, 0, H), P(0, W, H)),  # 5 left -X
    ]
    tris = []
    for a, b, c, d in quads:
        tris += [(a, b, c), (a, c, d)]
    with open(path, "wb") as f:
        f.write(b"flexible evidence box".ljust(80, b" "))
        f.write(struct.pack("<I", len(tris)))
        for a, b, c in tris:
            u = [b[i] - a[i] for i in range(3)]
            v = [c[i] - a[i] for i in range(3)]
            n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
            ln = math.sqrt(sum(x * x for x in n))
            n = [x / ln for x in n]
            f.write(struct.pack("<3f", *n))
            for p in (a, b, c):
                f.write(struct.pack("<3f", *p))
            f.write(struct.pack("<H", 0))


def stamp_def(stamp_id):
    with open(STAMPS) as f:
        for s in json.load(f)["stamps"]:
            if s["id"] == stamp_id:
                return s
    raise KeyError(stamp_id)


def inside(shape, x, y):
    """Is (x, y) (mm, relative to the stamp centre) under the shape?"""
    k = shape["shape"]
    if k == "ellipse":
        a, b = shape["width_mm"] / 2.0, shape["length_mm"] / 2.0
        return (x / a) ** 2 + (y / b) ** 2 <= 1.0
    if k == "circle":
        return x * x + y * y <= (shape["diameter_mm"] / 2.0) ** 2
    if k == "group":
        return any(inside(m, x - m["offset_mm"][0], y - m["offset_mm"][1]) for m in shape["members"])
    raise ValueError("harness does not rasterise shape " + k)


def extent(shape):
    k = shape["shape"]
    if k == "ellipse":
        return shape["width_mm"], shape["length_mm"]
    if k == "circle":
        return shape["diameter_mm"], shape["diameter_mm"]
    if k == "group":
        xs, ys = [], []
        for m in shape["members"]:
            w, l = extent(m)
            xs += [m["offset_mm"][0] - w / 2, m["offset_mm"][0] + w / 2]
            ys += [m["offset_mm"][1] - l / 2, m["offset_mm"][1] + l / 2]
        return max(xs) - min(xs) + 2, max(ys) - min(ys) + 2
    raise ValueError(k)


def rasterise(stamp_id, force_n, centre_uv, cell_mm=0.5, face_region_id=None):
    """A SOFT stamp: the force spread evenly over the shape (stamps.json
    default_press.soft), sampled at cell centres, normalised so the cells add up to
    the force exactly."""
    s = stamp_def(stamp_id)
    w, l = extent(s)
    nu, nv = int(math.ceil(w / cell_mm)) + 2, int(math.ceil(l / cell_mm)) + 2
    ou, ov = centre_uv[0] - nu * cell_mm / 2.0, centre_uv[1] - nv * cell_mm / 2.0
    mask = []
    for j in range(nv):
        for i in range(nu):
            x = ou + (i + 0.5) * cell_mm - centre_uv[0]
            y = ov + (j + 0.5) * cell_mm - centre_uv[1]
            mask.append(1 if inside(s, x, y) else 0)
    n = sum(mask)
    p = force_n / (n * cell_mm * cell_mm)
    out = {"name": s["id"], "mode": s["press"], "force_n": force_n, "origin_mm": [ou, ov],
           "cell_mm": cell_mm, "nu": nu, "nv": nv, "values_mpa": [p if m else 0.0 for m in mask]}
    if face_region_id is not None:
        out = {"face_region_id": face_region_id, **out}
    return out


def base_job(model, material="varioshore_tpu"):
    return {
        "_comment": "evidence job, task 2026-09-28-flexible-squish-maths; written by harness/make_evidence.py",
        "model": model,
        "material": material,
        "mode": "analyze",
        "resolution": 100,
        "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "unused"},
        "loads": {"face_regions": [{"id": 100 + f, "name": n, "add": [f]} for f, n in
                                   enumerate(["bottom", "top", "front -Y", "right +X", "back +Y", "left -X"])]},
    }


def scenario_a():
    job = base_job("pad_100x100x20.stl")
    job["flexible"] = {
        "material_id": "varioshore_tpu", "nozzle_temp_c": 220, "topology": "auto", "feel": "springy",
        "beads_per_wall": 1, "min_extrudable_width_mm": 0.42,
        "faces": [
            {"face_region_id": 101, "role": "loaded", "weight_n": round(30 * G, 3), "deepest_squish_mm": 4,
             "mode": "both", "curve_x": [[0, 0.3], [0.5, 1], [1, 0.3]], "curve_y": [[0, 0.3], [0.5, 1], [1, 0.3]],
             "skin_on": True},
            {"face_region_id": 100, "role": "resting", "skin_on": True},
        ],
    }
    return "a_pad_centre_soft", (100, 100, 20), job


def scenario_b():
    name, dims, job = scenario_a()
    fx = job["flexible"]
    fx["faces"][0]["design_stamp"] = rasterise("thumb", 50.0, (50, 50))
    fx["check_stamps"] = [rasterise("palm", 100.0, (50, 50), face_region_id=101),
                          rasterise("heel", 300.0, (50, 50), face_region_id=101)]
    return "b_pad_thumb_design_palm_heel_check", dims, job


def scenario_c():
    job = base_job("block_100x100x60.stl")
    job["flexible"] = {
        "material_id": "varioshore_tpu", "nozzle_temp_c": "auto", "topology": "auto", "feel": "damped",
        "beads_per_wall": 1, "min_extrudable_width_mm": 0.42,
        "faces": [
            {"face_region_id": 101, "role": "loaded", "weight_n": round(30 * G, 3), "deepest_squish_mm": 10,
             "mode": "either", "curve_x": [[0, 1], [0.2, 0.3], [0.8, 0.3], [1, 1]],
             "curve_y": [[0, 1], [0.2, 0.3], [0.8, 0.3], [1, 1]], "skin_on": True},
            {"face_region_id": 103, "role": "loaded", "weight_n": round(25 * G, 3), "deepest_squish_mm": 10,
             "mode": "centre_edge", "curve_centre_edge": [[0, 0.4], [1, 1]], "skin_on": True},
            {"face_region_id": 100, "role": "resting", "skin_on": True},
            {"face_region_id": 105, "role": "resting", "skin_on": True},
        ],
    }
    return "c_block_top_and_side_handover", (100, 100, 60), job


def scenario_d():
    """C1 addendum (2026-10-07): ANGLED PRESSES. A 60 mm cube pressed on top (straight
    down) and on its vertical +X/+Y EDGE (one footprint of two faces, along (-1,-1,0)):
    two stacks 90 degrees apart, so a handover, not a conflict."""
    job = base_job("cube_60.stl")
    job["resolution"] = 60
    job["flexible"] = {
        "material_id": "varioshore_tpu", "nozzle_temp_c": 220, "topology": "auto", "feel": "springy",
        "beads_per_wall": 1, "min_extrudable_width_mm": 0.42,
        "faces": [
            {"face_region_id": 101, "role": "loaded", "weight_n": round(10 * G, 3), "deepest_squish_mm": 6,
             "mode": "both", "curve_x": [[0, 0.6], [0.5, 1], [1, 0.6]], "curve_y": [[0, 0.6], [0.5, 1], [1, 0.6]],
             "skin_on": True},
            {"face_region_ids": [103, 104], "press_direction": [-1, -1, 0], "role": "loaded",
             "weight_n": round(15 * G, 3), "deepest_squish_mm": 6, "mode": "centre_edge",
             "curve_centre_edge": [[0, 0.5], [1, 1]], "skin_on": True},
            {"face_region_id": 100, "role": "resting", "skin_on": True},
        ],
    }
    return "d_cube_top_and_vertical_edge_press", (60, 60, 60), job


def run(cli, name, dims, job, out_root):
    d = os.path.join(out_root, name)
    os.makedirs(d, exist_ok=True)
    box_stl(os.path.join(d, job["model"]), *dims)
    with open(os.path.join(d, "job.json"), "w") as f:
        json.dump(job, f, indent=1)
    p = subprocess.run([cli, "flexible", os.path.join(d, "job.json"), "--out", os.path.join(d, "out")],
                       capture_output=True, text=True)
    with open(os.path.join(d, "cli_output.txt"), "w") as f:
        f.write("$ topopt-cli flexible job.json --out out\n" + p.stdout + p.stderr +
                "exit code %d\n" % p.returncode)
    print(name, "exit", p.returncode)
    if p.returncode != 0:
        print(p.stdout, p.stderr)
        sys.exit(1)
    with open(os.path.join(d, "out", "run_info.json")) as f:
        return json.load(f)["flexible"]


def face(rc, fid):
    return next(f for f in rc["faces"] if f["face_region_id"] == fid)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--out", default=os.path.abspath(os.path.join(HERE, "..")))
    a = ap.parse_args()
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("  PASS " if cond else "  FAIL ") + msg)
        ok = ok and cond

    rc = run(a.cli, *scenario_a(), a.out)
    t = face(rc, 101)
    check(t["frame"]["load"] == [0, 0, -1], "(a) face 101 is the top: load -Z")
    check(t["stack"]["linked_faces"][0]["face_id"] == 0 and t["stack"]["linked_regions"][0]["face_region_id"] == 100,
          "(a) its stack's other end is the bottom (face 0 / region 100)")
    check(rc["nozzle_temp_c"] == 220 and rc["topology"] == "gyroid", "(a) gyroid at 220 C")
    # Core strain (review round 1): the firmest gyroid squishes 0.40 mm under 30 kg, deeper
    # than the 0.38 mm drawn at the four corners, so those few columns are too soft.
    st = t["columns_by_status"]
    check(0 < st["too_soft"] <= 20 and st["too_firm"] == 0 and st["beyond_data"] == 0 and
          not rc["recommendation"]["reachable"],
          "(a) only the corner columns are out of reach (too soft), and Auto says so")
    check(t["tier"]["tier"] == "literature" and t["tier"]["band"] == 0.4, "(a) literature tier, +/-40 %")

    rc = run(a.cli, *scenario_b(), a.out)
    t = face(rc, 101)
    check(t["design_stamp"]["name"] == "thumb", "(b) thumb is the design load")
    names = [c["name"] for c in rc["check_stamps"]]
    check(names == ["palm", "heel"], "(b) palm and heel checked")

    rc = run(a.cli, *scenario_c(), a.out)
    s = face(rc, 103)
    check(s["frame"]["side"] and s["tier"]["tier"] == "estimated" and s["tier"]["band"] == 0.5,
          "(c) the side stack is 'estimated', +/-50 %")
    check(rc["topology"] == "gyroid", "(c) gyroid only")
    check(any(r["code"] == "honeycomb_side_stack" for r in rc["recommendation"]["reasons"]),
          "(c) the reason names the side stack")
    check(len(rc["handover"]) == 1 and rc["handover"][0]["blended_mm3"] > 0, "(c) a blended handover zone")
    check(s["stack"]["linked_faces"][0]["face_id"] == 5, "(c) the side's other end is the -X face")
    rc = run(a.cli, *scenario_d(), a.out)
    e = face(rc, 103)
    check(e["press"]["footprint_face_region_ids"] == [103, 104] and e["press"]["side"] and
          abs(e["press"]["build_angle_deg"] - 90) < 1e-6, "(d) the edge press: footprint 103+104, 90 degrees, side")
    check({l["face_region_id"] for l in e["stack"]["linked_regions"]} == {102, 105},
          "(d) the edge's other end is the -Y and -X faces")
    check(len(rc["handover"]) == 1 and rc["handover"][0]["blended_mm3"] > 0 and not rc["conflicts"],
          "(d) top and edge: one blended handover, no conflict")
    check(rc["topology"] == "gyroid", "(d) gyroid only (a side press)")
    print("ALL PASS" if ok else "SOME CHECKS FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

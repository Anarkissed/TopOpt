#!/usr/bin/env python3
# scen_red.py CLI FACES_PROBE OUTDIR: E2.1 red-first. One 60 x 20 x 20 mm bar, anchored at x = 0,
# two scenarios: "light down" (top face, 30 N down) and "heavy side" (the x = 60 end, 300 N in +y).
# Four graded octet lattice runs of the SAME part: A = [light, heavy], B = [heavy, light],
# C = heavy alone (no scenarios), D = light alone. If the lattice certificate follows the order
# (A = D, B = C) it certifies scenario 1 only.
import json, os, struct, subprocess, sys
cli, probe, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
L, Wd, H = 60.0, 20.0, 20.0
v = [(0,0,0),(L,0,0),(L,Wd,0),(0,Wd,0),(0,0,H),(L,0,H),(L,Wd,H),(0,Wd,H)]
t = [(0,2,1),(0,3,2),(4,5,6),(4,6,7),(0,1,5),(0,5,4),(3,7,6),(3,6,2),(0,4,7),(0,7,3),(1,2,6),(1,6,5)]
stl = os.path.join(out, "bar.stl")
with open(stl, "wb") as f:
    f.write(b"\0" * 80 + struct.pack("<I", len(t)))
    for a, b, c in t:
        f.write(struct.pack("<3f", 0, 0, 0))
        for i in (a, b, c): f.write(struct.pack("<3f", *v[i]))
        f.write(b"\0\0")
faces = {}
for line in subprocess.run([probe, stl], capture_output=True, text=True).stdout.split("\n"):
    p = line.split()
    if len(p) == 7:
        n = tuple(round(float(x)) for x in p[1:4])
        faces[n] = int(p[0])
left, top, right = faces[(-1, 0, 0)], faces[(0, 0, 1)], faces[(1, 0, 0)]
light = {"name": "light down", "groups": [{"face_ids": [top], "force": [0, 0, -30]}], "anchor_face_ids": [left]}
heavy = {"name": "heavy side", "groups": [{"face_ids": [right], "force": [0, 300, 0]}], "anchor_face_ids": [left]}
def job(scen, alone=None):
    loads = {"minimize_plastic": False, "build_dir": [0, 0, 1], "anchor_face_ids": [left]}
    if scen:
        loads["groups"] = scen[0]["groups"]
        loads["scenarios"] = scen
    else:
        loads["groups"] = alone["groups"]
    return {"model": "bar.stl", "material": "PLA", "mode": "minimize_plastic", "resolution": 32,
            "loads": loads, "lattice": {"topology": "octet"},
            "grading": {"topology": "octet", "cell_mm": 4.0, "min_extrudable_width_mm": 0.45},
            "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}}
runs = {"A_light_then_heavy": job([light, heavy]), "B_heavy_then_light": job([heavy, light]),
        "C_heavy_alone": job(None, heavy), "D_light_alone": job(None, light)}
for name, j in runs.items():
    p = os.path.join(out, name + ".json")
    json.dump(j, open(p, "w"), indent=1)
    o = os.path.join(out, "out_" + name)
    r = subprocess.run([cli, "run", p, "--out", o], capture_output=True, text=True, cwd=out)
    open(o + ".log", "w").write(r.stdout + r.stderr)
    print("==", name, "exit", r.returncode)
    for line in (r.stdout + r.stderr).split("\n"):
        if line.startswith("LATTICE") or "NO LATTICE" in line or "governs" in line.lower() or "[loadcase] load scenario" in line:
            print("  ", line[:260])

#!/usr/bin/env python3
"""R3 — THE FULL GATE TABLE WITH THE OPTION ARMED.
(task 2026-08-05-lattice-void-reaches-exterior)

    ./r3_gate_table.py <cli> <out-dir>

Every rung, its verdict and its margin, on the SAME binary with the check OFF
and then ON, plus the VOXEL-CLASSIFICATION FLIP COUNT between the two designs.

WITH THE OPTION OFF NOTHING MAY FLIP AT ALL — the check is a read-only walk over
a mask that is already final, so arming it must move no design, no margin and no
verdict. This script asserts that.

★ THE NEGATIVE-CONTROL FLOOR, because "0 flips" from a comparator that cannot
count is worth nothing. Two controls run first:

  C1 RESOLUTION. One voxel of the run's own design is nudged across the printed
     iso by 1e-9 and the comparator is required to report EXACTLY ONE flip. A
     comparator that missed it would report 0 for everything.
  C2 SENSITIVITY. Two DIFFERENT rungs of the same run are compared and the flip
     count is required to be large. A comparator that always reported 0 would
     pass C1's inverse but not this.

Only then is the armed-vs-unarmed 0 meaningful.
"""
import json, os, shutil, struct, subprocess, sys, time

CLI = sys.argv[1] if len(sys.argv) > 1 else "topopt-cli"
OUT = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "r3_out")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DEMO = os.path.join(REPO, "core", "tests", "fixtures", "demo")

os.makedirs(OUT, exist_ok=True)
shutil.copy(os.path.join(DEMO, "l-bracket.step"), OUT)

ISO = 0.5

BASE = {
    "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
    "resolution": 48, "simp": {"max_iterations": 14},
    "loads": {"anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
              "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]},
    # A lattice WITH a role region, and an OPEN one — a refused rung would give
    # the armed side no lattice artifacts to compare and make the table vacuous.
    "lattice": {"topology": "octet", "cell_mm": 8.0, "strut_radius_mm": 1.2,
                "emit_stl": True, "skin": "none",
                "regions": [{"role": "include", "kind": "face", "geometry": {
                    "origin": [-5.0, 0.0, 6.0], "normal": [0.0, 0.0, -1.0],
                    "half_u_mm": 8.0, "half_w_mm": 40.0, "depth_mm": 3.0}}]},
    "output": {"report": "report.json", "mesh_format": "stl",
               "mesh_prefix": "variant"},
}


def read_designs(path):
    """-> (meta, [(vf, [rho...]) ...]) from design.bin v1."""
    d = open(path, "rb").read()
    ver = d[0]
    assert ver == 1, f"design.bin version {ver} — this reader is v1 only"
    o = 4
    nx, ny, nz = struct.unpack_from("<3i", d, o); o += 12
    ox, oy, oz, sp = struct.unpack_from("<4d", d, o); o += 32
    vc, _ = struct.unpack_from("<2i", d, o); o += 8
    out = []
    for _ in range(vc):
        vf, avf, mwc, meff, vm = struct.unpack_from("<5d", d, o); o += 40
        acc, iters = struct.unpack_from("<2i", d, o); o += 8
        o += 24 + 8 + 8            # build dir, auto/baked flags, fingerprint
        (n,) = struct.unpack_from("<q", d, o); o += 8
        rho = struct.unpack_from(f"<{n}d", d, o); o += 8 * n
        out.append({"vf": vf, "achieved": avf, "margin": mwc, "margin_eff": meff,
                    "accepted": bool(acc), "iters": iters, "rho": rho})
    return {"nx": nx, "ny": ny, "nz": nz, "spacing": sp, "variants": vc}, out


def flips(a, b):
    """Voxel-CLASSIFICATION flips: voxels on opposite sides of the printed iso."""
    assert len(a) == len(b)
    return sum(1 for x, y in zip(a, b) if (x >= ISO) != (y >= ISO))


def run(job, sub):
    d = os.path.join(OUT, sub)
    shutil.rmtree(d, ignore_errors=True)
    json.dump(job, open(os.path.join(OUT, sub + ".json"), "w"), indent=1)
    t0 = time.time()
    r = subprocess.run([CLI, "run", sub + ".json", "--out", sub], cwd=OUT,
                       capture_output=True, text=True)
    open(os.path.join(OUT, sub + ".log"), "w").write(r.stdout + r.stderr)
    if r.returncode != 0:
        print(r.stderr[-2000:])
        sys.exit(f"run {sub} failed")
    return d, time.time() - t0


off_job = json.loads(json.dumps(BASE))
on_job = json.loads(json.dumps(BASE))
on_job["lattice"]["require_lattice_void_reaches_exterior"] = True

off_dir, off_wall = run(off_job, "off")
on_dir, on_wall = run(on_job, "on")

meta, off_v = read_designs(os.path.join(off_dir, "design.bin"))
_, on_v = read_designs(os.path.join(on_dir, "design.bin"))

print(f"grid {meta['nx']}x{meta['ny']}x{meta['nz']} @ {meta['spacing']:.4f} mm, "
      f"{meta['variants']} rungs, printed iso {ISO}")
print()

bad = False

# ── C1 RESOLUTION: one voxel nudged across the iso by 1e-9. ─────────────────
base = list(off_v[0]["rho"])
probe = list(base)
idx = next(i for i, x in enumerate(base) if x >= ISO)
probe[idx] = ISO - 1e-9
c1 = flips(base, probe)
print(f"C1 negative-control floor: one voxel moved {base[idx]:.12f} -> "
      f"{probe[idx]:.12f} (across the iso by 1e-9) => {c1} flip(s)")
if c1 != 1:
    print("   *** C1 FAILED: the comparator cannot resolve a 1e-9 crossing, so a "
          "0 below would mean nothing ***")
    bad = True

# ── C2 SENSITIVITY: two DIFFERENT rungs must differ a lot. ──────────────────
if len(off_v) >= 2:
    c2 = flips(off_v[0]["rho"], off_v[1]["rho"])
    print(f"C2 negative-control floor: rung {off_v[0]['vf']:.2f} vs rung "
          f"{off_v[1]['vf']:.2f} => {c2} flips")
    if c2 <= 0:
        print("   *** C2 FAILED: the comparator reports 0 for designs that are "
              "genuinely different ***")
        bad = True
else:
    print("C2 SKIPPED: fewer than two rungs")
print()

# ── THE GATE TABLE. ────────────────────────────────────────────────────────
def rungs(path):
    r = json.load(open(path))
    rows = list(r.get("variants") or []) + list(r.get("rejected_variants") or [])
    return {round(v["volume_fraction"], 6): v for v in rows}

off_rep = rungs(os.path.join(off_dir, "report.json"))
on_rep = rungs(os.path.join(on_dir, "report.json"))

print(f"{'rung':>6} {'margin OFF':>16} {'margin ON':>16} {'d margin':>12} "
      f"{'eff OFF':>14} {'eff ON':>14} {'verdict':>16} {'voxel flips':>12}")
print("-" * 112)
for k in sorted(off_rep, reverse=True):
    a, b = off_rep[k], on_rep.get(k)
    if b is None:
        print(f"{k:>6.2f}  *** RUNG MISSING ON THE ARMED SIDE ***")
        bad = True
        continue
    ma, mb = a["margin"]["worst_case"], b["margin"]["worst_case"]
    ea, eb = a["margin_effective"], b["margin_effective"]
    dm = mb - ma
    va, vb = bool(a["accepted"]), bool(b["accepted"])
    # report.json keys rows by the ACHIEVED volume fraction; design.bin stores
    # the REQUESTED ladder rung. Match on the nearest rung rather than on
    # equality, or every row would silently report "no design" (-1).
    fa = min(off_v, key=lambda v: abs(v["vf"] - k)) if off_v else None
    fb = min(on_v, key=lambda v: abs(v["vf"] - k)) if on_v else None
    if fa and abs(fa["vf"] - k) > 0.05: fa = None
    if fb and abs(fb["vf"] - k) > 0.05: fb = None
    fl = flips(fa["rho"], fb["rho"]) if (fa and fb) else -1
    mark = ""
    if va != vb:
        mark = "  *** VERDICT FLIP ***"; bad = True
    if dm != 0.0:
        mark += "  *** MARGIN MOVED ***"; bad = True
    if fl != 0:
        mark += f"  *** {fl} VOXELS FLIPPED ***"; bad = True
    print(f"{k:>6.2f} {ma:>16.9f} {mb:>16.9f} {dm:>12.3e} {ea:>14.9f} "
          f"{eb:>14.9f} {str(va) + '->' + str(vb):>16} {fl:>12}{mark}")

# ── THE LATTICE side: the composite margins must not move either. ──────────
print()
def lattice_margins(d):
    out = {}
    for f in sorted(os.listdir(d)):
        if f.endswith("_lattice.report.json"):
            r = json.load(open(os.path.join(d, f)))
            out[f] = (r["lattice_margin_worst_case"], r["lattice_margin_effective"],
                      r["lattice_accepted"], r["lattice_voxels"])
    return out

la, lb = lattice_margins(off_dir), lattice_margins(on_dir)
print(f"{'latticed variant':<34} {'composite OFF':>16} {'composite ON':>16} "
      f"{'accepted':>18} {'lattice voxels':>15}")
print("-" * 104)
for f in sorted(set(la) | set(lb)):
    A, B = la.get(f), lb.get(f)
    if A is None or B is None:
        print(f"{f:<34}  *** present on only one side ***"); bad = True; continue
    mark = ""
    if A[0] != B[0] or A[1] != B[1] or A[2] != B[2] or A[3] != B[3]:
        mark = "  *** THE COMPOSITE MOVED ***"; bad = True
    print(f"{f:<34} {A[0]:>16.9f} {B[0]:>16.9f} "
          f"{str(A[2]) + '->' + str(B[2]):>18} "
          f"{str(A[3]) + '->' + str(B[3]):>15}{mark}")

# ── the check's own cost, reported next to the run it protects. ────────────
ri = json.load(open(os.path.join(on_dir, "run_info.json")))
ve = (ri.get("lattice_export") or {}).get("void_escape") or {}
gen = (ri.get("lattice_export") or {}).get("gen_seconds")
print()
print(f"cost: the run took {on_wall:.1f} s wall (un-armed twin {off_wall:.1f} s); "
      f"lattice generation {gen} s; the void check "
      f"{ve.get('wall_seconds')} s over {ve.get('bfs_visits')} voxel pushes.")
print()
print("R3 " + ("PASS — every rung's verdict, both margins, the composite margins "
      "and\n       every voxel classification are UNCHANGED by arming the check, "
      "against\n       a comparator proven to resolve a 1e-9 iso crossing."
      if not bad else "FAIL — something moved."))
sys.exit(1 if bad else 0)

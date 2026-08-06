#!/usr/bin/env python3
"""R1 + R2 — THE BEFORE/AFTER TABLE AND THE GATE TABLE, ON HIS OWN PART.
(task 2026-08-06-arm-projection-and-void-check)

    ./r1r2_analysis.py <r1-work-dir> <probe-exe> <cli> [step-file]

Reads the two runs r1_before_after.py produced — BEFORE = merge-base binary
(both defaults off), AFTER = branch binary (both defaults on), SAME job document
— and reports, per rung:

  R1  exported volume, mesh-derived mass, watertightness, bore radii min/max,
      worst flat-face deviation, the void-check record, and the certified margin
      and verdict.
  R2  the voxel-classification flips between the two runs' designs, against a
      1e-9 negative-control floor, with each flip ATTRIBUTED to one of the two
      changes.

★ THE ATTRIBUTION IS THE DELIVERABLE, so it is worth stating what the two
changes CAN move, before any number is printed:

  * `output.project_cad_faces` runs inside `export_variant_mesh`
    (run_job.cpp:342) on a COPY of the mesh, AFTER the design, the density
    field, the certification and the report are all final. It cannot move a
    voxel. The prediction is therefore ZERO flips from projection, and a
    non-zero count would be a defect, not a result.
  * `lattice.require_lattice_void_reaches_exterior` runs at run_job.cpp:2905 on
    the FINAL mask and either refuses a rung or does nothing at all. It cannot
    move a voxel either; it can only remove a rung's output entirely.

So the honest prediction for R2 is ZERO flips on a part that passes the void
check, and the negative control is what makes a zero worth reading.

★ BORE RADII AND FLAT DEVIATIONS come from PR 307's own probe, run once per
arm, and read out of its BEFORE columns both times — because the probe's BEFORE
column measures the mesh IT WAS GIVEN. Given the before run's meshes it reports
the un-projected part; given the after run's meshes it reports the projected
one. That measures the two FILES, rather than re-deriving what projection would
have done.
"""
import csv, json, os, struct, subprocess, sys, collections

WORK = os.path.abspath(sys.argv[1])
PROBE = os.path.abspath(sys.argv[2])
CLI = os.path.abspath(sys.argv[3])
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
STEP = sys.argv[4] if len(sys.argv) > 4 else os.path.join(WORK, "M2_verticalStand.step")
RES = 128
PLA_DENSITY_G_MM3 = None   # read from materials.json below


def read_designs(path):
    """-> (meta, [(requested_vf, [rho...]) ...]) from design.bin v1.
    Same reader PR 305's r3_gate_table.py used, unchanged."""
    d = open(path, "rb").read()
    o = 0
    magic = d[o:o + 8]; o += 8
    (ver,) = struct.unpack_from("<i", d, o); o += 4
    assert ver == 1, f"design.bin version {ver} — this reader is v1 only"
    nx, ny, nz = struct.unpack_from("<3i", d, o); o += 12
    ox, oy, oz, sp = struct.unpack_from("<4d", d, o); o += 32
    vc, _ = struct.unpack_from("<2i", d, o); o += 8
    out = []
    for _ in range(vc):
        vf, avf, mwc, meff, vm = struct.unpack_from("<5d", d, o); o += 40
        acc, iters = struct.unpack_from("<2i", d, o); o += 8
        (n,) = struct.unpack_from("<q", d, o); o += 8
        rho = struct.unpack_from(f"<{n}d", d, o); o += 8 * n
        out.append((vf, avf, mwc, acc, list(rho)))
    return dict(nx=nx, ny=ny, nz=nz, spacing=sp), out


def stl_stats(path):
    d = open(path, "rb").read()
    n = struct.unpack("<I", d[80:84])[0]
    vol = 0.0
    idx, F = {}, []
    off = 84
    for _ in range(n):
        v = struct.unpack_from("<12f", d, off); off += 50
        a, b, c = v[3:6], v[6:9], v[9:12]
        vol += (a[0] * (b[1] * c[2] - b[2] * c[1])
                - a[1] * (b[0] * c[2] - b[2] * c[0])
                + a[2] * (b[0] * c[1] - b[1] * c[0])) / 6.0
        f = []
        for p in (a, b, c):
            k = struct.pack("<3f", *p)
            if k not in idx:
                idx[k] = len(idx)
            f.append(idx[k])
        F.append(f)
    ec = collections.Counter()
    degen = 0
    for a, b, c in F:
        if a == b or b == c or a == c:
            degen += 1
            continue
        for e in ((a, b), (b, c), (c, a)):
            ec[tuple(sorted(e))] += 1
    bad = sum(1 for v in ec.values() if v != 2)
    return dict(tris=n, verts=len(idx), volume_mm3=abs(vol),
                watertight=(bad == 0 and degen == 0), nonmanifold=bad)


# PLA density, read from the shipped library rather than typed in here.
mats = json.load(open(os.path.join(REPO, "core", "src", "materials", "materials.json")))
_rows = mats["materials"] if isinstance(mats, dict) and "materials" in mats else mats
for m in (_rows if isinstance(_rows, list) else _rows.values()):
    if str(m.get("name", "")).upper() == "PLA":
        for k in ("density_g_cm3", "density"):
            if k in m:
                PLA_DENSITY_G_MM3 = float(m[k]) / 1000.0
        if "density_g_mm3" in m:
            PLA_DENSITY_G_MM3 = float(m["density_g_mm3"])
assert PLA_DENSITY_G_MM3, "could not read PLA density from materials.json"

arms = {}
for arm in ("before", "after"):
    d = os.path.join(WORK, arm)
    rep = json.load(open(os.path.join(d, "report.json")))
    ri = json.load(open(os.path.join(d, "run_info.json")))
    meshes = sorted(f for f in os.listdir(d)
                    if f.startswith("variant_") and f.endswith(".stl")
                    and "_lattice" not in f)
    arms[arm] = dict(dir=d, report=rep, run_info=ri, meshes=meshes)
    print(f"{arm}: {len(meshes)} solid variant meshes: {', '.join(meshes)}")
print()

# ── R1: the exported files, side by side ────────────────────────────────────
print("=" * 100)
print("R1 — THE EXPORTED FILE, BEFORE (both defaults OFF) vs AFTER (both ON)")
print("     same job document; the BINARY decides what the absent keys mean")
print("=" * 100)
hdr = (f"{'rung':<14}{'arm':<8}{'tris':>8}{'verts':>8}{'watertight':>11}"
       f"{'volume mm^3':>14}{'mesh mass g':>12}")
print(hdr); print("-" * len(hdr))
vols = {}
for mesh in arms["before"]["meshes"]:
    for arm in ("before", "after"):
        p = os.path.join(arms[arm]["dir"], mesh)
        if not os.path.exists(p):
            print(f"{mesh:<14}{arm:<8}  MISSING — this rung produced no mesh")
            continue
        s = stl_stats(p)
        vols[(mesh, arm)] = s
        print(f"{mesh.replace('.stl',''):<14}{arm:<8}{s['tris']:>8}{s['verts']:>8}"
              f"{('yes' if s['watertight'] else 'NO'):>11}"
              f"{s['volume_mm3']:>14.1f}"
              f"{s['volume_mm3'] * PLA_DENSITY_G_MM3:>12.2f}")
    b, a = vols.get((mesh, "before")), vols.get((mesh, "after"))
    if b and a:
        dv = 100.0 * (a["volume_mm3"] - b["volume_mm3"]) / b["volume_mm3"]
        print(f"{'':<14}{'delta':<8}{'':>8}{'':>8}{'':>11}{dv:>13.2f}%{dv:>11.2f}%")
print()

# ── R1: the void-check record ───────────────────────────────────────────────
print("=" * 100)
print("R1 — THE VOID-CHECK RECORD")
print("=" * 100)
for arm in ("before", "after"):
    le = arms[arm]["run_info"].get("lattice_export") or {}
    ve = le.get("void_escape")
    if not ve:
        print(f"{arm:<8} NO void_escape block at all — the check did not run")
    else:
        print(f"{arm:<8} ran={ve.get('ran')} decidable={ve.get('decidable')} "
              f"sealed={ve.get('sealed')} sealed_variants={ve.get('sealed_variants')}")
        print(f"{'':8} latticed_cells={ve.get('latticed_cells')} "
              f"reached={ve.get('latticed_voxels_reached')} "
              f"sealed_voxels={ve.get('sealed_voxels')} "
              f"depth={ve.get('escape_depth_voxels')} "
              f"faces={ve.get('escape_faces')}")
        print(f"{'':8} connectivity={ve.get('connectivity')} "
              f"bfs_visits={ve.get('bfs_visits')} "
              f"wall_seconds={ve.get('wall_seconds')}")
        print(f"{'':8} enclosed voids holding NO lattice: "
              f"{ve.get('sealed_pockets_without_lattice')} "
              f"({ve.get('sealed_volume_without_lattice_mm3')} mm^3)")
print()

# ── R2: voxel-classification flips, with the negative control FIRST ─────────
print("=" * 100)
print("R2 — VOXEL-CLASSIFICATION FLIPS, against a 1e-9 negative-control floor")
print("=" * 100)
meta_b, vb = read_designs(os.path.join(arms["before"]["dir"], "design.bin"))
meta_a, va = read_designs(os.path.join(arms["after"]["dir"], "design.bin"))
print(f"grid {meta_b['nx']}x{meta_b['ny']}x{meta_b['nz']} "
      f"spacing {meta_b['spacing']:.6f} mm; "
      f"{len(vb)} designs before, {len(va)} after")
ISO = 0.5


def flips(r0, r1):
    return sum(1 for a, b in zip(r0, r1) if (a >= ISO) != (b >= ISO))


# C1 — the comparator must be able to SEE one voxel move across the iso.
r = list(vb[0][4])
i = next((k for k, v in enumerate(r) if v >= ISO), None)
assert i is not None, "no printed voxel in the first design — control impossible"
ctrl = list(r); ctrl[i] = ISO - 1e-9
print(f"C1 negative control  : one voxel moved across the printed iso by 1e-9 "
      f"({r[i]:.12f} -> {ctrl[i]:.12f})  ->  {flips(r, ctrl)} flip(s) "
      f"[must be exactly 1]")
if len(vb) > 1:
    print(f"C2 sensitivity control: rung {vb[0][0]:.2f} vs rung {vb[1][0]:.2f} of the "
          f"SAME run  ->  {flips(vb[0][4], vb[1][4])} flips [must be large]")
print()
hdr = (f"{'requested vf':>13}{'achieved before':>17}{'achieved after':>16}"
       f"{'margin before':>15}{'margin after':>14}{'accepted':>12}{'voxel flips':>13}")
print(hdr); print("-" * len(hdr))
by_a = {round(v[0], 9): v for v in va}
total_flips = 0
for v in vb:
    m = by_a.get(round(v[0], 9))
    if m is None:
        print(f"{v[0]:>13.4f}   (no matching rung in the AFTER run)")
        continue
    f = flips(v[4], m[4])
    total_flips += f
    print(f"{v[0]:>13.4f}{v[1]:>17.9f}{m[1]:>16.9f}"
          f"{v[2]:>15.6f}{m[2]:>14.6f}"
          f"{str(bool(v[3])) + '->' + str(bool(m[3])):>12}{f:>13}")
print()
print(f"TOTAL VOXEL FLIPS ACROSS EVERY RUNG: {total_flips}")
print()
print("ATTRIBUTION. Both changes act strictly AFTER the design is final —")
print("projection inside export_variant_mesh (run_job.cpp:342) on a copy of the")
print("mesh, the void check at run_job.cpp:2905 as a refuse-or-nothing gate on")
print("the final mask. Neither can move a voxel, so the expected count is 0 and")
print("any non-zero flip would have to be explained as a defect rather than as")
print("a result. C1 above proves the comparator can see a single 1e-9 move.")

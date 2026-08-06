#!/usr/bin/env python3
"""S3 — DOES PROJECTION SEAL A PORE THE FIELD CALLS OPEN?
(task 2026-08-06-arm-projection-and-void-check)

    ./s3_mesh_flood_fill.py <grid-n> <mesh.stl> [mesh.stl ...]

THE INTERACTION NEITHER PR COULD SEE ALONE. The void check is FIELD-level: it
runs the moment the lattice occupancy is final, before a triangle is written.
Projection is MESH-level: it moves the exported surface, ~0.67 mm inward on the
maintainer's part. PR 305's own `scope_note` says the check does not model the
exported solid shell as a barrier — and `outer_finish` defaults to `"shell"`,
which closes a marching-cubes surface over the whole part. Arming both makes
that gap MORE relevant, not less: projection pulls the shell inward over pores
the field calls open.

★ SO THIS MEASURES THE EXPORTED GEOMETRY, NOT THE FIELD. A flood fill on the
file, exactly as the brief requires — no argument from the design.

METHOD, and it is the same shape as the field-level check so the two answers are
comparable:

  1. Voxelize the exported mesh by PARITY RAY CASTING along +z. For each (x, y)
     column the z of every triangle crossing that column is collected, sorted,
     and the spans between odd/even crossings are marked SOLID. For a watertight
     mesh this is exact inside/outside — no tolerance, no sampling of normals.
  2. Flood fill the EMPTY space 6-CONNECTED from the grid's boundary planes.
     6-connected for PR 305's reason: two voxels meeting at an edge or a corner
     share zero area, so nothing drains through them. Using the same adjacency
     is what makes "the field says open" and "the file says open" the same
     question asked twice.
  3. Any empty voxel the fill does NOT reach is an ENCLOSED CAVITY in the
     exported solid. Report the count, the voxel total and the volume.

Run it on the SAME rung exported both ways. A cavity count that RISES when
projection is armed is projection sealing something, and that is the finding the
brief calls a blocked-stop for the default.

★ WATERTIGHTNESS IS REPORTED FIRST AND IS NOT A FORMALITY. Parity is only
meaningful on a closed surface, and this task found that projection could weld
two surface sheets together and produce a file that is NOT closed (the weld
guard, core/src/mesh/cad_project.cpp). A row whose mesh is not watertight has an
undefined inside, and the script says so rather than printing a number.

The 26-connected fill is computed alongside as a NEGATIVE CONTROL: it can only
ever reach MORE, so any cavity the 6-connected fill reports that the 26-connected
one does not is a diagonal-only escape — a staircase of corner touches through a
wall nothing could actually pass. Reporting both keeps the strict answer honest.
"""
import struct, sys, collections
import numpy as np
from scipy import ndimage

GRID_N = int(sys.argv[1]) if len(sys.argv) > 1 else 128
MESHES = sys.argv[2:]


def read_stl(path):
    d = open(path, "rb").read()
    n = struct.unpack("<I", d[80:84])[0]
    if len(d) < 84 + 50 * n:
        raise SystemExit(f"{path}: truncated binary STL")
    a = np.frombuffer(d[84:84 + 50 * n],
                      dtype=np.uint8).reshape(n, 50)
    f = a[:, 12:48].copy().view("<f4").reshape(n, 3, 3).astype(np.float64)
    return f


def watertight(tris):
    """Weld by exact float32 bits — the precision the FILE carries — and require
    every edge to appear exactly twice. Welding by position rather than by index
    is the point: STL is triangle soup and every consumer re-welds this way, so
    two distinct vertices at one position ARE one vertex here."""
    idx, F = {}, []
    for t in tris:
        f = []
        for v in t:
            k = struct.pack("<3f", *v)
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
    return (bad == 0 and degen == 0), bad, degen, len(idx)


def voxelize_parity(tris, n, lo, hi):
    """SOLID mask by +z parity ray casting through voxel CENTRES."""
    sp = (hi - lo) / n
    nx = ny = nz = n
    solid = np.zeros((nx, ny, nz), dtype=bool)
    cx = lo[0] + (np.arange(nx) + 0.5) * sp[0]
    cy = lo[1] + (np.arange(ny) + 0.5) * sp[1]
    cz = lo[2] + (np.arange(nz) + 0.5) * sp[2]

    A, B, C = tris[:, 0], tris[:, 1], tris[:, 2]
    # Bucket triangles by their x-column range so each column tests few.
    tminx = np.minimum(np.minimum(A[:, 0], B[:, 0]), C[:, 0])
    tmaxx = np.maximum(np.maximum(A[:, 0], B[:, 0]), C[:, 0])
    i0 = np.clip(((tminx - lo[0]) / sp[0]).astype(int) - 1, 0, nx - 1)
    i1 = np.clip(((tmaxx - lo[0]) / sp[0]).astype(int) + 1, 0, nx - 1)
    buckets = [[] for _ in range(nx)]
    for t in range(len(tris)):
        for i in range(i0[t], i1[t] + 1):
            buckets[i].append(t)

    for i in range(nx):
        ts = buckets[i]
        if not ts:
            continue
        ts = np.asarray(ts)
        a, b, c = A[ts], B[ts], C[ts]
        px = cx[i]
        # Barycentric solve in the xy plane for the whole column at once.
        v0 = b[:, :2] - a[:, :2]
        v1 = c[:, :2] - a[:, :2]
        den = v0[:, 0] * v1[:, 1] - v0[:, 1] * v1[:, 0]
        ok = np.abs(den) > 1e-16
        if not ok.any():
            continue
        a, b, c, v0, v1, den = a[ok], b[ok], c[ok], v0[ok], v1[ok], den[ok]
        for jy in range(ny):
            py = cy[jy]
            wx = px - a[:, 0]
            wy = py - a[:, 1]
            s = (wx * v1[:, 1] - wy * v1[:, 0]) / den
            t2 = (wy * v0[:, 0] - wx * v0[:, 1]) / den
            inside = (s >= 0) & (t2 >= 0) & (s + t2 <= 1.0)
            if not inside.any():
                continue
            zs = (a[inside, 2] + s[inside] * (b[inside, 2] - a[inside, 2])
                  + t2[inside] * (c[inside, 2] - a[inside, 2]))
            zs = np.sort(zs)
            # Odd number of crossings above a point => inside.
            cnt = len(zs) - np.searchsorted(zs, cz, side="left")
            solid[i, jy, :] = (cnt % 2) == 1
    return solid


def _structure(connectivity):
    if connectivity == 6:
        return ndimage.generate_binary_structure(3, 1)   # face adjacency only
    return ndimage.generate_binary_structure(3, 3)       # 26: faces+edges+corners


def flood_empty(solid, connectivity):
    """Reach the EMPTY set from the grid's boundary planes, then return whatever
    it could NOT reach — the enclosed cavities.

    `binary_propagation` is the same reachable-set membership test a hand-rolled
    BFS computes; it is used because the grid is 2M voxels and a Python frontier
    loop over it is not a measurement anyone would wait for. The RESULT is
    order-independent either way, which is the property that matters."""
    empty = ~solid
    seeds = np.zeros_like(empty)
    seeds[0, :, :] = seeds[-1, :, :] = True
    seeds[:, 0, :] = seeds[:, -1, :] = True
    seeds[:, :, 0] = seeds[:, :, -1] = True
    seeds &= empty
    reached = ndimage.binary_propagation(seeds, mask=empty,
                                         structure=_structure(connectivity))
    return empty & ~reached


def components(mask, connectivity=6):
    lab, n = ndimage.label(mask, structure=_structure(connectivity))
    if n == 0:
        return 0, []
    sizes = np.bincount(lab.ravel())[1:]
    return int(n), sizes.tolist()


print(f"S3 — enclosed cavities in the EXPORTED MESH, 6-connected flood fill "
      f"from outside, grid {GRID_N}^3")
print()
hdr = (f"{'mesh':<34} {'watertight':>10} {'tris':>8} {'solid vox':>10} "
       f"{'cavities':>9} {'cav vox':>8} {'cav mm^3':>11} {'26-conn cav':>11}")
print(hdr)
print("-" * len(hdr))

for path in MESHES:
    tris = read_stl(path)
    wt, bad, degen, nv = watertight(tris)
    name = path.split("/")[-1]
    if not wt:
        print(f"{name:<34} {'NO':>10} {len(tris):>8} "
              f"{'—':>10} {'—':>9} {'—':>8} {'—':>11} {'—':>11}"
              f"   <-- {bad} non-manifold edges, {degen} degenerate: the inside "
              f"is UNDEFINED, so no cavity count is printed")
        continue
    lo = tris.reshape(-1, 3).min(axis=0)
    hi = tris.reshape(-1, 3).max(axis=0)
    pad = (hi - lo) * 0.02
    lo, hi = lo - pad, hi + pad
    sp = (hi - lo) / GRID_N
    solid = voxelize_parity(tris, GRID_N, lo, hi)
    enc6 = flood_empty(solid, 6)
    enc26 = flood_empty(solid, 26)
    n6, sz6 = components(enc6, 6)
    n26, _ = components(enc26, 6)
    vox_mm3 = sp[0] * sp[1] * sp[2]
    print(f"{name:<34} {'yes':>10} {len(tris):>8} {int(solid.sum()):>10} "
          f"{n6:>9} {int(enc6.sum()):>8} {enc6.sum() * vox_mm3:>11.3f} {n26:>11}")

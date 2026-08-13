#!/usr/bin/env python3
"""★ A SECOND, INDEPENDENT IMPLEMENTATION OF THE TOPOLOGY COUNTERS, USED ONCE.

This is NOT the shipped number and must never become one — `plsm_void_topology`
is. It exists because those counters are brand new, they are computed by a
union-find and an alternating sum that are easy to get subtly wrong, and the unit
test only exercises them on a 9^3 block whose answer is arithmetic. A defect that
only shows on a real design with 22,480 void voxels in 16 components would have
survived that test.

So this recomputes b0, chi, b2 and the sealed count on the SAME field with
different code — BFS instead of union-find, an explicit cell enumeration instead
of the anchored scan — and the two are compared. Agreement is the check; a
disagreement means the shipped one is wrong and the arms cannot be read.

    python3 crosscheck_topology.py <part_solid_mask.npy-free> ...

Takes the same `<prefix>.f64` files `plsm_topology_probe` takes, plus the grid
dimensions, and the IN-PART mask as a raw uint8 file (written by
`--dump-in-part`). Slow — minutes on 468k voxels — which is exactly why it is a
one-off cross-check and not an instrument.
"""
import sys
from collections import deque


def load_f64(path, n):
    import struct
    with open(path, "rb") as f:
        b = f.read()
    if len(b) != n * 8:
        raise SystemExit(f"{path}: {len(b)} bytes, expected {n*8}")
    return struct.unpack(f"<{n}d", b)


def main():
    if len(sys.argv) < 6:
        raise SystemExit(
            "usage: crosscheck_topology.py <nx> <ny> <nz> <in_part.u8> <field.f64>")
    nx, ny, nz = (int(sys.argv[i]) for i in (1, 2, 3))
    n = nx * ny * nz
    with open(sys.argv[4], "rb") as f:
        in_part = f.read()
    if len(in_part) != n:
        raise SystemExit("in-part mask is the wrong size")
    occ = load_f64(sys.argv[5], n)

    def at(i, j, k):
        return i + nx * (j + ny * k)

    printed = [occ[v] > 0.5 for v in range(n)]
    isvoid = [bool(in_part[v]) and not printed[v] for v in range(n)]
    escape = [not printed[v] for v in range(n)]

    def bfs_components(mask, nbrs26=False):
        seen = [False] * n
        comps = []
        offs = []
        if nbrs26:
            for dk in (-1, 0, 1):
                for dj in (-1, 0, 1):
                    for di in (-1, 0, 1):
                        if di or dj or dk:
                            offs.append((di, dj, dk))
        else:
            offs = [(-1, 0, 0), (1, 0, 0), (0, -1, 0),
                    (0, 1, 0), (0, 0, -1), (0, 0, 1)]
        for k0 in range(nz):
            for j0 in range(ny):
                for i0 in range(nx):
                    v0 = at(i0, j0, k0)
                    if not mask[v0] or seen[v0]:
                        continue
                    comp = []
                    q = deque([(i0, j0, k0)])
                    seen[v0] = True
                    while q:
                        i, j, k = q.popleft()
                        comp.append((i, j, k))
                        for di, dj, dk in offs:
                            a, b, c = i + di, j + dj, k + dk
                            if not (0 <= a < nx and 0 <= b < ny and 0 <= c < nz):
                                continue
                            w = at(a, b, c)
                            if mask[w] and not seen[w]:
                                seen[w] = True
                                q.append((a, b, c))
                    comps.append(comp)
        return comps

    void_comps = bfs_components(isvoid)
    esc_comps = bfs_components(escape)
    # which escape components reach a boundary plane
    open_esc = set()
    for idx, comp in enumerate(esc_comps):
        for (i, j, k) in comp:
            if i in (0, nx - 1) or j in (0, ny - 1) or k in (0, nz - 1):
                open_esc.add(idx)
                break
    esc_of = {}
    for idx, comp in enumerate(esc_comps):
        for p in comp:
            esc_of[p] = idx
    sealed_pockets = 0
    sealed_voxels = 0
    for comp in void_comps:
        if esc_of[comp[0]] not in open_esc:
            sealed_pockets += 1
            sealed_voxels += len(comp)

    # b2 — solid islands, 26-connected, reaching neither the grid boundary nor
    # an out-of-part voxel.
    solid = [bool(in_part[v]) and printed[v] for v in range(n)]
    b2 = 0
    for comp in bfs_components(solid, nbrs26=True):
        unbounded = False
        for (i, j, k) in comp:
            if i in (0, nx - 1) or j in (0, ny - 1) or k in (0, nz - 1):
                unbounded = True
                break
            for di, dj, dk in ((-1, 0, 0), (1, 0, 0), (0, -1, 0),
                               (0, 1, 0), (0, 0, -1), (0, 0, 1)):
                if not in_part[at(i + di, j + dj, k + dk)]:
                    unbounded = True
                    break
            if unbounded:
                break
        if not unbounded:
            b2 += 1

    # chi, by explicit cell enumeration over the void set.
    def vox(i, j, k):
        return (0 <= i < nx and 0 <= j < ny and 0 <= k < nz and isvoid[at(i, j, k)])

    V = E = F = C = 0
    for k in range(nz + 1):
        for j in range(ny + 1):
            for i in range(nx + 1):
                if any(vox(i + di, j + dj, k + dk)
                       for di in (-1, 0) for dj in (-1, 0) for dk in (-1, 0)):
                    V += 1
                if i < nx and any(vox(i, j + dj, k + dk)
                                  for dj in (-1, 0) for dk in (-1, 0)):
                    E += 1
                if j < ny and any(vox(i + di, j, k + dk)
                                  for di in (-1, 0) for dk in (-1, 0)):
                    E += 1
                if k < nz and any(vox(i + di, j + dj, k)
                                  for di in (-1, 0) for dj in (-1, 0)):
                    E += 1
                if i < nx and j < ny and (vox(i, j, k) or vox(i, j, k - 1)):
                    F += 1
                if i < nx and k < nz and (vox(i, j, k) or vox(i, j - 1, k)):
                    F += 1
                if j < ny and k < nz and (vox(i, j, k) or vox(i - 1, j, k)):
                    F += 1
                if i < nx and j < ny and k < nz and vox(i, j, k):
                    C += 1
    chi = V - E + F - C
    print(f"b0={len(void_comps)} chi={chi} b2={b2} "
          f"b1={len(void_comps) + b2 - chi} "
          f"sealed_pockets={sealed_pockets} sealed_voxels={sealed_voxels} "
          f"void_voxels={sum(1 for x in isvoid if x)}")


main()

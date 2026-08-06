#!/usr/bin/env python3
"""SECTION A, the ISOLATION question, done properly.

a0_reproduce_stl.py decided "shares space with a real body" by bounding-box overlap.
That is far too coarse here: both real bodies span almost the whole part, so every
fragment's box overlaps them and the test reports zero isolated fragments. A box test
can only OVER-report sharing, so that zero was a lower bound, not an answer.

This asks the physical question instead. A fragment SHARES SPACE with a real body if
its material overlaps that body's material:

  * against the SOLID COMPANION (a closed body): point-in-solid by ray casting along
    +X, counting crossings. A fragment with any vertex inside the companion is
    absorbed into the print.
  * against the STRUT NETWORK (an open interpenetrating soup of capsules, for which
    ray casting is meaningless): proximity. A fragment vertex within one strut RADIUS
    of a strut-network vertex is inside strut material. The radius is read from the
    run's own run_info (strut_radius_max_mm), never guessed.

A fragment that fails BOTH tests is loose in air: it is what drops off the plate.

    python3 a0b_isolated_fragments.py <mesh.stl> <run_info.json>
"""
import json
import struct
import sys

import numpy as np
from scipy.spatial import cKDTree


def read_binary_stl(path):
    with open(path, "rb") as f:
        data = f.read()
    n = struct.unpack("<I", data[80:84])[0]
    raw = np.frombuffer(data, dtype=np.uint8, count=n * 50, offset=84).reshape(n, 50)
    floats = raw[:, :48].copy().view(np.float32).reshape(n, 12)
    return floats[:, 3:12].reshape(n, 3, 3).astype(np.float64)


def components(tris):
    n = len(tris)
    q = np.round(tris.reshape(-1, 3) / 1e-4).astype(np.int64)
    _, vid = np.unique(q, axis=0, return_inverse=True)
    vid = vid.reshape(n, 3)
    parent = np.arange(int(vid.max()) + 1)

    def find(a):
        root = a
        while parent[root] != root:
            root = parent[root]
        while parent[a] != root:
            parent[a], a = root, parent[a]
        return root

    for a, b in ((0, 1), (1, 2), (2, 0)):
        for u, v in zip(vid[:, a], vid[:, b]):
            ru, rv = find(int(u)), find(int(v))
            if ru != rv:
                parent[rv] = ru
    return np.array([find(int(v)) for v in vid[:, 0]])


def inside_solid(points, tris):
    """Point-in-mesh by +X ray casting. `tris` must be a closed body."""
    v0, v1, v2 = tris[:, 0], tris[:, 1], tris[:, 2]
    # Pre-project to the YZ plane; only triangles whose YZ box contains the point
    # can be crossed by a +X ray through it.
    ylo = np.minimum(np.minimum(v0[:, 1], v1[:, 1]), v2[:, 1])
    yhi = np.maximum(np.maximum(v0[:, 1], v1[:, 1]), v2[:, 1])
    zlo = np.minimum(np.minimum(v0[:, 2], v1[:, 2]), v2[:, 2])
    zhi = np.maximum(np.maximum(v0[:, 2], v1[:, 2]), v2[:, 2])
    xhi = np.maximum(np.maximum(v0[:, 0], v1[:, 0]), v2[:, 0])

    out = np.zeros(len(points), dtype=bool)
    for i, p in enumerate(points):
        cand = ((ylo <= p[1]) & (yhi >= p[1]) & (zlo <= p[2]) & (zhi >= p[2])
                & (xhi >= p[0]))
        idx = np.flatnonzero(cand)
        if idx.size == 0:
            continue
        a, b, c = v0[idx], v1[idx], v2[idx]
        # Barycentric test in YZ, then require the crossing to be ahead in +X.
        d = ((b[:, 1] - a[:, 1]) * (c[:, 2] - a[:, 2])
             - (c[:, 1] - a[:, 1]) * (b[:, 2] - a[:, 2]))
        ok = np.abs(d) > 1e-12
        if not ok.any():
            continue
        a, b, c, d = a[ok], b[ok], c[ok], d[ok]
        u = ((p[1] - a[:, 1]) * (c[:, 2] - a[:, 2])
             - (c[:, 1] - a[:, 1]) * (p[2] - a[:, 2])) / d
        v = ((b[:, 1] - a[:, 1]) * (p[2] - a[:, 2])
             - (p[1] - a[:, 1]) * (b[:, 2] - a[:, 2])) / d
        hit = (u >= 0) & (v >= 0) & (u + v <= 1)
        if not hit.any():
            continue
        xa, xb, xc = a[hit, 0], b[hit, 0], c[hit, 0]
        uu, vv = u[hit], v[hit]
        xs = xa + uu * (xb - xa) + vv * (xc - xa)
        out[i] = int(np.count_nonzero(xs > p[0])) % 2 == 1
    return out


def main():
    mesh, info = sys.argv[1], sys.argv[2]
    tris = read_binary_stl(mesh)
    roots = components(tris)
    labels, counts = np.unique(roots, return_counts=True)
    order = np.argsort(-counts)
    labels, counts = labels[order], counts[order]

    radius = json.load(open(info))["lattice_export"]["strut_radius_max_mm"]
    print(f"strut radius from run_info: {radius} mm")
    print(f"components: {len(labels)}   fragments (excluding the 2 real bodies): "
          f"{len(labels) - 2}")

    strut_tris = tris[roots == labels[0]]
    solid_tris = tris[roots == labels[1]]
    strut_tree = cKDTree(strut_tris.reshape(-1, 3))
    solid_tree = cKDTree(solid_tris.reshape(-1, 3))

    isolated, shares_solid, shares_strut = [], 0, 0
    for lab, cnt in zip(labels[2:], counts[2:]):
        pts = np.unique(tris[roots == lab].reshape(-1, 3), axis=0)
        near_strut = strut_tree.query(pts, distance_upper_bound=radius)[0]
        if np.isfinite(near_strut).any():
            shares_strut += 1
            continue
        # Touching the companion's SURFACE counts as sharing too — a fragment welded
        # against the solid skin is printed as part of it.
        near_solid = solid_tree.query(pts, distance_upper_bound=radius)[0]
        if np.isfinite(near_solid).any():
            shares_solid += 1
            continue
        if inside_solid(pts, solid_tris).any():
            shares_solid += 1
            continue
        isolated.append((int(lab), int(cnt)))

    print(f"  shares space with the STRUT network : {shares_strut}")
    print(f"  shares space with the SOLID body    : {shares_solid}")
    print(f"  FULLY ISOLATED IN AIR               : {len(isolated)}")
    if isolated:
        tot = sum(c for _, c in isolated)
        print(f"  isolated triangle total             : {tot}")
        print(f"  isolated sizes (largest 12)         : "
              f"{sorted((c for _, c in isolated), reverse=True)[:12]}")


if __name__ == "__main__":
    main()

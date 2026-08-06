#!/usr/bin/env python3
"""SECTION A REPRODUCTION — the shipped mesh of the maintainer's overnight run.

Binary STL parse + union-find over WELDED vertices (quantized to 1e-4 mm, which is
far below the 0.5 mm print resolution and far above float32 STL round-off), then:

  * connected-component count and per-component triangle counts;
  * which components are FULLY ISOLATED IN AIR — i.e. share no space with any other
    body — versus which merely overlap one. The export is deliberately
    interpenetrating soup (lattice_export.interpenetrating_soup is true), so
    OVERLAPPING stubs are expected and fine; ISOLATED ones are loose fragments that
    would drop off the plate.

"Shares space with a real body" is decided by axis-aligned bounding-box overlap
against the two large bodies. A box test can only OVER-count sharing (two boxes can
overlap while the geometry does not), so the isolated count it reports is a LOWER
BOUND on the true number of loose fragments. That is the conservative direction for
a bar that must drive the count to zero.

    python3 a0_reproduce_stl.py <mesh.stl>
"""
import struct
import sys

import numpy as np


def read_binary_stl(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 84:
        raise SystemExit(f"{path}: too short to be a binary STL")
    n = struct.unpack("<I", data[80:84])[0]
    if len(data) != 84 + n * 50:
        raise SystemExit(
            f"{path}: not a binary STL (header says {n} tris => "
            f"{84 + n * 50} bytes, file is {len(data)})")
    # 50 bytes per facet: 12 floats (normal + 3 verts) + 2-byte attribute.
    raw = np.frombuffer(data, dtype=np.uint8, count=n * 50, offset=84)
    raw = raw.reshape(n, 50)
    floats = raw[:, :48].copy().view(np.float32).reshape(n, 12)
    return floats[:, 3:12].reshape(n, 3, 3).astype(np.float64)


class DSU:
    def __init__(self, n):
        self.p = np.arange(n)

    def find(self, a):
        p = self.p
        root = a
        while p[root] != root:
            root = p[root]
        while p[a] != root:  # path compression
            p[a], a = root, p[a]
        return root

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[rb] = ra


def main():
    path = sys.argv[1]
    tris = read_binary_stl(path)
    n = len(tris)
    print(f"file       : {path}")
    print(f"triangles  : {n}")

    # WELD: quantize vertices and map identical positions to one id.
    q = np.round(tris.reshape(-1, 3) / 1e-4).astype(np.int64)
    _, vid = np.unique(q, axis=0, return_inverse=True)
    vid = vid.reshape(n, 3)
    print(f"welded vertices: {vid.max() + 1}")

    dsu = DSU(int(vid.max()) + 1)
    for a, b in ((0, 1), (1, 2), (2, 0)):
        for u, v in zip(vid[:, a], vid[:, b]):
            dsu.union(int(u), int(v))

    roots = np.array([dsu.find(int(v)) for v in vid[:, 0]])
    labels, counts = np.unique(roots, return_counts=True)
    order = np.argsort(-counts)
    labels, counts = labels[order], counts[order]
    print(f"connected components: {len(labels)}")
    print()
    print("largest components (triangles):")
    for i in range(min(6, len(labels))):
        print(f"  #{i}: {counts[i]}")

    # The two REAL bodies are the two large ones; everything else is a fragment.
    big = labels[:2]
    big_boxes = []
    for lab in big:
        v = tris[roots == lab].reshape(-1, 3)
        big_boxes.append((v.min(axis=0), v.max(axis=0)))
    print()
    for i, (lo, hi) in enumerate(big_boxes):
        print(f"body {i}: {counts[i]} tris  bbox min {np.round(lo, 3)}  "
              f"max {np.round(hi, 3)}")

    small = labels[2:]
    small_counts = counts[2:]
    under100 = small_counts < 100
    print()
    print(f"components under 100 triangles: {int(under100.sum())}, "
          f"{int(small_counts[under100].sum())} triangles total")

    # ISOLATED vs OVERLAPPING, by bbox against the two real bodies.
    isolated = 0
    sharing = 0
    for lab in small:
        v = tris[roots == lab].reshape(-1, 3)
        lo, hi = v.min(axis=0), v.max(axis=0)
        hit = any((lo <= bhi).all() and (hi >= blo).all()
                  for blo, bhi in big_boxes)
        if hit:
            sharing += 1
        else:
            isolated += 1
    print(f"of {len(small)} fragments: {sharing} share space with a real body, "
          f"{isolated} FULLY ISOLATED IN AIR")

    # Where the strut network starts, relative to the whole mesh envelope.
    allv = tris.reshape(-1, 3)
    mlo, mhi = allv.min(axis=0), allv.max(axis=0)
    print()
    print(f"mesh envelope  min {np.round(mlo, 3)}  max {np.round(mhi, 3)}")
    print(f"mesh size mm   {np.round(mhi - mlo, 1)}")
    for i, (lo, hi) in enumerate(big_boxes):
        print(f"body {i} inset from -X face: {lo[0] - mlo[0]:.1f} mm, "
              f"above bottom (-Z): {lo[2] - mlo[2]:.1f} mm")


if __name__ == "__main__":
    main()

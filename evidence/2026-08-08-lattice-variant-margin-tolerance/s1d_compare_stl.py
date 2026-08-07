#!/usr/bin/env python3
"""How far apart are the eagerly-written mesh and the on-demand one?

S3 turns on this: "regenerable" is only as good as what comes back. The two
files have the same byte COUNT (same triangle count), so this walks them
triangle by triangle and reports the largest coordinate difference, in mm and
relative to the voxel spacing.

Binary STL: 80-byte header, u32 count, then per triangle 12 f32 (normal + 3
vertices) + u16 attr = 50 bytes.
"""
import struct
import sys

A, B = sys.argv[1], sys.argv[2]
SPACING = 1.705279303  # his run's voxel edge, mm


def tris(path):
    f = open(path, "rb")
    f.read(80)
    n = struct.unpack("<I", f.read(4))[0]
    return f, n


fa, na = tris(A)
fb, nb = tris(B)
print(f"triangles: {na} vs {nb}")
assert na == nb, "different triangle counts — not comparable vertex by vertex"

CH = 50 * 20000
worst_v = 0.0
worst_n = 0.0
differing_tris = 0
identical = 0
done = 0
while done < na:
    k = min(20000, na - done)
    ba = fa.read(50 * k)
    bb = fb.read(50 * k)
    if ba == bb:
        identical += k
        done += k
        continue
    for t in range(k):
        ra = ba[t * 50:t * 50 + 50]
        rb = bb[t * 50:t * 50 + 50]
        if ra == rb:
            identical += 1
            continue
        differing_tris += 1
        va = struct.unpack("<12f", ra[:48])
        vb = struct.unpack("<12f", rb[:48])
        for i in range(3):
            worst_n = max(worst_n, abs(va[i] - vb[i]))
        for i in range(3, 12):
            worst_v = max(worst_v, abs(va[i] - vb[i]))
    done += k

print(f"identical triangles : {identical} ({100.0 * identical / na:.4f} %)")
print(f"differing triangles : {differing_tris} ({100.0 * differing_tris / na:.4f} %)")
print(f"worst vertex coordinate difference : {worst_v:.6g} mm "
      f"({worst_v / SPACING:.3g} of a voxel)")
print(f"worst normal component difference  : {worst_n:.6g}")

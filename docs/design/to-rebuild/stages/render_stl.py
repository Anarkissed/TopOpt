#!/usr/bin/env python3
"""Draw one or more STL files side by side, each from two sides, shaded by a fixed light.

    python3 render_stl.py out.png "title A" a.stl ["title B" b.stl ...]

For the stage reports' pictures (the maintainer: pictures over numbers; a file that
passes every number check can still look wrong, so every feature is drawn from both
sides). Binary STL only. Triangles are drawn back to front per view (painter's order
by the triangle's depth), which is exact enough for a look and wrong at interlocking
surfaces; it is a quick look, not a render.
"""
import struct
import sys

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection


def read_stl(path):
    d = open(path, "rb").read()
    n = struct.unpack("<I", d[80:84])[0]
    t = np.frombuffer(d[84:84 + 50 * n], dtype=np.dtype([("n", "<3f4"), ("v", "<9f4"), ("a", "<u2")]))
    return t["v"].reshape(n, 3, 3).astype(float)


def view(ax, tris, az_deg, el_deg, title):
    az, el = np.radians(az_deg), np.radians(el_deg)
    # Camera axes: right, up, toward the viewer.
    fwd = np.array([np.cos(el) * np.cos(az), np.cos(el) * np.sin(az), np.sin(el)])
    right = np.array([-np.sin(az), np.cos(az), 0.0])
    up = np.cross(fwd, right)
    nrm = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    ln = np.linalg.norm(nrm, axis=1)
    ok = ln > 0
    tris, nrm = tris[ok], nrm[ok] / ln[ok, None]
    facing = nrm @ fwd > 0
    tris, nrm = tris[facing], nrm[facing]
    depth = tris.mean(axis=1) @ fwd
    order = np.argsort(depth)
    tris, nrm = tris[order], nrm[order]
    light = np.array([0.35, -0.5, 0.8])
    light = light / np.linalg.norm(light)
    shade = 0.35 + 0.65 * np.clip(nrm @ light, 0, 1)
    xy = np.stack([tris @ right, tris @ up], axis=2)
    cols = np.stack([0.72 * shade, 0.78 * shade, 0.86 * shade, np.ones_like(shade)], axis=1)
    ax.add_collection(PolyCollection(xy, facecolors=cols, edgecolors="none", antialiaseds=False))
    lo, hi = xy.reshape(-1, 2).min(axis=0), xy.reshape(-1, 2).max(axis=0)
    c, r = 0.5 * (lo + hi), 0.55 * (hi - lo).max()
    ax.set_xlim(c[0] - r, c[0] + r)
    ax.set_ylim(c[1] - r, c[1] + r)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(title, fontsize=9)


def main():
    out, rest = sys.argv[1], sys.argv[2:]
    items = [(rest[i], rest[i + 1]) for i in range(0, len(rest), 2)]
    fig, axes = plt.subplots(2, len(items), figsize=(4.2 * len(items), 8.0), squeeze=False)
    for k, (title, path) in enumerate(items):
        tris = read_stl(path)
        view(axes[0][k], tris, -60, 25, title + "\nfront")
        view(axes[1][k], tris, 120, 25, "back")
    fig.savefig(out, dpi=120, bbox_inches="tight")
    print("wrote", out)


if __name__ == "__main__":
    main()

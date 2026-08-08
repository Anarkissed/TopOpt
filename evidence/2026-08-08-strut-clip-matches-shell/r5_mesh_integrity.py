#!/usr/bin/env python3
"""R5 — MESH INTEGRITY UNCHANGED: do not trade a protrusion for a fragment.

    python3 r5_mesh_integrity.py <before.stl> <after.stl> <line_width_mm>

THE QUESTION. Clipping struts to a surface that sits INSIDE the old one removes
material near the boundary. Removing material near the boundary is exactly how a
strut that used to reach a neighbour stops reaching it — i.e. how a fix for
protruding teeth becomes a fix that ships loose fragments instead. So the bar is
not "the protrusion went to zero", it is "the protrusion went to zero AND nothing
came loose".

THE METHOD is the one already established for this repo, reused rather than
reinvented (evidence/2026-08-05-lattice-cell-size-adaptation/a0_reproduce_stl.py
and a0b_isolated_fragments.py):

  * connected components by union-find over vertices welded at 1e-4 mm — far
    below the print resolution, far above float32 STL round-off;
  * a component is ISOLATED when no vertex of it comes within `line_width_mm` of
    any vertex of either of the two large bodies (the strut network and the solid
    shell/companion). ★ THE THRESHOLD IS THE JOB'S OWN LINE WIDTH, per this task's
    R5, and it is the physically meaningful test: "will this fuse to anything
    during the print". The cell-size-adaptation handoff §A measured how violently
    this count moves with the threshold, which is why the threshold is named in
    the output and swept below rather than left implicit.

Both files are measured the same way and reported side by side. What matters is
the DELTA: an after-count above the before-count is the trade this bar forbids.
"""
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
    """Union-find over vertices welded at 1e-4 mm; returns a root label per tri."""
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

    for t in vid:
        r0 = find(t[0])
        for v in t[1:]:
            r1 = find(v)
            if r0 != r1:
                parent[r1] = r0
    return np.array([find(t[0]) for t in vid])


def report(path, thr):
    tris = read_binary_stl(path)
    roots = components(tris)
    labels, counts = np.unique(roots, return_counts=True)
    order = np.argsort(-counts)
    labels, counts = labels[order], counts[order]
    out = {
        "path": path,
        "triangles": int(len(tris)),
        "components": int(len(labels)),
        "largest": [int(c) for c in counts[:4]],
    }
    if len(labels) < 3:
        out["isolated"] = 0
        out["sweep"] = {}
        return out
    # The two largest components are the real bodies (the strut network and the
    # shell / solid companion); everything else is a candidate fragment.
    big = [cKDTree(tris[roots == labels[i]].reshape(-1, 3)) for i in (0, 1)]
    frags = [np.unique(tris[roots == lab].reshape(-1, 3), axis=0) for lab in labels[2:]]

    def isolated_at(t):
        n = 0
        for pts in frags:
            if any(np.isfinite(b.query(pts, distance_upper_bound=t)[0]).any()
                   for b in big):
                continue
            n += 1
        return n

    out["fragments"] = len(frags)
    out["isolated"] = isolated_at(thr)
    # The count is extremely threshold-sensitive (handoff §A), so it is swept and
    # not reported as one number pretending to be definitive.
    out["sweep"] = {f"{t:.3f}": isolated_at(t)
                    for t in (1e-9, 0.1, 0.25, thr, 0.5, 1.0)}
    return out


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    before, after, thr = sys.argv[1], sys.argv[2], float(sys.argv[3])
    print(f"R5 mesh integrity — isolation threshold = the job's own line width "
          f"{thr:.3f} mm\n")
    rows = [report(before, thr), report(after, thr)]
    for tag, r in zip(("BEFORE", "AFTER "), rows):
        print(f"{tag}  {r['path']}")
        print(f"        triangles          {r['triangles']}")
        print(f"        components         {r['components']}")
        print(f"        largest components {r['largest']}")
        print(f"        fragments          {r.get('fragments', 0)}")
        print(f"        ISOLATED @{thr:.3f}mm {r['isolated']}")
        print(f"        sweep              {r['sweep']}")
        print()
    d_comp = rows[1]["components"] - rows[0]["components"]
    d_iso = rows[1]["isolated"] - rows[0]["isolated"]
    print(f"DELTA   components {d_comp:+d}   isolated {d_iso:+d}")
    print("BAR     isolated must not INCREASE — a protrusion may not be traded "
          "for a loose fragment.")
    print("VERDICT " + ("HOLDS" if d_iso <= 0 else "★ FAILS"))
    return 0 if d_iso <= 0 else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""R5 — DOES THE EMITTED LATTICE PERCOLATE?

    python3 r5_percolation.py <mesh.stl> <run_info.json | job.json> [more.stl ...]

TWO NUMBERS, and they answer different questions:

  * CONNECTED COMPONENTS of the emitted mesh. A lattice is one interpenetrating
    strut soup plus (usually) one solid companion body, so 2 is the healthy count
    and anything above it is fragments.
  * ISOLATED COMPONENTS — components that share no space with any other body. Those
    are what drops off the plate. This must be ZERO.

THE THRESHOLD IS THE RUN'S OWN LINE WIDTH (run_info `wall_line_width_mm`, or a
job's `loads.wall_line_width_mm`), never a
literal and never a strut radius: two bodies closer than one extruded line weld
together when printed. Handoff 2026-08-05-lattice-cell-size-adaptation measured how
threshold-dependent this count is on the maintainer's mesh — 843 fragments at 0 mm,
128 at 0.45 mm, 9 at one strut radius — which is exactly why the definition is
pinned here and read from the job.
"""
import json
import struct
import sys

import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
from scipy.spatial import cKDTree


def read_binary_stl(path):
    with open(path, "rb") as f:
        data = f.read()
    n = struct.unpack("<I", data[80:84])[0]
    raw = np.frombuffer(data, dtype=np.uint8, count=n * 50, offset=84).reshape(n, 50)
    floats = raw[:, :48].copy().view(np.float32).reshape(n, 12)
    return floats[:, 3:12].reshape(n, 3, 3).astype(np.float64)


def components(tris):
    """Union-find over welded vertices; returns a root label per triangle.

    scipy's connected_components over the sparse edge graph, not a Python loop: a
    fit-mode lattice at the finest printable cell runs to millions of triangles and a
    per-edge Python loop does not finish on one.
    """
    n = len(tris)
    q = np.round(tris.reshape(-1, 3) / 1e-4).astype(np.int64)
    _, vid = np.unique(q, axis=0, return_inverse=True)
    vid = vid.reshape(n, 3)
    nv = int(vid.max()) + 1
    rows = np.concatenate([vid[:, 0], vid[:, 1], vid[:, 2]])
    cols = np.concatenate([vid[:, 1], vid[:, 2], vid[:, 0]])
    g = coo_matrix((np.ones(len(rows), dtype=np.int8), (rows, cols)),
                   shape=(nv, nv))
    _, lab = connected_components(g, directed=False)
    return lab[vid[:, 0]]


def line_width_mm(path):
    """The welding threshold, READ — from the run's own run_info.json (the value the
    run actually used) or from a job's `loads.wall_line_width_mm`. Never invented: a
    file that states neither is an error, because the count is strongly threshold-
    dependent (843 fragments at 0 mm vs 128 at 0.45 mm on the maintainer's mesh)."""
    j = json.load(open(path))
    w = j.get("wall_line_width_mm")
    if w is None:
        w = (j.get("loads") or {}).get("wall_line_width_mm")
    if w is None or not float(w) > 0.0:
        raise SystemExit(
            f"{path} states no wall_line_width_mm — refusing to invent a welding "
            "threshold. The definition is DECIDED; it must be read.")
    return float(w)


def report(mesh, weld):
    tris = read_binary_stl(mesh)
    if len(tris) == 0:
        print(f"{mesh}: EMPTY MESH (0 triangles)")
        return 0
    roots = components(tris)
    labels, counts = np.unique(roots, return_counts=True)
    order = np.argsort(-counts)
    labels, counts = labels[order], counts[order]
    print(f"{mesh}")
    print(f"  triangles            : {len(tris)}")
    print(f"  connected components : {len(labels)}   (sizes: "
          f"{', '.join(str(int(c)) for c in counts[:6])}"
          f"{' ...' if len(counts) > 6 else ''})")
    if len(labels) == 1:
        print("  isolated components  : 0   (a single body cannot be isolated "
              "from itself)")
        return 0
    trees = [cKDTree(np.unique(tris[roots == lab].reshape(-1, 3), axis=0))
             for lab in labels]
    pts = [np.unique(tris[roots == lab].reshape(-1, 3), axis=0) for lab in labels]
    isolated = []
    for i, lab in enumerate(labels):
        shares = False
        for k in range(len(labels)):
            if k == i:
                continue
            d = trees[k].query(pts[i], distance_upper_bound=weld)[0]
            if np.isfinite(d).any():
                shares = True
                break
        if not shares:
            isolated.append((int(lab), int(counts[i])))
    print(f"  weld threshold       : {weld} mm (the job's wall_line_width_mm)")
    print(f"  isolated components  : {len(isolated)}"
          + ("" if not isolated
             else "   sizes " + ", ".join(str(c) for _, c in isolated)))
    return len(isolated)


def main():
    mesh_args = [a for a in sys.argv[1:] if a.endswith(".stl")]
    job = [a for a in sys.argv[1:] if a.endswith(".json")]
    if not mesh_args or not job:
        raise SystemExit(__doc__)
    weld = line_width_mm(job[0])
    bad = 0
    for m in mesh_args:
        bad += report(m, weld)
        print()
    print("R5 PASS — nothing is loose." if bad == 0
          else f"R5 FAIL — {bad} isolated component(s).")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

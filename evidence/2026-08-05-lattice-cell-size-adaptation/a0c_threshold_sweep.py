#!/usr/bin/env python3
"""How sensitive is the ISOLATED-fragment count to the definition of "shares space"?

a0b reports 4 fully isolated fragments; the amendment's section A reports 123. Before
calling that a non-reproduction, this asks whether the gap is definitional — i.e.
whether a stricter notion of "touching" moves 4 towards 123. It sweeps the proximity
threshold from exact coincidence to twice the strut radius.
"""
import importlib.util
import sys

import numpy as np
from scipy.spatial import cKDTree

spec = importlib.util.spec_from_file_location("a0b", "a0b_isolated_fragments.py")
a0b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a0b)

MESH = "/Users/nadim/.topopt-worker/7ba2442960a24050/out/variant_068_lattice.stl"
tris = a0b.read_binary_stl(MESH)
roots = a0b.components(tris)
labels, counts = np.unique(roots, return_counts=True)
order = np.argsort(-counts)
labels, counts = labels[order], counts[order]

strut = tris[roots == labels[0]]
solid = tris[roots == labels[1]]
st = cKDTree(strut.reshape(-1, 3))
so = cKDTree(solid.reshape(-1, 3))
frags = [np.unique(tris[roots == lab].reshape(-1, 3), axis=0) for lab in labels[2:]]

print(f"fragments: {len(frags)}   strut radius: 1.095372083 mm")
print(f"{'threshold_mm':>14} {'isolated':>9}  (isolated = touches neither body "
      f"within threshold, ignoring containment)")
for thr in [1e-9, 0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 1.0, 1.095372083, 1.5, 2.0]:
    iso = 0
    for pts in frags:
        if np.isfinite(st.query(pts, distance_upper_bound=thr)[0]).any():
            continue
        if np.isfinite(so.query(pts, distance_upper_bound=thr)[0]).any():
            continue
        iso += 1
    print(f"{thr:>14.6f} {iso:>9}")

# Containment matters only at the strict end: a fragment fully INSIDE the solid body
# touches nothing yet shares space with it.
inside = 0
for pts in frags:
    if np.isfinite(st.query(pts, distance_upper_bound=1e-9)[0]).any():
        continue
    if np.isfinite(so.query(pts, distance_upper_bound=1e-9)[0]).any():
        continue
    if a0b.inside_solid(pts, solid).any():
        inside += 1
print()
print(f"of the strict-threshold isolated set, {inside} are actually INSIDE the "
      f"solid companion (share space, touch nothing)")

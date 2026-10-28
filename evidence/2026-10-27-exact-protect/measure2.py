"""Vertex-based measures (vertices sit ON the true surface; facet centres sit inside a circle).
bore: circle fit to the vertices of hole-wall facets in the middle 80 % → diameter, out-of-round; open: 5 points on the axis
inside the exported solid (ray parity) must be 0. flat: every vertex in the face's slabs (shrunk 1 mm in-plane) within ±2 mm
of the CAD plane, whatever its facet's angle → peak-to-peak height (bumps included)."""
import json, sys, math
import numpy as np
sys.path.insert(0, sys.argv[4]); from measure import load_stl, basis

def inside(tris, p):
    d = np.array([0.5773, 0.5774, 0.5775]); d /= np.linalg.norm(d)
    a, b, c = tris[:, 0], tris[:, 1], tris[:, 2]
    e1, e2 = b - a, c - a; h = np.cross(d, e2); det = (e1 * h).sum(1); ok = abs(det) > 1e-12
    s = p - a; u = (s * h).sum(1) / np.where(ok, det, 1); q = np.cross(s, e1)
    v = (q @ d) / np.where(ok, det, 1); t = (e2 * q).sum(1) / np.where(ok, det, 1)
    return int((ok & (u >= 0) & (u <= 1) & (v >= 0) & (u + v <= 1) & (t > 1e-9)).sum()) % 2 == 1

def bore(tris, f):
    p0 = np.array(f['axis_point'], float); d, u, v = basis(np.array(f['axis_dir'], float)); r = f['radius_mm']
    reg = [g for g in f['regions'] if g['shape'] == 'cylinder'][0]
    ax = reg['axis']; lo, hi = sorted([(reg['min'][ax] - p0[ax]) * np.sign(d[ax]), (reg['max'][ax] - p0[ax]) * np.sign(d[ax])])
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]); nl = np.linalg.norm(n, axis=1)
    c = tris.mean(1) - p0; x, y, t = c @ u, c @ v, c @ d; rad = np.hypot(x, y)
    nn = n / np.maximum(nl, 1e-12)[:, None]
    toward = ((nn @ u) * x + (nn @ v) * y) / np.maximum(rad, 1e-9) < -0.3
    m0, m1 = lo + 0.1 * (hi - lo), hi - 0.1 * (hi - lo)
    sel = (nl > 1e-12) & (abs(rad - r) < 1.5) & (t > m0) & (t < m1) & toward
    if sel.sum() < 6: return {'points': int(sel.sum())}
    V = tris[sel].reshape(-1, 3) - p0; X, Y = V @ u, V @ v
    A = np.stack([X, Y, np.ones_like(X)], 1); cx, cy, k = np.linalg.lstsq(A, X * X + Y * Y, rcond=None)[0]
    rf = math.sqrt(k + (cx / 2) ** 2 + (cy / 2) ** 2); dev = np.hypot(X - cx / 2, Y - cy / 2) - rf
    filled = sum(inside(tris, p0 + d * (lo + (hi - lo) * s)) for s in (0.2, 0.35, 0.5, 0.65, 0.8))
    return {'diameter': 2 * rf, 'cad': 2 * r, 'out_of_round': float(dev.max() - dev.min()), 'axis_points_inside_solid': filled}

def flat(tris, f):
    n0 = np.array(f['plane_normal'], float); n0 /= np.linalg.norm(n0); o = np.array(f['plane_origin'], float)
    ax = int(np.argmax(abs(n0))); oth = [i for i in range(3) if i != ax]
    boxes = [(np.array(g['min']), np.array(g['max'])) for g in f['regions'] if 'min' in g]
    V = tris.reshape(-1, 3); h = (V - o) @ n0; m = abs(h) < 2.0
    inb = np.zeros(len(V), bool)
    for lo, hi in boxes:
        k = np.ones(len(V), bool)
        for i in oth: k &= (V[:, i] > lo[i] + 1.0) & (V[:, i] < hi[i] - 1.0)
        inb |= k
    sel = m & inb
    if sel.sum() < 3: return {'vertices': int(sel.sum())}
    return {'vertices': int(sel.sum()), 'flatness_pp': float(h[sel].max() - h[sel].min()), 'max_off_plane': float(abs(h[sel]).max())}

faces = json.load(open(sys.argv[1]))['faces']
M = {k: load_stl(p) for k, p in zip(['today', 'exact'], sys.argv[2:4])}
out = []
for f in faces:
    if not f['regions']: continue
    kind = 'bore' if f['kind'] == 'cylinder' else 'flat'
    out.append({'face': f['face'], 'kind': kind, **{k: (bore(m, f) if kind == 'bore' else flat(m, f)) for k, m in M.items()}})
print(json.dumps(out, default=float))

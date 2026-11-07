"""Measure an exported STL against the CAD: a protected bore's fitted diameter and a protected flat face's flatness.

usage: python3 -I measure.py faces.json today.stl exact.stl
Prints one table: for each bore/plane region, today's number and the exact export's, side by side.
"""
import json, struct, sys, math
import numpy as np


def load_stl(path):
    data = open(path, 'rb').read()
    if data[:5] == b'solid' and b'facet' in data[:400]:
        v = []
        for line in data.decode('ascii', 'ignore').splitlines():
            s = line.split()
            if s and s[0] == 'vertex':
                v.append([float(s[1]), float(s[2]), float(s[3])])
        return np.array(v).reshape(-1, 3, 3)
    n = struct.unpack('<I', data[80:84])[0]
    a = np.frombuffer(data[84:84 + n * 50], dtype=np.dtype([('n', '<f4', 3), ('v', '<f4', 9), ('a', '<u2')]))
    return a['v'].reshape(-1, 3, 3).astype(float)


def basis(d):
    d = d / np.linalg.norm(d)
    seed = np.array([1.0, 0, 0]) if abs(d[0]) < 0.9 else np.array([0, 1.0, 0])
    u = seed - d * seed.dot(d); u /= np.linalg.norm(u)
    return d, u, np.cross(d, u)


def bore(tris, f):
    """Fitted diameter of the exported surface on the bore: triangle-centroid points within ±1.5 mm of the CAD radius,
    in the middle 80 % of the bore's length, whose normals face the axis (the hole's own wall)."""
    p0 = np.array(f['axis_point'], float); d, u, v = basis(np.array(f['axis_dir'], float))
    r = f['radius_mm']
    span = None
    for reg in f['regions']:
        if 'axis' in reg:
            ax = reg['axis']
            ts = sorted([(reg['min'][ax] - p0[ax]) * np.sign(d[ax]), (reg['max'][ax] - p0[ax]) * np.sign(d[ax])])
            span = ts
    if span is None:
        return None
    c = tris.mean(axis=1)
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    area = np.linalg.norm(n, axis=1); ok = area > 1e-12
    q = c - p0
    t = q @ d
    span_lo, span_hi = span
    mid_lo = span_lo + 0.1 * (span_hi - span_lo); mid_hi = span_hi - 0.1 * (span_hi - span_lo)
    x, y = q @ u, q @ v
    rad = np.hypot(x, y)
    radial = np.stack([x, y], 1) / np.maximum(rad, 1e-9)[:, None]
    nn = n / np.maximum(area, 1e-12)[:, None]
    toward = (np.stack([nn @ u, nn @ v], 1) * radial).sum(1) < -0.3
    sel = ok & (abs(rad - r) < 1.5) & (t > mid_lo) & (t < mid_hi) & toward
    if sel.sum() < 6:
        return {'points': int(sel.sum())}
    X, Y = x[sel], y[sel]
    A = np.stack([X, Y, np.ones_like(X)], 1); b = X * X + Y * Y
    cx, cy, k = np.linalg.lstsq(A, b, rcond=None)[0]
    rf = math.sqrt(k + (cx / 2) ** 2 + (cy / 2) ** 2)
    dev = np.hypot(X - cx / 2, Y - cy / 2) - rf
    return {'points': int(sel.sum()), 'diameter': 2 * rf, 'cad': 2 * r, 'err': 2 * rf - 2 * r,
            'roundness_pp': float(dev.max() - dev.min())}


def flat(tris, f):
    """Flatness of the exported surface on the face: triangles whose normal is the face's (±10°), whose centroid lies
    inside one of the face's slabs shrunk by 1 mm in-plane, within ±1.5 mm of the plane; the peak-to-peak height of
    their vertices from the CAD plane."""
    n0 = np.array(f['plane_normal'], float); n0 /= np.linalg.norm(n0)
    o = np.array(f['plane_origin'], float)
    boxes = [(np.array(r['min']), np.array(r['max'])) for r in f['regions'] if r['shape'] == 'box' and 'min' in r]
    if not boxes:
        return None
    ax = int(np.argmax(abs(n0)))
    c = tris.mean(axis=1)
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    a = np.linalg.norm(n, axis=1); ok = a > 1e-12
    nn = n / np.maximum(a, 1e-12)[:, None]
    facing = abs(nn @ n0) > math.cos(math.radians(10))
    near = abs((c - o) @ n0) < 1.5
    inside = np.zeros(len(c), bool)
    oth = [i for i in range(3) if i != ax]
    for lo, hi in boxes:
        m = np.ones(len(c), bool)
        for i in oth:
            m &= (c[:, i] > lo[i] + 1.0) & (c[:, i] < hi[i] - 1.0)
        inside |= m
    sel = ok & facing & near & inside
    if sel.sum() < 3:
        return {'triangles': int(sel.sum())}
    h = ((tris[sel].reshape(-1, 3) - o) @ n0)
    return {'triangles': int(sel.sum()), 'flatness_pp': float(h.max() - h.min()), 'mean_offset': float(h.mean())}


def main():
    faces = json.load(open(sys.argv[1]))['faces']
    meshes = {name: load_stl(path) for name, path in zip(['today', 'exact'], sys.argv[2:4])}
    rows = []
    for f in faces:
        if not f['regions']:
            continue
        for reg in f['regions']:
            if 'axis' in reg:
                f['_axis'] = reg['axis']
        kind = 'bore' if f['kind'] == 'cylinder' else 'plane'
        res = {k: (bore(m, f) if kind == 'bore' else flat(m, f)) for k, m in meshes.items()}
        rows.append({'face': f['face'], 'kind': kind, **res})
    print(json.dumps(rows, indent=1, default=float))


if __name__ == '__main__':
    main()

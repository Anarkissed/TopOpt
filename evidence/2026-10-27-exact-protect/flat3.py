"""Flatness by SAMPLING the surface: a 2 mm grid over each slab (shrunk 1 mm), a ray down the face normal from 3 mm
outside; the first hit's height from the CAD plane. Peak-to-peak and the largest step off the plane, over all samples."""
import json, sys
import numpy as np
sys.path.insert(0, sys.argv[4]); from measure import load_stl
def first_hit(tris, p, d):
    a, b, c = tris[:, 0], tris[:, 1], tris[:, 2]; e1, e2 = b - a, c - a; h = np.cross(d, e2); det = (e1 * h).sum(1)
    ok = abs(det) > 1e-12; det = np.where(ok, det, 1); s = p - a; u = (s * h).sum(1) / det; q = np.cross(s, e1)
    v = (q @ d) / det; t = (e2 * q).sum(1) / det; m = ok & (u >= 0) & (u <= 1) & (v >= 0) & (u + v <= 1) & (t > 1e-9)
    return t[m].min() if m.any() else None
faces = json.load(open(sys.argv[1]))['faces']; M = {k: load_stl(p) for k, p in zip(['today', 'exact'], sys.argv[2:4])}
for f in faces:
    if f['kind'] != 'plane' or not f['regions']: continue
    n0 = np.array(f['plane_normal'], float); n0 /= np.linalg.norm(n0); o = np.array(f['plane_origin'], float)
    ax = int(np.argmax(abs(n0))); oth = [i for i in range(3) if i != ax]
    pts = []
    for g in f['regions']:
        lo, hi = np.array(g['min']), np.array(g['max'])
        for a in np.arange(lo[oth[0]] + 1, hi[oth[0]] - 1 + 1e-9, 2.0):
            for b in np.arange(lo[oth[1]] + 1, hi[oth[1]] - 1 + 1e-9, 2.0):
                p = o.copy(); p[oth[0]] = a; p[oth[1]] = b; pts.append(p)
    row = [f['face'], len(pts)]
    for k in ('today', 'exact'):
        T = M[k]; tri_near = T[np.abs(((T.mean(1) - o) @ n0)) < 6]
        hs = []
        for p in pts:
            t = first_hit(tri_near, p + n0 * 3, -n0)
            if t is not None and t < 6: hs.append(3 - t)
        hs = np.array(hs)
        row += [len(hs), round(float(hs.max() - hs.min()), 4) if len(hs) else None, round(float(abs(hs).max()), 4) if len(hs) else None]
    print('flat %4d samples %4d | today hit %4d pp %s max off %s | exact hit %4d pp %s max off %s' % tuple(row))

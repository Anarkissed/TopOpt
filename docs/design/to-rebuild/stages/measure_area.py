# usage: measure_area.py part.stl file.stl [...]
# TOReview's 3 mm patch test (local quadric fit, worst residual per patch), made fair to
# meshes of any tessellation: the surface is sampled EVENLY BY AREA (not at corners), and
# each patch is classed by where it lies: DRAWN (90 %+ of its points within 0.05 mm of
# the drawn part's surface), CUT (90 %+ farther: the optimiser's own surface) or SEAM.
# Sharp patches (normals spread over 35 deg) are counted apart, as in measure_surface.py.
import numpy as np, struct, sys, json
from scipy.spatial import cKDTree


def load(p):
    b = open(p, 'rb').read(); n = struct.unpack('<I', b[80:84])[0]
    return np.frombuffer(b, dtype=np.dtype([('n', '<f4', 3), ('v', '<f4', (3, 3)), ('a', '<u2')]),
                         count=n, offset=84)['v'].astype(float)


def area_samples(T, spacing, rng):
    n = np.cross(T[:, 1] - T[:, 0], T[:, 2] - T[:, 0]); a = 0.5 * np.linalg.norm(n, axis=1)
    ok = a > 0; T, n, a = T[ok], n[ok], a[ok]; n /= (2 * a)[:, None]
    N = int(a.sum() / spacing ** 2); i = rng.choice(len(T), N, p=a / a.sum())
    u = rng.random(N); v = rng.random(N); f = u + v > 1; u[f] = 1 - u[f]; v[f] = 1 - v[f]
    return T[i, 0] + u[:, None] * (T[i, 1] - T[i, 0]) + v[:, None] * (T[i, 2] - T[i, 0]), n[i]


rng = np.random.default_rng(1)
Pp, _ = area_samples(load(sys.argv[1]), 0.05, rng); ptree = cKDTree(Pp)
for f in sys.argv[2:]:
    X, N = area_samples(load(f), 0.25, rng)
    d, _ = ptree.query(X, distance_upper_bound=1.0); drawn = d < 0.05
    tree = cKDTree(X); S = rng.choice(len(X), min(4000, len(X)), replace=False)
    res = {'DRAWN': [], 'CUT': [], 'SEAM': []}; sharp = 0
    for s in S:
        nb = tree.query_ball_point(X[s], 3.0)
        if len(nb) < 30: continue
        Q = X[nb] - X[s]; Nn = N[nb]
        # orient normals consistently with the patch's mean before testing the spread
        n0 = Nn.mean(0); n0 /= max(np.linalg.norm(n0), 1e-12)
        if np.degrees(np.arccos(np.clip(Nn @ n0, -1, 1))).max() > 35: sharp += 1; continue
        a = np.cross(n0, [1, 0, 0]) if abs(n0[0]) < 0.9 else np.cross(n0, [0, 1, 0]); a /= np.linalg.norm(a)
        b = np.cross(n0, a); x = Q @ a; y = Q @ b; z = Q @ n0
        A = np.c_[x * x, x * y, y * y, x, y, np.ones_like(x)]
        co, *_ = np.linalg.lstsq(A, z, rcond=None); r = np.abs(z - A @ co).max()
        fr = drawn[nb].mean(); res['DRAWN' if fr >= 0.9 else ('CUT' if fr <= 0.1 else 'SEAM')].append(r)
    out = {'file': '/'.join(f.split('/')[-3:]), 'sharp': sharp}
    for k, v in res.items():
        v = np.array(v)
        out[k] = {'n': len(v)} if len(v) == 0 else {
            'n': len(v), 'median': round(float(np.median(v)), 3), 'p90': round(float(np.percentile(v, 90)), 3),
            'max': round(float(v.max()), 3), 'over0.05': round(float((v > 0.05).mean()), 2)}
    print(json.dumps(out)); sys.stdout.flush()

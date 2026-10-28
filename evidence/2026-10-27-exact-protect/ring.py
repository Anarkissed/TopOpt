import sys, numpy as np, math
sys.path.insert(0, '/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad/exact')
from measure import load_stl
def first_hit(tris, p, d):
    a, b, c = tris[:, 0], tris[:, 1], tris[:, 2]; e1, e2 = b - a, c - a; h = np.cross(d, e2); det = (e1 * h).sum(1)
    ok = abs(det) > 1e-12; det = np.where(ok, det, 1); s = p - a; u = (s * h).sum(1) / det; q = np.cross(s, e1)
    v = (q @ d) / det; t = (e2 * q).sum(1) / det; m = ok & (u >= 0) & (u <= 1) & (v >= 0) & (u + v <= 1) & (t > 1e-9)
    return t[m].min() if m.any() else None
for name, path in (('today', sys.argv[1]), ('exact', sys.argv[2])):
    T = load_stl(path)
    for face, z, n, cx in ((118, 136, 1, -40.17), (116, 136, 1, 40.17), (40, 106, -1, -40.17), (14, 106, -1, 40.17)):
        n0 = np.array([0, 0, n], float); near = T[np.abs(T.mean(1)[:, 2] - z) < 6]; hs = []
        for r in np.linspace(4.85, 5.8, 5):
            for a in np.linspace(0, 2 * math.pi, 48, endpoint=False):
                p = np.array([cx + r * math.cos(a), 54.55 + r * math.sin(a), z]); t = first_hit(near, p + n0 * 3, -n0)
                if t is not None and t < 6: hs.append(3 - t)
        hs = np.array(hs); print(name, face, 'samples', len(hs), 'pp', round(float(hs.max() - hs.min()), 4))

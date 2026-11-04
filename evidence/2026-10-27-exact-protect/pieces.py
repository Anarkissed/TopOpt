import sys, numpy as np
sys.path.insert(0, '/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad/exact'); from measure import load_stl
T = load_stl(sys.argv[1]); V = T.reshape(-1, 3); key = np.round(V * 1e4).astype(np.int64)
_, inv = np.unique(key, axis=0, return_inverse=True); inv = inv.reshape(-1, 3)
par = list(range(inv.max() + 1))
def f(x):
    while par[x] != x: par[x] = par[par[x]]; x = par[x]
    return x
for a, b, c in inv:
    ra = f(a); par[f(b)] = ra; par[f(c)] = ra
lab = np.array([f(a) for a, b, c in inv])
for r in sorted(set(lab), key=lambda r: -(lab == r).sum())[1:]:
    P = T[lab == r].reshape(-1, 3); lo, hi = P.min(0), P.max(0)
    print('piece', (lab == r).sum(), 'tris  centre', np.round((lo + hi) / 2, 2), 'size', np.round(hi - lo, 2))

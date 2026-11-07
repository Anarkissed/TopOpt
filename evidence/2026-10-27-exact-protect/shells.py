import sys, numpy as np
sys.path.insert(0, '/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad/exact'); from measure import load_stl
for path in sys.argv[1:]:
    T = load_stl(path); V = T.reshape(-1, 3); key = np.round(V * 1e4).astype(np.int64)
    _, inv = np.unique(key, axis=0, return_inverse=True); inv = inv.reshape(-1, 3)
    par = list(range(inv.max() + 1))
    def f(x):
        while par[x] != x: par[x] = par[par[x]]; x = par[x]
        return x
    for a, b, c in inv:
        ra = f(a); par[f(b)] = ra; par[f(c)] = ra
    lab = np.array([f(a) for a, b, c in inv])
    vol = {}
    for r in set(lab):
        t = T[lab == r]; vol[r] = float(np.einsum('ij,ij->i', t[:, 0], np.cross(t[:, 1], t[:, 2])).sum() / 6)
    bodies = [v for v in vol.values() if v > 0]; voids = [v for v in vol.values() if v < 0]
    print(path.split('/')[-1], 'bodies', len(bodies), [round(v) for v in bodies], '| sealed voids', len(voids), [round(v) for v in voids])

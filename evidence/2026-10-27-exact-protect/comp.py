import sys, numpy as np
sys.path.insert(0, '/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad/exact'); from measure import load_stl
for p in sys.argv[1:]:
    T = load_stl(p); V = T.reshape(-1, 3); key = np.round(V * 1e4).astype(np.int64)
    _, inv = np.unique(key, axis=0, return_inverse=True); inv = inv.reshape(-1, 3)
    par = list(range(inv.max() + 1))
    def f(x):
        while par[x] != x: par[x] = par[par[x]]; x = par[x]
        return x
    for a, b, c in inv:
        ra, rb, rc = f(a), f(b), f(c); par[rb] = ra; par[f(rc)] = ra
    roots = {}
    for a, b, c in inv: r = f(a); roots[r] = roots.get(r, 0) + 1
    print(p.split('/')[-1], 'triangles', len(T), 'pieces', len(roots), 'sizes', sorted(roots.values(), reverse=True)[:6])

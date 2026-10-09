# Independent cross-check of the band101 emptied counts: Python slab test (core's region_contains
# face branch, no seam flare) over design.bin; part-solid inside the slab proxied by rung-0.68 solid
# (core counted 0 emptied there).
import json, sys, numpy as np
sys.path.insert(0, sys.argv[1])
from readdesign import read
S = sys.argv[2]
dump = json.load(open(S + '/dump/sync-68BF7B74-3C2A-4ED6-A46D-AC040A9CA649.json'))
prisms = [r for r in dump['lattice']['regions'] if r.get('face_id') == 23]
D = read(S + '/standvar/run/design.bin'); A = read(sys.argv[3])
nx, ny, nz, o, h = D['nx'], D['ny'], D['nz'], np.array(D['o']), D['h']
I, J, K = np.meshgrid(np.arange(nx), np.arange(ny), np.arange(nz), indexing='ij')
P = np.stack([o[0] + (I + .5) * h, o[1] + (J + .5) * h, o[2] + (K + .5) * h], -1).reshape(-1, 3)
flat = (I + nx * (J + ny * K)).reshape(-1)          # x fastest
def pip(a, b, loops):
    inside = np.zeros(a.shape, bool)
    for L in loops:
        L = np.array(L); n = len(L)
        for i in range(n):
            xi, yi = L[i]; xj, yj = L[i - 1]
            c = (yi > b) != (yj > b)
            x = xj + (b - yj) * (xi - xj) / np.where(yi - yj == 0, 1e-300, yi - yj)
            inside ^= c & (a < x)
    return inside
def slab(dmax, dmin=-1e-12):
    m = np.zeros(len(P), bool)
    for r in prisms:
        g = r['geometry']; n = np.array(g['normal']); u = np.array(g['frame_u']); w = np.array(g['frame_w'])
        rel = P - np.array(g['origin']); s = rel @ n; du = rel @ u; dw = rel @ w
        ok = (s >= 0) & (s <= dmax) & (s > dmin) & (np.abs(du) <= g['half_u_mm']) & (np.abs(dw) <= g['half_w_mm'])
        m |= ok & pip(du, dw, g['outline_uv'])
    return m
print('prisms', len(prisms), [p['geometry']['depth_mm'] for p in prisms], 'frame keys', sorted(prisms[0]['geometry'].keys()))
for name, sel in [('slab 24.15', slab(24.15)), ('band (20,24.15]', slab(24.15, 20.0))]:
    for tag, des in [('before', D), ('after', A)]:
        d = [v['d'][flat] for v in des['v']]
        part = sel & (d[0] >= 0.5) if tag == 'before' else sel & (D['v'][0]['d'][flat] >= 0.5)
        print(tag, name, 'geom', sel.sum(), 'solid@before0.68', part.sum(),
              'emptied per rung', [int((part & (x < 0.5)).sum()) for x in d])

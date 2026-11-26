# usage: slope_at_file.py out_dir vf_tag   -> slope of phi (mm/mm) at the file's corners where |phi| <= 0.01 mm
# Rebuilds phi from variant_<tag>_alpha.f64 + .meta (cubic B-spline tensor basis, peak 1).
import sys, struct, numpy as np
d, tag = sys.argv[1], sys.argv[2]
meta = {}
for ln in open(f'{d}/variant_{tag}_alpha.meta'):
    if ln.startswith('#') or not ln.strip(): continue
    k, *v = ln.split(); meta[k] = v
kv = float(meta['knots_vox'][0]); sup = float(meta['support_vox'][0]) / kv
mx, my, mz = (int(x) for x in meta['counts']); pad = int(meta['pad'][0])
h = float(meta['spacing'][0]); o = np.array([float(meta[k][0]) for k in ('ox', 'oy', 'oz')])
A = np.fromfile(f'{d}/variant_{tag}_alpha.f64', dtype='<f8').reshape(mz, my, mx)
b = open(f'{d}/variant_{tag}.stl', 'rb').read(); n = struct.unpack('<I', b[80:84])[0]
V = np.frombuffer(b, dtype=np.dtype([('n', '<f4', 3), ('v', '<f4', (3, 3)), ('a', '<u2')]), count=n, offset=84)['v'].reshape(-1, 3).astype(float)
V = np.unique(V, axis=0)
def B(u):
    a = np.abs(u); out = np.where(a < 1, 1 - 1.5 * a**2 + 0.75 * a**3, np.where(a < 2, 0.25 * (2 - a)**3, 0.0)); return out
def dB(u):
    a = np.abs(u); s = np.sign(u)
    return s * np.where(a < 1, -3 * a + 2.25 * a**2, np.where(a < 2, -0.75 * (2 - a)**2, 0.0))
X = (V - o) / h - 0.5
phi = np.zeros(len(X)); g = np.zeros((len(X), 3))
i0 = np.floor(X / kv).astype(int) + pad
for da in range(-2, 3):
  for db in range(-2, 3):
    for dc in range(-2, 3):
      a = i0[:, 0] + da; bb = i0[:, 1] + db; c = i0[:, 2] + dc
      ok = (a >= 0) & (a < mx) & (bb >= 0) & (bb < my) & (c >= 0) & (c < mz)
      ux = (X[:, 0] - (a - pad) * kv) / kv; uy = (X[:, 1] - (bb - pad) * kv) / kv; uz = (X[:, 2] - (c - pad) * kv) / kv
      al = np.where(ok, A[np.clip(c, 0, mz - 1), np.clip(bb, 0, my - 1), np.clip(a, 0, mx - 1)], 0.0)
      wx, wy, wz = B(ux), B(uy), B(uz)
      phi += al * wx * wy * wz
      g[:, 0] += al * dB(ux) / kv * wy * wz; g[:, 1] += al * wx * dB(uy) / kv * wz; g[:, 2] += al * wx * wy * dB(uz) / kv
on = np.abs(phi) <= 0.01
sl = np.linalg.norm(g[on], axis=1) / h
q = np.percentile(sl, [5, 25, 50, 75, 95]) if on.any() else []
print(f'{d.split("/")[-2]} vf {tag}: {on.sum()} of {len(V)} corners on phi = 0; slope p5/p25/median/p75/p95 =', np.round(q, 2))

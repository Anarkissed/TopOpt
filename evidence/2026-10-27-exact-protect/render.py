import sys, numpy as np
sys.path.insert(0, '/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad/exact'); from measure import load_stl
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
cx, cy = -40.17, 54.55
fig = plt.figure(figsize=(16, 8.4), facecolor='#0B0D12')
for i, (title, path) in enumerate((('Today (voxel export, quality 64)', sys.argv[1]), ('Exact Protect (this release, quality 40)', sys.argv[2]))):
    T = load_stl(path); c = T.mean(1)
    m = (np.hypot(c[:, 0] - cx, c[:, 1] - cy) < 24) & (c[:, 2] > 128)
    T = T[m]
    n = np.cross(T[:, 1] - T[:, 0], T[:, 2] - T[:, 0]); n /= np.maximum(np.linalg.norm(n, axis=1), 1e-12)[:, None]
    L = np.array([0.4, -0.6, 0.7]); L /= np.linalg.norm(L); s = 0.25 + 0.75 * np.clip(n @ L, 0, 1)
    ax = fig.add_subplot(1, 2, i + 1, projection='3d', facecolor='#0B0D12')
    pc = Poly3DCollection(T, facecolors=np.stack([s * 0.86, s * 0.88, s * 0.92, np.ones_like(s)], 1), edgecolors='none')
    ax.add_collection3d(pc)
    ax.set_xlim(cx - 24, cx + 24); ax.set_ylim(cy - 24, cy + 24); ax.set_zlim(128, 176)
    ax.view_init(elev=38, azim=-62); ax.set_axis_off(); ax.set_box_aspect((1, 1, 1))
    ax.set_title(title, color='#F2F3F5', fontsize=15, pad=0)
fig.text(0.5, 0.04, 'Carriage Arms, the cup at x = -40: Ø32.5 bore, the counterbore step, Ø3.3 bolt holes — all Protected', color='#A3A7B3', ha='center', fontsize=12)
plt.subplots_adjust(left=0, right=1, top=0.94, bottom=0.07, wspace=0)
plt.savefig(sys.argv[3], dpi=110, facecolor='#0B0D12')

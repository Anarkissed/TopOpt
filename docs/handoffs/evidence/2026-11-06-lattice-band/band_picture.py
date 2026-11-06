#!/usr/bin/env python3
# band_picture.py DUMP_MINUS DUMP_PLUS OUT.png
# Ruling 2's fixture picture: the run's shape-grade band against the preview's law, on the
# test bar (test_lattice_shape_band: 60 x 20 x 20 mm, swept 1.6-6.4 mm, 8 mm band, 0.45 mm
# line). Each dump row is one band voxel the run latticed (TOPOPT_SHAPE_BAND_DUMP).
# Left: cell size by distance from the outline; dots = the run, line = the preview's centre
# rule (coarsest S with d + S/2 >= band (S - f)/(6.4 - f)) for the commonest finest cell f.
# Right: strut diameter, dots = the run: the preview's raise taken to a whole line width where
# one lies between the law's own strut and the quilt row (blue); where none does, the raise
# stands and the receipt counts it as off_line_width (orange). No strut is under its law
# (checked voxel by voxel in test_lattice_shape_band §4). Grey lines = k x 0.45 mm.
import sys, collections
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

def rows(p):
    out = []
    for l in open(p):
        if l.startswith("BAND "):
            d, b, a, S, r, st, r0, f = map(float, l.split()[1:])
            if d < b and f > 0: out.append((d, b, a, S, r, st, r0, f))
    return out

def preview_cell(d, b, f, sb=6.4):
    S, Sp = 2 * f, f
    while sb > f and S <= sb * (1 + 1e-9):
        if d + 0.5 * S >= b * (S - f) / (sb - f) - 1e-9: Sp = S; S *= 2
        else: break
    return Sp

fig, ax = plt.subplots(2, 2, figsize=(11, 8))
for row, (path, label) in enumerate([(sys.argv[1], "strength -1"), (sys.argv[2], "strength +1")]):
    R = rows(path)
    f = collections.Counter(r[7] for r in R).most_common(1)[0][0]
    xs = [i * 0.05 for i in range(0, 161)]
    ax[row][0].scatter([r[0] for r in R], [r[3] for r in R], s=4, alpha=0.25, label="run (each band voxel)")
    ax[row][0].plot(xs, [preview_cell(x, 8.0, f) for x in xs], "r-", lw=2, label=f"preview, f = {f:g} mm")
    ax[row][0].set_title(f"{label}: cell size by distance from the outline")
    ax[row][0].set_xlabel("distance from the outline (mm)"); ax[row][0].set_ylabel("cell (mm)")
    ax[row][0].legend(loc="lower right", fontsize=8)
    on = [r for r in R if abs(r[5] / 0.45 - round(r[5] / 0.45)) < 1e-3]
    off = [r for r in R if abs(r[5] / 0.45 - round(r[5] / 0.45)) >= 1e-3]
    ax[row][1].scatter([r[0] for r in on], [r[5] for r in on], s=4, alpha=0.25, label=f"whole line width ({len(on)})")
    ax[row][1].scatter([r[0] for r in off], [r[5] for r in off], s=6, alpha=0.6, color="tab:orange",
                       label=f"no whole width above the law, under the quilt row ({len(off)})")
    ax[row][1].legend(loc="upper right", fontsize=8)
    ax[row][1].axhline(0.45, color="k", lw=0.5)
    for k in range(2, 6): ax[row][1].axhline(0.45 * k, color="0.8", lw=0.5)
    ax[row][1].set_title(f"{label}: strut diameter (grey lines: whole line widths)")
    ax[row][1].set_xlabel("distance from the outline (mm)"); ax[row][1].set_ylabel("strut (mm)")
fig.suptitle("Shape-grade band, run vs the preview's law (test_lattice_shape_band bar)")
fig.tight_layout()
fig.savefig(sys.argv[3], dpi=110)
print("wrote", sys.argv[3])

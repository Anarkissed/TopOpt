#!/usr/bin/env python3
"""★ WHAT DOES THE PART LOOK LIKE **AS PRINTED**, AND HOW MUCH SURFACE IS IN
HOLES THAT NEVER GET MADE?

★ THE IDEA, WHICH IS THE MAINTAINER'S. `hole_sizes.py` measured that 5 wall
loops at 0.45 mm line every surface with 2.25 mm of plastic, so any hole
narrower than 4.50 mm has its walls meet from both sides and prints SOLID. On
the best arm that is 7.05% of the void; on SIMP it is 11.06%.

★★ THOSE HOLES STILL COST US EVERYTHING A HOLE COSTS — they carry internal
SURFACE, which is the quantity this whole task was spent minimising — and they
deliver NOTHING, because the printer fills them. The optimiser is being REWARDED
for making holes that do not exist.

★ SO THE FIX IS NOT A PENALTY, IT IS A CORRECTION: evaluate the design the
printer will actually produce. That is a morphological CLOSING of the solid by
the wall-stack radius — dilate the solid by r, erode it back by r — which is
exactly "fill every void narrower than 2r".

★ AND IT IS NOT ONE OF THE FIVE SMOOTHING OPERATORS THIS PROJECT HAS REFUSED.
The closing flow was refused (2026-08-08) as a POST-PROCESSING operator applied
to a finished design, on the grounds that the crevice radius rules out every
curvature/frequency operator. This is the same distinction PR 325 drew for the
perimeter penalty: applied to the OBJECTIVE it changes which design the
optimiser walks to, and no earned geometry is smoothed away because the
structure is never built. ★ IT ALSO HAS NO FREE PARAMETER — the radius is
5 loops x 0.45 mm, MEASURED from the job, not chosen.

THIS SCRIPT ONLY MEASURES THE PRIZE. It applies the closing to designs that are
already finished and asks what their surface and mass would have been. If the
prize is small, nothing should be built.
"""
import csv, gzip, os, struct, sys
import numpy as np
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
H = 1.7052793026343613
NX, NY, NZ = 128, 31, 118
WALL_STACK = 5 * 0.45          # 2.25 mm per side
DENSITY_G_MM3 = None           # taken from each arm's own certified mass


def load(p):
    op = gzip.open if p.endswith(".gz") else open
    with op(p, "rb") as f:
        return np.frombuffer(f.read(), dtype=np.float64).reshape((NZ, NY, NX))


def close_void(rho, active):
    """The design AS PRINTED: every void narrower than the wall stack filled.

    ★ QUANTISED TO WHOLE VOXELS, and `hole_sizes.py` explains why: a distance
    transform on a voxel grid cannot resolve a radius below one voxel, and the
    wall-stack radius is 0.66 of one. The wall threshold of 4.50 mm falls
    between 2 voxels (3.41 mm) and 3 (5.12 mm), so "survives an opening by a
    1-voxel ball" — i.e. at least 3 voxels thick — IS the wall test here.
    """
    solid = rho > 0.5
    void = (~solid) & active
    ball = ndimage.generate_binary_structure(3, 1)
    er = ndimage.binary_erosion(void, structure=ball, border_value=0)
    survives = void & ndimage.binary_dilation(er, structure=ball)
    filled = void & ~survives            # the holes the printer closes
    out = rho.copy()
    out[filled] = 1.0
    return out, int(filled.sum()), int(solid.sum())


def write_field(path, arr, meta_src, vf):
    arr.astype(np.float64).tofile(path + ".f64")
    lines = open(meta_src).read().splitlines()
    with open(path + ".meta", "w") as f:
        for ln in lines:
            if ln.startswith("achieved_vf "):
                f.write(f"achieved_vf {vf}\n")
            else:
                f.write(ln + "\n")
        f.write("# AS PRINTED: void narrower than the 5x0.45 mm wall stack "
                "filled solid, which is what the slicer does\n")


def main():
    mask = load(os.path.join(REPO, "evidence", "2026-08-10-parametric-level-set",
                             "sources", "designmask.f64.gz"))
    active = np.abs(mask - 0.5) < 0.25
    part_solid = 110904.0

    out_dir = os.path.join(HERE, "asprinted")
    os.makedirs(out_dir, exist_ok=True)
    subjects = [("SIMP", os.path.join(REPO, "evidence",
                                      "2026-08-10-parametric-level-set", "sources",
                                      "simp", "rung_0.68.f64.gz"),
                 os.path.join(REPO, "evidence", "2026-08-10-parametric-level-set",
                              "sources", "simp", "rung_0.68.meta"))]
    for arm in ("RB1_volcount", "E1_c1_eta1", "P3_c4"):
        p = os.path.join(HERE, "arms", arm, "rho.f64.gz")
        m = os.path.join(HERE, "arms", arm, "rho.meta")
        if os.path.exists(p):
            subjects.append((arm, p, m))

    print(f"wall stack {WALL_STACK:.2f} mm/side -> holes under "
          f"{2*WALL_STACK:.2f} mm print SOLID\n")
    print(f"{'design':16s} {'printed vox':>11s} {'as-designed':>11s} "
          f"{'filled':>7s} {'mass err':>9s}")
    print("-" * 60)
    rows = []
    for name, path, meta in subjects:
        rho = load(path)
        pr, filled, was = close_void(rho, active)
        now = int((pr > 0.5).sum())
        vf = now / part_solid
        write_field(os.path.join(out_dir, name), pr, meta, vf)
        print(f"{name:16s} {now:11d} {was:11d} {filled:7d} "
              f"{100.0*filled/was:8.2f}%")
        rows.append(dict(design=name, as_designed_voxels=was,
                         as_printed_voxels=now, voxels_filled=filled,
                         mass_understated_pct=round(100.0 * filled / was, 4),
                         as_printed_vf=round(vf, 6)))
    with open(os.path.join(HERE, "as_printed.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader(); w.writerows(rows)
    print("\n★ 'mass err' is how much HEAVIER the printed part is than the "
          "design says.\n  Every mass in every table in this line of work is "
          "understated by that much.")
    print(f"\nwrote as_printed.csv and asprinted/*.f64 for the surface probe")


if __name__ == "__main__":
    main()

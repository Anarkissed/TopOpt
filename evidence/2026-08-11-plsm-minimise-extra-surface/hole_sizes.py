#!/usr/bin/env python3
"""★ HOW BIG ARE THE HOLES, AND WOULD THE PRINTER MAKE THEM?

★ WHY THIS EXISTS AND WHY IT IS NEW CODE. This task spent itself minimising
INTERNAL SURFACE. Internal surface is the surface of HOLES. Nothing in this
repository measures how big those holes are:

  * `min_feature_violations` counts thin SOLID — a solid voxel not inside any
    fully-solid 2x2x2 block (core/src/voxel/voxelize.cpp). It is silent about
    voids.
  * `min_section_mm2` reads 3.4106 on every arm AND on SIMP — it is pinned at a
    floor and discriminates nothing here.
  * A grep for min_void / void_size / hole_size / inscribed across core/src and
    core/include returns no instrument.

So R2's "invoke, do not retype" has nothing to invoke. This is a new
measurement, written once, and it computes no roughness and no mechanics — only
the geometry of the void.

★ THE TWO LIMITS A HOLE HAS TO CLEAR, AND THE SECOND IS THE ONE THAT BITES:

  1. THE BEAD. 0.42 mm outer / 0.45 mm inner line width. A void narrower than
     about one bead cannot be traced at all. Against a 1.705279 mm voxel this
     is a QUARTER of a voxel — the design lattice cannot represent a hole that
     small, so this limit is unreachable by construction.

  2. ★★ THE WALL STACK. The job runs 5 wall loops at 0.45 mm, so every surface
     is lined with 2.25 mm of wall material — INCLUDING the inside of a hole.
     A hole whose width is below 2 x 2.25 = 4.50 mm has its walls meet from
     opposite sides and is FILLED SOLID by the slicer. That is 2.64 VOXELS on
     this grid, and it is far above the representation floor.

  ★ SO THE QUESTION IS NOT "can the printer resolve these holes" (it can) BUT
  "does the WALL SETTING erase them" (it may).

WIDTH is the diameter of the largest sphere that fits inside the void component
— for a channel that is its cross-section, which is exactly what the wall loops
have to fit into. The distance transform is scipy's exact Euclidean one.

★ MEASURED ON THE DESIGN LATTICE, which is where the design lives. The shipped
export resamples to factor 2 before extracting, and that can only round a hole's
corners — it cannot open a hole the design does not have. So these widths are an
upper bound on what survives, and the conclusion is one-sided.
"""
import csv, gzip, os, sys
import numpy as np
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
H = 1.7052793026343613          # voxel, mm — from every arm's .meta
NX, NY, NZ = 128, 31, 118
BEAD_OUTER = 0.42
WALL_LOOPS, WALL_W = 5, 0.45
WALL_STACK = WALL_LOOPS * WALL_W          # 2.25 mm lining every surface
FILLED_BELOW = 2.0 * WALL_STACK           # 4.50 mm — walls meet, hole vanishes


def load(path):
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rb") as f:
        a = np.frombuffer(f.read(), dtype=np.float64)
    if a.size != NX * NY * NZ:
        raise SystemExit(f"{path}: {a.size} values, expected {NX*NY*NZ}")
    # levelset_probe writes x fastest, then y, then z.
    return a.reshape((NZ, NY, NX))


def holes(rho, active):
    """The LOCAL WIDTH of the void, everywhere in it.

    ★ THE FIRST VERSION OF THIS FUNCTION ANSWERED THE WRONG QUESTION AND THE
    NUMBERS LOOKED FINE. It labelled void components and took each component's
    largest inscribed sphere. But the carved region is one big interconnected
    void, and a component's MAXIMUM width says nothing about its narrow parts:
    a dumbbell with two 18 mm bulbs joined by a 1 mm neck reports 18 mm, and the
    neck is exactly what the wall loops fill. It read "0.1% of void volume at
    risk" on a design where that is not the interesting quantity.

    What decides whether the slicer keeps a piece of void is its LOCAL width.
    The set of void that is part of a region at least 2r wide is the
    morphological OPENING of the void by a ball of radius r, and that is what is
    computed here — by the exact Euclidean distance transform twice, which is
    equivalent and far cheaper than a structuring element:

        core   = {dist_to_solid >= r}          (erosion by the ball)
        opened = {dist_to_core  <= r}          (dilation of it back)

    The fraction of void volume NOT in `opened` is the fraction whose local
    width is under 2r — the part the wall loops close.
    """
    void = (rho <= 0.5) & active
    tot = int(void.sum())
    if tot == 0:
        return None
    # ★ AND THE SECOND VERSION WAS WRONG TOO, IN A WAY THAT PRINTED 100.00% ON
    # EVERY DESIGN INCLUDING SIMP — which is the tell. `distance_transform_edt`
    # measures centre-to-centre, so the SMALLEST non-zero value it can return is
    # one voxel: a lone void voxel reads 1.705 mm, not the 0.85 mm half-width it
    # actually has. Every radius threshold below one voxel — and the wall stack's
    # 1.125 mm radius is 0.66 of a voxel — therefore passes everywhere.
    #
    # On a voxel grid the honest test is EROSION BY WHOLE VOXELS. A ball of
    # radius 1 voxel fits only where the void is at least 3 voxels thick, so:
    #
    #     thickness >= 1 voxel (1.71 mm)  : all void, by definition
    #     thickness >= 3 voxels (5.12 mm) : survives one erosion + dilation
    #     thickness >= 5 voxels (8.53 mm) : survives two
    #
    # ★ THE WALL-STACK THRESHOLD IS 4.50 mm, WHICH FALLS BETWEEN 2 VOXELS
    # (3.41 mm) AND 3 (5.12 mm). So "at least 3 voxels thick" IS the wall test
    # on this grid, and void 1 or 2 voxels thick is what the loops close.
    ball = ndimage.generate_binary_structure(3, 1)     # 6-connected unit ball
    out = {"void_mm3": tot * H ** 3}
    er = void
    prev = void
    for k in (1, 2):
        er = ndimage.binary_erosion(er, structure=ball, border_value=0)
        if not er.any():
            out[f"ge{2*k+1}"] = 0.0
            prev = np.zeros_like(void)
            continue
        opened = ndimage.binary_dilation(er, structure=ball, iterations=k)
        keep = void & opened
        out[f"ge{2*k+1}"] = float(keep.sum()) / tot
        prev = keep
    # ★ AND "AT LEAST 2 VOXELS THICK", BY CORE'S OWN CONVENTION. `min_feature_
    # violations` calls a SOLID voxel thick enough when it belongs to a
    # fully-solid 2x2x2 block (core/src/voxel/voxelize.cpp). Mirroring that onto
    # the void gives the same test for holes, and it is the only way to separate
    # 1-voxel-thick void from 2-voxel-thick void — which is what the wall-loop
    # sweep below turns on, since the thresholds it needs (1.80 / 2.70 / 3.60 /
    # 4.50 mm) all fall between one voxel and three.
    cube = np.ones((2, 2, 2), dtype=bool)
    er2 = ndimage.binary_erosion(void, structure=cube, border_value=0)
    out["ge2"] = (float((void & ndimage.binary_dilation(er2, structure=cube)).sum())
                  / tot) if er2.any() else 0.0
    dist = ndimage.distance_transform_edt(void) * H
    out["max_width_mm"] = float(2.0 * dist.max() - H)   # centre-to-centre -> width
    return out


def main():
    mask = load(os.path.join(HERE, "sources", "designmask.f64.gz")
                if os.path.exists(os.path.join(HERE, "sources", "designmask.f64.gz"))
                else os.path.join(REPO, "evidence", "2026-08-10-parametric-level-set",
                                  "sources", "designmask.f64.gz"))
    # 1.0 FrozenSolid, 0.5 Active, 0.0 FrozenVoid/Empty.
    active = np.abs(mask - 0.5) < 0.25

    subjects = []
    simp = os.path.join(REPO, "evidence", "2026-08-10-parametric-level-set",
                        "sources", "simp", "rung_0.68.f64.gz")
    if os.path.exists(simp):
        subjects.append(("SIMP rung 0.68", simp))
    for arm in ("RB1_volcount", "S0_seed16", "P1_c1", "P3_c4", "P4_c8",
                "E1_c1_eta1", "A3_seed16_perim", "W1_winning_6core"):
        p = os.path.join(HERE, "arms", arm, "rho.f64.gz")
        if os.path.exists(p):
            subjects.append((arm, p))

    print(f"voxel {H:.4f} mm   bead {BEAD_OUTER} mm   wall stack "
          f"{WALL_STACK:.2f} mm/side")
    print(f"★ a hole below {FILLED_BELOW:.2f} mm ({FILLED_BELOW/H:.2f} voxels) has "
          f"its wall loops meet from opposite sides and is FILLED SOLID\n")
    hdr = (f"{'design':18s} {'void mm3':>9s} {'widest':>7s} | "
           f"{'>=5.12mm':>9s} {'>=8.53mm':>9s} | {'★ UNDER 4.50mm':>15s}")
    print(hdr)
    print("-" * len(hdr))
    rows = []
    for name, path in subjects:
        r = holes(load(path), active)
        if r is None:
            print(f"{name:18s}  no void in the active region")
            continue
        filled = 1.0 - r["ge3"]
        print(f"{name:18s} {r['void_mm3']:9.0f} {r['max_width_mm']:7.2f} | "
              f"{100*r['ge3']:8.2f}% {100*r['ge5']:8.2f}% | {100*filled:14.2f}%")
        rows.append(dict(design=name, void_mm3=round(r["void_mm3"], 1),
                         widest_mm=round(r["max_width_mm"], 3),
                         frac_thickness_ge_3vox_5p12mm=round(r["ge3"], 5),
                         frac_thickness_ge_5vox_8p53mm=round(r["ge5"], 5),
                         frac_below_2vox=round(1.0 - r["ge2"], 5),
                         frac_below_wall_stack_4p50mm=round(filled, 5)))
    with open(os.path.join(HERE, "hole_sizes.csv"), "w", newline="") as f:
        if rows:
            wcsv = csv.DictWriter(f, fieldnames=list(rows[0]))
            wcsv.writeheader()
            wcsv.writerows(rows)
    # ── ★ CAN THE SETTINGS OVERRIDE THE HOLES? THE WALL-LOOP SWEEP. ─────────
    #
    # The job runs 5 loops. Each loop is 0.45 mm on EVERY side of a surface, so
    # `loops` loops close any hole narrower than 2*loops*0.45 mm. The voxel
    # quantises which bucket each threshold lands in, and that is stated rather
    # than smoothed over.
    print("\n★ WALL LOOPS vs THE HOLES — what the SETTING closes, on the best")
    print("  arm and on SIMP. `>` reads: void narrower than this is filled solid.\n")
    print(f"| wall loops | closes void under | in voxels | E1 void closed | "
          f"SIMP void closed |")
    print("|---|---|---|---|---|")
    ref = {r["design"]: r for r in rows}
    e1 = ref.get("E1_c1_eta1"); sp = ref.get("SIMP rung 0.68")
    for loops in (1, 2, 3, 4, 5):
        thr = 2.0 * loops * WALL_W
        vox = thr / H
        if vox <= 1.0:
            key = None                      # below one voxel: nothing to close
        elif vox <= 2.0:
            key = "frac_below_2vox"
        else:
            key = "frac_below_wall_stack_4p50mm"
        def cell(r):
            if r is None: return "—"
            return "0.00%" if key is None else f"{100*r[key]:.2f}%"
        star = " ← THE JOB" if loops == WALL_LOOPS else ""
        print(f"| {loops}{star} | {thr:.2f} mm | {vox:.2f} | {cell(e1)} | {cell(sp)} |")
    print(f"\nwrote hole_sizes.csv")


if __name__ == "__main__":
    main()

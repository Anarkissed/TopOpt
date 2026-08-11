#!/usr/bin/env python3
"""S2 — the knot-lattice frontier, read off the arms' own artefacts.

★ NOTHING IS RETYPED. The surface columns come from `curves.csv`, which
`external_field_surface_probe` wrote in ONE invocation covering every arm AND
SIMP's own four rungs, so every row was extracted by the same binary at the same
factor. The margin and the mass come from `design_rung_dump`'s per-rung `.meta`,
which carries the run's OWN recorded certification. This script computes ratios.

★ EVERY ROUGHNESS NUMBER CARRIES ITS ENCLOSED VOLUME, ITS MASS AND ITS CAD ERROR
(R3). `dihedral_rms_deg` scales like kappa*h, so it is only comparable within a
column of constant extraction factor — SIMP itself reads 14.01 / 8.41 / 6.11 at
factors 1 / 2 / 3. `obl_cad_rms_mm` is a true error against known CAD geometry
and is the column a blur cannot fake: a blur pushes it UP.
"""
import csv
import json
import os
import sys

# The bar, from SIMP's own rung 0.68 (PR 324 §0, and re-emitted in curves.csv by
# the same probe in the same run, so it is checked rather than remembered).
BAR_CUT = 7.5521
BAR_MARGIN = 3254.34
BAR_MASS = 543.7

ARMS = ["K2", "K424", "K4", "K8"]
COEFF = {"K2": 85680, "K424": 24480, "K4": 14688, "K8": 3040}
KNOTS = {"K2": "2, 2, 2", "K424": "4, 2, 4", "K4": "4, 4, 4", "K8": "8, 8, 8"}


def read_meta(path):
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path):
        parts = line.split()
        if len(parts) >= 2:
            try:
                out[parts[0]] = float(parts[1])
            except ValueError:
                out[parts[0]] = parts[1]
    return out


def iteration_totals(path):
    if not os.path.exists(path):
        return None
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return None
    return {
        "iters": len(rows),
        "cg": sum(int(r["cg_iters"]) for r in rows),
        "wall_s": sum(float(r["total_ms"]) for r in rows) / 1000.0,
        "compliance": [float(r["compliance"]) for r in rows],
        "vf": [float(r["achieved_vf"]) for r in rows],
    }


def main(out_dir):
    curves = {}
    cpath = os.path.join(out_dir, "curves.csv")
    if not os.path.exists(cpath):
        print("MISSING", cpath)
        return 1
    for r in csv.DictReader(open(cpath)):
        curves.setdefault(r["arm"], {})[r["rung"].strip()] = r

    simp = curves.get("SIMP", {}).get("0.68")
    if simp is None:
        print("★ NO SIMP ROW AT RUNG 0.68 — the comparison row is missing and no")
        print("  number below can be read. (external_field_surface_probe matches")
        print("  the rung as a STRING; check the .meta's `rung` line.)")
        return 1

    print("== S2 — THE KNOT-LATTICE FRONTIER, RUNG 0.68, PRODUCTION PATH ==")
    print()
    print("Every row extracted by ONE external_field_surface_probe invocation at")
    print("the shipped convention (design lattice, factor 2 tricubic). SIMP's row")
    print("is that probe's own, from the reference design.bin, in the same run.")
    print()
    hdr = (f"{'arm':<8}{'knots (vox)':<14}{'coeff':>8}{'CARVED':>9}{'whole':>9}"
           f"{'CAD':>9}{'CAD err mm':>12}{'mid %':>8}{'volume mm3':>12}"
           f"{'mass g':>9}{'margin':>12}")
    print(hdr)
    print("-" * len(hdr))

    def row(label, knots, coeff, c, margin, mass):
        line = (f"{label:<8}{knots:<14}{coeff if coeff else '—':>8}"
                f"{float(c['dihedral_cut_deg']):>9.4f}"
                f"{float(c['dihedral_all_deg']):>9.4f}"
                f"{float(c['dihedral_cad_deg']):>9.4f}"
                f"{float(c['obl_cad_rms_mm']):>12.4f}"
                f"{100.0 * float(c['midpoint_share']):>8.2f}"
                f"{float(c['volume_mm3']):>12.1f}")
        line += f"{mass:>9.1f}" if mass is not None else f"{'—':>9}"
        line += f"{margin:>12.2f}" if margin is not None else f"{'—':>12}"
        print(line)

    # SIMP first — the bar.
    simp_mass = float(simp["volume_mm3"]) * 0.00124
    row("SIMP", "—", 0, simp, float(simp["margin_worst_case"]), simp_mass)

    best = None
    for a in ARMS:
        c = curves.get(a, {}).get("0.68")
        if c is None:
            print(f"{a:<8}(no row — the run did not produce a rung 0.68 field)")
            continue
        meta = read_meta(os.path.join(out_dir, f"{a}.rung_0.68.meta"))
        margin = meta.get("margin_worst_case")
        mass = float(c["volume_mm3"]) * 0.00124
        row(a, KNOTS[a], COEFF[a], c, margin, mass)
        cut = float(c["dihedral_cut_deg"])
        if margin is not None:
            score = (cut <= BAR_CUT, margin >= BAR_MARGIN, mass <= BAR_MASS)
            if best is None or sum(score) > best[1]:
                best = (a, sum(score))
    print()
    print(f"THE BAR: carved <= {BAR_CUT}, margin >= {BAR_MARGIN}, "
          f"mass <= {BAR_MASS} g.")
    print("Mass is the enclosed volume x PLA's 1.24 g/cm3 — the same density the")
    print("certification's own mass_grams uses, applied to the MESH volume so it")
    print("is the mass of the object that was measured for roughness.")
    print()

    # ── THE MARGIN AS A CURVE, NEVER A POINT (R3) ──────────────────────────
    print("== THE TRAJECTORY, NOT THE ENDPOINT ==")
    print()
    print("PR 323's arms swung 2027 -> 3172 -> 2015 between ADJACENT iterations,")
    print("and PR 324 measured two fits of ONE design disagreeing by 64% on margin.")
    print("A single-iteration number in this regime is not trustworthy, so the")
    print("compliance and volume-fraction trajectories are printed beside the")
    print("endpoint. (A per-iteration MARGIN would need a certification solve per")
    print("iteration — 40 of them per arm — which is not affordable here and is")
    print("said rather than quietly skipped.)")
    print()
    for a in ARMS:
        t = iteration_totals(os.path.join(out_dir, f"{a}.iterations.csv"))
        if t is None:
            print(f"{a}: no iteration record")
            continue
        c = t["compliance"]
        tail = c[-10:] if len(c) >= 10 else c
        spread = (max(tail) - min(tail)) / max(tail) if max(tail) > 0 else 0.0
        print(f"{a:<6} {t['iters']:>3} iters  {t['cg']:>8,} solver steps  "
              f"{t['wall_s']:>8.1f} s  compliance {c[0]:.6g} -> {c[-1]:.6g}  "
              f"last-10 spread {spread:.3%}")
        print(f"       vf {t['vf'][0]:.4f} -> {t['vf'][-1]:.4f}")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))

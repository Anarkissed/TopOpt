#!/usr/bin/env python3
"""gripcheck.py OLD_EV NEW_EV: what sets the cut-layer population, in the 11-09 rows and the new ones.

The probe's classify() puts every voxel of the cut fixture's top partial layer in the cut population FIRST, before the
grip test, so the cut layer's two end cells (ci = 0 and N-1) sit against the prescribed x faces. Part 1 compares, per
cut fixture, the cut layer's exact worst case (K_dev_max) with the grip population's (k_exact_boundary.csv). Part 2
splits the cut-layer CELLS by column with the per-cell records (k_cells.csv, K_far = the cell peak over the far-field macro vm: the seven named states only, so a lower
bound on the exact worst case, but the same states for every class): the end columns against the grips, and the
middle column(s) away from them."""
import csv, sys

for ev in sys.argv[1:]:
    print("=== %s" % ev)
    for t in ("bcc", "diamond", "sc"):
        d = {}
        for r in csv.DictReader(open("%s/%s/k_exact_boundary.csv" % (ev, t))):
            if r["fixture"] == "cut":
                d.setdefault((r["rho_lib"], r["N"], r["vpc"]), {})[r["population"]] = float(r["K_dev_max"])
        cells = {}
        for r in csv.DictReader(open("%s/%s/k_cells.csv" % (ev, t))):
            if r["fixture"] != "cut":
                continue
            key = (r["rho_lib"], r["N"], r["vpc"])
            n, ci, k = int(r["N"]), int(r["ci"]), float(r["K_far"])
            e = cells.setdefault(key, {"cut_end": 0.0, "cut_mid": 0.0, "free": 0.0, "grip": 0.0, "interior": 0.0})
            c = r["class"]
            col = "cut_end" if ci in (0, n - 1) else "cut_mid"
            slot = col if c == "cut_layer" else "free" if c == "free_surface" else c
            if slot in e:
                e[slot] = max(e[slot], k)
        for key in sorted(d):
            p = d[key]
            e = cells.get(key, {})
            print("  %-8s rho %s N%s vpc%-3s exact K_dev: cut_layer %9.1f grip %9.1f free %8.1f interior %8.1f | "
                  "named states, cut cells: end columns %8.1f middle %8.1f (free %7.1f)"
                  % (t, key[0], key[1], key[2], p.get("cut_layer", 0), p.get("grip", 0), p.get("free_surface", 0),
                     p.get("interior", 0), e.get("cut_end", 0), e.get("cut_mid", 0), e.get("free", 0)))

#!/usr/bin/env python3
"""Render the conditioning-probe CSVs into markdown tables for the handoff.
Read-only formatter; takes a grid dir (containing cond_sweep.csv / design_cost.csv).
Usage: format_tables.py <griddir> [<griddir2> ...]"""
import csv, sys, os

def load(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))

def cond_table(rows):
    # group by rung, show contrast sweep
    print("| rung | contrast | density_min | cg_raw | cg_jac | cg_resc | kappa | mg_used | mg_cycles | mg_cg_iters |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        raw = r["cg_unprecond"]
        raw = "—" if raw == "-1" else raw
        resc = r["cg_rescaled"]
        resc = "—" if resc == "-1" else resc
        print(f"| {r['rung_vf']} | {r['contrast']} | {float(r['density_min']):.2e} | "
              f"{raw} | {r['cg_jacobi']} | {resc} | {float(r['kappa_lanczos']):.2e} | "
              f"{r['mg_used']} | {r['mg_cycles']} | {r['mg_cg_iters']} |")

def design_table(rows):
    print("| rung | contrast | density_min | ctl | grid | solid_base | solid_var | changed | frac_changed | marginB | marginV | sign | acc_base | acc_var |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        grid = f"{r['nx']}x{r['ny']}x{r['nz']}"
        ctl = "NEG" if r["is_negctrl"] == "1" else ""
        sign = {"1":"+","0":"0","-1":"−"}.get(r["margin_sign"], r["margin_sign"])
        print(f"| {r['rung_vf']} | {r['contrast']} | {float(r['density_min']):.2e} | {ctl} | {grid} | "
              f"{r['solid_baseline']} | {r['solid_variant']} | {r['changed_voxels']} | "
              f"{float(r['frac_changed'])*100:.3f}% | {float(r['margin_baseline']):.3f} | "
              f"{float(r['margin_variant']):.3f} | {sign} | {r['accepted_baseline']} | {r['accepted_variant']} |")

for d in sys.argv[1:]:
    print(f"\n### {d}")
    cond = load(os.path.join(d, "cond_sweep.csv"))
    if cond:
        print("\n**cond_sweep.csv**\n")
        cond_table(cond)
    des = load(os.path.join(d, "design_cost.csv"))
    if des:
        print("\n**design_cost.csv**\n")
        design_table(des)

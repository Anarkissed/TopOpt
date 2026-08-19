#!/usr/bin/env python3
"""tables.py — every table the handoff quotes, from the two sweep CSVs.

  ./evidence/2026-08-19-peak-stress-convergence/tables.py

Fits q in sigma_peak ~ h^-q two ways, because they answer different questions:

  * PAIRWISE between consecutive rungs, q = ln(s2/s1) / ln(h1/h2). This is the
    form PR 320 reported (0.4945 then 0.4391) and the only one that can show q
    FAILING TO COLLAPSE, which was PR 320's actual finding.
  * GLOBAL, least squares of ln(sigma) on ln(1/h) over every rung, with R^2.
    ★ A GLOBAL SLOPE WITH A POOR R^2 IS NOT A POWER LAW and must not be quoted
    as one; the R^2 is printed beside every q for exactly that reason.

Reference exponents: 0.4945 / 0.4391 (PR 320, rung 0.68, replicate mode) and
0.4555 (the 2-D re-entrant 90-degree corner).
"""
import csv, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

def load(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))

def fit_global(hs, ys):
    xs = [math.log(1.0 / h) for h in hs]
    ls = [math.log(y) for y in ys]
    n = len(xs)
    mx, ml = sum(xs) / n, sum(ls) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return float("nan"), float("nan")
    q = sum((x - mx) * (l - ml) for x, l in zip(xs, ls)) / sxx
    a = ml - q * mx
    ss_res = sum((l - (a + q * x)) ** 2 for x, l in zip(xs, ls))
    ss_tot = sum((l - ml) ** 2 for l in ls)
    return q, (1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan"))

def pairwise(hs, ys):
    out = []
    for i in range(len(hs) - 1):
        if ys[i] <= 0 or ys[i + 1] <= 0:
            out.append(None)
        else:
            out.append(math.log(ys[i + 1] / ys[i]) / math.log(hs[i] / hs[i + 1]))
    return out

def spread(xs):
    mid = sum(xs) / len(xs)
    return 100.0 * (max(xs) - min(xs)) / mid if mid else float("nan")

def fitline(label, hs, ys):
    if not ys or min(ys) <= 0:
        return f"  {label:38s}  (a rung reported zero — not fitted)"
    q, r2 = fit_global(hs, ys)
    pw = " ".join("  n/a  " if v is None else f"{v:+.4f}" for v in pairwise(hs, ys))
    return (f"  {label:38s}  global q = {q:+.4f}  (R^2 {r2:6.4f})\n"
            f"  {'':38s}  pairwise  {pw}")

COLS = [
    ("peak_vm_mpa",       "ALL         what the gate reads"),
    ("peak_vm_frozen",    "FROZEN      mask-stamped pads"),
    ("peak_vm_active",    "ACTIVE      the level set's cells"),
    ("peak_vm_cut",       "CUT         * THE SMOOTH BOUNDARY"),
    ("peak_vm_active_g5", "ACTIVE >5mm from pads/tags"),
    ("peak_vm_cut_g5",    "CUT >5mm    from pads/tags"),
    ("peak_vm_cut_g10",   "CUT >10mm   from pads/tags"),
    ("peak_vm_active_g20","ACTIVE >20mm from pads/tags"),
    ("peak_vm_cut_g20",   "CUT >20mm   from pads/tags"),
    ("compliance",        "compliance  (the CONTROL: it must be tame)"),
]

def report(rows, title, key):
    arms = []
    for r in rows:
        if r["arm"] not in arms:
            arms.append(r["arm"])
    print("#" * 78)
    print("# " + title)
    print("#" * 78)
    for arm in arms:
        rs = sorted((r for r in rows if r["arm"] == arm), key=lambda r: float(r[key]))
        if len(rs) < 2:
            print(f"\nARM {arm}: only {len(rs)} rung — not fitted\n")
            continue
        hs = [float(r["spacing_mm"]) for r in rs]
        print()
        print("=" * 78)
        print(f"ARM: {arm}    ({len(rs)} rungs, mode {rs[0].get('mode','-')})")
        print("=" * 78)
        print(f"{'res':>5} {'h mm':>9} {'dofs':>11} {'ALL':>11} {'FROZEN':>11} "
              f"{'ACTIVE':>11} {'CUT':>11} {'CUT>10':>11} {'margin':>11} "
              f"{'wall s':>8}")
        for r in rs:
            print(f"{r['resolution']:>5} {float(r['spacing_mm']):9.5f} "
                  f"{int(r['dofs']):>11} {float(r['peak_vm_mpa']):11.5g} "
                  f"{float(r['peak_vm_frozen']):11.5g} "
                  f"{float(r['peak_vm_active']):11.5g} "
                  f"{float(r['peak_vm_cut']):11.5g} "
                  f"{float(r['peak_vm_cut_g10']):11.5g} "
                  f"{float(r['margin_worst_case']):11.3f} "
                  f"{float(r['wall_s']):8.1f}")
        print()
        print("-- q in sigma_peak ~ h^-q   (PR 320: 0.4945 -> 0.4391; corner 0.4555)")
        for k, lab in COLS:
            print(fitline(lab, hs, [float(r[k]) for r in rs]))
        print()
        print("-- R1: THE GEOMETRY INVARIANT ------------------------------------")
        print(f"{'res':>5} {'{phi<0} in part mm^3':>22} {'ACTIVE mm^3':>14} "
              f"{'frozen mm^3':>13} {'certified mm^3':>15} {'cut cells':>10} "
              f"{'>10mm cut':>10}")
        for r in rs:
            print(f"{r['resolution']:>5} {float(r['vol_phi_mm3']):22.4f} "
                  f"{float(r['vol_active_mm3']):14.2f} "
                  f"{float(r['vol_frozen_mm3']):13.2f} "
                  f"{float(r['vol_total_mm3']):15.2f} {int(r['n_cut']):>10} "
                  f"{int(r['cut_printed_g10']):>10}")
        vp = [float(r["vol_phi_mm3"]) for r in rs]
        vt = [float(r["vol_total_mm3"]) for r in rs]
        print(f"  spread of {{phi<0}} volume : {spread(vp):.3f} %   "
              f"spread of CERTIFIED volume : {spread(vt):.3f} %")
        print()
        print("-- R4: THE MARGIN, AND THE NOISE FLOOR IT SETS -------------------")
        mg = [float(r["margin_worst_case"]) for r in rs]
        me = [float(r["margin_effective"]) for r in rs]
        print(f"  margin_worst_case  min {min(mg):11.4f}  max {max(mg):11.4f}  "
              f"mean {sum(mg)/len(mg):11.4f}  SPREAD {spread(mg):7.2f} %")
        print(f"  margin_effective   min {min(me):11.4f}  max {max(me):11.4f}  "
              f"{'':17s}  SPREAD {spread(me):7.2f} %")
        print(f"  accepted at every rung: "
              f"{all(int(r['accepted']) == 1 for r in rs)}")
        print()
        print("-- WHERE THE PEAK SAT --------------------------------------------")
        for r in rs:
            print(f"  res {r['resolution']:>4}: ({r['peak_i']},{r['peak_j']},"
                  f"{r['peak_k']}) tag={r['peak_tag']:<8} mask={r['peak_mask']:<12}"
                  f" load voxels {r['load_voxels']:>6}, fixture {r['fixture_voxels']:>6}")
        print()

def ab(rows, key, label):
    by = {}
    for r in rows:
        by.setdefault(r["arm"], {})[r["resolution"]] = r
    arms = list(by)
    if len(arms) < 2:
        return
    common = sorted(set.intersection(*[set(by[a]) for a in arms]), key=int)
    if not common:
        return
    print("=" * 78)
    print(f"A/B/C at each rung ({label}): same phi, same mask, same cells — only")
    print("the ACTIVE density differs.")
    print("=" * 78)
    hdr = f"{'res':>5}"
    for a in arms:
        hdr += f" {a+' ALL':>16} {a+' CUT':>16}"
    print(hdr)
    for r in common:
        line = f"{r:>5}"
        for a in arms:
            line += (f" {float(by[a][r]['peak_vm_mpa']):16.6g}"
                     f" {float(by[a][r]['peak_vm_cut']):16.6g}")
        print(line)
    print()

rep = load(os.path.join(HERE, "s1_replicate.csv"))
ret = load(os.path.join(HERE, "s2_retag.csv"))
if rep:
    report(rep, "S1 — REPLICATE MODE. The load case, the pads and the mask are ONE\n#      physical solid at every rung; only the element size changes.\n#      THIS IS THE CONVERGENCE MEASUREMENT.", "refine")
    ab(rep, "refine", "replicate")
if ret:
    report(ret, "S2 — RETAG MODE. The shipped builder run outright at each resolution:\n#      what a re-certification of this job at another resolution ACTUALLY does.\n#      The pad depth is in VOXELS, so the certified object MOVES. Not a\n#      convergence measurement, and never mixed with S1.", "resolution")
    ab(ret, "resolution", "retag")
if not rep and not ret:
    print("no CSV found — run s1_replicate.sh / s2_retag.sh first")

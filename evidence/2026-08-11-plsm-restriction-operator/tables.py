#!/usr/bin/env python3
"""The handoff's tables, joined from what the instruments wrote.

★ COMPUTES NO GEOMETRY AND NO MECHANICS. Roughness from
`external_field_surface_probe` (m1_matched.csv), margin/mass/load-path from
`analyze_fixed_design` via `levelset_probe --certify-field`
(m2/margin_curve.csv), trajectory columns from each arm's own iterations.csv.
If a number is not in one of those files it is not in a table.

★ EVERY SURFACE ROW IS AT MATCHED ITERATION 60. `levelset_probe` writes and
certifies the BEST-COMPLIANCE iterate, which across PR 326's arms ranged from
iteration 9 to 60; a table built off `rho` compares arms at different points in
their own lives, and that error reversed a conclusion there.
"""
import csv, os

HERE = os.path.dirname(os.path.abspath(__file__))
SIMP = dict(cut=7.5521, n_cut=26191, whole=8.4075, cad=7.5842, obl=0.4293,
            margin=3254.34, mass=543.7, vf=0.679951, vol=440550.90, mid=0.8528)
PR326 = dict(cut=9.2460, n_cut=53243, margin=3388.6, mass=463.7, obl=0.4268)
WHAT = {
 "F0_none":            "no restriction operator (the control)",
 "FA_r1":              "A · Helmholtz filter r=1 voxel",
 "FA_r2":              "A · Helmholtz filter r=2 voxels",
 "FA_r3":              "A · Helmholtz filter r=3 voxels",
 "FB_robust":          "B · robust triple on the filtered field",
 "FC_t1":              "C · diffusion energy T=1",
 "FC_t4":              "C · diffusion energy T=4",
 "FC_t16":             "C · diffusion energy T=16",
 "FX_best_perim":      "A + perimeter C=1",
}


def rd(p):
    return list(csv.DictReader(open(p))) if os.path.exists(p) else []


def summary(a, key):
    p = os.path.join(HERE, "arms", a, "summary.txt")
    if not os.path.exists(p):
        return ""
    for line in open(p):
        if line.startswith(key):
            return line[len(key):].strip()
    return ""


def main():
    surf, simp_row = {}, None
    for r in rd(os.path.join(HERE, "m1_matched.csv")):
        if r["arm"] == "SIMP":
            if abs(float(r["achieved_vf"]) - 0.68) < 0.01:
                simp_row = r
        else:
            surf[r["arm"]] = r

    curve = {}
    for r in rd(os.path.join(HERE, "m2", "margin_curve.csv")):
        p = r["field"].replace("\\", "/").split("/")
        if "snap" in p:
            curve.setdefault(p[p.index("snap") - 1], {})[
                int(os.path.basename(r["field"])[2:])] = (
                    float(r["margin_worst_case"]), float(r["mass_grams"]),
                    r["load_path_connected"], r["accepted"])

    order = [a for a in WHAT if a in surf] + [a for a in sorted(surf) if a not in WHAT]

    print("\n## T1 — ★ THE THREE RESTRICTION OPERATORS, at MATCHED ITERATION 60")
    print("\n| arm | what | carved | vs SIMP | ★ n_cut | vs SIMP | whole | CAD | "
          "★ CAD err mm | mid % | volume mm3 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    if simp_row:
        s = simp_row
        print(f"| **SIMP 0.68** | the bar | **{float(s['dihedral_cut_deg']):.4f}** | — | "
              f"**{s['n_cut']}** | — | {float(s['dihedral_all_deg']):.4f} | "
              f"{float(s['dihedral_cad_deg']):.4f} | {float(s['obl_cad_rms_mm']):.4f} | "
              f"{100*float(s['midpoint_share']):.1f} | {float(s['volume_mm3']):.1f} |")
    print(f"| _PR 326 best_ | _perimeter C=1, η=1_ | _{PR326['cut']}_ | "
          f"_+{100*(PR326['cut']/SIMP['cut']-1):.1f}%_ | _{PR326['n_cut']}_ | "
          f"_+{100*(PR326['n_cut']/SIMP['n_cut']-1):.1f}%_ | _—_ | _—_ | "
          f"_{PR326['obl']}_ | _—_ | _—_ |")
    for a in order:
        r = surf[a]
        cut, nc = float(r["dihedral_cut_deg"]), int(r["n_cut"])
        print(f"| {a} | {WHAT.get(a,'')} | {cut:.4f} | {100*(cut/SIMP['cut']-1):+.1f}% | "
              f"{nc} | {100*(nc/SIMP['n_cut']-1):+.1f}% | "
              f"{float(r['dihedral_all_deg']):.4f} | {float(r['dihedral_cad_deg']):.4f} | "
              f"{float(r['obl_cad_rms_mm']):.4f} | "
              f"{100*float(r['midpoint_share']):.1f} | {float(r['volume_mm3']):.1f} |")

    print("\n## T2 — ★ WHAT IT COSTS. The margin as a CURVE (R3), and where it settled.")
    print("\n★ `settled` is the first snapshot from which the margin stays within "
          "2% of its value at iteration 60. `↑` means it never did — that arm is "
          "reporting a LOWER BOUND, not a cost.\n")
    print("| arm | @10 | @20 | @30 | @40 | @50 | @60 | settled at | vs SIMP | "
          "mass g | vf | load path |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    print(f"| **SIMP 0.68** | | | | | | **{SIMP['margin']}** | — | — | "
          f"**{SIMP['mass']}** | {SIMP['vf']} | yes |")
    for a in order:
        c = curve.get(a, {})
        if 60 not in c:
            continue
        cells = " | ".join(f"{c[i][0]:.0f}" if i in c else "" for i in (10, 20, 30, 40, 50, 60))
        fin = c[60][0]
        settled = ""
        for i in sorted(c):
            if i >= 10 and all(abs(c[j][0] / fin - 1) <= 0.02 for j in sorted(c) if j >= i):
                settled = str(i); break
        vf = summary(a, "achieved vf").split()[0] if summary(a, "achieved vf") else ""
        print(f"| {a} | {cells} | {settled if settled else '↑ never'} | "
              f"{100*(fin/SIMP['margin']-1):+.1f}% | {c[60][1]:.1f} | {vf} | "
              f"{'yes' if c[60][2]=='1' else 'NO'} |")

    print("\n## T3 — what each operator cost to run")
    print("\n| arm | s/iteration | filter s | filter % | in-loop cert s | "
          "optimisation only s |")
    print("|---|---|---|---|---|---|")
    for a in order:
        w = summary(a, "WALL PER ITERATION")
        fl = summary(a, "★ FILTER")
        ce = summary(a, "★ IN-LOOP CERT")
        oo = summary(a, "★ OPTIMISATION ONLY")
        print(f"| {a} | {w.split()[0] if w else ''} | {fl} | | {ce} | "
              f"{oo.split()[0] if oo else ''} |")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The handoff's tables, assembled from what the instruments wrote.

★ THIS SCRIPT COMPUTES NO GEOMETRY AND NO MECHANICS. Every roughness number
comes from `external_field_surface_probe` (m1_surface.csv), every margin, mass
and load-path answer from `analyze_fixed_design` through
`levelset_probe --certify-field` (m2/margin_curve.csv), and every trajectory
column from the optimiser's own `iterations.csv`. All this does is join them and
print. If a number is not in one of those files, it is not in a table.
"""
import csv, glob, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PR324 = os.path.join(REPO, "evidence", "2026-08-10-parametric-level-set")


def read_csv(p):
    if not os.path.exists(p):
        return []
    with open(p, newline="") as f:
        return list(csv.DictReader(f))


def summary_fields(path):
    """The optimiser's own summary.txt, as a dict of the lines that matter."""
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path):
        for key, name in (
            ("achieved vf", "vf"), ("MARGIN worst case", "margin"),
            ("max von Mises", "vm"), ("mass", "mass"),
            ("VERDICT", "verdict"), ("load path connected", "loadpath"),
            ("min-feature viols", "minfeat"),
            ("WALL PER ITERATION", "wall"),
            ("iterations run", "iters"),
        ):
            if line.startswith(key):
                out[name] = line[len(key):].strip()
    return out


def f(x, nd=4):
    try:
        return f"{float(x):.{nd}f}"
    except (TypeError, ValueError):
        return str(x)


# ── SIMP, the only bar (PR 324 and this task both measure against it alone) ──
SIMP = dict(cut=7.5521, n_cut=26191, whole=8.4075, cad=7.5842,
            margin=3254.34, mass=543.7, vm=0.016900, vf=0.679951, vol=440550.90)
# PR 324's ARM 2 — quoted as the thing being re-baselined, never as a bar.
PR324_ARM2 = dict(cut=14.1076, n_cut=79679, whole=11.5068, cad=7.8081,
                  margin=3391.74, mass=463.0114, vm=0.016216, vf=0.678839)


def main():
    # ★ THE SURFACE TABLE READS THE MATCHED-ITERATION FILE, NOT `rho`.
    # `levelset_probe` writes the BEST-COMPLIANCE iterate, which across these
    # arms is iteration 9, 20, 40, 55, 57 and 60. A table built off `rho`
    # compares arms at different points in their own lives, and it changed a
    # conclusion here: C=8 read as a catastrophic failure at its iteration 9 and
    # is the SMOOTHEST arm in the study at iteration 60. `m3_matched.csv` is
    # every arm's it0060 snapshot, measured in one invocation with SIMP.
    src = os.path.join(HERE, "m3_matched.csv")
    if not os.path.exists(src):
        src = os.path.join(HERE, "m1_surface.csv")
        print("NOTE: m3_matched.csv absent, falling back to m1_surface.csv "
              "(BEST-COMPLIANCE iterates, NOT matched)\n")
    surf = {r["arm"]: r for r in read_csv(src) if r["arm"] != "SIMP"}
    simp_rows = [r for r in read_csv(src) if r["arm"] == "SIMP"]

    marg = read_csv(os.path.join(HERE, "m2", "margin_curve.csv")) + \
        read_csv(os.path.join(HERE, "m4", "margin_curve.csv"))
    per_arm = {}
    for r in marg:
        parts = r["field"].replace("\\", "/").split("/")
        if "snap" in parts:
            arm = parts[parts.index("snap") - 1]
            per_arm.setdefault(arm, []).append(r)
    for v in per_arm.values():
        v.sort(key=lambda r: r["field"])

    arms = sorted(surf)

    # ── TABLE 1 — the one the task is about ────────────────────────────────
    print("\n## T1 — SURFACE, at MATCHED ITERATION 60 (design lattice, factor 2"
          " tricubic).\n★ NOT off `rho`, which is each arm's own"
          " best-compliance iterate and differs between arms by up to 51"
          " iterations.")
    print("\n| arm | carved | vs SIMP | ★ n_cut | vs SIMP | whole | CAD | "
          "carved share | mid % | volume mm3 |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    if simp_rows:
        s = simp_rows[0]
        share = int(s["n_cut"]) / int(s["tris"])
        print(f"| **SIMP rung 0.68** | **{f(s['dihedral_cut_deg'])}** | — | "
              f"**{s['n_cut']}** | — | {f(s['dihedral_all_deg'])} | "
              f"{f(s['dihedral_cad_deg'])} | {share*100:.1f}% | "
              f"{float(s['midpoint_share'])*100:.2f} | {f(s['volume_mm3'],1)} |")
    print(f"| _PR 324 ARM 2 (being re-baselined)_ | _{PR324_ARM2['cut']}_ | "
          f"_+{100*(PR324_ARM2['cut']/SIMP['cut']-1):.0f}%_ | "
          f"_{PR324_ARM2['n_cut']}_ | "
          f"_+{100*(PR324_ARM2['n_cut']/SIMP['n_cut']-1):.0f}%_ | "
          f"_{PR324_ARM2['whole']}_ | _{PR324_ARM2['cad']}_ | _42.9%_ | _57.86_ | _370148.5_ |")
    for a in arms:
        r = surf[a]
        cut, ncut = float(r["dihedral_cut_deg"]), int(r["n_cut"])
        share = ncut / int(r["tris"])
        print(f"| {a} | {f(cut)} | {100*(cut/SIMP['cut']-1):+.1f}% | {ncut} | "
              f"{100*(ncut/SIMP['n_cut']-1):+.1f}% | {f(r['dihedral_all_deg'])} | "
              f"{f(r['dihedral_cad_deg'])} | {share*100:.1f}% | "
              f"{float(r['midpoint_share'])*100:.2f} | {f(r['volume_mm3'],1)} |")

    # ── TABLE 2 — what it costs (R4: never a point) ────────────────────────
    #
    # ★ THE CURVE, NOT THE ENDPOINT — BUT NOT BECAUSE THE MARGIN IS NOISY.
    # T5 measures the margin on twenty consecutive iterates of a settled design
    # and finds a spread of 0.15%. It is not noise. What it IS, is SLOW: the
    # margin settles far later than the compliance does — one arm here moved
    # 27% in margin while moving 0.05% in compliance — so an arm stopped at 60
    # may still be climbing, and its margin is a LOWER BOUND rather than a cost.
    # The whole curve is printed so that is visible per arm.
    print("\n## T2 — WHAT IT COSTS. Margin as a CURVE, with mass and achieved "
          "vf beside it")
    print("\n★ `certified` is the arm's own summary: `levelset_probe` certifies "
          "the BEST-COMPLIANCE iterate, which is not always iteration 60 — the "
          "column beside it says which. ★ `median` and `min..max` are over the "
          "CONVERGED TAIL (snapshots from iteration 30 on).\n")
    print("| arm | margin @10 | @20 | @30 | @40 | @50 | @60 | ★ tail median | "
          "tail min..max | vs SIMP | certified (best it) | peak vM | mass g | "
          "achieved vf | verdict |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    print(f"| **SIMP rung 0.68** | | | | | | | **{SIMP['margin']}** | — | — | "
          f"{SIMP['margin']} | {SIMP['vm']} | **{SIMP['mass']}** | {SIMP['vf']} | ACCEPTED |")
    for a in arms:
        sm = summary_fields(os.path.join(HERE, "arms", a, "summary.txt"))
        rows = per_arm.get(a, [])
        curve = {}
        for r in rows:
            it = int(os.path.basename(r["field"])[2:])
            curve[it] = float(r["margin_worst_case"])
        cells = " | ".join(f(curve[i], 0) if i in curve else ""
                           for i in (10, 20, 30, 40, 50, 60))
        # ★ THE LEVEL IS TAKEN OVER THE CONVERGED TAIL, NOT THE WHOLE CURVE.
        # Iteration 1 is the seed and iteration 10 is still walking; including
        # them makes every arm's "range" the distance from its own start, which
        # says nothing about the design it ended on. Snapshots from 30 onward.
        tail = sorted(v for i, v in curve.items() if i >= 30)
        vals = tail if tail else sorted(curve.values())
        med = vals[len(vals) // 2] if vals else float("nan")
        rng = f"{vals[0]:.0f}..{vals[-1]:.0f}" if vals else ""
        vm = sm.get("vm", "").replace(" MPa", "")
        mass = sm.get("mass", "").replace(" g", "")
        vf = sm.get("vf", "").split()[0] if sm.get("vf") else ""
        # Which iterate the arm's own certificate belongs to, read from its log
        # rather than assumed — the loop prints it.
        cert_it = ""
        logp = os.path.join(HERE, "arms", a + ".log")
        if os.path.exists(logp):
            for line in open(logp):
                if line.startswith("certifying iteration "):
                    cert_it = line.split()[2]
        certm = sm.get("margin", "").split()[0] if sm.get("margin") else ""
        print(f"| {a} | {cells} | **{f(med,0)}** | {rng} | "
              f"{100*(med/SIMP['margin']-1):+.1f}% | {f(certm,1)} (it {cert_it}) | "
              f"{vm} | {f(mass,1)} | {vf} | {sm.get('verdict','')} |")

    # ── TABLE 3 — S1's drift, the reason for the re-baseline ───────────────
    print("\n## T3 — S1: what the constraint was actually holding")
    old = read_csv(os.path.join(PR324, "arm3", "B1_scratch_max", "iterations.csv"))
    new = read_csv(os.path.join(HERE, "arms", "RB1_volcount", "iterations.csv"))
    if old and new:
        print("\n| it | ★ WITHOUT (PR 324 ARM 2) occ_vol / printed / vf | "
              "★ WITH --volume-count occ_vol / printed / vf |")
        print("|---|---|---|")
        for i in (1, 10, 20, 30, 40, 50, 60):
            def cell(rows):
                for r in rows:
                    if int(r["iteration"]) == i:
                        return (f"{float(r['occupancy_volume']):.1f} / "
                                f"{r['printed_voxels']} / "
                                f"{float(r['achieved_vf']):.6f}")
                return ""
            print(f"| {i} | {cell(old)} | {cell(new)} |")
        def span(rows, col):
            vals = [float(r[col]) for r in rows]
            return min(vals), max(vals)
        for label, rows in (("WITHOUT", old), ("WITH", new)):
            lo, hi = span(rows, "achieved_vf")
            olo, ohi = span(rows, "occupancy_volume")
            print(f"\n{label}: occupancy_volume spans {olo:.2f}..{ohi:.2f} "
                  f"({ohi-olo:.2f}); achieved_vf spans {lo:.6f}..{hi:.6f} "
                  f"({hi-lo:.6f})")

    # ── TABLE 4 — the interface area the penalty actually prices ───────────
    print("\n## T4 — the functional itself: interface area over the trajectory")
    print("\n| arm | area @1 mm2 | @20 | @40 | @60 | vs re-baseline @60 | "
          "★ compliance @60 | last-10 change | kappa_rms | perim w |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    base_area = base_c = None
    for a in ["RB1_volcount"] + [x for x in arms if x != "RB1_volcount"]:
        rows = read_csv(os.path.join(HERE, "arms", a, "iterations.csv"))
        if not rows or "interface_area_mm2" not in rows[0]:
            continue
        by = {int(r["iteration"]): r for r in rows}
        def A(i):
            return float(by[i]["interface_area_mm2"]) if i in by else float("nan")
        last = max(by)
        c_last = float(by[last]["compliance"])
        # ★ IS IT CONVERGED? A frontier of arms stopped at a fixed iteration
        # count says nothing unless they are all at the same place on their own
        # curve. This is the compliance change over the final ten iterations,
        # which is the number that says whether 60 was enough for THIS weight —
        # a penalised arm has further to walk than an unpenalised one.
        c_prev = float(by[last - 10]["compliance"]) if (last - 10) in by else float("nan")
        conv = 100 * (c_last / c_prev - 1) if c_prev == c_prev else float("nan")
        if a == "RB1_volcount":
            base_area, base_c = A(last), c_last
        rel = (f"{100*(A(last)/base_area-1):+.1f}%"
               if base_area else "—")
        print(f"| {a} | {f(A(1),0)} | {f(A(20),0)} | {f(A(40),0)} | "
              f"{f(A(last),0)} | {rel} | {c_last:.8f} | {conv:+.3f}% | "
              f"{f(by[last]['kappa_rms'],5)} | {f(by[last]['perim_weight'],3)} |")


    # ── TABLE 5 — ★ HOW BIG IS THE COIN? ───────────────────────────────────
    #
    # Every iterate of one converged tail, certified. Until this existed, every
    # "costs X% of margin" in this task was a difference between two single
    # draws from an unmeasured distribution.
    print("\n## T5 — ★ THE MARGIN'S OWN SPREAD, on ONE converged trajectory")
    tail = {}
    for r in read_csv(os.path.join(HERE, "m4", "margin_curve.csv")):
        p = r["field"].replace("\\", "/").split("/")
        if "snap" in p and p[p.index("snap") - 1] == "A4_mask":
            it = int(os.path.basename(r["field"])[2:])
            if it >= 41:
                tail[it] = float(r["margin_worst_case"])
    if tail:
        vals = [tail[i] for i in sorted(tail)]
        n = len(vals)
        mean = sum(vals) / n
        sd = (sum((v - mean) ** 2 for v in vals) / max(1, n - 1)) ** 0.5
        lo, hi = min(vals), max(vals)
        comp = read_csv(os.path.join(HERE, "arms", "A4_mask", "iterations.csv"))
        cm = {int(r["iteration"]): float(r["compliance"]) for r in comp}
        ctail = [cm[i] for i in sorted(tail) if i in cm]
        cspread = (max(ctail) / min(ctail) - 1) * 100 if ctail else float("nan")
        print(f"\n{n} consecutive iterates (41..60) of `A4_mask`, each certified "
              f"by `analyze_fixed_design` at the production penalty.\n")
        print("| iterate | " + " | ".join(str(i) for i in sorted(tail)) + " |")
        print("|---" * (n + 1) + "|")
        print("| margin | " + " | ".join(f"{tail[i]:.0f}" for i in sorted(tail)) + " |")
        # ★ REPORTED IN TWO WINDOWS, BECAUSE LUMPING THEM INVERTS THE ANSWER.
        # Iterates 41 and 42 are still settling; including them gives a 10%
        # spread that reads as noise. The question this table exists to answer
        # is how much the margin moves on a design that has STOPPED moving, so
        # both windows are printed and the settled one is the answer.
        settled = [tail[i] for i in sorted(tail) if i >= 43]
        print(f"\nover ALL {n} iterates: mean {mean:.0f}, sd {sd:.0f} "
              f"({100*sd/mean:.1f}%), range {lo:.0f}..{hi:.0f} — but 41 and 42 "
              f"are still settling.")
        if settled:
            m2 = sum(settled) / len(settled)
            s2 = (sum((v - m2) ** 2 for v in settled) /
                  max(1, len(settled) - 1)) ** 0.5
            print(f"\n★ **over the SETTLED window 43..60 ({len(settled)} "
                  f"consecutive iterates): mean {m2:.0f}, sd {s2:.2f} — "
                  f"{100*s2/m2:.3f}% of the mean, range {min(settled):.0f}.."
                  f"{max(settled):.0f}, a spread of "
                  f"{100*(max(settled)/min(settled)-1):.2f}%.**")
        print(f"\n★ **THE CERTIFIED MARGIN IS NOT NOISE.** Over the same window "
              f"the compliance spans {cspread:.3f}%: the design is static and so "
              f"is its margin. The large swings elsewhere in this line of work "
              f"are REAL DESIGN DIFFERENCES, not measurement scatter — and §2's "
              f"table shows the margin settling far LATER than the compliance.")
        for lab, x in (("SIMP's 3254.34", 3254.34),):
            k = sum(1 for v in vals if v >= x)
            print(f"\n{k} of {n} of those iterates certify at or above {lab}.")


if __name__ == "__main__":
    main()

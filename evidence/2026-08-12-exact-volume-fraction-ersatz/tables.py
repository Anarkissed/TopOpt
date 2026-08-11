#!/usr/bin/env python3
"""Every table the handoff prints, built from the CSVs the instruments wrote.

Nothing is retyped: each number below is read out of a file produced by
`external_field_surface_probe` or by `analyze_fixed_design` through
`levelset_probe --certify-field`. If a file is missing the table says so rather
than printing a plausible blank.
"""
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def rows(path):
    p = os.path.join(HERE, path)
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return list(csv.DictReader(f))


def fnum(r, k, default=float("nan")):
    try:
        return float(r[k])
    except (KeyError, TypeError, ValueError):
        return default


def missing(name, path):
    print(f"[{name}: {path} not present — run reproduce.sh]")
    print()


# ── 1. THE HEADLINE. Matched iteration, one probe invocation, SIMP in the run.
def table_surface():
    rs = rows("m1_matched.csv")
    print("== 1. THE SURFACE, AT A MATCHED ITERATION, SIMP IN THE SAME RUN ==")
    if rs is None:
        return missing("surface", "m1_matched.csv")
    cert = {}
    cr = rows("m2_margin.csv")
    if cr:
        for c in cr:
            cert[os.path.basename(os.path.dirname(os.path.dirname(c["field"])))
                 + "/" + os.path.basename(c["field"])] = c
    hdr = ("arm", "carved", "n_cut", "whole", "CAD mm", "mid %", "volume mm3",
           "achieved vf")
    print("| " + " | ".join(hdr) + " |")
    print("|" + "|".join(["---"] * len(hdr)) + "|")
    for r in rs:
        print("| %s | %.4f | %s | %.4f | %.4f | %.2f%% | %.1f | %.6f |" % (
            r["arm"], fnum(r, "dihedral_cut_deg"), r["n_cut"],
            fnum(r, "dihedral_all_deg"), fnum(r, "obl_cad_rms_mm"),
            100.0 * fnum(r, "midpoint_share"), fnum(r, "volume_mm3"),
            fnum(r, "achieved_vf")))
    print()


# ── 2. THE MARGIN CURVE. R3 asks for the curve AND the settling iteration.
def table_margin():
    rs = rows("m2_margin.csv")
    print("== 2. THE MARGIN CURVE, AND WHERE IT SETTLES ==")
    if rs is None:
        return missing("margin", "m2_margin.csv")
    by_arm = {}
    for r in rs:
        field = r["field"]
        parts = field.split(os.sep)
        if "snap" not in parts:
            continue
        arm = parts[parts.index("snap") - 1]
        it = int(os.path.basename(field).replace("it", ""))
        by_arm.setdefault(arm, {})[it] = r
    for arm, d in sorted(by_arm.items()):
        its = sorted(d)
        print(f"\n{arm}")
        print("| iteration | " + " | ".join(str(i) for i in its) + " |")
        print("|" + "|".join(["---"] * (len(its) + 1)) + "|")
        print("| margin | " + " | ".join(
            "%.1f" % fnum(d[i], "margin_worst_case") for i in its) + " |")
        print("| mass g | " + " | ".join(
            "%.2f" % fnum(d[i], "mass_grams") for i in its) + " |")
        print("| accepted | " + " | ".join(str(d[i]["accepted"]) for i in its) + " |")
        print("| load path | " + " | ".join(
            str(d[i]["load_path_connected"]) for i in its) + " |")
        # ★ THE SETTLING ITERATION, DEFINED AND THEN APPLIED — not eyeballed.
        # The first iterate after which every later certified margin stays
        # within 1% of the last one. PR 326 measured a settled tail spanning
        # 0.15%, so 1% is loose enough to be a real statement about settling and
        # tight enough to exclude an arm that is still climbing.
        m = [fnum(d[i], "margin_worst_case") for i in its]
        last = m[-1]
        settle = None
        for a in range(len(its)):
            if all(abs(x - last) <= 0.01 * abs(last) for x in m[a:]):
                settle = its[a]
                break
        print("| | |")
        if settle is None:
            print("SETTLED: NO — still moving more than 1%% at iteration %d "
                  "(the margin is a LOWER BOUND)" % its[-1])
        else:
            print("SETTLED at iteration %d (every later certificate within 1%% "
                  "of %.1f)" % (settle, last))
    print()


# ── 3. THE EXPORT CONVENTION, as a separate axis (R2: F=2 rows only).
def table_export():
    rs = rows("m3_export.csv")
    print("== 3. THE EXPORT CONVENTION — SAME DESIGN, TWO FIELDS, F=2 ONLY ==")
    if rs is None:
        return missing("export", "m3_export.csv")
    print("| field | carved | n_cut | whole | CAD mm | mid % | volume mm3 |")
    print("|---|---|---|---|---|---|---|")
    for r in rs:
        print("| %s | %.4f | %s | %.4f | %.4f | %.2f%% | %.1f |" % (
            r["arm"], fnum(r, "dihedral_cut_deg"), r["n_cut"],
            fnum(r, "dihedral_all_deg"), fnum(r, "obl_cad_rms_mm"),
            100.0 * fnum(r, "midpoint_share"), fnum(r, "volume_mm3")))
    print()


# ── 4. R4 — the finite difference, all four (density, gradient) pairs.
def table_fd():
    print("== 4. R4 — THE SENSITIVITY AGAINST A CENTRAL DIFFERENCE ==")
    any_found = False
    for name in ("heaviside", "frac_k4", "frac_centre", "frac_soft", "frac_l1"):
        rs = rows(f"probe/fd_{name}/frac_fd.csv")
        if rs is None:
            continue
        any_found = True
        print(f"\n{name}")
        print("| kind | which | step | dV rel err | dC rel err |")
        print("|---|---|---|---|---|")
        for r in rs:
            dc = fnum(r, "pred_dC")
            print("| %s | %s | %s | %+.4f%% | %s |" % (
                r["kind"], r["which"], r["step"], 100.0 * fnum(r, "relerr_V"),
                ("%+.4f%%" % (100.0 * fnum(r, "relerr_C"))) if dc != 0.0 else "—"))
    if not any_found:
        missing("fd", "probe/fd_*/frac_fd.csv")
    print()


# ── 5. S1(a) — the fraction against k.
def table_k():
    rs = rows("probe/kreport/frac_kreport.csv")
    print("== 5. S1(a) — THE FRACTION AGAINST k ==")
    if rs is None:
        return missing("k", "probe/kreport/frac_kreport.csv")
    print("| k | cut cells | sampled cells | sum f_v | build s |")
    print("|---|---|---|---|---|")
    for r in rs:
        print("| %s | %s | %s | %.4f | %.3f |" % (
            r["k"], r["cut_cells"], r["sampled_cells"], fnum(r, "sum_f"),
            fnum(r, "build_s")))
    print()


# ── 6. the per-iteration cost of the fraction, as a share of an iteration.
def table_cost():
    print("== 6. WHAT THE FRACTION COSTS, AS A SHARE OF AN ITERATION ==")
    found = False
    for arm in sorted(os.listdir(os.path.join(HERE, "arms"))
                      if os.path.isdir(os.path.join(HERE, "arms")) else []):
        p = os.path.join("arms", arm, "iterations.csv")
        rs = rows(p)
        if not rs or "frac_build_ms" not in rs[0]:
            continue
        found = True
        # ★ THE FIRST ITERATION IS EXCLUDED AND THE REASON IS STATED: it carries
        # a cold solve (113 s against 28 s on PR 326's own re-baseline) because
        # nothing is warm, so including it would understate the fraction's share
        # by a factor of four.
        rs = rs[1:]
        if not rs:
            continue
        n = len(rs)
        b = sum(fnum(r, "frac_build_ms") for r in rs) / n
        s = sum(fnum(r, "frac_sens_ms") for r in rs) / n
        solve = sum(fnum(r, "solve_ms") for r in rs) / n
        wall = sum(fnum(r, "iteration_wall_s") for r in rs) / n * 1000.0
        print("%-16s  sampling %7.1f ms  sensitivity %7.1f ms  "
              "state solve %9.1f ms  iteration %9.1f ms  ->  the fraction is "
              "%.2f%% of an iteration" % (arm, b, s, solve, wall,
                                          100.0 * (b + s) / wall if wall else 0.0))
    if not found:
        print("[no arm has frac columns yet]")
    print()


for fn in (table_surface, table_margin, table_export, table_fd, table_k,
           table_cost):
    try:
        fn()
    except Exception as e:  # a broken table must not hide the others
        print(f"[{fn.__name__} failed: {e}]", file=sys.stderr)
        print(f"[{fn.__name__} failed: {e}]")
        print()

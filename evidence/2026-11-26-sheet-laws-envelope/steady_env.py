#!/usr/bin/env python3
"""Are the 2-cell rows still steady once the law is the off-grip envelope over the cut sweep?
usage: python3 -I steady_env.py <this folder>     (run envelope.py first)

The five criteria are notes28's, fixed in c78d7c6d before its long runs (steady.py in
../2026-11-25-sheet-laws-thin-members), applied UNCHANGED in kind; the only difference is that every
placement of the 11-26 cut sweep is a placement too:
  a. connected  every 2-cell fixture (every placement, the sweep's included) is kept by the guard at
                some pitch, with a free-surface and an off-grip cut population
  b. width      the 2-cell envelope at the law pitch is at most 1.25 x the 3-cell one, by 11-09's
                populations (bulk, free, cut_layer) AND by the law's (bulk, free, cut_off_grip)
  c. pitch      at each pitch measured, the 2-cell free-surface Kd is within 10 % of the 3-cell one
  d. placement  the 2-cell spread over the placements (off the grips: max of free and off-grip cut per
                placement, max / min) is at most 1.25 x the 3-cell spread, at the law pitch
  e. bending    the 2-cell bending error at the three densities is within +-20 % of its mean (at
                least +-5 points)
Writes steady_env.csv and prints the verdict per type: STEADY -> floor 2, else 3.
"""
import csv
import glob
import os
import sys

ev = os.path.abspath(sys.argv[1])
OLD = os.path.join(os.path.dirname(ev), "2026-11-25-sheet-laws-thin-members")
COLS = ("K_dev_max", "K_vol", "K_il_dev", "K_il_vol")


def rows(p):
    if not os.path.exists(p):
        return []
    with open(p) as f:
        return list(csv.DictReader(f))


def aliased(r):
    lib, meas = float(r["rho_lib"]), float(r["rho_meas"])
    return lib <= 0 or abs(meas - lib) / lib > 0.15


out, verdict = [], {}
for t in ("gyroid", "schwarz_d"):
    sw = rows(os.path.join(ev, t, "kenv_sweep.csv"))
    kw = rows(os.path.join(ev, t, "kenv_widths.csv"))
    if not sw:
        continue
    exact = rows(os.path.join(OLD, t, "k_exact_w_all.csv")) + rows(os.path.join(ev, t, "k_exact_w_all.csv"))
    bulk = {round(float(r["rho_lib"]), 5): float(r["Kd_bulk"]) for r in kw}
    ok_all = True
    for rho in sorted(bulk):
        P = [r for r in sw if abs(float(r["rho_lib"]) - rho) < 1e-6]
        E = [r for r in exact if abs(float(r["rho_lib"]) - rho) < 1e-4]
        # a: every 2-cell placement attempted is kept at some pitch
        tried = {round(float(r["cut_frac"]), 4) for r in E if int(r["N"]) == 2}
        kept = {round(float(r["cut_asked"]), 4) for r in P if int(r["N"]) == 2 and r["population"] == "free_surface"}
        og = {round(float(r["cut_asked"]), 4) for r in P if int(r["N"]) == 2 and r["population"] == "cut_off_grip"}
        a = tried == kept and og == {c for c in tried if c > 0}
        out.append((t, rho, "a_connected", f"{len(kept)} of {len(tried)} 2-cell placements kept, "
                    f"{len(og)} with an off-grip cut population", a))

        # b
        def env(n, pops):
            v = [float(r["Kd"]) for r in P if int(r["N"]) == n and r["population"] in pops]
            return max([bulk[rho]] + v)
        r_law = env(2, ("free_surface", "cut_off_grip")) / env(3, ("free_surface", "cut_off_grip"))
        r_1109 = env(2, ("free_surface", "cut_layer")) / env(3, ("free_surface", "cut_layer"))
        b = r_law <= 1.25 and r_1109 <= 1.25
        out.append((t, rho, "b_width", f"K2/K3 = {r_1109:.3f} (11-09 populations), {r_law:.3f} (the law's)", b))
        # c: at each pitch, the kept fixtures' max free surface, 2 cells over 3
        fr = {}
        keep = {}
        for r in E:
            k = (int(r["N"]), int(r["vpc"]), round(float(r["cut_frac"]), 4))
            if r["population"] == "free_surface":
                keep[k] = (not aliased(r)) and float(r["K_dev_max"]) > 0
        for r in E:
            k = (int(r["N"]), int(r["vpc"]), round(float(r["cut_frac"]), 4))
            if r["population"] == "free_surface" and keep.get(k):
                fr[(k[0], k[1])] = max(fr.get((k[0], k[1]), 0.0), float(r["K_dev_max"]))
        cs, cok = [], True
        for (n, v), k2 in sorted(fr.items()):
            if n != 2 or (3, v) not in fr:
                continue
            cs.append(f"vpc{v} {k2 / fr[(3, v)]:.3f}")
            cok = cok and abs(k2 / fr[(3, v)] - 1) <= 0.10
        c = cok and bool(cs)
        out.append((t, rho, "c_pitch", "free K2/K3: " + (", ".join(cs) if cs else "none"), c))

        # d: the spread over the placements at the law pitch
        def spread(n):
            per = {}
            for r in P:
                if int(r["N"]) == n and r["population"] in ("free_surface", "cut_off_grip"):
                    cu = round(float(r["cut_asked"]), 4)
                    per[cu] = max(per.get(cu, 0.0), float(r["Kd"]))
            v = [x for x in per.values() if x > 0]
            return (max(v) / min(v), len(v)) if v else (0.0, 0)
        (s2, n2), (s3, n3) = spread(2), spread(3)
        d = n2 > 0 and n3 > 0 and s2 <= 1.25 * s3
        out.append((t, rho, "d_placement", f"spread {s2:.3f} over {n2} placements (2 cells) vs {s3:.3f} over {n3} (3 cells)", d))
        ok_all = ok_all and a and b and c and d
    errs = []
    for dpath in sorted(glob.glob(os.path.join(OLD, "bend", f"{t}_vf*_vpc24_*"))):
        for r in rows(os.path.join(dpath, f"{t}_bend.csv")):
            if int(r["cells_across"]) == 2:
                errs.append((float(r["cell_rho"]), float(r["bend_err_pct"])))
    if len(errs) == 3:
        m = sum(e for _, e in errs) / 3
        tol = max(0.2 * abs(m), 5.0)
        e = all(abs(x - m) <= tol for _, x in errs)
        out.append((t, 0.0, "e_bending", "2-cell error " + ", ".join(f"rho {r:.3f}: {x:+.2f} %" for r, x in sorted(errs))
                    + f"; mean {m:+.2f} %, band +-{tol:.2f}", e))
    else:
        e = False
        out.append((t, 0.0, "e_bending", f"{len(errs)} of 3 densities measured", e))
    verdict[t] = ok_all and e

with open(os.path.join(ev, "steady_env.csv"), "w") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["type", "rho", "criterion", "detail", "pass"])
    for t, rho, crit, det, p in out:
        w.writerow([t, f"{rho:.5f}" if rho else "", crit, det.replace(", ", "; "), int(bool(p))])
for t, rho, crit, det, p in out:
    print(f"{t:9s} {rho:7.5f} {crit:12s} {'PASS' if p else 'FAIL'}  {det}")
for t, v in verdict.items():
    print(f"{t}: the 2-cell rows are {'STEADY -> floor 2' if v else 'NOT steady -> floor 3'}")

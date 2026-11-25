#!/usr/bin/env python3
"""Are the 2-cell rows steady? The five criteria fixed in the timing commit (c78d7c6d), before the
long runs, applied to this folder's CSVs. usage: python3 -I steady.py <this folder>

  a. connected  every 2-cell fixture at the law pitch passes the aliasing guard (its ladder
                included), with a free-surface and a cut population (all five placements kept)
  b. width      the 2-cell envelope at the law pitch is at most 1.25 x the 3-cell one, by 11-09's
                populations and with the cut layer off the grips
  c. pitch      at each pitch measured, the 2-cell free-surface Kd is within 10 % of the 3-cell one
  d. placement  the 2-cell spread over the placements (off the grips) is at most 1.25 x the 3-cell one
  e. bending    the 2-cell bending error at the three densities is within +-20 % of its mean (at
                least +-5 points)
Writes steady.csv (one line per type, density and criterion) and prints the verdict per type.
"""
import csv
import glob
import os
import sys

ev = sys.argv[1]
out = []


def rows(p):
    with open(p) as f:
        return list(csv.DictReader(f))


verdict = {}
for t in ("gyroid", "schwarz_d"):
    if not os.path.exists(os.path.join(ev, t, "kfit_widths.csv")):
        continue
    kf = rows(os.path.join(ev, t, "kfit_widths.csv"))
    kc = rows(os.path.join(ev, t, "kcheck_widths.csv"))
    ok_all = True
    rhos = sorted({float(r["rho_lib"]) for r in kf})
    for rho in rhos:
        f = {int(r["N"]): r for r in kf if abs(float(r["rho_lib"]) - rho) < 1e-9}
        c = {(int(r["N"]), int(r["vpc"])): r for r in kc if abs(float(r["rho_lib"]) - rho) < 1e-9}
        law2 = [r for (n, v), r in c.items() if n == 2 and r["law_pitch"] == "1"]
        law3 = [r for (n, v), r in c.items() if n == 3 and r["law_pitch"] == "1"]
        bulk = float(f[2]["Kd_bulk"]) if 2 in f else 0.0
        # a
        a = bool(law2) and int(law2[0]["fixtures"]) == 5 and float(law2[0]["Kd_free_max"]) > 0 \
            and float(law2[0]["Kd_cut_layer_max"]) > 0
        out.append((t, rho, "a_connected", f"law pitch vpc{law2[0]['vpc'] if law2 else '-'}, "
                    f"{law2[0]['fixtures'] if law2 else 0} of 5 placements kept", a))
        # b
        if 2 in f and 3 in f and law2 and law3:
            r11 = float(f[2]["Kd_N"]) / float(f[3]["Kd_N"])
            og2 = max(bulk, float(law2[0]["Kd_free_max"]), float(law2[0]["Kd_cut_off_grip_max"]))
            og3 = max(bulk, float(law3[0]["Kd_free_max"]), float(law3[0]["Kd_cut_off_grip_max"]))
            b = r11 <= 1.25 and og2 / og3 <= 1.25
            out.append((t, rho, "b_width", f"K2/K3 = {r11:.3f} (11-09 populations), {og2 / og3:.3f} (off the grips)", b))
        else:
            b = False
            out.append((t, rho, "b_width", "missing 2- or 3-cell rows", b))
        # c
        cs = []
        cok = True
        for (n, v), r in sorted(c.items()):
            if n != 2 or (3, v) not in c:
                continue
            k2 = float(r["Kd_free_max"])
            k3 = float(c[(3, v)]["Kd_free_max"])
            if k2 <= 0 or k3 <= 0:
                continue
            cs.append(f"vpc{v} {k2 / k3:.3f}")
            cok = cok and abs(k2 / k3 - 1) <= 0.10
        out.append((t, rho, "c_pitch", "free K2/K3: " + (", ".join(cs) if cs else "none"), cok and bool(cs)))
        # d
        if law2 and law3:
            s2, s3 = float(law2[0]["Kd_og_spread"]), float(law3[0]["Kd_og_spread"])
            d = s2 <= 1.25 * s3
            out.append((t, rho, "d_placement", f"spread {s2:.3f} (2 cells) vs {s3:.3f} (3 cells)", d))
        else:
            d = False
            out.append((t, rho, "d_placement", "missing", d))
        ok_all = ok_all and a and b and cok and bool(cs) and d
    # e: bending at the three densities, vpc 24
    errs = []
    for dpath in sorted(glob.glob(os.path.join(ev, "bend", f"{t}_vf*_vpc24_*"))):
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

with open(os.path.join(ev, "steady.csv"), "w") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["type", "rho", "criterion", "detail", "pass"])
    for t, rho, crit, det, p in out:
        w.writerow([t, f"{rho:.5f}" if rho else "", crit, det.replace(", ", "; "), int(bool(p))])
for t, rho, crit, det, p in out:
    print(f"{t:9s} {rho:7.5f} {crit:12s} {'PASS' if p else 'FAIL'}  {det}")
for t, v in verdict.items():
    print(f"{t}: the 2-cell rows are {'STEADY -> floor 2' if v else 'NOT steady -> floor 3'}")

#!/usr/bin/env python3
"""crosscheck.py EV_DIR OLD_EV_DIR: the measured rows against the published laws. A CROSS-CHECK ONLY: no number here
enters a table (this project measured textbook stiffness 23-52 % optimistic at few cells).

Published (all for the solid's E_s and yield sigma_ys; rho the relative density):
  Gibson & Ashby, Cellular Solids, 2nd ed., CUP 1997, doi:10.1017/CBO9781139878326 -- bending-dominated (open cell):
      E/E_s ~ 1.0 rho^2,  plastic collapse sigma/sigma_ys ~ 0.3 rho^1.5
  Ashby, Phil. Trans. R. Soc. A 364 (2006) 15-30, doi:10.1098/rsta.2005.1678 -- stretch-dominated:
      E/E_s ~ rho/3,  sigma/sigma_ys ~ 0.3 rho   (bending-dominated as Gibson-Ashby above)
  Lumpe & Stankovic, PNAS 118 (2021) e2003504118, doi:10.1073/pnas.2003504118 (ETH: 10.3929/ethz-b-000457598):
      the class of each network -- BCC (8 bars a node) and diamond (4) bending-dominated, so E ~ rho^2;
      SC stretch-dominated along its bars (E_100 ~ rho), its shear carried by bending.
Measured here:
  stiffness  E_100 / E_s of each new tensor row (the [100] Young's modulus of the cubic tensor), and its log-log slope
             over the new rows;
  strength   the strut law's own uniaxial first-yield bound in any direction: a macro uniaxial stress s has
             vm = s and |p| = s/3, so strut vm <= (Kd + Kv/3) s and the law certifies s / sigma_ys = 1 / (Kd + Kv/3)
             (in-plane; the interlayer pair is the layer analogue). First yield at the hottest voxel of the hottest
             strut, in the worst direction, sits BELOW a plastic-collapse law: the ratio says by how much.
"""
import csv, math, os, sys

EV, OLD = sys.argv[1], sys.argv[2]
ES = 3500.0
CLASS = {"bcc": "bending", "diamond": "bending", "sc": "stretch (axial)"}


def e100(c11, c12):
    return (c11 - c12) * (c11 + 2 * c12) / (c11 + c12)


def slope(pts):
    xs = [math.log(p[0]) for p in pts]
    ys = [math.log(p[1]) for p in pts]
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)


out = open(os.path.join(EV, "crosscheck.csv"), "w")
out.write("type,quantity,rho,measured,published,published_law,measured_over_published\n")
for t in ("bcc", "diamond", "sc"):
    print("== %s (%s)" % (t, CLASS[t]))
    rows = [r for b in ("floor", "low", "high") if os.path.exists(os.path.join(EV, "tensor", b, t + "_sweep.csv")) for r in csv.DictReader(open(os.path.join(EV, "tensor", b, t + "_sweep.csv"))) if r["validated"] == "1"]
    pts, seen = [], set()
    for r in sorted(rows, key=lambda r: float(r["rho_row"])):
        rho = float(r["rho_row"])
        if r["rho_row"] in seen:   # two targets on one voxel set, or a row in two blocks
            continue
        seen.add(r["rho_row"])
        e = e100(float(r["C11"]), float(r["C12"])) / ES
        pub, law = (rho ** 2, "GA rho^2") if CLASS[t] == "bending" else (rho / 3, "Ashby rho/3")
        pts.append((rho, e))
        out.write("%s,E100/Es,%.5f,%.6g,%.6g,%s,%.3f\n" % (t, rho, e, pub, law, e / pub))
        print("  stiffness rho %.5f  E100/Es %.5g  %s %.5g  ratio %.3f" % (rho, e, law, pub, e / pub))
    if len(pts) >= 3:
        print("  stiffness log-log slope over the new rows: %.3f (bending 2, stretch 1)" % slope(pts))
        out.write("%s,E100_slope,,%.4f,%s,,\n" % (t, slope(pts), "2" if CLASS[t] == "bending" else "1"))
    for d, tag in ((os.path.join(EV, t), "new"), (os.path.join(OLD, t), "11-09")):
        f = os.path.join(d, "kfit.csv")
        if not os.path.exists(f):
            continue
        for r in csv.DictReader(open(f)):
            rho = float(r["rho_lib"])
            s = 1.0 / (float(r["Kd_cert"]) + float(r["Kv_cert"]) / 3.0)
            ga = 0.3 * rho ** 1.5
            st = 0.3 * rho
            pub, law = (ga, "GA 0.3 rho^1.5") if CLASS[t] == "bending" else (st, "Ashby 0.3 rho")
            out.write("%s,first_yield_uniaxial/sigma_ys (%s row),%.5f,%.6g,%.6g,%s,%.3f\n" % (t, tag, rho, s, pub, law, s / pub))
            print("  strength  rho %.5f (%5s)  1/(Kd+Kv/3) %.5g  %s %.5g  ratio %.3f" % (rho, tag, s, law, pub, s / pub))
out.close()

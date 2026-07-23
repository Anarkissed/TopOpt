#!/usr/bin/env python3
"""Summarise trajectory.csv: per (fixture, k, cadence) the terminal + worst values."""
import csv, sys, collections

FIELDS = ("fixture,band_k,cadence,iter,active_frac,C_full,C_restricted,dC_rel,"
          "dSens_rel,mean_drho,max_drho,outside_band_rel,band_escapes,"
          "max_escaping_rho").split(",")
rows = [r for r in csv.DictReader(open(sys.argv[1]), fieldnames=FIELDS)
        if r["fixture"] != "fixture"]
by = collections.defaultdict(list)
for r in rows:
    by[(r["fixture"], int(r["band_k"]), int(r["cadence"]))].append(r)

hdr = (f"{'fixture':<16} {'k':>2} {'cad':>3} {'iters':>5} | {'active% end':>11} "
       f"{'active% min':>11} | {'worst dC/C':>10} {'worst dSens':>11} | "
       f"{'end mean|dr|':>12} {'end max|dr|':>11} | {'escapes':>7} {'max esc rho':>11}")
print(hdr)
print("-" * len(hdr))
for key in sorted(by):
    rs = sorted(by[key], key=lambda r: int(r["iter"]))
    end = rs[-1]
    print(f"{key[0]:<16} {key[1]:>2} {key[2]:>3} {len(rs):>5} | "
          f"{100*float(end['active_frac']):>10.2f}% "
          f"{100*min(float(r['active_frac']) for r in rs):>10.2f}% | "
          f"{max(float(r['dC_rel']) for r in rs):>10.2e} "
          f"{max(float(r['dSens_rel']) for r in rs):>11.2e} | "
          f"{float(end['mean_drho']):>12.3e} {float(end['max_drho']):>11.3e} | "
          f"{max(int(r['band_escapes']) for r in rs):>7} "
          f"{max(float(r['max_escaping_rho']) for r in rs):>11.4f}")

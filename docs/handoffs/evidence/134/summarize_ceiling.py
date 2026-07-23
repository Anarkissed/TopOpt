#!/usr/bin/env python3
"""Summarise ceiling.csv into the handoff tables (percent, per rung, per k)."""
import csv, sys, collections

path = sys.argv[1]
rows = list(csv.DictReader(open(path)))
by = collections.defaultdict(list)
for r in rows:
    by[(r["fixture"], int(r["rung"]))].append(r)

print(f"{'fixture':<26} {'rung':>4} {'iters':>5} {'elems':>9} | "
      f"{'k=0 first/mid/last':>26} | {'k=2 last':>8} {'k=4 last':>8} {'k=8 last':>8} | {'nodes k=4 last':>13}")
for key in sorted(by):
    rs = sorted(by[key], key=lambda r: (int(r["iter"]), int(r["boundary"])))
    n = len(rs)
    f = lambda r, c: 100 * float(r[c])
    first, mid, last = rs[0], rs[n // 2], rs[-1]
    print(f"{key[0]:<26} {key[1]:>4} {n:>5} {int(rs[0]['domain_elems']):>9} | "
          f"{f(first,'elem_frac_k0'):>7.2f}{f(mid,'elem_frac_k0'):>9.2f}{f(last,'elem_frac_k0'):>9.2f} | "
          f"{f(last,'elem_frac_k2'):>8.2f} {f(last,'elem_frac_k4'):>8.2f} {f(last,'elem_frac_k8'):>8.2f} | "
          f"{f(last,'node_frac_k4'):>13.2f}")

print()
print("PER-ITERATION DETAIL (every row, k=0/2/4/8 element %)")
for key in sorted(by):
    rs = sorted(by[key], key=lambda r: (int(r["iter"]), int(r["boundary"])))
    print(f"\n-- {key[0]} rung {key[1]} ({int(rs[0]['domain_elems'])} elements) --")
    print("iter  k=0    k=2    k=4    k=8   | nodes k=0  k=2   k=4   k=8")
    step = max(1, len(rs) // 14)
    for i, r in enumerate(rs):
        if i % step and i != len(rs) - 1:
            continue
        print(f"{int(r['iter']):>4} "
              f"{100*float(r['elem_frac_k0']):>6.2f} {100*float(r['elem_frac_k2']):>6.2f} "
              f"{100*float(r['elem_frac_k4']):>6.2f} {100*float(r['elem_frac_k8']):>6.2f} | "
              f"{100*float(r['node_frac_k0']):>9.2f} {100*float(r['node_frac_k2']):>5.2f} "
              f"{100*float(r['node_frac_k4']):>5.2f} {100*float(r['node_frac_k8']):>5.2f}"
              + ("  <- rung boundary" if int(r["boundary"]) else ""))

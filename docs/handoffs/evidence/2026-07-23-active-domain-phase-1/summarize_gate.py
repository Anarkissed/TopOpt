#!/usr/bin/env python3
"""Render the ACTIVE DOMAIN phase 1 gate table from gate/gate.csv.

Usage:  python3 summarize_gate.py [gate/gate.csv]

The CSV is written by core/tests/harness/active_domain_gate.cpp (mode `gate`),
one row per evaluated ladder rung, comparing the band-OFF and band-ON (k = 4)
postures of the SAME production ladder on the SAME fixture.
"""
import csv
import os
import sys

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "gate", "gate.csv")

with open(path) as fh:
    rows = list(csv.DictReader(fh))

print(f"{'rung':>4} {'vf':>5} {'f_bar':>7} {'iters off/on':>13} "
      f"{'mean|drho|':>12} {'max|drho|':>12} {'dC/C':>10} {'dM/M':>10} "
      f"{'verdict off/on':>15}")
print("-" * 100)
worst_mean = worst_max = worst_m = 0.0
verdicts_match = True
for r in rows:
    mean = float(r["mean_abs_drho"])
    mx = float(r["max_abs_drho"])
    mrel = float(r["margin_rel_delta"])
    worst_mean = max(worst_mean, mean)
    worst_max = max(worst_max, mx)
    worst_m = max(worst_m, mrel)
    off_v = "accept" if r["off_accepted"] == "1" else "REJECT"
    on_v = "accept" if r["on_accepted"] == "1" else "REJECT"
    if off_v != on_v:
        verdicts_match = False
    print(f"{r['rung']:>4} {float(r['vf']):>5.2f} {float(r['on_f_bar']):>7.4f} "
          f"{r['off_iters']:>6}/{r['on_iters']:<6} "
          f"{mean:>12.4e} {mx:>12.4e} {float(r['compliance_rel_delta']):>10.2e} "
          f"{mrel:>10.2e} {off_v:>7}/{on_v:<7}")

print("-" * 100)
print(f"WORST mean|drho| {worst_mean:.4e}   (stated bar: <= 1e-4)")
print(f"WORST max|drho|  {worst_max:.4e}")
print(f"WORST margin relative delta {worst_m:.4e}   (stated bar: <= 1e-3 = 0.1%)")
print(f"gate verdicts identical: {'YES' if verdicts_match else 'NO'}")

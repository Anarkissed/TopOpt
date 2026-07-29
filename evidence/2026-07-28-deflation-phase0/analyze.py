#!/usr/bin/env python3
"""Cross-fixture reducer for the deflation Phase-0 probe.

Reads deflation_<fixture>.csv files (written by deflation_probe) and prints the
per-rung D1 (component count / deflation dim) and D2 (measured iteration cut +
effective condition number) tables, plus the headline cross-fixture trend.

Usage:  python3 analyze.py <csv_dir> [<csv_dir> ...]
Each dir is expected to hold deflation_load.csv and/or deflation_box.csv.
"""
import csv
import sys
import glob
import os


def load(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def fnum(row, key):
    try:
        return float(row[key])
    except (KeyError, ValueError):
        return float("nan")


def report(path):
    rows = load(path)
    name = os.path.basename(path).replace("deflation_", "").replace(".csv", "")
    print(f"\n===== {path}  [{name}] =====")
    print(f"{'vf':>5} {'status':>13} {'printed':>8} {'ng':>7} "
          f"{'nc6':>4} {'nc26':>4} {'k':>4} {'setup':>6} {'memMB':>6} "
          f"{'base':>6} {'defl':>6} {'cut%':>6} {'kappaB':>10} {'kappaD':>9} {'kfac':>5}")
    cuts = []
    for r in rows:
        base = int(fnum(r, "iters_base"))
        defl = int(fnum(r, "iters_defl"))
        cut = fnum(r, "cut_pct")
        kb = fnum(r, "kappa_base")
        kd = fnum(r, "kappa_defl")
        kfac = kb / kd if kd > 0 else float("nan")
        cuts.append(cut)
        print(f"{fnum(r,'vf'):5.2f} {r['status']:>13} {int(fnum(r,'printed')):8d} "
              f"{int(fnum(r,'ng')):7d} {int(fnum(r,'nc6')):4d} {int(fnum(r,'nc26')):4d} "
              f"{int(fnum(r,'k')):4d} {int(fnum(r,'setup_mv')):6d} {fnum(r,'mem_mb'):6.1f} "
              f"{base:6d} {defl:6d} {cut:6.1f} {kb:10.0f} {kd:9.0f} {kfac:5.1f}")
    if cuts:
        print(f"  mean cut = {sum(cuts)/len(cuts):.1f}%   "
              f"min = {min(cuts):.1f}%   max = {max(cuts):.1f}%")
    # self-check: iters_base vs library mf
    worst = 0
    for r in rows:
        worst = max(worst, abs(int(fnum(r, "iters_base")) - int(fnum(r, "iters_mf"))))
    print(f"  operator-reconstruction self-check: max |base-mf| = {worst} iters "
          f"({'OK' if worst <= 2 else 'SUSPECT'})")


def main():
    dirs = sys.argv[1:] or ["."]
    paths = []
    for d in dirs:
        if os.path.isfile(d):
            paths.append(d)
        else:
            paths += sorted(glob.glob(os.path.join(d, "deflation_*.csv")))
    if not paths:
        print("no deflation_*.csv found")
        return
    for p in paths:
        report(p)


if __name__ == "__main__":
    main()

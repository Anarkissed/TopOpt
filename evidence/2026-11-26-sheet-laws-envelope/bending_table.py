#!/usr/bin/env python3
"""(c) of the ruling of 2026-11-26, item 3: the bending error at 3, 4 and 6 cells across (2 for the
floor kept in the law), plainly: cells across -> error %. usage: python3 -I bending_table.py <this folder>

  the record:  ../2026-11-25-sheet-laws-thin-members/bend/<type>_vf*_vpc24_nc2-3-4-5-6-7-8/<type>_bend.csv
  the check:   bend/<type>_vf*_vpc{32,36}_nc2-3-4-6/<type>_bend.csv (this folder, finer pitch)
The error: + means the averaged (homogenized) member is that much too stiff in bending; core scales its
tensor by 1 / (1 + error) (sheet_stiffness_scale). Writes bending_346.csv.
"""
import csv
import glob
import os
import re
import sys

ev = os.path.abspath(sys.argv[1])
OLD = os.path.join(os.path.dirname(ev), "2026-11-25-sheet-laws-thin-members")
NS = (2, 3, 4, 6)
out = []
for t in ("gyroid", "schwarz_d"):
    for base, tag in ((OLD, "vpc24 (the record)"), (ev, "finer (11-26)")):
        for d in sorted(glob.glob(os.path.join(base, "bend", f"{t}_vf*_vpc*_nc*"))):
            m = re.search(r"_vf([0-9.]+)_vpc(\d+)_nc", os.path.basename(d))
            p = os.path.join(d, f"{t}_bend.csv")
            if not m or not os.path.exists(p):
                continue
            with open(p) as f:
                R = {int(r["cells_across"]): r for r in csv.DictReader(f)}
            if not R:
                continue
            rho = float(next(iter(R.values()))["cell_rho"])
            out.append(dict(type=t, vf=m.group(1), vpc=int(m.group(2)), rho=rho, src=tag,
                            err={n: float(R[n]["bend_err_pct"]) for n in NS if n in R}))
with open(os.path.join(ev, "bending_346.csv"), "w") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["type", "target_rho", "cell_rho", "vpc", "source"] + [f"err_pct_N{n}" for n in NS])
    for o in out:
        w.writerow([o["type"], o["vf"], f"{o['rho']:.4f}", o["vpc"], o["src"]]
                   + [f"{o['err'][n]:+.2f}" if n in o["err"] else "" for n in NS])
print("cells across ->      2         3         4         6     (bending error, % too stiff)")
for o in out:
    print(f"{o['type']:9s} rho {o['rho']:.4f} vpc{o['vpc']:<2d} " + " ".join(
        f"{o['err'][n]:+8.2f}%" if n in o["err"] else "        ." for n in NS) + f"   {o['src']}")

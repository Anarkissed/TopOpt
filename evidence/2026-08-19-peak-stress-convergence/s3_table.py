#!/usr/bin/env python3
"""s3_table.py — the positive control's table and its fitted exponent."""
import csv, math, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "s3_cavity.csv")
rows = list(csv.DictReader(open(PATH)))

def fit(hs, ys):
    xs = [math.log(1.0 / h) for h in hs]
    ls = [math.log(y) for y in ys]
    n = len(xs); mx = sum(xs)/n; ml = sum(ls)/n
    sxx = sum((x-mx)**2 for x in xs)
    q = sum((x-mx)*(l-ml) for x,l in zip(xs,ls))/sxx
    a = ml - q*mx
    ssr = sum((l-(a+q*x))**2 for x,l in zip(xs,ls))
    sst = sum((l-ml)**2 for l in ls)
    return q, (1-ssr/sst if sst>0 else float('nan'))

groups = {}
for r in rows:
    groups.setdefault((r["arm"], r["radius_frac"]), []).append(r)

for (arm, rad), rs in sorted(groups.items()):
    rs.sort(key=lambda r: int(r["resolution"]))
    hs = [float(r["spacing_mm"]) for r in rs]
    ks = [float(r["K"]) for r in rs]
    print("=" * 72)
    print(f"ARM {arm}   R/L = {float(rad):.6g}   ({len(rs)} rungs)")
    print("=" * 72)
    print(f"{'res':>5} {'h mm':>8} {'R/h':>7} {'dofs':>10} {'K = peak/sigma0':>17} "
          f"{'vol err %':>10} {'cut':>7} {'wall s':>8}")
    for r in rs:
        ve = 100.0*(float(r["vol_mm3"])-float(r["vol_exact_mm3"]))/float(r["vol_exact_mm3"])
        rh = float(rad)*float(r["side_mm"])/float(r["spacing_mm"])
        print(f"{r['resolution']:>5} {float(r['spacing_mm']):8.4f} {rh:7.2f} "
              f"{int(r['dofs']):>10} {float(r['K']):17.8f} {ve:10.4f} "
              f"{int(r['n_cut']):>7} {float(r['wall_s']):8.1f}")
    if len(rs) >= 2 and min(ks) > 0:
        q, r2 = fit(hs, ks)
        pw = " ".join(f"{math.log(ks[i+1]/ks[i])/math.log(hs[i]/hs[i+1]):+.4f}"
                      for i in range(len(ks)-1))
        print(f"  global q = {q:+.5f}  (R^2 {r2:.4f})     pairwise  {pw}")
        print(f"  K spread over the ladder: {100.0*(max(ks)-min(ks))/(sum(ks)/len(ks)):.3f} %"
              f"   (min {min(ks):.6f}, max {max(ks):.6f})")
        if rs[0]["K_southwell"]:
            print(f"  Southwell K (infinite medium, nu=0.35): "
                  f"{float(rs[0]['K_southwell']):.6f}")
    print()

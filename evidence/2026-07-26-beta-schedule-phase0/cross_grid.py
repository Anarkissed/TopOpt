#!/usr/bin/env python3
# Cross-grid trend (B4): pull the headline numbers per grid so the schedule-shape
# conclusion can be read across scale, not from one rung of one grid (PR 203 trap).
# Usage: cross_grid.py small med large
import csv, sys, os

def load(d):
    fp = os.path.join(d,'summary.csv')
    return list(csv.DictReader(open(fp))) if os.path.exists(fp) else []
def fl(x,k):
    try: return float(x[k])
    except: return float('nan')
def ii(x,k):
    try: return int(x[k])
    except: return -1

print(f"{'grid':<8}{'solid':>7}{'Σit_base':>9}{'Σit_cap16':>10}{'Δ%':>6}"
      f"{'cap16_verdicts':>16}{'cap16_maxflips':>15}{'β32_ΔMnd(r0..r3)':>22}")
for d in sys.argv[1:]:
    S = load(d)
    if not S: print(f"{d:<8} (no summary)"); continue
    solid = ii(S[0],'solid')
    def rungs(n): return sorted([r for r in S if r['schedule']==n], key=lambda r: ii(r,'rung'))
    def sit(n): return sum(ii(r,'iters') for r in rungs(n))
    base=rungs('base'); cap=rungs('cap16')
    baseit=sit('base'); capit=sit('cap16')
    # verdict flips base->cap16
    vf="identical"
    if cap:
        flips=[(ii(r,'rung'),ii(b,'accepted'),ii(r,'accepted'))
               for r,b in zip(cap,base) if ii(r,'accepted')!=ii(b,'accepted')]
        vf = "identical" if not flips else str(flips)
        maxfl = max((ii(r,'flips_vs_base') for r in cap), default=-1)
    else:
        maxfl=-1
    dpct = 100.0*(capit-baseit)/baseit if baseit else 0
    print(f"{os.path.basename(d):<8}{solid:>7}{baseit:>9}{capit:>10}{dpct:>+6.1f}"
          f"{vf:>16}{maxfl:>15}", end="")
    # β=32 stage ΔMnd from per-iter base: last two distinct-beta stages' proj mnd
    pi = os.path.join(d,'periter_base.csv')
    dmnd=[]
    if os.path.exists(pi):
        rows=list(csv.DictReader(open(pi)))
        for rung in range(4):
            rr=sorted([x for x in rows if ii(x,'rung')==rung and fl(x,'beta')==32.0],
                      key=lambda x: ii(x,'iter'))
            if rr: dmnd.append(f"{fl(rr[0],'mnd_proj'):.3f}->{fl(rr[-1],'mnd_proj'):.3f}")
            else: dmnd.append("--")
    print(f"   {' '.join(dmnd)}")

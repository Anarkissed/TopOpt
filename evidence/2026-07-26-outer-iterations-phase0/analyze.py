#!/usr/bin/env python3
# Phase-0 analysis of the outer_iter_probe per-iteration CSVs.
#
# Q0 established the basin noise floor: two should-agree runs (cg_tol 1e-8 vs
# 1e-9) flip ZERO voxels' classification at every rung's terminal. So the
# material-change threshold is >= 1 voxel flip; we also report graded fractions
# (0.1% / 0.5% / 1% of solid) to separate "topology settled" from "single-voxel
# boundary jitter".
#
# Usage: analyze.py <periter_cg1e-8.csv> [solid_voxel_count]
import csv, sys
from collections import defaultdict

path = sys.argv[1]
rows = list(csv.DictReader(open(path)))
by = defaultdict(list)
for r in rows: by[int(r['rung'])].append(r)
# solid count: from the CSV's `solid` column (per-iter, on the SOLVED grid)
solids = [int(r['solid']) for r in rows if r['solid'] not in ('', '-1') and int(r['solid'])>0]
SOLID = int(sys.argv[2]) if len(sys.argv)>2 else (max(solids) if solids else 1)

def ci(x):
    try: return int(x['class_count'])
    except: return -1
def fl(x,k):
    try: return float(x[k])
    except: return float('nan')

print(f"# {path}   SOLID(solved-grid)={SOLID}")
print(f"# material threshold from Q0 negative control = >=1 voxel flip (basin noise flips 0)\n")
hdr = ("rung stop gray_end | lastFlip:>=1vox >=0.1% >=0.5% >=1% | "
       "GAP(stop-1vox) tail_flat_and_frozen | movelimit_iters")
print(hdr)
summary=[]
for rung in sorted(by):
    rs=by[rung]; stop=int(rs[-1]['iter'])
    gray=[x for x in rs if fl(x,'beta')==0.0]
    gray_end=int(gray[-1]['iter']) if gray else 0
    def last_ge(frac):
        thr=max(1, frac*SOLID); L=0
        for x in rs:
            if ci(x)>=thr: L=int(x['iter'])
        return L
    l1=last_ge(0); l01=last_ge(0.001); l05=last_ge(0.005); l1p=last_ge(0.01)
    # dead tail: consecutive trailing iters with 0 flips AND compliance flat (rel<1e-4)
    Cf=fl(rs[-1],'compliance'); dead=0
    for x in reversed(rs):
        c=ci(x); C=fl(x,'compliance')
        flat = (Cf>0 and abs(C-Cf)/Cf < 1e-4)
        if (c==0 or c==-1) and flat: dead+=1
        else: break
    # move-limit binding: iters whose design change is within 2% of the (possibly
    # damped) move limit for that iter's beta. move=0.2; damp=min(1,8/beta) if beta>8.
    ml=0
    for x in rs:
        b=fl(x,'beta'); lim=0.2*(min(1.0,8.0/b) if b>8 else 1.0)
        if fl(x,'change_design') >= 0.98*lim: ml+=1
    print(f"{rung:>4}{stop:>5}{gray_end:>9} | {l1:>11}{l01:>7}{l05:>7}{l1p:>6} | "
          f"{stop-l1:>13} {dead:>21} | {ml:>13}")
    summary.append(dict(rung=rung,stop=stop,gray_end=gray_end,lastflip=l1,
                        settle_05pct=l05,gap=stop-l1,dead_tail=dead,movelimit_iters=ml))
print()
tot_stop=sum(s['stop'] for s in summary)
tot_gap=sum(s['gap'] for s in summary)
tot_dead=sum(s['dead_tail'] for s in summary)
tot_after05=sum(s['stop']-s['settle_05pct'] for s in summary)
print(f"# TOTALS over {len(summary)} rungs: outer_iters={tot_stop}  "
      f"iters_after_last_1voxel_flip={tot_gap} ({100*tot_gap/tot_stop:.0f}%)  "
      f"flat+frozen_dead_tail={tot_dead} ({100*tot_dead/tot_stop:.0f}%)")
print(f"# iters after topology settled (last >=0.5% flip) = {tot_after05} "
      f"({100*tot_after05/tot_stop:.0f}% of all outer iters)")

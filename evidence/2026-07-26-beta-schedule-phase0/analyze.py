#!/usr/bin/env python3
# beta_schedule_probe reducer — Phase 0 (β-continuation schedule).
#
# Consumes one grid directory produced by beta_schedule_probe:
#   periter_<schedule>.csv  (+ periter_base_ctrl.csv), summary.csv
# and emits the S1-S4 / B1-B5 tables. READ-ONLY analysis of measured CSVs.
#
# Usage: analyze.py <grid_dir>
import csv, sys, os
from collections import defaultdict, OrderedDict

D = sys.argv[1]
def load(p):
    fp = os.path.join(D, p)
    return list(csv.DictReader(open(fp))) if os.path.exists(fp) else []

def fl(x, k):
    try: return float(x[k])
    except: return float('nan')
def ii(x, k):
    try: return int(x[k])
    except: return -1

summary = load('summary.csv')
if not summary:
    print(f"no summary.csv in {D}"); sys.exit(1)

# ---- grid facts (B3: dims + solid in every row) --------------------------------
srow = summary[0]
NX, NY, NZ = ii(srow,'solved_nx'), ii(srow,'solved_ny'), ii(srow,'solved_nz')
SOLID = ii(srow,'solid')
print(f"==== GRID {D}  solved={NX}x{NY}x{NZ}  solid={SOLID} voxels ====\n")

# ---- B1: basin floor (base vs base_ctrl terminal per rung) ---------------------
print("[B1] NEGATIVE CONTROL — basin floor (shipped schedule, cg 1e-8 vs 1e-9)")
print("     rung  vf   class_frac(ctrl-vs-base)  flips  accepted(base/ctrl)  iters(base/ctrl)")
base_rows = [r for r in summary if r['schedule']=='base']
ctrl_rows = [r for r in summary if r['schedule']=='base_ctrl']
floor_frac = 0.0; floor_flips = 0
for r in ctrl_rows:
    rung = ii(r,'rung'); b = next((x for x in base_rows if ii(x,'rung')==rung), None)
    cf = fl(r,'class_frac_vs_base'); fp = ii(r,'flips_vs_base')
    floor_frac = max(floor_frac, cf if cf==cf else 0.0); floor_flips = max(floor_flips, fp)
    print(f"     {rung:>4} {fl(r,'vf'):.2f}   {cf:>10.3e}            {fp:>4}   "
          f"{ii(b,'accepted') if b else '?'}/{ii(r,'accepted')}            "
          f"{ii(b,'iters') if b else '?'}/{ii(r,'iters')}")
print(f"     => BASIN FLOOR (max over rungs): class_frac={floor_frac:.3e}  flips={floor_flips}")
print(f"        (design diffs below are reported as flips + as x-floor when floor>0)\n")

def xfloor(fp):
    return "inf(floor=0)" if floor_flips==0 else f"{fp/floor_flips:.1f}x"

# ---- per-iter loader, grouped into contiguous β stages -------------------------
def stages(rows, rung):
    """Return list of stage dicts for one rung: contiguous runs of equal beta."""
    rr = sorted([x for x in rows if ii(x,'rung')==rung], key=lambda x: ii(x,'iter'))
    out = []; cur=None
    for x in rr:
        b = fl(x,'beta')
        if cur is None or b != cur['beta']:
            if cur: out.append(cur)
            cur = dict(beta=b, iters=0, i0=ii(x,'iter'), i1=ii(x,'iter'),
                       c_in=fl(x,'compliance'), c_out=fl(x,'compliance'),
                       mnd_in=fl(x,'mnd_proj'), mnd_out=fl(x,'mnd_proj'),
                       mfv_in=ii(x,'mfv_proj'), mfv_out=ii(x,'mfv_proj'),
                       flips=0, entry_flip=ii(x,'class_count'),
                       last_material_iter=ii(x,'i0') if False else None,
                       rows=[])
        cur['iters']+=1; cur['i1']=ii(x,'iter'); cur['c_out']=fl(x,'compliance')
        cur['mnd_out']=fl(x,'mnd_proj'); cur['mfv_out']=ii(x,'mfv_proj')
        cc = ii(x,'class_count')
        if cc>0: cur['flips']+=cc
        # last iter in this stage with a >=1-voxel classification flip (S4 lag)
        if cc>=1: cur['last_material_iter']=ii(x,'iter')
        cur['rows'].append(x)
    if cur: out.append(cur)
    return out

base_pi = load('periter_base.csv')
NR = max((ii(r,'rung') for r in summary), default=-1)+1

# ---- S1: WHAT EACH β STAGE BUYS (shipped schedule, per rung, per stage) --------
print("[S1] WHAT EACH β STAGE BUYS  (shipped base schedule; c=compliance, proj=projected field)")
print("     rung  β    iters   c_in     c_out    Δc%     flips  mnd_proj(in→out)   mfv_proj(in→out)")
s1w=None
for rung in range(NR):
    for st in stages(base_pi, rung):
        dc = (st['c_in']-st['c_out'])/st['c_in']*100 if st['c_in'] else 0.0
        bstr = 'gray' if st['beta']==0 else f"{st['beta']:g}"
        print(f"     {rung:>4} {bstr:>4} {st['iters']:>6}  {st['c_in']:>8.4g} {st['c_out']:>8.4g}"
              f" {dc:>6.1f}  {st['flips']:>6}  {st['mnd_in']:.3f}→{st['mnd_out']:.3f}"
              f"    {st['mfv_in']:>4}→{st['mfv_out']:<4}")
print()

# ---- S4: plateau lag PER β STAGE (base) ----------------------------------------
print("[S4] PLATEAU LAG PER β STAGE (iters after last ≥1-voxel flip, within each stage)")
print("     rung  β    iters  last_flip_iter  stage_end  lag   (lag = along-for-the-ride tail)")
run_lag_total=0; run_iters_total=0
for rung in range(NR):
    rung_lag=0
    for st in stages(base_pi, rung):
        lm = st['last_material_iter']
        lag = (st['i1']-lm) if lm is not None else st['iters']
        rung_lag += lag; run_lag_total += lag; run_iters_total += st['iters']
        bstr = 'gray' if st['beta']==0 else f"{st['beta']:g}"
        lmstr = str(lm) if lm is not None else "none"
        print(f"     {rung:>4} {bstr:>4} {st['iters']:>6}  {lmstr:>13}  {st['i1']:>9}  {lag:>4}")
    print(f"       rung {rung} total per-stage lag = {rung_lag}")
print(f"     => TOTAL per-stage lag = {run_lag_total} of {run_iters_total} iters "
      f"({100.0*run_lag_total/max(run_iters_total,1):.1f}%)")
print(f"        (193 measured the per-RUN dead tail at 3-5%; per-STAGE lag sums that lag "
      f"across every stage)\n")

# ---- S2 + S3: schedule comparison (terminal design + gate verdict) -------------
def sched_rungs(name): return sorted([r for r in summary if r['schedule']==name], key=lambda r: ii(r,'rung'))
def total_iters(name): return sum(ii(r,'iters') for r in sched_rungs(name))

print("[S2/S3] SCHEDULE COMPARISON vs shipped base  (Σiters, gate verdicts, terminal Δdesign)")
base_iters = total_iters('base')
base_by_rung = {ii(r,'rung'):r for r in base_rows}
order = ['cap16','cap8','start4','jump16','jump32','aggr']
present = [s for s in order if sched_rungs(s)]
print(f"     shipped base: Σiters={base_iters}  per-rung iters="
      f"{[ii(base_by_rung[k],'iters') for k in sorted(base_by_rung)]}")
print(f"     {'schedule':<8} Σiters  Δiters   verdict_flips  worst_class_frac  worst_flips  "
      f"(x-floor)  terminal Δcompliance% (per rung)")
for s in present:
    rows = sched_rungs(s)
    if any(ii(r,'rung')<0 for r in rows):        # infeasibility marker (rung=-1)
        bmax = fl(rows[0],'beta_final')
        print(f"     {s:<8} {'INFEASIBLE — CG diverged jumping straight to β={:g} '.format(bmax)}"
              f"(mechanical justification for gradual continuation; S3)")
        continue
    it = total_iters(s)
    flips_verdict=[]; worst_cf=0.0; worst_flp=0; dcs=[]
    for r in rows:
        rung=ii(r,'rung'); b=base_by_rung.get(rung)
        if b and ii(r,'accepted')!=ii(b,'accepted'):
            flips_verdict.append(f"rung{rung}:{ii(b,'accepted')}→{ii(r,'accepted')}")
        cf=fl(r,'class_frac_vs_base'); fp=ii(r,'flips_vs_base')
        if cf==cf and cf>worst_cf: worst_cf=cf
        if fp>worst_flp: worst_flp=fp
        if b and fl(b,'compliance'):
            dcs.append((fl(r,'compliance')-fl(b,'compliance'))/fl(b,'compliance')*100)
    fv = ",".join(flips_verdict) if flips_verdict else "NONE"
    dcstr = " ".join(f"{d:+.2f}" for d in dcs)
    print(f"     {s:<8} {it:>5}  {it-base_iters:>+5}   {fv:<13}  {worst_cf:>10.3e}      "
          f"{worst_flp:>5}   {xfloor(worst_flp):>10}  [{dcstr}]")
print()

# ---- S2 detail: what stopping at 16 (cap16) / 8 (cap8) costs, per rung ----------
for cap in ['cap16','cap8']:
    rows = sched_rungs(cap)
    if not rows: continue
    print(f"[S2] STOP-AT-{cap[3:]} cost per rung  ({cap} vs base)")
    print("     rung  iters(base→cap)  Δcompl%  mnd_final(base→cap)  mfv_final(base→cap)  "
          "class_frac  flips  accepted(base→cap)")
    for r in rows:
        rung=ii(r,'rung'); b=base_by_rung.get(rung)
        dcompl = (fl(r,'compliance')-fl(b,'compliance'))/fl(b,'compliance')*100 if b and fl(b,'compliance') else 0
        print(f"     {rung:>4}  {ii(b,'iters') if b else '?':>4}→{ii(r,'iters'):<4}       {dcompl:>+6.2f}   "
              f"{fl(b,'mnd_final') if b else 0:.3f}→{fl(r,'mnd_final'):.3f}       "
              f"{ii(b,'mfv_final') if b else 0:>4}→{ii(r,'mfv_final'):<4}      "
              f"{fl(r,'class_frac_vs_base'):.2e}  {ii(r,'flips_vs_base'):>4}   "
              f"{ii(b,'accepted') if b else '?'}→{ii(r,'accepted')}")
    print()

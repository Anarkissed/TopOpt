#!/usr/bin/env python3
"""Per arm, P4 (before) vs P1 (after): every plan base that moves, every region whose cells or uncovered
share changes beyond noise, the job's cell totals, and half-extent changes. Usage: compare_fitcells.py"""
import re, json, os, glob
M = '/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lattice-stage-frontend-37bee1'
B, A = M + '/scratch/evidence-p1-before/plans', M + '/scratch/evidence-p1-after/plans'
def find(o, k):
    if isinstance(o, dict):
        if k in o: return o[k]
        for x in o.values():
            r = find(x, k)
            if r is not None: return r
    elif isinstance(o, list):
        for x in o:
            r = find(x, k)
            if r is not None: return r
def line(path, tag):
    if not os.path.exists(path): return None
    for l in open(path, errors='replace'):
        if l.startswith(tag): return l.strip()
def bases(l):
    return {} if not l else {int(a): float(b) for a, b in re.findall(r'job region (\d+): ([\d.]+) mm', l)}
def regs(l):
    out = {}
    if not l: return out
    for m in re.finditer(r'r(\d+) cells=(\d+) \[([^\]]*)\] prism=([\d.]+) mm3 uncovered=([\d.]+) mm3 \(([\d.]+)%\)', l):
        out[int(m.group(1))] = (int(m.group(2)), m.group(3), float(m.group(4)), float(m.group(5)), float(m.group(6)))
    return out
for d in sorted(glob.glob(A + '/*/*')):
    pid, arm = d.split('/')[-2], d.split('/')[-1]
    bd = B + f'/{pid}/{arm}'
    print(f'===== {pid[:8]} {arm}')
    hb, ha = bd + '/harness.log', d + '/harness.log'
    if not os.path.exists(hb) or not os.path.exists(ha): print('  missing', hb if not os.path.exists(hb) else ha); continue
    bb, ba = bases(line(hb, 'DG-PLAN-BASES')), bases(line(ha, 'DG-PLAN-BASES'))
    mv = [(k, bb.get(k), ba.get(k)) for k in sorted(set(bb) | set(ba)) if bb.get(k) != ba.get(k)]
    print(f'  plan bases: {len(bb)} -> {len(ba)}; moved: {mv}')
    rb, ra = regs(line(hb, 'DG-REGIONS')), regs(line(ha, 'DG-REGIONS'))
    cb, ca = sum(v[0] for v in rb.values()), sum(v[0] for v in ra.values())
    print(f'  harness cells {cb} -> {ca}')
    for k in sorted(set(rb) | set(ra)):
        x, y = rb.get(k), ra.get(k)
        if x is None or y is None or x[0] != y[0] or x[1] != y[1] or abs(x[4] - y[4]) > 1.0:
            if x and y and x[0] == 0 and y[0] == 0 and max(x[2], y[2]) < 50: continue  # zero-cell slivers
            print(f'   r{k}: {x} -> {y}')
    for nm in ['job_plan.json', 'job_noplan.json']:
        jb, ja = bd + '/' + nm, d + '/' + nm
        if os.path.exists(jb) and os.path.exists(ja):
            Jb, Ja = json.load(open(jb)), json.load(open(ja))
            sb, sa = find(Jb, 'stepped_cells') or [], find(Ja, 'stepped_cells') or []
            Rb, Ra = find(Jb, 'regions') or [], find(Ja, 'regions') or []
            hc = sum(1 for x, y in zip(Rb, Ra) if (x.get('geometry', {}).get('half_u_mm'), x.get('geometry', {}).get('half_w_mm'))
                     != (y.get('geometry', {}).get('half_u_mm'), y.get('geometry', {}).get('half_w_mm')))
            same = json.dumps(sb, sort_keys=True) == json.dumps(sa, sort_keys=True)
            print(f'  {nm}: stepped_cells {len(sb)} -> {len(sa)} (identical: {same}); regions {len(Rb)} -> {len(Ra)}, half-extents changed on {hc}')
    for tag in ['DG-OVERLAPS', 'DG-PLAN ', 'DG-PLAN per region', 'DG-SLOT-ORIGINS']:
        lb, la = line(hb, tag), line(ha, tag)
        if lb or la:
            if lb != la: print(f'  {tag.strip()}:\n    B {lb}\n    A {la}')
            else: print(f'  {tag.strip()} same: {lb[:160]}')

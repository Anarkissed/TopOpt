#!/usr/bin/env python3
"""Which plan cells did core lay NO strut in, and why — from core's own K4 ledger (lattice.emit_plan_laid,
<base>_LAID.txt: one `LAID <region> <cx> <cy> <cz> <size_mm> <rho> <struts> <nodes>` line per PLAN cell, laid or
not, centre in mm). Each ledger line is matched to its plan cell (region, centre, size) and each strut-less cell is
classed the way core reads the job's own region (as classify_unlaid_cells.py does from SPANS):
  OUTSIDE    — the cell's CENTRE projects outside the region's outline_uv (even-odd, frame_u/frame_w);
  PAST_DEPTH — its far side is past depth_mm (or its centre in front of the plane);
  IN_REGION  — neither.
Writes the IN_REGION cells (job index, region, origin, size) to <out> for the preview's verdict.
Usage: classify_laid_ledger.py job_plan.json LAID.txt [in_region_out.json]"""
import json, math, sys
from collections import Counter, defaultdict

job = json.load(open(sys.argv[1]))
cells = job['lattice']['stepped_cells']
includes = [r for r in job['lattice']['regions'] if r['role'] == 'include']
ledger = []
for l in open(sys.argv[2]):
    t = l.split()
    if t and t[0] == 'LAID':
        ledger.append((int(t[1]), float(t[2]), float(t[3]), float(t[4]), float(t[5]), float(t[6]), int(t[7]), int(t[8])))
plan_line = next((l for l in open(sys.argv[2]) if l.startswith('PLAN')), '').strip()

# match each ledger line to its plan cell: same region, size within 1e-4 mm, centre within 1e-3 mm (the ledger
# prints ~10 significant digits, so a fixed rounding key splits values that straddle a rounding boundary)
bucket = defaultdict(list)
def bkey(r, c): return (r,) + tuple(int(math.floor(c[a])) for a in range(3))
for i, c in enumerate(cells):
    s = c['size_mm']; ctr = [c['origin_mm'][a] + 0.5 * s for a in range(3)]
    bucket[bkey(c['region_id'], ctr)].append(i)
struts = {}
unmatched = 0
for (r, cx, cy, cz, s, rho, st, nd) in ledger:
    hit = None
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                k = (r, int(math.floor(cx)) + dx, int(math.floor(cy)) + dy, int(math.floor(cz)) + dz)
                for i in bucket.get(k, []):
                    c = cells[i]
                    if i in struts or abs(c['size_mm'] - s) > 1e-4: continue
                    if all(abs(c['origin_mm'][a] + 0.5 * c['size_mm'] - v) < 1e-3 for a, v in enumerate((cx, cy, cz))):
                        hit = i; break
                if hit is not None: break
            if hit is not None: break
        if hit is not None: break
    if hit is None: unmatched += 1; continue
    struts[hit] = st

def sub(a, b): return [a[i] - b[i] for i in range(3)]
def dot(a, b): return sum(a[i] * b[i] for i in range(3))
def unit(v):
    n = math.sqrt(dot(v, v)); return [x / n for x in v]
def seg_dist(p, a, b):
    ab = [b[0] - a[0], b[1] - a[1]]; l2 = ab[0] ** 2 + ab[1] ** 2
    t = 0 if l2 < 1e-12 else max(0, min(1, ((p[0] - a[0]) * ab[0] + (p[1] - a[1]) * ab[1]) / l2))
    q = [a[0] + ab[0] * t, a[1] + ab[1] * t]
    return math.hypot(p[0] - q[0], p[1] - q[1])
def signed_in(p, loops):
    inside_ = False; best = 1e18
    for loop in loops:
        n = len(loop)
        for i in range(n):
            j = (i - 1) % n
            xi, yi = loop[i]; xj, yj = loop[j]
            if (yi > p[1]) != (yj > p[1]):
                x = xj + (p[1] - yj) * (xi - xj) / (yi - yj)
                if p[0] < x: inside_ = not inside_
            best = min(best, seg_dist(p, loop[j], loop[i]))
    return best if inside_ else -best

cls = Counter(); by = defaultdict(Counter); sizes = defaultdict(Counter); in_region = []
for i, c in enumerate(cells):
    if struts.get(i, 0) > 0: continue
    if i not in struts: cls['NOT_IN_LEDGER'] += 1; continue
    g = includes[c['region_id'] - 1]['geometry']
    o, nrm = g['origin'], unit(g['normal'])
    s = c['size_mm']; ctr = [c['origin_mm'][a] + 0.5 * s for a in range(3)]
    rel = sub(ctr, o)
    sm = dot(rel, nrm)
    shi = dot(sub(c['origin_mm'], o), nrm) + s * sum(max(0, x) for x in nrm)
    fu, fw = g.get('frame_u'), g.get('frame_w')
    d_in = signed_in([dot(rel, fu), dot(rel, fw)], g['outline_uv']) if fu and fw and g.get('outline_uv') else None
    if d_in is not None and d_in < 0: k = 'OUTSIDE'
    elif shi > g['depth_mm'] + 1e-6 or sm < -1e-6: k = 'PAST_DEPTH'
    else: k = 'IN_REGION'
    cls[k] += 1; by[c['region_id']][k] += 1; sizes[k][round(s, 3)] += 1
    if k == 'IN_REGION':
        in_region.append({'index': i, 'region_id': c['region_id'], 'origin_mm': c['origin_mm'], 'size_mm': s,
                          'centre_in_plane_mm': None if d_in is None else round(d_in, 4)})
total_unlaid = sum(cls.values())
print(f"{plan_line} | ledger lines {len(ledger)} (unmatched {unmatched}) | NO STRUT {total_unlaid} of {len(cells)} | "
      + " ".join(f"{k}={v}" for k, v in cls.most_common()))
for r in sorted(by): print(f"  region {r}: " + " ".join(f"{k}={v}" for k, v in by[r].most_common()))
for k in sizes: print(f"  {k} by size: " + " ".join(f"{s:g}={n}" for s, n in sorted(sizes[k].items())))
if len(sys.argv) > 3:
    json.dump(in_region, open(sys.argv[3], 'w'), indent=1)
    print(f"  IN_REGION cells written to {sys.argv[3]}")

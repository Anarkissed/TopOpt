#!/usr/bin/env python3
"""Why did core lay no strut in a plan cell? For every plan cell with no strut (the same test as
compare_plan_spans.py: a strut belongs to a cell when both ends lie in its cube to 1e-3 mm), report its
region, size and two in-region measures, computed the way core reads the job's own region:
  - inPlane: where the cell's CENTRE projects against the region's outline_uv (frame_u/frame_w), as the
    signed distance in mm to the polygon (positive inside), even-odd over the loops;
  - depth: the centre's distance from the region plane along the unit normal, and the cell's far side,
    against depth_mm.
Classes: OUTSIDE (centre outside outline_uv), PAST_DEPTH (far side past depth_mm), IN_REGION (neither).
Also counts unlaid cells sharing volume with a cell of ANOTHER region (a straddler pair).
Usage: classify_unlaid_cells.py job_plan.json SPANS.txt"""
import json, math, sys
from collections import Counter, defaultdict

job = json.load(open(sys.argv[1]))
cells = job['lattice']['stepped_cells']
regs = job['lattice']['regions']
segs = [tuple(map(float, l.split()[1:7])) for l in open(sys.argv[2]) if l.startswith('SEG')]
includes = [r for r in regs if r['role'] == 'include']
big = max(c['size_mm'] for c in cells)
def key(p): return tuple(int(math.floor(p[a] / big)) for a in range(3))
buckets = defaultdict(list)
for i, c in enumerate(cells): buckets[key(c['origin_mm'])].append(i)
def inside(i, p, eps=1e-3):
    o, s = cells[i]['origin_mm'], cells[i]['size_mm']
    return all(o[a] - eps <= p[a] <= o[a] + s + eps for a in range(3))
laid = set()
for s in segs:
    a, b = s[:3], s[3:6]
    ka = key(a)
    for d in [(x, y, z) for x in (-1, 0, 1) for y in (-1, 0, 1) for z in (-1, 0, 1)]:
        hit = next((i for i in buckets.get((ka[0] + d[0], ka[1] + d[1], ka[2] + d[2]), []) if inside(i, a) and inside(i, b)), None)
        if hit is not None: laid.add(hit); break

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

cls = Counter(); by = defaultdict(Counter); examples = defaultdict(list)
for i, c in enumerate(cells):
    if i in laid: continue
    g = includes[c['region_id'] - 1]['geometry']
    o, nrm = g['origin'], unit(g['normal'])
    s = c['size_mm']; ctr = [c['origin_mm'][a] + 0.5 * s for a in range(3)]
    rel = sub(ctr, o)
    sm = dot(rel, nrm)
    shi = dot(sub(c['origin_mm'], o), nrm) + s * sum(max(0, x) for x in nrm)
    fu, fw = g.get('frame_u'), g.get('frame_w')
    if fu and fw and g.get('outline_uv'):
        d_in = signed_in([dot(rel, fu), dot(rel, fw)], g['outline_uv'])
    else:
        d_in = None
    if d_in is not None and d_in < 0: k = 'OUTSIDE'
    elif shi > g['depth_mm'] + 1e-6 or sm < -1e-6: k = 'PAST_DEPTH'
    else: k = 'IN_REGION'
    cls[k] += 1; by[c['region_id']][k] += 1
    if len(examples[k]) < 3:
        examples[k].append(f"r{c['region_id']} {s:.3f} mm inPlane={d_in if d_in is None else round(d_in, 3)} "
                           f"depth mid={sm:.3f} far={shi:.3f} of {g['depth_mm']:.3f}")
print(f"UNLAID {len(cells) - len(laid)} of {len(cells)} | " + " ".join(f"{k}={v}" for k, v in cls.most_common()))
for r in sorted(by): print(f"  region {r}: " + " ".join(f"{k}={v}" for k, v in by[r].most_common()))
for k, ex in examples.items():
    for e in ex: print(f"  e.g. {k}: {e}")

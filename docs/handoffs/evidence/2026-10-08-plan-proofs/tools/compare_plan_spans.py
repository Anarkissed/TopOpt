#!/usr/bin/env python3
"""Cell for cell: the plan a job carried (lattice.stepped_cells) against the struts core shipped
(_SPANS.txt from emit_welded_stl + emit_organic_spans, the spans AFTER every pass). A strut belongs
to a plan cell when both its ends lie in that cell's cube (to 1e-3 mm). Reports:
  - plan cells with at least one strut (laid) and with none (NOT laid);
  - struts inside no plan cell (FOREIGN: a cell core laid that the plan does not have, or the skin);
  - per size: plan cells, laid cells.
Evidence tooling only; it never decides for core."""
import json, sys
from collections import Counter, defaultdict

job = json.load(open(sys.argv[1]))
cells = job['lattice'].get('stepped_cells', [])
segs = []
for line in open(sys.argv[2]):
    p = line.split()
    if p and p[0] == 'SEG':
        segs.append(tuple(map(float, p[1:8])))
if not cells:
    sys.exit('the job carries no plan')
big = max(c['size_mm'] for c in cells)
buckets = defaultdict(list)
def key(x, y, z): return (int(x // big), int(y // big), int(z // big))
for i, c in enumerate(cells):
    o = c['origin_mm']
    buckets[key(*o)].append(i)
def inside(i, p, eps=1e-3):
    o, s = cells[i]['origin_mm'], cells[i]['size_mm']
    return all(o[a] - eps <= p[a] <= o[a] + s + eps for a in range(3))
laid = Counter()
foreign = 0
for (ax, ay, az, bx, by, bz, r) in segs:
    a, b = (ax, ay, az), (bx, by, bz)
    ka = key(*a)
    hit = None
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                for i in buckets.get((ka[0] + dx, ka[1] + dy, ka[2] + dz), []):
                    if inside(i, a) and inside(i, b):
                        hit = i; break
                if hit is not None: break
            if hit is not None: break
        if hit is not None: break
    if hit is None: foreign += 1
    else: laid[hit] += 1
by_size, laid_by_size = Counter(), Counter()
for i, c in enumerate(cells):
    by_size[round(c['size_mm'], 6)] += 1
    if laid[i]: laid_by_size[round(c['size_mm'], 6)] += 1
not_laid = [i for i in range(len(cells)) if not laid[i]]
print(f"CELLS-VS-SPANS plan cells {len(cells)} | laid {len(cells) - len(not_laid)} | NOT laid {len(not_laid)} | "
      f"struts {len(segs)}: in a plan cell {len(segs) - foreign}, FOREIGN {foreign}")
print("per size (plan / laid): " + " ".join(f"{s:.2f}={by_size[s]}/{laid_by_size[s]}" for s in sorted(by_size, reverse=True)))
for i in not_laid[:10]:
    c = cells[i]
    print(f"  not laid: region {c['region_id']} {c['size_mm']:.3f} mm at {c['origin_mm']}")

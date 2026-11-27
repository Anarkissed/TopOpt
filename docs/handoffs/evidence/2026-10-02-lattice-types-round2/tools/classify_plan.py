#!/usr/bin/env python3
"""Classify EVERY cell of a job's lattice.stepped_cells against core's own checks (ruling 4).

A Python port of core's stepped_validate_plan (core/src/mesh/stepped_plan.cpp, linked 19a1443b)
and of how run_job.cpp builds the doubled plan regions (base = the region's largest sent cell;
slot_origin = the region's sent origin; normal; depth; tile floor = stepped_min_tile_mm or the
bead; prints_open only under intent "aesthetic", never for doubled). Core stops at the FIRST bad
cell; this reports them ALL, by cause:
  MENU     size not on the region's halving ladder
  R1-ALIGN in-plane offset from the region's origin not a multiple of the family tile
  R2-DEPTH the cell's min corner projected on the normal is outside [0, depth]
  R5/R3    overlap-hash collision: R3 = with ANOTHER region's cell (the key has no region id),
           R5 = within one region (one global finest tile across regions with incommensurate bases)
Also tests R1's shape: whether ONE constant in-plane shift per region would align every cell.
Evidence tooling only; the CLI is the verdict."""
import json, math, sys
from collections import Counter, defaultdict

MAX_HALVINGS, SAME_REL = 8, 1e-9

def halving_divisors(base, bead, tile_floor):
    out, n = [], 2
    while n <= (1 << MAX_HALVINGS):
        t = base / n
        if tile_floor > 0 and t < tile_floor: break
        if t <= bead: break
        out.append(n); n *= 2
    return out

def aligned(offset, size, base, divs):
    for n in divs:
        t = base / n
        k = size / t
        if abs(k - math.floor(k + 0.5)) > 1e-6: continue
        q = offset / t
        if abs(q - math.floor(q + 0.5)) <= 1e-6: return True
    return False

def llround(x): return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))

def classify(job):
    g, lat = job['grading'], job['lattice']
    bead = g.get('min_extrudable_width_mm', 0.0)
    tile_floor = g.get('stepped_min_tile_mm') or bead
    cells = lat.get('stepped_cells', [])
    incl = [r for r in lat['regions'] if r['role'] == 'include']
    base_of = defaultdict(float)
    for c in cells: base_of[c['region_id']] = max(base_of[c['region_id']], c['size_mm'])
    regs = {}
    for i, r in enumerate(incl, 1):
        geo = r['geometry']; base = base_of.get(i, g.get('cell_mm', 0.0))
        divs = halving_divisors(base, bead, tile_floor)
        regs[i] = dict(origin=geo['origin'], normal=geo['normal'], depth=geo['depth_mm'], base=base,
                       divs=divs, menu=[base] + [base / n for n in divs])
    finest = min((s for r in regs.values() for s in r['menu'] if s > 0), default=0.0)
    occ, causes, first = {}, Counter(), {}
    per_region = defaultdict(Counter)
    residues = defaultdict(list)
    for ci, c in enumerate(cells):
        r = regs[c['region_id']]; size = c['size_mm']
        o = [c['origin_mm'][a] - r['origin'][a] for a in range(3)]
        bad = []
        if not any(abs(s - size) <= SAME_REL * max(1.0, s) for s in r['menu']): bad.append('MENU')
        is_base = abs(size - r['base']) <= SAME_REL * max(1.0, r['base'])
        al = [aligned(o[a], size, r['base'], r['divs']) for a in range(3)]
        if not is_base and not all(al): bad.append('R1-ALIGN')
        n = r['normal']; nl = math.sqrt(sum(x * x for x in n))
        if r['depth'] > 0 and nl > 0:
            s0 = sum(o[a] * n[a] / nl for a in range(3)); s1 = s0 + size
            if s0 < -1e-6 or s1 > r['depth'] + 1e-6: bad.append('R2-DEPTH')
        if finest > 0:
            i0, j0, k0 = (llround(o[a] / finest) for a in range(3)); span = max(1, llround(size / finest))
            hit = None
            for i in range(i0, i0 + span):
                for j in range(j0, j0 + span):
                    for k in range(k0, k0 + span):
                        prev = occ.setdefault((i, j, k), ci)
                        if prev != ci and hit is None: hit = prev
            if hit is not None:
                bad.append('R3-OVERLAP-OTHER-REGION' if cells[hit]['region_id'] != c['region_id'] else 'R5-OVERLAP-SAME-REGION')
        for b in bad:
            causes[b] += 1; per_region[c['region_id']][b] += 1; first.setdefault(b, (ci, c))
        # R1's shape: the in-plane residue of the offset modulo the cell size, per axis
        residues[c['region_id']].append(tuple(round(((o[a] % size) + size) % size, 4) for a in range(3)))
    hist = Counter(c['size_mm'] for c in cells)
    line = ' '.join('%.2f=%d' % (s, hist[s]) for s in sorted(hist, reverse=True))
    return dict(cells=len(cells), regions=len(incl), finest=finest, causes=causes, per_region=per_region,
                first=first, hist=line, regs=regs, residues=residues)

def exact_overlaps(cells, eps=1e-6):
    """The TRUTH the hash approximates: pairs of cells (world axis-aligned cubes, origin = min
    corner) whose intersection has positive volume. Bucketed on the largest cell so each pair is
    tested once. Returns (same-region pairs, cross-region pairs)."""
    big = max((c['size_mm'] for c in cells), default=0.0)
    if big <= 0: return 0, 0
    buckets = defaultdict(list)
    for ci, c in enumerate(cells):
        buckets[tuple(math.floor(c['origin_mm'][a] / big) for a in range(3))].append(ci)
    same = cross = 0
    for ci, c in enumerate(cells):
        key = tuple(math.floor(c['origin_mm'][a] / big) for a in range(3))
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for cj in buckets.get((key[0] + dx, key[1] + dy, key[2] + dz), ()):
                        if cj <= ci: continue
                        d = cells[cj]
                        if all(min(c['origin_mm'][a] + c['size_mm'], d['origin_mm'][a] + d['size_mm'])
                               - max(c['origin_mm'][a], d['origin_mm'][a]) > eps for a in range(3)):
                            if c['region_id'] == d['region_id']: same += 1
                            else: cross += 1
    return same, cross

if __name__ == '__main__':
    job = json.load(open(sys.argv[1]))
    r = classify(job)
    print(f"plan: {r['cells']} cell(s) over {r['regions']} region(s) | {r['hist']}")
    print(f"finest tile across regions {r['finest']:.4f}")
    for i, reg in r['regs'].items():
        print(f"  r{i}: base {reg['base']:.4f} halvings {reg['divs']} normal {reg['normal']} depth {reg['depth']}")
    print('causes:', dict(r['causes']) or 'NONE — every cell passes')
    for i, cc in sorted(r['per_region'].items()): print(f"  r{i}: {dict(cc)}")
    for b, (ci, c) in r['first'].items(): print(f"  first {b}: cell {ci} r{c['region_id']} {c['size_mm']:.4g} mm at {[round(x,3) for x in c['origin_mm']]}")
    for i, res in sorted(r['residues'].items()):
        distinct = Counter(res).most_common(3)
        print(f"  r{i} offset-mod-size residues: {len(set(res))} distinct; top {distinct}")
    same, cross = exact_overlaps(job['lattice'].get('stepped_cells', []))
    print(f"exact positive-volume overlaps: {same} pair(s) within a region, {cross} pair(s) across regions")

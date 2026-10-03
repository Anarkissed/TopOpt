# A line-for-line Python port of core's stepped_group_cells (core/src/mesh/stepped_plan.cpp:260-326
# at 23e6154e), used only to (1) check it predicts what the CLI runs measured and (2) run core's
# own packed-slot fixture (test_stepped_plan.cpp:705-788) through grouping.
import math
def llround(x): return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))
def group(cells, slot):          # cells: [(origin(3), size)]; one region
    bucket = {}
    for o, s in cells: bucket.setdefault(llround(s * 1e6), []).append(o)
    laid = []
    for key, os_ in bucket.items():
        size = key * 1e-6
        lo = [min(o[a] for o in os_) for a in range(3)]
        org = [slot[a] + math.floor((lo[a] - slot[a]) / size + 1e-9) * size for a in range(3)]
        for o in os_:
            idx = [llround((o[a] - org[a]) / size) for a in range(3)]
            laid.append((tuple(org[a] + idx[a] * size for a in range(3)), size, o))
    return laid
# (1) the CLI-measured cases: sent -> laid
cases = {
 'R6 base off grid (doubled)':     ([((19.0, 9.0, 8.0), 3.0)], (18.0, 12.0, 8.0)),
 'R6 off grid +2 (doubled)':       ([((20.0, 9.0, 8.0), 3.0)], (18.0, 12.0, 8.0)),
 'R6b half on quarter (doubled)':  ([((18.0, 9.0, 8.0), 3.0), ((21.75, 10.5, 8.0), 1.5)], (18.0, 12.0, 8.0)),
 'R6c 3-tile at 1 tile (any-step)':([((18.0, 0.0, 8.0), 14.5 / 6), ((18.0 + 14.5 / 6, 0.0, 8.0), 3 * (14.5 / 6))], (18.0, 0.0, 8.0)),
 'R6d second slot (any-step)':     ([((18.0, 0.0, 8.0 + 14.5), 3 * (14.5 / 5))], (18.0, 0.0, 8.0)),
}
for name, (cells, slot) in cases.items():
    for laid, size, sent in group(cells, slot):
        moved = tuple(round(laid[a] - sent[a], 6) for a in range(3))
        print(f'{name:34s} size {size:7.4f} sent {tuple(round(v,4) for v in sent)} -> laid {tuple(round(v,4) for v in laid)}  moved {moved}')
# (2) core's packed slot: a 9 at (3,3,0) + 37 3s in a 12 mm slot, coverage sampled on the LAID cells
cells = [((3.0, 3.0, 0.0), 9.0)]
for i in range(4):
    for j in range(4):
        for k in range(4):
            x, y, z = 3.0 * i, 3.0 * j, 3.0 * k
            if not (x >= 3.0 and y >= 3.0 and z < 9.0): cells.append(((x, y, z), 3.0))
def coverage(cs):
    h = 0.5; once = twice = none = 0
    n = int(12 / h)
    for a in range(n):
        x = h / 2 + a * h
        for b in range(n):
            y = h / 2 + b * h
            for c in range(n):
                z = h / 2 + c * h
                hits = sum(1 for o, s in cs if o[0] <= x < o[0] + s and o[1] <= y < o[1] + s and o[2] <= z < o[2] + s)
                if hits == 1: once += 1
                elif hits == 0: none += 1
                else: twice += 1
    return once, none, twice
print('packed slot, SENT cells  (what test_stepped_plan.cpp:739-755 samples): once/uncovered/doubled =', coverage(cells))
laid = [(l, s) for l, s, _ in group(cells, (0.0, 0.0, 0.0))]
print('packed slot, LAID cells (after stepped_group_cells):                 once/uncovered/doubled =', coverage(laid))
print('the 9 is laid at', [l for l, s in laid if s == 9.0])

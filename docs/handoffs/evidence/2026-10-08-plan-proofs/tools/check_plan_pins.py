#!/usr/bin/env python3
"""The plan bar (reviewer ruling 2026-10-24 17:46): every arm's plan is byte-identical to its pin from the redesign
tree (5f8954b3) on. Pins: plans-redesign/PINS.txt (`<arm> <cells> <sha256 of stepped_cells, sorted keys, compact>`).
Usage: check_plan_pins.py <EVID plans dir, e.g. scratch/evidence-redesign-post/plans>   (exit 1 on any mismatch)
       check_plan_pins.py --write <plans dir>   (re-pin; only on a ruling)"""
import hashlib, json, os, sys, glob
here = os.path.dirname(os.path.abspath(__file__))
pins_path = os.path.join(here, '..', 'plans-redesign', 'PINS.txt')
def sig(p):
    cells = json.load(open(p)).get('lattice', {}).get('stepped_cells') or []
    return len(cells), hashlib.sha256(json.dumps(cells, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
write = sys.argv[1] == '--write'
root = sys.argv[-1]
found = {}
for d in sorted(glob.glob(os.path.join(root, '*', '*'))):
    p = os.path.join(d, 'job_plan.json')
    if os.path.exists(p): found[f"{os.path.basename(os.path.dirname(d))[:8]}-{os.path.basename(d)}"] = sig(p)
if write:
    with open(pins_path, 'w') as f:
        f.write('# arm cells sha256(stepped_cells) — pinned on the redesign tree 5f8954b3 (slab removed), ruling 2026-10-24 17:46\n')
        for k, (n, h) in sorted(found.items()): f.write(f'{k} {n} {h}\n')
    print(open(pins_path).read()); sys.exit(0)
pins = {l.split()[0]: (int(l.split()[1]), l.split()[2]) for l in open(pins_path) if l.strip() and not l.startswith('#')}
bad = 0
for k, v in sorted(pins.items()):
    got = found.get(k)
    ok = got == v
    bad += not ok
    print(f"{'OK  ' if ok else 'DIFF'} {k}: pinned {v[0]} cells {v[1][:16]}… | now {got[0] if got else '-'} {got[1][:16] + '…' if got else 'missing'}")
sys.exit(1 if bad else 0)

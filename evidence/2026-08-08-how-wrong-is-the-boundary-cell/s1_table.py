#!/usr/bin/env python3
"""S1(b)+(c)+(d) -- turn s1_refine.csv into the tables the handoff quotes.

Every difference is printed with the REFERENCE'S OWN NOISE beside it (bar R2).
The noise floor comes from the repeat rows: the same rung, the same mode, the
same refinement, the same arguments, a fresh process.

  python3 s1_table.py [s1_refine.csv]
"""
import csv, sys, collections, math

path = sys.argv[1] if len(sys.argv) > 1 else 's1_refine.csv'
rows = list(csv.DictReader(open(path)))
F = lambda r, k: float(r[k])
KEY = lambda r: (r['mode'], round(float(r['rung_vf']), 2), int(r['refine']))

by = collections.OrderedDict()
for r in rows:
    by.setdefault(KEY(r), []).append(r)

MODES = []
for r in rows:
    if r['mode'] not in MODES: MODES.append(r['mode'])
VFS = sorted({round(float(r['rung_vf']), 2) for r in rows}, reverse=True)
REFS = sorted({int(r['refine']) for r in rows})
BASE = min(REFS)

GATE = [
    ('peak_vm_mpa',                'peak von Mises (MPa)'),
    ('margin_worst_case',          'margin worst_case'),
    ('margin_effective',           'margin effective'),
    ('mass_g',                     'printed mass (g)'),
    ('compliance',                 'compliance f.u (N.mm)'),
    ('max_disp_mm',                'peak |displacement| (mm)'),
    ('peak_vm_boundary_onlattice', 'peak vM, BOUNDARY cells'),
    ('peak_vm_interior_onlattice', 'peak vM, INTERIOR cells'),
]

def rel(a, b):
    return (a - b) / abs(b) if b else float('nan')

# ══ THE POSITIVE CONTROL ════════════════════════════════════════════════════
print("=" * 92)
print("POSITIVE CONTROL -- at refine 1 the reference construction is the IDENTITY,")
print("so it must land on the margin the run RECORDED (and on the shipped setup).")
print("=" * 92)
print(f"  {'mode':>10} {'rung':>6} {'recorded margin':>24} {'reproduced':>24} {'rel delta':>12}  band 1e-06")
for m in MODES:
    for vf in VFS:
        rs = by.get((m, vf, BASE))
        if not rs: continue
        r = rs[0]
        rec, rep = F(r, 'recorded_margin'), F(r, 'margin_worst_case')
        d = abs(rel(rep, rec))
        print(f"  {m:>10} {vf:6.2f} {rec!r:>24} {rep!r:>24} {d:12.3e}  "
              f"{'PASS' if d < 1e-6 else '*** OUT OF BAND ***'}")
# replicate vs retag at refine 1: must be identical
print()
for vf in VFS:
    a = by.get(('replicate', vf, BASE)); b = by.get(('retag', vf, BASE))
    if not a or not b: continue
    same = all(a[0][k] == b[0][k] for k, _ in GATE)
    print(f"  rung {vf:.2f}: replicate@1 vs retag@1 on every gate quantity: "
          f"{'IDENTICAL' if same else 'DIFFER -- ' + str([k for k,_ in GATE if a[0][k]!=b[0][k]])}")

# ══ R2 -- THE REFERENCE'S OWN NOISE ═════════════════════════════════════════
print()
print("=" * 92)
print("R2 -- THE REFERENCE'S OWN NOISE (repeat solves, fresh process each time)")
print("=" * 92)
worst_noise = 0.0
any_repeat = False
for k, rs in by.items():
    if len(rs) < 2: continue
    any_repeat = True
    print(f"\n  {k[0]}, rung vf={k[1]:.2f}, refine {k[2]}x, {len(rs)} solves:")
    for key, label in GATE:
        vals = [F(r, key) for r in rs]
        lo, hi = min(vals), max(vals)
        spread = abs(rel(hi, lo)) if lo else 0.0
        worst_noise = max(worst_noise, spread)
        print(f"    {label:26s} {lo!r:>24} .. {hi!r:<24} rel spread {spread:.3e}"
              f"{'   BIT-IDENTICAL' if hi == lo else ''}")
if not any_repeat:
    print("  (no repeat rows -- R2 cannot be reported)")
print(f"\n  WORST repeat spread over every quantity and rung: {worst_noise:.3e}")
print("  PR 313 measured the WARM-vs-COLD Krylov path difference on this same")
print("  machinery at 8.4e-11 .. 6.8e-09 relative. The floor a coarse-vs-fine")
print("  difference must clear is the LARGER of the two.")
FLOOR = max(worst_noise, 6.8e-9)
print(f"  FLOOR USED: {FLOOR:.3e} relative.")

# ══ S1(b) -- WHAT THE GATE READS ════════════════════════════════════════════
print()
print("=" * 92)
print("S1(b) -- WHAT THE GATE READS: coarse (as certified) against the finer solve")
print("=" * 92)
for m in MODES:
    for vf in VFS:
        c = by.get((m, vf, BASE), [None])[0]
        if c is None: continue
        print(f"\n--- mode {m}, rung vf={vf:.2f}   recorded margin {c['recorded_margin']}")
        print(f"    {BASE}x: {c['nx']}x{c['ny']}x{c['nz']} @ {float(c['spacing_mm']):.6f} mm, "
              f"{c['dofs']} dofs, ACCEPTED={c['accepted']}, load_path_ok={c['load_path_ok']}")
        for rf in REFS:
            if rf == BASE: continue
            fs = by.get((m, vf, rf))
            if not fs: continue
            f = fs[0]
            print(f"    {rf}x: {f['nx']}x{f['ny']}x{f['nz']} @ {float(f['spacing_mm']):.6f} mm, "
                  f"{f['dofs']} dofs, ACCEPTED={f['accepted']}, load_path_ok={f['load_path_ok']} "
                  f"(Load voxels {f['load_voxels']}, {f['load_unprinted']} NOT printed)")
            print(f"      {'quantity':28s} {'as certified':>20s} {'reference':>20s} "
                  f"{'rel err of coarse':>18s}   vs floor")
            for key, label in GATE:
                a, b = F(c, key), F(f, key)
                e = rel(a, b)
                mult = abs(e) / FLOOR if FLOOR else float('inf')
                verdict = ('MEASUREMENT' if mult >= 10 else
                           'above floor' if mult >= 1 else 'AT THE FLOOR')
                print(f"      {label:28s} {a:20.10g} {b:20.10g} {e:+18.4e}  "
                      f"{mult:11.0f}x  {verdict}")
            print(f"      {'ACCEPT verdict':28s} {c['accepted']:>20s} {f['accepted']:>20s} "
                  f"{'MOVED' if c['accepted'] != f['accepted'] else 'unchanged':>18s}")
            print(f"      peak cell {BASE}x (i,j,k)=({c['peak_i']},{c['peak_j']},{c['peak_k']}) "
                  f"tag={c['peak_tag']}  ->  {rf}x coarse-equivalent "
                  f"({int(f['peak_i'])//rf},{int(f['peak_j'])//rf},{int(f['peak_k'])//rf}) "
                  f"tag={f['peak_tag']}  "
                  f"{'SAME CELL' if (int(f['peak_i'])//rf, int(f['peak_j'])//rf, int(f['peak_k'])//rf) == (int(c['peak_i']), int(c['peak_j']), int(c['peak_k'])) else 'moved'}")
            print(f"      tag repair {f['tag_repair_voxels']} voxels; ceil-gap printed cells lost "
                  f"{f['ceil_gap_printed']}; resultant {f['load_resultant_z']} N")

# ══ S1(c) -- SURFACE vs INTERIOR ════════════════════════════════════════════
print()
print("=" * 92)
print("S1(c) -- SURFACE vs INTERIOR (the split a whole-part number would hide)")
print("=" * 92)
print(f"  {'mode':>10} {'rung':>6} {'refine':>7} {'peak BOUNDARY':>18} {'peak INTERIOR':>18} "
      f"{'bdry/int':>9} {'err BOUNDARY':>14} {'err INTERIOR':>14}")
for m in MODES:
    for vf in VFS:
        c = by.get((m, vf, BASE), [None])[0]
        for rf in REFS:
            rs = by.get((m, vf, rf))
            if not rs: continue
            r = rs[0]
            b, i = F(r, 'peak_vm_boundary_onlattice'), F(r, 'peak_vm_interior_onlattice')
            if rf == BASE or c is None:
                eb = ei = ''
            else:
                eb = f"{rel(F(c,'peak_vm_boundary_onlattice'), b):+.4e}"
                ei = f"{rel(F(c,'peak_vm_interior_onlattice'), i):+.4e}"
            print(f"  {m:>10} {vf:6.2f} {rf:6d}x {b:18.10g} {i:18.10g} "
                  f"{b/i if i else 0:9.4f} {eb:>14} {ei:>14}")

# ══ CONVERGENCE ORDER, where three points exist ═════════════════════════════
print()
print("=" * 92)
print("THE THIRD POINT -- is the reference itself converged?")
print("""
  A CONVERGENT quantity settles: each refinement moves it less than the last, and
  the successive-refinement exponent q in  peak ~ h^-q  decays toward 0. A
  SINGULAR one does not: q stays put, and there is no limit to extrapolate to.
  So this reports q per refinement step rather than fitting a convergent form and
  quoting an extrapolated value the data may not support.
""")
for m in MODES:
    for vf in VFS:
        pts = []
        for rf in REFS:
            rs = by.get((m, vf, rf))
            if rs:
                pts.append((F(rs[0], 'spacing_mm'), F(rs[0], 'peak_vm_mpa'),
                            F(rs[0], 'peak_vm_surface')))
        if len(pts) < 2:
            continue
        pts.sort(reverse=True)  # coarsest first
        print(f"\n  {m}, rung {vf:.2f}:")
        for h, f, s in pts:
            print(f"    h = {h:.6f} mm   peak(centroid) {f:.10g}   peak(surface) {s:.10g}")
        if len(pts) < 3:
            (h1, f1, s1), (h2, f2, s2) = pts
            q = math.log(f2 / f1) / math.log(h1 / h2)
            print(f"    ONE refinement only -- q = {q:.4f}, but a single step cannot "
                  f"distinguish convergence from divergence. Not quoted as an order.")
            continue
        qs = []
        for i in range(len(pts) - 1):
            (h1, f1, s1), (h2, f2, s2) = pts[i], pts[i + 1]
            q = math.log(f2 / f1) / math.log(h1 / h2)
            qsurf = math.log(s2 / s1) / math.log(h1 / h2)
            qs.append(q)
            print(f"    refine x{h1/h2:.3f}: centroid x{f2/f1:.5f} -> q = {q:.4f}"
                  f"   |   surface x{s2/s1:.5f} -> q = {qsurf:.4f}")
        decaying = all(qs[i + 1] < 0.5 * qs[i] for i in range(len(qs) - 1))
        if decaying:
            print("    q is COLLAPSING between steps -> the sequence is converging; an "
                  "extrapolated limit would be meaningful.")
        else:
            print(f"    q is NOT collapsing ({' -> '.join(f'{x:.4f}' for x in qs)}).")
            print("    ** THE PEAK IS NOT CONVERGING. There is no limit to extrapolate to,")
            print("       so 'the correct margin' does not exist for this stress measure on")
            print("       this geometry. What CAN be quoted is how far it moves per")
            print("       refinement, which is what the S1(b) table reports. **")
            print(f"       For reference, the 2-D re-entrant 90-degree corner exponent is")
            print(f"       0.4555 and a crack is 0.5.")

# ══ R4 -- ITERATIONS AND WALL, SEPARATELY ═══════════════════════════════════
print()
print("=" * 92)
print("R4 -- ITERATIONS AND WALL, SEPARATELY")
print("=" * 92)
print(f"  {'mode':>10} {'rung':>6} {'refine':>7} {'dofs':>12} {'operator applies':>17} "
      f"{'wall (s)':>10} {'applies x':>10} {'wall x':>8}")
for m in MODES:
    for vf in VFS:
        c = by.get((m, vf, BASE), [None])[0]
        for rf in REFS:
            for r in by.get((m, vf, rf), []):
                am = F(r, 'matvecs') / F(c, 'matvecs') if c else 0
                aw = F(r, 'wall_s') / F(c, 'wall_s') if c else 0
                print(f"  {m:>10} {vf:6.2f} {rf:6d}x {r['dofs']:>12} {r['matvecs']:>17} "
                      f"{F(r,'wall_s'):10.1f} {am:10.2f} {aw:8.2f}")

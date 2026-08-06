#!/usr/bin/env python3
"""R1 — THE BEFORE/AFTER TABLE ON HIS OWN PART, RESOLUTION 128, ALL FOUR RUNGS.
(task 2026-08-06-arm-projection-and-void-check)

    ./r1_table_128.py <probe-work-dir>

SUBJECT, stated precisely because it decides what the numbers mean. His part at
resolution 128, all four rungs, from
`evidence/2026-08-03-multiscale-lattice-to/m2_multiscale_final/` — the same four
exported meshes PR 307 measured, so its headline figures are directly
reproducible here rather than merely compatible with these.

BEFORE = those meshes as committed, i.e. what the pipeline exported with
`output.project_cad_faces` absent under the OLD default (off).
AFTER  = the same meshes through `cad_project_probe`, which makes the SAME two
calls `export_variant_mesh` makes (`attribute_to_cad_faces` then
`project_onto_cad_faces` with `cad_project_options_for_grid`, run_job.cpp:342-347)
and therefore reproduces the shipped projection, INCLUDING this task's weld
guard.

★ WHY THE MESHES ARE PROJECTED HERE RATHER THAN RE-OPTIMIZED. The design is not
an input to either default: projection runs after the design, the field, the
certification and the report are all final, and the void check either refuses a
rung or does nothing. Re-running the hour-long optimize would reproduce the same
design and then project it — which is what this does, without pretending the
optimizer had anything to say about it. The DEFAULT-PATH comparison (same job
document, two binaries, the keys absent) is measured separately in
r1_before_after.py; this is the four-rung geometry table.
"""
import csv, os, struct, sys, collections

W = os.path.abspath(sys.argv[1])
RUNGS = ["variant_026", "variant_038", "variant_052", "variant_068"]
PLA_DENSITY_G_MM3 = 1.24 / 1000.0   # materials.json PLA, 1.24 g/cm^3


def stl(path):
    d = open(path, "rb").read()
    n = struct.unpack("<I", d[80:84])[0]
    vol = 0.0
    idx = {}
    ec = collections.Counter()
    F = []
    off = 84
    for _ in range(n):
        v = struct.unpack_from("<12f", d, off); off += 50
        a, b, c = v[3:6], v[6:9], v[9:12]
        vol += (a[0] * (b[1] * c[2] - b[2] * c[1])
                - a[1] * (b[0] * c[2] - b[2] * c[0])
                + a[2] * (b[0] * c[1] - b[1] * c[0])) / 6.0
        f = []
        for p in (a, b, c):
            k = struct.pack("<3f", *p)
            if k not in idx:
                idx[k] = len(idx)
            f.append(idx[k])
        F.append(f)
    degen = 0
    for a, b, c in F:
        if a == b or b == c or a == c:
            degen += 1
            continue
        for e in ((a, b), (b, c), (c, a)):
            ec[tuple(sorted(e))] += 1
    bad = sum(1 for x in ec.values() if x != 2)
    return dict(tris=n, verts=len(idx), volume=abs(vol),
                watertight=(bad == 0 and degen == 0), nonmanifold=bad)


bores = collections.defaultdict(list)
for r in csv.DictReader(open(os.path.join(W, "s3_bores.csv"))):
    bores[r["variant"].replace(".stl", "")].append(r)
flats = collections.defaultdict(list)
for r in csv.DictReader(open(os.path.join(W, "s3_flats.csv"))):
    flats[r["variant"].replace(".stl", "")].append(r)
motion = {}
for r in csv.DictReader(open(os.path.join(W, "s3_motion.csv"))):
    motion[r["variant"].replace(".stl", "")] = r

print("=" * 104)
print("R1 — HIS OWN PART, RESOLUTION 128, ALL FOUR RUNGS")
print("     BEFORE = both defaults OFF (what shipped)   AFTER = both ON (what ships now)")
print("=" * 104)
print()

h = (f"{'rung':<12}{'arm':<8}{'watertight':>11}{'tris':>8}"
     f"{'exported mm^3':>15}{'mesh mass g':>13}{'Δ mass':>10}")
print(h); print("-" * len(h))
for v in RUNGS:
    b = stl(os.path.join(W, v + ".stl"))
    a = stl(os.path.join(W, v + "_projected.stl"))
    bm = b["volume"] * PLA_DENSITY_G_MM3
    am = a["volume"] * PLA_DENSITY_G_MM3
    print(f"{v:<12}{'before':<8}{('yes' if b['watertight'] else 'NO'):>11}"
          f"{b['tris']:>8}{b['volume']:>15.1f}{bm:>13.2f}{'':>10}")
    print(f"{v:<12}{'after':<8}{('yes' if a['watertight'] else 'NO'):>11}"
          f"{a['tris']:>8}{a['volume']:>15.1f}{am:>13.2f}"
          f"{100.0 * (am - bm) / bm:>9.2f}%")
print()

print("=" * 104)
print("BOLT BORES — every 3.0000 mm bore, measured about its OWN B-rep axis")
print("=" * 104)
h = (f"{'rung':<12}{'face':>5}{'nominal':>9}{'before min':>12}{'before max':>12}"
     f"{'before oor':>12}{'after min':>11}{'after max':>11}{'after oor':>11}")
print(h); print("-" * len(h))
for v in RUNGS:
    for r in bores[v]:
        if abs(float(r["nominal_radius_mm"]) - 3.0) > 1e-9:
            continue
        print(f"{v:<12}{r['face_id']:>5}{float(r['nominal_radius_mm']):>9.4f}"
              f"{float(r['before_min']):>12.4f}{float(r['before_max']):>12.4f}"
              f"{float(r['before_oor']):>12.4f}"
              f"{float(r['after_min']):>11.4f}{float(r['after_max']):>11.4f}"
              f"{float(r['after_oor']):>11.2e}")
print()
print("WORST out-of-roundness over EVERY cylindrical face (bores, fillets, arcs):")
for v in RUNGS:
    wb = max(float(r["before_oor"]) for r in bores[v])
    wa = max(float(r["after_oor"]) for r in bores[v])
    print(f"  {v}: {wb:.4f} mm  ->  {wa:.3e} mm")
print()

print("=" * 104)
print("FLAT FACES — deviation from each face's OWN nominal plane")
print("=" * 104)
h = f"{'rung':<12}{'faces':>7}{'worst max before':>19}{'worst rms before':>19}{'worst max after':>18}"
print(h); print("-" * len(h))
for v in RUNGS:
    rows = flats[v]
    print(f"{v:<12}{len(rows):>7}"
          f"{max(float(r['before_max_abs']) for r in rows):>19.6f}"
          f"{max(float(r['before_rms']) for r in rows):>19.6f}"
          f"{max(float(r['after_max_abs']) for r in rows):>18.3e}")
print()

print("=" * 104)
print("MOTION AND THE GUARDS")
print("=" * 104)
h = (f"{'rung':<12}{'verts':>9}{'attributed':>12}{'moved':>9}"
     f"{'max move mm':>13}{'rms move mm':>13}{'guard refused':>15}")
print(h); print("-" * len(h))
for v in RUNGS:
    m = motion[v]
    print(f"{v:<12}{int(m['verts']):>9}{int(m['attributed']):>12}"
          f"{int(m['moved']):>9}{float(m['max_move_mm']):>13.6f}"
          f"{float(m['rms_move_mm']):>13.6f}{int(m['refused_by_guard']):>15}")

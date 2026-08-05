#!/usr/bin/env python3
"""S2 + S4 ON THE CASE WHERE RETENTION ACTUALLY FIRES.
(task 2026-08-04-subfloor-lattice-unloaded-regions)

WHY THIS RUN EXISTS, stated plainly because it is the difference between a
measurement and a formality.

`s2s3s4_maintainer_case.py` runs his job EXACTLY as he wrote it, off vs on. On
that job retention retains NOTHING — the union of his 8 include regions measures
0.9102 of the part's peak von Mises — so the margin delta it reports is 0.0000 %
on every rung. That number is true and it prices nothing: you cannot price a
relaxation on a run where the relaxation did not happen.

`subfloor_region_probe` then measured each of his include regions separately on
his own part and found exactly one that qualifies: a 137 x 31 mm, 4 mm-deep wall
at 0.1707 of peak. That is his "back wall that carries no load and exists for
geometry".

So this pair is HIS job with the lattice scoped to THAT wall, off vs on, at his
resolution 128. Retention fires here, and these are the numbers S2 and S4 ask for.

  usage: s2s4_wall_case.py <off-out-dir> <on-out-dir>
"""
import json
import os
import struct
import sys

# The acceptance bound, stated before the measurement is read. Same reasoning and
# same number as s2s3s4_maintainer_case.py — see that file's header for the
# derivation from handoff protect-freeze-vs-solidity §10.
MAX_ACCEPTED_DELTA_PCT = 0.10


def rungs(d):
    rep = json.load(open(os.path.join(d, "report.json")))
    vs = list(rep.get("variants") or []) + list(rep.get("rejected_variants") or [])
    return sorted(vs, key=lambda v: -v["volume_fraction"])


def receipt(d, vf):
    p = os.path.join(d, f"variant_{int(round(vf * 100)):03d}_lattice.report.json")
    return json.load(open(p)) if os.path.exists(p) else None


def read_fields(path):
    b = open(path, "rb").read()
    if b[0] != 1:
        raise SystemExit(f"fields.bin: unexpected version {b[0]}")
    o = 4
    nx, ny, nz = struct.unpack_from("<iii", b, o); o += 12
    o += 8 * 3 + 8 + 8
    nvar, _ = struct.unpack_from("<ii", b, o); o += 8
    out = {}
    for _ in range(nvar):
        vf, = struct.unpack_from("<d", b, o); o += 8
        o += 8 + 8
        vm_n, st_n, dp_n = struct.unpack_from("<qqq", b, o); o += 24
        out[round(vf, 6)] = struct.unpack_from(f"<{vm_n}f", b, o) if vm_n else ()
        o += 4 * (vm_n + st_n + dp_n)
    return nx, ny, nz, out


def argmax_vm(vm, nx, ny):
    if not vm:
        return None, None
    bi, best = 0, vm[0]
    for e in range(1, len(vm)):
        if vm[e] > best:
            best, bi = vm[e], e
    return best, (bi % nx, (bi // nx) % ny, bi // (nx * ny))


def main():
    off_d, on_d = sys.argv[1], sys.argv[2]
    print("=== S2 + S4 — THE MAINTAINER'S WALL, retention OFF vs ON ===")
    print("M2_verticalStand.step, resolution 128, HIS job document with the")
    print("lattice scoped to his one qualifying include region: a 137x31mm,")
    print("4mm-deep wall measured at 0.1707 of the part's peak von Mises.")
    print()

    # ── S2: what was actually latticed ─────────────────────────────────────────
    print("--- S2: the maintainer's case, measured ---")
    print(f"{'rung':>6} {'region':>8} {'lat OFF':>9} {'lat ON':>8} "
          f"{'OFF%':>7} {'ON%':>7} {'retained':>9} {'recov':>7} "
          f"{'cpm lo-hi':>13} {'strut mm lo-hi':>18}")
    for a in rungs(off_d):
        vf = a["volume_fraction"]
        co, cn = receipt(off_d, vf), receipt(on_d, vf)
        if not co or not cn:
            print(f"{vf:>6.2f}   (no lattice receipt on one side)")
            continue
        go, gn = co.get("grading") or {}, cn.get("grading") or {}
        s = gn.get("subfloor_retention") or {}
        rv = go.get("region_voxels", 0)
        lo, ln = go.get("latticed_voxels", 0), gn.get("latticed_voxels", 0)
        cpm = s.get("retained_cells_per_member") or [0, 0]
        dia = s.get("retained_strut_diameter_mm") or [0, 0]
        print(f"{vf:>6.2f} {rv:>8} {lo:>9} {ln:>8} "
              f"{(lo/rv if rv else 0):>6.1%} {(ln/rv if rv else 0):>6.1%} "
              f"{s.get('voxels_retained', 0):>9} "
              f"{s.get('voxels_recovered_in_regime', 0):>7} "
              f"{cpm[0]:>6.2f}-{cpm[1]:<6.2f} {dia[0]:>8.4f}-{dia[1]:<9.4f}")
    print()
    c = receipt(on_d, rungs(off_d)[0]["volume_fraction"])
    s = ((c or {}).get("grading") or {}).get("subfloor_retention") or {}
    if s:
        print("the predicate, as the run measured it (top rung):")
        print(f"  region peak vM / part peak vM = "
              f"{s.get('region_stress_fraction_measured'):.6f}")
        print(f"  ceiling                       = {s.get('stress_fraction_ceiling')}")
        print(f"  region qualified              = {s.get('region_qualified')}")
        print(f"  cells-per-member floor        = {s.get('cells_per_member_floor')}")
        print()

    # ── the OUT-OF-REGIME flag must be raised where material was retained ──────
    print("--- the flag stays, and it is specific ---")
    print(f"{'rung':>6} {'retained':>9} {'strut_out_of_regime OFF':>25} "
          f"{'ON':>8} {'min cells/member ON':>20}")
    for a in rungs(off_d):
        vf = a["volume_fraction"]
        co, cn = receipt(off_d, vf), receipt(on_d, vf)
        if not co or not cn:
            continue
        s = ((cn.get("grading") or {}).get("subfloor_retention") or {})
        # The flag lives inside the receipt's strut_strength block, alongside the
        # cells-per-member number the analysis actually compared to the floor.
        so = co.get("strut_strength") or {}
        sn = cn.get("strut_strength") or {}
        print(f"{vf:>6.2f} {s.get('voxels_retained', 0):>9} "
              f"{str(so.get('out_of_regime')):>25} "
              f"{str(sn.get('out_of_regime')):>8} "
              f"{sn.get('cells_per_member_min', float('nan')):>20.4f}")
    print()

    # ── S4: the margin, priced, on a run where retention DID something ─────────
    print("--- S4: the margin, priced ---")
    print("SOLID gate (the ladder's own verdict — retention cannot touch it):")
    print(f"{'rung':>6} {'verdict OFF':>12} {'margin OFF':>15} "
          f"{'verdict ON':>12} {'margin ON':>15} {'d':>11}")
    worst, worst_rung, flip = 0.0, None, False
    for a, b in zip(rungs(off_d), rungs(on_d)):
        ma = (a.get("margin") or {}).get("worst_case")
        mb = (b.get("margin") or {}).get("worst_case")
        va = "ACCEPT" if a["accepted"] else "reject"
        vb = "ACCEPT" if b["accepted"] else "reject"
        flip = flip or (va != vb)
        d = 100.0 * (mb - ma) / ma if ma else 0.0
        print(f"{a['volume_fraction']:>6.2f} {va:>12} {ma:>15.6f} "
              f"{vb:>12} {mb:>15.6f} {d:>+10.4f}%")
    print()
    print("COMPOSITE lattice certificate (the number retention actually moves):")
    print(f"{'rung':>6} {'verdict OFF':>12} {'margin OFF':>15} "
          f"{'verdict ON':>12} {'margin ON':>15} {'d':>11}")
    for a in rungs(off_d):
        vf = a["volume_fraction"]
        co, cn = receipt(off_d, vf), receipt(on_d, vf)
        if not co or not cn:
            continue
        ma, mb = co.get("lattice_margin_worst_case"), cn.get("lattice_margin_worst_case")
        va, vb = bool(co.get("lattice_accepted")), bool(cn.get("lattice_accepted"))
        flip = flip or (va != vb)
        d = 100.0 * (mb - ma) / ma if (ma and mb is not None) else 0.0
        if abs(d) > abs(worst):
            worst, worst_rung = d, vf
        print(f"{vf:>6.2f} {str(va):>12} {ma:>15.6f} {str(vb):>12} "
              f"{mb:>15.6f} {d:>+10.4f}%")
    print()
    print(f"largest |d composite margin| = {abs(worst):.4f}% (rung {worst_rung})")
    print(f"stated acceptance bound      = {MAX_ACCEPTED_DELTA_PCT:.2f}%")
    print("S4 " + ("MET" if abs(worst) <= MAX_ACCEPTED_DELTA_PCT
                   else "EXCEEDED — BLOCKED-STOP, report the number, do not move "
                        "the threshold to fit it"))
    if worst < 0:
        print("NOTE: the largest movement is NEGATIVE (the certified margin went "
              "DOWN). Every movement §10 measured was positive.")
    print("verdict flips: " + ("YES — BLOCKED-STOP" if flip else "none"))
    print()

    # ── S3 on this pair too: the argmax ────────────────────────────────────────
    print("--- S3: the argmax, on the run where retention FIRED ---")
    nx, ny, nz, vo = read_fields(os.path.join(off_d, "fields.bin"))
    _, _, _, vn = read_fields(os.path.join(on_d, "fields.bin"))
    print(f"grid {nx}x{ny}x{nz}; the COMPOSITE solve's own von Mises field.")
    print(f"{'rung':>6} {'peak OFF':>13} {'argmax OFF':>18} "
          f"{'peak ON':>13} {'argmax ON':>18}")
    moved = False
    for vf in sorted(set(vo) & set(vn), reverse=True):
        po, ao = argmax_vm(vo[vf], nx, ny)
        pn, an = argmax_vm(vn[vf], nx, ny)
        moved = moved or (ao != an)
        print(f"{vf:>6.2f} {po:>13.6f} {str(ao):>18} {pn:>13.6f} "
              f"{str(an):>18}  {'MOVED' if ao != an else 'same'}")
    print()
    print("S3 " + ("FAILED — THE ARGMAX MOVED. BLOCKED-STOP." if moved else
                   "MET — the peak von Mises stayed at the same voxel on every "
                   "rung, with material actually retained below the floor."))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""S2 / S3 / S4 — THE MAINTAINER'S CASE, THE ARGMAX, AND THE PRICE, ON A REAL PART.
(task 2026-08-04-subfloor-lattice-unloaded-regions)

Runs HIS job document (evidence/2026-08-04-protect-freeze-vs-solidity/
job_maintainer.json, unmodified except the model path) on M2_verticalStand.step at
resolution 128 — TWICE. Once exactly as he wrote it, and once with a single key
added:  "grading": { ..., "retain_subfloor_in_unloaded_regions": true }.

Everything below is read off those two runs. Nothing is hand-written.

  S2  THE MAINTAINER'S CASE. latticed_voxels against region_voxels, the
      cells-per-member achieved, and the strut diameters. States the fraction
      latticed. If it is near zero the filter was not the blocker, and THAT is
      the finding — reported, not explained away.

  S3  THE ARGMAX MUST NOT MOVE, on a REAL part rather than the probe cantilever.
      Peak von Mises AND ITS LOCATION are read out of fields.bin (the composite
      solve's own field) with the region solid vs sub-floor-latticed. A move is a
      BLOCKED-STOP: §10's probe result did not generalise.

  S4  THE MARGIN, PRICED. The certified margin both ways, per rung, and the delta.

  usage: s2s3s4_maintainer_case.py <off-out-dir> <on-out-dir>
"""
import json
import os
import struct
import sys

# ── THE ACCEPTANCE BOUND FOR S4, STATED BEFORE THE MEASUREMENT IS READ ──────────
# The largest certified-margin movement this task will accept on the real part.
#
# 0.10 % is chosen as the largest Δ handoff protect-freeze-vs-solidity §10 measured
# ANYWHERE across its whole six-station sweep (+0.0823 % at a region carrying
# 23.5 % of peak) — a station the 0.20 threshold shipped here REJECTS. So the bound
# is deliberately loose relative to what should actually happen: at or under 20 % of
# peak §10 measured no movement larger than +0.0008 %. If the real part moves more
# than the worst thing measured at a stress fraction we refuse to admit, the
# extrapolation from that probe to this part has failed, and that is a stop.
#
# AND A DIRECTION, because magnitude alone is not the whole risk. Every movement §10
# saw was POSITIVE — the certified margin went UP, the safe direction. A NEGATIVE
# delta is a different animal even when it is small, so it is called out separately
# rather than being absorbed into an absolute value.
MAX_ACCEPTED_DELTA_PCT = 0.10


def rungs(d):
    rep = json.load(open(os.path.join(d, "report.json")))
    vs = list(rep.get("variants") or []) + list(rep.get("rejected_variants") or [])
    return sorted(vs, key=lambda v: -v["volume_fraction"])


def receipt(d, vf):
    p = os.path.join(d, f"variant_{int(round(vf * 100)):03d}_lattice.report.json")
    return json.load(open(p)) if os.path.exists(p) else None


def read_fields(path):
    """fields.bin v1 -> (nx, ny, nz, {requested_vf: [von_mises floats]}).

    Format is documented in core/include/topopt/fields.hpp. The version byte is
    checked first, as that header requires."""
    with open(path, "rb") as f:
        blob = f.read()
    ver = blob[0]
    if ver != 1:
        raise SystemExit(f"fields.bin: unexpected version {ver}")
    off = 4
    nx, ny, nz = struct.unpack_from("<iii", blob, off); off += 12
    off += 8 * 3          # origin
    off += 8              # spacing
    off += 8              # voxel volume
    nvar, _ = struct.unpack_from("<ii", blob, off); off += 8
    out = {}
    n = nx * ny * nz
    for _ in range(nvar):
        vf, = struct.unpack_from("<d", blob, off); off += 8
        off += 8          # mass
        off += 8          # support voxels + reserved
        vm_n, st_n, disp_n = struct.unpack_from("<qqq", blob, off); off += 24
        vm = struct.unpack_from(f"<{vm_n}f", blob, off) if vm_n else ()
        off += 4 * vm_n
        off += 4 * st_n
        off += 4 * disp_n
        out[round(vf, 6)] = vm
        assert vm_n in (0, n), (vm_n, n)
    return nx, ny, nz, out


def argmax_vm(vm, nx, ny, nz):
    """Peak von Mises and WHERE it is, as an (i, j, k) voxel index."""
    if not vm:
        return None, None
    best_i, best = 0, vm[0]
    for e in range(1, len(vm)):
        if vm[e] > best:
            best, best_i = vm[e], e
    i = best_i % nx
    j = (best_i // nx) % ny
    k = best_i // (nx * ny)
    return best, (i, j, k)


def num(x, w=14, p=6):
    return f"{x:>{w}.{p}f}" if isinstance(x, (int, float)) else f"{'—':>{w}}"


def main():
    off_d, on_d = sys.argv[1], sys.argv[2]
    print("=== S2 / S3 / S4 — the maintainer's own job, retention OFF vs ON ===")
    print("M2_verticalStand.step, resolution 128, his job document unmodified")
    print("except a single added key: grading.retain_subfloor_in_unloaded_regions.")
    print()

    ro, rn = rungs(off_d), rungs(on_d)

    # ── S4: THE MARGIN, BOTH WAYS, PER RUNG ────────────────────────────────────
    print("--- S4: the certified margin, priced ---")
    print(f"{'rung':>6} {'verdict off':>12} {'margin off':>14} "
          f"{'verdict on':>12} {'margin on':>14} {'d margin':>12}")
    worst_delta = 0.0
    worst_rung = None
    any_verdict_flip = False
    for a, b in zip(ro, rn):
        assert abs(a["volume_fraction"] - b["volume_fraction"]) < 1e-9, "rung mismatch"
        # The solid gate's margin. `margin` is the block; `worst_case` inside it
        # is the number the verdict is taken on.
        ma = (a.get("margin") or {}).get("worst_case", a.get("margin_effective"))
        mb = (b.get("margin") or {}).get("worst_case", b.get("margin_effective"))
        va = "ACCEPT" if a["accepted"] else "reject"
        vb = "ACCEPT" if b["accepted"] else "reject"
        if va != vb:
            any_verdict_flip = True
        d = 100.0 * (mb - ma) / ma if ma else 0.0
        if abs(d) > abs(worst_delta):
            worst_delta, worst_rung = d, a["volume_fraction"]
        print(f"{a['volume_fraction']:>6.2f} {va:>12} {num(ma)} "
              f"{vb:>12} {num(mb)} {d:>+11.4f}%")
    print()
    print(f"largest |d margin| = {abs(worst_delta):.4f}% "
          f"(rung {worst_rung}); accepted bound = {MAX_ACCEPTED_DELTA_PCT:.2f}%")
    print("S4 " + ("MET" if abs(worst_delta) <= MAX_ACCEPTED_DELTA_PCT
                   else "EXCEEDED — BLOCKED-STOP"))
    if worst_delta < 0:
        print("NOTE: the largest movement is NEGATIVE (margin went DOWN). Every "
              "movement §10 measured was positive; this one is not.")
    print(f"verdict flips: {'YES — BLOCKED-STOP' if any_verdict_flip else 'none'}")
    print()

    # ── S2: WHAT WAS ACTUALLY LATTICED ─────────────────────────────────────────
    print("--- S2: the maintainer's case ---")
    print(f"{'rung':>6} {'region vox':>11} {'latticed off':>13} "
          f"{'latticed on':>12} {'frac off':>9} {'frac on':>9} "
          f"{'retained':>9} {'min cpm':>8} {'strut mm':>16}")
    for a in ro:
        vf = a["volume_fraction"]
        co, cn = receipt(off_d, vf), receipt(on_d, vf)
        if not co or not cn:
            print(f"{vf:>6.2f} {'(no lattice receipt)':>60}")
            continue
        go = (co.get("grading") or {})
        gn = (cn.get("grading") or {})
        sub = gn.get("subfloor_retention") or {}
        rv = go.get("region_voxels", 0)
        lo, ln = go.get("latticed_voxels", 0), gn.get("latticed_voxels", 0)
        fo = lo / rv if rv else 0.0
        fn = ln / rv if rv else 0.0
        cpm = sub.get("retained_cells_per_member") or [0, 0]
        dia = sub.get("retained_strut_diameter_mm") or [0, 0]
        print(f"{vf:>6.2f} {rv:>11} {lo:>13} {ln:>12} "
              f"{fo:>8.1%} {fn:>8.1%} {sub.get('voxels_retained', 0):>9} "
              f"{cpm[0]:>8.2f} {dia[0]:>7.3f}-{dia[1]:<8.3f}")
    print()
    for a in ro[:1]:
        cn = receipt(on_d, a["volume_fraction"])
        sub = ((cn or {}).get("grading") or {}).get("subfloor_retention") or {}
        if sub:
            print("the retention predicate, as the run measured it:")
            print(f"  region peak vM / part peak vM = "
                  f"{sub.get('region_stress_fraction_measured'):.6f}")
            print(f"  ceiling                       = "
                  f"{sub.get('stress_fraction_ceiling'):.6f}")
            print(f"  region qualified              = {sub.get('region_qualified')}")
            print(f"  voxels below the floor        = "
                  f"{sub.get('voxels_below_floor')}")
            print(f"  voxels retained               = {sub.get('voxels_retained')}")
            print(f"  cells-per-member floor        = "
                  f"{sub.get('cells_per_member_floor')}")
    print()

    # ── S3: THE ARGMAX ─────────────────────────────────────────────────────────
    print("--- S3: does the argmax move on a REAL part? ---")
    fo = os.path.join(off_d, "fields.bin")
    fn = os.path.join(on_d, "fields.bin")
    if not (os.path.exists(fo) and os.path.exists(fn)):
        print("fields.bin missing on one side — cannot answer S3.")
        return 1
    nx, ny, nz, vo = read_fields(fo)
    _, _, _, vn = read_fields(fn)
    print(f"grid {nx}x{ny}x{nz}; comparing the COMPOSITE solve's own von Mises "
          f"field, variant by variant.")
    print(f"{'rung':>6} {'peak off':>13} {'argmax off':>18} "
          f"{'peak on':>13} {'argmax on':>18}  {'':>6}")
    moved_any = False
    for vf in sorted(set(vo) & set(vn), reverse=True):
        po, ao = argmax_vm(vo[vf], nx, ny, nz)
        pn, an = argmax_vm(vn[vf], nx, ny, nz)
        moved = ao != an
        moved_any = moved_any or moved
        print(f"{vf:>6.2f} {po:>13.6f} {str(ao):>18} "
              f"{pn:>13.6f} {str(an):>18}  {'MOVED' if moved else 'same'}")
    print()
    print("S3 " + ("FAILED — THE ARGMAX MOVED. BLOCKED-STOP: §10's probe result "
                   "did not generalise to a real part."
                   if moved_any else
                   "MET — the peak von Mises stayed at the same voxel on every "
                   "variant compared."))
    return 0


if __name__ == "__main__":
    sys.exit(main())

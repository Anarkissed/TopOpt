#!/usr/bin/env python3
"""BAR 2 — THE MAINTAINER'S CASE, MEASURED (task 2026-08-04-protect-freeze-vs-
solidity), and the maintainer's-job half of BAR 5's gate table.

Re-runs of HIS job document (evidence/…/job_maintainer.json, unmodified except
the model path) on M2_verticalStand.step at resolution 128, base (`main`) vs this
branch, compared rung by rung:

  * the SOLID gate verdict + margin      (report.json)
  * the COMPOSITE lattice verdict + margin, and the latticed voxel count
                                          (variant_*_lattice.report.json)
  * the frozen split the branch now reports, which base could not say at all

  usage: bar2_maintainer_case.py <base-out-dir> <branch-out-dir>
"""
import json
import os
import sys


def rungs(d):
    rep = json.load(open(os.path.join(d, "report.json")))
    vs = list(rep.get("variants") or []) + list(rep.get("rejected_variants") or [])
    return sorted(vs, key=lambda v: -v["volume_fraction"])


def receipt(d, vf):
    p = os.path.join(d, f"variant_{int(round(vf * 100)):03d}_lattice.report.json")
    return json.load(open(p)) if os.path.exists(p) else None


def main():
    base, branch = sys.argv[1], sys.argv[2]
    rb, rr = rungs(base), rungs(branch)
    print("=== BAR 2 / BAR 5 — the maintainer's own job, base vs branch ===")
    print("M2_verticalStand.step, resolution 128, his job document unmodified.")
    print()
    print(f"{'rung':>6} {'solid base':>22} {'solid branch':>22} "
          f"{'composite base':>24} {'composite branch':>24}")
    flips = 0
    for vb, vr in zip(rb, rr):
        cb, cr = receipt(base, vb["volume_fraction"]), receipt(branch, vr["volume_fraction"])
        sb = f"{str(vb['accepted']):>5} {vb['margin_effective']:>14.6f}"
        sr = f"{str(vr['accepted']):>5} {vr['margin_effective']:>14.6f}"
        def comp(c):
            if c is None: return f"{'(none)':>24}"
            return (f"{str(c['lattice_accepted']):>5} "
                    f"{c['lattice_margin_worst_case']:>11.4f} "
                    f"{c['lattice_voxels']:>5d}vx")
        if vb["accepted"] != vr["accepted"]:
            flips += 1
        if cb and cr and cb["lattice_accepted"] != cr["lattice_accepted"]:
            flips += 1
        print(f"{vb['volume_fraction']:>6.2f} {sb} {sr} {comp(cb)} {comp(cr)}")

    print()
    print("=== THE SPLIT PR 293 COULD NOT REPORT ===")
    print("PR 293 measured `region reachability: active=932 frozen_solid=10070")
    print("(of 11002)` and read the 10070 as UNREACHABLE. Under the new semantics")
    print("they are ordinary retained material and the include region applies to")
    print("them. What moved is not the mask — the optimizer's constraint is")
    print("unchanged — but what that frozen material is ALLOWED TO BECOME.")
    print()
    print(f"{'rung':>6} {'frozen printed':>15} {'in include':>12} {'latticed':>10} "
          f"{'kept solid':>12} {'total latticed vx':>18}")
    for vr in rr:
        c = receipt(branch, vr["volume_fraction"])
        if c is None or "frozen_material" not in c:
            print(f"{vr['volume_fraction']:>6.2f}  (no frozen_material block)")
            continue
        f = c["frozen_material"]
        print(f"{vr['volume_fraction']:>6.2f} {f['frozen_printed_voxels']:>15d} "
              f"{f['frozen_in_include_region']:>12d} {f['frozen_latticed']:>10d} "
              f"{f['frozen_kept_solid']:>12d} {c['lattice_voxels']:>18d}")

    print()
    print("=== THE AUDIT (bar 3) on his job ===")
    for vr in rr:
        c = receipt(branch, vr["volume_fraction"])
        if c is None or "frozen_material" not in c: continue
        f = c["frozen_material"]
        print(f"  vf {vr['volume_fraction']:.2f}: cells_not_emitted="
              f"{f['frozen_cells_not_emitted']} strut_and_solid="
              f"{f['frozen_voxels_strut_and_solid']} unexplained="
              f"{f['frozen_strut_and_solid_unexplained']} "
              f"in_exclude_latticed={f['frozen_in_exclude_region_latticed']}")

    print()
    print(f"VERDICT FLIPS: {flips}  "
          + ("— BAR 5 PASS on the maintainer's own job."
             if flips == 0 else "— *** BLOCKED-STOP ***"))
    return 1 if flips else 0


if __name__ == "__main__":
    sys.exit(main())

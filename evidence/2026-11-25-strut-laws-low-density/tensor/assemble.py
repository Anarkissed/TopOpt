#!/usr/bin/env python3
"""assemble.py TENSOR_DIR: the low-density tensor rows lattice.cpp carries, from the sweeps of run_tensor.sh (blocks
`low`: vpc 80 vs 120, `high`: vpc 64 vs 96) and run_tensor_floor.sh (block `floor`: vpc 96 vs 144).

Each block ran its rows against its own reference curve over the SAME targets, one process per block, so the probe's
own drift column is judged on that whole curve at the row's own rho (tensor_library_nine_probe's interp_curve). The
probe's rule, unchanged: VALIDATED := |drift| < 2.4 % AND vox/strut >= 6 AND converged. A row LANDS when it is
  * validated,
  * inside its block's reference curve (min rho_ref <= rho_row <= max rho_ref: interp_curve clamps outside it, so a
    drift there compares two different densities -- octet's 0.18522 was left out for that),
  * under the type's old band floor (the 11-09 rows from there up are unchanged),
  * and not the same density as a row of a finer block (two targets can voxelize to the same solid; within 1 % of
    rho, the finer block's row is kept).
A row that fails is left out, as octet's 0.18522 was (ruling 2026-11-02 (c)); its neighbours are interpolated across.
"""
import csv, os, sys

D = sys.argv[1]
OLD_FLOOR = {"bcc": 0.21050, "diamond": 0.15712, "sc": 0.08659}
FINENESS = {"floor": 3, "low": 2, "high": 1}
for t, old in OLD_FLOOR.items():
    print("== %s (old band floor %.5f)" % (t, old))
    cand = []
    for b in ("floor", "low", "high"):
        p = os.path.join(D, b, t + "_sweep.csv")
        if not os.path.exists(p):
            continue
        rows = list(csv.DictReader(open(p)))
        lo = min(float(r["rho_ref"]) for r in rows)
        hi = max(float(r["rho_ref"]) for r in rows)
        print("  %s: rows at vpc %s vs a vpc %s curve over rho %.5f .. %.5f" % (b, rows[0]["vpc_row"], rows[0]["vpc_ref"], lo, hi))
        seen = set()
        for r in sorted(rows, key=lambda r: float(r["rho_row"])):
            rho = float(r["rho_row"])
            v = r["validated"] == "1"
            inside = lo <= rho <= hi
            why = ("not validated" if not v else "outside its curve" if not inside else
                   "at/over the old floor" if rho >= old - 1e-9 else "same solid as the row below" if rho in seen else "")
            seen.add(rho)
            print("    target %s  rho %.5f  vox/strut %6.3f  E100 %10.4f  drift %+6.2f %%  cg %4s  %s"
                  % (r["target_vf"], rho, float(r["vox_per_strut"]), float(r["E100_row_MPa"]), float(r["drift_pct"]),
                     r["cg_iters"], why or "candidate"))
            if not why:
                cand.append((rho, FINENESS[b], b, r))
    landed = []
    for c in sorted(cand, key=lambda c: (c[0], -c[1])):
        clash = [l for l in landed if abs(l[0] - c[0]) <= 0.01 * c[0]]
        if clash:
            if clash[0][1] < c[1]:
                landed.remove(clash[0])
                landed.append(c)
            continue
        landed.append(c)
    landed.sort(key=lambda c: c[0])
    print("  lattice.cpp rows (Row{rho, C11, C12, C44, resolved}):")
    for rho, _, b, r in landed:
        print("    {%.5f, %.4f, %.4f, %.4f, true},  // %s vpc%s vs %s, drift %+.2f %%, %.1f vox/strut"
              % (rho, float(r["C11"]), float(r["C12"]), float(r["C44_xy"]), b, r["vpc_row"], r["vpc_ref"],
                 float(r["drift_pct"]), float(r["vox_per_strut"])))

#!/usr/bin/env python3
"""summary.py EV_DIR: one line per new strut-law row, for the README: its strut/cell, the law row's vpc and the strut's
voxels across (diameter, 2 r vpc) and the probe's wall_vox (median solid run along x; for sc it splits at the periodic
edge and reads about half), the boundary fixtures kept (and every aliased attempt), which population sets each
*_cert column, and the bulk K_dev growth over the law row's last 16-voxel step (the still-rising caveat)."""
import csv, os, sys

EV = sys.argv[1]
out = open(os.path.join(EV, "summary.csv"), "w")
out.write("type,rho_lib,strut_per_cell,law_vpc,law_diameter_vox,law_wall_vox,boundary_fixtures,Kd_cert,Kv_cert,"
          "Kild_cert,Kilv_cert,Kd_from,Kild_from,bulk_Kd_last_step,bulk_Kd_last_step_pct\n")
for t in ("bcc", "diamond", "sc"):
    d = os.path.join(EV, t)
    r_unit = {}
    for r in csv.DictReader(open(os.path.join(d, "k_states_bulk.csv"))):
        r_unit[r["rho_lib"]] = float(r["r_unit"])
    bulk = {}
    for r in csv.DictReader(open(os.path.join(d, "k_exact_bulk.csv"))):
        bulk.setdefault(r["rho_lib"], {})[int(r["vpc"])] = float(r["K_dev_max"])
    bnd = {}
    for r in csv.DictReader(open(os.path.join(d, "k_exact_boundary.csv"))):
        if r["population"] not in ("free_surface", "cut_layer"):
            continue
        lib, meas = float(r["rho_lib"]), float(r["rho_meas"])
        off = abs(meas - lib) / lib
        key = "%s N%s vpc%s (%.1f vox)%s" % (r["fixture"], r["N"], r["vpc"], 2 * r_unit[r["rho_lib"]] * int(r["vpc"]),
                                            "" if off <= 0.15 else " ALIASED %+.0f %%" % (100 * (meas - lib) / lib))
        bnd.setdefault(r["rho_lib"], [])
        if key not in bnd[r["rho_lib"]]:
            bnd[r["rho_lib"]].append(key)
    print("== %s" % t)
    for r in csv.DictReader(open(os.path.join(d, "kfit.csv"))):
        lib = r["rho_lib"]
        vpcs = sorted(bulk[lib])
        last = vpcs[-1]
        prev = [v for v in vpcs if v <= last - 16]
        step = "%d->%d" % (prev[-1], last) if prev else ""
        pct = 100 * (bulk[lib][last] / bulk[lib][prev[-1]] - 1) if prev else float("nan")
        kd_from = "boundary" if float(r["Kd_bnd"]) > float(r["Kd_bulk"]) else "bulk"
        kild_from = "boundary" if float(r["Kild_bnd"]) > float(r["Kild_bulk"]) else "bulk"
        sc = 2 * r_unit[lib]
        dvox = sc * int(r["vpc"])
        fx = "; ".join(bnd.get(lib, []))
        out.write('%s,%s,%.4f,%s,%.1f,%s,"%s",%s,%s,%s,%s,%s,%s,%s,%.1f\n' % (
            t, lib, sc, r["vpc"], dvox, r["wall_vox"], fx, r["Kd_cert"], r["Kv_cert"], r["Kild_cert"], r["Kilv_cert"],
            kd_from, kild_from, step, pct))
        print("  rho %s  strut/cell %.4f  law vpc %s (%.1f vox across, wall_vox %s)  Kd %s Kv %s Kild %s Kilv %s  "
              "Kd from %s, Kild from %s  bulk Kd %s %+.1f %%\n    boundary: %s"
              % (lib, sc, r["vpc"], dvox, r["wall_vox"], r["Kd_cert"], r["Kv_cert"], r["Kild_cert"], r["Kilv_cert"],
                 kd_from, kild_from, step, pct, fx))
out.close()

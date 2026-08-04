#!/usr/bin/env python3
"""analyze.py — turn the two M2 runs into the M2/M3/M4/M5/M7 tables.

Reads m2_multiscale/ and m2_twostep/ (produced by run_m2.sh) and writes the CSVs
the handoff quotes. Pure reporting: it computes nothing the runs did not measure.
"""
import csv, glob, json, os, statistics, sys

EV = os.path.dirname(os.path.abspath(__file__))


def receipts(run):
    """Per-variant lattice receipts, keyed by variant name, in ladder order."""
    out = {}
    for f in sorted(glob.glob(os.path.join(EV, run, "*_lattice.report.json"))):
        out[os.path.basename(f).replace("_lattice.report.json", "")] = json.load(open(f))
    return out


def dig(d, keys):
    o = {}
    for k, v in d.items():
        if any(s in k for s in keys):
            o[k] = v
        elif isinstance(v, dict):
            o.update(dig(v, keys))
    return o


def m2_table():
    """M2 — latticed_voxels against region_voxels, both ways."""
    rows = []
    for run in ("m2_twostep", "m2_multiscale"):
        for name, r in receipts(run).items():
            g = dig(r, ["region_voxels", "latticed_voxels", "solid_fallback",
                        "ungradeable", "rho_min_used", "rho_max_used"])
            rv = g.get("region_voxels", 0)
            lv = g.get("latticed_voxels", 0)
            rows.append(dict(run=run, variant=name, region_voxels=rv,
                             latticed_voxels=lv,
                             solid_fallback=g.get("solid_fallback_voxels", 0),
                             latticed_fraction=(lv / rv if rv else 0.0),
                             region_ungradeable=g.get("region_ungradeable", ""),
                             rho_min_used=g.get("rho_min_used", 0),
                             rho_max_used=g.get("rho_max_used", 0)))
    return rows


def m4_table():
    """M4 — the full gate table, every rung, verdict + margin, both ways."""
    rows = []
    for run in ("m2_twostep", "m2_multiscale"):
        p = os.path.join(EV, run, "report.json")
        if not os.path.exists(p):
            continue
        rep = json.load(open(p))
        for key in ("variants", "rejected_variants"):
            for v in rep.get(key, []):
                m = v.get("margin", {})
                rows.append(dict(run=run, kind=key, volume_fraction=v.get("volume_fraction"),
                                 accepted=v.get("accepted"),
                                 margin_worst_case=m.get("worst_case"),
                                 margin_in_plane=m.get("in_plane"),
                                 margin_interlayer=m.get("interlayer"),
                                 margin_effective=v.get("margin_effective"),
                                 margin_required=v.get("margin_required"),
                                 rejection_reason=v.get("rejection_reason", "")))
        # the LATTICED (composite) certification lives on the receipts
        for name, r in receipts(run).items():
            g = dig(r, ["lattice_margin", "lattice_accepted", "lattice_certified",
                        "lattice_strength_uncertified"])
            rows.append(dict(run=run, kind="latticed_recert", volume_fraction=name,
                             accepted=g.get("lattice_accepted"),
                             margin_worst_case=g.get("lattice_margin"),
                             margin_in_plane="", margin_interlayer="",
                             margin_effective="", margin_required="",
                             rejection_reason=""))
    return rows


def m5_table():
    """M5 — PR 263's strut-strength report on every multiscale receipt."""
    rows = []
    for run in ("m2_twostep", "m2_multiscale"):
        for name, r in receipts(run).items():
            g = dig(r, ["margin_in_plane", "margin_interlayer", "margin_worst_case",
                        "z_knockdown", "vm_bound_max_mpa", "il_bound_max_mpa",
                        "amplification", "strut_report", "out_of_regime",
                        "strut_strength_uncertified"])
            if not g:
                continue
            g["run"] = run
            g["variant"] = name
            rows.append(g)
    return rows


def m3_floor():
    """M3 — member thickness in cells, converged design, from run_info."""
    out = []
    p = os.path.join(EV, "m2_multiscale", "run_info.json")
    if os.path.exists(p):
        ms = json.load(open(p)).get("multiscale")
        if ms:
            for R in ms["rungs"]:
                out.append(dict(run="m2_multiscale", vf=R["volume_fraction"],
                                floor_cells=ms["cells_per_member_floor"],
                                floor_cell_mm=ms["floor_cell_mm"],
                                measured=R["floor_measured_voxels"],
                                below=R["floor_below_voxels"],
                                below_fraction=(R["floor_below_voxels"] /
                                                max(1, R["floor_measured_voxels"])),
                                min_cells=R["floor_min_cells_per_member"],
                                histogram=";".join(str(x) for x in R["floor_histogram"])))
    return out


def m7_cost():
    """M7 — DOF-weighted work and wall per design iteration, both ways."""
    rows = []
    for run in ("m2_twostep", "m2_multiscale"):
        p = os.path.join(EV, run, "iterations.csv")
        if not os.path.exists(p):
            continue
        it = list(csv.DictReader(open(p)))
        if not it:
            continue
        f = lambda k: [float(r[k]) for r in it]
        rows.append(dict(
            run=run, iterations=len(it),
            cg_mean=statistics.mean(f("cg_iters")),
            cg_min=min(f("cg_iters")), cg_max=max(f("cg_iters")),
            mg_engaged=sum(1 for r in it if r["cg_multigrid"] == "1"),
            matvecs_total=sum(f("matvecs")),
            matvecs_per_iter=statistics.mean(f("matvecs")),
            wall_ms_total=sum(f("total_ms")),
            wall_ms_per_iter=statistics.mean(f("total_ms")),
            fea_ms_per_iter=statistics.mean(f("fea_ms")),
            geneo_setup_ms_per_iter=statistics.mean(f("geneo_setup_ms")),
            peak_rss_mb=max(f("peak_rss_mb"))))
    return rows


def write(name, rows):
    if not rows:
        print("  (no rows for %s)" % name)
        return
    keys = list(rows[0].keys())
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    p = os.path.join(EV, name)
    with open(p, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print("  wrote", name, "(%d rows)" % len(rows))
    for r in rows:
        print("   ", {k: v for k, v in r.items() if k != "histogram"})


if __name__ == "__main__":
    print("M2 — latticed voxels against region voxels")
    write("m2_latticed.csv", m2_table())
    print("M3 — cells-per-member floor on the converged design")
    write("m3_floor.csv", m3_floor())
    print("M4 — the gate table")
    write("m4_gate_table.csv", m4_table())
    print("M5 — strut strength (report-only)")
    write("m5_strut_strength.csv", m5_table())
    print("M7 — cost per design iteration")
    write("m7_cost_m2.csv", m7_cost())

#!/usr/bin/env python3
"""Summarize an instrumented iterations.csv (task 2026-08-02-iteration-phase-timing).

Usage:  python3 summarize_phases.py <iterations.csv> [--rows]

Prints, per rung: the phase split as a percentage of measured iteration wall,
the accounting residue, and the solver's internal split. `--rows` also dumps
every row's headline columns. Pure reader — it changes nothing.
"""
import csv, sys, collections

PHASES = ["filter_ms", "project_ms", "solve_ms", "update_ms", "analysis_ms",
          "observe_ms", "residual_ms"]
SOLVER = ["solver_build_ms", "mg_build_ms", "mg_ms", "cg_ms",
          "geneo_setup_ms", "geneo_apply_ms", "recycle_ms"]
ROWCOLS = ["rung", "iter", "achieved_vf", "cg_iters", "cg_multigrid",
           "hier_built", "geneo_action", "geneo_dim", "total_ms", "mg_build_ms",
           "mg_ms", "cg_ms", "geneo_setup_ms", "geneo_apply_ms", "matvecs",
           "residual_ms", "rss_mb", "peak_rss_mb", "major_faults", "swapins"]


def main(path, show_rows):
    rows = list(csv.DictReader(open(path)))
    if not rows:
        print("no rows"); return
    if show_rows:
        print(" ".join("%-11s" % c for c in ROWCOLS))
        for r in rows:
            print(" ".join("%-11s" % r[c] for c in ROWCOLS))
        print()

    by_rung = collections.defaultdict(list)
    for r in rows:
        by_rung[r["rung"]].append(r)

    for rung in sorted(by_rung, key=int) + ["ALL"]:
        rs = rows if rung == "ALL" else by_rung[rung]
        tot = collections.defaultdict(float)
        for r in rs:
            for k in PHASES + SOLVER + ["total_ms", "tail_prev_ms", "fea_ms",
                                        "sens_ms"]:
                tot[k] += float(r[k])
        T = tot["total_ms"] or 1.0
        mg = sum(1 for r in rs if r["cg_multigrid"] == "1")
        latched = sum(1 for r in rs if r["hier_built"] == "0")
        print("== rung %s : %d iters, %.1f s wall, MG carried %d/%d, "
              "hierarchy-build skipped (latched) %d ==" %
              (rung, len(rs), T / 1000.0, mg, len(rs), latched))
        for k in PHASES:
            print("   %-16s %10.1f s  %6.2f%%" % (k, tot[k] / 1000.0,
                                                  100 * tot[k] / T))
        print("   -- solve_ms splits (sub-split; not extra terms) --")
        for k in ["fea_ms", "sens_ms"] + SOLVER:
            print("   %-16s %10.1f s  %6.2f%%" % (k, tot[k] / 1000.0,
                                                  100 * tot[k] / T))
        peak = max(float(r["peak_rss_mb"]) for r in rs)
        avail = min(float(r["available_mb"]) for r in rs)
        mf = [int(r["major_faults"]) for r in rs]
        sw = [int(r["swapins"]) for r in rs]
        print("   memory: peak RSS %.0f MB, min available %.0f MB, "
              "major faults %d->%d, swapins %d->%d" %
              (peak, avail, mf[0], mf[-1], sw[0], sw[-1]))
        print()


if __name__ == "__main__":
    main(sys.argv[1], "--rows" in sys.argv[2:])

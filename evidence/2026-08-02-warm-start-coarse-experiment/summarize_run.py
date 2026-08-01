#!/usr/bin/env python3
"""Summarize one instrumented CLI run for the warm-start-coarse experiment.

Usage:  summarize_run.py <out_dir> [<out_dir> ...]

Reads each run directory's iterations.csv + run_info.json + design.bin and
prints the four things the task's bars ask for, per rung:

  * ITERATIONS and WALL, both, always (AC2) — from PR 273's per-phase columns.
  * STAGNATING iterations and the wall spent in them (AC1). An iteration is
    STAGNATING when the multigrid V-cycle did not carry it (cg_multigrid == 0).
    `hier_built == 0` additionally means the 127 latch had already fired, so no
    hierarchy was even attempted; both counts are printed because they are
    different facts.
  * The iteration at which COMPLIANCE SETTLES (AC1) — the first iteration after
    which every later compliance in that rung stays within SETTLE_TOL (relative)
    of the rung's final compliance. This is a definition, not a fit; it is
    printed with the tolerance so it can be re-derived.
  * The coarse pre-solve's OWN iterations and wall (AC3), as a SEPARATE line,
    never folded into a rung total.

Pure reader. It changes nothing and asserts nothing.
"""
import csv
import json
import os
import struct
import sys
import collections

SETTLE_TOL = 0.10  # 10% relative band around the rung's final compliance


def settle_iteration(compliances, tol=SETTLE_TOL):
    """First 1-based iteration from which the rung stays within `tol` of final.

    Returns (iteration, final_compliance). A rung whose compliance never leaves
    the band settles at 1. A rung of length 1 settles at 1 by definition.
    """
    if not compliances:
        return (0, float("nan"))
    final = compliances[-1]
    if final == 0.0 or final != final:
        return (len(compliances), final)
    settled = len(compliances)
    for i in range(len(compliances) - 1, -1, -1):
        if abs(compliances[i] - final) / abs(final) <= tol:
            settled = i + 1
        else:
            break
    return (settled, final)


def read_design(path):
    """Read design.bin -> (dims, [StoredDesign...]) using the documented layout."""
    with open(path, "rb") as fh:
        blob = fh.read()
    # header: magic(8) version(u8) pad? — parse defensively from the tail-most
    # consistent interpretation instead of guessing: locate by density_count.
    return blob


def summarize(out_dir):
    csv_path = os.path.join(out_dir, "iterations.csv")
    info_path = os.path.join(out_dir, "run_info.json")
    if not os.path.exists(csv_path):
        print("%s: no iterations.csv" % out_dir)
        return
    rows = list(csv.DictReader(open(csv_path)))
    info = json.load(open(info_path)) if os.path.exists(info_path) else {}

    print("=" * 78)
    print("RUN %s" % out_dir)
    print("  posture: warm_start_coarse=%s  warm_start_inherit=%s  "
          "geneo=%s  mg_mode=%s  mg_levels=%s" %
          (info.get("warm_start_coarse"), info.get("warm_start_inherit"),
           info.get("geneo_twolevel"), info.get("mg_mode"),
           info.get("mg_levels")))
    # AC3 — the pre-solve's own cost, on its own line, first, so it can never be
    # read as part of a rung total.
    print("  PRE-SOLVE (res/2 cascade, charged separately, AC3): "
          "%s iterations, %.3f s" %
          (info.get("warm_start_coarse_iterations", 0),
           float(info.get("warm_start_coarse_ms", 0.0)) / 1000.0))

    by_rung = collections.OrderedDict()
    for r in rows:
        by_rung.setdefault(r["rung"], []).append(r)

    grand = collections.defaultdict(float)
    grand_iters = 0
    grand_stag = 0
    for rung, rs in by_rung.items():
        wall = sum(float(r["total_ms"]) + float(r["tail_prev_ms"]) for r in rs)
        stag = [r for r in rs if r["cg_multigrid"] == "0"]
        latched = [r for r in rs if r["hier_built"] == "0"]
        stag_wall = sum(float(r["total_ms"]) + float(r["tail_prev_ms"])
                        for r in stag)
        comps = [float(r["compliance"]) for r in rs]
        s_it, final_c = settle_iteration(comps)
        geneo = sum(float(r["geneo_setup_ms"]) + float(r["geneo_apply_ms"])
                    for r in rs)
        print("  rung %s: %3d iters, %8.1f s wall | STAGNATING %2d iters "
              "(%.1f s = %5.1f%% of rung) | latched %2d | GenEO %.1f s | "
              "compliance settles @ iter %d (+-%.0f%%), final %.6g" %
              (rung, len(rs), wall / 1000.0, len(stag), stag_wall / 1000.0,
               100.0 * stag_wall / wall if wall else 0.0, len(latched),
               geneo / 1000.0, s_it, 100 * SETTLE_TOL, final_c))
        grand["wall"] += wall
        grand["stag_wall"] += stag_wall
        grand["geneo"] += geneo
        grand_iters += len(rs)
        grand_stag += len(stag)

    pre_ms = float(info.get("warm_start_coarse_ms", 0.0))
    pre_it = int(info.get("warm_start_coarse_iterations", 0))
    print("  ---- TOTALS ----")
    print("  fine grid      : %4d iters, %8.1f s  (stagnating %d iters, "
          "%.1f s = %.1f%%)" %
          (grand_iters, grand["wall"] / 1000.0, grand_stag,
           grand["stag_wall"] / 1000.0,
           100.0 * grand["stag_wall"] / grand["wall"] if grand["wall"] else 0))
    print("  pre-solve      : %4d iters, %8.1f s   <-- AC3, charged" %
          (pre_it, pre_ms / 1000.0))
    print("  CHARGED TOTAL  : %4d iters, %8.1f s" %
          (grand_iters + pre_it, (grand["wall"] + pre_ms) / 1000.0))


if __name__ == "__main__":
    for d in sys.argv[1:]:
        summarize(d)

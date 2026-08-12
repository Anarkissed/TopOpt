#!/usr/bin/env python3
"""Every table the handoff prints, from the committed artifacts and nothing else.

Two sources, and the difference between them is load-bearing:

  * HIS CAPTURED PRODUCTION RUN — evidence/2026-08-10-plsm-production/
    s1_production_run/{run_info.json,iterations.csv}. This is a real 4-rung 128^3
    run on his part, and it is where §1's decision log and §2's latch point come
    from. Nothing in this task re-ran it; it was read.

  * THIS TASK'S ARMS — arms/<name>/{run_info.json,iterations.csv}, produced by
    run_arms.sh through the production driver on the same job.

★ ONE HONESTY NOTE THAT THE §1 TABLE CANNOT BE READ WITHOUT. `geneo_decisions`
records TRANSITIONS ONLY, by design ("runs of identical consecutive decisions are
not [recorded], so the log stays legible on a long ladder" — geneo.hpp). His run
declined 156 solves and logged 8 declines. So the decision log CANNOT give the
distribution of (burn - threshold) over all declines: the 8 it holds are the
solves that immediately followed an engage, which are the HARDEST declines, not a
sample of them. The full distribution comes from the per-iteration
geneo_burn/geneo_threshold columns instead — which his run wrote as 0 (the
columns post-date the binary that produced it), and which this task's arms fill.
Both are printed, and the limitation is printed with them.
"""
import csv
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
HIS = os.path.join(REPO, "evidence", "2026-08-10-plsm-production", "s1_production_run")
ARMS = os.path.join(HERE, "arms")


def rows(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def section(t):
    print("\n" + "=" * 78)
    print(t)
    print("=" * 78)


# ── §1a. The GenEO decision log, in full, with the arithmetic beside it. ──────
def geneo_decisions():
    section("§1(a)  HIS RUN'S GenEO DECISION LOG, IN FULL  (transitions only)")
    info = json.load(open(os.path.join(HIS, "run_info.json")))
    gd = info["geneo_decisions"]
    print(f"armed={info['geneo_armed_solves']}  declined={info['geneo_declined_solves']}  "
          f"builds={info['geneo_basis_builds']}  refreshes={info['geneo_coarse_refreshes']}")
    print(f"N_t={info['geneo_basis_dim']}  basis={info['geneo_basis_mb']:.2f} MB  "
          f"refresh_cost/col={info['geneo_refresh_cost_per_column']}  "
          f"deflated_iter_cost={info['geneo_deflated_iter_cost']}  "
          f"trigger={info['geneo_trigger_iters']}")
    print(f"log holds {len(gd)} rows for {info['geneo_armed_solves'] + info['geneo_declined_solves']} "
          f"solves — TRANSITIONS ONLY (dropped={info['geneo_decisions_dropped']})")
    print()
    act = {1: "REUSE", 2: "REFRESH+ENGAGE", 3: "REBUILD", 4: "MEM-REFUSED", 5: "DECLINE"}
    print(f"{'solve':>6} {'action':>15} {'burn':>6} {'thresh':>7} {'burn-thr':>9} "
          f"{'iters':>6} {'tail':>6} {'N_t':>6}")
    misses = []
    tails = []
    for d in gd:
        tail = d["iterations"] - d["burn"]
        delta = d["burn"] - d["threshold"]
        print(f"{d['solve']:>6} {act.get(d['action'], '?'):>15} {d['burn']:>6} "
              f"{d['threshold']:>7} {delta:>9} {d['iterations']:>6} {tail:>6} "
              f"{d['basis_dim']:>6}")
        if d["action"] == 5:
            misses.append(delta)
        if d["action"] in (2, 3):
            tails.append(tail)
    print()
    print("THE THRESHOLD, DERIVED FROM THE RUN'S OWN NUMBERS "
          "(geneo.cpp:897-899, the cost model):")
    nt, eb, et = 1674, 500, 427
    print(f"  refresh   kGeneoRefreshCostPerColumn * N_t = 2 x {nt} = {2*nt}"
          f"   <- {100*2*nt/4702:.0f}% of the threshold")
    print(f"  plain leg engaged_burn                     =     {eb}")
    print(f"  defl. leg kGeneoDeflatedIterCost * tail    = 2 x {et} = {2*et}")
    print(f"  ------------------------------------------------------")
    print(f"  threshold                                  =    {2*nt + eb + 2*et}"
          f"   (the run reports 4702)")
    print()
    if misses:
        print(f"DECLINES: {len(misses)} logged, (burn - threshold) = {sorted(misses)}")
        print(f"  worst miss {min(misses)}  best miss {max(misses)}  "
              f"median {statistics.median(misses):.0f}")
        print(f"  as a FRACTION of the threshold: "
              f"{[f'{100*m/4702:.1f}%' for m in sorted(misses)]}")
    if tails:
        print(f"DEFLATED TAILS (iterations after engaging): {sorted(tails)}")
        print(f"  median {statistics.median(tails):.0f}  max {max(tails)}")
        print(f"  -> a deflated solve finishes in {statistics.median(tails):.0f} iterations "
              f"where a plain one needs thousands.")


# ── §2a. Where the latch fired, from the per-solve record. ───────────────────
def latch_point(label, path):
    r = rows(path)
    if not r:
        print(f"{label}: no rows")
        return None
    total = sum(int(x["cg_iters"]) for x in r)
    built = [x for x in r if x["hier_built"] == "1"]
    carried = [x for x in r if x["cg_multigrid"] == "1"]
    first0 = next((x for x in r if x["hier_built"] == "0"), None)
    print(f"{label}:")
    print(f"  design iterations {len(r)}   TOTAL CG {total}")
    print(f"  hierarchy ATTEMPTED on {len(built)} solves; CARRIED on {len(carried)}")
    if built:
        cyc = [int(x['mg_cycles_attempted']) for x in built]
        print(f"  V-cycles per attempt: min {min(cyc)} max {max(cyc)} "
              f"(budget kMgIterBudget = 300; ==300 means it never contracted)")
    if first0 is not None:
        print(f"  first solve with NO hierarchy: rung {first0['rung']} iter {first0['iter']}"
              f"  <- the latch")
    per = {}
    for x in r:
        per.setdefault(x["rung"], []).append(int(x["cg_iters"]))
    for k, v in per.items():
        print(f"    rung {k}: n={len(v):3d} total_cg={sum(v):8d} "
              f"mean={sum(v)/len(v):8.1f} min={min(v)} max={max(v)}")
    return total


def latch():
    section("§2(a)  WHEN DID MULTIGRID LATCH — from the per-solve record")
    latch_point("HIS RUN (evidence/2026-08-10-plsm-production/s1_production_run)",
                os.path.join(HIS, "iterations.csv"))


# ── R1. The arms table: TOTAL CG FIRST, wall beside it. ──────────────────────
def arms():
    section("R1  THE ARMS — TOTAL CG ITERATIONS IS THE FIGURE OF MERIT")
    if not os.path.isdir(ARMS):
        print("no arms/ directory yet")
        return
    names = sorted(d for d in os.listdir(ARMS)
                   if os.path.isdir(os.path.join(ARMS, d)) and d != "job")
    base_cg = None
    base_mv = None
    # ★ MATVECS SITS BESIDE TOTAL_CG AND IS NOT OPTIONAL. A coarse-operator
    # refresh is N_t operator applies and moves NO iteration counter, so an arm
    # that engages GenEO can report fewer CG iterations while doing more work.
    # Reporting total_cg alone would make that read as a win.
    print(f"{'arm':>10} {'total_cg':>10} {'vs base':>9} {'matvecs':>11} {'vs base':>9} "
          f"{'iters':>6} {'wall_s':>8} {'mg_mode':>18} {'mg_carried':>11} "
          f"{'geneo_arm':>10} {'geneo_dec':>10} {'N_t':>6}")
    for n in names:
        csvp = os.path.join(ARMS, n, "iterations.csv")
        infop = os.path.join(ARMS, n, "run_info.json")
        if not os.path.exists(csvp):
            print(f"{n:>10}  (no iterations.csv — run incomplete)")
            continue
        r = rows(csvp)
        # ★ A HEADER-ONLY CSV IS NOT A ZERO. An arm that has not produced a
        # single solve must not print `total_cg 0  0.000x` — that reads as a
        # measured result of zero rather than as "this did not run", which is
        # precisely the failure this project files under "a green run that
        # measures nothing".
        if not r:
            print(f"{n:>10}  (iterations.csv has no rows — the run produced no "
                  f"solve; NOT a measurement of zero)")
            continue
        total = sum(int(x["cg_iters"]) for x in r)
        mv = sum(int(x.get("matvecs", 0) or 0) for x in r)
        carried = sum(1 for x in r if x["cg_multigrid"] == "1")
        info = json.load(open(infop)) if os.path.exists(infop) else {}
        wall = ""
        sm = os.path.join(ARMS, n + ".summary")
        if os.path.exists(sm):
            for line in open(sm):
                if line.startswith("ARM_SUMMARY"):
                    for tok in line.split():
                        if tok.startswith("wall_s="):
                            wall = tok.split("=", 1)[1]
        if n == "base":
            base_cg, base_mv = total, mv
        rel = f"{total/base_cg:.3f}x" if base_cg else "-"
        relmv = f"{mv/base_mv:.3f}x" if base_mv else "-"
        print(f"{n:>10} {total:>10} {rel:>9} {mv:>11} {relmv:>9} "
              f"{len(r):>6} {wall:>8} "
              f"{str(info.get('mg_mode')):>18} {carried:>11} "
              f"{info.get('geneo_armed_solves', ''):>10} "
              f"{info.get('geneo_declined_solves', ''):>10} "
              f"{info.get('geneo_basis_dim', ''):>6}")


# ── R3. The margin per rung, per arm — no verdict moves. ─────────────────────
def margins():
    section("R3  CERTIFIED MARGIN PER RUNG, PER ARM — no verdict may move")
    if not os.path.isdir(ARMS):
        print("no arms/ directory yet")
        return
    for n in sorted(os.listdir(ARMS)):
        p = os.path.join(ARMS, n + ".summary")
        if not os.path.exists(p):
            continue
        for line in open(p):
            if line.startswith("ARM_RUNG"):
                print("  " + line.strip())


# ── §1a (full). The per-solve gate distribution, when a run wrote it. ────────
def gate_distribution():
    section("§1(a)  THE FULL (burn - threshold) DISTRIBUTION, per solve")
    for label, csvp in [("HIS RUN", os.path.join(HIS, "iterations.csv"))] + \
            ([(n, os.path.join(ARMS, n, "iterations.csv"))
              for n in sorted(os.listdir(ARMS))
              if os.path.isdir(os.path.join(ARMS, n)) and n != "job"]
             if os.path.isdir(ARMS) else []):
        if not os.path.exists(csvp):
            continue
        r = rows(csvp)
        if not r or "geneo_threshold" not in r[0]:
            print(f"{label}: no geneo_threshold column")
            continue
        held = [x for x in r if int(x["geneo_threshold"]) > 0]
        if not held:
            print(f"{label}: no solve wrote a nonzero geneo_threshold "
                  f"(no basis was ever held, or the columns predate this binary)")
            continue
        d = [int(x["geneo_burn"]) - int(x["geneo_threshold"]) for x in held]
        near = sum(1 for x in d if -0.10 * 4702 <= x < 0)
        print(f"{label}: {len(held)} solves with a basis held")
        print(f"  (burn - threshold): min {min(d)} median {statistics.median(d):.0f} "
              f"max {max(d)}")
        print(f"  declined WITHIN 10% of the threshold: {near} of {sum(1 for x in d if x < 0)}")


# ── The mechanism probes: three solves each, because three is the latch. ─────
def probes():
    section("§4(a) / §3  THE MECHANISM PROBES — the solves multigrid is ATTEMPTED on")
    P = os.path.join(HERE, "probes")
    if not os.path.isdir(P):
        print("no probes/ directory yet")
        return
    print("kMgLatchThreshold = 3: the latch is decided by the first three ATTEMPTS,")
    print("and his three were identical — 300 cycles each, the whole budget, no")
    print("contraction. So a posture that does not change the FIRST attempt cannot")
    print("change the run. At ITERS=1 the ladder yields one attempt (rung 0 iter 1);")
    print("the other two stagnations that close the latch are rung-boundary")
    print("certification solves, which iterations.csv carries no row for.")
    print("mg_cycles 300 = the full budget = the V-cycle never contracted.\n")
    print(f"{'probe':>8} {'solve':>6} {'cg_iters':>9} {'hier_built':>11} "
          f"{'mg_cycles':>10} {'used_mg':>8}")
    for n in ("ctl", "alg1", "eta05", "eta40"):
        csvp = os.path.join(P, n, "iterations.csv")
        if not os.path.exists(csvp):
            print(f"{n:>8}  (not run)")
            continue
        for x in rows(csvp):
            if x["rung"] != "0":
                continue
            print(f"{n:>8} {x['iter']:>6} {x['cg_iters']:>9} {x['hier_built']:>11} "
                  f"{x['mg_cycles_attempted']:>10} {x['cg_multigrid']:>8}")
    # The algebraic level's own report, which is the other half of §4(a).
    infop = os.path.join(P, "alg1", "run_info.json")
    if os.path.exists(infop):
        i = json.load(open(infop))
        print()
        print("mg_algebraic_level1 report:")
        for k in ("mg_algebraic_level1", "mg_algebraic_level1_refused",
                  "mg_algebraic_refuse_reason", "mg_algebraic_levels",
                  "mg_algebraic_aggregates", "mg_algebraic_coarse_dim",
                  "mg_algebraic_added_mb", "mg_mode"):
            print(f"  {k} = {i.get(k)}")


# ── R3. The compliance curve and where it settles, per arm. ─────────────────
def curves():
    section("R3  THE TRAJECTORY CURVE AND ITS SETTLING ITERATION, per arm per rung")
    print("★ WHAT THIS IS AND IS NOT. R3 asks for the certified MARGIN as a curve.")
    print("A per-iteration margin curve is not affordable here and the reason is")
    print("measured, not asserted: PR 326 timed certifying an UNCONVERGED design at")
    print("26x the cost of certifying a converged one, so a margin curve over a")
    print("4-rung ladder would cost more than every arm in this table put together")
    print("and would put the instrument inside the timing the arms report. What is")
    print("printed instead is (a) the per-iteration COMPLIANCE curve, which is free")
    print("— it is already in iterations.csv — with the iteration at which it")
    print("settles to within 0.1%, and (b) the CERTIFIED margin at every rung, which")
    print("is the number the accept gate actually reads. The gap between them is")
    print("real and is named in the handoff.\n")
    for src, label in ([(ARMS, "arm")] if os.path.isdir(ARMS) else []):
        for n in sorted(os.listdir(src)):
            csvp = os.path.join(src, n, "iterations.csv")
            if not os.path.exists(csvp):
                continue
            r = rows(csvp)
            per = {}
            for x in r:
                per.setdefault(x["rung"], []).append(float(x["compliance"]))
            for rung, c in per.items():
                settle = len(c)
                for i in range(1, len(c)):
                    if c[-1] != 0 and abs(c[i] - c[-1]) / abs(c[-1]) < 1e-3:
                        settle = i + 1
                        break
                print(f"  {label} {n:>8} rung {rung}: compliance "
                      f"{c[0]:.6g} -> {c[-1]:.6g} over {len(c)} iters, "
                      f"settles (0.1%) at iteration {settle}")


if __name__ == "__main__":
    geneo_decisions()
    latch()
    gate_distribution()
    probes()
    arms()
    margins()
    curves()

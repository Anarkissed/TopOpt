#!/usr/bin/env python3
"""Every table the tiling-sweep handoff prints, from this directory's artifacts.

Two sources:

  * HIS CAPTURED PRODUCTION RUN — evidence/2026-08-10-plsm-production/
    s1_production_run/. A real 4-rung 128^3 run on his part at the SHIPPED
    tiling. Read, never re-run. It is the row the sweep is measured against.

  * THIS TASK'S SWEEP — nt_triage/core<N>.txt (N_t per tiling, one solve each)
    and arms/<name>/ (the full ladders that carry TOTAL CG ITERATIONS).

★ TOTAL CG ITERATIONS IS THE FIGURE OF MERIT, NOT THE ARMED COUNT (§1c). A
smaller basis that engages on every solve and deflates badly is WORSE than a
large one that engages rarely. The tables below therefore put total CG first and
print the armed count beside it as a DIAGNOSTIC, with that sentence attached, so
nobody reads engagement as success.

★ ONE HONESTY NOTE, INHERITED FROM PR 329 AND STILL TRUE. `geneo_decisions`
records TRANSITIONS ONLY, by design ("runs of identical consecutive decisions are
not [recorded], so the log stays legible on a long ladder" — geneo.hpp). His run
declined 156 solves and logged 8 declines, and those 8 are the solves that
immediately FOLLOWED an engage — the hardest declines, not a sample. So the
(burn - threshold) DISTRIBUTION in §1(d) is taken from the per-iteration
`geneo_burn`/`geneo_threshold` CSV columns, never from the decision log. His run
wrote those columns as 0 (they post-date the binary that produced it); this
task's arms fill them. Both facts are printed rather than worked around.
"""
import csv
import json
import math
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
HIS = os.path.join(REPO, "evidence", "2026-08-10-plsm-production", "s1_production_run")
ARMS = os.path.join(HERE, "arms")
TRIAGE = os.path.join(HERE, "nt_triage")

# His grid, from the captured run's own preflight line and confirmed by
# solved_grid_dofs = 1473696 = 3 * 129 * 32 * 119.
NX, NY, NZ = 128, 31, 118
# His run's two measured legs, held fixed so the ONLY thing moving across the
# sweep's implied thresholds is N_t.
HIS_BURN, HIS_TAIL = 500, 427
HIS_THRESHOLD = 4702


def section(t):
    print("\n" + "=" * 78)
    print(t)
    print("=" * 78)


def rows(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


# ── §1(a). What the tiling MEANS in voxels, per axis. ────────────────────────
def tiling_geometry():
    section("§1(a)  WHAT EACH TILING MEANS IN VOXELS ON HIS 128 x 31 x 118 GRID")
    print("PER-AXIS, NEVER A MINIMUM. `tile_cores` (core/src/fea/geneo.cpp:167)")
    print("steps x, y and z independently, so the subdomain count is")
    print("ceil(nx/c)*ceil(ny/c)*ceil(nz/c) and NOT (n/c)^3 for any single n.")
    print("His part is a 4.1:1 slab (128 long, 31 thin); a tiling keyed to the")
    print("thin axis would size every axis to 31 and multiply the subdomain count")
    print("— and N_t, and the refresh the gate is priced against — with it.")
    print("Pinned by test_geneo's R6 block against a 24:1 synthetic slab.\n")
    print(f"{'core':>5} {'tiles x':>8} {'tiles y':>8} {'tiles z':>8} {'subdomains':>11}"
          f"  {'last-tile x,y,z':>16}")
    for c in (8, 12, 16, 24, 32):
        tx, ty, tz = math.ceil(NX / c), math.ceil(NY / c), math.ceil(NZ / c)
        lx, ly, lz = NX - (tx - 1) * c, NY - (ty - 1) * c, NZ - (tz - 1) * c
        note = "  <- y collapses to ONE tile" if ty == 1 else ""
        print(f"{c:>5} {tx:>8} {ty:>8} {tz:>8} {tx*ty*tz:>11}"
              f"  {lx:>4},{ly:>3},{lz:>3}{note}")
    print("\n32 is shown but is NOT a sweep point: with y at a single tile it")
    print("confounds 'coarser tiling' with 'no tiling on one axis'. 24 is the")
    print("last point that still tiles every axis, which is why the sweep stops")
    print("there.")


# ── §1(b). N_t per tiling, from the one-solve triage. ────────────────────────
def nt_table():
    section("§1(b)  N_t PER TILING — the one-solve triage")
    print("N_t is decided on the FIRST solve: the basis is built once per")
    print("structure and its dimension is a property of that build. So one")
    print("design iteration per rung answers this, and does it deterministically")
    print("— N_t is a COUNT and a contended host cannot change it.\n")
    if not os.path.isdir(TRIAGE):
        print("no nt_triage/ directory yet")
        return {}
    out = {}
    print("★ TWO N_t COLUMNS, AND THE DIFFERENCE BETWEEN THEM IS A FINDING.")
    print("`N_t first` is the dimension of the basis built on the run's FIRST")
    print("stagnating solve. `N_t final` is what the run was still holding at the")
    print("end. They differ when the basis DEGRADED and the scheduled rebuild")
    print("returned a different dimension — which is what happened at core=12")
    print("(718 -> 1123) and did not happen at core=8 (built once, never rebuilt).")
    print("Production experiences the FINAL number for most of a run, so the")
    print("headline fall is 1.5x and not the 2.35x the first build suggests.\n")
    # first-build N_t per tiling, read from the per-solve CSV rather than
    # run_info (which only ever reports the currently-held basis).
    first = {}
    for n in sorted(os.listdir(TRIAGE)) if os.path.isdir(TRIAGE) else []:
        p = os.path.join(TRIAGE, n, "iterations.csv")
        if n.startswith("run_core") and os.path.exists(p):
            b = [x for x in rows(p) if int(x["geneo_action"]) == 3]
            if b:
                first[int(n.replace("run_core", ""))] = int(b[0]["geneo_dim"])
    print(f"{'core':>5} {'subdomains':>11} {'N_t first':>10} {'N_t final':>10}"
          f" {'modes/sub':>10} {'basis MB':>9} {'refresh 2*N_t':>14} {'implied thresh':>15}")
    # ★ DRIVEN OFF THE COLLECTED PER-SOLVE CSVs, not off the parsed core<N>.txt.
    # The .txt is written by run_nt_triage.sh only AFTER a point's process fully
    # exits, and on a contended host a finished 4-rung ladder can sit in STL
    # export for many minutes afterwards. Keying the table on the .txt therefore
    # DROPS a point whose measurement is complete — which is how core=16's row
    # went missing from an earlier version of this table while its four rungs sat
    # collected in run_core16/. The CSV is the measurement; the .txt is a
    # convenience. Values only available from run_info (basis MB, the final
    # rebuilt N_t) are read from the .txt when it exists and printed as "-" when
    # it does not, rather than being silently omitted or guessed.
    for d in sorted(os.listdir(TRIAGE),
                    key=lambda s: int(''.join(filter(str.isdigit, s)) or 0)):
        if not (d.startswith("run_core")
                and os.path.exists(os.path.join(TRIAGE, d, "iterations.csv"))):
            continue
        c = int(d.replace("run_core", ""))
        if c not in first:
            continue
        kv = {}
        txtp = os.path.join(TRIAGE, f"core{c}.txt")
        if os.path.exists(txtp):
            txt = open(txtp).read().strip()
            if "NOT MEASURED" in txt:
                print(f"  {txt}")
                continue
            kv = dict(t.split("=", 1) for t in txt.split() if "=" in t)
        tx, ty, tz = math.ceil(NX / c), math.ceil(NY / c), math.ceil(NZ / c)
        subs = tx * ty * tz
        # `N_t final` needs run_info; without it, report the first build and say so.
        nt = int(kv["N_t"]) if "N_t" in kv else first[c]
        mb = float(kv["basis_MB"]) if "basis_MB" in kv else float("nan")
        thr = 2 * nt + HIS_BURN + 2 * HIS_TAIL
        out[c] = dict(nt=nt, subs=subs, mb=mb, thr=thr)
        ntf = str(nt) if "N_t" in kv else "-"
        mbs = f"{mb:.2f}" if mb == mb else "-"
        print(f"{c:>5} {subs:>11} {first[c]:>10} {ntf:>10} {nt/subs:>10.2f} {mbs:>9}"
              f" {2*nt:>14} {thr:>15}")
    if 8 in out:
        base = out[8]["nt"]
        print(f"\nAgainst the shipped 8^3 (N_t = {base}):")
        for c in sorted(out):
            o = out[c]
            print(f"  core={c:<3} N_t {o['nt']:>5}  = {o['nt']/base:5.2f}x the shipped"
                  f"   subdomains {o['subs']/out[8]['subs']:5.2f}x")
        print("\nIf N_t fell exactly with the subdomain count the two ratios would")
        print("match. Where N_t falls SLOWER, each larger subdomain is carrying more")
        print("modes — block_m = 20 caps it at 20 per subdomain, and that cap is the")
        print("mechanism that would flatten the curve.")
    print(f"\nTHE BAR THE THRESHOLD MUST CLEAR: his 160 stagnating solves cost a")
    print(f"MEDIAN of 2,717 plain CG iterations (min 927, max 5,091), against his")
    print(f"observed threshold of {HIS_THRESHOLD}. ★ NOT ~4,400 — that is the median of")
    print("the 8 declines in his DECISION LOG, which records transitions only and")
    print("so holds the hardest 5 % of the 156 declines rather than a sample.")
    print("")
    print("A tiling whose implied threshold drops under ~2,700 is one where the")
    print("gate starts engaging routinely. ★ THAT IS A NECESSARY CONDITION AND NOT")
    print("A SUFFICIENT ONE, and on this part it is not even a desirable one on its")
    print("own: cost_model.py shows the gate ENGAGING MORE while the run gets")
    print("SLOWER, because engagements near the threshold lose. Read cost_model.txt")
    print("and the §2(b) trade table before drawing anything from this column.")
    return out


# ── §1(c). THE FIGURE OF MERIT. ─────────────────────────────────────────────
def arms_table():
    section("§1(c)  TOTAL CG ITERATIONS PER TILING — ★ THE FIGURE OF MERIT")
    print("★ TOTAL CG ITERATIONS, NOT THE ARMED COUNT. A smaller basis that")
    print("engages on every solve and deflates badly is WORSE than a large one")
    print("that engages rarely. The armed/declined columns are a DIAGNOSTIC of")
    print("what the gate did; the total-CG column is the result. Read them in")
    print("that order.\n")
    print("R1: iteration counts are the EVIDENCE (deterministic, contention-immune);")
    print("wall is CONTEXT and on this host it was measured under load — see")
    print("host_load.txt. Every wall figure here is from a Release build")
    print("(CMAKE_BUILD_TYPE=Release, recorded in build_type.txt).\n")
    print("★ ONE CONFOUND IN THIS COLUMN, NAMED RATHER THAN BURIED, AND IT IS")
    print("LARGER THAN IT LOOKS. GenEO is exact to the SOLVER TOLERANCE, not to")
    print("the last bit, so two tilings finish rung 0 with fields agreeing to")
    print("~1e-8 and hand slightly different designs to the next rung.")
    print("")
    print("How small that design difference is, and how big its effect: at core=8")
    print("and core=12 the certified margins agree at EVERY rung to all six")
    print("printed digits (1751.28 / 1383.13 / 514.952) — yet rung 1 cost 1,121 CG")
    print("at core=8 and 1,372 at core=12, a 22 % swing. A perturbation too small")
    print("to move the margin in the 6th digit moves the iteration count by a")
    print("fifth, because CG counts are sensitive to where a residual lands")
    print("relative to a fixed tolerance.")
    print("")
    print("CONSEQUENCE: at --iters 1 a total-CG difference below roughly 20 %")
    print("between tilings CANNOT be attributed to the lever. This is why the")
    print("handoff leans on the cost-model decomposition (N_t, tail, threshold —")
    print("all trajectory-independent, all read per solve) and treats total CG as")
    print("a confirming measurement rather than the sole one.\n")
    if not os.path.isdir(ARMS):
        print("no arms/ directory yet")
        return
    names = [n for n in sorted(os.listdir(ARMS))
             if os.path.isdir(os.path.join(ARMS, n)) and n != "job"]
    if not names:
        print("no arms have completed yet")
        return
    print(f"{'arm':>10} {'TOTAL CG':>10} {'design it':>10} {'N_t':>6} {'armed':>6}"
          f" {'declin':>7} {'builds':>7} {'basis MB':>9} {'build s':>8} {'wall s':>9}")
    base_cg = None
    for n in names:
        info = load_json(os.path.join(ARMS, n, "run_info.json"))
        summ = os.path.join(ARMS, n + ".summary")
        cg = None
        kv = {}
        if os.path.exists(summ):
            for line in open(summ):
                if line.startswith("ARM_SUMMARY"):
                    for tok in line.split():
                        if "=" in tok:
                            k, v = tok.split("=", 1)
                            kv[k] = v
        if "total_cg" in kv:
            cg = int(kv["total_cg"])
        if cg is None:
            print(f"{n:>10}  INCOMPLETE — no ARM_SUMMARY; this row is the ABSENCE of a"
                  f" measurement, not a zero")
            continue
        if n == "base" or (base_cg is None and n.endswith("8")):
            base_cg = cg
        print(f"{n:>10} {cg:>10} {kv.get('design_iters',''):>10}"
              f" {kv.get('geneo_dim',''):>6} {kv.get('geneo_armed',''):>6}"
              f" {kv.get('geneo_declined',''):>7} {kv.get('geneo_builds',''):>7}"
              f" {kv.get('geneo_basis_mb',''):>9} {kv.get('geneo_build_s',''):>8}"
              f" {kv.get('wall_s',''):>9}")
    if base_cg:
        print(f"\nAgainst the shipped tiling's total CG ({base_cg}):")
        for n in names:
            summ = os.path.join(ARMS, n + ".summary")
            if not os.path.exists(summ):
                continue
            for line in open(summ):
                if line.startswith("ARM_SUMMARY"):
                    kv = dict(t.split("=", 1) for t in line.split() if "=" in t)
                    cg = int(kv["total_cg"])
                    d = 100.0 * (cg - base_cg) / base_cg
                    verdict = "BETTER" if d < 0 else ("same" if abs(d) < 0.5 else "WORSE")
                    print(f"  {n:<10} {cg:>10}  {d:+6.1f}%  {verdict}")


# ── §1(d). The gate's own distribution, per tiling. ─────────────────────────
def gate_distribution():
    section("§1(d)  THE (burn - threshold) DISTRIBUTION PER TILING")
    print("This is what says whether a tiling moved the gate from 'misses by 7%'")
    print("to 'clears comfortably' or merely to 'misses by 4%'. A NEGATIVE value")
    print("is a solve that finished plain before the armed alternative would have")
    print("paid for itself — a DECLINE, and a correct one.\n")
    print("★ FROM THE PER-ITERATION CSV COLUMNS, NOT THE DECISION LOG. The log")
    print("records transitions only, so its declines are the hardest ones and not")
    print("a sample of the distribution (geneo.hpp, kGeneoDecisionLogCap).\n")
    srcs = [("HIS RUN (shipped 8^3)", os.path.join(HIS, "iterations.csv"))]
    # ★ The TRIAGE runs are included, and they are labelled `triage core=N` so
    # nobody reads them as the arms. They ran at one design iteration per rung,
    # which makes their solves EASY (rung 1 at core=8 burned 1,121 plain against
    # a threshold of 4,816) — so an all-decline result there is a property of the
    # fixture depth, not of the tiling. Printed because they carry the only
    # per-tiling gate columns that exist if the arms do not finish; read with
    # that caveat and never as the engagement answer.
    if os.path.isdir(TRIAGE):
        for n in sorted(os.listdir(TRIAGE)):
            p = os.path.join(TRIAGE, n, "iterations.csv")
            if n.startswith("run_core") and os.path.exists(p):
                srcs.append((f"triage {n.replace('run_', '')} (--iters 1, EASY solves)", p))
    if os.path.isdir(ARMS):
        srcs += [(n, os.path.join(ARMS, n, "iterations.csv"))
                 for n in sorted(os.listdir(ARMS))
                 if os.path.isdir(os.path.join(ARMS, n)) and n != "job"]
    for label, csvp in srcs:
        if not os.path.exists(csvp):
            continue
        r = rows(csvp)
        if not r or "geneo_threshold" not in r[0]:
            print(f"{label}: no geneo_threshold column in this CSV")
            continue
        held = [x for x in r if int(x["geneo_threshold"]) > 0]
        if not held:
            print(f"{label}: no solve wrote a nonzero geneo_threshold — no basis was")
            print(f"  ever held, or these columns post-date the binary that ran it.")
            continue
        d = sorted(int(x["geneo_burn"]) - int(x["geneo_threshold"]) for x in held)
        neg = [x for x in d if x < 0]
        thr = statistics.median(int(x["geneo_threshold"]) for x in held)
        print(f"{label}: {len(held)} solves with a basis held, median threshold {thr:.0f}")
        print(f"  (burn - threshold): min {min(d)}  median {statistics.median(d):.0f}"
              f"  max {max(d)}")
        if neg:
            frac = statistics.median(neg) / thr if thr else float('nan')
            print(f"  {len(neg)} DECLINED; they missed by a median of {-statistics.median(neg):.0f}"
                  f" iterations = {abs(frac)*100:.1f}% of the threshold")
        else:
            print("  0 declined — the gate ENGAGED on every solve that held a basis")


# ── R5. No verdict moves. ───────────────────────────────────────────────────
def margins():
    section("R5  THE CERTIFIED MARGIN AT EVERY TILING — GenEO IS EXACT")
    print("Every term in the preconditioner is SPD, so the deflation changes the")
    print("CG ROUTE and never the converged field or the stopping test. A margin")
    print("that moved with the tiling would mean that claim is false, so this is")
    print("a real check and not a formality.\n")
    per = {}
    # The TRIAGE logs carry ARM_RUNG lines at full precision, one per evaluated
    # rung, so the margin curve exists per tiling even when the deeper arms have
    # not run. `arm=core=N` is parsed off the ARM_RUNG line itself rather than
    # from the filename, so a mislabelled file cannot silently retitle a column.
    srcs = []
    if os.path.isdir(TRIAGE):
        srcs += [os.path.join(TRIAGE, f) for f in sorted(os.listdir(TRIAGE))
                 if f.endswith(".log")]
    if os.path.isdir(ARMS):
        srcs += [os.path.join(ARMS, f) for f in sorted(os.listdir(ARMS))
                 if f.endswith(".summary")]
    for p in srcs:
        for line in open(p):
            if line.startswith("ARM_RUNG"):
                kv = dict(t.split("=", 1) for t in line.split() if "=" in t)
                per.setdefault(kv.get("arm", os.path.basename(p)), []).append(
                    (float(kv["vf_requested"]), float(kv["margin"]), kv["accepted"]))
    if not per:
        print("no ARM_RUNG rows yet")
        return
    arms = sorted(per)
    vfs = sorted({v for a in arms for v, _, _ in per[a]}, reverse=True)
    print(f"{'vf':>7} " + " ".join(f"{a:>16}" for a in arms))
    for vf in vfs:
        cells = []
        for a in arms:
            m = [x for x in per[a] if abs(x[0] - vf) < 1e-9]
            cells.append(f"{m[0][1]:.9g}({m[0][2]})" if m else "-")
        print(f"{vf:>7.3f} " + " ".join(f"{c:>16}" for c in cells))
    print("\n(value(accepted)) — accepted=1 is an ACCEPT verdict.")
    print("\n★ THE RIGHT BAR IS NOT BIT-IDENTITY, AND SAYING SO MATTERS.")
    print("GenEO is exact to the SOLVER TOLERANCE (1e-8), not to the last bit: it")
    print("changes the CG route, so two tilings reach the same field to 1e-8 and")
    print("then hand slightly different fields to an optimiser that can amplify")
    print("the difference over a ladder. So a margin that moves by ~1e-6 relative")
    print("is the expected behaviour of an exact method, and a margin that moves")
    print("by PERCENT is the thing that would falsify the exactness claim. Both")
    print("are reported below rather than collapsed into one pass/fail.")
    ref = arms[0]
    for a in arms[1:]:
        worst, worst_vf = 0.0, None
        flips = 0
        for x in per[a]:
            m = [y for y in per[ref] if abs(x[0] - y[0]) < 1e-9]
            if not m:
                continue
            if x[2] != m[0][2]:
                flips += 1
            denom = abs(m[0][1]) or 1.0
            rel = abs(x[1] - m[0][1]) / denom
            if rel > worst:
                worst, worst_vf = rel, x[0]
        tag = ("IDENTICAL" if worst == 0.0 else
               f"max rel move {worst:.3e} at vf={worst_vf}")
        verdict = ("consistent with exactness" if worst < 1e-3 else
                   "*** MOVED MATERIALLY — read this ***")
        print(f"  {a} vs {ref}: {tag}; verdict flips: {flips} — {verdict}")


# ── §2(b). Deflation QUALITY per tiling — the trade curve's other axis. ─────
def deflation_quality():
    section("§2(b)  DEFLATION QUALITY PER TILING — does a smaller basis deflate WORSE?")
    print("★ THIS IS THE AXIS THAT SEPARATES §2(a) FROM §2(b), and it is readable")
    print("from the triage without any extra run. On every point, rung 0's first")
    print("solve is the BUILD solve: it burns exactly kGeneoTriggerIters = 500")
    print("plain iterations, then deflates to convergence. So")
    print("")
    print("      deflated tail  =  cg_iters(rung 0, iter 1)  -  500")
    print("")
    print("is the number of DEFLATED iterations that basis needed to finish a solve")
    print("plain Jacobi could not. A coarser tiling buys a cheaper refresh (2*N_t)")
    print("and pays for it here. If the tail grows faster than N_t shrinks, the")
    print("lever is exhausted and the answer is §2(b).\n")
    if not os.path.isdir(TRIAGE):
        print("no nt_triage/ directory yet")
        return
    print(f"{'core':>5} {'N_t':>7} {'rung0 cg':>9} {'burn':>6} {'tail':>6}"
          f" {'refresh 2*N_t':>14} {'engage thresh':>14} {'all-in equiv':>13}")
    for n in sorted(os.listdir(TRIAGE)):
        p = os.path.join(TRIAGE, n, "iterations.csv")
        if not (n.startswith("run_core") and os.path.exists(p)):
            continue
        c = n.replace("run_core", "")
        r = rows(p)
        build = [x for x in r if int(x["geneo_action"]) == 3]
        if not build:
            print(f"{c:>5}   no BUILD solve (action 3) in this run — nothing to read")
            continue
        b = build[0]
        nt, cg, burn = int(b["geneo_dim"]), int(b["cg_iters"]), int(b["geneo_burn"])
        tail = cg - burn
        thr = 2 * nt + burn + 2 * tail
        # What one engaged solve costs all-in, in plain-iteration equivalents:
        # burn the threshold, then pay the refresh and the deflated tail.
        allin = thr + 2 * nt + 2 * tail
        print(f"{c:>5} {nt:>7} {cg:>9} {burn:>6} {tail:>6} {2*nt:>14} {thr:>14}"
              f" {allin:>13}")
    print("\nREAD IT AGAINST THE PLAIN ALTERNATIVE — AND AGAINST THE RIGHT ONE.")
    print("★ A CORRECTION THIS TABLE CARRIES SO NOBODY REPEATS IT. His TYPICAL")
    print("stagnating solve costs 2,717 CG (median of all 160 rows of his")
    print("iterations.csv). It does NOT cost ~4,400: that figure is the median of")
    print("the 8 declines in his DECISION LOG, and the log records transitions")
    print("only, so those 8 are the solves that immediately followed an engage —")
    print("systematically the hardest, 5 % of the 156 declines. Using 4,400 puts")
    print("the break-even at N_t = 669 when it is really near 256, i.e. it calls a")
    print("tiling a win that is not one.")
    print("")
    print("★ THE BREAK-EVEN, IN CLOSED FORM. Substituting the gate's own cost")
    print("model (geneo.hpp: refresh = 2*N_t, a deflated iteration = 2 plain):")
    print("")
    print("    all-in equiv = threshold + 2*N_t + 2*tail")
    print("                 = (2*N_t + 500 + 2*tail) + 2*N_t + 2*tail")
    print("                 = 4*N_t + 4*tail + 500")
    print("")
    print("so beating a MEDIAN 2,717-iteration plain solve needs")
    print("")
    print("    ★  N_t + tail  <  554  ★")
    print("")
    print("At the shipped 8^3 that sum is 1686 + 472 = 2158, i.e. 3.9x over.")
    print("")
    print("★ AND THIS CLOSED FORM IS THE COARSE VIEW, NOT THE ANSWER. It compares")
    print("against ONE representative solve. `cost_model.py` does the honest")
    print("version — it runs the gate's rule against ALL 160 of his measured solve")
    print("costs, one at a time, and finds a NON-MONOTONE result this one-number")
    print("form cannot show: shrinking N_t from 1686 to 718 makes the run WORSE,")
    print("because it drops the threshold into the middle of his cost distribution")
    print("and the gate starts engaging on solves that were about to finish plain.")
    print("Read cost_model.txt before quoting anything from this block.")
    print("")
    print("AND ONE FRAMING THIS TABLE DELIBERATELY DOES NOT USE. If a hot basis")
    print("could deflate from iteration 0 — no burn — the cost would be just")
    print("2*N_t + 2*N_defl, which at 8^3 is 3372 + 944 = 4316 against 5,412 for")
    print("his hardest plain solve: already a win. The SHIPPED ski-rental gate")
    print("forbids that, by design and for a measured reason (arming every solve")
    print("lost 1.25x on wall — 2026-08-02-geneo-standing-probe). So the gate")
    print("policy is itself a term in the economics, and a tiling that made N_t")
    print("small enough would reopen the standing-preconditioner question that was")
    print("closed at N_t ~ 1,686. That is a SEPARATE proposal and is not armed")
    print("here; it is flagged because the sweep is what would justify re-asking.")


def main():
    tiling_geometry()
    nt_table()
    deflation_quality()
    arms_table()
    gate_distribution()
    margins()


if __name__ == "__main__":
    main()

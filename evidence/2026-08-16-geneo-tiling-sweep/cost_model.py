#!/usr/bin/env python3
"""What each tiling would cost on HIS ACTUAL RUN — from measured inputs only.

★ WHY THIS EXISTS ALONGSIDE THE ARMS. §1(c) wants TOTAL CG ITERATIONS per
tiling. Measuring that directly at his depth means re-running a 4-rung 60-
iteration 128^3 ladder per tiling, which is many hours on a quiet box and was
not available (see host_load.txt). This computes the same quantity from
quantities that ARE measured:

  * the COST of every one of his 160 stagnating solves — his own
    `iterations.csv`, `cg_iters` column, no model in it at all;
  * `N_t` per tiling — measured by this task's triage, one solve per point;
  * the gate's cost model — read out of `geneo.hpp`, the same arithmetic the
    solver itself runs;
  * the warm deflated tail — his own decision log's 8 engaged solves at the
    shipped tiling, AND this task's own measurements at the coarser tilings
    (the triage's rung-3 solve engages once the threshold falls far enough, and
    `run_engaged_probe.sh` forces the rest).

Nothing here is fitted or extrapolated. The ONE judgement is which tail to use,
and both are reported.

★ EACH MEASURED TILING IS CHARGED ITS OWN MEASURED WARM TAIL, and hypothetical
rows are charged his 170. Borrowing one tiling's tail for another was the
tempting shortcut and it would have been wrong in BOTH directions at different
points in this sweep — the coarse tails are smaller than 170 on easy rungs and
larger on hard ones. The tail actually charged, and the number of solves it is a
median over, are printed beside every row so no rate can be read without them.

★ AND ONE MEASUREMENT ERROR THIS SCRIPT EXISTS TO AVOID, MADE AND CAUGHT HERE.
The first version of this analysis took his "typical" solve cost from the
DECISION LOG's declines and got 4,370. That is wrong by 61 %: the log records
TRANSITIONS ONLY, so its declines are the solves that immediately followed an
engage — the HARDEST ones. His true per-solve distribution, from all 160 rows of
`iterations.csv`, has a median of 2,717. Using 4,370 would have made the
break-even N_t look like 669 when it is really 256 — i.e. it would have called a
tiling a win that is not one. The biased number is not used anywhere below.
"""
import csv
import json
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
HIS = os.path.join(REPO, "evidence", "2026-08-10-plsm-production",
                   "s1_production_run", "iterations.csv")
TRIAGE = os.path.join(HERE, "nt_triage")

# His run's two build-solve legs, which the gate's threshold is computed from.
BURN0, TAIL0 = 500, 427
# His median WARM refreshed deflated tail, from the 8 engaged solves in his
# decision log (11/70/74/150/189/236/304/889).
#
# ★ AND THIS SAMPLE IS USABLE WHERE THE DECLINE SAMPLE IS NOT — the difference
# is coverage, not luck. The log records transitions only, so of his 156 DECLINED
# solves it holds 8 (5 %), and those 8 are the ones that immediately followed an
# engage, i.e. systematically the hardest. Of his 12 ARMED solves it holds ~10
# (8 refreshes + 2 builds), i.e. most of the population. So the warm tail below
# is a fair summary of the armed solves; the decline burns are not a fair summary
# of the declines, and the per-solve `cg_iters` column is used for those instead.
TAIL_WARM = 170


def his_solves():
    """His 160 per-design-iteration CG costs — and what they are NOT.

    ★ THREE THINGS ABOUT THIS COLUMN THAT THE MODEL BELOW DEPENDS ON, ALL
    CHECKED RATHER THAN ASSUMED:

    1. EVERY ROW IS A JACOBI FALLBACK. `cg_multigrid` is 0 on all 160 rows
       (`mg_mode = stagnated-latched`), so every row is a solve GenEO is
       entitled to act on. A multigrid-carried solve never enters GenEO and
       would have to be excluded; none needs to be. Asserted below.

    2. THE CSV'S GenEO COLUMNS ARE EMPTY, AND THAT IS NOT THE SAME AS GenEO
       BEING OFF. `geneo_action`, `geneo_dim` and `geneo_burn` are 0 on all 160
       rows because those columns POST-DATE the binary that produced this run —
       while `run_info.json` for the same run records `geneo_armed_solves = 12`,
       `geneo_declined_solves = 156` and a full decision log. So GenEO WAS
       active; the per-row record of what it did simply does not exist. This
       means the total CANNOT be decomposed into plain and engaged parts from
       the CSV, and the model does not try to.

    3. SO THESE ARE 'HIS RUN AS IT RAN', NOT 'A GenEO-FREE RUN'. Up to 12 of the
       168 solves were engaged, and an engaged solve's raw count is
       (burn + deflated tail) rather than the full plain cost it was spared.
       ★ THE DIRECTION OF THAT ERROR IS THE SAFE ONE: it makes the plain
       baseline slightly TOO LOW, so every GenEO win reported against it is
       understated and every GenEO loss overstated. A win measured here is
       conservative. (Also: the decision log's solve indices run to 168 while
       the CSV has 160 rows — the certification/stress-recovery solves sit
       outside the iteration loop and are not in this column at all.)
    """
    with open(HIS) as f:
        r = list(csv.DictReader(f))
    carried = sum(int(x["cg_multigrid"]) for x in r)
    assert carried == 0, f"{carried} rows carried multigrid — revisit this model"
    acts = {x["geneo_action"] for x in r}
    assert acts == {"0"}, (
        f"his CSV now carries real geneo_action values {acts} — point 2 of this "
        f"docstring is stale and the model can and should decompose the total")
    return [int(x["cg_iters"]) for x in r]


ENGAGED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "engaged")


def _csv_sources():
    """Every per-solve CSV this task produced, tagged with its tiling.

    Both the triage runs and the forced-engagement probe runs are read: a warm
    (action 2) solve is a warm solve wherever it happened, and the triage
    produced some for free at the coarser tilings where its rung-3 burn happened
    to clear the threshold.
    """
    for base, pat, strip in ((TRIAGE, "run_core", "run_core"),
                             (ENGAGED, "eng", "eng")):
        if not os.path.isdir(base):
            continue
        for n in sorted(os.listdir(base)):
            p = os.path.join(base, n, "iterations.csv")
            if n.startswith(pat) and os.path.exists(p):
                yield int(n.replace(strip, "")), p
    # The probe writes its runs under $TMPDIR; collect_triage-style copies land
    # in engaged/. Nothing else is read, so a stray directory cannot contribute.


def measured_nt():
    """Per tiling: N_t, the COLD build tail, and every WARM (refreshed) tail.

    ★ THE COLD AND WARM TAILS ARE KEPT APART AND NEVER AVERAGED. A cold build
    solve (action 3) burns 500 plain, builds the basis, then deflates; a warm
    solve (action 2) refreshes a held basis and deflates from where the gate let
    it start. His run measured 427 cold against a warm median of 170 — a 2.5x
    difference. Folding them together would produce a number describing neither.
    """
    out = {}
    for c, p in _csv_sources():
        with open(p) as f:
            rows = list(csv.DictReader(f))
        rec = out.setdefault(c, {"nt": 0, "cold": None, "warm": [], "seen": set()})
        for x in rows:
            act, dim = int(x["geneo_action"]), int(x["geneo_dim"])
            if dim > 0:
                rec["nt"] = rec["nt"] or dim
            burn, iters = int(x["geneo_burn"]), int(x["cg_iters"])
            tail = iters - burn
            if act == 3 and rec["cold"] is None:
                rec["cold"] = tail
            elif act == 2:
                # ★ KEYED BY (burn, iterations), NOT APPENDED BLIND. The SAME
                # solve appears in both sources — a design-iteration solve is a
                # row in iterations.csv AND an entry in the decision log — so a
                # blind append counts it twice and silently shifts the median.
                # It did: core=16 first came out [187, 320, 810, 810] and
                # core=12 [73, 73, 204, 278, 1144], both with a duplicate.
                key = (burn, iters)
                if key not in rec["seen"]:
                    rec["seen"].add(key)
                    rec["warm"].append(tail)
        # ★ THE DECISION LOG CARRIES WARM SOLVES THE CSV CANNOT SEE, and on a
        # short ladder that is most of them. `iterations.csv` has ONE row per
        # design iteration (4 here), while the gate acts on every fallback solve
        # including the per-rung certification/stress-recovery solves — 12 at
        # core=16. Reading only the CSV gave core=16 a single warm tail (810,
        # from rung 3, the hardest) and therefore a worst-case median; the log
        # holds three (187/320/810).
        #
        # THE BIAS THAT COMES WITH IT, STATED: the log records TRANSITIONS only,
        # so its action-2 rows are each the FIRST engage after a run of declines.
        # For DECLINES that selection is severe (it picks the hardest 5 %, which
        # is why this file never uses logged declines). For engaged TAILS it is
        # far milder — a solve's deflated tail is a property of the basis and the
        # system, not of what the previous solve decided — but it is not nothing,
        # and it is the reason the `n` column is printed beside every tail.
        info = os.path.join(os.path.dirname(p), "run_info.json")
        if os.path.exists(info):
            try:
                with open(info) as f:
                    d = json.load(f)
            except Exception:
                d = {}
            for x in d.get("geneo_decisions", []):
                if x.get("action") == 2:
                    key = (x["burn"], x["iterations"])
                    if key in rec["seen"]:
                        continue
                    rec["seen"].add(key)
                    rec["warm"].append(x["iterations"] - x["burn"])
    for v in out.values():
        v.pop("seen", None)
    return {c: v for c, v in out.items() if v["nt"] > 0}


def main():
    C = his_solves()
    tot = sum(C)
    print("=" * 78)
    print("HIS RUN — the denominator, measured, no model")
    print("=" * 78)
    print(f"{len(C)} stagnating solves, TOTAL CG = {tot:,}")
    print(f"  min {min(C)}  median {statistics.median(C):.0f}  max {max(C)}")
    print("  every row is a Jacobi fallback (mg_mode = stagnated-latched), so")
    print("  every row is a solve GenEO is entitled to act on.")

    nt = measured_nt()
    print()
    print("=" * 78)
    print("MEASURED N_t PER TILING (this task's triage)")
    print("=" * 78)
    if not nt:
        print("no triage points collected yet")
    print(f"{'core':>5} {'N_t':>7} {'cold tail':>10} {'warm tails (deflated iters)':>32}")
    for c in sorted(nt):
        v = nt[c]
        w = (f"{sorted(v['warm'])} median {statistics.median(v['warm']):.0f}"
             if v["warm"] else "none measured at this tiling")
        cold = v["cold"] if v["cold"] is not None else "-"
        print(f"{c:>5} {v['nt']:>7} {str(cold):>10}   {w}")
    print()
    print("★ THE WARM TAIL IS §2(b)'s WHOLE QUESTION: does a SMALLER basis deflate")
    print("WORSE? If it does, the refresh saving is bought back in a longer tail")
    print("and the lever is exhausted. Compare these against his measured warm")
    print("median of 170 at the shipped 8^3.")

    print()
    print("=" * 78)
    print("MODEL A — THE SHIPPED SKI-RENTAL GATE")
    print("=" * 78)
    print("★ THE BASELINE IS HIS RUN AS IT ACTUALLY RAN — 438,348 CG over 160")
    print("stagnating design-iteration solves — and NOT a differently-tuned GenEO.")
    print("Comparing an accelerator only against other tunings of itself hides the")
    print("possibility that none of them earns its keep. See his_solves()'s")
    print("docstring for what that baseline is and is not: GenEO WAS active in it,")
    print("so it is not a clean GenEO-free control, and the direction of that")
    print("impurity understates every GenEO win reported below.")
    print()
    print("A solve whose plain cost is C pays:")
    print("    C                                if C <= threshold  (finishes plain)")
    print("    threshold + 2*N_t + 2*tail_warm  if C >  threshold  (engages)")
    print()
    print("    threshold = 2*N_t + 500 + 2*427")
    print("    all-in    = threshold + 2*N_t + 2*tail_warm")
    print()
    print("★ NOTE WHAT THE SECOND LINE MEANS, BECAUSE IT IS THE WHOLE STORY. The")
    print("burn is NOT refunded when the deflation engages — the solve has already")
    print("spent it. So all-in ALWAYS exceeds the threshold, and any solve whose")
    print("plain cost sits between threshold and all-in is one the gate engages")
    print("and LOSES on. That is the ski-rental 2-competitive bound showing up as")
    print("real iterations, and it is why the 'engage' and 'of which LOSE' columns")
    print("are printed side by side. An earlier version of this script modelled the")
    print("cost as min(C, all-in), which quietly refunds the burn; it made core=12")
    print("look like -0.6 % when it is really +13.1 %. The wrong version is named")
    print("here because it is an easy and flattering mistake to repeat.")
    print()
    print(f"{'N_t':>7} {'source':>13} {'thresh':>7} {'all-in':>7} {'engage':>11}"
          f" {'LOSE':>6} {'TOTAL CG':>11} {'vs HIS RUN':>12}")
    print(f"{'--':>7} {'HIS RUN':>13} {'-':>7} {'-':>7} {'-':>11} {'-':>6}"
          f" {tot:>11,} {'baseline':>12}")
    cands = sorted({v["nt"] for v in nt.values()} | {500, 430, 400, 325, 256, 225, 150, 100})
    for N in sorted(cands, reverse=True):
        src = next((f"core={c} MEAS" for c in sorted(nt) if nt[c]["nt"] == N), None)
        # ★ EACH MEASURED TILING IS CHARGED ITS OWN MEASURED WARM TAIL HERE TOO,
        # exactly as MODEL B does. An earlier version charged every row his 170
        # while MODEL B used the measured value — the two models then disagreed
        # about the same tiling for no reason but their own inconsistency, and it
        # mattered: core=16 read -6.1 % on the borrowed tail and +1.3 % on its
        # own measured 320. The measured tail is the right one and both models
        # now use it.
        tail = TAIL_WARM
        if src:
            c = int(src.split("=")[1].split()[0])
            if nt[c]["warm"]:
                tail = statistics.median(nt[c]["warm"])
        thr = int(2 * N + BURN0 + 2 * TAIL0)
        allin = int(thr + 2 * N + 2 * tail)
        s = sum(c if c <= thr else allin for c in C)
        eng = [c for c in C if c > thr]
        lose = [c for c in eng if allin > c]
        print(f"{N:>7} {src or 'hypothetical':>13} {thr:>7} {allin:>7} "
              f"{len(eng):>4} of {len(C):<3} {len(lose):>6} {s:>11,} "
              f"{100*(s-tot)/tot:>+11.1f}%")

    print()
    print("★ READ THE SHIPPED ROW FIRST, BECAUSE IT VALIDATES THE MODEL. At")
    print("N_t = 1686 the model engages 8 of 160 solves and every one of them is a")
    print("LOSS. His run armed 12 and declined 156 — same picture, and PR 329's")
    print("finding in one line: the gate is doing correct arithmetic on a")
    print("mechanism that cannot pay at this basis size.")
    print()
    print("★ AND THE NON-MONOTONE MIDDLE IS THE REAL WARNING. Shrinking N_t from")
    print("1686 to 718 makes things WORSE, not better (+6.5 % -> +13.1 %), because")
    print("it drops the threshold into the middle of his solve-cost distribution")
    print("and the gate starts engaging on solves that were about to finish plain.")
    print("A tiling that halves N_t but lands there is a REGRESSION. GenEO only")
    print("starts beating no-GenEO-at-all at N_t of roughly 430.")
    print()
    print("★ AND THE CEILING THIS MODEL EXPOSES. Even at N_t = 100 the shipped")
    print("gate returns about -32 %. THE 21.7x IS NOT REACHABLE THROUGH THIS GATE")
    print("AT ANY BASIS SIZE, because the gate makes every solve burn its")
    print("threshold plain BEFORE deflating and never refunds it. The 21.7x")
    print("(5,412 -> 249, fea.hpp) is what deflation does running from iteration 0,")
    print("which the ski-rental policy forbids by construction.")

    print()
    print("=" * 78)
    print("MODEL B — STANDING ARMING (deflate from iteration 0, no burn)")
    print("=" * 78)
    print("    per solve = 2*N_t (refresh) + 2*N_defl")
    print()
    print("This is NOT a proposal and is NOT armed by this task. It is here")
    print("because it is where the 21.7x actually lives, and because the standing")
    print("posture was measured as a 1.25x LOSS (2026-08-02-geneo-standing-probe)")
    print("AT N_t ~ 1,686 — a verdict whose entire cost basis is the refresh term")
    print("this sweep moves. If a tiling shrinks N_t enough, that NO-GO is built on")
    print("a number that no longer holds and deserves re-asking. Separately.")
    print()
    print("★ READ THE 'n' COLUMN BEFORE COMPARING TWO MEASURED ROWS. The tail is a")
    print("median over n solves, and the tail GROWS with rung difficulty at every")
    print("tiling (core=8: 217/241/905 across rungs 1/2/3). So a row whose n is 1")
    print("is a median over whichever single rung happened to engage — for core=16")
    print("that is rung 3, the HARDEST — and it is therefore charged a worst-case")
    print("tail while rows with n=3 or 4 are charged a middling one. core=16's row")
    print("is PENALISED by this, not flattered, and its true standing-armed cost is")
    print("better than shown. Fixing it needs the forced-engagement probe at 16,")
    print("which did not run.\n")
    print(f"{'N_t':>7} {'source':>13} {'tail':>6} {'n':>3} {'per solve':>10} {'TOTAL CG':>12} {'vs HIS RUN':>12}")
    print(f"{'--':>7} {'HIS RUN':>13} {'-':>6} {'-':>3} {'-':>10} {tot:>12,} {'baseline':>12}")
    for N in sorted(cands, reverse=True):
        src = next((f"core={c} MEAS" for c in sorted(nt) if nt[c]["nt"] == N), None)
        # ★ USE EACH TILING'S OWN MEASURED WARM TAIL WHERE ONE EXISTS. Charging
        # every tiling his 8^3 tail of 170 would flatter the coarse rows, since
        # the coarse tails measured here are LARGER on the hard rungs (core=12
        # rung 3 needed 1,144 against core=8's 905). The measured median is used
        # for measured tilings and 170 only for hypothetical ones, and the tail
        # actually charged is printed so no row's cost can be read without it.
        tail, n = TAIL_WARM, 8  # his run's own sample: 8 engaged solves
        if src:
            c = int(src.split("=")[1].split()[0])
            if nt[c]["warm"]:
                tail = statistics.median(nt[c]["warm"])
                n = len(nt[c]["warm"])
        per = int(2 * N + 2 * tail)
        s = per * len(C)
        print(f"{N:>7} {src or 'hypothetical':>13} {int(tail):>6} {n:>3} {per:>10} "
              f"{s:>12,} {100*(s-tot)/tot:>+11.1f}%")
    print()
    print("★ BOTH MODELS ARE ANCHORED AT AN INDEPENDENTLY OBSERVED POINT, and")
    print("that is the only reason to read either of them off-baseline:")
    print("  MODEL A at N_t=1686 predicts 8 engagements out of 160, ALL of them")
    print("    losses. His run armed 12 and declined 156. Same picture to within")
    print("    the difference between his N_t (1,674/1,684) and this task's")
    print("    triage value (1,686), and the same conclusion: the engagements")
    print("    that do happen are not paying for themselves. AGREES.")
    print("  ★ AND A SECOND, INDEPENDENT CHECK THAT THIS TASK PRODUCED. MODEL A")
    print("    predicts core=12 (N_t=718) costs +13.1 % against the shipped")
    print("    tiling. The triage MEASURED core=12 at 6,909 total CG against")
    print("    core=8's 6,114 — +13.0 %. Two unrelated routes (a 160-solve model")
    print("    over HIS run, and a direct 4-solve measurement over THIS one).")
    print("    ★ DO NOT READ THE THIRD DIGIT. The triage's own trajectory noise is")
    print("    ~20 % (rung 1 cost 1,121 CG at core=8 and 1,372 at core=12 on")
    print("    designs whose margins agree to 6 digits), so the agreement is in")
    print("    SIGN and MAGNITUDE. That is still worth a great deal: both say a")
    print("    tiling that halves N_t makes the run SLOWER, which is the opposite")
    print("    of what the sweep was expected to find.")
    print("  MODEL B at N_t=1686 predicts +35.5 % total CG, i.e. a ~1.36x loss.")
    print("    2026-08-02-geneo-standing-probe MEASURED a 1.25x loss on WALL for")
    print("    the standing posture at this operating point. CONSISTENT — but note")
    print("    these are different units (plain-iteration equivalents against wall")
    print("    clock), so this is agreement in sign and rough magnitude, NOT a")
    print("    reproduction. It is quoted at that strength and no higher.")
    print()
    print("★ THE CAVEAT THAT KEEPS MODEL B HONEST. It assumes the warm deflated")
    print("tail stays near 170 as the basis shrinks. That is the ONE thing here")
    print("not measured across tilings, and it is exactly what §2(b) warns about:")
    print("a smaller basis may deflate worse. `run_engaged_probe.sh` measures it")
    print("directly by forcing the gate open at each tiling; until those numbers")
    print("are in, MODEL B IS AN UPPER BOUND AND MUST BE READ AS ONE.")


if __name__ == "__main__":
    main()

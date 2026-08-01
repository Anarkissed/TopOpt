# E0 — Expected numbers, written BEFORE any measurement (AC1)

Task: `warm-start-coarse-experiment`. This file is committed before the first
experimental run so the predictions cannot be fitted to the results. Every
number below is a falsifiable claim with a mechanism attached.

Machine of record: Apple M2 Pro (6P+4E), 16 GB, macOS 25.5.0 — the same machine
as `evidence/2026-08-02-iteration-phase-timing/`.

---

## The mechanism I expect to find, stated first

The target is an EARLY-DESIGN TRANSIENT: multigrid's V-cycle stagnates while the
design is dilute, grey and high-contrast, the 127 latch turns multigrid off, and
GenEO then charges 87.9 % of each latched iteration's wall (handoff
2026-08-02-iteration-phase-timing). `warm_start_coarse` proposes to do that
thrashing at res/2 (1/8 the DOFs) and hand the fine grid a settled design.

**Two structural facts make me expect much less than the ~8x the framing hopes
for, and I am naming them before measuring:**

1. **`warm_start_coarse` seeds RUNG 0 ONLY.** With `warm_start_inherit` off —
   and it IS off on a self-weight run by handoff 113's deliberate decision —
   every rung ≥ 1 still starts from uniform grey. If the transient is a
   PER-RUNG property, the cascade can only ever rescue one rung's worth of it.
2. **Prolongation makes the seed GREYER, not sharper.** The seed reaches the
   fine grid through trilinear upsampling and then one pass of the loop's own
   density filter. Grey and dilute is precisely the conditioning that stagnates
   the V-cycle. A "settled" design in the OPTIMIZER's sense is not automatically
   a well-conditioned one in the SOLVER's sense, and the whole lever rests on
   assuming it is.

---

## E1 — The coarse pre-solve will itself stagnate

The ill-conditioning is a property of the dilute, high-contrast design, not of
the resolution. **Predict:** on the stagnating design-box fixture the res/2
pre-solve latches multigrid off too, and pays GenEO at res/2.

## E2 — The pre-solve's own wall will exceed the naive 1/8

If E1 holds, the pre-solve's price is dominated by GenEO setup, whose cost is
`N_t` operator applies plus an `N_t²` Galerkin assembly — `N_t` does not fall
8x when the DOF count does. **Predict:** pre-solve wall lands at **15–40 %** of
baseline rung-0 wall, against the naive-DOF expectation of 12.5 %.

## E3 — Net wall on the stagnating fixture: a wash, not a rescue

**Predict:** total run wall (fine + pre-solve, AC3-charged) changes by between
**−30 % and +20 %**. Most likely outcome: within ±10 %, i.e. a wash. I am
explicitly predicting this does NOT reproduce the ~80 %-of-wall recovery the
target implies, because of fact (1) above.

## E4 — Iterations move less than wall, and may move the wrong way

**Predict:** rung-0 fine iterations down **10–30 %**; grand total including the
pre-solve **flat to +15 %** — reproducing handoff 110's warmB finding
(L-bracket −6 %, self-weight **+8 %**) rather than overturning it.

## E5 — The 127 latch still fires

**Predict:** `mg_mode` stays `stagnated-latched` with the option armed. The
latch is run-level and does not re-arm (memory: mg-latch-rearm-refuted), so even
a rung-0 rescue leaves rungs ≥ 1 latched.

## E6 — Rungs ≥ 1 will be BIT-IDENTICAL, not merely similar

This is the sharpest prediction and the one that would most cleanly falsify the
whole lever. With inherit off, rung 1 starts uniform in both postures, from a
mask and grid that do not depend on rung 0's design. Handoff 110 measured
exactly this on its own fixtures ("warmB terminal is bit-identical to cold",
mean |Δρ| = 0.000). **Predict:** every rung ≥ 1 reproduces cold to the byte —
same iterations, same compliance, same margin, same mesh hash — and ONLY rung 0
differs. If so, the gate table can only flip on rung 0, and AC5's compliance
comparison is a rung-0 comparison.

## E7 — Gate: no verdict flip

**Predict:** no rung changes verdict. Rung-0 margin moves by a few percent in
either direction (110 saw its L-bracket rung-0 margin fall 9.83 → 7.18, a
"weaker but still safe different optimum"). Rung-0 design difference will
EXCEED the 1e-9 negative-control floor by many orders of magnitude — that is
expected and is not a defect; the floor exists to prove the rungs that DIDN'T
move really didn't.

## E8 — Healthy control: a pure loss

On a fixture where multigrid never stagnates, every iteration costs roughly the
same, so the pre-solve buys only the iterations it removes from rung 0 and pays
its own. **Predict:** net wall **+3 % to +15 %** — a small, real LOSS. I will
report this trade rather than averaging it against the stagnating case.

---

## What would make me recommend ARM

All of: net wall win > 20 % on the stagnating fixture AFTER charging the
pre-solve; no verdict flip on any rung of any fixture; and the healthy-control
loss under ~5 %. On my predictions above, I expect NOT to reach that bar.

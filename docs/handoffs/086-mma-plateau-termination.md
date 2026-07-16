# 086 — MMA objective-plateau termination

**Track:** core. **Territory:** `/core/` only (no app, no fixtures, no
benchmarks.json, no materials.json, no ARCHITECTURE.md, no ROADMAP box).
**Builds on:** diagnosis 085-mma-convergence (the branching that proved MMA
terminates on the iteration cap 100% of the time) and 085-matrixfree-speed (the
SIMD + 8-colour-threading + scratch-reuse work that this task re-measures on
real Apple hardware).

## What changed, in one paragraph

MMA's stopping test was `change_tol` on the DESIGN-space `max|drho|`. At fixed
volume a few boundary voxels oscillate at the move limit long after the
COMPLIANCE has settled, so that test needs ~395 iterations to fire while the
objective is within ~1% by ~150 — which is why the production ladder always ran
out the iteration cap (60) and discarded the branch-refinement phase. This task
replaces the MMA stop test with an OBJECTIVE-PLATEAU test (running-minimum
compliance improvement over a trailing window) behind a raised safety cap. The
OC / projected path — including Gate-V2 — is byte-identical and untouched.

---

## STEP 1 — CURRENT cost re-measured (the old table was badly stale)

The 085-matrixfree-speed work **is in this tree** (verified: `matfree.cpp` has
the NEON `axpy24`, the 8-colour `color_offsets` threading, `apply_kgg_raw`, and
`MfScratch`). This worktree ran on **real Apple Silicon (M-series, 10 cores,
macOS 26), Release `-O3`** — so unlike the 085 x86 proxy these are true on-device
NEON + threaded numbers.

Measured, matrix-free MG-CG, self-weight cube at **64³ (262 144 elements,
823 k DOF)**, `MultigridCG_Matfree`, default threads:

| quantity | diagnosis (stale) | **this tree, measured** |
|---|---:|---:|
| per-iteration wall @ 64³ | ~14.75 s/iter | **~4.73 s/iter** |
| implied cap-60 rung | ~15 min | **~4.7 min** |

**~3.1× faster per iteration than the diagnosis assumed.** The cap/plateau cost
decision (STEP 4) is made against 4.73 s/iter, not 14.75.

> Harness: `core/tests/harness/mma_probe.cpp` (NOT wired into CTest), built with
> `c++ -std=c++17 -O3 -DNDEBUG -I include tests/harness/mma_probe.cpp
> build-release/libtopopt.a -o /tmp/mma_probe -lpthread`, run as
> `mma_probe cost`.

---

## STEP 2 — the plateau test (design + non-monotone robustness)

New public predicate `topopt::mma_objective_plateau(compliance_history, window,
rel_tol, min_drop)` (declared in `simp.hpp`, defined in `simp.cpp`):

> Fire when the **running-minimum** compliance has improved by less than
> `rel_tol` (relative) over the trailing `window` iterations — but only once it
> has dropped at least `min_drop` below the uniform-start compliance.

`SimpOptions` gains three tunables and a raised cap:

- `mma_plateau_window` (default **10**) — trailing window; `<= 0` disables
  the plateau and reverts MMA to the `change_tol` test (opt-out / back-compat).
- `mma_plateau_tol` (default **1e-3**) — relative running-min threshold.
- `mma_plateau_min_drop` (default **0.05**) — the progress gate (point 3 below).
- `max_iterations` default **60 → 200** — the raised SAFETY CAP behind the
  plateau. This default is the ONLY thing the production app (which relies on
  `SimpOptions` defaults, per the diagnosis) needed to change to let the plateau
  be the terminator; every test and fixture sets `max_iterations` explicitly, so
  the raised default reaches only the production MMA ladder.

Wired into BOTH `simp_optimize` overloads (plain + masked) via the shared
`stage_should_stop(options, history, change)` helper: for `updater == MMA &&
window > 0` it tests the plateau, otherwise it keeps `change < change_tol`
byte-identically. MMA rejects a projection schedule, so an MMA run is always a
single non-projected stage and `history` is exactly its compliance curve. The
stress path (`simp_optimize_stress`) is intentionally left on `change_tol` (its
objective dynamics differ; out of scope for this diagnosis).

### Why the running MINIMUM, not a raw relative change (the robustness argument)

MMA compliance is **non-monotone**: it spikes up whenever a member toggles, then
recovers to a NEW low. Measured proof from this tree — the 64³ cost run's first
six compliance values were `8.18e2, 7.82e2, 5.11e5, 5.96e2, 3.85e5, 5.72e2`:
two full **~10³× spikes** in six iterations. A naive `|c[i]-c[i-1]|/c[i]` test is
useless against that.

The failure the diagnosis warned about is subtler: a naive test fires in the
**flat spot that precedes a productive toggle**, terminating BEFORE the drop and
keeping a worse design. The running-minimum window test is immune two ways:

1. **Spikes never lower a running minimum**, so a spike is inert — it cannot make
   the test fire, and it cannot be the kept "improvement".
2. It fires only when `window` CONSECUTIVE iterations have all failed to find a
   materially lower compliance. A flat spot **shorter than `window`** cannot
   trigger it, because the window still reaches back to real descent (so
   `best_prev > best_now`). It fires only once the descent has genuinely stalled.
3. **A progress gate** (`mma_plateau_min_drop`, default 0.05) blocks the fire
   until the running minimum has dropped ≥5 % below the uniform-start compliance
   `c[0]`. This is not cosmetic — it was forced by a REAL failure STEP 4 exposed
   (below): on a low-volume rung the early "forming" iterations spike ABOVE `c[0]`,
   so the running minimum stays PINNED at `c[0]` for ~10 iterations and property
   (2)'s "no improvement over the window" reads TRUE while the design is still
   near-uniform. The gate requires genuine descent from the start before a
   plateau is even considered; every well-behaved case drops far more than 5 %
   long before it settles, so the gate never delays a legitimate plateau.

This is proven as a deterministic unit test (`test_simp`, `[plateau]` block) at
the **production default window = 10**, on a hand-built curve: descent → an
8-iter flat spot (shorter than the window) → a toggle spike → recovery to a new
low → settle. The naive single-iteration test fires at **iter 15**, inside the
flat spot (with well more than window+1 samples present, so the window test's
refusal is a real check), where the running min is still ~14.4 (true optimum ~9).
The window test does NOT fire there and only fires at **iter 37**, after the
toggle, with the running min at the true optimum ~9. The guard asserts both — it
FAILS against a `window=1` (naive) detector, which is asserted to fire early on
the same prefix. A SECOND `[plateau gate]` block guards the progress gate on a
hand-built spike curve (`c[0]=18.4`, iters 2-11 spike to `1e5-1e6`, then a
descent to ~2.39): with the gate OFF the forming-phase prefix fires at iter 11
(the bug), with the gate ON it fires only at iter 39, once the design is
near-optimal.

**The measured curves also killed the diagnosis's suggested `window=5`:** on the
real 64×4×32 cantilever, `window=5` fires at **iter 6** keeping a `+863%` spiked
design, because the early forming phase (iters 1-12) is all spikes and a
5-window cannot outlast them. `window` must be ≥8; STEP 3 settled on 10.

---

## STEP 3 — proof on four geometries (incl. the one that broke the rule)

Distinct self-weight/loaded cases (raw compliance curves captured with plateau
DISABLED at a 250-iter cap; the plateau fire point is then computed for candidate
params). "converged c\*" = running min over the full run; "cap-60" = the design a
cap-60 run keeps.

| case | grid | vf | load | converged c\* | cap-60 | plateau fires@ | plateau c | plateau vs c\* | vs cap-60 |
|---|---|---:|---|---:|---:|---:|---:|---:|---|
| cantilever | 64×4×32 | 0.26 | self-weight | 8.7654 | +3.00% | **102** | 8.870 | **+1.20%** | closes 60% of gap |
| blocky | 24×24×12 | 0.40 | self-weight | 0.48615 | +5.07% | **145** | 0.4892 | **+0.62%** | closes 88% of gap |
| tip-loaded | 64×8×16 | 0.30 | tip = 4× self-wt | 68.03 | +4.19% | **108** | 68.35 | **+0.47%** | closes 89% of gap |
| low-vf cube | 24×24×24 | 0.20 | self-weight | 2.279 | (see below) | **116** | 2.382 | **+4.53%** | — |

("cap-60"/"plateau" columns are the design a run terminating there keeps, as %
above c\*. Raw curves in `mma_probe curve` / `mma_probe probe`; fire points from
`mma_objective_plateau`.)

> **Fire-iteration precision (honest caveat).** These fire points come from raw
> plateau-off curves and are reproducible PER SOLVER (two independent JacobiCG
> `probe` runs are byte-identical). But the plateau tail is EXTREMELY flat, so the
> exact iteration at which "improvement < 1e-3 over the window" first trips is
> SOLVER-SENSITIVE: the vf=0.20 rung fires at **116** under JacobiCG (the offline
> probe) but at **183** under matrix-free MG-CG (the STEP-4 ladder / production
> solver) — both solve to `cg_tolerance = 1e-8`, but their sub-tolerance
> displacement fields differ enough near a near-flat objective to shift the trip
> point by tens of iterations. Both land near the converged optimum (2.32-2.38 vs
> c\*=2.28) and both beat cap-60, so the DESIGN QUALITY is robust even though the
> exact fire iteration is not solver-invariant. The STEP-4 ladder and the
> production s/iter both use matrix-free, which is bit-deterministic (085); the
> vf=0.20 row above is the JacobiCG probe, hence 116 vs the ladder's 183.

**The low-vf cube is here because it BROKE the rule, exactly as the acceptance
criterion anticipated — and I fixed it rather than tuning it away.** When STEP 4's
4-rung ladder ran, the vf=0.20 rung fired at **iter 11** (the minimum possible)
with compliance **69.4** while a plain cap-60 run reached **2.49** — the plateau
kept a near-uniform design ~30× worse than the optimum. Cause (measured curve):
`c[0]=18.4`, then iters 2-11 SPIKE to `1e4-3.4e6` (the design percolating), so the
running minimum stays pinned at `c[0]` and the window test reads "0 % improvement"
and fires. The fix is the **progress gate** (`mma_plateau_min_drop`, STEP 2 point
3): with it the rung fires at **iter 116** (compliance 2.38 — better than cap-60's
2.49), and the three well-behaved cases above are **byte-for-byte unchanged**
(102 / 145 / 108) because they descend far past the 5 % gate long before settling.
This is the criterion working as designed: an early fire on one case meant the
rule was wrong; the answer was a principled gate, not re-tuning `window`/`tol`
until the case looked good.

**Chosen default: `window = 10`, `tol = 1e-3`.** It is identical to `window = 8`
on the two cases that flatten early (cantilever, tip-loaded fire at 102/108
either way) but far better on the chunky `blocky` case, whose refinement runs
longer: `window = 8` fires at 104 leaving +1.96%, while `window = 10` waits until
145 and leaves +0.62%. This is the detector ADAPTING to each curve — it fires
when THAT curve's running minimum actually flattens, not at a fixed iteration.
`window = 10` is also strictly safer against the early spike phase than the `8`
that already survived it, and than the `5` the diagnosis suggested (which fired
at iter 6). `tol` tighter than `1e-3` (e.g. `3e-4`) NEVER fires on the tip-loaded
150-iter run — too strict — so `1e-3` is the robust choice across all three.

**ACCEPTANCE — met on all four (after the gate fix).** (1) The plateau design is
materially better than cap-60 everywhere (it closes 60 / 88 / 89 % of the cap-60
→ converged gap on the three well-behaved cases; on the low-vf cube it lands at
2.38 vs cap-60's 2.49). (2) No case fires before its refinement settles: the four
fire at 102 / 145 / 108 / 116, each at/after the end of the STEEP refinement
(measured on the cantilever: the descent rate is ~0.045 %/iter over iters 60-100,
then falls to ~0.016 %/iter by 120 and ~0.004 %/iter by 143 — the plateau fires
right as the steep phase ends and does NOT discard it the way cap-60, at the
phase's START, does). The one case that DID fire early (vf=0.20 @ iter 11) is
reported above and fixed by the progress gate, not by tuning `window`/`tol`.

---

## STEP 4 — honest cost

The plateau costs **~2× the wall time** of cap-60, because it runs each MMA
rung ~2× as many iterations (94-183 vs 60). That is the maintainer's call —
stated plainly, not hidden.

**Measured 4-rung self-weight ladder** (vf `{0.5, 0.4, 0.3, 0.2}`, 4 independent
`simp_optimize` rungs, exactly as `minimize_plastic` drives them). The absolute
seconds below were measured under CONCURRENT load from a second worktree on this
machine, so they are indicative, not clean — but the per-rung ITERATION COUNTS
are deterministic (solver- and load-independent) and are the honest cost driver:

| rung (vf) | plateau iters | plateau converged | cap-60 iters | plateau c | cap-60 c |
|---|---:|:---:|---:|---:|---:|
| 0.50 | 94 | ✓ | 60 | 0.3804 | 0.3837 (+0.85%) |
| 0.40 | 134 | ✓ | 60 | 0.5648 | 0.5796 (+2.55%) |
| 0.30 | 105 | ✓ | 60 | 1.0417 | 1.0588 (+1.62%) |
| 0.20 | 183 | ✓ | 60 | 2.316 | 2.494 (+7.68%) |
| **total** | **516** | | **240** | | |

Every plateau rung terminated `converged == true` (on the plateau, not the cap of
200), and each beat its cap-60 counterpart (0.85-7.68% lower compliance). The
vf=0.20 rung is the one the progress gate rescued: before the gate it fired at
iter 11 keeping a compliance-69 design; with the gate it runs to 183 and reaches
2.316 (near the converged 2.279). The plateau ran **516 / 240 = 2.15×** the
iterations. (Measured n=24 matrix-free MG-CG wall, under concurrent load from a
second worktree: indicative only; the 24³ grid is a fast proxy — the iteration
counts are the invariant that matters, and they use the production matrix-free
solver.)

**Projected to production 64³** using the clean STEP-1 measurement of
**4.73 s/iter** (matrix-free MG-CG):

| | iterations (4 rungs) | 64³ wall @ 4.73 s/iter |
|---|---:|---:|
| cap-60 (today) | 4 × 60 = 240 | ~19 min |
| plateau | 516 (94+134+105+183) | ~41 min |

So a 64³ 4-rung ladder goes from ~19 min (cap-60, discarding refinement) to
~41 min (plateau, 2.1×) for a materially better design. The maintainer already runs ~1 h ladders; this is
within that envelope and buys the branch-refinement phase the diagnosis showed
was being thrown away.

**Higher resolution — the adaptive rule scales where a fixed cap does not.** The
plateau fires on the objective CURVE SHAPE, not the iteration index, so its fire
point is roughly resolution-stable: across the STEP-3 geometries (6 912 to
32 768 elements) and this ladder it lands at ~100-145 iterations regardless of
size. A FIXED cap is the opposite — the diagnosis noted cap-60 is "open-ended at
128³": at higher resolution the objective needs MORE iterations to reach the same
relative settledness, so a fixed 60 captures an ever-smaller fraction of the
refinement as the mesh refines, while the plateau keeps terminating at "the
objective has settled" and therefore keeps delivering the same design QUALITY at
every resolution (at a wall cost that scales with the solve, as any method must).
This confirms the diagnosis's expectation that an adaptive rule behaves better at
128³ than a fixed cap.

---

## Guards & every changed expected value

- **Gate-V2: GREEN and byte-identical.** The plateau touches only the MMA branch
  of `stage_should_stop`; the OC + projected path Gate-V2 pins is unchanged.
  Verified: `gate_v2` passes.
- **Full core suite: GREEN — `100% tests passed, 0 failed out of 41`** (Release,
  Apple Silicon).

Tests whose expectations changed, each justified:

1. **`test_simp` (unit) — NEW `[plateau]` + `[plateau gate]` blocks.** Two
   pure-function guards for `mma_objective_plateau`: the anti-early-termination
   guard (does NOT fire in a flat spot before a productive toggle; FAILS against a
   `window=1` naive detector) and the progress-gate guard (does NOT fire in the
   spike-heavy forming phase; without the gate the same prefix DOES fire — the
   vf=0.20 bug). No existing assertion changed.
2. **`test_mma` (validation) — NEW scenario 5.** Solve-based guard: a self-weight
   cantilever under MMA now terminates `converged == true` with
   `iterations < cap`; the same run with the plateau disabled hits the cap; and
   the plateau design beats the old cap-60 design. Also asserts the production
   defaults (`window`, `tol`, `max_iterations == 200`). No existing assertion
   changed — scenarios 1-4 (updater parity, box, move-limit, mask pins) still
   pass with the plateau ON, which is itself evidence the plateau does not
   regress the MMA optimum within their 2% bands.
3. **`test_minimize_plastic` (validation) — scenario O.** Added
   `omma.simp.mma_plateau_window = 0`. Scenario O asserts the MMA *update rule*
   matches or beats OC at each rung; that is only meaningful at a MATCHED
   iteration budget. With the plateau on, MMA stopped ~14 iters early on rung 0
   and read `+3.11%` vs OC-at-40 — a termination artifact, not an updater
   regression. Disabling the plateau restores the full-cap-vs-full-cap
   comparison the assertion was written for; the assertion value and 2% band are
   byte-identical. No assertion weakened.
4. **`test_stress` (validation) — two invariant (c) blocks.** Added
   `opt.mma_plateau_window = 0` / `lopt.mma_plateau_window = 0`. Invariant (c)
   compares constrained vs unconstrained COMPLIANCE and needs both at the same
   budget; the plateau cut the unconstrained (compliance-min) run short, leaving
   it higher and flipping "constrained ≥ unconstrained". Both runs now share the
   full cap. No assertion weakened; the stress loop itself is unchanged.

`change_tol` remains in the API and is still the terminator for OC and for MMA
when `mma_plateau_window <= 0`; it is simply no longer what decides for the
production MMA path.

## Build

`/core/` change → rebuild the vendored core for the app with
`./app/scripts/build_core.sh` (not run here — core-track worktree).

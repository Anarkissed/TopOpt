# Adaptive move limit — outer-iterations Phase 1

**Task.** PR 193 ruled out the stopping rule as the outer-iteration lever (dead
tail 2-3%, deliberate) and named the real one: `SimpOptions::move` is FIXED at
0.2 for the whole MMA run (only β-damped on the projection stages), and the
design step is PINNED at that limit in 24-36% of outer iterations, concentrated
in the early forming phase and the high-β stages. Phase 1: make the move limit
ADAPTIVE — grow while the design moves productively, shrink when it oscillates —
reusing the Svanberg asymptote oscillation sign rather than inventing a second
signal, and MEASURE whether that cuts outer iterations without changing the
certified part or the gate.

**Verdict (honest, up front) — NO-GO on the 20% bar.** BUILT, safe,
byte-identical OFF, and it does exactly what it says — the move grows to its 0.5
ceiling in the productive phase and shrinks under oscillation. But the measured
outer-iteration reduction across four grids is **+2.1% / −0.6% / 0.0% / +0.2%**
(three loadcase sizes + a dilute design box) — noise-level, not the 20% the task
set, and not even reliably positive. It also perturbs the certified design above
the basin floor on at least one rung of every grid (gate-equivalent per M5, but
NOT design-equivalent per M4). The reason is mechanistic and is the core finding
of this phase: **the move-limit "pinning" PR 193 measured is largely
coincidental, not a throttle on convergence** — the natural MMA step is ≈0.2 in
the forming phase, so a larger trust region is simply not used, and outer-
iteration COUNT is set by the plateau + β-continuation structure, which a bigger
per-step trust region does not shorten. Shipped OPT-IN, default OFF; do not flip
it on. This is a measured NO-GO, not a production default.

---

## BLOCKED-STOP check — NOT blocked (feasibility is preserved)

> "If a larger move limit cannot preserve MMA's feasibility guarantee, STOP."

It can. A larger move never returns an infeasible iterate, for two independent
reasons, both visible in `mma_update*` (`simp.cpp`):

1. **Box feasibility.** The move only sets the trust box
   `alpha = max(xmin, L+albefa(x−L), x−move·xrange)`,
   `beta  = min(xmax, U−albefa(U−x), x+move·xrange)`. Whatever `move` is, the
   box is intersected with the **asymptote bracket** `[L+albefa(x−L),
   U−albefa(U−x)] ⊂ (L,U)` (albefa=0.1), so the iterate stays strictly inside
   the asymptotes where the separable approximation is finite and convex. A large
   move merely relaxes the trust region toward that bracket; it can never widen
   the box past it.
2. **Volume feasibility.** The single volume constraint is enforced by the dual
   bisection on λ, which is INDEPENDENT of the move box — `gval` is monotone in λ
   and the box only clamps the closed-form primal minimiser. The returned iterate
   is volume-feasible at any move.

The adaptive value is floored at `adaptive_move_min > 0` (validated), so `move`
is always strictly positive. The `test_adaptive_move` "feasibility" block asserts
box + per-iteration volume feasibility on a live adaptive run. **Feasibility, the
reason MMA is here, is intact.**

---

## What was built

Opt-in, MMA-only, default OFF (`SimpOptions::adaptive_move = false`).

- **The rule.** Each iteration, the fraction of design voxels that REVERSED
  direction this step is measured — `osc_fraction`, the aggregate of the SAME
  per-voxel sign `s = (xᵏ−xᵏ⁻¹)(xᵏ⁻¹−xᵏ⁻²)` the Svanberg asymptote adaptation
  already keys on (reused, not reinvented — PR 193 Q4's warning against a second,
  fighting accelerator). Above `adaptive_move_osc_hi` (0.30) → shrink by
  `adaptive_move_shrink` (0.7 = asydecr); below `adaptive_move_osc_lo` (0.15) →
  grow by `adaptive_move_grow` (1.2 = asyincr); hold in the dead band. Clamped to
  `[adaptive_move_min, adaptive_move_max] = [0.02, 0.5]`.
- **Seeding.** The adapted value is seeded to the stage's (β-damped) reference
  move for the first two iterations of each β stage (before two prior steps
  exist), then evolves. On each β advance the MMA state resets and the seed
  re-anchors to the new damped reference — so the deliberate high-β damping is the
  starting point the adaptation grows/shrinks from, not something it ignores.
- **Scope.** Both `simp_optimize` overloads (plain + masked; production runs the
  masked path). Oscillation is measured over the design set (solid voxels
  plain, Active voxels masked). Rejected with the OC updater and on the stress
  path (refused, not silently ignored — the 125 §0 discipline, same as
  `mma_projection`). The one internal OC-forcing path (`minimize_plastic`'s draft
  design-space probe) explicitly sets `adaptive_move = false`.
- **Observability.** `SimpIterationObservation` gains `move` (the limit the step
  used) and `osc_fraction` (−1 when the rule held the seed). Read-only.

Files: `core/include/topopt/simp.hpp` (options + observation),
`core/src/simp/simp.cpp` (`oscillation_fraction`, `adapt_move_value`,
`validate_adaptive_move_options`, both driver loops),
`core/src/simp/minimize_plastic.cpp` (draft-probe disable),
`core/tests/validation/test_adaptive_move.cpp` (M1 + feasibility + scope + wired).

---

## M1 — OFF is byte-identical to origin/main

`test_adaptive_move` runs the fixed path against a run with **every** adaptive
knob set to a non-default value but `adaptive_move = false`, on both overloads,
and asserts bit-identical iteration count, compliance, and design. All existing
optimizer suites pass unchanged (`test_mma` 39, `test_simp` 198,
`test_mma_projection` 23, `test_gate_v2` 72, `test_rung_infeasible` 61,
`test_warm_start_integration` 20). The default path builds no dof list, takes no
new branch, and reads the fixed reference move verbatim.

---

## M2-M7 — measurement (production posture, MMA + matrix-free MG, real ladder)

Harness: `core/tests/harness/adaptive_move_probe.cpp` (standalone, sanctioned
probe pattern; NOT wired into CTest). Three runs per grid — FIXED (adaptive OFF,
cg 1e-8), CONTROL (adaptive OFF, cg 1e-9 — the M2 basin floor), ADAPT (adaptive
ON, cg 1e-8) — on the production `production_reduction_ladder()`
{0.68,0.52,0.38,0.26} with `configure_production_options`.

### M2 — negative-control basin floor (tight vs tighter)
On every grid the FIXED-vs-CONTROL terminal design flips **ZERO** voxel
classifications on every rung (same as PR 193). **The basin floor is 0 class
flips** — any classification change ADAPT introduces vs FIXED is above the floor.

### M3 — outer iterations per rung, FIXED vs ADAPT (bar: ≥20% fewer)

| grid (part) | solid | rung0 | rung1 | rung2 | rung3 | Σ fixed | Σ adapt | reduction |
|---|---|---|---|---|---|---|---|---|
| 24×8×24 (small) | 2016 | 112→112 | 125→125 | 250→236 | 172→172 | 659 | 645 | **+2.1%** |
| 32×12×32 (medium) | 5376 | 146→146 | 147→147 | 160→160 | 183→187 | 636 | 640 | **−0.6%** |
| 40×16×40 (large) | 11200 | 143→143 | 143→143 | 162→162 | 239→239 | 687 | 687 | **0.0%** |
| box 40×8×40 (dilute) | 11552 | 221→222 | 269→269 | 224→225 | 116→112 | 830 | 828 | **+0.2%** |

**Below the 20% bar on every grid, and I say so — the reduction is noise-level
and does not scale.** Across the four grids the net change is +2.1% / −0.6% /
0.0% / +0.2%, i.e. it hovers around zero and is not even consistently positive.
The 2.1% on the small grid lives entirely in one long high-β structural rung
(rung 2: 250→236); at every larger scale it evaporates, and on the medium grid a
perturbed rung 3 runs 4 iterations MORE (net negative). Crucially the dilute
DESIGN BOX — the marathon regime PR 193 predicted "multiplies hardest" — gives
+0.2%: the lever does not bite there either.

### M4 — terminal design match, ADAPT vs FIXED (fraction of solid voxels flipping class)

Small grid, floor = 0:

| rung | vf | class-change frac | mean\|Δρ\| | max\|Δρ\| | solid | vs floor |
|---|---|---|---|---|---|---|
| 0 | 0.68 | 0.000 | 9.2e-8 | 1.5e-5 | 2016 | within floor |
| 1 | 0.52 | 4.96e-4 | 5.6e-4 | 0.53 | 2016 | **above floor** |
| 2 | 0.38 | 4.96e-3 | 6.0e-3 | 1.00 | 2016 | **above floor** |
| 3 | 0.26 | 0.000 | 5.3e-5 | 1.6e-2 | 2016 | within floor |

**M4 is NOT met at the strict floor.** ADAPT converges to a NEARBY but distinct
basin — up to 0.5% of solid voxels flip class (small grid rungs 1-2; the medium
grid flips rung 0 at 3.7e-4). It is a different (very close) part, not the same
part. This is the direct cost of a different trajectory and it must be named:
which rung gets perturbed is grid-dependent, but SOME rung always ends above the
basin floor.

### M5 — gate verdicts identical
On every rung of every grid, both runs ACCEPT, and the worst-case margins agree
closely (small grid within ~1-2%: 8.249/8.249, 7.602/7.596, 5.905/5.811,
3.702/3.702; large/box tighter, within ~0.1%). **The part certifies identically**
even though M4 shows it is not bit-identical — the M4/M5 tension the task
anticipated: gate-equivalent, not design-equivalent.

### M6 — mostly stable, with one realised cost (named)
The adapted move spans [0.02, 0.50] with mean ~0.30-0.36; mean `osc_fraction` per
rung is 0.12-0.21 (below the 0.30 shrink threshold most of the time, which is why
it mostly grows). No thrash / no runaway: the shrink branch damps the high-β
stages before they blow up, and on the small grid rung 2 (β=4, where the biggest
steps and the only savings both occur) converged in FEWER iterations.

**But the larger step is not free.** On the medium grid rung 3 ran **4 more**
iterations under ADAPT (183→187), and on the dilute box rungs 0 and 2 each ran
**1 more** (221→222, 224→225): the perturbed trajectory reaches the running-min
plateau slightly later, so the window-10 detector fires later. This is exactly the
cost the task told me to name — a larger step nudging the plateau detector to fire
late — and it is why the net medium reduction is negative and the box net is a
rounding-error +0.2%. It is small (a few iterations) but it is real and it
routinely cancels the forming-phase savings.

### M7 — trend across grid sizes
Four grids (three loadcase sizes 2016 → 5376 → 11200 solid, plus a dilute design
box at 11552). The iteration reduction is +2.1% → −0.6% → 0.0% (loadcase) and
+0.2% (box). **The trend is flat-to-negative: the win does NOT grow with scale,
and it does not appear in the dilute marathon regime.** The basin floor itself
grows with scale (0 at small/medium loadcase, 8.9e-5 at large, 6.1e-4 at the
box — bigger grids have more near-boundary voxels the cg tolerance alone can
flip), but on every grid at least one rung's ADAPT-vs-FIXED class-change fraction
exceeds even that larger floor. So the picture is scale-invariant in the way that
matters: ≈0% faster, always a slightly different (gate-equivalent) part.

---

## The mechanism (why the lever is small) — the core Phase-1 finding

From the per-iteration CSVs (`evidence/.../small_periter_*.csv`):

- **FIXED**: the max design step over the ENTIRE run is **0.1998** — the step is
  genuinely pinned at the 0.2 move limit, exactly as PR 193 measured.
- **ADAPT**: the move grows to the 0.5 ceiling, yet the design step ACTUALLY
  exceeds 0.2 on only **13 of 645 iterations** (max 0.441), and every one of those
  13 is inside rung 2's high-β structural-rearrangement stage.

So the "pinning" is mostly **coincidental**: in the forming phase the natural MMA
step magnitude is ≈0.2, so enlarging the trust region leaves the step unchanged
(the asymptote-bracketed convex-subproblem optimum is interior to the enlarged
box). Releasing the move only accelerates the small subset of iterations where the
subproblem genuinely wants a larger step — the aggressive structural toggles of the
high-β stages. And outer-iteration COUNT is governed by the plateau detector +
β-continuation structure (PR 193's finding), which a bigger per-step trust region
does not shorten. `change == move` is a symptom of the step magnitude, not proof
the trust region is the binding constraint on convergence.

This is why the honest answer is NO-GO: the measured throttle PR 193 found is
real, but relieving it buys ≈0% of iterations (−0.6% to +2.1% across four grids),
not 20%, and perturbs the certified basin doing it.

---

## Recommendation

Ship OPT-IN, default OFF (done). Do not flip it on in production: the win is
small and it changes the certified design (gate-equivalent but not
design-equivalent), which is a bad trade for ≈0%. If outer-iteration count is
pursued further, the lever is NOT the per-step trust region — it is the
β-continuation structure (44-59% of iterations, PR 193 Q1/Q3): fewer or cheaper
β stages, or a projection that needs fewer continuation iterations, is where the
count actually lives. A globalized quasi-Newton on the reduced (bound + single
volume constraint) problem — PR 193's other Phase-1 suggestion — remains
un-measured and is the next thing to try if the step direction (not its length)
is the target.

---

## Reproduce

```bash
cd core
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --target topopt -j8
# unit test (M1 + feasibility + scope + wired):
cmake --build build --target test_adaptive_move -j8 && ./build/test_adaptive_move
# measurement probe:
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
  tests/harness/adaptive_move_probe.cpp build/libtopopt.a -o build/adaptive_move_probe
OP_SPAN=24 OP_NY=8 OP_ARM=24 OP_T=6 AM_CSV_DIR=<dir> ./build/adaptive_move_probe          # small loadcase
OP_SPAN=32 OP_NY=12 OP_ARM=32 OP_T=8 AM_CSV_DIR=<dir> ./build/adaptive_move_probe         # medium
OP_SPAN=40 OP_NY=16 OP_ARM=40 OP_T=10 AM_CSV_DIR=<dir> ./build/adaptive_move_probe        # large
OP_SPAN=24 OP_NY=8 OP_ARM=24 OP_T=6 OP_BOX=1 OP_BOXMULT=1.6 AM_CSV_DIR=<dir> ./build/adaptive_move_probe  # dilute box
```

Evidence: `evidence/2026-07-26-adaptive-move-limit/` — `small_periter_{fixed,adapt}.csv`,
`small_summary.txt`, and the medium/large/box summaries.

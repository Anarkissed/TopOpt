# β-continuation schedule — Phase 0 (measurement, read-only)

**Task.** PR 193 showed 44-59% of outer iterations run AFTER the topology settles —
they are the Heaviside β-projection continuation crisping the boundary, so NOT
waste. PR 203 showed the iteration COUNT is set by the plateau detector and the
β-continuation STRUCTURE, not the move limit. So the β schedule (1→2→4→8→16→32) IS
the iteration budget. Nobody had measured whether it is the RIGHT schedule. This is
that measurement.

**Scope / B6.** Measurement only. NO production source changed, NO production default
touched. Every schedule ALTERNATIVE is expressed through EXISTING `SimpOptions` knobs
that already flow through the driver (`opt = options.simp` at
`minimize_plastic.cpp:508`): the continuation start `mma_projection_beta0`, the cap
`mma_projection_beta_max`, and the plateau-advance detector `mma_plateau_flat_windows`
/ `mma_plateau_tol`. The ×2 doubling FACTOR is the one thing hard-coded in
`simp.cpp:1743`; schedules with a different geometric ratio are therefore BRACKETED
with beta0-shift + single-jump runs rather than run directly (that gap is the first
Phase-1 item). Harness: `core/tests/harness/beta_schedule_probe.cpp` (standalone, NOT
wired into CTest — sanctioned probe pattern, à la `cg_tol_probe` / `outer_iter_probe`).

**What β continuation actually is (measured, not assumed).** Two facts that reframe
the task's own S3 wording:

1. **The shipped MMA advance is ALREADY adaptive, not fixed-count.** On the production
   MMA path (`simp.cpp:1721-1751`) β advances when the 086 objective-plateau detector
   fires on the *current* β stage's compliance curve, then doubles (capped at 32). The
   fixed "50 iterations per stage" in `heaviside_continuation_schedule()` is the OC
   path, which production does not use. So "advance when the design stops moving" is
   what production does; the lever is HOW AGGRESSIVELY the detector declares the stop
   (measured as `aggr` below), not adaptive-vs-fixed.
2. **β continuation fires CONDITIONALLY.** A rung is continued into β-projection only
   if its converged grayscale design-region Mnd exceeds 0.07 (handoff 123). On every
   grid here all four rungs fired and reached β=32, so the schedule question is live on
   every rung. On an already-crisp part no β stage runs at all and the schedule is moot.

---

## Q0 / B1. Negative control FIRST — the basin floor

Shipped schedule, two runs that SHOULD agree: `cg_tolerance` 1e-8 (baseline) vs 1e-9
(control). Terminal design difference per rung is the basin noise floor; every
cross-schedule difference below is reported both as a raw voxel-flip count and as a
multiple of this floor (B3: dims + solid count in every row).

| grid | solved dims | solid | basin floor (max class-frac / flips over rungs) |
|---|---|---|---|
| small | 16×6×16 | 672 | 1.49e-3 / **1 flip** (rung 3 only; rungs 0-2 = 0) |
| med | 24×8×24 | 2016 | 0 / **0 flips** (all rungs) |
| large | 32×10×32 | 4480 | 0 / **0 flips** (all rungs) |
| box (dilute) | 24×8×24 | 3456 | 1.27e-2 / **44 flips** (rung 3; rungs 0-2 = 0) |

The loadcase basin is tight (0-1 flip). The dilute DESIGN-BOX basin is much wider (44
flips on the light rung) — the stagnation regime is genuinely noisier, so its schedule
diffs must be read against ITS floor, which is why the ×-floor column matters there.

The floor is 0-1 voxel flips — essentially the PR 193 result (zero-flip basin) with a
single 1-voxel boundary jump on the lightest small-grid rung. So "materially different
design" = more than ~1 voxel flip; the schedule differences below are 2-142 flips, i.e.
above the floor by design. Every rung of every grid ACCEPTS at both tolerances (verdict
never moves with cg tolerance — B2 satisfied for the control).

---

## S1. What each β stage buys (shipped schedule, small grid; the pattern is identical med/large)

Per rung, per contiguous β stage: iterations, compliance in→out (Δc%, +=drop), voxels
crossing 0.5 during the stage, and the PROJECTED-field discreteness Mnd + min-feature
violations (the two measures projection exists to move). "gray" = the β=0 grayscale
phase before the conditional gate fires.

| rung | β | iters | c_in | c_out | Δc% | flips | Mnd_proj in→out | mfv_proj in→out |
|---|---|---|---|---|---|---|---|---|
| 0 | gray | 55 | 38.3 | 18.4 | **+52.0** | 318 | 0.80→0.37 | 36→202 |
| 0 | 1 | 25 | 22.9 | 18.1 | **+20.9** | 88 | 0.51→0.35 | 138→182 |
| 0 | 2 | 11 | 17.4 | 17.5 | −0.6 | 4 | 0.31→0.31 | 182→186 |
| 0 | 4 | 11 | 16.1 | 16.1 | −0.2 | 16 | 0.19→0.19 | 186→210 |
| 0 | 8 | 16 | 15.1 | 15.0 | +0.3 | 4 | 0.05→**0.05** | 210→210 |
| 0 | 16 | 12 | 14.9 | 14.8 | +0.2 | 2 | 0.02→**0.003** | 210→204 |
| 0 | 32 | 11 | 14.83 | 14.83 | 0.0 | 4 | 0.001→**0.001** | 204→204 |

(Rungs 1-3 same shape: gray = +70/+81/+87% compliance, β=1 = +41/+54/+66%, every
β≥2 stage within ±5% and usually slightly NEGATIVE — the discreteness-for-compliance
trade projection is supposed to make.)

**Reading it.**

- **Compliance is bought by gray + β=1, full stop.** Across all rungs the grayscale
  and β=1 stages capture essentially 100% of the compliance drop; every stage β≥2
  moves compliance by <5% and often makes it slightly WORSE (crisping costs a little
  stiffness). β stages do not exist to reduce compliance and do not.
- **Discreteness is bought by β=4→8→16.** Mnd_proj falls from ~0.37 (gray end) to
  ~0.003 almost entirely across β=4,8,16. That is exactly the range the conditional
  gate (threshold 0.07) exists to drive down — these stages earn their iterations.
- **β=32 (the last doubling) buys almost nothing.** Mnd_proj change AT β=32 is
  0.001→0.001 (r0), 0.009→0.002 (r1), 0.017→0.012 (r2), 0.014→0.005 (r3); mfv
  unchanged; compliance flat-to-slightly-worse. The field is already crisp when β=32
  starts. This is the S2 result seen from the stage side.
- **Honesty note — projection does NOT cure min-feature violations here.** mfv_proj
  RISES from grayscale (36) to the projected field (~200) and stays there through
  β=32: sharpening a blurred gray field manufactures thin sub-2-voxel members. Feature
  SIZE is controlled by the min-feature FILTER radius (2.5 mm), not by β. So the
  "min-feature measure the projection exists to improve" is, on this evidence, the
  wrong frame — Mnd is the measure β moves; mfv is not.

---

## S2. Is the last doubling worth it? (cap16 = β_max 16, cap8 = β_max 8)

`beta_max` is an existing knob; capping is byte-identical to the shipped run up to the
cap. Small grid (Σiters shipped = 614):

| schedule | Σiters | Δiters | gate verdicts | worst design diff | worst Δcompliance |
|---|---|---|---|---|---|
| **cap16** | 570 | **−44 (−7.2%)** | **IDENTICAL** (all rungs accept) | 2 flips (2× floor) | +1.14% (rung 3) |
| cap8 | 525 | −89 (−14.5%) | IDENTICAL | 10 flips (10× floor) | +8.78% (rung 3) |

- **Stopping at β=16 is a near-free ~7% iteration win.** Gate verdicts identical on
  every rung, terminal design within 2 voxel flips of the shipped design, terminal
  Mnd still crisp (0.003-0.028 vs 0.001-0.005), compliance cost ≤1.1%. This is the
  large-free-win the task asked S2 to test for, and it is real.
- **Stopping at β=8 is too aggressive.** Still gate-identical here, but compliance
  cost climbs to +8.8% on the light rung and terminal Mnd rises to 0.04-0.09 (visibly
  grayer, approaching the 0.07 gate). β=8 is where discreteness is still actively
  dropping (S1), so cutting it charges a real quality cost. The cut belongs after 16,
  not after 8.

---

## S3. Does the schedule need to be geometric? (fewer/larger jumps + adaptive advance)

All via existing knobs. Small grid:

| schedule | knob | Σiters | Δiters | gate verdicts | design diff | worst Δcompl |
|---|---|---|---|---|---|---|
| start4 | β0=4 (skip β=1,2) | 461 | −153 (−25%) | IDENTICAL | 36 flips (36× floor) | +1.6% |
| jump16 | β0=β_max=16 | 343 | −271 (−44%) | IDENTICAL | 34 flips (34× floor) | **+14.2%** (rung 3) |
| jump32 | β0=β_max=32 | — | — | **INFEASIBLE (small grid only)** | — | — |
| aggr | flat_windows 3→1 | 536 | −78 (−12.7%) | IDENTICAL | 11 flips (11× floor) | +0.26% |

- **jump32 is INFEASIBLE on the small grid — CG diverges — but FEASIBLE on med/large.**
  Jumping straight to β=32 from the gray field leaves a contrast so high that on the
  smallest/poorest-conditioned grid (672 solid) the matrix-free multigrid CG cannot
  reach tolerance in budget and the solve throws; on med (2016) and large (4480) the
  better-conditioned systems solve it (382 / 340 iters, gate-identical, but 92-142 flips
  and +6-8% compliance on light rungs). So the single-jump risk is SCALE/CONDITIONING
  dependent — gradual continuation is a solvability insurance policy that bites hardest
  on small/ill-conditioned grids (and, by extension, the dilute stagnation regime),
  not a universal law. It is still the wrong trade: even where feasible it degrades the
  design well past the basin floor for the same crispness the ramp reaches safely.
- **Bigger jumps (start4, jump16) save 25-44% but MOVE the design.** Both keep every
  gate verdict, but the terminal design is 34-36 voxel flips from shipped (34-36× the
  basin floor) and jump16 costs +14% compliance on the light rung. Per B2 a schedule
  that keeps all verdicts but visibly moves the design is a **borderline "different
  product"**, not a free win — it is a Phase-1 design decision (is a gate-passing but
  different structure acceptable?), with the gate as the only objective arbiter.
- **Aggressive adaptive advance (aggr) is the interesting middle.** Promoting β as soon
  as one flat window appears (vs the shipped three) keeps ALL stages and still reaches
  β=32, but spends fewer iterations idling at each stage: −12.7% (small) / −15.0% (med)
  / **−19.6% (large)** iterations — the saving GROWS with scale — gate-identical on all
  three, 11-48 flips, compliance within ±1%. It recovers most of the per-stage lag S4
  measures without changing the schedule's shape, and unlike the big-jump schedules it
  does not need the ramp's solvability insurance. It is the lowest-risk Phase-1 lever
  after cap16, and the two compose (cap16 + tighter advance).

---

## S4. Where the plateau detector sits inside a stage (per-stage lag)

193 measured the dead tail PER RUN at 3-5%. Measured PER β STAGE (iterations after the
last ≥1-voxel classification flip, summed over every stage), small grid:

| rung | per-stage lag | of iters |
|---|---|---|
| 0 | 57 | 141 |
| 1 | 52 | 133 |
| 2 | 38 | 139 |
| 3 | 29 | 201 |
| **Σ** | **176** | **614 (28.7%)** |

Across grids the per-stage lag is **28.7% (small) / 17.8% (med) / 18.0% (large)** — in
every case FAR above PR 193's per-RUN 3-5%.

**The lag COMPOUNDS across stages** — exactly the S4 hypothesis. Each β stage carries
its own ~5-11-iteration plateau-detector settling window (the deliberate 086 window-10
/ 3-flat-window lag), and with 7 stages per rung (gray + 6 β) that ~8-iter lag is paid
seven times. The per-RUN 3-5% (193) becomes ~18-29% per-STAGE because the detector
re-arms every stage. This is why `aggr` (shorten the per-stage settle) recovers 13-20%
and `cap16` (one fewer stage) recovers ~7% — both attack the compounded lag, from
different sides. (Caveat: the lag is measured on the design field's voxel flips; some
of those trailing iters still reduce Mnd on the projected field, so the lag is the
detector's settling cost, not pure dead time — which is exactly why `aggr` recovers it
gate-identically while a blunter truncation would not.)

---

## B4. Cross-grid trend

The PR 203 trap was a win that existed on one rung of one grid. The two headline
findings here hold on **every rung of all three grids**:

| grid | solid | Σit base | Σit cap16 | Δ% | cap16 verdicts | cap16 max flips | β=32 stage ΔMnd (r0..r3) |
|---|---|---|---|---|---|---|---|
| small | 672 | 614 | 570 | **−7.2%** | identical | 2 | .001→.001, .009→.002, .017→.012, .014→.005 |
| med | 2016 | 659 | 615 | **−6.7%** | identical | 2 | .001→.001, .001→.001, .006→.003, .005→.002 |
| large | 4480 | 607 | 563 | **−7.2%** | identical | 4 | .000→.000, .000→.000, .003→.000, .005→.001 |

**Trend statement.** (1) **cap16 is a stable, gate-identical ~7% iteration win at every
scale** (−7.2 / −6.7 / −7.2%), with the terminal design ≤4 voxel flips from shipped and
the compliance cost SHRINKING as the grid grows (worst-rung Δc +1.14% small → +0.44%
med → +0.26% large — the bigger the part, the more crisp the field already is when β=32
would start). (2) **β=32 changes projected Mnd by ~0.001 on every rung of every grid** —
its stage is along for the ride universally, not on one lucky rung. This is the opposite
of the PR 203 pattern: the win is scale-INDEPENDENT and rung-INDEPENDENT. The only
scale-DEPENDENT effect is jump32 feasibility (S3), which argues FOR keeping the ramp,
not against cap16.

### Dilute design-box (marathon regime) spot-check

A whole-domain design box (16×6×16 part in a 1.5× box → solved 24×8×24, **3456 solid**,
part ≈19% of the region — the void-heavy Jacobi-stagnation regime the 96³ marathon lives
in). All four rungs fired to β=32; β=32 stage ΔMnd = 0.0013→0.0009 / 0.0036→0.0023 /
0.0014→0.0007 / 0.0030→0.0030 (buys nothing, same as the loadcase). Schedule comparison
(base Σiters = 896):

| schedule | Σiters | Δiters | gate verdicts | design diff | ×floor | worst Δcompl |
|---|---|---|---|---|---|---|
| cap16 | 860 | −36 (−4.0%) | IDENTICAL | 42 flips | **1.0× floor** | −1.1% |
| cap8 | 819 | −77 (−8.6%) | IDENTICAL | 43 flips | 1.0× | +13.1% |
| jump16 | 479 | −417 (−47%) | IDENTICAL | 66 flips | 1.5× | +19.5% |
| aggr | 606 | −290 (−32%) | IDENTICAL | 121 flips | 2.8× | +2.6% |

**The strongest confirmation of the headline: in the dilute regime cap16's terminal
design difference (42 flips) is AT the basin floor (44 flips) — i.e. indistinguishable
from cg-tolerance noise — with identical gate verdicts.** Dropping β=32 is not merely
gate-safe in the marathon regime, it is within the solver's own noise. (The iteration
saving is smaller here, −4%, because the dilute regime's grayscale phase is
proportionally longer, so the β tail is a smaller share — but `aggr` recovers −32% by
tightening every stage's settle, and cap8 is still ruled out by its +13% compliance.)

---

## B5. Design-converged vs solver-got-cheap

Per-iteration solver telemetry (`cg_iters`, `mg_used`, `hier_built`, `mg_levels`) is in
every `periter_*.csv` row. On these loadcase grids multigrid stays healthy (mg_used=1)
and CG cost RISES with β (higher contrast → harder systems), so a stage ending is the
design plateauing, never the solver getting cheap — the two are cleanly separated, as
193 found. jump32's divergence is the extreme of the same fact.

---

## Verdict — the honest answer to the task's framing

The task named the answer that would end the fewer-iterations campaign: *if every β
stage moves the design materially and the schedule is near-minimal, say so.* The
measurement says something sharper and does NOT fully close it:

- **The last doubling (β=32) does NOT earn its iterations — on every rung of all three
  grids.** It changes projected Mnd by ~0.001 and compliance by ~0. Capping at β=16
  (`beta_max=16`, an existing knob) is a **gate-identical ~7% iteration win at all three
  scales** (−7.2/−6.7/−7.2%), terminal design ≤4 voxel flips from shipped, and the tiny
  compliance cost SHRINKS with scale. This is a real, safe, scale-stable Phase-1 change
  — the one to make.
- **The per-stage plateau lag compounds to ~18-29%.** Fewer stages (cap16, ~7%) OR a
  tighter per-stage advance (aggr, −13→−20%, gate-identical, saving grows with scale)
  both recover part of it. `aggr` is the next-lowest-risk lever and composes with cap16.
- **But the schedule is NOT freely compressible.** Larger geometric jumps (start4,
  jump16) save 25-44% yet move the design 34-114× the basin floor while merely keeping
  the gate verdict — a "different product" question for Phase 1, not a free win. And a
  single jump to β=32 is **infeasible on the small/ill-conditioned grid** (CG diverges;
  feasible-but-degrading on larger grids): the gradual ramp is load-bearing for
  solvability, not habit.

So — answering the task's "answer that would end this" directly: it is **NOT** true that
every β stage moves the design materially. Gray + β=1 own the compliance; β=4→8→16 own
the discreteness; **β=32 owns nothing**, uniformly across scale. The schedule is one
stage too long and somewhat too patient per stage, though its gradual SHAPE is justified
by solvability. Phase 1 should (1) drop β_max to 16 and re-gate the production ladder to
confirm gate-identity at full production scale (a small dilute box is confirmed here —
cap16 within the basin floor — but full 96³ is not), (2) measure the `aggr`
tighter-advance alongside, and (3) treat any
bigger-jump schedule as a design change requiring a fresh gate table, never a free
speedup. This is a modest, honest ~7-20% outer-iteration recovery, not the multiplier
the campaign hoped for; the per-solve-cost wins remain the larger prize.

**Not measured (Phase-1 targets).** (a) FULL 96³ scale in the dilute whole-domain
DESIGN-BOX regime — a SMALL dilute box is confirmed here (cap16 within the basin floor,
gate-identical), but the full marathon at production resolution should still be
re-gated, since projection fires hardest and jump32's conditioning risk is worst there.
(b) True larger geometric ratios (e.g. literal 1→4→16 ×4
doubling) — the ×2 factor is hard-coded in `simp.cpp:1743`; this Phase-0 bracketed it
with beta0-shift + single-jump runs but did not run it, because that requires a
production edit (out of scope by B6).

---

## Reproduce

```bash
cd core
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --target topopt -j8
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
  tests/harness/beta_schedule_probe.cpp build/libtopopt.a -o beta_schedule_probe
# one grid = base + negative control + 6 schedule variants, all production posture:
OP_SPAN=16 OP_NY=6 OP_ARM=16 OP_T=4 BS_CSV_DIR=<dir> ./beta_schedule_probe   # small
OP_SPAN=24 OP_NY=8 OP_ARM=24 OP_T=6 BS_CSV_DIR=<dir> ./beta_schedule_probe   # med
OP_SPAN=32 OP_NY=10 OP_ARM=32 OP_T=8 BS_CSV_DIR=<dir> ./beta_schedule_probe  # large
python3 evidence/2026-07-26-beta-schedule-phase0/analyze.py <dir>            # S1-S4/B1-B3
python3 evidence/2026-07-26-beta-schedule-phase0/cross_grid.py small med large  # B4 trend
```

Files under `evidence/2026-07-26-beta-schedule-phase0/`: `beta_schedule_probe.cpp`
(probe), `analyze.py` (per-grid reducer), `cross_grid.py` (B4), and `{small,med,large}/`
each with `periter_<schedule>.csv`, `summary.csv`, `run.log`.

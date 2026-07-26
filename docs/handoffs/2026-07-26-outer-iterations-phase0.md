# Outer-iteration count — Phase 0 (measurement, read-only)

**Task.** Every speed win banked so far cuts COST PER SOLVE (recycling, fast-fail,
P-core pin, Galerkin cache, warm-start, matrix-free, stagnation latch, Active
Domain, draft quality). None cuts HOW MANY SOLVES a rung takes. Before adding
another per-solve trick, measure whether the ladder's rungs stop too late — i.e.
whether the design has stopped changing MATERIALLY well before the run terminates.
A cut there multiplies with everything already banked.

**Scope.** Phase 0 is measurement only. No production default touched, no new
stopping rule, no move-limit edit. Everything below comes from two READ-ONLY
observer hooks that make a captured run byte-identical to an uncaptured one
(handoff 114), plus a read of the shipped MMA/penalty code.

---

## 0. Is instrumentation even possible? — YES, no production change (not BLOCKED-STOP)

Per-iteration design snapshots are already recoverable through hooks that exist and
are documented as byte-identity-safe:

- `SimpOptions::progress` / `MinimizePlasticOptions::on_iteration` →
  `SimpIterationObservation` per completed iteration: compliance, design
  `change` = maxₑ|xₖ₊₁−xₖ|, achieved vf, **CG iters, cg_used_multigrid,
  cg_hier_built, cg_mg_levels, cg_mg_cycles_attempted** (B3), active_fraction,
  plateau verdict, β, infeasible verdict.
- `MinimizePlasticOptions::on_density_snapshot` → the pinned PHYSICAL density
  field every iteration (`boundary=false`) + each rung's converged density
  (`boundary=true`). From consecutive physical fields we compute max|Δρ|,
  mean|Δρ| over solid voxels, and the **fraction of solid voxels changing
  classification** (ρ crossing 0.5) — the B1-mandated metric.

The harness that drives these: `core/tests/harness/outer_iter_probe.cpp`
(standalone, NOT wired into CTest, sanctioned probe pattern à la
`cg_tol_probe`). It runs the ACTUAL production posture
(`configure_production_options`: matrix-free MG, `min_feature_mm=2.5`, MMA,
conditional gray-gate projection, Krylov recycle k=16, AUTO active-domain band)
on the production `production_reduction_ladder()` = {0.68, 0.52, 0.38, 0.26}.

---

## Q0. Negative control FIRST — the basin noise floor

Two runs that SHOULD agree: identical production config, `cg_tolerance` 1e-8
(baseline) vs 1e-9 (control). Terminal design difference per rung (L-bracket
loadcase, 24×8×24, 2016 solid voxels):

| rung | vf | class-change frac (1e-8 vs 1e-9) | mean\|Δρ\| | max\|Δρ\| | base iters | ctrl iters |
|---|---|---|---|---|---|---|
| 0 | 0.68 | **0.000** | 1.3e-12 | 1.3e-9 | 112 | 112 |
| 1 | 0.52 | **0.000** | 1.0e-5 | 1.1e-2 | 125 | 125 |
| 2 | 0.38 | **0.000** | 1.4e-4 | 1.2e-1 | 250 | 250 |
| 3 | 0.26 | **0.000** | 1.5e-9 | 7.4e-7 | 172 | 172 |

**The basin floor is ZERO classification flips.** Basin noise perturbs individual
voxel densities by up to max|Δρ|=0.12 (rung 2, voxels near the 0.5 boundary) but
flips NO voxel's printed/void classification, and both runs terminate at the
identical iteration count. **Therefore the material-change threshold used
throughout Q1 is ≥ 1 voxel flip** — any classification change between consecutive
iterations is above the floor. (Graded fractions 0.1%/0.5%/1% of solid are also
reported to separate real topology change from single-voxel boundary jitter.)

Evidence: `evidence/2026-07-26-outer-iterations-phase0/periter_cg1e-8.csv`,
`periter_cg1e-9.csv`.

---

## Q1. Is the run stopping too late?

### Method
For each rung of the baseline (1e-8) run, per iteration: max|Δρ|, mean|Δρ|,
compliance, class-change fraction — all computed from consecutive physical-density
snapshots on the solved grid (dims + solid count travel with every fraction, B1).
"Materially stops changing" = the last iteration with ≥1 voxel flip (Q0 floor);
graded thresholds locate where TOPOLOGY (≥0.5% of solid) settles vs where only
single-voxel jitter remains.

### Loadcase regime (24×8×24, 2016 solid — healthy multigrid)

| rung | outer iters | grayscale ends | last ≥1-vox flip | last ≥0.5% flip | GAP (stop − last flip) | flat+frozen dead tail | move-limit-bound iters |
|---|---|---|---|---|---|---|---|
| 0 | 112 | 33 | 93 | 34 | 19 | 10 | 25 |
| 1 | 125 | 40 | 122 | 42 | 3 | 3 | 43 |
| 2 | 250 | 139 | 245 | 140 | 5 | 3 | 126 |
| 3 | 172 | 73 | 163 | 151 | 9 | 1 | 44 |
| **Σ** | **659** | — | — | — | **36 (5%)** | **17 (3%)** | **238 (36%)** |

Reading it:

1. **The strict dead tail is small — 3-5% of all outer iterations.** The number of
   iterations after the last single-voxel flip (36 of 659 = 5%), and the number
   with zero flips AND compliance flat to <1e-4 (17 of 659 = 3%), are both small.
   This tail is essentially the **window-10 plateau detector's inherent lag** — it
   needs 10 flat running-min iterations before it will declare a plateau (handoff
   086 deliberately made the window that long to survive member-toggle spikes). So
   the run is NOT stopping grossly late; there is no large free win in the stopping
   rule alone.

2. **44% of iterations run after the topology has settled — but they are not
   waste.** The last ≥0.5% classification flip is at iter ~34 on rung 0 (end of the
   grayscale phase), yet the rung runs to 112. Those 78 iterations are the
   conditional Heaviside β-projection continuation (handoff 123): they drop rung-0
   compliance from 12.2 to 10.82 (−11%) while barely flipping any voxel — they are
   crisping the boundary, which is exactly what conditional projection is FOR.
   Cutting them reverts to the gray design the projection gate deliberately chose to
   sharpen. This is a real cost but it is not a "stopping too late" cost.

### Design-box regime (dilute — the 96³ marathon posture)

Same L-bracket wrapped in a whole-domain design box (solved grid 32×8×32, **4056
solid voxels**, part ≈ 17% of the design region — the void-heavy dilute regime the
96³ marathon lives in). Q0 negative control here ALSO flips zero voxels (basin floor
= 0), so the same ≥1-voxel material threshold applies. One honest wrinkle: rung 3
ran 104 iters at 1e-8 vs **105** at 1e-9 — cg tolerance can move the plateau by a
single iteration (classification identical either way).

| rung | outer iters | grayscale ends | last ≥1-vox flip | last ≥0.5% flip | GAP (stop − last flip) | flat+frozen dead tail | move-limit-bound | terminated on |
|---|---|---|---|---|---|---|---|---|
| 0 | 194 | 79 | 185 | 80 | 9 | 7 | 50 | plateau |
| 1 | 192 | 62 | 183 | 63 | 9 | 6 | 38 | plateau |
| 2 | 199 | 97 | 195 | 99 | 4 | 1 | 60 | plateau |
| 3 | 104 | 104 (no projection) | 86 | 39 | 18 | 1 | 19 | plateau |
| **Σ** | **689** | — | — | — | **40 (6%)** | **15 (2%)** | **167 (24%)** | — |

Same shape as the loadcase, sharper: the strictly dead tail is even smaller (**2%**),
while the share of iterations after topology settles is even larger (**59%** — the
dilute regime has more boundary to crisp, so more β-projection). **Every rung
terminates on the plateau detector, not the 200 cap** (the cap is per-β-stage; the
loadcase rung 2 runs 250 total across stages and still plateau-stops). Rung 3 — the
lightest, vf 0.25 — stayed PURE grayscale (β never rose; the gray-gate found it crisp
enough), and it carries the biggest single-rung tail: 18 iters after the last voxel
flip, a gentle grayscale settle with no ≥1% step ever.

### B3 — "did the design converge, or did the solver get cheap?"

Per-iteration solver telemetry (mg_used, hier_built, CG count) says the solver did NOT
get cheap as the design settled — it got MORE EXPENSIVE, cleanly separating the two:

| regime · rung | mg_used frac | CG min/mean/max | CG early-third → late-third |
|---|---|---|---|
| loadcase · 0 | 1.00 | 50 / 94 / 187 | 84 → 104 |
| loadcase · 2 | 0.45 | 59 / 449 / 1117 | 243 → 589 |
| loadcase · 3 | 0.00 | 554 / 798 / 1427 | 766 → 797 |
| box · 0 | 1.00 | 67 / 145 / 265 | 114 → 194 |
| box · 2 | 0.00 | 289 / 674 / **8758** | 891 → 634 |
| box · 3 | 0.00 | 314 / 870 / 8386 | 1607 → 504 |

CG cost RISES late in most rungs (higher β → higher material contrast → harder
systems), and on the lightest / most dilute rungs multigrid collapses to Jacobi
(mg_used = 0) with CG exploding to hundreds–thousands of iterations per solve — the
stagnation regime (125/128) the 96³ marathon lives in. Two consequences: (a) the
small dead tail is made of EXPENSIVE solves, so trimming it is worth slightly more
than its iteration-% suggests; (b) any reduction in OUTER iterations multiplies
hardest exactly here, where each solve is most costly.

### Real-scale cross-check: the committed 96³ design-box run
`core/tests/fixtures/infeasible/iterations_96_designbox.csv` is a real production
marathon (compliance + solver telemetry, NO density — so it cannot answer the
classification question, only compliance). It is PURE grayscale MMA (β=0 — this run
predates conditional projection) and rung 0 = **146 iterations**. It is not directly
comparable iter-for-iter to my probe (my probe runs current production, which adds
the conditional β-projection continuation the 96³ run never had), but it anchors the
scale: a real dilute rung is O(150) grayscale iterations, and my dilute box rung 0 is
79 grayscale + projection to 194 — same order, same regime. Compliance behaviour:

- rung 0 running-min compliance is within 10% of its final by iter 72, within 1% by
  iter 109, within 0.1% by iter 136. The detector-style last-improving iteration
  (window 10, tol 1e-3) is **145 of 146** — i.e. the running-min compliance keeps
  improving (by >0.1%/window) essentially to the end, which is WHY the detector runs
  the full 146. The last ~25% of the rung buys the final <1% of compliance.
- Whether that final <1% is real topology change or boundary polish CANNOT be read
  from compliance alone — it needs density snapshots, which this fixture lacks. That
  is the density-instrumented design-box measurement above (my probe), and the
  Phase-1 target at full 96³ scale.

Solver telemetry (B3) matters here: the 96³ design-box run has `cg_multigrid=0` on
EVERY iteration (multigrid never coarsened; all Jacobi-CG at 4.5k–12k CG iters/solve
— the stagnation regime, 125/128). So on the reference marathon the solver did NOT
"get cheap"; it got EXPENSIVE. Any per-iteration read there is dominated by CG cost,
not design motion — reinforcing that fewer OUTER iterations, if available, would
multiply hardest exactly in this regime.

---

## Q2. MMA move limits and asymptotes

Source: `core/src/simp/simp.cpp` `mma_update` (≈L940–1083) and `mma_continuation_move`
(L127).

- **Move limit — FIXED.** `SimpOptions::move` (default 0.2) is a constant for the
  whole run on the plain path. Applied as the box `alphaₑ = max(ρ_min, L+0.1(xₑ−L),
  xₑ−move·xrange)`, `betaₑ = min(1, U−0.1(U−xₑ), xₑ+move·xrange)`, xrange = 1−ρ_min ≈
  0.999. So the max per-iteration design step is ≈ 0.2. The ONLY adaptation is on
  the β-projection continuation stages: `move_eff = move·min(1, 8/β)` → 0.1 at β=16,
  0.05 at β=32 (damped to stop high-β structure-splitting oscillation). It is NOT
  adaptive to trajectory progress.
- **Asymptotes — ADAPTIVE** (Svanberg 1987, standard `mmasub`). `asyinit=0.5`,
  grow `asyincr=1.2` / shrink `asydecr=0.7` on the oscillation sign
  `(xᵏ−xᵏ⁻¹)(xᵏ⁻¹−xᵏ⁻²)`, each asymptote clamped to [0.01, 10]·xrange of the current
  point; initialised ±0.5·xrange for iterations ≤ 2.
- **Is the optimizer throttled by its own limit late in a rung?** The per-iteration
  design step `change` (= maxₑ|Δxₑ|) is captured directly. On the loadcase ladder
  **238 of 659 iterations (36%) have the max step pinned at the (possibly damped)
  move limit**, concentrated in (a) the early grayscale forming phase and (b) the
  high-β projection stages. Concretely on rung 0: `change` = 0.20 (at the cap) for
  the first ~16 iters, relaxes to ~0.05–0.13 through grayscale, then is pinned at
  exactly **0.100 at β=16** and **0.050 at β=32** — the damped caps — for the entire
  final projection stages. So yes: the leading edge of the design is step-limited for
  a large share of the run, most starkly during high-β projection. This — not the
  stopping rule — is where the per-iteration step is being throttled, and it is the
  natural Phase-1 lever (step size / acceleration), which is why Q4 was asked.

---

## Q3. SIMP penalty continuation

- **SIMP penalty p = 3.0, FIXED. There is NO penalty continuation.** `params.penalty`
  is set exactly once (`minimize_plastic.cpp:300`, `= 3.0`; `SimpParams` default is
  also 3.0) and is thereafter only READ, in E(ρ)=ρᵖ·E₀ and its derivative
  (`simp.cpp:137/363/437-439/2836`). It is never ramped, on any trigger, in any loop.
  So there is no p-schedule, no "iterations spent at each p".
- **The only continuation in the system is the Heaviside PROJECTION sharpness β**
  (1→2→4→8→16→32, `heaviside_continuation_schedule`), which sharpens the smoothed
  threshold on the FILTERED density for discreteness/crispness — it is NOT the SIMP
  material-penalization exponent. On the production MMA path β-projection fires
  CONDITIONALLY: after a grayscale rung converges, only if its design-region
  discreteness Mnd exceeds the gray threshold is the SAME rung continued into β
  continuation (handoff 123); each β stage advances on its own objective plateau,
  capped at 32, with the move damping above.
- **Does the design move during each β stage?** Yes — materially. On rung 0 the
  β-continuation drops compliance 12.2→10.82 (−11%); on the 16³ cross-check rung 3
  drops 88→40 across β 0→16, with the design step pinned at the move limit. The β
  stages are re-optimizing under a sharper projection, not merely thresholding a
  frozen field. (This is the same 44%-of-iters-after-topology-settled observation as
  Q1, viewed from the penalty/projection side.)

---

## Q4. Anderson-acceleration feasibility (assessment only — NOT implemented)

The design update is a fixed-point iteration xₖ₊₁ = G(xₖ), where G is one MMA
subproblem solve (filter the compliance sensitivity → adapt asymptotes L,U → build
the separable convex subproblem → dual bisection for the single volume multiplier →
box-clamped new x). At a KKT point G(x*) = x*, so AA is structurally applicable.

**State that would have to be stored.** AA with memory m keeps the last m residuals
fᵢ = G(xᵢ)−xᵢ and the last m iterates (or G-values), each a length-N_design vector →
≈ 2·m·N doubles. On the part grid N is small (negligible). On a 96³ whole-domain box
(~2M design voxels) at m=5 that is ~160 MB of extra live state — non-trivial in the
exact regime where memory is already the binding constraint (the reason the
matrix-free solver exists: the assembled K OOMs at ~7 GB). Manageable but not free.

**Cost per iteration.** AA does NOT add FEA solves — it reuses the one G-evaluation
(one penalized solve) MMA already does. Its arithmetic is m² length-N dot products +
a tiny m×m least-squares solve — utterly negligible next to a multigrid solve. So the
overhead is memory, not flops.

**Known failure modes for a constrained optimizer like MMA (why it is a poor match):**
1. **Feasibility is destroyed by the affine mix.** AA's xₖ₊₁ = Σαᵢ G(xₖ₋ᵢ), Σαᵢ=1
   with αᵢ free in sign, does not respect the box [ρ_min,1] or the volume constraint.
   MMA's entire value is that every subproblem solve returns a box-AND-volume-feasible
   iterate; AA extrapolation discards that and requires a projection (clip+rescale)
   every step, and G∘projection is a different, non-smooth map for which AA's
   convergence theory (Toth–Kelley) no longer holds.
2. **G is non-stationary and nonsmooth.** MMA's map CHANGES every iteration: the
   asymptotes L,U move (grow 1.2 / shrink 0.7 by the oscillation sign) and the active
   set of box constraints changes. AA assumes a fixed contraction G; applying it
   across a moving map degrades or diverges.
3. **It fights MMA's own damping.** The asymptote adaptation IS a feasibility-preserving
   acceleration/oscillation-damper already. AA induces the oscillation the asymptote
   logic then contracts against — they work at cross purposes.
4. **Non-monotone spikes get amplified.** MMA compliance spikes on member toggles
   (the plateau detector uses running-min precisely for this). AA combining pre- and
   post-toggle iterates mixes different branches and tends to amplify the spike.
5. **Ill-conditioning exactly where a win would live.** Near the plateau the residual
   differences become linearly dependent → the AA least-squares is ill-conditioned →
   α blows up → wild steps. Tikhonov/column-filtering are mandatory, and this is the
   regime (the settling tail) where the hoped-for iteration cut would come from.

**Assessment.** AA is applicable in principle but poorly matched to MMA specifically:
non-stationary map + mandatory feasibility projection break its theory, and the
near-plateau regime is where it is least stable. It is not the first lever. If the
goal is fewer outer iterations, the measured throttle (Q2: 36% of iterations
step-limited) points instead at the STEP itself — an adaptive/larger move limit in
the throttled phases, or a globalized quasi-Newton on the reduced (bound+single-
constraint) problem — as lower-risk directions to prototype and measure in Phase 1.

---

## Verdict (the honest answer to the task's framing)

The task named the finding that "would end this": if the design is still moving
materially at the last iteration of every rung, the runs are not too long and only a
better optimizer helps. The measurement says something more precise:

- **There is NO large free win in the stopping rule** — in EITHER regime. The
  strictly dead tail (no classification change AND flat compliance) is 3–5% of outer
  iterations on the healthy-MG loadcase and 2% on the dilute design box, and it equals
  the deliberate window-10 lag of the plateau detector (086). Every rung of both
  ladders terminates on the plateau detector, not the cap. A stopping rule that also
  watched classification-flips could shave those ~3–19 iters/rung (biggest on a pure-
  grayscale rung: box rung 3, 18 iters), but it is small and must be weighed against
  086's toggle-safety; it is a minor tidy-up, not the multiplier the task was hunting.
- **Most "post-settle" iterations are productive**, not late: 44% (loadcase) / 59%
  (design box) of iterations run after topology settles, but they are the β-projection
  crisping stages doing real work (compliance −11% on rung 0), by design.
- **The genuine per-iteration lever is the STEP, not the STOP** (Q2): the max design
  step is pinned at the move limit in ~24% (box) to ~36% (loadcase) of iterations,
  worst in the early forming phase and the high-β stages. Fewer outer iterations, if
  they exist, come from moving faster per step — an adaptive move limit or
  acceleration — a Phase-1 optimizer question. Where it multiplies hardest is the
  dilute design-box marathon regime (all-Jacobi, 4.5k–12k CG/solve) the 96³ reference
  lives in.

Phase 1, if pursued, should prototype an adaptive move limit (measured against the
Q2 throttle) before Anderson, and re-run this density-instrumented gap measurement at
full 96³ design-box scale to confirm the loadcase result carries into the marathon
regime.

---

## Reproduce

```bash
cd core
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --target topopt -j8
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
  tests/harness/outer_iter_probe.cpp build/libtopopt.a -o outer_iter_probe
# loadcase (healthy MG):
OP_SPAN=24 OP_NY=8 OP_ARM=24 OP_T=6 OUTER_PROBE_CSV_DIR=<dir> ./outer_iter_probe
# design-box (dilute, marathon posture):
OP_SPAN=16 OP_NY=6 OP_ARM=16 OP_T=4 OP_BOX=1 OP_BOXMULT=1.6 OUTER_PROBE_CSV_DIR=<dir> ./outer_iter_probe
python3 <dir>/analyze.py <dir>/periter_cg1e-8.csv <solved_solid_count>
```

Files: `outer_iter_probe.cpp` (probe), `analyze.py` (Q1/Q2/B3 reducer),
`periter_cg1e-{8,9}.csv` (loadcase), `box/periter_cg1e-{8,9}.csv` (design-box),
`analysis_loadcase.txt`, `analysis_box.txt`.

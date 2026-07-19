# 110 — Warm-start the solve: rung inheritance + coarse-to-fine cascade

**Track:** core. **Territory:** `/core/` only — `src/simp` (ladder loop + init),
a new Eigen-free upsample/restrict util (`warm_start.{hpp,cpp}`), `pipeline.hpp`
options, tests. No bridge, no app, no CLI schema, no Gate-V2, no fixtures/benchmarks.
**Builds on:** 054/066 (MMA switchover), 086 (MMA plateau termination), 080/104
(part-relative ladder), 091 (peak memory = the iteration-0 build transient).

## Summary

Two opt-in warm starts that cut solve **iterations** (never peak memory):

- **(A) Rung inheritance** (`warm_start_inherit`): the ladder walks heaviest →
  lightest, so rung k+1 now starts from rung k's **converged** density (rescaled to
  the lighter target, clamped, one filter pass) instead of uniform grey — it carves
  further from a good design instead of rediscovering it.
- **(B) Coarse-to-fine cascade** (`warm_start_coarse`): before the ladder, solve the
  **same** effective problem at **res/2** (an ordinary `simp_optimize`, its own guard
  rails), trilinear-upsample the converged density to the fine grid, and seed the
  first fine rung. The coarse solve's iterations are reported
  (`result.warm_start_coarse_iterations`) and **counted** in every claim below.

**STEP 0 established the fact:** rung k+1 previously started from **uniform grey**
(`simp_uniform_density(grid, options.volume_fraction)` — [simp.cpp](../../core/src/simp/simp.cpp)
inside each overload's init), reconstructed fresh from `SimpOptions opt =
options.simp` per rung in the ladder loop
([minimize_plastic.cpp](../../core/src/simp/minimize_plastic.cpp)). No inheritance
existed. Part A was needed.

**Headline (both features, L-bracket loadcase / self-weight block, MMA, 4-rung
ladder):**

| run | L-bracket total iters | self-weight total iters |
|---|---|---|
| cold (baseline) | **326** | **460** |
| warmA (inherit) | 171 (−48%) | 281 (−39%) |
| warmB (coarse only) | 276 fine + 29 coarse = **305** (−6%) | 438 fine + 59 coarse = **497 (+8%)** |
| warmAB (both) | 107 fine + 29 coarse = **136 (−58%)** | 233 fine + 59 coarse = **292 (−37%)** |

Wall-clock (this Mac, −O2): L-bracket 0.79 s → **0.29 s (warmAB, −63%)**;
self-weight 8.0 s → **4.7 s (warmAB, −42%)**.

**Honesty up front — two things go in the headline, not a footnote:**

1. **warmB *alone* is marginal, and on self-weight it *raised* the raw iteration
   count (460 → 497).** The coarse pre-solve only warm-starts **rung 0**; when rung
   0's savings don't repay the coarse solve's iterations, the grand total goes up.
   It still nets a small *wall* win (coarse iters run at ~1/8 the fine DOF count, so
   59 coarse iters ≈ 7 fine-equivalent; wall −2%), but as an iteration count it is a
   wash-to-loss. **Its real value is compounding with A (warmAB).**
2. **Warm starts converge to a DIFFERENT local optimum** — expected, not a bug (the
   initialization changed). Characterized below. The **accept gate is untouched**:
   every warm rung was certified exactly as cold, and on both fixtures **every rung
   still passed** (margin ≥ margin_stop), with terminal margins within noise.

**Peak memory is UNCHANGED (say it plainly).** Per handoff 091 peak memory is the
iteration-0 build transient, and it **recurs on every rung** regardless of the
starting field. Warm starting removes iterations from the *middle* of each solve; it
does not shrink the transient. **This does not revive Fine-on-iPad.** The coarse
pre-solve's transient is smaller (1/8 DOF) but the fine rungs each still pay the full
fine transient.

**THE ONE RULE holds:** both default OFF; with both off the driver takes the uniform
init in both `simp_optimize` overloads and never builds a coarse grid — byte-for-byte
identical to the pre-110 driver. Proven structurally (the init is a branch on
`initial_design.empty()`) and empirically (the cold numbers above are bit-identical
to the pre-change baseline). Gate-V2 untouched and green.

---

## STEP 0 — the fact, and the baseline every claim is measured against

`minimize_plastic`'s ladder loop builds `SimpOptions opt = options.simp` fresh each
rung and calls `simp_optimize(G, params, B, loads, opt, mask)` with **no** carried
density; both `simp_optimize` overloads initialize the design **uniform at
`options.volume_fraction`** on every design voxel. So **rung k+1 started from grey,
not from rung k's field.** Inheritance was absent → Part A implemented.

Cold baseline (unmodified code, this Mac, MMA, plateau termination, ladder
{0.68, 0.52, 0.38, 0.26}, margin_stop 1.5):

```
L-BRACKET LOADCASE (8x3x8, 84 solid):   rung iters [76, 77, 84, 89] = 326, 0.79 s
SELF-WEIGHT BLOCK  (16x8x8, 1024 solid): rung iters [70,118, 95,177] = 460, 8.0 s
```

**Amdahl ceiling (named before measuring):** the only win here is *iterations saved ×
s/iter* — there is no other lever. For Part A, rung 0 has no predecessor, so its
cold cost (76 / 70 iters) is a floor the inheritance win cannot cross; Part B's coarse
pre-solve attacks exactly that rung-0 floor but pays its own (cheaper) iterations to
do so. The measured warmAB (−58% / −37% grand-total) sits inside that ceiling.

---

## What changed

- **`SimpOptions::initial_design`** (new, default empty). Empty → uniform start
  (byte-identical). Non-empty → a raw grid-indexed density seed; `simp_optimize`
  (both overloads) rescales its mean over the design set to `volume_fraction`, clamps
  to `[density_min, 1]`, and applies **one pass of the loop's own filter** to form
  x0 (`warm_start_design` helper in [simp.cpp](../../core/src/simp/simp.cpp)). Frozen
  pins are reapplied exactly as the uniform start applies them. This changes ONLY the
  initialization — same loop, filter, FEA, updater, termination.
- **`warm_start.{hpp,cpp}`** — pure geometry, Eigen-free, in the always-built base
  library: `coarsen_grid` (dims (n+1)/2, spacing ×2, tag priority Load>Fixture>solid),
  `restrict_density` (block average), `prolong_density` (trilinear upsample, same
  centre convention as `resample_field`), `coarsen_bcs` / `restrict_loads` (force
  conserved) / `coarsen_mask`.
- **`minimize_plastic`** — Part A carries each rung's converged density into the next
  rung's `initial_design` (when `warm_start_inherit`); Part B runs the res/2 pre-solve
  on the coarsened effective problem and seeds rung 0 (when `warm_start_coarse`). The
  rung-vf adjustment is factored into an `effective_vf` lambda so the coarse target
  matches rung 0 exactly. With both flags off, `warm_seed` stays empty the whole
  ladder → uniform init every rung.
- **`MinimizePlasticResult::warm_start_coarse_iterations`** — the coarse pre-solve's
  iteration count, so no speedup claim can hide it. 0 when the feature is off.
- **`pipeline.hpp`** — `warm_start_inherit`, `warm_start_coarse` options (both false).

## Cold vs warm — the different-optimum characterization

Terminal-rung density difference vs cold (mean |Δρ| over the solved grid):

| | L-bracket | self-weight |
|---|---|---|
| warmA | 0.0013 (≈ identical design, just faster) | 0.197 (different optimum) |
| warmB | 0.000 (rungs ≥1 start uniform → bit-identical to cold) | 0.000 |
| warmAB | 0.162 (different optimum) | 0.167 (different optimum) |

- **warmB terminal is bit-identical to cold** because with inheritance off it seeds
  ONLY rung 0; the terminal rung starts uniform exactly as cold. (Rung 0's own design
  *does* shift — e.g. L-bracket rung-0 margin 9.83 → 7.18, a weaker-but-still-safe
  different optimum — but rung 0 is not the terminal rung here.)
- **warmA / warmAB reach a materially different design** (mean |Δρ| ~0.16–0.20) at
  **comparable margins** — no rung dropped below margin_stop, terminal margins within
  ~1% either direction (some higher, some lower). **No rung was ever WORSE on
  margin or savings beyond noise.** Savings are identical (every rung hits its volume
  target: achieved ≈ requested to 1e-3, as the volume constraint enforces).

**Determinism:** verified — cold twice and warmAB twice are byte-for-byte identical
(same iters, same densities). Both features are deterministic (fixed seed math, fixed
filter, no RNG/time).

## Tests (raw ctest below)

- `warm_start` (unit, no Eigen, 30 checks): upsample operator correctness
  (trilinear on a known ramp; constant → constant exact; **mean conserved** within
  tolerance; restrict→prolong round-trip), block-average restrict, grid/BC/load/mask
  coarsening (force conservation, tag priority, dedup).
- `warm_start_integration` (Eigen, 15 checks): **parity** (cold deterministic +
  defaults OFF), **structural skip** (warmB rungs ≥1 byte-identical to cold),
  **iteration reduction** (warmA & warmAB total < cold with the **accept gate still
  passing on every rung**), **determinism** (warmAB twice identical).

## Production flip — NOT done here (evidence first, separate task)

Both features stay OFF. A production-flip task can wire the two flags CLI/bridge-side
and decide defaults. Evidence to weigh: **warmA is the reliable iteration win**
(−48%/−39%, near-identical designs on the load-case fixture); **warmB alone is
marginal-to-negative** and should only ship compounded with A; the coarse cascade's
benefit grows with grid size (the rung-0 floor is a larger share at higher res) —
measure on a production-size grid before flipping B.

## Scope / untested edges (honest)

- **Part B on the design-box path is structurally supported but NOT measured.** The
  coarse pre-solve coarsens the *effective* problem (the already-expanded `G` / mask
  / loads), so an align-8 fine grid coarsens to a multiple-of-4 grid — fewer
  multigrid levels than the box path's 3, though the coarse solve still runs (and
  falls back gracefully). Both fixtures here are **no-box** load-case / self-weight
  runs. Measure a box run before relying on warmB there.
- Both fixtures are small (≤1024 voxels). The coarse cascade's benefit **grows with
  grid size** (rung 0's cold cost is a larger share at higher res, and the coarse
  solve's 1/8-DOF discount is larger in wall terms). These numbers are a floor, not a
  ceiling, for production grids — but that too is unmeasured here.

## Do NOT

- Resurrect Fine-on-iPad from this. Peak memory is unchanged (091); warm starting
  cuts iterations, not the per-rung build transient.
- Run concurrently with the Metal task — both touch the shared options structs.

## Raw ctest

Full suite: **100% tests passed out of 52** (Total 176.96 s). Key regression +
new tests (targeted re-run):

```
 1/10 Test #10: resample .........................   Passed    0.14 sec
 2/10 Test #11: warm_start .......................   Passed    0.05 sec
 3/10 Test #24: simp .............................   Passed   40.81 sec
 4/10 Test #27: gate_v2 ..........................   Passed   51.45 sec
 5/10 Test #28: property_v3 ......................   Passed    2.27 sec
 6/10 Test #29: variants .........................   Passed    4.54 sec
 7/10 Test #31: minimize_plastic .................   Passed   17.48 sec
 8/10 Test #38: ladder_rung_count ................   Passed    5.16 sec
 9/10 Test #39: warm_start_integration ...........   Passed    3.34 sec
10/10 Test #44: mma_projection_gate ..............   Passed    0.86 sec
100% tests passed out of 10
```

Harness (not CTest): `tests/harness/warm_start_probe.cpp` produced every cold/warm
number in this handoff — build with:
`c++ -std=c++17 -O2 -I include -I <eigen> -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" tests/harness/warm_start_probe.cpp build/libtopopt.a -o warm_start_probe`

# 128 — MG fallback economics + plateau escape (the certain wins from 125's ranking)

**Track:** core only. **Territory:** `/core/` (`src/fea`, `src/simp`, `src/cli`,
headers, tests). **NO app, NO bridge.** **Builds on:** 125 (diagnosis, READ-ONLY)
and 127 (the walk-back + per-run stagnation latch). Ships the four remedies 125's
Q3 ranked as certain wins, minus what 127 already landed or disproved.

**Handoff number:** `docs/handoffs/` tops at **127** (126 is a gap; verified vs the
worktree HEAD *and* open PRs — none open). This takes **128**.

**Gates (all green):** full `ctest` **60/60**. Healthy-run byte-identity holds
(cli_demo + production/clearance/face-protection parity all pass). THE ONE RULE:
every solver change lives in the fallback policy/config and is inert where MG
carries; the plateau escape is the one deliberately-sanctioned termination change
(item 4), guarded so the 086 fixtures stay caught.

---

## What shipped (four items)

### 1. MG iteration budget 100 → 300, with a per-attempt wall-clock guard
`multigrid.cpp`. `kMgIterBudget` 100 → **300**. 125 measured a BORDERLINE band of
real systems whose V-cycle contracts but slowly (~120–300 cycles, Jacobi converged
in ≤20 k so the operator is well-posed) that bailed to Jacobi at budget-100; at 300
they CARRY. Healthy grids converge in ~11–40 cycles — far under both budgets — so
raising the ceiling is **byte-identical** for them (the budget is never reached).
The pathological end (occ0.4+hole; 125 §1d) still does not converge even at 2000,
so it still bails — but at most 3 times before the 127 latch stops building.

Added `kMgAttemptWallGuardSec = 90.0`: a per-attempt wall-clock backstop
(`std::chrono::steady_clock`, checked each cycle in both `mgpcg` and `mf_mgpcg`) so
tripling the cycle budget cannot triple the worst-case wasted time on a
pathologically slow grid. It is a **coarse safety net set far above the converging
envelope**, NOT a within-solve fast-fail: 127 measured that no early residual/rate
signature separates slow-but-converging (rel. resid 2–8 @ iter 15, converges by
~60–90) from stagnating, and the binding rule is never to abandon a solve MG would
have solved — so there is **no within-solve early-bail** (127's finding, cited, not
re-attempted). The guard keys on wall time, so it is the ONE non-deterministic
cutoff; but it only fires on a grid too slow to finish even the bounded budget, and
the field it then produces (exact Jacobi fallback) is deterministic. Converging
solves never reach it. `0` disables it.

### 2. Adaptive early CG tolerance (opt-in, trajectory-only)
`simp.hpp` + `simp.cpp`. New `SimpOptions::cg_tolerance_loose` (default **0 =
disabled → byte-identical**). When set to a loose value (e.g. 1e-3), the INTERIOR /
trajectory penalized solves solve only to a tolerance interpolated between loose
and the tight `cg_tolerance`, on a deterministic schedule keyed to the design's
recent motion (`adaptive_traj_cg_tol`: log-linear in the previous iteration's
max|Δρ|, loose while moving ≥ the move limit, tightening to `cg_tolerance` as the
design settles). The **ACCEPT / FINAL** compliance solve and every stress/margin
solve ALWAYS use the tight `cg_tolerance`, so the **certificate is untouched** (the
110 warm-start precedent — trajectory changes, certified output does not). Wired
into both `simp_optimize` overloads.

### 3. Observability — build-rejection vs stagnation is now a direct read
`CgInfo` gains `hier_built` + `mg_cycles_attempted` (populated in both the
matrix-free and assembled MG paths). Forwarded through `SimpIterationObservation`
into **two new `iterations.csv` columns** `hier_built,mg_cycles_attempted` (golden
`test_observability` + `test_observability_capture` updated same commit).
`run_info.json` gains **`mg_mode`**: `"carried"` / `"stagnated-latched"` /
`"build-rejected"`, finalized post-run (null until observed / when the solver is
not MG), from a new `MinimizePlasticResult::mg_hierarchy_ever_built` tally. This
closes 125 §0: `cg_multigrid=0` with `hier_built=1` is **stagnation**; `hier_built=0`
is **build-rejection** (or the 127 latch). No reconstruction needed next time.

### 4. Plateau flatness escape (guarded)
`mma_objective_plateau` gains `min_flat_windows` (SimpOptions
`mma_plateau_flat_windows`, default **3**; `0` = exact pre-128 behavior). When the
086 min_drop gate is CLOSED (total descent < min_drop) — the regime 125 found,
where the objective is flat almost from the start and the run cap-walks for hours —
a plateau may fire on **flatness alone** once the running minimum has been flat
(sub-tol) across the last `min_flat_windows × window` samples. It is measured over
the trailing `3×window` running-min improvement, which is **strictly stronger** than
the single-window test the predicate already applies (the running min is monotone),
so the escape can NEVER fire earlier than the gated detector would once the gate
opens — it only ADDS firing in the gate-never-opens + long-flat case. Gated on
flatness, **never a bare iteration count**, so the spike-heavy forming phase can't
trigger it. New `test_simp` cases prove: (a) a <5%-descent flat run fires only with
the escape on and only after ≥3 flat windows; (b) the 086 spike fixtures are
**unchanged** (same fire point with the escape on); (c) a descending curve still
never plateaus.

---

## Evidence (measured; iteration counts are deterministic, thermal-independent)

Scratchpad probes (the 113/125 precedent — not committed), Release `libtopopt.a`,
production entry point `fea_solve_mgcg_matfree`.

**(A) Budget-300 rescues the borderline band** — 1e-9 checkerboard, tol 1e-6:

```
 n=16  used_mg=1  mg_cycles=118  CARRIES   (was fallback at budget 100)
 n=20  used_mg=1  mg_cycles=214  CARRIES
 n=24  used_mg=1  mg_cycles=297  CARRIES
 n=28  used_mg=0  mg_cycles=300  fallback  (still stagnates past 300)
 n=32  used_mg=0  mg_cycles=300  fallback
```
At budget-100 all five fell back; at 300 the 120–300-cycle band carries — exactly
125's predicted borderline. (This is also why `test_coarsen_rule`'s latch fixture
moved 16³ → 32³: 16³ now carries.)

**(B) Adaptive tol cuts the fallback per-solve cost** — stagnating 32³ checker,
matrix-free Jacobi-CG iterations vs tolerance:

```
 tol=1e-3   jacobi_cg_iters=207
 tol=1e-4   jacobi_cg_iters=292
 tol=1e-6   jacobi_cg_iters=368
 tol=1e-8   jacobi_cg_iters=440
```
Loosening the trajectory tol 1e-8 → 1e-3 is **2.1× fewer** CG iters/solve (validates
125 remedy iv's 2–5× on a higher-conditioned production field). The accept/final
solve stays at 1e-8 (440, exact) → certificate untouched.

**(C) End-to-end** — L-bracket @48, `MultigridCG_Matfree`, self-weight ladder:
`run_info.json` → `"mg_mode": "carried"`, `cg_multigrid: true`, `mg_levels: 3`;
`iterations.csv` → new columns present, `hier_built=1`, `mg_cycles_attempted` =
75/70/…/221/204 (== cg_iters when MG carries). Byte-identical report (cli_demo
passes) — this healthy run never touches the new fallback/escape paths.

**Not run to completion here:** a full production 128³ design-box + clearance run to
single-digit-hours confirmation (hours-long; the 125 precedent left the analogous
2000-cycle probe to the maintainer). The Amdahl projection stands on the measured
micro-evidence above + 125 §5: budget-300 carries the borderline real runs (removing
the per-iter build + Jacobi grind), the latch caps the pathological end at 3 doomed
builds, and where MG still cannot carry, adaptive tol (opt-in) cuts each trajectory
Jacobi ~2× and the plateau escape stops the flat-from-start cap-walk — together the
19 h → single-digit hours 125 predicted, without touching the numerics.

---

## Out of scope (own task later)
The (v-a) **stronger smoother** (Chebyshev / colored Gauss-Seidel) — gated on
whether borderline stagnation persists after budget-300 on real runs. Do NOT build
it until a real run shows the n≥28-style pathological band still bites in production.

## Reproduce
`cmake --build core/build -j8 && (cd core/build && ctest -j8)` → 60/60.
Evidence probes: compile `ev_probe.cpp` / `stag_probe.cpp` against `build/libtopopt.a`
(recipe as 125 §4).

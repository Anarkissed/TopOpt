# 122 — Multigrid silently fell back to Jacobi-CG on non-coarsenable grids

**Track:** core + CLI. **Territory:** `/core/` (`src/fea`, `src/voxel`, `src/simp`,
`src/cli`, `src/settings`, headers, tests). **NO app change, NO bridge change.**
**Builds on:** 079 (design-box coarsening padding), 117 (per-iteration CSV that
made the bug measurable), 106 (the 10-hour forensic that this finally explains).

---

> ## ⚠️ WALK-BACK (handoff 127) — the central FIX in this handoff was reverted
>
> A res-128 loadcase+box+clearance **production** run on the build shipped here
> (fingerprint `92e702008a9b`) **falsified the premise** the fix rested on. The fix
> — escalating the design-box pad to force the grid coarsenable — does **not**
> address the production slowness:
>
> - That job's grid at the fixed align-8 floor is **232×64×216 (NOT coarsenable)**;
>   PR #151's escalation grew it to **240×64×224 (coarsenable)**. So multigrid
>   **built** a hierarchy there — and then **stagnated**, falling back to Jacobi-CG
>   on **every one of 158 iterations** (`cg_multigrid=0` throughout, ~7–10 min/iter,
>   stuck in rung 0 for 19.4 h). The real failure is **CONVERGENCE STAGNATION** on
>   the ~1e-9-contrast field with a large clearance void — the adversarial-coefficient
>   regime `multigrid.cpp` already warns about — which **no amount of padding fixes**.
> - Worse, forcing the build was **net-negative**: it converted a cheap
>   build-fast-fail into an expensive build-then-stagnate-then-Jacobi every solve
>   (measured ~2.5× slower per stagnating solve on a 64³ probe).
>
> **What remains TRUE here** (do not over-correct): the coarsenability RULE itself
> (`mg_grid_coarsenable`) and the fixture-scale flip are correct — a grid that
> genuinely cannot coarsen *does* fall back. The error was **extrapolating that
> relevance to the production job**, whose grid coarsens once escalated yet still
> fails for a different reason. The rule/predicate are retained (documentation +
> future gate); only the *escalation of the pad* was withdrawn.
>
> **The original 128³ bracket run's "non-coarsenable" diagnosis (§ below,
> `cg_multigrid=0` on 535 iters) is now UNVERIFIED.** The CSV cannot distinguish a
> build-REJECTION (non-coarsenable) from a build-then-STAGNATE; that run's grid was
> never reconstructed. Do not read the sections below as confirmed for it — and do
> not replace one confident story with its mirror.
>
> **Shipped by the walk-back (127):** the pad reverts to the fixed align-8 floor;
> the solver gains a stagnation **fast-fail + per-run latch**; `run_info.json`
> `cg_multigrid` is emitted as **null until observed** (an earlier bug wrote the
> optimistic intent `true`, which misdiagnosed this very run). The observability and
> honesty-rider from this handoff are kept. See **handoff 127** for the two real
> blockers this leaves open (MG convergence; the plateau-stop that never fired).

---

**Handoff-number note:** `docs/handoffs/` tops at 121; the next free number is
**122**. A memory note references a "122" remote-result-fields lane in a separate
worktree — same collision pattern as the two "121"s. This is the core/CLI lane.

---

## The bug, in one line

The production geometric-multigrid solver (`MultigridCG_Matfree`) **silently fell
back to Jacobi-CG** whenever the solved grid could not be coarsened under the
multigrid DOF cap — and the maintainer's instrumented 128³ box run proved it fires
in production: `iterations.csv` showed **`cg_multigrid=0` on all 535 iterations,
CG 1400–5000 per solve, 11.5 h wall**. A ~4× slowdown, reported nowhere. Silent
slowdowns violate the honesty principle exactly like wrong numbers do.

---

## 1. REPRODUCE + NAME — the coarsenability rule

### Why the run fell back (the rule)

`build_hierarchy` / `build_mf_hierarchy` (`src/fea/multigrid.cpp`) coarsen the grid
by **halving every element axis per level**, stopping at the first axis that is odd
or would drop below `kMinCoarseElems=2`. The coarsest level is solved by a **direct
factorisation**, so it is capped at `kCoarseDofCap = 6000` DOFs; a hierarchy whose
coarsest level exceeds that cap is **rejected** (returns empty / `false`), and the
solver falls back to Jacobi-CG.

A grid rounded to a multiple of **8 (=2³)** guarantees only **3 halvings**. The
coarsest of those 3 levels has ≈ `N / 8³` elements — whose DOF count blows past
6000 once `N` (total elements) is large, i.e. **at res ≈128 with a design box**.
The real requirement is therefore not "each extent is even" but:

> **each extent's 2-adic divisibility DEPTH must be ≥ the number of MG levels
> needed to bring the coarsest level under the DOF cap** — and that depth GROWS
> with grid size, so the padding alignment must be **computed, not fixed**.

### The maintainer's job (l-bracket-large, res 128, design box)

The exact voxel extents depend on the (private) part's bounding box, which sets the
voxel spacing (`longest_part_extent / 128`). From handoff 106's box dimensions
(**183.5 × 100.4 × 125.4 mm**, ≈4.8–5.4 M voxels), a representative solved extent is
**≈183 × 100 × 125 voxels**. Rounded to the old fixed align-8 that is
**184 × 104 × 128**, whose limiter is **104 = 8·13** (2-adic depth **exactly 3**):

| level | element dims | coarsest node DOF (≈ 3·nodes) |
|---|---|---|
| 0 (fine) | 184 × 104 × 128 | — |
| 1 | 92 × 52 × 64 | — |
| 2 | 46 × 26 × 32 | — |
| 3 | 23 × **13** × 16 | 24·14·17·3 = **17 136 > 6000** → REJECT |

`y=104` goes **odd (13)** after exactly 3 halvings, so coarsening cannot continue,
the coarsest level is 17 k DOF > the 6000 cap, `build_hierarchy` returns empty, and
every solve of the run runs Jacobi-CG. That is `cg_multigrid=0` for 535 iterations.

### Empirically confirmed (the solver's own `used_multigrid`)

A probe over solid grids (the pure-arithmetic predictor `mg_grid_coarsenable`
mirrors the solver's real `CgInfo::used_multigrid`, DOF-for-DOF):

| grid | predict | used_mg | levels | CG iters |
|---|---|---|---|---|
| 104³ (align-8, coarsest 8232 DOF > cap) | not coarsenable | **0** | 0 | ∞ (Jacobi) |
| 112³ (align-16, coarsest 1536 DOF ≤ cap) | coarsenable | **1** | 5 | **7** |
| 96×80×96 (079 baseline, align-8) | coarsenable | 1 | 4 | 9 |
| 41×40×40 (odd axis) | not coarsenable | **0** | 0 | ∞ |

This is exactly the task's "CG iters collapse (~2000 → ~100-class)": 104³ grinds
thousands of Jacobi iterations; 112³ converges in **7** MG iterations.

**Why 079 worked at res 64 but not 128:** at 96×80×96 the 3-halving coarsest is
13·11·13·3 = **5577 ≤ 6000** — align-8 was *just* enough. Double the resolution and
the same 3 halvings leave ~35 k DOF. Align-8 was never a rule; it was a size-64
coincidence.

## 2. FIX — pad to coarsenable extents at the SEAM (one rule, both front-ends)

The rule now lives in **one** header, `topopt/coarsen.hpp` (pure integer math, no
Eigen — safe to include from the always-built voxel TU and the Eigen-gated
multigrid TU):

- `kMgMinCoarseElems`, `kMgCoarseDofCap`, `kMgMinLevels` — the **source of truth**;
  `multigrid.cpp` now derives its `kMinCoarseElems`/`kCoarseDofCap`/`kMinLevels`
  from these, so the SOLVER and the SEAM can never drift.
- `mg_grid_coarsenable(ex,ey,ez)` — mirrors the coarsening loop, upper-bounds coarse
  DOF by `3·nodes` (conservative: a `true` is never optimistic).
- `required_coarsen_align(rx,ry,rz, floor_align)` — the **smallest power of two
  ≥ floor** for which rounding all three extents to that multiple yields a
  coarsenable grid.

`expand_design_domain` (`src/voxel/voxelize.cpp`) now computes the raw extents, then
`align = required_coarsen_align(raw…, coarsen_align)`, and rounds each axis to that
common power-of-two by **appending Empty voxels on the HIGH side only** (079's
mechanism). `kDesignBoxCoarsenAlign = 8` is now the **floor**, not the value: the
computed align grows to 16/32 for the large grids that align-8 left broken, and
stays 8 for every grid that already coarsened (byte-identical). The driver and
`minimize_plastic_solved_grid` both call the same seam, so the app and CLI padding
are now literally the same rule (the task's "one rule, both front-ends").

Seam evidence (`required_coarsen_align`, floor 8):

```
raw  90x 78x 91 : align-8 ->  96x 80x 96 coarsenable=1 | adaptive align= 8 -> UNCHANGED
raw 183x100x125 : align-8 -> 184x104x128 coarsenable=0 | adaptive align=16 -> 192x112x128 coarsenable=1
raw 200x136x184 : align-8 -> 200x136x184 coarsenable=0 | adaptive align=16 -> 208x144x192 coarsenable=1
raw 235x128x160 : align-8 -> 240x128x160 coarsenable=1 | adaptive align= 8 -> UNCHANGED   (no over-pad)
raw 104x104x104 : align-8 -> 104x104x104 coarsenable=0 | adaptive align=16 -> 112x112x112 coarsenable=1
```

**Byte-identity (079 precedent, the "must not change the design space" guard).**
`test_coarsen_rule` expands a design box at floor-8 (→align-8) and floor-16
(→align-16) on a case coarsenable at both, and proves the extra padding is inert:
identical Active/FrozenSolid/FrozenVoid **design-space counts**, and — through a
JacobiCG optimize on both — **`|Δvf| = 0` and `max|Δρ| = 0` (bit-exact)** over the
common region. The deeper pad only adds void voxels the DOF gate removes.

## 3. LOUD FALLBACK — the fallback is now REPORTED

`MinimizePlasticResult` gains `used_multigrid` / `mg_levels`, aggregated across the
run's optimize solves. **A single solve is not representative** — the first
iterations of a rung start near-uniform and MG can stagnate past its 100-cycle
budget and fall back even on a perfectly coarsenable grid (the demo does exactly
this: 3 of 90 iterations fall back). So `used_multigrid` is reported true only when
MG carried the **majority** of solves; that cleanly separates the **coarsenability
bug** (MG never engages — the maintainer's 535/535) from benign early stagnation.

- **`run_info.json` gains `"cg_multigrid"` and `"mg_levels"`.** Written up-front as
  the requested INTENT (true iff a multigrid solver was asked for), then
  **overwritten post-run** with the observed outcome, so a completed run's record
  states what MG *actually did*.
- **The CLI prints a WARNING** to stderr when a multigrid solver was requested but
  fell back:
  `WARNING: multigrid solver "MultigridCG_Matfree" fell back to Jacobi-CG on the
  NxNxN solved grid … expect a ~4x slowdown. … run_info.json records
  cg_multigrid=false.`
- The per-iteration `iterations.csv` `cg_multigrid` column (117) is unchanged; a new
  `SimpIterationObservation::cg_mg_levels` feeds the aggregate.

This exposure is already earning its keep: the **48³ self-weight demo** reports
`cg_multigrid=true, mg_levels=3` (87/90 iterations MG — no false alarm), while a
**30³** self-weight grid (odd after one halving) reports `cg_multigrid=false,
mg_levels=0`. Both verified in `test_coarsen_rule` (§Part 4).

## 4. REPORT HONESTY RIDER

**(a) Gate-rejected variants no longer vanish.** `VariantReport` gains `accepted`,
`margin_required` (the `margin_stop` threshold) and `margin_effective` (the
infill-adjusted worst-case margin actually compared at the gate). `JobReport` gains
a `rejected` vector; `report.json` gains a **`rejected_variants`** array (always
present, `[]` when the whole ladder was accepted). The `variants` array keeps its
accepted-only contract (≈20 tests depend on it), so this is purely additive. The
maintainer's "rung 3" now appears with `accepted:false` and its
margin-vs-required numbers instead of silently disappearing.

**(b) The report's infill lie.** `run_info.infill_percent` (the job's actual infill,
which drives the margin knockdown) and the report's `settings.infill_percent` (the
rules engine's margin-derived recommendation) **disagreed** — the maintainer saw
run_info 30 / report 15. The report was the liar: a part gated at 30% infill was
told to slice at 15%, invalidating its own accepted margin. **Fix:** when the job
requests sparse infill (`options.infill_percent < 100`, so the knockdown is active),
the report's `settings.infill_percent` now **echoes the job's infill** — the value
the margin was gated for and that run_info records. At solid/unset infill (100) the
knockdown is a no-op and the engine recommendation stands, so every existing run is
byte-identical (the demo still reports 15).

## Evidence / gates

- **Before→after on a small non-coarsenable box:** `cg_multigrid` 0→1, CG iters
  collapse (thousands → **7**), design **bit-identical** where domains match
  (`test_coarsen_rule`).
- **All 56 core tests green** (incl. gate_v2, cli_demo, production_parity, and the
  new `coarsen_rule`).
- New: `test_coarsen_rule` (37 checks: rule, byte-identity, the flip, loud-fallback
  reporting). Extended: `test_minimize_plastic` (rejected_variants + infill echo),
  `test_observability` (run_info cg_multigrid/mg_levels schema).

## For the maintainer

- **Re-run the 128³ overnight** as production confirmation. Expected: MG engages
  (run_info `cg_multigrid=true`, `mg_levels≈4–5`), CG collapses to the ~10–30/solve
  regime, wall-clock in **hours, not 11.5** — no WARNING line.
- **App:** unaffected (no bridge/view change). `report.json`'s new `rejected_variants`
  array and per-variant `accepted` field are additive; a future app change can
  surface rejected rungs and the honest infill. Swift `Codable` ignores the new keys
  today.
- **No-box res-128 self-weight** still lacks padding by design (this fix pads the
  design-box seam; the no-box path aliases the caller's grid). It is no longer
  *silent*: such a run now emits the loud fallback (run_info + WARNING). Padding the
  no-box path is a larger, higher-blast-radius change left for a follow-up.
- **`kCoarseDofCap`/`kMg*` tuning** now lives in one place (`coarsen.hpp`); raising
  the cap or the smoother budget is a one-line change the seam automatically tracks.

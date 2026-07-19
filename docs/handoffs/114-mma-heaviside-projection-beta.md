# 114 — MMA Heaviside projection + β-continuation ("finish the design")

**Track:** core. **Territory:** `/core/` only — `src/simp/simp.cpp` (the two
`simp_optimize` loops + new MMA-projected updaters), `include/topopt/simp.hpp`
(the opt-in options), one new validation test. No bridge, no app, no CLI schema,
no fixtures/benchmarks, **no change to `production.cpp`** (the production flip is
a separate later decision — see below). **Builds on:** 031 (M6.3 OC Heaviside
projection + β-continuation), 054/066 (MMA switchover), 068 (`mma-skip-projection`
gate), 086 (MMA plateau termination), 104 (two-basis volume reporting), 110
(warm start).

## Name the ceiling first

This is a **design-QUALITY and HONESTY** change, **not a speedup**. Projection
adds β-continuation stages, so **wall-clock INCREASES**: on the cantilever
fixture, plain MMA converges in **54** iterations and MMA+projection takes
**154–210** (≈3–4×). That is the price of a printable, honest design; nobody
should mistake this for a performance win.

## Summary

`enable_projection` existed but MMA (the production updater since 066) skipped
it: the OC-locked `projection` schedule throws under MMA (068's gate), so real
MMA runs shipped a **grayscale** field. Measured consequence: production
discreteness Mnd ≈ 0.27 vs Gate-V2's projected ≈ 0.015, and the continuous-vs-
printed volume divergence (102/103) — up to ~0.09 at light rungs — **is** that
grayness (a wide sub-threshold density fringe carries real mass in Σρ but 0 in
`#{ρ>0.5}`).

This task adds the **MMA-correct** Heaviside projection as a NEW opt-in,
`SimpOptions::mma_projection` (default **false**), entirely separate from the
OC-locked `projection` schedule:

- **Smoothed Heaviside** (tanh, η = `projection_eta` = 0.5) on the FILTERED
  field. The **projected** density ρ̄ = `heaviside_project(filter(x), β, η)`
  drives BOTH the stiffness AND the volume constraint (the constraint sees what
  prints, not the fog). The MMA compliance and volume sensitivities gain the
  projection chain-rule term dρ̄/dρ̃ **before** the filter transpose — exactly as
  `oc_update_projected` chains it, but folded into the MMA moving-asymptote
  subproblem (`mma_update_projected` / `mma_update_masked_projected`).
- **β-continuation** reusing the **086 plateau detector's machinery** (no rival
  invented): β starts at `mma_projection_beta0` (≈1), and whenever
  `mma_objective_plateau` fires over the CURRENT β stage's compliance curve, β
  **doubles**, capped at `mma_projection_beta_max` (default 32). **Termination**
  is a plateau at the final β — composing with 086. `max_iterations` is the
  whole-run safety cap across all stages.
- **High-β move damping** (`mma_continuation_move`): move × min(1, 8/β), i.e. the
  exact OC-schedule damping (0.2 for β≤8, 0.1 at 16, 0.05 at 32). Undamped high-β
  moves oscillate (structure-splitting) and never plateau — measured: the final
  stage ran to the iteration cap without it.
- **Stage-aware progress gate:** 086's `min_drop` gate guards ONLY the first
  (β0) stage — its spike-heavy forming phase from the uniform/warm start is what
  the gate exists to survive. Later stages start from a formed design (no forming
  spikes) and often improve less than `min_drop`, so keeping the gate would block
  their plateau and run the final stage to the cap; they use pure flatness there.

## THE ONE RULE

`mma_projection` defaults **false** → the MMA loop is the unchanged
M7.mma.1/M7.mma.4 grayscale formulation, **byte-for-byte identical** (structural
+ empirical parity: the OFF path never touches the new updaters, and the test
proves an OFF run with the β knobs set is bit-identical to plain MMA). **Gate-V2
untouched** (it is OC + the `projection` schedule — a different field and code
path, unchanged). The **projection-gate test** (`mma_projection_gate`) is
**untouched and green**: MMA + the OC `projection` schedule STILL throws — see
"The gate" below. **`production.cpp` is unchanged**, so every production front-end
stays byte-identical; turning `mma_projection` on in production is a **separate
later decision**, to be made with this task's evidence.

## The gate (`mma_projection_gate`) — no silent edit

`test_mma_projection_gate` pins that the run path does NOT enable the OC-locked
Heaviside `projection` **schedule** under MMA: `projection_supported(MMA)==false`
and `simp_optimize` throws on `MMA + non-empty options.projection`. **All of that
is preserved verbatim.** This task does not relax the gate — it adds an
*orthogonal* mechanism (`mma_projection`, a bool, with its own MMA-correct
chain-rule) that the gate never referenced. `validate_updater_options` (the
throw the gate checks) is unchanged; a new `validate_mma_projection_options`
enforces the new field's rules (MMA-only; mutually exclusive with the
`projection` schedule; valid β range; rejected on the stress path). The gate test
passes bit-identically (10/10, same crisp/compliance numbers) before and after.

## Evidence

Cantilever fixtures (Gate-V2 family, filter 2.5 voxels, JacobiCG). "gray" = plain
MMA; "proj" = `mma_projection`; "OC-ref" = OC + the locked continuation schedule.

**Headline — 24×8×8, vf 0.30 (β cap 64):**

| metric | gray MMA | MMA+proj | OC-ref (locked) |
|---|---|---|---|
| discreteness **Mnd** | **0.559** | **0.032** | 0.070 |
| volume-basis divergence \|Σρ − #{ρ>0.5}\| | **0.0265** | **0.0005** | 0.0138 |
| compliance | 88.1 | **38.1** | 41.1 |
| iterations | 54 | 210 | 244 (fixed 300-cap) |
| min-feature 2×2×2 violations | — | **364** | 370 |

- **Mnd 0.56 → 0.032** clears the ≤ 0.05 headline; MMA+proj **beats** the
  accepted OC-ref (0.070) on this fixture on Mnd, divergence AND compliance.
- **Volume-basis collapse (interaction c, the honesty payoff): 0.0265 → 0.0005**
  (a 53× collapse). This is the headline: the constraint now measures what
  prints, so `volume_fraction` and `printed_fraction` (104's two bases) agree.
- **Min-feature (interaction d): 364 ≤ OC's 370** on the same fixture. The 2×2×2
  count does NOT go to zero under projection on these coarse meshes — a KNOWN
  property of single-field projection (benchmarks.json `honest_limitations`,
  368/288 for locked OC) — but MMA-proj stays **within OC's accepted regime**
  (no worse than the shipped OC path), the design-field 2.5-voxel filter scale is
  untouched, and M5.2b's report warning remains the user-facing backstop. The
  2.5 mm contract holds as strongly as it does for OC.

**Default β cap = 32** (conservative — matches OC's tested cap; 64 is excluded by
the OC lock as "destroys the structure"). At cap 32 the coarse cantilever reaches
Mnd ≈ 0.075 (within the benchmarks.json `discreteness_Mnd_max = 0.1` accepted for
this fixture); the ≤ 0.05 headline is reached at cap 64, and — per benchmarks.json
— app-scale (48–128) grids with proportionally wider members reach it at 32.
Light rungs (vf 0.15) are **iteration-bound**: they exhaust `max_iterations`
before climbing to the sharpest β (β-64 and β-32 runs were byte-identical there —
64 is *safe*, simply never reached), so raising the cap does not destroy thin
structure; the safety cap backstops, exactly as 086 does.

**Determinism:** the projected run reproduces byte-for-byte twice (verified in
the test).

**|Δρ| vs unprojected** (24×8×8 vf 0.30): max ≈ 0.57, mean ≈ 0.22 — projection
genuinely moves the boundary fringe to 0/1, which is why compliance drops (the
gray fringe was soft, ρ³-penalized material).

**Cold AND warm through `minimize_plastic`** (L-bracket load-case, 2-rung ladder
{0.60, 0.45}, MMA, min_feature 2.5 mm, β cap 32). Iterations per rung / total,
and terminal-rung Mnd:

| run | rung 0.60 | rung 0.45 | total it | rung Mnd (0.60 / 0.45) |
|---|---|---|---|---|
| gray cold | 105 | 71 | **176** | 0.388 / 0.405 |
| gray warm | 105 | 28 | **133** (−24%) | 0.388 / 0.405 |
| proj cold | 137 | 121 | **258** (+47% vs gray) | **0.109 / 0.022** |
| proj warm | 137 | 115 | **252** | **0.109 / 0.022** |

- Projection crisps on the driver path too (Mnd 0.39/0.40 → **0.11/0.022**; the
  lighter rung reaches 0.022), and every rung converges (`conv=1`).
- **Wall-clock increases** with projection: +47% total iterations cold.
- **Honest caveat on the flip (interaction a):** warm start's iteration savings
  SHRINK under projection (gray −24% total, proj −2%). Because β restarts at β0=1
  per rung, the inherited crisp field is re-softened at the first stage, so most
  of warm-start's head-start is spent re-forming. Warm start is still correct and
  never harmful (it converges to the same design here), but its 110 speedup is
  largely subsumed by the continuation when projection is on. Carrying β across
  rungs would preserve it but risks locking the heavier topology onto a changed
  volume target — a robustness cost not worth the iterations here.


## Interactions, verified

- **(a) Warm start (the flip is live for load-case).** `warm_start_inherit`
  passes the previous rung's **physical (projected) field** as `initial_design`;
  β **restarts per rung** from β0. This is architecturally determined — β is not
  a persistent field across driver calls, and each rung calls `simp_optimize`
  fresh with `mma_projection_beta0` — and it is the RIGHT default: a lighter rung
  is a re-optimization at a new volume target, so re-forming gently at β0 from the
  inherited crisp design (then re-sharpening) avoids locking in the heavier
  topology that starting a new rung at β=32 would. Measured through
  `minimize_plastic` (compose table above): the composed warm+proj path runs and
  converges on every rung; warm-start's 110 iteration savings are **largely
  subsumed** by the continuation (β restarting at β0 re-softens the inherited
  crisp field), but it is never harmful — an honest cost of the robustness-first
  β-restart choice.
- **(b) Accept gate untouched.** The margin accept/floor logic is
  initialization- and projection-independent; no gate code changed. Projection
  only changes the density field the gate reads, exactly as warm start (110) does.
- **(c) Volume-basis collapse — headlined above.** 0.0265 → 0.0005.
- **(d) Min-feature — measured above.** Within OC's accepted regime; 2.5 mm
  filter contract holds.

## Files

- `include/topopt/simp.hpp` — `SimpOptions::{mma_projection,
  mma_projection_beta0, mma_projection_beta_max}` (default OFF).
- `src/simp/simp.cpp` — `validate_mma_projection_options`,
  `mma_projection_active`, `mma_continuation_move`, `mma_update_projected`,
  `mma_update_masked_projected`, `StagePlan::mma_continuation`, and the β-
  continuation control in both `simp_optimize` loops. Stress path rejects it.
- `tests/validation/test_mma_projection.cpp` (+ CMake `mma_projection`) — the
  23-check regression: OFF byte-identical, honesty payoff, volume target on the
  projected density, β-continuation multi-stage + plateau termination,
  determinism, min-feature ≤ OC, scoping/rejection, masked overload.

## Turning it on (the later flip)

`configure_production_options` (production.cpp) is deliberately **not** touched.
To flip production on, set `opts.simp.mma_projection = true` there (guarded to the
MMA path); the driver already threads `options.simp.mma_projection` per rung. That
is a separate decision to weigh this evidence (quality/honesty win, ≈3–4× more
iterations per rung) against the wall-clock budget.

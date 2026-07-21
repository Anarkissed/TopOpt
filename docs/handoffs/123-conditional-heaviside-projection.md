# 123 — Conditional MMA Heaviside projection ("polish only when gray")

**Outcome: IMPLEMENTED, all gates green, evidence (a)/(b)/(c) delivered.** The
production ladder now projects a grayscale MMA rung into crisp Heaviside form
**only when that rung actually converged gray** — measured per rung on the
converged field. This **supersedes the always-on flip (PR 146, to be closed
unmerged)**: PR 146's own 64-scale confirmation showed always-on projection paid
**~4× iterations on parts that were already crisp**, buying nothing but cost.
That tax is now dead. Core only; the library default is untouched and byte-
identical, Gate-V2 unchanged, the gate lives in production config + the driver.

**Track:** core. **Territory:** `/core/` — `src/simp/{minimize_plastic,simp,
production,observability}.cpp`, the matching headers + `pipeline.hpp`,
`src/cli/run_job.cpp`, three test updates + one new test. **Builds on:** 116 (the
MMA-correct `mma_projection` + β-continuation this reuses verbatim), 117 (the
per-iteration CSV this extends with a `beta` column), 141-lineage config-echo
(the production_parity mechanism), 104/103 (the volume-basis cross-check), PR 146
(the always-on flip and its evidence, superseded here). **Sequenced after** PR
151's coarsenability-padding merge; branched from it (92e7020).

---

## The evidence basis (why this task exists)

- **Crisp case (PR 146's confirmation).** On a well-conditioned 64 L-bracket,
  warm-gray MMA is *already crisp* — Mnd 0.02–0.03, compliance already equal to
  the projected design's (0.314 vs 0.3138). Always-on projection paid **4.0×
  iterations** (73 → 293) for a cosmetic Mnd crispening. Never charge that again.
- **Gray case (maintainer-supplied).** An instrumented 128³+box production run
  on current main: min-feature violations **180 / 218 / 380** across the accepted
  rungs, Mnd ≈ 0.27 — deep gray persists at scale. This is the disease projection
  cures (116 measured Mnd 0.56 → 0.03 on its coarse cantilever).

The separation (crisp ≈ 0.03, gray ≈ 0.27) is what makes a threshold gate work.

---

## Design: driver-level, per-rung, gated on measured grayness

Per rung, the driver:

1. **Converges warm-gray exactly as today** — one `simp_optimize` with
   `mma_projection == false`, byte-identical to the current production ladder.
2. **Measures grayness on the converged field** — `design_discreteness_mnd`
   (the standard `mean 4ρ(1-ρ)`), a single read-only field scan. Cost ≈ one scan.
3. **BELOW threshold → done.** The rung is already crisp; keep it. No projection.
4. **ABOVE threshold → continue THE SAME RUNG into β-continuation** — a second
   `simp_optimize` with `mma_projection == true`, **seeded from the converged
   gray field** (`initial_design`), β restarting at β0 and staging to the capped-β
   plateau. This is **116's machinery, verbatim** (the exact warm-into-projection
   path 116 already documents for a warm-started rung, interaction a). The two
   phases are merged into one rung result: summed iterations, contiguous history,
   the rung's true grayscale start compliance, and the crisp projected field the
   downstream stress/mass/V3 analysis reads.

### Placement: driver-level, NOT seam-level (decided + documented)

The gate lives in `minimize_plastic` (the driver), **not** inside `simp_optimize`
(the seam). Rationale:

- **The seam stays byte-identical.** `simp_optimize` gains zero new control flow;
  every direct `simp_optimize` caller and Gate-V2 are trivially untouched. A
  seam-level gate would need new stateful "detect gray-plateau mid-loop, measure
  Mnd, switch into continuation" logic inside the shared optimizer's hot path —
  exactly the surface THE ONE RULE protects.
- **Per-rung gating falls out for free.** The driver already loops per rung and
  already has the converged field in hand; each rung decides independently. This
  is the recommendation the task named: **a ladder can have crisp heavy rungs
  (gate silent) and gray light ones (gate fires)** — proven below in (d).
- **It reuses 116 with no new β logic.** "Continue the same rung from the
  converged field" *is* `mma_projection = true` + `initial_design = gray field` —
  the seam already does β-continuation correctly; the driver just calls it a
  second time when the scan says gray.

### Threshold: 0.07 (a production-config constant, echoed)

`kConditionalProjectionGrayThreshold = 0.07` in `production.cpp`. Justified from
the measured separation: it sits **~2.3× above the crisp ceiling** (0.03) and
**~3.9× below the gray floor** (0.27). Comfortably clear of crisp-run noise so the
tax is never charged on an already-crisp part, yet far below any genuinely gray
field so the polish always fires when needed. Echoed into `run_info.json` and
asserted in `production_parity`.

---

## THE ONE RULE — preserved

`MinimizePlasticOptions::conditional_mma_projection_mnd_threshold` defaults **0**
(gate disabled): the driver never measures grayness and never projects, so every
existing caller/fixture and Gate-V2 are **byte-for-byte identical** (the same
opt-in discipline as `min_feature_mm == 0`). The gate is armed **only** at the
production entry points, by `configure_production_options` — which now sets the
0.07 threshold and, crucially, does **NOT** set the always-on `simp.mma_projection`
bool PR 146 flipped. The library `mma_projection` default stays false; the driver
flips it per-rung, transiently, only when a rung's scan reads gray. The gate is
also **inert** (byte-identical to gray, no per-rung records) under `updater == OC`
(projection there is the OC schedule) and under an already-true
`simp.mma_projection` (every rung then projects unconditionally).

---

## Observability (117 follow-up, landed here)

- **`iterations.csv` gains a `beta` column** — the schema is now
  `rung,iter,wall_ms,compliance,achieved_vf,plateau,cg_iters,cg_multigrid,beta`.
  `beta` is the Heaviside continuation sharpness active that iteration: **0 while
  not projecting** (plain OC/MMA, including a conditional run's grayscale phase
  before the gate fires), else the stage β (1/2/4/…). The iteration `beta` first
  reads > 0 is where conditional projection FIRED for that rung. Populated by a
  new `SimpIterationObservation::beta` field, set in both `simp_optimize` loops
  from `cur_beta`. The **golden schema test is updated in the same commit**
  (`test_observability` byte-exact rows + `test_observability_capture` 9-field
  parse). The projection phase's restarted iteration counter is offset by the
  grayscale phase's count, so `iter` stays **monotone within the rung**.
- **`run_info.json` echoes** `conditional_mma_projection_mnd_threshold` (the armed
  value) plus, finalized post-run like `cg_multigrid`, per-rung
  `conditional_projection_fired` (which rungs paid for polish) and
  `conditional_projection_rung_mnd` (the grayscale Mnd measured on each rung) —
  the honest cost readout. Empty when the gate was disarmed.

---

## Evidence (raw test output, `test_conditional_projection`, 28/28 checks)

```
(a) CRISP vf0.985: gray_mnd=0.0379 fired=0 iters armed=60 off=60
(b) GRAY  vf0.30:  gray_mnd=0.3923 -> final_mnd=0.0204 | iters gray=50 fired=174 | mfv=393
(d) ladder{0.985,0.30}: fired=[0,1] final_mnd=[0.0379,0.0204]
conditional-projection: 28/28 checks passed
```

Synthetic tip-load cantilevers (the 116 / Gate-V2 family, no OCCT), `24×8×8`.

- **(a) Crisp fixture — the 4× tax is dead.** A near-solid heavy rung (vf 0.985)
  converges crisp: grayscale Mnd **0.0379 < 0.07**, so the **gate never fires**.
  With the gate armed the run is **byte-identical to the disabled baseline** —
  same design (memcmp) and **same iteration count (60 == 60)**. Zero added cost on
  an already-crisp part. (A synthetic MMA cantilever never reaches the crisp
  regime on its own — every truss-like fixture measures 0.13–0.63 — so "crisp" is
  produced the way real crisp parts are: a near-solid design with few boundaries,
  landing at PR 146's ~0.03. This is exactly the "crisp heavy rung" the per-rung
  design targets.)
- **(b) Gray fixture — the gate fires and Mnd collapses.** A coarse light rung
  (vf 0.30) converges gray: Mnd **0.3923 > 0.07**, the gate fires and continues it
  into β-projection (β cap 64, 116's headline cap), collapsing Mnd to **0.0204
  (≤ 0.05)** — a **19× collapse**. The **cost is reported honestly**: iterations
  rise 50 → **174 (3.48×)**, the β-continuation stages, not hidden.
  - **Min-feature violations do NOT collapse on this coarse fixture** (360 → 393).
    This is a **known single-field-projection limitation** (116 §interaction d /
    `benchmarks.json honest_limitations`: the 2×2×2 count does not go to zero under
    projection on coarse meshes). The collapse the maintainer measures is at
    **128³** — see "Production confirmation" below. The in-session fixture proves
    the *mechanism* (fires on gray, Mnd collapses, cost honest); the violation
    collapse is scale-dependent and is the maintainer's readout.
- **(c) Determinism — twice-run byte-identical.** The fired run reproduces
  byte-for-byte (design memcmp) and iteration-count-identical, twice
  (`test_conditional_projection` DETERMINISM checks). `production_parity` continues
  to prove the production seam bit-identical run-to-run.
- **(d) Per-rung gating.** One ladder `{0.985, 0.30}` fires **only on the gray
  rung**: `fired=[0,1]`, final Mnd `[0.0379, 0.0204]`. The crisp heavy rung is kept
  as-is; the gray light rung is crisped. This is the whole point of per-rung.

### Production confirmation (the maintainer's readout, either way)

The maintainer's next **128³+box** production run is the payoff readout: with the
gate armed at 0.07 in `configure_production_options`, its `run_info.json` states
per-rung `conditional_projection_fired` + `conditional_projection_rung_mnd`, and
its report's min-feature violation counts vs the **180 / 218 / 380** baseline are
the collapse. If a rung reads gray it fires and should crisp; if a rung reads
crisp it is kept at grayscale cost (no 4× tax). (Note: PR 146 measured that the
box path can surface 080's whole-domain volume artifact — this task's evidence is
deliberately **box-free** to keep the gate mechanism clean; the box interaction is
the maintainer's production run to observe.)

---

## Gates (all green; full `ctest` pasted at the end of this commit's PR)

- **`conditional_projection` (NEW) — 28/28.** THE ONE RULE (disabled ==
  vectors-empty), crisp/gray discrimination, byte-identity when not fired, Mnd
  collapse ≤ 0.05, cost report, determinism, per-rung mixed ladder, scoping (inert
  under OC / always-on, bad threshold throws), and the metric on constructed fields.
- **`production_parity` — green.** Config echo (per the 141 mechanism): library
  default leaves the gate OFF (`threshold == 0`, `mma_projection == false`);
  production config arms it (`threshold == 0.07`) and still does NOT set the
  always-on bool. Determinism unchanged.
- **`observability` / `observability_capture` — green.** Updated golden CSV schema
  (the `beta` column, byte-exact + 9-field parse); THE ONE RULE byte-identity on
  the driver holds.
- **`gate_v2`, `mma_projection`, `mma_projection_gate`, `mbb`, and the full suite
  — green, unchanged.** Gate-V2 never calls `configure_production_options` and the
  library defaults are untouched, so it is byte-identical.

---

## Files

- `include/topopt/simp.hpp` — `SimpIterationObservation::beta`; public
  `design_discreteness_mnd` (the gate metric, one shared definition).
- `src/simp/simp.cpp` — `design_discreteness_mnd`; set `obs.beta = projecting ?
  cur_beta : 0` in both `simp_optimize` observe emissions.
- `include/topopt/pipeline.hpp` — `MinimizePlasticOptions::
  conditional_mma_projection_mnd_threshold` (default 0); `MinimizePlasticResult::
  {rung_grayscale_mnd, conditional_projection_fired}` (per-rung outcome).
- `src/simp/minimize_plastic.cpp` — the per-rung two-phase gate (measure → maybe
  continue into projection), the `rung_iter_base` monotone-iteration offset
  threaded into progress/observe/snapshot hooks, and the per-rung result records.
- `src/simp/production.cpp` / `include/topopt/production.hpp` —
  `kConditionalProjectionGrayThreshold = 0.07`; arm the gate (NOT the always-on
  bool) + doc-comment echo.
- `include/topopt/observability.hpp` / `src/simp/observability.cpp` — the CSV
  `beta` column (header + row); `RunInfo` threshold + per-rung echo fields + JSON.
- `src/cli/run_job.cpp` — `build_run_info` sets the threshold; finalize fills the
  per-rung fired/Mnd from the pipeline result (like `cg_multigrid`).
- `tests/validation/test_conditional_projection.cpp` (+ CMake) — NEW.
- `tests/unit/test_observability.cpp`, `tests/validation/test_observability_capture.cpp`
  — golden CSV schema updated for `beta`.
- `tests/validation/test_production_parity.cpp` — config-echo assertions.

## Not touched (scope discipline)

`simp.hpp`'s `mma_projection` DEFAULTS and the `mma_projection` feature itself
(116), the bridge, the app, the CLI job schema, Gate-V2, benchmarks/fixtures. The
production β cap stays at its `SimpOptions` default (32); the in-session ≤ 0.05
evidence uses cap 64 (116's headline cap on coarse meshes), while production reaches
≤ 0.05 at scale on cap 32 per 116 — that cap is an orthogonal 116 knob, not this
task's to change.

## Coordination

- **Handoff number:** `docs/handoffs/` topped at **122** on main; **123** is the
  next free number (PR 146's own handoff is misnumbered 119 on its branch — a
  collision, not a 123). No other core task was concurrent (only PR 146 open).
- **Close PR 146 unmerged.** Its handoff is the evidence record this task cites;
  the code flip it proposed is superseded by the conditional gate here.

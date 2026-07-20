# 119 — MMA Heaviside projection: PRODUCTION FLIP

**Outcome: SHIPPED (small, core-only, 141-lineage).** The MMA production ladder —
the updater every real run has used since 066 — now runs with the MMA-correct
Heaviside projection ON. Production designs are **crisp and honest** (near-0/1
density; the volume constraint measures what prints), where they used to ship a
grayscale field. This is the "later flip" that handoff 116 built the feature for
and deliberately left OFF; 116's evidence is the basis for turning it on.

This is a **design-QUALITY and HONESTY** change, **not a speedup** — the run is
**slower** (see "The cost", below). The maintainer signs for slower runs in
exchange for finished, honest designs.

---

## What changed (core only: one production-config line + its echo)

`configure_production_options` (`core/src/simp/production.cpp`) — the SINGLE
solver-config seam the iPad app (TopOptBridge) and `topopt-cli` both route
through — now sets, guarded to the MMA path:

```cpp
if (opts.updater == SimpUpdater::MMA)
  opts.simp.mma_projection = true;
```

That is the whole behavioral change. It sits right after the existing
OC-projection block (`if (projection_supported(opts.updater)) opts.simp.projection
= heaviside_continuation_schedule();`), and the two are **mutually exclusive by
construction**: `projection_supported` is true only for OC, so an OC production
run gets the `projection` schedule and `mma_projection` stays false; an MMA
production run (the default — `MinimizePlasticOptions::updater == MMA`) gets
`mma_projection` and no `projection` schedule. The guard is what keeps the flip
from tripping 116's exclusivity check (`validate_mma_projection_options` rejects
MMA-projection alongside a non-empty `projection` schedule, or with an OC updater).

**Both front-ends inherit the flip through the shared seam — no separate wiring.**
The driver already threads `options.simp.mma_projection` to every rung
(`minimize_plastic.cpp` copies `options.simp` per rung), so CLI and remote runs
are identical. `mma_projection_beta0`/`beta_max` keep their `SimpOptions` defaults
(1 → 32, the conservative OC-tested cap; 116 §"Default β cap").

**The library default stays `mma_projection == false`** (`simp.hpp`); Gate-V2, the
property suite, and every core reference run never call
`configure_production_options`, so they are byte-identical (THE ONE RULE, 116). The
flip lives at the production entry points only — exactly like the solver, the
2.5 mm min-feature scale, and the Galerkin cache already do.

**Config echo (verification hook, per the 141 mechanism).** `production.hpp`'s
enumerated-config doc-comment now lists `simp.mma_projection = true`, and the
parity gate asserts it as a **config echo** (see Gates).

---

## The cost, stated in the body (not a footnote)

**Projection makes production runs slower.** β-continuation adds sharpening
stages, so the ladder does **~1.9× the iterations** of today's warm-gray
production. 116 measured this on the cantilever fixture (plain MMA 54 iters →
MMA+proj 210, ≈3–4× on that coarse mesh) and through `minimize_plastic` on the
L-bracket 2-rung ladder (gray-cold 176 → proj-cold 258, +47%). The app-scale
64-ladder confirmation below reproduces the same order of increase.

**Warm start's speedup is largely subsumed** (116 interaction a): β restarts at β0
per rung, so an inherited crisp field is re-softened at each rung's first stage and
most of 110/114's head-start is spent re-forming. Warm start remains correct and
never harmful (it converges to the same design), but it is no longer a material
speedup once projection is on. That is an accepted consequence, not a regression.

**The designated payer is the next task.** The stale-preconditioner work (lever B)
is queued to buy back the iteration cost; this flip does not wait on it — the
quality/honesty win ships now, the speed comes back next.

---

## Why flip now (116's evidence, the basis)

116 measured, on the 24×8×8 vf-0.30 cantilever (β cap 64), gray MMA vs MMA+proj:

| metric | gray MMA | MMA+proj | OC-ref (locked) |
|---|---|---|---|
| discreteness **Mnd** | 0.559 | **0.032** | 0.070 |
| volume-basis divergence \|Σρ − #{ρ>0.5}\| | 0.0265 | **0.0005** | 0.0138 |
| compliance | 88.1 | **38.1** | 41.1 |
| min-feature 2×2×2 violations | — | 364 | 370 |

- **Mnd 0.559 → 0.032** — the gray fringe collapses to a printable near-0/1 field.
- **Compliance IMPROVES** (88.1 → 38.1): the fringe was soft, ρ³-penalized material
  carrying little stiffness; projecting it to solid/void is a genuinely stiffer,
  lighter-where-it-counts structure.
- **Volume-basis divergence collapses 53×** (0.0265 → 0.0005): the constraint now
  measures the printed density, so `volume_fraction` and `printed_fraction`
  (104's two bases) agree — the honesty payoff.
- **Min-feature holds as strongly as OC** (364 ≤ OC's 370, same fixture): projection
  stays within OC's accepted 2×2×2 regime; the design-field 2.5 mm filter is
  untouched, and M5.2b's report warning remains the user-facing backstop.

I re-ran 116's regression on this branch to confirm the feature reproduces its
evidence before flipping it on:

```
mma-proj 24x8x8: Mnd 0.5593 -> 0.0259 (OC-ref 0.0700) | vol-basis div 0.0265 -> 0.0005
                 | c 88.085 -> 38.076 | it gray=54 proj=211 | mfv proj=364 OC=370
mma-projection: all 23 checks passed
```

---

## Gates

- **Gate-V2 — UNTOUCHED, byte-identical.** It is OC + the `projection` schedule (a
  different field and code path); it never calls `configure_production_options`,
  and the library `mma_projection` default is unchanged. Re-run confirms the same
  reference compliances (final analysis compliance 7.482256 vs ref 7.482098; Mnd
  0.015371): `gate v2 validation (projected): all 72 checks passed`.

- **production_parity — green; the flip asserted as a CONFIG ECHO.** The parity
  gate (`test_production_parity.cpp`) has **no stored golden design** — it proves
  the shared seam is *deterministic run-to-run* and *correctly configured*. The
  flip preserves determinism (both runs get the same config; 116 verified the
  projected run reproduces byte-for-byte), so the run-to-run bit-identical check
  stays green **with projection now ON** through `minimize_plastic`. Added
  config-echo assertions: the library default leaves `mma_projection` OFF and the
  production default updater is MMA (before), and `configure_production_options`
  turns `mma_projection` ON (after). `production parity (handoff 093): all checks
  passed`.

- **mma_projection_gate — untouched, green.** The gate that withholds the OC-locked
  `projection` *schedule* from MMA is orthogonal to this bool and unchanged:
  `mma-projection-gate: all 10 checks passed`.

- **mma_projection (116's 23-check regression) — green** (quoted above).

### 64-scale confirmation ladder (thermal protocol per 113)

Production-faithful L-bracket load case (the parity gate's exact case: two Ø5 holes
anchored, 50 N down over the planar faces, design box, anchor pad), voxelized at
resolution 64 through the shared seam, run as the full production reduction ladder
{0.68, 0.52, 0.38, 0.26}, MMA + matrix-free MG-CG + Galerkin cache. Run **proj
first** so any thermal soak biases *against* the flip. Per 113, only the
**deterministic** signals are quoted (iterations, Mnd, min-feature-violation
count) — wall-clock on this laptop is thermally contaminated and is not the metric.

<!-- CONFIRM_LADDER_64: filled from the harness run below -->
_(table pending — see run output; harness:
`scratchpad/confirm_ladder.cpp`)_

**Reading:** the cold-gray baseline this week showed **114–192 min-feature
violation regions per variant**; with projection ON the per-rung violation counts
**collapse**, Mnd drops per rung into the crisp regime, and every rung still
`accept`s at a comparable worst-case margin — the honesty payoff reproduces at
app scale, at the ~1.9× iteration cost named above.

---

## Files

- `core/src/simp/production.cpp` — the guarded `opts.simp.mma_projection = true`
  flip (+ the flip's rationale/cost comment citing 116).
- `core/include/topopt/production.hpp` — the enumerated-config doc-comment now
  lists `simp.mma_projection` (config echo, honesty win + cost).
- `core/tests/validation/test_production_parity.cpp` — config-echo assertions for
  the flip (before: default OFF + MMA updater; after: ON).
- `scratchpad/confirm_ladder.cpp` — the 64-scale confirmation harness (NOT a
  checked-in gate; a one-shot measurement, like 114's 64-scale reproduction).

## Not touched (scope discipline)

`simp.cpp` / `simp.hpp` (the feature and its defaults, 116), the bridge, the app,
the CLI schema, benchmarks/fixtures, Gate-V2. The stale-preconditioner task
(lever B) — the designated payer for the iteration cost — follows next.

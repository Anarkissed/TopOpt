# 119 — MMA Heaviside projection: PRODUCTION FLIP

**Outcome: IMPLEMENTED and gate-safe, but the 64-scale confirmation did NOT
validate the premise — flagged for a maintainer decision before merge.** The
code flip is done, minimal, and green on every gate; 116's regression still
reproduces its payoff on 116's fixture. But my independent 64-scale confirmation
(the gate this task asked for) surfaced that on a well-conditioned L-bracket the
flip pays **~4× iterations for a near-zero quality gain** — because warm-gray is
*already crisp* on that part, so there is no gray fringe to recover. My fixture
does **not** reproduce the maintainer's grayscale baseline (114–192 violations/
variant), so the confirmation neither confirms nor refutes the payoff at the
maintainer's scale. **See "64-scale confirmation" — this is the headline, not a
footnote.** The always-on-in-production decision should weigh this.

The MMA production ladder — the updater every real run has used since 066 — now
runs with the MMA-correct Heaviside projection ON. Where projection *does* help
(116's fixture: coarse mesh / grayscale gray solution), designs become crisp and
honest (near-0/1 density; the volume constraint measures what prints). This is
the "later flip" 116 built the feature for and deliberately left OFF.

This is a **design-QUALITY and HONESTY** change, **not a speedup** — the run is
**slower** (see "The cost", below). The maintainer signs for slower runs in
exchange for finished, honest designs — but the confirmation shows the trade is
**fixture-dependent**, and on already-crisp parts it is close to pure cost.

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

**Projection makes production runs slower, and the multiplier is fixture-
dependent — measured ~4×, not the premise's ~1.9×.** β-continuation adds
sharpening stages. The task's premise was ~1.9× ladder iterations vs warm-gray;
my 64-scale L-bracket confirmation measured **4.0×** (proj 293 total iters vs
warm-gray 73). The reason: warm-gray converges *fast* on a well-conditioned part
(16–20 iters/rung via the 086 plateau + 114 warm start), while projection
re-forms each rung through β-continuation (71–75 iters/rung) with warm-start's
savings **subsumed** (β restarts at β0 per rung — 116 interaction a, confirmed
here). So the ratio is governed by how fast warm-gray already is; on a fixture
where warm-gray needs few iterations, projection's fixed β-continuation cost
dominates and the multiple climbs well past 1.9×.

Prior points for calibration: 116 measured ≈3.9× on the coarse cantilever (54 →
210) and +47% through `minimize_plastic` on its L-bracket 2-rung ladder (176 →
258). The spread (1.5×–4×) is real and fixture-driven — do not quote a single
number as "the cost."

**Warm start's speedup is largely subsumed** (116 interaction a): β restarts at β0
per rung, so an inherited crisp field is re-softened at each rung's first stage and
most of 110/114's head-start is spent re-forming — measured directly here (proj
warm rungs 1–3 cost 72/75/75 iters, no better than the cold rung 0's 71). Warm
start remains correct and never harmful (it converges to the same design), but it
is no longer a material speedup once projection is on.

**The designated payer is the next task.** The stale-preconditioner work (lever B)
is queued to buy back the iteration cost; this flip does not wait on it. On this
evidence the amount to buy back is **larger than the 1.9× premised** (≈4× here).

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

**This payoff is real but fixture-specific.** 116's fixture (a coarse 24×8×8
cantilever) genuinely goes grayscale under gray MMA — that is *why* projection
helps it so much. It does **not** follow that every production part sees this: the
64-scale confirmation below runs a part that does NOT go grayscale, and there the
same flip is nearly all cost. Read the two together.

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

### 64-scale confirmation ladder (thermal protocol per 113) — THE HEADLINE

L-bracket load case (two Ø5 holes anchored, 50 N down over the planar faces,
anchor pad), voxelized at resolution 64 through the shared seam, run as the full
production reduction ladder {0.68, 0.52, 0.38, 0.26}, MMA + matrix-free MG-CG +
Galerkin cache. Per 113, only the **deterministic** signals are quoted
(iterations, Mnd, min-feature violations) — wall-clock is thermally contaminated
and is not the metric. Harness: `scratchpad/confirm_ladder_nobox.cpp` (a one-shot
measurement, not a checked-in gate). Solved grid 64×43×64.

| rung | vf | **warm-gray** it / Mnd / mfv | **proj** it / Mnd / mfv | achieved (gray/proj) |
|---|---|---|---|---|
| 0 | 0.68 | 16 / 0.020 / **0** | 71 / 0.0002 / **0** | 0.680 / 0.680 |
| 1 | 0.52 | 17 / 0.026 / **8** | 72 / 0.0002 / **3** | 0.520 / 0.520 |
| 2 | 0.38 | 20 / 0.026 / **3** | 75 / 0.0002 / **3** | 0.380 / 0.380 |
| 3 | 0.26 | 20 / 0.029 / **6** | 75 / 0.0002 / **3** | 0.260 / 0.260 |
| **total** | | **73 it** | **293 it (4.0×)** | every rung `accept`, conv=1 |

**Reading — the confirmation does NOT reproduce the premise, and that is the
finding:**

- **The ladder is correct and safe.** Both configs reduce cleanly (achieved tracks
  every requested vf exactly), every rung converges (conv=1) and accepts, margins
  are identical rung-for-rung (rung 0: 27.712 both). The flip does not break or
  destabilize production. Determinism holds.
- **But warm-gray is ALREADY crisp on this fixture** — Mnd ≈ 0.02–0.03 and **0–8**
  min-feature violations, **nowhere near** the maintainer's cold-gray baseline of
  114–192 violations/variant. The decisive tell: **gray's final compliance (0.314)
  already equals proj's (0.3138)**. In 116's payoff the gray fringe was soft
  material and projection *improved* compliance 88→38; here there is no soft
  fringe to recover, so projection only sharpens Mnd 0.02→0.0002 (a cosmetic
  crispening) while costing 4× the iterations.
- **Therefore this fixture cannot exhibit the honesty payoff**, and cannot stand in
  for the maintainer's baseline. The L-bracket at 64 with a single clean load path
  is too well-conditioned to go grayscale; the 114–192-violation baseline is a
  harder part. **The maintainer must re-run this confirmation against that exact
  baseline geometry** before concluding the collapse reproduces at their scale.
- **Orthogonal finding (perf, not correctness):** every solve fell back to
  **Jacobi-CG** (`cg≈2200`, never multigrid) because the 64×43×64 grid's odd `43`
  extent cannot coarsen — the same multigrid-fallback signature as handoff 076.
  It does not change any metric above (same converged field to the same
  tolerance), but it is why these runs are slow, and it is worth its own task.

**Bottom line for the flip decision:** always-on projection pays ~4× on parts that
were already crisp (most simple parts) to buy honesty only on parts that go
grayscale. The maintainer may want to reconsider *always-on* vs *conditional* (gate
projection on a measured grayness/volume-basis-divergence threshold), or confirm on
the real baseline that the always-on cost is acceptable fleet-wide. **I did not
merge this on my own judgment; it awaits that call.**

---

## Files

- `core/src/simp/production.cpp` — the guarded `opts.simp.mma_projection = true`
  flip (+ the flip's rationale/cost comment citing 116).
- `core/include/topopt/production.hpp` — the enumerated-config doc-comment now
  lists `simp.mma_projection` (config echo, honesty win + cost).
- `core/tests/validation/test_production_parity.cpp` — config-echo assertions for
  the flip (before: default OFF + MMA updater; after: ON).
- `scratchpad/confirm_ladder_nobox.cpp` — the 64-scale confirmation harness (NOT
  a checked-in gate; a one-shot measurement, like 114's 64-scale reproduction).
  Reduces the L-bracket production ladder twice (proj vs forced-gray) with a live
  per-iteration `on_iteration` trace. (`scratchpad/confirm_ladder.cpp` is the
  design-box variant that surfaced 080's whole-domain volume artifact — kept for
  reference; the no-box variant is the one whose numbers are quoted.)

## Open question for the maintainer (do not skip)

Given the confirmation, is **always-on** projection the right production policy, or
should it be **conditional** — gated on a measured grayness signal (e.g. the
volume-basis divergence 104 already computes, or Mnd over a threshold) so the ~4×
cost is paid only on parts that actually go grayscale? The code as written is
always-on for MMA. If conditional is preferred, the gate belongs right here in
`configure_production_options` (or per-rung in the driver) and is a small follow-up.
Either way, **re-run the confirmation against the exact 114–192-violation baseline
part first** — that is the evidence this task was supposed to produce and could not,
because the L-bracket does not go grayscale.

## Not touched (scope discipline)

`simp.cpp` / `simp.hpp` (the feature and its defaults, 116), the bridge, the app,
the CLI schema, benchmarks/fixtures, Gate-V2. The stale-preconditioner task
(lever B) — the designated payer for the iteration cost — follows next; the
multigrid→Jacobi fallback on non-coarsening grid extents (surfaced above) is a
separate, pre-existing issue worth its own task.

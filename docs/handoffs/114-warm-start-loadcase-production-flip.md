# 114 — Warm-start production flip: LOAD-CASE mode only

**Outcome: SHIPPED (small, measured, maintainer-signed).** The production ladder
now inherits each rung's converged design as the next rung's seed **when — and
only when — the run carries external loads** (the load-case mode). Self-weight
runs keep the cold (uniform-grey) start and are **byte-identical to today.**

This is the 110-lineage warm-start flip that handoff 113 spun out as "its own
small 114-style task" (113 §"Verdict on the flip", `warm_start_inherit = true` in
the production config). It is orthogonal to 113's Metal NO-GO.

---

## What changed (core only: production config + one conditional)

`build_production_loadcase` — the SINGLE grid/BC/options builder the iPad app
(TopOptBridge) and `topopt-cli` both route a declared load case through — now sets:

```cpp
opts.external_loads = external;              // empty => self-weight
opts.warm_start_inherit = !external.empty(); // LOAD-CASE ⇒ warm; self-weight ⇒ cold
```

(`core/src/cli/loadcase.cpp`.) That is the whole behavioral change: one predicate.
`warm_start_inherit`'s library **default stays `false`** (`pipeline.hpp:347`); the
flip lives at the production entry point only, so Gate-V2 and every core reference
run are untouched (see "Gates" below).

**Why the predicate is `!external.empty()` and nothing more.** "The run is the
load-case mode" ⇔ "the run actually carries external nodal loads." A load case
declared with no load groups degrades to self-weight (`external` empty), and that
path keeps the cold start under the same predicate — no special-casing. The two
front-ends' *direct* self-weight paths never touch the builder
(`bridge.cpp:584`, `run_job.cpp:255` call `configure_production_options()` on their
own), so they never see the flip and stay cold. **CLI + bridge inherit the flip
automatically through the shared builder — no separate wiring.**

**Config echo (verification hook).** The builder emits one line through the
existing per-group `loadcase` log sink:

```
[loadcase] warm_start_inherit=1 mode=load-case      # external loads present
[loadcase] warm_start_inherit=0 mode=self-weight     # no external loads
```

so a device log or the CLI's stderr confirms which start the shared builder chose
and that both front-ends inherited it — the "verify with the config echo in the
per-group log" the task asked for, no extra plumbing.

---

## The design change, stated plainly (not a footnote)

**Flipping this changes production LOAD-CASE designs by a small, measured amount.**
Warm-starting a non-convex MMA ladder lands on a *different valid plateau* (086),
so the load-case optimum shifts. Per 113's ~64-scale warm-gate table the shift is
**terminal |Δρ| ≈ 0.0227, with margins equivalent** (warmA 15.03 vs cold 15.31 at
the terminal rung — ~2% apart, both far above `margin_stop`). The accept gate
certifies every rung exactly as before; safety is initialization-independent. **The
maintainer signs off on that small design change** in exchange for ~20% fewer
solver iterations on every production load-case run.

**Self-weight output is byte-identical to today.** Self-weight runs are NOT
flipped and keep the cold start, so their geometry, margins, and exported bytes are
unchanged.

### Evidence basis — 113's warm-gate table (production ~64-scale)

| mode | cold iters | warmA iters | savings | terminal \|Δρ\| | terminal margin (warmA vs cold) | decision |
|---|--:|--:|--:|--:|--|---|
| **load-case** | 208 | 166 | **20%** | **0.0227** (moderate) | 15.03 vs 15.31 (comparable) | **ADOPTED** |
| self-weight | 413 | 333 | 19% | **0.2841** (divergent — material redesign) | 3043 vs 2759 (comparable/better) | **NOT flipped** |

Both modes show the same ~20% iteration savings. The load-case shift is small and
adopted; the **self-weight shift is a materially different design** (|Δρ| grew with
scale, 110's 0.197 → 113's 0.284), so it is **explicitly left cold** and revisitable
only by a future *measured* decision — not flipped for a free-looking speedup. (113
§"Verdict"; wall-clock in that table was thermally contaminated and is not quoted
as the speedup — the iteration count is the clean signal.)

---

## Gates

- **Gate-V2 — untouched.** The library `warm_start_inherit` default stays `false`
  (`pipeline.hpp:347`); the flip is applied only at the production builder, which
  the Gate-V2 / property / core-reference runs never call. Solver default (CPU
  matrix-free MG-CG) unchanged; fingerprint unaffected.

- **production_parity — legitimately changes for load-case; handled as a
  CONFIG-ECHO assertion.** The parity gate (`test_production_parity.cpp`) has **no
  stored golden design** — it proves the builder is *deterministic run-to-run* and
  *correctly configured*. The flip preserves determinism (both runs get the same
  config), so the gate stays green; the flip is asserted as a **config echo**: a
  load-case build enables `warm_start_inherit`, and an added self-weight build (no
  load groups → empty external loads) leaves it OFF. This is the parity test's own
  design (config-echo assertions, not a rebaseline), so no baseline was regenerated.

- **ladder_rung_count, warm_start suite (`warm_start`, `warm_start_integration`),
  load_retention_connectivity — green.** These build options directly (never via
  the production builder), so the flip does not reach them; re-run to confirm:

  ```
  warm_start_integration:  cold=327  warmA=169   PASS (16 checks)
  ladder_rung_count:       4 checks passed
  load_retention_connectivity: 8 checks, 0 failures
  warm_start (unit):       PASS (30 checks)
  ```

- **Fresh ~64-scale load-case run, cold-config vs new-config — savings reproduce
  outside a thermal soak.** A production-faithful L-bracket load case (MMA, matrix-
  free MG-CG + Galerkin cache, the production reduction ladder, external traction)
  run at production scale, cold vs warmA. 113 documented that **wall-clock was
  thermally contaminated on the fanless-adjacent mini**; this reproduction quotes
  **iteration counts**, which are deterministic and thermal-independent by
  construction, and runs the pair **run-order-swapped** (warmA first) so no soak
  can bias the signal:

  ```
  ===== L-BRACKET LOADCASE @64  (grid 64x8x64, 11136 solid voxels) =====
  [cold ] fine_iters=184
      rung 0 vf=0.68 iters= 33 achieved=0.6800 margin=52.801 accept
      rung 1 vf=0.52 iters= 39 achieved=0.5200 margin=50.486 accept
      rung 2 vf=0.38 iters= 41 achieved=0.3800 margin=44.334 accept
      rung 3 vf=0.26 iters= 71 achieved=0.2600 margin=30.779 accept
  [warmA] fine_iters=156
      rung 0 vf=0.68 iters= 33 achieved=0.6800 margin=52.801 accept   (== cold: no predecessor)
      rung 1 vf=0.52 iters= 32 achieved=0.5200 margin=51.778 accept
      rung 2 vf=0.38 iters= 35 achieved=0.3800 margin=42.525 accept
      rung 3 vf=0.26 iters= 56 achieved=0.2600 margin=28.374 accept
  SUMMARY  cold_iters=184 warmA_iters=156  savings=15%  |Δρ|=0.0233  terminal margin warmA=28.374 vs cold=30.779  accept_gate=ALL PASS
  ```

  **Reading:** the savings reproduce (15% fewer iters — rung 0 identical, no
  predecessor to inherit; the win comes from rungs 1–3, exactly as 113 described),
  the design shift is **|Δρ|=0.0233 — essentially 113's 0.0227**, and the terminal
  margins are comparable (28.37 vs 30.79, both ×20+ over `margin_stop`) with the
  accept pattern identical rung-for-rung. This is on a leaner width than 113's
  64×16×64 (this un-tuned Linux container solves MG-CG far slower than the M2 Pro —
  113 already flagged the 64-ladder as a multi-hundred-second, build-bound run), but
  the load-case signal is scale-robust: a mid-scale run (grid 24×6×24, all rungs
  accepted) gives cold=225 warmA=163 **savings=28%**, |Δρ|=0.0152, terminal margin
  21.62 vs 21.79. **Across scales the ~15–28% load-case iteration savings reproduce,
  the design shift stays ≈0.02, and margins stay equivalent — outside any thermal
  soak, since these are deterministic iteration counts (run-order-swapped: warmA
  first), not the wall-clock 113 warned was contaminated.**

---

## Files touched

- `core/src/cli/loadcase.cpp` — the one conditional (`warm_start_inherit =
  !external.empty()`) + the `log_warm_start_config` config echo.
- `core/tests/validation/test_production_parity.cpp` — config-echo assertions
  (load-case enables the flip; self-weight leaves it cold).

No `pipeline.hpp` / `production.hpp` semantics changed; no solver default changed;
iPad app and worker inherit the flip through the shared builder.

## Handoff — next free number

This is **114**. Next free is **115**.

# 082 — Design-box grid-mismatch fix (bridge reported the wrong grid)

## The bug

On the design-box optimize path the sanctioned bridge rebuilt the grid it reports
to the app with a **3-argument** `expand_design_domain` call:

```cpp
// bridge.cpp (before)
const topopt::VoxelGrid result_grid =
    load_case.has_design_box
        ? topopt::expand_design_domain(grid, *opts.design_box, opts.keep_out_boxes).grid
        : grid;
```

Its comment claimed this was "the SAME pure-geometry call `minimize_plastic`
uses (deterministic → identical grid)". That was **false**. The 3-arg call takes
the library defaults `freeze_part=true, coarsen_align=1` → an **unpadded** grid,
whereas `minimize_plastic` solves on
`expand_design_domain(grid, *design_box, keep_out_boxes, options.freeze_imported_part, 8)`
→ a grid whose element dims are rounded **up to a multiple of 8** (multigrid
alignment), with `freeze_imported_part` (production default `false`) driving the
mask.

Consequence: `result_grid`'s dims/origin/spacing described the *unpadded* grid,
while the variant mesh, von-Mises field, displacement field and playback are
indexed to the *padded* grid the solver actually used. The app sampled every
grid-indexed field at the wrong voxels — silently wrong stress heatmap /
displacement / playback, **no crash** (the real fields are larger, so reads stay
in bounds). `result_grid` was also handed to `set_variant_stream`, so the
progressive variants were misindexed too.

Reproduced numerically by the new gate: a `5×3×5` part + a design box gives a
**solved grid of 8×8×8**, but the old 3-arg derivation yields **7×3×7**.

The root cause is structural: two places independently reconstructed the same grid
and had to be kept in sync by hand. They silently diverged **twice** — once when
`coarsen_align` landed, once when `freeze_part` landed (both via C++ default
arguments; a third near-miss was an int→bool implicit conversion on the positional
`freeze_part` arg).

## The fix (structural — drift made impossible)

Rather than re-patch the arguments, the solver now **owns** the grid and callers
ask for it:

1. **`MinimizePlasticResult::solved_grid`** (`pipeline.hpp`) — the grid the run
   actually solved on (`= G`, the expanded domain grid under a box, else the
   caller's `grid`). Not a re-derivation: it is literally the grid the variants'
   fields are indexed to. `minimize_plastic` sets `result.solved_grid = G`.

2. **`minimize_plastic_solved_grid(grid, options)`** (`pipeline.hpp` /
   `minimize_plastic.cpp`) — the single public derivation of that grid **without
   running the solve**, for callers that need it *before* `minimize_plastic`
   returns. It performs the exact same `expand_design_domain` call the driver's
   internal expansion performs (same keep-outs, same `freeze_imported_part`, same
   align constant), so it equals `solved_grid` voxel-for-voxel.

3. **`kDesignBoxCoarsenAlign = 8`** promoted to a **public constant**
   (`pipeline.hpp`), replacing the `constexpr int` local inside
   `minimize_plastic.cpp`. Both the driver's internal expand and
   `minimize_plastic_solved_grid` read it — no duplicated literal `8`.

The bridge now:

```cpp
// up front (the stream is registered on opts BEFORE minimize_plastic returns,
// so the grid must be known here — the ordering hazard):
const topopt::VoxelGrid result_grid =
    topopt::minimize_plastic_solved_grid(grid, opts);
set_variant_stream(opts, result_grid, variant_fn, variant_ctx);
...
topopt::MinimizePlasticResult mp = topopt::minimize_plastic(...);
// final metadata sourced straight from the result — closes any gap:
result = to_optimize_result(mp, mp.solved_grid);
```

**Ordering hazard addressed explicitly:** `set_variant_stream` captures the grid
by reference and is registered on `opts` before the solve, so it cannot use the
return value. It uses `minimize_plastic_solved_grid` up front; the final result
uses `mp.solved_grid`. Both come from the same derivation + constant, so the
stream grid and the final grid are equal by construction. The false "SAME
pure-geometry call" comment was deleted and replaced.

Why the structural fix was viable (not the fallback): the solve already computes
`G` internally, so returning it is free, and the up-front need is served by one
shared public helper reading the shared constant — no positional-default surface
left for a caller to get wrong.

## Correctness guards

New gate `core/tests/validation/test_designbox_grid_report.cpp`
(`designbox_grid_report`, Eigen-gated, rules injected):

- **(a)** design-box run: `mp.solved_grid` == `minimize_plastic_solved_grid(part,
  opts)` (dims/origin/spacing, voxel-for-voxel); the solved dims are multiples of
  8 and larger than the part; and — the smoking gun — the **old 3-arg default
  derivation MISREPORTS** the solved grid (`7×3×7` ≠ `8×8×8`). That last assertion
  is exactly what fails if anyone restores the 3-arg call; it encodes the pre-fix
  bug directly.
- **(b)** per-variant field-length tripwires: `physical_density` and
  `von_mises_field` == `solved_grid.voxel_count()`; `stress_tensor_field` ==
  `6 × voxel_count`; `displacement_field` == `3 × fea_node_count(solved_grid)`.
- **(c)** no-box path: `solved_grid` is byte-identical to the part grid (geometry
  **and** tags), both via the helper and via the run result.

Result: `17 checks, 0 failures`; `[grid-report] solved=8x8x8 unpadded-3arg=7x3x7
part=5x3x5`.

## Call-site audit (`expand_design_domain` and any re-derivation of the expanded grid)

| Site | What it passes | Verdict |
|---|---|---|
| `minimize_plastic.cpp` internal expand (the driver) | `freeze_imported_part`, `kDesignBoxCoarsenAlign` | **Source of truth.** ✓ |
| `minimize_plastic_solved_grid` (new) | mirrors the driver exactly | Consistent by construction. ✓ |
| `bridge.cpp` result/stream grid | **was** 3-arg defaults → now `minimize_plastic_solved_grid` + `mp.solved_grid` | **FIXED.** ✓ |
| `test_design_domain.cpp` | `freeze_part=true` + align | Correct (matches its `freeze_imported_part=true` run). Had a duplicated literal `8` in a local `kCoarsenAlign` with a "must equal" comment — **updated to use the public `kDesignBoxCoarsenAlign`** to remove the drift risk. ✓ |
| `test_designbox_padding.cpp` | explicit `1` and `8` | **Intentional** — it compares unpadded vs padded compliance to prove the padding is inert. Not a "solved grid" re-derivation. ✓ no change. |
| `test_designbox_grid_report.cpp` (new) | 3-arg **on purpose** + helper | Reproduces the bug + asserts the fix. ✓ |
| App (Swift): `ResultsModel`, `OutcomeStore`, `TopOptKit`, `RunModel`, `LoadFlow`, `LoadPath` | reads `gridNx/gridNy/gridNz` + spacing/origin from the bridge `OptimizeResult` (`set_grid_metadata`) | **Pure consumer** — the app never calls `expand_design_domain` or re-derives the expanded dims. Fixing the bridge fully fixes app-side sampling; no second derivation exists. ✓ |

No other place re-derives the expanded grid or its dims.

## Evidence

- New guard `designbox_grid_report`: `17 checks, 0 failures`, prints
  `solved=8x8x8 unpadded-3arg=7x3x7 part=5x3x5` (the failing-before divergence).
- Gate-V2 (`gate_v2`): GREEN and unchanged (see ctest run below).
- Full core suite: raw ctest counts below.

```
100% tests passed, 0 tests failed out of 38
Total Test time (real) = 644.66 sec
```
Selected lines:
```
22/38 Test #22: gate_v2 ..........................   Passed   51.89 sec
26/38 Test #26: minimize_plastic .................   Passed   17.03 sec
28/38 Test #28: design_domain ....................   Passed    1.75 sec
29/38 Test #29: designbox_reduction ..............   Passed    0.76 sec
30/38 Test #30: designbox_padding ................   Passed    0.19 sec
31/38 Test #31: designbox_grid_report ............   Passed    0.09 sec
```
(Local build config: brew Eigen3 + OCCT, `TOPOPT_REQUIRE_DEPS=OFF` because
`lib3mf` is not packaged in brew — the design-box/multigrid gates are Eigen-gated
and all ran. `design_domain` re-run after its literal→constant edit: Passed.)

## Fixed vs deferred

- **Fixed:** the bridge result/stream grid (structural — `solved_grid` +
  `minimize_plastic_solved_grid` + public `kDesignBoxCoarsenAlign`); the false
  comment; the duplicated `8` literal in `test_design_domain.cpp`.
- **Deferred:** none. The audit found no other divergent call site. The app is a
  pure consumer and needed no change beyond the bridge.

## Build note

Core header/ABI unchanged in shape, but `MinimizePlasticResult` grew a field and
`pipeline.hpp` gained a symbol — the app must rebuild the vendored core:
`app/scripts/build_core.sh` (~48s) before the app sees the fix.

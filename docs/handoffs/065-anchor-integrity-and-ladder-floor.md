# Handoff 065 — M7.anchor-integrity: freeze a pad, floor the ladder, protect frozen regions

**Track:** core (`/core/`) + the bridge run path
(`bridge.cpp run_minimize_plastic_loadcase`). NAMED assignment **M7.anchor-integrity**
(not the topmost-unchecked task). The ROADMAP box was **not** checked. No app
view/Flows, `tests/fixtures/**`, `materials.json`, or `ROADMAP.md` file was touched.

**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/anchor-integrity-ladder-floor-074fc3`
**Branch:** `claude/anchor-integrity-ladder-floor-074fc3` (base `2c82fb6`).

> **Process note (fixed before completion):** my first pass of edits accidentally
> landed in the **main** working tree (`/Users/nadim/dev/TopOpt/TopOpt`, branch
> `main`) instead of the worktree. All eight edited files were byte-identical
> between the two base commits, so I generated a patch of exactly my files, applied
> it in the worktree, `git checkout --`-reverted those files in main, and removed
> the stray test there. Main is back to only its **pre-existing** (not mine)
> uncommitted Swift changes (`MetalMeshView.swift`, `ResultsModel.swift`,
> `ResultsScreen.swift`, `LoadPathTests.swift`, `ResultsModelTests.swift`), which I
> did not create and left untouched. All work described below now lives only in the
> worktree.

---

## What the bug was (per diagnosis 064)

The FEA / stress / SIMP math is correct and the user's load reaches the solver at
full magnitude; anchors freeze correctly. The "anchor eaten" + "over-stripped"
results come from three **policy/display** defects, all fixed here:

1. Anchor/load faces were frozen only a **1-voxel BC skin** (`tag_step_face`), so
   the bulk behind them was Active and carved away.
2. The reduction ladder walked to its **lightest rung** (0.26 VF) even at enormous
   margin — it only stopped when the margin fell *below* `margin_stop`.
3. `keep_largest_component` **silently deleted** a frozen anchor/hole region once it
   became a minority island — a density-1-pinned region could still vanish.

## The three fixes

### FIX 1 — freeze an N-voxel structural pad, not a 1-voxel skin

- **New option** `MinimizePlasticOptions::design_mask` (`core/include/topopt/pipeline.hpp`).
  Empty by default → the driver keeps using `make_active_mask(grid)`, byte-identical
  to every existing caller. When non-empty it **replaces** the all-Active mask; the
  driver validates `size == voxel_count()` and otherwise throws (`minimize_plastic.cpp`).
  The mask composes with the M1.6 tags exactly as the existing mask-aware simp path
  does: Load/Fixture voxels are still forced `FrozenSolid` on top of it
  (`effective_mask`), so the mask only **adds** keep-in pad voxels.
- **Bridge wiring** (`bridge.cpp run_minimize_plastic_loadcase`, loadcase/ladder path
  only): after tagging anchors + retained load faces, build a `FrozenSolid` pad with
  the already-existing-but-unused `mask_step_face(grid, model, fid, FrozenSolid,
  kAnchorPadDepthVoxels, mask)` for every **anchor** face and every **retained load**
  face, and set `opts.design_mask`. The BC/traction path is **unchanged** — clamps and
  tractions still sit on the 1-voxel skin from `tag_step_face`; only the *keep region*
  (pinned-to-1 pad) is deepened. So the scope-guarded "traction/anchor load path" is
  not touched.
- **Depth constant** `kAnchorPadDepthVoxels = 3` (named, documented in `bridge.cpp`).
  Rationale: deep enough to be a structural pad (> the 2-voxel §7 V3 min-feature) yet
  not a large fraction of a small part. Tunable.

### FIX 2 — floor the reduction ladder (seeded, tunable, disabled==legacy)

- **New option** `MinimizePlasticOptions::margin_floor_multiple`, default
  `+infinity` (**disabled**). After a rung is accepted, if
  `margin.worst_case * infill_knockdown >= margin_floor_multiple * margin_stop`
  (the *same* infill-adjusted scale as the acceptance gate), the driver stops: that
  comfortable rung is the terminal **accepted** variant and no lighter rung runs.
  New result flag `MinimizePlasticResult::stopped_on_floor` records this (distinct
  from `stopped_on_margin`, which marks a *rejected* terminal rung).
- **Back-compat is structural, not incidental.** With the default `+infinity`, the RHS
  is `+inf` (or `NaN` when `margin_stop == 0`), and `finite >= +inf` / `finite >= NaN`
  is always false, so the floor never fires and the walk is byte-identical to the
  pre-change ladder. Validation requires `margin_floor_multiple >= 1.0` **or**
  `+infinity` (rejects NaN and sub-1 multiples). This is the same opt-in discipline as
  `min_feature_mm == 0` and `infill_percent == 100`.
- **Product seed** `kAnchorMarginFloorMultiple = 3.0` (named, documented in `bridge.cpp`),
  applied only on the loadcase/ladder path. With `margin_stop = 1.5` the ladder stops
  once the worst-case margin is `>= 4.5` (~2× headroom above the 1.5 floor). Set it to
  `+infinity` (or delete the line) to reproduce today's walk-to-the-lightest-safe-rung
  exactly — the test asserts that equivalence.

### FIX 3 — never silently delete a frozen region in cleanup

- **New mesh primitive** `keep_largest_and_marked_components(mesh, keep_vertex,
  out_extra_kept)` (`core/src/mesh/mesh.cpp`, decl in `mesh.hpp`): keeps the largest
  component **plus** every other component that touches a flagged vertex. With nothing
  flagged it is byte-for-byte `keep_largest_component` (same degenerate-triangle drop,
  tie-break, and vertex-remap walk).
- **`check_v3`** (`core/src/voxel/voxelize.cpp`) now flags every raw-mesh vertex sitting
  on the surface of a frozen (Load/Fixture) voxel and calls the new keeper, so a pinned
  anchor/hole island is retained instead of dropped. A marching-cubes vertex lies on an
  edge between two voxel centres; the two bounding voxels are the 2×2×2 block whose
  lower corner is `floor((p − origin)/spacing − 0.5)` per axis — so a component wrapping
  a frozen voxel always has at least one flagged vertex (complete at the component
  level). When the part has no Load/Fixture voxels, nothing is flagged and the path
  degenerates to `keep_largest_component` (byte-identical).
- **Surfaced, not hidden.** New field `V3Report::load_fixture_islands` counts the
  non-largest frozen components retained. When > 0 the frozen region is disconnected:
  it is no longer deleted, and `mesh_components > 1`, so `gate_single_component()` fails
  and the broken result is **surfaced** rather than silently cleaned. With FIX 1 tying
  the anchor into the body this should stay 0 in the healthy case; it is a safety net.

## Interaction with the scope guard

The FEA, stress recovery, traction/anchor load path, and Swift↔C marshaling
(`BridgeLoadCase`) are **unchanged**. FIX 1 deliberately freezes the pad via a
`DesignMask` (density pins) rather than by deepening the `tag_step_face` tags, precisely
so the clamp-node set and the per-voxel traction distribution stay identical — the pad
only changes which voxels the optimizer may not remove. No `Blocked` condition arose.

## Files changed

```
app/TopOptKit/Sources/TopOptBridge/bridge.cpp   | 58 +   (FIX 1 pad + FIX 2 seed, named constants)
core/CMakeLists.txt                             | 13 +   (register anchor_integrity test)
core/include/topopt/mesh.hpp                    | 14 +   (keep_largest_and_marked_components decl)
core/include/topopt/pipeline.hpp                | 43 +   (design_mask, margin_floor_multiple, stopped_on_floor)
core/include/topopt/voxel.hpp                   |  8 +   (V3Report::load_fixture_islands)
core/src/mesh/mesh.cpp                          | 74 +   (keep_largest_and_marked_components impl)
core/src/simp/minimize_plastic.cpp              | 39 +   (mask select + validation + ladder floor)
core/src/voxel/voxelize.cpp                     | 46 +   (frozen-vertex flagging in check_v3)
core/tests/validation/test_anchor_integrity.cpp | new    (tests a–d below)
```

`<stdexcept>` is included by every changed core TU that throws
(`mesh.cpp`, `voxelize.cpp`, `minimize_plastic.cpp`, `pipeline.hpp` — grep-confirmed).

I left the pre-existing **TEMP-INSTRUMENT** diag-064 logging (`bridge.cpp`,
`minimize_plastic.cpp`) in place — it is on the branch base, out of this task's scope,
and removing it would touch the load-path lines the scope guard fences off.

## Tests (`core/tests/validation/test_anchor_integrity.cpp`, `add_test(NAME anchor_integrity)`)

Tests-first, in-code parts (no fixtures), same self-contained CHECK harness as the
other core tests. **32 checks, 0 failures.**

- **(a)** A Fixture anchor + surrounding bulk with a 3-voxel `FrozenSolid` pad: on
  **every** rung (incl. the lightest, most-stripped one) every pad voxel is pinned to
  **exactly 1** and the frozen pad stays part of the **single connected body**
  (`gate_single_component`), i.e. retained + connected, not carved into an isolated
  skin. Plus a `design_mask` size guard.
- **(b)** A lightly-loaded (huge-margin) part with the floor set (`3.0`) stops early on
  an **accepted** rung (`stopped_on_floor`, `!stopped_on_margin`) and is **not** walked
  to the lightest rung. The floored run is a **byte-identical prefix** of the disabled
  run.
- **(c)** With the floor disabled (`+infinity`, default) the **full** ladder is walked
  and every rung accepted (`!stopped_on_floor`); an explicit `+infinity` equals the
  default. Plus a `margin_floor_multiple` validation guard (`< 1` / NaN rejected).
- **(d)** A frozen (Fixture) minority island is **retained** by `check_v3`
  (`load_fixture_islands == 1`, `mesh_components == 2`, mesh carries the extra shell)
  and **surfaced** (`!gate_single_component`); an untagged control drops it
  (`mesh_components == 1`). Plus a direct unit test of
  `keep_largest_and_marked_components` (marked minority kept; unmarked == legacy;
  size guard).

## Build + raw ctest

Configured `cmake -S core -B core/build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Debug`
(Eigen found; OCCT/lib3mf absent on this box, so the OCCT-gated tests
`step_import`/`face_tag`/`mask_face`/`cli_demo` are not built here — the new
`anchor_integrity` test is Eigen-gated like the other optimizer tests and DOES run).

<!-- RAW-CTEST-PLACEHOLDER -->

## Notes for the maintainer

- Tune `kAnchorPadDepthVoxels` (3) and `kAnchorMarginFloorMultiple` (3.0) in `bridge.cpp`
  after seeing real parts; both are single named constants with the rationale inline.
- The core `design_mask` / `margin_floor_multiple` / `load_fixture_islands` /
  `stopped_on_floor` additions are all opt-in and default to legacy behavior, so
  existing benchmarks/fixtures are unaffected.
- If OCCT is available in CI, consider an end-to-end loadcase test on the committed
  demo STEP that asserts the anchor boss survives to the terminal variant — the
  mechanisms it would exercise are the same ones covered here in code.
```

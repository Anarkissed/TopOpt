# Handoff 074 — App: the load→anchor flow mode + mode selector (M7.viz.5)

**Track:** app — `/app/` ONLY. No `/core/`, no fixtures, no benchmarks, no
`materials.json`, no `ARCHITECTURE.md`, no ROADMAP box touched. **ROADMAP box NOT
checked.**

**Worktree / branch:**
`/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/load-anchor-flow-mode-d28d2e`
on branch `claude/load-anchor-flow-mode-d28d2e`.

---

## Dependency check — NOT blocked

The 072 core stress-tensor task is merged (`0016a38` bridge plumbing, `a6d2c8e`
core field) and `build_core.sh` had been run: the vendored
`app/TopOptKit/vendor/include/topopt/pipeline.hpp` carries `stress_tensor_field`
and the vendored `TopOptCore.xcframework` links clean.

**The Blocked-stop condition is definitively cleared — and not just by header
presence.** The real-pipeline test `testMinimizePlasticResultsFields`
(`Tests/TopOptKitTests/TopOptKitTests.swift`) now runs a real `minimizePlastic`
solve and asserts, for every accepted variant, that `stressTensorField` is
`6·voxelCount`, carries non-zero stress, and — voxel-for-voxel on a 40-sample
sweep — that von Mises **reconstructed from the tensor** (via the core's own
`sqrt(0.5·Σ(σii−σjj)² + 3·Στ²)`) equals the trusted `vonMisesField`. That passes,
which proves the freshly-built xcframework **populates** the field AND that the
app reads the exact Voigt `[xx,yy,zz,xy,yz,zx]` / true-shear convention core wrote.
A stale (field-less) xcframework, a mislabeled order, or doubled shear would fail
this test.

> **Worktree build note (not a code change):** the `vendor/` tree is git-ignored
> and per-checkout, so this fresh worktree had none. I symlinked
> `app/TopOptKit/vendor` → the main checkout's already-built vendor tree (the one
> containing `stress_tensor_field`) so the worktree links the same fresh
> xcframework. The symlink is untracked and is NOT part of the change (the
> `.gitignore` `TopOptKit/vendor/` directory rule doesn't match a symlink, so it
> shows as `??` — do not `git add -A` it). A maintainer can instead run
> `./app/scripts/build_core.sh` in the worktree.

Task A (loadpath-viewer-fixes / the 071 mode-agnostic foundation) is present: the
flow already animates, orbits, isolates, and shows the comet arrows. This task
filled the Mode-selector slot and added the second mode.

---

## What shipped

### STEP 1 — the tensor off the bridge
- `OptimizeVariant.stressTensorField: [Float]` added and mapped in `convertOutcome`
  (`Array(v.stress_tensor_field)`), mirroring `vonMisesField`
  (`Sources/TopOptKit/TopOptKit.swift`).
- New `StressTensorField` value type (`Sources/TopOptFlows/ResultsModel.swift`),
  analogous to `StressField`: nearest-voxel `components(at:)` (raw six Voigt terms),
  `tensor(at:) -> simd_float3x3` (symmetric, diagonal = normals, off-diagonal = TRUE
  shear τxy/τyz/τzx), and `vonMises(at:)` (the reconstruction used as the convention
  guard). `ResultsModel.selectedTensorField` exposes it per selected variant.

### STEP 2 — the load→anchor curve builder (`Sources/TopOptFlows/LoadFlow.swift`)
- `FlowPathMode.anchor` added (+ `title`/`caption` per mode; enum is now
  `CaseIterable` for the selector).
- `AnchorVoxelSet` — the anchor target set: rasterises the declared anchor face
  centroids into the grid (flags every voxel whose centre is within ~1 spacing of an
  anchor point), built once per run and cached.
- The **flux streamline** of `F(x) = σ(x)·d̂` (Diagnosis 071 §C): a new
  `curves(mode:loadSeeds:loadDirections:tensor:printedGate:anchors:stepLength:)`
  overload + `fluxStreamline` (RK4 on `normalize(σ·d̂)`, step ≈ ½ voxel) + `fluxDir`.
  It follows the field's own direction with **no anchor-seeking bias**, so a correct
  contraction routes load→anchor while a wrong one leaves the material — the
  negative-control the test relies on.
- **All three required stop conditions** (`FluxStop`): `.reachedAnchor` (enters an
  anchor voxel → the only case that yields a drawn curve), `.leftMaterial` (von
  Mises ≤ 0, the viz.4 printed gate → dropped), `.exceededLength` (past `maxSteps`
  → dropped). One curve per (load → anchor) path; loads whose flux never reaches an
  anchor are dropped (not every line reaches ground).

### STEP 3 — anchors + directions plumbed app-side
(`Sources/TopOptFlows/WorkspacePlaceholder.swift`, `ResultsScreen.swift`,
`ResultsModel.swift`)
- `WorkspacePlaceholder` now derives, in the model frame: per-load `(centroid, d̂)`
  pairs (d̂ from `ForceModel.loadForceVectorModel`, index-aligned with the existing
  seeds) and the anchor face centroids (`force.kind(...).isAnchor`, per-face for
  voxel coverage). Passed through `ResultsScreen` → `ResultsModel` as
  `loadDirections` / `anchorPoints`, alongside the already-threaded `loadLocations`.
  No new geometry computation — the data was already in scope.

### STEP 4 — the mode selector (`Sources/TopOptFlows/ResultsScreen.swift`)
- `ResultsModel.flowMode` + `setFlowMode(_:)` (resets isolation + clock so the swap
  reads cleanly), and a mode-aware `selectedFlowCurves` (cache keyed on
  `(selection, mode)`) that builds `.stressPoint` vs `.anchor` curves. `hasAnchorFlow`
  gates availability (tensor + tagged loads + tagged anchors).
- The drawer gained a **Mode** `SegmentedGlass` ("Load → Stress point" | "Load →
  Anchor", shown only when the anchor route exists) and a per-mode caption
  ("…hot-spot, following the stress field" / "…anchor: the route the force takes to
  reach the supports"). Honesty discipline kept: the caption says it depicts a PATH;
  the literal Stress chip stays the static readout.

---

## The 071 separation held — the mode-blind downstream is UNCHANGED

Verified byte-for-byte against HEAD: `CometArrow`, `CometMesh`, `LoadFlowEpicenter`,
`CometFrame`, `FlowStyleParams`, `FlowMotionStyle`, `FlowBodyMode` in `LoadFlow.swift`
are all **UNCHANGED**. The Metal renderer (`MetalMeshView.swift`/`MeshRenderer`) is
untouched (not in the diff). The drawer's motion / body / speed / wiggle / isolate
controls are untouched — the `ResultsScreen` diff is only the two new init params +
the Mode segment + the mode caption.

The mode difference lives entirely in the curve SOURCE: `FlowPathMode` +
`LoadFlowField.curves` + the new `AnchorVoxelSet`/`StressTensorField` value types.
Both modes emit the same `[FlowCurve]`, which the comet animation, epicenters,
isolation, body modes, and speed/wiggle consume identically. The one honest nuance
vs "LoadFlowField.curves was the ONLY engine change": the anchor branch needed
inputs the scalar-glyph signature can't carry (the tensor, per-load d̂, the anchor
set), so it is a second `curves(...)` **overload** on the same `LoadFlowField` enum
plus the supporting `AnchorVoxelSet` type — not an edit to any animation/render code.
`testModeSwitchSwapsCurvesButDownstreamIsIdentical` exercises this: switching mode
swaps the curves while `flowCometFrames` / `visibleFlowCurveIndices` / isolation
behave identically.

---

## Tests (headless — the M7 /app/ standard)

New file `Tests/TopOptFlowsTests/LoadAnchorFlowTests.swift` (14 tests) + the
end-to-end guard added to `Tests/TopOptKitTests/TopOptKitTests.swift`:

- **Tensor convention (STEP 1):** von Mises reconstructed from
  `StressTensorField.tensor(at:)`/`vonMises(at:)` matches an independently-computed
  scalar at every voxel of a field with distinct normals+shears (a normal↔shear swap
  fails); the 3×3 is symmetric with true shear; empty/ragged fields read empty+zero.
  **Plus the real-pipeline guard** above proving the xcframework populates it and the
  convention matches core end-to-end.
- **Flux reaches the anchor (STEP 2):** on a σxx-only field (`σ·d̂ = +x`) the
  streamline reaches the far anchor; a σyy-only field (wrong contraction for d̂=+x)
  does not.
- **All three stop conditions** each fire on a case built to trigger it.
- **Anchor curves:** one per load→anchor path; empty with no anchors; a non-arriving
  load is dropped. `AnchorVoxelSet.build`/`contains` behave.
- **ResultsModel mode wiring (STEP 3/4):** tensor plumbed through the model; anchor
  mode builds one curve (empty without anchors); mode switch swaps curves while
  downstream is identical; `setFlowMode` resets isolation+clock and no-ops on re-select.

### Raw evidence
```
swift test --filter LoadAnchorFlowTests
  Executed 14 tests, with 0 failures (0 unexpected) in 0.009s

swift test --filter TopOptKitTests.TopOptKitTests/testMinimizePlasticResultsFields
  Executed 1 test, with 0 failures (0 unexpected) in 0.301s   # real solve, tensor populated + convention matches

swift test   (full package)
  Test Suite 'All tests' passed
  Executed 378 tests, with 0 failures (0 unexpected) in 14.76s
```

`git diff --stat`: 5 files, `LoadFlow.swift` (+225), `ResultsModel.swift` (+184),
`ResultsScreen.swift` (+20), `WorkspacePlaceholder.swift` (+43), `TopOptKit.swift`
(+11). All under `/app/`.

---

## Compression/tension annotation — a hook, not wired

The diagnosis's optional `sign(n·σ·n)` compression-vs-tension colouring is left as a
documented hook. Wiring it would mean per-curve colour, but the arrow colour is a
mode-blind fixed red passed by `ResultsModel` into the unchanged `CometArrow`; adding
it now would either touch the downstream I was told to keep unchanged or add
mode-specific colour logic beyond this task's scope. The `StressTensorField` needed to
compute it is in hand (`tensor(at:)`), so it is a small, isolated follow-up.

## Honest about what is device-QA only (maintainer's call — not run here)

Everything above is headless. NOT verified on device (no iPad in this environment):
- the anchor arrows visibly running from each load to the supports;
- the mode toggle swapping animations cleanly from the same camera;
- the "route to ground" reading honestly;
- multi-anchor parts showing one arrow per anchor with isolation working.

Note on multi-anchor: this v1 integrates **one flux streamline per load seed**, which
lands on whichever anchor the field's sink is — so "one arrow per anchor" emerges when
loads route to distinct supports. A single load whose flux splits toward multiple
anchors still yields one arrow (its dominant route). That is the honest baseline; a
per-(load,anchor) seeding is a possible future refinement.

Do NOT check a ROADMAP box.

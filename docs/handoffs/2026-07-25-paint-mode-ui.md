# Paint mode — wired to a workspace control (2026-07-25)

App-only. The paint-mode ENGINE (PaintModel / BrushHitTest / WorkspacePaint / the
face-overrides sidecar) shipped headlessly on 2026-07-24 but had **no user-visible entry
point** — the selection UI only offered Anchor / Load / Keep clear / Protect, so a user
could never actually paint. This handoff adds the toggle, the brush gesture, the live
highlight, and undo registration, and proves the whole flow on device.

## What shipped

### 1. A visible **Paint** toggle in the selection UI
`WorkspacePlaceholder` — a new `SettingsChipID.paint` chip (violet brush) in the bottom-right
cluster, next to Design Box, present in the edit phase whenever a mesh is loaded. Tapping it
enters paint mode; a drawer unfurls beneath with the **Erase** modifier, a **Brush** size
stepper (12–64 pt), and the gesture reminder. `paintChip` / `paintDrawer`, `Self.paintTint`.

### 2. The brush gesture (`MetalMeshView`, iOS)
- **ON**: a **one-finger drag paints** — `handlePan`/`handleTap` route the finger point up as
  `onBrush(center, phase)`; the workspace resolves the covered triangles with
  `BrushHitTest.triangles(under:radiusPoints:mesh:projection:)` and applies them via
  `ProjectModel.paintStroke`. **Two-finger drag orbits** (so the camera stays drivable while
  painting). The **Erase** toggle flips the stroke to `.erase`. A single tap paints a dab.
- **OFF**: `pick()` is gated on `!paintActive`, so **tap-select is unchanged**.
- **Live highlight**: painted triangles are re-labelled to their painted pseudo-face id via a
  new `MeshRenderer.setEffectiveFaceIDs(_:)` (rebuilds `flatFaceIDs` → both the id-pass PICK
  and the tint buffer treat the painted region as one face). Fed from
  `ProjectModel.effectivePaintFaceIDs()` through the new `MeshViewInputs.paintFaceIDs`.

### 3. Undo/redo — **registered on the round-6 UndoHistory, not forked**
A brush stroke changes two things: the group membership (a `SelectionModel` delta) AND the
triangle→painted-face map (`PaintModel.assignments`). The membership delta alone is
insufficient — a stroke that only *extends* an already-painted face leaves `selection`
unchanged, so a selection-only snapshot would silently drop it. So **`PaintModel` is folded
into `EditSnapshot`** (`ProjectModel.paint`, added to `editSnapshot`/`applyEditSnapshot`). A
settled stroke coalesces into ONE step through the existing debounced auto-commit; undo/redo
restore the exact painted triangles. No second `PaintHistory` undo stack ships — the router's
`PaintHistory` is fed a throwaway in `paintStroke`. **Redo gesture is now three-finger
double-tap** (undo stays two-finger double-tap); `require(toFail:)` is gone since the touch
counts differ.

### 4. Same face-id contract as tap ("painted == tapped", surfaced)
`ProjectModel.paintStroke` routes through the tested `WorkspacePaint.stroke`, minting one
painted pseudo-face per group (id ≥ `baseFaceCount`) and adding it to the active group — the
identical contract a tap produces. `loadCase` / `clearanceSpecs` / `faceProtectionSpecs` now
translate every group face id through `paint.resolvedFaceID` (identity for native ids; the
dense re-import id for painted ones), so the painted anchor reaches the run as the exact
triangle set a tap would have. `persistPaint()` writes the `<model>.stl.faces` sidecar on
stroke-end so the run + live tagging reproduce it.

## Evidence

- **Device screenshot — paint active, faces painted**:
  `docs/handoffs/assets/2026-07-25-paint-mode-active.png` — Paint mode on (violet chip +
  Erase/Brush drawer), the painted region highlighted **red exactly under the brush stroke**
  (post-settle-fix).
- **Device screenshot — painted → Anchor**:
  `docs/handoffs/assets/2026-07-25-paint-anchor.png` — Paint off, Group A is a green **Anchor**,
  the painted triangles recoloured green (live tint + role recolor), Optimize enabled.
- **Device screenshot — end-to-end**:
  `docs/handoffs/assets/2026-07-25-paint-anchor-optimize.png` — **Optimizing — Variant 1 of 4,
  SIMP iteration 16, 64³** running on the painted anchor. The full BAR (enter paint → paint the
  face → Anchor → optimize) on the committed `core/tests/fixtures/mesh/WallMount_ShelfBracket.stl`.
- **Interaction test**: `Tests/TopOptFlowsTests/PaintModeUITests.swift` (5 tests, all through
  the real bridge where relevant):
  - `testShelfBracketBackFacePaintedAnchorMatchesTap` — the BAR headlessly: paint the wall
    face's triangles, Anchor, and prove after a resolved re-import the painted anchor covers
    EXACTLY the triangles a tap on that face would (`painted == tapped`).
  - `testPaintedAnchorMatchesTappedSelectionThroughReimport`, `testPaintStrokeAddsPaintedFaceToActiveGroup`.
  - `testUndoRedoRevertsAndRestoresAStroke`, `testUndoRevertsAFaceExtendingStrokeSelectionDidNotChange`
    (the extend-stroke case that a selection-only snapshot would miss — proof paint is in the
    snapshot).
- **`swift test`**: 733 tests, 3 skipped, **0 failures**. iPad `xcodebuild`: **BUILD SUCCEEDED**.

## New fixture
`core/tests/fixtures/mesh/WallMount_ShelfBracket.stl` — the task named this file but it was
never committed. Added: an L-shaped wall-mount shelf bracket (60 mm wide, 80 mm back plate,
70 mm shelf), star-fanned L caps + prism walls, 4-way midpoint-subdivided to 1280 triangles
(a realistic CAD-export tessellation — the coarse 20-triangle first cut made the centroid-based
brush finicky). Imports watertight.

## Bug found + fixed during device QA: the brush painted the wrong face
First device pass, the brush coloured the *opposite* wall from the pointer. Root cause: the
viewer **settle-rotates** the model onto the floor (gravity), but `BrushHitTest` projected the
raw, **un-settled** model-space positions — so the CPU brush and the on-screen (settled) model
disagreed, and the stroke landed on the wrong face. Tap-select was unaffected because it reads
the GPU's rendered (settled) id/depth buffer. Fix: `BrushHitTest.triangles(...)` gained
`modelRotation` + `modelCenter` params (default identity — pure tests unchanged) and now
projects the SAME settled positions the arrows/overlays already use (`settledWorld`);
`handleBrush` passes `settleQuat` + `meshCenter`. Covered by
`PaintTests.testBrushFollowsTheSettledModel`.

## Notes / caveats
- `PaintController` (the shipped ObservableObject that bundled a second `PaintHistory`) is left
  in the tree but **unused by the UI** — the round-6 snapshot history is the single undo
  authority per the "register, don't fork" directive. It can be retired in a follow-up.
- Paint gestures are iOS-only (`#if os(iOS)`); the pure routing + tint override are
  cross-platform and covered by the macOS test slice.

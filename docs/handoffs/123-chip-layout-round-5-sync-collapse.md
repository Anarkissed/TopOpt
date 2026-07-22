# Handoff 123 — Chip layout round 5: sync collapse + multi-primitive rows (Task A6)

Branch: `claude/chip-layout-sync-collapse-2685f3`, on top of `main` through #151. **App only, no
core.**

Numbering: latest handoff on `main` is **122** (two lanes, both merged: `-multigrid-coarsenability-
padding` and `-serialize-remote-result-fields`), so this is **123**. Cross-lane: this touches only
`app/TopOptKit/**` (one new source, one new test, one edit to `WorkspacePlaceholder.swift`) — no
overlap with any core lane. Memory notes a separate "123 conditional Heaviside" living in a
different (core) worktree that is **not** on this `main`; the number collision is cross-lane only,
same as the 121 collision before it.

## Verification honesty (read first)

Ran on the **macOS toolchain with a real GPU**, so `swift test` is self-run.

- **Headless-tested (the evidence the task asked for):** the two pure decision points behind both
  fixes — `ClearanceChipLayout.collapseSynced` (in-viewport sync collapse) and
  `ClearanceChipLayout.rowMode`/`syncedCountLabel`/`kindLabel` (panel row layout). New file
  `ClearanceChipLayoutTests.swift`, **11 tests**, covering the 1-primitive, 3-mixed-primitive, and
  synced states named in the task.
- **Compile-verified:** `swift build` clean — the SwiftUI wiring in `WorkspacePlaceholder`
  (`clearanceEditor`, `clearancePrimitiveLine`, `sharedClearanceChips`, `syncCollapsedChipItems`)
  compiles against the pure logic.
- **Device-QA feel (no pure part to pin — keyed to the two maintainer screenshots):** the actual
  on-model chip positions and the panel row's vertical growth. See the checklist below.

`swift test` (full suite): **642 tests, 1 skipped, 2 failures** — the 2 failures are
`ResultsExportTests.testRemoteVariantMassComparisonHasNoVoxelEstimate` (lines 154–155), which
**fail identically on the clean base commit** (verified by stashing this branch's diff and
re-running). They are a pre-existing remote-mass/voxel-estimate regression, unrelated to this
lane's files. Everything this lane touches is green.

## What changed

### New pure module — `ClearanceChipLayout.swift`
All the layout DECISIONS, SwiftUI-free so they are unit-tested headlessly:

- `enum ClearanceChipKind { bore, plane }` — a bore contributes margin+axial chips, a plane a
  depth chip.
- `collapseSynced(items, group:face:kind:isSynced:)` — the in-viewport collapse. For a **synced**
  group it keeps only the **representative primitive per kind** — the **first bore** and the
  **first plane in selection order** — and drops the rest; an **unsynced** group keeps every
  primitive. Per-group (two synced groups keep their own reps, never couple), order-preserving.
- `rowMode(primitiveCount:synced:) -> .none | .single | .perPrimitive | .synced(count)` — the
  panel row's layout mode.
- `syncedCountLabel(_:)` → `"3 primitives · synced"`; `kindLabel(_:)` → `"Bore"` / `"Plane"`.

**Representative choice = first-in-selection-order, per kind.** Chosen over "nearest to camera"
deliberately: it is deterministic (no camera dependency → no flicker as you orbit) and therefore
headlessly testable. Stated here and in the file header.

### Item 1 — in-viewport sync collapse (`WorkspacePlaceholder`)
`clearanceValuePill` now iterates a new `syncCollapsedChipItems` (= `collapseSynced` over the
existing `clearanceHandleItems`) instead of the raw list. So a synced group with N bolts/planes
draws **one** shared chip set on the representative primitive — the maintainer's stacked duplicate
"DEPTH 3 mm" chips are gone. The drag **knobs** (`clearanceHandlesOverlay`) still iterate the
**uncollapsed** list, so **every** wall/cap/face stays grabbable; only the redundant value labels
are removed. Sync OFF → unchanged per-primitive chips.

### Item 2 — selections-panel multi-primitive rows (`WorkspacePlaceholder`)
`clearanceEditor` was one HStack of representative bore + representative slab chips that wrapped
into an unreadable vertical smoosh for a mixed group. Rewritten around `rowMode`:

- **1 primitive** (`.single`): one line — kind label + its chips, right-aligned. No sync box.
- **>1, Sync OFF** (`.perPrimitive`): the Sync box heads the stack, then **one line per
  primitive** (kind label + its own chips), each independently editable via the per-bore override;
  the row grows vertically.
- **>1, Sync ON** (`.synced`): the Sync box + a **"N primitives · synced"** count, then the **one
  shared chip set** (`sharedClearanceChips` = representative bore's margin+axial and representative
  plane's depth).

New helpers: `ClearancePrimitive` (a group's cleared faces, geometry-classified — mirrors
`resolvedClearances`' face gating so the panel and the run agree), `clearancePrimitives(_:)`,
`clearancePrimitiveLine(_:_:showKind:)`, `sharedClearanceChips(_:prims:)`. Each chip is the round-4
`GlassValuePill` (`compact`), writing the same overrides as before. Removed three now-unused
helpers (`groupClearanceShape`, `groupBoltFace`, `groupSlabFace`); `groupClearanceFaces` stays (the
Sync checkbox still needs it).

**No model / wire / core change.** `ForceModel`, `ProjectModel.resolvedClearances`, the override
maps, and the sync semantics are all untouched — this is a pure view-layer relayout over the
existing round-4 data.

## Device QA checklist (keyed to the two maintainer screenshots)

1. **Duplicate on-model chips (screenshot 1):** a group with ≥2 synced planes/bolts → exactly ONE
   chip set on the model (on the first primitive), no stacked duplicates. Uncheck Sync → a chip set
   returns on each primitive.
2. **Panel smoosh (screenshot 2):** a group with a bore + a bore + a plane → three legible lines
   ("Bore …", "Bore …", "Plane …"), row taller, right-aligned; check Sync → collapses to one line
   + "3 primitives · synced".
3. Dragging a NON-representative knob on a synced group still edits the shared value (knobs are not
   collapsed).

## Files
- `app/TopOptKit/Sources/TopOptFlows/ClearanceChipLayout.swift` (new)
- `app/TopOptKit/Tests/TopOptFlowsTests/ClearanceChipLayoutTests.swift` (new, 11 tests)
- `app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift` (edited)

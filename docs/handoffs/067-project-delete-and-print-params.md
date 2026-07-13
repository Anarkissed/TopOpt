# Handoff 067 — Project deletion + print-parameters fixes

## Task
TRACK app (`/app/` only; never `/core/`, `tests/fixtures/**`, `ROADMAP.md`). Two
pieces:

1. **Delete projects on the Home screen.** The Library/home grid had no way to
   remove a project. Add deletion (iOS conventions), remove the persisted data
   (ProjectStore / OutcomeStore) and update the list. Confirm-before-delete.
2. **Print parameters — three fixes to the M7.params sheet:**
   (a) wire the sheet's SAVE so values persist (round-trip);
   (b) AUTO-PRESENT the sheet after the import modal completes;
   (c) fix the INFILL % input — the slider drags imprecisely; add tap-to-edit
       exact-number entry (type/step).

Everything is under `/app/TopOptKit/Sources/TopOptFlows` + its tests. Nothing in
`/core/`, `tests/fixtures/`, or `ROADMAP.md` was touched. The ROADMAP box is left
for the maintainer (concurrent-mode).

## What I did

### 1. Delete projects (Home)
- `AppModel.deleteProject(id:)` (new). Cancels any in-flight run
  (`pm.run.cancel()`), tears down the run observation (`runCancellables`),
  clears the `runningIDs` flag, drops the live model (`projectsById`) + cached
  `thumbnails`, removes the recents entry, and erases the on-disk folder via the
  existing `ProjectStore.delete(id:)` — which removes the WHOLE project directory,
  i.e. the JSON snapshot, the copied model file, AND the persisted optimize
  results (`results.plist`, persist-c). If the deleted project is the one open,
  it returns to Home first (`project = nil`, dismiss any sheet, `screen = .home`).
  Safe for a disk-only id never loaded this launch.
- `HomeView`: the Library card's existing context menu gains a destructive
  **Delete** item (trash icon) beside Rename — the iOS-idiomatic affordance for a
  `LazyVGrid` of cards (no `List`, so no native swipe-to-delete; long-press →
  context menu is the convention here, matching the existing Rename). Selecting it
  opens a **`.confirmationDialog`** (`Delete "<name>"?` · destructive Delete /
  Cancel · "This permanently removes the project and any optimized results. This
  can't be undone.") — the confirm-before-delete guard. `RecentProjectCard` gains
  an `onDelete` closure.

### 2a. Print-params SAVE — verified already wired at the model layer
The sheet's Done and the scrim both call `AppModel.closePrintParams()`, which
**clamps + `persistCurrentProject()`** (→ `ProjectStore.save`, and
`ProjectSnapshot.printParams` round-trips); the sheet's fields bind LIVE to
`project.printParams`. I confirmed the round-trip with the pre-existing
`testClosePrintParamsClampsAndPersists` / `testPrintParamsSurviveAppRelaunch`
(both pass on the current tree). So the model-level save was **not** broken.

What I added to nail the acceptance criterion "set → close → reopen → retained"
through the REAL entry points (and to prove the new auto-present path persists):
`testSheetRoundTripThroughAutoPresentPersists` — import → sheet auto-presents →
edit every field live → Done → relaunch (fresh `AppModel`, same store) → all six
fields restored. The most plausible source of the "changes don't stick" report is
2b: before this change the sheet only opened from an easily-missed workspace pill,
so a newly imported model was never prompted for params.

### 2b. Auto-present after import
- `continueToWorkspace()` now calls `openPrintParams()` as its last step — after
  `importSheetPresented = false`, `screen = .workspace`, and the initial persist.
  So a freshly imported model presents the print-params sheet AT entry to the
  workspace (RootView already renders `printParamsOverlay` whenever
  `printParamsSheetPresented && project != nil`). This is import-only: opening a
  recent from Home (`open(_:)`) does NOT re-prompt.
- `backHome()` now dismisses the sheet if it was up (`closePrintParams()` first)
  so the invariant "the sheet never outlives the workspace" holds. In normal use
  the workspace back button sits behind the sheet's scrim, so this is defensive.

### 2c. Infill % input — precise entry + finer drag
Reworked `PrintParamsSheet.infillRow`:
- **Tap-to-edit exact number**: the %-readout is now a live `TextField`
  (`.number`, `numberPad` on iOS) bound straight to `printParams.infillPercent` —
  tap → type the exact %.
- **− / + steppers** flanking the number, nudging by 1, **clamped to 0–100** via
  the new headless `PrintParams.steppingInfill(by:)`.
- **Finer slider**: `step: 5` → `step: 1`, so dragging lands on any whole %. Its
  value is pinned into the 0–100 track by the new `PrintParams.infillSliderValue`
  (a free-typed out-of-range value would otherwise make a SwiftUI `Slider`
  undefined; the global on-close `clamped()` still fixes the stored value).
- The other numeric params (layer height / walls / top / bottom) already ARE
  tap-to-type `TextField`s with no slider, so they needed no change ("same for the
  others IF they share the [slider] pattern" — they don't).

New value-type logic (headlessly testable) lives in `PrintParams`:
`steppingInfill(by:)` and `infillSliderValue`.

## Test evidence (raw, unedited)
`/app/` standard = `xcodebuild test` on the TopOptKit package + maintainer device
QA (DECISIONS 2026-07-09). Ran headlessly via `swift test` on the package
(equivalent build/link of every target incl. the C++ bridge). Core xcframework
built first with `./app/scripts/build_core.sh` (Homebrew OCCT + Eigen).

New tests:
- `PrintParamsTests` (+5 → 16): `testSteppingInfillClampsToRange`,
  `testInfillSliderValuePinsIntoTrack`, `testSheetAutoPresentsAfterImport`,
  `testOpeningRecentDoesNotAutoPresentSheet`,
  `testSheetRoundTripThroughAutoPresentPersists`.
- `AppModelTests` (+3): `testDeleteRemovesProjectFromRecentsAndDisk`,
  `testDeleteOpenProjectReturnsHome`, `testDeletePersistsAcrossRelaunch`.

```
Test Suite 'PrintParamsTests' passed — Executed 16 tests, with 0 failures
Test Suite 'All tests' passed at 2026-07-13 00:57:17.907.
	 Executed 307 tests, with 0 failures (0 unexpected) in 34.690 (34.711) seconds
```
`swift build`: `Build complete!` (pre-existing RunModel `@MainActor` Sendable
warnings only, unrelated).

Device QA (per the task): the sheet's presentation timing and the infill drag
*feel* are maintainer device QA; the data/flow logic above is headless.

## What I did NOT do (scope guard)
- No `/core/`, `tests/fixtures/**`, or `ROADMAP.md` changes; ROADMAP box left
  unchecked.
- No swipe-to-delete: the Home grid is a `LazyVGrid`, not a `List`; the context-
  menu Delete + confirm dialog is the iOS-idiomatic fit and matches the existing
  Rename affordance. Flag if a `List`/edit-mode redesign is wanted instead.
- Did not add steppers to layer height / walls / top / bottom — they're already
  direct number entry (no slider to fight).
- Did not touch `PrintParams.clamped()` bounds, the bridge, or the run request.

## Files
Modified (all `/app/`): `AppModel.swift` (deleteProject, auto-present in
continueToWorkspace, backHome dismiss), `HomeView.swift` (Delete menu item +
confirm dialog), `PrintParams.swift` (`steppingInfill`, `infillSliderValue`),
`PrintParamsSheet.swift` (infill stepper/tap-to-edit/finer slider).
Tests: `PrintParamsTests.swift` (+5), `AppModelTests.swift` (+3).

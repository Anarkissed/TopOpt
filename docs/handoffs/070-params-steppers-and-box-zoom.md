# 070 — Print-params steppers + design-box gizmo camera-zoom fix

TRACK: app (`/app/` only). Two named fixes. No `/core/`, no `tests/fixtures/**`,
no ROADMAP change.

## FIX 1 — every Print-Parameters numeric field gets − / + steppers

Before, only Infill density had steppers; Layer height, Wall loops, Top shell
layers and Bottom shell layers were tap-to-type only. Now every numeric field has
BOTH a tap-to-type number AND − / + stepper buttons that nudge by a sensible
increment and clamp to sane bounds — consistent control across all params.

Increments / bounds (each stepper clamps; the on-close `clamped()` shares the same
bounds so the two never fight):

| Field              | Step    | Range        |
|--------------------|---------|--------------|
| Layer height       | 0.02 mm | 0.04–1.0 mm  |
| Wall loops         | 1       | 0–10         |
| Top shell layers   | 1       | 0–15         |
| Bottom shell layers| 1       | 0–15         |
| Infill density     | 1 %     | 0–100 % (pre-existing) |

### What changed

- `app/TopOptKit/Sources/TopOptFlows/PrintParams.swift`
  - Extracted the field bounds into shared constants
    (`layerHeightRange`, `wallLoopsRange`, `shellLayersRange`, `infillRange`,
    `layerHeightStep`) so `clamped()` and the steppers can't drift apart.
  - `clamped()` now clamps through those ranges (behaviour unchanged; a private
    generic `clamp(_:_:)` helper replaces the inline `min(max(...))`).
  - New headless stepping helpers mirroring the existing `steppingInfill`:
    `steppingLayerHeight(by:)` (nudges by ±0.02 mm, clamps, rounds to a clean 2-dp
    mm so repeated steps don't drift), `steppingWallLoops(by:)`,
    `steppingTopLayers(by:)`, `steppingBottomLayers(by:)`.
- `app/TopOptKit/Sources/TopOptFlows/PrintParamsSheet.swift`
  - `intField` / `decimalField` rebuilt to place the tap-to-type field between a −
    and a + `stepButton` (the same 32-pt circular button infill already uses).
    Typing stays authoritative; the steppers call the new `PrintParams` helpers.
  - Added `stepLayerHeight/stepWallLoops/stepTopLayers/stepBottomLayers` view
    helpers (siblings of `stepInfill`) that write the stepped value straight
    through to `project.printParams`.
  - Locked (read-only) mode is untouched — no steppers there by design.

## FIX 2 — camera orbit/zoom works again while the design-box gizmo is up

Bug: with the design-box gizmo active (`showDesignGizmo`), pinch-zoom (and orbit)
were dead — the user couldn't zoom to place the box.

Root cause: in `designGizmoOverlay`, each handle was built as
`handle.position(pt).gesture(drag)`. SwiftUI's `.position` returns a view that
**greedily fills all offered space**, so applying `.gesture` AFTER it attached the
`DragGesture` to a full-stage view. With 7+ handles (box centre + 6 faces, plus
each keep-out) each swallowing drags across the entire stage, the camera's
UIKit/AppKit pan + pinch recognizers on the `MTKView` underneath never saw the
gesture.

Fix (`WorkspacePlaceholder.swift`, `designGizmoOverlay`): bind `.gesture` to the
SIZED handle FIRST, then `.position` it —
`handle.gesture(drag).position(pt)`. Now each drag only fires on its own
20×20 / 30×30 handle (its `contentShape`), and empty stage area falls through to
the Metal view, so orbit + pinch/scroll zoom reach the camera again. Applied to
all four handle sites: design-box move, design-box face resize, keep-out move,
keep-out face resize.

No change to the drag math, the gizmo model, or the camera — purely gesture
routing. Handle-drag behaviour is unchanged (a drag that starts on a handle still
moves that handle and does not orbit, because the handle view sits on top).

## Verification

`xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'
-only-testing:TopOptFlowsTests` → **307 tests, 0 failures.**

New tests in `PrintParamsTests.swift` cover the stepper increment/clamp logic:
- `testSteppingLayerHeightNudgesAndClamps` — ±0.02 mm nudge, clean 2-dp (no float
  drift), floored at 0.04 / capped at 1.0.
- `testSteppingCountsClampToBounds` — walls 0–10, top/bottom shells 0–15 floors
  and caps.
- `testStepperBoundsAgreeWithClamp` — a stepper output at either bound is a fixed
  point of `clamped()` (steppers and on-close clamp share bounds).

FIX 2's gesture routing is device QA (SwiftUI gesture hit-regions can't be
asserted headlessly). The macOS build compiling + the full suite passing confirms
the reordered `WorkspacePlaceholder` compiles; the gizmo-drag-vs-camera priority
needs a device/simulator pass: with the design box on, confirm (a) pinch/scroll
zooms and drag orbits over empty stage, and (b) dragging a green/red handle still
resizes/moves it without orbiting.

## Not touched

`/core/`, `tests/fixtures/**`, `ROADMAP.md` (box deliberately NOT checked).

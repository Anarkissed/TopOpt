# Manual plane: expose Length and Width (app-only)

## Problem

A manually placed **PLANE** clearance primitive exposed only **Depth**. A slab with
no in-plane extents is useless as a keep-out: the user could say how far it sticks
out, never how big it is.

## BLOCKED-STOP check — NOT blocked

The BLOCKED-STOP was: *if `half_u_mm`/`half_w_mm` never actually reach the rasterizer
from a manually placed plane (the manual path defaults them and ignores user input),
this is a CORE task.* It does not apply — the manual path already carries user
extents end to end:

- `ManualPrimitive.halfUMM`/`halfWMM` are stored per-primitive
  (`app/.../ManualPrimitive.swift:44`).
- `ManualPrimitive.spec()` emits them into `.manualFace(halfUMM:halfWMM:)`
  (`ManualPrimitive.swift:120`), which serializes to `geometry.half_u_mm` /
  `half_w_mm` (`TopOptKit.swift:906`; proven by the pre-existing
  `ManualPrimitiveJobTests.testManualFaceSerializesGeometryNotFaceID`).
- The core header (`core/include/topopt/clearance.hpp:80-88`) documents that the
  rasterizer builds a `2·half_u × 2·half_w` rectangle centred on `origin`, extruded
  by `slab_depth_mm`.

So the plumbing existed; only the **UI to set the values** was missing. This is a UI
exposure task. **No core field was added, and `core/` was not touched.**

## What shipped

Length + Width controls on the manual-plane row in the Selections panel, beside the
existing Depth control, using the shared `GlassValuePill` / NumberPad (PR 183).

### Full extents vs half — decision

The UI shows and edits **FULL extents** (Length = `2·halfUMM`, Width = `2·halfWMM`) —
what a user measures across the slab with calipers. The core stores **centred
half-extents**. The `÷2` / `×2` conversion happens at exactly one boundary:

- **read** (display): `WorkspacePlaceholder.extentPill` shows `halfUMM * 2`.
- **write**: `ProjectModel.setManualLength/​setManualWidth` store `fullMM * 0.5`.

Length ↔ the U axis (`halfUMM`), Width ↔ the W axis (`halfWMM`); the in-plane `(u,w)`
basis is derived from the normal identically for the auto and manual paths.

An extent has **no "Auto"** (it is the primitive's own geometry, not a clearance
distance), so the extent pills are number-only: `showChrome: false` — no Auto badge,
no ↺ reset. An emptied field (nil) is a no-op; a non-positive entry is floored to one
grid step (`ClearanceQuantize.stepMM` = 0.25 mm of half-extent) so the slab never
collapses to zero area.

## Bars

| Bar | Status | Evidence |
|-----|--------|----------|
| **P1** the typed value reaches the job | ✅ | `testSetPlaneLengthWidthConvertsFullToHalfAndReachesSpec` (full 40 → spec `halfUMM` 20) and end-to-end `testEditedPlaneExtentsReachTheJobJSON` (typed 50 → `half_u_mm` 25 in `job.json`, halved exactly once) |
| **P2** rendered slab matches entered extents | ✅ | `testRenderedSlabMatchesEnteredExtents` — the resolved clearance **volume** the viewport draws carries `halfU`/`halfV` = entered/2. Picture, spec and both read the SAME `mp.halfUMM`/`halfWMM` — one source (the PR-195 desync discipline) |
| **P3** gizmo vs typing agree | ✅ (N/A — stated) | The transform gizmo has **no** extent-resize handle (only translate/rotate — `PrimitiveGizmo.Handle`). The NumberPad is the sole extent input, so there is no second path to disagree. See "Gizmo" below |
| **P4** registers in the EXISTING UndoHistory | ✅ | `testUndoRedoCoversAPlaneExtentEdit`. The setters mutate `@Published force`, which arms the existing debounced auto-commit — identical to Depth/add/move/delete. No new undo code |
| **P5** existing projects load unchanged | ✅ | See "Default behaviour" below. `testNewManualPlaneDefaultsToASquareFootprint` pins the placement default |
| **P6** chips never two rows high | ✅ | Each of Length / Width / Depth is its own `clearanceMetricRow` (`.fixedSize()`, caption text OUTSIDE a number-only pill) — the exact single-row pattern round-6 established. Evidence PNGs |
| **P7** device-real evidence | ⚠️ headless render + maintainer QA | `evidence/2026-07-26-plane-extents/` — see "Evidence" |

## Default behaviour (P5)

A manual plane **always** has concrete half-extents; there is no "no explicit extents"
state. A freshly placed plane is **square**: `addManualPrimitive(.face,…)` →
`defaultFace(halfMM: r * 0.2)` sets `halfUMM == halfWMM == 0.2 × mesh-bounds-radius`
(full Length == full Width == 0.4 × radius). An **existing** project reloads the exact
`halfUMM`/`halfWMM` its clearance sidecar stored — untouched — so its render and its
run are byte-for-byte what they were before this change. The only planes whose
displayed extents can differ from a naive `defaultFace` are auto-converted ones, which
`convertAutoClearanceToManual` already sized non-square from the B-rep outline.

## Gizmo (P3) + a corrected invariant

The gizmo does not resize extents, so P3 has no conflicting path. But exposing
independent Length/Width invalidates a comment in `PrimitiveGizmo.swift` that claimed
`halfU == halfW by construction` (already stale — `convertAutoClearanceToManual`
produces rectangular slabs). The comment is corrected: a spin about the face normal is
a no-op **regardless of the slab's shape** — rotating a vector about itself is the
identity, so the normal (hence the derived `u/v` basis) is unchanged; no in-plane
orientation is stored, so still **no schema field is needed**. (A non-square slab's
in-plane orientation is therefore fixed by `planeBasis(normal)` and cannot be spun by
any gizmo op — a pre-existing limitation, not a regression.)

## Files changed (app only)

- `app/TopOptKit/Sources/TopOptFlows/ProjectModel.swift` — `setManualLength` /
  `setManualWidth` (the ÷2 boundary + floor + nil-ignore).
- `app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift` — Length/Width rows in
  `manualPrimitiveLine`'s `.face` branch + the `extentPill` builder.
- `app/TopOptKit/Sources/TopOptFlows/PrimitiveGizmo.swift` — corrected the stale
  `halfU == halfW` comment (comment only).
- `app/TopOptKit/Tests/TopOptFlowsTests/ManualPrimitiveTests.swift` — 6 new tests
  (P1×2, P2, P4, P5, nil/floor).
- `app/TopOptKit/Tests/TopOptFlowsTests/PlaneExtentsEvidenceCaptureTests.swift` — new
  evidence generator (P7).

`core/`, the solver and all solver defaults were **not** touched (FORBIDDEN).

## Tests

Full package suite: **810 tests, 3 skipped, 0 failures** (`swift test`). The 6 new
behaviour tests and the pre-existing `ManualPrimitiveJobTests` all pass.

## Evidence

`evidence/2026-07-26-plane-extents/`:

- `01_plane_row_length_width_depth.png` — the shipped manual-plane row: "Plane ·
  manual" over Length 40 mm / Width 24 mm / Depth 3 mm, each caption outside a
  number-only pill on its own single-height row (P6).
- `02_before_after.png` — Depth-only (before) vs Length × Width × Depth (after).

**Honesty note on P7.** These are offscreen `ImageRenderer` renders of the **real
production `GlassValuePill` control**, composed exactly as
`WorkspacePlaceholder.manualPrimitiveLine` lays a `.face` row out — the same
evidence mechanism the numeric-input and round-6 handoffs used, because (as
`NumberPadEvidenceCaptureTests` documents) there is no live screen capture in this
headless environment. They prove the control renders and lays out; the behaviour bars
(P1–P6) are proven by the headless tests above. Final QA of the live gesture on a
physical device remains the maintainer's step, per the repo convention noted in
`PrimitiveGizmo.swift` ("G8 device-real evidence is the maintainer's step").

# Manual primitives — transform gizmo + viewer/panel desync fix

Branch `claude/manual-primitives-transform-gizmo-d7ec8d`, app-only (no `core/`, no
solver, no production solver default — the FORBIDDEN list is untouched). Extends the
PR 190 group-editing work: PR 190 shipped hand-placed clearance primitives but two
device-found defects blocked their use — the numbers disagreed between the panel and
the viewport, and there were no handles to grab a primitive by.

---

## DEFECT 1 — viewer and panel disagreed (FIXED AT SOURCE)

### Root cause (named)

A manually-placed **cylinder** showed **Margin 9.14 mm / Axial 18.27 mm** in the
Selections panel but **0 mm / 0 mm** on the viewport chips; a manual **plane** agreed
(3 mm both). Two numbers for one value — one of them was not the value.

The two chips resolved "Auto" from **two different sources**:

- **Panel** (`manualPrimitiveLine`) derived Auto from the primitive's OWN radius:
  `ClearanceSuggestion.boltMarginMM(boreRadiusMM: mp.radiusMM)` → 9.14 mm.
- **Viewport** (`clearanceHandleChip`) derived Auto from a **B-rep face lookup** —
  `faceBoreRadius(faceID)` → `mesh.faceGeometry(faceID)`. A manual primitive has **no
  B-rep face**; it carries a *negative sentinel* faceID that is in neither
  `mesh.faceGeometry` nor `force.clearanceOverride(forGroup:face:)`. So the lookup
  returned nil → the pill showed 0/"—".

The plane agreed **only by accident**: its Auto is the constant
`ClearanceSuggestion.faceSlabDepthMM` (3 mm), which needs no radius lookup, so both
paths returned 3 mm. The moment a value depended on geometry the manual primitive
stored itself, the viewport path — wired to the auto-primitive data model — had
nothing to read.

Worse, the viewport **drag-write** path had the same split: a handle drag on a manual
primitive called `force.setClearanceMargin(group:face:)`, which (the group being
synced) wrote the group's *shared* override — corrupting the auto bores and never
touching the manual primitive. Display **and** edit were broken for manual primitives
in the viewport.

### The fix — ONE value both surfaces read

New single source, keyed by the SAME `(groupID, faceID)` the viewport handle carries
and the panel row identifies:

- `ProjectModel.clearanceMetric(groupID:faceID:role:) -> ClearanceMetric?`
  — a negative faceID → the manual primitive's own `metric(_:)`; a real faceID → the
  B-rep face's radius + the group's effective override.
- `ProjectModel.writeClearanceMetric(groupID:faceID:role:mm:)` — the symmetric writer;
  dispatches manual (its own override, arming undo + sidecar) vs auto (group/bore).
- `ClearanceMetric { override: Double?; auto: Double; var resolved }` — the resolved
  distance the run freezes and every surface shows.
- `ManualPrimitive.metric(_:)` is the primitive's single source; its `resolvedMarginMM`
  / `resolvedAxialMM` / `resolvedDepthMM` (used by the run spec + rendered volume) are
  now thin readers over it.

Both chips (`clearanceHandleChip`, `manualPrimitiveLine`, `clearancePrimitiveLine`)
and the drag-write now call `clearanceMetric` / `writeClearanceMetric`. And
`ProjectModel.resolvedClearances` (the rendered volume AND the run) sources its
distances from `clearanceMetric` too — so panel, chip, picture and run are literally
one value.

### G1 test — fails if they can diverge

`ManualPrimitiveTests`:
- `testManualBoltMetricIsOneValueAcrossSurfaces` — a manual bolt's margin/axial resolve
  to radius / 2·radius (non-zero), and the rendered `ClearanceVolume`'s cylinder radius
  and axial span are built from the identical number. Fails the instant `clearanceMetric`
  stops handling the negative (manual) faceID — i.e. the exact regression.
- `testManualPlaneMetricIsOneValue` — the plane (which agreed on device) still agrees.
- `testAutoBoreMetricMatchesRenderedVolume` — the other origin reads the same source.
- `testWriteClearanceMetricReachesManualPrimitiveAndRun` — a viewport-handle write lands
  on the primitive's own override AND the serialized run spec (not a phantom slot).

---

## DEFECT 2 — the transform gizmo

A Shapr3D-style **affordance set** in TopOpt's own blue liquid-glass gizmo language
(matching the design-box `move.3d` handle and the 109 gizmo frost). Attached to the
active group's manual primitives: each shows a select knob; the selected one shows the
full gizmo.

Affordances (all required ones present):
- **translate along one axis** — lettered X/Y/Z knobs at the arrow tips (`Handle.axis`);
- **translate in a plane** (two axes) — square knobs per principal plane (`Handle.plane`);
- **translate freely** (all three) — the centre `move.3d` knob, camera-facing plane
  (`Handle.free`);
- **rotate about an axis** — a `rotate.3d` ring knob per axis (`Handle.rotate`);
- **copy** — the `plus.square.on.square` button (`ProjectModel.copyManualPrimitive`).

### Layers

- **Pure, headless-tested** (`PrimitiveGizmo.swift`, 8 tests in `PrimitiveGizmoTests`):
  the ray↔plane / ray↔axis math, `rotate(_:about:radians:)`, `ringAngle`, the grab-drag
  `resolve`, and the knob-anchor layout. All in model space; no jump at grab; degenerate
  geometry is a safe no-op.
- **Model ops** (`ProjectModel`, tested in `ManualPrimitiveTests`):
  `moveManualPrimitive(…snap:)`, `rotateManualPrimitive`, `copyManualPrimitive`,
  `convertAutoClearanceToManual`.
- **Device-QA'd** (`WorkspacePlaceholder.primitiveGizmoOverlay` + gestures): the SwiftUI
  knobs, the touch→ray plumbing, the haptics/badge. Compiles for iOS; the touch feel is
  the maintainer's device step (see G8).

### Magnetic detents — what, radius, override

Reuses PR 190's `ManualPrimitiveDetent` (unchanged math):
- **Snaps to:** the world principal axes (X/Y/Z), existing group primitives' axes
  (co-axial / parallel) and centres, and the group's **part-face bore axes/centres** —
  each reported with a human label ("world Z axis", "bore axis", "primitive 2 centre").
- **Snap radius:** `distanceTolMM = 3.0 mm` for centres/lines, `angleTolDeg = 8°` for
  axis alignment.
- **Override (two ways):** the gizmo's **magnet toggle** (`scope` knob) disables detents
  for the next drag (`snap: false` → no targets); OR simply drag **past** the 3 mm / 8°
  tolerance — `apply` only snaps within tolerance, so a farther placement releases. The
  active drag states what it snapped to via the "Snapped to: …" badge + a haptic.

### G2 — both kinds, both origins; the auto→manual decision (stated + explicit)

The pure math is kind-agnostic (it moves `center` / turns `axis`), so it serves cylinder
and plane identically. For origin: a **manual** primitive is edited directly. An
**auto-found** primitive's geometry is DERIVED from its B-rep face and re-read core-side
every run — there is **nowhere to store a dragged centre/axis**.

**Decision:** grabbing an auto primitive's gizmo **converts it to a manual primitive**.
`convertAutoClearanceToManual(face:in:)` materialises the face's current resolved
geometry (axis/radius/half-length or origin/normal/half-extents) as a `ManualPrimitive`,
carries the exact override over (so no value jumps), and **suppresses the auto face**.
The conversion is **explicit in the model** — a real `ManualPrimitive` + a suppressed
face — never implicit. `testConvertAutoBoreToManualPreservesTheClearance` proves the
clearance count and resolved value are unchanged. The UI entry is a `move.3d` button on
each auto clearance row (active group only).

### G3 — one UndoHistory

Every gizmo op mutates `@Published force` through a `ProjectModel` method
(`moveManualPrimitive` / `rotateManualPrimitive` / `copyManualPrimitive`), so the
existing debounced auto-commit (`installUndoAutoCommit`) coalesces a drag into one undo
step — the same path PR 190's move used. No parallel history.
`testRotateManualPrimitiveTurnsAxisKeepsCentreUndoable` covers rotate; move/add/delete
were already covered.

### G4 — the moved geometry reaches the job

`ManualPrimitive.spec()` reads `center` / `axis`, so a dragged/rotated primitive
serializes its new geometry. `testGizmoMoveReachesTheJob` resolves a translate through
the SAME pure math the gesture uses, commits it, and asserts the serialized
`ManualGeometry.axisPoint` equals the dragged centre (and the rendered volume centres
there too — B2 for a dragged primitive). `testRotatedAxisReachesTheRun` does the same
for `axisDir`.

### G5 — does not fight the camera

Every knob binds its gesture to the **sized knob BEFORE `.position`** (the clearance-
handle rule) inside a named coordinate space (`primitiveGizmoStage`), so a touch on a
knob owns the drag and empty space falls through to orbit — and, symmetrically, an orbit
touch never lands on a knob. This is a SwiftUI **gesture-arbitration** property; the
headless suite cannot drive it, so — like PR 190/121 — it is a **device-QA** assertion
(G8). The mechanism is identical to the shipped, working clearance handles.

### G6 — copy is independent

`ManualPrimitive` is a value type; `copyManualPrimitive` inserts a fresh-id duplicate,
nudged clear of the original. `testCopyProducesIndependentPrimitive`: editing the copy's
margin leaves the original untouched; distinct ids + centres.

### G7 — chips never two rows high

The Selections-panel chip layout is unchanged (number-only pill + caption-outside, one
metric per row); the fix only swapped the *value source*. The gizmo's snap badge is a
separate floating overlay, not a chip.

### G8 — device-real evidence (maintainer step)

This is a touch-manipulation feature and **cannot be verified in a simulator**. I have
no device, so I could NOT produce device-real evidence. What IS proven here: all pure
math + model ops + undo + serialization are green headlessly (86 tests across the
touched suites), and the interactive layer **compiles for iOS** (`xcodebuild -scheme
TopOptFlows -destination generic/platform=iOS` → BUILD SUCCEEDED). The on-device touch
QA — grab each handle, confirm the camera never orbits mid-drag and orbit never nudges a
primitive, feel the detents, verify the "Snapped to" badge — is the maintainer's step,
consistent with PR 190's B7 and handoff 103's Phase-B device-QA posture.

---

## BLOCKED-STOP — rotation vs the PR 190 schema (checked; NO field added)

The task said: report what is missing before adding a field; rotation may already be
expressible by rotating the direction vectors — check first. **It is.**

- A **bolt** carries `axis_point / axis_dir / radius / half_length`. A cylinder is
  rotationally symmetric about its own axis, so its entire orientation IS `axis_dir` →
  rotating that unit vector covers every bolt rotation. Fully expressible.
- A **face** carries `origin / normal / half_u / half_w`. Its plane is fully defined by
  `normal` + `origin`; the in-plane (u,v) basis is DERIVED from the normal
  (`planeBasis`). Rotating the normal covers every face rotation **except a spin about
  the normal itself** — and that spin is a **no-op for the square manual slab**
  (`halfU == halfW` by construction, `defaultFace`), so it changes no geometry and needs
  no stored orientation.

Therefore rotation is expressed **entirely by rotating `ManualPrimitive.axis`** (the
direction vector), and **no field was added** to the clearance geometry schema. The one
thing not expressible (a non-square face's in-plane spin) does not arise for the manual
primitives that exist. If non-square, in-plane-orientable slabs are ever wanted, THAT is
when a stored u-axis would need adding — flagged here, not added now.

---

## Files

Changed:
- `ClearanceGeometry.swift` — `ClearanceMetric` value type; `ClearanceHandle.Role.metricRole`.
- `ManualPrimitive.swift` — `metric(_:)` single source; `resolved*` readers over it.
- `ProjectModel.swift` — `clearanceMetric` / `writeClearanceMetric`; `resolvedClearances`
  sourced from them; `rotateManualPrimitive` / `copyManualPrimitive` /
  `convertAutoClearanceToManual`; `moveManualPrimitive(…snap:)`.
- `WorkspacePlaceholder.swift` — all clearance chips + drag-write routed through the
  single source; the transform-gizmo overlay, gestures, knobs, auto→manual entry,
  select-on-add.

New:
- `PrimitiveGizmo.swift` — the pure transform math + knob-anchor layout.
- `PrimitiveGizmoTests.swift` — 8 pure-math tests.
- `ManualPrimitiveTests.swift` — +9 tests (DEFECT 1 divergence guard + gizmo model ops).

## Evidence

`evidence/2026-07-26-primitive-gizmo/`: `tests.txt` (86 tests, 0 failures across the
touched suites), `builds.txt` (macOS package + iOS BUILD SUCCEEDED), `diffstat.txt`.

Note: the full `swift test` run shows a signal-11 in a GPU-touching suite — the
documented flake (memory `app-swift-test-gpu-flake`: intermittent SIGTRAP under xctest,
passes in isolation, not real); all touched suites pass cleanly in isolation.

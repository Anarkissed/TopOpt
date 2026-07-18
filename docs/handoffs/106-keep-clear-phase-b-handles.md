# 106 — Keep-clear Phase B: drag handles + liquid-glass value pill

**Status:** DONE (code complete). App-only change under `/app/TopOptKit`. Builds are
`xcodebuild`/macOS — the maintainer's device-QA standard (this package is NOT covered
by Linux CI, per `Package.swift`), and I could **not** run `xcodebuild`/`swift test`
in this environment (Linux, no Xcode toolchain). See **Evidence** for exactly what is
verified vs. what remains device QA. No core, no bridge, no wire-format change.

**Handoff-number note:** main tops at **104**. Two sibling tasks are in flight tonight
(the orientation-gizmo reskin and the results/export task); each takes its own free
number ≥ 105. This task is **105**. Handoff files are uniquely named, so even if a
sibling also computes "105" the files never collide (the repo already carries
duplicate numbers, e.g. 086/088/089); the descriptive filename is the real key.

**Foundation consumed (merged, handoff 103/104):** `ClearanceDragMath` (pure
screen-ray → mm math), `ClearanceVolume` red render items in MetalMeshView, the affix
model + per-group `ClearanceOverride`, the "Auto · N mm" labels. Phase B was
Blocked-stopped ONLY on the gesture wiring — that is now done, plus the value-UI
redesign.

---

## Part A — the drag handles

**What ships:** each rendered clearance volume grows draggable knobs in the viewport:
- **cylinder WALL** → radial drag sets the concentric **margin**;
- each **END CAP** → axial drag sets the axial **clearance length** (independently per
  side);
- **slab FACE** → normal drag sets the **depth**.

A pan on a knob builds the per-frame camera ray, runs it through `ClearanceDragMath`
(via the new pure `ClearanceHandle.value`), and **writes the mm continuously** during
the drag — the volume re-tessellates live through the existing Equatable-gated
`clearanceVolumes` path. The first write flips the field **Auto → explicit** (setting
any override does that). Haptics fire on grab, on release, and when the dragged value
**crosses its Auto suggestion**. **Degenerate volumes get NO handles** (a bolt affixed
to a non-cylinder face, etc.) — `ClearanceHandles.handles` returns `[]` and
`ProjectModel.clearanceHandles()` drops the entry.

**Not fighting the orbit camera:** the knobs use the *same* proven pattern as the
design-box gizmo — each `DragGesture` is bound to the SIZED knob view **before**
`.position(...)`. A gesture applied *after* `.position` fills the whole stage and
swallows orbit/zoom; bound before, only a touch that actually lands on a knob owns the
drag, and everywhere else the touch falls through to the Metal view and orbits exactly
as today. Two-finger gestures are unaffected (pinch/orbit still reach the MTKView).
Hit targets are generous (~46pt: a 22pt knob with a `contentShape(Circle().inset(-12))`).

### New pure, headless-tested pieces (Part A)
- `ClearanceHandle` (in `ClearanceGeometry.swift`) — role + anchor + the fixed
  bore/plane geometry; `settled(center:rotation:)` rigidly re-poses it into
  settled-world space (rotations preserve distances/axis-params, so the mm is
  invariant), and `value(rayOrigin:rayDir:)` dispatches to `ClearanceDragMath`.
- `ClearanceHandles.handles(for:boreRadiusMM:axialSpan:)` — the anchor placement
  (wall at mid-length, caps at tLo/tHi, slab at the outer face), fed the **fixed** bore
  facts (radius + tessellation span) so the drag measures against a stable reference
  even as the volume grows under the finger.
- `CameraProjection.ray(throughViewPoint:)` (in `OrbitCamera.swift`) — the pure
  inverse of `project`; unprojects the near/far clip points of the pixel. This is the
  screen→world-ray seam the drag uses, driven off the SAME published projection the
  volumes were drawn with.
- `ProjectModel.clearanceHandles()` — built from a new shared `resolvedClearances()`
  helper that `clearanceVolumes()` now also flows through, so the picture and the
  handles can never derive from different numbers.

`ForceModel` was **not** changed: the existing `setClearanceMargin/Axial/Slab` are
plain setters that already write continuously and flip Auto→explicit, so no live-drag
variant of the override API was needed (as the task allowed only-if-needed).

---

## Part B — the liquid-glass value pill

`GlassValuePill` (new, `GlassValuePill.swift`) replaces the plain margin/axial/slab
text fields. It is dark ultra-thin-material glass with a soft inner sheen and a
rounded-squircle, from the TopOptDesign tokens (extended, not hardcoded):
`DS.Surface.valuePill`, `DS.Radius.valuePill`, `DS.Color.clearance` (the shared
keep-out red — `clearanceTint` now points at this token). Each pill has:
- a **big legible number + unit**, **scrubbable** horizontally with Shapr3D-style
  precision — the pure `ClearanceScrub` gives a slow finger fine steps and a fast flick
  coarse ones;
- **tap to type** (a numeric field, decimal keypad on iOS);
- an **"Auto" chip** shown when the value is auto-derived, displaying the real derived
  mm as the big number;
- a **↺ reset** to Auto once an explicit value is set.
- **Dynamic Type**: the number size is a `@ScaledMetric`, so it scales.

**Placement:** a floating pill cluster anchors just above the ACTIVE clearance
selection's projected centroid when it projects on-screen; the Selections row carries
the always-reachable compact copy (both write the same override, like the weight
pill). During a Part-A handle drag the SAME floating pill is the live readout (it reads
the override the drag writes, and its border lights up for the role being dragged).

Values are mm always (the task's kg/lbs aside is a no-op here). Value changes animate
the red volume via the existing live re-tessellation.

---

## Files touched (territory-compliant)
- `TopOptFlows/ClearanceGeometry.swift` — +`ClearanceHandle`, `ClearanceHandles`,
  `ClearanceScrub` (pure).
- `TopOptFlows/OrbitCamera.swift` — +`CameraProjection.ray`.
- `TopOptFlows/ProjectModel.swift` — +`resolvedClearances()` (shared), +`clearanceHandles()`.
- `TopOptFlows/WorkspacePlaceholder.swift` — handle overlay + gesture routing + floating
  pill; `clearanceEditor` now uses `GlassValuePill`; removed the old
  `clearanceField`/`mmString`.
- `TopOptFlows/GlassValuePill.swift` (new), `TopOptFlows/ClearanceHaptics.swift` (new).
- `TopOptDesign/DesignSystem.swift` — +`Color.clearance`, +`Surface.valuePill`,
  +`Radius.valuePill`.
- Tests: `ClearanceGeometryTests`, `CameraProjectionTests`, `ClearanceDerivationTests`.

NOT touched: ResultsScreen / ResultsModel / OutcomeStore (export task), OrientationGizmo*
(gizmo task), MetalMeshView (the render already consumed `ClearanceRenderItem` from
103; no change was needed — handles live in the SwiftUI overlay, like the design-box
gizmo). Core/bridge untouched.

---

## Evidence

**Headless tests added (the pure, xcodebuild-testable parts):**
- `ClearanceGeometryTests`:
  - `testCylinderHandlesAnchorsAndGeometry`, `testSlabHandleAnchorAndGeometry`,
    `testDegenerateVolumeHasNoHandles` — **anchor projection / placement** + degenerate
    honesty.
  - `testMarginValueWritePathFromRaySequence`, `testAxialAndSlabValueWritePath` — the
    **value-write path, drag simulated as a ray sequence**.
  - `testSettledHandlePreservesValueUnderRigidTransform` — model↔world invariance the
    world-space drag relies on.
  - `testScrubStepIsFinerWhenSlow`, `testScrubDirectionAndClampAtZero` — the precision
    scrub curve.
- `CameraProjectionTests`: `testRayThroughProjectedPointHitsThatPoint`,
  `testRayThroughViewportCentreLooksAtTarget`, `testRayNilOnDegenerateViewport` — the
  **screen→ray (hit-test) math** as the exact inverse of `project`.
- `ClearanceDerivationTests`: `testBoreHandlesMatchTheRenderedVolume`,
  `testSuppressedBoreHasNoHandles`, `testExplicitPlaneAffixAddsDepthHandle` — the
  ProjectModel wiring end-to-end on the octagon bore+plane fixture.

**xcodebuild / swift test:** NOT run here — this environment is Linux with no Xcode/Swift
toolchain, and the app package needs SwiftUI/MetalKit (Apple-only). The maintainer must
run `xcodebuild test` on the TopOptKit package on macOS to confirm green (app + package),
the M7 `/app/` standard. The new tests are pure value-type math + the projection seam,
consistent with the existing headless suite they sit in.

**Screenshots — split honestly:**
- *Captured:* none. I cannot render SwiftUI/Metal in this environment, so there are no
  pixels to show.
- *Code-derived (what the code will draw, not a rendered image):* red glass knobs
  (wall = ↔, +cap = ↑, −cap = ↓, slab = ⤒ glyphs) at each volume's projected wall/caps/
  face; a floating dark-glass value pill above the selected clearance with a big mm
  number, an "Auto" chip when auto, and a ↺ once explicit; the pill border tinting red
  for the role being dragged.

**Honest limitations / device-QA list (NOT verified — needs a device/simulator):**
1. The touch layer itself: that a knob reliably wins the gesture vs. orbit on a real
   iPad, and that ~46pt targets feel right under a finger. (The *pattern* matches the
   shipping design-box gizmo; the specific knob feel is unverified.)
2. Haptics (`ClearanceHaptics`) — grab/release/cross ticks are UIKit-only and fire on
   device; nothing pinned them (there is no pure part to a UIImpactFeedbackGenerator).
3. The named-coordinate-space alignment between the overlay and the MTKView projection
   (the overlay fills the stage and shares the projection origin by construction, but
   pixel alignment is a render-time fact).
4. Visual polish of the "liquid glass" — the tokens/recipe follow the existing glass
   vocabulary, but the actual blur/sheen look is a rendered fact I did not capture.
5. Dynamic Type layout at the largest accessibility sizes (the number scales; the pill's
   surrounding layout wrap at extreme sizes is unverified).
6. A group with MANY cleared bore faces shows a handle set per face; all write the one
   per-group override (consistent with the panel). Interaction with dense handle
   clusters on a small part is unverified.

---

## Follow-ups / notes for the next hop
- If handle clutter is a problem on parts with many bores, consider showing handles only
  for the ACTIVE clearance group (the data + overlay already know `activeGroupID`).
- The floating pill and the row pill both edit the same override; if that feels
  redundant on device, gate the row pill off while the floating one is up.

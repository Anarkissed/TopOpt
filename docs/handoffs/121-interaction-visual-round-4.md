# Handoff 121 — Interaction / visual round 4 (maintainer device punch list)

Branch: `claude/round-4-interaction-visual-03a436`, on top of `main` through #147 (which merged
handoff 120, the round-3 finisher). App only, **no core**.

Numbering: latest handoff on `main` is 120, so this is **121**. Cross-lane check (per the task):
the only open PR is **#146 `mma-heaviside-production-flip`** (Lane B) — it touches only
`core/**` + `core/tests/**` and adds `docs/handoffs/119-mma-heaviside-production-flip.md` (a
mislabelled number, but core-only). **No file or code overlap with this app-only lane.**

## Verification honesty (read first)

This session ran on the **macOS toolchain with a real GPU**, so `swift test` is self-run and the
GPU tests actually execute. Split:

- **Headless-tested (named below):** the face-deselect routing (1), the camera pan math + Home
  reset (2), the per-group/per-bore sync (3), the detent drag *pipeline* (5).
- **Absorbed + GPU-verified (item 6):** the embedded-look shaders shipped in **120** and are
  green on this branch (`ContactShadingTests`, 6/6 incl. before≠after for both consumers + the
  bounded frame-cost). Not re-implemented — verified.
- **Device-QA feel (no pure part to pin):** the two-finger-pan *gesture wiring* + sign, the chip
  restyle/adjacency look, the detent haptic/pulse feel. Keyed in the checklist below.

`swift test --no-parallel`: **611 tests, 1 skipped, 0 failures.** (The 120-era
`ClearanceDerivationTests.testBoreHandlesMatchTheRenderedVolume` failure is **gone** — fixed by
`618e7a3` on the way to this branch.)

## What changed, by punch-list item

### 1. Face deselect — `WorkspaceInteraction.route`
The old rule was "a tap never removes". Now a tap on a face **in the ACTIVE group deselects it**
(the tap-toggle `SelectionModel.pickFaces` already implements — the router now lets it through);
emptying the active group drops it (existing cleanup, via `clearActive`). A face in an **inactive**
group still just re-selects that group (no steal, no toggle) — removal there is still the trash
icon. Tests (`WorkspaceInteractionTests`): `testTapAFaceInTheActiveGroupDeselectsIt`,
`testTapTheOnlyFaceInTheActiveGroupDropsTheGroup`, `testTapDeselectDoesNotTouchInactiveGroups`
(the old `…ChangesNothing` test is replaced).

### 2. Two-finger pan — EVERY 3D view (workspace AND results)
`OrbitCamera` gains `pan(dx:dy:viewportHeight:)` (slides the look-at `target` in the view plane,
world-per-pixel from the frustum so the grab tracks 1:1 at any zoom; roll-aware like `orbit`) and
`resetPan()` (returns `target` to the framed centre `homeTarget`, captured by `init`/`frame`).
`OrbitCameraModel.pan(…)` wraps it (cancels a running snap); **`home()` now calls `resetPan()`** so
Home clears the pan. Gesture wiring in `MetalMeshView` (shared by every viewer, so results gets it
for free): iOS `handlePan` branches on `numberOfTouches` (≥2 → pan, else orbit) and the pan+pinch
recognizers are made to fire **simultaneously** (two-finger pan while pinch-zooming; tap stays
exclusive) via a `UIGestureRecognizerDelegate`; macOS uses **Option-drag** to pan (a two-finger
trackpad drag isn't a pan-recognizer event there). Tests (`ViewerTests`):
`testPanMovesTargetInTheViewPlane`, `testPanSignsFollowTheCameraBasis`,
`testPanThenOrbitOrbitsAboutTheNewTarget`, `testResetPanReturnsToFramedCentre`,
`testPanIgnoresDegenerateViewport`; (`OrientationGizmoTests`) `testHomeResetsPan`.
**Device QA:** the grab-pan sign (content-follows-finger) and the pan/pinch feel.

### 3. Sync scope correction — per-group, per-bore (`ForceModel`)
Round-3 coupled **across groups** (a global checked-set fan-out). Corrected to **within-group**
scope, per the maintainer + the follow-up clarification ("option 1, and each icon gets its own chip
when sync = off"):
- A group's **Sync flag** (`syncExcluded`, per group, default checked) couples its OWN bores;
  **groups never couple**.
- **Synced (default):** the group edits its one shared `clearanceOverrides[group]` — every bore
  reads it. This is the pre-round-4 storage/wire, so the default path is **byte-identical**
  (`ProjectModel` now resolves `clearanceOverride(forGroup:face:)`, which returns the shared value
  when synced).
- **Unsynced:** each bore edits its own `clearanceBoreOverrides["group:face"]` (new optional map)
  and is independent; unchecking **seeds** each bore from the shared value (keeps current numbers),
  re-checking **drops** the divergence (adopt the shared value / Auto). API:
  `setClearance{Margin,Axial,Slab}(group:face:mm:)`, `clearanceOverride(forGroup:face:)`,
  `setClearanceSynced(_:_:boreFaces:)`. Tests (`ForceModelTests`, rewritten):
  `testSyncedGroupBoresShareOneValue`, `testUnsyncedGroupBoresAreIndependent`,
  `testUncheckSeedsBoresFromShared`, `testRecheckAdoptsSharedDroppingDivergence`,
  `testRecheckAdoptsAutoWhenSharedUnedited`, **`testTwoGroupsNeverCrossTalk`** (the fix),
  `testSyncedDepthSharesWithinGroupIndependentOfMargin`, `testMembershipAndBoreOverridesPersist`,
  `testSyncRetainsLiveGroupBoreOverrides`, `testSyncDefaultsChecked`.

### 4. Chip unification — margin/axial match the load-weight pill
`GlassValuePill` restyled to **match the "100 lbs" weight pill exactly**: one inline row, dialog-
surface capsule ("glass"), 14 pt heavy number, with MARGIN/AXIAL kept as a small text title only
(this overrides the blue liquid-glass look 109 gave the chips). **Right-aligned everywhere:** the
Selections-row cluster sits `.trailing` under the trash icon (unchanged from 115); the **viewport
chips are now ONE chip PER HANDLE**, positioned right beside their handle icon (adjacency is the
point — each chip belongs to its handle) — which is also what item 3's unsynced mode needs (each
margin/axial/depth icon carries its own editable value). Restructured `clearanceValuePill` from a
per-group cluster to a per-`ClearanceHandleItem` chip; `writeClearance` + the chips now carry the
`faceID` so edits are per-bore.

### 5. Detent — verified live + integration-tested
The round-3 snap math + the 120 face-highlight **pulse** and **haptic** are present and wired
(`applyBoxDrag` → `boxFaceDetent` → `flashDesignBoxDetent` → `MeshViewInputs.detentPulse`;
`ClearanceHaptics.detent()`). To prove the *gesture path* engages it (not just the pure math), the
whole face-drag detent composition (candidates → hysteresis resolve → `movingFace` → `matchedFace`)
is extracted into one pure `DesignBoxDetent.applyFaceDrag(…)`, and **`applyBoxDrag` now calls it** —
so the gesture and the test share the exact path; a dead wire fails the test. Tests
(`DesignBoxTests`): `testFaceDragPipelineSnapsHoldsAndReleases` (a 3-frame drag: enter → hold →
release, box face lands on the snapped coord, matched face id returned), `testFaceDragSnapToAABBExtentHasNoFace`
(AABB-extent snap fires but returns no face → haptic only). Pulse colour/duration + haptic feel are
device QA (120).

### 6. Embedded look — absorbed from 120, verified (NOT re-implemented)
The depth-prepass → single `contact` shader (bright contact line + interior occlusion), shared by
BOTH the design-box glass and the clearance faces, static per the 108 rule, with the grazing-angle
caveat baked into the shader header — all shipped in **handoff 120** and merged via #147, so it is
already on this branch. Verified green here: `ContactShadingTests` (compile + pipeline build +
`testContactChangesPictureForClearanceCylinder`/`…DesignBox` before≠after +
`testDepthPrepassFrameCostIsBounded` idle-delta ≈ 0 + the detent-pulse render test). Captures live
at `docs/handoffs/assets/120_contact_{cylinder,box}_{before,after}.png` (the ContactShadingTests
before≠after assertions are the standing regression guard so the effect can't silently regress).

## Files touched
- `OrbitCamera.swift` (pan/resetPan/homeTarget), `OrbitCameraModel.swift` (pan wrapper, home resets pan)
- `MetalMeshView.swift` (two-finger/Option pan wiring, simultaneous pan+pinch delegate)
- `WorkspaceInteraction.swift` (+ tests) — face deselect
- `ForceModel.swift` (+ `ForceModelTests` rewrite) — per-group/per-bore sync
- `ProjectModel.swift` — per-bore override resolution (synced → shared, byte-identical default)
- `WorkspacePlaceholder.swift` — per-handle viewport chips, per-bore writes, group-scoped sync checkbox
- `GlassValuePill.swift` — weight-pill match
- `DesignBox.swift` (+ `DesignBoxTests`) — `applyFaceDrag` pipeline
- `ViewerTests.swift` (pan), `OrientationGizmoTests.swift` (home resets pan)

## Device-QA checklist (keyed to the 7 device notes)
1. **Face deselect:** tap a face in the active group → it drops out; tap the last face → the group
   disappears; a face in another group still re-selects that group.
2. **Two-finger pan (workspace):** two-finger drag translates the view in-plane; one finger still
   orbits; pinch still zooms (and can pan+zoom together); a two-finger drag with ~no pinch reads as
   pure pan; content tracks the finger.
3. **Two-finger pan (results):** same, in the results 3D viewer.
4. **Home resets pan:** pan away, then Home — the view recentres (and un-rolls, unchanged).
5. **Sync scope:** a group's several bores share margin/axial when its Sync box is checked; uncheck
   → each bore edits independently (its own on-model chip); two separate keep-clear groups never
   affect each other's numbers.
6. **Chips:** the margin/axial/depth chips (row AND viewport) look like the "100 lbs" pill (same
   capsule/size/number), each viewport chip sits right beside its handle icon; row chips are
   right-aligned under the trash.
7. **Detent + embedded look:** drag a design-box face toward a part face → it snaps (~1.5 mm) with a
   haptic tick and the matched part face PULSES (no toast); keep-clear cylinders + the box read as
   embedded in the part (clean contact line + interior shadow, no z-fight shimmer).

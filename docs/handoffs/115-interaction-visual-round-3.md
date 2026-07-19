# Handoff 115 — Interaction / visual round 3 (maintainer device punch list)

Branch: `claude/interaction-visual-round-3-drvj1u`, on top of `main` (through #138). The open
Metal-NO-GO PR (#139) takes the next number **113**, so this is **114**.

Territory: `OrbitCamera` / `OrbitCameraModel`, `OrientationGizmo*`, `WorkspacePlaceholder`,
`GlassValuePill` / `ClearanceSyncCheckbox` (repurposed), `ClearanceGeometry`, `ForceModel`
(sync semantics), `DesignBox`, `ClearanceHaptics`, `MetalMeshView`. App only.

## ⚠️ Verification honesty (read first)

This round was implemented in a **Linux CI container with no Swift toolchain and no Metal
GPU**. Unlike prior rounds I could **NOT** self-run `swift build` / `swift test`, and I could
**NOT** capture headless GPU renders. Every change was made by careful reading against the
existing patterns, and the pure logic is covered by new/updated **headless XCTest** cases — but
those tests have **not been executed here**. Concretely, the task's evidence requirements that
remain **UNFULFILLED and are required maintainer follow-ups on macOS**:

- **`swift test` green self-run** — not run here. Please run `swift test --no-parallel` (the
  known GPU-parallel SIGTRAP flake, [[app-swift-test-gpu-flake]]; fresh worktree needs
  `app/scripts/build_core.sh` first, [[app-worktrees-need-build-core]]).
- **Before/after intersection renders** (items 7+8, the 112 precedent) — not captured here (no
  GPU). See item 7+8 below for exactly what to capture.

Where a change is device-QA feel (SwiftUI Canvas, Metal, haptics) I say so; where it is pure and
headless-tested I name the test. Treat anything not headless-tested as **needs device QA**.

## What changed, by punch-list item

### Camera (items 1, 2, 13)

1. **Gizmo roll ±15°→±45°/tap** — `OrientationGizmoView.rollStep` is now `.pi / 4` (was
   `.pi / 12`). One constant drives both arrows, so the ⟲/⟳ pair stays symmetric. Comments
   updated. Roll is device-QA feel; the constant is trivially correct.

2. **Roll-aware orbit** — `OrbitCamera.orbit(dx:dy:)` now decomposes the screen drag in the
   CAMERA frame before mapping to azimuth/elevation: it rotates `(dx, dy)` by `R(−roll)` (the
   image rotates by `+roll` in the y-down screen space; see the derivation in the code comment
   on `up`). So **screen-down always moves the view down regardless of roll** — the 074 roll-pin's
   exact concern, resolved screen-relatively now that roll exists. At `roll == 0` the rotation is
   the identity, so behaviour is **bit-identical** to before. Snap/Home still level roll (unchanged).
   Headless tests (`OrientationGizmoTests`): `testRollZeroOrbitIsBitIdenticalToClassic`,
   `testRollNinetyScreenDownDrivesAzimuthNotElevation` (at 90° a screen-down drag changes what it
   must — azimuth, elevation held), `testRollFortyFiveIsTheRotatedDelta` (the exact −roll delta).

13. **Swoosh body 180° flip** — in `RotateButton.draw`, the tube arc was
    `addArc(…, startAngle: 200°, endAngle: −20°, clockwise: true)`, which in Canvas' y-down space
    sweeps **through the bottom (90°)** — putting the body 180° off from the (correct) arrowhead
    and sheen, which ride the top. Now `endAngle: 340°, clockwise: false` sweeps **through the
    top (270°)**, so the body rejoins its highlight and matches the mock's `rotL` minor arc. The
    arrowhead + sheen geometry are **unchanged**, and the whole-Canvas mirror keeps the pair
    mirrored. **Device QA:** Canvas arc direction is exactly the kind of thing to confirm on
    screen against `docs/design/gizmo_redesign.html`; the fix is derived from CoreGraphics
    `addArc` semantics but not rendered here.

### Clearance chips + sync (items 3, 4, 5, 6, 9, 12)

3. **On-model chips always visible** — `clearanceValuePill` was gated on the ACTIVE group; it now
   `ForEach`es `keepClearChipGroups` (every keep-clear site with an editable shape), rendering a
   compact chip cluster per site anchored beside its handle. Chip size dropped to the weight-label
   class (`compact: true`, smaller than "See Results" — the round-2 correction). **Device QA:** the
   precise "immediately next to its handle icon" anchor is a screen-space offset (`pt.y − 40`) to
   tune on device.

4. **Selections-row chips right-aligned below trash** — `groupRow` is now a trailing-aligned
   `VStack`: the name/kind row on top, then `clearanceEditor(g)` beneath it, `.frame(maxWidth:
   .infinity, alignment: .trailing)` so the chips sit at the row's trailing edge under the trash.

5+6. **Per-row sync membership (109 global toggle dies)** — `ForceModel.syncClearances: Bool` is
   removed; membership is now per row via `syncExcluded: Set<UUID>` (default checked → only
   exclusions stored). `isClearanceSynced(_:)`, `setClearanceSynced(_:_:peers:)`, and the rewritten
   `syncTargets` implement it: a CHECKED row's edit fans out to every checked peer; an UNCHECKED row
   is independent. **Adopt-on-check (chosen + stated):** re-checking a row copies the shared group's
   current override (a checked peer's value), or reverts to Auto when the shared group has no edit
   yet — so it resumes sending the 0 sentinel. The on-model checkbox is **withdrawn**; the
   checkbox now lives in each keep-clear row (`ClearanceSyncRowCheckbox`, always enabled). Legacy
   `syncClearances` key is decoded-and-dropped for back-compat. Headless tests (`ForceModelTests`):
   `testEditCheckedWritesCheckedOnly`, `testUncheckedRowIsIndependent`, `testRecheckAdoptsSharedValue`,
   `testRecheckAdoptsAutoWhenSharedUnedited`, `testUntouchedCheckedRowStaysAutoUntilSharedEdit`,
   `testMembershipPersists`, `testLegacySyncClearancesKeyStillDecodes`. `SyncCheckboxState` and its
   round-2 tests are removed (`DesignOverhaulRound2Tests` now pins only the default-checked row).

9. **One axial icon per cylinder** — `ClearanceHandles.handles` appended both `.axialHi` and
   `.axialLo`; it now appends only `.axialHi`. The axial clearance is a single symmetric value
   (`tLo = span.lo − axial`, `tHi = span.hi + axial`), so the second cap was redundant and the
   drag math resolves either end from the one handle. Test: `testCylinderHandlesAnchorsAndGeometry`
   now expects **2** handles (wall + one cap) and asserts the `.axialLo` icon is gone.

12. **0.25 mm quantization** — new pure `ClearanceQuantize.snap(_:step:)` (0.25 mm grid, clamped
    ≥ 0). Wired live into the scrub pill (emits snapped while accumulating raw), the handle-drag
    write (`writeClearance`), and typed commit (rounds on commit). Auto stays Auto (never
    quantized — `onSet(nil)` untouched). Tests (`ClearanceGeometryTests`):
    `testQuantizeSnapsToQuarterMillimetreGrid`, `testQuantizeNeverNegativeAndFloatMatchesDouble`.

### Intersection quality (items 7, 8) — PARTIAL, honesty required

The translucent keep-clear cylinders and the design-box glass pass through the part and read
choppy: **z-fighting shimmer** + a jagged contact. The requested treatment has three parts:
(a) depth bias to kill z-fighting, (b) a bright screen-space CONTACT LINE where fragment depth ≈
scene depth, (c) a contact-occlusion darkening just inside.

**Shipped (part a, safe + verifiable-by-reading):** both translucent FACE passes (design box +
clearance) now set a small polygon `setDepthBias` (`translucentDepthBias = −3.0`, slope `−1.5`)
around the face draws only (reset before the crisp edge lines). This pulls the translucent
fragments a hair toward the camera so a near-coincident tie with the part resolves cleanly instead
of shimmering. Static render state on those draws only — **no per-frame CPU work (108 rule)**.

**NOT shipped (parts b + c):** the bright contact line and the contact-occlusion darkening
**require the opaque scene depth texture to be readable by the translucent fragment shader**, which
is a real pipeline restructure (today the box/clearance faces reuse `groundPipeline` and there is
no depth prepass texture bound to the fragment stage). I did **not** attempt that restructure here
because I **cannot compile or run Metal** in this environment, and a wrong change to the Swift
pipeline plumbing would break the whole `TopOptFlows` build — poisoning the `swift test` run for
all the other (tested) items. Shipping unverifiable pipeline surgery is the wrong trade.

**Ready-to-apply plan for parts b + c (do on macOS, then capture):**
1. Add a **depth prepass**: render the opaque part into a `MTLTexture` (`depth32Float`, or a color
   R32Float holding linear-or-clip depth) sized to the drawable. Bind it to the translucent
   box/clearance fragment shader as `[[texture(0)]]` plus a sampler.
2. In the translucent fragment (a variant of `ground_fragment`), read `sceneDepth` at the
   fragment's `position.xy` (use `[[position]]`), compute `d = |fragDepth − sceneDepth|` in a
   linearized space, then: **(b)** add a bright additive contact term `smoothstep(feather, 0, d)`
   (~1–2 px feather) to the volume colour where `d` is near 0; **(c)** multiply the interior by a
   cheap occlusion gradient `mix(shadow, 1, saturate(d / band))` just inside the contact.
3. Apply the SAME mechanism to **both** the cylinder and box passes (one shader variant, two
   consumers).
4. Keep it **static** (108): sample per fragment in the existing pass; no idle-time CPU work.
5. **HONESTY to bake into the code comment + this doc:** this is a **screen-space depth-proximity**
   effect, not a true analytic intersection curve. Known failure mode: at **grazing angles** the
   depth gradient is shallow, so `d` stays small across many pixels and the **contact line
   thickens**. That's expected and acceptable for the contact read.
6. **Capture** (the 112 precedent) a headless `renderOffscreen` of a cylinder **AND** the box
   crossing a part, **before/after**, into `docs/handoffs/assets/` (e.g.
   `114_contact_cylinder_before.png` / `_after.png`, `114_contact_box_before.png` / `_after.png`).

### Design box (items 10, 11)

10. **Magnetic face detent** — new pure `DesignBoxDetent` (in `DesignBox.swift`):
    `candidates(axis:faces:aabbMin:aabbMax:)` derives snap targets along the drag axis from the
    127-bridge per-face geometry (planar faces PERPENDICULAR to the axis contribute their plane
    coordinate) plus the part AABB extents, sorted + de-duped; `resolve(rawCoord:candidates:current:)`
    is the **snap/release hysteresis** — enter within `snapThresholdMM` (1.5 mm), escape only past
    `releaseThresholdMM` (2× = 3.0 mm), reporting `didSnap` on a fresh entry. Wired into
    `applyBoxDrag`'s `.face` case (`boxFaceDetent` @State carries the held candidate; reset on
    drag end) with a haptic tick (`ClearanceHaptics.detent()`, `.rigid`). Headless tests
    (`DesignBoxTests`): `testDetentCandidatesFromFaceGeometryAndAABB`,
    `testDetentSnapEntersWithinThreshold`, `testDetentReleaseHysteresis`,
    `testDetentSwitchingReportsFreshSnap`. **Device QA / not finished:** the "flash the matched part
    face (brief highlight pulse)" is a short toast (`flashDesignBoxDetent`) as the safe feedback —
    the precise part-face highlight-pulse in the Metal viewer is device-QA polish layered on the
    same trigger. The 1.5 mm threshold and the feel are device QA.

11. **Drawer opens beneath the chip** — `settingsChipRow(.designBox)` was an HStack with the drawer
    LEFT of the chip; it is now a trailing-aligned `VStack` with the chip on top and
    `designBoxDrawer` BENEATH it (transition `.move(edge: .top)` — unfurls downward), wider than the
    chip and right-aligned so it extends LEFT. Because the cluster is bottom-anchored, the taller
    row pushes the chips ABOVE it up. (Round 2 put it above; corrected.)

## Captured vs code-derived (honesty split)

- **Captured (real GPU render):** NONE. No GPU in this environment — the items 7+8 before/after
  captures the task asks for could not be produced here and are a required macOS follow-up (see
  the plan above).
- **Code-derived / headless-tested:** the camera roll math (item 2), per-row sync membership
  (5+6), 0.25 mm quantization (12), single axial handle (9), and the detent candidate/hysteresis
  math (10) — all pinned by the XCTest cases named above (authored, **not executed here**).
- **Device-QA feel (no pure part to pin):** gizmo swoosh Canvas arc (13), chip anchoring/size (3),
  row layout (4), drawer transition (11), depth-bias look + the parts b/c contact treatment (7+8),
  detent flash + haptic + threshold feel (10).

## Device-QA checklist (keyed 1–13)

1. Each ⟲/⟳ tap rolls the view 45° (was 15°); the pair stays symmetric.
2. Roll the view, then drag DOWN — the view moves DOWN (not sideways) at any roll; at roll 0 it
   feels identical to before; Snap/Home level the horizon.
3. On-model Margin/Axial (and Depth) chips are visible for EVERY keep-clear site without selecting,
   sized like the weight label, sitting next to each handle.
4. In the Selections list, each keep-clear row's chips are right-aligned under the trash icon.
5+6. Each keep-clear row has an always-on "Sync" checkbox (default checked); editing a checked
   row's value updates all checked rows, an unchecked row keeps its own; re-checking adopts the
   shared value; an untouched checked row still shows Auto. The old on-model checkbox is gone.
7+8. Where a cylinder/box passes through the part: the z-fighting shimmer is gone (depth bias).
   The bright contact line + inside-darkening are NOT yet present — apply the plan, then verify a
   clean 1–2 px contact line and a subtle contact shadow, and confirm the grazing-angle thickening
   is acceptable. Capture before/after for a cylinder AND the box.
9. One axial drag icon per keep-clear cylinder (not one per end cap); axial drag still works.
10. Drag a design-box face toward a part face/AABB plane — it snaps within ~1.5 mm with a haptic
   tick (and a "Snapped to face" flash); keep dragging past ~3 mm to escape. Tune the threshold.
11. Opening the Design Box tool: the drawer opens BENEATH the Design Box chip, extends LEFT, and
   the chips above it shift UP.
12. Margin/Axial/Depth values snap to 0.25 mm steps while scrubbing AND handle-dragging; typed
   values round to the nearest step on commit; Auto stays Auto.
13. Both gizmo swoosh arrows read correctly — highlight, arrowhead, AND body all on the same
   (top) side, matching `docs/design/gizmo_redesign.html`; the pair stays mirrored.

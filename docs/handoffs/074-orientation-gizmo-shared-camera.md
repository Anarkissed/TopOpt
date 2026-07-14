# 074 — Orientation gizmo + shared orbit camera (app track)

**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/3d-gizmo-orbit-camera-0622db`
**Branch:** `claude/3d-gizmo-orbit-camera-0622db`
**Territory:** `/app/` only. No `/core/`, fixtures, benchmarks, materials.json, ARCHITECTURE.md, or ROADMAP box touched.
**Build note:** `/app/`-only change, so no core rebuild is required — but the vendor
xcframework must be present to build/test. This worktree started with `vendor/` absent;
I ran `./app/scripts/build_core.sh` once (macos-arm64 + ios-arm64 + ios-arm64-simulator,
OCCT-free iOS slices) to get a linkable package. A fresh checkout needs the same.

---

## STEP 0 — Diagnosis (do this first; findings before the fix)

**The maintainer's hypothesis ("single-axis yaw only, or unclamped so it can never be
levelled") is DENIED at the camera-model level, with evidence.**

- **What the drag actually applies.** `MetalMeshView.Coordinator.handlePan`
  (`app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift`) feeds the drag delta to
  `OrbitCamera.orbit(dx:dy:)` (`OrbitCamera.swift:120`), which applies **both** axes:
  `azimuth -= dx·sens` **and** `elevation = clamp(elevation + dy·sens)`. Elevation is
  clamped to `±(π/2 − 0.05)` (`maxElevation`), so it can never flip past vertical. This
  is not new code — it has been there since M7.4, and the existing tests
  `testOrbitTurnsAzimuthBySensitivity` / `testElevationClampsAtPoles` (ViewerTests) pin
  it. I added `testAFreeDragCanReachACleanFrontView`, which drives a **finite** drag
  from the default 3/4 view and lands on an **exactly level, straight-on** front
  (`azimuth == 0`, `elevation == 0`, `direction == (0,0,1)` within 1e-3). So a front view
  **is** reachable by dragging — the orbit is neither single-axis nor unusably unclamped.

- **So why did it feel near-impossible?** Two real root causes, both of which this task
  fixes:
  1. **No way to land a *clean* canonical view.** Free-drag is continuous; with no snap
     and no home, hitting azimuth/elevation *exactly* 0 by hand is a pixel-hunt. The user
     experiences "I can spin it but I can never get a clean, square-on front."
  2. **Camera state was DUPLICATED per viewer and locked away.** Each `MetalMeshView`
     made its own `Coordinator` → its own `MeshRenderer` → its own **private**
     `var camera = OrbitCamera()`. Nothing outside the renderer could read or drive it, so
     there was no shared source of truth a corner widget could reflect or a "home" button
     could reset. (Camera state is per-`MetalMeshView`; it was **not** shared.)

  Note: the camera is a **turntable** (up is hard-pinned to world +Y in `lookAt`), so roll
  is always 0 — the horizon is always level. "Levelling" was only ever about getting
  elevation→0 and azimuth→a right angle, which snap now makes exact.

---

## STEP 1 — Consolidated to ONE shared orbit-camera model  *(shared-viewer refactor)*

New `OrbitCameraModel` (`app/TopOptKit/Sources/TopOptFlows/OrbitCameraModel.swift`) — a
`@MainActor ObservableObject` wrapping `OrbitCamera`. It is the single source of truth a
screen creates once and hands to **both** its Metal viewer and its gizmo:

- `MetalMeshView` gained an optional `camera: OrbitCameraModel?` parameter (iOS, macOS,
  and the non-Metal fallback inits). When present, the `Coordinator` subscribes to
  `model.$camera` and mirrors every published camera onto `renderer.camera` + redraws
  (efficient — no full SwiftUI pass); gestures route **into** the model
  (`model.orbit`/`model.zoom`) instead of mutating the renderer directly. On a mesh
  change the renderer frames as before (preserving azimuth/elevation, refitting distance)
  and hands the framed camera back to the model via `adopt`, so the model stays
  authoritative. When absent, the legacy self-owned camera path is byte-for-byte
  unchanged — so `MeshThumbnail`'s offscreen `MeshRenderer` render is untouched.
- `Coordinator` is now `@MainActor` (it drives a `@MainActor` model); the Combine sink
  uses `MainActor.assumeIsolated` (the model only mutates on main).

**Which viewers now use it:** both `MetalMeshView` mount points — **ResultsScreen** (the
Stress / Flex / Load-path stage; it is one viewer with different overlays, so one shared
model covers all three) and **WorkspacePlaceholder** (the edit/setup viewer). Each screen
owns one `@StateObject OrbitCameraModel`. `MeshThumbnail` deliberately stays on the
legacy path. Every viewer still renders (full suite + both-platform builds green).

## STEP 2 — Free-drag orbit fix

The orbit itself was already correct; consolidating it means the drag, the gizmo, and the
snap all move the *same* clamped azimuth+elevation state. `OrbitCameraModel.orbit`
delegates to `OrbitCamera.orbit` (both axes, elevation clamped just under ±90°) and
cancels any running snap so a grab always wins. Verified by
`testAzimuthAndElevationBothChangeTheView`, `testElevationCannotFlipPastVertical`,
`testModelOrbitRoutesAndClamps`.

## STEP 3 — The orientation gizmo  *(gizmo-only)*

- **Pure geometry** — `OrientationGizmo` (`OrientationGizmo.swift`): the 26 clickable
  regions (6 faces / 12 edges / 8 corners) as `{-1,0,1}³` anchors, each mapping to a
  canonical `(azimuth, elevation)` shared with `OrbitCamera` (so a snap is an exact
  round-trip). `hitTest` ray-casts the tap through the **same** rotation the widget
  renders with and classifies where it enters the unit cube (`edgeBand = 0.3` → central
  70% of a face is the face; outer band splits into edges/corners — the standard ViewCube
  feel). Tap outside the silhouette → nil.
- **SwiftUI widget** — `OrientationGizmoView` (`OrientationGizmoView.swift`): a `Canvas`
  cube drawn through `camera.viewRotation()` (painter-sorted front faces, translucent
  fills, hovered/tapped region highlights via `onContinuousHover`), **Front/Top/Right**
  (and Back/Left/Bottom when facing you) labels in the app's typography. A single
  `DragGesture(minimumDistance:0)` does double duty: a real drag **grab-and-spins** the
  cube (orbits the shared camera); a near-zero drag is a **tap → snap** (`~0.3s`
  smoothstep ease via the model, not a teleport). A **Home** button (house icon) below
  the cube returns to the viewer's default via `model.home()` — the default is captured
  from the initial `OrbitCamera()` (azimuth π/4, elevation π/6, the exact angle a
  freshly-opened viewer uses), not invented. Grab-to-spin was **kept** — it does not
  fight the tap regions (drop-distance threshold disambiguates).
- **Live tracking:** the cube renders from `camera.viewRotation()` every published change,
  so dragging the model turns the cube in lockstep; `testGizmoRotationIsTheCameraRotation`
  asserts the gizmo's transform *is* the camera's (they cannot diverge).

## STEP 4 — Aesthetic

Reuses the design tokens the chips/drawers use: `.ultraThinMaterial` backdrop + the
`DS.Surface.bar` glass tint, `DS.Color.strokePanel` hairline, `DS.Radius.control` corners,
`DS.Color.accent` for highlights. Faces are subtly translucent; the hovered/tapped region
lights up. It reads as part of the app, not an engine widget. (Pixel-level look is device
QA.)

**Placement — TOP-LEFT in both viewers, and why.** The right rail is occupied on every
viewer (ResultsScreen: the viz chips + their left-sliding drawers and the
recommended-orientation cube in the bottom-right; WorkspacePlaceholder: design-box /
gravity controls top-right). Bottom-left is taken too (ResultsScreen savings tabs;
Workspace Selections panel) and the bottom-centre is the media player. **Top-left, just
under the top nav bar, is the one corner clear on all of them** — so the gizmo never
collides with the chip drawers the task called out.

---

## Shared-viewer refactor vs gizmo-only

- **Shared-viewer refactor (touches the shared viewer, affects every mount):**
  `OrbitCameraModel`, the `camera:` param + Coordinator sync in `MetalMeshView`, the
  `OrbitCamera` helpers (`setOrientation`, `azimuthElevation(forDirection:)`,
  `viewRotation`), and the `cameraModel` wiring in ResultsScreen + WorkspacePlaceholder.
- **Gizmo-only:** `OrientationGizmo` geometry, `OrientationGizmoView`, and the top-left
  overlay in each screen.

---

## Evidence (raw)

Baseline before changes: `swift test` → **364 tests, 0 failures**.

After (`cd app/TopOptKit && swift test`):
```
Test Suite 'TopOptKitPackageTests.xctest' passed
	 Executed 379 tests, with 0 failures (0 unexpected) in 15.501 (15.529) seconds
Test Suite 'All tests' passed
	 Executed 379 tests, with 0 failures (0 unexpected)
```
New file `OrientationGizmoTests` → **15 tests, 0 failures** (shared-camera both-axes +
clamp; free-drag-reaches-front; snap Front/Top/corner within tolerance; home restores
exact default; gizmo-rotation-is-camera-rotation; face/edge/corner hit-testing incl.
"top tap is not an adjacent face" and "tap outside misses"; 26-region inventory). These
fail against a stub (a no-op snap, an always-nil/always-same hit-test, or a fixed gizmo
rotation each break a named assertion).

iOS target compiles (exercises the `#if os(iOS)` gesture branch that macOS `swift build`
skips):
```
xcodebuild build -scheme TopOpt -destination 'generic/platform=iOS Simulator'
** BUILD SUCCEEDED **
```
`xcodebuild test -scheme TopOptKit` is *not* usable here — the scheme isn't configured for
the test action in this project; `swift test` is the working headless path (and the README
command errored the same way, unrelated to this change).

---

## Device QA (maintainer's call — not verifiable headlessly)

- The gizmo's look/placement against the app aesthetic (glass tint, blur, label
  legibility on the ~74pt cube — "Bottom" is the tightest label at 8.5pt).
- Dragging the model turns the cube naturally (sign/feel), and grab-and-spin on the cube
  orbits the model without accidentally firing a snap.
- Tap-to-snap feels smooth (~0.3s ease) for faces, edges, and corners.
- Home reliably lands a clean front-facing default on all viewers.
- Front/level views are now easy to reach on **Stress, Flex, and Load-path** (all the
  ResultsScreen viewer) **and** the Workspace viewer.
- The snap animation uses a `CADisplayLink` (iOS) / main-runloop `Timer` (macOS); confirm
  it stops cleanly (no lingering redraws) after landing — the headless tests use
  `animated: false`, so the clock path itself is device QA.

## Not done / honest caveats

- No ROADMAP box checked (per instructions).
- Snap-animation *timing* is device QA only (headless tests assert end-states via
  `animated: false`).
- The gizmo is mounted on the two existing `MetalMeshView` mount points; if a third 3D
  viewer is added later it should pass a `cameraModel` + drop in `OrientationGizmoView`
  the same way.

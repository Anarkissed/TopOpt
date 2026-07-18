# 107 — Orientation gizmo: liquid-glass redesign (raymarched SDF port)

**Branch:** `claude/orientation-gizmo-redesign-n4u1op` (developed on the dedicated feature
branch, isolated from `main`; the CCR session is an ephemeral fresh clone).
**Territory:** `OrientationGizmo.swift` + `OrientationGizmoView.swift` + ONE new support file
(`OrientationGizmoMetal.swift`) + the gizmo tests + a headless oracle. **Not touched:**
`MetalMeshView`, `WorkspacePlaceholder`, `ResultsScreen`, clearance files, `OrbitCamera*`
(sibling tasks own the first three tonight; the camera is shared — see the "Blocked" note).
**Handoff number:** claimed **105** (first free ≥ 105 on `main`, which tops out at 104). Two
sibling tasks run tonight — they should take **106 / 107**.

**Task:** rebuild the gizmo to match the maintainer's spec `docs/design/gizmo_redesign.html`
("Liquid Glass View Gizmo v21"), a WebGL/SDF mock whose CSS+JS+shader ARE the design.

> ⚠️ **Honest build status up front.** This work was authored in a **Linux** CCR container
> with **no macOS toolchain** — there is no `swift`, no `xcodebuild`, no Metal compiler, and no
> device. Therefore **`xcodebuild` was NOT run and the app was NOT built or run here.** What I
> *could* verify, I did, rigorously: the shared-constants **picking math** is proven by a C++
> oracle that mirrors the mock byte-for-byte (33/33 checks pass in both `double` and `float`),
> and the Swift XCTest expectations are derived from it. The Metal render + SwiftUI composition
> are written to the codebase's own conventions but are **unbuilt** — they need a
> `xcodebuild test` pass and device QA on the maintainer's Mac/iPad. Every place I could not
> verify is called out below. Nothing green is claimed that wasn't actually run.

---

## STEP 0 — What the mock actually is, and the porting strategy

The mock raymarches an SDF "liquid glass" cube in a fragment shader, with **one** `CFG` object
of geometry constants **interpolated into the GLSL source** (`const float KC = ${CFG.KCELL};`).
The SAME `CFG` drives a **JS mirror** of the SDF used for hit-testing (`pickId`). The maintainer's
hard requirement: keep that property — **ONE constants source feeding both the picture and the
picking, never two hand-tuned copies.**

Two facts shaped the port:

1. **The codebase already compiles Metal from inline Swift strings** (`MetalMeshView.swift:48`:
   "the SwiftPM target needs no `.metal` resource bundling"; every shader is built with
   `device.makeLibrary(source:)`). So I do exactly what the mock does — **interpolate the shared
   Swift constants into the MSL shader string** — and get the single-source property for free,
   with no SwiftPM `.metal`-bundling risk.
2. **The gizmo mirrors `camera.viewRotation()`.** The mock's virtual camera is fixed on +Z; the
   object rotates by `orient`. In the app, `orient ≡ R = camera.viewRotation()` (world→view), and
   the ray transform into model space is `Rᵀ` — structurally the SAME `rotation.transpose` the old
   hit-test used. So the port keeps the camera-sync contract exactly.

**Result — the single source:** `GizmoConstants` (in `OrientationGizmo.swift`) is the one struct.
`OrientationGizmoMetal.shaderSource(_:)` interpolates it into the MSL; `OrientationGizmo.pick`
evaluates the same values on the CPU. Change a number once → the drawn glass and the tappable
geometry move together.

---

## Architecture (files + data flow)

```
GizmoConstants (OrientationGizmo.swift)  ── the ONE set of numbers ──┐
     │                                                               │
     ├─ interpolated into MSL string  ─▶ GizmoRenderer (Metal SDF raymarch, OrientationGizmoMetal.swift)
     │                                        └─ transparent MTKView, floats over the housing
     └─ evaluated on CPU  ─▶ OrientationGizmo.pick (SDF raymarch → face/edge/corner/home)
                                   └─ hitTest(...) preserves the old GizmoRegion API + 26 regions

OrientationGizmoView.swift  ── SwiftUI composition ──
   housing squircle · drop-shadow · GizmoMetalView · projected face labels
   · control ring (2 swoosh + Home) · snap toast · drag/tap gestures → OrbitCameraModel
```

The 26 `GizmoRegion` anchors and their canonical `(azimuth, elevation)` mapping are **unchanged**,
so snaps remain exact round-trips with `OrbitCamera`, and the shared camera is driven/mirrored
exactly as before.

---

## Behaviour inventory — every current gizmo behaviour, KEPT / CHANGED

| # | Current behaviour | Status | Notes |
|---|---|---|---|
| 1 | Mirrors `OrbitCameraModel.viewRotation` live (both directions) | **KEPT** | Renderer reads the camera's rotation each frame; picking uses it too. |
| 2 | Drag to orbit the shared camera (`orbit(dx:dy:)`, same y-down mapping) | **KEPT** | `orbitOrTap.onChanged`, byte-identical routing. |
| 3 | Tap a face/edge/corner → ease-snap to that canonical view | **KEPT** | Now via the SDF `pick`; snap targets are the same 26 regions. |
| 4 | Tap outside the cube → no-op | **KEPT** | `pick` returns `.miss`; margin is larger (glass renders with a deliberate margin — see #12). |
| 5 | Home button → `camera.home(animated:)` | **KEPT** | Redrawn as the mock's isometric-cube glyph, bottom-right. |
| 6 | Pointer hover highlights the hovered region | **KEPT** | Hover → shared `globalId` → shader lights that cell. |
| 7 | Tap flash (touch has no hover) | **KEPT** | Snapped cell glows for the ease duration. |
| 8 | Reduce-Motion respected | **KEPT** | Idle float held still; MTKView drops to on-demand redraw. |
| 9 | 26 clickable regions, exact ids + canonical mapping | **KEPT** | `buildRegions()` untouched; all 26 reachable at their view centre (tested). |
| 10 | Look: layered-gradient "bubble" cube (handoff 078) | **CHANGED** | Replaced by the raymarched liquid-glass SDF per the new spec. |
| 11 | Center-of-cube tap | **CHANGED (added)** | The frosted core now reads as Home (`pick` → `.home`); still also a Home button. |
| 12 | Cube filled ~most of the widget (ortho, `cubeScreenScale`) | **CHANGED** | Perspective (FOV 38 / CAMZ 9.25): glass fills the central ~38%, floating with margin — faithful to the mock's "20% smaller". `cubeScreenScale`/`edgeBand` removed (vestigial). |
| 13 | Rotate buttons | **ADDED / DIVERGES** | New swoosh buttons step the turntable ±45° azimuth. The mock ROLLS about screen-Z — impossible on a turntable camera (see "Blocked"). |
| 14 | Snap toast | **ADDED** | Bottom-centre pill naming the target (the mock has it; the old app gizmo didn't). |
| 15 | Idle float / breathing / sheen | **ADDED** | Render-only flourish from the mock; frozen during interaction so picking stays exact. |

---

## Faithfulness & disclosed divergences

- **Material** — ported line-for-line from the mock's fragment shader: dark liquid-glass base,
  fresnel rim with a whisper of spectrum, the Siri-style spectral top band, world-fixed key
  speculars, the carved junction grooves, and the **back-face refraction glint** (marches from
  beyond and adds a cool glint of "what lies behind"). **This is self-contained** — the mock does
  NOT sample the page behind it, and neither does this port: it does **not** refract the live FEA
  viewport. That is the disclosed approximation the task allowed, and it matches the mock exactly
  (so it is faithful, not a downgrade), and it keeps the cost fixed regardless of the scene.
- **Labels** — the mock **etches curved decals into the domes**. This port draws **upright
  billboard labels** projected with the identical virtual camera (FOV/CAMZ + rotation), fading as a
  face turns away. Divergence: not curved/etched. Legible and cheap; device-QA the placement.
- **Housing / drop-shadow / toast / buttons** — SwiftUI, matched to the mock's layout (frosted
  squircle, shadow cast straight back so the glass floats IN FRONT, ~48px corner inset ring). Exact
  pixel metrics are code-derived (see below) and need device QA.
- **Rotate buttons** — see "Blocked".

---

## BLOCKED (documented, not worked around) — the roll buttons

The mock's circular arrows **roll the view about the screen-Z axis**. The shared `OrbitCamera` is a
**turntable with up hard-pinned to world +Y** (handoff 074: "roll is always 0 — the horizon is
always level"). A true screen-Z roll needs a **roll DOF added to `OrbitCamera`/`OrbitCameraModel`**,
which is **shared with `MetalMeshView`** — out of this task's territory. Per the task's "Blocked-stop
that one edit with a note" rule, **I did not add it.**

**Shipped in-territory analogue:** the buttons step **±45° azimuth** via the existing
`camera.orbit(dx:)` API (a turntable yaw step to the next quarter view). It is **instant, not eased**
— `OrbitCameraModel` exposes no animated relative-rotation API, and adding one is also out of
territory. Follow-up options for the maintainer: (a) add a roll DOF to the camera for a true screen
roll; or (b) add an eased `nudge(azimuthBy:)` to `OrbitCameraModel` so the step animates.

---

## Performance — budget, ceiling, and honest measurement status

**Named ceiling (the levers):**
- Drawable capped by **DPR ≤ 1.5** (`contentScaleFactor`), so a 300pt gizmo renders at **≤ ~450²
  px** — never the FEA viewport's resolution.
- Raymarch steps capped: **80 primary + 40 back** (mock is 80 + 48; the back march is a subtle
  glint, trimmed).
- **Self-contained material** — no live-scene sampling, so the cost is fixed.
- **Bounding-sphere early-out (added, invisible):** a ray whose closest approach to the origin
  exceeds 2.0 can't hit (the SDF's farthest surface point is |p| ≤ 1.766 — *verified* by the
  oracle's dense sweep), so margin fragments skip the entire march. Identical picture, large saving
  on the empty margin, which is most of the frame.

**Analytic estimate (NOT a device measurement):** at 450² px, hit fragments (~38% central disc,
~60k px) each do ≤80 primary map() calls + 4 normals + ≤40 back; margin fragments are rejected by
the bounding sphere after a handful of ops. Order ~10⁷–10⁸ ellipsoid evals/frame → well within an
M1 GPU's budget for a small overlay at 60fps, but **this is a paper estimate.**

**MEASUREMENT STATUS — NOT DONE.** No CPU/GPU frame cost was captured: this environment has no
Metal/device. The task asked for Instruments/`os_signpost` numbers before/after — **these must be
taken on device.** If profiling shows it over budget beside a live FEA run, pull the levers in
order: cap drawable to 256², drop to 30fps when idle, reduce primary steps to ~56, or pause the
gizmo's continuous loop while the solver animates.

---

## Evidence

### Headless picking oracle (REAL, run here) — `Testing/gizmo_pick_oracle.cpp`
A C++ port of the mock's `CFG` + SDF + `globalId` + perspective pick, byte-for-byte. Run:
```
clang++ -O2 -std=c++17 Testing/gizmo_pick_oracle.cpp -o /tmp/gizmo_oracle && /tmp/gizmo_oracle
```
Output (actual):
```
[double] 33 checks, 0 failed
[float]  33 checks, 0 failed
OK — all picking checks pass
```
It verifies: all **26 canonical views** resolve at their centre ray; the **clamped poles**
(elevation 85°, as `OrbitCamera` clamps) still resolve to Top/Bottom; the exact **front-view
synthetic rays** (`(100,100)→Front`, `(100,70)→Top-Front edge`, `(130,70)→Top-Front-Right corner`,
`(100,10)→miss`, `(2,2)/74→miss`) — the same points baked into the Swift tests. Both `double`
(mock/JS precision) and `float` (shader/Swift precision) pass, so 32-bit rounding doesn't flip a
classification.

### Swift tests (UPDATED; expectations from the oracle) — `OrientationGizmoTests.swift`
- **Kept, unchanged & still valid:** the shared-camera / orbit-clamp / snap-Front/Top/Corner / Home
  / gizmo-tracks-camera tests (they exercise `OrbitCameraModel`, untouched).
- **Kept (pass under the SDF, oracle-confirmed):** `testHitTestFaceCentresResolveToThatFace`,
  `testHitTestCornerAndEdgeCentresResolve`, `testEveryAnchorHasAReachableClickableTarget`,
  `testAllTwentySixRegionsExist`.
- **Updated for the new geometry:** the old `testTopTapIsNotAnAdjacentFace` used a `(37,20)/74`
  point that is now in the (larger) margin → replaced by
  `testSyntheticRaysOnFrontViewResolveFaceEdgeCorner` + `testTapOutsideGlassMisses` with
  oracle-verified points.
- **Added:** `testNumericIdMatchesSharedGlobalIdScheme` (pins the CPU↔shader `globalId` contract that
  drives the hover glow) and `testPickReturnsRegionOrMiss` (the `.region/.home/.miss` enum).
- **STATUS:** written to pass, but **`xcodebuild test` was NOT run** (no macOS here). The picking
  assertions are oracle-backed; the maintainer must run the suite to confirm the Swift build.

### Screenshots — **all CODE-DERIVED, none captured**
No screenshots were taken (no device/simulator). Descriptions of the intended result, derived from
the code + the mock, NOT from a running build:
- *(code-derived)* A dark frosted squircle; a dark liquid-glass cube floating in front of it with a
  soft shadow cast straight back; a bright fresnel rim + a spectral band riding the top; six face
  labels glowing over the front-facing domes; two glass swoosh buttons top-corners and an isometric
  cube Home button bottom-right; a snap toast rising from the bottom on tap.
- *(captured)* — none.

---

## Follow-ups for the maintainer (device QA)
1. `xcodebuild test` the package on macOS + an iOS destination; confirm the updated gizmo tests pass
   and the MSL compiles (`GizmoRenderer.lastInitError` surfaces any `makeLibrary`/pipeline failure).
2. Visual QA on iPad: material fidelity vs the mock, label placement, button glyph shapes, housing
   metrics, the drop-shadow float.
3. Touch QA: tap-snap accuracy across orientations, drag-orbit feel, hover glow (pointer), the ±45°
   buttons, Home.
4. Instruments/`os_signpost` frame-cost beside a live FEA run; pull the perf levers if needed.
5. Decide on the roll buttons: keep the azimuth-step analogue, or add a camera roll DOF (out of this
   territory).

## Files changed
- `app/TopOptKit/Sources/TopOptFlows/OrientationGizmo.swift` — `GizmoConstants` (single source),
  the CPU SDF + perspective `pick`, `numericId`, region model kept.
- `app/TopOptKit/Sources/TopOptFlows/OrientationGizmoMetal.swift` — **new** — MSL shader (constants
  interpolated), `GizmoRenderer`, transparent `GizmoMetalView` representable.
- `app/TopOptKit/Sources/TopOptFlows/OrientationGizmoView.swift` — rewritten SwiftUI composition.
- `app/TopOptKit/Tests/TopOptFlowsTests/OrientationGizmoTests.swift` — SDF-picking tests.
- `Testing/gizmo_pick_oracle.cpp` — **new** — headless ground-truth oracle.

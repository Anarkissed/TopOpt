# 078 — Orientation gizmo: liquid-glass re-skin

**Task:** aesthetic-only re-skin of the merged orientation gizmo (074 + 077). "The
movement and feel are impeccable — it's the look that needs serious updates." Territory:
`/app/` only. Hard guardrail: do not touch the feel (OrbitCamera(Model), gesture routing,
snap easing, the 26 anchors and their canonical mapping, hit-testing). Keep
`OrientationGizmoTests` green.

Files changed (all `/app/TopOptKit/`):
- `Sources/TopOptFlows/OrientationGizmoView.swift` — the re-skin (full redraw).
- `Sources/TopOptFlows/ResultsScreen.swift` — placement (top-left → top-right, below Export).
- `Sources/TopOptFlows/WorkspacePlaceholder.swift` — placement (top-left → bottom-right).
- `Tests/TopOptFlowsTests/OrientationGizmoTests.swift` — **added** one test (no existing
  test changed).

The pure geometry/hit-test module `OrientationGizmo.swift` and the camera
(`OrbitCamera*.swift`) were **not touched**. Nothing here changes what a tap snaps to.

---

## STEP 0 — rendering approach + justification

**Verified, do not assume:** the brief said "deployment target is iOS 26.5." It is **not**.
`IPHONEOS_DEPLOYMENT_TARGET = 16.0` (app xcodeproj, both configs) and the package is
`platforms: [.macOS(.v13), .iOS(.v16)]`. The SDK/toolchain is 26.5 (Xcode 26.6), but the
**minimum** the gizmo must run on is iOS 16. There are zero `#available` gates anywhere in
the Sources today. So iOS-26 Liquid-Glass APIs (`.glassEffect`, `GlassEffectContainer`,
`.buttonStyle(.glass)`) are only reachable behind an `#available(iOS 26.0, …)` gate **with a
fallback** — they are not the unconditional system effect the brief assumed.

**Chosen: (c) `Canvas` + layered gradients/blurs for the cube, with the iOS/macOS-26
`.glassEffect` layered onto the holder as a progressive enhancement.** Reasoning:

1. Two of the required looks **cannot** be expressed by any system glass effect, which
   glasses a static 2-D SwiftUI shape:
   - **Labels pinned in 3-D onto the rotating face planes** (item 5) — need a per-face
     projective affine.
   - **Domed bubbles sized to each of the 26 hit regions** (item 6) — need per-cell
     projected quads on each face plane.
   Both require drawing in the same projected space the feel-math uses, i.e. a `Canvas`.
2. The `Canvas` keeps the **exact** projection (`cubeScreenScale`) and defers every tap to
   the unchanged `OrientationGizmo.hitTest`, so the feel is provably preserved.
3. One `Canvas` renders the whole widget → **one coherent look on every supported OS** (iOS
   16–26+), instead of a divergent iOS-26-only path.
4. It redraws only when the camera publishes (as before) and is all cheap vector work — no
   per-pixel shader, no framebuffer sampling — so live tracking stays smooth.

The frosted **holder** still gets genuine system Liquid Glass where available: `HolderGlass`
applies `.glassEffect(.regular, in:)` behind `#available(iOS 26.0, macOS 26.0, *)`, falling
back to `Material` + Canvas frosting on older OS. (Verified this compiles for both the iOS
target and the macOS 26 test host.)

**Perf note (device QA):** worst case ~54 domed tiles (6 faces × 9 cells) + labels +
caustics per frame, redrawn live while dragging. All vector fills/gradients; expected
smooth on iPad, but the glass redraws on every camera tick — **watch for a drag hitch on
device** and, if any, cull back-face tiles or drop the far-side ghost.

---

## The 8 items

1. **Size** — holder default `300pt` (≈4× the old 74pt). `OrientationGizmoView(size:)`
   default bumped 74 → 300; home/inset scale off `size`.
2. **Placement — right side, below Export.**
   - **ResultsScreen:** moved top-left → **top-right, directly below the Export .3mf
     button** (`.padding(.top, 96).trailing xl3`). Collision-checked clear: the viz chips
     (Stress/Flex/Load-path/Failure) + their left-opening drawers and the recommended-
     orientation cube all sit **bottom-right** (`vizRail`/`orientationCorner`, lifted by
     `cubeClearance`); savings tabs are bottom-left; media player bottom-centre. A ~300pt
     gizmo at ≈y 96–396 never reaches the bottom cluster (starts ≈y 480 even on the
     shortest supported iPad, landscape ~768pt). **No collision.**
   - **WorkspacePlaceholder (setup): reported divergence.** Its right rail is congested —
     `topRightControls` chips fill the top-right (≈y 22–230) and, when the design-box tool
     is active, `designBoxPanel` (260pt wide, top inset 210 ⇒ ≈y 210–460) owns the upper-
     right. There is **no ~300pt top-right slot free of both**, so the gizmo is anchored
     **bottom-right** (clear of the top controls; clear of the design-box panel in
     portrait; clears the bottom bar via the inset). **Residual caveat:** in *short
     landscape* with the design-box tool open, the case's top edge can graze the panel's
     lower edge (~70pt). Reported per the guardrail rather than silently worked around;
     the screen the maintainer's verdict targets (ResultsScreen, with Export + viz chips)
     is unaffected.
3. **Blue** — `DS.Color.accent` throughout: bubble rims, the caustic wash, the holder's
   edge glow, the home-button rim, and the active-bubble fill.
4. **Liquid glass on the cube** — translucent glass body (see item "follow-up"), a blurred
   **chromatic-dispersion caustic band** across the upper-middle, a **specular bloom**, a
   cool accent wash, and crisp facet edges. The frosted holder supplies the real backdrop
   blur (magnification of what's behind).
5. **Labels pinned in 3-D** — each face label is drawn through the exact affine that maps
   its local box onto the face's projected parallelogram using the face's in-plane
   right/up axes, so it **shears + rotates with the face and flips upside-down** when the
   face's up-vector projects downward. Not level, not billboarded. Auto-fits the face
   width (≈66%), so "BOTTOM" (the tightest) never truncates. Conventional ViewCube label
   frames (sides upright with +Y up; poles along +X).
6. **Bubble buttons = the hit regions.** Each face is tiled with the **9 domed glass
   bubbles that match its hit cells** (the `edgeBand=0.3` partition): a big centre bubble
   (the face), 4 strips (the edges, each the full width up to its corners), 4 squares (the
   corners), with a gap between. Because the footprints ARE the bands, **hit-testing is
   unchanged** — a tap on a bubble lands in that region's band and snaps to the same
   anchor. Hovered/tapped bubbles highlight app-blue (touch gets a ~0.3s flash via
   `pressed`, since it has no hover).
7. **Home icon inside the holder** — moved from below the cube to the holder's **top-left
   corner** (glass squircle, blue rim).
8. **Holder = frosted case** — `.ultraThinMaterial` + a heavier diffuse tint + broad
   blurred light *pools* (softer/larger than the cube's crisp lens) + a top-edge sheen +
   a faint blue edge glow; `.glassEffect` on top where available. Deliberately more diffuse
   than the clear cube.

### Follow-up refinement (maintainer request, same session)
After the first pass the maintainer asked for: (a) bubbles **sized to their region area**
(edge = width up to the corner, corner = small square, face = nearly the whole face, with
gaps), (b) **fatter** bubbles, (c) a body you can **see through** to the far side. Done:
- Bubbles became the region-sized domed tiles above (was: small circles at anchor points).
- Fatter doming via a stronger up-left radial body + a **soft** specular glint (radial
  fade, not a hard dot).
- See-through: the **far side is drawn first as a ghost** (faint tiles/edges), then the
  near side over it with translucent tile bodies, so you read the back of the cube through
  the glass.

---

## Tests

- **No existing test changed.** All 15 in `OrientationGizmoTests` still pass unmodified —
  hit-testing stayed band-based, so anchors, snap targets, home, and gizmo==camera rotation
  are untouched.
- **Added 1:** `testEveryAnchorHasAReachableClickableTarget` — for each of the 26 regions,
  orient the camera to its canonical view (its bubble projects to centre) and assert a tap
  at centre resolves back to that region. Proves no region became unreachable when the
  targets became bubbles. (Passes for all 26.)

## Evidence (raw)

- `swift test` (macOS package): **Executed 405 tests, with 0 failures** (53.0s).
- `swift test --filter OrientationGizmoTests`: **Executed 16 tests, with 0 failures.**
- `xcodebuild -scheme TopOpt -destination 'generic/platform=iOS Simulator' build`:
  **BUILD SUCCEEDED.**
- Author sanity-render (offscreen `ImageRenderer`, temporary harness, removed): confirmed
  no Canvas crash, labels present + pinned/sheared onto planes (incl. the receding-face
  case), bubbles tiled to their regions, see-through to the far side, home icon inside the
  holder, blue accent. The **material blur / real refraction renders blank offscreen** — it
  only shows over live content on device.

## Device QA (maintainer's call)

Author cannot judge these headlessly — flagged honestly:
- The glass/caustic look vs Apple's Liquid-Glass lens reference; the real
  refraction/magnification of the model behind the frosted holder (blank offscreen).
- Label legibility over the busy tiled surface, and confirming the upside-down 3-D pin on a
  device rotation.
- Bubble tap accuracy at the new size (targets unchanged, but the visual is new).
- **Frame rate while dragging** — the glass redraws live; flag any hitch (perf note above).
- No collision with Export / viz chips / drawers in ResultsScreen; the WorkspacePlaceholder
  design-box-panel caveat (item 2) in short landscape.

No ROADMAP box checked. Vendor xcframework rebuilt via `build_core.sh` to link the tests.

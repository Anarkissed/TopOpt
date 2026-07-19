# Handoff 112 — Visual / layout round 2 (maintainer punch list)

Branch: `claude/visual-layout-round-2-aab60f`, on top of #137 (design-box-drag-bugs) and the
109 design-language overhaul. Territory: `OrientationGizmo*`, `WorkspacePlaceholder`,
`GlassValuePill` / new `ClearanceSyncCheckbox`, `ResultsScreen`, `MetalMeshView` (box fill +
background only), new `WorkspaceChipLayout`.

**Evidence:** `swift build` + `swift test` green — **568 tests, 1 skipped, 0 failures**
(`swift test --no-parallel`; run non-parallel to avoid the known GPU-parallel SIGTRAP flake,
[[app-swift-test-gpu-flake]]). Fresh worktree needs `app/scripts/build_core.sh` first
([[app-worktrees-need-build-core]]).

## What changed, by punch-list item

1. **Gizmo arrows** — `OrientationGizmoView.RotateButton` now ports the MOCK's glossy WHITE 3D
   swoosh (white→cool-white glass gradient, bright sheen, gradient-filled arrowhead, soft black
   drop-shadow + faint blue glow), mirrored pair, each spun 45° into its corner like the mock.
   The 109 blue-glass pair is gone. Roll behaviour unchanged (±15°/tap about the view axis via
   `OrbitCamera.roll`, already shipped in 109).
2. **Equal insets** — new `GizmoLayout` is the ONE source: `controlInsetFraction` places both
   arrows AND the Home cube at the same inset from their nearest edges (0.20·size). Proven equal
   in `DesignOverhaulRound2Tests.testGizmoControlsShareEqualInset`.
3. **See-through glass + centred cube** — `OrientationGizmoMetal` fragment: base opacity 0.44→
   0.22, haze ·0.5→·0.30, cap 0.97→0.84, and the back-face march now contributes ~1.8× more, so
   the FAR side reads through the near faces. `GizmoLayout.housingOffset == .zero` is asserted
   (`testGizmoHousingIsCentred`) — the recurring "cube sits high" bug can't silently return.
4. **One gizmo, one size, one place** — `OrientationGizmoView.standardSize = 210` used on BOTH
   screens; results' 300 default + below-Export placement is gone. Both gizmos sit in the
   absolute top-right corner (`.padding(.top/.trailing, DS.Space.s)`). Results' **Export .stl**
   chip moved OUT of the top-right into the top bar NEXT TO "See Original".
5. **Selections chips side by side** — `clearanceEditor` row is now an HStack (was a column), so
   Margin sits next to Axial; the row is only slightly taller than a plain one.
6. **On-model chips + checkbox adjacency** — the floating `clearanceValuePill` cluster is an
   HStack of the value chips with the sync checkbox beneath/beside them.
7. **Sync checkbox** — new `ClearanceSyncCheckbox` (+ pure `SyncCheckboxState`): a small liquid-
   glass checkbox "Same clearance for all", DEFAULT checked, **visible whenever there's ≥1
   keep-clear site** (the 109 toggle was invisible — only ≥2 in the header). At exactly 1 site it
   shows DISABLED with the explanation "Add another keep-clear site and they'll share one
   clearance." Rendered beside the on-model chips AND mirrored in the Selections panel. Fan-out
   semantics are unchanged — it writes `ForceModel.setSyncClearances`, whose peer fan-out is
   proven by the existing 109 tests (`ForceModelTests` "Same clearance for all" block); the
   visibility/enablement rule is proven in `DesignOverhaulRound2Tests`.
8. **See Results chip** — pinned to the top edge (`.padding(.top, DS.Space.xl3)`, aligned with
   the chrome row), exact horizontal centre (`frame(maxWidth: .infinity, alignment: .top)`).
9. **CAD stage background** — new `stageShaderSource` + `stagePipeline` in `MetalMeshView`: a
   full-screen deep charcoal-blue radial gradient + a mathematically-correct infinite floor grid
   (per-pixel ray↔floor-plane intersection → tracks the camera exactly), blue-tinted, major/minor
   line hierarchy, distance + grazing fade, soft horizon glow. Drawn FIRST with
   `lineOverlayDepthState` (depth-always, no write) so the part/box/grid occlude it. STATIC — the
   uniform (`makeStageUniforms`) is rebuilt only on a redraw (the view is on-demand), never on an
   idle timer (the 108 rule). GATED off in `renderOffscreen` (thumbnails / exported video keep
   their own clear). See the captured render `assets/112_stage_box_capture.png`.
10. **Design box glass volume** — `appendGlassBox` now adds frosted-BLUE translucent faces
    (tint (0.40, 0.58, 1.0), α 0.22, premultiplied) so the box reads as a VOLUME the part passes
    through — a slight blue tint + a small amount of frosting the maintainer asked for, legible
    enough that you can SEE the box enter the part and exit the far side (depth-tested, no
    depth-write → part occludes far faces, box tints the part where it contains it and shows over
    the background where it overhangs). The bright doubled "refractive wobble" edge is kept as the
    fresnel-edge read. See `assets/112_stage_box_capture.png` (a bar passing through a cube) and
    the honest limitation below.
11. **Design box drawer** — the panel moved OUT of the top-left; it now lives INSIDE the
    bottom-right cluster as `designBoxDrawer`, sliding LEFTWARD out of the Design Box chip
    (`.move(edge: .trailing)`), as an HStack row whose height grows and pushes the chips above it
    up. Animated via `DS.Motion.emphasized` on `showDesignGizmo`.
12. **Chip width ordering** — new `WorkspaceChipLayout`: chips are measured (`SettingsChipWidthKey`
    GeometryReader) and ordered smallest→largest by `BottomChipOrder.sorted` (ascending width,
    stable tie-break on declaration order; unmeasured parks at the bottom). Optimize stays beneath
    in the bottom bar. Comparator proven in `DesignOverhaulRound2Tests`.

## Captured vs code-derived (honesty split)

- **Captured (real GPU render):** the CAD stage backdrop + design-box glass —
  `assets/112_stage_box_capture.png` (headless `renderOffscreen(stage: true)` of a unit cube in a
  design box that overhangs it). Shows the gradient, blue perspective grid with major/minor
  hierarchy + distance fade, horizon glow, and the box's doubled-edge wobble crossing the part.
  It does NOT include the SwiftUI chrome/gizmo (headless render is the Metal layer only).
- **Code-derived (tests + build):** every layout constant + semantics seam — gizmo equal-inset /
  centred-cube / shared-size (`DesignOverhaulRound2Tests`), the sync-checkbox visibility/enable
  rule + its reuse of the 109 fan-out, the chip-ordering comparator, and the CAD-stage shader
  compile + pipeline build + background-gating (`StageBackdropTests`, GPU-gated).
- **Needs the maintainer's device (pixels):** the white swoosh arrows, the gizmo glass see-through
  + the arrows/cube margins in the SwiftUI housing, the chip typography/spacing on a real panel,
  the drawer slide feel, and the stage/box over a REAL STEP part with the full chrome. Keyed
  below.

## Device-QA sign-off checklist (by punch-list number)

- [ ] **1** Gizmo arrows are glossy WHITE swooshes (not blue), a mirrored pair, dimensional with a
  soft shadow; a tap rolls the view ±15°.
- [ ] **2** The two arrows and the Home cube have visibly EQUAL margins from their corners and sit
  comfortably inside the squircle (not crowding the edges).
- [ ] **3** You can see the cube's FAR faces through the near ones; the cube is centred in the
  squircle (not riding high).
- [ ] **4** The gizmo is the SAME size + absolute top-right corner on BOTH the workspace and
  results; results' "Export .stl" is in the top bar next to "See Original", not top-right.
- [ ] **5** In the Selections rows, MARGIN and AXIAL sit side by side; the row is only slightly
  taller than a plain one.
- [ ] **6** The on-model Margin/Axial chips are the "See Results" size class, sit adjacent, with
  the sync checkbox beside them.
- [ ] **7** The "Same clearance for all" checkbox is visible next to the chips whenever a
  keep-clear site exists; at exactly one site it's disabled with the explanation; default checked;
  toggling still fans out to all peers.
- [ ] **8** "See Results" is at the top edge, exact horizontal centre, in every state it appears.
- [ ] **9** The background is the charcoal-blue CAD stage (gradient + fading blue grid + horizon
  glow), the part/box occlude it, and it does NOT animate on its own (static; only moves when you
  move the camera).
- [ ] **10** The design box reads as a translucent glass VOLUME the part passes through (part
  visible through the tint; box visible through the part where it overhangs), doubled-edge wobble
  intact.
- [ ] **11** The Design Box panel slides LEFT out of its bottom-right chip; the chips above shift
  up to make room; both animate.
- [ ] **12** The bottom-right chips read smallest-width at top → largest at bottom, Optimize
  beneath.

## Honest limitations / notes

- **Item 10 fresnel:** the box's "fresnel-edge reflection" is carried by the bright DOUBLED
  wireframe edge, not a true per-fragment fresnel term. A real fresnel would need a dedicated
  normal-carrying pipeline updated per camera frame; that was declined to keep the box static and
  avoid touching the shared viewer's pipeline set (the box faces go through the existing flat
  ground pipeline). The faint faces + bright edge give the volume read; a per-fragment fresnel is
  a possible follow-up if the maintainer wants more edge shimmer.
- **Item 12 measured width:** the sort is by REAL measured width via a preference key. Before the
  first measurement (one transient frame) the default declaration order is used; unmeasured chips
  park at the bottom. This is deterministic (a total order over `(width, index)`), not a guessed
  intrinsic estimate.
- **CAD stage floor:** the grid floor plane + spacing derive from the settled part bounds, so it
  sits just under the part and scales with it on both screens. With no mesh loaded it falls back
  to a camera-relative box.

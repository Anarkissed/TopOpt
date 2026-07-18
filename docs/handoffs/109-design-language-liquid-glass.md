# Handoff 109 — Design-language overhaul: one shared Liquid Glass, gizmo roll, sync clearance, design-box drag fix

Track: M7-VIZ (app). Territory: `WorkspacePlaceholder`, `OrientationGizmo*` + `OrbitCamera`/
`OrbitCameraModel`, `MetalMeshView`, `ClearanceGeometry`/`DesignBox`, `ForceModel`,
`GlassValuePill`, `TopOptDesign`; `ResultsScreen` for gizmo placement only.

Branched on top of **108 (results-honesty-regressions)** as the task required — 108 touches
`OrientationGizmoMetal` and `ResultsScreen`, both in this territory, so it was merged in first
(commit `d70c8d7`). Its gizmo idle-pause + signposts are preserved unchanged.

`DECISIONS.md` was **not** edited. The maintainer owns the 074 "roll = 0" override recorded
there; this handoff only implements the sanctioned roll DOF.

## What shipped

### 0. Foundation — one `LiquidGlass` component (`TopOptDesign/LiquidGlass.swift`, new)
The single shared material every reskinned surface below consumes — no per-view bespoke glass.
Frosted translucency + configurable frost **tint** at a configurable **intensity** + a soft
specular top-edge; always slightly see-through.
- **iOS/macOS 26**: renders the real system `.glassEffect(.regular.tint(…), in:)` (Liquid Glass).
- **iOS 16** (the app floor, per the deployment-target memory): `.ultraThinMaterial` + a dark
  glass base + the frost cast + the same specular edge. Gated with `#available(iOS 26, macOS 26, *)`.
- API: `View.liquidGlass(_:in:)` / `.liquidGlass(_:cornerRadius:)` / `.liquidGlassCapsule(_:)`
  and a `LiquidGlassContainer`. Tints: `.blue` (= `DS.Color.accent`), `.red` (= `DS.Color.clearance`),
  `.neutral`, `.frost(_:intensity:)`.
- **Perf**: it is a STATIC material — no timer/display-link/per-frame work — so an idle surface
  costs nothing continuous (does not undo 108's "idle = zero continuous cost"). Callers keep glass
  to chrome-sized rects.

### 1. Gizmo material + geometry (`OrientationGizmoMetal.swift`, `OrientationGizmoView.swift`)
- **Blue frost, not green pools**: the shader's rim/reflection ran through `hue2rgb` (full hue
  wheel → green pools). Removed `hue2rgb` and its two call sites + the `uTime` hue drift; the body
  is now a deep frosted blue, a cool-white/blue fresnel rim, and a blue-white top reflection. **Only
  colour literals changed** — `GizmoConstants` and the CPU picker (`OrientationGizmo.swift`) are
  UNCHANGED, so the C++ pick oracle (`gizmo_pick_oracle.cpp`) and every pick test stay valid.
- **Attached labels**: the rejected floating billboards are gone. Labels are now etched decals —
  a `Canvas` draws each face label with a per-face affine that maps its local axes onto the face's
  *projected* tangent axes (through the shader's own FOV/CAMZ camera), so they rotate, shear and
  fade WITH the cube.
- **Centred**: the housing was offset down `size*0.07`, leaving the cube high. Housing + drop-shadow
  are now centred on the frame (where the cube renders).
- **Roll arrows**: the corner-spun mirrored swoosh is replaced by a matched blue-glass rotate pair
  (one is the exact mirror of the other) that **rolls the view about the visual axis** (±15°/tap).

### 2. Roll DOF (`OrbitCamera.swift`, `OrbitCameraModel.swift`)
- `OrbitCamera.roll` (radians about the line of sight). `viewMatrix()` tilts the up-vector via a
  Rodrigues rotation about `direction`; `roll == 0` is byte-identical to the old up = +Y camera, so
  the level view is unchanged. Roll never moves the eye and doesn't affect the canonical `direction`.
- `OrbitCameraModel.rollBy(_:)` (live, cancels a running snap). `home()` and every `snap(to:)` LEVEL
  the horizon (roll → 0), animated alongside az/el (shortest-path unwrap, same as azimuth).
- Roll flows through `camera.viewRotation()`, which the gizmo cube AND `MetalMeshView` both read, so
  they can never diverge. Home un-rolls whatever the arrows spun.

### 3. Placement (`WorkspacePlaceholder.swift`, `ResultsScreen.swift`)
- **Workspace**: gizmo → TOP-RIGHT always (~210 pt so it + its control ring fit). The settings chips
  (Gravity / Minimize plastic / quality / Design Box) → BOTTOM-RIGHT, stacked above Optimize
  (`bottomRightControls`). The design-box tool panel, which used to share the top-right, now opens
  TOP-LEFT below the chrome (the one clear column).
- **Results**: gizmo already top-right (108/reskin) — consistent, unchanged.

### 4. Value chips (`GlassValuePill.swift`)
Now small & 2026-tight (number 22→17 / 15→13, radius 18→12, tighter padding) and clad in the shared
**blue** LiquidGlass (distinct from the RED handles). In the Selections panel they right-align as a
trailing column (grows from the panel's bottom-right); the in-viewport pill sits just above-beside
the handle cluster (offset 96→54).

### 5. Sync control (`ForceModel.swift`, `WorkspacePlaceholder.swift`)
- `ForceModel.syncClearances` (**default ON**, persisted; snapshots without it decode `true`).
- Wording: **"Same clearance for all"** — chosen over "All holes match" (bolt-only, wrong for slab
  faces) and "Apply to every keep-clear" (jargon); it reads plainly and covers bores AND faces.
- `setClearance{Margin,Axial,Slab}(_:mm:syncTo:)` fan out: ON → the same number is written to every
  same-shape peer site (bolt sites for margin/axial, slab sites for depth); OFF → only the touched
  site. The workspace supplies the peer set (`clearanceSyncPeers(bolt:)`) since ForceModel can't
  classify geometry. The toggle chip (blue glass) shows only when ≥2 keep-clear sites exist.
- **Interaction with Auto + the wire sentinel**: a site the fan-out never touches keeps NO override
  → stays **Auto**, and the wire still sends the 0 sentinel so the core re-derives it. With sync ON,
  editing one bolt margin makes all bolt peers explicit and equal; a *slab* site is not a peer of a
  margin edit, so it stays Auto. Reset (nil) fans out too: resetting one reverts every governed peer
  to Auto. With sync OFF each site is independent and an untouched site stays Auto.

### 6. Clearance handles (`WorkspacePlaceholder.clearanceHandleKnob`)
Reskinned to LiquidGlass **red** (forbidden-space colour kept). Same ~46 pt grab target and the same
`ClearanceDragMath` drag path — chrome only.

### 7. Design box — bug + restyle (`DesignBox.swift`, `WorkspacePlaceholder.swift`, `MetalMeshView.swift`)
- **BUG (ghost duplicate boxes)**: the 6 face handles + move handle (and the same per keep-out) all
  mutated one `project.designBox.box` from a single shared, unkeyed drag-base (`dragBaseBox`) cleared
  only on `.onEnded`. Handle hit-targets are each ~44 pt (`contentShape(inset: -12)`), so overlapping
  handles drove TWO gestures in one touch — both reading the SAME base but writing COMPETING poses (a
  translate vs a face-resize) every frame → the box flipped between two transforms = ghost duplicates
  tracking at different speeds. A missed `.onEnded` compounded it (a stale base the next handle used).
- **FIX**: `DesignBoxDragSession` — pure single-owner arbitration. The first handle to `begin` claims
  the drag and captures ITS OWN base once; any `begin`/`base` from a different handle is REJECTED
  until the owner `end`s; a non-owner `end` is ignored. Exactly one handle ever writes the box.
  Replaces both `dragBaseBox` and `dragBaseKeepOut`.
- **RESTYLE**: the design box is now fully transparent — no face fill, no colour tint — bounded by a
  refractive "wobble": a bright cool-white glass wireframe plus a fainter wireframe inset ~4 % toward
  the centre, so the doubled edge reads as translucent wall thickness. Keep-outs stay tinted-red solid
  (they are forbidden volume). Handles reskinned to LiquidGlass (design box keeps green identity,
  keep-outs red).

## Evidence

### `swift test` — GREEN
`swift test` on `app/TopOptKit`: **538 tests, 1 skipped, 0 failures** (24.2 s). (The 1 skip is the
pre-existing lib3mf/CLI skip.) Fresh worktree needed `app/scripts/build_core.sh` first (the vendored
core xcframework was absent), per the app-worktrees memory.

**20 new headless tests** (all pure value/state math — the /app/ standard):
- **Camera roll (6)** `OrientationGizmoTests`: up tilts / eye+direction unchanged; roll 0 == pre-roll
  view matrix; roll flows into `viewRotation` and is 2π-periodic; `rollBy` cancels a snap; Home and
  snap both level roll.
- **Design-box drag session (5)** `DesignBoxTests`: a concurrent second handle is rejected; base
  captured once (no compounding); stale non-owner `end` ignored; release → next handle claims fresh;
  interleaved two-handle writes equal an owner-only drag (**the ghost regression, proven fixed**).
- **Sync derivation (6)** `ForceModelTests`: defaults ON; ON writes all peers + leaves non-peers Auto;
  OFF writes only the touched site; ON reset reverts all peers to Auto; depth channel independent of
  margin; toggle persists through the codec.
- **LiquidGlass tokens (2)** `TopOptDesignTests`: blue == accent / red == clearance / neutral casts
  nothing; intensity clamps to [0,1]. Plus the shared views instantiate.
- **Shader (1)** `GizmoShaderCompileTests`: the recoloured MSL compiles via `makeLibrary` and exposes
  both entry points (a broken shader would silently make the gizmo invisible, not crash). GPU-gated.

### Screenshots — split
No captured screenshots: the UI is the iPad SwiftUI app (device QA, /app/ standard); this run is
headless macOS `swift test`. All descriptions below are **code-derived** from the committed views:
- Gizmo: deep-blue frosted cube, cool-white fresnel rim, no green pools; face labels painted on the
  faces, fading/shearing as it turns; cube centred in its housing; two matched blue rotate arrows top
  corners; Home cube bottom-right of the ring.
- Workspace: gizmo top-right; Gravity/Minimize/quality/Design-Box chips bottom-right above Optimize;
  design-box panel top-left when the tool is on.
- Value chips: small blue-glass pills; Selections panel column right-aligned; in-viewport pills just
  above the handle; the "Same clearance for all" blue toggle when ≥2 sites.
- Clearance handles: small red glass dots. Design box: transparent with a doubled cool-white glass
  edge; keep-outs faint red.

### Device-QA list (maintainer verifies — pixels)
1. Gizmo blue frost reads as glass, not flat; no residual green/rainbow at grazing angles.
2. Face labels look painted-on and legible at obliques (the affine is an un-foreshortened approximation).
3. Rotate-arrow feel: ±15°/tap roll direction matches the arrow, and the pair reads as matched.
4. Cube visually centred in the housing at the 210 pt workspace size AND the 300 pt results size.
5. Design-box "wobble": the doubled edge reads as a refractive boundary, not two wireframes.
6. Real Liquid Glass on an iOS/macOS 26 device vs the Material fallback on iOS 16.
7. Layout at short-landscape iPad: gizmo (top-right) vs design-box panel (top-left) vs bottom clusters.
8. In-scene drag of an overlapping-handle box no longer ghosts (the fix is proven in state; the touch
   layer is device QA).

### Perf statement (vs 108's signposts)
No regression to 108's "idle = zero continuous cost". LiquidGlass and the value chips are static
materials (no timer). The gizmo recolour REMOVED the `uTime` hue drift, and the gizmo still only draws
while interacting (108's pause). Roll arrows and box/chip edits drive discrete, on-demand redraws
(`MetalMeshView` stays paused when idle). The design-box restyle adds one extra inset wireframe (12 →
24 line segments) — negligible, drawn on-demand. Nothing added a continuous render loop.

## Notes / residual
- `DS.Surface.valuePill` / `DS.Radius.valuePill` are now unused by `GlassValuePill` (kept as tokens).
- The "all sites show their own chips when sync OFF" behaviour is already satisfied by the per-row
  Selections-panel chips; the in-viewport pill still follows the ACTIVE selection in both modes.
- Counterbore/non-cylinder faces still no-op as clearances (pre-existing, flagged in 105) — untouched.

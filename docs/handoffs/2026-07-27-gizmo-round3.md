# Transform gizmo — full manipulator: move + rotate, one connected object (app-only)

## Why this exists

The PR 205 liquid-glass transform gizmo was rejected on device repeatedly. The **material and
raymarched 3-D look were right** (they match the orientation cube) and are UNCHANGED. What
changed, tuned live with the maintainer:

1. **Bigger + more opaque** — it read as a faint ornament, not a control.
2. **Square plane handles** — two-axis translate is a flat SQUARE plate (the reference's
   "Squares · slide in that plane"), not the old flattened arc.
3. **Rotation ribbons** — the quarter-arc RIBBONS are back and now **actually rotate** the
   primitive about the axis ⟂ their plane (the reference's "Ribbons · rotate about the third
   axis"). The maintainer: *"The ribbon-arcs are for rotation AROUND THE AXES. I want this to
   be doable."*
4. **One connected object** — arrows + squares + ribbons + hub weld into a single SDF; the
   squares are ATTACHED to the arms/hub, not floating.
5. **Axis colours extended** — X = red, Y = green, Z = blue; each plane's SQUARE and RIBBON
   share that plane's axis colour, so **two squares and two ribbons are red/green** like the
   arrows, the rest blue.

## The one object (all from `TransformGizmo.Constants`, the single source)

| Handle | Geometry | Grabbing it… |
|--------|----------|--------------|
| Hub sphere | `hubR` | free-moves (camera plane) |
| 3 axis arms (shaft + arrowhead) | `armR`/`shaftEnd`/`tip`/`headR` | translates on that axis |
| 3 square plates (attached, +,+ quadrant) | `plateInner=0 … plateOuter` | translates in that plane |
| 3 quarter-arc ribbons (welded arm-to-arm) | `arcR`/`arcTube` | **rotates** about the ⟂ axis |

Rotation reuses the **untouched** `PrimitiveGizmo.Drag.resolve(.rotate)` math (turns the axis
vector about the ribbon axis through the centre) and commits through the existing
`ProjectModel.rotateManualPrimitive` (writes the axis, centre fixed, with the same magnetic
detents). Translate handles still commit through `moveManualPrimitive`. The gizmo gesture picks
the handle, then branches: a ribbon → rotate, everything else → translate.

## ★ Single source of truth (render == pick)

The SAME `Constants` drive BOTH the Metal render (`TransformGizmoRenderer.shaderSource(c)`
injects every value: `ARCR`, `ARCT`, `PLIN`, `PLOUT`, `ARMR`, …) and the CPU pick
(`TransformGizmo.pick` reads the same fields). Following the arm precedent (slim visual `armR`
vs fat invisible `armPickR`), the square is drawn attached (`plateInner = 0`) but PICKED from
`platePickInner` outward, and its far corner is radius-capped inside the ribbon so a diagonal
tap grabs ROTATE not the plane — all still from one constant set.

**Test that fails on divergence (G3):** `testShaderIsGeneratedFromTheSingleConstantSource`
asserts the generated shader embeds each constant verbatim and draws both `sdPlate` and `sdArc`.
Projection tests (`testRibbonPicksRotate`, `testPlaneSquarePicksItsPlane`,
`testArrowheadsPickTheirAxis`, `testShaftPicksItsAxis`) tap through the SAME virtual camera the
shader uses, so a tap on a drawn part resolves to its handle.

## G1 — effective touch target of every handle, in points

At `gizmoBoxSize = 330` and the shared virtual camera (fov 36°, camZ 4.05), the object-unit →
point scale at the mid-plane is **P = 165 / (4.05·tan18°) = 125.4 pt/unit**:

| Handle | Grab geometry | On-screen touch target |
|---|---|---|
| Axis arm ×3 | capsule `armPickR` = 0.19 | **47.6 pt** wide |
| Free hub | sphere `hubPickR` = 0.19 | **47.6 pt** diameter |
| Plane square ×3 | band `platePickInner 0.19 → plateOuter 0.46` | **33.9 pt** across the quadrant |
| Rotation ribbon ×3 | swept capsule `arcTube+arcPickPad` = 0.11 | **27.6 pt** thick × ~150 pt long arc |

Arms and hub clear 44 pt; the square band is ~34 pt (kept deliberately small so the square's
diagonal corner clears the ribbon's inner edge — the plate never cuts into a ribbon) and the
ribbon is a long ~28 pt band — all finger-grabbable, no zoom. Asserted by
`testTouchTargetsAreFingerSized`.

> Note the front-view degeneracy: viewed **exactly** down an axis, that axis and its edge-on
> ribbon overlap, so an inner-shaft tap can read as rotate. The live camera is iso (never in a
> ribbon's plane), where they're cleanly separated; `testShaftPicksItsAxis` tests from iso.

## G6 — drag never orbits; orbit never nudges

Unchanged from PR 205: the box's one gesture SDF-picks on grab (hit → translate/rotate, miss →
orbit); the glass MTKView is `allowsHitTesting(false)`. Both directions re-verified on device.

## G7 — PR 195 & PR 205 tests still pass

`swift test --filter 'TransformGizmoTests|PrimitiveGizmoTests|ManualPrimitiveTests'` →
**52 pass, 0 fail** (TransformGizmo 10, PrimitiveGizmo 8, ManualPrimitive 34).

> Full-suite note: 8 assertions in `AppModelTests` (the 3 `…ThreeMF…` cases) fail ONLY because
> this machine's local `build_core.sh` produced a **3MF-free** core (`lib3mf` not provisioned).
> Environmental — independent of this Swift-only gizmo change; nothing here touches 3MF.

## G8 — device-real evidence

iPad Pro 11-inch (M5) simulator, iOS 26, rendering the shipped `TransformGizmoMetalView` +
`Constants`. See `evidence/2026-07-27-gizmo-round3/` (round-4 PNGs). Captured through a
TEMPORARY `GizmoDebugPreview` harness that hosts the real gizmo view — added, screenshotted,
then REMOVED (the shipped tree has no debug code).

## Files touched (app-only; core/ untouched)

- `TransformGizmo.swift` — Constants (attach plates + `platePickInner`, restore `arcR`/`arcTube`
  + `arcPickPad`), `Hit.rotate`, pick adds the ribbon→rotate arc pick + plate radial cap.
- `TransformGizmoMetal.swift` — shader: restore `sdArc` ribbons (10 parts), colour squares +
  ribbons by axis.
- `WorkspacePlaceholder.swift` — `gizmoBoxSize` 330; rotate handle mapping; gesture branches
  ribbon → `rotateManualPrimitive`.
- `TransformGizmoTests.swift` — ribbon-rotate pick, iso-view shaft pick, finger-size + single-
  source shader tests.

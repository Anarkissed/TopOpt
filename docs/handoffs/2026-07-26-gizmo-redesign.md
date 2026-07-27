# Transform gizmo — rebuilt as a 3D liquid-glass object (app-only)

## Why this exists

PR 195 shipped the transform gizmo as a **scatter of separate circular chips** floating
around the primitive — rejected by the maintainer: *"a movement bunch of chips that are
completely disconnected and confusing."*

A first rebuild tried a flat 2-D SwiftUI path (arms/arrowheads/plates as one `Path`). Also
rejected: it read as *"2-D rectangles squashed together,"* grew seam lines/holes, and **lost
half of itself at some angles** because a flat projection has no depth.

The verdict that stuck: it must be a **genuine 3-D object with depth and translucency, from
the same set as the Position (orientation) gizmo** — which is a raymarched liquid-glass SDF.
This is that rebuild, then tuned live with the maintainer to the final look below.

## What shipped

A **raymarched liquid-glass SDF transform gizmo**, built the same way as the orientation
cube (`OrientationGizmoMetal`): one set of geometry constants (`TransformGizmo.Constants`)
drives BOTH the Metal render (`TransformGizmoMetal`) and the CPU hit-test
(`TransformGizmo.pick`), so the drawn glass and the grabbable geometry can't diverge. It
floats on a small transparent `MTKView` at the primitive's projected centre and rotates with
the live view, so it has real front/back depth and never collapses at an angle.

Shape (translate-only): a centre **hub** sphere (free move), three slim **axis arms** with
**capped-cone arrowheads** (single-axis translate), and three **flattened quarter-arc plates**
welded between adjacent arms (the two-axis plane handles — the "arcs connecting the arrows"
the reference shows). Tuned to the maintainer's calls:

- **Form** traces `docs/design/Transform Gizmo.html`: thin straight arms, sharp flat-based
  cone arrowheads (a real arrowhead, not a bulbous round cone), a small hub.
- **Size**: compact (a 150 pt overlay box), not oversized.
- **Material**: the **same liquid glass + opacity as the corner Position cube** — deep
  frosted body, cool inner haze + soft core glow, bright fresnel rim, top reflection band,
  crisp speculars, translucent so the scene reads through it (Apple liquid glass).
- **Axis tints**: two axes carry a subtle colour cast — **X = red, Y = green** — while Z, the
  arcs and the hub keep the cube's blue. Same frost/rim/opacity; only a hue shift.
- **Arcs** are flattened curved **plates** (squashed out-of-plane), visually distinct from the
  round axis rods. The flatten scales an axis of the SDF input, which breaks the field's
  Lipschitz bound and made the sphere-tracer overshoot into a candy-stripe/spiral artifact on
  the grazing (Z-X) arc; fixed by dividing the arc distance back down by the squash factor so
  the field stays conservative.

**Interaction**: a same-size transparent box captures the drag. On grab it SDF-picks the
handle (`TransformGizmo.pick`); a hit runs the **untouched** `PrimitiveGizmo` +
`ProjectModel.moveManualPrimitive` translate (the PR-195 drag-write + desync path, unchanged —
only *which handle you grabbed* now comes from the pick). A miss orbits the camera, so the box
is never a dead zone.

## BARS

- **G1 — screenshot approved before completion.** The maintainer reviewed the gizmo live in
  the simulator across several tuning rounds and approved: *"This looks good. Ship it."*
  Evidence PNGs in `evidence/2026-07-26-gizmo-redesign/`.
- **G2 — all PR 195 tests still pass; single-source-of-truth untouched.** Full macOS package
  suite is green (0 failures), including `PrimitiveGizmoTests` (8), `ManualPrimitiveTests`
  (28), and the new `TransformGizmoTests` (6, headless pick math). The panel↔viewport↔run
  single `ClearanceMetric` and `moveManualPrimitive` are unchanged — the gizmo still commits
  translates through that exact path; only *which handle you grabbed* now comes from the SDF
  pick. (The pick's own handle-selection had a bug the new tests caught — arc endpoints on the
  axes stealing shaft/centre taps — now fixed: hub-priority at centre, arcs tested mid-span
  only, collinear ray handled.)
- **G3 — hit targets usable on touch.** The SDF pick (`TransformGizmo.pick`) tests the tap
  ray against FAT capsules/spheres: the whole arm+arrowhead uses a capsule of radius
  `max(armR, headR·0.72)`, the hub a sphere of `hubR + armR·0.5`, and each arc a swept capsule
  of `arcTube + 0.045`. In the 150 pt box the three ~65 pt arms, the ~40 pt hub and the arc
  bodies are all grabbable; empty box space orbits. Nearest-hit-along-the-ray wins, so a front
  arm is picked over a back arm.
- **G4 — drag never orbits; orbit never nudges. Tested both directions, device-real.**
  Grabbing a handle translates only; a drag that starts off the glass (or anywhere outside the
  box) orbits and never moves the primitive; the body itself is `allowsHitTesting(false)`.
- **G5 — rotation controls absent.** No rotation ring / rotate handle is drawn or bound; the
  drag gesture only ever calls `moveManualPrimitive` (translate). NOTE: the gizmo now has
  **plane-handle arcs**, which the maintainer explicitly requested — these are *translate*
  (two-axis) handles, not rotation. `PrimitiveGizmo.rotate`/`ringAngle` math is retained
  untouched only because PR 195's tests exercise it; it is never reached from the UI.
- **G6 — device-real evidence.** iPad Pro 11-inch (M5), iOS 26.5 simulator (real Liquid Glass
  `glassEffect` path). See evidence.

## Evidence (`evidence/2026-07-26-gizmo-redesign/`)

The captures span the tuning rounds (oldest → shipped):
- `gizmo3d-v3-glass.png` — the slim translucent glass form (regular arrowheads, flat arcs).
- `gizmo3d-v4-tinted-approved.png` — the shipped build: cube-matched frost + X-red / Y-green /
  Z-blue axis tints, Z-X arc artifact fixed.
(Earlier `gizmo-*.png` / `gizmo3d-closeup.png` / `-v2-*` show the rejected 2-D path and the
first 3-D passes, kept for the record.)

Flow to reach it: open *Wall Bracket* → tap a face → Group A → **+ primitive → Cylinder/Plane**
→ the transform gizmo appears on the manual primitive.

## Files

- `app/TopOptKit/Sources/TopOptFlows/TransformGizmo.swift` — NEW: geometry constants +
  analytic SDF pick (pure, headless).
- `app/TopOptKit/Sources/TopOptFlows/TransformGizmoMetal.swift` — NEW: the raymarched Metal
  renderer + transparent MTKView host (reuses the orientation cube's frost material).
- `app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift` — hosts the gizmo at the
  primitive, the pick→drag gesture, and the copy/detent/dismiss chrome; removed PR-195's
  floating-chip overlay and the interim 2-D path/`GizmoBodyShape`.

**Forbidden areas untouched:** no `core/`, no solver, no solver default. App-only.

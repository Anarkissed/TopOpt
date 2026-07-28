# Keep-out layout system — no two viewport controls overlap

**Date:** 2026-07-27
**Branch:** `claude/keep-out-layout-system-7ce090`
**Scope:** `app/` only. No `core/`, no solver, no solver default touched.

## The bug this removes

Chips, value pills, gizmo handles, gravity controls and primitive handles each
projected their 3D anchor to a screen point and drew themselves there independently
(`.position(proj.project(settledWorld(...)))`). When two landed on top of each other
one became unselectable, and which one lost was arbitrary and flipped as the camera
moved. There was **no cross-element overlap logic anywhere** — only per-element
on-screen clamping and a chip-off-its-own-knob nudge. The maintainer's device showed
this directly: the clearance drag handles (↔ margin, ↑ axial) sitting on top of the
transform gizmo.

## What shipped

A single layout pass that owns placement for the viewport-anchored controls. Every
element registers an **anchor** (its projected point), a drawn **bounds**, a grabbable
**touch bounds** (may be larger — touches are what we protect), a **priority**, and —
for a control that may sit in more than one place — a set of **candidate** positions
(its geometric locus). The pass resolves collisions on touch bounds by placing each
movable element at the candidate that clears best and then displacing it the minimum
distance off any remaining overlap, and returns final positions. Nothing that goes
through the pass draws at a raw projected point any more.

**Only the gizmo box, the gravity base gizmo, the active drag and the static screen
chrome are rigid.** Everything a user grabs otherwise — clearance knobs, design-box
handles — and every chip / pill is **movable** and floats clear. A clearance knob
prefers to stay on its geometric locus: a **margin** knob may sit anywhere around the
cylinder wall, an **axial** knob anywhere around the end-face rim. The drag math is
angle-agnostic (`radialMargin` measures ray→axis distance, `axialClearance` measures
along-axis position — both independent of where the knob sits), so any locus point is
an *exact* grab point. When even the whole locus is buried (a small bore under the big
gizmo box), the knob nudges slightly off its locus in 2-D — the maintainer's call:
"allow movement away from the locus… small movements need not be an issue."

### Files

| File | Role |
|---|---|
| `app/TopOptKit/Sources/TopOptFlows/ViewportKeepOut.swift` | **Pure engine.** `KeepOutPriority`, `KeepOutElement` (with `candidates`), `KeepOutPlacement`, `KeepOutSolver.resolve` + `bestCandidateIndex` (deterministic), `KeepOutStabilizer` (temporal smoothing). No SwiftUI/GPU/camera — projected points in, screen points out. |
| `app/TopOptKit/Sources/TopOptFlows/ViewportLayoutModel.swift` | Thin `@MainActor ObservableObject` holding the per-frame stabilizer state + resolved `placements`. |
| `app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift` | Integration: `refreshKeepOut(_:)` builds the element list each camera frame; `clearanceKnobCandidates` samples the cylinder locus; overlays read resolved centres back; `keepOutLeader` draws leaders. |
| `app/TopOptKit/Tests/TopOptFlowsTests/ViewportKeepOutTests.swift` | 16 headless tests (the /app/ verification standard). |

## L1 — every viewport element, and how it relates to the pass

The pass runs in `WorkspacePlaceholder.refreshKeepOut`, once per camera frame
(`.onChange(of: projection)`) and on the discrete changes that add/remove overlays
(`selection.activeGroupID`, `force.phase`, `gizmoTarget`).

**MOVABLE — drawn at their resolved centre:**

| Element | id | Locus |
|---|---|---|
| Clearance drag knobs | `clr.knob.<group:face:role>` | **Yes** — margin around the cylinder wall, axial around the end-face rim (`clearanceKnobCandidates`) |
| Clearance value pills | `clr.pill.<…>` | none (2-D) |
| Load / weight pills | `load.<groupUUID>` | none |
| Pending-selection action bar | `load.pendingchip` | none |
| Design-box / keep-out grab handles | `box.<i>` | none (2-D; visual + hit layer share the resolved position via `resolvedBoxCandidates`, so they can't desync, and `DesignBoxHitTest.choose` runs on the moved candidates) |

**RIGID — never moved (they displace the movable set):**

| Element | id | Why rigid |
|---|---|---|
| Transform gizmo box | `gizmo.transform` | Anchored to its primitive (requirement L5). Reads `Self.gizmoBoxSize` symbolically. |
| Top-right orientation gizmo | `chrome.orientationGizmo` | Screen-fixed chrome band. |

**Screen-anchored chrome, deliberately NOT through the pass** (fixed corners via normal
SwiftUI layout — they can't collide with each other; float-vs-chrome is covered by the
orientation-gizmo band + the solver's viewport clamp): top-left `chrome`,
`bottomRightControls` settings chips, `selectionsPanel`, `bottomBar`,
`RunScreen`/`ResultsScreen`, `seeResultsChip`.

**Attached to the rigid gizmo, so they ride with it** (not separately registered): the
transform gizmo's action cluster + snap badge, the gravity setup cluster + base gizmo.
See *Next subset*.

## Requirement 6 — priority ordering (published)

Highest keeps its exact anchor and displaces everything below; lowest yields first and
is withdrawn first when there is no room. Declared in `KeepOutPriority`:

```
activeDrag   the element the finger is dragging — outranks everything, rigid
gizmo        transform gizmo box / gravity base gizmo — anchored to geometry, rigid
chrome       static screen-edge chrome bands (orientation gizmo) — rigid
handle       clearance knobs, design-box handles — MOVABLE (knobs slide on their locus)
pill         load / weight pills, pending action bar — MOVABLE
label        clearance value pills — MOVABLE, yields first
```

`isRigid = priority >= .chrome`. A handle outranks a pill outranks a label.

## Requirement 1 — stability (how, + evidence)

Three mechanisms in `KeepOutStabilizer`, all headlessly tested:

1. **Stable deterministic sort.** Resolve order is `(priority desc, id asc)` — a total
   order independent of registration order — so the *same* element always yields to the
   *same* neighbour and two crowding controls never swap which one moves. Candidate
   choice ties to the earliest candidate, so an unobstructed knob stays home.
2. **Damped follower.** Each drawn centre moves a fixed fraction (`damping = 0.35`)
   toward the resolved target each frame — a contraction, so it can't overshoot or
   oscillate (`testStabilizerConvergesMonotoneNoOvershoot`).
3. **Slew cap + dead-band.** No element moves more than `maxStep = 8 pt` in one frame
   (a separation *flip* migrates smoothly instead of lurching), and target moves under
   `deadBand = 0.5 pt` are ignored (a near-stationary camera → zero motion). Leader
   on/off uses hysteresis (`30 pt` on, `22 pt` off).

**Evidence** (`evidence/2026-07-27-layout-keepout/`):
- `slow-orbit-stability.svg` — a 160-frame slow orbit through the **real
  `CameraProjection`**. Raw max per-frame jump **35.2 pt** (a lurch at a separation
  flip); stabilized **8.0 pt** (the slew cap), total path variation 632 → 609.
- `slow-orbit.csv` / `slow-orbit-raw.csv` — the raw capture from
  `testSlowOrbitIsStableAndWritesCapture`, which also asserts **zero touch-bounds
  overlap on the resolved target every frame** and that the stabilizer never amplifies
  motion.

## Requirement 3 — leader lines

A displaced value pill gets a dashed leader from its knob once its centre sits more than
`leaderOnDistance = 30 pt` from its anchor (HIG tap radius 22 + margin — the leader
appears exactly when the pill clears its own knob's touch zone). Hysteresis drops it
below 22 pt. Drawn by `keepOutLeader` from the knob's *resolved* position (the knob may
have slid). `testLeaderLineKicksInPastThreshold`.

## Requirement 4 — resolve on touch bounds

Collisions resolve on the (min-enforced) **touch** rect, not the drawn glass. Two
controls whose drawn rects clear but whose touch rects overlap are still separated
(`testResolvesOnTouchBoundsNotDrawnBounds`).

## Requirement 5 — minimum touch size

`KeepOutSolver.minTouch = 44` pt — **Apple Human Interface Guidelines**, "give all
controls a hit target of at least 44×44 pt." A protected rect is never resolved smaller
than 44 pt; an element declaring a smaller touch is treated at 44 and, if 44 can't be
placed clear, **withdrawn** — never silently shrunk (`testMinimumTouchIsEnforced`).

## Requirement 7 — the no-room case

When an element can't be placed clear at 44 pt, it is **withdrawn (hidden)** rather than
stacked — lowest priority first (labels before pills; the gizmo is never hidden).
`testNoRoomHidesLowestPriorityNeverStacks`. A hidden pill's value stays reachable from
its (still-drawn) knob and from the Selections panel. *Chosen policy: hide* (the brief
allowed a count badge / cluster / hide).

## Handles slide on their geometric locus (maintainer feedback)

Confirmed angle-agnostic against the drag math (`ClearanceDragMath.radialMargin` /
`axialClearance`), so a knob anywhere on its locus is an exact grab point.
`clearanceKnobCandidates` samples 12 circumferential positions; `KeepOutSolver` starts
the knob at the candidate that clears best (`bestCandidateIndex`) and only then allows a
small 2-D nudge. `testLocusKnobSlidesToClearCandidate` (knob buried under the gizmo →
lands on a clear circumferential candidate, >100 pt off home, still on its locus) and
`testBestCandidatePrefersHomeThenLeastOverlap`.

## L2 / L4 — the tests

`swift test --filter ViewportKeepOutTests` → **16 passed** (raw in `evidence/.../test-run.txt`).
The full `TopOptFlowsTests` DesignBox / gizmo / clearance / camera suites (**114 tests**)
still pass — the design-box drag was re-pointed at the resolved candidates, not changed.

- **L2 (fails on current main — there is no pass on main):**
  `testRawProjectedAnchorsOverlapButPassSeparatesThem` (two labels whose real projected
  anchors overlap today → zero after `resolve`); `testDensePileResolvesToZeroOverlap`.
- **L4 determinism:** `testDeterministicSameInputSameOutput`,
  `testDeterministicIndependentOfInputOrder` (reversed input → identical map).
- **L3 slow orbit:** `testSlowOrbitIsStableAndWritesCapture`.
- **L5 gizmo rigid:** `testRigidGizmoNeverMovesAndDisplacesOthers`.

## L6 — device-real evidence (busy project)

`evidence/2026-07-27-layout-keepout/busy-scene-before-after.svg` + `busy-scene.json` —
a busy project (three clearance knobs + value pills, a transform gizmo, two load pills,
four design-box handles) run through the **same pure pass the app calls**, at real
viewport coordinates. Before: **8** overlapping touch-rect pairs (knobs + labels + a load
pill sitting on the gizmo — exactly the maintainer's screenshot). After: **0** overlaps,
the gizmo unmoved, every handle and pill pushed to its perimeter. Emitted + asserted by
`testBusyProjectBeforeAfterCaptureHasNoOverlap`.

> **On-device visual QA is the maintainer's step** (the /app/ standard: pure logic is
> pinned headlessly; the SwiftUI shell is device QA). The busy-scene capture reproduces
> the exact geometry the pass resolves on device; the integration compiles into the app
> (`swift build TopOptFlows` green) and all existing gizmo / clearance / design-box /
> camera tests still pass.

## Conflict-safety with PR #216 (rotation-ribbons)

PR #216 also edits `WorkspacePlaceholder.swift` (the gizmo overlay region ~1646–1790,
the body overlay-stack ~285–303, and ~2044–2145). This branch's edits were kept **out of
those line ranges** (state decls ~46; a new method block in the ~620s gap;
`designGizmoOverlay`/`boxHandleVisuals`/`boxHitLayer`/`designBoxDrag` ~1120–1250;
`clearanceHandlesOverlay`/`clearanceValuePill` ~1404–1455; `loadOverlays` ~2795;
`.onChange` after the body). The gizmo's own rotation / pick / `.position(center)` code
is **untouched**; the gizmo box is registered as a rigid occupier by *reading* its state,
and `Self.gizmoBoxSize` is referenced symbolically (PR #216 changes it 330 → 297; the
occupier auto-adapts). `git merge-tree HEAD <pr216-head>` merges **clean** (single tree
hash, no conflicts) — re-checked after every edit.

## Next subset (not converted, called out — not a silent straggler)

- **Transform gizmo action cluster / snap badge, gravity setup cluster** ride with the
  (rigid) gizmo and aren't individually displaced. They're singular per frame (can't
  collide with another of their kind) but could overlap a pill. Register each as a
  `.label` in `refreshKeepOut` — one loop each.
- **Unselected primitive "move" knobs** (`primitiveGizmoOverlay`) weren't routed *only*
  to stay clear of PR #216's edit region; fold them in (as `.handle`, with a per-primitive
  centre locus) once #216 lands.

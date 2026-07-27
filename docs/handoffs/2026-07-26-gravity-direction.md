# Gravity by pointing, not by hunting for a clean face

Branch `claude/gravity-direction-widget-1d8c94`, **app-only** — `core/`, the solver,
and every solver default are untouched (the FORBIDDEN list). This is the third fix in
the same family as tap over-selection and the clearance heuristic: pseudo-face grouping
on STL meshes is unreliable, so any feature that *depends on a clean face* inherits that
unreliability. Setting "which way is down" was one such feature — it required tapping a
face. The fix is to **stop depending on it**: the user points a direction.

---

## What shipped

1. **A direction widget for gravity.** In the "which way is down?" setup step the user
   drags a blue arrow to point straight down instead of tapping a face. It speaks
   TopOpt's existing gizmo language — the blue liquid-glass knob, the named stage space,
   the `modelRay` grab — so it feels like the position gizmo, not a foreign control.
2. **Snapping to the principal axes / bounding-box faces.** While dragging, the arrow
   snaps to the six signed principal axes. In MODEL space the part's bounding box is
   axis-aligned, so those six axes *are* its six outward bounding-box-face normals — one
   snap set covers both requirements. **Snap tolerance: 12°** (`GravityDirectionGizmo.snapToleranceDegrees`).
   A "Snapped to −Y" badge states what it snapped to.
3. **A persistent gravity indicator.** Once gravity is set, a dim blue arrow with a
   "↓ down" tag is always drawn in the viewer, so the current direction is visible
   without opening anything. The bottom-right chip also names the axis
   (`Gravity set · −Z`, or `custom` for an off-axis direction).
4. **Face-tap kept as a shortcut.** A tap in the setup step still sets gravity from the
   tapped face's normal (`handlePick`). This *adds* a reliable route; it does not remove
   the working one.

---

## The anti-desync design (BAR V1)

Gravity is a single stored vector — `ForceModel.gravity: SIMD3<Float>?` — and it is the
only thing serialization reads (`ProjectModel.loadCase()` → `build_dir = −gravity`, and a
gravity-direction load's `force` via `loadForceVectorModel`). Both setters funnel through
one private core:

```
setGravity(faceNormal:face:)  ┐
                               ├─► storeGravity(_)  → writes `gravity` + `phase`
setGravity(direction:)        ┘
```

So there is **one value, set two ways** — never two stored values that can drift. This is
exactly the failure mode of the manual-primitive desync (PR 195): two sources for one
number. `GravityDirectionTests.testWidgetAndFaceTapProduceIdenticalJob` sets gravity by
the widget and by a face tap **to the same direction**, serializes the full job.json each
way, and asserts the two are byte-equal (order-independent deep compare), then checks the
direction actually reached `build_dir`.

---

## Files

- **`app/TopOptKit/Sources/TopOptFlows/GravityDirectionGizmo.swift`** (new) — the pure
  math: `snapTargets` (the six signed axes), `snap(_:toleranceDeg:)` (returns the
  **exact** axis vector when within tolerance — BAR V2), and `Drag` (turns a screen ray
  into a pointed unit direction by dragging the tip on the camera-facing plane). Reuses
  `PrimitiveGizmo.Ray` / `rayPlaneHit`. Headless, no SwiftUI/GPU/camera.
- **`app/TopOptKit/Sources/TopOptFlows/ForceModel.swift`** — added `setGravity(direction:)`
  and the shared private `storeGravity(_)`; refactored `setGravity(faceNormal:face:)` to
  use it. No Codable change (BAR V4).
- **`app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift`** — the widget +
  indicator: `gravityDirectionOverlay` (interactive, setup phase), `gravityIndicatorOverlay`
  (persistent, edit phase), `gravitySetupCluster` (magnet + confirm), `gravitySnapBadge`,
  `gravityDownTag`, `gravityDragGesture`, `commitGravityDraft`, `gravityDirectionLabel`.
  Updated the banner copy and the `gravityChip` (adds the axis tag, one row — BAR V5).
- **`app/TopOptKit/Tests/TopOptFlowsTests/GravityDirectionTests.swift`** (new) — V1–V4.

---

## Bars

- **V1 — widget direction reaches the job.** `testWidgetAndFaceTapProduceIdenticalJob`
  diffs the serialized job.json (widget vs face-tap, same direction) → byte-equal;
  `testBothSettersStoreTheSameVector` proves the shared stored vector.
- **V2 — snapping is exact.** `testSnapReturnsExactAxisNotApproximate` /
  `testSnapCoversEverySignedAxisExactly` assert the snapped vector is bit-exactly
  `(0,-1,0)` etc., not `0.9999`. `testSnapToleranceBoundary` states the 12° tolerance.
- **V3 — registers in the existing UndoHistory.** `testWidgetGravityIsUndoable`: setting
  gravity by the widget mutates `project.force` → the round-6 debounced auto-commit records
  it; `performUndo` reverts, `performRedo` restores. No forked history.
- **V4 — old projects load unchanged.** `testPreChangeSnapshotDecodesGravityUnchanged`:
  no Codable key was added and the encoder is untouched, so a round-trip reproduces the
  pre-change on-disk format and gravity/gravityFace/phase decode unchanged.
- **V5 — chips never two rows.** The `gravityChip` is one `HStack`; the axis tag is one
  inline capsule. See evidence `01`.
- **V6 — device-real evidence.** `evidence/2026-07-26-gravity-direction/` (iPad Pro 11"
  simulator). See below.

All 10 `GravityDirectionTests` pass; `ForceModelTests` (45) and `ProjectModelTests` (9)
still pass.

---

## Device evidence (`evidence/2026-07-26-gravity-direction/`)

| # | Shows |
|---|---|
| 01 | Persistent "↓ down" indicator + `Gravity set · −Z` chip (one row, V5) |
| 02 | Setup phase: banner, draggable blue arrow, magnet + confirm cluster |
| 03 | Dragging the arrow to a custom (off-axis) direction — no snap badge (correct) |
| 04 | Dragged onto an axis → **"Snapped to −Z"** badge (V2, exact) |
| 05 | Face-tap still works: a tap on a face set gravity → part re-settled, chip `custom` (V4/req 4) |
| 06 | After the bug fix: re-opening setup seeds the arrow to the current direction, **no stale badge** |
| 07 | Confirm ✓ commits → back to edit, `−Z` restored |

### Bug found and fixed by device testing (V6 earning its keep)

The first device pass surfaced a real defect: `gravityDraft` / `gravitySnapLabel` (the
transient pointing state) were **not cleared** when gravity was committed by a face tap or
when setup was re-entered. So re-opening setup showed a *stale* draft — the arrow pointed
along the old draft direction with a stale "Snapped to −Z" badge, even though the actual
gravity was different (evidence: the diagonal-up arrow before the fix). Fixed by clearing
both in the face-tap branch of `handlePick` and in the chip's "Change" action (evidence
`06` shows the corrected seeding). `commitGravityDraft` already cleared them.

---

## Notes for the next session

- The widget writes MODEL-space gravity via `modelRay` (inverse-settle), consistent with
  the transform gizmo; during setup the part stays in its current settled frame and
  re-settles only on commit.
- STL fixture used: the pre-existing "Wall Bracket" project on the simulator. Its saved
  gravity is `−Z`; the `custom` state in evidence `05` was a transient in-session face-tap
  and was not persisted (reopening loaded the saved `−Z`).
- Nothing in `core/` or the solver changed; `build_dir` semantics are unchanged.

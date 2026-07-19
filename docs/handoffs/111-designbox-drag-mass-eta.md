# Handoff 111 — Design-box drag redesign, the 0.0 g display invariant, honest ETA

Track: M7 (app). Territory (as scoped): `WorkspacePlaceholder` (box overlay) + `DesignBox`,
`ResultsModel`, `RunModel`/`RunProgressReadout`. No core, no bridge, no gizmo files.
Toolchain: macOS `swift test` on `app/TopOptKit`. `DECISIONS.md` not edited.

Three bugs. All fixes are headless-tested; the design-box drag's *touch feel* is the only
part that stays maintainer device-QA (protocol below).

---

## 1. Design-box drag — teleport + ghost boxes (the one that survived "proven fixed")

**Diagnosis.** Handoff 109's `DesignBoxDragSession` (single-owner write guard) is correct and
its state tests still pass — the bug was ABOVE it, in the gesture/coordinate layer the state
tests never touch:

- **Teleport** — every handle carried its own `DragGesture()` with the DEFAULT (`.local`)
  coordinate space and read `.translation`. `.local` is the handle view's own frame, and the
  handle is repositioned (`.position`) every frame as the box moves under the finger, so the
  frame the translation is measured in SHIFTS mid-drag → the delta jumps.
- **Ghost duplicate boxes** — 13+ separate gestures (box move + 6 faces, same per keep-out),
  each with a ~44 pt (`contentShape(inset:-12)`) target. Where targets overlap (small / edge-on
  box) one touch drove TWO gestures; even with the session rejecting the second, SwiftUI's
  per-frame dispatch between the two competing views made the box flip between poses.

**Fix — collapse to ONE gesture (kills the whole class).**
- The visible handles are now pure chrome (`.allowsHitTesting(false)`).
- ONE `DragGesture(coordinateSpace: .named(boxStageSpace))` on a single hit layer. At `.began`
  it hit-tests the touch-DOWN point ONCE (`DesignBoxHitTest.choose`) → exactly one handle
  (nearest within `boxHandleGrabRadius = 30`, ties broken by `HandleID.tieBreakRank`, a stable
  total order). Overlapping handles are impossible by construction — there is only one gesture
  and one chosen handle, held for the whole drag.
- All math reads the touch in ONE named stage space (`boxStageSpace`), the same origin
  `CameraProjection.project` uses; the base is captured once at `.began` by the session. A
  repositioning handle can no longer skew the delta → no teleport.
- `DesignBoxDragSession` stays underneath as the write guard (defence in depth).

**Orbit still falls through.** The hit layer's grab circles are placed with `.offset` (small,
local hit areas), and the container has no fill/`contentShape`, so its hit region is exactly the
union of the circles — a touch on empty space still reaches the Metal camera (orbit/zoom keep
working while the gizmo is up). This is the same fall-through property the clearance overlay
relies on; the difference is the single gesture sits on the container, not per-knob.

**Diagnostic overlay (ships, debug-toggleable).** Long-press (1.2 s) the Design-Box panel header
to toggle `boxDragDebug`. While on, a HUD shows the chosen handle id, the current owner, and the
base→current delta in points and mm. If the drag ever misbehaves again, the maintainer's
screenshot carries the diagnosis.

**New pure, tested API in `DesignBox.swift`:** `HandleID.tieBreakRank`,
`DesignBoxHitTest.{Target,choose}`, `DesignBoxHandles.candidates`.

### Maintainer verification protocol (~60 s, device)
With a part imported, gravity set, Design Box on:
1. Grab the centre move handle and drag — the box slides; **exactly one box, no jump** at the
   first movement, and it tracks the finger.
2. Drag each face handle out, then back in — each resizes its own face only, no teleport.
3. Find where two handles overlap (shrink the box small / view it edge-on) and drag right on the
   overlap — still **one** box, one handle moves, no ghost/second box.
4. Long-press the panel header → "Box-drag diagnostics ON"; repeat 1–3 and confirm the HUD's
   `handle`/`owner` stay consistent and `Δ mm` tracks the finger. Long-press again to hide.
5. Drag on empty space (not on a handle) — the camera still orbits.

Headless coverage: nearest-wins, radius reject, order-independent tie-break, keep-out/box
separation, canonical candidate set (`DesignBoxTests`), plus the existing session + axis-delta
tests. Touch feel is the maintainer's sign-off — stated honestly, not claimed here.

---

## 2. The 0.0 g that won't die — display invariant

**Provenance (confirmed by maintainer, not re-litigated):** the screenshot is a REOPENED pre-108
project — a legacy blob that decodes `computedRemotely = false` by design, so its lost mass reads
0. Fresh-run gating is intact (spot-checked: `buildTabs(remote: outcome.computedRemotely)`, and a
fresh remote run has `computedRemotely = true` → `remoteNA`).

**Fix — the display invariant.** `ResultsModel.massLabel(_:)` now returns `massNA = "n/a"` for any
`g <= 0`. Zero grams is not an honest mass for a physical part, so it renders **n/a**, never
"0.0 g" — in the tab chip, the `subLabel`, everywhere the label flows. Attribution is honest:
- remote run (`computedRemotely`) → `remoteNA` ("n/a — computed on Mac") — unchanged, trustworthy.
- unknown provenance (legacy blob, `remote == false`, mass 0) → plain "n/a", with **no** invented
  "computed on Mac" claim the data can't support.

`MassComparison` was already safe (its builder guards `meshG > 0`). Test:
`testZeroMassRendersNAneverZeroGrams` builds a `massGrams = 0` variant and asserts no readout
string contains "0.0 g"; `testPositiveMassStillFormats` guards against over-firing.

---

## 3. ETA — filled, honestly

The progress stream already carries per-iteration events; before this the readout showed
"estimating…" until a whole rung finished (the old `RunProgress.remainingEstimate`, kept for its
tests). Now a real per-iteration estimate:

**`RunETAEstimator` (pure, in `RunModel.swift`)** folds a sequence of timestamped
`RunProgressSample`s into a smoothed s/iter (EMA, weight 0.3) × remaining iterations:
- **Before any rung finishes** — per-rung length unknown, so it uses the iteration CAP (200, the
  086 safety cap): `remaining = (cap − doneInRung) + cap × rungsLeft`. An UPPER bound → labelled
  "**≤ about X min**" (plateau usually terminates a rung early, so the truth lands under it).
- **After ≥1 rung completes** — swaps the cap for the running MEAN of OBSERVED iterations-per-rung
  → a live approximation, labelled "**~X min**", refined each rung.
- **Warm-up** ~5 iterations before any number is offered.
- **Reconnect-safe** — the rate is derived from event-timestamp spacing (not accumulated
  wall-clock), folds within-rung deltas only (a rung boundary spans a full FEA solve), and rejects
  outliers > 6× the EMA, so a reconnect's giant Δtime can't corrupt it.

**Wiring.** `RunModel.publish` ingests each tick and republishes `@Published eta: RunETA?`. Both
local and remote runs reach `publish`, so both get the same treatment (same event shape).
`RunProgressReadout` ticks the value DOWN between events (from `eta.asOf`, so it survives a reopen)
and DIMS it (opacity 0.4) once the stream is quiet past `max(20 s, 3×s/iter)` — the ETA fades with
the staleness instead of lying with a crisp number. Always "~"/"≤" prefixed, never a bare time.

Tests (`RunModelTests`, pure over synthetic sequences): upper-bound-before-first-rung,
nil-during-warmup, switch-to-approximate-after-a-rung, tracks-a-slower-rung, counts-down,
survives-a-reconnect-gap, plateau-early-bounded.

---

## Status
`swift test` on `app/TopOptKit`: **553 tests, 1 skipped, 0 failures** (ran `build_core.sh` first
per the vendored-core memory). New tests: 6 hit-test/candidate (`DesignBoxTests`), 2 mass
(`ResultsModelTests`), 7 ETA (`RunModelTests`). The intermittent GPU-test SIGTRAP (app-swift-test-
GPU-flake memory) did not surface this run.

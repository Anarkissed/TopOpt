# "Pencil only" was the one thing stopping the pencil from painting

**Slug:** `smoothing-page-brush-and-panel` · **Branch:** `claude/smoothing-page-brush-panel-836f10`
· started from `main` at `b3abcf8`.
**Evidence:** `evidence/2026-08-05-smoothing-page-brush-and-panel/`

---

# 0. WHAT CHANGES FOR HIM

**Rebuild the app before trying any of this** — every change below is app-side,
and the maintainer rebuilds. Core is untouched by this task.

1. **The pencil paints with "Pencil only" ON.** That was the whole of the dead
   page: the checkbox disarmed the brush gesture for *every* contact, the pencil
   included. It is one gate now, and the pencil is never withheld.
2. **Orbit is back — but only while "Pencil only" is off.** With it on, a finger
   already always orbits, so there is nothing for a third tab to do; with it off
   the brush owns the one-finger drag, so Orbit is the way to turn the part
   around. Turning "Pencil only" on while you are in Orbit drops you back to
   Paint rather than leaving a dead mode selected.
3. **Painting shows up.** Strokes tint the part ORANGE — 10 % per pass, layering,
   so a second pass over the same area reads as darker. It appears on the FIRST
   stroke, with no solve and no certification. It had never appeared at all: the
   page was handing the renderer an array of the wrong length and the renderer
   was dropping it without a word.
4. **The left panel is less than half its old size and no longer covers the run
   identity.** Measured at your landscape size: 686 pt tall starting at y = 74
   (straight across "Working on Variant 1 · 68 % · 186.1 g") → 284 pt starting at
   y = 358, centred on the left.
5. **The bounding box is gone from this page.** The design box was being drawn
   through the part you were brushing. The lattice page still draws its own.
6. **One column of actions** — Receipt, Discard, Lattice this, Apply & certify —
   and Apply & certify is always at the bottom.
7. **Discard is no longer greyed out.** It said "returns the original variant,
   unchanged" while refusing to do it; now it does what it says whenever the page
   is not busy.
8. **Notes queue.** One at a time, top-centre, a minute each, each with an ✕, and
   a queued note whose situation has passed is dropped rather than shown late.
   The paragraph that used to stand under the Original/Smoothed tabs goes through
   the same queue, so it can no longer lie across the note in the middle.

**One thing I found and did NOT fix, because it belongs to the other task:** the
"Smoothed" tab is disabled unless a *certification* exists, even when a live
brush preview has already been computed. That is why you could not see the
Smoothed side without pressing Re-certify and waiting. Detail in §7.

---

# 1. METHOD

The D1 chain was reproduced link by link in the code before anything was changed,
and then confirmed from the device side by the maintainer's own test (turning
"Pencil only" off and painting with the pencil). Every layout claim in this
handoff is a MEASUREMENT off the shipping view, not a computation from the chrome
tokens — round 3's overlap tests were all token arithmetic, and they passed
while the panel sat on top of the identity bars.

To make that possible the page got one new seam, `SmoothingPage.onChromeFrame`:
each piece of chrome reports the rect the layout system actually gave it, in page
coordinates. It is `nil` in the app (no closure, no work) and it is what
`measured_layout.txt` and R8's overlap test are built on.

**CI:** `core-linux` (untouched) + `app-macos`. Full app suite: **1264 tests, 0
failures, 15 skipped** (the skips are the opt-in evidence generators).

---

# 2. D1 — THE GATE. A finger-only property decided whether the gesture existed

## Root cause, file and line (bar R2)

Every link reproduced, in the shipped tree:

| # | Site | What it did |
|---|---|---|
| 1 | `SmoothBrush.swift:170` | `public var paints: Bool { paints(from: .finger) }` — a FINGER-ONLY property retained under round 2's name |
| 2 | `WorkspacePlaceholder.swift:341-343` | `brushGestureActive = showSmoothingPage ? smoothTools.paints : paintActive` — with `pencilOnly` on this is **false** |
| 3 | `WorkspacePlaceholder.swift:421` | passes it as `paintActive:` |
| 4 | `MetalMeshView.swift:2734` | `guard let view = g.view as? MTKView, paintActive else { return }` — `handlePencilPan` bails. **The pencil never paints.** |

The code stated the intended behaviour four lines above the guard that broke it
(`MetalMeshView.swift:2730-2732`: "A pencil ALWAYS paints while the brush is
armed… that toggle withholds the FINGER, never the pencil"). Bar U2 of round 3
added `brushRequiresPencil` as the correct admission mechanism and left the
round-2 master gate reading a finger-only property; two mechanisms decided one
thing and the stricter one won.

## How `pencilOnly` came to be ON in his session (bar R2)

**User-set, in that session, via the checkbox.** With evidence:

* the initialiser defaults it FALSE (`SmoothBrush.swift:152`);
* the page holds it in `@State` (`WorkspacePlaceholder.swift:162`) and
  `openSmoothingPage` **resets it to a fresh value on every entry**
  (`WorkspacePlaceholder.swift:1844`), so it cannot survive leaving the page;
* `grep -rn "pencilOnly" app --include=*.swift` finds **no** `UserDefaults`,
  `@AppStorage`, sidecar key or job field — nothing persists it;
* the only writer outside those two is the checkbox itself
  (`SmoothingPage.swift:532`, `tools.pencilOnly.toggle()`). The one other
  occurrence, `SmoothingPageEvidenceGen.swift:156`, sets it for an offscreen
  capture and never runs in the app.

So: he checked a box labelled "Pencil only" *because he wanted to paint with the
pencil*, and that is precisely what stopped the pencil painting.

## The fix shape

One value, `BrushGesture` (`SmoothBrush.swift`), built once by the workspace and
consulted by every site that routes a drag:

```swift
armed            // does the brush claim a drag at all?  MODE decides.
requiresPencil   // is the FINGER being withheld?        pencilOnly decides.
admits(_ input)  // may THIS contact paint?
route(_ input, touches:) -> .paint | .orbit | .pan
```

`SmoothBrushTools.paints` is **renamed to `fingerPaints`** and a separate `armed`
added, so "a finger does not paint" can no longer be written where "the brush is
off" is meant. `WorkspacePlaceholder.brushGestureActive` is gone; the recognizers
call `gesture.route(...)`; `handleBrush` calls `gesture.admits(input)`.

## Failing test first (bar R1)

`SmoothingRound4Tests.testAPencilDragPaintsWhilePencilOnlyIsOn` drives the four
shipping functions in the order the app calls them and asserts a stroke comes
out. **Confirmed failing** by restoring the shipped wiring — one line, feeding
`armed` from the finger-only property exactly as round 3 did:

```
SmoothingRound4Tests.swift:93: error: XCTAssertTrue failed - D1: the brush is ARMED
  on the smoothing page. … `armed` was fed from a property answering 'does a FINGER
  paint?', so checking 'Pencil only' turned the whole gesture off
SmoothingRound4Tests.swift:101: error: XCTAssertEqual failed: ("orbit") is not equal
  to ("paint") - D1: the pencil's own recognizer paints
SmoothingRound4Tests.swift:105: error: XCTAssertTrue failed
```

(`evidence/…/d1_failing_before_fix.txt`.) The second admission path — a FINGER
drag with "Pencil only" off — is pinned by
`testAFingerDragPaintsWhilePencilOnlyIsOff`, and every other routing outcome by
`testTheGateRoutesEveryOtherDragToTheCamera`.

## (a) The audit of every `smoothTools.paints` / `paintActive` site

| Site | Meaning it wanted | Verdict |
|---|---|---|
| `WorkspacePlaceholder:341` master gate | **armed** | WAS finger-only → **the defect**, fixed |
| `WorkspacePlaceholder:421` `paintActive:` input | **armed** | fed from the gate now |
| `WorkspacePlaceholder:982` `handleBrush` | **admission** | correct meaning; routed through the one gate |
| `MetalMeshView:2734` `handlePencilPan` | **armed** | WAS the bug, fixed — and see below |
| `MetalMeshView:2755` `handlePan` | armed + admission | correct; now one `route` call |
| `MetalMeshView:2812` `handleTap` | **admission** | **SECOND DEFECT**: read `paintActive`, so a finger TAP painted a dab even while the brush belonged to the pencil. Fixed |
| `MetalMeshView:2709` `pick` | armed | correct |
| `WorkspacePlaceholder:2234/2270/2376-2440` | the TO page's own drawer state | correct, untouched |

**A third defect found in the same audit and fixed:** `handlePencilPan` is
mounted with `allowedTouchTypes = [.pencil]`, which makes it the ONLY recognizer
a pencil drag can reach — so its early return meant **a pencil could not orbit
anywhere in the app while the brush was off**. It falls through to the camera
now (`testAPencilDragDrivesTheCameraWhenTheBrushIsOff`).

## (b) The page now says why a drag was refused

An armed brush that refuses a contact reports it (`onBrushRefused`), and the page
posts ONE note the first time it happens: *"Pencil only" is on — a finger drag
turns the part around. Draw with the pencil, or switch Pencil only off to paint
with a finger.* Once per page, because orbiting with a finger is the intended
behaviour here and a note on every drag would be noise. The checkbox also carries
a caption stating which contact it is withholding, before anything is tried.

## (c) The disabled-control audit

| Control | Predicate | Correct? |
|---|---|---|
| Apply & certify | `working` / `brush.unusableReason` / `!brush.hasEffect` | **Yes.** Caption fixed: "brush an area **and give it a strength** first" named a slider round 3 deleted → now "brush an area first" |
| **Discard** | was `(hasKept ‖ hasReceipt) && !working` | **NO — the maintainer is right.** Strokes, tint and preview are all things to discard and none is a certification; with nothing painted the press is a harmless no-op that lands where its caption says. Now `!working` |
| Lattice this | `hasReceipt && !working` | Yes — a lattice needs certified geometry (AE8) |
| Receipt | a receipt or a stale receipt exists | Yes |
| Clear strokes | `brush.isEmpty` | Yes |
| Paint / Erase tabs | `!brush.canPaint` (freeze mask not resolved) | Yes |
| **Orbit tab** | same predicate | **NO** — orbit paints nothing, so gating it on the freeze mask removed the only thing you can do while waiting. Now exempt |
| Brush −/+ | `canShrink` / `canGrow` | Yes |
| **"Smoothed" tab** | `receipt != nil ‖ kept != nil` | **NO — and NOT FIXED HERE.** See §7 |

---

# 3. D2 — Orbit is back, conditionally

`SmoothBrush.swift:91` recorded that round 3 replaced Orbit with `pencilOnly`,
reasoning from an earlier note. That was a misreading: the rule is a conditional,
not an either/or, and it is now implemented as stated —

```swift
availableModes = pencilOnly ? [.paint, .erase] : [.paint, .erase, .orbit]
setPencilOnly(true)  // falls back OUT of .orbit, so no dead mode is left selected
```

`SmoothBrushTools(mode: .orbit, pencilOnly: true)` normalises to `.paint`, so the
state cannot be constructed either. The page renders `tools.availableModes`.

**The invariant is AMENDED, not deleted (bar R3).**
`SmoothingPageRound2Tests.testBrushToolsAreAValueWithTheRulesTheGestureObeys`
keeps round 2's assertion and round 3's, and states both paths inline;
`SmoothingRound4Tests.testAOneFingerDragCanAlwaysOrbit` walks **every reachable
configuration of the two controls** and asserts that in each one there is a
reachable state where a one-finger drag orbits:

* `pencilOnly` ON → the finger falls through to the camera, with no mode switch;
* `pencilOnly` OFF → the Orbit mode is present and releases the drag.

Orbit parks the brush for **both** contacts (the pencil too) — it is the brush
being put down, not a contact filter. `SmoothBrushModel.brush` refuses `.orbit`
as a second layer, so the model cannot mark the surface even if a gesture did.

---

# 4. D3 — the panel: measured 686 → 284, and off the identity bars

## Root cause (bar R2)

Two defects in three lines at `SmoothingPage.swift:146-149`:

* `panelView(maxHeight: geo.size.height - 200)` handed a ScrollView a 634 pt
  ceiling, and **a ScrollView is greedy**: it took all 634;
* the resulting slab was then centred in the FULL height, so its top edge landed
  at y = 74 — above "Working on…" (y = 86) and the load-case row (y = 138).

## Failing test first (bar R1)

`testNoTwoPiecesOfChromeOverlap`, run with those two hunks restored:

```
R8 (1194.0, 834.0) rest: panel (24.0, 74.0, 348.0, 686.0) overlaps
                         workingOn (24.0, 86.0, 628.0, 40.0)
R8 (1194.0, 834.0) rest: loadCase (24.0, 138.0, 750.0, 40.0) overlaps
                         panel (24.0, 74.0, 348.0, 686.0)
R8 (1194.0, 834.0) noted: note (287.0, 190.0, 620.0, 50.0) overlaps
                          panel (24.0, 74.0, 348.0, 686.0)
```

— his screenshot, as numbers (`evidence/…/d3_failing_before_fix.txt`).

## The fix

* the ScrollView **hugs its content** (`.fixedSize(horizontal: false, vertical:
  true)` after the ceiling frame), so `maxHeight` is a scroll ceiling and not a
  height;
* the ceiling and the placement are the same **band**:
  `PageChrome.sidePanelBand(canvasHeight:) = height − noteTop − edge`, i.e.
  everything below the identity rows and above the bottom edge, and the panel is
  centred inside it;
* the brush-footprint row reserves the CURRENT disc rather than the largest
  possible one — 76 pt of empty panel at the default radius, which is a quarter
  of what the panel should be. The disc is still drawn at its true size, so
  round 3's U2 is unaffected.

## R5 — the measured heights, iPad landscape 1194 × 834

| | Orbit present (Pencil only OFF) | Orbit absent (ON) |
|---|---|---|
| **before** | h 686, top y 74 | h 686, top y 74 |
| **after** | **h 284, top y 358** | **h 284, top y 358** |

Identical in both states: the mode tabs are one row whether there are two tabs or
three, so the third tab costs no height. The only thing that moves it is the
brush size, because the disc is a true-scale preview: h = 232 + 2 × radius → 284
at radius 26, **332 at his radius 50**, 360 at the maximum 64. The band is 620 pt,
so every one of those fits with room to spare. Full table in
`evidence/…/measured_layout.txt`.

---

# 5. D4 — the tint: why the existing one never reached the screen, then his spec

## FIRST, THE ROOT CAUSE OF THE TINT THAT ALREADY EXISTED (bar D4)

**Two independent app-side defects, either of which alone was fatal.**

**(1) The array was the wrong length, and the renderer dropped it in silence.**

```swift
// MetalMeshView.swift:1380
guard vertexDrawCount > 0, colors.count == vertexDrawCount else { return }
```

`vertexDrawCount` is `mesh.flat.vertexCount` (`MetalMeshView.swift:968`), and
`FlatMesh` is the **unshared** render buffer — `3 × triangleCount`
(`ViewerMesh.swift:236-246`). The page was passing
`smoothBrush.vertexTints()` (`WorkspacePlaceholder.swift:373`), one entry per
**welded** vertex. On his bracket those two numbers differ by roughly 6:1, so
**every upload the brush ever produced was dropped on the floor**. No stroke he
has ever painted could have tinted anything.

**(2) Even at the right length, it was uploaded once.** The re-upload condition
(`MetalMeshView.swift:2518`) triggers on the MESH changing, the overlay turning
on, the stress multiplier moving, or the load-flow clock — and a brush stroke
touches none of them. So the first frame would have uploaded the empty tint and
every stroke after it would have uploaded nothing.

Both are in the app. **Nothing here reaches into core**, so this is not handed to
`smoothing-must-actually-smooth`.

Fixes: `SmoothBrushModel.viewerTints()` produces one tint per flat vertex (which
is also the *right* unit — a stroke paints triangles, so nothing bleeds across a
shared corner into an unpainted neighbour), and the coordinator compares the tint
array itself (`tintsMoved`) and remembers what it uploaded.

## Failing test first (bar R1, amended)

`testTheTintIsTheLengthTheRendererWillAccept` and `testChangedTintsAreReuploaded`
with those two hunks restored:

```
SmoothingRound4Tests.swift:347: error: XCTAssertTrue failed - and the page sends
  the viewer-shaped array
SmoothingRound4Tests.swift:349: error: XCTAssertFalse failed
SmoothingRound4Tests.swift:361: error: XCTAssertTrue failed - and that trigger is
  in the condition that uploads
```

(`evidence/…/d4_d5a_failing_before_fix.txt`.)

## His specification, implemented

* **ORANGE** — `SmoothBrushModel.paintTint = (1.00, 0.48, 0.10)`, one hue, and
  the same hue and value at every pass. Round 3 put half the readout in VALUE
  (darkening toward black); his instruction is opacity, so opacity is the
  channel.
* **+10 % PER PASS, LAYERING** — `tintPerPass = 0.10`; a second pass over the
  same area is 20 %, a third 30 %.
* **THE CAP, AND WHY: 40 %.** The strength ladder caps at
  `SmoothBrushModel.levels.count = 4` passes (the top rung is 1.00 — there is no
  more smoothing to ask for). A fifth pass changes nothing about the result, so
  it must not read as more. Tint cap and strength cap are the same event.
* **ERASE clears the accumulation outright**, exactly as it clears the smoothing
  it stands for — round 3's rule ("take the smoothing off here", not a
  rung-by-rung undo), unchanged.
* **FROZEN still wins** over a stroke, in the array the viewer draws, at every
  pass and after an erase —
  `testFrozenCornersStayLockedInTheViewerArrayHoweverManyPasses`, with the
  positive control that its free neighbours DO accumulate (see R3 in §8).

## R9 — the tint is independent of the solve

`testTheTintNeedsNoSolveNoPreviewAndNoCertification`: after one stroke the tint
is present while `receipt`, `kept` and `preview` are all nil and
`certifyCallCount == previewCallCount == 0`; and running the previewer does not
change what was painted. The tint is a pure function of the brush value — there
is no path from a page model, a receipt or a preview into it.

---

# 6. D5 — the layout rules

## D5a — the bounding box is not drawn on this page

**Root cause:** `WorkspacePlaceholder.swift:378-379`. The comment directly above
it said "L1: a full-screen page draws NO design-box wireframe"; the CONDITION was
only `showDesignGizmo` = *edit phase + gravity set + the Design Box tool is on*.
Anyone who had ever switched the Design Box on kept its translucent box and
bright edges drawn straight through the part he was brushing.

**Shared view, deliberately narrow gate:** the lattice page mounts the same
`MetalMeshView`. Gating on `fullScreenPageUp` would have changed it too, so the
gate is `!showSmoothingPage` and the lattice page's geometry is byte-identical.
`testTheDesignBoxIsNotDrawnOnTheSmoothingPage` asserts both halves — that this
page excludes it, and that the lattice page's own conditions were not touched.

## D5b — one action column

`SmoothPageActions.columnOrder = [receipt, discard, lattice, recertify]`, rendered
by a `ForEach`, with `Apply & certify` pinned last.

**The order is a CONSTANT, not a sort**, because every caption on this column
changes with the page's state — a sort would re-order the column under his thumb
the moment a certification landed, which is exactly what he forbade.

**R7 — the measured widths, landscape 1194 × 834** (trailing edge shared at
x = 1170; each row 64 pt tall, 12 pt apart):

| Row | at rest | after a stroke | after certifying |
|---|---|---|---|
| Receipt | 163 | 163 | 232 |
| Discard | 269 | 269 | 269 |
| Lattice this | 338 | 338 | 347 |
| **Apply & certify** | **167** | **594** | **594** |

**Where the two rules collide, and which one wins.** "Narrowest at the top" and
"Apply & certify always at the bottom" are compatible in every state where the
button is enabled (163 → 269 → 338 → 594, strictly ascending). At rest its
caption is short ("brush an area first"), so it measures 167 and the column is
not monotonic. His second rule is absolute and his third forbids reflowing, so
the position is held. The test asserts exactly this: the first three run narrow →
wide in every state, and `Apply & certify` is last in every state.

## D5c — one note at a time, queued

**Root cause:** `SmoothingPageModel.topNote` was already a single value (round
3's U5 holds — the failure/transient/working precedence cannot draw two). What
his screenshots show is a note that was NOT in that system: `smoothedSideNote`,
up to four lines, rendered as standing prose under the Original/Smoothed tabs
(`SmoothingPage.swift:282-288`), which sat across the top-centre note. And
`PageNoteBox.post` REPLACED the visible note, so a second piece of news
overwrote the first rather than waiting.

**`PageNoteQueue` (in `PageChrome.swift`, so a fourth page inherits it):**

* never more than one visible; the rest queue;
* `PageTransientNote.lifetime` = 60 s, then the next one takes the band;
* an ✕ on the transient note AND on the failure banner — round 3 gave only the
  transient an invisible tap-to-dismiss. The failure banner is not in the queue
  (it is derived from the phase), so dismissing it is its own fact
  (`failureDismissed`), re-armed by the next failure — otherwise the ✕ would have
  been a control that does nothing, which is the family of defect this whole task
  is about. The WORKING pill deliberately has none: it is a live status, the work
  is still running, and a dismiss that cannot stop it would only hide that;
* **always top-centre**, at `PageChrome.noteTop`, in both orientations:
  landscape x 287…907 (w 620) at y 190, portrait x 226…608 (w 382) at y 190,
  midX exactly half the canvas in both (`testTheNoteIsTopCentreInBothOrientations`);
* **a queued note whose topic has gone stale is DROPPED, not shown late.** Each
  queued note carries a topic; when it comes up for display the model re-resolves
  it (`noteText(forTopic:)`) and skips it if the topic no longer says anything.
  A note describing a state the user has already left is worse than no note.
* `discard()` clears the whole queue — every note behind the visible one
  described a state the reset has just left.

The Smoothed-side sentence goes through the queue, posted only when it becomes
NEWS (the value at entry is seeded, so the page still starts with nothing
standing on it — round 3's U6).

---

# 7. THE BOUNDARY, AND ONE THING HANDED ACROSS IT

I did not touch `core/src/mesh/smooth.cpp`, the operator's ability to remove
stair-stepping, real-time smoothing, or the decoupling of the Original/Smoothed
preview from certification. Those are `smoothing-must-actually-smooth`'s.

**The finding that belongs to them, with the line:**

```swift
// SmoothingPage.swift:296
private var hasSmoothed: Bool { page.receipt != nil || page.kept != nil }
```

It ignores `page.preview`. The live preview machinery already exists and already
runs — `SmoothingPageModel.refreshPreview` is called on every stroke end
(`WorkspacePlaceholder.swift:1013-1029`) and `currentGeometry` already prefers
the preview over the original — but the tab that would SHOW it is disabled unless
a certification exists. **That is why he could not reach the Smoothed view
without pressing Re-certify and waiting five to ten minutes.** The one-line gate
is page code, but the question it answers ("may Smoothed be shown without a
solve?") is that task's to decide, so it is theirs to change. If they want it,
the change is `|| page.preview != nil`.

The stroke TINT is mine and is delivered, independent of all of that: it marks
where he brushed whether or not the geometry has visibly moved (R9).

---

# 8. THE BARS

**R1 — failing test first.** D1, the panel overlap and the tint each have a
permanent test that was confirmed failing by restoring the shipped code at the
seam in question (one or two hunks each, listed in §2/§4/§5), with the failure
output pasted here and in `evidence/…/*_failing_before_fix.txt`.

**R2 — root cause with file and line** for every defect: §2 (D1, four links, plus
two more found in the audit), §4 (D3, `SmoothingPage.swift:146-149`), §5 (D4,
`MetalMeshView.swift:1380` and `:2518`), §6 (D5a,
`WorkspacePlaceholder.swift:378-379`; D5c, `SmoothingPage.swift:282-288` and
`PageNoteBox.post`). How `pencilOnly` came to be ON: §2, answered with the grep.

**R3 — no assertion weakened or deleted, and here is the sweep that proves it.**

The first version of this paragraph said "no assertion weakened or deleted" and
then accounted only for assertions that CHANGED. That is not the same claim, and
the review was right to reject it: three test FUNCTIONS disappear from the diff
and none of them was named. The sweep, which is now run on every PR that touches
tests (see the note under R6):

```
$ git diff b3abcf8 HEAD -- app/TopOptKit/Tests | grep -E '^-\s*func test'
-    func testPaintedRegionsTintByTheirOwnStrengthAndFrozenStillWins() {
-    func testTheTintDarkensWithEachStroke() {
-    func testThePortraitPanelClearsTheTwoRowActionCluster() {
```

Every one, with its disposition:

| Removed | Disposition |
|---|---|
| `testTheTintDarkensWithEachStroke` | **Superseded** by `testTheTintStrengthensWithEachStroke` (same file). It asserted the VALUE-channel readout the maintainer's D4 instruction replaced with opacity; the invariant it existed for — a further pass always reads as MORE than the one before — is asserted there, plus the exact 10 %/pass step and a constant hue. |
| `testThePortraitPanelClearsTheTwoRowActionCluster` | **Superseded** by `testThePortraitPanelClearsTheActionCluster` (row count 2 → 4, D5b) and, more strongly, by `testThePortraitPanelClearsTheActionColumn` + `testNoTwoPiecesOfChromeOverlap`, which measure the real rects across 5 states × 2 orientations instead of computing one. |
| `testPaintedRegionsTintByTheirOwnStrengthAndFrozenStillWins` | **RENAMED, not deleted** — it is `testPaintedAreasTintByTheirPassCountAndFrozenStillWins`, `SmoothingPageTests.swift:222`, and its closing assertion is still `frozen wins over a stroke that touched it`. The grep reports a rename as a deletion, which is exactly why every line it returns has to be accounted for by hand rather than trusted. |

**On the review's specific worry — that the frozen-wins behaviour lost its only
test — the branch does not support it.** Three tests assert it, and one of them
was added by this PR against the flat array the review asked for:

* `SmoothingPageTests.testPaintedAreasTintByTheirPassCountAndFrozenStillWins:235`
  (the renamed one), `vertexTints()`;
* `SmoothingRound3Tests.testFrozenVerticesStayTintedAtEveryRung:791`, at every
  rung, `vertexTints()`;
* `SmoothingRound4Tests.testFrozenCornersStayLockedInTheViewerArray…`,
  **`viewerTints()`** — the array the renderer actually receives.

The review's underlying point still improved the branch, so the third test was
**strengthened rather than merely defended.** It now walks `levels.count + 2`
passes over a triangle that touches the frozen corner and asserts, at every pass:
the frozen corner keeps the locked green *exactly* (not the orange, not a blend);
nothing accumulated on it; and — the positive control — its free neighbours in
the same triangles DID accumulate, so it cannot pass by the whole array being
inert. Then an erase, which leaves the lock where it was.

**Confirmed to be a real test** the same way D1, D3 and D4 were: by removing the
frozen override from `viewerTints()` (`SmoothBrush.swift`, the
`frozen ? frozenTint : c` line) and running it —

```
SmoothingRound4Tests.swift:530: error: XCTAssertEqual failed:
  ("SIMD4<Float>(1.0, 0.48, 0.1, 0.1)") is not equal to
  ("SIMD4<Float>(0.42, 0.85, 0.55, 0.34)") - pass 1: the frozen corner keeps the
  LOCKED appearance — not the orange, not a blend of the two
SmoothingRound4Tests.swift:533: error: XCTAssertNotEqual failed: ("0.1") is equal
  to ("0.1") - pass 1: and nothing accumulated on it
… same at passes 2 and 3, with the orange deepening 0.1 → 0.2 → 0.3 on a surface
  that is supposed to be locked.
```

(`evidence/…/frozen_wins_failing_without_the_guard.txt`.)

**The assertions that CHANGED**, each with its reasoning inline in the test: the
one-finger-orbit invariant is amended to cover both paths and asserted over every
reachable configuration of the two controls; the tint's VALUE channel became
opacity (D4); a second note queues instead of replacing (D5c); and the control
count ceiling moved 11 → 12 **because he asked for the Orbit tab back** — 11 with
"Pencil only" on, 12 with it off, against round 2's 11 at rest and 13 after a
stroke.

**R4 — the page is demonstrably usable, both input modes.**
`testTheWholePathWorksForBothInputModes` walks the whole path with the pencil
("Pencil only" ON) and with a finger (OFF), through the functions the app calls:
nothing painted → Apply & certify disabled and says "brush an area first",
Discard enabled → drag routes to `.paint` → **tint 10 % on the first stroke, with
`certifyCallCount == 0`** → second pass 20 % → Apply & certify enables →
re-certify → receipt and `kept` present, Lattice this and Receipt enable, the
verdict announced once top-centre → Discard → receipt, kept, preview, note,
strokes and tint all gone, both buttons disabled again, stage back on the
original.

**R5 — panel heights before and after, both states.** §4: 686 → 284 at 1194 × 834,
identical with Orbit present and absent.

**R6 — no unfilled placeholders.** `grep -nE '<<|TBD|filled in|TODO'` over this
file: no matches.

**The standing habit this PR added (review M2).** A deleted test is invisible in
a test-count summary — "1264 passing" says nothing about what stopped being
asked. Before pushing any PR that touches tests:

```bash
git diff <merge-base> HEAD -- app/TopOptKit/Tests | grep -E '^-\s*func test'
```

and account for **every line it returns**, by name, in the handoff: superseded by
X, renamed to Y, or restored. Note that a rename shows up as a deletion, so the
sweep over-reports rather than under-reports — which is the right direction, and
the reason each line needs a human answer rather than a glance.

**R7 — measured layout numbers.** §4 (panel), §6 (column order and widths, note
position in both orientations), and the full table in
`evidence/…/measured_layout.txt`.

**R8 — no two pieces of chrome overlap, asserted.**
`testNoTwoPiecesOfChromeOverlap` renders the page in 5 states × 2 orientations,
collects every chrome rect through the seam, and asserts pairwise
non-intersection plus containment in the page. It reads what SwiftUI laid out, so
it catches what round 3's token arithmetic could not — and it does: restoring the
D3 hunks fails it with `panel overlaps workingOn`. The identity stack is probed
row by row rather than as one box, because its rows are different widths and a
union rect reports an overlap the user cannot see while hiding ones they can.

**R9 — the tint is independent of the solve.** §5.

---

# 8b. TWO THINGS THAT ARE HIS CALL, NOT MINE (raised in review of PR 300)

Both are choices I made inside instructions that did not cover the case. Neither
is a defect; both are recorded so he can overrule them in a sentence.

1. **The 40 % tint cap is my choice, not his.** He specified orange, 10 % per
   pass, layering — and no ceiling. I capped it at four passes because the
   STRENGTH ladder caps there (`SmoothBrushModel.levels.count`): a fifth pass
   asks for no more smoothing, so a fifth shade would be the page claiming
   something the result does not do. If he wants the orange to keep deepening
   past the point where the smoothing stops, that is a one-line change to
   `tint(forRung:)` — but the tint would then stop tracking the strength.
2. **At rest the action column is not monotonic.** "Narrowest at the top" and
   "Apply & certify always at the bottom" agree in every state where that button
   is enabled (163 → 269 → 338 → 594). At rest its caption is short — "brush an
   area first" — so it measures 167 against Discard's 269 and Lattice this's 338
   and the column reads slightly ragged. I held the position because his
   "always at the bottom" rule is absolute and his no-reflow rule forbids
   sorting; the alternative he might prefer is a fixed column width, which makes
   "ordered by width" invisible. His call.

---

# 9. FILES

| File | What changed |
|---|---|
| `SmoothBrush.swift` | `BrushGesture` (the one gate + router); `Mode.orbit` restored with `marks`; `armed` / `fingerPaints` split; `availableModes` / `setPencilOnly`; orange layering tint + `viewerTints()` |
| `MetalMeshView.swift` | both pan handlers and the tap route through `BrushGesture`; pencil drags drive the camera when the brush is off; `onBrushRefused`; tint re-upload trigger |
| `WorkspacePlaceholder.swift` | `brushGesture` replaces `brushGestureActive`; `viewerTints()`; design box + keep-outs off this page; no face picking on this page; refusal note |
| `SmoothingPage.swift` | panel hugs + sits in the band; conditional Orbit tabs; one action column; ✕ on notes; side-note paragraph removed; the `onChromeFrame` seam |
| `SmoothingPageModel.swift` | note queue + topics + staleness + failure dismissal; `notePencilOnlyRefusedFinger`; `SmoothPageActions.Kind` / `columnOrder`; Discard and Apply & certify predicates/captions |
| `PageChrome.swift` | `PageNoteQueue`; `sidePanelBand` |
| tests | `SmoothingRound4Tests` (29 tests), `SmoothingRound4EvidenceGen`; amendments in `SmoothingPageTests`, `SmoothingPageRound2Tests`, `SmoothingRound3Tests` |

---

# 10. IN PLAIN LANGUAGE

**What was wrong.** You checked a box called "Pencil only" so that you could draw
with the Apple Pencil. That box turned painting off completely — for the pencil
as well as for your finger. Everything else you saw greyed out was downstream of
that: with nothing painted, there is nothing to certify, so there is no receipt,
no lattice and nothing to discard. **With "Pencil only" OFF the pencil paints
today; so the control labelled "Pencil only" is currently the one thing that
prevents the pencil from painting.** You lost a night to that, and I am sorry.

The reason it happened is small and dull: there were two switches deciding the
same thing. One asked "should the brush exist at all?" and it was accidentally
wired to a value that meant "can a *finger* paint?". Check the box, the finger
stops painting, and the brush stops existing. There is one switch now, and it
knows the difference between "the brush is on" and "this particular contact may
use it".

**Orbit.** It is back, but only when you need it. With "Pencil only" off, the
brush takes over the one-finger drag, so you need a way to spin the part — that
is the Orbit tab. With "Pencil only" on, your finger already spins the part, so
the tab would be clutter and it is not shown. If you are in Orbit and then tick
"Pencil only", you land back in Paint rather than in a mode that no longer
exists.

**The colour.** Your strokes now show up in orange, and each pass over the same
place adds another 10 %, so an area you have worked hard is visibly darker. It
appears the instant you lift the pencil — no waiting, no solve. It had never
appeared before, and the reason is worth knowing: the page was sending the
renderer a list of colours that was about six times shorter than the list the
renderer wanted, and the renderer threw it away without complaining. It stops at
four passes because the smoothing itself stops at four passes — beyond that a
pass changes nothing, and the colour must not pretend otherwise. Erase clears the
colour along with the smoothing.

**The panel.** It was 686 points tall and started 12 points above the bar that
tells you which variant you are painting, so it covered it. It is 284 now,
centred on the left, and it can no longer reach that high — there is a test that
measures the real thing, not a drawing of it, and it fails if anything on that
page ever lands on top of anything else.

**One test came back stronger.** Review of this PR asked whether the guarantee
that *protected areas cannot be painted over* had quietly lost its test. It had
not — three tests still assert it — but the reviewer's instinct was right about
which array matters: the strongest of the three now checks the exact list of
colours the screen receives, paints over a protected corner half a dozen times,
and insists it stays locked green with no orange building up on it while its
unprotected neighbours darken normally. That is the guarantee that bolt holes,
mating faces and anchors never get smoothed, stated where you can see it.

**The rest.** The design box is no longer drawn through the part on this page (it
still is on the lattice page). The four buttons are one column with Apply &
certify always at the bottom. Discard works whenever the page is not busy —
including when there is nothing to discard, which is exactly what its caption
promises. Messages at the top come one at a time, wait their turn, carry an ✕ and
disappear after a minute; one that has gone out of date while it waited is thrown
away rather than shown late.

**What is still not fixed, and who has it.** You could not see the "Smoothed"
view without pressing Re-certify and waiting. Half of that is genuinely someone
else's job right now — a second task owns whether smoothing can run quickly and
whether it visibly changes the shape. But I found the specific reason the tab was
greyed out: the page enables it only when a full certification exists, even
though it already computes a quick preview after every stroke. That is one line,
it is on the boundary of the other task's work, and I have handed it to them
rather than changing it underneath them.

**Next steps.** Rebuild the app and try the page: paint with the pencil with
"Pencil only" on, watch the orange build up, then press Apply & certify. If the
Smoothed tab is still grey when you have painted, that is the handed-over item
above, not this work.

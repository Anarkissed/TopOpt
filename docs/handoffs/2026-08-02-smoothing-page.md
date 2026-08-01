# A smoothing page — brush locally, re-certify, decide

**Slug:** `smoothing-page` · **Branch:** `claude/smoothing-page-14d478` · started from
`main` at `c7194b4`, which contains PR 274 (`lattice-a-variant`, merge `938bcdd`).
**Evidence:** `evidence/2026-08-02-smoothing-page/`

---

## What this is

A third full-screen page, sibling to the TO page and the lattice page. You enter it
from a **finished variant**, brush smoothing onto the regions that need it, press
**Re-certify**, and read a **before/after receipt**. Then you keep it or discard it.

The value is not the smoothing. PR 200's own conclusion was that *"cranking
smooth_factor alone would buy most of the cosmetic win with none of the honesty"* —
so the whole interaction is built around the two things a plain smoother cannot do:

* **the receipt** — both columns measured by `analyze_fixed_design`, under the load
  case the variant was *optimized* under;
* **the hard constraints** — bolt bores, mating faces, anchors, load faces and
  Protect groups are frozen bit-identically, and the brush cannot reach them.

---

## What was already there, and was reused rather than rebuilt

| Piece | Where | What this task did with it |
|---|---|---|
| Constrained Taubin smoothing, frozen regions proven bit-identical by `memcmp` | `core/src/mesh/smooth.cpp` (PR 200) | Added a per-vertex weight; the frozen path is untouched |
| Freeze by explicit CYLINDER/PLANE predicates that survive re-meshing | `resolve_clearance_manual`, `point_in_clearance_region` | The brush feeds these same predicates; the mask comes from core's own `compute_freeze_mask` |
| `analyze_fixed_design` re-certification of a fixed design | PR 196 | Both columns of the receipt |
| Retained `job.json` + `design.bin` beside each variant | PR 274 | The load case is READ from the retained job |
| One selections library, one group model | PR 274's M1 | The smoothing page mounts the SAME panel |
| `LatticeChromeLayout` — one spacing token per seam | PR 251 / lattice round 2 | Promoted into `PageChrome`, now shared by all three pages |

**No second smoothing path was built.** The brush is a per-vertex weight on PR 200's
`constrained_taubin_smooth`, and an empty weight vector reproduces the shipped
uniform smoother byte for byte (bar BR4 in `test_smooth_brush`).

---

## The three hazards, addressed

### H1 — re-certification can throw rather than return a number

PR 200 measured `variant_030` at strength 0.50 failing the production multigrid-CG
(*"did not reach tolerance within max_iterations"*), deterministically. On a brush
workflow the user re-certifies repeatedly, so this happens **more**, not less.

`SmoothingPageModel` treats it as a state, never a crash:

* a non-convergent solve → `.couldNotCertify(.didNotConverge, stale:)`;
* `receipt` returns **nil** in that state, so a view has no numeric surface to
  accidentally render as current;
* the last good receipt is returned by `staleReceipt` **already marked**
  (`stale == true`), and the card renders a `STALE` badge and the sentence *"the
  smoothing on screen now has NOT been certified"*;
* the failure copy names the cause, says explicitly that it is *"a solver limit on
  this particular sparse field, not a verdict"*, and offers "Lower the strength and
  re-certify";
* a non-convergent smoothing is **not keepable** (`keep()` returns false).

Asserted by `testNonConvergenceIsLegibleAndTheOldReceiptIsMarkedStale`,
`testAHardFailureIsAlsoAStateAndNeverACrash`,
`testANonConvergentSmoothingIsNeverKeepable`.

### H2 — smoothing may IMPROVE printability

PR 200 measured min-feature violations **falling** on real tendrilly variants
(961 → 639) because smoothing removes terracing that counted as sub-printable.

Nothing in the UI presumes smoothing is a cost. The min-feature row carries both a
`worse` and a `better` flag computed from the sign of the change, the row tints
green when violations fall, and `minFeatureLine` reads *"Min-feature violations FELL
961 → 639: smoothing removed terracing that counted as sub-printable."* Asserted
both directions by `testMinFeatureIsReportedBothWays`.

**The probe measured BOTH directions on the same specimen, which is the strongest
argument for reporting it both ways.** On the bracket, min-feature violations *fell*
17 → 13 at strength 0.10 and then *rose* to 50 at strength 1.00. A UI that assumed
either direction would have been wrong about the same part at a different strength.

### H3 — the certified object is a re-voxelization, not the mesh

The smoothed **mesh** is the deliverable; what was certified is its voxelization at
the print grid. PR 274 established these are not identical.

The bridge now returns `mesh_volume_fraction` and `voxel_volume_fraction` against
the same grid volume, and the receipt prints both plus the percentage gap. Measured
on the bracket at 1.62 mm spacing:

| | mesh volume fraction | voxel volume fraction | gap |
|---|---|---|---|
| unsmoothed | 0.22168 | 0.22517 | **+1.57 %** |
| smoothed (strength 1.0) | 0.22213 | 0.22286 | **+0.33 %** |

Smoothing *narrows* the gap, which is the expected direction — a smoother surface
quantizes onto the grid with less error. The receipt states the number rather than
letting a reader assume it is negligible. Asserted by
`testTheReceiptStatesTheAnalyzedVsPrintedGap`.

---

## The bars

### AE1 — FROZEN MEANS FROZEN, at PR 200's standard

`core/tests/validation/test_smooth_brush.cpp`, on **PR 200's own specimen**: the
committed real ladder output `variant_030.stl` (4344 vertices, 8700 triangles),
frozen against the same resolved bolt-bore predicate — **228 frozen vertices**,
exactly the number PR 200 reported.

```
[BRUSH] specimen: 4344 verts, 8700 tris; frozen bore = 228 verts
[BRUSH] AE1  strength  pairs  frozen_changed  moved  max_shift(mm)
[BRUSH]      0.10       20         0          4116    0.0119
[BRUSH]      0.25       20         0          4116    0.1098
[BRUSH]      0.50       20         0          4116    0.3933
[BRUSH]      0.75       20         0          4116    0.6254
[BRUSH]      1.00       20         0          4116    0.7489
```

`frozen_changed` is counted with `std::memcmp` on the raw `Vec3` doubles — anything
weaker than memcmp would be a miss. 54 checks, 0 failures.

**Three structural layers, not "we undo it after":**

1. `SmoothBrushModel.paint` **refuses** a triangle whose every vertex is frozen —
   the stroke does not take, so the surface reads as untouchable.
2. `vertexWeights()` writes 0 at every frozen index **unconditionally**, whatever
   the assignments say.
3. `laplacian_pass` in core tests `frozen[v]` **first** and copies the vertex
   verbatim. Never computed, never restored.

Bar BR3 proves layer 3 alone: painting weight 1.0 over **every** vertex, bore
included, still moves nothing frozen.

> One implementation detail that matters: a zero-weight vertex takes the same
> *verbatim-copy branch* as a frozen one rather than `p + 0.0·lap`. On a −0.0
> coordinate, `−0.0 + 0.0 = +0.0` — one flipped sign bit, and memcmp fails.

### AE2 — the receipt is the product

Both columns come from the certification engine. The before column is a real
`analyze_fixed_design` pass over the **unsmoothed** variant mesh, run through the
same seam as the after column.

`SmoothCertification` has exactly one initialiser, and it takes a
`TopOptKit.MeshCertification` (an analyze result). There is no path from an
`OptimizeVariant`, a stored outcome, or any remembered number.

`testBothColumnsComeFromTheCertificationEngine` sets the run's remembered margin to
**9.99**, the measured baseline to **2.7814** and the smoothed result to **1.21**,
then asserts the engine ran twice, once per subject, and that the displayed before
is 2.7814 and *not* 9.99. It also asserts both requests carry the same input mesh
and the same load case, so the two readings differ by the brush and nothing else.

### AE3 — the retained job is used

`SmoothRecertLoadCase.fromRetainedJob(Data)` is the **only** way to build a
re-certification load case. It has no parameter through which the project's current
state could enter, and the file contains no reference to `ProjectModel`,
`ForceModel` or `SelectionModel` (asserted after stripping comments).

`testSubstitutingTheProjectsCurrentStateWouldFail` builds a retained job (anchor 3,
load face 7, −500 N, PLA, 64³) and a "current state" that differs in **every** one
of those (anchor 11, face 13, −5000 N, PETG, 128³), asserts the two parse to
different load cases, and then asserts the resolved one is the retained one field by
field. It also reads `openSmoothingPage` and asserts it takes
`relatticeArtifacts?.jobJSON` and never calls `project.loadCase()`.

A run that kept no job document is refused **by name** (`.noRetainedJob`) rather than
falling back. A self-weight run is refused by name too, with its own reason: under
self-weight a lighter part carries less of its own weight, so the margin can only
rise and the receipt would be real but vacuous.

### AE4 — S3 on the WallMount bracket: does a verdict actually drop?

**YES. And the way it drops is more interesting than the fact that it does.**

`core/tests/harness/smooth_brush_probe.cpp`, on the committed
`WallMount_ShelfBracket.stl` at resolution 128 (1.62 mm spacing, 125 × 128 × 13).
The load case is chosen by geometry and printed, not by magic ids: anchor = the five
faces at max-x (the wall plate), load = the four at min-y (the shelf's free end),
traction along −y. The design under test is the **marching-cubes iso-surface of the
part's own voxelization** — terraced and high-frequency, the kind of surface a
variant actually has. Smoothing a smooth prismatic CAD face moves it by microns and
would answer nothing. 3013 of 20526 vertices are frozen (anchor + load faces).

**Two postures, because the first answer I got was vacuous.**

My initial run reported "the verdict never changes" — true, and worthless: at the
bracket's own 35 % infill the specimen **starts REJECTED**. That is PR 276's whole
finding, that the infill rejected the run and not the part (raw margin 2.78, but the
number the gate compares is 0.58). A part already on the wrong side of the stop stays
there however hard you smooth it. So the probe runs the sweep twice.

**Posture A — as the maintainer's run was** (traction calibrated to worst-case
2.7814, their own number; 35 % infill):

| strength | pairs | vm (MPa) | in-plane | interlayer | worst | effective | min-feat | verdict |
|---|---|---|---|---|---|---|---|---|
| 0.00 | 0 | 16.192 | 3.3968 | 7.5481 | 3.3968 | 0.7033 | 17 | REJECTED |
| 0.10 | 2 | 15.953 | 3.4475 | 7.7592 | 3.4475 | 0.7139 | 13 | REJECTED |
| 0.25 | 5 | 19.476 | 2.8240 | 7.7967 | 2.8240 | 0.5847 | 36 | REJECTED |
| 0.50 | 10 | 18.461 | 2.9793 | 7.7826 | 2.9793 | 0.6169 | 43 | REJECTED |
| 0.75 | 15 | 18.477 | 2.9766 | 7.8435 | 2.9766 | 0.6163 | 43 | REJECTED |
| 1.00 | 20 | 17.789 | 3.0918 | 7.8011 | 3.0918 | 0.6402 | 50 | REJECTED |

No verdict can drop here, so the reading is the **size of the move**: worst-case
3.3968 → 2.8240, **−16.9 %**. That is a real, large move — comfortably enough to
cross a stop if the part were near one.

**Posture B — the same specimen loaded so it sits just above the gate.** The force is
derived from posture A's own reading of the design under test (the margin is exactly
inverse in the traction), so it lands the iso-surface at effective 1.65 — not from
the CAD solid, which would aim at a different object than the one being smoothed:

| strength | pairs | vm (MPa) | in-plane | interlayer | worst | effective | min-feat | verdict |
|---|---|---|---|---|---|---|---|---|
| 0.00 | 0 | 6.902 | 7.9686 | 17.7073 | 7.9686 | **1.6500** | 17 | **ACCEPTED** |
| 0.10 | 2 | 6.800 | 8.0877 | 18.2026 | 8.0877 | **1.6747** | 13 | **ACCEPTED** |
| **0.25** | 5 | 8.302 | 6.6249 | 18.2906 | 6.6249 | **1.3718** | 36 | **REJECTED** |
| 0.50 | 10 | 7.869 | 6.9892 | 18.2576 | 6.9892 | 1.4472 | 43 | REJECTED |
| 0.75 | 15 | 7.876 | 6.9830 | 18.4005 | 6.9830 | 1.4459 | 43 | REJECTED |
| **1.00** | 20 | 7.583 | 7.2531 | 18.3010 | 7.2531 | **1.5018** | 50 | **ACCEPTED** |

> **ANSWER: the verdict drops.** ACCEPTED at 1.6500 → REJECTED at 1.3718, a −16.9 %
> fall straight through the 1.50 stop. This is S3, on the maintainer's own part —
> the thing PR 200 was owed and never got.

**THE FINDING THAT MATTERS MORE THAN THE BAR.** The margin is **NOT MONOTONE in
strength**. It *rises* at 0.10 (removing stress-concentrating terracing), falls
through the stop at 0.25, and *recovers* to 1.5018 — back above the gate — at full
strength. The verdict sequence is ACCEPT, ACCEPT, **REJECT**, REJECT, REJECT,
**ACCEPT**.

You therefore cannot infer the verdict at one strength from the verdict at another,
in either direction. That is the measured justification for the page's central design
decision: **re-certify at the strength you actually chose, and never extrapolate.** A
UI that interpolated between two measured strengths, or that assumed "stronger is
worse" and greyed out the strong end, would have been wrong about this part twice.

It also means the shipped **min-feature constraint is doing real work here**: this
sweep runs with `enforce_min_feature = false` deliberately, to see the whole curve.
With the constraint ON — the app's default — the pairs that drive min-feature from 17
to 50 would have been refused, and the user would never reach the REJECTED band.

> Note this differs from PR 200's `test_smooth_recert_loadcase`, whose S3b asserts a
> monotone non-increasing margin. That holds on its synthetic cog bar — uniform ribs,
> one failure mode, a clean single-direction weakening. This is a different specimen
> with a real load path, and the difference between them is the finding, not a
> conflict. **That test was not touched.**

### The brush measured: local is NOT automatically cheaper

The same strength (1.00), applied globally versus to one half of the surface — the
half away from the anchor, which is where the load hangs:

| brush | brushed | unbrushed | worst | effective | min-feat | drift % | bound % | verdict |
|---|---|---|---|---|---|---|---|---|
| global | 17513 | 0 | 3.0918 | 0.6402 | 50 | 0.202 | 0.565 | REJECTED |
| local | 13344 | 4169 | 2.8573 | 0.5916 | 25 | 0.142 | 0.565 | REJECTED |

The local brush is **geometrically gentler in every way** — it moves 24 % fewer
vertices, leaves 4169 of them bit-identical, drifts 0.142 % of volume against 0.202 %,
and ends with **half the min-feature violations** (25 vs 50).

**And it costs MORE margin: −0.5395 against the global −0.3050.**

That is not a defect, it is the point. *Where* you brush dominates *how much* you
brush, because this half carries the load path, while the global pass also smooths
regions whose terracing was concentrating stress. The intuition a user brings to this
page — "I touched less, so it must have cost less" — is measurably wrong on a real
part, in the direction that would make them over-confident.

Which is the case for the whole page in one table: the brush is a way to smooth
exactly where you want, and the receipt is the only thing that can tell you what that
choice actually cost.

### AE5 — H1 is a state

Covered above. The test drives the non-convergent case through the injected runner
and asserts: no current receipt, a named failure with the right strength, the
previous receipt returned already marked stale, and the status line saying the
numbers below are out of date.

Three failure kinds, not one, because they call for different advice:

| kind | what it means | what the page suggests |
|---|---|---|
| `didNotConverge` | the SMOOTHED shape's solve hit its cap | lower the strength, or brush a smaller area |
| `baselineDidNotConverge` | the UNSMOOTHED variant will not certify | *nothing about strength* — smoothing is not the cause, and no receipt is possible for this variant at this resolution |
| `refused(msg)` | the smoother or importer refused outright | the message, verbatim |

The baseline case also short-circuits: the smoothed pass is not attempted at all,
because there would be nothing to compare it against. Asserted by
`testAnUncertifiableBaselineIsNamedAsItsOwnFailure`.

### AE6 — one selection model

The smoothing page opens the **same** `selectionsPanel` the TO page and the lattice
page mount, over the **same** `project.selection`. There is still exactly one
`var selectionsPanel` definition in the app. `SmoothingPage.swift` constructs no
`SelectionModel` and defines no panel; `SmoothingPageModel` holds no group or face
collection (checked by reflection, the same shape as PR 274's M1).

The brush is not a selection: its state is triangles and per-region strengths on the
variant's own surface, which has no face ids at all (PR 274's Z11).

### AE7 — layout parity

`PageChrome` is now the one chrome geometry: `gap`, `edge`, `topInset`,
`circleButton`, `barHeight`, `actionButton`, `compactButton`, `infoBar`,
`panelWidth`, `gizmoSize`, `gizmoInset`, `gizmoClearance`, `panelBottomClearance`.
Every value is the number the workspace and the lattice page already used — this
file only gave them one home.

`LatticeChromeLayout` is now a **named view** onto those tokens, so its own M4 test
(every seam equals `gap`) still passes and there is no second copy.

The test asserts by value (`LatticeChromeLayout.gap == PageChrome.gap`,
`PageChrome.gizmoSize == OrientationGizmoView.standardSize`, …) **and** by reading
`SmoothingPage.swift` for the token names, plus asserting the page hardcodes none of
`frame(height: 64)`, `width: 52, height: 52`, `frame(width: 348)`.

**The gizmo.** The lattice page hides it (round-2 item L6: its Metal-backed glass
composited *over* that page's pure-SwiftUI chrome, so the page's own buttons
rendered behind it). The smoothing page shows it, in the shared corner, by mounting
the workspace's one `orientationGizmo` **above** the page overlay in the ZStack —
which avoids the compositing bug rather than re-introducing it. The page's own
top-right chrome is inset by `PageChrome.gizmoClearance` so the two never overlap.
The test asserts exactly one `orientationGizmo` placement exists in the app.

> Honest limit: this makes the gizmo appear in the same place on the TO page and the
> smoothing page. It is still **hidden** on the lattice page, for L6's reason. Making
> it appear there too is a one-line change plus a fix for the compositing order, and
> is left alone here because it is the lattice page's defect, not this page's.

### AE8 — smooth-then-lattice, and not the reverse

**Forward.** A kept smoothing hands its geometry to the lattice page:
`openLatticePage(variantIndex:smoothed:)` replaces the variant's mesh via
`OptimizeVariant.withGeometry` — geometry only. The rung, the field, the retained
artifacts and the run's own margins travel unchanged, deliberately: the smoothing
page's receipt carries the smoothed geometry's certification, and copying it into the
variant would restate one solver's answer as another's.

The "Lattice this" button is gated on a **kept** smoothing, not merely a certified
one, so a lattice is never generated on geometry without a verdict.

**Reverse.** `SmoothPageEntry.availability` refuses a variant from a run that
generated a lattice — keyed on the **run's own** `OptimizeOutcome.latticeReport`, not
the project's current lattice settings — with the reason *"this run generated a
lattice — smoothing it would round the struts. Smooth first, then lattice the
smoothed variant."*

### AE9 — non-destructive

The original variant is the immutable `SmoothVariantContext`, which is never mutated.
`discard()` is a state reset, not an inverse operation that could drift.

`testDiscardReturnsTheOriginalVariantBitIdentically` snapshots the original vertices
and indices as raw `Data`, smooths, keeps, asserts the geometry actually changed,
discards, then asserts the returned buffers are **byte-equal** to the snapshots — and
that the context's own arrays were never touched.

### AE10 — existing paths unchanged

**Core — `ctest` on the full suite: 100% passed, 94 of 94** (1632 s wall).
`smooth_brush` is the 94th; every pre-existing entry is unchanged, including
`smooth` itself (50 checks, 0 failures), which is the byte-identity guard on the
uniform path.

| suite | result |
|---|---|
| core `ctest` (all) | **94/94 passed, 0 failed** |
| `test_smooth` (PR 200's own bars S1–S6) | 50 checks, **0 failures** |
| `test_smooth_brush` (new, AE1 + BR2–BR7) | 54 checks, **0 failures** |

**App — `swift test` on the full package: 1079 tests, 14 skipped, 8 failures.**

All 8 failures are in **3 pre-existing 3MF tests** and are the documented worktree
gap, not a regression:

```
AppModelTests.testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance
AppModelTests.testReopenedThreeMFProjectReimportsTheStlWorkingCopy
AppModelTests.testThreeMFImportOptimisesOnDeviceEndToEnd
```

The cause is structural and self-reporting — this worktree's `vendor/` contains
`TopOptCore.xcframework` and `occt-lib` but **no `lib3mf-lib`**, and the refusal the
tests receive says so verbatim: *"3MF import requires lib3mf, which is not available
in this build"*. Nothing in this task touches 3MF import.

**The specific suites AE10 names, re-run and reported:**

| suite | result |
|---|---|
| `SmoothingPageTests` (new) | **31 tests, 0 failures** |
| `LatticeSDFAlignmentTests` (PR 251's alignment) | 7 tests, 1 skipped, **0 failures** |
| `LatticeVariantTests` (PR 274) | 16 tests, **0 failures** |
| `LatticePageRound2Tests` (incl. the M4 chrome bar) | 15 tests, 1 skipped, **0 failures** |
| `LatticePageTests` | 25 tests, **0 failures** |
| `SelectionModelTests` | 18 tests, **0 failures** |

PR 251's alignment and PR 274's variant tests both pass unchanged, which is the
load-bearing part: `LatticeChromeLayout` was rewired to derive from `PageChrome`
and its own M4 test still pins every seam.

---

## What changed, file by file

**Core**

* `core/include/topopt/smooth.hpp` / `core/src/mesh/smooth.cpp` — added
  `SmoothConstraints::vertex_weight` (empty ⇒ byte-identical to before), the brush
  fields on `SmoothStats`, and `taubin_volume_drift_bound_weighted`, which takes the
  peak over the whole (k, w) rectangle so the quoted bound covers every weight the
  brush applied — not only the strongest.
* `core/tests/validation/test_smooth_brush.cpp` — new, AE1 + BR2…BR7.
* `core/tests/harness/smooth_brush_probe.cpp` — new, the AE4 measurement.

**Bridge**

* `smooth_freeze_mask` — the per-vertex freeze mask, from core's own
  `compute_freeze_mask` on the same resolved region list the smoother applies. The
  region resolution was factored into one shared `loadcase_freeze_regions`, so what
  the page paints against and what the smoother protects cannot drift apart.
* `smooth_brush_and_recertify_loadcase` — the brush seam. The existing
  `smooth_and_recertify_loadcase` now **delegates** to it with an empty brush, so
  there is one implementation.
* `AnalyzeResult` gained `margin_in_plane`, `margin_interlayer`, `solid_voxels`, the
  brush counts, and the two volume fractions.

**App**

* `PageChrome.swift` — the shared chrome geometry.
* `SmoothBrush.swift` — the brush: regions, per-region strength, painting, undo,
  weight derivation, the freeze mask, the inspectable summaries, and
  `vertexTints()` — the per-vertex tint the stage draws, which rides the viewer's
  existing tint channel (no new GPU buffer, no new renderer path). Frozen vertices
  are tinted **before anything is painted**, so what the brush will refuse is
  visible in advance rather than explained in a footnote afterwards.
* `SmoothingVariantSession.swift` — `SmoothRecertLoadCase` (retained-job parse),
  `SmoothVariantContext`, `SmoothUnavailable`, `SmoothPageEntry`, `SmoothKeptResult`.
* `SmoothingPageModel.swift` — `SmoothCertification`, `SmoothReceipt`,
  `SmoothingApplied`, `SmoothCertifyFailure`, the phase machine, `SmoothPageActions`.
* `SmoothingPage.swift` — the page.
* `SmoothBrushKit.swift` — the three Swift seams over the bridge.
* `WorkspacePlaceholder.swift` — page lifecycle, the live runner, brush routing
  through the existing `BrushHitTest` gesture, the gizmo mount, the lattice handoff.
* `ResultsScreen.swift` — the per-variant **Smooth** chip, placed before **Lattice**
  because the pipeline order is smooth-then-lattice.

---

## What is NOT built, and why

* **The brush does not run remotely.** Re-certification uses the on-device bridge,
  the same path PR 200's `SmoothingModel.live` uses. A brush workflow re-certifies
  repeatedly and a LAN round trip per press would make it unusable; the LAN worker
  also routes only `run` and `lattice_variant` jobs today. The consequence is stated:
  on a large part at a high resolution each press costs a full certification solve on
  the device.
* **The CLI has no per-region brush.** `--smooth S` stays exactly as it was. Adding a
  per-vertex weight file to the CLI would be a new schema for one caller; the brush
  is a UI affordance and its weights are derived from strokes, which the CLI has no
  way to author.
* **The gizmo is still hidden on the lattice page.** See AE7 above.

## What the measurements say is worth doing next

Not built here, and each is a consequence of a number above rather than a wish:

* **The non-monotone margin deserves a strength SWEEP, not a slider.** The bracket
  reads ACCEPT / ACCEPT / REJECT / REJECT / REJECT / ACCEPT across six strengths. A
  user hunting for "the strongest smoothing that still passes" by hand will re-certify
  five or six times and may still miss the answer. The page could certify a small
  ladder of strengths in one press and show the whole curve — the machinery is
  already there (one `recertify` call per rung), but it is N solves per press and
  that trade needs the maintainer's call, not mine.
* **`analyze_fixed_design`'s solver policy is still PR 200's owed follow-up.** H1 is
  handled honestly here, but handling it is not fixing it: a fixed-design re-analysis
  is a one-shot solve, not a hot optimizer loop, so it can afford a higher CG cap or
  a Jacobi-CG fallback without the byte-identity concern that blocks changing the
  optimizer's cert solver. On a brush workflow this is now the difference between
  "re-certify" working and "re-certify" failing. PR 200 flagged it; this task makes
  it cost more.
* **The local-vs-global result suggests the page should say WHERE the margin went.**
  The certification already returns a per-voxel von Mises field. Showing which
  brushed region moved the binding stress would turn "your smoothing cost 0.54" into
  "this region cost 0.54" — which is the actionable form, and the data is already
  in hand.

---

## In plain language

You have a finished variant. It is strong enough, but it looks like it came off a
3D printer — stair-steps everywhere, because that is what a voxel optimizer produces.
You want to smooth the ugly bits without touching the bolt holes.

So you open the new page from that variant, and you paint. Not a global slider — you
brush the areas you actually care about, and each brushed area gets its own strength.
Paint the shelf face at 0.6; paint the fillet at 0.2; leave the rest alone. If you
try to paint over a bolt hole, the brush simply does not take there, and the panel
tells you how many vertices it refused to touch. That is not a filter applied
afterwards: those vertices are copied through the smoother untouched, bit for bit,
and there are three separate places in the code that would each have to fail before
one of them could move.

When you are happy, you press **Re-certify** — once, deliberately, not on every
stroke. Two solves run: one on the variant exactly as the optimizer made it, one on
the smoothed version. Then you get a table with both, side by side: the margin, the
two failure modes it is the smaller of, the number the gate actually compares, how
many features are too thin to print, the mass, and the verdict.

Both numbers are measured. The "before" is not the number the run remembered — it is
a fresh solve, because a remembered number and a measured one can differ for reasons
that have nothing to do with your brush, and putting them next to each other would
blame the brush for that difference.

Three things the page is careful about:

**It can fail to answer.** Sometimes the solver cannot converge on the smoothed
shape — this is a known, repeatable limit on very sparse geometry, not a bug in the
smoothing. When it happens the page says so, says why, and suggests a lower strength.
Crucially, the numbers from your *last* successful certification stay on screen but
get stamped **STALE**, in orange, with a sentence saying the shape you are looking at
has not been certified. You never get a stale number wearing a fresh badge.

**Smoothing is not always a cost.** On stringy, tendrilly variants, smoothing
actually *reduces* the number of unprintably-thin features, because it removes the
stair-stepping that was being counted as thin. The page reports that as an
improvement, in green, using the same code path it uses to report a regression.

**What gets certified is not exactly what gets printed.** The solver works on a
voxel grid; the file you export is a triangle mesh. They are close but not identical.
Rather than hide that, the receipt prints both volume numbers and the percentage gap
between them, so you can see how big the approximation is instead of assuming it away.

Then you decide. **Keep**, and the smoothed shape and its receipt travel onward
together — including to the lattice page, which will then lattice the *smoothed*
geometry. **Discard**, and you get the original variant back exactly as it was, to
the byte; nothing was ever modified in place.

One direction only: you can smooth and then lattice. You cannot smooth something
already latticed — that would round off the struts, which is not what anyone means
by smoothing a part — and the page refuses it by name rather than letting you find
out afterwards.

---

## The one thing the measurements changed my mind about

I expected smoothing to be a slider where more is worse, and brushing locally to be
the cheap option. **Both turned out to be false on the maintainer's own bracket, and
that is the most useful thing this task produced.**

On that part, smoothing at 10 % made the margin *better*. At 25 % it fell through the
safety stop and the part was rejected. At 50 % and 75 % it stayed rejected. At 100 %
it came back and passed again — barely. Six settings, and the answer flips three
times.

And brushing *only* the half that needed it — moving a quarter fewer vertices, leaving
thousands untouched, halving the number of too-thin features — cost **nearly twice as
much margin** as smoothing the whole thing. Because that half was the half carrying
the load.

So the honest summary of the whole feature is short: **you cannot guess.** Not from
the strength number, not from how much of the part you touched, not from how it
looks. The only way to know what a particular smoothing cost is to certify that exact
smoothing — which is why the button says "Re-certify", why it runs on demand instead
of guessing between strokes, why the before column is measured rather than remembered,
and why a smoothing whose certification failed can never be kept.

The page is not a smoothing tool with a receipt bolted on. It is a receipt, with a
brush attached to make it worth asking for.

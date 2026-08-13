# 2026-08-14 — separating the TO from the lattice, and a wizard you can see

Evidence: `evidence/2026-08-14-lattice-separation/`
Branch base: **`726160c`** — PR 331 `face-regions`, REBASED onto (bar R11), not merged blind.
Original base before the interrupt: `9e96beb` (the merge of PR 329)

> **"It is VERY important we separate the TO and Lattices out so the user can
> choose between JUST TO or TO+lattice and have complete control with where the
> lattice goes — or choose to set it automatically."**

PR 328 built the right mechanisms and the wrong shape. The depth fix, the
per-region preview, the cinematic values and the PENDING unblock all stand. What
changed is the arrangement.

---

## §0 — THE FOUR ANSWERS, ONE LINE EACH

**A TO-only job needs no lattice page.** Set an anchor, set a load, press
Optimize: `lattice.enabled` is false, `latticeJobRegions()` is empty,
`runSpec` is nil, and the job.json a submit posts has **no `lattice` key at
all** — asserted on the project AND on the document
(`testATopologyOnlyJobNeedsNoLatticePage`,
`testTheJobDocumentOfATopologyOnlyRunCarriesNoLatticeAtAll`).

**What was removed from the TO page.** The "Lattice settings · on / topology +
infill setup" state banner; the "Lattice here" and "No lattice" chips on every
group; the "Struts" toggle **and the raymarched strut LAYER it arms** — separate
state, so removing only the toggle would have left a lattice drawn over the
topology page with no way to turn it off; the per-region readout (depth · held ·
grams · cell · density · strut · regime flag); and the lattice density shading on
the part surface. (The Design Box and Paint chips are hidden on the lattice stage
for the mirror reason.) One button remains, top right, **green**, one word:
**Lattice**.

**Why the sample was invisible.** `LatticeSetupWizard` passed the renderer
`reveal: Float(model.densityMode == .auto ? wipe : 1)` (line 75) with
`@State private var wipe: Double = 0` (line 42), and PR 328 §4b had just made
`.auto` the **default** — so the page opened at `reveal = 0` and
`MetalMeshView`'s fragment shader (`if (t > reveal.x) discard_fragment();`, line
126) threw away **every fragment of a mesh it had already built and uploaded**.
That is the empty viewport reading "1 ms · 544 tris", exactly.

**The wizard and the side modal share one state.** `LatticeWizardSetting.stage`
is one table: changing a setting in the modal calls `touched(_:)` which moves the
wizard to that setting's stage and plays its cinematic; the wizard's **Next**
calls `advance()`, which moves the sub-title the modal lights. Neither view owns
the state (`testTheWizardAndTheSideModalShareOneState`,
`testTheModalsSubTitlesAreTheWizardsStages`).

---

## §7 — THE INVISIBLE SAMPLE, MEASURED THROUGH THE SHIPPING PIPELINE

Not argued — rendered. `LatticeSeparationEvidenceGen` builds the wizard's own
Stage-A mesh, hands it to the app's own `MeshRenderer`, and renders it twice
through the same shader, at the two reveal values:

| | reveal | lit pixels of 230,400 |
|---|---|---|
| **BEFORE** — what shipped on entry | 0 | **0** |
| **AFTER** — `LatticeWizardReveal().value` | 1 | **61,794** |

`r6_sample_before_reveal0.png` is a black frame. `r6_sample_after.png` is the
octet cell. Both are asserted, so this is a test as well as a capture — a
screenshot nobody looks at is not evidence.

**The fix is a type, not a condition.** A wipe is a CINEMATIC — a thing that runs
and finishes — so `LatticeWizardReveal` models it as one: `value` is 1 unless
`wiping`, `begin`/`step`/`end` bracket it, and a stale `step` after `end` cannot
blank the page again. A density mode is no longer an input to what is drawn.

**§7b — framed on entry and on every stage transition.** `frameSample()` calls
`camera.reframe(mesh.bounds)` in `.onAppear` and in `.onChange(of: model.stage)`.
`OrbitCamera.frame` re-anchors the look-at target on the object's own centre, so
it also clears the pan the Stage-C dive leaves behind — which is the second way
this page could have shown nothing.

**One thing I did NOT find, and say so.** The wipe was also not animating: a
`Double` handed straight into a Metal view is not interpolated by
`withAnimation`, so PR 328's single `wipe = 1` assignment was a jump, not a wipe.
It now steps on the same clock `animateTile` uses. That was not in the brief; it
is one line and the alternative was shipping a "cinematic" that cuts.

---

## §1 / §2 — THE SEPARATION, AND WHY IT IS ONE TABLE

`WorkspaceStage` is `.topology` or `.lattice`, and **both are the same view over
the same models**. That is not a description — it is how "seeing the same style
of page as before" is made structurally true rather than approximately true. The
Selections library, the button sizes, the bottom bar and the gizmo corner are
literally the same code, so backlog L3's "the buttons feel different" cannot
recur BETWEEN THESE TWO — there is no second set of them to drift. (The ladder
page and the smoothing page are still their own views; §6's shared modal
placement is what keeps those in line, and it is a weaker guarantee than this
one.)

What differs is `WorkspaceStageVisibility.of(stage)` — five columns, read at
every visibility site. A site reads the TABLE, never the stage, so a new
affordance cannot be given to one page by accident: it has to be given a column
first.

| | design box | group primitives | keep-outs | depth planes | lattice controls |
|---|---|---|---|---|---|
| **TO page** | ✔ | ✔ | ✔ | — | — |
| **Lattice page** | — | — | — | ✔ | ✔ |

The group ROW is the same idea one level down: `rowSections` returns
`[.clearanceEditor]` on the TO page and the three lattice sections on the lattice
page, and the row builder switches over exactly that list — **a section that is
not in the list is not built**. That is what makes R2 a property the tests read
rather than a claim about a view.

### §2c — hiding is not disabling, and it is checked

The obvious way to get this wrong is for "hidden" to quietly become "off", which
is the class of defect that produced empty lattices for weeks.
`testHidingIsNotDisabling` drives a protected, latticed wall dragged to 7 mm,
asserts `WorkspaceStageVisibility.of(.topology).latticeDepthPlanes == false` —
the plane IS hidden — and then requires **both** protections to still come out at
7 mm and **both** regions to still be emitted. The design box is the same: it is
not drawn on the lattice stage and it still bounds the run.

The one place I let visibility touch a CONTROL is the Design Box and Paint chips,
and deliberately: the Design Box chip toggles the box's visibility and its drawer
adds keep-outs, so on a stage that draws neither it would be a dead control. The
box itself is untouched.

---

## §3 — THE LATTICE PAGE

**(c) Each primitive gets its own lattice / no-lattice.** His words were
"Otherwise, what the fuck are they doing?", and the complaint is precise: PR 328
keyed the role on the GROUP, so a group holding a wall face, a boss face and a
hand-placed slab had one answer for all three.

The role moves down one level and the group becomes a summary:

* `LatticeSettings.groupRoles` — the group's DECLARATION. Still what the
  eligibility gate (§1a/§1d) reads, still what turns the mode on.
* `LatticeSettings.primitiveRoles` — the per-primitive OVERRIDE, keyed by
  `LatticePrimitiveRef.key`. **Absent ⇒ follows the group**, so every snapshot
  written before this task resolves to exactly the roles it had, and the emission
  is unchanged (`testASnapshotWithoutOverridesEmitsExactlyWhatItDidBefore`).

The group row shows **all / some / none**, computed from the resolved answers.

**★ AND THE PER-PRIMITIVE ANSWER HAS THREE STATES, NOT TWO — this is the part
worth reading.** `LatticeGroupRole` is `include | exclude`, and **both are
regions core emits**. So a per-primitive override needs a third answer the
two-case enum cannot express: *not a region at all*. Without it, a group with
three faces and no declaration would gain one the moment you latticed ONE of
them, and the other two — having no override — would follow it and be latticed
too. **Setting one face would silently set three**, which is the exact failure
mode the whole request is about. `LatticePrimitiveRole` adds `off`, the chips are
**Lattice / Solid / Off**, and the declaring tap PINS the siblings to whatever
they resolved to a moment before (`LatticePrimitiveRoles.declare`). `off` never
reaches the wire. `testDeclaringOnePrimitivePinsItsSiblingsInsteadOfMovingThem`
declares one face of two and requires exactly ONE face region in the job.

**R3, on the emitted job.** Two walls in one group, one set "Lattice" and one set
"Solid", produce two regions with `role` `include` and `exclude` and face ids 16
and 17 — two different regions from one group, which is what "decorative
primitives" meant in practice.

**The gate is not routed around.** A per-primitive override on a group that
declares nothing still emits nothing
(`testAPerPrimitiveOverrideIsNotAWayPastTheRoleGate`).

**(d) The depth plane got its 3D handle.** PR 328 built the slab's geometry and
its number and put the drag on the card's numeric field, and said so. This is the
handle it did not get to — and it is not new drag math:
`ProjectModel.latticeDepthPlanes()` builds a `ClearanceVolume.slab` and asks
`ClearanceHandles` for its `.slabDepth` grab, the same tested pair the keep-clear
face slabs have used since keep-clear Phase B. **The normal is flipped** — a
clearance slab reaches OUT of the part, a lattice slab reaches IN — for exactly
the reason `LatticeRegionEmission.spec` flips it, so the plane on screen is the
region in the job.

**R4 — and this is where it could have broken.** Making the depth per-primitive
means two faces of one group can hold two depths. So the protection is resolved
**per face**, through the same `LatticeSlabDepth.depthMM(ref:…)` call the region
emission makes. `testTheDepthDragAndTheProtectionDepthRemainOneNumberPerFace`
drags face 16 to 9 mm and face 17 to 3 mm and requires
`LatticeSlabDepth.mismatches` to be empty — **and** asserts the two really are
different numbers, so it cannot pass by both being the group default.

---

## §4 — THE DRAWER

His question was what those numbers are, whether they matter, whether they are
modifiable. **They matter and they are the most valuable thing on the card**: a
4.0 mm depth against a 4.93 mm cell IS out of regime, and that is the failure
that produced empty lattices for weeks — reported correctly, before the run, and
rendered as unreadable vertical text.

Nothing was removed.

* **Collapsed (§4d):** one thing — the grams handed over, with the verdict as
  COLOUR, plus the all/some/none coverage.
* **Open (§4a):** a drawer beneath the group squircle, collapsed by default.
* **Headline (§4c):** the out-of-regime flag, first, as its own line — "0.8 cells
  across" against an orange ground. It is the one line that predicts a wasted run.
* **Controls (§4b):** `LatticeDrawerRow.modifiable` is true for the DEPTH and
  nothing else. A row that is not modifiable gets no gesture and no control
  chrome — the lesson of backlog item (1)'s Diagrid picker that was not a picker.
  `testOnlyTheDepthIsAControl` asserts there is exactly one.

---

## §5 — THE WIZARD

**(a) Centre stage, one decision at a time, with a NEXT button.** The card holds
this stage's settings and nothing else; the object is above it; both sit on the
screen's centre line. It is padded clear of the left modal's width, because a
380 pt card centred in a 1024 pt canvas lands 50 pt inside a 348 pt panel, and
overlapping chrome is the complaint this page exists to answer.

**(b) The side modal skips it.** `jump(to:)` goes anywhere with no cinematic, and
every control is live in the modal at all times.

**(c) The coupling, which is the part that makes it work.** The modal is grouped
under sub-titles that ARE the wizard's stages, and `LatticeWizardSetting.stage`
is the only mapping — `LatticeWizardStage.settings` is derived by filtering it,
so the two lists cannot disagree. Changing a control in the modal moves the
wizard to that stage's visual output; Next moves the modal's lit sub-title.

**(d) Stage order, unchanged from PR 328's build**, with the third stage given a
name of its own: one cell alone (type morphs, size, thickness) → the cell flies
into the sample and tiles it → density and boundary finish, with the stress-field
wipe on Auto.

---

## §6 — THE MODAL GEOMETRY STANDARD

"EVERY page should always look the same with the modal that is in the center of
the left side and doesn't reach the top or bottom." The smoothing page already
did this and derived the band from the chrome tokens (bar D3) — but it did it
inside its own body, so nothing inherited it. It is now `PageLeftModal`, one
modifier, deriving width / top / bottom / band from `PageChrome`.

**Pages that changed:** the **workspace** (both stages — the Selections panel was
bottom-leading with a hard 96 pt lift, and its width was 300 rather than the
shared 348), the **lattice settings wizard** (its modal ran the full height), and
the **lattice ladder page** (it was centred, but in `height − 200`, a number with
no relationship to anything on screen). The smoothing page already conformed and
is unchanged.

---

## §8 — WITHDRAWN MID-TASK, AND WHAT IT COST

§8 said face splitting, grid splitting and union were deferred and must not be
designed around. **PR 331 landed and that stopped being true**, in the very panel
this task restructures. What follows is the rebase, section by section, against
the bars the interrupt added.

### R11 — rebased, and the rebase found a defect of its own

`git rebase 726160c` over six commits, one conflict, in
`WorkspacePlaceholder.swift`'s overlay stack: PR 331 added `regionsPanelOverlay`
exactly where §1 removed `latticeEntryButtonOverlay`. Resolved by keeping BOTH —
regions are a SELECTION facility, not a lattice one, so the Regions surface
belongs to both stages while the lattice affordances belong to one.

★ **AND THE REBASE BROKE THE SUITE IN A WAY THAT LOOKED LIKE A BAD TEST.** PR 331
changed `core/src/cli/job.cpp`; I did not re-run `build_core.sh`, so the vendored
`TopOptCore.xcframework` was built from the PRE-rebase core. It did not fail to
link — **it hung**. `swift test --filter LatticeSeparation` ran 10+ minutes at
100% CPU with no output, while every one of those tests passed in milliseconds
run ALONE. `sample <pid>` named the frame:

```
LatticeSettings.runSpec(...)  default argument 6
  LatticeRetentionCapability.fromCore   (LatticeSubfloorRetention.swift:91)
    one-time initialization function for fromCore
```

`fromCore` is a lazy `static let` that asks the linked core whether its grading
schema accepts four keys. Against a core whose parser had moved underneath it the
probe never returned — and because it initialises ONCE, only the first test to
reach it hangs, which is why single-test runs looked healthy. Rebuilding the
xcframework fixed it: **39 tests, 0 failures, 0.216 s.**

### §3(c) → PER SELECTABLE, not per primitive

`LatticePrimitiveRef` is now `LatticeSelectableRef` with a third case,
`.region(group:region:)`, and the stores are `selectableRoles` /
`selectableDepthMM` (the old `primitive*` keys still DECODE, so a snapshot
written yesterday keeps its choices). A region carries its own lattice /
no-lattice, its own depth, its own drawer, and counts in the group's
all/some/none exactly as a face does — `testARegionIsASelectableJustLikeAFace`,
`testARegionCarriesItsOwnLatticeChoice`.

### §3(d) → the depth handle works on a REGION, into PR 331's own store

A region's dragged depth lands in `face_protection_region_ids` +
`face_protection_region_depths_mm` — PR 331's arrays, filled through the same
`LatticeSlabDepth` call a face goes through. No parallel store.
`testARegionsDepthFillsPR331sPerRegionProtectionArrays` drags a region to 9 mm
and the face beside it to 3 mm and requires both to come out.

★ **AND THE PLANE IS REFUSED, NOT INVENTED, WHEN THE REGION HAS NO DIRECTION.**
A face has a plane; a region is a voxel set. The plane is built from PR 331's own
`FaceRegionGeometry.frame` plus the area-weighted mean of the members' outward
normals — and when that mean is shorter than 0.75 (a union wrapping a bore, or a
top face unioned with a side face) there IS no "into the part", so no 3D grab is
offered. The region keeps its depth NUMBER and its row; what it loses is a handle
that would have meant nothing. `testAWrappingRegionGetsNoDepthPlaneRatherThanAMeaninglessOne`.

### R12 — ONE disclosure, and PR 331 owns the half it should

`LatticeRowDisclosure` is the only expand/collapse concept in the Selections
panel, and for a REGION it reads and writes **PR 331's own
`FaceRegion.collapsed`** — the same bit, not a mirror — so the panel and the
Regions sheet cannot disagree about whether a split is open. Expanding a region
therefore reveals its drawer AND its children together, which is what §5(b)
describes a deliberate expand doing; a collapsed grid parent is still ONE row in
this list (`testAGridSplitStillAddsONERowToTheLatticeList`: 1 collapsed, 26
expanded). A group and a face have no `FaceRegion` to store it on, so those live
in the same type's own set — one mechanism, and only one of its two backing
stores is ours.

### R14 — PR 331's guards still fire

The sliver guard (`FaceRegionModel.checkSliver`, floor 16 voxels — the size of the
smallest face his own CAD hands him) still refuses with its number after the
restructure, and the small-face policy still DIMS rather than hides: a
sub-floor selectable is listed in the lattice row list and drawn at 0.55 opacity,
because hiding it would lose a selection his CAD does hand him (faces 41-47).
`testTheSliverGuardStillRefusesWithItsNumber`,
`testASmallSelectableIsListedAndFlaggedNotHidden`.

### ★ THE ONE THING THAT IS NOT IDENTICAL, AND HOW IT IS SHOWN

The interrupt forbade making a region into a lattice region, and it is right that
this is core's problem: `lattice.regions` are pure GEOMETRY that become
`ClearanceGeometry` predicates evaluated pointwise (`run_job.cpp:621`, `:756`,
`:856`), while a region is a voxel SET (PR 331 §6).

**So the choice is captured and the row says it is not consumed.** I considered
disabling the chips instead, and rejected it: the interrupt asks for the choice to
be CAPTURED so it survives until core catches up, and a disabled control captures
nothing. What makes capture honest is that it is not silent — the row carries
**"Frozen, not latticed"** (three words) and the drawer LEADS with it, outranking
even the out-of-regime verdict. The depth half is genuinely live: it is PR 331's
per-sector protection depth and the run consumes it.

`testARegionsLatticeChoiceIsCapturedAndTheRowSaysItIsNotConsumed` asserts the
capture, the words, and that the row chip and the drawer headline are the same
words. `testNoRegionIsEverEmittedAsALatticeRegion` asserts the other half — no
region reaches `lattice.regions`, so nothing downstream can act on a choice core
cannot read.

**If that is still the wrong trade, the smaller alternative is one line:** make
`latticeReachesTheRun` disable the two chips and keep the depth live. The flag is
already the single point that decides it.

### §4 of the interrupt — the coplanar correction

Nothing to correct: `git diff 726160c -- app docs` in this branch contains no
occurrence of "coplanar". This branch never promised the expand-to-coplanar
behaviour PR 331 refuted (22 → 22 on his part).

---

## The bars

| bar | status |
|---|---|
| **R1** TO-only end to end | **MET.** Asserted on the project and on the job document — the emitted job.json has no `lattice` key, with the anchor and the load present so the check is not passing on an empty job. Path: import → set gravity → tap a face → Anchor → tap a face → Load → **Optimize**. The lattice button is the only thing on that page that mentions a lattice, and it navigates. |
| **R2** nothing lattice survives on the TO page | **MET.** `WorkspaceStageVisibility.of(.topology).rowSections == [.clearanceEditor]`, and the removed list is enumerated in §0. |
| **R3** per-primitive asserted | **MET.** Two walls in one group, set differently → `include` on face 16 and `exclude` on face 17 in the emitted regions. |
| **R4** depth drag == protection depth | **MET, and now per FACE.** 9 mm and 3 mm on two faces of one group; `LatticeSlabDepth.mismatches` empty on the path the run is built from. |
| **R5** wizard and modal one state, failing test first | **MET.** `r5_r7_failing_first.txt` — the tests do not COMPILE against the pre-task model, the same shape as PR 328's L5: the API had no way to express the case. |
| **R6** the sample is visible on entry | **MET.** 0 lit pixels → 61,794, through the shipping shader. `r6_sample_before_reveal0.png` / `r6_sample_after.png`. |
| **R7** no wall of text | **MET. Longest string added: 3 words** — "Holds no material" and the out-of-regime headline "0.8 cells across". Asserted at ≤ 3 over every string this task adds. Stated honestly: the longest string the lattice stage can render is still `LatticeFaceRoleGate.Block.undeclared.reason` — "Give this face a role first", 6 words — which PR 328 wrote and this task did not touch. |
| **R8** no verdict moves | **MET, structurally: this branch does not touch `core/`.** `git diff --stat 726160c -- core/` is empty; every change is under `app/`. ★ The BASE moved, though — PR 331 changed core — so the suite was RE-RUN on the rebased tree rather than the pre-rebase number being quoted: **120/120** (`ctest.txt`), the extra test versus the pre-rebase 119 being PR 331's own `face_region`. NOT a CI pass either way: this machine has no lib3mf, so `export_3mf` and `threemf_import` do not REGISTER. Report N/122, never N/N. |
| **R9** never weaken an assertion | **MET.** `r9_assertion_census.txt` — every kind unchanged or up, nothing deleted. Two source-reading tests were UPDATED where a symbol was renamed, and both were STRENGTHENED in the same edit: the "no workspace chrome while a page is up" census renamed `latticeEntryButtonOverlay` → `stageNavigationButtonOverlay` **and gained the two overlays this task added**, and the design-box census kept its D5a assertions and **gained the lattice-stage term**. |
| **R10** no unfilled placeholders, no scratch at root | **MET.** |
| **R11** rebased on PR 331, base stated | **MET.** Base `726160c`; six commits rebased, one conflict, resolved by keeping BOTH surfaces. The rebase also surfaced a stale-vendor hang — see §8. |
| **R12** one collapse mechanism in the panel | **MET.** `LatticeRowDisclosure`; a region's bit IS `FaceRegion.collapsed`. A collapsed grid parent is 1 row here, 26 expanded. |
| **R13** a region and a face behave identically | **MET**, with the one difference ASSERTED rather than glossed: same refs list, same role chips, same three states, same depth resolution, same drawer builder — and `latticeReachesTheRun == false` on a region, shown as "Frozen, not latticed". |
| **R14** PR 331's guards still fire | **MET.** `checkSliver` still refuses with its number; the small-face policy still DIMS rather than hides, in the new row list. |

**The suites.** Core: **120/120** on the rebased tree (`ctest.txt`) — 120 of CI's 122, the two lib3mf tests not registering here.
App: **1497 executed, 22 skipped, 3 failures** (on the REBASED tree — PR 331's 26 region tests and this task's 39 are both in that number) — all three are
`AppModelTests.test*ThreeMF*`, and they fail because THIS MACHINE's core slice
has no lib3mf ("3MF import requires lib3mf, which is not available in this
build"). They failed identically on this branch's first run before any source
edit. I provisioned lib3mf to close the gap and the test bundle then failed to
LINK with undefined `_lib3mf_*` — the known worktree trap — so I reverted to the
3MF-free slice, which is three visible refusals instead of a bundle that will not
build. **CI provisions lib3mf and runs the same `swift test`, so report this as
1494/1497 local against CI's own denominator.**

---

## In plain language

You told us the topology optimizer and the lattice had got tangled up together,
and you were right. The first page — the one where you pick which faces are
anchors and which carry load — had six different lattice things on it. A banner
saying what the lattice was set to. A "Lattice here" and a "No lattice" button on
every group. A Struts button. And a row of small numbers about cells and struts
and grams. If you only wanted a topology run, none of that was for you, and it
was all in your way.

It is gone. That page now has one lattice thing on it: a green button in the top
right that says "Lattice". It does not tell you anything — it just takes you
there. You can set an anchor, set a load, press Optimize, and never touch it.

Press it and you get the same page again. Same layout, same list of selections on
the left, same buttons, same position cube in the corner — because it really is
the same page, just showing different things. On this one your design box and
your keep-outs are not drawn, because they are not what you are thinking about
here; and back on the first page the lattice depth planes are not drawn, for the
same reason. Nothing is switched off by being hidden: the depth you drag here
still holds the wall against the optimizer over there, and we check that rather
than assert it.

The thing you asked for that mattered most: every primitive now decides for
itself. Before, if a group had three faces in it, you got one answer for all
three, which is why you asked what the primitives were even doing. Now each one
has its own Lattice / Solid, and its own depth, and the group just tells you
whether all of them, some of them, or none of them are latticed. Two faces in one
group set differently really do come out as two different regions in the job — we
run that.

There was a trap in that which is worth knowing about. The two answers the run
understands are "lattice this" and "keep this solid", and both of them are
instructions — neither means "leave this one alone". So if we had only offered
those two, tapping Lattice on one face of a three-face group would have quietly
latticed the other two as well, which is the opposite of what you asked for. Each
primitive therefore has a third state, **Off**, and setting one primitive pins
the others to whatever they already were. One tap moves one thing.

The numbers you asked about — the 4.0 mm, the 72.5 g, the 4.93 mm, the 5%, the
0.32 mm and the orange flag — matter more than anything else on that card, so
none of them were removed. They moved into a drawer that opens under the group,
closed until you want it. Closed, it shows one thing: the grams that face hands
to the lattice, coloured by whether it will work. Open, the first line is the
warning, because that orange flag is the single line that tells you a run is
going to be wasted before you spend an hour on it. The depth is the only one you
can change; the rest are worked out from it, and they look like facts rather than
like buttons, so you are not left tapping something that was never a control.

Then the settings page. You said it was meant to be a wizard and all you could
see was a list on the left. There is now an actual wizard in the middle of the
screen: one decision at a time with a Next button, and the object right above it
doing whatever you just changed. The list on the left is still there and still
live — if you know what you want you change it directly and never see the
walkthrough. And the two are wired together: the list is grouped under the same
headings the wizard walks through, so changing a setting on the left jumps the
middle to the picture that shows it. They are not two screens; they are one thing
with two ways in.

Finally, the bug. You opened that page and saw nothing, while the corner said "1
ms · 544 tris" — geometry being made and not shown. The cell was being drawn
correctly the whole time. There is a wipe effect for the stress field, and the
page was reading how far that wipe had got in order to decide how much of the
object to draw — but it read it whenever automatic density was on, and automatic
density had just become the default. So the wipe was at zero, the graphics card
was told to draw zero percent of the object, and it threw away every pixel of a
cell it had already built. We fixed it by making the wipe a thing that runs and
finishes rather than a setting, so it cannot hold the page blank again, and we
proved it by rendering the same cell through the same graphics code twice: zero
lit pixels before, sixty-one thousand after. Both pictures are in the evidence
folder. The camera also now frames the object when you arrive and every time the
wizard moves on, so it is always in view at a sensible size.

---

**A late change, and what it means for you.** Part way through this work the
face-regions branch landed — the one that lets you combine twenty-four little
fillets into one thing and cut it into pieces. That put a new kind of row in the
same list I was rebuilding, so the rule you gave me had to widen: it is not "each
primitive gets its own lattice choice", it is *each selectable*. A region you made
by combining faces now has its own Lattice / Solid / Off, its own depth, and its
own drawer, exactly like a single face. Two of them in one group can disagree, and
the job comes out with them disagreeing.

One thing about regions is honestly not finished, and it is not something this
branch could finish. The optimiser can freeze a region to a depth — that works
today, and it is how you hand-set ten different depths around a curved feature.
But it cannot yet *lattice* a region, because the lattice code wants a shape (a
cylinder, a slab) and a region is a set of voxels. So the choice you make is
remembered, and the row tells you plainly: **"Frozen, not latticed."** I would
rather it said that than quietly do nothing. Finishing it is three changes in the
core, they are written down in the face-regions handoff, and it is a separate job.

There is also one place a region does not get a 3D handle: if you combine faces
that point in different directions — say a wall and the top — there is no single
"into the part" for a depth plane to run along, so you get the number without the
handle rather than a handle that means nothing.

And a note from the rebase, because it cost an hour and will cost the next person
the same. Pulling in that branch changed the C++ core, and I did not rebuild the
compiled copy the app links against. Nothing failed to build — the test run just
sat there, spinning, forever, while every test passed fine on its own. The stale
copy was answering a question about the job format and never coming back.

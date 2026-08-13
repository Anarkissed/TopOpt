# 2026-08-14 — separating the TO from the lattice, and a wizard you can see

Evidence: `evidence/2026-08-14-lattice-separation/`
Branch base: `9e96beb` (the merge of PR 329)

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
group; the "Struts" toggle; the per-region readout (depth · held · grams · cell ·
density · strut · regime flag); the lattice density shading on the part surface;
and the Design Box and Paint chips are hidden on the lattice stage for the mirror
reason. One button remains, top right, **green**, one word: **Lattice**.

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
literally the same code; backlog L3's "the buttons feel different" cannot recur,
because there is no second set of buttons.

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

## §8 — NOT BUILT, ON INSTRUCTION

Face splitting, grid splitting and union are deferred. Nothing here builds toward
them and nothing here is designed around them.

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
| **R8** no verdict moves | **MET, structurally: `core/` is untouched.** `git diff --stat 9e96beb -- core/` is empty; every change is under `app/`. Core ctest reported below. |
| **R9** never weaken an assertion | **MET.** `r9_assertion_census.txt` — every kind unchanged or up, nothing deleted. Two source-reading tests were UPDATED where a symbol was renamed, and both were STRENGTHENED in the same edit (the page-hiding census gained the two new overlays; the design-box census gained the lattice-stage term). |
| **R10** no unfilled placeholders, no scratch at root | **MET.** |

**The suites.** App: **1456 executed, 22 skipped, 3 failures** — all three are
`AppModelTests.test*ThreeMF*`, and they fail because THIS MACHINE's core slice
has no lib3mf ("3MF import requires lib3mf, which is not available in this
build"). They failed identically on this branch's first run before any source
edit. I provisioned lib3mf to close the gap and the test bundle then failed to
LINK with undefined `_lib3mf_*` — the known worktree trap — so I reverted to the
3MF-free slice, which is three visible refusals instead of a bundle that will not
build. **CI provisions lib3mf and runs the same `swift test`, so report this as
1453/1456 local against CI's own denominator.**

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

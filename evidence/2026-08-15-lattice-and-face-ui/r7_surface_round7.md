# Round 7 — the 2026-08-16 list, and what each item actually was

Measured, not asserted. Every claim below has a test named beside it.

## 1. Off-model taps selected faces — and they were not random

`pick(at:in:)` did `pickFaceID(…) ?? FacePicker.pick(…)`. `pickFaceID` returned
`FaceID?`, which collapses "the id pass ran and that pixel is empty" into "the id
pass could not run" — so a tap on the floor fell through to the CPU picker.

That picker casts a **world-space** ray at **model-space** vertices. Once gravity
settles the part, the geometry the ray meets is the part in its ORIGINAL pose. A
tap to the lower right passes clean through the un-rotated part and names the face
it crossed — the same wrong face every time from the same pixel.

* `MeshRenderer.FaceIDPass` names the three outcomes; `.background` is a MISS.
* the `.unavailable` fallback now casts the same model-space ray as the hit point.
* `OffModelTapTests` — a world ray and a model ray name DIFFERENT faces on a
  settled part (the mechanism), and a ray past the mesh returns nil.

## 2. Union would not toggle off

`SurfaceUnion.toggle` always removed a re-tapped piece. What kept it lit is that
every tap also set `surfaceSelected`, and the tint lights a SELECTED region as well
as the picked ones. Toggled out of the union, the piece went on glowing — as a
selection. The union branch now clears the selection: in union, the picks ARE it.

* `UnionToggleTests`.

## 3. Switching tool now arms on the selection

The tray button threw the selection away, so the switch was a dead end. `surfaceEngage`
is now the one place a tool decides what to do with a piece, called by both the tap
and the switch. `ToolCarriesSelectionTests` pins the model half — a cut piece and a
union both still name their faces.

## 4. The wireframe reflects cuts and unions

Two halves, both missing:

* a CUT adds its trace — worked, but the renderer's diff key was `extraLines.count`.
  A cut that MOVES a boundary rather than adding one changes every coordinate and
  the count not at all, so the buffer was never re-uploaded. Hashed now. This is the
  same cheap-key trap `VertexTintKey` already cost this branch a session.
* a UNION must REMOVE the B-rep edge between the faces it combined. It did not, at
  all. `SurfaceWireframe.edges(of:welded:)` drops an edge when every face touching
  it is inside one union; the outer rim survives.

`LiveWireframeTests`, with the negative control (a union of ONE face removes nothing).

Also deleted: `surfaceCutRibbon`. It widened each segment in the plane of a single
face normal, which collapses to nothing wherever a curve turns edge-on — the stray
gold ticks on the maintainer's curved face. The wide-line pipeline widens in screen
space and has no such blind direction.

## 5. Wireframe + x-ray on the Topology page

`WorkspaceStageVisibility.wireframe` is a PERMISSION now (which stages offer the
control); the toggle state is shared, so the view mode persists across stages. The
lattice stage stays false on its own merits — it draws a lattice preview, not the
imported B-rep. `ViewModeStageTests`.

## 6. The pattern — rebuilt on the arc

Five division rules had been tried and each reported as still uneven. The division
was never the broken part. Two other things were:

1. **a divider is a PLANE, and a plane cuts a curved strip more than once.** A third
   of the way along a U it passes through the far arm too, so "the middle third" was
   two disconnected patches and its divider drew in two or three places.
2. **the lateral box built to contain that did not partition.** Oriented off a world
   axis, padded by `halfWidth*2 + extent*0.25`, so neighbours overlapped by a
   quarter of their length. A cell holding no surface was routine — that is
   "Smallest piece: 0 voxels, floor 16" and the dead checkmark.

The maintainer's own suggestion fixes (1) exactly: fit the circle, and every divider
becomes a plane hinged on its AXIS. Spokes on a wheel cannot reach the far arm — it
is at a different angle — so the wedges tile with no fencing at all.

Departures from the brief, both measured:

* **placed by ARC LENGTH, not equal degrees.** On a circle these are identical
  (s = Rθ). They come apart on straight-bend-straight — his own part — where the
  arms contribute no turn, so equal degrees puts every divider inside the bend.
* **`sweepDegrees` is the angle subtended at the CENTRE, not the tangent turn.** A U
  turns 180° by tangent and subtends ~310°; only the second divides it.

Measured on `uStrip`:

| columns | area shares |
|---|---|
| 2 | 0.50 / 0.50 |
| 3 | 0.33 / 0.33 / 0.33 |
| 6 | sixths |

Triangles in two cells: **0** (was 23 at three columns, 96 at six). Triangles in no
cell: **0**.

Three defects found while building it, each by a test:

* **the end cells were left open.** A wedge bound is a half-space, so an unbounded
  end cell claims a full 180°; at a 320° sweep the first and last overlapped by 107°.
* **the axis was re-derived from `cross(first, last)`.** That cannot tell 303° from
  −57°, so on a hook the axis flipped, the angle ran backwards, and the U fell
  through to the straight construction that cannot cut it.
* **integrated tangents read curvature off a saw-tooth.** A walked spine hops
  between the two triangles of each quad strip; on a dead straight tapered wedge
  that integrated to 23° of turn and a centre 93 mm off the part. Fixed by averaging
  the spine into equal-arc windows AND testing the BOW — how far the strip departs
  from its own chord — which a wiggle that returns to the line cannot fake. Measured:
  wedge 0.3% of its length, a 120° arc 24%, a hook 45%.

And it refuses what a plane cannot do, in words: two 175° wedges are the same plane
facing opposite ways and enclose nothing, so `"175° per piece is too wide to cut
with a plane — use 3 or more"` — and a test checks the count it suggests works.

`SurfacePatternArcTests` (23), `SurfaceGridExactnessTests`, `SurfaceCurvedPatternTests`.

## 7. An isolated piece could not be deselected on the TO page

A group holds BOTH a `faces` list and a `regionIDs` list. `handleTopologyPiecePick`
only handled a face with CUT pieces; an isolate has no cuts, so the ordinary face
route ran and toggled `faces` while the REGION carried on covering exactly those
faces. The group still contained them, by its other membership.

Now: any face a region covers is tapped by that region, and dropping a region drops
its resolved faces with it. `IsolateReachesTopologyTests` pins both halves.

The isolate also had no visible result — the tool stayed on `similar` and kept
lighting its MATCHES. It now drops to `select` with the new region selected, plus a
toast naming the count.

## 8. Save on the Surface page

`SurfaceScratch` captures regions AND group membership on entry; leaving without
saving restores both. Restoring one without the other would reinstate the old
regions under new ownership — a state neither before nor after.

Save is a new BASELINE, not a write: the edits were always live. `SurfaceScratchTests`.

## 9. A cut that detaches a scrap makes it its own piece

`splitManual` makes two children, one per side of the plane — right for the PLANE,
wrong for the SURFACE. Cut a U across its opening and one side holds the two arm
tips, which do not touch.

`SurfaceComponents` walks each child's triangles by shared-edge adjacency, and gives
each patch the parent's cuts plus one separating plane per sibling. Every candidate
split is **verified** — each piece must hold all of its own patch and none of anyone
else's — and where no plane separates, nothing is split at all. That refusal is the
point: an almost-separating plane is the same defect class as the pattern tool's old
lateral box.

`DetachedPieceTests`, with the negative control (an ordinary cut through a strip
splits nothing further).

## Suite

`swift test`: **1712 tests, 22 skipped, 8 failures** — all 8 the known lib3mf gap in
`AppModelTests` (3 tests), unchanged from the baseline. Other tasks' evidence
restored after the run.

## Not verified by me

Nothing here is verified on device. The build is on the iPad Pro 13-inch simulator.

---

# Round 7b — the device findings, measured on HIS part

## The arc: root-caused on M2_verticalStand, not on a test shape

The pattern passed every synthetic strip I built and still failed on his screen.
So I pulled `M2_verticalStand.step` out of the simulator's container and ran the
real thing. Face 4 — the fillet band round the inside of the hook, the blue strip
in his screenshots:

| columns | before | after |
|---|---|---|
| 2 | 88 / 11 | 49 / 50 |
| 3 | 52 / 47 / **0** | 32 / 33 / 34 |
| 4 | 34 / 54 / 11 / **0** | 24 / 25 / 25 / 25 |
| 6 | 16/36/36/11/**0**/**0** | 15/16/16/16/16/17 |

Face 17, the same kind of band on the other side: 35 / 64 / **0** → 33 / 32 / 33.

**The zero is the whole report.** "Smallest piece: 0 voxels, floor 16" is a piece
holding no surface; "I set 3 columns and there is only 1 cut in between" is the
divider next to it having nothing to separate.

### Cause

`SurfacePatternAxis.grid` short-circuited any `frame.cylindrical` face straight to
the old even-angle sector split, never reaching the arc system. My comment for that
line read *"a cylindrical frame is already an angular parametrisation, exactly what
the arc system derives — nothing to fit."* It is an angular parametrisation about
the axis the SURFACE is swept around; for a fillet band that is across its width,
not along its length.

★ **No shape I would have invented could have caught this.** Every strip in
`SurfacePatternArcTests` is a bare triangle mesh with no analytic surface, so none
of them ever took that branch. His part is now checked in as a fixture and swept
face-by-face in `RealPartPatternTests`.

### Two more, found by sweeping every face rather than by reasoning

* **face 61** still produced an empty piece at 4 columns — its walked spine doubles
  back, so two boundaries landed together. `SurfacePatternArc.cells` now VERIFIES
  every piece holds surface and refuses when one does not; `grid` then retries with
  the second centreline. The two centrelines fail on different faces, so trying both
  rescues both.
* **a refusal recommended what it had just refused** — face 3 asked for two and was
  told "use 2 or more".

Final state on his part: **no face refused at 2, 3 or 4 columns except one** — face
65, which is 24 mm long and genuinely cannot hold four pieces. That refusal is
recorded exactly in the test, so a regression in either direction shows up.

### Known limitation, measured and recorded

Broad plates (faces 15, 2, 3 — the big curved side walls) divide 22/42/34 rather
than thirds. Their walked spine is a corner-to-corner diagonal, so equal steps along
it are not equal division. I built a second centreline for them (`centroidSpine`,
the swept area-weighted centroid) expecting it to win, and measured:

| face | ratio | walked | swept |
|---|---|---|---|
| 4 | 0.02 | 32/33/34 | — |
| 16 | 0.06 | 33/33/33 | 33/33/33 |
| 15 | 0.17 | 22/42/34 | 23/37/38 |
| 2 | 0.13 | 19/47/33 | 26/35/38 |
| 3 | 0.19 | 16/44/38 | **61/21/16** |

It is far worse on face 3, where a slab crosses the face twice. So the walk stays
primary and the sweep is the fallback only. Not a refusal, not a zero — imperfect,
recorded, and better than every alternative measured.

## Isolate stands alone

He isolated a face, saved, went back, and the piece was still part of its old
group — and tapping its neighbour lit it too.

`commitSurfaceIsolate` disconnected the faces at the REGION layer and then **added
the new region to the very group those faces came from**, and left the bare faces in
that group's face list as well. Self-contradictory: "disconnect from everything it
is connected with", followed by connecting it to something.

Now: the faces leave every group, the region joins none, and the piece stands alone —
selectable on the Topology page, ready to be given to a group by a tap.

## Save at full stature

`WorkspaceStage.surface.forward` is now empty — the greyed-out "Lattice" button is
gone (it needed an anchor and a load, which are set on the Topology page, so it was
permanently disabled) and Save has that slot at `PageChrome.actionButton` height,
with a second line saying what leaving would cost.

## Suite

`swift test`: **1719 tests, 22 skipped, 8 failures** — all 8 the known lib3mf gap.

---

# Round 7c — the isolated face was being swept up by a LOOP

"I select-similar'd the same curved face, saved, and went back to the TO page. I
couldn't select the face. I selected the face next to it, and it was automatically
selected with it … it should be its own isolated face."

## Isolating had worked, and was overruled one layer down

`FaceTopology.loop(fromFace:)` implements "tap inside a bore and get the whole
tube": from a CURVED face it walks every connected curved face and returns them all.
It is pure geometry and has never heard of regions.

His isolated band is curved and touches curved neighbours. So tapping ANY of them
walked straight through it and selected it too — whatever the region layer said.
Round 7b's fix (an isolate joins no group) was correct and simply never got a say.

## The fix, and where it belongs

`FaceTopology` stays geometry. What a face BELONGS to is layer 2, so layer 2 gets a
veto over what the walk proposes:

    ProjectModel.surfaceLoopRespectingRegions(_ loop:from:)

A loop member is kept only if it is covered by the SAME regions as the tapped face.
Consequences, all of them wanted:

* a piece made its own is never dragged in by a neighbour;
* an isolate of SEVERAL faces still selects together — they share their region;
* a face in no region still loops with other faces in no region, so bores and
  blends behave exactly as before.

Applied at all three call sites that grow a selection from a loop (TO page, lattice
page, lattice library).

`LoopStopsAtIsolatedPieceTests`, three tests including the control that the walk
really does take all three faces when no region objects — without it the veto test
would pass on a mesh whose faces were never adjacent, which is exactly what my first
attempt did.

## Suite

`swift test`: **1722 tests, 22 skipped, 8 failures** — all 8 the known lib3mf gap.

---

# Round 7d — `nil == nil`, and a frame that is not the glass

## The isolated piece could not be picked up: two optionals compared

`handleTopologyPiecePick` asked

    owner?.id == selection.activeGroupID

meaning "is this piece already in the group I am building?" — and on a miss it
would move the piece into the active group.

An ISOLATED piece belongs to no group, so `owner` is nil. On a page where nothing
has been selected yet, `activeGroupID` is nil too. **`nil == nil` is true.** So the
tap took the "already mine — drop it and stop" branch and did precisely nothing,
every time, for the one kind of piece that is unowned by design.

Round 7c had removed the reason it was wrongly SELECTED; this is why it could never
be selected on purpose. Two different defects with one symptom between them.

The rule is now a value type, `TopologyPieceTap.route(owner:active:)`, because the
whole rule is two optionals compared and that is exactly where it went wrong. Five
tests, one per combination of owned/unowned × active/none.

## The top-right buttons sat ~10 pt high

The gizmo's frame is `gizmoSize` (210) square. The frosted housing a user actually
sees is `GizmoLayout.housingFraction` = 0.90 of that, CENTRED — so there is a
transparent margin of `(1 − 0.90) / 2 ≈ 10.5 pt` all round.

Every top-right control padded down by `gizmoInset`, exactly as the gizmo's FRAME
does. Correct arithmetic against the wrong edge: their tops lined up with an
invisible frame edge and sat 10.5 pt above the glass beside them.

`PageChrome.gizmoAlignedTop` = `gizmoInset + gizmoVisualInset`, DERIVED from the
housing fraction so it cannot drift, and used by all four: the stage-nav column, the
stage-nav placement modifier, Lattice Settings, and Save.

## Suite

`swift test`: **1729 tests, 22 skipped, 8 failures** — all 8 the known lib3mf gap.

---

# Round 7e — the selection was real and invisible

"It's showing as something was selected — but it won't show the highlight … the
'load/anchor…' is not close to the actual face."

Both symptoms, and a third he had not hit yet, are the same cause from the other
side of the one this branch keeps meeting: **a group has two memberships and the
places that read it were reading one.**

| reader | read | consequence |
|---|---|---|
| `roleTints` | `g.faces` | the face never tinted — selected and grey |
| `groupCentroidModel` | `g.faces` | no centroid, so the role chips fell to a default position |
| `groupNormalModel` | `g.faces` | a load arrow on such a group had no direction |
| `anchorFlowPoints` | `g.faces` | an anchor held as a region would rasterise to nothing |
| three empty-group sweeps | `faces.isEmpty` | the group was DELETED as empty on the next sweep |

The last one had not been reported yet and would have been the next report: a
region-held group survived only until anything triggered a cleanup.

## Fixes

* `groupTintedFaces(_:)` — "every face this group contains, by either membership",
  asked once and used by the tint, the centroid, the normal and the anchor set.
* `SelectionGroup.isEmptySelection` — `faces.isEmpty && regionIDs.isEmpty`, one
  definition replacing five inline `faces.isEmpty` tests. Two of the five already
  checked both; three did not, which is exactly how it drifts.

`RegionHeldGroupTests`, including the control that a group with NEITHER membership
is still dropped — otherwise the fix just leaks empty rows.

## Suite

`swift test`: **1732 tests, 22 skipped, 8 failures** — all 8 the known lib3mf gap.

---

# Round 7f — select-similar becomes a selection, and a frozen face explained

## 1. The ✓ is gone

It made a filter-defined UNION of every match — one row, one role, one depth. A
real operation, still available from the Regions sheet, and the wrong FIRST answer
to "these faces are alike": it welds them together when the point of selecting them
is to get at them. Removed rather than left as a second confusing verb beside ✂.

## 2. Select-similar multi-selects KINDS

`SurfaceSimilar` holds a list of RULES, never their matches — PR 331 measured what
storing matches costs (a 24-face union grew to 32 after a CAD edit). Tap a face and
its kind joins; tap a face ALREADY COVERED and that kind leaves.

★ The toggle keys on COVERAGE, not on the seed. Keying on the seed would leave every
other face of a kind unable to switch that kind off — you would have to remember
which face you originally tapped.

## 3. A tool picked after select-similar acts on the whole selection

The matched set is captured before the switch clears it (`surfaceCarried`), and:

* **union** — every match becomes a pick; confirm makes them one piece;
* **cut** — every face is cut through ITS OWN centre at the same angle;
* **pattern** — the same grid on each face, in each face's own frame; a face the
  grid does not fit is skipped rather than failing the batch.

## 4. ✂ splits by connectivity

"If they are *not* directly attached to one another, they should separate into
isolated pieces … However, if multi-select connects the pieces, then they are all
made into a single face group." That is exactly connectivity, and it is the rule a
CUT already follows (`SurfaceComponents`).

★ **Adjacency had to be re-derived on POSITION.** `FaceTopology.adjacency` keys an
edge on vertex INDEX, which is right for a welded mesh and finds NOTHING on an
unwelded one — and a tessellated STEP part is usually written with each face
carrying its own copies of the shared corners. `SurfaceWireframe.edges` already
documents this for the same reason. Keyed on index, every isolate on such an import
would shatter into one piece per face. Caught by the test mesh being unwelded, which
was luck; it is now the documented reason for `SurfaceComponents.faceAdjacency`.

## 5. The frozen face

"I attempted to cut out one of the faces … it didn't disconnect it. Instead, it made
it not be able to be de-selectable/re-selectable."

A group holds REGIONS, and a region that has been cut is represented by its
CHILDREN. So a group holding the PARENT contains every child implicitly. Removing
one child from the group therefore changed **nothing** — the parent went on speaking
for it — and adding it back changed nothing either. Frozen, in both directions.

`ProjectModel.surfaceDetachPiece(_:from:)` makes the implicit explicit exactly when
it stops being true: the ancestor is replaced by the pieces it stands for, and then
the one piece can leave. Its SIBLINGS stay, which is why the ancestor is expanded
rather than dropped.

`DetachPieceFromGroupTests` pins both states — the frozen one (as a demonstration of
the mechanism) and the fixed one.

## Suite

`swift test`: **1740 tests, 22 skipped, 8 failures** — all 8 the known lib3mf gap.

---

# Round 7g — the views on every stage, and off by default

"Please add the wireframe and xray view in the Lattice stage. I also don't want the
wireframe view to be the default. Please turn off all views by default."

* `WorkspaceStageVisibility.wireframe` is now true on all three stages. It was false
  on the lattice stage for a stated reason — that stage can show a lattice PREVIEW
  rather than the imported B-rep, so the edge set would describe a surface it is not
  drawing. The reason was real but small: the stage shows the part itself most of the
  time, and where it does not, `SurfaceWireframe.edges` finds no face partition and
  draws nothing rather than nonsense. Withholding a view control on a maybe is the
  worse trade.
* `surfaceWireframeOn` defaults to FALSE (x-ray already did). A view aid is something
  you reach for, not the resting state of a page.

## ★ AND ONE THING THAT WOULD HAVE BROKEN QUIETLY

The pattern PREVIEW reaches the renderer through the wireframe's line channel, and
both it and `showWireframe` were gated on the same toggle. Turning the default off
would therefore have left the pattern tool aiming at a grid nobody could see — the
view toggle would have become a silent prerequisite for a TOOL.

So the preview is no longer gated on the toggle, and `showWireframe` opens whenever
there are preview lines to draw. The wireframe is a view; the preview is the thing
being decided.

## Suite

`swift test`: **1739 tests, 22 skipped, 8 failures** — all 8 the known lib3mf gap.
(One test fewer than 7f: two stage-visibility tests collapsed into one that loops
over `WorkspaceStage.allCases`, so a fourth stage could not be added without it.)

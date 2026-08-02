# The smoothing page: the brush works, and it is a page now

**Slug:** `smoothing-page-round2` · **Branch:** `claude/smoothing-brush-mesh-mismatch-6b4ccf`
· started from `main` at `ce4e181` (PR 285, `design-box-lattice-recert`).
**Evidence:** `evidence/2026-08-03-smoothing-page-round2/`

Round 1 (`2026-08-02-smoothing-page`, PR 279) shipped a page that on the
maintainer's device **could not be used at all**, drawn on top of a live TO
workspace. Both are fixed. The blocker first.

---

# PART 1 — THE BRUSH

## S1 — the two meshes, named and measured

On device the page said:

> The protected-surface map describes a different mesh (17496 vertices vs
> 105060) — refusing to paint rather than guess which vertices it means.

**The refusal was correct and the mask was never wrong.** It described a
different mesh, and there genuinely were two.

| | what produced it | vertices |
|---|---|---|
| **the mesh being PAINTED** | `MeshExport.parseBinarySTL` — [`MeshExport.swift:106`](../../app/TopOptKit/Sources/TopOptFlows/MeshExport.swift#L106), fed by `RemoteRunner.fetchMesh` into `OptimizeVariant.meshVertices` at [`RemoteRunner.swift:1312`](../../app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift#L1312) | **3 × triangles** |
| **the mesh being MASKED** | `import_any` → `topopt::import_part_file` → `weld_and_clean` (weld by exact coordinate), called from `smooth_freeze_mask` at [`bridge.cpp:1359`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp#L1359) | **≈ triangles / 2** |

`parseBinarySTL`'s own doc comment states the cause in the file:
*"each triangle its own three vertices — STL shares none"*. A binary STL body has
no shared vertices; topology only exists after a reader welds. Core's reader
welds. The app's does not.

`3F : F/2 = 6`.

**Measured**, not inferred — `core/tests/harness/smooth_mesh_identity_probe.cpp`
on the maintainer's own `WallMount_ShelfBracket.stl` at their own resolution 64:

```
A-remote  MeshExport.parseBinarySTL (soup)         121548
A-local   bridge to_optimize_variant (MC)           20248
B         import_part_file (welded)                 20248
ratio A-remote : B = 6.0030
```

Their screen read 105060 : 17496 = **6.0048**. And the probe's freeze tolerance
comes out at **2.43 mm**, the number their panel printed verbatim.

### The finding that explains why this shipped

**The on-device path was never broken.** Marching cubes already welds shared
edges ([`mesh.cpp:509`](../../core/src/mesh/mesh.cpp#L509)), so the bridge's own
variant mesh agrees with core's **on count AND index-for-index on order**:

| app mesh | same count | same order |
|---|---|---|
| A-remote (LAN worker) | NO | NO |
| A-local (on device) | **YES** | **YES** |

So the defect is **remote-only** — and remote is the *only* path that can reach
this page, because PR 274's retained job document (which AE3 requires) is written
by the CLI and not by the on-device bridge. Every path that could open the page
was the broken one; every path that worked could not open it. That is why round 1
passed 31 tests and was still 100 % unusable in the maintainer's hands.

## S2 — one mesh, by construction

**The fix is not a remap.** Reconciling two meshes is exactly the "guess which
vertices it means" the guard exists to refuse.

The page now has one mesh, and it is **core's own import of the one file the page
writes**. That file was already the input to the freeze mask, to the smoother and
to both certification columns — the app was the only participant holding
something else. Dropping its copy leaves nothing to reconcile.

`openSmoothingPage` writes the STL, then:

```swift
pageMesh = try SmoothPageMesh.imported(from: inPath) { path in
    let m = try TopOptKit.importMesh(path: path)
    return (m.vertices, m.indices)
}
```

and from there the stage, the brush, the context and the mask request all come
from `pageMesh`. Nothing reads `v.meshVertices` after the export.

### What makes it structural rather than a habit

`SmoothPageMesh.swift` — three seams, each removing a way to name a second mesh:

1. **`imported(from:by:)`** takes a **path**. There is no production route from
   an in-memory buffer.
2. **`freezeMaskRequest(modelPath:loadCase:)`** fills `meshPath` in from
   `self.path`. The caller supplies the load case and nothing else.
   `SmoothFreezeMaskRequest`'s initialiser is `fileprivate`, so **asking core
   about a different file is not a thing this API can express.**
3. **`brush(freeze:)`** builds the `SmoothBrushModel` from this mesh's own
   indices and count, and stamps this mesh's path on it.

Asserted behaviourally *and* by reading `openSmoothingPage`'s whole body for the
absence of `v.meshVertices` / `v.meshIndices` after the export — and for the
absence of any `remap` / `nearestVertex` / `matchVertices` / `resample` step.

> **Honest limit.** `SmoothPageMesh` keeps a public memberwise initialiser,
> because bar S3's test must be able to build a deliberately mismatched pair. The
> enforcement is therefore: the type names the invariant, the two derivation
> seams cannot express a violation, production has exactly one construction site,
> and a source-reading test pins that. It is not a compiler proof.

A mesh core cannot read is now its own named refusal, `SmoothUnavailable
.meshUnreadable(String)`, carrying core's own words and checked **before** every
other verdict — the others would all be about a mesh that was never read.

It is the one refusal the *entry gate* cannot reach, since it is only knowable
after writing the file and asking core to read it back. So it lands on the page's
own `gateOverlay` — the full-screen card that already exists for exactly this —
rather than a toast that scrolls away.

## S3 — the guard stays, and got sharper

Unchanged: a count mismatch still refuses, in the same words the device showed.
`SmoothingPageRound2Tests` feeds a 240-vertex soup brush a 40-vertex mask and
asserts the refusal, that no stroke takes, that `vertexWeights()` is all zero,
and that nothing is tinted.

**Added, because the S1 measurement demanded it.** The on-device path matched
core on *count*. A count-only guard therefore has a silent failure mode: a
same-size mesh from a *different* variant would pass it and paint the wrong
vertices. So `SmoothFreezeMask` now carries the **file** core computed it from,
`SmoothBrushModel` carries the file it is painting, and `meshesAgree` compares
both:

> The protected-surface map was computed for a different file (…) — the vertex
> counts match, but matching counts are not the same vertices, so this refuses
> rather than guess.

An empty path on either side means "not stated" and does not fail the check, so
every pre-round-2 caller keeps its exact previous verdict.

**Three layers, and the third is not new.** PR 279 already put a length check in
C++ where the weights are actually consumed
([`bridge.cpp:1433`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp#L1433)):
*"refusing rather than weighting the wrong vertices"*. Round 2 adds a test that
it stays, because an app-side fix must not become a reason to let the last line
of defence rot.

## S4 — AE1 holds at its original strength

`core/tests/validation/test_smooth_brush.cpp`, untouched, on PR 200's own
specimen. Identical numbers to PR 279:

```
frozen bore = 228 verts
strength  pairs  frozen_changed  moved  max_shift(mm)
 0.10       20         0          4116    0.0119
 ...
 1.00       20         0          4116    0.7489
54 checks, 0 failures
```

`frozen_changed` by `std::memcmp` on the raw `Vec3` doubles.

The app half is asserted on the mesh that is **actually painted**: for every
strength, with *every* triangle painted including frozen corners, a frozen
vertex's weight is `+0.0` **compared by bit pattern** — PR 279's own reason
(`−0.0 + 0.0 = +0.0` flips a sign bit, which `==` misses and memcmp catches).

---

# PART 2 — IT IS A PAGE NOW

## L1 — the mechanical reason it was an overlay

Round 1 gave the page **no brush tools of its own**. Paint on/off, the eraser and
the disc size all lived in the TO page's paint drawer, and `handleBrush` read
`paintActive` / `paintErasing` / `brushRadiusPoints` from it.

**So the chrome could not be hidden without disarming the page's own brush.**
L1 and L4 are one change, not two: the tools had to move first.

`SmoothBrushTools` (paint / erase / **orbit**, plus the disc size) is now a value
type on the page's panel. Orbit is not a nicety — the brush claims the one-finger
drag, so without it the page would have no single-finger orbit at all.

Then the gates. Round 1's problem was not that it forgot one condition; it was
that there were **eight separate `!showLatticePage` conditions** and a third page
had to remember to add itself to each. There is now **one** predicate:

```swift
private var fullScreenPageUp: Bool { showLatticePage || showSmoothingPage }
```

Gone while a page is up: `chrome`, `bottomBar`, `bottomRightControls` (Paint,
Fast·64³, Minimize plastic, Design Box + Reset / Add keep-out), `selectionsPanel`,
`latticeEntryButtonOverlay`, `latticePreviewOverlay`, `loadOverlays`,
`seeResultsChip`, `designGizmoOverlay`, `primitiveGizmoOverlay`,
`clearanceHandlesOverlay`, `arrowsOverlay`, the gravity trio, and the red
clearance volumes. **A fourth page is now hidden correctly by default.**

Protected regions are still **indicated** — better than before, in fact: the
brush tints the actual frozen *vertices* of the mesh being painted, so what the
brush will refuse is visible on the surface itself rather than as a red box
floating near it.

### One deliberate reversal of round 1

Round 1 read AE6 ("one selection model, never a second UX") as licence to mount
the shared `selectionsPanel` **editor** over the page. L1 says protected regions
may be indicated but **not editable**, and L1 is right for a reason round 1
missed: **the brush's freeze mask is computed FROM those selections.** Editing an
anchor or a keep-clear volume mid-stroke leaves every stroke on screen measured
against a mask that no longer describes the part, and the page cannot react.

The row is now a read-only readout of the same one model. **AE6 is not weakened —
it is more strongly asserted:** the page mounts no panel at all, there is still
exactly one `selectionsPanel` definition in the app, and the page still holds no
selection state. The one assertion I changed is called out in
`SmoothingPageTests` with the reasoning inline.

## L2 — the gizmo, on the third ask

This is the third time the maintainer has asked for gizmo invariance. Both
earlier answers were local: round-3 lattice feedback got it **removed** from the
lattice page (its Metal-backed glass composited over that page's pure-SwiftUI
chrome, so RUN SIM rendered behind it), and round 1 of this page drew it from a
**second `if` site**. "The same corner on every page" was a claim about two pages
out of three.

It is now mounted **once, last in the ZStack, above every page**, gated on
nothing but having a mesh. That placement is what fixed the lattice page's
compositing bug in the first place — the answer to "it draws on top" is to put it
genuinely on top, not to hide it. Each page insets its own top-right column by
`PageChrome.gizmoClearance`.

Round 1's AE7 asserted the literal string
`showSmoothingPage, viewerMesh != nil { orientationGizmo }` — which was satisfied
*while the gizmo was hidden on the lattice page*. It now asserts the structure:
one definition, one placement, and that the placement mentions neither page flag.

## L3 — the simulation button is bottom right

The lattice page's **RUN SIM** was top-right, in the gizmo's corner. It moved to
the bottom-right cluster with that page's other actions — where the smoothing
page's `Re-certify` and the TO page's `Optimize` already are. That is what freed
the corner for L2, so L2 and L3 are also one change. What is left in the lattice
page's top-right is the gate's *reason*, a caption rather than a control, inset
past the gizmo.

## L4 — all brush tools, one modal, left

`toolsSection` at the top of the page's panel: a three-way mode segment, a size
stepper, and Clear strokes. `frame(height: PageChrome.compactButton)`,
`HStack(spacing: PageChrome.gap)` — PR 260's L1 spacing token, asserted equal to
`LatticeChromeLayout.gap`.

## L5 — no overlaps, either orientation

The three the maintainer saw were all workspace chrome bleeding through, so L1
fixes them. Two more things make it structural:

* **Two full-screen pages can never both be up.** `openLatticePage` clears
  `showSmoothingPage` and vice versa. (This is also what lets a `showLatticePage`
  gate be read as "and therefore not the smoothing page".)
* `testNoPageChromeLandsUnderThePositionGizmo` computes the gizmo's rect and each
  page's regions **from the `PageChrome` tokens** and asserts non-intersection at
  1194×834 and 834×1194 — including the portrait panel against the bottom cluster.

## L6 — asserted by what is HIDDEN

Round 1's AE7 passed while the page was an overlay because it only asserted what
the page **positions**. `testWhileAPageIsUpTheWorkspaceDrawsNoChromeOfItsOwn`
asserts what the workspace **hides**: it walks `body`'s brace structure — with
multi-line `if` conditions folded first — and requires every one of the fifteen
named chrome placements to sit inside a guard that makes it unreachable while the
smoothing page is up.

**I verified the test is load-bearing rather than vacuous.** Regressing one gate
back to `if !showLatticePage { bottomBar }` fails it; deleting the gate entirely
fails it through the brace scan specifically. Both restored after.

---

## Bars

### S6 — no regression

| suite | result |
|---|---|
| `SmoothingPageRound2Tests` (new) | 21 tests, **0 failures** |
| `SmoothingPageTests` (PR 279's own) | 31 tests, **0 failures** |
| `SmoothingModelTests` (PR 200) | 11 tests, **0 failures** |
| `LatticeVariantTests` (PR 274) | 16 tests, **0 failures** |
| `LatticeSDFAlignmentTests` (PR 251) | 7 tests, 1 skipped, **0 failures** |
| `LatticePageRound2Tests` | 15 tests, **0 failures** |
| `LatticePageTests` | 25 tests, **0 failures** |
| `SelectionModelTests` | 18 tests, **0 failures** |

**App package, whole thing: 1131 tests, 13 skipped, 10 failures.** All 10 are
pre-existing — confirmed by re-running them on a stashed (clean) tree, where they
fail identically:

* 8 in 3 `AppModelTests` 3MF tests — this worktree carries no `lib3mf-lib`, and
  the refusal says so verbatim (the documented worktree gap);
* 2 in `VariantEntryGatingTests.testTheAppBlockExistsBecauseTheCoreRefusalDoes` —
  it reads core for a lattice/design-box refusal string that PR 285 removed.

Neither is touched by this task.

**Core `ctest` on the full suite: 100 % passed, 98 of 98** (1259 s wall).
`test_smooth` (PR 200's own S1–S6 byte-identity guard) and `test_smooth_brush`
(PR 279's AE1) are both unchanged and both green; the new identity probe is
`EXCLUDE_FROM_ALL` and adds no ctest entry, so the suite count is unmoved.

### S7 — determinism

Nothing new is randomised. The page mesh is `import_part_file`, whose weld is an
**ordered** map over the input triangle list — the file's own comment says
*"no hash iteration order, so vertex numbering is a pure function of the input
triangle list"*. The identity probe reproduces the same three counts on every run.

### S5 — reachable and usable end to end

**Reported honestly: I ran the pipeline, not the iPad.** I cannot drive the
device's UI from here, and I have not seen the page on a screen.

What is proven on the maintainer's own fixture, through the shipped seams:

* the mask now has **one entry per painted vertex** — 20248 : 20248, where round
  1 had 20248 : 121548 (probe output above), so the brush is armed rather than
  refused;
* every action bar was disabled *by* `brush.canPaint`, and it is now true on this
  path — `testTheNormalPathNoLongerTripsTheGuard`;
* the tools that make painting possible are on the page and no longer depend on
  chrome that is now hidden;
* AE1's frozen-vertex bar holds unchanged at every strength.

**What I have NOT verified: the on-device run.** The receipt's own numbers under
a brush — S5's "re-certify, see before/after" — are PR 279's measurement
(`smooth_brush_probe`, AE4: worst-case 3.3968 → 2.8240, −16.9 %, verdict
ACCEPT→REJECT→ACCEPT across six strengths) and this task did not change the
certification seam, so those numbers stand. But *this* branch has not been built
onto a device and driven by hand. **That is the one bar I am reporting as
unverified rather than met.**

---

## What changed, file by file

**Core**

* `core/tests/harness/smooth_mesh_identity_probe.cpp` — new; the S1 measurement.
* `core/CMakeLists.txt` — its `EXCLUDE_FROM_ALL` target.

**App**

* `SmoothPageMesh.swift` — new; the page's one mesh and the two seams that cannot
  name another.
* `SmoothBrush.swift` — `SmoothBrushTools`; `meshPath` on the mask and the brush;
  `meshesAgree` and the second refusal message.
* `SmoothingVariantSession.swift` — the context carries a `SmoothPageMesh` and
  derives its buffers from it; `freezeMaskRequest`; `.meshUnreadable`.
* `SmoothingPageModel.swift` — `libraryOpen` removed.
* `SmoothingPage.swift` — `toolsSection`; the protected row is read-only.
* `WorkspacePlaceholder.swift` — the page mesh at `openSmoothingPage`;
  `fullScreenPageUp`; `brushGestureActive`; one gizmo placement; page exclusivity.
* `LatticePage.swift` — RUN SIM to the bottom cluster; top-right cleared and
  inset past the gizmo.
* `SmoothingPageTests.swift` — the byte-window source reader replaced with a real
  declaration-body reader; AE7's gizmo assertion strengthened; AE6's mount
  assertion inverted with the reasoning inline.
* `SmoothingPageRound2Tests.swift` — new; 21 tests.

## Not done, and why

* **The remote soup is not welded at its source.** `MeshExport.parseBinarySTL`
  still produces a triangle soup, and `OptimizeVariant.meshVertices` still holds
  it on a LAN run. Welding there would change the mesh every viewer, exporter and
  mass calculation in the app reads — far past this PR, and it would need its own
  byte-identity evidence. The smoothing page no longer *cares*, because it reads
  core's import. **But any future feature that indexes per-vertex data against a
  variant's buffer will hit this same 6:1, and there is now a named type to
  reach for.** Worth its own task.
* **The receipt's per-region attribution** (round 1's own "what the measurements
  say is worth doing next") is untouched.

---

## In plain language

Last time you opened the smoothing page and it told you it was refusing to paint,
because the map of which surfaces are protected described a mesh with 17,496
corners while the shape on your screen had 105,060. Then every button was greyed
out. The page was, in practice, a picture of a page.

**The message was true and the map was fine.** There really were two different
copies of your part, and they disagreed by almost exactly six times.

Here is why. When your Mac worker finishes a variant, it sends the shape back as
an STL file. STL is a dumb format: it lists triangles, and it writes out all three
corners of every triangle separately, so a corner shared by six triangles gets
written six times. The app read that file literally and kept all the duplicates —
105,060 corners. The engine that works out which surfaces are protected read the
same shape and did the sensible thing first: it noticed the duplicates and merged
them back into 17,496 real corners. Two copies of one part, six-to-one, and a map
of one of them being held up against the other.

Six is not a coincidence — it is what that arithmetic gives you, and I measured it
on your own bracket at your own settings: 6.0030 against the 6.0048 on your screen.
The probe even lands on "within 2.43 mm", the exact tolerance your panel printed.

**The thing that explains why this ever shipped**: when a run happens on the iPad
itself, there is no STL file in the middle and no duplicates, so the two copies
agree perfectly. The bug only exists on Mac-worker runs. And Mac-worker runs are
the *only* ones that can open the smoothing page at all, because on-device runs
don't save the paperwork the page needs to re-certify against. So every route that
could reach the page was broken, and every route that worked couldn't get there.

**The fix is not to translate between the two copies.** Guessing which corner
means which is precisely what the refusal existed to prevent, and I would rather
it kept refusing than start guessing. Instead the page now stops keeping its own
copy. It writes the file once, then asks the engine to read it back, and *that* is
the shape it draws, the shape you brush, and the shape it maps. Everything is
looking at the same thing because everything is reading the same file. There is
nothing left to reconcile.

The refusal stays, and it got a bit sharper. It used to compare only the number of
corners — but I measured a case where two different shapes have the same number,
which would have let it paint the wrong thing quietly. That is worse than refusing.
So it now checks *which file* the map was made from as well.

**On the page being an overlay.** You were right, and the reason turned out to be
mechanical rather than sloppy: the page had no brush controls of its own. The
paint on/off switch, the eraser and the brush size all lived in the toolbar
underneath. Hiding that toolbar would have left you with a brush you couldn't
turn on. So the tools moved onto the page first — paint, erase, orbit, and a size
control — and then the whole workspace behind it could go: the Design Box panel,
Reset and Add keep-out, Paint, Fast·64³, Minimize plastic, Plate up, Gravity set,
the Group A/B list, the red keep-out boxes and the design-box wireframe. Just the
part and the brush now.

Protected areas are still visible, and better than before: instead of red boxes
floating near the part, the corners the brush won't touch are tinted on the
surface itself, so you can see what it will refuse before you try. What you *can't*
do any more is edit them from this page — because the protection map was worked
out from those very settings, and changing one mid-brush would leave your strokes
measured against a map that no longer matched.

**The position cube.** You have asked for this three times. Both previous answers
were half-answers: once it got deleted from the lattice page, once it got drawn
from a second bit of code just for the smoothing page. It is now drawn from one
place, on top of everything, on all three pages. To make room for it on the lattice
page, RUN SIM moved down to the bottom-right with that page's other buttons —
which is also where Re-certify and Optimize already live, so the "run it" button
is in the same corner everywhere now.

I also made it impossible for two full-screen pages to be open at once, which was
behind several of the overlaps you saw.

**One thing I want to be straight about.** I have proven all of this through the
code and on your own bracket file — the map now has exactly one entry per corner
of the shape being painted, the brush is armed instead of refused, the protected
corners still can't move at any brush strength, 98 of 98 core tests pass and the
app suite has no new failures. **But I have not run this build on an actual iPad
and painted with my own hands.** I can't from here. So "the page works end to end
on a device" is the one claim I'm reporting as untested rather than proven, and
it's the first thing worth checking.

# The smoothing viewer never showed the smoothed mesh, and the page was unusable

**Slug:** `smoothing-viewer-and-ui` · **Branch:** `claude/smoothing-viewer-mesh-bug-0ee4b0`
· started from `main` at `a70bca0`.
**Evidence:** `evidence/2026-08-04-smoothing-viewer-and-ui/`

Two things, and only one of them was a defect in the physics path. The viewer bug
first, because it is the one that made the receipt look like a lie.

---

# PART 1 — THE BRUSH WORKS, THE VIEWER DID NOT

## V1 — the smoothed mesh was produced, returned, and bound. It was never uploaded.

**Answer: none of (a), (b) or (c) as stated.** The smoothed mesh is produced
(core writes it), returned (the bridge runner imports it back), and bound to the
Smoothed view (`stageMesh` returns it). Every seam the task asked about is
correct. The break is one step further down, in the RENDERER.

`MetalMeshView` re-uploads its GPU buffers only when a signature changes, and
that signature was:

```swift
// MetalMeshView.swift:456, as shipped
private func meshSignature(_ mesh: ViewerMesh) -> [Float] {
    [Float(mesh.vertexCount), Float(mesh.triangleCount),
     mesh.bounds.min.x, mesh.bounds.min.y, mesh.bounds.min.z,
     mesh.bounds.max.x, mesh.bounds.max.y, mesh.bounds.max.z]
}
```

compared at [`MetalMeshView.swift:2436`](../../app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift#L2436).

**Taubin smoothing cannot move any component of that tuple.** It preserves the
welded topology exactly — same vertices, same triangles — and a LOCAL brush moves
only the painted patch, so the bounding box is decided by vertices that never
moved. The comparison found no change, took its early-out, and the GPU went on
drawing the buffer it already had. Original and Smoothed rendered identically
because the renderer had exactly one mesh.

### The measurement

`core/tests/harness/smooth_viewer_identity_probe.cpp`, on the maintainer's own
`WallMount_ShelfBracket.stl`, through the shipped `constrained_taubin_smooth`
with the min-feature constraint enforced exactly as the bridge invokes it. The
subject is a marching-cubes iso-surface of the part's own voxelization — the kind
of surface an optimizer variant has, and the only kind the page ever opens on.

```
patch       str painted  moved maxshift   cnt+bounds content      mesh dmass voxel dmass
corner     0.25    1692   1692   0.4320   differs   differs       +0.035941   +0.000000
corner     0.50    1692   1692   0.6221   differs   differs       +0.070855   +0.000000
corner     1.00    1692   1692   0.8314   differs   differs       +0.140012   +0.000000
interior   0.25      23     23   0.3986   IDENTICAL differs       -0.000000   +0.000000
interior   0.50      23     23   0.5378   IDENTICAL differs       +0.000000   +0.000000
interior   1.00      23     23   0.5927   IDENTICAL differs       +0.000000   +0.000000
```

**The shipped signature is not merely weak — it is CONDITIONAL.** It separated
the two meshes only when the painted patch happened to contain the part's own
bounding-box extreme. Brush a corner and the viewer updates; brush the middle of
the part, which is what a brush is for, and it shows nothing. That is why this
survived round 1 and round 2: any test that painted broadly enough would pass.

### The fix

`ViewerMeshSignature`
([`ViewerMesh.swift:293`](../../app/TopOptKit/Sources/TopOptFlows/ViewerMesh.swift#L293))
— FNV-1a over the float32 bit patterns of every position, then every index, plus
the two counts. Computed ONCE in `ViewerMesh.init`
([`ViewerMesh.swift:392`](../../app/TopOptKit/Sources/TopOptFlows/ViewerMesh.swift#L392)),
so the renderer's per-update-pass comparison stays a scalar compare however large
the mesh is. `meshSignature` now returns it and mentions neither the bounds nor
the counts.

Deliberately **not** Swift's `Hasher`, whose seed is randomised per process: the
same mesh would sign differently on every launch, which is the opposite of what a
cache key needs. Asserted by value AND by reading the source for the absence of
`Hasher(` and the presence of the fixed FNV prime.

**This is not a smoothing-page fix.** Any viewer swap whose vertices move without
changing counts or bounds hit this — a re-solved variant at the same resolution,
a re-imported mesh, a repaired mesh. It is fixed for all of them.

## V2 — the tell was real, the inference was not

**Mesh mass is NOT computed from the original mesh, so this is not a second
instance of the same defect.** `analyze_loadcase` derives it from whatever mesh it
analysed ([`bridge.cpp:1300`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp#L1300)),
and the smoothed pass calls it on `smoothed_out_path`
([`bridge.cpp:1485`](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp#L1485)).
The probe reproduces bridge.cpp's own sum verbatim and watches the column move —
245.650462 → 245.790474 g on the corner patch at strength 1.00. A number computed
from the original would have been constant down that whole column. It is not.

**What makes it move so little is Taubin itself.** The λ|μ pair is
volume-preserving by construction — that is the entire reason core uses it instead
of a plain Laplacian, which would collapse the part. The smoother's own receipt
already says so: *"Volume drift 0.06% (Taubin bound over the brushed range
0.56%)"*. So the enclosed volume genuinely barely changes, while the VOXEL mass
moves freely because re-voxelization is a step function and a surface crossing a
voxel centre flips the whole voxel.

**What was wrong is the reporting.** Both mass rows printed at ONE decimal, so a
real change under 0.05 g rendered as the same string — and an unchanged string is
not something a reader can tell apart from an unchanged shape. That is exactly the
inference the maintainer drew, and it was a reasonable one.

`SmoothReceipt.massDecimals = 3`
([`SmoothingPageModel.swift`](../../app/TopOptKit/Sources/TopOptFlows/SmoothingPageModel.swift)),
named rather than inlined so the two rows cannot drift and a future edit cannot
quietly round the change away again. On the maintainer's own numbers the row now
reads **182.640 g → 182.601 g** instead of "182.6 → 182.6" (see
`page_receipt_drawer_landscape.png`).

**Reported honestly:** a volume-preserving smoothing that genuinely does not move
the enclosed volume still prints an unchanged mass, and it should —
`testAVolumePreservingSmoothingHonestlyReportsNoMassChange` pins that, because
manufacturing a difference there would be the real dishonesty.

## V3 — the tests, and they are load-bearing

`SmoothingViewerTests` — **12 tests, 0 failures.**

Every assertion that the new signature separates two meshes is PAIRED with the
demonstration that the old tuple did not, on the same data:

```swift
XCTAssertNotEqual(originalMesh.signature, smoothedMesh.signature,
                  "V3/B1: the viewer must re-upload — this is the bar")
XCTAssertEqual(shippedSignature(originalMesh), shippedSignature(smoothedMesh),
               "and the shipped signature would NOT have, on this very "
               + "data — the test is load-bearing, not decorative")
```

so the negative control travels with the fix instead of being a claim about it.
The fixture is a slab whose interior vertex moves inward — not contrived to defeat
the old signature, but the shape of what the probe measured on the real part.

Driven through the shipping seam: `recertify` → `currentGeometry`
([`SmoothingPageModel.swift:755`](../../app/TopOptKit/Sources/TopOptFlows/SmoothingPageModel.swift#L755)),
the ONE property the host builds `smoothedVariantMesh` from and `stageMesh`
reads. Plus a source read that `meshSignature` resolves to `mesh.signature`, no
longer mentions `bounds`, and is still what `updateUIView` compares — a better
signature that the renderer ignores would be this repo's "built, never invoked"
failure for the sixth time.

Mesh mass: `testReportedMeshMassChangesWithTheSmoothedShape` uses the maintainer's
own magnitudes (a sub-0.05 g move on a ~182 g part) and asserts the row's two
strings DIFFER — with the load-bearing half asserting that at one decimal they are
the same string.

---

# PART 2 — THE PAGE

## U1 — the regions are gone, and the model is the interface

No region list, no per-region row, no strength slider. Asserted by name:
`regionsSection`, `regionRow`, `BRUSH REGIONS`, `brush.setStrength`,
`brush.addRegion`, `brush.removeRegion`, `Slider(` — none of them appear in
`SmoothingPage.swift`.

**Where strength comes from now.** With the slider gone there is exactly one input
left, so brushing an area AGAIN deepens it — one rung per stroke, capped, the way
every sculpting tool behaves — and the tint darkens to match. `SmoothBrushModel
.levels = [0.25, 0.50, 0.75, 1.00]`.

**ONE STROKE, ONE RUNG.** A drag emits a sample every few points over the same
triangles, so without a stroke boundary a single swipe would run straight to the
top rung and the brush would have exactly one strength again.
`beginStroke`/`endStroke` bound it, driven from the gesture's own `.began`/`.ended`
phases.

**The tint moves in two channels, not one:** more opaque AND darker in value with
each rung, because an opacity difference alone disappears over a light patch of
the model. One hue, not a palette — a rainbow encodes WHICH region, and there is
no list left to match a colour back to.

**The region model is KEPT internally**, one region per rung, created on first
use. That is not a leftover: `vertexWeights`, `maxStrength`, `normalizedWeights`
and the receipt's own region lines are all written against regions and are
unchanged by this — which is how bar B2 passes through code this task did not
touch.

## U2 — the left modal is brush controls, and nothing else

Paint/erase, the size, Pencil only, Clear strokes. The pane's whole body is
`toolsSection`; `sellCard`, `protectedSection`, `receiptCard` and `regionsSection`
are gone from it.

**The footprint is the real one.** The disc is drawn at `radiusPoints * 2`, in the
same screen points `BrushHitTest` is given — asserted against the hit-test call
site, so it is a preview of the brush rather than a decoration beside a number.

### Pencil only, and the one assertion I moved

Round 2's `SmoothBrushTools` had a third mode, `.orbit`, and an assertion whose
stated reason was: *"orbit releases the one-finger drag — without it the page would
have no single-finger orbit at all."* The maintainer's instruction is the opposite
shape: he should never have to reach for a mode to turn the part around.

`pencilOnly` provides the same guarantee without a mode to switch: with it on a
finger drag never paints and a pencil always does. **The invariant is unchanged
and the coverage is wider** — it used to be checked for one input kind and is now
checked for both, and the reasoning is inline in `SmoothingPageRound2Tests` at the
assertion itself, following round 2's own precedent for its AE6 reversal. With
`pencilOnly` off, round 2's behaviour is unchanged: one finger paints, two orbit.

**It is honoured by the gesture layer, not just the value type.** Two pan
recognizers with DISJOINT `allowedTouchTypes` — a pencil drag can only drive the
pencil recognizer and a finger only the finger one — so "which contact was this?"
is a fact rather than an inference from touch counts, which could never have
answered it (a pencil is always exactly one contact). When the brush belongs to
the pencil, the finger pan skips the paint branch and falls through to the
ordinary camera gestures; that fall-through IS the single-finger orbit.

## U3 — the buttons

Discard and Lattice this on the row ABOVE Re-certify, asserted by source order.
**"Keep smoothing" is deleted.**

Deleting it required moving what it did, not dropping it. Its only real job was
gating "Lattice this" on there being a current verdict, so a successful
re-certification now keeps, and the gate reads the receipt. `keep` still refuses
without a current, non-stale receipt, so a non-convergent or failed
re-certification keeps nothing and the lattice stays blocked —
`testANonConvergentRecertificationKeepsNothingAndBlocksTheLattice` pins that.
AE8's guarantee is unchanged; only the second press is gone.

`SmoothPageActions.keep` left the type with the button. The assertion that iterated
it — "every disabled action states its reason" — is unchanged and now covers every
action that exists.

## U4 — the receipt is a drawer

Above Re-certify, in the same bottom-right column, closed at rest. It opens over
the page's own dead space rather than over the model or the brush panel.

## U5 — one note, and it is the same rule as the lattice page

This is the maintainer's THIRD ask for transient top-centre notes. The first two
answers were local, so this page had nothing to inherit and had invented three
overlapping notices instead: a status banner, a failure banner under it, and an
in-panel warning card.

`PageTransientNote` and `PageNoteBox` now live in `PageChrome.swift` with the rest
of the shared page geometry, and `LatticeTransientNote` is an **alias** — so the
lattice page and its tests are untouched while there is literally one definition.
`testTheNoteRuleIsSharedWithTheLatticePage` asserts the two types are identical
and that the lattice page's own copy is gone.

**Two cannot appear, structurally.** `SmoothingPageModel.topNote` is a single
optional value with a precedence (failure > transient > working), so a view has
nothing to render twice. **At rest it is nil** — nothing stands on this page when
nothing is happening, which is bar U6 expressed as a state rather than a promise
about layout. The re-certification outcome is posted as a transient note: it is
news, and news stops being news.

**Auto-dismissing**, 60 s ceiling, dismissible by tap, same constant as the
lattice page.

### Never behind anything — and this is where I found a second overlap

`PageChrome.noteTop` puts the note BELOW the identity rows rather than at
`topInset`. A note centred in the full width and pinned to the top row shares that
row with the top-left identity stack and the top-right tabs; on a landscape iPad
the three just fit with about 17 pt to spare, and on a PORTRAIT one (1024 pt wide
against a 620 pt note) they do not — the note lands on top of both. The first
portrait capture shows it. Dropping the note below those rows makes the clearance
a property of the layout rather than of how wide the screen happens to be.

`PageChrome.noteWidth(for:cap:)` then caps it clear of the 210 pt position gizmo,
which binds in portrait and not in landscape. Both derived from tokens, so a
different gizmo size cannot silently reintroduce either overlap.

**And a third, from the same captures.** `PageChrome.panelBottomClearance` was
`edge + actionButton + gap` — a ONE-row action cluster. U3 made this page's
cluster two rows, so in portrait the brush panel ran underneath Discard and
Lattice this. It is now `panelBottomClearance(actionRows:)`, the page states its
own row count, and the one-row value is unchanged for the lattice page. A
clearance derived from one page's current button count stops being a clearance
the moment another page adds a button, and it fails silently.

## U6 — cut the text

One dismissible notice on entry — *"You cannot smooth protected areas."* with an
OK — and then nothing standing. Gone: `WHAT THIS BUYS YOU`, the frozen-vertex
counts, the "fixed for this variant" paragraph, `protectedProvenance`, and the
"Nothing smoothed yet — both show the variant as the run made it" sentence (the
Smoothed tab is simply disabled until there is one, which is what a disabled
control says by itself).

**The protected-areas INDICATION is not gone, only the readout.** Round 2's own
reasoning for that panel row was that *"the strongest indication is not this text:
it is the FROZEN TINT the brush paints onto the actual vertices"* — so the row was
always the weaker half, and it is the half the maintainer counted as text. The
tint is untouched, and the round-2 assertion now checks the tint plus the one
dismissible sentence.

## U7 — the counts

**The rule**, applied identically to both revisions by
`evidence/2026-08-04-smoothing-viewer-and-ui/count_standing.py`: standing prose is
the total character count of the string literals inside every `Text(...)` that
renders at rest, each declaration multiplied by how many times it actually appears
(three mode tabs, four action buttons, and so on). Characters rather than `Text(`
occurrences, because a five-line paragraph is ONE `Text(` and it is the five lines
being counted.

| | round 2 | round 3 |
|---|---|---|
| standing prose, at rest | **998 ch** (~17 lines) | **184 ch** (~3 lines) |
| controls at rest | 11 | 11 |
| standing prose, after one stroke | **1225 ch** (~20 lines) | **184 ch** (unchanged) |
| controls, after one stroke | 13 | 11 |

The after-one-stroke row is the one that matters: a stroke used to add a region
row with a name, a triangle count, a slider, a strength readout and up to two
explanatory lines, without limit. **A stroke now adds nothing**, because the tint
on the model is the readout. Asserted by the absence of `regionRow` entirely.

**Controls did not drop, and I am not claiming they did.** Two went (the Orbit
tab, the add-region "+"), two arrived (Pencil only, the receipt drawer's handle),
and one action button was deleted while the receipt toggle took its place. The
maintainer asked for the number, so the number is the one that is there.

**PR 260's L1 spacing token** is asserted equal to `LatticeChromeLayout.gap`, along
with `edge` and the cluster height, and the rebuilt panel is checked for
`PageChrome.gap` and `PageChrome.compactButton` — the panel was rebuilt from
scratch, which is exactly where a page reinvents its own spacing.

---

## Bars

| bar | result |
|---|---|
| **B1** viewer shows the smoothed shape, on the shipping path | MET — `SmoothingViewerTests`, 12/12, with the old signature as a paired negative control |
| **B2** no regression in what the brush protects | MET — see below |
| **B3** the note rule is asserted | MET — one at a time, top-centre, clear of the panel/tabs/gizmo in both orientations, ≤60 s |
| **B4** layout parity, no overlaps, both orientations | MET — and it found THREE real overlaps, all fixed |
| **B5** app + core suites | see below |
| **B6** determinism | MET — see below |

### B2 — AE1 holds, through the new entry point

PR 279's AE1 is repeated on `brush(_:triangles:)` rather than on
`paint(_:triangles:into:)`: at every rung, with every triangle painted including
frozen corners, a frozen vertex's weight is `+0.0` **compared by bit pattern** —
PR 279's own reason (`−0.0 + 0.0 = +0.0` flips a sign bit, which `==` misses and
memcmp catches). Also through `normalizedWeights()`. A fully-frozen triangle is
still refused outright, and the frozen tint still wins at every rung.

Core's own `test_smooth_brush` (AE1 proper, `std::memcmp` on the raw `Vec3`
doubles) is **untouched** and green.

### B5 — the counts

| suite | result |
|---|---|
| `SmoothingViewerTests` (new) | **12 tests, 0 failures** |
| `SmoothingRound3Tests` (new) | **27 tests, 0 failures** |
| `SmoothingPageRound2Tests` (PR 286's) | 21 tests, **0 failures** |
| `SmoothingPageTests` (PR 279's) | 32 tests, **0 failures** |
| `SmoothingModelTests` (PR 200's) | 11 tests, **0 failures** |
| `SmoothingRungStalenessTests` | 4 tests, **0 failures** |
| `ViewerTests` | 33 tests, **0 failures** |
| `LatticePageTests` / `LatticePageRound2Tests` | 25 / 15 tests, **0 failures** |

**App package, whole thing: 1221 tests, 14 skipped, 8 failures.** All 8 are
pre-existing and are the documented worktree gap: three `AppModelTests` 3MF tests,
whose refusal says so verbatim — *"3MF import requires lib3mf, which is not
available in this build"* — and `app/TopOptKit/vendor/` carries no lib3mf. Round 2
reported 10 failures on this suite; the other 2 (`VariantEntryGatingTests`) were
fixed by PR 285 in the meantime. **No new failures.**

**Core `ctest` on the full suite: 100 % passed, 106 of 106** (1697 s wall).
`smooth` (PR 200's S1–S6 byte-identity guard), `smooth_brush` (PR 279's AE1
proper, `std::memcmp` on the raw `Vec3` doubles) and `smooth_recert_loadcase` all
passed and are **unchanged by this task**. The new probe is `EXCLUDE_FROM_ALL` and
adds no ctest entry, so the suite count is unmoved.

**The iOS-only code is compiled, which `app-macos` does not do.** The pencil
recognizer, `allowedTouchTypes` and `UITouch.TouchType` all live behind
`#if os(iOS)`, so `swift test` on macOS never typechecks them. `xcodebuild -sdk
iphonesimulator` builds `TopOptFlows` for arm64 AND x86_64, and
`handlePencilPan` is present in the resulting `MetalMeshView.o` (`nm`). The app
TARGET fails to link in this worktree with *"no such module 'TopOptFlows'"* — I
checked that against a stashed clean tree and it fails identically, so it is a
pre-existing worktree gap and not this change.

### B6 — determinism

* The signature is FNV-1a with a fixed basis, a fixed prime and a fixed traversal
  order — no hashing container, no process-seeded hasher. Asserted by value and by
  a source read for the absence of `Hasher(`/`hashValue`.
* The strength ladder is driven by paint order, which is deterministic; regions are
  created in ascending rung order on first use.
* `smooth_viewer_identity_probe` run twice: **byte-identical output** apart from
  the evidence path it was told to write to.
* `SmoothingViewerTests` + `SmoothingRound3Tests` run twice: 12/12 and 26/26 both
  times.

---

## What changed, file by file

**Core**

* `core/tests/harness/smooth_viewer_identity_probe.cpp` — new; the V1/V2
  measurement.
* `core/CMakeLists.txt` — its `EXCLUDE_FROM_ALL` target.

**App — the viewer**

* `ViewerMesh.swift` — `ViewerMeshSignature`; `ViewerMesh.signature`, computed once
  in `init`.
* `MetalMeshView.swift` — `meshSignature` returns it; `appliedSignature` retyped;
  `BrushInput`; the pencil pan recognizer and the disjoint touch-type sets;
  `brushRequiresPencil`.

**App — the page**

* `SmoothBrush.swift` — `SmoothBrushTools.pencilOnly` / `Input` / `paints(from:)` /
  `fingerOrbits`, `.orbit` removed; the strength ladder (`levels`, `level(of:)`,
  `beginStroke`/`endStroke`, `brush(_:triangles:)`); one-hue darkening tint.
* `SmoothingPageModel.swift` — `massDecimals`; re-certification keeps; `topNote`;
  the note box; `receiptOpen`; the entry notice; `SmoothPageActions.keep` removed
  and `sendToLattice` re-gated on the receipt.
* `SmoothingPage.swift` — the panel cut to brush controls; the footprint disc;
  the pencil-only row; the two-row action cluster; the receipt drawer; the entry
  notice; one note renderer; the Smoothed tab disabled until there is one.
* `PageChrome.swift` — `PageTransientNote`, `PageNoteBox`, `receiptDrawerWidth`,
  `topRowsHeight`, `noteTop`, `noteWidth(for:cap:)`,
  `panelBottomClearance(actionRows:)`.
* `LatticePageModel.swift` — `LatticeTransientNote` is now an alias.
* `WorkspacePlaceholder.swift` — stroke boundaries and the contact-kind gate in
  `handleBrush`; `brushRequiresPencil` fed from the page's toggle; `onKeep` gone.

**Tests**

* `SmoothingViewerTests.swift` — new; 12 tests (V1/V2/V3).
* `SmoothingRound3Tests.swift` — new; 27 tests (U1–U7, B2, B3, B4).
* `SmoothingPageEvidenceGen.swift` — new; the B4 captures, opt-in.
* `SmoothingPageRound2Tests.swift` — the orbit assertion moved to `pencilOnly`
  (wider); the protected-regions assertion moved to the tint; the source window
  widened with the reason.
* `SmoothingPageTests.swift` — the lattice gate now reads the receipt, with a new
  test for the non-convergent half; the disabled-action loop covers the actions
  that exist.

## Not done, and why

* **I have not run this build on an iPad and painted with my own hands.** I cannot
  from here. Everything above is proven through the code, on the maintainer's own
  fixture, and in offscreen renders at exact iPad point sizes — but "it feels right
  under a real pencil" is the one claim I am reporting as untested. The pencil
  routing in particular is the part I would check first: the recognizer split is
  correct by construction and asserted by source read, but touch-type behaviour is
  the kind of thing a device surprises you about.
* **The remote soup is still not welded at its source** (round 2's own note).
  `MeshExport.parseBinarySTL` still produces a triangle soup on a LAN run. The
  smoothing page does not care, and now neither does the viewer's upload
  decision — but the underlying 6:1 is unchanged and still deserves its own task.
* **The receipt's per-region attribution** is untouched, and is now arguably moot:
  there are no user-facing regions to attribute to.

---

## In plain language

You painted, you pressed Re-certify, and the shape on your screen did not change.
Every number on the receipt moved except one — "mass (mesh) 182.6 g → 182.6 g" —
so you concluded the certification had solved a different shape from the one it
was showing you. That was a completely reasonable read, and I want to be clear
that the numbers were not lying to you: **the smoothing really did happen, and the
thing that got certified really was the smoothed shape.** What was broken was the
picture.

Here is the actual bug, and it is a small and stupid one.

Drawing a 3D shape on screen means uploading it to the graphics card. That is not
free, so the viewer keeps a little fingerprint of whatever it last uploaded and
skips the work if the new shape has the same fingerprint. The fingerprint was:
how many corners, how many triangles, and how big is the box the shape fits
inside.

Now think about what smoothing does. It does not add or remove any corners — it
just nudges the existing ones. So the corner count is identical and the triangle
count is identical. And when you brush a patch in the *middle* of the part, the
corners at the outer edges never move, so the box it fits inside is identical too.

All three numbers the same. The viewer concluded "same shape, nothing to do", and
kept showing you the one it already had. Both tabs showed the unsmoothed part
because the graphics card only ever had the unsmoothed part.

I measured it on your own bracket, and the detail that explains why this survived
two rounds of testing: **the bug depends on where you paint.** Brush a corner of
the part and the box does change, so the viewer updates and everything looks fine.
Brush the middle — which is the entire point of having a brush — and it shows
nothing. Any test that painted a big enough area would have passed.

The fix is that the fingerprint now actually reads the shape instead of measuring
its box. The tests I added prove the new fingerprint tells your two shapes apart
*and* prove the old one did not, on that same pair, so the fix comes with its own
proof rather than a promise.

**About that unchanged mass.** I checked whether it was a second copy of the same
mistake, and it is not. That number is computed from the smoothed file — I traced
it, and I watched it move when I measured it directly (245.650 → 245.790 grams).
It barely moves because of the *kind* of smoothing this uses. A naive smoother
shrinks a part every time you run it, a bit like sanding it; the one here is
specifically built to move the surface around without changing how much material
is enclosed. That is why it is safe to run repeatedly. So the enclosed volume
genuinely does stay almost the same — while the *voxel* mass moves a lot, because
that one counts whole blocks and a surface sliding past the middle of a block
flips the whole block.

The real problem was that the receipt printed both to one decimal place, so a
genuine change of a few hundredths of a gram came out as the same string. It now
prints three decimals, and on your numbers that row reads 182.640 → 182.601
instead of "no change". A number that can't show a change is worse than no number.

**On the page itself.** You were right that it was drowning. I counted it: about
17 lines of permanent explanatory text before you touch anything, growing to about
20 the moment you make a single stroke, because every stroke added a region row
with its own name, slider, counts and warnings. It is about 3 lines now, and a
stroke adds nothing at all.

Regions are gone from the screen entirely. Instead the part *is* the control:
brush an area and it tints, brush it again and the tint gets darker, and darker
means more smoothing. There is no list to read and no slider to set, because the
thing you are looking at already tells you.

The left panel now holds only brush things: paint or erase, the size — shown as an
actual circle the size the brush really is, not just a number — and a "Pencil
only" switch. That switch is my answer to never having to hunt for an Orbit mode:
turn it on and one finger always spins the model while the pencil always paints,
so the two never fight over the same gesture.

Discard and Lattice this now sit above Re-certify. "Keep smoothing" is deleted, as
you asked. It was doing one quiet job — making sure you cannot send an
uncertified shape to the lattice page — so I moved that job onto the certification
itself. Re-certifying now keeps. You cannot lattice something that failed to
certify, which was the only thing that button was really protecting.

The receipt is in a drawer above Re-certify. And there is exactly one note at a
time, centred at the top, gone within a minute — the same one you asked for on the
lattice page, except this time it is literally the same code rather than a third
copy of the idea. On entry you get one sentence, "You cannot smooth protected
areas", with an OK, and after that nothing is standing.

Two overlaps turned up while I was checking this in both orientations, and both
were real. In portrait the note was landing on top of the title bar and the
Original/Smoothed tabs, and the receipt drawer was opening straight into the
bottom panel. Both are fixed, and the fixes are computed from the layout rather
than nudged until they looked right, so a future change to the panel or the corner
cube can't quietly bring them back.

**One thing I have not done.** I have not built this onto an actual iPad and used
it. I can't from here. Everything is proven through the code, on your own bracket
file, and in rendered frames at exact iPad sizes — 1220 app tests with no new
failures — but the pencil behaviour in particular is the sort of thing a real
device can surprise you about, and that is the first thing I would check.

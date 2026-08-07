# smoothing-that-works-and-is-usable — a stroke no longer touches your view, and the operator question is settled: NO-GO

**Slug:** `smoothing-that-works-and-is-usable` · **Branch:** `claude/smoothing-page-reset-63aa19`
**Evidence:** `evidence/2026-08-08-smoothing-that-works-and-is-usable/`
**Changes:** `app/` and `core/`. CI: core-linux + app-macos. `materials.json` untouched.
**Required reading it builds on:** PR 299 (Taubin NO-GO), 303 (SDF), 306 (the bake-off), 307 (CAD projection + the classifier).

---

# 0. WHAT CHANGES FOR YOU

**One brush stroke no longer moves your view.** Your zoom, your pan, your angle and
the part's settled pose all survive a stroke, and they survive flipping between
Original and Smoothed. Measured on the fixture the moment before the fix: your
camera sat at **distance 0.9108709** with the target panned off centre, and one
stroke put it back to **distance 2.6155658** on the model centre — your exact
words, "the zoom/position back to the origin point", as a number. It is now
**bit-identical across a stroke**, asserted on the whole camera value.

**And a stroke is 12x faster.** On your own rung-068 variant — 143,862 vertices,
14.4 MB — the wait between letting go of the brush and the Smoothed side updating
was **819 ms**. It is now **69 ms**. The page had been re-reading that STL from
disk on every single stroke to rebuild vertices it was already holding and
drawing; the re-read was **95.3%** of the preview call.

**The part also stopped re-dropping onto the ground on every stroke.** That was
the second half of "resets the entire page": a full mesh upload resets the settle
rotation to identity and re-runs its 0.8 s animation. It now runs **once per
session** instead of once per stroke.

**You can see the smoothed shape without certifying.** The Smoothed tab was dead
until a certification solve had run — certification was being used as the
rendering path. PR 303 found that, named the one-line fix and deferred it. It is
taken (§S3d).

---

## ★ AND THE ANSWER TO THE OPERATOR QUESTION IS NO. THIS IS A SECOND NO-GO.

PR 306 measured mean-curvature flow removing **51.6%** of the stair-step
amplitude on an analytic sphere against the shipped smoother's 11.2% — 4.6x — and
stopped, correctly, because the classifier that separates your CAD from the
optimizer's cuts did not exist. PR 307 merged it. **I finished the measurement on
your own four rungs, and MCF does not reproduce that win on your part.**

| | Taubin (shipped) | mean-curvature flow |
|---|---|---|
| **on the CUT surface**, roughness (rms dihedral, rung 068) | 8.36° → **8.09°** (smoother) | 8.36° → **11.03°** (ROUGHER) |
| same, rung 026 | 9.00° → **8.18°** | 9.00° → **15.65°** |
| **on surface that HAS a correct answer**, amplitude removed (rung 068) | +2.5% / **+8.0%** | +4.2% / **−3.7%** / **−5.5%** |
| same, rung 026 | +1.9% / **+6.2%** | −0.3% / **−8.4%** / **−10.4%** |

**MCF makes your part's surface rougher at every setting, on every rung, and on
the only surface where "how much staircase was removed" has a truthful answer it
is worse than doing nothing at anything past 5 steps.** The BLOCKED-STOP in the
brief fires. **I built nothing on it** — no operator swap, no new brush wiring.

**And the brief predicted what that means: the answer is resolution, not
smoothing.** §S2.1 puts a number under it — see below.

**Two things that did work, and are worth keeping:**

* **C4 holds, bitwise.** Every vertex the classifier attributes to your CAD is
  frozen, for *both* operators, and comes out **byte-for-byte where it started** —
  0 violations on every row of every rung. Your bolt holes and flat faces cannot
  be touched by the brush by construction, not by policy.
* **No tendril thinned.** The minimum cross-section reads **104.6872 mm²** before
  and after on rung 068 and **84.3313 mm²** on the other three, in every row of
  both operators at every setting.

**Read §R3 before you read a margin next to a smoothed part.** The certificate
cannot see this class of change at all, and the page now says so.

---

# 1. S1 — ONE STROKE MUST NOT RESET THE PAGE

## S1(a) — THE CAMERA. Root cause, and why the fix is not "save and restore it"

**`MetalMeshView.swift`, `MeshRenderer.setMesh`, its last lines:**

```swift
buildIDBuffer();  buildTintBuffer(faceTint: [:], activeFaces: [])
camera.frame(mesh.bounds)                    // <- re-anchors target, re-fits distance
modelCenter = mesh.bounds.center
modelRotation = identity; settleFrom = identity; settleTo = identity
isSettling = false
buildGround()
```

`OrbitCamera.frame` sets `target`, `homeTarget`, `distance`, `minDistance` and
`maxDistance`. Every mesh swap went through `setMesh`, and the coordinator then
**persisted** the result — `DispatchQueue.main.async { model?.adopt(framed) }`
writes the reframed camera back into the shared `OrbitCameraModel`, so the reset
was not merely drawn once.

**That is why the symptom reads the way you described it.** Azimuth and elevation
*survived*, because the coordinator mirrors them onto the renderer immediately
before the swap (`renderer.camera = model.camera`). What did not survive was the
zoom and the pan — which is exactly "moving the zoom/position back to the origin
point", and not "the view spun".

**The brief offered two routes and asked which and why. I took the first —
update the vertex positions in place — and the reason is the rest of that block.**
Saving and restoring the camera around a `setMesh` call restores those five
numbers and leaves everything else: the settle rotation still snaps to identity
and re-animates for 0.8 s, the ground is rebuilt, the model centre jumps, and the
tint buffer is zeroed and rebuilt. You did not report a camera jump. You reported
the page resetting, and those are the rest of it. A stroke should touch the vertex
positions and nothing else, so the camera falls out of the fix rather than being
put back by hand — and a future caller who has never heard of the camera still
gets the right behaviour.

**The decision.** `ViewerMeshSignature` gains a `topologyHash` — FNV over the
indices *alone*, with the positions left out. `contentHash` already answers "is
this a different mesh?", which is all the upload cache needed. The camera has to
ask a narrower question, "is this the **same surface, moved**?", and connectivity
is exactly the part a stroke does not change. `MeshRenderer.applyMesh` routes a
same-surface swap to an in-place position upload and everything else to `setMesh`.

The id buffer **is** rebuilt on the in-place path — it carries the positions the
pick pass rasterizes, so a stale one would make the brush hit-test the shape from
before the stroke.

## S1(b) — THE DISK RE-READ

**`app/TopOptKit/Sources/TopOptBridge/bridge.cpp:1381`**, in `smooth_brush_preview`:

```cpp
topopt::TriangleMesh input = import_any(input_mesh_path);
```

A full STL parse of your 14.4 MB variant, on every settled stroke, to rebuild the
array the caller was already holding. The path came down from
`SmoothingPageModel.refreshPreview`, which passed `variantMeshPath` — a **path** —
even though the model owns `context.meshVertices`.

**The fix is the signature, not a cache.** `Previewer` now takes
`(vertices, indices, strength, weights)`. There is no longer a parameter through
which a file could be named, so the re-read cannot come back by someone re-wiring
a caller. `smooth_brush_preview_mesh` is the new bridge door; both doors share one
body (`smooth_brush_preview_impl`), so the preview a test takes and the preview
the page draws cannot drift.

**The live previewer also got a name.** It was an anonymous closure inside
`WorkspacePlaceholder.openSmoothingPage`, so nothing outside that function could
call it and every test of the preview ran against a stand-in the test wrote — and
a stand-in is the one thing that can never reproduce the real one's I/O. It is now
`SmoothingPageWiring.livePreviewer`, and the R2/R3 tests drive that value.

## S1(c) — THE FEEL, MEASURED

Your own rung 068: **14,386,084 bytes, 143,862 vertices / 287,720 triangles.**
Brush at strength 0.49 over every vertex. **RELEASE build — the configuration the
app ships**; the harness stamps which build it ran in, because a plain
`swift test` is DEBUG and puts the cost in a completely different place.

```
stage                                  repeats    ms/stroke
------------------------------------------------------------
A  preview via PATH   — STL re-import        5     ~795
A  preview via PATH   — smoothing            5      ~40
A  preview via PATH   — TOTAL                5     ~798
B  preview via MEMORY — STL re-import        5       0.0
B  preview via MEMORY — smoothing            5      ~39
B  preview via MEMORY — TOTAL                5      ~48
   ViewerMesh build (app side, both)         5      ~21
------------------------------------------------------------
stroke release -> updated preview, BEFORE:   ~819 ms
stroke release -> updated preview, AFTER :    ~69 ms
```

The exact run is `evidence/.../s1c_stroke_latency.txt`; the figures move a few per
cent between runs on this machine and the conclusion does not.

**And the end-to-end path, walked on that same variant** (`r3_usable_path.txt`):

```
HE SETS HIS VIEW: distance 181.5483, target (84.785, -28.061, 110.690)
  stroke 1 -> rung 1, 20403 vertices moved, max 0.2681 mm, preview 43 ms (import 0 ms), camera UNCHANGED
  stroke 2 -> rung 2, 20403 vertices moved, max 0.3715 mm, preview 49 ms (import 0 ms), camera UNCHANGED
  stroke 3 -> rung 3, 20403 vertices moved, max 0.4221 mm, preview 47 ms (import 0 ms), camera UNCHANGED
  toggled back to Original — camera UNCHANGED
  renderer holds the page's geometry; settle ran ONCE for the whole session
```

**The assertion is the deliverable, not the rewrite** — the camera equality is
checked on the whole `OrbitCamera` value (target, home target, distance, azimuth,
elevation, roll, fov and both zoom limits), not on a tolerance.

## S1(d) — WHAT ELSE `.ended` REBUILDS

You said "resets the entire page", so I audited the rest rather than stopping at
the camera.

**Fixed here:**

1. **The settle animation.** `setMesh` resets `modelRotation` to identity and the
   coordinator cleared `lastSettleVector`, so `beginSettle` ran again with its
   0.8 s animation — the part visibly re-dropped onto the ground on every stroke.
   Now **1 per session**, asserted by `settleBeginCount`, with a positive control
   that a genuinely new part still settles.
2. **The tint buffer.** `setMesh` zeroes and rebuilds it; the in-place path leaves
   it alone and the tint block re-uploads only when the tints actually change.
3. **The ground mesh and the model centre.** Rebuilt and re-derived per stroke;
   now untouched.

**Found, measured, NOT fixed — and named so they are not lost:**

4. **`smoothBrush.viewerTints()` is computed inside `WorkspacePlaceholder.body`,**
   so it is rebuilt on **every SwiftUI pass**, not only when the brush changes.
   On your mesh that is **863,160 entries, ~13 ms**, plus ~1 ms for the
   coordinator's element-by-element compare against the uploaded copy. It is not
   on the critical path measured above and it is not a "reset", but it is real
   work repeated for no reason. A `@State` cache keyed on the brush's own revision
   would remove it.
5. **The top-centre note flickers on every stroke.** `refreshPreview` sets
   `previewing = true` then `false`, and `topNote` is a precedence that returns
   `.working(statusLine)` while it is true — so a note appears and is replaced on
   every stroke release. Correct by the page's own rules, and still a flicker.
6. **The panel, the notes and the action column re-render** because
   `smoothedVariantMesh` is `@State` on `WorkspacePlaceholder`, whose body
   contains the whole smoothing overlay. SwiftUI diffs this cheaply and **no
   state is lost** — the drawer's open/closed flag lives on the model and
   `SmoothingPage`'s own `@State` survives, because the view's identity is stable.
   So this one is a re-*evaluation*, not a reset, and I am reporting it as such
   rather than "fixing" something that is not broken.

---

# 2. S2 — THE BAKE-OFF ON YOUR OWN PART. **NO-GO.**

New harness: `core/tests/harness/cut_population_probe.cpp`
(`./core/build/cut_population_probe <design.bin> <part.step> <evidence_dir>`),
run on your `design.bin` and `M2_verticalStand.step` from
`evidence/2026-08-03-multiscale-lattice-to`. Full output:
`evidence/.../s2_cut_population_probe.txt`, CSV in `s2_cut_population.csv`.

**PR 307's classifier, not a second one.** `attribute_to_cad_faces` with
`cad_project_options_for_grid(1.705279)`, exactly as PR 307 calls it.

## S2.0 — the split, on all four rungs

| rung | CAD-attributed | ambiguous | **optimizer-cut** |
|---|---|---|---|
| 0.68 | 113,123 (79.72%) | 3,596 (2.53%) | **25,175 (17.74%)** |
| 0.52 | 104,313 (72.25%) | 3,673 (2.54%) | **36,384 (25.20%)** |
| 0.38 | 96,475 (59.80%) | 3,748 (2.32%) | **61,097 (37.87%)** |
| 0.26 | 90,155 (55.81%) | 3,797 (2.35%) | **67,594 (41.84%)** |

Consistent with PR 307's 82.83% / 17.17% by vertex on rung 068. The small
difference is honest and worth stating: PR 307 measured the **shipped
`variant_068.stl`**; this probe re-extracts the mesh from `design.bin` so all four
rungs are produced identically, and the two extractions differ slightly in vertex
count (141,894 here vs 143,862 in the file).

## ★ S2.1 — WHY PR 299's METRIC COULD NOT BE CARRIED OVER VERBATIM

The brief asked for "PR 299's metric unchanged" on the cut population. **PR 299's
metric is the distance to the ORIGINAL CAD SURFACE**, and its entire justification
is that the CAD is the smooth surface the staircase is an error against — "it has
a floor at 0 that no cheat reaches".

**On the cut population that reference does not exist.** Those vertices are
surface the optimizer cut; the CAD says nothing about where they should be, and
driving their distance-to-CAD down would mean pulling your structure toward the
CAD, which is damage. So rather than substitute a metric quietly, the probe
**measures the claim**:

```
factor 2: 141894 verts   factor 4: 567698 verts
the shipped surface deviates from the finer one by:
    all vertices   max 0.3479 mm  rms 0.0095 mm  (0.6% of a voxel)
    CUT vertices   max 0.3479 mm  rms 0.0083 mm  (0.5% of a voxel)
```

Same on all four rungs (rms 0.0083–0.0100 mm). **Read against the staircase
itself, which PR 299 measured at rms 0.3424 mm = 21% of a voxel:** extracting the
same field twice as finely moves the surface by about **1/40th** of the staircase's
own amplitude. The staircase is in the **field**, not in the tessellation — so no
finer extraction of that field is a reference for it, and PR 303 §S1.6's result
("16x the count, deviation flat") reproduces on the cut population specifically.

**This is the measured form of the brief's own prediction that the answer is
resolution.** Not a finer *mesh* — a finer *grid*, solved.

So the cut-population table reports what can be known without a ground truth, with
the controls that make PR 299's objection to intrinsic roughness ("melting the part
also reduces it") inapplicable: **motion is bounded by C1 at half a cell, volume is
held by C3, and every tendril's minimum cross-section is measured geometrically.**
A dihedral reduction bought by melting shows up in those three columns.

## S2.2 — THE TABLE, rung 068 (all four in the evidence)

```
operator            iters   wall_s   cutmax   cutrms  cutmoved  cadmoved   dihed_b  dihed_a    vol%   minsec_mm2
as exported             0    0.000   0.0000   0.0000         0         0      8.36     8.36   0.000     104.6872
Taubin_pairs_20        20    0.036   0.5093   0.1234     24218         0      8.36     8.30  -0.004     104.6872
Taubin_pairs_160      160    0.117   0.7595   0.1866     25175         0      8.36     8.09  -0.032     104.6872
MCF_x5                  5    0.050   0.6047   0.1368     25175         0      8.36    10.99   0.000     104.6872
MCF_x20                20    0.140   0.6826   0.2124     25175         0      8.36    11.03   0.000     104.6872
MCF_x40                40    0.262   0.6774   0.2286     25175         0      8.36    10.69   0.000     104.6872
```

**MCF raises the roughness at every setting, on every rung** — worst on the
sparsest rung, 9.00° → 15.65°. Taubin lowers it slightly. This is the same
*sign* PR 306 measured on the sphere (14.53° → 26.32°); the difference is that on
the sphere there was a truth to move toward, so the trade was worth making. **Here
there is no truth on this population and the only reading available says MCF is
worse.**

## S2.3 — THE CALIBRATED ARM, where the question does have an answer

With C4 **off**, on the CAD population, PR 299's metric verbatim. This is not a
proposal to run either operator there — PR 307's projection owns that surface and
is exact — it is the calibration that keeps §S2.2 honest.

```
rung 068                                        rung 026
operator          cad_rms_mm  removed%          cad_rms_mm  removed%
as exported          0.3270      0.0%              0.3698      0.0%
Taubin_pairs_20      0.3187      2.5%              0.3628      1.9%
Taubin_pairs_160     0.3009      8.0%              0.3469      6.2%
MCF_x5               0.3134      4.2%              0.3711     -0.3%
MCF_x20              0.3392     -3.7%              0.4009     -8.4%
MCF_x40              0.3448     -5.5%              0.4081    -10.4%
```

**MCF's sphere result does not transfer.** The mechanism is not mysterious: a
sphere is all smooth curvature, and mean-curvature flow moves toward it. Your part
is planes, cylinders and sharp CAD edges, and curvature flow rounds a sharp edge
off — which *raises* the deviation. Taubin's best-anywhere on your part is 8.0%,
close to PR 299's 10.6% on a different bracket.

## S2.4 — C4, AND THE CONSTRAINTS

**(b) C4 — CAD FACES MUST NOT MOVE. Asserted, not assumed, and bitwise.** Every
CAD-attributed vertex — plus every `ambiguous` one, folded in on the safe side —
is frozen. MCF takes it through `TrustSign::Pinned`; Taubin through
`vertex_weight = 0`, its own copy-verbatim branch. One classifier, each operator's
own mechanism. **`cadmoved` reads 0 on every row of every rung**, compared with
`memcmp`, and the CAD deviation is unchanged to four decimal places on all five
operator rows. On rung 068 that is **116,719 vertices frozen** and the brush's
whole domain is the remaining 17.74%.

**(c) The constraints from PR 306 §S2, each reported as met or not:**

| constraint | status on his part |
|---|---|
| C1 Gibson per-vertex trust region | **met.** cell = 1.705279/2 = 0.852640 mm, radius 0.426320 mm. Max cut motion 0.6774–0.7212 mm, i.e. inside the cube's r·√3 = 0.7384 mm diagonal, every per-axis component inside r. |
| C2 signed one-sided bound | **met**, via `classify_trust_sign` with C4 overriding to Pinned. |
| C3 volume preservation | **met for MCF: 0.000% on every row.** Taubin drifts −0.004% to −0.125% — it has no volume term, which is a property of the incumbent, not a failure here. |
| C4 CAD faces do not move | **met, bitwise** — see above. |

**(d) MINIMUM cross-section of every tendril, before and after — not the mean.**
Measured with PR 306's own slice-area instrument (moved verbatim into a shared
header, §R5): **104.6872 mm² on rung 068 and 84.3313 mm² on rungs 052/038/026,
identical in every row, both operators, every setting.** Nothing necked.

## S2.5 — THE VERDICT

**BLOCKED-STOP, as the brief defined it.** MCF does not clearly beat the shipped
operator on the cut population — it is worse on the only two readings available.
**S3(a), (b) and (c) are not built.** Nothing was wired, no operator was swapped,
and the brush still drives the shipped smoother.

---

# 3. S3 — WHAT WAS TAKEN ANYWAY

## S3(d) — THE PREVIEW GATE

`SmoothingPage.swift` had its own copy of the enable condition:

```swift
private var hasSmoothed: Bool { page.receipt != nil || page.kept != nil }
```

— which ignored `page.preview`, so the Smoothed tab was dead until a certification
had run, even though `refreshPreview` produces a displaced mesh on every stroke
and `currentGeometry` was already willing to hand it to the stage.

**Taken now, despite the S2 NO-GO, because it is a different question.** Whether
the smoother is worth improving (it is not) has nothing to do with whether you can
see what it did. It is meaningless to make smoothing feel good if the result is
behind a solve.

The predicate **moved onto the model** as `hasSmoothedToShow`. As a `private var`
in the view the only way to test it was to retype the expression in the test — a
mirror, which agrees with the view right up until someone edits one of them. PR
303's own G1 reproduction did exactly that. It now reads the same property the tab
reads, its skip is gone, and it gained a positive control (the tab must be OFF
when there is nothing to show).

## S3(e) — AND WHAT THE CERTIFICATE CAN SEE

New footnote on the receipt, next to the quantization line:

> The certification re-voxelizes at 1.71 mm, so it cannot see surface motion
> smaller than one voxel: a margin that did not move is NOT evidence that the
> smoothing was safe. What bounds the risk is the displacement limit on the brush,
> not this number.

PR 303 measured a **0.23 mm** surface move returning an identical margin, peak
stress, verdict and voxel mass to every digit. It is stated **unconditionally**
rather than only when the margin holds still — the limitation is a property of the
instrument, and a footnote that appeared only sometimes would imply the
certificate *can* see the change the rest of the time.

## What is still owed on this page (PR 303's G2 and G3, still failing)

Both remain skipped in `SmoothingPreviewGateTests`, and both are real:

* **G2** — after one certification, no later stroke ever reaches the stage.
  `WorkspacePlaceholder.swift`, the `.ended` guard `page.receipt == nil,
  page.kept == nil`.
* **G3** — the model prefers a stale certified mesh over a fresher preview.
  `SmoothingPageModel.currentGeometry`.

They are outside this task's S3(d), and unlike G1 they change the page's **honesty
ranking** between a certified shape and an uncertified one — currently an
uncertified shape can never outrank a certified one on the stage, by design.
Re-deciding that deserves its own task, not a drive-by inside this one.

---

# THE BARS

**R1 — byte-identical when not smoothing.** `evidence/.../r1_byte_identity.txt`.
Proven **structurally for core, which is stronger than a checksum**: `git diff`
over `core/src` and `core/include` is **empty** — no shipped translation unit
differs, so the CLI, the solver, the exporter and the certification cannot differ
on *any* input, not merely on the ones a checksum tried. The only `core/` changes
are one additive `EXCLUDE_FROM_ALL` CMake block, a new harness, and a harness
header move. For the app, the one shipped value that could have moved silently is
`ViewerMeshSignature.contentHash` (the viewer's upload cache key): the base tree's
struct and this branch's were **compiled side by side, both lifted verbatim**, and
agree on all 30 mesh cases. The two preview routes are asserted bit-identical
permanently. **The four deliberate behaviour changes are listed rather than buried
under a checksum.**

**R2 — failing test first, for S1(a) and S1(b). Both pasted.**

*S1(a)*, `evidence/.../r2_s1a_camera_fails_today.txt`: PR 306's method — the fix
surgically disabled in `MetalMeshView.swift`, the **unmodified** test re-run.
9 failures. The deciding line:

```
XCTAssertEqual failed:
 ("OrbitCamera(target: (0.5, 0.4925, 0.5), … distance: 2.6155658, …)") is not equal to
 ("OrbitCamera(target: (0.451, 0.446, 0.593), … distance: 0.9108709, …)")
 - a brush stroke must leave the camera exactly as the user had it
… ("2") is not equal to ("1") - a stroke must not re-run the settle animation
```

The four tests that PASS in that arm are the positive controls (a different part
must still be framed, must still settle, and the signature must still separate the
two cases) — they are what stops the bars passing vacuously.

*S1(b)*: **the "today" assertion is a permanent test, not a stash arm, and that is
deliberate.** `SmoothingPreviewNoDiskTests.testTheRouteThePageUsedToTakeDoesReadTheFile`
asserts that the route which shipped **does** open the file — it spends measurable
import time, and deleting the file makes it throw. Its sibling
`testAStrokePreviewsWithTheVariantFileDeleted` then deletes the file and requires
a stroke to preview anyway, through `SmoothingPageWiring.livePreviewer`, the value
the app itself passes. A stash arm was attempted and rejected: the signature change
makes the pre-fix tree fail to **compile** against the same tests, and a compile
error proves less than a permanent assertion that runs in CI forever.

**R3 — demonstrably usable, on his own variant.** `evidence/.../r3_usable_path.txt`
and `SmoothingUsablePathTests`. The path is walked in order — stroke → tint appears
→ preview updates → **camera unchanged** → repeated strokes darken (rungs 1, 2, 3;
displacement 0.2681 → 0.3715 → 0.4221 mm) → Smoothed reachable with `receipt == nil`
— on his real rung-068 mesh, through the real `SmoothBrushModel` (via
`brush(_:triangles:)`, the seam `handleBrush` calls), the real `SmoothingPageModel`
with the shipped previewer, the real `MetalMeshView.Coordinator` over a real
`MeshRenderer`, and the real `hasSmoothedToShow`. Nothing is a stand-in and nothing
is retyped. It skips **loudly** if his mesh is absent.

**R4 — iterations and wall, separately.** Every table carries both: the S2 tables
have `iters` and `wall_s` columns; S1(c) reports repeats and ms/stroke with the
import and the smoothing split apart.

**R5 — never weaken or delete an assertion.** `evidence/.../r5_assertion_census.txt`
— a census of every removed assertion-bearing line in the diff, accounted for by
name. **Exactly two**, both in PR 303's G1 test: an unconditional `throw XCTSkip`
(the absence of an assertion, removed because the defect is fixed) and a dead
mirror line after it that had never executed, replaced by the real property plus a
new positive control, message preserved verbatim. **Net +70 / −2.** The 247-line
drop from `operator_bakeoff_probe.cpp` is a MOVE: all 232 non-blank removed lines
were verified present in `surface_instruments.hpp` by exact whole-line match, and
the probe was rebuilt and re-run reproducing PR 306's committed output figure for
figure (`r5_instrument_move.txt`).

**R6 — root cause with file and line.** §S1(a) (`MeshRenderer.setMesh`,
`camera.frame`), §S1(b) (`bridge.cpp:1381`, `import_any`), §S3(d)
(`SmoothingPage.swift`, the duplicated predicate). No unfilled placeholders: every
number here is from a run in `evidence/`. No scratch at the repository root.

**R7 — separate commit for any review response.**

---

# FILES

| file | what |
|---|---|
| `app/.../ViewerMesh.swift` | `topologyHash` + `isSameSurface` — the same-surface decision |
| `app/.../MetalMeshView.swift` | `applyMesh` / `updateVertexPositions`, the coordinator call site, `settleBeginCount` |
| `app/.../SmoothingPageWiring.swift` | the live previewer, named so a test can drive it |
| `app/.../SmoothingPageModel.swift` | `Previewer` takes geometry; `hasSmoothedToShow`; `certificateBlindnessLine` |
| `app/.../SmoothingPage.swift` | one predicate, one footnote |
| `app/.../SmoothBrushKit.swift`, `bridge.cpp`, `TopOptBridge.hpp` | the in-memory preview door; the cost split |
| `core/tests/harness/cut_population_probe.cpp` | S2 |
| `core/tests/harness/surface_instruments.hpp` | PR 306's instruments, moved verbatim |
| `app/.../SmoothingStrokeCameraTests.swift` | R2 for S1(a), + positive controls |
| `app/.../SmoothingPreviewNoDiskTests.swift` | R2 for S1(b), + route parity |
| `app/.../SmoothingUsablePathTests.swift` | R3 |
| `app/.../SmoothingStrokeLatencyEvidence.swift` | S1(c)/S1(d) |

Reproduce:

```bash
./app/scripts/build_cli_macos.sh && ./app/scripts/build_core.sh
cmake --build core/build -j8 --target cut_population_probe
D=evidence/2026-08-03-multiscale-lattice-to
./core/build/cut_population_probe $D/m2_multiscale_final/design.bin $D/M2_verticalStand.step \
  evidence/2026-08-08-smoothing-that-works-and-is-usable
(cd app/TopOptKit && swift test -c release)
```

---

# IN PLAIN LANGUAGE

**A stroke no longer moves your view.** You can zoom in on the bit you care about,
slide it where you want it, and brush — and when you let go, the part stays
exactly where you put it. It stays put when you flip between Original and Smoothed
too, and the part no longer re-drops onto the ground every time. What was going
wrong is simple to say: the app treated the smoothed shape as a *new object*
arriving, and it frames a new object for you automatically, which is right when
you open a part and wrong when you have just brushed the one already on screen. It
now recognises "same object, moved" — same points, same triangles, different
positions — and quietly updates the positions instead. As a bonus that made a
stroke about **twelve times faster**: it was re-reading the 14 MB file off disk
every single time to rebuild the shape it was already drawing, and that re-read was
about **95%** of the wait. Roughly **0.8 seconds down to 0.07**.

**How much of the staircase the new smoother actually removes on your part: none.
It makes it worse.** This is the honest answer and it is not the one anyone hoped
for. The new method won convincingly on a test sphere — it removed about half the
stair-stepping against the old smoother's tenth. On your actual part it does the
opposite: it makes the surface *rougher* at every strength, on all four rungs, and
on the surfaces where we can properly check the answer it ends up further from
correct than doing nothing at all. The reason is not mysterious. A sphere is
nothing but smooth curves, and this method works by flowing toward smooth curves.
Your part is flat walls, round holes and sharp edges — and flowing toward smooth
curves *rounds a sharp edge off*, which is damage, not smoothing. **So I stopped
and built nothing on it**, which is what the brief asked for in this case.

There is a useful number underneath that. I checked whether the staircase is just
a matter of chopping the surface into finer triangles, and it is not: chopping it
four times finer moves the surface by about **one fortieth** of the staircase's own
height. **The stair-stepping is baked into the grid the design was solved on, not
into the surface we draw from it.** Which means the lever is resolution — solving
your part on a finer grid — and no amount of smoothing afterwards will substitute
for that. That is now measured rather than suspected.

**Your bolt holes and flat faces cannot be touched by the brush.** Not "we try not
to" — every point that came from your CAD is frozen before either smoother runs,
and afterwards I check it is sitting on the *identical* number it started on, down
to the last bit. Zero moved, on every rung, at every strength. On your fullest
rung that is about **117,000 frozen points**, and the brush can only ever reach the
remaining **18%** — the surface the optimizer cut, where there is no drawing to be
faithful to. I also measured the thinnest part of every strut before and after:
unchanged, everywhere.

**One thing to keep in mind when you next read a report.** If you smooth
something and the strength number does not move, that is **not** the software
confirming the part is still fine. The check re-measures your design on a grid
about 1.7 mm across, and the brush moves the surface by less than half of that — so
the change is invisible to it by construction. The page now says this on the
receipt itself, right under the numbers. What actually protects you is the hard
limit on how far any point may move, not the number that did not change.

**And you can finally see what the brush did without waiting for a full check.**
The Smoothed view used to be greyed out until you had run a certification, which
meant a several-minute solve just to look at your own brush stroke. It turns on as
soon as there is something to show.

**What I would do next, in order:**

1. **Resolution, not smoothing.** §S2.1 puts a number on it. That is where the
   staircase actually lives.
2. **Two remaining page defects, already reproduced and named** (§S3, G2 and G3):
   after you run one certification, later brush strokes stop reaching the screen.
   Worth its own task because it involves deciding when an unchecked shape may be
   shown over a checked one.
3. **A small piece of wasted work** I measured but did not fix (§S1(d) item 4):
   the brush's colouring is recomputed on every screen update rather than when the
   brush changes — about 13 ms each time, on 863,000 entries.

# lattice-preview-confetti — the preview was drawing struts *behind an opaque part*

Task: `lattice-preview-confetti`. Branch `claude/lattice-preview-specks-f869d6`,
base `fa50d826` (the PR #340 merge). Evidence:
`evidence/2026-08-18-lattice-preview-confetti/`.
Measured on an **Apple M2 Pro (macOS, headless)** and on the **iPad Pro 13-inch (M5)
iOS 26.5 SIMULATOR**. **No measurement was taken on a real iPad** — see §1.

> **"There is a lattice preview button. I turned it on. I have already done the FEA,
> everything is set to be built automatically to it. I still get this bullshit confetti."**
>
> He was right about all of it. Every declaration on his screen was correct, the bake
> was correct, the shader was correct, and the frame was correct. One line of SwiftUI
> plumbing never told the renderer to hide the part, so the part was drawn opaque **in
> front of** the lattice, in the depth buffer PR #340 had just given them to share.

---

## Section 0 — the answers, one line each

* **Does it reproduce on device, or only in the simulator?**
  **Not simulator-only.** It reproduces on the iOS Simulator *and* on macOS Metal —
  two different Metal implementations — through the production code path. **It could
  not be tested on a real iPad** (see §1 for why). The root cause is Swift state
  plumbing, not a shader, a depth format, MSAA or tile memory, so nothing about it is
  platform-conditional.
* **Does it predate PR #340?** **The defect does; the confetti does not.** The dropped
  `bodyAlpha` has been there since the preview shipped on **2026-07-29**, three weeks
  before PR #340. At PR #340's merge base (`849a6cf2`) the lattice lived in its own
  transparent `MTKView` with **no depth attachment at all** (verified in that tree: zero
  `[[depth(...)]]` outputs, no depth format on the pipeline, `isOpaque = false`), so it
  drew *over* the body whether or not the body was hidden and the dropped alpha cost
  nothing anyone could see. PR #340 put both objects in **one** depth buffer, and the
  opaque shell that should never have been there started winning.
* **How many struts was the preview handed?** **1,689 active lattice cells of 6,032**,
  over **103,578** interior voxels, tiling a **132-segment** octet soup at an **8.00 mm**
  cell — strut radii **0.26 – 1.10 mm** (he said "roughly 0.32–1.05 mm"). The bake was
  never the problem.
* **Upstream or renderer?** **Neither, exactly — the layer above both.** The geometry
  was there and the renderer would have drawn it. `MetalMeshView.Coordinator.apply`
  never handed the renderer the body opacity the workspace had asked for.
* **What are the coloured specks?** Measured, not guessed — see §4/R5. They are the
  lattice's own G-buffer pixels at the handful of places a strut trimmed flush against
  a wall landed a hair **in front of** that wall. On the simulator only ~37% of them
  carry the lattice's real indigo colour; the rest are **values the lattice's shader
  cannot produce** (green- and red-dominant) — undefined G-buffer content. On macOS
  every speck is indigo. On his screen there is a third contributor: face-role tints.

---

## §1 — the simulator, ruled out first

**It is not the simulator.** Both platforms were measured with the same harness, on his
own part, through `Coordinator.apply`:

| | lattice pixels won | **isolated** (the confetti metric) |
|---|---|---|
| **BEFORE**, macOS (Apple M2 Pro) | 6,900 (0.66%) | **54.90%** |
| **BEFORE**, iPad Pro 13-inch (M5) simulator | 26,623 (2.54%) | **30.85%** |
| **AFTER**, macOS | 121,818 (11.62%) | 0.06% |
| **AFTER**, iPad Pro 13-inch (M5) simulator | 121,818 (11.62%) | 0.06% |

*Isolated* = the share of won pixels with fewer than two of their four neighbours also
won. A rendered strut is a run of adjacent pixels and scores near zero; a scatter of
single-pixel specks scores near one. **Half the surviving pixels on macOS, and a third
on the simulator, are isolated specks.** That number *is* the maintainer's complaint,
made countable.

The two platforms differ only in **degree**, and in exactly the way depth precision
would: the simulator keeps ~4× as many z-fighting specks. **The AFTER frame is
identical on both** (121,818 / 0.06%) — once the part stops occluding the lattice there
is nothing platform-dependent left.

**I could not test on a real iPad, and I am not going to imply otherwise.** A physical
iPad is visible to `xctrace`, but installing and launching on it needs code signing and
a provisioning profile this environment does not have, and putting a build on the
maintainer's own device is not something to do without asking. It was not necessary:
the cause is a missing Swift call, and it reproduced on two independent Metal
implementations.

### PR #340 tested against its own merge base

Built `849a6cf2` for the same simulator and read its source directly. Two facts, both
checkable:

* `Coordinator.apply` at the merge base has **the same single `setBodyAlpha` call site,
  inside the same `if let flow = inputs.loadFlowVertices` block** (`MetalMeshView.swift`
  4546). The defect is identical there.
* `LatticeSDFRenderer` at the merge base declares **no depth attachment and no fragment
  depth output**, and its view sets `isOpaque = false` with alpha blending
  (`LatticeSDFMetal.swift` 191, 790–794). The body could not occlude it.

So PR #340 did not introduce the bug. It removed the thing that was hiding it.

---

## §2 — the number, before any fix

`LatticePreviewConfettiTests.testWhatThePreviewIsHandedOnHisPart`, on
`Fixtures/M2_verticalStand.step` through the app's own importer:

```
part          3106 triangles · bounds 218.28 × 52.59 × 200.00 mm
              octet · cell AUTO · density AUTO · finish SKIN
cell size     8.00 mm  (the value the PREVIEW folds at)
density band  0.050 … 0.900
strut radius  0.26 … 1.10 mm

SEGMENTS in the tiled soup .................. 132
OCCUPIED VOXELS (part interior, 128×31×117) ... 103578
ACTIVE LATTICE CELLS (graded) .............. 1689 of 6032
ACTIVE LATTICE CELLS (no field) ............ 1689 of 6032
```

**Large, not zero.** §3 does not apply; the bug is downstream of the bake. The graded
and ungraded bakes are identical in cell count, which also rules out §3(c)'s silent
no-field fallback: a missing demand field grades strut radii, it does not switch cells
off.

---

## §3 — two things the trace turned up that are NOT this bug

Reported because they are real, not fixed because they are not what he asked about.

**(a) §3(d): Face 15 and Face 2's declarations never reach the preview generator.**
`buildStrutScene()` (`WorkspacePlaceholder.swift` 2718) builds
`LatticeSDFScene(mesh:field:latticeID:)` — mesh, demand field, topology id. That is the
whole input. The declared lattice **regions** and their depths (11.0 mm and 10.6 mm)
are not among them, so the preview lattices the part's **entire interior**, not his two
declared regions. That makes the preview show *more* lattice than the job would build,
never less, so it cannot be the cause of an empty preview — but it does mean the
picture is not region-accurate. Worth its own task.

**(b) A project saved by the `lattice-stage-repair` branch cannot be opened on `main`,
and vanishes without a word.** His saved project carries `"densityMode": "sim"`, a case
that branch added (commit `913349b1`, "Density 'Auto' is named 'Sim'"). On `main`
`LatticeSettings.init(from:)` decodes that key with `decodeIfPresent`, which **throws**
on an unknown raw value rather than returning nil, so the whole snapshot fails to
decode — and `ProjectStore.snapshot(id:)` swallows it with `try?`
(`ProjectStore.swift` 284). The project simply does not appear in the list. Same family
of defect as §5(b): a silent failure that reads as "the feature is broken". That branch's
territory, flagged here.

---

## §4 — the root cause, and what the specks are

### The one line

`MetalMeshView.Coordinator.apply` reached `setBodyAlpha` **only from inside the
load-flow block**:

```swift
if let flow = inputs.loadFlowVertices {          // ← the lattice stage has no load flow
    …
    if !appliedFlow || inputs.bodyAlpha != appliedBodyAlpha {
        appliedBodyAlpha = inputs.bodyAlpha
        renderer.setBodyAlpha(inputs.bodyAlpha)  // ← the ONLY call site in production
    }
    …
}
```

The workspace has passed `bodyAlpha: 0` whenever the strut layer is up since the
preview shipped (`WorkspacePlaceholder.swift` 720, bar A3: *while the strut layer is up
there is ONE visible object*). The lattice stage has no load flow. **The request was
dropped on every frame it was ever made.** The renderer kept `bodyAlpha = 1`,
`encodeDepthPrepass` therefore saw `shellVisible == true` (`MetalMeshView.swift` 3518)
and rasterised the opaque shell into the shared G-buffer, and the marched lattice —
which is *inside* the part by construction — lost the depth test essentially everywhere.

**Why no test caught it.** Every test in the repo that hides the body calls
`renderer.setBodyAlpha(0)` **by hand**: `UnifiedShadingTests` 84/181/270,
`UnifiedShadingEvidenceGen` 119/126/229/232, `LatticeSDFAlignmentTests` 274. All of
them pin what the *renderer* does with a hidden body. Not one went through the path
that decides whether the renderer is ever told to hide it. The new
`testWorkspaceInputsHideTheBodyForTheStrutPreview` drives the real `MeshViewInputs`
through the real `Coordinator.apply` and asserts on `renderer.bodyAlpha`; it failed
before the fix (`1.0` vs `0.0`) and passes after.

### R5 — what the coloured specks actually are

Read out of the G-buffer the lattice itself wrote, at the pixels it won, with **no face
tints bound** — so the only colour the shader can produce is the indigo density ramp
(blue-dominant, red above green):

```
BEFORE, simulator — 22,884 pixels won
  indigo density ramp (b ≥ r ≥ g) ....... 8549
  green-dominant ........................ 5625
  red-dominant .......................... 5638
  other blue-ish ........................ 3042
  near-black ............................    30

AFTER,  simulator — 121,818 pixels won
  indigo density ramp ................... 121818     (everything else: 0)
```

So, precisely:

1. **They are lattice pixels**, not a separate overlay: pixels where a strut, trimmed
   flush against the part surface, resolved a hair *nearer* than the rasterised wall it
   is flush with — classic coplanar z-fighting, which is why they cluster on the inner
   curve and the lower wall where the surface is most nearly tangent to the view.
2. **Only about a third carry the lattice's real colour.** The green- and red-dominant
   majority are values `lsdf_albedo` cannot output. They are undefined G-buffer
   content — the albedo attachment read at pixels whose write was never coherently
   resolved. **This part is simulator-specific**: on macOS every speck is indigo.
3. **On his screen there is a third contributor I did not bind and so did not measure**:
   he has Group C protected and two faces declared, so `LatticeFaceTintVolume.bake`
   stamps the anchor / load / keep-clear / protect colours — green, red, blue — into the
   albedo volume, and `lsdf_albedo` mixes them in (`UnifiedShading.swift` 385–391).
   That is read from the code, not measured here, and it is stated as such.

Either way: **not debug colouring, not per-region tints by design, and not a
scale problem.** §4(a)'s scale answer for completeness: his struts are 0.26–1.10 mm at
an 8.00 mm cell, which at the framing above renders 3–12 px wide — visible struts, as
`02_after_struts.png` shows.

---

## §5 — the fix, and the second defect

### (a) The root cause — `MetalMeshView.swift`

Body alpha is reconciled **unconditionally**, after the load-flow block, **against the
renderer's own value** rather than a cached copy:

```swift
if renderer.bodyAlpha != inputs.bodyAlpha {
    renderer.setBodyAlpha(inputs.bodyAlpha)
    dirty = true
}
```

The cached `appliedBodyAlpha` is gone. It had to go: `clearLoadFlow()` also resets the
renderer's alpha to 1, so a cache could believe it had already delivered a 0 the
renderer no longer held. Reading the renderer makes that whole class unrepresentable —
one value, and it is the one being drawn with. `bodyAlpha` becomes `private(set)` so
the getter is visible; the setter is unchanged.

### (b) The second defect — a preview with nothing to draw now says so

**This ships regardless of the cause, and it is independent of §5(a).** The overlay was:

```swift
if showStrutPreview, let scene = strutScene { Text(scene.preview.previewLabel) }
```

Read the other way round: a preview that is **on** and has **no scene** renders
**nothing at all**. Turn it on before a mesh exists, or during the second the bake
takes, and the toggle says "on", the viewport does not change, and nothing anywhere
says why. He has lost two sessions to a silent preview.

`LatticePreviewBanner.make(previewOn:hasModel:scene:)` is now **total** over the states.
Three strings, all under 25 words, no jargon (asserted):

| state | string |
|---|---|
| on, no model open | `No lattice to show — there is no model open yet.` |
| on, bake not landed | `Building the strut preview — this takes a moment.` |
| on, part has no interior | `No lattice to show — this part has no inside to fill with struts.` |
| on, drawing | `LATTICE PREVIEW — live strut geometry, not the exported mesh` *(unchanged, bar P1)* |

The empty ones render in primary rather than secondary text, so they read as a message
and not as a caption. `LatticeSDFScene` gained `interiorVoxelCount`, counted once
during the bake it already walks, so the check costs nothing per frame (bar P2).

**What is deliberately NOT built:** a runtime warning for *his* case — "the lattice is
there and something is in front of it". The only honest way to detect that is to count
the lattice's won pixels, which costs a second full march per frame. It is pinned as a
**test** instead (`testTheStrutPreviewSurvivesTheSharedDepthBuffer`), which is where an
invariant belongs.

---

## R7 — nothing about the exported mesh moved

The root cause is in `MetalMeshView.Coordinator.apply`, a SwiftUI-to-renderer state
hand-off. **No generator, no job document, no spec, no verdict.** The four changed
source files are the renderer, the preview's pure model, the scene's voxel count, and
the overlay's banner. `LatticeSDFScene`'s bake is byte-identical apart from an added
integer count of a grid it already builds.

## R8 — assertion-message census

Diffed against **`fa50d826`, this branch's own base** — not a moving `origin/main`.

```
git diff fa50d826 -- app/ | grep '^-' | grep -E 'XCTAssert|XCTUnwrap|XCTFail|precondition|assertionFailure|fatalError|assert\('
→ (empty)
git diff fa50d826 -- app/ | grep -E '^-.*func test'
→ (empty)
```

**No assertion and no test was removed, weakened or renamed.** No existing test file was
touched at all; both new files are additions. One pre-existing macOS-only test
(`LatticePageRound2Tests`, which spawns the CLI via `Process`) blocks the test bundle
from compiling for the iOS Simulator; it was moved aside **temporarily** to take the
simulator measurements and restored immediately, verified clean with `git status` each
time. It is unmodified in the commit.

Four unrelated PNGs under `docs/handoffs/assets/` were rewritten by a full `xcodebuild
test` run (another task's evidence gen runs unconditionally). They were restored with
`git checkout --` and are not in this commit.

## The suite

`xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'`:
**1,780 passed · 4 failed · 29 skipped** (1,813 cases started). Both new files pass in
full, on macOS and on the simulator.

The four failures are pre-existing and neither is this change:

* **3 × `AppModelTests.test*ThreeMF*`** - the worktree's `lib3mf` gap. They come back as
  an `ImportRefusal`, and `build_core.sh` prints the matching **"REDUCED TEST SUITE"**
  warning on this machine. The same three are named as pre-existing in PR #340's
  handoff. So this is **1,780/1,784 of what can run here**, not 1,780 of CI's
  denominator.
* **1 × `LatticeProxyProfileTests.testProxyVsRealOnMaintainerBracket`** - a timing
  flake, and a documented one: its own comment records a 0.97× / 1.43× history and PR
  #340's handoff chased the identical thing. Re-run **in isolation three times on this
  exact tree it passed, passed, then failed** (1.58×) with nothing changed between runs.
  It measures the density-proxy draw, a path with no lattice layer and no body alpha
  in it.

## R9 — cost

**No wall-clock number is quoted, because none is needed.** The change is one
comparison and at most one property write per SwiftUI update; the render path,
the bake path and the shaders are untouched. `interiorVoxelCount` is counted inside the
occupancy loop `LatticeSDFScene.init` already runs. The one number that could be called
a cost — `latticeMaskDump` — is test-only and never on a frame path.

---

## In plain language

The lattice preview was working the whole time. It was drawing the struts *inside* the
part, and the part was being drawn solid and opaque *in front of them*.

The app has always known it should make the part invisible while you look at the
struts — there is a line asking for exactly that, and it has been there since the
preview was built. But that request was written inside a block of code that only runs
when the load-path arrows are showing. On the lattice screen there are no load-path
arrows, so the request was quietly thrown away every single time.

For three weeks that did no harm, because the struts used to be drawn on a separate
transparent layer laid over the top of everything — they showed up whether the part was
hidden or not. Last week's change merged the struts and the part into one object so
they could shade and shadow each other properly, which is a genuine improvement. But it
also meant the part could now block the struts. And it did: it blocked all of them,
except for a few hundred pixels where a strut ends exactly flush with the outer wall and
the two surfaces are the same distance from the camera, so which one wins is down to
rounding. Those are the specks. The odd green and red among them is uninitialised
memory being lit, plus your own face markings — anchor, load, keep-clear, protect — which
are painted onto the lattice.

The fix is one line moved out of the wrong block. On his part the preview goes from
6,900 scattered pixels — over half of them lone specks — to 121,818 pixels of solid
strut with almost no specks at all.

Separately: a preview that has nothing to show now says so, in one short sentence, with
the reason. It used to show nothing and say nothing, which is indistinguishable from
being broken.

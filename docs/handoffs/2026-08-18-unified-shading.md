# unified-shading — the lattice and the shell are one object

Task: `unified-shading`. Branch `claude/unified-shading-lattice-shell-4ac47b`,
merge base `500833ed`. Evidence: `evidence/2026-08-18-unified-shading/`.
Device: **Apple M2 Pro, macOS, headless — NOT the maintainer's iPad.** See R3.

> **Merged with `origin/main` (`849a6cf2`, PR #339 `surface-stage-gestures`) after the
> work above.** Two conflicts, both in the SwiftUI layer and both the same shape: that
> task and this one each appended fields to `MeshViewInputs`, parameters to the three
> `MetalMeshView` initialisers and arguments to the workspace's call site. **Resolved as
> the union in every case** — nothing was dropped from either side, and no behaviour was
> chosen between them. All of that task's changes to `MetalMeshView.swift` land at line
> 3729 and beyond (the inputs struct, the representables and the gesture extension); every
> change in this task's renderer work is above it, so the two never touched the same code,
> only the same parameter lists. The one judgement call: the non-MetalKit `MetalMeshView`
> stub does **not** get a `latticeLayer:` parameter, because `LatticeLayerInputs` carries a
> `LatticeSDFScene` and that type is MetalKit-only — it cannot be mirrored into that branch
> the way `DetentPulse` and `BrushPhase` are. Nothing is lost: `WorkspacePlaceholder` holds
> a `LatticeSDFScene` in its own `@State` and so is MetalKit-only regardless of the stub.
> Post-merge: **1807 executed, 28 skipped, 8 failures** — the same three pre-existing 3MF
> cases, and both tasks' suites pass (`UnifiedShadingTests` 9/9,
> `SurfaceStageGesturesTests` + `SurfaceStageTests` + `SurfaceRound7Tests` all green).
> The shell's frame digest is **unchanged** by the merge (see R7). One flake seen and
> chased down: `LatticeProxyProfileTests.testProxyVsRealOnMaintainerBracket` reported a
> 1.59× ON/OFF ratio against its 1.35 bound on one full-suite run and 0.95–1.08× on five
> subsequent runs including a second full suite — its own comment documents exactly this
> flake history (0.97× then 1.43× on one commit), and it measures a renderer path with no
> lattice layer in it.

The maintainer's complaint was *"I want something that looks like it could be a PART
of the model — NOT something that looks literally pasted on top of it."* The task's
diagnosis was that the shell and the lattice were being lit, occluded, depth-tested
and edge-detected as two separate objects. That diagnosis was right, and it was worse
than two passes: **they were two MTKViews.**

---

## Section 0 — what was already shared, and what was not

One line each, with file and line at the merge base.

| | shared before? |
|---|---|
| ONE pass, or two? | **Two VIEWS.** The body: `MetalMeshView.swift` `MeshRenderer.encode` (2769). The lattice: a second `MTKView` hosted by `LatticeSDFPreviewView` (`LatticeSDFMetal.swift` 728), stacked in the workspace's ZStack (`WorkspacePlaceholder.swift` 746–756). |
| Same DEPTH buffer? | **No — the lattice had no depth attachment at all.** The mesh view sets `depthStencilPixelFormat` (`MeshRenderer.depthFormat`, 1384); the lattice view sets `isOpaque = false` and alpha-blends (`configure`, 783–795) with no depth anywhere. Its pipeline never declared one (188–199). |
| Same NORMAL buffer? | **No.** The G-buffer's eye-normal attachment (1602) was written only by `depth_fragment` (556) from the rasterised shell. |
| AO once, or per object? | **Once — over the SHELL ONLY.** `encodeAO` (3311) reads that G-buffer. The lattice got **zero AO at any price**; it was not in the buffer AO is computed from. |
| Silhouette/crease pass? | **Once, over the shell only** (`ao_fragment`'s G channel, 697–713). The lattice had no edge pass — so no sticker *outline*, but no creases either. |
| Contact shadow? | Shell only (`contactShadowTexture`, 3131 — the part's floor footprint). |
| Depth fade? | Shell only (`viewer_fragment`, `sp.fade`, 395). |
| Same BRDF / ambient / key-fill-rim / tone map? | **No, and not close.** Shell: clay albedo `(0.78,0.77,0.75)`, two-colour hemisphere ambient `0.225…0.470`, world key `(−0.38,0.82,0.42)×0.72` wrapped, fill `(0.72,0.10,0.55)×0.55`, Fresnel³·⁵ rim, no tone curve. Lattice: **flat** `amb = 0.30`, key in **MODEL** space `(0.4,0.85,0.55)×0.85`, fill `(−0.5,0.2,0.7)×0.30`, Fresnel²·⁵ rim mixed to white, a **specular lobe (pow 48)** the shell does not have, and `pow(lit, 0.85) × 1.08` — a gamma lift and an exposure the shell does not apply. |
| Resolution | The lattice view capped its own drawable at 1152 px on the long side and let the **compositor upscale** it (its bar P3). On an iPad that is ~2.4× — a soft layer over a crisp 4×MSAA scene. |

**Nothing was shared.** There was no part of this to scope down: the two objects
shared a camera and a model transform (the 2026-07-30 alignment fix) and nothing else.

**Does any pass write depth from the fragment shader?** At the merge base, **no** —
every pass was a normal rasterised early-Z pass. After this change exactly one does
(the lattice), and it declares `greater`. See §2(b) below.

### Which of the three mechanisms was actually responsible

**All three, plus a fourth the task did not list: compositing.** The lattice was not a
badly-lit object in the scene, it was an *image laid over the scene*. Ranked by how
much each contributes to "pasted on":

1. **separate material (§1 iii/d)** — toggle the preview and the object changes
   substance. Different ambient model, different light space, a specular highlight
   that appears out of nowhere, a different exposure.
2. **separate occlusion (§1 i)** — no contact darkening anywhere: not between struts,
   not where a strut meets a wall. The lattice was a flat lilac mat (see
   `01_before_two_views_composited.png`).
3. **separate depth (§1 ii)** — the struts could not be occluded by *anything*: not
   the part, not the ground grid, not a clearance volume in front of them.
4. **the upscale** — a soft 1152-px layer over a 4× multisampled frame.

---

## Section 0 (continued) — the answers in one line each

* **What was already shared:** the camera and the model/settle transform. Nothing else.
* **What was not:** the pass, the depth buffer, the normal buffer, the occlusion pass,
  the edge pass, the depth fade, the material, the tone map, and the resolution.
* **Which mechanism was responsible:** all three — and the root cause was that the
  lattice lived in a second, depth-less, alpha-composited `MTKView`.
* **Frame-time delta, and on what device:** a few milliseconds dearer — median **+3.0
  to +5.0 ms** across four repeated ten-trial runs, on a **~26–27 ms** frame, on an
  **Apple M2 Pro via macOS, headlessly**, at a framing where the part fills a 2048²
  target. 8–9 of every 10 trials come back slower; the magnitude is only good to a few
  ms because the march that dominates both arrangements has that much run-to-run spread
  itself. **No iPad measurement was taken.**
* **Does the junction darkening now appear in the AO buffer:** **yes.** Over the
  covered pixels, the occluded fraction goes **20.6% → 66.1%** and mean openness
  **0.892 → 0.743** — and `06_after_ao_buffer_union.png` shows it as the lattice's own
  shape with a dark seam at every strut junction, where `05_before_ao_buffer_shell_only.png`
  is a blank white plate.

---

## The before/after pairs

All in `evidence/2026-08-18-unified-shading/`, from `UnifiedShadingEvidenceGen`.
Same camera, same part (`WallMount_ShelfBracket.stl`), same octet lattice at the
maintainer's 8 mm cell, same clear colour, 4× MSAA, body hidden (the lattice stage's
own bar A3).

| file | what it is |
|---|---|
| `01_before_two_views_composited.png` | The arrangement that shipped: `MeshRenderer`'s frame with the body hidden, with `LatticeSDFRenderer`'s own transparent frame composited over it by the same premultiplied "over" the compositor used. Not a reconstruction — both shaders are the shipped ones. |
| `02_after_one_pass.png` | One `MeshRenderer` frame, lattice marched inside its passes. |
| `03_before_junction_zoom3x.png` / `04_after_junction_zoom3x.png` | The same 256-px window, 3×, on a latticed region where struts meet the flush-cut wall — R1's junction. |
| `05_before_ao_buffer_shell_only.png` | **§3(b).** The AO buffer as the shipped code filled it: the solid bracket, and the lattice nowhere in it. |
| `06_after_ao_buffer_union.png` | The AO buffer over the union. The lattice, with a dark seam at every junction. |
| `07_after_ao_buffer_junction_zoom3x.png` | The same window on that buffer, 3×. |
| `frame_time.txt`, `ao_and_pixels.txt` | The harness printouts, verbatim. |

**Both sides are captured at 1024², deliberately.** The old view capped at 1152 and the
new G-buffer caps at the same 1152, so at 1024 *neither* cap bites and the pair differs
only in shading, occlusion, depth and edges. The pictures do not get to claim a
sharpness win that is really about resolution.

★ AND THE UNIFIED PATH DOES NOT BUY RESOLUTION EITHER — do not read one into it. The
march, the occlusion and the normals are all at the 1152 cap on both sides; what the
deferred shade evaluates per colour pixel is a *filtered* read of capped inputs, not
more geometry. The gain is shared occlusion, shared depth and one material. On the iPad
the lattice will still be a 1152-resolution silhouette.

---

## Method — what actually changed

### The one material (§1 d) — done first, and nearly free

`unifiedMaterialSource` in the new `app/TopOptKit/Sources/TopOptFlows/UnifiedShading.swift`
holds `ShadeParams`, `to_material` (hemisphere ambient + key + fill + Fresnel rim) and
`to_edge_fade` (the crease line and the depth fade). Every constant is
`render-quality` §2's, **lifted verbatim** — this task retuned nothing. Both
`viewerShaderSource` and the new `unifiedLatticeShaderSource` are built by
concatenating that string, so there is exactly **one definition** and a test asserts
there is exactly one (`testOneMaterialDefinitionSharedByShellAndLattice`). The
lattice's albedo is still the indigo density ramp plus the face-role tint volume —
albedo is information; the *response to light* is now identical.

The lattice's old model (flat ambient, model-space key, specular lobe, exposure lift)
survives **only** in `LatticeSDFRenderer.shaderSource`, on purpose: that is this
task's before picture, and a drifted before makes the pair meaningless. A test pins
that too.

### One depth buffer (§1 ii)

`unifiedLatticeShaderSource` has two entry points:

* `lsdf_gbuffer` runs **inside `MeshRenderer`'s depth prepass**, in the same encoder
  and against the same depth attachment as the rasterised shell. Whichever surface is
  nearer per pixel is the one that lands in the G-buffer.
* `lsdf_shade` runs **inside the main colour pass**, immediately after the body, as a
  full-screen *deferred* shade of what the prepass marched — no second march — and
  writes fragment depth into the shared depth buffer.

So a strut behind the shell wall is gone, a strut in front of the ground grid occludes
it, and an opaque shell hides the struts inside it entirely
(`testSharedDepthBufferHidesTheLatticeBehindAnOpaqueShell`: indigo pixels drop by
>90% when the body goes opaque — a composited layer could not do that at all).

### AO over the union (§1 i) and one edge pass (§1 iii)

Because both surfaces are in one G-buffer, `encodeAO` — unchanged — now computes
occlusion and the silhouette/crease channel over the union, once. The lattice consumes
that same RG texture through the same `to_edge_fade`. There is no per-object edge
pass and therefore no outline around "the lattice as an object"; a test pins that the
lattice does not detect its own edges.

### The contact term (§3)

Not a new pass: it is the short-range end of that same union AO, which is where a
strut fusing into a wall darkens. Shown in the AO buffer pair, measured above.

### Two smaller things the union forced

* **An invisible shell must not go in the G-buffer.** `bodyAlpha` goes to 0 on the
  lattice stage; an invisible wall in the buffer would occlude the struts behind it and
  the interior would darken for a surface nobody can see. The prepass now skips the
  shell when `bodyAlpha ≤ 0.004`. A *partially* translucent body (the load-flow x-ray
  at ~0.35) is still visible and still goes in, so that path is untouched.
* **The G-buffer is resolution-capped when a lattice is in it**
  (`MeshRenderer.latticeGBufferMaxPixels = 1152`, the same number the deleted view
  used). The march is fill-bound — `LatticeSDFProfileTests` measures 12.5 ms for one
  1024² frame on this machine — so marching at an iPad's full drawable is not an
  option. The consequence: `ShadeParams.ao.zw` are now `1/mainTargetWidth`, not
  `1/aoTextureWidth` (sizing them from the AO texture put every uv past 1), and the
  contact pass, which reads the G-buffer by integer coordinate, is handed the scale in
  its previously-unused `params.zw`.

### §2 — the architecture Apple's hardware wants

* **(a)** The shell is still a normal rasterised early-Z pass. Nothing about its
  hidden-surface removal changed.
* **(b)** Exactly one pass writes depth from a fragment shader (the lattice, which for
  a raymarch is unavoidable), and it is both **confined** — a pixel with no lattice in
  the G-buffer discards before writing anything — and **declared**: the full-screen
  triangle is emitted at NDC z = 0, so every depth written is ≥ the interpolated one
  and `[[depth(greater)]]` is the truthful declaration. A test asserts there are
  exactly two `[[depth(...)]]` outputs and that both say `greater`, and that the shell's
  shader contains none.

### §4 — not in this task, and not done

No raymarching change (the field is byte-identical, see below), no mesh shaders, no
hardware ray tracing, no OIT/xray work, **no mesh changes**, no panel/control/copy/
layout changes.

### The second view is gone

`LatticeSDFPreviewView` — the stacked, transparent, depth-less MTKView — is deleted.
`LatticeSDFRenderer` stays, as the **baker** of the lattice's volumes for the unified
pass (`init(device:buildPipeline:)` skips its own pipeline) and as the standalone
before-capture that five existing test files still measure. It lost `@MainActor` so
`MeshRenderer` — which is not, because `MTKViewDelegate` callbacks are not — can drive
it; it is the same class, on the same thread, with the same callers.

The lattice's field, march, gradient and albedo moved into `latticeFieldSource`, shared
verbatim by both paths, so the before and the after march **the same geometry**. A test
pins that too — otherwise R4's "pixels, not geometry" would not be checkable.

---

## Bars

**R1 — before/after pairs on a latticed region where struts meet a shell wall, plus
the AO buffer pair.** Done; table above. One thing to be explicit about: **on the
lattice stage there is no separately-meshed shell wall to meet.** The strut field is
CSG-intersected with the part's own signed distance, so where a strut reaches the
surface it is cut flush and the visible facet carries the *part's* normal — a machined
section. That facet **is** the wall in these pictures, and the concave seam between a
strut tube and it is the junction. The crops are of that. When the body is opaque
instead, the shared depth buffer hides the lattice entirely, which is the other half of
the same fact and is what the depth test asserts.

**R2 — frame time against the baseline.** `frame_time.txt`. The BEFORE cost the **sum
of two command buffers** (two MTKViews, both redrawing per orbit tick) — mesh view
**~3.0 ms** at 2048² plus lattice view **~23–29 ms** at its own 1152 cap ≈ **~26 ms**;
the AFTER is one pass at **~29–37 ms**. Per-trial deltas over ten interleaved trials
span **−0.2 … +9.9 ms**, median **+5.0 ms** in the saved run and **+3.0 … +5.0 ms**
across four repeated runs, with 8–9 of 10 trials slower. **The march is ~89% of the
baseline and this task
did not touch it.** Where the delta goes is not a mystery: SSAO now runs over a frame
whose covered pixels are almost all lattice, and a self-occluding lattice is SSAO's
expensive case — `render-quality` measured that directly (its lattice column
1.39 → 7.02 ms at 2048², against 0.27 → 2.87 for the solid bracket). Two things pull
the other way and are already in the number: the occlusion pass moved from 2048² down
to the 1152 cap, and the shell is no longer rasterised into the G-buffer while
invisible.

*Not taken:* `aoQuality = .low` (8 SSAO samples instead of 16) would return most of the
delta. That is a quality decision about the feature this task exists to add, so it is
named rather than made silently.

*On the R2 numbers quoted in the task* (1.39 → 7.02 lattice, 0.27 → 2.87 bracket,
0.63 → 3.42 TO): those are `render-quality`'s treatment costs on **meshes**, with no
lattice layer anywhere. The row that speaks to them here is "no lattice layer
installed", measured at **~2.7–4.0 ms** — the `08_all` frame, and it is unchanged
because the shell's pixels are unchanged (see R7's digest below).

**R3 — state the device.** Apple M2 Pro, macOS, headless, via
`measureFrameGPUSeconds` (GPU timestamps, no readback, no wall clock). **This is not
his iPad and no iPad number was measured.** The one absolute claim worth carrying to
the device: both arrangements are already over the 16.6 ms budget at this framing
(the part filling a 2048² target), before and after — that is pre-existing and it is
the march, not the unification. `LatticeSDFProfileTests`' own 60 Hz assertion is on the
standalone renderer at 1024² with generous framing, and it is untouched.

**R4 — no mesh changes, byte-identical export, by checksum.** `git diff --name-only`
against the merge base touches **no** file under `core/` and no file on the export
path. Digests at merge base vs working tree:

```
SAME  app/TopOptKit/Sources/TopOptFlows/MeshExport.swift   ef8ffcef4bbbaaf0748e6979e2ae47aa6a2336cba24aacef6c4b8204c462d8a5
SAME  app/TopOptKit/Sources/TopOptBridge/bridge.cpp        48227e12a417dcb11ad7f01472d61813cebb711f040ea38d51db5058f62da67b
```

`testExportedGeometryDigestIsUnchanged` additionally pins the SHA-256 of the shipping
binary-STL writer's output for the bracket fixture, so this stays checkable. 3MF is
**not** covered by that test — it goes through lib3mf in the bridge, which this build
does not link (the same reason three pre-existing `AppModelTests.test*ThreeMF*` cases
refuse here); the bridge source digest above is what covers it.

**R5 — no control, panel or copy changes.** `git diff --stat` against `500833ed`:

```
 app/TopOptKit/Sources/TopOptFlows/LatticeSDFMetal.swift      | 519 +++++------------
 app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift        | 620 ++++++++++++++++++---
 app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift |  57 +-
 3 files changed, 692 insertions(+), 504 deletions(-)

 untracked (new):
 app/TopOptKit/Sources/TopOptFlows/UnifiedShading.swift
 app/TopOptKit/Tests/TopOptFlowsTests/UnifiedShadingTests.swift
 app/TopOptKit/Tests/TopOptFlowsTests/UnifiedShadingEvidenceGen.swift
 app/TopOptKit/Tests/TopOptFlowsTests/ShellPixelDigestProbe.swift
 docs/handoffs/2026-08-18-unified-shading.md
 evidence/2026-08-18-unified-shading/
```

`LatticeSDFMetal.swift` loses more than it gains because the shader's field moved to
`UnifiedShading.swift` and the stacked SwiftUI host was deleted; `MetalMeshView.swift`
gains the two pipelines, the union prepass, the deferred shade and the layer's setters.

The `WorkspacePlaceholder.swift` change is pass structure only: the stacked
`LatticeSDFPreviewView` block is removed and the same four values are handed to the
existing `MetalMeshView(...)` call as `latticeLayer:`. **The gate is unchanged** —
still `showStrutPreview && (visible.latticeControls || showLatticePage)`, and the
`bodyAlpha: 0` beside it is untouched. No panel, no control, no copy, no layout.

**R6 — the three mechanisms, individually.**

| | was | is now | still isn't |
|---|---|---|---|
| **(i) occlusion** | Per object, and the lattice was in *no* occlusion buffer — the G-buffer held the shell only. | One SSAO pass over the union; both surfaces in the same depth + normal buffers when it runs. Occluded fraction of covered pixels 20.6% → 66.1%. | SSAO is screen-space, so it cannot occlude with geometry off-screen or hidden behind the near surface. Unchanged property of the technique. |
| **(ii) depth** | The lattice view had **no depth attachment**. Struts could not be occluded by anything, including the part. | One shared depth buffer, written from the lattice's fragment shader with a declared `greater`; interpenetration resolves per pixel, and every overlay drawn after the lattice is occluded by it. | The G-buffer that decides shell-vs-strut is 1× and capped at 1152, so that decision is made at the march's resolution, not the colour target's. The colour pass's own depth test is at full resolution. |
| **(iii) edges + material** | One edge pass, over the shell only — no outline around the lattice, but no creases on it either. Two materials, differing in ambient model, light space, specular and exposure. | One detector over the combined buffers, consumed by both through one `to_edge_fade`. One BRDF, one ambient, one tone map, one definition, asserted to be one. | Nothing. Both are shared. |

**R7 — nothing that already works regresses.**

★ **THE SHELL'S PIXELS ARE BYTE-IDENTICAL TO THE MERGE BASE'S, AND THAT NEEDED ITS OWN
PROOF.** `testFrameWithoutLatticeIsUnchanged` compares this renderer against *another
instance of this renderer* — it catches leftover state from installing and removing a
lattice layer, and it cannot catch "extracting the material into a shared function
moved the shell's pixels", because both sides would move together. So
`ShellPixelDigestProbe` prints a SHA-256 of the shell's own 512² offscreen frame
(bracket, production camera, stage + ground on). Run on the branch, then with **every**
one of this task's source changes stashed and its new files moved out of the tree, and
run again on `500833ed`:

```
                       quality=.all                                                       quality=.none
branch     ebf6e9432fe0951c646ab02d91825d046959fb578fe1e08665bec02ff402fe42   3657a7a8882ad417c719f4c839e583bbc5ce1c5e23fdd8c6c9e9782d72fdc5a1
500833ed   ebf6e9432fe0951c646ab02d91825d046959fb578fe1e08665bec02ff402fe42   3657a7a8882ad417c719f4c839e583bbc5ce1c5e23fdd8c6c9e9782d72fdc5a1
```

Identical on both quality settings. The material extraction is a true no-op for the
shell — which is also what makes `render-quality`'s own before/after evidence still
true. (The probe is a print, not an assertion, deliberately: the digest is GPU-dependent
and a hard-coded constant would fail on every machine but this one.)

★ **AND A TRAP WORTH RECORDING:** `swift test` runs several evidence generators
unconditionally, and they rewrote FOUR other tasks' committed artefacts
(`docs/handoffs/assets/120_contact_*.png`, `tap_overselect_*.png`,
`evidence/2026-08-14-lattice-separation/r6_sample_after.png`, and three
`evidence/…/*.txt`). Since the shell's frame is byte-identical to the merge base's,
those files were **already stale** before this branch existed — nothing here changed
them. They are reverted, and `git status` is clean apart from this task's own files.

`testFrameWithoutLatticeIsUnchanged` still earns its place: installing a lattice layer
and removing it leaves the frame byte-identical (zero pixels moved by more than 1 level
over a 384² frame). Enumerated, on all three
stages: **AO** — same pass, same shader, same strengths; only its input gained a
surface. **Lighting** — the shell's world rig is the same function with the same
constants, now called rather than inlined; the pre-`worldLighting` headlight branch is
untouched. **Edges** — same detector, same thresholds. **AA** — the shell's 4× MSAA
pass is unchanged, and the lattice's silhouette is at the *same* 1152 cap it always was;
what changed is how it reaches the screen — a nearest read inside the colour pass
instead of a filtered compositor upscale of a separate layer, so it is marginally
crisper and marginally blockier, with the shared crease line now drawn on it. It is not
multisampled, and it was not before either. **Contact shadow** — same footprint pass,
same cache key;
it is the shell's footprint, and the lattice is inside the part so its footprint is a
subset. **Depth fade** — same curve, same backdrop colour, now applied to the lattice
too. **Wireframe and x-ray** — untouched, and both now depth-test against the lattice
as well as the body. Full suite result below.

**R8 — no assertion weakened or deleted.** Census over all 143 test files present at
the merge base, read whole:

```
test files at merge base: 143   all present
test functions:           1772 → 1772
XCTAssert/XCTUnwrap/XCTFail/XCTSkip call sites: 6932 → 6932   (0 files changed)
in-source assert()/precondition()/fatalError(): 1 → 1  (LatticeSDFMetal's P2 draw() assert, verbatim)
```

Diffed against the merge base `500833ed`, not a moving head.

**R9 — no unfilled placeholders, no scratch at the repository root, separate commit for
any review response.** Held.

---

## Tests

`swift test` on `app/TopOptKit` (macOS, `build_core.sh` run in this worktree):

```
Executed 1773 tests, with 27 tests skipped and 8 failures
```

All 8 failures are 8 assertions inside **3 pre-existing cases** —
`AppModelTests.testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance`,
`…testThreeMFImportOptimisesOnDeviceEndToEnd`,
`…testReopenedThreeMFProjectReimportsTheStlWorkingCopy` — all with core's
*"3MF import requires lib3mf, which is not available in this build"*. Proven
pre-existing, not assumed: with every source change stashed and all four new files
moved out of the tree, `AppModelTests` at `500833ed` gives **31 executed, 8 failures** —
the same eight.

**This is NOT CI's denominator.** `build_core.sh` reports `lib3mf: (none)` here, so CI's
`export_3mf` and `threemf_import` core tests do not register at all, and this run says
so rather than reporting N/N.

New: `UnifiedShadingTests` (9 cases, all passing), `UnifiedShadingEvidenceGen`
(2, env-gated on `TOPOPT_UNIFIED_SHADING_EVIDENCE=1`), `ShellPixelDigestProbe`
(1, env-gated on `TOPOPT_SHELL_DIGEST_PROBE=1`).

---

## In plain language

The lattice preview looked like a sticker because it *was* one. The struts were drawn
into a completely separate, transparent window that was laid on top of the picture of
your part. A separate window cannot share anything that makes a solid object look
solid: it has no depth information, so nothing could ever hide the struts — not the
part itself, not the grid, not a red keep-out box in front of them. It had no
shadowing, so there was no darkening where two struts cross or where a strut runs into
a wall, and the eye reads missing contact shadow as *floating*. And it had its own
lighting, with a different ambient level, a light coming from a different direction, a
shiny highlight the rest of the model doesn't have, and a brightness boost the rest of
the model doesn't get. Three ways of saying "different substance".

So the struts are now drawn inside the same pass as the part. They go into the same
depth buffer, so the part genuinely hides them and they genuinely hide what's behind
them. They go into the same surface buffer the shadowing is computed from, so the
crevices between struts and the seams where struts meet a wall darken by themselves —
that darkening is the single strongest cue that two things are one piece of material,
and you can see it appear in the two grey pictures in the evidence folder: before, that
buffer was a blank white plate with no lattice in it at all; after, it's the lattice
with a dark line at every junction. And they are lit by literally the same code as the
part — one copy of it, with a test that fails if anyone adds a second.

It costs a few milliseconds more per frame on my Mac. Almost all of the frame's cost
(about 89%) is the strut drawing itself, which this task deliberately did not touch —
making that cheaper is a separate, later piece of work. The extra few milliseconds are
the shadowing, and the shadowing is the thing you asked for. If it turns out to be too
slow on your iPad, there is a single dial (halving the shadow sample count) that gives
most of it back; I did not turn it on my own initiative because it trades away some of
the quality this change exists to add.

Two honest caveats. First, I measured on a Mac, not on your iPad — the numbers are
comparable to every other render measurement in this project, but they are not your
device. Second, on the lattice page your part's solid outer wall isn't drawn as a
separate object at all: the struts are cut off flush at the surface, and the flat faces
you see at the boundary *are* the wall. That's what the zoomed-in pictures show struts
meeting. Nothing about the exported geometry changed — this was a change to pixels
only, and the files you'd print are byte-for-byte the same.

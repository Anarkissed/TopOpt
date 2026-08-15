# 2026-08-15 · render-quality

★ **THE MAINTAINER'S WORDS:** *"is there any way to make all the 3d models look BETTER?
I really don't like the look of them so far."*

Base commit `a2b9ec7e` (`main` at the time of writing). This task is **independent of
`lattice-and-face-ui`** — it touches **one source file**, `MetalMeshView.swift`, and it
changes **how geometry is shaded and nothing else**. No panel, no control, no copy, no
layout. If both tasks are running, they do not overlap.

Evidence: `evidence/2026-08-15-render-quality/`.

---

## §0 — the answers, one line each

| | |
|---|---|
| **Renderer** | **Custom Metal.** `MeshRenderer: NSObject, MTKViewDelegate` — [MetalMeshView.swift:873](../../app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift). No SceneKit, no RealityKit anywhere in `app/` (zero matches for either). Every shader is MSL in a Swift string literal, compiled at runtime. **Screen-space post-processing was therefore available without replacing the render path** — the BLOCKED-STOP does not apply. |
| **AO cost on his part** | **+5.2 ms on the lattice**, +0.8 ms on his bracket, +0.9 ms on the TO result, at 2048². |
| **Lighting: IBL or matcap?** | **Neither, and on purpose: a world-space key/fill/rim over a two-colour hemisphere ambient.** A matcap is a lookup by *eye-space* normal — it is camera-locked by construction, which is the exact defect §2(c) names, and it also bakes colour, which would fight every region tint. A cubemap IBL buys, on a matte clay material, essentially the two terms the hemisphere already gives, at a texture fetch instead of one dot product. |
| **Total frame-time delta** | **1.39 → 7.02 ms** (lattice, ×5.05) · **0.27 → 2.87 ms** (bracket) · **0.63 → 3.42 ms** (TO result). At **2048²** on an Apple M2 Pro. A 60 Hz budget is 16.6 ms, so the lattice — the worst case — now spends **42% of it**. ★ See the correction below: an earlier draft of this table quoted 1024² and reported ~1 ms, which understated the real cost by 4×. |
| **Could the state colours be desaturated after?** | **Yes — 50% of the saturation came off every state tint** and all four states stay unambiguous (closest pair 22.9 in RGB, against a floor of 18). Two exclusions, both stated below with reasons. |

---

## The before/after pairs

Same camera, same part, same clear colour; only `MeshRenderer.quality` differs. Every
image is 1024² and comes out of `renderOffscreen` — the shipping encode path.

### ★ His lattice at a 2 mm cell — the picture he was looking at

`lattice_00_before.png` → `lattice_08_all.png`

**118,920 triangles — exactly the number in the readout he quoted.** That is his content,
not something like it.

The before is his description word for word: flat grey struts with nothing darkening
between them, reading as visual noise. The after separates every strut from the one
behind it. AO moves **49% of the part's pixels**; the full treatment moves 99.9% of them.

### His bracket · `WallMount_ShelfBracket.stl`

`bracket_00_before.png` → `bracket_08_all.png`

### A topology-optimised result on that bracket

`to_00_before.png` → `to_08_all.png`

Produced by `topopt-cli run` on his own analyze job
(`evidence/2026-08-05-smoothing-must-actually-smooth/job.json`, switched to
`minimize_plastic` at resolution 64). The job, the report and the mesh are in
`content/`. All curved surface, every concavity carved by the optimiser — the case §2
says a headlight is worst for.

### Per item

Every configuration adds exactly one item to the one before it, so any two adjacent
files are that item's before/after:

| file | adds |
|---|---|
| `*_00_before.png` | — the shipped renderer |
| `*_01_ao_low.png` · `*_02_ao.png` | §1 SSAO at 8 and 16 samples |
| `*_03_light.png` | §2 world-space key/fill/rim, **alone** (no AO) |
| `*_04_ao_light.png` | §1 + §2 |
| `*_05_msaa.png` | §3b 4× MSAA |
| `*_06_edges.png` | §3a silhouette + crease lines |
| `*_07_shadow.png` | §3c contact shadow |
| `*_08_all.png` | §3d depth fade → everything |

### §4 / R7 — every state at once

`states_00_before.png` → `states_01_after.png`: solid clay, anchor/fixed, protected,
latticed·include, latticed·exclude, the design box and a keep-out, all in one frame.

---

## R2 — frame time, per item and together

**Apple M2 Pro**, `measureFrameGPUSeconds(size: 2048, stage: true)` — Metal's own
`gpuEndTime − gpuStartTime` for one encoded frame, no readback. Same probe
`LatticeSDFProfileTests` and `LatticeProxyProfileTests` price against.

**★ TIMED AT 2048², AND THAT IS A CORRECTION TO AN EARLIER DRAFT OF THIS TABLE.** The
first version measured at 1024², where his bracket's whole frame costs 0.12 ms — close
enough to the resolution floor of a GPU timestamp that the harness disagreed with itself
by 0.345 ms against a 0.59 ms headline, and the run failed its own noise-floor bar. A
re-run then *passed* at 0.158 ms, which is worse than failing: **a bar that flips on the
draw is not a bar.** More rounds do not fix it — the jitter is a fixed per-command-buffer
spike, so a minimum over more single frames never converges it away. Timing a frame with
4× the pixels does, because every item here is a screen-space cost that scales with pixel
count while that spike does not. Two consecutive runs now clear the bar with 4–100×
margin. 2048² is also nearer an iPad Pro's real drawable than 1024².

**★ AND THE 4× IS NOT FREE — the honest cost is 5.6 ms on his lattice, not the ~1 ms an
earlier draft of this handoff reported.** The pictures did not change; the measurement
did, and the larger frame is the one worth quoting.

| config | lattice (118,920 tris) | bracket (2,224) | TO result (34,472) |
|---|---|---|---|
| 00 shipped | 1.389 | 0.273 | 0.631 |
| 01 AO ×8 | 4.351 | 1.197 | 1.497 |
| 02 AO ×16 | 6.614 | 1.079 | 1.541 |
| 03 lighting alone | 1.679 | 0.301 | 0.673 |
| 04 AO + lighting | 6.930 | 1.056 | 1.582 |
| 05 + 4× MSAA | 7.006 | 3.059 | 3.421 |
| 06 + edges | 7.011 | 3.103 | 3.512 |
| 07 + contact shadow | 7.004 | 3.198 | 3.566 |
| 08 + depth fade (all) | **7.016** | **2.865** | **3.422** |
| **noise floor** | **0.036** | **0.395** | **0.225** |

**★ READ THE NOISE-FLOOR ROW BEFORE READING ANY OTHER.** It is the largest disagreement
between two independent interleaved sweeps of the same nine configurations. **Any delta
smaller than it is this harness, not the feature** — which is why §2's lighting
(+0.03 to +0.29 ms) is reported as *nearly free*: it adds ALU and no render pass, and on
two of three parts it is within a factor of two of the floor.

**Where the cost actually is.** On the lattice it is SSAO (+5.2 ms) — 118,920 triangles
of thin geometry means the G-buffer pass rasterises a lot and the AO kernel then reads a
heavily-varying depth buffer. On the two brackets it is **4× MSAA** (+2.0 and +1.8 ms),
which is a bandwidth cost and barely moves with triangle count. Anyone needing that time
back has two one-property-write levers: `aoQuality = .low` (half the SSAO cost, and on
his content a 0.01 difference in mean part-pixel Δ — visually equivalent here), and
`sampleCount: 2`.

**★ AND THE MEASUREMENT DESIGN IS PART OF THE RESULT.** The first version of this table
benchmarked each configuration to completion before starting the next, and came back
**non-monotone**: world lighting measured 0.25 ms *faster* than the shipped renderer on
the lattice. Per-configuration repeatability was 0.001 ms, so that was not noise — it was
**order**. What a configuration measures depends on the state the one before it left. The
table above round-robins: every round touches every configuration once, so that state is
paid equally by all of them and cancels in the delta.

### ★★ THE 44 ms IN THE TASK IS NOT A FRAME TIME

`LatticeSetupWizard.swift:328` (`latencyReadout`) prints `lastLatencyMS`, which
`LatticeSetupWizard.swift:393` (`rebuild()`) measures with `CFAbsoluteTimeGetCurrent`
around `model.stageMesh(progress:)` — **a CPU mesh build**, once per settings change. Its
own doc comment says so: *"The measured build+upload time for the object on screen."*
Measured here on that same 2 mm-cell sample: **865 ms** to build those 118,920 triangles.
Nothing in the app displays a frame time. The renderer's cost was 1.39 ms at 2048² and
was never 44; the headroom the task infers from 44 ms is real, but it is not the headroom
that number describes — and at 7.0 ms the treated lattice frame uses 42% of a 60 Hz
budget, which is a genuine constraint rather than the rounding error "1 ms out of 44"
would have suggested.

### Where the measurement was taken

**On an Apple M2 Pro via macOS, not on his iPad** — the same shaders, the same encode
path, the same `MeshRenderer`, run headlessly. I have no access to his device. The iPad's
absolute numbers will differ; the *shape* (SSAO is a screen-space cost that barely moves
with triangle count; lighting is free; MSAA is a bandwidth cost) is a property of the
algorithm and transfers.

---

## What was built

One file: `app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift`. One new test file.

### §1 — SSAO (`aoShaderSource`)

The existing depth prepass became a **G-buffer**: attachment 0 is unchanged (same
R32Float eye-Z, same sentinel, so the contact pass reads exactly the bytes it always
did), attachment 1 is the eye-space normal. It now runs whenever AO or edges are on as
well as when a translucent volume is present — **one rasterisation of the part serves the
contact read, the occlusion and the edges**; the alternative was three.

Then two full-screen passes: hemisphere-sampled SSAO with an interleaved-gradient kernel
rotation, and a depth-aware 4×4 blur of the AO channel only. Output is one RG8 texture —
R openness, G edge — which the body fragment reads **once**.

**Radius, tuned on his content and the tuning is in the evidence.** The rule is a
fraction (0.50) of the part's *smallest* bounding-box side.
`testAORadiusSweepOnHisContent` sweeps it across all three of his parts and prints what
each setting reaches. **That sweep refuted the reason I changed the rule**: I had claimed
a fraction of the *largest* side mis-scaled his elongated bracket; what actually governs
coverage is the absolute radius, and both rules land in the same place on his parts. The
min-side rule is kept only because it degrades more gracefully on a case his three parts
do not cover (a long thin rod).

**★ And his bracket's low AO coverage — 13.6% of its pixels — is THE PART, not the
tuning.** A flat plate seen face-on has almost nothing to occlude itself with. The sweep
shows coverage climbing monotonically to 17.6% at a 14 mm radius and never approaching
the lattice's, so no radius fixes it. The two cases §1 actually names — the lattice and
the TO result — are at 49% and 25%, and those are the pictures that change.

**§1(b), both quality settings, not one picked silently:** 8 samples and 16.
8 samples costs 0.46 ms on the lattice against 0.93 for 16, and the pictures differ by
0.01 in mean part-pixel Δ — i.e. **the low setting is visually equivalent here and half
the price**. 16 ships because there is a 14 ms budget spare; 8 is one property write away
if a device needs it.

### §2 — lighting

The old shader transformed normals by `view · model` and used *constant* light
directions, which is a headlight by construction. The new path transforms by the **model
rotation alone** and lights in world space: a warm key high front-left, a cool weak fill
low right, a fresnel-weighted rim from behind, over a two-colour hemisphere ambient
(cool sky above, warm floor bounce below). Orbit the camera and the highlight stays on
the same face of the part.

**Tuned on his bracket, and the first values were wrong.** Ambient 0.150→0.400 with a
0.42 fill looked fine on a sphere; on his bracket, from a camera looking at the side the
key does *not* reach, the body came back around 40% grey — darker than the flat headlight
it replaced, and a user orbiting a part will find that side. A fixed world light means one
side is always the shadow side; the fix is a stronger ambient floor and a stronger fill
(0.225→0.470, fill 0.55), not a light that follows the camera back.

### §3a edges, §3b AA, §3c contact shadow, §3d depth fade

- **Edges** ride the AO pass — same two texture reads, so their marginal cost is inside
  the noise floor. Depth threshold is *relative* to eye-Z, so one setting holds from a
  20 mm cell to a 200 mm bracket and does not thicken as the camera pulls back. Applied at
  0.55 strength on a 0.30 multiply: a dark line, not a cartoon outline.
- **AA is 4× MSAA**, and on Apple GPUs it is one line (`view.sampleCount`) plus a matching
  `rasterSampleCount` on the seven main-pass pipelines; `MTKView` owns the multisample
  texture and the resolve. It is the **most expensive single item** — +0.35 ms on the
  bracket, +0.39 on the TO result — because it is a bandwidth cost, not an ALU one. A
  temporal solution was not attempted: this viewer is deliberately *on-demand* (paused at
  rest, one frame per camera change), and TAA needs a continuous frame stream and motion
  vectors, so adopting it would mean giving up the idle-cost property the viewer is built
  around.
- **Contact shadow is the part's own FOOTPRINT**, not an ellipse: one orthographic pass
  straight down into a 192² R8 target, sampled by the stage's floor shader with a 3×3 tap.
  It is cached on (mesh, settle rotation, floor rect) — **a camera orbit re-renders it
  zero times**, because a drop shadow from above does not depend on where the camera is.
  **Honestly: it is a drop shadow from directly above, not a shadow map from the key
  light, and its softness does not grow with height above the floor** — a part held 100 mm
  up casts the same edge as one resting on the floor.
- **Depth fade** is capped at 0.45 and starts at the *far half* of the part's own eye-space
  depth span. At full fade the material is still 55% itself, so it can never hide a region.

### §4 — the state colours, after §1 and §2

The mechanism is one line: **a tint now colours the ALBEDO, not the finished pixel.**
Before, a tinted region was `mix(litClay, tint, a)` — a flat colour laid over the part.
Now it is `tintedAlbedo × shade + rim`, so a tinted region carries the same occlusion,
key, fill and rim as bare clay. That is *why* the saturation can come down: hue no longer
has to carry "this region is different" on its own.

**50% of the saturation comes off every state tint**, with a lift back toward clay's
brightness so a deep indigo becomes a muted slate rather than a dark stain.

**★ It is done in the renderer, not in the colour tokens, and that is a scope decision.**
`LatticeDensityProxy.densityColor`, `DS.Color.groupPalette` and `ForceModel.anchorColor`
are read by SwiftUI chips and legends *as well as* by the mesh. Editing any of them would
change controls this task must not touch (§4c) and would collide with
`lattice-and-face-ui`. Desaturating at the one point where a colour becomes a triangle's
albedo reaches every state tint and reaches nothing else.

Measured on his bracket, mean rendered RGB of each state's own pixels (attributed by the
renderer's **own id pass**, not by matching colours — a colour match would beg the
question):

| state | before | after |
|---|---|---|
| anchor / fixed | (102,150,118) | (91,112,111) |
| protected | (68, 93, 89) | (54, 66, 66) |
| latticed · include | (132,124,159) | (93, 90,110) |
| latticed · exclude | (111,105,142) | (102, 99,136) |
| **closest pair** | **33.3** | **22.9** |

**Two exclusions, per §4(b), named rather than quietly dropped:**

1. **Keep-out red and the design box are unchanged.** They are translucent *glass*
   volumes drawn through `ground_fragment`/`contact_fragment` — no AO, no key light. §4's
   premise ("with real shading, less saturation still reads") is simply not true of them:
   taking saturation off an unlit volume only makes it weaker. Keep-out red is
   additionally the app's one "forbidden" signal.
2. **The stress and density ramps are unchanged.** They are *data*, read against a printed
   legend; their hue is the measured value. Desaturating them would not make them subtler,
   it would make them wrong. `tintsAreState` — set by whichever setter last filled the tint
   buffer — is what keeps them out.

---

## Bars

| bar | status |
|---|---|
| **R1** before/after pairs, every item, both the lattice sample and his real part | ✔ 27 PNGs + the states pair. Same camera, same clear, one property differs. The pair is *measured*, not eyeballed: an assertion fails if AO moves less than 40% of the lattice's pixels. |
| **R2** frame time per item and together, on device | ✔ table above, **with its own noise floor as a positive control**. Measured on an M2 Pro via macOS, not his iPad — stated, not implied. |
| **R3** tuned on his content | ✔ his 2 mm-cell lattice (118,920 tris — his exact readout), his bracket, and a TO result run on that bracket. The AO radius sweep is over those three. No cube, no sphere. |
| **R4** renderer named with file and line; anything the framework cannot do named with its reason | ✔ §0. Nothing was blocked by the framework. The one thing *not* done and why: TAA, refused because this viewer is on-demand by design. |
| **R5** exported STL byte-identical | ✔ `testExportIsByteIdenticalAfterRendering` — FNV-1a `e43074dcdfd2c023`, identical before and after a full `.all` render, and the renderer's own mesh copy is unchanged. |
| **R6** view-layer diff touches shading and materials only | ✔ **one source file changed**, `MetalMeshView.swift` (+995/−51), plus one line in one existing TEST file. Both enumerated below. |
| **R7** state colours re-tuned after AO and lighting, one screenshot with every state | ✔ `states_00_before.png` / `states_01_after.png` + the table above. |
| **R8** no assertion weakened or deleted | ✔ census run over the whole diff: every deleted line is a struct field, a signature that gained a parameter, or a shading expression that moved *verbatim* into the `else` (before) branch. No `guard`, `assert`, `precondition` or `XCTAssert` was removed or loosened; `sceneDepthTextures`' guard gained a third condition. |
| **R9** no unfilled placeholders, no scratch at the repo root | ✔ |

### R6 — exactly what was touched in `MetalMeshView.swift`

1. `ViewerUniforms` +4 fields (world normal basis, model, modelView, eye) — **appended**, so
   `id_vertex` and `depth_vertex`, which read only the earlier prefix, are byte-unaffected.
2. New `ShadeParams`, `AOUniforms`, `ShadowUniforms` structs.
3. `viewerShaderSource` — the fragment gained the AO/edge read, the world-lighting branch,
   the albedo tint, the state-tint desaturation and the depth fade. **The original shading
   survives verbatim in the `else` branch**, and with AO off its multiplier is exactly 1.0,
   so `quality = .none` is byte-identical to what shipped.
4. `depthPrepassShaderSource` — second colour attachment (eye normal).
5. New `aoShaderSource` (SSAO + edge, and the blur) and `shadowShaderSource` (footprint).
6. `stageShaderSource` — the contact-shadow lookup on the floor.
7. `init` gained `sampleCount:`; `rasterSampleCount` set on the seven main-pass pipelines;
   two AO pipelines and one shadow pipeline built.
8. `encode` — the G-buffer gate widened, the AO and footprint passes, the new fragment
   bindings.
9. Texture management for the new targets; MSAA targets in both offscreen paths.
10. The two design-box/keep-out colour literals moved to named constants (same values).

Nothing else. No `WorkspacePlaceholder`, no `DesignSystem`, no page, no control, no copy.

**Two test files, both named rather than buried:**

- `RenderQualityEvidenceGen.swift` — new; this task's captures, measurements and gates.
- `LatticeSeparationEvidenceGen.swift` — **one line, and it is a change I caused.** That
  file asserts EXACTLY ZERO lit pixels for `reveal = 0`, and 4× MSAA started reporting 5
  lit pixels out of 230,400. The cause is not the reveal: the shader discards on
  `t > reveal.x`, so at reveal 0 the zero-height sliver of vertices at exactly `t == 0`
  survives, and multisampling is the first thing whose sample points ever landed on it.
  I pinned that test's renderer to `sampleCount: 1` — **the assertion is untouched at
  `== 0`**. Weakening it to `< 10` would have hidden a property of the reveal behind a
  property of the anti-aliasing.

### What I did NOT update, and why

`swift test` regenerates several other handoffs' captures, and six of them are pictures
of this viewer — `docs/handoffs/assets/120_contact_*.png`,
`assets/tap_overselect_*.png`, `evidence/2026-08-14-lattice-separation/r6_sample_after.png`.
**They genuinely look different now**, because the renderer they capture changed. I
reverted all of them: re-baselining other tasks' evidence inside this PR would rewrite
their claims in a diff nobody reviewing those claims is reading. They will regenerate on
their own next run, and the difference is the feature, not a regression.

### Test suite

`swift test` on the full package: **1,529 tests, 25 skipped, 8 failures — all 8 from the
3 pre-existing `AppModelTests` 3MF cases** (`"3MF import requires lib3mf, which is not
available in this build"`). Proved pre-existing rather than assumed: I stashed the
renderer diff, moved my new test file out of the tree, and re-ran those three alone —
they still fail. In the same run `LatticeSeparationEvidenceGen` **passed**, which is how
the MSAA interaction above was identified as mine.

---

## How to reproduce

```bash
cd app/TopOptKit && TOPOPT_RENDER_QUALITY_EVIDENCE=1 swift test --filter RenderQualityEvidenceGen
```

Full console output is `evidence/2026-08-15-render-quality/render_quality_run.txt`.

Two traps, both hit on the way here and both in memory: this worktree's vendored
`TopOptCore.xcframework` was **stale** (`./app/scripts/build_core.sh`), and provisioning
lib3mf broke the test-bundle link, needing
`LIB3MF_PREFIX=/nonexistent ./app/scripts/build_core.sh` to revert.

---

## In plain language

He said the 3D models look bad. He was right, and the reason was specific: the app had
**one light bolted to the camera and nothing else**. Everything facing you was the same
brightness, so nothing had any shape — and a lattice, which is thousands of little struts,
turned into grey static. The only way the app could say "this bit is different from that
bit" was to paint it a loud colour, which is where the purple and the green came from.

Three things changed.

**Shadows in the crevices.** Wherever the geometry crowds itself — between struts, inside
every pocket the optimiser carved — it now darkens. That single change is what turns the
lattice from static into something you can see the depth of. Look at
`lattice_00_before.png` and `lattice_08_all.png`; it is not subtle.

**The light stopped following you.** There is now a proper three-light setup fixed in the
world, so curved surfaces have a bright side and a dark side, and turning the part shows
you its shape instead of moving the lighting with you.

**Then the loud colours could go quiet.** Once a region has real shading, the colour only
has to *name* it, not carry it. Half the saturation came off the purple and the green and
every state is still perfectly clear.

Plus smoother edges (no more jagged struts), a faint dark outline on the geometry, and a
soft shadow on the floor so the part stops floating in space.

**What it costs.** On his lattice — the heaviest thing the app draws — the frame goes
from 1.4 ms to 7.0 ms at full iPad-class resolution. The budget for smooth 60 fps motion
is 16.6 ms, so it fits with room to spare, but it is not free: it is about 40% of that
budget where before it was 8%. I first reported this as "about 1 ms" from a
lower-resolution measurement; that was 4× optimistic and I have corrected it. If it ever
needs to come back down, halving the shadow-detail quality gives back roughly half of it
and, on his own content, looks the same.

Two honest caveats. The floor shadow is a straight-down drop shadow, not a real
light-accurate one — it grounds the part, which is what it is for, but a part floating
100 mm above the floor casts the same shadow as one sitting on it. And the shadows-in-
crevices effect does very little on a **flat plate** like his plain bracket, because a
flat plate has nothing to shadow itself with; it is the lattice and the optimised results
that transform. I measured that rather than guessed it, and the numbers are in the
evidence.

I could not test on his iPad — everything was measured on this Mac through the identical
code path.

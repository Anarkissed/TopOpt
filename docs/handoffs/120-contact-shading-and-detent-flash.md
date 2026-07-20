# Handoff 120 — Round-3 finisher: intersection contact shading (7b/7c) + detent face flash (item 2)

Branch: `claude/round3-depth-prepass-detent-49437c`, on top of `main` (through #144). This finishes
the two round-3 items handoff 115 could **not** ship because that session ran in a Linux CI
container with **no Swift toolchain and no Metal GPU**: the parts-b+c contact treatment (the plan
was written but "ready-to-apply, do on macOS") and the item-2 detent flash (shipped as a toast
stand-in). This session had the macOS toolchain **and** a real GPU, so everything below is
self-run and GPU-captured.

Territory: `MetalMeshView` (shaders + pipelines), `DesignBox.swift` (`DesignBoxDetent.matchedFace`),
`WorkspacePlaceholder.swift` (detent flash wiring). App only.

## What shipped

### Items 7+8 parts b+c — the translucent-intersection contact treatment

Part a (the z-fighting depth bias) shipped in 115. Parts **b** (bright contact line) and **c**
(interior contact-occlusion) are now implemented exactly per 115's ready-to-apply plan:

1. **Depth prepass** (`depthPrepassShaderSource` / `depthPrepassPipeline`): before the main pass,
   when a translucent volume is present, the opaque part is rendered into a drawable-sized
   **R32Float** texture holding each nearest surface's **eye-space depth** (a large sentinel where
   no part covers the pixel). You cannot sample the depth attachment you are rendering into, so the
   part's depth is captured in its own pass first (`encodeDepthPrepass`). Reuses the mesh's
   position + flex buffers so the captured depth matches the visible part exactly.
2. **Contact shader** (`contactShaderSource` / `contactPipeline`): **ONE** variant used by **BOTH**
   the design-box glass and the clearance face draws (`encodeVolume` is the single shared call
   site). It replaces `ground_fragment` for those faces, reads `sceneDepth` at the fragment's
   `[[position]].xy`, and adds **(b)** a bright additive contact line + **(c)** an interior
   occlusion darkening, driven by `|fragmentEyeZ − sceneEyeZ|`. Away from the part it is
   byte-identical to `ground_fragment`, so only the contact region changes.
3. **Static** (108 rule): the prepass + contact pass run only on a redraw, gated on a volume being
   present AND the pipelines having built — **zero** idle-time cost, zero cost when no volume.

**Deviation from the plan, and why:** the plan specified the depth gap `d` compared against an
eye-space/world band. Measured on the GPU, a world-space band scaled to the model diagonal is
**sub-pixel** at a real intersection curve (the before/after diff was **1 px** — invisible). The
shipped shader instead divides `d` by `fwidth(eyeZ)` to get the gap **in screen pixels**, then
feathers with a `contactFeatherPixels = 1.5` line and a `contactOcclusionPixels = 7` occlusion
falloff. This is scale- and resolution-independent (a crisp ~1.5 px line at any model size), and it
makes the honesty caveat's grazing-angle thickening emerge **for free**: at a grazing angle `eyeZ`
changes fast per pixel (large `fwidth`), so `dPix` stays small across many pixels and the line
thickens.

**Honesty caveat (baked verbatim into the `contactShaderSource` header comment, per plan step 5):**

> this is a screen-space depth-proximity effect, not a true analytic intersection curve. Known
> failure mode: at grazing angles the depth gradient is shallow, so `d` stays small across many
> pixels and the contact line thickens. That's expected and acceptable for the contact read.

**The bug that cost the most time** (documented so the next person doesn't repeat it): the contact
FRAGMENT also declares `CUniforms u [[buffer(1)]]` (it reads the pixel feather/occlusion), so the
fragment's index-1 buffer must be bound with `setFragmentBytes` — binding only the **vertex** stage
made Metal silently **drop the draw** (0 visible fragments), exactly the trap `loadpath_fragment`
documents. Fixed + commented.

### Item 2 — detent face-highlight PULSE replaces the toast

The magnetic face-detent (item 10, shipped 115) fired a `model.toast = "Snapped to face"`. That
toast is **gone**; a fresh snap now **flashes the matched part face in the Metal viewer**, same
trigger (`didSnap`) and same haptic (`ClearanceHaptics.detent()`):

- `DesignBoxDetent.matchedFace(axis:coord:faces:)` (pure, headless-tested) maps the snapped
  coordinate back to the B-rep face id whose ⟂-plane sits there (nil for an AABB-extent snap → only
  the haptic fires).
- The renderer pulses that face: `beginDetentPulse(faceID:)` overrides the face's per-vertex tint
  with a gold `sin`-envelope alpha (0 → peak → 0 over `pulseDuration = 0.42 s`), reusing the
  existing tint buffer (no new pass). Like the settle, it drives continuous redraw only WHILE
  active, then returns to on-demand — a bounded, user-triggered animation, not an idle loop.
- Threaded through as `MeshViewInputs.detentPulse` (a `DetentPulse` = face id + monotonic token, so
  re-snapping the SAME face re-pulses); the coordinator fires it when the token advances.

## Evidence (self-run on macOS + GPU — the thing 115 could not do)

- **`swift test --no-parallel`**: my new/changed suites are green — `ContactShadingTests` (8) +
  `DesignBoxTests` (34, incl. the new `matchedFace` cases) = **40 passing, 0 failures**. The full
  suite has exactly **2 pre-existing failures**, both in
  `ClearanceDerivationTests.testBoreHandlesMatchTheRenderedVolume` (a bore-handle count, 2 vs 3) —
  **verified to fail on the pristine branch HEAD with my changes stashed**, so it is NOT caused by
  this work and is out of territory (clearance derivation, not the viewer). Worth a separate look.
- **Captures** (headless `renderOffscreen`, 512², into `docs/handoffs/assets/`):
  `120_contact_cylinder_before.png` / `_after.png`, `120_contact_box_before.png` / `_after.png`.
  Before = plain depth-biased faces (part a only); after = the bright contact line where the volume
  meets the part + the interior occlusion. The tests assert before ≠ after in a bounded pixel band
  (a contact band, not the whole frame) so the effect can never silently regress to a no-op.
- **Frame-cost delta of the prepass** (`testDepthPrepassFrameCostIsBounded`, 512² redraw, 40-iter
  mean): base `1.859 ms` → with contact `1.870 ms`, **delta ≈ 0.011 ms/redraw**. The prepass is one
  extra opaque pass, gated on a volume being present. **Idle cost is unchanged (zero):** the viewer
  is on-demand (`isPaused` + `enableSetNeedsDisplay`), so idle frames don't redraw at all.

## Device-QA follow-ups (feel, not correctness — no GPU capture can settle these)

- The contact-line intensity/tint (`mix(white, hue, 0.35) * 0.9`), the `1.5 px` feather and `7 px`
  occlusion falloff, and the `0.42` occlusion floor are tuned against the headless captures; confirm
  they read well on-device against a real STEP part and adjust `contactFeatherPixels` /
  `contactOcclusionPixels` / the shader constants to taste.
- The detent pulse colour (gold `1.0, 0.82, 0.35`), `0.42 s` duration and `sin` envelope are a
  first pass — confirm the flash reads as "that face" on-device.

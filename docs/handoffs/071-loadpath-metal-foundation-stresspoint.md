# Handoff 071 — Load-path redesign → Metal: alive flow + moving epicenters + load→stress-point

**Track:** app — `/app/` only. `/core/`, `tests/fixtures/**`, `ROADMAP.md` untouched.
ROADMAP box **not** checked (device QA of the "alive" feel is the maintainer's call).

**Worktree:** `.claude/worktrees/affectionate-newton-c99e38`
(branch `claude/loadpath-metal-animation-b5bb48`).

Ports the approved browser prototype (handoff 070,
`docs/prototypes/loadpath/loadpath-redesign.html`) to the real Metal renderer: the
old principal-stress **hedgehog** (a static field of tiny direction glyphs) is
replaced, in the Load-path chip, by a few flowing red **comet-arrows** that stream
LOAD → hot-spot, wiggle as they travel, and drag a hot bloom of stress with them —
through a semi-transparent x-ray body. The controls live in the existing compact
right-rail chip drawer, not a big panel.

**Not blocked.** All three inputs the mode needs already exist and are consumed as-is:
principal-stress directions (`LoadPath` glyphs, viz.4), the peak-stress hot-spot
(`StressField.peak()`, viz.2), and the load locations — the tagged load-group
centroids, threaded in from the workspace exactly like `appliedLoadKg` is (app-side
`ForceModel`/`SelectionModel` data, NOT a core field). No field was faked.

---

## What shipped (the acceptance items)

1. **The "alive" animation FOUNDATION (mode-agnostic).** One red comet-arrow per path
   flows from the load along its curve — travelling-sine undulation with the amplitude
   tapering to zero at the head (clean arrowhead), comet radius taper, additive halo
   glow, per-path phase/speed desync so arrows never beat in lockstep. Three motion
   styles (**Sine / Serpentine / Pulse**) are presets of one parameter set. It is a
   flowing, undulating tube rebuilt every frame from a continuous clock — **not** a
   keyframe slide.
   - **A path is just "a curve + a target"** (`FlowCurve`). The animation engine
     (`CometArrow`) never asks where the curve came from. Adding the **load→anchor**
     mode (the separate follow-up) is: add a `case` to `FlowPathMode` and a branch in
     `LoadFlowField.curves` that emits different `FlowCurve`s. The comet animation, the
     moving epicenters, the renderer, and the whole drawer are reused **unchanged**.

2. **Moving stress-epicenters.** Each arrow's head is a travelling epicenter: in the
   flow's **Stress** body mode, per-vertex heat is the true static stress fraction
   blended UP toward hot near the nearest arrow head, falling off with distance
   (`LoadFlowEpicenter.heatedFraction`). This **reuses the exact "drive stress colour
   from an animation parameter" coupling** the flex→stress machinery uses — the
   parameter is now arrow position instead of a load multiple.
   - **Honesty:** this is a FLOW viz layered over the real STATIC field. The literal
     **Stress chip** (M7.viz.1) is unchanged and remains the truthful static readout;
     the bloom illustrates how load *travels*, it is not a claim that stress moves in
     waves. The head carries zero undulation (`env→0` at `s=1`), so the epicenter sits
     on the real curve inside the body.

3. **Load→stress-point mode.** Each path integrates a streamline from a load location
   THROUGH the principal-stress direction field (signed toward the target — a principal
   axis has no head/tail) and TERMINATES exactly at the peak-stress hot-spot. A modest
   base pull guarantees convergence without flattening the field's shape, so the ends
   are pinned to the real load point and the real hot-spot while the middle follows the
   derived directions.

4. **Compact-drawer controls** (the Load-path chip's drawer, matching the prototype's
   Tune set, squeezed into the existing drawer): **Motion** (Sine/Serpentine/Pulse),
   **Isolate a path** (All by default; menu appears only with >1 path), **Body**
   (X-ray / Stress / Solid), **Flow speed** (0.2–2.5×), **Wiggle** (0–2×), **Reduced
   motion (static)** toggle. Reuses `SegmentedGlass` + `resultsDrawerChrome`.

5. **Semi-transparent body.** A `bodyAlpha` fragment uniform + a translucent viewer
   pipeline (premultiplied "over", depth-test on / depth-write off, double-sided) draws
   the x-ray (α 0.18) and stress (α 0.5) bodies so the arrows/blooms read THROUGH the
   walls; Solid (α 1) is the unchanged opaque draw.

Default is **all paths together**; **single-path isolation** via the drawer menu.

---

## Files

**New**
- `app/TopOptKit/Sources/TopOptFlows/LoadFlow.swift` — the whole pure engine:
  `FlowPathMode`, `FlowCurve` (resample + arc-length sample), `LoadFlowField`
  (streamline curve builder), `FlowMotionStyle`/`FlowStyleParams`, `FlowBodyMode`,
  `CometFrame`/`CometArrow` (per-frame animated geometry), `CometMesh` (tube/halo/cone
  extrusion → stride-7 pos+rgba), `LoadFlowEpicenter` (moving-bloom heat).
- `app/TopOptKit/Tests/TopOptFlowsTests/LoadFlowTests.swift` — 18 headless tests.

**Modified**
- `ResultsModel.swift` — `loadLocations` init param; flow state (`flowStyle`,
  `flowBodyMode`, `flowSpeed`, `flowWiggle`, `flowReducedStatic`, `flowIsolate`,
  `flowClock`); cached `selectedFlowCurves`/`flowLoadSeeds` (with a max-deflection
  fallback seed); `flowCometFrames`/`flowHeadPositions`/`flowStressTints`/
  `flowGuidePolylines`/`visibleFlowCurveIndices`; clock/isolate resets on
  toggle/select.
- `MetalMeshView.swift` — `bodyAlpha` in `viewer_fragment` (premultiplied; α 1 =
  byte-identical opaque); additive **comet** pipeline (reuses the ground pos+rgba
  shaders) + **translucent body** pipeline + depth state; `setLoadFlow` /
  `setFlowGuides` / `setBodyAlpha` / `clearLoadFlow`; comet+guide draw in `encode`;
  new `MeshViewInputs` channels + coordinator wiring (comet re-uploaded every tick).
- `ResultsScreen.swift` — expanded `loadPathDrawer` (the control set); the flow
  geometry properties (`loadFlowVertices`/`loadFlowGuides`/`bodyAlpha`); stress tints
  routed to the moving-epicenter path in flow mode; ticker advances `flowClock`.
- `WorkspacePlaceholder.swift` — computes the load-group centroids (`loadFlowSeeds`)
  and passes them to `ResultsScreen`.

The old load-path hedgehog code (`setLoadPath`/ribbon pipeline, `loadPathSegments`,
`advanceLoadPath`) is left intact (still unit-tested) but no longer fed by the results
screen — the redesign replaces its RENDERING while the `LoadPath` glyph field remains
the DATA source for the flow curves.

---

## Verify (headless, macOS)

`xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'` → **TEST
SUCCEEDED**. `swift test` aggregate: **364 tests, 0 failures**. New suite:

```
Test Suite 'LoadFlowTests' passed
  Executed 18 tests, with 0 failures (0 unexpected)
```

The 18 cover the acceptance's headless targets:
- **path-curve generation** — resample spacing/clamp; streamline terminates at the
  hot-spot, signs the principal axis toward the target, bends with the field yet
  converges; model-level curves terminate at the hot-spot from each load, and fall
  back to the max-deflection node when no load is tagged.
- **epicenter-color mapping** — heat peaks at the head, cools with distance (smoothstep),
  clamps to 1, no-heads = base; and at the model level the bloom actually changes the
  body tints.
- **mode/isolation logic** — one curve per seed; isolate restricts the visible set +
  comet-frame count to one; out-of-range isolate defends to all; toggle resets
  clock/isolate and is mutually exclusive with flex; the clock only advances while on.
- **comet + translucent body GPU smoke** (`renderOffscreen`) — a translucent body
  changes the raster, comet geometry adds pixels, and `clearLoadFlow` restores the
  opaque baseline exactly.

**Device QA remains** (the M7 `/app/` standard — the "alive" feel is not a headless
assertion): the on-device look of the wiggle/glow, the x-ray legibility, drawer
placement, and the per-frame cost of `flowStressTints` (it re-samples all mesh vertices
× heads each frame in Stress body mode — same cost class as the existing flex→stress
recolor; memoize if a hitch shows on a large mesh).

**Build note:** `app/TopOptKit/vendor/` (the prebuilt core xcframework, git-ignored) is
required to build/test the package. This worktree had it symlinked from the primary
worktree for verification; a fresh checkout needs `app/scripts/build_core.sh` first.

---

## Architecture note for the follow-up (load→anchor mode)

`LoadFlowField.curves(mode:…)` is the only place that knows about `.stressPoint`. To add
`.anchor`: add the case + an anchor-seeking curve builder (e.g. integrate the load path
down to the nearest clamped anchor centroid — anchor centroids come from the same
`ForceModel`/`SelectionModel` centroid path the load seeds do). Everything downstream —
`CometArrow`, `CometMesh`, the epicenters, the renderer, the drawer — is mode-blind and
needs no change. A body-mode-style or extra drawer control could pick the mode.

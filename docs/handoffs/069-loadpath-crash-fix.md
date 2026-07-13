# 069 — Load Path chip crash fix (Metal fragment-buffer binding)

**Track:** app (`/app/` only). Core, `tests/fixtures/**`, and `ROADMAP.md` untouched.
**Worktree:** `.claude/worktrees/practical-chatelet-fe617e`
**Status:** Fixed + verified headlessly. ROADMAP box NOT checked (per assignment).

## The bug (SIGABRT, reproduced on device)

Tapping the **Load Path** chip crashed the app with a Metal API-validation abort:

```
Fragment Function(loadpath_fragment): missing Buffer binding at index 1 for u[0].
-[MTLDebugRenderCommandEncoder validateCommonDrawErrors]: failed assertion
Thread 1 SIGABRT
```

Origin: `MeshRenderer.encode(...)` in `app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift`,
the `loadPathRibbonVertexCount > 0` branch — the animated thick-ribbon load-path draw
added in the chips/animations task (068/067).

## Root cause

The ribbon pipeline's shaders **both** declare the load-path uniforms at buffer index 1:

- `loadpath_vertex(... constant LPUniforms& u [[buffer(1)]])` — billboards the ribbon.
- `loadpath_fragment(... constant LPUniforms& u [[buffer(1)]])` — reads `params.z`
  (the flow phase) to scroll the traveling dash.

The draw bound index 1 for the **vertex** stage only (`setVertexBytes(&lpu, …, index: 1)`)
and never bound a **fragment** buffer at index 1. Metal's validation layer aborts the
draw when a declared fragment buffer is unbound — hence the on-device SIGABRT.

## The fix

`MetalMeshView.swift`, ribbon draw branch — add the missing fragment binding before
`drawPrimitives`:

```swift
enc.setVertexBytes(&lpu, length: MemoryLayout<LoadPathUniforms>.stride, index: 1)
// loadpath_fragment ALSO declares LPUniforms u [[buffer(1)]] (flow phase for the dash),
// so the fragment index-1 buffer must be bound too — else Metal aborts.
enc.setFragmentBytes(&lpu, length: MemoryLayout<LoadPathUniforms>.stride, index: 1)
enc.drawPrimitives(type: .triangle, …, vertexCount: loadPathRibbonVertexCount)
```

`lpu` (a `LoadPathUniforms` value) carries `mvp` + `params (aspect, halfWidth, flow, 0)`,
identical to what the vertex stage receives — the two stages share one uniform block.

### Binding audit (both load-path pipelines verified against their shaders)

- **Ribbon** (`loadPathPipeline`): vertex reads buffer 0 (stage_in) + `LPUniforms`@1;
  fragment reads `LPUniforms`@1. Now bound: `setVertexBuffer(rbuf,0)`,
  `setVertexBytes(&lpu,1)`, **`setFragmentBytes(&lpu,1)`**. ✓
- **Fallback line** (`groundPipeline`, used when the ribbon pipeline fails to build):
  vertex reads buffer 0 + `GUniforms`(mvp)@1; fragment (`ground_fragment`) takes no
  buffer. Bindings already correct; no fragment buffer needed. ✓

## Verification (headless)

Extended `LoadPathTests` with `testRendererDrawsAnimatedLoadPathRibbon`, which drives the
exact crashing draw: sets a load-path segment (→ 6-vertex ribbon), sets a non-zero flow
phase, renders offscreen, then advances the phase and re-renders (proving the fragment
uniforms are actually read — the dash animates the frame).

- `swift test --filter LoadPathTests` → **21/21 pass**.
- Under the Metal validation layer that aborts on-device
  (`MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1`): the new test **passes** with the fix.
- Reverting only the `setFragmentBytes` line and re-running under validation reproduces the
  **exact** original abort (`missing Buffer binding at index 1 for u[0]`, signal 6) — so
  the test genuinely catches the regression. Fix restored afterward.

## Pre-existing failures (NOT mine, NOT in scope)

The full `swift test` run shows 5 failures in `RunModelTests` / `TopOptKitTests`
(`minimize_plastic: gravity_direction is (near) zero length`, SIMP-callback count 0).
Confirmed present on the base commit with my changes stashed — they are native-solver /
core test-environment issues, unrelated to this `/app/` rendering fix.

## Files changed

- `app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift` — bind fragment buffer @1 in the ribbon draw.
- `app/TopOptKit/Tests/TopOptFlowsTests/LoadPathTests.swift` — add animated-ribbon GPU smoke test.

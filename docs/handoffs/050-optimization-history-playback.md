# Handoff 050 — optimization-history playback (true history)

## Task (maintainer-directed, interactive)
Playback that shows the ACTUAL optimization — material being carved away as the
solver iterates — replacing the "layers" reveal. Fidelity: **true iteration
history** (maintainer choice). This handoff covers everything except the
Save-video export, which is the follow-up. Not a ROADMAP task — no box.

## What I did — the optimizer now records its history; the app plays it back
End-to-end (core → bridge → Swift → results), tested; the Metal animation is
device QA.

### Core (backward-compatible; V-gates re-run 26/26 green)
- `SimpOptions.keyframe_stride` + `keyframe` callback: when both set, the SIMP loop
  (BOTH the plain and the mask-aware overload) invokes `keyframe(analysis_density)`
  once per `keyframe_stride` OC iterations + the first iteration + the final state.
  Read-only — a pinned COPY in the mask overload — so `x` and the optimization are
  untouched. Off by default (only a null check per iteration otherwise).
- `MinimizePlasticVariant.keyframe_meshes` + `MinimizePlasticOptions.keyframe_count`:
  the driver spreads `keyframe_count` frames across each rung (stride = total iters /
  count; total = summed projection-stage iters, else max_iterations) and sets the
  callback to extract a marching-cubes isosurface per snapshot INLINE — so no density
  fields accumulate (critical at 128³). Frames run ~solid → optimized.

### Bridge / Swift
- `OptimizeVariant` carries the keyframes FLATTENED (scalar vectors only, interop-
  safe): `keyframe_vertices` + per-frame `keyframe_vertex_counts` / `keyframe_indices`
  + `keyframe_index_counts`. Swift `reconstructKeyframes` rebuilds them into
  `[KeyframeMesh]`. The bridge sets `keyframe_count = 12` in both run entry points.
  Keyframes ride the progressive-results stream AND the final outcome.

### App playback
- `ResultsModel`: `hasHistory`, cached `keyframes()`, `playbackMesh` (the keyframe at
  the scrub position), and the pure `keyframeIndex(playT:count:)`.
- `ResultsScreen`: when the variant has history and stress is off, the viewer shows
  `playbackMesh` and Play scrubs THROUGH the real optimization (solid → carved),
  instead of the reveal wipe. Early empty frames make material appear/condense from
  nothing (low-volume rungs start below the iso). Stress overlay still shows the
  final mesh; meshes without history keep the reveal-scrub fallback.

## Test evidence (raw, pasted, unedited)

### Core `ctest` — full V-gate suite (the SIMP loop changed; must be unaffected)
```
26/26 Test #26: cli_demo .........................   Passed  651.03 sec

100% tests passed, 0 tests failed out of 26

Total Test time (real) = 900.11 sec
```

### App package — `xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'`
```
Test Suite 'TopOptFlowsTests.xctest' passed at 2026-07-10 23:38:17.216.
	 Executed 172 tests, with 0 failures (0 unexpected) in 18.039 (18.234) seconds
Test Suite 'TopOptKitTests.xctest' passed at 2026-07-10 23:38:51.333.
	 Executed 21 tests, with 0 failures (0 unexpected) in 33.453 (33.466) seconds
** TEST SUCCEEDED **
```
(210 = 17 design + 172 flows [+2 keyframe] + 21 kit.) Both iOS slices build. Ran
`./app/scripts/build_core.sh` first (core changed).

New tests:
- Core scenario **L**: keyframe capture off by default; `keyframe_count = K` →
  each accepted variant carries ~K frames, the final non-empty (converged shape).
  Honesty-checked (disabling capture fails L).
- `ResultsModelTests`: `keyframeIndex` mapping (start/end/middle/clamp/single/empty);
  history playback selects keyframes; a variant without keyframes has no history.
- `TopOptKitTests.testMinimizePlasticResultsFields` (extended): real bridge — each
  accepted variant returns ≥ 2 keyframes, the last non-empty.

## What I did NOT do
- **Save-video export** — the "download it" half. Rendering the keyframe sequence to
  an mp4 (AVAssetWriter) + share (UIActivityViewController) is a distinct capability
  and the immediate follow-up.
- **Did NOT verify the animation on device** — the scrub-through-history visual, the
  empty→formed effect, and the Play feel are maintainer device QA (M7 standard).

## Warnings for the next run (and device QA)
- **Data volume.** Keyframes (12/variant) cross the bridge on BOTH the stream and
  the final outcome; at Fine (128³) that is a lot of mesh data + memory per run —
  watch it in device QA alongside the projection cost. If heavy: capture fewer
  frames (`keyframe_count`), or keyframes only for the recommended variant, or only
  forward them in the final outcome (not the stream).
- **The keyframe MC is RAW** (no largest-component cleanup) — fine for a preview; it
  can differ slightly from the cleaned final `mesh()`. The last keyframe ≈ but is not
  identical to `mesh()`.
- `./app/scripts/build_core.sh` is REQUIRED before app tests (core changed).
- **`DECISIONS.md`** still carries the maintainer's uncommitted 2026-07-11 print-time
  entry (not part of my commit), as in handoffs 045–049.

## Blocked
None.

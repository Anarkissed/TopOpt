# 064 (v2) — Results animations redone on the merged UI chip-reorg

**Track:** app (`/app/` only — no `/core/`, no `tests/fixtures/**`, no `ROADMAP.md`).
**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/animations-stress-coupling-redo-a8d83b`
**Branch:** `claude/animations-stress-coupling-redo-a8d83b` (cut from current `main` @ `16d9da6`, which includes the merged chip-reorg #62).

This REDOES handoff `064-animations-stress-coupling` on top of the now-merged chip
reorg. The behavior is unchanged from the prior run (it was layout-independent); the
prior run's `ResultsScreen.swift` rewrite could not merge because the reorg rewrote
the same file. The two pure model methods and the MetalMeshView render-state changes
port verbatim; only the ResultsScreen wiring was re-expressed against the reorg's
computed-property layout (the viz controls now live in per-chip drawers, but the
viewer construction and the `showHistory`/`stressTints` derivation are the same
handful of computed vars).

## Files changed (5, all under /app/)

- `app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift`
- `app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift`
- `app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift`
- `app/TopOptKit/Tests/TopOptFlowsTests/ResultsModelTests.swift` (+5 tests)
- `app/TopOptKit/Tests/TopOptFlowsTests/LoadPathTests.swift` (+1 GPU smoke)

## 1. Stress ↔ motion coupling (task item 1) — DONE

Linear FEA: the von Mises field scales with the applied load, so the displayed field
= base field × (current load multiple), recolored against the SAME yield scale. The
existing `pushFactor` / flex amplitude are reused verbatim — no new push mechanism.

- `ResultsModel.stressColorMultiplier(reduceMotion:)` (NEW, pure): `pushFactor` when
  the failure push is active; the flex `flexAmplitude` (0 at rest → 1 at full
  deflection; pinned 1 under reduced-motion) when the flex loop is active; else 1.
- `ResultsModel.stressTints(for:field:multiplier:)`: added the `multiplier` param
  (default 1), applied to each sampled value before the color lookup. The existing
  no-multiplier call sites are unchanged (default 1 = old behavior).
- `ResultsScreen`: stress coloring is now shown when `stressOn` **OR** a deflection is
  animating (`showStressColors`), tints computed at `stressMultiplier`
  (= `stressColorMultiplier`) and sampled against `viewerMesh` (so during the morph
  they color whatever keyframe is on screen). The multiplier is passed to the viewer
  as `stressMultiplier`.
- `MetalMeshView`: added `stressMultiplier` to `MeshViewInputs` + both platform inits;
  the coordinator re-uploads the (already-multiplied) tints whenever the multiplier
  moves (`inputs.stressMultiplier != appliedStressMultiplier`). Without this the
  heatmap froze at the first animation frame — this is the literal missing link that
  makes color move together with the motion.

Result: as the flex wobbles the body cycles blue → hot → blue; as the failure push
ramps to the multiple the whole body flushes red and the peak voxel reaches exactly
yield (20 MPa × 3 = 60 = yield → fraction 1 → red).

## 2. Load path (task item 2) — visible; render-state bug, NOT a missing field

Root cause (occlusion): load-path glyphs sit at voxel CENTRES inside the solid part.
They were drawn with `groundDepthState` (`depthCompareFunction = .less`) against the
opaque mesh, so every interior segment failed the depth test → nothing appeared.

Fix: added `lineOverlayDepthState` (`.always`, no depth write) and switched the
load-path draw to it. The trajectories now overlay the part as an x-ray hedgehog
(the intent — see how force travels through the structure). Mesh / ground / id passes
unchanged. The data was already present (`hasLoadPath == hasFlex`; glyphs build from
the displacement field), so this is NOT a Blocked/missing-field case — no core field
is empty at runtime.

## 3. Stress chip broke playback (task item 3) — DONE

`ResultsScreen.showHistory` used `!model.stressOn && …`, so Stress on fell through to
the slice/reveal viewer instead of the history morph. Extracted the branch into
`ResultsModel.showsHistoryMorph(hasHistory:deflectionActive:loadPathActive:)` (pure,
headlessly tested) with `stressOn` deliberately NOT a factor. The morph and the stress
overlay now coexist (tints sampled per keyframe from `viewerMesh`). Deflection /
load-path still take precedence (they animate/annotate the final formed mesh).

## Divergence from the prior run (intentional)

The prior handoff also deleted `ResultsModel.pushReadout(...)` and two of its tests.
That deletion was an artifact of the prior run's OLDER base and is NOT reproduced
here — the current `main` still uses `pushReadout`, so it and its tests are left
intact. This redo is purely additive to the model + a render-state fix.

## Verification — `xcodebuild test` (macOS)

Build aid: the git-ignored `vendor/` tree (prebuilt `TopOptCore.xcframework`) is absent
in a fresh worktree. It was symlinked from the main worktree for the test run and
removed afterward (untracked; not committed):
`ln -s /Users/nadim/dev/TopOpt/TopOpt/app/TopOptKit/vendor app/TopOptKit/vendor`

Command:
`xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS' -only-testing:TopOptFlowsTests`

```
Test Case '…testStressTintsScaleWithMultiplier]' passed (0.001 seconds).
Test Case '…testStressColorMultiplierDefaultsToOne]' passed (0.001 seconds).
Test Case '…testStressColorMultiplierFollowsFlexAmplitude]' passed (0.001 seconds).
Test Case '…testStressColorMultiplierFollowsFailurePush]' passed (0.001 seconds).
Test Case '…testShowsHistoryMorphIgnoresStressToggle]' passed (0.001 seconds).
Test Case '…LoadPathTests testRendererDrawsLoadPathLinesInsideTheSolid]' passed (0.016 seconds).
Test Suite 'TopOptFlowsTests.xctest' passed … Executed 261 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

**TopOptFlows: 261 tests, 0 failures** (255 baseline + 6 added). The interior
load-path GPU smoke ran on a real Metal device (0.016 s, not skipped).

NOTE on the full-package run: `TopOptKitTests` / `RunModelTests` have 5 PRE-EXISTING
failures on this worktree, all `minimize_plastic: gravity_direction is (near) zero
length` — a core/vendored-xcframework issue in `/core`, unrelated to and untouched by
this /app-only change. The `-only-testing:TopOptFlowsTests` slice above is the
relevant, fully-green target.

## Tests added (headless, the M7 /app/ standard)

- `testStressTintsScaleWithMultiplier` — the same field recolors blue→red as the
  multiplier goes 0 → 1 → 2; default multiplier 1 is unchanged behavior.
- `testStressColorMultiplierDefaultsToOne` / `…FollowsFlexAmplitude` /
  `…FollowsFailurePush` — the multiplier tracks rest/flex/push; at the failure multiple
  the peak voxel is red.
- `testShowsHistoryMorphIgnoresStressToggle` — the playback branch morphs with a
  history regardless of Stress; deflection/load-path suppress it.
- `testRendererDrawsLoadPathLinesInsideTheSolid` — interior load-path lines draw
  (depth-always) instead of being occluded.

## Device QA (out of scope for headless; maintainer to confirm on device)

- Flex: body visibly cycles blue → warm → blue while the geometry wobbles.
- Failure push: dragging 1× → failure flushes the whole body to red and lights the
  failure marker.
- Load path: toggling "Load path" shows visible coloured trajectories over the part.
- Stress + Play: pressing Play with Stress on MORPHS (carves out) — no slice-reveal.

## Notes / follow-ups

- Per-frame O(N) tint recompute + re-upload while animating is accepted (matches the
  existing `stressTints` perf note). If a device hitch shows, memoize on
  `(selectedIndex, multiplier)` or move the 5-stop ramp into the shader.
- The load-path overlay is intentionally x-ray (depth-always). Occluding it behind the
  near surface would need a depth bias / two-pass approach — deferred; visibility was
  the acceptance bar.
- ROADMAP box deliberately NOT checked (per task instruction; verification is headless,
  visual is device QA).

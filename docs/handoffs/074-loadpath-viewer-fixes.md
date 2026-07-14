# Handoff 074 — Load-path flow viewer fixes (diagnose → fix)

**Track:** app — `/app/` only. No `/core/`, fixtures, benchmarks, `materials.json`,
`ARCHITECTURE.md`, or ROADMAP box touched. ROADMAP box **not** checked (the "alive"
feel + drawer look + full-orbit feel are the maintainer's device-QA call).

**Worktree:** `.claude/worktrees/gifted-sammet-89ab09`
(branch `claude/load-path-viewer-fixes-9a2220`).

Builds on the 071 Metal load-path foundation. Its engine (`LoadFlow.swift`) is
unit-tested and correct, so this was a **wiring/presentation** pass: instrument, find
why the mode "doesn't show" on device, fix without touching the verified numerics.

> **⚠️ Parallel-task collision (coordination note).** While working I found the PRIMARY
> checkout (`/Users/nadim/dev/TopOpt/TopOpt`, on `main`) carries a **concurrent
> follow-up task's uncommitted work** adding the `.anchor` mode + a mode selector to the
> SAME files this task's spec calls out as SEQUENTIAL (`LoadFlow.swift`,
> `ResultsModel.swift`, `MetalMeshView.swift`, `TopOptKit.swift`). That is the very
> "load→anchor / mode selector" follow-up this task was told to leave out. My work is
> isolated in this worktree (branched off `main` before that work); the two branches
> will need a merge reconciliation. I designed the drawer with a **labelled Mode slot**
> (below) so the anchor selector drops in with no redesign.

---

## STEP 1 — Diagnostic findings (evidence first)

Method: read the full flow path end-to-end (engine → model → view → Metal coordinator),
cross-checked against the 18 passing `LoadFlowTests`, and reasoned the GPU/blend/redraw
behaviour that headless tests can't assert. Device-pixel confirmation is the
maintainer's QA (noted per item).

### a. Camera rotation — **hypothesis REJECTED: already full clamped orbit**
The shared `OrbitCamera` already applies **both** axes with a pole clamp. Evidence:
- `OrbitCamera.orbit(dx:dy:)` — [`OrbitCamera.swift:120`](../../app/TopOptKit/Sources/TopOptFlows/OrbitCamera.swift):
  `azimuth -= dx·k`; `elevation = clampElevation(elevation + dy·k)`.
- `clampElevation` clamps to ±`maxElevation` = `π/2 − 0.05` (`OrbitCamera.swift:81,101`).
- Both gesture handlers pass dx **and** dy: iOS
  [`MetalMeshView.swift:1649`](../../app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift),
  macOS `:1669` (`dy` negated for AppKit's y-up).
- Same on `main`. All three result "viewers" (Stress / Flex / Load-path) are the **one**
  `MetalMeshView` under different overlays (`ResultsScreen.swift:77`), so they share this
  camera — a single camera fix covers all.

So "yaw-only" was **not reproduced in the code**. I did not fabricate a change; instead
I added the missing **regression tests** pinning that elevation moves the view matrix,
that azimuth/elevation are independent, and that pitch clamps at the poles (below). If
the device still feels yaw-only, the next lead is gesture interception upstream of the
pan recogniser — but nothing in the camera/gesture code restricts an axis.

### b. Flow clock / comet re-upload — **advancing correctly; comet is NOT frozen**
The ticker advances the clock and the comet re-uploads every tick:
- Ticker: `Timer.publish(every: 1/30)` (`ResultsScreen.swift:46`) → `.onReceive` calls
  `model.advanceFlowClock(1/30)` while `loadPathOn && !reduced` (`:116`).
- `advanceFlowClock` bumps the `@Published flowClock` (`ResultsModel.swift:905`) →
  `ResultsScreen.body` re-evaluates → `loadFlowVertices` rebuilds from
  `flowCometFrames(flowClock)` (`:221`) → `updateUIView` → the coordinator re-uploads
  `setLoadFlow(...)` **unconditionally each tick** and marks dirty → `setNeedsDisplay`
  (`MetalMeshView.swift:1550-1567,1591`). MTKView is on-demand (`isPaused=true`,
  `enableSetNeedsDisplay=true`).

Conclusion: the **comet geometry animates**. The maintainer's "arrows don't animate"
is best explained by (e) — the comet rendered as a washed-out white/pink blob, so the
undulation was invisible — and by (d), the bloom genuinely freezing. Fixing colour makes
the motion legible again.

### c. Seed / curve count — **one arrow is CORRECT for the L-bracket (one tagged load)**
Seeds are the tagged **LOAD**-group centroids:
`WorkspacePlaceholder.loadFlowSeeds` maps each load group to its model-space centroid
([`WorkspacePlaceholder.swift:253`](../../app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift))
→ passed as `loadLocations` (`:152`) → `ResultsModel.flowLoadSeeds` (`:776`). The demo
L-bracket has **one** tagged load → **one seed → one curve → one arrow**. Not a dropped
seed. Only when **zero** loads are tagged does it fall back to a single max-deflection
node (`ResultsModel.swift:781`). Multi-load parts get one arrow each; the isolate menu
only appears when `flowCurveCount > 1` (`ResultsScreen.swift:372`) — so a single-load
part shows **no empty menu**. The all-vs-one path is verified with a 2-seed model in
tests.

### d. Moving bloom — **root cause found: the bloom was FROZEN (never re-uploaded)**
The moving-epicenter tints are computed correctly every tick (`stressTints` reads the
live heads, `ResultsScreen.swift:161-165`; `flowStressTints`,
`ResultsModel.swift:869`). **But the coordinator never re-uploaded them while the arrows
travelled.** The stress re-upload was gated on
`dirty || !appliedStress || stressMultiplier changed` (`MetalMeshView.swift` stress
block). In load-path mode the mesh doesn't change (`dirty=false` at that point),
`appliedStress` is already true, and `stressMultiplier` is the **flex/failure** load
multiple — which **does not move** in load-path mode. So the very first frame's tints
stuck while the heads (and comet) moved on → the bloom sat still. That is why the bloom
"didn't travel." (Strength itself was fine but conservative.)

### e. Arrow colour white/pink — **root cause: additive over-accumulation**
The comet draws with **additive premultiplied** blending, stacking halo + core + head
cone + head-halo (`CometMesh.build`, `LoadFlow.swift`). With the old warm red
`(1.0, 0.28, 0.22)` the RED channel saturates to 1 after one or two layers while the
non-trivial green/blue keep summing on top — so the overlapping core/tip washed toward
**pink/white**. Deep-red + trimmed layer alphas keep the tip red no matter the overlap.

---

## STEP 2 — Fixes

| # | Fix | Scope |
|---|-----|-------|
| 1 | Full-orbit camera — **already implemented**; added regression tests | **shared viewer** (all 3 modes + workspace) |
| 2 | Drawer reshaped to a wider "folder" + Mode slot | load-path only |
| 3 | Comet colour deep-red + trimmed additive alphas (restores visible red flow) | load-path only |
| 4 | Show all arrows by default + isolate — **already correct**; strengthened tests | load-path only |
| 5 | Moving bloom un-frozen (re-upload on flow-key) + strength bump | **shared coordinator** gate, load-path-only effect |

**1 — 3D rotation (shared).** No code change needed — the shared `OrbitCamera` already
orbits azimuth **and** elevation with a `±(π/2−0.05)` pole clamp, and both pan handlers
feed `dy`. This is a **shared-viewer** property: Stress, Flex, and Load-path are the same
`MetalMeshView`, so they all already full-orbit. Added `CameraProjectionTests` locking
the behaviour so a future edit can't regress it to yaw-only.

**2 — Drawer folder (load-path only).** `ResultsScreen.loadPathDrawer`:
- Widened content `188 → 236pt` so **no control text wraps** — the Motion segmented
  control now fits **"Serpentine" on one line**. Belt-and-braces: `SegmentedGlass` labels
  got `.lineLimit(1).minimumScaleFactor(0.8)` (a shared-control hardening).
- New `loadPathFolderChrome`: the panel reads as a **folder body** with a small rounded
  **tab poking up at the top-trailing edge** — i.e. just to the LEFT of the "Load path"
  chip it hangs from. Reuses the same panel surface/stroke/shadow as
  `resultsDrawerChrome`; still a compact right-rail folder, not a full panel. (Used a
  plain `RoundedRectangle` for the tab, **not** `UnevenRoundedRectangle` — the latter
  forces a direct `SwiftUICore` link the headless SwiftPM test product can't resolve.)
- **Mode slot left on purpose:** a `MODE` label + a single locked segment reading
  "Load → Stress point", styled exactly like `SegmentedGlass`. The follow-up swaps that
  one line for a 2-segment selector bound to a mode enum with **no folder reflow**.

**3 — Comet colour (load-path only).** `ResultsModel.flowColor` `(1.0,0.28,0.22) →
(1.0,0.12,0.07)`; `CometMesh` layer alphas trimmed (halo `.22→.16`, core `.9→.7`, cone
`1.0→.85`, head-halo `.30→.22`). Deep red + lighter stack ⇒ the additive overlap
saturates RED (a glowing red core/tip) without lifting green/blue into pink/white.

**4 — All-by-default + isolate (already correct).** Default `flowIsolate == nil` shows
all curves; the drawer's picklist isolates one and back to all; out-of-range defends to
all (`ResultsModel.visibleFlowCurveIndices`). No behaviour change; tests strengthened to
assert the default-nil / all / one / back-to-all / out-of-range path on a multi-load
model.

**5 — Moving bloom (coordinator gate).** Added a `flowTintsMoved` trigger to the stress
re-upload: `inputs.loadFlowVertices != nil && inputs.loadFlowKey != appliedFlowKey`
(`MetalMeshView.swift` stress block). Now in the "Stress" body the tints re-upload every
tick, so the bloom **travels with the head** instead of freezing at frame 0. Also raised
`epicenterStrength 0.55 → 0.7` so the travelling bloom is unmistakable. The gate change
is in the **shared coordinator** but only fires when a flow is active (x-ray/solid pass
nil `stressTints`, so no effect there). **Honesty preserved:** the literal static Stress
readout (`ResultsModel.stressTints`) is untouched and independent of the heads/clock —
pinned by a new test; the bloom is a flow layer over the real static field, the base
field is not faked.

---

## Files changed (all `/app/`)

- `TopOptFlows/ResultsModel.swift` — `flowColor` deep red; `epicenterStrength` 0.55→0.7.
- `TopOptFlows/LoadFlow.swift` — `CometMesh` additive-layer alphas trimmed (+ comment).
- `TopOptFlows/MetalMeshView.swift` — stress re-upload also fires on flow-key change
  (un-freezes the moving bloom).
- `TopOptFlows/ResultsScreen.swift` — folder chrome + widen + `MODE` slot for the drawer.
- `TopOptDesign/SegmentedGlass.swift` — labels `lineLimit(1)+minimumScaleFactor` (no wrap).
- `Tests/TopOptFlowsTests/CameraProjectionTests.swift` — 3 orbit tests (elevation moves
  the view, axes independent, pole clamp).
- `Tests/TopOptFlowsTests/LoadFlowTests.swift` — default-all/isolate strengthened;
  clock-moves-heads vs reduced-frozen; static-readout-unchanged-by-flow.

---

## Verify (headless, macOS)

`swift test` (worktree, macOS) → **`Executed 369 tests, with 0 failures (0 unexpected)`**
(`Test Suite 'All tests' passed`). Up from **364** at handoff 071 — the +5 are this
task's new/strengthened tests. The two touched suites:

```
Test Case '-[…CameraProjectionTests testElevationOrbitChangesViewMatrix]' passed
Test Case '-[…CameraProjectionTests testAzimuthAndElevationAreIndependent]' passed
Test Case '-[…CameraProjectionTests testElevationClampsAtPoles]' passed
    CameraProjectionTests — Executed 8 tests, with 0 failures

Test Case '-[…LoadFlowTests testAdvancingFlowClockMovesHeadsUnlessReduced]' passed
Test Case '-[…LoadFlowTests testStaticStressReadoutUnchangedByFlowClock]' passed
Test Case '-[…LoadFlowTests testFlowIsolationRestrictsVisibleCurves]' passed   (strengthened)
    LoadFlowTests — Executed 20 tests, with 0 failures
```

New/changed coverage maps to the required headless targets:
- **Default = all curves** (`flowIsolate == nil`, `visible == 0..<count`), isolate → one
  → back to all, out-of-range → all — on a genuinely multi-load (2-seed) model.
- **Clock moves heads / reduced freezes** — `advanceFlowClock` shifts
  `flowHeadPositions` with motion ON; identical (frozen) with reduced ON.
- **Moving bloom vs static readout** — `flowStressTints` differs across the clock (bloom
  travels) while `stressTints` (the literal static readout) is byte-identical across the
  same clock advance (honesty: base field not faked/altered).
- **Camera elevation** — a vertical drag moves the view matrix and lifts the eye at
  constant radius (pitch applied, not yaw-only); axes independent; pitch clamps at ±poles.

**Build note.** The worktree's vendored core (`app/TopOptKit/vendor/TopOptCore.xcframework`,
git-ignored) was **STALE** — its `libtopopt.a` predated `topopt::expand_design_domain`
(design-box work now called by `bridge.cpp`), so the test executable failed to LINK
(a C++ symbol, unrelated to these Swift changes — the Swift compiled clean). Rebuilt with
`app/scripts/build_core.sh` to unblock the headless link. This is the known "stale
xcframework" blocker; a fresh checkout needs the same rebuild. No `/core/` **source** was
changed — only recompiled.

---

## Device QA (maintainer's call — name them)

- The "alive" feel of the flow now that the comet reads red (not pink/white).
- Arrow colour/legibility through the x-ray body.
- The drawer **folder shape + tab placement** (tab left of the chip) — exact pixel offset
  is tunable (`loadPathFolderChrome`).
- Full-orbit rotation feel on all three viewers (Stress / Flex / Load-path) + workspace.
- The bloom now visibly **travels** with the head over the static field (Stress body).
- Per-frame cost of `flowStressTints` on a large mesh (unchanged cost class; memoise if a
  hitch shows — carried over from 071).

## Not done / out of scope
- The **load→anchor** mode and the Stress-point/Anchor selector (a labelled slot is
  reserved). A parallel task is already doing this on `main` — see the collision note.
- No ROADMAP box checked.

# 077 — Orientation-gizmo branch rebased onto current main (reconcile)

**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/3d-gizmo-orbit-camera-0622db`
**Branch:** `claude/3d-gizmo-orbit-camera-0622db`
**Rebased onto:** `origin/main` @ **`e417eb8`** ("Update TopOpt.xcscheme"), which contains the
multigrid production flip, viewer-fixes (#82), load-anchor-flow (#83), OCCT iOS /
step-import-simulator (#85), and the silent-fail diagnosis (#86).
**Result HEAD:** `057a4a1 3d gizmo` — the branch's single gizmo commit replayed on top of
`e417eb8` (confirmed: `git merge-base --is-ancestor origin/main HEAD` → true).
**Territory:** `/app/` only. No `/core/`, fixtures, benchmarks, materials.json,
ARCHITECTURE.md, or ROADMAP box touched. No redesign — approved gizmo/camera behavior
preserved verbatim; this was purely a rebase reconciliation.
**Vendor:** re-ran `./app/scripts/build_core.sh` after the rebase (main moved core-adjacent
code) → macos-arm64 + ios-arm64 + ios-arm64-simulator, iOS slices OCCT-free. Must be
current to build/test.

---

## Not a redesign — this is the same approved work (handoff 074), reconciled

The branch is one commit (`3d gizmo`) that adds the shared `OrbitCameraModel`, wires it
through `MetalMeshView`, and adds the `OrientationGizmo` + view + tests + the top-left
overlay in the two viewers. Rebasing replays exactly that commit on the new base.

## How the rebase went — conflict-by-conflict

The branch was cut from #80 (`c72f612`). Between there and `e417eb8`, main touched three of
the branch's files. Git's 3-way merge **auto-resolved all of them cleanly** because the
branch's hunks and main's hunks land in **different regions** of each file — there were **no
conflict markers to hand-resolve**. I then verified, per file, that BOTH sides survived
(auto-merge can be textually clean but semantically drop behavior — it did not here):

- **`MetalMeshView.swift`** — main's only change since #80 is the #82 bloom re-upload
  (`flowTintsMoved`) inside the stress block (`6d96670`, part of #82). The branch's changes
  are the Coordinator restructure (shared-camera fields/sink, `attachCameraModel`, the
  mesh-frame handoff, and gesture routing). These sit in different methods/regions, so both
  merged. The #83 load-flow plumbing in this file (`setLoadFlow` / `setFlowGuides` /
  `loadFlowVertices` / `appliedFlowKey`) predates the merge base (handoff 070) and is intact.
  **All three behaviors coexist** — verified below.
- **`ResultsScreen.swift`** — kept #82/#83's `loadDirections`/`anchorPoints` init params +
  pass-through to `ResultsModel`, the Mode selector (`FlowPathMode` / `FlowBodyMode`
  `SegmentedGlass`), and the folder-drawer chrome; ADDED the branch's `cameraModel`
  `@StateObject` (line 47), `camera: cameraModel` on the viewer (84), and the
  `orientationGizmo` overlay (108, defined ~939). Both survive.
- **`WorkspacePlaceholder.swift`** — kept #83's `loadFlowDirections`/`anchorFlowPoints`
  centroid plumbing passed into `ResultsScreen`; ADDED `cameraModel` (48), `camera:` (102),
  and the `orientationGizmo` overlay (129, defined ~202). Both survive.
- **`OrbitCamera.swift`** — main did **not** touch it since #80, so the branch's helpers
  (`setOrientation`, `azimuthElevation(forDirection:)`, `viewRotation`) applied with no
  three-way merge at all.
- **New files** (`OrbitCameraModel.swift`, `OrientationGizmo.swift`,
  `OrientationGizmoView.swift`, `OrientationGizmoTests.swift`) carried over cleanly — all
  present post-rebase.

`git diff --stat origin/main HEAD -- app/` is exactly the branch's 8 files (978 insertions),
i.e. nothing of main's was rewritten — the gizmo work is a clean delta on top of `e417eb8`.

## The three MetalMeshView behaviors coexist — merged stress block

From `MetalMeshView.swift` (the shared-camera mesh-frame handoff immediately precedes the
stress block; the #82 trigger is inside it):

```swift
            let sig = inputs.mesh.map(meshSignature)
            if sig != appliedSignature {
                appliedSignature = sig
                if let mesh = inputs.mesh {
                    // (a) SHARED-CAMERA gesture routing: mirror the model onto the renderer
                    //     BEFORE framing, then hand the framed camera back to the model.
                    if let model = cameraModel {
                        renderer.camera = model.camera
                        renderer.setMesh(mesh)
                        model.adopt(renderer.camera)
                    } else {
                        renderer.setMesh(mesh)
                    }
                }
                appliedTint = nil
                lastSettleVector = nil
                dirty = true
            }
            ...
            if let stress = inputs.stressTints {
                // (b) #82 MOVING-BLOOM re-upload: re-upload when the flow clock advances,
                //     not only when the multiplier moves — else the bloom freezes frame 1.
                let flowTintsMoved = inputs.loadFlowVertices != nil && inputs.loadFlowKey != appliedFlowKey
                if dirty || !appliedStress || inputs.stressMultiplier != appliedStressMultiplier
                    || flowTintsMoved {
                    appliedStress = true
                    appliedStressMultiplier = inputs.stressMultiplier
                    renderer.setStressTints(stress)
                    dirty = true
                }
            } else { ... }
```

- **(a) shared-camera gesture routing** — present: `attachCameraModel` subscribes to
  `model.$camera` and mirrors it onto `renderer.camera`; `handlePan`/`handlePinch`
  (iOS) and `handlePan`/`handleMagnify` (macOS) call `model.orbit` / `model.zoom` when a
  model is attached (lines ~1700–1745). The mesh-frame handoff above keeps the model the
  single source of truth on a mesh swap.
- **(b) #82 moving-bloom re-upload** — the `flowTintsMoved` trigger (line 1506) is intact in
  the stress block.
- **(c) #83 load-flow / anchor wiring** — `setLoadFlow` (876), `setFlowGuides` (888), the
  `loadFlowVertices` inputs (both platform inits) and the per-frame re-upload block
  (`if let flow = inputs.loadFlowVertices` ~1582) are intact; ResultsScreen/Workspace feed
  `loadDirections`/`anchorPoints` through.

## Evidence (raw)

`cd app/TopOptKit && swift test`:
```
Test Suite 'All tests' passed
	 Executed 404 tests, with 0 failures (0 unexpected) in 54.737 (54.764) seconds
```

Named suites green **together** (one invocation, `--filter` each):
```
Test Suite 'CameraProjectionTests' passed   — Executed  8 tests, 0 failures
Test Suite 'LoadAnchorFlowTests'  passed   — Executed 14 tests, 0 failures   (#83)
Test Suite 'LoadFlowTests'        passed   — Executed 20 tests, 0 failures   (#82)
Test Suite 'OrientationGizmoTests' passed  — Executed 15 tests, 0 failures   (this branch)
Test Suite 'ViewerTests'          passed   — Executed 26 tests, 0 failures
	 Executed 83 tests, with 0 failures (0 unexpected)
```

iOS build (exercises the `#if os(iOS)` gizmo/gesture branch macOS `swift test` skips):
```
xcodebuild build -scheme TopOpt -destination 'generic/platform=iOS Simulator'
** BUILD SUCCEEDED **
```

## Honest notes / anything unresolved

- **`ViewerVisibilityRegressionTests` (#75) does not exist under that name on current main.**
  The #75 viewer-regression work was a *diagnosis* branch
  (`claude/diagnose-viewer-regression-ios-64afcf`); no test suite by that literal name is in
  the tree. The standing viewer coverage that IS present and green is **`ViewerTests`** (26)
  plus the #82 **`LoadFlowTests`** (20) — I ran those in the named-suite batch above. The
  full 404-test suite (which includes every viewer/results/load-flow test on main) passes,
  so no viewer regression was introduced. Flagged so the reviewer knows the exact `#75`
  suite name was a mis-reference, not a dropped run.
- No conflict markers were produced by the rebase (clean 3-way auto-merge); I verified
  survival of both sides by inspection + the green named suites rather than by editing
  conflict hunks. Nothing was left unresolved.
- No ROADMAP box checked. The prior handoff `074-orientation-gizmo-shared-camera.md` remains
  (documents the gizmo design); this doc only covers the rebase.

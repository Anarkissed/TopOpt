# 075 — Viewer regression diagnosis: "3D models don't display on iOS Simulator"

**Track:** app · **Type:** DIAGNOSE-FIRST · **Territory:** `/app/` (read `/core/`, no core changes)
**Verdict:** **No render/merge regression exists.** The shared Metal viewer is verified
drawing a real STEP model on the iOS Simulator. The blank viewer is the *upstream*
OCCT-free-simulator STEP-import gap (a mesh never reaches the working renderer), which is
the known separate packaging issue — NOT a fault introduced by PRs #78–#83.

---

## STEP 1 — Reproduce + localise with git

### First-bad commit: there is none (for the render path)

Lineage of the merges under suspicion (`git log --graph`):

```
1a04004  Merge #83 (anchor-mode)     parents: fabfb0c (#82) , b2ccd2e (#83 tip)
fabfb0c  Merge #82 (viewer-fixes)    parents: 7dc1f2b (#81) , 6d96670 (#82 work)
b2ccd2e  #83 tip  ← 5116192 ← c72f612 (#80 merge)   ← #83 branched from #80, NOT #82
```

Key facts established with `git show` / `git diff`:

- **`MetalMeshView.swift` (the shared renderer + all Metal pipelines + shader source) is
  byte-identical between `6d96670` (#82) and `HEAD`** — `git diff 6d96670 HEAD -- …/MetalMeshView.swift`
  is empty. Across the entire #78→#83 range the ONLY change to this file is #82's one
  bloom re-upload hunk in the coordinator (the `flowTintsMoved` / `appliedFlowKey`
  trigger), which **is present in HEAD**. The shader/pipeline code is unchanged since
  before #78.
- The `1a04004` merge base is `c72f612` (#80), so both sides independently edited
  `ResultsScreen`/`ResultsModel`/`LoadFlow` — a genuine three-way conflict merge. I read
  the combined + both directional diffs: **the merge is clean.** #82's work survives
  (deep-red comet `flowColor = (1.0, 0.12, 0.07)`, `epicenterStrength = 0.7`, the
  folder-drawer chrome `loadPathFolderChrome`/`modeSlot`, the bloom re-upload) AND #83's
  anchor mode survives (`FlowPathMode` cache, `anchorVoxelCache`, `loadDirections`/
  `anchorPoints` plumbing). No dropped hunk, no duplicated declaration.
- No app navigation/import code (`AppModel`, `ProjectModel`, `ImportSheet`) changed in the
  range — the import→workspace flow is untouched. Non-test source changes are confined to:
  `bridge.cpp`/`.hpp` (#79 tensor field), `LoadFlow`, `ResultsModel`, `ResultsScreen`,
  `WorkspacePlaceholder`, `TopOptKit.swift` (+`SegmentedGlass` +2). The workspace's
  `MetalMeshView(mesh: viewerMesh, …)` call is unchanged.

Because the render path is unchanged and cleanly merged, a git bisect on "does the viewer
draw" has no bad commit — confirmed empirically below.

---

## STEP 2 — Instrumentation (evidence, not theory)

The display is device/sim QA, so I drove the *real* code paths and logged counts.

### (a) Data → renderer, on macOS (OCCT-enabled slice), real STEP files

Imported each fixture through `TopOptKit.importMesh` → `ViewerMesh` → `MeshRenderer.setMesh`
→ `renderOffscreen(128)`, counting lit pixels (shared `encode(into:)` — identical to the
live `draw(in:)`):

```
step/cube.step     : verts=8   tris=12  distinctFaces=6   boundsEmpty=false  → LIT 6164 / 16384
step/cylinder.step : verts=52  tris=100 distinctFaces=3   boundsEmpty=false  → LIT 3769 / 16384
demo/l-bracket.step: verts=116 tris=236 distinctFaces=10  boundsEmpty=false  → LIT 3476 / 16384
```

Non-zero geometry with real B-rep faces reaches the renderer and rasterizes to thousands
of pixels.

### (b) The viewer itself, ON the iOS Simulator

Injected the faceful l-bracket STEP mesh (pre-computed on macOS) straight into the
workspace via a temporary debug launch-arg — bypassing OCCT — and instrumented
`MeshRenderer`. Launched `com.topopt.TopOpt -diagStepMesh` on the booted iPad Pro (iOS 26.5)
simulator and captured `os_log`:

```
DIAG diagOpenWorkspaceWithStepMesh ViewerMesh tris=236 boundsEmpty=false center=(0,0,30) radius=46.9
DIAG project.viewerMesh isNil=false triCount=236
DIAG MeshRenderer INIT ok: main=true id=true ground=true loadpath=true comet=true translucentBody=true
DIAG setMesh flatVertexCount=708 bounds.center=(0,0,30) radius=46.9 empty=false
DIAG encode DRAW vertexDrawCount=708 bodyAlpha=1.0 reveal=SIMD4(1.0, -20.0, 20.0, 0.0)
… (draw executes every frame; no "encode SKIPPED"; zero Metal pipeline/buffer errors)
```

**On the simulator: every Metal pipeline compiles, the 708-vertex mesh uploads, and the
opaque body draw (`bodyAlpha=1.0`, reveal disabled `w=0`) executes every frame.** The
viewer works.

### Which of (i)/(ii)/(iii)? — None.

- (i) *data never reaches renderer* — false when a mesh exists (708 verts uploaded on sim).
- (ii) *reaches it but draw skipped* — false (`encode DRAW` every frame, never SKIPPED).
- (iii) *draws but invisible* — false (`bodyAlpha=1`, reveal `w=0`, camera framed on the
  bounds center/radius; 3476 lit px for the same mesh offscreen).

The failure is **upstream of the viewer**: on the sim, `AppModel.importFile` →
`TopOptKit.importMesh` → `import_step` throws because the simulator core slice is built
**OCCT-free** (`build_core.sh` output: `ios-arm64-simulator (Eigen, OCCT-free)`). The
throw is toasted, `importedMesh`/`viewerMesh` stay nil, and the viewer correctly draws
nothing because it was handed nothing. This matches the maintainer's own observation
("OCCT does not reach the app; no STEP file is loadable") and is the packaging issue the
task scoped out — confirmed here as the *only* cause, with the viewer positively cleared.

---

## STEP 3 — Root cause

**There is no viewer or #78–#83 integration regression.** The shared Metal viewer
initialises all pipelines and draws real STEP-derived, face-bearing meshes on the iOS
Simulator (opaque by default). The "3D models don't display" symptom is entirely explained
by STEP import failing on the OCCT-free simulator core slice — no mesh is produced, so the
(fully working) renderer has nothing to display. The specific mechanisms the brief flagged
were each checked and disproven by direct evidence:

| Hypothesis | Finding |
|---|---|
| #83 merge dropped #82's `setStressTints`/bloom hunk | Present in HEAD; `MetalMeshView` byte-identical to #82 |
| `bodyAlpha` defaults to 0 (body transparent) | `bodyAlpha=1.0` observed on the sim; default is 1 everywhere |
| Camera default framing off-screen/inside-out | Camera frames bounds; 3476 lit px; draws on sim |
| Botched conflict merge (dropped/dup hunk) | Combined + directional diffs clean; both features intact |

---

## STEP 4 — Fix

**No code fix to the viewer or the merge is warranted** — applying one would be a
guess-patch against a non-defect (the brief forbids this). The real remedy for
STEP-on-simulator is the OCCT sim-slice packaging (`build_occt_ios.sh`), explicitly out of
scope for this task.

What landed instead — **regression guards** so a future merge cannot silently reintroduce
the failure modes we ruled out (`app/TopOptKit/Tests/TopOptFlowsTests/ViewerVisibilityRegressionTests.swift`):

1. `testStepImportHandsNonEmptyMeshToViewer` — a normal STEP (B-rep, faceful) import yields
   a non-empty `ViewerMesh` with faces (the data→renderer seam). STL deliberately excluded
   — no faces, not the process path.
2. `testBodyRendersOpaqueByDefault` — with only `setMesh` called (no bodyAlpha/reveal
   overrides), an l-bracket STEP mesh rasterizes to > 500 lit px. Fails if a merge zeroes
   the body-alpha default or leaves the reveal scrub enabled at 0.
3. `testResultsViewStartsFullyFormedAndOpaque` — a fresh `ResultsModel` starts `playT == 1`
   and `loadPathOn == false`, so the results body draws fully-formed and opaque on open.

All temporary instrumentation/debug hooks were reverted; `MetalMeshView.swift` is again
byte-identical to #82.

---

## Feature preservation (both suites green together)

`swift test` (macOS, OCCT slice): **386 tests, 0 failures** (383 pre-existing + 3 new).
- #82 viewer-fixes suites: `CameraProjectionTests`, `LoadFlowTests` — pass.
- #83 anchor-mode suite: `LoadAnchorFlowTests` — pass.
- New: `ViewerVisibilityRegressionTests` — pass.

If those two ever failed together, that would itself be the integration bug — they don't.

## Reproduce / evidence commands

- Build core (vendored xcframework must be current): `app/scripts/build_core.sh` (~48s).
- App suite: `cd app/TopOptKit && swift test`.
- App builds for the sim: `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt
  -sdk iphonesimulator -destination 'platform=iOS Simulator,id=<booted>' build` → BUILD SUCCEEDED.

## Notes / follow-ups

- No ROADMAP box checked (diagnosis task).
- The one live-app path not exercised end-to-end here is a *post-optimize* results mesh
  under the new multigrid(#81)/tensor(#79) core — but `testMinimizePlasticWithProgress`
  and `testMinimizePlasticResultsFields` already assert `meshTriangleCount > 0` on the
  optimized variant and pass, so the solver changes don't yield an empty results mesh.
- If the maintainer still sees a blank viewer with a model that DID load (i.e. on a
  build where STEP import succeeds — macOS/device with OCCT), that is a different report
  than the one investigated here; capture the `DIAG`-style counts on that platform and
  reopen.

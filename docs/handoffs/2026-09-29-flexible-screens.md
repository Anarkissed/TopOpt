# Handoff — 2026-09-29-flexible-screens (TRACK app, A1): the Flexible screens

## Round 3 · batch B — verification pass (read this first)

A verifier read batch B against your rules on YOUR project 0004 (headless renders; the app
was not launched). I confirmed each finding myself, on the code and on your restored project.
Every major has a test that went RED on the code as batch B left it. Each minor has a test
whose inline control shows the old rule failing. I fixed every major and the cheap, safe
minors. One minor is not done; it is listed below with the reason.

**What changes for you:**
- **Exit → the lattice always follows your edits on the main page.** Before, it was kept as
  "Lattice ready" after a new quality (grid), a new lattice region or a new bead width. After
  the two-finger UNDO on the main page, it vanished behind "Building the lattice…" and no build
  ever started. Now the lattice is keyed by the scene it was built on. The main page also
  watches the project (a quarter-second debounce, only while it shows), so it re-opens or
  re-designs and rebuilds.
  - On your project: Fast → Fine gives grid 64×64×13 → 128×128×26 and generation 1 → 2.
  - "sides" set to Lattice gives latticeVoxels 53248 → 4992 and generation 1 → 2.
  - An undo gives a build within 3 s. Undoing [Face 5 rests] makes the pill say the 3/5
    conflict again, not "Building…".
- **A build that fails is said, once.** It had retried for ever (8 starts in 4 s) behind
  "Building the lattice…", and the error had no reader anywhere. Now there is ONE attempt per
  (settings, scene). The pill and the Settings line say "Couldn't build the lattice: <core's
  first sentence>" in warning colour. It is tried again after your next edit, or once more
  when you Save & Exit, and it never blocks Exit.
- **No lattice outside the part.** With face 3's skin off, walls hung up to 12 mm outside the
  part while it squished. The preview's part-distance grid has no margin: its last texel lies
  ON face 3, and beyond it the clamped distance read 0. Beyond the grid, the distance is now
  at least the distance to the grid's box, in the shader and in its Swift twin. On a box
  whose grid ends on a face, GPU F ≤ 0.001 went from 6344 points to 0 of 17784 at s = 0, 2
  and 4. The same probe just inside the face still finds the walls.
  - **My first version of this fix was wrong.** It took max(SDF, 0) inside the grid as well,
    so every interior distance became ≥ 0 and no wall was drawn anywhere. The full suite
    caught it (FlexibleLatticePassTests: "0 in a wall"; FlexibleInPassCompositeTests: nothing
    covered). My own positive control had counted F ≤ 0 and passed on the broken code. The
    control now counts F < −0.01, in the GPU and in the Swift twin, and a mutation run
    restoring the broken line turns it RED (0 wall points inside).
  - Every lattice suite is back to its baseline numbers: 43868 px covered at the 0.04 ghost,
    and 50 of 256 probe points in a wall.
- **The main view gives the battery back.** Settings going up, a stale lattice, or leaving
  the stage mid-play had left #354's main view drawing at display rate. It now returns to
  on-demand drawing, and the dent returns to the page's own squish instead of freezing
  mid-cycle (1321 px → 0 px differ). The Settings page's loop is now stepped by the renderer
  too, so its whole body no longer re-renders 30 times a second while it plays.
- **Every blocker has a button.**
  - With no main-page load and nothing selected, the pop-up says "Press Face 1 or tap the
    face that carries weight" with [Press Face 1]. Face 1 is the face with the most area
    facing up (the pad's top). Before, the pop-up had no button at all.
  - With no filament that has data, the pop-up offers any filament (shape-only).
  - The pop-up now shows the issue as it is NOW: after you tap the face it names, its button
    follows.
- **The blocker pops up at once when Settings opens** (your rule), once, after the scene and
  the designs have landed.
  - A shared stack pulses BOTH faces, one after the other.
  - The camera turns to an oblique corner view from above (Top-Back-Left on your pad). The old
    face-on view of Face 5 hid Face 3 behind it and turned its curve edge-on.
- **Nothing covers Undo / Redo or the gizmo.** At 11" portrait the top line ran over Redo and
  part of Undo and swallowed their taps, and [Fix] sat half under the gizmo. Now the top line
  takes the band right of the Exit row and left of the gizmo. Where that band is narrower than
  460 pt (every portrait iPad up to 11"), it takes its own row under Exit. The pop-up sits
  under it, clear of the gizmo.
  - The legend is placed by the same placement function the tests measure.
  - The main page's player keeps clear of the bottom-right chip column (Gravity …).
- **Words:**
  - The main pill no longer says "Lattice / Lattice ready". It says "Ready", "Building…",
    "Tap to open", and a blocker in short: "Fix: Face 3 & Face 5 share a stack". The whole
    sentence is on the pop-up.
  - A shape-only lattice's timeline ends "As drawn", never "10 kg".
  - A toast clears itself even when no Settings page is up.
- **Main-page views:**
  - Dent heat now shows a thermometer.
  - The Lattice button shows what is drawn. With X-ray off it reads off, and turning it on
    turns X-ray on.
- **From Topology** the pill goes to the Lattice stage first, then opens Settings, so Exit
  shows the lattice.

**Rejected:** none. Every finding reproduced.

**Not done (and why):**
- **Curve points under the Settings panel at 11" portrait** (4 of top A's 7). This needs the
  camera to frame the part right of or above the panel, which means a viewport offset in
  #354's `OrbitCameraModel`. That is not a one-line hook, so I left it for your call rather
  than change the shared camera.
- **Face tags ('3', '5') on the part while the pop-up is up**: not added. Both faces pulse
  and the camera shows both, but the pop-up still names them "Face 3 / Face 5".
- **The camera does not turn to a face with no stack yet** (the "no pressed face" pop-up on a
  fresh part). The turn needs the face's stack. The face is still selected and the button
  presses it.
- **No simulator check** (the launch is refused to me). The Release frame budget was not
  re-measured.
- **Carried over from batch B:** the main-page mesh swap still reframes the camera (#354's
  `applyMesh`), and the per-update tint hash on large parts.

**Your call:**
- **Popping on open.** A blocker standing when Settings opens now pops once (your "at once").
  Batch B had deliberately not popped on open. Say if once per visit is too much.
- **The "no pressed face" suggestion** is the face with the most area facing up (against
  gravity). Say if you prefer the face nearest the camera.

### Each finding, confirmed on the code (RED before the fix → after)

| # | finding (verifier) | confirmed by | before → after |
|---|---|---|---|
| C1 | a failed build retries for ever; the error is never shown | `testAFailedBuildIsTriedOnceAndSaid` (his project, TPU 95A, a forced builder refusal) | 8 starts in 4 s, pill "Building the lattice…" → 1 start, pill and Settings line "Couldn't build the lattice: …"; Save & Exit retries exactly once; an edit rebuilds. Control: an unforced build starts exactly once |
| C2 | a new grid / lattice region keeps the old lattice "ready" | `testANewGridOnTheMainPageRebuilds`, `testANewLatticeRegionOnTheMainPageRebuilds`, `testTheSceneKeyFollowsTheBeadWidth` | grid 64×64×13 → 64×64×13, generation 1 → 1 (timed out) → 128×128×26, generation 2; latticeVoxels 53248 → 4992, generation 2; the key moves with the bead width |
| C3 | main-page undo: stale, walls hidden, "Building…" for ever | `testAnUndoOnTheMainPageRebuilds` | 0 builds in 3 s, pill "Building the lattice…"; undoing [Face 5 rests] still "Building…" → 1 build, generation 3, "Ready"; the conflict is said ("Fix: Face 3 & Face 5 …") |
| C4 | the main view keeps continuous rendering once the loop is taken away; the dent freezes mid-cycle | `testTheLoopTakenAwayMidPlayGivesTheViewBack`, `testTheLoopTakenAwayRestoresTheViewsOwnSquish` | isPaused false (detached and torn down) → true; 1321 of 16384 px off the page's own scale → 0. Control: a pause re-pauses |
| U1 | walls up to 12 mm outside the part while it squishes | `testNoWallOutsideThePartsGrid` (a box whose SDF grid ends ON a face, skin off) | GPU and Swift F ≤ 0.001 at 6344 of 17784 points beyond the face at s = 0 / 2 / 4 → 0 (min F 0.5). Control: walls inside the same face; GPU/Swift parity < 0.02 mm |
| C5 / U3 | "no pressed face" / "no filament" pop-ups with NO button; the pop-up stale after his tap | `testEveryBlockingIssueHasOneToThreeFixes`, `testNoPressedFaceOffersThePadsTop`, `testThePopUpShowsTheIssueAsItIsNow` | 0 fixes (control, the old rule) → [Press Face 1] on the pad; any filament; the live issue shows [Press Face 3] after the tap |
| U2 / U6 | the top line covers Redo/Undo and puts [Fix] under the gizmo; the pop-up covers the gizmo (11" portrait) | `testTheTopLineAndThePopUpClearTheExitRowAndTheGizmo` (744 / 820 / 834 / 1032 portrait, 1194 / 1376 landscape) + page pins | the old pill (190,30 453×40) ∩ redo and gizmo, the old pop-up ∩ gizmo (controls) → the band (24,80 573×40) at 11" portrait, the pop-up (80,132 460×…), no intersection anywhere |
| U4 | shape-only timeline ends "10 kg" | `testTheShapeOnlyTimelineEndsAsDrawn` | → "As drawn" |
| U5 | no pop-up on opening; the shared stack shows one face face-on | `testABlockerStandingWhenThePageOpensPopsOnce`, `testASharedStackIsSeenObliquely`, `testThePipelineSaysWhenADesignRunIsInFlight` | the old prompt silent (control) → pops once when settled; LEFT face-on (control) → Top-Back-Left corner; both faces named and pulsed |
| U7 | pill truncates the fix; "Lattice / Lattice ready" | `testThePillReadsWholeAndSaysLatticeOnce`, `FlexibleMainStageTests.testThePillSaysTheReadinessLine` | → "Fix: Face 3 & Face 5 share a stack", "Ready", "Building…", "Tap to open" |
| C7 | a toast set with Settings closed never clears | `testAToastClearsItselfWithNoPageUp` | the model clears it (0.2 s in the test, 3.5 s live) |
| U9 | icons; X-ray off hides the lattice with Lattice on | `testTheLatticeViewTurnsXRayOn` | thermometer for Dent heat; the Lattice button shows what is drawn and turns X-ray on |
| C6 / U10 | the main player's keep-outs omit the chip column | `testTheMainPlayerClearsTheChipColumn` | a 280 pt chip under the old player (control) → the player moves left (101…441 at 11" portrait) |
| C8 | the legend test measures a function the page never calls | page pin `FlexibleLegendPlacement.legend(size: measured, …)` | the Settings legend is placed by that function (the gizmo and the top line as keep-outs) |
| U12 | the Settings page re-renders 30×/s while the squish plays | `testTheSettingsPageLetsTheRendererStepTheSquish` | the renderer steps the loop while a lattice is drawn; the ticker only for his live drawing |
| U13 | the pill on Topology: "Tap to set up", Exit shows no lattice | H10 pin | a tap goes to the Lattice stage, then Settings; "Tap to open" |
| U11 | 4 of 7 curve points under the panel at 11" portrait | confirmed from the verifier's screenshots | **not fixed** (needs #354's camera) |

### Hook lines in #354 files changed this pass (each grepped after the edit; pinned)

| hook | file · anchor | ± | why |
|---|---|---|---|
| H10 | WorkspacePlaceholder · `FlexibleMainStatusPill(main: flexibleMain, open: {` | ~1 | `open: { if stage != .lattice { goToStage(.lattice) }; showFlexiblePage = true }` — from another stage the pill lands on the Lattice stage, so Exit shows the lattice (`goToStage` is #354's one way to change stage) |
| P | WorkspacePlaceholder · `FlexibleMainPlayerSlot(main: flexibleMain, bottomClearance: bottomBarClearance` | ~1 | `, chipColumnWidth: force.gravityIsSet ? (settingsChipWidths.values.max() ?? 0) : 0` — the player clears `bottomRightControls` (shown under the same condition, widths already measured by #354) |
| M3 | MetalMeshView · `if renderer.applyFlexibleLattice(inputs.flexibleLattice, device: view.device` | ~1 | `, baseScale: appliedFlexScale` — the coordinator's own flexScale comes back when a loop lets go |

No other #354 / main file changed. Everything else is in track files: FlexibleMainStage,
FlexibleStageModel, FlexibleReadiness, FlexibleStagePage, FlexibleFixPopup,
FlexibleLegendPlacement, FlexibleMainStatusPill, FlexibleSquishPlayer, FlexibleLatticeGeneration,
FlexibleLatticeField, FlexibleLatticeShader, MeshRenderer+FlexibleLattice.

### Tests (raw)

RED first, on the code as batch B left it (only a test seam added — `controlFailBuild`):
```
Executed 9 tests, with 23 failures (0 unexpected)
FLEX-REVIEW failed build: starts in 4 s 8 · … · pill 'Building the lattice…' building · Settings line 'Ready: Exit builds a shape-only lattice'
FLEX-REVIEW new grid: 64x64x13 → 64x64x13 · generation 1 → 1 · stale false · pill 'Lattice ready'
FLEX-REVIEW new region: latticeVoxels 53248 → 53248 · generation 1 → 1 · pill 'Lattice ready'
FLEX-REVIEW undo: builds started in 3 s 0 · generation 2 → 2 · stale true · pill 'Building the lattice…'
FLEX-REVIEW undo of [Face 5 rests]: pill 'Building the lattice…' building
FLEX-REVIEW beyond the grid's last texel, s=0.0: GPU F ≤ 0.001 at 6344 of 17784 (min 0.0) · Swift 6344
FLEX-REVIEW loop detached mid-play: paused false · setNeedsDisplay false
FLEX-REVIEW pass torn down mid-play: paused false
FLEX-REVIEW squish after the loop left: 1321 of 16384 px differ from the page's own scale
```
(My first undo test passed on the old code. A model publish left over from the rebuild before
the undo reached the stage's debounce AFTER the undo and started the build. With a 1 s settle
before the undo — which is what the app does, with its run loop running — it is RED: 0 builds.)

Targeted suite after the fixes (every Flexible* suite + UnifiedShading, LatticePreviewBodyAlpha,
LatticeGBufferMask, LatticeThreeAlgorithmsDraw, OrganicCapsuleImpostor, Viewer, StageBackdrop,
SmoothingPageRound2, LatticeStageMode, LatticeSettingsPersist, ProjectStore, UndoHistory,
SurfaceStage, LatticeSimSolveTrigger, batch B's list, and EVERY suite that scans a file I
touched — WorkspacePlaceholder, MetalMeshView, MeshRenderer+FlexibleLattice, FlexibleStagePage:
FrozenRegionAsMaterial, LatticeGradingWiring, LatticeProbeSampling, LatticeRegionCap,
LatticeSDFAlignment, LatticeShellAndMarchAgree, OrganicAutoGradeAndFreeze,
OrganicDeadWallParity, OrganicLookAndVisibility, OrganicPreviewParameterParity,
OrganicPreviewSpeedAndRim, OrganicSolidRim, ProtectFreezeVsSolidity, SmoothingPage,
SmoothingPreviewGate, SmoothingRound3, SmoothingRound4, SurfaceStageGestures, VariantRetention):
```
Executed 655 tests, with 9 tests skipped and 1 failure (0 unexpected) in 631.990 (632.050) seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
```
Every Flexible suite again at the final source (after "Save & Exit retries a failed build once"):
```
Executed 185 tests, with 4 tests skipped and 0 failures (0 unexpected) in 108.351 (108.370) seconds
FLEX-REVIEW failed build: starts in 4 s 1 · error The lattice builder refused: no printable cell. More words. · pill 'Couldn't build the lattice: The lattice builder refused: no printable cell' fix · Settings line 'Couldn't build the lattice: The lattice builder refused: no printable cell'
FLEX-REVIEW control build: starts 1 · pill 'TPU 95A: shape only — no squish predicted'
FLEX-REVIEW new grid: 64x64x13 → 128x128x26 · generation 1 → 2 · stale false · pill 'Ready'
FLEX-REVIEW new region: latticeVoxels 53248 → 4992 · generation 1 → 2 · pill 'Ready'
FLEX-REVIEW undo: builds started in 3 s 1 · generation 2 → 3 · stale false · pill 'Ready'
FLEX-REVIEW undo of [Face 5 rests]: pill 'Fix: Face 3 & Face 5 share a stack' fix
FLEX-REVIEW beyond the grid's last texel, s=0.0: GPU F ≤ 0.001 at 0 of 17784 (min 0.5) · Swift 0
FLEX-REVIEW beyond the grid's last texel, s=2.0: GPU F ≤ 0.001 at 0 of 17784 (min 0.5) · Swift 0
FLEX-REVIEW beyond the grid's last texel, s=4.0: GPU F ≤ 0.001 at 0 of 17784 (min 0.5) · Swift 0
FLEX-REVIEW loop detached mid-play: paused true · setNeedsDisplay true
FLEX-REVIEW pass torn down mid-play: paused true
FLEX-REVIEW squish after the loop left: 0 of 16384 px differ from the page's own scale
FLEX-REVIEW no load: 'Press Face 1 or tap the face that carries weight' fixes [TopOptFlows.FlexibleFix.press(1)] (top face 1)
FLEX-REVIEW shared stack camera: Top-Back-Left
FLEX-PLACE top line 11" portrait: band (24.0, 80.0, 573.0, 40.0) · pop-up (80.0, 132.0, 461.0, 130.0) · gizmo (610.0, 13.0, 211.0, 211.0)
FLEX-PLACE top line mini portrait: band (24.0, 80.0, 483.0, 40.0) · pop-up (35.0, 132.0, 461.0, 130.0) · gizmo (520.0, 13.0, 211.0, 211.0)
FLEX-PLACE top line 13" portrait: band (262.0, 26.0, 533.0, 40.0) · pop-up (179.0, 78.0, 461.0, 130.0) · gizmo (808.0, 13.0, 211.0, 211.0)
FLEX-PLACE top line 11" landscape: band (262.0, 26.0, 695.0, 40.0) · pop-up (260.0, 78.0, 461.0, 130.0) · gizmo (970.0, 13.0, 211.0, 211.0)
FLEX-PLACE main player 834×1194 chip 280: (101.0, 1040.0, 340.0, 46.0) · chip (530.0, 1038.0, 280.0, 48.0)
FLEX-T5 covered at 0.04 ghost: 43868 of 147456; opaque shell 0; control (ghost kept in the G-buffer) 0
FLEX-PROBE gyroid: max |gpu − swift| = 0.00095558167 mm over 256 points (50 in a wall, 206 not); …
```
Mutation run (the shader's first version restored, the test run, the file restored; grep
shows no marker): `testNoWallOutsideThePartsGrid` → "control: walls inside the part (s = 0.0)
… 0 is not greater than 100", in the GPU and in the Swift twin.

**iOS build:** `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration Debug
-destination id=147E56A1… -derivedDataPath …/flexA1 build` → `** BUILD SUCCEEDED **` (exit 0), no
warning in a Flexible file. The app was not launched.

**Deleted-test sweep:** none deleted. Re-pinned on purpose:
- FlexibleMainPageHookTests: H10 and P (their new lines), the `settled:` expression, and new
  pins for the page's placement and live pop-up.
- FlexibleMainStageTests: the pill says the short form.
- FlexibleReadinessTests: one comment (that prompt is action-only).

## Round 3 · batch B — Exit always leaves a lattice on the main Flexible page

(Batch B as it was built. The verification pass above changes several of the lines quoted
here: the pill says "Ready" / "Building…"; a blocker standing on opening now pops once.)

**What you will see** (judged headlessly on YOUR project 0004 restored through `AppModel.open`,
and on C1's pad; the app was not launched — nothing here has been seen on a screen yet):

- **The top line of Settings is a live readiness line.** On your project as saved it reads
  **"1 thing to fix: Face 3 and Face 5 press the same material [Fix]"** — the ONE thing that
  blocks (with TPU 95A too: calibrate-first no longer blocks; the old Generate gate said
  "calibrate-first" first and hid it). When it is clear: **"Ready: Exit builds the lattice"**
  (green), or "Ready: Exit builds a shape-only lattice", or "Ready · Squish shown on the 4
  largest of 7 faces".
- **A blocker pops up at once** when your action caused it (pressing face 5 while 3 is
  pressed): the pop-up selects the face, pulses it on the part, turns the camera to look at it,
  says one sentence and offers big buttons — **[Face 5 rests] [Face 3 rests]**; for a face with
  no weight **[Type the weight]** (the number pad); for a face core cannot stack or design
  **[Face N rests] [Remove Face N]**; with no filament **[colorFabb varioShore TPU]**. Opening a
  project that already has one does not pop (its line says so); recompute noise never pops.
- **Exit is blocked only when truly needed**, and then it reads **"Fix 1 thing"** (orange) and
  opens the same pop-up. Calibrate-first, more than four faces and "still designing" never
  block. Two obvious refusals are fixed for you with a one-line toast (an untested nozzle
  temperature → Auto; a family with no data → Gyroid).
- **No Generate button.** Save & Exit builds the lattice and the **MAIN Flexible page shows
  it**: "Building the lattice…" in the bottom pill, then the lattice squishing inside the X-ray
  part, with your dented map. The bottom bar's octet "Lattice · nothing set to lattice" is
  gone under Flexible; its pill says **"Lattice ready"**, **"Building the lattice…"**, the
  shape-only label, or the one thing to fix (a tap opens Settings on that fix).
- **TPU 95A (and every calibrate-first filament) gets a SHAPE-ONLY lattice** — your answer:
  it follows your curves (softer where you drew softer), it is labelled **"TPU 95A: shape only —
  no squish predicted"**, and the map beside it says "What you drew".
- **The squish player** (your request) on both pages: a white play/pause circle, "Rest" ——●——
  "10 kg", in the Results player's capsule, bottom-centre. Play loops rest → full → rest and
  resumes from where it is; dragging pauses and sets the squish directly — the dent and the
  lattice move together (one number). Reduced motion: no auto-play. It shows only when there
  is something to squish, and its place is computed against the panel, the legend, the top row
  and (main page) the bottom bar, the view buttons and the right-edge legend slot.
- **The main page's views under the gizmo: X-ray, Dent heat, Lattice** (all on). Stress, the
  legends with tap-to-read and the Surface button are batch C.
- **Legends never cover a button**: the Settings page has no bottom-right buttons at all; the
  legend stays on the trailing edge, centred.

**Not done in batch B (honestly):**
- **No simulator check.** The plan's steps 6–7 (install on your project, press 5 and see the
  pop-up, Exit and watch "Building…" then the squish; the Release frame budget on the main
  page) need the app launched, which is refused to me. `xcodebuild` for the simulator
  succeeds; everything else was measured headlessly on your restored project and the pad.
  The loop's own per-frame cost was measured (1.5–4.7 µs per step, Debug); the lattice march
  under it is the same pass T16 measured — not re-measured on a Release build here.
- **Main-page mesh swap.** The main page draws the part WITH its map quads (the overlay mesh,
  like Settings). #354's viewer reframes the camera when the mesh changes, so the first time
  the map appears (and whenever the pressed faces change) your zoom / pan return to the
  framed view; the settle SNAPS under Flexible (hook H4, no 0.8 s spin). Not fixed here: it
  needs a #354 change to `applyMesh`.
- **Main-page vertex tints are hashed per update** by #354's existing `VertexTintKey` (the
  Surface stage pays the same): on a large part every workspace body update (an orbit tick
  publishes `projection`) hashes ~8 floats per flat vertex. Fine on your pad; worth a look on
  the M2 stand in batch C. The dent's own check is O(1) (the flex hook compares the array's
  storage; a full hash was 83 ms per update over 1.2 M floats in Debug — replaced).
- **"One at a time" (load cases)** is the third fix for a shared stack in the plan — it is
  batch D; today the pop-up offers [Face 5 rests] [Face 3 rests].
- **7 pressed faces** are tested on values (the readiness never blocks; the four LARGEST
  squish; only they dent), not on a real build: no 7 pressed faces on the pad avoid shared
  stacks.
- **The Settings page's Export pill** left with Generate (exports still wait on core); the
  export modal is not reachable until core's exporter lands (batch C/D can host it on the
  main page).
- **Your project as saved still has faces 3 and 5 pressed** by the old taps (batch A's
  "your call"): the readiness line and the pop-up now make that one tap to fix.

**Your call:**
- **The shape-only band** is my choice, not a prediction: the finest cell 8 walls (3.4 mm at a
  0.42 mm bead), the coarsest half the pressed face's lattice depth, capped at 12 mm (your pad:
  3.4 … 9.2 mm). Say if you want it firmer / softer overall.
- **Export** is unreachable until core's exporter lands (it left with Generate). Main page, or
  wait for core?
- **Pulse on a split face**: the pop-up pulses the whole B-rep face (top A and top B flash
  together); the selection tint is per sector. Worth a per-sector pulse (a #354 hook)?

### Hooks in #354 / main files (every line, grepped after the edit; pinned by FlexibleMainPageHookTests / FlexibleSquishPlayerTests)

| hook | file · anchor | ± | why |
|---|---|---|---|
| H1 | WorkspacePlaceholder · after `@State private var latticeSettingsSavedThisSession = false` | +1 | `@StateObject private var flexibleMain = FlexibleMainStage()` — the ONE model per project |
| H2 | WorkspacePlaceholder · `FlexibleStagePage(project: project, …` (the `showFlexiblePage` mount) | +3 −4 | the page over `flexibleMain.model(for:…)`; `onExit: { showFlexiblePage = false; latticeSettingsSavedThisSession = true; flexibleMain.didExitSettings() }` (also stops Settings re-popping on every Lattice entry) |
| H3 | WorkspacePlaceholder · the main `MetalMeshView`'s `latticeLayer: … : nil)` | +2 −1 | `: nil,` + `flexibleLattice: flexibleMain.layer(project, stage: stage, pageUp: fullScreenPageUp))` (`latticeLayer: latticeLayerIsDrawn` untouched) |
| H4 | WorkspacePlaceholder · `MetalMeshView(mesh: stageMesh,` | ~1 | `mesh: flexibleMain.mesh(project, on: stage) ?? stageMesh` |
| H4 | · `vertexTints: visible.surfaceEditing ? surfaceVertexTints : nil,` | ~1 | `… : flexibleMain.tints(project, on: stage)` (ghost + dent heat) |
| H4 | · `settleAnimated: !reduceMotion,` | ~1 | `!reduceMotion && !flexibleMain.owns(project, stage)` — a map-mesh swap snaps, never spins |
| H4 | · `stressTints: stageSurfaceTints,` | ~1 +1 | `flexibleMain.owns(project, stage) ? nil : stageSurfaceTints` + `flexDisplacements: flexibleMain.dents(…), flexScale: flexibleMain.dentScale(…)` |
| H4 | · `bodyAlpha: latticePreviewBodyAlpha,` | ~1 | `flexibleMain.bodyAlpha(project, on: stage) ?? latticePreviewBodyAlpha` (X-ray) |
| H5 | · `if viewerMesh != nil, visible.wireframe, !visible.surfaceEditing {` | +1 ~1 | `if flexibleMain.owns(project, stage) { FlexibleMainViewToggles(main: flexibleMain) }` + `else if …` — the octet cube (and its bake) is not offered under Flexible |
| P | · inside `if !fullScreenPageUp { bottomBar … }` | +1 | `if flexibleMain.owns(project, stage) { FlexibleMainPlayerSlot(main: flexibleMain, bottomClearance: bottomBarClearance) }` — the squish player |
| H10 | · `latticeThisButton` in `bottomBar` | ~1 | `if project.lattice.flexible == nil { latticeThisButton } else { FlexibleMainStatusPill(main: flexibleMain, open: { showFlexiblePage = true }) }` |
| H12 | LatticeSettings · `previewBakeInputs` (after `s.organicForecast = nil`) | +1 | `s.flexible = nil` — a Flexible edit never re-keys the octet bake (OrganicPreviewBakeInputsTests green) |
| M1 | MetalMeshView · `func draw(in view: MTKView) {` | +1 ~1 | `let flexLooping = stepFlexibleLoop(in: view)` before encode; the settle's end `… && !flexLooping` — the main page's loop runs in the renderer |
| M2 | MetalMeshView · Coordinator `private var appliedFlex = false` / the flex upload | +2 ~1 | `appliedFlexArray`; `if dirty \|\| !appliedFlex \|\| flex != appliedFlexArray` — a new dent on the same mesh reaches the GPU |

WorkspacePlaceholder: 12 lines touched (+10 net); MetalMeshView +3 ~2; LatticeSettings +1.
Everything else is in track files. **No bridge / core change:** the plan's
`flexible_scene_mask_field` was not needed — `densityField(faces: [])` is core's own mask
(FlexibleKit+Mask.swift, 4 lines of Swift).

### Added / changed (track files)

- NEW `FlexibleReadiness.swift` (issues, fixes, auto-fixes, `FlexibleExitDecision`,
  `FlexibleFixPrompt`), `FlexibleFixPopup.swift`, `FlexibleGeometryOnlyLattice.swift`,
  `TopOptKit/FlexibleKit+Mask.swift`, `FlexibleMainStage.swift` (+ `FlexibleMainStatus`),
  `FlexibleMainStatusPill.swift` (+ `FlexibleMainViewToggles`, `FlexibleMainPlayerSlot`),
  `FlexibleSquishPlayer.swift` (`FlexibleSquishLoop` + the control), `FlexibleLegendPlacement.swift`.
- `FlexibleStageModel`: per-face design catch (`designEach`), `stackErrors` / `designErrors`,
  no blind stack retry, `actionSerial`, auto-fixes + `toast`, `pendingFix`, a ready scene with
  the same key is re-used (the shared model keeps its stacks), `generateLattice` builds the
  shape-only field or the designed one, faces LARGEST first; `FlexibleLatticeGate` removed.
- `FlexibleStagePage`: over the shared model; no Generate / Export pill; the readiness line,
  the pop-up, Exit's decision, the player; the loop is the player's (one amount).
- `FlexibleLatticePass` / `MeshRenderer+FlexibleLattice`: the loop reference and
  `stepFlexibleLoop` / `flexibleLoopScale`. `FlexibleSquish`: the layer carries the loop.
- `FlexiblePageChannels`: a `heat` switch; only the squished faces dent under a lattice.
  `FlexibleShownValues`: a shape-only lattice's map says "What you drew".

### Decisions rows (00-decisions.md §1b)

D-R3-10 what blocks Exit (and what never does; the pop-up; the silent fixes) · D-R3-11 no
Generate — Save & Exit builds, the main page shows it, H1–H12 · D-R3-12 the shape-only
lattice · D-R3-13 the squish player · D-R3-14 more than four faces.

### Commits (on claude/flexible-screens, not pushed)

23506824 the squish player + the renderer loop + the dent upload · 9b3b95e5 readiness, the fix
pop-up, the shape-only lattice, per-face catch, more than four faces · 5729e291 no Generate —
Save & Exit builds, the main page shows it (the #354 hooks) · (this handoff + DECISIONS rows).

### Tests (raw)

Targeted suite (every Flexible* suite in both targets + UnifiedShading, LatticePreviewBodyAlpha,
LatticeGBufferMask, LatticeThreeAlgorithmsDraw, OrganicCapsuleImpostor, Viewer, StageBackdrop,
SmoothingPageRound2, LatticeStageMode, LatticeSettingsPersist, ProjectStore, UndoHistory,
SurfaceStage, LatticeSimSolveTrigger, and every suite that scans or drives a file I touched:
LatticeLegendColour, OrganicPreviewBakeInputs, LatticeBandChips, OrganicWalk0907Evening,
LatticePreviewConfetti, SmoothingStrokeCamera, SmoothingUsablePath, BottomBarMeasurement,
LatticePageRound2, LatticeMode, SmoothingViewer, VariantEntryGating, GroupViewState,
LatticePreviewNoticeCaption, LatticeStressTint), after the last source change, raw:

```
Executed 437 tests, with 5 tests skipped and 1 failure (0 unexpected) in 318.415 (318.464) seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
FLEX-LOOP cost per frame: 1.54 µs (step + read, this build) — sink 74635
FLEX-MAIN 2 s loop: stage publishes 0, scale 0.0…3.9923894
FLEX-MAIN dented quad vertices: all squished A 12288 B 12288 | only A: A 12288 B 0
FLEX-MAIN designing at Exit: true; lattice built: true
FLEX-PLACE main 11" landscape: player (427.0, 702.0, 340.0, 46.0) · legend slot (902.0, 333.0, 268.0, 168.0)
FLEX-PLACE main 11" portrait: player (247.0, 1062.0, 340.0, 46.0) · legend slot (542.0, 513.0, 268.0, 168.0)
FLEX-PLACE main 13" landscape: player (518.0, 900.0, 340.0, 46.0) · legend slot (1084.0, 432.0, 268.0, 168.0)
FLEX-PLACE main 13" portrait: player (346.0, 1244.0, 340.0, 46.0) · legend slot (740.0, 604.0, 268.0, 168.0)
FLEX-PLACE settings 11" landscape: legend (906.0, 358.0, 264.0, 118.0) · player (633.0, 752.0, 340.0, 46.0)
FLEX-PLACE settings 11" portrait: legend (546.0, 538.0, 264.0, 118.0) · player (453.0, 1112.0, 340.0, 46.0)
FLEX-PLACE settings 13" landscape: legend (1088.0, 457.0, 264.0, 118.0) · player (518.0, 950.0, 340.0, 46.0)
FLEX-PLACE settings 13" portrait: legend (744.0, 629.0, 264.0, 118.0) · player (552.0, 1294.0, 340.0, 46.0)
FLEX-READY TPU 95A shape only: 3 faces, ρ span 0.17608377…0.38643384
FLEX-READY his project as saved: 1 blocking — 1 thing to fix: Face 3 and Face 5 press the same material | fixes [TopOptFlows.FlexibleFix.rest(5), TopOptFlows.FlexibleFix.rest(3)]
FLEX-READY his project, TPU 95A: ["Face 3 and Face 5 press the same material"] | info ["TPU 95A: shape only — no squish predicted"]
FLEX-READY varioShore after [Face 5 rests]: lattice of 3 faces, squished 3
FLEX-READY weight 0 first: designs [1] errors [TopOptFlows.FlexFaceKey(region: 2, rotation: 0): "face 2: weight must be > 0"]
FLEX-SHAPE S soft 0.49 → ρ 0.272 · S firm 0.00 → ρ 0.386 (band 0.155…0.386)
FLEX-SHAPE band ρ 0.141…0.386 ⇒ cells 3.36…9.20 mm (t 0.42, depth 18.4)
FLEX-SHAPE mask voxels 53248, core's latticeVoxels 53248 | app occupancy on its own grid 51597 (control)
FLEX-UPLOAD same mesh, new dent: 2226 of 16384 pixels changed
FLEX-UPLOAD same-array check over 1.2 M floats: 0.13 µs per apply (this build)
```

RED first (the new suites run before the #354 hooks, `b_red1`): `Executed 32 tests, with 18
failures` — the 13 hook pins, H12 (twice), the draw(in:) pin, the dent upload ("0 of 16384
pixels changed"), the pill after [Face 5 rests] (stale conflicts — fixed in the readiness), and
one wrong expectation of mine in the area order (corrected: 80 mm² before 50 mm²).
Mutation runs (each reverted in source, the tests run, then restored — grep shows no marker
left): no shape-only branch ⇒ "No lattice voxel has a density yet" and no lattice; the old
single catch ⇒ the next face never designed (timed out); no build when the designs land ⇒
timed out; the flex upload check removed ⇒ 0 of 16384 px changed.
The first targeted run also caught `FlexibleRowCopyTests`' pin (`"flexible-view-xray"` gone
from every Flexible file): the main page's toggles now use `flexible-main-view-*`.

**iOS build:** `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration Debug
-destination id=147E56A1… build` — `** BUILD SUCCEEDED **`, no warning in a batch-B file.

**Deleted-test sweep (my diff):** one test renamed and rewritten deliberately —
`FlexibleSquishTests.testGenerateRefusesMoreThanFourLoadedFaces` →
`testMoreThanFourPressedFacesNeverBlockAndAreSaidInOneLine` (your "exit is blocked only when
truly needed" overturns the refusal; what it guarded — no face dropped without a word — is
kept: the line says "Squish shown on the 4 largest of 5 faces"). No other test deleted or
re-pinned. `FlexibleRowCopyTests`' pin that `"flexible-view-xray"` is gone from every Flexible
file stays: the main page's toggles use `flexible-main-view-*`.

## Round 3 · batch A — verification pass

A verifier read batch A against your rules and rendered it on YOUR project 0004. I confirmed
every finding myself (code + your restored project; renders are headless, the app was not
launched) and fixed each blocker-level and major one that belongs to batch A, plus the cheap
minors. **Still true: on your project, Exit builds nothing today** — the Generate pill,
Save & Exit, the readiness pop-up and the shape-only lattice are batch B; do not judge batch A
alone as "done".

**What changed for you (all in `Flexible*` track files; no #354 / main hook added):**

- **Your top A now reads "10 kg from Top" and writes back to the Top group.** It had been
  pressed by the old tap at its 10 kg default (unlinked), so the batch-A build showed "10 kg"
  and kept a second truth. Every face a main-page Load group presses is now linked
  (`FlexibleMainPageLoads.adopt`); if the group's weight replaces one of yours, one line says
  "Was 7 kg · now Top's weight". Faces no group holds (top B, faces 3 and 5) keep your 10 kg.
- **[Rests] stays.** Choosing Rests on a face the Top group presses used to be undone by the
  next re-sync (every open, every weight you typed). It is now your choice; one line says
  "Top presses it on the main page". **The trash is gone for a face a group holds** (it came
  straight back at the next open) — Rests is the way out.
- **The number pad commits once, when it closes.** Typing "12" had written 1 kg and then
  12 kg to the Top group (two undo steps), and pressing a new face on the first digit tore
  the pad down ("25" became 2 kg).
- **The prism is drawn only while you drag the chip**, and a flat prism has four clean walls
  (the old one stood a line every 2 mm — a barcode that hid the bend from img 1's angle).
  **It never leaves the part:** k now also keeps k × deepest within 0.65 of the lattice (your
  top A: × 6 → × 4), and one drag stops where the drawn prism meets the lattice (let go and
  drag again to go deeper). While you drag, the dent follows the chip on varioShore too.
  Looking straight down the load, dragging DOWN is deeper (it had been the other way on top A).
  If the chip slides under the panel mid-drag it stays and the drag still finishes (before, k
  stayed frozen and nothing was recomputed or saved).
- **After Generate, a curve you edit shows at once.** The old lattice had kept owning the map
  (looping its old depths); a stale lattice now gives way to your live drawing and hides.
- **Only the dent map is green.** Curves, their points, the chip, the prism and the selected
  face are the neutral light colour; the green is the map's ramp and the page accent.
- **What you must know is on the panel:** one orange line when the selected face is refused
  or your curve cannot be reached ("Can't reach your curve on 794 columns" on your top A at
  10 kg), "Auto: can't meet your curve" / "Auto: no pick" in orange, a missing filament list.
  TPU 95A reads "· no squish data" (it had promised "shape only", which nothing builds yet).
- **Rows fit in points, not only in characters:** "Nozzle °C", chips at their own widths
  ("Honeycomb" had read "Honeyco…"); the filament line is ≤ 38 characters. The (i) is a
  44 pt target. Gone: the second filament name in the header, the permanent "no strength
  certificate" notice (it is in the Physics (i)), the Walls row (folded into "Physics ·
  1-bead walls"); Feel and Lattice are hidden for a calibrate-first filament.
- **A tap on a curve point no longer moves it** (drags start at 6 pt, relative to the grab).
- **Top B's curve is not flipped** by the round-3 read-through: its extra knot came from the
  old "+ point" on the default dome (its shape is within 0.022 of the default; your top A's
  moved peak is 0.072 away and is flipped, as is face 3's V).

**Findings I did not fix here, and why:**
- *Exit yields no lattice / Generate pill / blockers not pop-ups* (the verifier's blocker):
  confirmed; it is batch B by the plan (it needs the hoisted model and the shape-only
  lattice). This handoff now says so plainly above and in the batch-A section.
- *Prism floor vs legend vs "Deepest squish"* (3.0 mm × k vs the map's 2.1 mm): kept by
  design — the prism is the deepest squish (S = 1); your curve never touches the face line,
  so the dent stops short of it. Recorded in D-R3-5; the batch-A sentence "the dent bottoms
  out on its floor" is corrected.
- *Curve handles have no keep-out; X's corner point can sit under Y's*: not fixed (minor,
  and hiding an unreachable handle does not make it reachable) — batch C's camera work.

**Your call:** faces the OLD taps pressed that no main-page group holds (top B, faces 3 and 5,
10 kg each) are kept. Faces 3 and 5 share a stack, which is what refuses Generate on your
project. Should the first open after round 3 drop old-tap faces that no group holds, or keep
them (today)?

**Decisions rows:** D-R3-5 and D-R3-6 extended; D-R3-8 (only the map is green; the prism
only while dragging) and D-R3-9 (a stale lattice never owns the map) added —
`docs/design/flexibles/00-decisions.md` §1b.

**Commits (not pushed):** ce1f0471 the group is the one truth · ee9377c4 the prism, the stale
lattice, the chip's drag · b465e461 only the map is green · 9169fde1 the panel says it, rows
fit in points · 9b56539d top B's knot is not a drawing · 80b42512 the temperature note's
colour · (this handoff).

**Tests:** every fix has a test with an inline RED control, and each fix was also reverted in
source and the new tests run RED before restoring (mutation runs: 12 failures in 4 tests;
15 in 8; 2 in 1; 8 in 4; 1 in 1). Final targeted run (every Flexible* suite + UnifiedShading,
LatticePreviewBodyAlpha, LatticeGBufferMask, LatticeThreeAlgorithmsDraw, OrganicCapsuleImpostor,
Viewer, SmoothingViewer, StageBackdrop, SmoothingPageRound2, LatticeStageMode,
LatticeSettingsPersist, ProjectStore, UndoHistory, SurfaceStage, LatticeSimSolveTrigger), raw:

```
Executed 269 tests, with 4 tests skipped and 1 failure (0 unexpected) in 259.738 (259.760) seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
FLEX-LOADS his top A row: '10 kg from Top'
FLEX-PRISM top A skirt: 4 vertical edges (grid mesh: 150), 5 vertices
FLEX-PRISM diagonal sector: 1225 columns in 69 rectangles, boundary 416.0 mm (perimeter 416.0 mm), skirt 208 vertical edges
FLEX-PRISM flat 0.3 drawing: shown max 0.27 mm, k 4, prism 12.0 mm, floor z 7.95 (lattice 20.0–20.0 mm)
FLEX-BEND his top A: shown depths 0.00–2.07 mm × 4; the quads' shown dent spans 0.00–8.27 mm along the load
FLEX-MIGRATE shape gap from the default dome: top B 0.022, top A 0.072 (tolerance 0.04)
FLEX-ROWS in points (panel content 372 pt): Feel 244 · Top A 239 · Shape 243 · Nozzle °C 347 · Lattice 329 · 10 kg from T 212 · Deepest squi 266 · Auto: can't  293 · Physics · 1- 257
```

**iOS build:** `xcodebuild … -destination id=147E56A1… build` at 80b42512 — BUILD SUCCEEDED,
no warning in a Flexible file. **Hooks in #354 / main files: still none.**

## Round 3 · batch A — the Settings page: simple, visual, and it bends (current state)

**What you will see on the Flexible Settings page** (judged headlessly on YOUR project 0004,
restored through `AppModel.open` from a copy of the simulator's folder — the app was not
launched, per the standing rule; nothing here has been seen on a screen yet):

- **The hole is closed** (img 2). With only 'top A' pressed, every point of the top face is
  covered exactly once: the part's own surface runs up to the heat map along the cut. The
  sector tint and "skin off" stop at the cut too.
- **The heat map bends in 3D, always** (img 1). While you draw it holds still; it loops
  0 → full → 0 only once a lattice is drawn. TPU 95A (calibrate-first) bends as well — its
  map is core's squish_fraction of your curves. The page is **always in X-ray** (the button
  under the gizmo is gone). The legend sits on the **right edge, vertically centred**, with
  one line: "What you drew · shown ×4". Its colours are the dent's own green ramp (never
  purple; Stress keeps its rainbow).
- **The curve reads the right way round.** Nearer the face = squishier ("soft" at the face
  line, "firm" at the dashed guide). Your drawn V keeps its picture (its stored values flip
  once); the untouched default is now a valley touching the face in the middle.
- **Both X and Y curves are on the part at once.** Tap the line: a point lands there, on
  the curve. Tap a point: a red × appears beside it; tap the × to delete (never on an end
  point). A tap on the part clears the ×. The double-tap and "+ point" are gone.
- **Deepest squish = a prism you drag out.** A glass chip ("3.0 mm") sits at the deepest
  squish under the selected pressed face; drag it and a prism grows into the part — drawn
  ONLY while you drag (verification fix: at rest it buried the bend). It snaps every 0.5 mm
  and at the lattice depth, with a haptic tick; one drag stops where the drawn prism meets
  the lattice (let go, drag again to go deeper). The dent reaches the prism floor only where
  your curve touches the face line. Looking straight down the load it becomes a scrub
  (down = deeper). At rest it hides under the panel or the legend; mid-drag it never does.
- **A tap on the part only selects.** Faces come from the main page: your 'Top' group
  (10 kg, gravity) presses top A with "10 kg from Top" — on YOUR saved project too since the
  verification fix (the batch-A build left top A unlinked, reading "10 kg"); the bottom
  anchor rests. Editing the weight here **writes back to the group** (your answer), once,
  when the number pad closes; a group over several faces is split by area and re-syncs.
  [Rests] on a face the group presses is your choice and stays ("Top presses it on the main
  page"); the trash is not offered for a face a group holds. A face in no group shows
  [Press it] [It rests here]; pressing it asks "How much weight presses here?".
- **The panel: Face | Stamps | More, one line per setting, details behind (i).** Face:
  filament (a menu, until New TopOpt supplies it; "· squish data" / "· no squish data"),
  Feel, then the selected face's name [Pressed | Rests], Weight, Shape [Curves] [Stamp —
  disabled, batch D], Deepest squish, Solid skin — and ONE warning line when the face's
  design is refused or your curve cannot be reached on some columns. More: "Nozzle °C",
  lattice family, Auto's pick (in warning colour when Auto cannot meet your curve or picked
  nothing), "Physics · 1-bead walls". Feel and Lattice are hidden for a calibrate-first
  filament. **Removed:** Both/Either/Centre (always both), the X/Y/3D steps, the frame
  rotation, 1/2 beads (always 1), the density cross-section and its slider, every long
  caption, the header's second filament name and the permanent notice.

**Not done in batch A (honestly):**
- **No simulator check.** The plan's step 5 (install on your project, compare with img 1/2,
  screenshots) needs the app launched, which is refused to me. `xcodebuild` for the
  simulator succeeds; everything else was measured on your restored project in tests.
- **Stamp shape** is shown disabled (batch D). The Stamps tab itself is unchanged (its
  captions stay until batch D reworks it).
- **ON YOUR PROJECT, EXIT BUILDS NOTHING TODAY — do not judge batch A alone as done.** The
  Generate pill is still on this page (batch B moves the build to Save & Exit), and on your
  project as saved it is refused: "Face 3 and face 5 share a stack — mark one of them as
  where it rests" (a grey line bottom-right, not yet the pop-up that selects the face with
  fix buttons). With TPU 95A it is refused as calibrate-first. Readiness pop-ups, the
  shape-only lattice for calibrate-first filaments, the >4-face limit and removing the pill
  are batch B.
- **Your saved project keeps the faces the old taps pressed** that no main-page group holds
  (top B, faces 3 and 5 at 10 kg each; 0, 2, 4 resting). Top A — in your Top group — now
  follows Top. Whether the others should be pruned is your call (see "Your call" below).
- A face you saved at 90° now reads at 0°; its curves are not re-mapped to the turned frame.
  A curve whose SHAPE is the default dome (within 0.04 of core's curve — e.g. top B's extra
  knot from the old "+ point") is not flipped; a curve you redrew to look like the default
  is treated the same way.
- The oblique-press line reads "… at an angle" in the weight row; there is no separate
  confirm button.

### Hooks in #354 / main files

**None.** Every change is in `Flexible*` track files (plus this handoff and
`docs/design/flexibles/00-decisions.md` §1b). MetalMeshView, WorkspacePlaceholder,
LatticeSettings and ProjectModel are untouched; the prism uses MetalMeshView's existing
`clearanceVolumes:` argument; the weight write-back uses `ForceModel.setWeight` (public).

### Decisions rows (00-decisions.md §1b)

D-R3-1 frame rotation removed (overrides R13's 90° steps) · D-R3-2 walls always 1 bead
(R1; Core brief: recommend weighs 1 vs 2 once 2-bead coupons exist) · D-R3-3 the curve
convention (face line = squishiest; drawn curves flip once, marker `curveConvention`) ·
D-R3-4 mode always both, no steps, the map always bends · D-R3-5 one integer k (0.20 ·
extent / deepest, 1…10, ≤ 0.65 of each column's lattice) · D-R3-6 a tap only selects; the
main-page group is the one source of truth for weight; `loads.build_dir` = −gravity ·
D-R3-7 the density cross-section removed.

### Commits (on claude/flexible-screens, not pushed)

f580008d the hole · 4c04024e Optional fields + read-through migration · bea8e56e the curve
(inversion, tap-add, ×) · 5394b0f9 the map bends · 1dd4221f main-page weights, select-only
tap, build_dir · 014f48a8 the depth prism + chip · 06521d22 the panel (Face | Stamps | More)
· 3dc4b91d the dent's own ramp.

### Tests (raw, targeted suite: every Flexible* suite + the round's list)

```
Executed 252 tests, with 4 tests skipped and 1 failure (0 unexpected) in 265.234 seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
FLEX-HOLE pad, only top A pressed (pitch 2.00 mm): interior 38416 points — uncovered 0 (0 mm²), twice 0; band 1584, off 0 | OLD centroid rule: uncovered 4851 (1213 mm²), twice 4560
FLEX-HOLE HIS project 0004, only top A pressed: interior 38416 — uncovered 0 (0 mm²), twice 0; band 1584, off 0
  (run before the fix, same instrument: uncovered 4753 (1188 mm²), twice 6298)
FLEX-HOLE uvt on 5 clipped flat vertices: worst |interp − core to_uvt| 0.0 mm; old corner lookup 70.71 mm (control)
FLEX-HOLE skin off on top A: top B points without skin 0, top A points still skinned 0 | OLD centroid rule: 4950, 5050
FLEX-HOLE his top face before any stack: 6 pieces, 0 straddle x = 50 | the part's own: 2 straddle (control)
FLEX-BEND TPU 95A pad, default curves: deepest quad dent 3.00 mm (× 4 shown), legend "What you drew · shown ×4", animated no
FLEX-BEND his top A: shown depths 0.00–2.07 mm × 6; the quads' shown dent spans 0.00–12.41 mm along the load
  (after the verification fix k is also capped by k × deepest: × 4, 0.00–8.27 mm — see the verification section)
FLEX-CURVE insert at t 0.2 on the default dome: |Δ curve| over 20 t's max 0.0174 mean 0.0055 (exact at the tap)
FLEX-PRISM top A: 1250 columns, footprint 5000.0 mm² (columns × pitch² 5000.0), 1326 corners, 2500 triangles, built in 7.2 ms (Debug)
FLEX-PRISM handle round trip: worst |read − set| 0.00030 mm (model projection), 4.15 mm (world, control)
FLEX-LOADS 60/40 split, 10 kg: [4.0, 6.0] kg, shares [0.4, 0.6]
FLEX-ROWS 42 lines, longest 44: "Siraya Tech Roamr TPU Air HR 8… · shape only"   (batch-A copy; now "· no squish data")
FLEX-RAMP dent ramp hue span 3° (Stress rainbow 221°), luminance 0.22 → 0.86
```

Every new comparison has a control that goes red (the old centroid rule, the old corner
lookup, the old curve mapping, the old widest-gap insert, the old tap, a sector-blind
mapping, an equal split, a weightFrom-blind re-sync, no build_dir, −load, a world
projection, the uncapped k, the old caption, the DS purple). Tests were run red for their
stated reasons before each change (the hole: 1188 mm² on your project; the dent: the old
drawing branch failed "a drawn map dents"; the tap: face 3 pressed at 10 kg).

**Deleted-test sweep (my diff):** one test renamed and rewritten deliberately —
`FlexibleSquishTests.testAStampOrACurveStepIsNotTakenOverByTheLattice` →
`testAStampWinsAndADrawnMapDentsStatically` (your round-3 ruling overturns "a curve step …
never an animated dent"; the stamp half is kept). Re-pinned assertions, each commented in
place: `testTheLatticeIsDrawnOnlyInXrayWithALattice` (latticeShows without steps; a shown
stamp still hides the walls), `testTheMapAndDentComeFromTheLatticeWhileItIsDrawn` (k with the
thin-stack cap), `FlexibleRegionsTests.testOverlayReplacesOnlyTheSectorsTriangles` (kept area
5000 mm², not a triangle count). No test deleted.

**iOS build:** `xcodebuild … -destination id=147E56A1… build` — BUILD SUCCEEDED (no new
warning in the new files).

**Your restored project** is committed as a test fixture under
`docs/handoffs/evidence/2026-09-29-flexible-screens/his_project_0004/` (project.json + the
pad STL, byte-identical to the simulator's); `HIS_PROJECT_DIR` points the same tests at any
other copy.


## In plain words

**What you can do on screen now** (simulator, on the 100 × 100 × 20 pad and on the M2 stand):

- **Open the Lattice stage.** Three cards now sit side by side: Structural, Aesthetic and
  **Flexible**, in the same style. Flexible's text says it is for squishy filaments, you draw
  how far each face gives, there is no strength certificate, and every number shows where it
  comes from.
- **Choose Flexible.** The Lattice stage shows a green "Flexible" title chip. Tapping it opens
  the same limitations sheet with the same two-tap "Delete … and choose again". The
  **Settings** button opens the Flexible page instead of the octet wizard. Placement is the
  existing region tools, unchanged.
- **Filament.** Filaments with data are listed first, then the calibrate-first ones. Each has
  its tier badge. varioShore offers only its tested temperatures (190 / 220 / 240 °C). A
  calibrate-first filament shows "Calibrate first — geometry only" with core's own reason, and
  its squish fields stay empty.
- **Squish.**
  - Tap a face on the part to load it. The panel says "Face 2 of 4" and names the linked
    other end with its area share ("Other end: face 15 43 %, face 1 30 %, …").
  - You can set the weight in kg (the N value is shown underneath), the deepest squish in mm,
    the frame rotation in 90° steps, and skin on/off. Every number opens the number pad.
  - A side face says "Side face · gyroid only · estimated".
  - The **X curve is drawn on the model**, along the face's own X edge, rising out of the
    part. Drag its points and the map on the face recolours as you drag. "+ point" adds a
    point; a double-tap deletes one. The Y curve works the same way. Centre → edge uses a
    single curve.
  - The **3D view** colours the face by depth and dents it. It has a "What you drew / What can
    be built" toggle and a legend with the tier and ± band. The clamped columns are counted in
    plain words.
  - A **density cross-section** (X / Y / Z, with a slider) shows either density or the
    **owner map** where faces hand over, with core's handover volumes.
  - Two faces on the same stack give **core's conflict sentence with both face ids**.
- **Auto.**
  - Springy or damped?
  - Core's one-line sentence and its reasons.
  - Where it cannot be met: which face, the u/v range, and the nearest achievable squish.
  - Every candidate core weighed (family × tested temperature), with mass where it is known.
  - An override that shows "no data here" for a pick core has no data for.
- **Physics.**
  - The three tested temperatures side by side on one scale.
  - The curve in use at each loaded face's density, with that face's operating point.
  - Source, tier, band, the tested density and strain limits, and core's strain convention.
  - Both honesty notes (after break-in; sharper dents).
- **Stamps.**
  - The 10 built-ins, and an SVG or image import.
  - Check mode takes any number of stamps and shows each dent on the model. Design mode takes
    one stamp and re-designs the face under it.
  - Size, rotation and weight use the number pad. Soft or rigid. Drag the stamp's handle on
    the part to move it.
  - Each stamp is laid on the face at half the column pitch; the panel prints the grid.
  - Flags shown: narrow stamp, force off the face, and the note about a rigid design stamp.
- **Everything is saved and undoable.** Every edit reaches `project.json` within 0.8 s. Undo
  and Redo are on the page.

**Morning round (below) — this is the current state.** Since the first handoff:

- **X-ray view.** The Flexible page has the position gizmo top-right and a **view button**
  under it. X-ray turns the part into a ghost (faint face-on, lit toward its outline) and
  keeps the bent heat-map plane fully opaque, so the dent reads.
- **The lattice is drawn inside the part's own renderer**, the way the Structural and
  Aesthetic previews are: marched as an SDF into the same G-buffer, lit by the same shade,
  at the same 1152 px cap. In X-ray you see it through the ghost; it never paints over the
  heat map. It squishes on repeat with the dent, on the same number.
- **Split faces** are loaded faces (each half its own design); the two halves' dents meet
  along the cut.
- **Exports wait on core.** The app's STL exporter is gone; the Export modal says STL and
  G-code both come from core's Flexible lattice.

Needs you: a look in the simulator (the launch is refused to me — nothing has been seen on a
device), and the rulings listed under "Morning round → Your call".

**What is next.**

- **Maintainer look.** Please check the curve editor's feel, the 3D dent (see "Not done" §2),
  and whether the panel layout is right for you.
- **A2 (bead-path preview)** waits on C2.
- **Full app suite:** the result is pasted below.

## Task
A1 of docs/design/flexibles/07-roadmap.md: the Flexible stage's screens in `/app/`, drawing every
number from C1's core through the bridge.

## Synced commits (merge-only, nothing pushed to those branches)

| branch | last synced commit |
|---|---|
| #361 `claude/flexible-squish-maths` (base) | `23196cfb` Handoff: FULL CHECK — core 140/140 … (morning sync) |
| #354 `claude/topopt-holes-quilting-298212` | `e0021963` Dead walls are core's verdict everywhere … (morning sync) |
| #358 `claude/raster-receipt-fields` | `5be7862a` unsupported_spans_seen: the comment said "not printed" and they are printed |
| `main` | `f932266f` Merge pull request #360 (lattice types setup) |

- **Merges.** `ee3cd779` (Sync: merge #354) and `8c666f6c` (Sync: merge #358) merged with no
  conflicts. #361 and main were already contained.
- **After the sync.** `build_core.sh` exited 0, `swift build` finished, and the 62 targeted
  tests passed.
- **Morning sync.** `c2fd316c` (Sync: merge #361, handoff only) and `4f4d3b04` (Sync: merge #354,
  `e0021963`: app-side only, no core/ change, so the core xcframework stands) merged with no
  conflicts. After it: `swift build` clean, and 209 targeted tests (all Flexible suites,
  #354's renderer/page suites, `OrganicDeadWallParityTests`, `LatticeStageModeTests`,
  `LatticeSettingsPersistTests`, `SmoothingPageRound2Tests`, `ProjectStoreTests`,
  `UndoHistoryTests`) passed:
  ```
  	 Executed 209 tests, with 4 tests skipped and 0 failures (0 unexpected) in 251.024 (251.043) seconds
  ```

## Per-stage status

| Stage | Status | Evidence (docs/handoffs/evidence/2026-09-29-flexible-screens/) |
|---|---|---|
| S0 baseline look | Topology, Lattice (Aesthetic), Settings wizard and the two-card modal captured before any change | `s0_before_*.png` |
| S1 entry + setup | **done**: third card, chip, delete-and-re-ask sheet, once-only rule, filament list with tiers and tested temperatures, calibrate-first empty fields with reason, placement unchanged | `s1_pad_modal_three_cards`, `s1_m2_modal_three_cards`, `s1_pad_lattice_stage_flexible_chip_placement`, `s1_m2_filament_varioshore_tested_temps`, `s1_pad_calibrate_first_filament_reason`, `s1_pad_calibrate_first_geometry_only` |
| S2 squish screen | **done**: face stepper, linked other end + fractions, kg→N, deepest mm, 90° frame, skin, side label, pen curves on the model (X, Y, centre→edge) validated and drawn by core, 3D view with drew / buildable, legend, clamp counts, density slice with owner map, conflict | `s2_m2_squish_x_curve_on_model`, **`s2_m2_curve_mid_drag`** (taken during a drag), `s2_pad_3d_what_you_drew`, **`s2_pad_3d_what_can_be_built`**, `s2_m2_3d_what_you_drew`, `s2_pad_side_face_gyroid_only_estimated`, `s2_pad_density_slice_owner_map_handover`, `s2_pad_three_faces_owner_map`, **`s2_pad_same_stack_conflict`** |
| S3 Auto + physics | **done** | `s3_pad_auto`, `s3_m2_auto`, `s3_pad_physics`, `s3_m2_physics` |
| S4 stamps | **done**: library, import (SVG / image, unit-tested; not yet driven on the simulator, see Not done), size / rotation / weight / soft-rigid / drag, several per face, design vs check, narrow / off-face / rigid-design notes | **`s4_pad_stamp_check_mode_heel`**, **`s4_pad_stamp_design_mode_thumb_with_heel_check`**, `s4_m2_stamp_check_mode_thumb`, `s4_m2_stamp_off_face_flag` |
| S5 persistence + job | **done**: settings in `LatticeSettings.flexible` (saved, undoable, cleared by delete-and-re-ask); `FlexibleJob` writes the `flexible` block; the round trip goes through core's `parse_job` | tests below |

## What I did

**Bridge.** Two new files:

- `app/TopOptKit/Sources/TopOptBridge/flexible_bridge.cpp`
- `app/TopOptKit/Sources/TopOptBridge/include/FlexibleBridge.hpp`

Each function copies a `topopt::flexible` result into POD vectors; none computes a squish number
itself. The functions, grouped by contract item:

- **F1**: `flexible_materials` (catalogue + `tested_temperatures`, plus core's `curve_set`
  refusal as the no-prediction reason), `flexible_error_bands`, `flexible_temperature_note`.
- **F4**: `flexible_pen_curve_error`, `flexible_pen_curve_values`.
- **F3 and F10**: `flexible_curve_set`, `flexible_stress_at`, `flexible_density_for`,
  `flexible_strain_under`, `flexible_curve_samples` (σ(ε) sampled with core's `stress_at`),
  `flexible_tier_band`, `flexible_cell_size_mm`.
- **F8**: `flexible_stamp_grid_error`, `flexible_stamp_force_n`, `flexible_stamp_width_mm`.
- **Scene**: `flexible_scene_open` / `close` / `info`. It parses the job with `parse_job`,
  imports with `import_part_file_resolved`, then calls `voxelize`, `flexible_region_mask` and
  `resolve_face_regions`, and keeps the results.
- **F5**: `flexible_scene_stack` (cached per face and rotation), `flexible_scene_from_uv`,
  `flexible_scene_to_uvt` (core's `to_uv`, plus t along the load).
- **F6–F8 on the scene**: `flexible_scene_squish_fraction`, `flexible_scene_edge_fraction`,
  `flexible_scene_design` (the design is cached for the field),
  `flexible_scene_check_stamp` (densities come from the cached design, exactly as
  `run_flexible_job` reads them), `flexible_scene_conflicts`,
  `flexible_scene_density_slice` (`assemble_density_field`, cached, one axis slice + owner +
  handovers).
- **F9**: `flexible_scene_recommend`.
- **F11**: `flexible_parse_job_block` (core's `parse_job`, read back).

The Swift wrappers are in `app/TopOptKit/Sources/TopOptKit/FlexibleKit.swift`
(`FlexibleCore` and `FlexibleScene`).

★ **Swift/C++ interop trap.** Reading `s.col_u_mm[k]` in a loop copies the whole
`std::vector` on each access. `stack()` took 3.1 s and `design()` 6.9 s until every vector was
converted with `Array(...)` once (`FLEX_TIMING` probe). After the fix:

- scene open: 4 ms
- stack: 19 ms (15 ms cached)
- squish map: 0.9 ms
- design: 92 ms (Debug, macOS, 4,096-column pad)

**App (all new files):**

- `FlexibleSettings.swift`: inputs only, never a prediction.
- `FlexibleJob.swift`: the run and scene job writer. Face region id = face id, so core's
  sentences name the face the app shows.
- `FlexibleStageChrome.swift`: card, chip and sheet, copied from the mode modal and sheet;
  accent `DS.Color.accentGreen`.
- `FlexibleStageModel.swift`: an actor worker off the main thread. It opens the scene once
  per placement, and caches stacks and geometry per (face, rotation). A dragged point re-runs
  only the squish map at once and the designs 120 ms after the drag rests (coalesced).
  Auto, the field slice and the stamp checks follow.
- `FlexibleStagePage.swift`: layout from the Settings wizard (Exit top-left, one notice,
  one bottom-left panel with `PageChrome.edge` / `DS.Surface.panel` / `DS.Radius.panel`).
- `FlexiblePanes.swift`: Auto, Physics, the slice, Stamps and the stamp handles.
- `FlexibleCurveEditor.swift`: the curve is projected from world points every frame. Only
  the handles take touches, so the rest of the screen still orbits the part.
- `FlexibleOverlay.swift`: column quads on the face at core's `from_uv` + `entry_t`, with the
  02 §6 linear ramp for the dent.
- `FlexibleStamps.swift`: library, rasteriser, SVG/image import.

**Data bundling.** The Xcode Resources phase references core's own files (`../core/src/materials/flexible_materials.json`, `../core/src/materials/flexible_curves` as a folder, `../docs/design/flexibles/data/stamps.json`), the way `materials.json` is bundled. No copy is committed.

### Every hook line in #354's files

| file | lines | what |
|---|---|---|
| `LatticeSettings.swift` | +5 | `public var flexible: FlexibleStageSettings? = nil` (L1178–1179), `case flexible` in CodingKeys (L1917), `decodeIfPresent` (L1988), `encodeIfPresent` (L2168). Absent ⇒ nil ⇒ an untouched project's file is byte-identical (test). |
| `LatticeStageModeModal.swift` | +9 −2 | `onChooseFlexible: (() -> Void)?` (default nil) + `flexibleFocused` state + init parameter (L25–32); one `FlexibleStageCard` line in the card HStack (L75); max width 980 when three cards (L80). `LatticeStageMode` is **not** touched. |
| `WorkspacePlaceholder.swift` | +33 −3 | `showFlexiblePage` state (L673); joins `fullScreenPageUp` (L617); `latticeStageModeNeeded` also requires `flexible == nil` (L624); the modal call gains `onChooseFlexible:` (L1373–1376); `FlexibleStageSheet` + `FlexibleStagePage` presented next to the mode sheet (L1384–1394); `FlexibleStageChip` in the title slot (L2790–2792); one `.onChange(of: showLatticeWizard)` on the always-mounted background that sends the Settings door to the Flexible page under Flexible (L729–732). |
| `project.pbxproj` | +12 | three file refs, three build files, group entries, Resources entries (IDs `F1E0…`). |
| `TopOptBridge/include/module.modulemap` | +1 | `header "FlexibleBridge.hpp"`. (The overnight `FlexibleLattice.hpp` line was removed with the exporter.) |
| `MetalMeshView.swift` | see Morning round | the dent's opaque flag (flags.y), the X-ray ghost (flags.z), and the Flexible lattice as a third G-buffer writer: every line is listed under "Morning round → Hook lines". |
| `SmoothingPageRound2Tests.swift` (test) | +2 −1 | the pinned `fullScreenPageUp` text includes `showFlexiblePage` (+ one comment line). |

## Test evidence (raw, pasted, unedited)

**Targeted tests** (`swift test --filter "FlexibleBridgeTests|FlexibleStageTests"`, after the last commit):
```
	 Executed 32 tests, with 0 failures (0 unexpected) in 3.928 (3.940) seconds
```

After the sync, with the hook-adjacent suites
(`FlexibleBridgeTests|FlexibleStageTests|LatticeStageModeTests|LatticeSettingsPersistTests|ProjectStoreTests|UndoHistoryTests`):
```
	 Executed 62 tests, with 0 failures (0 unexpected) in 3.877 (3.890) seconds
```

**Full app suite:** see "Full suite" below; it was started on `dcae9a03`.

**New tests**

- `FlexibleBridgeTests` (17), each checked against core:
  - catalogue: varioShore offers exactly [190, 220, 240]; every calibrate_first filament
    predicts nothing, with core's reason;
  - temperature note;
  - **0.292 MPa** for 20 % gyroid (core ρ 0.226) at 190 °C at the last tabulated strain,
    read through the bridge; the strain comes from `curveSet.strainMeasuredMax`, not a typed
    number;
  - 205 °C is refused as `temperature_not_tested`;
  - the inverse round-trips through the forward to 1e-9;
  - σ(ε) samples: none past the data;
  - **the pen curve passes through its points** and never overshoots its neighbours;
  - core's refusal sentence;
  - the stamp force rule;
  - **the box face's frame**: load −Z, 100 × 100, tied, Y = load × X, and the linked end is
    region 100 at 100 %;
  - rotation 90° is orthogonal;
  - design target = S × deepest (from core's own squish map);
  - tier band = core's literature band;
  - the density slice is owned by 101;
  - calibrate_first is refused with no columns;
  - **same-stack conflict names 100 and 101**;
  - check stamp: depth or beyond-data, never both; a heavy press leaves the data;
  - Auto: sentence + reasons + 6 candidates;
  - the job block reads back through `parse_job`.
- `FlexibleStageTests` (15):
  - **run job → core's `parse_job` round trip**: material, temperature, topology, feel,
    beads, bead width 0.42, rotation, kg→N at 9.80665, deepest, both curves, skin, resting
    face;
  - auto temperature + centre→edge round trip;
  - design + check stamps round-trip as core grids;
  - refusals: no filament, no loaded face;
  - the scene job opens a real scene;
  - **every library stamp at 3 pitches passes core's `stamp_grid_error`**, with cell ≤ ½
    pitch;
  - stamp size and rotation;
  - whole-face stamp stays on the face;
  - image: darker presses harder;
  - SVG outline filled;
  - settings round trip inside `LatticeSettings`;
  - **an untouched project is byte-identical**;
  - delete-and-re-ask clears Flexible;
  - **undo / redo through the project's history**;
  - kg→N.
- Probes (skipped unless an environment variable is set): `FlexibleTimingProbe`
  (`FLEX_TIMING=1`) and `FlexibleSliceProbe` (`FLEX_SLICE=1`).

**Known pre-existing failures** (#354's list, as quoted in C1's handoff):
- `AppModelTests`: the three 3MF tests (no lib3mf in a worktree macOS slice; this worktree's
  core was built with `LIB3MF_PREFIX=/nonexistent`, as the memory recommends);
- `OrganicSampleCubeTests.testThickerIsLive…`;
- `OrganicVariantCacheTests.testTheKeyIgnoresThickness…`;
- `LatticeCellGradingTests.testGradingChangesTheRenderedLattice`: reproduced on #354's
  head `8105522b` with its own core (see the overnight round).

PR (draft): https://github.com/Anarkissed/TopOpt/pull/362 · CI: the PR's checks tab.

## Overnight round (2026-09-29, while you slept)

> **Partly superseded by the Morning round below.** The separate lattice layer
> (`FlexibleLatticeRenderer.swift`) and the STL exporter (`flexible_lattice.cpp`,
> `FlexibleLatticeExport.swift`) described here are REMOVED; the lattice is now drawn inside
> MeshRenderer, and exports wait on core. The field's gyroid is now a ladder (see Morning).
> The evidence PNGs this section names (`lattice_pad_*`, `lattice_split_pad_*`,
> `page_composite_*`) were deleted with the layer. The split faces, Generate gate and dent
> sections still hold.

### In plain words

- **The dent reads through the part.** While a dent is shown, the part drops to 30 %
  opacity and the dented face map stays at 100 %.
- **Split faces work as loaded faces.** A face you split on the Surface stage offers each
  half as its own loaded face. A tap picks the half you touched, using the Surface stage's
  own rule. Core frames each half from its own triangles, so a half of the pad's top is
  50 × 100, not 100 × 100. The names read "face 1 · top A".
- **Generate lattice.** When every loaded face has a design core accepted, a **Generate
  lattice** button appears at the bottom right. If it can't run yet, the button says why
  in one sentence (no filament, calibrate-first, a shared stack, or a face core refused).
  - Generating builds the lattice from core's assembled density field. The part becomes a
    ghost (18 %), the lattice is drawn inside it, and **the squish plays on repeat**:
    rest → full design load → rest, every 2.4 s. The dent and the lattice move together.
  - **Hide / Show lattice** and **Generate again** sit beside it. "Out of date" shows
    when you change a face after generating.
- **Export.** The Export button opens a modal with two cards:
  - **STL:** the part with its lattice as one closed solid. Draft / Standard / Fine set the
    sampling. The card shows the size before you export, a progress bar, Cancel (which
    deletes the partial file), and then the share sheet. Above 500 MB it warns that a
    slicer may be slow to open the file.
  - **G-code:** greyed out, with the reason: "TopOpt does not slice (ARCHITECTURE §2)".
    What comes next (DECISIONS 2026-09-27 item 6) is post-processing your sliced G-code
    for foaming filaments.

**Please look at these three things:**

1. **The STL is big.** The 100 × 100 × 20 mm pad, gyroid, with one 0.42 mm bead per wall:
   | quality | pitch | triangles | size |
   |---|---|---|---|
   | Draft | 0.210 mm | ~17 M | 824 MB |
   | Standard | 0.168 mm | ~27 M | 1.3 GB |
   | Fine | 0.140 mm | ~40 M | 1.9 GB |

   A whole-part lattice meshed finely enough to keep a 0.42 mm wall closed is simply that
   large. The honeycomb is about 60 % of these sizes. Options are yours:
   - decimate flat regions;
   - export only the lattice region and let the slicer fill the rest;
   - go the G-code route sooner.
2. **The lattice is a layer drawn over the part, not occluded by it.** You see every wall
   through the ghost body. That is on purpose for an x-ray look, but the part's near side
   does not hide the far walls.
   - The composed frame (`page_composite_pad_gyroid_{rest,full}.png`) shows the cost: the
     lattice also covers the dent's colour map. Only the map's rim and a few deepest
     (yellow) spots show through the pores.
   - The squish still reads as a sunken centre.
   - If you want the map on top, or the walls hidden where the body is in front, the
     follow-up is folding the march into MetalMeshView's passes. The octet did this.
3. **I could not run it on the simulator tonight.** Launching the app on my simulator
   (147E56A1, not yours) was refused by the permission check, and I did not work around
   that. The new build is installed there, but none of the overnight screens has been
   seen on a device. The evidence below is the preview's own shader rendering offscreen,
   not screenshots.

### Your rulings this round, and where they live

| ruling | where |
|---|---|
| "the dent to show via an opacity drop in the model (but the dent is full 100% opacity)" | `FlexibleStagePage.dentBodyAlpha = 0.3`. The dented quads carry tint `flags.y = 1` (`FlexibleOverlayMesh.tints`), and `MetalMeshView` keeps those fragments at alpha 1 (hook below). |
| "work on the split faces" | `FlexibleRegions.swift` |
| "the lattice generated when everything is done and then an animation showing the squishing of the model playing on repeat with an 'export' button that will pull up a modal to either export gcode or an stl" | the Generate / Export pills, `FlexibleLatticeGeneration.swift`, `FlexibleExportSheet.swift` |
| "there is no core yet for Flexibles, so your preview will be the source of truth" | `FlexibleLatticeField.swift` defines the geometry once. The renderer (MSL) and the exporter (C++) are held to it by tests. |
| G-code: "STL now, G-code next" | the G-code card says "Not ready yet" and why |
| Generate: "Button + design load" | the loop plays each face's own design load |

### The lattice, defined once (`FlexibleLatticeField.swift`)

- **Input.** Core's assembled density field for the faces' current designs
  (`FlexibleScene.densityField` → `assemble_density_field`).
- **Gyroid.** Walls are whole beads (R1), t = beads × bead width. The cell follows ρ
  continuously, with L = 3.0915 t/ρ (03-generators §3), clamped to ρ ∈ [0.05, 0.9].
- **Honeycomb.** One cell for the whole part, d = 2t/ρ̄ (03 §4, uniform d in v1), as prisms
  along the build direction.
- **Skin.** Default 0.8 mm of solid under every face. A loaded face with skin off lets the
  lattice run to its surface.
- **What the preview draws:** the walls only,
  `F = max(wall, dRegion, dPart, dSkin)`. The body and skin are the ghosted mesh.
- **What the STL writes:** the body plus the walls,
  `S = min(max(dPart, −max(dRegion, dSkin)), F)`.
  - ★ The spec first said `min(dRegion, dSkin)`, which made every skin air and the part
    outside the region hollow. Both my tests and the exporter's builder caught it
    independently; it is fixed, and the change is recorded in the file's header.
- **Three copies of the field, held together:**
  - **Swift reference.**
  - **C++ exporter (`flexible_lattice.cpp`):** bit-identical at 4,000 points on each of five
    fields (graded ρ from 0.01 to 1.0, a region edge, four build directions).
    - Controls: the old π rounding gives 1,220 differing values, and a wall one ulp
      thicker moves ~1,000.
    - To get there, the C++ now uses Swift's `Float.pi` (rounded toward zero) and
      `simd_normalize`, both found by the verifier.
  - **Metal shader:** within 1.2e-4 mm (gyroid) and 2.4e-6 mm (honeycomb) at 256 points.
    The GPU's own sin/cos is the gap.

### The preview renderer (`FlexibleLatticeRenderer.swift`, `FlexibleLatticeShader.swift`)

- **Technique.** Built on the octet preview's approach: a per-pixel sphere-tracer of the
  field on a transparent layer above MetalMeshView. It takes no touches, so orbiting still
  reaches the part.
- **Rays.** Unprojected in double on the CPU. Inverting in single precision is what cost
  the octet preview 1–4 px of swim.
- **Squish.** The shader inverts 02-squish-model §6's ramp per sample: a point at t in a
  column moves s·d·(exit − t)/(exit − entry) along the load. The depths are core's
  buildable depths (`FlexibleSquishFace(stack:design:)`). One page clock drives both the
  dent and the lattice, so they stay in phase.
- **Frame time at 1024² on the M2 Pro** (median):
  | | rest | squished |
  |---|---|---|
  | gyroid | 15–18 ms | 25–26 ms |
  | honeycomb | 4–5 ms | 8–9 ms |

  The drawable is capped at 1152 px, as for the octet.
- **March cap.** The gyroid step cap is 0.1 cell. At 0.25, 2,203 px disagreed with a fine
  reference march at 768²; at 0.1, 95 px did.

### The STL exporter (`flexible_lattice.cpp`, `FlexibleLatticeExport.swift`)

- **Streaming.** Marching cubes over `solid`, streamed: two sample layers in memory and a
  1 MiB write buffer. The triangle count is patched in at the end.
- **Test box (30 × 30 × 12 mm).**
  - The mesh is closed: every directed edge is matched once each way, and a flipped facet
    shows as a failure.
  - It winds outward.
  - Its volume is within 0.9 % (gyroid) and 1.4 % (honeycomb) of a Monte-Carlo integral of
    the Swift field.
  - It is deterministic.
- **Cancel** deletes the partial file.
- **Off the main thread.** The page runs the export off the main actor and caches the size
  estimate per lattice and pitch.

### Hook lines added this round (in #354's files)

| file | lines | what |
|---|---|---|
| `MetalMeshView.swift` | +4 −1 | `float solid;` in `VOut` (L426), `o.solid = in.flags.y;` (L487), and in the fragment `float a = in.solid > 0.5 ? 1.0 : bodyAlpha; return float4(rgb * a, a);` (L683–684). No other tint writer uses slot 5 (checked: SurfaceTint writes slot 4 only), so every other screen is unchanged. |
| `TopOptBridge/include/module.modulemap` | +1 | `header "FlexibleLattice.hpp"`, the exporter's POD API. |

All other work this round is in new files:

- `FlexibleRegions`
- `FlexibleLatticeField`, `FlexibleLatticeGeneration`, `FlexibleLatticeGlue`
- `FlexibleExportSheet`
- `FlexibleLatticeRenderer`, `FlexibleLatticeShader`
- `FlexibleLatticeExport`
- `flexible_lattice.cpp` and `FlexibleLattice.hpp`
- five test files

### Evidence (`docs/handoffs/evidence/2026-09-29-flexible-screens/`)

- **Lattice layer, drawn offscreen by the preview's own shader.** These are not device
  screenshots. The part is settled as the page draws it, and the dent is ×3.
  - C1's pad designed at 30 kg: `lattice_pad_gyroid_{rest,half,full}_x3.png` and
    `lattice_pad_honeycomb_{rest,half,full}_x3.png`.
  - The pad split at x = 50, halves at 10 kg and 25 kg (buildable deepest 2.25 mm and
    2.90 mm): `lattice_split_pad_10kg_25kg_{rest,full}_x3.png`.
- **The page's frame, composed offscreen from its own two renderers:**
  `page_composite_pad_gyroid_{rest,full}.png`. MeshRenderer draws the settled overlay mesh
  at the 18 % ghost, with the dented map opaque and dented ×3 × amplitude. The lattice layer
  is laid over it with the page's projection. This is the closest I could get to the screen
  without a launch.
- **Regenerate** with
  `FLEX_EVIDENCE_DIR=<dir> swift test --filter FlexibleLatticeEvidenceProbe`.
- **Dent through a 30 % body** (on the device, before this round's launch refusal):
  `s5_pad_dent_body_30pct_map_opaque.png`.

### Tests

`swift test --filter Flexible`, after the last commit:
```
Test Suite 'FlexibleLatticeFieldTests' passed at 2026-09-29 04:42:37.324.
	 Executed 4 tests, with 0 failures (0 unexpected) in 3.668 (3.669) seconds
Test Suite 'FlexibleLatticeRendererCoverageTests' passed at 2026-09-29 04:42:38.358.
	 Executed 2 tests, with 0 failures (0 unexpected) in 1.033 (1.033) seconds
Test Suite 'FlexibleLatticeRendererTests' passed at 2026-09-29 04:42:44.725.
	 Executed 11 tests, with 1 test skipped and 0 failures (0 unexpected) in 6.366 (6.367) seconds
Test Suite 'FlexibleRegionsTests' passed at 2026-09-29 04:42:44.775.
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.050 (0.050) seconds
Test Suite 'FlexibleSliceProbe' passed at 2026-09-29 04:42:44.775.
Test Suite 'FlexibleStageTests' passed at 2026-09-29 04:42:46.536.
	 Executed 15 tests, with 0 failures (0 unexpected) in 1.760 (1.762) seconds
Test Suite 'FlexibleTimingProbe' passed at 2026-09-29 04:42:46.537.
	 Executed 63 tests, with 4 tests skipped and 0 failures (0 unexpected) in 18.180 (18.186) seconds
	 Executed 63 tests, with 4 tests skipped and 0 failures (0 unexpected) in 18.180 (18.187) seconds
```

New this round:

- **`FlexibleRegionsTests` (3):**
  - sectors are declared, named and picked by the side of the tap;
  - core frames a sector from its own half;
  - the overlay replaces only the sector's triangles.
- **`FlexibleLatticeFieldTests` (4):**
  - core's field becomes filled grids;
  - walls exist inside and the skin is solid;
  - skin off reaches the face;
  - the honeycomb is a prism along the build axis.
- **`FlexibleLatticeExportTests` (8):**
  - C++ = Swift, both to 1e-4 and bit-exact;
  - skin and body are solid;
  - closed, wound, and the right volume;
  - deterministic;
  - cancel;
  - two layers held (self-reported);
  - refusals.
- **`FlexibleLatticeRendererTests` (11):**
  - the shader compiles;
  - the uniform layout matches the MSL, field by field;
  - the GPU matches Swift, and the squish probe matches the Swift pullback;
  - the pullback inverts the ramp;
  - coverage, and the two topologies differ;
  - s = 0 draws exactly the rest lattice;
  - the march matches a fine reference march, with controls that go red;
  - frame time;
  - frames run only while the squish loops.

Each comparison has a control that goes red.

**Full app suite.** It was started on `dcae9a03`, before this round. The raw result is
under "Full suite" below.

- **Tonight's MetalMeshView hook.** I ran the 111 tests that draw through MetalMeshView's
  fragment shader on HEAD `fe9dc359`, and all passed:
  - `LatticePreviewBodyAlphaTests`, `UnifiedShadingTests`, `ViewerVisibilityRegressionTests`
  - `StageBackdropTests`, `SurfaceStageTests`, `SurfaceRound7Tests`
  - `FaceSelectionTests`, `ContactShadingTests`, `ViewerTests`
  - `FaceProtectionTests`, `LatticeGBufferMaskTests`
  ```
  	 Executed 111 tests, with 0 failures (0 unexpected) in 81.290 (81.299) seconds
  ```
  They rewrite `docs/handoffs/assets/120_*.png`; I restored those with git.
- **`LatticeCellGradingTests.testGradingChangesTheRenderedLattice` is PRE-EXISTING.** It
  fails identically on #354's head `8105522b` built with its own core
  (`GRADING lit uniform=3720 graded=3719 moved=298 noiseFloor=0 levels=[0.0, 1.0, 2.0]`,
  so 298 against a threshold of 500). It sits in #354's octet renderer, which this branch
  does not touch.
- **`0191aa6a` (the renderer, as cherry-picked) does not build on its own.** It declares two
  names the branch already had; the next commit, `e5247c45`, reconciles them. The tip builds.
  Keep this in mind if you bisect.

### What I did NOT do (this round)

1. **No on-device check of the overnight screens.** The simulator launch was refused
   (above).
2. **The lattice is not occluded by the body** (above).
3. **No decimation**, so the STL sizes are as in the table above.
4. **The G-code card is informational only**, as ruled.
5. **Draw-order limitation with the translucent body.** The body is drawn without depth
   writes while it is translucent. So an opaque dented quad drawn after a nearer
   translucent wall can overwrite it. From normal angles it reads correctly.
6. **The squish is the 02 §6 linear ramp.** It is a picture of the design, not a
   simulation.

## Morning round (2026-09-29) — X-ray view, and the lattice drawn inside the part's renderer

**This is the current state.** The separate lattice layer and the STL exporter from the
overnight round are gone.

### Your rulings, verbatim, and where they live

| ruling | where |
|---|---|
| "We are building this App first, so I would first look at the way App does the lattice preview and build upon that." | The lattice is drawn inside MeshRenderer like the Structural and Aesthetic previews (`FlexibleLatticePass.swift`, `MeshRenderer+FlexibleLattice.swift`). |
| "The exports aren't supposed to happen until core gets to it. So we don't need to worry about exports or sizes. I am simply looking for a fast preview via an SDF - like the preview in the other two sections of the lattice stage" | Exporter removed (recoverable at `85b1bdc0`). `FlexibleExportSheet` is static: two disabled cards, "Not ready yet — comes from core's Flexible lattice". |
| "Where is the ghost version with a dent and heat map?" / "I am not able to see through the model. Imagine an "X-ray vision" with a plane with a heat map for the dent. Make it a "view" button below the position gizmo (which should be on every screen that had a 3d object)" | `FlexibleViewControls.swift`: the gizmo (shared size and inset) and, under it, the workspace's view-button (same metrics and tokens) toggling X-ray. |
| "I'd like the x-ray to look more ghostly for this version with the bent plane showing the dent" | MetalMeshView ghost hook (tint flags.z): alpha 0.04 face-on, rising by 0.5·(1−N·V)^2.2 toward the outline, in DS accentCyan. The dented map (flags.y) stays opaque. |

### What you see (X-ray on)

- **The part** is a ghost, and **the loaded face** is an opaque heat-map plane that bends
  with the dent.
- **The lattice** shows inside through the ghost. It is lit by the octet's own deferred shade
  (`lsdf_shade`) and coloured by density: `LatticeStructureColour.pale` → the Flexible
  accent (DS accentGreen).
  - ★ The octet's dense end, `LatticeStructureColour.interior` (0.49, 0.42, 0.86), reads
    violet, so it is not used: never purple.
- **The squish** plays on repeat after Generate (rest → full design load → rest, 2.4 s).
  The walls and the plane move together.
- **Toggling:**
  - X-ray off → the lattice is hidden. It is not torn down, so turning X-ray back on
    recompiles nothing.
  - Generate / Generate again → X-ray on.
- **While a check stamp or a curve step owns the map**, the walls hide, so that map is not
  contradicted.
- Evidence: `inpass_xray_pad_gyroid_{rest,half,full}.png` (C1's pad, 30 kg, ×3).

### How it is drawn: a third G-buffer writer

- **The march.** `FlexibleLatticePass` marches `FlexibleLatticeField` into MeshRenderer's
  depth-prepass G-buffer: eye-Z, eye normal, and albedo with alpha as the mask, plus depth,
  with the same attachments and the same `.less`+write depth state. It runs after the octet
  and organic writers. The main pass's `lsdf_shade` then lights it, exactly as it lights
  the octet.
- **Two gates, active only while a Flexible pass is in frame:**
  1. The see-through body stays out of the G-buffer. Otherwise the 0.04 ghost would
     depth-reject every wall.
  2. The body draw is re-issued after the shade, with neutral AO. The ghost then blends over
     the walls, the ghost's back faces behind a wall fail depth, and the opaque map replaces
     the walls behind it.
- **One number.** The lattice's squish is `MeshRenderer.flexScale`, the dent's own scale,
  driven by the page's single 30 fps clock.
- **Speed (Stage B, applied because the first Release frame was 22–24 ms):**
  - (part SDF, skin) are stored as half-float, hardware-filtered; ρ stays exact.
  - The march alone uses range-reduced `fast::sincos`; hits, normals and probes stay
    precise.
  - GPU parity with the Swift field is about 1 µm (stated bound 5 µm).
- **Limit.** At most 4 loaded faces; Generate refuses more with one sentence.

### The gyroid changed: a ladder of true gyroids

- **The fault.** The overnight field was `q = k(p)·p`, with p in absolute model
  coordinates. That warps the cells by p·∇k, so the verifier found your symmetric pad's
  lattice lopsided: 1017 vs 2358 wall crossings at mirrored ends.
- **The fix.** Rungs `Lmin·2^(j/4)`, 19 % apart, each a true gyroid with one k. Neighbouring
  rungs blend their sheet functions over the middle half of each step, and the gradient
  includes the blend weight's own term.
- **The result:**
  - the mirror gap is 4.8 % / 0.7 %;
  - cell ratios against a constant-cell gyroid are 1.05 / 0.99 and 1.10 / 1.11;
  - the analytic gradient matches a central difference to 0.7 % at p95.
- **For you to judge.** Inside a blend the walls are a hybrid of two gyroids. The blend
  width and rung spacing are two constants: `ladderStepsPerOctave`, and
  `blendLo`/`blendHi`.

### Split faces: the seam

- **The fault.** The two halves' dented maps stepped apart at the cut: 0.315 mm at full
  load, with dark cracks.
- **The fix.** A corner shared by two loaded regions now averages both regions' columns.
  The step is 0.0 mm (control: 0.315 mm), and a whole face is unchanged bit for bit.
- Evidence: `inpass_xray_split_pad_10kg_25kg_{rest,full}.png`.

### Hook lines in #354's files (this round)

**`MetalMeshView.swift`** (cumulative since `a6fa2702`, including the overnight dent and
ghost hooks):

- **Shader** (+13 −1):
  - `float solid;` and `float ghost;` in `VOut`;
  - `o.solid = in.flags.y;` and `o.ghost = in.flags.z;`;
  - in the fragment tail: alpha 1 on the map, and the ghost's rim-lit alpha/colour
    (6 lines).
- **Renderer:**
  - `var flexibleLattice: FlexibleLatticePass?` (+1);
  - `wantsLattice` also true for the Flexible pass (1 edited);
  - `let ghostAfterLattice = flexibleGhostAfterLattice(...)` (+1);
  - the body draw becomes `if !ghostAfterLattice { countedDraw(...) }` (1 edited);
  - the re-issued ghost after the lattice shade (+7);
  - `gbufferSize` guard (1 edited);
  - `shellVisible = bodyAlpha > 0.004 && !flexibleGhostOutOfGBuffer` (1 edited);
  - the prepass guard (1 edited);
  - the third writer before `penc.endEncoding()` (+5);
  - the `latticeMaskDump` guard (1 edited).
- **Inputs:**
  - `MeshViewInputs.flexibleLattice` (+1);
  - the iOS and macOS inits (+1, 1 edited each);
  - `Coordinator.apply`: `if renderer.applyFlexibleLattice(inputs.flexibleLattice, device: view.device) { dirty = true }` (+1).
- **Inertness.** Every gate reduces to #354's expression when the pass is nil, not ready or
  hidden. A verifier compared 18 octet and organic frames recorded before and after: they
  are byte-identical. T12 proves the same in CI.

**Other files:**

- **`SmoothingPageRound2Tests.swift` (#354 test file)** (+2 −1): the pinned
  `fullScreenPageUp` text now includes `showFlexiblePage`, plus a comment line.
- **`module.modulemap`:** the overnight `header "FlexibleLattice.hpp"` is removed again.
  This PR's modulemap hook is back to S1's single `FlexibleBridge.hpp` line.
- **Untouched:** `LatticeSDFMetal.swift`, `UnifiedShading.swift`, `LatticeStageMode`,
  core/. `WorkspacePlaceholder.swift` and `LatticeSettings.swift` gained nothing this round.

### Added / removed

- **Added:**
  - sources: `FlexibleLatticePass.swift`, `FlexibleSquish.swift`,
    `MeshRenderer+FlexibleLattice.swift`, `FlexibleViewControls.swift`;
  - tests: `FlexibleInPassCompositeTests` (10), `FlexibleLatticePassTests` (10),
    `FlexibleSquishTests` (10), `FlexibleLatticeGradingTests` (2),
    `FlexibleOverlaySeamTests` (2), `FlexibleLatticePassPerfTests` (1, Release only),
    and `FlexibleLatticeFixtures`.
- **Rewritten:** `FlexibleLatticeShader.swift` (G-buffer source).
- **Removed:**
  - `FlexibleLatticeRenderer.swift` and `FlexibleLatticeGlue.swift`;
  - `FlexibleLatticeExport.swift`, `flexible_lattice.cpp`, `FlexibleLattice.hpp`, and
    `FlexibleLatticeField.solid(at:)`;
  - the test files `FlexibleLatticeExportTests`, `FlexibleLatticeRendererTests` and
    `FlexibleLatticeRendererCoverageTests`.
- **Deleted test functions (23)**, all either for removed code or ported:
  - Exporter: the C++ agreement tests (to 1e-4, and bit-exact), the export's
    closed/outward/volume, determinism, cancel, two layers held, refusals, and the solid's
    skin/body.
  - Standalone layer: shader compiles, uniform layout, GPU probe, squish probe, pullback,
    offscreen coverage, zero squish, fine-reference march, frame time, frames only while
    looping, lands where it projects, region/skin terms.
    - All except "frames only while looping", which has no MTKView now, are ported as
      T1–T11 in-pass.
  - Evidence probes: the two old opt-in probe tests and `testWriteEvidencePNGs`, replaced
    by `testDrawThePagesXrayFrameInPass`.

### Tests (raw)

All Flexible suites plus #354's renderer and page suites (UnifiedShading,
LatticePreviewBodyAlpha, LatticeGBufferMask, LatticeThreeAlgorithmsDraw,
OrganicCapsuleImpostor, LatticeSDFAlignment, Viewer, ViewerVisibilityRegression,
StageBackdrop, SmoothingPageRound2, LatticeStageMode, LatticeSettingsPersist), on HEAD after
the colour change:
```
	 Executed 197 tests, with 6 tests skipped and 0 failures (0 unexpected) in 254.856 (254.874) seconds
```
The 6 skipped are the opt-in evidence and timing probes and the Release-only frame budget.

**Every comparison has a control that goes red.** A verifier also switched on 15 real code
mutations one at a time.

- **What the tests catch:**
  - the ghost put back in the G-buffer → T5/T6/T7 red;
  - the body drawn before the shade → T6/T7/T8;
  - lattice AO on the heat map → T8;
  - the squish fixed at 1 or 0 → T9;
  - the ghost dropped → T6/T7/T8.
- **Gaps closed in the fix round:**
  - the march view's trig (T11 now 4168 px against a bar of 526);
  - the G-buffer normal (a model-space normal gives 1.07–1.62 rad);
  - the shader's 0.95 squish clamp (13 mm);
  - the 1152 px cap hook (2048 × 2048);
  - the `Coordinator.apply` line;
  - the ghost's far side at depth `.always` (43859 px).
- **Known instrument gap:** a colour ramp read at the deformed point is invisible to the
  fixtures. It is cosmetic.

### Frame budget (T16, Release)

Command: `swift test -c release -Xswiftc -enable-testing --filter FlexibleLatticePassPerfTests`.
Whole frame at 1152 px, MSAA 4×, X-ray config, on the M2 Pro.

| frame | median |
|---|---|
| gyroid fully squished (s = 1), five runs | 16.09 / 13.19 / 14.45 / 12.94 / 16.35 ms |
| gyroid s = 0 | 7.5–8.8 ms |
| honeycomb | 3.3–8.0 ms |
| hidden | ~1 ms |

- Two of the five gyroid runs miss 16 ms by 0.09 and 0.35 ms. ★ All were measured with
  about 40 % background GPU load from other apps and sessions, so re-measure on an idle GPU
  and on the iPad.
- The 1152 px cap is untouched.
- The octet cube in the same process took 67–83 ms. That is only a comparison bar (a
  different scene from the handoff's 12.5 ms), but worth a look by #354's owner.

### Evidence (`docs/handoffs/evidence/2026-09-29-flexible-screens/`)

These are the page's frame, rendered offscreen by MeshRenderer with the Flexible pass. They
are NOT device screenshots. The part is settled as on the page.

- **C1's pad** (top face 30 kg, the 0.3–1–0.3 curves, dent ×3; honeycomb ×4):
  - `inpass_xray_pad_gyroid_{rest,half,full}.png`;
  - `inpass_xray_pad_honeycomb_{rest,half,full}.png`;
  - poke-through: 0 map px in every frame.
- **Skin off** on the top face: `inpass_xray_pad_gyroid_skin_off_{half,full}.png`.
  Wall tops speckle the map on 16.6 % / 16.1 % of its px, with 5 / 32 px outside the
  silhouette (your call, below).
- **Split pad** (halves at 10 kg and 25 kg): `inpass_xray_split_pad_10kg_25kg_{rest,full}.png`.
  0 px poke-through, and the halves meet along the cut.
- **The X-ray ghost before Generate** (no lattice): `xray_ghost_dent_pad_{rest,full}.png`.
- **Regenerate** with
  `FLEX_EVIDENCE_DIR=<dir> swift test --filter FlexibleLatticeEvidenceProbe`.

### Your call

1. **Wall colours.** Pale → Flexible green. The octet's dense end would be violet, which
   breaks never-purple. Keep green, or pick another existing token?
2. **Skin-off faces.** The walls move per column while the map's corners average their
   neighbours, so wall tops show through the opaque map (16 % of its px at ×3, full). The
   squish model is unchanged. Accept it, or should the walls follow the map's interpolated
   surface?
3. **The ladder gyroid.** Please judge it on your restored project (blend width and rung
   spacing are two constants).
4. **More than 4 loaded faces?** Generate refuses them today. Raising the limit to 8 is a
   small change in new files.
5. **The map under X-ray.** While the lattice shows, the map has no AO or crease lines of its
   own, and there is no floor shadow under the 0.04 ghost (pre-existing).
6. **The map's per-column flat colours** read as a mosaic up close. And would iso-depth lines
   or a fixed colour scale make the dent read better in a still frame?
7. **The wall-profile editor's small 3D card** has no gizmo. The standard 210 pt gizmo would
   cover the card. Add a small one, or is your rule for full-screen 3D views only?

### Not done / warnings

- **Nothing here has been seen on a device.** The simulator launch is refused to me by the
  permission check. The build is INSTALLED on my simulator 147E56A1 (binary 09:23; strings
  `flx_gbuffer` ×3, `flexible-view-xray` ×1). Your M2 project and the seeded "Pad split top
  (Flexible)" project are on it.
- **For #354's owner (pre-existing):** `Coordinator.apply` re-uploads `flexDisplacements`
  only when `dirty || !appliedFlex`, so a new dent with unchanged tints is not uploaded. The
  fix is a content key there, a #354 hook not taken.
- **Commits that don't build alone.** Intermediate commits `760fc53c`, `cadaf920`,
  `9d8ed40f` and `a3318fdc` were not built individually, and `0191aa6a` (overnight) does
  not build alone. The tip builds for macOS and the iOS simulator. Keep this in mind if you
  bisect.

## What I did NOT do

1. **Simulator-driven SVG/image import.** The file picker is wired, and the import and
   rasterisation are unit-tested. I did not put a file into the simulator's Files app to drive
   it end to end.
2. **The dent reads only from a low angle.**
   - On the pad, ×3 on a 3 mm squish is subtle from above.
   - On the M2 stand, the 02 §6 ramp moves the part's own vertices through the whole stack,
     and at ×8 that visibly distorted the cradle. The exaggeration is now capped at ×4.
   - Whether the part's vertices should move at all, or only the face, is your call.
3. **The centre→edge baseline is a drawing aid.** It runs from the face's boundary to the
   column core's `edge_fraction` calls most-inside, along the frame's X. The curve's values are
   core's.
4. **No skin geometry.** `skin_on` is saved and sent, and core records it only (C1 #9).
5. **No bead-path preview or print settings.** Those are A2 and C5. (An STL export of the
   app's own lattice now exists: see the overnight round.)
6. ~~**Face picking uses the importer's faces (one region per face).**~~ Done in the
   overnight round: split sectors are loaded faces (`FlexibleRegions`).
7. **Undo is the project's snapshot history.** A curve drag is one step once it rests.

## Warnings for the next run

- **Taps on the simulator need a short press** (`duration` 0.1–0.15 s); instant taps were
  sometimes dropped. The screenshot → points factor depends on the image size: 1032 pt ÷
  image width.
- **Interop copies.** Never index a C++ vector member in a Swift loop; convert it with
  `Array(...)` once (see the timing above).
- **`swift test` rewrites other tasks' evidence.** Check `git status` after the full suite.
- **Seeded test projects.** My simulator is a separate device, "iPad Pro 13 Flexible-A1"
  (`147E56A1-…`). The three test projects on it were seeded by copying your M2 project and
  C1's pad STL. Your device was not touched.

## Full suite

`swift test` (whole package) on `dcae9a03` (before the overnight round), own scratch path,
03:04 → 06:34 (other sessions' suites shared the machine). Raw:
```
Test Suite 'All tests' failed at 2026-09-29 06:34:29.891.
	 Executed 2588 tests, with 36 tests skipped and 13 failures (0 unexpected) in 12572.089 (12572.356) seconds
```
13 assertion failures in 8 tests:

| test | status |
|---|---|
| `AppModelTests` × 3 (3MF) | pre-existing: the worktree's macOS core has no lib3mf |
| `LatticeCellGradingTests.testGradingChangesTheRenderedLattice` | pre-existing: identical on #354's head `8105522b` with its own core (moved 298 vs 500) |
| `LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds` | pre-existing: the test reads the first 900 characters of `startStressSolveIfNeeded`; #354's own DIAG lines put `latticeSim.run(ctx)` at offset 1073 on both `8105522b` and HEAD |
| `OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces` | pre-existing (#354's known list) |
| `OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology` | pre-existing (#354's known list) |
| `SmoothingPageRound2Tests.testWhileAPageIsUpTheWorkspaceDrawsNoChromeOfItsOwn` | **MINE, fixed** in `2ff7fed7`: it pins `fullScreenPageUp`'s exact text, which my S1 hook extended with `showFlexiblePage` (the one-predicate rule the test asks a new page to follow). Now green. |

The suite rewrote other tasks' tracked evidence (`docs/handoffs/assets/`, `evidence/`); restored.

## Blocked
None. No core brief was needed: every number on screen comes from the C1 bridge contract.

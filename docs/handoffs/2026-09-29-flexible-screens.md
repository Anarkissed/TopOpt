# Handoff — 2026-09-29-flexible-screens (TRACK app, A1): the Flexible screens

## Round 5 · batch E — "a protected face isn't frozen" (your item 4)

Your words: "For some reason a protected face is considered frozen - however, that is how we make a
lattice and protected from TO. Please fix this so a protected face isn't frozen."

**The cause was the split, not protection.** 'top A' on your pad is a cut piece of face 1 (region
103, x ≥ 50), and your 'Top' group is not even protected (Protect is on 'sides' and 'bottom' only).
#354's rule dropped every cut piece — and every union of pieces — from the lattice, so:
- the row said "Frozen, not latticed" under "Out of regime" (img 4);
- the Lattice button said "nothing set to lattice";
- the Flexible job, given no lattice region, latticed the WHOLE part.

Fixed on this branch, as you asked, in its own commits. Three of them touch only #354's rule and its
tests and are built to cherry-pick onto #354 (`ad00765f`, `3cb4da7d`, `7a9e0302`; simulated onto #354's
head `606c613a`: clean; not built there). **The app was NOT launched: nothing here has been seen on a
device or simulator.**

**What you will see:**
- **Main page, Selections:** 'top A' reads like any latticed piece — no "Frozen" chip, no "Out of
  regime". The Lattice button lattices it.
- **The lattice sits only on top A's side of the cut** (offscreen frames of the shipping renderer on
  a pad built like yours — 100 × 100 × 20, top cut at x = 50 — `batch_e/E_split_pad_topA_iso.png`,
  `…_topA_above.png`; your own project is checked by the numbers below, not rendered). With top B latticed too, the two halves meet with no wall between them
  (`…_topA_and_topB_iso.png`); with top B not latticed, the lattice ends at the cut under a wall, as it
  does at any face edge.
- **The words, when a region still cannot be latticed** (only a region with no surface left on the
  model): "Protected, not latticed" for a protected group, else "Not latticed". Never "Frozen", never
  "Out of regime".
- **Your 'Union of 2'** (round 5: top A + top B in 'Top') is latticed too, both halves, at the union
  row's depth (4 mm — the row you see; 'top A' and its 25 mm are folded under it).
- **This also changes Structural and Aesthetic runs** for any split piece set to Lattice. None of
  your other projects has one: their job bytes are identical (below).

**The Flexible side (your pad) — the lattice now goes where your main page says:**
- **Round 3 copy (img 4):** the Flexible lattice is top A's 25 mm prism — the right half of the pad.
  Top B is still pressed, with no lattice under it, so it cannot squish. The page says so at once:
  - Settings line: "Ready · No lattice under Top B" with [Fix];
  - main page pill: "No lattice under Top B" (a tap opens the fix);
  - the pop-up: "Top B has no lattice under it, so it can't squish" — **[Lattice under it] [Top B
    rests]**.
- **[Lattice under it]** makes a main-page group 'Top B', **Protected + Lattice** (your rule), 20 mm
  deep (the pad under it). No load moves. One undo step. The part re-opens with lattice under every
  column of top B.
  (A face already in a group that may carry a lattice role gets that row's own "Lattice" tap instead.)
- **Round 5 copy:** the union lattices the top 4 mm. Faces 3 and 5 have lattice under only 23 % of
  their columns: "Only 23 % of Face 3 has lattice under it". [Lattice under it] makes 'Face 3' and
  'Face 5' (50 mm each). After those two taps the whole pad is latticed again.
- **Never a blocker.** Exit still builds the lattice; the face just would not squish.

**Not done:**
- **Not seen on a device or the simulator** (track rule). The iOS build succeeds.
- **The cherry-pick onto #354 was simulated (clean), not built.** #354 is 11 commits ahead of what
  this branch has merged.
- **The HIS_PROJECT_DIR probes** (`LatticeHisProjectRenderProbe`, `LatticeHisSteppedBakeProbe`) were not
  run. They need a model.step. Your stand has no split piece, so its stage job is byte-identical and
  their picture cannot move. Your pad is an STL; its pictures are the frames above.
- **A union of pieces still gets no 3D depth handle** on the main page (it had none before). A cut
  piece's handle now sits over the piece only.
- **A protected union of pieces**: the protection still goes to core as region 105 with no faces
  (`FaceRegion.kitSpec` carries no parts — batch M's "Couldn't simulate"). Not touched; #354's.

**Your call:**
1. **The round-5 'Top' row reads 4 mm** (the union's own row). The run follows it; 'top A' (25 mm)
   is folded under the union, as the Selections list shows. Should a folded piece's own depth win
   where it differs?
2. **[Lattice under it] makes a new protected group** when the face is in none. The other choice is to
   add the face to the group that presses it (e.g. top B into 'Top', as you did in round 5) — but that
   group's load would then spread over it. Which?
3. **The threshold**: the line appears when under half of a pressed face's columns have lattice.
4. **Or no tap at all**: should a pressed Flexible face ALWAYS get lattice under it? That would change
   round 3's rule ("the main page's Lattice roles decide where the Flexible lattice goes").

### How it works (`LatticeSectorOutline.swift`, new)

- A piece is its member faces ∩ its half-spaces. On a planar face — or each planar facet of a curved
  one (`LatticeFaceFacets`) — every half-space is a half-PLANE in the face's own frame. Each member's
  outline loops are clipped to it and emitted as ordinary face prisms under the piece's own key (its
  role, depth, expand, density). Core's `region_contains`, #354's previews and C1 Flexible all read
  `outline_uv` even-odd: **no core change**.
- The clip keeps loops simple: a cut across a concave outline gives separate loops, never a
  zero-width bridge along the cut (a bridge would be an outline edge over air, and every rim reads
  edges). Sutherland–Hodgman is only the fallback.
- **The cut edge** reads the piece's own face: `finishSeams` makes it a SEAM when the sibling piece is
  latticed and leaves it a RIM when not. A piece cut again first has its neighbour's long edge split
  at the T (the seam test matches edges end to end).
- **One surface, told once:** a piece whose ancestor in the same group (its union, the face it was cut
  from) emits its surface with the same role is skipped — ruling (g)'s own test, so it is never named
  as left out either.
- **Byte-identical without cuts:** a face no cut touches takes exactly the shapes it always took.
- **The expand** crosses a cut edge like any face edge (your "every direction"), unless it is a seam.
- **The row's 3D depth handle** for a piece is built from the piece's own clipped surface.
- Protected + Lattice on a piece: latticed, and protected to the depth its slab emits (round 3
  ruling a); core's parser accepts the stage job.

### Hook lines in #354 / main files (each grepped after the edit)

| file | anchor | +/− | why |
|---|---|---|---|
| ProjectModel.swift | `latticeJobRegions`: `regionMembers: { [weak self] gid, rid in self?.latticeEmittedRegionMembers(gid, rid) },` | 1 edited | one surface told once (the dedupe) |
| ProjectModel.swift | `regionCuts: { [weak self] rid, f in self?.latticeRegionCutSets(rid, face: f) ?? [[]] },   // ★ batch E` | +1 | each member's half-spaces |
| ProjectModel.swift | `latticeRegionMembers`: `if let r = faceRegions.region(rid), !r.cuts.isEmpty \|\| !r.parts.isEmpty { return latticeSectorMembers(rid) }` and its doc line | +1, 1 edited | a piece / union reaches the run iff it keeps surface |
| ProjectModel.swift | `latticeRegionDepthPlane`: `in: latticeSectorMesh(rid) ?? mesh)   // ★ batch E: a split piece's own surface` | 1 edited | the row's handle over the piece |
| LatticeRegionEmission.swift | `regionCuts: (RegionID, FaceID) -> [[RegionCut]] = { _, _ in [[]] },` (+ its comment) | +2 | the parameter; its default keeps every call byte-identical |
| LatticeRegionEmission.swift | `var sectorPieces = Set<Int>()` | +1 | the prisms that were clipped |
| LatticeRegionEmission.swift | `let piece = LatticeSectorOutline.pieces(…)` / `for r in piece.shapes {` | +1, 1 edited | the member loop through the clip |
| LatticeRegionEmission.swift | `if piece.clipped { sectorPieces.insert(out.count) }` | +1 | |
| LatticeRegionEmission.swift | `if emitted == 0, !piece.clippedAway { skipped += 1 }` | 1 edited | a face outside the piece is not a skipped face |
| LatticeRegionEmission.swift | `LatticeSectorOutline.meetAtTJunctions(&out, pieces: sectorPieces)` before `finishSeams` | +1 | the T |
| WorkspacePlaceholder.swift | the row chip: `Text(LatticeSectorOutline.notLatticedWords(protected: force.isProtected(g.id)))` | 1 edited | "Protected" only when protected |
| WorkspacePlaceholder.swift | `static let latticeRegionNotConsumed = LatticeSectorOutline.notLatticedWords(protected: true)` | 1 edited | never "Frozen" |
| LatticeRegionDrawer.swift | the unreachable headline: the words + `.noMaterial`; `verdict: .noMaterial` | 2 edited | never "Out of regime" |

No core file. No new case in `LatticeStageMode`. The Flexible half touches Flexible files only
(FlexibleReadiness, FlexibleFixPopup, FlexibleStagePage, FlexibleMainStage; new FlexibleLatticeUnder).

### #354 tests changed (where the old behaviour IS the bug)

- `LatticeSeparationRegionTests.testARegionsLatticeChoiceIsCapturedAndTheRowSaysItIsNotConsumed`:
  "Frozen, not latticed" → "Protected, not latticed" (the drawer is `held: true`), and not `.outOfRegime`.
- `LatticeRegionEmissionFaceRegionsTests.testACutSectorAndAnExcludedRegionEmitNothing`: comment only
  (nil members still emit nothing; a cut sector now has members). Name kept.
- `LatticeVariantFaceWallsTests.testACutSectorIsCountedAndNamedOnTheStageAndTheVariant` (ruling g): a cut
  child is now latticed (told once by a parent with the same role; emitted Include under an Off parent,
  Exclude as a Solid child — never named); the naming, the variant line and the banners are pinned on
  a piece with no surface (the wall cut at y = 50).

**Flexible tests changed:** `FlexibleBatchBReviewTests.testANewLatticeRegionOnTheMainPageRebuilds` (the
scene re-opened: by its key, not its voxel count — the taps made the lattice the whole part).
`FlexibleHisProject.restore` replays the taps (`asSaved: true` restores his project as saved).

### Proof

**His projects' stage job bytes, before (`fb715885`) and after (`ad00765f`, and again on `7a9e0302`)**, dumped with the app's own
`makeLatticeRunRequest` (`LatticeJobJSONDump`, `SWIFT_DETERMINISTIC_HASHING=1`), each from a fresh copy:
- his store (P2, the 7 projects round 3 hashed) and the A1 simulator (4 projects): **10 of 10 unsplit
  projects byte-identical** (the stand 68BF7B74 `38913b3fe56f021f` = `38913b3fe56f021f`, …);
- the split pad moves, as intended: round 3 copy 0 → 1 lattice region (top A, 25 mm, outline x 50…100),
  round 5 copy / live 0 → 2 (the union's halves, 4 mm). Their cell window moves with it (Auto now has
  an include wall).
- `batch_e/stage_job_hashes.txt`, `pad_r3_stage_job.diff`, `pad_r5_stage_job.diff`.

**Tests** (each comparison has its control beside it; every behaviour test RED by mutation):

| test | pins | RED control |
|---|---|---|
| `LatticeSectorOutlineTests` (17) | the clip: half the face on its own side (positional), x = 90 → 1000 mm², the cut edge reads the own face, a hole, a U gives two loops and no bridge, outside/inside/two cuts, a tilted face; the emission: no cut = unchanged, a piece's side only, a face outside the piece is not skipped, a face with no outline is; the pad: reaches the run, one prism on x ≥ 50, seam vs rim, the T, protected + latticed + core accepts, the words, the handle | 6 RED before the hooks (`red_before_hooks.txt`); mutations M1–M10, D1, D2 RED |
| `LatticeSectorRenderTests` (3 + evidence) | the preview's region field (octet "doubled", stepped): top A 22 620 voxels on x > 50, 0 on x < 50 — top B latticed: the mirror; organic: 1 485 capsules, every one at x ≥ 51.04; real frames: top A lights 6 648 px on one half and 0 on the other, top B the opposite | the flip (top B) in each; mutations M3–M5 RED |
| `LatticeSectorHisProjectTests` (2) | your round 3 copy: top A one prism, 5000 mm², x 50…100, 25 mm, nothing left out; round 5: the union's two halves, top A told once, 10 000 mm² with no overlap, a seam | M2 (no dedupe), M3, M4, M7 RED |
| `FlexibleLatticeUnderTests` (3) | the rule on values; your pad: FlexibleJob.regions = top A's prism, top B 0 % / top A 100 %, said, the main pill, the tap makes 'Top B' (protected, Lattice, 20 mm), top B then 100 %; the fixture's taps are the page's own offer | mutations F1–F7 RED |

Mutation runs: `batch_e/mutations_region_fix.txt` (10 of 11 RED; M11 — "an empty cut set still goes
through the clip" — is an equivalent mutant: the clip returns the face untouched), 
`mutations_flexible.txt` (7 of 7 RED), and D1/D2 (2 of 2 RED).

### Build and suite (raw lines, this Mac)

- `swift build --build-tests` → `Build complete!` (every build in this batch; core untouched, no
  `build_core.sh`).
- **Targeted suite** on `120e4d76` (every `Flexible*`, every `Lattice*`, `Organic*`, `Smoothing*`,
  `Surface*`, `FaceRegion*`, `Variant*`, `FrozenRegion*`, `UnifiedShadingTests`, `ViewerTests`,
  `StageBackdropTests`, `ProjectStoreTests`, `UndoHistoryTests`, `BottomBarMeasurementTests`,
  `GroupViewStateTests`, `ProtectFreezeVsSolidityTests`, `StrutLineWidthTests`):
  `Executed 2038 tests, with 44 tests skipped and 13 failures (0 unexpected) in 13676.728 (13676.913) seconds`.
  The failing tests: the four known — `LatticeCellGradingTests.testGradingChangesTheRenderedLattice`,
  `LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds`,
  `OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces`,
  `OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology` — and
  `LatticeVariantFaceWallsTests.testACutSectorIsCountedAndNamedOnTheStageAndTheVariant`, which pinned
  the old drop; re-pinned in `7a9e0302` (rerun: `Executed 8 tests, with 0 failures`; RED with the old
  member rule: 5 assertions). `AppModelTests` (3MF ×3, known) is outside this filter.
- Before the fixture's taps (the region fix alone), the first 51 `Flexible*` tests already showed 3
  failures — `FlexibleBatchMDentTests` ×2 and `FlexibleBatchMVerifyTests.testEachGroupsStressIsOnItsOwnScaleAndThePartIsNotOneColour`
  (their whole-part lattice was gone); with the taps all three pass (`Executed 3 tests, with 0 failures`).
  That run was stopped there to test the final code once.
- **iOS:** `xcodebuild … -derivedDataPath …/DerivedData/flexA1 build` → `** BUILD SUCCEEDED **`;
  `LatticeSectorOutline.o`, `FlexibleLatticeUnder.o`, `ProjectModel.o`, `FlexibleReadiness.o` newer
  than their sources.

### Decisions (00-decisions.md)

D-R5-E1 … D-R5-E6 (round 5 · batch E).

### Commits (PR #362's branch `claude/flexible-screens`; nothing pushed)

- `ad00765f` — #354 side: a split piece is latticed on its own side of the cut; the words.
- `cfc76743` — the Flexible half: [Lattice under it]; the fixture's taps.
- `3cb4da7d` — #354 side, follow-up: the piece's depth handle; a face with no outline is skipped.
- `120e4d76` — a Flexible re-pin (`FlexibleBatchBReviewTests`: the scene's key, not its voxel count).
- `7a9e0302` — #354 side: ruling (g)'s test re-pinned (`LatticeVariantFaceWallsTests`).
- the next commit: this section, DECISIONS D-R5-E1…E6, evidence (`batch_e/`).
- **For #354: cherry-pick `ad00765f`, `3cb4da7d`, `7a9e0302`** (simulated onto `606c613a`: clean; not
  built there). The Flexible commits stay here.


## Round 5 · merge — batch S into batch M, and the syncs (read this first)

Batch S (the Settings page) was built in a side worktree while batch M (the main page) was built here.
This pass merged them, synced the other branches, and ran the targeted suite and the iOS build on the
result. **The app was NOT launched: nothing here has been seen on a device or simulator.** The pictures
are offscreen frames from the shipping renderer and the hosted panel's pixels.

**What you see now (both batches together):**
- **Settings page:** the folder tabs on the left ([Model], one tab per group in its colour, [Rests],
  [+ New]); each pressed face framed in its group's colour; the selected group squishing alone; the
  number boxes, units, Reset all, delete, Exit / Save & Exit — all from batch S. The dent heat and
  its legend are batch M's FEA rainbow, graded per vertex, with the stamp's spread.
- **Main page:** batch M's per-group sims, Stress per group, one legend card, the dent view as X-ray
  with ghost walls. Batch S's group frames now show in **every** view, including each "Play all" turn.
- Pictures: `evidence/2026-09-29-flexible-screens/merge_r5/R5merge_settings_page.png`,
  `R5merge_main_page.png`, `R5merge_crease_seam.png`.

**What the merge had to fix (each with a test and a red control):**
1. **The frames vanished under "Play all"** (the main page's default). The renderer swaps each turn's
   own tints in with its field (batch G verification), and batch S had framed only the composed tints.
   The frames are now painted into every turn's tints. `FlexibleMergeR5SMTests`, on your project split
   as img 4: 0 of 8 280 framed vertices off on both turns; red control (`controlTurnsWithoutFrames`):
   8 280 of 8 280 off.
2. **The player's dot** is the group playing now (batch M) in the colour you chose (batch S)
   (`FlexibleSquishPlayer.dotColour`). The red controls are each side's own rule: S's shows no dot
   under Play all, M's shows the default orange instead of your blue.
3. **Two batch M checks measured the frames as if they were heat.**
   - The main page's "graded" check now measures the heat band. The frame is a deliberate step
     (D-R5-S1). Heat band step 0.0000; core's column colours (the red control) 1.2490 / 0.2062.
   - The depth check now keys each face's interior separately, so a crease between two solid faces
     counts as an edge.
4. **The crease seam (open, not fixed).** Under group 2's turn, group 1's frames are solid planes. Where
   the top's frame meets Face 5's, the two lifted planes leave batch M's known 1 px seam, and walls
   show through it: 525 px from the back left, 0 in the other views. Every face's interior reads 0;
   the no-depth control reads 28.8–59.8 %. `R5merge_crease_seam.png` shows it.

**Found on the way — batch M verification's fallout (fixed):**
- The verification pass committed without a full run (its result never came back). Two in-pass
  controls (T6 ghost-first, T8 lattice AO) read 0, because the dent planes' depth now keeps the walls
  off the map. Each control now also removes the planes' depth. T6: 26 372 of 30 929 px, and with the
  planes' depth 0 (now asserted). T8: 23 900.
- Its DECISIONS rows (D-R5-MV1…MV6) were never committed. This pass committed them unchanged (645f0973).
  It wrote no handoff section; its commit message (07a43ea0) is the record.

**Your call:**
- **Group colours against the rainbow (D-R5-X2).** S chose green, orange, red and blue, with blue last,
  when the dent heat was blue → cyan → white. M then made the heat the FEA rainbow, so all four group
  colours are now on the heat ramp.
  - On big faces the frame's near-black gap keeps it apart.
  - On a thin side face there is no gap (fewer than 16 columns across). Your Face 3, 64 × 13 columns,
    shows an orange frame against yellow-orange heat (main page, group 2).
  - Group 1's green frames also match the lattice density legend's green.
  - Options: (a) keep it; (b) always keep the gap, even 1 column; (c) another cue for the frame.
- Batch S's open calls (1)–(7) and batch M's still stand (their sections below).

**Not merged — Blocked:** `#358 claude/raster-receipt-fields` (5 commits to `4764ca7e`, the lattice-types
strut law). It conflicts in `core/src/cli/job.cpp`, which is not ours. At the end of `parse_job`, two
blocks were inserted before `return job;` on each side:
- #361's Flexible block (`05ee339e`, C1);
- #358's "one resolved topology" write-back (`4764ca7e`).

Keeping both looks like the resolution, but it is core's call. #361 meets the same conflict when it
syncs #358. Nothing was merged from #358; `git merge-tree` showed the conflict, and no merge was started.

**Merges (merge-only, nothing pushed):**
- `4fb372e8` Sync: merge #354 (`8f2504c2`, 17 commits). No conflicts. app/ only relative to this
  branch: the core/ changes were already here through the #358 syncs, so no `build_core.sh` was needed.
  It touched our hook files (WorkspacePlaceholder, MetalMeshView, LatticeSettings, ProjectModel) with
  no conflicts. The hook suites are green.
- `02c307f4` Merge batch S (`claude/flexible-screens-r5s`, 7 commits to `8feed6aa`). There were
  conflicts in our own files only, and each one kept both sides:
  - FlexibleSquishPlayer: M's picker condition, S's colour(n) dot, S's keep-out backgrounds.
  - FlexibleMainStatusPill: M's playAllLive / noteFor and S's colour closure.
  - FlexibleMainStage: M's FE heat channels, then S's frames.
  - FlexibleMainStage+Views: M's per-group composition, then S's frames after it.
  - This handoff: every section kept.
  - Every line either side added to the five main-page files is in the result (checked line by line).
- #361 `claude/flexible-squish-maths` and `main` were already contained.
- **No new hook in a #354/main file.** The only source lines this pass added are in Flexible files:
  a test control in FlexibleMainStage, the frames-per-turn paint and its key in
  FlexibleMainStage+Views, and `dotColour` in FlexibleSquishPlayer.

**Tests:** targeted suite (all Flexible* + the hook-adjacent suites + #354's new suites). The final run
(after the fixes): `Executed 708 tests, with 19 tests skipped and 1 failure (0 unexpected) in 3990.545 seconds` — the one failure is the known `LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds`. The first run, before the fixes: 706 tests, 19 skipped, 5 failing tests
(the known `LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds`, plus the four above).
`FlexibleFEFieldTests.testExtensionOutsideTheSolid` (which could not run in batch S's sparse worktree)
passes here. iOS: `xcodebuild … -derivedDataPath …/DerivedData/flexA1 build` → ** BUILD SUCCEEDED **
after the fixes (FlexibleSquishPlayer.o newer than its source).

**Seen in the renders, older than the merge:**
- A curve point's white depth pill renders with faint text in the hosted panel (batch S's own render
  shows the same).
- On macOS the player's picker label renders without its dot (an AppKit pop-up). On iOS the label is
  the HStack.

**Commits:** 645f0973 (M verification's DECISIONS), 4fb372e8 (sync #354), 02c307f4 (merge S),
ef1c1fc5 (frames per turn, the player's dot, the two re-pins), 2f047278 (the in-pass controls), and
the next commit (this section, D-R5-X1/X2, evidence).

## Round 5 · batch M — your round-5 notes on the main page and the dent visuals

Your seven notes on img 4–6 (taken on the build before batch G), and "this and the graded dent colours
should be in both views". Judged on YOUR project as you left it for round 5 (`his_project_0004_r5`:
Group 1 = Top A's elbow + Top B + Face 5's 10 kg thumb, Group 2 = Face 3's four fingertips), restored
through `AppModel.open`, and on C1's pad with a four-fingertip stamp on its top. The pictures below are
offscreen frames of the shipping renderer — the app was built for the simulator but NOT launched, so
none of this has been seen on a screen yet.

**What you will see:**
- **The dent colours are the FEA rainbow, on both pages** (M7): blue → cyan → green → yellow → red, the
  original FEA legend's own five colours. The map, every legend that shows it, and the Stress view use
  the same rainbow (the two are never on together). This replaces the deep blue → cyan → white of
  2026-09-30, as you asked.
- **The colours are graded, with no blocks and no hard cut** (M5), on both pages:
  - each corner of the map takes its own value and the screen blends between them;
  - a tap reads the number at that exact spot, so the number is the colour under your finger.
- **On the main page the colours are the 3D sim's own squish** (M5, M2):
  - they spread out of each stamp and the fingertips merge into one press (your Face 3: the ground
    0–3 mm outside the fingertips reads 95 % of under them; core's own numbers there read 37 %);
  - your Top A elbow is a soft cyan spot fading into the blue top, not a hard-edged disc.
- **On the Settings page a stamp spreads out too** (M2): the four fingertips grade out and merge into one
  press (between them: 88 % of the deepest squish; before: 13 %), still sinking the full depth under each.
- **Pick Group 1 or Group 2: you see only that group, pressing in** (M1). Its own field, its own faces
  moving INTO the part; "Play all" plays Group 1, then Group 2, and names the one playing.
- **Stress works on your pad, per group** (M3):
  - it shows the stress of the group you picked (or the one playing), from that group's own sim;
  - on the part and, with the lattice on, on its walls; tap for MPa;
  - the legend reads "Stress · Group 2 · MPa".
  - If a sim fails it says why in one line ("Couldn't simulate: it took too long") with Retry.
- **The dent view is X-ray, and the planes are solid** (M6):
  - turning on the dent view makes the part a ghost even with the lattice off;
  - with the lattice on, the walls are a faint ghost too, and the dent planes bend through them;
  - **the stripes are gone** (they were the lattice walls' cut faces at the part's surface poking
    through the plane).
- **One legend card** (M4), like the octet's key: the Squish (or Stress) row and the lattice-density row
  in one card on the right edge, clear of every button. Tap it to read; the caret folds it to a column
  of bars.

**What was wrong, and why:**
- **M1 "group 1 showed group 2's animation … group 2 as a negative":** on your round-5 build (the
  column squish, before G) the squish was per column and the groups shared walls. On G's field I found
  no swapped or inverted group: every group picked binds its own field (renderer, mesh, player name),
  and its pressed faces move in (Group 1: Top B 0.13, Top A 0.66, Face 5 1.83 mm at ×1; Group 2: Face 3
  12.69 mm). Tests now hold this per group, with red controls (the index swapped, the sign flipped).
- **M3 "Couldn't simulate":** your 'Top' group presses region 105 "Union of 2" (top A + top B). A
  union keeps its members as *parts*, and the region spec handed to core has no parts
  (`FaceRegion.kitSpec`), so core got region 105 with no faces and refused the whole solve: "face
  region 105 resolves to NO faces on this model". That is #354's region mapping (outside this track),
  and the Optimize run may hit it too — I did not change it. The Stress view no longer goes through that
  solve when a lattice exists.
- **M6 the stripes:** the lattice runs to the surface (Finish "None"), and its walls were drawn solid with
  depth. Where a wall's cut face met the dent plane (lifted 0.05 mm), it won, in rows. On your pad: 4.3 %
  of the top map's interior from above, 28.7 % from the iso view. Now: 0.

**Not done (and why):**
- **Nothing has been seen on a device or in the simulator** (track rule: never launch). The iOS build
  succeeds.
- **On Face 5 the sim squishes the top edge most, not the middle of the thumb.**
  - Under each stamp the colours read close to what you set: the thumb 11.4 mm on average (you set
    13.5), Top A's elbow 4.8 mm (4.0), Face 3's fingertips 25.8 mm (24.5).
  - But Face 5's top edge, just above the thumb, reads 23.7 mm — the most on that face.
  - That is Group 1's 3D sim (it presses the top and Face 5 together, and finds the part 7× stiffer than
    core's columns — G's (i) already said so). I did not change G's physics; core brief #24 / #35.
- **On the Settings page, steep stamp walls still show a slight saw-tooth** at the column pitch
  (1.56 mm at Fast): two flat triangles per column cannot draw a steep curved wall perfectly. The colour
  itself is continuous.
- **The Settings page's own legend bar** is still 24 small blocks (FlexibleStagePage is batch S's
  page); the main page's card uses smooth gradients.
- **Core still designs a stamp under the stamp alone** (core brief #33): the spread is in the
  Settings page's picture and in the 3D sim, not in core's density.
- **The solid-part Stress route without a lattice** still fails on your project (the union region,
  above).

**Your call:**
- **Group 1's colours:** show the sim's own squish (now — Face 5's top edge reads 23.7 mm, more than the
  13.5 you set), or cap the colours at the deepest you set (the edge would read 13.5, like the thumb's
  middle)?
- **The spread on the Settings page:** L = 0.2 × the lattice depth (4 mm on your top, 20 mm on your
  100 mm-deep sides), fitted to the sim of your pad. Wider or narrower?
- **Stress with the lattice on:** the walls take the stress colours and the density row stays in the
  card (a tap on a wall gives both). Or drop the density row while Stress is on?
- **Your union region 105:** should the stage's region spec carry union parts (a #354 change), so the
  Optimize run and the solid Stress solve see your 'Top' group's faces?

### Each note → what changed (file) → pinned by
| # | His note | What changed | Pinned by (RED control) |
|---|---|---|---|
| M1 | group 1 showed group 2's animation; group 2 "as a negative" | nothing in production (G's field binds per group); tests per group | FlexibleBatchMGroupTests (the other group's mesh; the flipped sign; the column fallback flipped) |
| M2 | stamps are isolated; foci should merge into one input | the Settings page's stamp dent spreads (`FlexibleStampSpread`, `stampDent`); the main page's heat is the sim's own squish | FlexibleBatchMDentTests (the footprint alone; core's per-column numbers) |
| M3 | Stress can't simulate; should be the playing / selected group | Stress = each group's own sim (`FlexibleFEStress`, `FlexibleMainStage+Stress`, the bridge's `element_e`, the walls' w channel); one-line failure + Retry on the kept request | FlexibleBatchMStressTests (the calibrated u; the other group's field; the request released) |
| M4 | one legend, like the other lattice sections | ONE card (`FlexibleMainLegends.card`, `legendCard`, `cardTapped`, the wall probe reading the plane first) | FlexibleBatchMLegendTests (batch C's per-kind frames; the probe's wall reading) |
| M5 | dent colours not graded, a hard cut | per-vertex colours (`FlexibleOverlayMesh.quadCorners` / `mapCornerValues`, `tints(vertexColour:)`), a tap reads the blend (`FlexibleProbe.dentReading`) | FlexibleBatchMDentTests, FlexibleMainViewsTests (one colour per column) |
| M6 | dent view → X-ray, the lattice a ghost, no stripes, solid | `xray = latticeShown ∥ dentXray`, `ghostWalls`, `flx_ghost_walls`, two MetalMeshView hooks | FlexibleBatchMXrayTests (C2's rule; the opaque walls: 4.3 % / 28.7 % of the map) |
| M7 | dent colours = the original FEA legend, both views | `FlexibleColours.depthStops` = ResultsModel.stressColor's stops, the Stress view reads the same | FlexibleShownValuesTests (the old deep blue → white ramp) |

### Hook lines in #354 / main files (this batch; each grepped after the edit)
| hook | file · anchor | ± | why |
|---|---|---|---|
| HM1 | MetalMeshView.swift · `if wantsLattice, let lpipe = latticeShadePipeline, let gb = gbuffer {` → `if wantsLattice, !flexibleWallsGhosted, let lpipe = latticeShadePipeline, let gb = gbuffer {   // Flexible (#362) batch M: …` | +1 −1 | #354's opaque lattice shade stands down while the dent view ghosts the Flexible walls (`MeshRenderer+FlexibleLattice.flexibleWallsGhosted`, false whenever the Flexible pass is not drawing — the octet's frame is byte-for-byte #354's) |
| HM2 | MetalMeshView.swift · after that block: `if wantsLattice, flexibleWallsGhosted, let gb = gbuffer { encodeFlexibleGhostWalls(enc, gbuffer: gb, mainSize: mainSize) }   // …` | +1 | the walls drawn as a ghost from the G-buffer the prepass already filled, before the ghost body and the solid map |

Nothing else outside the track: WorkspacePlaceholder, LatticeSettings, ProjectModel, ResultsModel,
FaceRegion and LatticeStageMode are untouched, no case was added, core/ is untouched (the bridge is
the app's), the pinned strings are untouched. Batch S's modal views (FlexibleSettingsPanel,
FlexibleFacePanel, FlexibleFaceList / FaceRows, FlexibleSqueezeGroupRows) and FlexibleStagePage are
untouched; the Settings page changed only through shared code (FlexiblePageChannels, FlexibleOverlay,
FlexibleShownValues, FlexibleProbe, FlexibleStampSpread). **Merge note for S:** FlexiblePageChannels
(`channels`) holds the group colours S owns AND batch M's per-vertex heat — keep both.

New files: `FlexibleStampSpread`, `FlexibleFEStress`, `FlexibleMainStage+Stress`; tests
`FlexibleBatchMDentTests`, `FlexibleBatchMGroupTests`, `FlexibleBatchMStressTests`,
`FlexibleBatchMXrayTests`, `FlexibleBatchMLegendTests`, and the opt-in `FlexibleBatchMProbe`.

### The numbers (his round-5 project unless said)
- **M5 continuity** (the largest colour step where two quads share a corner): Settings page, Face 3:
  0.0000 over 908 shared corners (one colour per column: 0.43); main page, Group 2 Face 3: 0.0000
  (core's per-column colours: 1.25), Group 1 Top A: 0.0000 (0.21). A tap off a column's centre reads the
  blend: 23 of 23 taps equal the colour's value; all 23 differ from the column's own number.
- **M2 spread** (Settings page): L = 0.2 × lattice depth — his top (20 mm) 4.0 mm, his sides (100 mm)
  20.0 mm. Between Face 3's fingertips: 88 % of the deepest (the footprint alone: 13 %); the largest step
  between neighbouring columns 14 % of the deepest (the footprint: 27 %). The fit to the 3D sim (the sink
  0–2 / 2–4 / 4–8 mm outside each stamp, over under it; `FlexibleBatchMProbe.testFEStampSpreadProfile`):
  share 0.1 / 0.15 / 0.2 / 0.25 / 0.3 → Top A rms 0.20 / 0.14 / 0.13 / 0.14 / 0.17, Face 5 0.10 / 0.03 /
  0.05 / 0.07 / 0.09, Face 3 0.16 / 0.11 / 0.08 / 0.06 / 0.04 — 0.2 is the best single share for the
  three (Top A's ring also carries Top B's own press).
- **M2/M5 main page** (the sim's squish, mm at the calibrated size; `FlexibleBatchMProbe.testFEHeatPerFace`):
  Group 1 — Face 5 under the thumb 11.35 (146 columns; you set 13.5), max 23.72 at its top edge (u 49.2,
  v 19.5), mean 8.05; Top A under the elbow 4.77 (644 columns; you set 4.0), max 5.65; Top B max 3.01
  (3.0). Group 2 — Face 3 under the fingertips 25.80 (235 columns; you set 24.5), max 27.29, mean 23.88. The ring 0–3 mm outside the stamp over under it:
  Face 3 95 % (core's columns 37 %), Top A 57 % (31 %). × the ASKED k instead: Face 5 87.65 mm.
- **M1:** at ×1 (full load, as cut), each group's own faces move in — Group 1: Top B 0.128, Top A 0.658,
  Face 5 1.826 mm (Group 2's field there: −0.683, −0.864, 0.000); Group 2: Face 3 12.691 mm (Group 1's
  field: 0.000). Play all's turns: group-1, group-2, group-1, group-2 (the bound field = the one named).
- **M3:** von Mises on known strains — uniaxial 0.015385 MPa (E ε / (1 + ν) = 0.015385), shear 0.013323
  (√3 μ γ = 0.013323); a field × 3 reads the same. His pad: Group 1 peak 0.7990 MPa, Group 2 0.0575 MPa;
  the part's colours are its own group's at 12 919 of 12 919 sampled vertices (the other group's: 26 and
  2); a tap reads 0.0139 / 0.0214 MPa (the other group's there: 0.0214 / 0.0139). A forced failure
  (1 ns budget): "Couldn't simulate: it took too long", core's words behind the (i); Retry re-runs it with
  the lattice's generation unchanged (control, the request dropped: the lattice rebuilds).
- **M6:** the map's interior (2 px in from its outline) — top view 126 174 px, iso 65 624 px; pixels where
  the walls show through: 0 and 0 (the old opaque walls: 5 439 = 4.3 % and 18 859 = 28.7 %).
- **M7:** the dent ramp's hue runs 6° … 226° (the FEA rainbow); the prism's nearest ramp colour is
  0.431 RGB away.

### Core brief (batch M; #1–#32 stand)
- **#33 A stamp's press spreads, and its foci are one press.** design_stamp designs the density under
  the stamp alone (weight ÷ footprint elsewhere). The 3D sim of his pad drags the face round a stamp over
  ~0.2 × the layer's depth, and close fingertips merge. Core should design for that press (one force over
  the merged foci), so the lattice matches what the Settings page draws and the main page plays.
- **#34 Stress from the squish solve.** The app computes von Mises from the linear field (secant moduli,
  ν = 0.3, small strain) and node-averages it. Core should return element stresses (and, with #20, the
  large-strain ones), and say how far the linear numbers are from the real TPU.
- **#35 Where the 3D sim and core's columns disagree past the band** (his Group 1: k asked 7.4), the heat
  now shows the sim's squish: under the thumb 11.4 mm (13.5 set), but Face 5's top edge above it 23.7 mm.
  Core should own that reconciliation (#24, now visible in colour).
- **Found, NOT core (#354's app mapping):** `FaceRegion.kitSpec` carries no union `parts`, so a load or
  anchor on a union region reaches core with no faces — his 'Top' group (region 105) made the solid Stress
  solve refuse ("face region 105 resolves to NO faces"); the Optimize run builds its regions the same way.

### Tests (every comparison with a RED control, computed beside it)
NEW (TopOptFlowsTests):
- `FlexibleBatchMDentTests` (2): the Settings page's heat graded (RED one colour per column) and the
  fingertips merged (RED the footprint alone), a tap reads the blend (RED the column's number); the main
  page's heat is the sim's on every column, graded (RED core's per-column colours) and spread (RED core's
  island).
- `FlexibleBatchMGroupTests` (1): each group binds its own field, H4 hands its mesh, its faces move in
  (RED the other group's field; the sign flipped); the column fallback too; Play all names each turn.
- `FlexibleBatchMStressTests` (4): the formula on known strains (RED the calibrated u); WHY his solid
  solve failed (the union region); Stress follows the picker on the body and the walls (RED the other
  group's field); a failure in one line + Retry without a rebuild (RED the request released), and the
  Stress button spins only while Stress is on (RED the sims' own state).
- `FlexibleBatchMXrayTests` (2): the dent view is X-ray and ghosts the walls (RED C2's rule) + the two
  hook lines; the solid plane never striped (RED the opaque walls).
- `FlexibleBatchMLegendTests` (2): one card clear of every button at 13" / 11", both orientations, open
  and folded, chip column or not (RED batch C's two frames); a tap reads what is under the finger (RED a
  wall is there to be read).
- Opt-in `FlexibleBatchMProbe`: the WHY, the before / after frames, the spread fit, the heat per face.

RE-PINNED, each with its reason in the test:
- `FlexibleShownValuesTests`: `testTheDentRampIsItsOwnAndNeverPurple` → `testTheDentRampIsTheFEARainbowOnBothPagesAndNeverPurple`;
  `testWhatIsDrawnOnThePartIsNotTheMapsGreen` → `testWhatIsDrawnOnThePartIsNotTheMapsColour` (renamed, not
  deleted: the rule they pinned is overturned by his M7).
- `FlexibleMainViewsTests`: the dent and Stress share one rainbow; a dent tap reads the blend under it;
  the stage's Stress tap — Stress takes the map from the dent, and with a lattice reads the group's sim.

Mutation runs (each breaks one rule in a mirror of the package, rebuilds, runs its pinning test; the file
restored after): all 15 RED (`m/mut/mut_run.log` in the session scratchpad):
```
MM1  the dent ramp back to deep blue → cyan → white      ⇒ testTheDentRampIsTheFEARainbow… (45 failures)
MM2  the Settings page's heat one colour per column       ⇒ testTheSettingsPageHeat… (2)
MM3  no spread: the footprint alone                       ⇒ testTheSettingsPageHeat… (2)
MM4  the main page's heat back to core's columns          ⇒ testTheMainPageHeat… (5)
MM5  a tap reads the column's number                      ⇒ testTheSettingsPageHeat… (23)
MM6  stress from the calibrated u (k not taken out)       ⇒ testVonMisesOfKnownStrains… (1)
MM7  Stress does not follow the picker                    ⇒ testStressIsTheShownGroupsOwnSim… (2)
MM8  the request released after a failure                 ⇒ testAFailedSimSaysWhy… (1)
MM9  C2's X-ray rule                                      ⇒ testTheDentViewTurnsXRayOn… (2)
MM10 the walls opaque under the dent view                 ⇒ testTheSolidDentPlaneIsNeverStriped… (2)
MM11 a legend per scale (batch C)                         ⇒ testOneCardHoldsTheActiveScales… (32)
MM12 the card reads the ghost wall behind the plane       ⇒ testTheCardReadsWhatIsUnderTheFinger (1)
MM13 H4 hands the other group's mesh (index swapped)      ⇒ FlexibleBatchMGroupTests (9)
MM14 the field's mesh sign flipped                        ⇒ FlexibleBatchMGroupTests (8)
MM15 the walls never take the stress colours              ⇒ testStressIsTheShownGroupsOwnSim… (2)
```
Deleted-test sweep (`git diff 33edeb15 -- app/TopOptKit/Tests`, removed `func test` lines): the two
renames above, nothing deleted.

### Evidence (`docs/handoffs/evidence/2026-09-29-flexible-screens/batch_m/`)
Offscreen frames of the shipping renderer (what FlexibleMainStage / the Settings page hand
MetalMeshView, settled like the page, at full load), contact sheets:
- `M_main_dent_before_after.png` — his round-5 pad, the dent view: BEFORE (this branch before batch M:
  the deep-blue ramp, the hard-edged disc on Top A, the wall tops striping the map, four flat grey-blue
  discs for the fingertips) and AFTER (each group at full load: the rainbow graded out of each stamp, the
  four fingertips one press, the ghost body and ghost walls, the solid bent planes; the dent view with
  the lattice off).
- `M_main_stress_per_group.png` — Stress per group, with and without the lattice (walls in the stress
  colours).
- `M_fingertip_pad_settings_main_stress.png` — C1's pad with a four-fingertip stamp on its top: the
  Settings page (the four foci graded and merged), the main page (the sim's squish), Stress; and his
  project's Settings page.
- `M_stripes_ghost_vs_opaque.png` — the ghost walls under the solid plane vs the old opaque walls, and his
  img-6 view (back-left) on the column squish he saw.
- `M_one_legend_card.png` — the ONE card (Squish + Lattice; Stress · Group 2 + Lattice), rendered by
  SwiftUI's ImageRenderer at an iPad 13" page with the Gravity chip column.
Re-render: `FLEX_M_PROBE_DIR=<dir> swift test --filter FlexibleBatchMProbe` (FLEX_M_TAG names the set).

### Build and suite (raw lines, this Mac)
- Targeted suite (G's 171-suite filter + every Flexible* class, LatticeRegionCapTests,
  LatticeShellAndMarchAgreeTests, SmoothingViewerTests, LatticeOvernightBatchTests, LatticePageTests,
  LatticeSimRegionLayerTests, ResultsModelTests — 188 names; Debug; other sessions' suites ran on the same
  Mac): `Executed 1293 tests, with 26 tests skipped and 10 failures (0 unexpected) in 3454.617 (3454.740) seconds`.
  - 8 are the known AppModelTests 3MF lines (testReopenedThreeMFProjectReimportsTheStlWorkingCopy ×2,
    testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance ×4, testThreeMFImportOptimisesOnDeviceEndToEnd ×2),
    1 is the known `LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds`.
  - The 10th was mine: `FlexibleMainPageRound4Tests.testTheLatticeButtonOpensSettingsWhenNothingCanShowAndExitShowsIt`
    expected the solid part (alpha 1) with the lattice hidden — M6 keeps the X-ray while the dent view
    shows a map. Re-pinned (the dent view: X-ray; dent off: solid).
- Re-run after that re-pin and the Stress button's spinner rule (the suites they touch or that read the
  stress state: FlexibleMainPageRound4Tests, FlexibleBatchMStressTests, FlexibleMainViewsTests,
  FlexibleBatchCVerifyTests, FlexibleMainStageTests, FlexibleSquishPlayerTests, FlexibleStageTests + the
  heat probe): `Executed 70 tests, with 0 failures (0 unexpected) in 413.025 (413.033) seconds`.
- iOS (Debug, the simulator 147E56A1…, DerivedData flexA1): `** BUILD SUCCEEDED **`. `TopOpt.debug.dylib`
  stamped 23:19 holds `flx_ghost_walls` and "Couldn't simulate: it took too long". Not installed, not
  launched.

### Decisions (00-decisions.md)
- New rows D-R5-M1 … M7 (the FEA rainbow on both pages; the heat per vertex; the main page's heat = the
  sim's own squish; the stamp's spread; Stress per group; the dent view's X-ray with ghost walls; one
  legend card). D-R5-G4 amended (in FE mode the heat, legend and tap-to-read are the sim's).

### Commits (PR #362's branch `claude/flexible-screens`; nothing pushed)
- `69389996` the dent heat on BOTH pages — the FEA rainbow, graded per vertex, a stamp that spreads
  (M7, M5, M2; shared code the Settings page already calls).
- `bfe66d6b` the main page — the sim's own squish as the heat, each group's own Stress, the dent view's
  X-ray with ghost walls, one legend card (M1–M6, M4) and the two MetalMeshView hooks.
- `bdaa0111` a smooth cap on the stamp's spread; smooth legend bars.
- The next commit: the Stress button's spinner only while Stress is on, the M6 re-pin of a C2 test, the
  opt-in probe, the evidence sheets, this section and DECISIONS D-R5-M1…M7.

## Round 5 · batch S — verification pass

A verifier read batch S against your words and found 21 things (2 lenses: correctness and your UX rules). I checked each one on the code and on your project 0004 before changing anything. **20 were confirmed; 1 was confirmed only in part** (the weight range). Every fix has a test with a red control, and each fix was put back and its test run: **16 mutations, all RED**. **The app was NOT launched: nothing here has been seen on a device or simulator.**

**What changes for you on the Settings page:**
- **A number box no longer changes when you only touch it.** Before, a 3 pt wobble on a box rounded its value to the step grid, so 98.07 N became 100 N, 22.05 lb became 22 lb and 7.3 kg became 7.5 kg. A weight was then written back to the main page's Load group. Now:
  - the value stays put until your finger has moved it half a step;
  - a drag that ends within half a step changes nothing;
  - a drag starts only after 8 pt (was 3) of mostly up/down movement, and those 8 pt are not counted;
  - a sideways wobble is never a drag.
- **A weight typed outside the main page's own limits (0.1–500 kg) is set to the limit, and one line says so:** "Kept within 0.1–500 kg". Before, 50 g was dropped without a word. "0 kg does nothing · kept 10 kg" when you type 0. A weight under 1 shows two decimals ("0.25 kg", not "0.3").
- **Tapping a group's own colour again (or picking another and then the original) leaves the button on "Exit".** Before, it read "Save & Exit" with nothing visibly changed.
- **Every group keeps its colour when an earlier group is removed**, including groups made before round 5 that never had a colour picked. Before, only picked colours survived a renumber.
- **[+ New]: tap the face on the part and the group is made** (the tab says "Tap the face that starts it"). Before, the tap only selected the face and left the tab. The rows are one per hand: "Top A + Top B → Group 2". Before, there were two rows, and each moved both faces.
- **The stamp's size is two boxes, Width [65.5 mm] and Length [20 mm]**. Either one keeps the stamp's proportions. Before, one row read "Width · 20 mm long [66 mm]", and the box rounded your 65.5 mm to 66.
- **When the column preview stands in for the 3D sim, one line above the player says why:**
  - "Column preview · Save & Exit for the 3D sim" (you edited since the last Save & Exit);
  - "Column preview · no lattice built yet";
  - "Column preview · 3D sim running";
  - "Column preview · the 3D sim failed".
  Nothing is said while you drag. Before, the fold and bulge changed to the column dent with no word.
- **The player ends on the playing group's force in your unit** ("10 kg", "22 lb"), the number in its Squeeze box. Before, your Group 1 (Top A 5 kg + Top B 5 kg of Top's 10 kg, faces 3 and 5 at 10 kg) read "Full load".
- **"Was 7 kg · now Top's weight" follows your unit** ("Was 15.4 lb …").
- **A curve's end point near the group picker is drawn again.** Only the picker (with its note) and the capsule are kept clear of the curves, not the empty rest of the picker's row. On your Face 3 at 11" landscape the Y curve's end now peeks out under the picker's lower-left corner, and its lower half takes a drag. Before, it was not drawn at all (`S_11l_group2_keypad.png`, before and after). The player does not yet move out of a point's way.
- **"Groups share material: the firmer one wins" shows only on a group's tab**, not under [Rests]. The group tab's (i) now describes the folder tab and the Squeeze box. It used to mention "the pill beside the group", which is gone.
- **Exit with nothing changed is counted from the moment the page appears.** An edit on the [Model] tab while the part is still opening now counts as a change. Before, it read "nothing changed yet" and Exit skipped saving it. The open's own re-read of the main page's loads is still not counted as your change.

**Each finding → verdict → what changed:**

| # | finding | verdict | what changed |
|---|---|---|---|
| C1 (major) | a touch on a number box rounds an off-grid value and writes a weight back to the main page | CONFIRMED (98.0665 N → 100 N on −3 pt; 7.3 kg → 7.5 kg) | scrub relative to its start (half-step dead zone), 8 pt slop not counted, vertical start only; `FlexNumberScrub.shown(raw:spec:)`, `startsScrub` |
| C2 | weight range 0.1–500 kgf drops a lighter weight silently, clamps a heavier one | PARTLY: the range IS the main page's own (`ForceModel.minWeightKg / maxWeightKg`; its `setWeight` clamps to them, so a Load group can never hold > 500 kgf). The silent drop and the rounding of small weights were real | the constants named; a positive value under the floor takes the floor; refused / clamped values SAID in one line (`typedNote` → the page's toast); < 1 shows two decimals |
| C3 | an edit while the part opens counts as "nothing changed" | CONFIRMED | snapshot at onAppear; at `.ready` the open's own adopt is applied to it (`FlexibleStageModel.openedSnapshot`), never re-taken |
| C4 | the S9 evidence test passes with the S9 fix removed | CONFIRMED (with a current lattice the Save & Exit path changes nothing visible) | new `testExitWithNothingChangedLeavesTheViewOffAndNothingDeferred`: view off and opened by the view button. Without the fix, Save & Exit's path turns the view on, so the test goes RED (V13). The failed-build test is the other S9 evidence. The review UI test's two counters, bumped on one condition, became one honest check |
| C5 | a group with no stored colour changes colour on a renumber | CONFIRMED (green/orange/red → [1,2] green, [3] orange) | `normalise` carries the colour each group was SHOWN in (pick, or its old number's default), then stores it in normal form |
| C6 / U2 | [+ New]: a tap on the part leaves the tab and makes nothing; two rows for one hand | CONFIRMED | `tapFace` on [+ New] calls `startGroup(with:)` for a candidate; `newGroupHands` = one row per hand ("Top A + Top B → Group 2") |
| C7 / U12 | stale (i) ("the pill beside the group"); "Width · 95 mm long"; `stampSizeRow` unused; the share note under [Rests] | CONFIRMED | `Info.groups` rewritten; Width and Length rows (`stampSizeRow`, `stampLengthRow`); the share note on group tabs only |
| C8 | "Reset == fresh" builds fresh with Reset's own constructor; "as New TopOpt preselects" unsupported (batch F not here) | CONFIRMED | the test's fresh project now starts at the APP's entry (`FlexibleStageSettings()`, WorkspacePlaceholder) and takes the page's own actions (the D-R5-S5 filament, his unit); the claim is reworded in the source and here |
| U1 (major) | after any edit the 3D fold drops to the column dent with no line | CONFIRMED | the four column-preview lines above. Re-running the sim on the Settings page is **your call** (below): the sim needs the lattice built on Save & Exit, and the Settings page never builds one (D-R4-6) |
| U3 (major) | "Width · 20 mm long [66 mm]"; a stored 65.5 mm shows 66 | CONFIRMED | two boxes (Width, Length), proportions kept (`FlexibleStampSize`); one decimal when the value has one |
| U4 | re-picking a swatch reads "Save & Exit" | CONFIRMED | colours in normal form (`FlexibleSqueezeGroups.canonical`) |
| U5 | view off: Save & Exit leaves the lattice stale, so the main page's 3D squish falls back to the column model | CONFIRMED | no code change. The consequence is now part of your call 3 below. The main-page pill is in batch M's file |
| U6 | > 4 groups reuse colours; orange / red are the warning / danger tokens | CONFIRMED | not changed: the DS has only these four tokens besides purple (the depth prism), cyan (resting) and white (selected) — **your call** below |
| U7 | on the main page's column fallback a side wall's opaque frame pokes through the top face | CONFIRMED (verifier's render) | NOT fixed. The geometry is older than S: the column model pushes a side face's top columns through the top face, and its heat-coloured columns already poked through the same way. The opaque frame makes it visible. A fix means the column model must know when a displaced column crosses another face. That belongs to the main page's dent work (batch M), so it is left as an open issue |
| U8 | relinked line in kg; Settings player "Full load" | CONFIRMED | `relinked(…, unit:)`; `FlexibleSettingsSquish.fullLabel` = the playing group's force (`squeezeValue(_:unit:)`) |
| U9 | the deepest box scrubs up = more, the depth chip down = deeper; 3 pt slop | slop CONFIRMED and fixed (8 pt, vertical start). Direction NOT changed | the box is a value dial, and up = more on every box on the page (the iOS convention). The chip is a handle ON the part that follows the dent plane into it. Flipping one box would make it the only one that runs backwards |
| U10 | a curve end point hides under the group picker (11" landscape) | CONFIRMED; PARTLY fixed | the player reports its drawn parts (`playerTopRow`, `playerCapsule`); `FlexibleStagePage.stageKeepOut` keeps out only those. On his Face 3 at 11" landscape the end point is drawn again, but it sits at the picker's corner and only its lower half is clear. Making the player dodge projected points is not done |
| U11 | Reset drops the faces he added here; the fresh card opens on "Can't reach your curve" | CONFIRMED | your call below. The warning comes from round 4's default dome (it misses columns on your top) and is older than this pass |
| U13 | FlexibleSquishPlayer.swift and FlexibleRowCopy.swift are also edited in the lead's tree | CONFIRMED (verifier read the lead's diff) | merge notes below |

**Your call (updated):**
1. Deleting a face a main-page group holds leaves that group unchanged, so the main run still presses it. Should deleting top A here also take it out of the main page's Top group?
2. Reset all keeps your weight unit. Should it go back to kg?
3. **Save & Exit with the Lattice view off** only stores ("View off · tap to build"). **Consequence:** with no new bake, the lattice stays stale. Every 3D sim needs a current lattice, so until you turn the view on, the main page's Heat and Stress squish is the old column preview, with no bulge. Round 4 built it anyway. Which do you want?
4. The frame is ~3 % of the face (3 mm on your 100 mm pad) plus a 1.6 mm dark gap. Thicker or thinner?
5. **NEW: after an edit on the Settings page, the 3D sim waits for Save & Exit.** It needs the lattice built on Exit. Should the Settings page re-run the playing group's sim on the last-built lattice once your edits settle (an approximation: the old lattice, the new loads)? If not, the "Column preview · Save & Exit for the 3D sim" line stays.
6. **NEW: Reset all** starts from the main page's faces only, so faces you added on this page are dropped. Should it keep every listed face, with its values reset?
7. **NEW: groups 5 and up re-use the four colours, and orange and red are also the warning and danger colours.** Accept four, or add a second cue for groups 5+ (e.g. the group number on the frame)?

**Merge notes for the lead (with batch M):**
- `FlexibleSquishPlayer.swift`:
  - S changed the picker's dot to `colour(n)`;
  - this pass adds two `FlexibleKeepOutKey` preference backgrounds: the top row's and the capsule's drawn frames;
  - the lead's tree changes the picker condition to `(playingGroup ?? shown)?.kind`.
  Keep all three.
- `FlexibleRowCopy.swift`: the lead's tree changes `stampMainPage` to "Main page: the 3D sim presses the stamp". Keep the lead's string. S's cards still show it under the stamp rows.
- The five main-page hook files listed under batch S below are not touched by this pass.

**Hook lines in this pass:** none in a #354 / main file. The pass only READS `ForceModel.minWeightKg / maxWeightKg`; `ForceModel.swift` is unchanged. No case was added to LatticeStageMode. Flexible track files only:
- FlexibleNumberBox;
- FlexibleSettingsRail;
- FlexibleGroupColours;
- FlexibleSqueezeGroups;
- FlexibleStageModel(+Groups);
- FlexibleSettingsReset;
- FlexibleSettingsSquish;
- FlexibleStagePage;
- FlexibleSquishPlayer;
- FlexibleFaceStamp;
- FlexibleFacePanel;
- FlexibleFaceList;
- FlexibleSqueezeGroupRows;
- FlexibleRowCopy.

**Tests:**
- NEW `FlexibleRound5SettingsVerifyTests` (9). Each test states its red control inline:
  - nudges commit nothing at 6 values × 4 nudges (control: round 5's absolute snap rewrote 24 of 24);
  - clamped and said;
  - colours in normal form and carried as shown;
  - an edit while opening counts, and the open's adopt does not;
  - a tap on the part starts the group, with one row per hand;
  - Width and Length;
  - the player's column lines and group force;
  - the keep-out is the player's drawn parts;
  - the share note on group tabs only.
- NEW hosted `FlexibleRound5SettingsVerifyHostedTests` (1): the page itself appears while the part is still opening. An edit then reads "Save & Exit"; the open's own re-read reads "Exit" (FLEX-R5V-HOSTED: "the open changed the settings true · title 'Exit'" / "… title 'Save & Exit'").
- NEW in `FlexibleRound5SquishExitTests`: `testExitWithNothingChangedLeavesTheViewOffAndNothingDeferred`. The column-preview line is also checked in both S2 tests.
- RE-PINNED, each with its reason in the test:
  - `FlexibleRound5SettingsTests.testANewGroupTakesAFreeColour…`: no entry for a number's own colour; it keeps orange when group 1 goes;
  - `…testResetAllIsABrandNewSetupOfThisPartAndUndoable`: fresh from the app's entry;
  - `FlexibleRowCopyTests`: the Width and Length rows, the hand row, the column lines and the unit-aware relinked line;
  - `FlexibleSqueezeGroupsReviewUITests`: one check instead of two counters on one condition.

Mutations (`scratchpad/s5v/mut/summary.txt`), each rebuilt and run on its pinning test:
```
V1  round 5's absolute snap (no half-step dead zone) ........ RED (24) testANudgeNeverRewritesAnOffGridValue
V2  a typed weight under the floor is dropped ............... RED (2)  testATypedWeightOutsideTheMainPagesLimitsIsClampedAndSaid
V3  every colour pick stored (no normal form) ............... RED (5)  testColoursAreStoredInNormalFormAndCarriedAsShown
V4  a renumber carries only STORED colours .................. RED (2)  same
V5  the S9 snapshot re-taken at .ready (model) .............. RED (1)  testAnEditWhileThePartOpensCountsAndTheOpensOwnReadDoesNot
V16 the page re-takes the S9 snapshot at .ready (wiring) .... RED (1)  hosted testThePageCountsAnEditMadeWhileThePartOpens
V6  a tap on the part on [+ New] only selects ............... RED (4)  testATapOnThePartStartsTheNewGroupAndTheRowsAreHands
V7  [+ New] lists one row per face .......................... RED (2)  same
V8  the stamp box shows whole mm only ....................... RED (1)  testTheStampsWidthAndLengthAreTwoBoxesThatKeepItsProportions
V9  no line for the column preview .......................... RED (3)  testThePlayerSays… + SquishExit testOnlyTheSelectedFacesGroup…
V10 the player ends on the faces' own weights ............... RED (3)  testThePlayerSaysWhyTheColumnPreviewPlaysAndEndsOnTheGroupsForce
V14 the relinked line in kg whatever the unit ............... RED (1)  same
V11 the whole player kept out of the curves ................. RED (1)  testTheCurvesKeepOutIsThePlayersDrawnPartsNotItsWholeWidth
V12 "Groups share material" under every tab ................. RED (1)  testTheSharedMaterialNoteIsOnlyOnAGroupsTab
V13 S9a: Exit (nothing changed) runs Save & Exit's path ...... RED (1)  testExitWithNothingChangedLeavesTheViewOffAndNothingDeferred
V15 round 5's 3 pt slop ..................................... RED (1)  testANudgeNeverRewritesAnOffGridValue
```

Build and suite (raw lines, this Mac, side worktree `wt-r5s`):
```
Targeted suite (every Flexible* suite + UnifiedShading, LatticePreviewBodyAlpha, LatticeGBufferMask, LatticeThreeAlgorithmsDraw,
OrganicCapsuleImpostor, Viewer, StageBackdrop, SmoothingPageRound2, LatticeStageMode, LatticeSettingsPersist, ProjectStore,
UndoHistory, SurfaceStage, LatticeSimSolveTrigger), FLEX_S_EVIDENCE_DIR set, load average up to 227 (other agents):
Executed 529 tests, with 11 tests skipped and 3 failures (1 unexpected) in 1375.400 (1375.474) seconds
  LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds — known, pre-existing
  FlexibleFEFieldTests.testExtensionOutsideTheSolid — "cannot open STL file: …/wt-r5s/evidence/2026-07-30-lattice-skin-freeform/…":
    this side worktree is SPARSE (.git/worktrees/wt-r5s/info/sparse-checkout excludes that evidence folder; set outside this
    task, as batch S reported) — run it in the lead's worktree
  FlexibleMainPageLoadsTests.testThePadCommitsOnceWhenItCloses — MINE: its source pin read the literal
    "if !open, let v = buffer.closed(spec)"; re-pinned to the close's body (one buffer.closed, one onCommit, only as it closes);
    rerun: Executed 10 tests, with 0 failures (0 unexpected) in 3.312 (3.314) seconds
Affected suites first (FlexibleRound5Settings, Round5SquishExit, SqueezeGroups, SqueezeGroupsReview, SqueezeGroupsModel,
  LegendPlacement, MainPageHook, SettingsRound4): Executed 62 tests, with 0 failures (0 unexpected) in 124.606 (124.613) seconds
FlexibleRound5SettingsVerifyTests: Executed 9 tests, with 0 failures (0 unexpected) in 3.577 (3.579) seconds
FLEX-R5V opening (edit false): the open's adopt changed the settings = true · modified = false
FLEX-R5V opening (edit true): the open's adopt changed the settings = true · modified = true
FLEX-R5V new tab: candidates [1000103, 1000104, 3, 5] · rows [["Top A", "Top B"], ["Face 3"], ["Face 5"]]
FLEX-R5V colours: same swatch / back / swap-and-back all equal · unstored group 3 → 2 keeps red (stored ["2": "red"])
FLEX-R5V player: group 1 faces ["Top A 5.0 kg", "Top B 5.0 kg", "Face 3 10.0 kg", "Face 5 10.0 kg"] · force 10.0...10.0 · label '10 kg'
FLEX-R5V S9 exit, view off: latticeOn false · deferred false · showOnExit false
FLEX-R5V-HOSTED opening: edit while opening false: the open changed the settings true · title 'Exit'
                          edit while opening true: the open changed the settings true · title 'Save & Exit'
iOS: xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration Debug -destination id=147E56A1-C8CA-4B9D-BE6C-CF230589A83A
  -derivedDataPath …/DerivedData/flexA1s build → ** BUILD SUCCEEDED ** (FlexibleNumberBox.o newer than its source; the log compiles
  wt-r5s/…/FlexibleSettingsSquish.swift). The app was not launched.
Evidence: the hosted page re-shot at 4 sizes (scratchpad/s5v/ev/S_<size>_*.png): the player reads "● Group 2 ▾  Column preview ·
  no lattice built yet" and ends on "10 kg"; Face 3's Y-curve end is drawn at the picker's corner (crop: scratchpad/s5v/crop_picker.png;
  batch S's: crop_picker_before.png, not drawn).
```

**Commits (on `claude/flexible-screens-r5s`; nothing pushed):** 0ae23c45 (the fixes and their tests, with FlexibleRowCopyTests' re-pin, which it needs to compile) · 0d6c1808 (re-pins) · 3ddad0ea (the box's source pin) · this section with D-R5-SV1..SV6.

## Round 5 · batch S — the Settings page: folder tabs, group colours, number boxes, units, Reset all, every face deletable, Exit vs Save & Exit

(The verification pass above corrects this section where they differ.)

Your words (img 1–3), with your clarifications:
- "The different groups should have different coloured faces on the model body, assigned in the settings modal." — "This should be in the settings page too".
- "Each different group should have different animations; depending on which face is selected, that's the group that gets animated … not as a combo." — "No this is for the setting page".
- "All number inputs should show a textbox with a number … numerical input OR draggable up/down."
- "Allow for a change of weight input: kg/lb/newtons/etc."
- "Create a "reset all" button to reset all inputs and start anew."
- "For some reason, top A/B are not deletable. All faces should be deletable."
- "When a face has been deleted, it comes back with the previous values. It should come back with reset values."
- "The groups should be separate folders … The folder tabs should be on the *left* side of the modal."
- "If there are *any* modifications, it should say "Save & Exit" … Otherwise, it should say "Exit" and no changes should occur on the main screen."

Judged on YOUR project 0004, restored through `AppModel.open`; the Settings page was hosted offscreen at 11" and 13", portrait and landscape, and clicked; the model was rendered offscreen by the shipping renderer. Built on a side branch (`claude/flexible-screens-r5s`) while batch M changed the main page. **The app was NOT launched: nothing here has been seen on a device or simulator.**

**What you will see on the Settings page:**
- **Folder tabs down the LEFT of the modal** (S8).
  - Top to bottom: **[Model]**, one tab per squeeze group (its colour, "Group 2", "1 face"), **[Rests]**, **[+ New]**.
  - The rail scrolls, so any number of groups fits. Six groups were measured on 11" landscape: every tab stays inside the panel.
  - Beside the rail is the open tab.
  - A group's tab shows its name (with × and (i)), then **Squeeze [10 | kg ▾]**, then **Colour ● ● ● ●**, then its faces. Tap a face to open its values in place, as before.
  - **[Model]** holds the filament, Feel and Finish, then the More rows (nozzle, lattice, Auto, physics).
  - A face you tap on the model opens its own group's tab, even from [Model].
  - A face you press on a group's tab joins THAT group.
  - [+ New] lists one row per hand that can start a new group ("Top A + Top B → Group 3": a main-page group's faces move together). A tap on a row, or on the face on the part, makes the group and opens its tab (verification pass).
  - The panel is 480 pt wide (400 before): the tab beside the rail keeps round 4's 372 pt, so every row still fits. It still hugs its rows and still folds to its header.
- **Each group has its own colour** (S1).
  - You pick it on the group's tab. The four colours are green, orange, red and blue, all DS tokens and never purple.
  - Picking a colour another group wears swaps the two, so each group keeps its own.
  - A new group takes the first free colour. A group keeps its colour when an earlier group goes and it is renumbered — any group, picked or not (verification pass; before it, only a picked colour survived).
  - Blue is last because the dent heat is deep blue → cyan → white, and a blue frame sinks into it.
  - **On the model, each pressed face is FRAMED in its group's colour.** The pressed face's body IS its heat map, so the heat keeps the inside:
    - a band of the face's outermost columns (≈ 3 % of its longer side; at most an eighth of its shorter side) in the group colour;
    - then one column of the stage's near-black between the frame and the heat (only on faces at least 16 columns across).
  - The frame is opaque, never the X-ray ghost, and moves with the dent. A split sector is framed along its cut.
  - It is on both pages, in every view: the main page paints it after the Stress / Heat / X-ray composition.
  - The list dots, the rail, the open card's dot and the player's picker wear the same colour.
- **The selected face's group squishes, ALONE** (S2).
  - The player shows which group plays ("● Group 2 ▾"). A pick selects that group's first face.
  - The other groups' maps keep their colours and stand still. It is never the firmer-wins combination.
  - After a Save & Exit with nothing changed since (the lattice is current), the page plays that group's OWN 3D sim (batch G's field for its load alone, on an overlay cut to the sim's grid, ×k capped as on the main page). The note reads "3D sim · as last saved".
  - Once you edit anything, the lattice is behind, so it plays the instant column dent of that group's faces. That includes every curve drag.
- **Every number is a box** (S3). Each box shows the number and its unit, with a hairline and a small ⇕.
  - A tap opens the numeric keypad. The value commits once, when the keypad closes.
  - An up / down drag scrubs the value: slow is fine, fast is coarse. It snaps to the field's step, is clamped to its range, and commits once, on release.
  - The boxes are:
    - a group's squeeze;
    - the deepest squish (0.5 mm steps, up to the lattice);
    - the stamp's width and its length, two boxes (1 mm steps; either keeps the stamp's proportions — verification pass);
    - the stamp's turn (15° steps, wrapping round; replaces the quarter-turn button);
    - **a curve point's squish in mm** (while a point shows its ×).
  - The pencil buttons are gone. A row whose number is in its box no longer repeats it ("Deepest squish [3 mm]").
- **Weights in kg, lb, N or kN** (S4). Tap the unit in the squeeze box.
  - Every weight on the page follows the unit: the rows, the "How much weight presses here?" keypad, the fix pop-up's keypad and the player's end label.
  - Storage stays kgf. 22 lb typed writes exactly 9.97903214 kgf to the main page's Top group, which reads back as 22.000000000000 lb.
  - The unit is saved with the project. It never makes the lattice stale.
- **[Reset all]** is in the modal's header (S5).
  - It asks in one line: "Reset every setting here? [Reset] [Cancel]".
  - Reset gives a brand-new Flexible setup of this part with the default filament (D-R5-S5 rules it: the app's own entry, `FlexibleStageSettings()`, has no filament on this branch):
    - the filament with squish data (varioShore TPU), Springy, Covered, Auto;
    - the main page's Load and Anchor groups read again as faces at their weights (on your pad: Top A pressed, 10 kg, and Face 0 resting);
    - one group, and nothing deleted.
  - One undo brings it all back. The weight unit is kept.
- **Every face has the trash** (S6): top A and top B (split sectors; top A is the main page's Top), Face 0 (the bottom anchor) and every face you pressed yourself.
  - Deleting takes the face out of the Flexible setup. The main page's group is NOT changed: the main run still presses it.
  - The face is remembered as deleted, so the re-sync never brings it back.
  - Pressing it again brings it back as a new face.
- **A deleted face comes back with defaults** (S7).
  - Everything it held goes with it: its curves, stamp, shape, squeeze group (and the group's colour if it was the last face), deepest squish, weight and link.
  - The page's copies of core's answers for it go too: the drawn map, the design, its words, the pinch halves, the relinked weight and a curve point's ×.
  - Added back, a face has the default dome, 3 mm, Curves and group 1, and the main page's weight if a group presses it.
- **"Exit" until something changes; "Save & Exit" after** (S9).
  - The comparison is by value: undo back to how the page opened and it reads "Exit" again. A colour or unit pick is a change.
  - Blocked AND changed, it reads "Fix 1 thing". With nothing changed, Exit always leaves, since leaving changes nothing.
  - The top line names the button: "Ready · nothing changed yet" / "Ready: Save & Exit builds the lattice".
  - **Exit** saves nothing and the main page does nothing:
    - no rebuild (a failed build is not retried);
    - no new sim;
    - the squish keeps playing;
    - the picture's generation does not move (measured).
  - **Save & Exit** saves. With the main page's Lattice view ON it bakes the lattice and runs the sims, as before. With the view OFF it only STORES: the pill reads "View off · tap to build", a tap (or the Lattice button) turns the view on, and the bake runs then.
  - Kept: when Settings was opened by the Lattice view button because nothing was set up, Save & Exit turns the view on.

**Deviations (each with its reason):**
1. **Frames, not whole faces, carry the group colour.** The pressed face's body is replaced by its heat map (the overlay), so a whole-face tint would hide the heat. The frame plus a near-black gap is the one mark no heat ramp draws: blue → cyan → white today, and a rainbow if batch M switches to it.
2. **On the Settings page the 3D field plays only while the lattice is current** (no edit since the last Save & Exit). The field belongs to the lattice built on Exit; the Settings page never builds one (D-R4-6). Any edit → the column preview of the selected group at once, and (verification pass) one line above the player says so: "Column preview · Save & Exit for the 3D sim".
3. **[Rests] and [+ New] are tabs, and [Model] also holds the More rows.** The rail replaces the Face | More chips.
4. **The rail tab has two tiny lines** (name, face count), as asked ("its colour, its name, its face count"). Every setting row is one line.
5. **With nothing changed, Exit is never blocked** (a legacy project's missing filament included): leaving changes nothing on the main page.
6. **A group with more than 4 groups re-uses the colours** (four distinct DS tokens exist that are not purple, cyan or white).

**Not done (and why):**
- **Nothing has been seen on a device or simulator.** I must not launch the app. The iOS build succeeds.
- **The box's drag inside the scrolling panel**: a vertical drag that starts on a box scrubs it and does not scroll the panel (by design). Whether that feels right needs a device.
- **Batch M's files**: the main page's dent colours, legends and Stress are M's. S touched five main-page files with small listed hooks (below) — the lead merges them with M's.

**Your call:**
- **Deleting a face a main-page group holds leaves the main page's group as it is**, so the main run still presses it. Should deleting top A on the Flexible page also take it out of the main page's Top group?
- **Reset all keeps your weight unit.** Should it go back to kg too?
- **Save & Exit with the Lattice view off** stores and waits for the view ("View off · tap to build"). Round 4 built it anyway and said "Lattice ready [Show]". Which do you want? (The verification pass adds the consequence: until the view is on, the main page's squish is the column preview, with no bulge.)
- **Frame width** is ~3 % of the face (3 mm on your 100 mm pad), plus a 1.6 mm dark gap. Thicker / thinner?

**What it does on YOUR pad (measured, his project 0004 restored):**
- **The frames** (his img 4's split: Face 3 in Group 2):
  - Top A and Top B (64 × 32 columns each): a 2-column green frame and a 1-column dark gap. That is 540 of 2 048 columns; the 1 508 inside keep their heat, untouched.
  - Face 5 (Group 1) and Face 3 (Group 2, orange), 64 × 13 columns each: a 1-column frame and no gap (150 of 832 columns).
- **The playing group, column preview:**
  - Top A selected: Top A, Top B and Face 5 dent (2.07 / 2.99 / 2.96 mm); Face 3 stands still (0.00).
  - Face 3 selected: only Face 3 dents (2.96 mm).
  - Round 4's page dented all four at once.
- **The playing group, 3D:** with the lattice built and both sims landed, Top A plays Group 1's own field and Face 3 plays Group 2's. The two fields differ by up to 0.98 mm.
- **Exit with nothing changed, on C1's pad under the main stage** (verification pass: these numbers do NOT go red without the fix — with a current lattice Save & Exit's path changes nothing visible; the tests that do are "does not retry a failed build" and "leaves the view off and nothing deferred"):
  - lattice generation 1 → 1;
  - picture generation 5 → 5;
  - still playing;
  - saves 1 → 1;
  - a latched failed build stays latched (Save & Exit retries it).
- **Save & Exit with the view off:** the lattice stays stale and the pill reads "View off · tap to build". Turning the view on bakes it.
- **Six groups fit the rail** (11" landscape): Model, Group 1–6, Rests and New, with the rail inside the panel. The first four groups wear four different colours.

### Evidence (offscreen; not device screenshots)
- The page, hosted and clicked, at 11"/13" in portrait and landscape (`scratchpad/s5/final_ev/S_<size>_*.png`):
  - `opened` (the rail, Exit);
  - `group2_keypad` (the deepest box being edited);
  - `group1_topA_trash` (top A's card with the trash);
  - `save_and_exit`;
  - `reset_confirm`;
  - `model_tab`;
  - `S_11l_six_groups`.
- The model, by the shipping renderer:
  - `S_settings_group1_topA_{before,after}_{iso,top}.png` and `S_settings_group2_face3_{before,after}_{iso,top}.png` (before = round 4: no frames, every group dents; after = frames, the selected group alone);
  - `S_settings_picked_red_blue_iso.png`;
  - `S_main_{xray_heat,solid_heat,solid_noheat}_iso.png` (the main page after Save & Exit: the frames in every view).

### Hook lines (no #354 / main file: WorkspacePlaceholder, MetalMeshView, LatticeSettings, ProjectModel, ForceModel, LatticeStageMode untouched; no case added)
Five MAIN-PAGE Flexible files that batch M is also editing got small hooks. The lead merges them.

| file | anchor | +/− | why |
|---|---|---|---|
| FlexibleMainStage.swift | `@Published public var latticeOn = true { didSet {` | +1 −1 | S9: the view turned on bakes what a view-off Save & Exit stored (`bakeDeferred`) |
| FlexibleMainStage.swift | `didExitSettings`, after `model?.pendingFix = nil` | +2 | S9: Exit with nothing changed returns at once (`takeExitUnchanged`) |
| FlexibleMainStage.swift | `didExitSettings`, after `if showLatticeOnExit {…}` | +2 | S9: `latticeBuildDeferred = !latticeOn` |
| FlexibleMainStage.swift | `buildIfReady`'s guard, after `m.lattice == nil \|\| m.latticeIsStale,` | +1 | S9: no bake while deferred and the view is off |
| FlexibleMainStage.swift | `refresh()`, after `var c = FlexiblePageChannels.channels(` | +1 | S1: the frames in the base tints (the picture's key follows a colour pick) |
| FlexibleMainStage.swift | `fullLabel`'s `shapeOnly: m.lattice?.shapeOnly == true` | +1 −1 | S4: the player's end label in his unit |
| FlexibleMainStage.swift | `FlexibleMainStatus.ready` | +2 | S9: `deferred = "View off · tap to build"` |
| FlexibleMainStage.swift | `FlexibleMainStatus.of(model:)`, after the `.failed` line | +3 | S9: the deferred pill |
| FlexibleMainStage+Views.swift | `tints(…)`, after `FlexibleMainTints.compose(` | +1 | S1: the frames painted after the composition — every view (Stress, no heat, X-ray) |
| FlexibleMainLatticeView.swift | `pillTapped`, after `self.goToLattice = goToLattice` | +1 | S9: a tap on the deferred pill turns the view on |
| FlexibleMainStatusPill.swift | `FlexibleMainPlayerSlot`'s `note: note)` | +2 −1 | S1: the player's picker dot in his chosen colour |
| FlexiblePageChannels.swift | the region tint `FlexibleSqueezeGroups.colour(number: g.number)` | +1 −1 | S1: a pressed face with no map yet in his chosen colour |

**Every other change is in a Flexible track file.**
- New files:
  - `FlexibleSettingsRail.swift` +493;
  - `FlexibleNumberBox.swift` +233;
  - `FlexibleGroupColours.swift` +189;
  - `FlexibleSettingsSquish.swift` +113;
  - `FlexibleWeightUnit.swift` +109;
  - `FlexibleSettingsReset.swift` +109.
- Edited files (+/−):
  - FlexibleFacePanel +63 −52;
  - FlexibleSettingsPanel +68 −12;
  - FlexibleStagePage +67 −11;
  - FlexibleStageModel +57 −14;
  - FlexibleRowCopy +46 −11;
  - FlexibleSettings +29;
  - FlexibleFaceList +23 −10;
  - FlexibleSqueezeGroupRows +11 −37;
  - FlexibleFaceStamp +10 −12;
  - FlexibleSqueezeGroups +9 −4;
  - FlexibleSquishPlayer +8 −4;
  - FlexibleStageModel+Groups +8;
  - FlexibleFixPopup +5 −4;
  - FlexibleReadiness +1 −1.

### Decisions (00-decisions.md)
New rows D-R5-S1 … D-R5-S9 (each names what it overrides):
- D-R4-2's Face | More chips;
- D-R4-12's pencil pill;
- the D2 headers in one list;
- D-R3's "no trash for a face a group holds";
- D-R3-11's single "Exit";
- C2's build with the view off;
- D-R5-G1's "the Settings page is unchanged";
- D2's palette order.

### Core brief
Nothing new: S is app-only.

### Tests
Every new test states its RED control inline. Each fix was also mutated back and its pinning test run: **all 26 mutations went RED** (`scratchpad/s5/mut/summary.txt`, table below).

NEW:
- `FlexibleRound5SettingsTests` (12; his project + pure):
  - the box's scrub, clamp and wrap;
  - the keypad's commit;
  - units round-trip and the exact kgf to the main page;
  - colours chosen, swapped and carried;
  - a new group's colour, and a pick that leaves the lattice current;
  - the frames on every pressed face;
  - every face deletable and staying deleted;
  - a deleted face back with defaults;
  - Reset all == a fresh setup, undoable;
  - the rail follows the selection;
  - Exit / Save & Exit.
- `FlexibleRound5SquishExitTests` (5):
  - the selected group alone (columns);
  - its own 3D field;
  - Exit leaves the main page alone;
  - Exit does not retry a failed build (control: Save & Exit does);
  - Save & Exit with the view off only stores (control: the view on bakes).
- `FlexibleRound5SettingsHostedTests` (3, hosted and clicked at 4 sizes):
  - the rail, boxes, trash, titles and Reset;
  - Exit leaves without saving, and undo back reads "Exit";
  - six groups fit.
- `FlexibleRound5EvidenceProbe` (opt-in renders).

RE-PINNED, each with its reason in the test:
- `FlexibleMainPageHookTests`: the exit button reads FlexibleSettingsExit.
- `FlexibleMainPageLoadsTests`:
  - `testTheTrashIsRefusedForAFaceAGroupHolds` → **renamed** `testTheTrashDeletesAFaceAGroupHoldsAndTheReSyncLeavesItDeleted` (superseded by S6; its control is kept);
  - the pad count (the pencils went).
- `FlexibleSqueezeGroupsTests`: the default palette order.
- `FlexibleSqueezeGroupsUITests` / `FlexibleSqueezeGroupsReviewUITests`: the open folder tab's header instead of D2's list headers; the slot hands over the colours.
- `FlexibleRowCopyTests` / `FlexibleSettingsVerifyD1Tests` / `FlexibleSettingsPageHostedTests`: the row width is `FlexibleSettingsPanel.contentWidth` (round 4's 372 pt, kept beside the rail).

Mutations (each rebuilt and run on its pinning test; `scratchpad/s5/mut/summary.txt`) — all 26 RED:
```
S6a round 4's trash refused for a main-page face .......... RED (7) testEveryFaceIsDeletableAndStaysDeleted
S6b the re-sync brings a deleted main-page face back ....... RED (2) testEveryFaceIsDeletableAndStaysDeleted
S6c the card's trash inert where round 4 had none .......... RED (8) hosted testTheRailTheBoxesTheTrashAndTheExitOnHisProject
S7a the per-face copies survive a delete ................... RED (2) testADeletedFaceComesBackWithDefaults
S7b a deleted face hidden, not purged (keeps its values) ... RED (7) testADeletedFaceComesBackWithDefaults
S5a Reset keeps the faces (no main-page re-read) ........... RED (3) testResetAllIsABrandNewSetupOfThisPartAndUndoable
S5b Reset folded into the edits before it (undo lost) ...... RED (1) same
S1a a renumber does not carry the colours .................. RED (1) testGroupColoursAreChosenSwappedAndCarriedWithTheirGroup
S1b a new group stores no colour ........................... RED (1) testANewGroupTakesAFreeColourAndAPickLeavesTheLatticeCurrent
S1c a colour pick re-runs the pipeline ..................... RED (1) same
S1d no frames painted ...................................... RED (1380) testEveryPressedFaceIsFramedInItsGroupsColour
S1e a colour pick does not swap ............................ RED (2) testGroupColoursAreChosen…
S3a the scrub runs the wrong way ........................... RED (5) testTheNumberBoxScrubsBySteppingClampsAndWraps
S3b the scrub never clamps ................................. RED (3) same
S3c the keypad commits a 0 below the range ................. RED (1) testTheKeypadCommitsOnceInRange
S4a a rounded pound (0.4536 kg) ............................ RED (3) the two unit tests
S4b a unit change makes the lattice stale .................. RED (1) testAWeightTypedInPounds…
S2a round 4: every group's faces dent ...................... RED (4) testOnlyTheSelectedFacesGroupSquishesOnTheSettingsPage
S2b Group 1's field whatever is selected ................... RED (2) testTheSelectedGroupsOwnSimMovesTheSettingsPage
S9a Exit (nothing changed) runs Save & Exit's path ......... RED (1) testExitWithNothingChangedDoesNotRetryAFailedBuild
S9b Save & Exit bakes with the Lattice view off ............ RED (3) testSaveAndExitWithTheLatticeViewOffOnlyStores
S9c the title ignores whether anything changed ............. RED (5) testExitSays… + hosted testExitLeavesWithoutSaving…
S9d the page snapshots nothing (always "modified") ......... RED (3) hosted testExitLeavesWithoutSaving…
S8a the rail does not follow a moved face .................. RED (2) testTheRailFollowsTheSelectedFace…
S8b a tab picked on the rail selects nothing ............... RED (2) same
S8c a face pressed on a group's tab joins group 1 .......... RED (1) same
```

### Build and suite (raw lines, this Mac; the side worktree `wt-r5s`)
```
Targeted suite (every Flexible* suite + UnifiedShading, LatticePreviewBodyAlpha, LatticeGBufferMask, LatticeThreeAlgorithmsDraw,
OrganicCapsuleImpostor, Viewer, StageBackdrop, SmoothingPageRound2, LatticeStageMode, LatticeSettingsPersist, ProjectStore,
UndoHistory, SurfaceStage, LatticeSimSolveTrigger), FLEX_S_EVIDENCE_DIR set:
Executed 518 tests, with 11 tests skipped and 8 failures (1 unexpected) in 1565.826 (1565.888) seconds
  LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds — known, pre-existing
  FlexibleFEFieldTests.testExtensionOutsideTheSolid — "cannot open STL file: …/wt-r5s/evidence/2026-07-30-lattice-skin-freeform/
    cylinder_r9_h28.stl": this side worktree was made SPARSE at 19:07:56, mid-run (.git/worktrees/wt-r5s/info/sparse-checkout
    excludes that evidence folder), not by me; the same test PASSED in this batch's first full run (12.764 s) before it
  FlexibleSqueezeGroupsReviewUITests.testTheGroupHeadersAreWholeAndOnThePanel, FlexibleSqueezeGroupsUITests.
    testNewGroupAndRemoveGroupByClickingThePage — "the pop-up opens" timed out at 60 s under a load average of 40–56 (other
    agents); rerun alone: Executed 2 tests, with 0 failures (0 unexpected) in 107.985 s; the wait raised to 180 s, rerun under
    load average 56: Executed 2 tests, with 0 failures (0 unexpected) in 102.885 s
First full run (before the re-pins): Executed 517 tests, with 11 tests skipped and 12 failures — the 8 re-pinned tests above + the
  known LatticeSimSolveTrigger; the re-pinned suites rerun: Executed 64 tests, with 1 test skipped and 0 failures (0 unexpected) in 321.145 s
FLEX-R5 units: Top written 9.9790321400 kgf for 22 lb · read back 22.000000000000 lb
FLEX-R5 reset: ["0:resting:10.0", "1000103:loaded:10.0"] · material varioshore_tpu · fresh ["0:resting:10.0", "1000103:loaded:10.0"]
FLEX-R5 frames: Top A (Group 1) 64×32 columns · frame 368 · gap 172 · heat 1508 (kept 1508) | Top B the same |
  Face 5 (Group 1) 64×13 · frame 150 · gap 0 · heat 682 (kept 682) | Face 3 (Group 2) the same
FLEX-R5 S2 column: Top A selected: Face 3 0.00 · Face 5 2.96 · Top A 2.07 · Top B 2.99 | round 4: Face 3 2.96 · Face 5 2.96 · Top A 2.07 · Top B 2.99
  Face 3 selected: Face 3 2.96 · Face 5 0.00 · Top A 0.00 · Top B 0.00
FLEX-R5 S2 FE: k 1.00 / 1.00 · the two groups' fields differ by up to 0.979 mm
FLEX-R5 S9 exit: lattice gen 1 → 1 · picture gen 5 → 5 · playing true → true · saves 1 → 1
FLEX-R5-HOSTED (all four sizes): panel x 24–504 · rail x 38–110 · tab x 118–490 · 5 tabs · titles Exit → Save & Exit
FLEX-R5-HOSTED six groups: rail (38, 205, 72 × 591) in panel (24, 143, 480 × 667) · Model, Group 1–6, Rests, New
iOS: xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration Debug -destination id=147E56A1-C8CA-4B9D-BE6C-CF230589A83A
  -derivedDataPath …/DerivedData/flexA1s build → ** BUILD SUCCEEDED ** (FlexibleSettingsRail.o etc. rebuilt from wt-r5s). The app was not launched.
```

### Commits (on `claude/flexible-screens-r5s`; the lead merges into PR #362's branch; nothing pushed)
- bb044c11 — the feature (sources + four new suites).
- 160a8589 — the re-pins.
- "A1 round 5 batch S: handoff section …" — this section, D-R5-S1..S9, the two hosted waits raised to 180 s.

## Round 5 · batch G — verification pass

The G verifier reported 13 findings: 5 majors and 8 minors, from a correctness lens and a UX lens.
Two of the majors are one bug seen from both sides (the first refresh after Save & Exit). I checked
each one myself, on YOUR project 0004 as you left it for round 5 (copied from the simulator's store,
saved 2026-09-30 16:52 — now `his_project_0004_r5` in the evidence folder), on the committed 0004
and on C1's pad. I fixed every major and every minor except the stamp's COLOURS (V5's second half
and V10, below). The app was built for the simulator but NOT launched, so none of this has been
seen on a screen yet.

Your round-5 notes that touch G's field were checked here too:
- (a) "When in group 1, it showed group 2's animation … group 2 as a negative": picking a group
  already played only its own field under G. What was still a combo was **"Play all"** (the
  default): every group's heat colours stayed on while one group's field played, and nothing said
  which group was playing. Fixed below. **Group 2 alone** also pulled Face 5 in (a two-sided pinch).
  Fixed below.
- (b) "the stamps are seen as isolated areas … it should … pull lattice next to it in": under G's
  field the SHAPE already drags its neighbours. On your Top A thumb, the part 0–3 mm outside the
  stamp sinks 58 % as far as under it; core's per-column numbers there are 30 %. A test now pins
  this. The COLOURS are still core's per-column depths, so the colour still reads as an island (not
  done, below).

**What changes for you on the main Flexible page:**
- **Save & Exit shows the lattice at rest until its 3D sim lands.** Batch G flashed the OLD column
  squish (its plugs, seams and flaps) for about 1–2 s first, then snapped to rest. Now "Simulating
  the squish…" shows from the first frame with the new lattice.
- **"Play all" plays each group ALONE.**
  - Each turn colours only that group's faces. The colours come in with the group's field and mesh
    at the rest point, so nothing pops. All groups keep ONE colour scale (the legend's).
  - The picker says which group is playing: "● All · Group 2", in that group's colour.
  - The note beside it is that group's own line (its firmer-wins miss, or nothing).
- **A group on its own no longer squeezes from both sides.** When a pressed face's far end is
  neither pressed nor resting in that group, that far end is now held (like a wall): it is where
  core designs the columns to be squeezed against.
  - On your pad, Group 2 (Face 3 alone) now leaves Face 5 still: 0.000 mm. Batch G moved Face 5 in
    by 49 % of Face 3's motion (4.25 mm on screen).
  - Your Group 1's 10 kg thumb on Face 5 now squeezes the pad against Face 3. Before, it sheared
    the pad over its gripped bottom.
- **No picture folds at ×1 any more.** The page never draws below ×1. So a field whose calibrated
  size would fold the part at ×1 is cut until it cannot (s · gmax ≤ ½ in the part, the rule batch G
  already used for ×k above 1).
  - Your Group 1 was 4.4× past that limit. The walls' pull-back missed by up to 9.2 mm near the
    thumb (a lattice sliver through the heat plane), and Top B rose 7.8 mm. Now it is cut to 23 %:
    the pull-back misses nowhere (0 of 53 248 cells). Your Group 2 is cut to 53 %; the M2 stand to
    60 %; your saved pad and C1's pad are not cut.
  - The Squish legend's (i) says it, in one sentence, with the band's k too: "…a linear 3D sim that
    finds this part 7× stiffer than core's columns (its skin and walls carry load), cut to 23 % so
    the picture never folds (the sim leaves small strain here)…". Batch G's (i) said only "the
    picture can fold" there, and hid that Face 5 moved about ⅓ of what it read.
- **If a sim fails, the squish still plays.**
  - With one group, a failed sim now plays the column squish. Batch G left it at rest, next to
    "Simple squish · the sim failed".
  - Under "Play all", a failed group is said: "Group 2 skipped · its sim failed". Pick it to play
    its simple squish.
  - If EVERY sim of "Play all" failed, the first group's simple squish plays and the picker shows
    that group. Batch G squished every group's faces at once there.
- **A pick of a group whose sim is still solving plays as soon as it lands.** Batch G sat at rest
  until you pressed play.
- **The stamp lines are true again.** The dent legend reads "Squish · mm" while the 3D sim plays
  (the sim presses the stamp where it sits). "Squish · stamp: whole face" is only for the column
  fallback now. The Settings stamp row reads "Main page: the 3D sim presses the stamp" (it said
  "whole face sinks, for now").

**Also fixed (you will not see these):**
- **Never two solves in core, as ONE claim.** Two solves in core's matrix-free pool deadlock (batch
  G found it).
  - The verifier put a squish sim inside core beside a running Stress solve, two ways. The gate was
    checked a step before the sim entered core. And the Stress model's Cancel drops its phase
    while its solve keeps running.
  - Now a sim claims core in the same step that commits it. The Stress / octet solve
    (`LatticeSimModel`) and a LOCAL topology run hold core for as long as they are really in it,
    a cancelled solve included. A solve that waits goes before the next queued sim.
- **A remote run no longer waits for the sims.** A LAN run never touches this device's pool.
- **A local run that waited for a sim gets its full stall-watchdog grace.** The watchdog is
  re-armed after the wait. Batch G counted up to 60 s of waiting against the 150 s grace, then
  entered core anyway.

**Not done (and why):**
- **Nothing has been seen on a device or in the simulator** (track rule: never launch). The iOS
  build succeeds.
- **The stamp's COLOURS are still core's per-column depths**, in 1.56 mm blocks. Where core has no
  number (Face 5's thumb: 149 of 149 columns; the pad's fingertips: 235 of 237), the spot is the
  near-white "no number" grey. Smoothing the colour, or colouring those spots by the sim, changes
  what the colours mean. That is the dent visuals (batch M) and core's "can't reach" columns.
- **Top B still rises a little under Group 1.** 445 of its 2 048 columns move out, at most 1.8 mm at
  ×1 (7.8 mm before the cut). This is the linear sim's physics: the 10 kg thumb on Face 5 lifts the
  top next to it, and Top B's own press is 1 kg-ish. It is not flagged on screen.
- **The octet's and Organic's own solves are still not gated** (core brief #18); the claim covers
  the app's own callers.
- **The "Play all" legend's ends stay the whole lattice's** (0–28.7 mm on your pad). Each turn's
  colours use that one scale, so they are comparable across groups; the ends do not change per turn.

**Your call:**
- **The fold cut.** Your Group 1 now moves 23 % of its calibrated size (≈ 7 % of core's numbers on
  Face 5). The alternative is to let ×k go below 1 and say "×0.2" on the legend. Keep the cut?
- **The far end held as a wall** (a side press squeezes against the opposite face, as core's columns
  assume). Or should an unpressed far face stay free, with the part balanced as batch G did?
- **Top B lifting next to the thumb** (above): leave it (it is what a linear body does), or say it
  in a line?
- **"Play all" stays the default** with two or more groups, now playing each group alone. Or make
  Group 1 the default and keep "Play all" as a choice (D2's default)?

### Each finding, confirmed on the code → what changed
| # | Finding (lens · severity) | Verdict | Fix (file) | Pinned by |
|---|---|---|---|---|
| V1 | a failed sim sits at rest when it is the only / first sim (correct · major) | CONFIRMED (VG-E: "failure true · playing false") | the sims are started BEFORE they are read, a request not yet scheduled is pending; the fallback auto-plays once per (generation, sequence asked) (`FlexibleMainStage+Squish.feView`, `FlexibleMainStage.refresh`) | FlexibleSquishVerifyGTests · testAFailedOnlySimPlaysTheColumnSquish (RED: batch G's order + loop) |
| V2 | the gate can be bypassed, two ways (correct · major) | CONFIRMED (VG-H, VG-I: a sim in core beside the Stress solve) | `FlexibleCoreGate`: one lock; `tryEnterSim` in pump(), `whileInCore` (LatticeSimModel, HV1), `claimForRun` (RunModel, HV2); waiting solves go first | FlexibleCoreClaimTests (RED: `controlLateClaim` + `controlOthersDoNotClaim` = batch G's gate) |
| V3 | a pick of a solving sim stays at rest when it lands (correct · minor) | CONFIRMED (VG-G) | the loop starts by (generation, sequence asked) and restarts when the shown sequence comes out of "Simulating…" | testAPickOfASolvingSimPlaysWhenItLands (RED: `controlLoopByGeneration`) |
| V4 | the column fallback's Play all is the combo; a failed group skipped silently (correct · minor) | CONFIRMED (VG-D: 4 faces) | every sim of Play all failed ⇒ the first group's column squish (`fallbackSim`, the picker shows it); "Group 2 skipped · its sim failed" | testEveryFailedSimOfPlayAllPlaysOneGroup (RED: `controlPlayAllCombo`) |
| V5 | stamp drag untested; colours still an island (correct · minor) | shape CONFIRMED OK and now pinned; colours NOT done (batch M) | — | FlexibleFEVerifyGTests · (c) (RED: core's per-column squish, 30 %) |
| V6 | HG1 delays remote runs, eats the watchdog's grace, enters after 60 s (correct · minor) | CONFIRMED (code) | remote claims nothing; a local run claims without a timeout; the watchdog is re-armed after a wait (HV2) | testALocalRunClaimsCoreAndARemoteRunDoesNot (RED: no claim) |
| V7 | Play all reads as a combo (ux · major) | CONFIRMED (probe: colours [3, 5, A, B] in both turns; label "All") | per-group tints (`playAllBaseTints`, `FlexibleFETints`) swapped by the renderer with the field and mesh; `loop.playingSimID` published per turn to the player; the picker "All · Group 2"; the playing group's note | testPlayAllPlaysEachGroupAlone (RED: `controlPlayAllCombo`) |
| V8 | Save & Exit flashes the old column squish (ux · major) | CONFIRMED (the same cause as V1) | as V1 | testSaveAndExitHoldsTheLatticeAtRestUntilItsFieldLands — caught at the source, inside the refresh (RED: batch G's order) |
| V9 | Group 1 4.4× past the fold limit at ×1 (ux · major) | CONFIRMED (pull-back misses 665 cells, worst 9.25 mm) | the fold cut (`FlexibleFEField.calibrated`, `foldShare`, k · gmax(part) ≤ ½); the far anvil (V11) | FlexibleFEVerifyGTests · (b) (RED: uncapped) |
| V10 | the stamp's colours: pixel blocks, grey "no number" (ux · minor) | CONFIRMED | NOT done — batch M / core | — |
| V11 | the legend "stamp: whole face" and the Settings row are false (ux · minor) | CONFIRMED | FE mode: "Squish · mm"; the row reworded (`FlexibleMainStage+Views.legendTitle`, `FlexibleRowCopy.stampMainPage`) | FlexibleFEVerifyGTests · (d) (RED: the column squish) |
| V12 | Group 2 alone pulls Face 5 in 4.25 mm (ux · minor) | CONFIRMED (control 32768: 49 %) | the far end held along its normal beside the rests (`flexible_squish_fe.cpp`, `far_anvils`) | FlexibleFEVerifyGTests · (a) (RED: control 32768) |
| V13 | the (i) hides ⅓ on Face 5 (ux · minor) | CONFIRMED | the (i) says the band's k in every case and the cut (`FlexibleFE.info(foldShare:)`) | testTheSquishInfoSaysTheBandAndTheCut; (e) |

### Hook lines in #354 / main files (this pass; each grepped after the edit)
| hook | file · anchor | ± | why |
|---|---|---|---|
| HV1 | LatticeSimModel.swift · `Result { try runner(ctx) }` → `Result { try FlexibleCoreGate.whileInCore { try runner(ctx) } }` | +1 −1 | the Stress / octet solve holds core's pool while it is IN it — a cancelled one too (its phase drops, its bridge call runs on) — so no squish sim enters beside it |
| HV2 | RunModel.swift · `scheduler.runInBackground { [weak self] in` | +2 −1 against batch G (HG1's line replaced); +2 against the branch before G | a LOCAL run claims core (`FlexibleCoreGate.claimForRun`, released by `defer`), waiting while a sim holds it; a remote run claims nothing; after a wait the stall watchdog is re-armed so the wait never eats its grace |

HG1 (`FlexibleSquishSolver.waitUntilOutOfCore()`) is gone: its rationale ("a new sim cannot start
meanwhile — the run is in runningIDs") was wrong — `runningIDs` is updated a main-queue hop after
the run starts.

Nothing else outside the track: WorkspacePlaceholder, MetalMeshView, LatticeSettings, ProjectModel
and LatticeStageMode are untouched, no case was added, core/ is untouched, the pinned strings are
untouched. The renderer's tint swap uses `MeshRenderer.setVertexTints` (already internal) from the
track's own extension.

Edited track files: `FlexibleSquishSolver` (the claim), `FlexibleMainStage` / `+Squish` / `+Views`
(read order, loop keys, the fallback group, per-group tints and notes, the legend line, the (i)),
`FlexibleSquishPlayer` (the playing group), `FlexibleMainStatusPill` (hands it over),
`MeshRenderer+FlexibleLattice` + `FlexibleLatticePass` + `FlexibleSquish` (the tint swap),
`FlexiblePageChannels` (one colour scale), `FlexibleFEField` + `FlexibleFE` (the fold cut, the (i),
the skipped line), `FlexibleRowCopy`, `flexible_squish_fe.cpp` + `FlexibleBridge.hpp` +
`FlexibleKit+Squish` (the far anvil).

### Decisions (00-decisions.md)
- D-R5-G3 amended: the far end is held beside the rests.
- D-R5-G5 amended: a field is cut so it never folds at ×1.
- D-R5-G6 amended: Play all plays each group ALONE (colours, picker, note); the fallback rules.
- D-R5-G7 amended: ONE claim on core.

### Tests
Every new test states its RED control inline — batch G's behaviour behind a test switch, computed
beside the fix, must fail the same assertion — and each control was seen RED:
- **FlexibleSquishVerifyGTests** (his 0004, Save & Exit, the page's own debounced refresh):
  - `testSaveAndExitHoldsTheLatticeAtRestUntilItsFieldLands` — the loop's `$playing` is watched AT
    THE SOURCE (a heavy first refresh holds the main actor, so a sampler missed the flash the
    renderer would draw): 0 starts before the field; RED `controlReadSimsBeforeStart` +
    `controlLoopByGeneration`: 1 ("started playing · fe pending false").
  - `testAFailedOnlySimPlaysTheColumnSquish` — one group, its sim failing after the page saw it
    pending (`controlFailDelayS`): playing, "Simple squish · the sim failed"; RED batch G: at rest.
  - `testAPickOfASolvingSimPlaysWhenItLands` — RED `controlLoopByGeneration`: at rest.
  - `testEveryFailedSimOfPlayAllPlaysOneGroup` — 2 faces (the top's), the picker on Group 1;
    "Group 2 skipped · its sim failed"; RED `controlPlayAllCombo`: 4 faces.
  - `testPlayAllPlaysEachGroupAlone` — per-turn quads equal the combo's on the group's own faces
    and differ on the other's; 40 renderer steps: turns [1, 2, 1, 2], tint / label / note
    mismatches 0, labels "All · Group 1", "All · Group 2"; RED `controlPlayAllCombo`: the top
    coloured in Group 2's turn, the label "All".
- **FlexibleCoreClaimTests**:
  - `testASimClaimsCoreInTheStepThatCommitsIt` — claimed at commit, Stress → waiting, no overlap
    (the Stress model then run straight waits in `whileInCore`); RED batch G's gate
    (`controlLateClaim` + `controlOthersDoNotClaim`): started, overlap. (With the late claim alone
    the result depended on who entered first — HV1 alone kept the sim out when it entered first.)
  - `testACancelledStressSolveStillInCoreKeepsTheSimsOut` — RED `controlLateClaim`: overlap.
  - `testALocalRunClaimsCoreAndARemoteRunDoesNot` — the local run waited, then ran without overlap,
    watchdog armed 2×; the remote run ran beside the sim (0 local watchdogs); no sim started while a
    run held core; RED `controlLateClaim`: 1 sim started, `controlOthersDoNotClaim`: the run beside the sim.
  - `testAWaitingSolveGoesBeforeTheQueuedSims` — positive control: nothing waits → a sim claims.
- **FlexibleFEVerifyGTests** (his round-5 project):
  - `testHisRound5GroupsAloneNeverFoldAndTheStampDrags` — (a) Face 5 under Group 2 0.000 of
    12.692 mm, RED control 32768: 2.125 of 4.332 (49 %); (b) both fields k · gmax(part) ≤ ½ and 0
    of 53 248 pull-backs miss, RED uncapped Group 1 (k 2): s·gmax 2.20, 665 misses, worst 9.25 mm;
    (c) Top A's stamp ring 58 % of inside, RED core's columns 30 %; (d) "Squish · mm", RED the
    column squish: "Squish · stamp: whole face"; (e) the (i) says "7× stiffer" and "cut to 23 %".
  - `testTheSquishInfoSaysTheBandAndTheCut` — one sentence each.
- Re-pinned: `FlexibleFEFieldTests.testCalibrationMatchesCoresDeepestColumn` — a band-held k is the
  band's edge × the fold share (1 when not cut).

Each fix was also mutated back in production, rebuilt in a mirror of the package and its pinning
test run. All 15 mutations went RED (`vfixG/mut_run.log` in the session scratchpad):
- MV1 the renderer never swaps a group's tints → testPlayAllPlaysEachGroupAlone (40 mismatches);
- MV2 HV1 removed (LatticeSimModel takes no claim) → testACancelledStressSolveStillInCoreKeepsTheSimsOut;
- MV3 HV2's re-arm removed → testALocalRunClaimsCoreAndARemoteRunDoesNot (armed 1×, not 2×);
- MV4 the fallback never auto-plays → testAFailedOnlySimPlaysTheColumnSquish;
- MV5 the sims read before they start → testSaveAndExitHoldsTheLatticeAtRestUntilItsFieldLands;
- MV6 no fold cut → testHisRound5… (s·gmax 2.20 and 0.94; 665 misses);
- MV7 no far anvil → testHisRound5… (Face 5 2.27 of a 0.23 mm limit);
- MV8 a queued sim jumps a waiting solve → testAWaitingSolveGoesBeforeTheQueuedSims;
- MV9 FE mode keeps "stamp: whole face" → testHisRound5…;
- MV10 a late pick not started → testAPickOfASolvingSimPlaysWhenItLands;
- MV11 a failed group not said → testEveryFailedSimOfPlayAllPlaysOneGroup;
- MV12 no fallback group (every face at once) → testEveryFailedSimOfPlayAllPlaysOneGroup (4 faces);
- MV13 the picker never says the playing group → testPlayAllPlaysEachGroupAlone (["All"]);
- MV14 the large-strain (i) drops the band → testTheSquishInfoSaysTheBandAndTheCut;
- MV15 the late claim in production → testASimClaimsCoreInTheStepThatCommitsIt.

Deleted-test sweep (`git diff 526b32e0 HEAD -- app/TopOptKit/Tests`, removed `func test` / class
lines): none.

### Build and suite (raw lines, this Mac)
- Targeted suite (the builder's 175 suites + LatticeOvernightBatchTests, LatticePageTests,
  LatticeSimRegionLayerTests and the three new ones; Debug; other sessions' suites were running on
  the same Mac):
  `Executed 1221 tests, with 21 tests skipped and 10 failures (0 unexpected) in 3173.088 (3173.223) seconds`.
  - 8 of the 10 are the known AppModelTests 3MF ×3 lines, 1 is the known
    `LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds`.
  - The 10th was mine: `FlexibleSqueezeGroupsUITests.testThePlayerWithItsPickerKeepsClearOfButtonsAndLegends`
    pins the slot's call `…sims: sims, shown: main.shownSimInfo, onPick: { main.pick($0) }, note: note)`.
    The two new player arguments now come before `sims:`, so the pin holds unchanged.
- Re-run after that fix and the last gate changes (the suites they touch, or that scan the files):
  FlexibleSqueezeGroupsUITests, FlexibleCoreClaimTests, FlexibleSquishVerifyGTests,
  FlexibleSquishSolverTests, FlexibleLegendPlacementTests, FlexibleSqueezeGroupsReviewUITests,
  FlexibleMainPageRound4Tests, FlexibleSquishPlayerTests, FlexibleSquishPlayAllTests:
  `Executed 47 tests, with 1 failure` — the claim test's red control, which with the late claim
  alone depended on who entered first; it is now batch G's whole gate, and
  FlexibleCoreClaimTests ran twice since: `Executed 4 tests, with 0 failures (0 unexpected) in 57.400`
  and `in 54.199`.
- Earlier in this pass: FlexibleSquishSolverTests, FlexibleSquishPlayAllTests, FlexibleFEFieldTests,
  FlexibleFEPassTests, FlexibleSquishFETests, FlexibleSquishCoarsenTests,
  FlexibleSquishModulusTests, FlexibleSettingsVerifyD1Tests, FlexibleSqueezeGroupsModelTests:
  `Executed 60 tests, with 0 failures (0 unexpected) in 457.398`.
  - On the M2 stand the fold cut gives k 1.204 (it was 2.000). His saved pad keeps k 2.000
    (gmax 0.21), and C1's pads keep 1.367 and 1.616.
- iOS: `** BUILD SUCCEEDED **` (`xcodebuild … -destination id=147E56A1-… -derivedDataPath …/flexA1
  build`) on the final tree. `TopOpt.debug.dylib` is stamped 20:28 and holds `FlexibleCoreGate`,
  `claimForRun` and `playAllPlaying`. It was not installed or launched.

### Commits (PR #362's branch `claude/flexible-screens`; nothing pushed)
- a7dbbd5c — never two solves in core, as ONE claim (`FlexibleCoreGate`, HV1, HV2).
- 17289c67 — a group alone squeezes against its far end; no field folds at ×1; the (i).
- 616ceab7 — the main page: rest until the field lands, a failed sim plays, Play all plays each
  group alone, the stamp lines, his round-5 project as evidence.
- This handoff section and the DECISIONS amendments (the commit after them).

## Round 5 · batch G — a realistic squish: one continuous 3D field per squeeze group

(★ The verification pass above corrects parts of this section: Save & Exit no longer flashes the column squish first, "Play all" plays each group alone, a failed sim plays, a group squeezes against its far end, no field folds at ×1, and HG1 is replaced by HV2.)

Your words: "is there a way to ensure that the squish sim also squeezes out the sides of the object?
I'd like it to actually bend and move and squish like it would in real life. Also, I'd like a way to
play the different sims if there are multiple ways to squeeze/squish a model. Can you do all this
along with the lattice?"

Judged on YOUR project 0004, restored through `AppModel.open`, on C1's plain pad, on a cylinder and
on the M2 stand.
The main page was rendered offscreen by the shipping renderer, BEFORE and AFTER. The app was NOT
launched, so none of this has been seen on a screen yet.

**What you will see on the main Flexible page:**
- **Save & Exit.**
  - The lattice appears at once, held at rest.
  - The player's note reads **"Simulating the squish…"** for a few seconds.
  - Then the part plays.
- **The part moves as one body.**
  - The pressed faces sink and the free sides BULGE out (on C1's pad the sides move out by 35 % of
    the top's squish).
  - The ghost, the bent heat map and the lattice walls move together, by one 3D field and one
    flexScale.
- **Two or more squeeze groups.**
  - The picker lists "Group 1 · Top A + Top B", "Group 2 · Face 3 + Face 5", then **"Play all"**.
  - "Play all" is the default. It plays Group 1 in and out, then Group 2 in and out, and so on.
  - The swap happens at rest, so nothing pops.
  - "All at once" is gone: your groups are separate squeezes.
- **The numbers do not change.** The colours, the legend's ends and tap-to-read are core's per-column
  depths. The 3D sim gives the SHAPE, scaled so its deepest zone moves core's deepest squish.
- **The four defects from batch B are gone** (before / after frames below):
  - the speckled seam along top A | top B;
  - the flap of the top map past the pressed side wall;
  - the torn, speckled pressed side face;
  - the pinched heat planes crossing.
- **Honesty, behind the Squish legend's (i)**, one sentence:
  - normally: "…moves by a linear 3D sim scaled to core's squish; real TPU stiffens and thin walls can
    fold";
  - on your Covered pad: "…a linear 3D sim that finds this part 4× stiffer than core's columns (its
    skin and walls carry load), so it moves less than the map reads";
  - after the one retry with every rest bonded: "…a linear 3D sim with every rest held fast
    (sliding, it did not settle)…";
  - where even ×1 is past small strain (the M2 stand): "…a linear 3D sim that leaves small strain
    here, so the picture can fold where real TPU would stiffen".
- **If a sim fails** (or runs past its budget):
  - that group plays today's column squish, with "Simple squish · the sim failed";
  - core's words are behind the (i);
  - "Play all" skips it.
- **The Settings page does not change.** While you drag a curve, the dent is still the instant
  column dent.

**What it does to YOUR pad (as saved: one group — Top A, Top B and the Face 3 | Face 5 pinch; 0, 2 and
4 resting):**
- **The solve.** 64 × 64 × 13 voxels, 53 k elements, 125 multigrid iterations, 2.3 s on this Mac
  (a Debug build of the app's bridge on Release core).
- **Your Covered finish's skin carries the load.**
  - The sim finds the part 3.6× stiffer than core's columns. The skin plates and walls work in
    parallel with the lattice, and core's columns ignore them.
  - So k is held at 2 (the band below), and the part moves about half of what the heat map reads.
  - The picture is ×2 (the column squish was ×4). A bigger ×k would fold the field there: its peak
    local compression is 21 % at ×1.
- **Your img-4 split (top | sides).**
  - The top group is inside the band (k 1.83) and plays at ×4.
  - The sides group asks 4.5 and is held at 2.
- **With [Face 5 rests]:** asked 13.6, held at 2.

**On the M2 stand** (my probe's case: the pocket floor pressed at 5 kg, the bottom resting; every
voxel is lattice):
- The sim lands in about 4 s (Jacobi-CG, 2 556 iterations; multigrid stagnates there).
- The U's walls splay out and the tower leans; the column squish only dented the pocket floor.
- It asks k 12.9 (held at 2), and even ×1 is past the small-strain bound (‖∇u‖ 0.83 in the part),
  so the page plays ×1 and the (i) says the picture can fold. The renders show no fold.

**Deviations from the design (each with its reason):**
1. **A rest grips only where it is an ANVIL.**
   - The design bonded every resting face. On your pad that glued the pad to the table under a side
     squeeze: k 7.7 for the sides group, 13.6 with [Face 5 rests], against the design's own sanity
     band [0.5, 2].
   - Now a resting face that a pressed stack of the group exits through is bonded (its friction
     holds under the load). Any other rest slides, with its normal held.
   - The rigid modes that leaves free are treated like a free squeeze: inertia relief, one pin each,
     and the rigid motion removed.
   - Measured: a ±X pinch on a sliding bottom squeezes exactly as with nothing resting (9.73 mm);
     bonded, 3.73 mm.
2. **k is kept inside [0.5, 2]**, flagged and said when held.
   - One scalar stretched to 13.6 sank a soft spot 20 mm through your 20 mm pad (frame
     `G_his0004rest5_group-1_after_iso_a100.png` of the first run).
   - A shape-only lattice is never held: its k is a unit conversion.
3. **gmax is the EXACT maximum of ‖∇u‖₂**: the trilinear Jacobian peaks at a cell corner. The design
   asked for a looser Frobenius-of-maxima bound; the injectivity rule s · gmax ≤ ½ is unchanged.
4. **The FE squish probe is held to its parts.**
   - The GPU-vs-twin pull-back is 1.4 µm, and the lattice at the GPU's own rest point is 1.2 µm.
   - The whole chain is not held to 5 µm (0.115 mm): the gyroid's distance estimate is steep near
     its sheets and amplifies the hardware filter's µm.
5. **The display solve is bounded by a WORK budget as well as its 20 s deadline.**
   - Core polls the deadline every 256 CG iterations. Under heavy CPU load one sim took ~150 s.
   - Core gives multigrid at most 300 V-cycles, then restarts Jacobi-CG from zero. The cap bounds
     that Jacobi-CG: elements × iterations ≤ 5·10⁷ (about 4 s on this Mac), never under 600 —
     939 on your pad, 3 763 on the M2 stand.
   - A fixed 600 (my first cut) FAILED the M2 stand: every voxel there is lattice
     (E 0.16–34 MPa), multigrid stagnates, and Jacobi-CG needs 2 556 iterations for 1e-4. The stand
     played the column squish with "Simple squish · the sim failed".
   - Past the cap core's non-convergence is a value, and the column squish plays. A failure now
     names which solver gave up ("multigrid built, 300 V-cycles, then N Jacobi-CG iterations,
     residual r") behind the (i).
6. **FOUND: two solves in core's matrix-free pool DEADLOCK** (sampled: both threads waiting on
   `ApplyPool::run`'s condition variable for ever).
   - The design's "threads = 1 makes the pool safe" is false: the pool is process-global and
     another solve raised the count mid-sim.
   - The gates are now both ways:
     - no sim starts beside the Stress solve or a run;
     - the Stress solve waits for the sims (a process-wide idle signal);
     - a topology run waits on its background thread until no sim is in core (RunModel's one hook).
   - Core brief #18 (a thread-safe pool) is now urgent.
7. **FOUND in the targeted suite: a topology run leaves core's production toggles armed.**
   - The M2 stand's test passed alone and failed in the suite (core's deadline, 73 s).
   - Sampled: the sim's Jacobi-CG fallback was building a GenEO eigenbasis (LOBPCG).
     `configure_production_options` arms GenEO and Krylov recycling for the whole process, and
     nothing disarms them. In the app, any topology run earlier in the session does the same.
   - The sim's posture now pins both OFF and gives them back (the receipt says before / during /
     after). With GenEO armed the stand's sim takes ~4 s again.
   - I first blamed the wait for the solver (the deadline started at the request) and changed that
     too: the deadline now starts once the sim holds the solver, and the wait is reported
     (`wait_ms`). A test proves the queued case; it was not what failed the stand.
   - Core's deadline also throws from inside the recurrence before `info` is filled, so a deadline
     failure now says the clock ("after N ms of solving, at CG iteration i") instead of a row of
     zeros.
   - ★ In two of the three runs where the stand's test failed, the test process then CRASHED (SIGSEGV in the next test, copying a
     `FlexSquishSolutionInfo`; `xctest-2026-09-30-164119.ips`). With GenEO pinned off it did not
     recur in the re-run of the same classes. The cause is NOT proven; GenEO's process-global
     basis, built for one system and met by the next, is my suspect.

**Not done (and why):**
- **Nothing has been seen on a device or simulator.** I must not launch the app. The iOS build
  succeeds.
- **Large-strain / hyperelastic TPU, buckling of thin skins, a per-voxel Poisson ratio, friction** —
  core brief #19–#28. The sim is linear small-strain; the (i) says so.
- **The octet's and Organic's own core solves are not held back by the sims.** They run on other
  sections of the Lattice stage; only the Flexible Stress solve and topology runs are gated. Core
  brief #18.
- **T16's own frame budget was RED in the Release run** (the column path, 18.26 ms > 16 ms; see
  "Release numbers"). Not A/B'd against the pre-G build.
- **The field outside the part is steep where two parts of it move apart** (the extension). On
  the M2 stand the air cells reach ‖∇u‖ 2.51 against 0.83 in the part and its surface cells, so
  the safe scale reads 0.20 instead of 0.60. Both are under ×1, which the page floors at, so
  nothing changes on screen today. A smoother (harmonic) extension would fix the reading.
- **A group's sim is not re-solved while you drag on the main page.** It re-solves when a
  main-page group or load change rebuilds the lattice (never per frame).

**Your call:**
- **Your Covered pad moves about half of what its heat map reads.** The sim says its skin carries
  the load and core's columns do not see it. Keep it honest (as now, said in the (i)), or scale the
  field fully to core's depth (k 3.6: a fold-limited ×1 picture)?
- **"Play all" plays the groups in turn and "All at once" is gone.** Should a simultaneous squeeze
  come back as its own sim? Linear superposition makes it cheap.
- **Resting faces:** they grip where they carry the group's load and slide elsewhere. Say if a rest
  should always grip (glued) or always slide (a smooth table).
- **A squeeze of yours that no rest grips can be stiff to solve.** Your pad with the bottom pressed
  too has no anvil (every exit face is pressed), so its rests slide. Multigrid then stalls, and the
  app retries once with every rest bonded (a stiffer picture; the Squish legend's (i) says so). Keep that retry,
  or show the column squish there instead?

### Release numbers (M2 Pro, this Mac; opt-in probes)

Command: `FLEX_G_PERF=1 swift test -c release -Xswiftc -enable-testing --filter "FlexibleSquishPerfProbe|FlexibleFEPassPerfTests|FlexibleLatticePassPerfTests"`.

**One sim, wall clock, three repeats each** (gates: your pad ≤ 4 s, C1's pad ≤ 3 s — both met; the stand is measured, not gated):

| case | grid | elements | iterations | multigrid | wall ms |
|---|---|---|---|---|---|
| your pad, Fast | 64 × 64 × 13, ×1 | 53 248 | 125 | 3 levels | 2409 / 2396 / 2395 |
| your pad, Fine | 128 × 128 × 26, ×2 | 53 248 | 126 | 3 levels | 2442 / 2430 / 2427 |
| C1's pad (covered) | 100 × 100 × 20, ×2 | 53 248 | 119 | 3 levels | 2296 / 2321 / 2310 |
| the M2 stand (top pressed 5 kg, bottom resting) | 64 × 16 × 59, ×1 | 13 287 | 2 556 (Jacobi-CG; cap 3 763) | stagnated (300 V-cycles), then Jacobi-CG | 3926 / 3906 (k asked 12.9, held at 2) |

- The first Release run had the M2 stand FAILED: "CG did not reach the requested tolerance within
  max_iterations" after 1 942 ms — the fixed 600 cap (deviation 5). The row above is the re-run
  with the work budget (`--filter FlexibleSquishPerfProbe/testTheM2Stand`, same flags).

**The frame** (1152 px, MSAA 4×, X-ray; 15 frames each after 1 warm-up):
- the FE frame's median is 15.79 ms (min 14.51, max 23.44);
- the same gyroid squished by the column path: 18.03 ms (min 15.12, max 26.77);
- hidden: 1.92 ms (the control: the timer sees the march).
- The bar (FE ≤ column + 3 ms) is met. In this run the FE frame was not slower than the column
  frame; one run cannot say more than that (the two medians are 2 ms apart, inside the spread).

**T16's own frame budget went RED in the same run**: the gyroid squished by the COLUMN path,
median 18.26 ms > 16 ms (min 12.82, max 23.36; n 9). That frame adds only one uniform branch
from batch G (`feK.x` is 0 with no field bound, so `flx_pullback` takes the column path).
T16 measured it at 12.94–16.35 ms under ~40 % background GPU load; this run shared the Mac with other sessions too. I did NOT A/B it
against the pre-G build, so a G cost there is not ruled out. Re-measure on an idle GPU and on the
iPad.

### The before / after frames

The main page's own picture, rendered by the shipping renderer:
- the overlay, tints, X-ray alpha, lattice layer and dents that FlexibleMainStage hands MetalMeshView;
- settled like the page, at rest / half / full;
- BEFORE is today's column squish (the stage's test switch), AFTER is the group's field with its mesh
  (`FlexibleSquishEvidenceProbe`, opt-in).

The contact sheet `g/G_before_after.png` (scratchpad) shows:

| row | before | after |
|---|---|---|
| his 0004, iso, full | the speckled seam along x = 50, flaps at both side walls | one surface, no seam |
| his 0004, right, full | lattice speckle through the grey pressed side, two flaps | a clean face |
| his img-4 split, the sides group, front | the top map stands out past both walls | the sides bend in, the top follows |
| C1's pad, top pressed, bare | the map dents, the walls stay straight | the top dents; the sides move out ~1 mm at ×2 (barely visible at this scale — the numbers are in the tests) |
| C1's pad, ±X pinch, nothing resting | torn middle, the map through the part | the faces curve in, top and front bow out |
| the M2 stand, pocket floor pressed | only the floor dents (×4) | the U's walls splay, the tower leans (×1); no tearing |

Every frame is in `g/ev2` (the pad), `g/ev3` (your project) and `g/ev4` (the M2 stand). Each case has three views, each at
rest, half and full squish.

### Hook lines in #354 / main files

| hook | file · anchor | ± | why |
|---|---|---|---|
| HG1 | RunModel.swift · `scheduler.runInBackground { [weak self] in` | +1 | `FlexibleSquishSolver.waitUntilOutOfCore()`: a topology run waits on its background thread until no squish sim is in core's matrix-free pool (two solves there deadlock; a new sim cannot start meanwhile — the run is in `runningIDs`). ★ SUPERSEDED by HV2 (verification pass): `runningIDs` is updated a main-queue hop after the run starts, so a sim COULD start meanwhile; the wait also delayed remote runs, ate the watchdog's grace and gave up after 60 s. |

Nothing else outside the track:
- `git diff --numstat` shows RunModel.swift 1 0.
- WorkspacePlaceholder, MetalMeshView, LatticeSettings, ProjectModel and LatticeStageMode are
  untouched, and no case was added. core/ is untouched.
- The pinned strings (SmoothingPageRound2Tests, the first 900 characters of
  `startStressSolveIfNeeded`) are untouched.
- The FE data reaches the renderer through the existing H3 (`layer`) and H4 (`dents`). The swap
  uses `MeshRenderer.setFlexDisplacements` (already internal) from the track's own extension.

New files:
- bridge: `flexible_squish_fe.hpp` / `.cpp` (private to the bridge target) and
  `FlexibleKit+Squish.swift`;
- Swift: `FlexibleFE`, `FlexibleFEField`, `FlexibleFERequest`, `FlexibleSquishSolver`,
  `FlexibleStageModel+Squish`, `FlexibleMainStage+Squish`.

Edited track files:
- `FlexibleBridge.hpp` (a section appended) and `flexible_bridge.cpp` (the entry point);
- `FlexibleLatticeShader` (the FE block, `flx_fe_pullback`, texture 6, the probe);
- `FlexibleLatticePass` (upload, bind, frame block, probes);
- `MeshRenderer+FlexibleLattice` (the sequence and the swap);
- `FlexibleSquish` (the layer's fields, the Swift twin's FE branch);
- `FlexibleSquishPlayer` (cycles, sequence, pause / scrub / play);
- `FlexibleSqueezeGroups`, `FlexibleRowCopy`, `FlexibleLatticeGeneration` (Play all);
- `FlexibleStageModel` (the request built in the build task, the cache, the solver, `sceneRef`);
- `FlexibleMainStage` / `+Views` (the FE view, the overlay edge, dents, notes, the (i), the gates);
- `FlexibleShownValues` (the uncapped rule), `FlexibleStressSolve` (`busy`, `.waiting`) and
  `FlexibleProbe` (the lattice read through the field).

### Decisions (00-decisions.md)

- New rows D-R5-G1 … G7: the field, the law, the rests, the calibration band, the injectivity cap,
  Play all, and never two solves in the pool.
- D-R4-15 and D-R4-18 are amended to point at them.

### Core brief (G — what the app does itself today that core should own; #1–#17 stand)

- **#18 (URGENT) A thread-safe matrix-free ApplyPool, or a per-call thread count.**
  - Two solves in the pool deadlock (sampled).
  - The app now keeps its squish sims apart from the Flexible Stress solve and from topology runs.
    It cannot see the octet's or Organic's own solves on the other sections.
- **#19 A `flexible::squish_field` API** so this setup moves into core and into the receipt: the
  group's loads by column pressure (sector cuts), the rests (anvils grip, others slide), inertia
  relief + minimal pins for free modes, the secant law, the calibration and its k.
- **#20 Large-strain hyperelastic FE for TPU lattices**: Ogden or Mooney–Rivlin fitted to the curve
  tables, loading AND unloading, contact at the rests, and a platen for the press. The app's
  secant-per-voxel linear model is a display approximation.
- **#21 Buckling of thin skins and side walls** (at least linear eigen-buckling). Real one-bead TPU
  walls fold outward under a top press; the linear FE cannot show it.
- **#22 A homogenised anisotropic law for TPU gyroid / honeycomb**, and LATERAL-strain (Poisson)
  data in the curve tables. ν = 0.3 is an assumption today.
- **#23 A per-voxel Poisson ratio and a locking-free element** (B-bar or selective reduced
  integration), so solid TPU (ν ≈ 0.48) and thin skins in bending are not over-stiff.
- **#24 The column model ignores side skins, neighbour shear and the bulge.**
  - On his Covered pad the 3D sim is 3.6× stiffer than the columns (the sides group 4.5×; with
    [Face 5 rests] 13.6×).
  - Core should design, or at least report, the depth with the 3D solve and its k.
- **#25 Solid modulus per nozzle temperature.** varioShore foams above ~210 °C; the TDS 50 MPa is
  for 210 °C / 100 % flow.
- **#26 Rigid stamp contact as a load case** (check stamps as selectable sims; the request already
  takes per-column pressures).
- **#27 Friction at the rests and a platen with friction.** Today a rest is bonded where it is the
  group's anvil and sliding elsewhere — the two linear limits.
- **#28 Where a pinch's halves meet.** The FE's zero-displacement plane is the evidence for #6: the
  app splits at the column's middle.
- **#29 A nonlinear (Newton on σ(ε; ρ)) or tangent-updated solve**, so a voxel's operating strain is
  self-consistent instead of taken from core's 1D column.
- **#30 A deadline polled inside the multigrid loop** (it is polled every 256 CG iterations, so a
  crawling solve overran 20 s by ~130 s under load); the app caps its display solve by a work
  budget.
- **#32 A per-call solver configuration.** `configure_production_options` sets process-global
  toggles (GenEO, recycling, threads) that outlive the run; every other caller must pin them. The
  squish sim now does, but the octet's and Organic's own solves on the Lattice stage do not.
- **#31 Multigrid stagnates on a slender all-lattice part.** On the M2 stand (64 × 16 × 59, 3.41 mm
  voxels) the V-cycle needs 217 cycles even at a UNIFORM modulus, and never reaches 1e-4 (nor 1e-2)
  in its 300 at the real 220× contrast. Its iterate is then thrown away and Jacobi-CG starts from
  zero (2 556 iterations). Arming the algebraic level 1 changed nothing in a quick check. A warm
  start from the stagnated iterate would save ~⅓ of the solve.

### Tests

Every new test states its RED control inline. That control is the wrong behaviour, computed beside
the right one, and it must fail the same assertion.

NEW, in TopOptKitTests (the bridge, on C1's pad):
- `FlexibleSquishModulusTests` (2): the law is the secant of core's curve.
  - 0.1744 MPa initial, 0.122 at 0.2294, 50 solid, the Voigt skin, the clamps, shape-only ρ².
  - Control 256 (the table's nominal axis) gives 0.20.
- `FlexibleSquishFETests` (12), each with its control:
  - the sides bulge 34.8 % (ν = 0: 0.00 %);
  - a symmetric pad mirrors to 2.8e-5 (an off-centre stamp: 1.01);
  - the ±X pinch with nothing resting: equal and opposite, the pins carry 1.5e-5 N of 196 N (a patch
    anchor: 0.34 N, the faces 2.66 / 7.07 mm);
  - another pin choice gives the same field to 3.7e-5 (the patch: 1.18);
  - the rest holds and carries 294.3 N (a roller slides 1.24 mm);
  - a side squeeze does not glue the pad to its rest (9.73 mm, as free; bonded 3.73);
  - the loads sum to the design force (unprojected: 162 N for 150);
  - a stamp stays local (uniform: the rim 100 %);
  - the posture is restored and a missed deadline is a value;
  - a sim queued behind another keeps its whole budget (measured from the request, its wait +
    solve is past it);
  - with GenEO armed (as a topology run leaves it) the sim solves with it OFF and gives it back
    (control 16384: left as found, it is on during the sim);
  - 1e-4 is within 0.004 % of 1e-8 (1e-1: 3.8 %);
  - the coarsening rule.

NEW, in TopOptFlowsTests (the app's pipeline, your project, C1's pad, a cylinder):
- `FlexibleFEFieldTests` (12):
  - the calibration (above; control 32 asks k 304);
  - the dent follows your drawing (centroid x 76.5 mm; uniform E: 50.0);
  - no seam: 571 top A | top B pairs, 569 bitwise equal (the per-region column dent steps 0.93 mm);
  - no flap: the top map's edge follows face 5 by ≥ 0.998 (the column dent: 0.0);
  - the planes never cross at the page's ×2: det ≥ 0.65, 97 % of the gap kept (control ×7.3: det
    −0.26);
  - the mesh samples the field exactly and is cut to 1.5625 mm (the column dent is 1.07 mm off at the
    side);
  - the extension on a cylinder: gmax equal inside and over the box, 0 / 432 pull-backs fail (zeros
    outside: 33×, 178 / 432);
  - five pressed faces all move (the column slots: 3 of 5);
  - a sector's loads stay on its side, and on the ×2 grid your sides are renormalised from 90.5 N to
    core's 98.07 N (control 4 doubles the raw traction);
  - the shape-only (TPU 95A) sim;
  - the (i) is one sentence in every state, including "with every rest held fast" after the
    bonded retry;
  - the M2 stand gets its field with GenEO armed in the process: multigrid stagnates, 2 556 of 3 763 Jacobi-CG iterations, within
    0.15 % of a 1e-8 reference (control 8192, the old fixed 600: core's non-convergence);
  - the five-face pinch's (i) says the rests were held fast (an unflagged field is silent).
- `FlexibleFEPassTests` (5, GPU):
  - the inverse: GPU vs the rest point 3.2 µm at ×2, GPU vs the twin 3.1 µm (one iteration:
    1.62 mm);
  - the lattice and the ghost move together on your faces 3 and 5 (0.5 / 0.9 µm; the column dent
    4.0 / 4.9 mm);
  - the FE uniform block by name;
  - rest pixel-identical (0 of 102 400; the field applied: 31 873);
  - the squish probe held to its two parts.
- `FlexibleSquishPlayAllTests` (5):
  - Play all in turn: 0, 1, 2, 0, every swap at amount ≤ 1e-5 (D2's single entry: group 0
    throughout);
  - pause / scrub / play keep the group;
  - the renderer swaps field and mesh in ONE step (a late mesh is a one-frame mismatch);
  - 0 publishes over 3 wraps (a per-wrap publisher fires 3);
  - the picker (D2's list is the control).
- `FlexibleSquishSolverTests` (5):
  - one solve at a time, the shown sim first (peak 1; concurrency 2 peaks 2);
  - a superseded generation dropped, and a pick never re-solves;
  - the gates both ways;
  - the column fallback with its line and core's words (no fallback: nothing plays);
  - H4 follows the renderer live, the stage's overlay is cut to the sim's grid, and a tap on face 3's
    bent map reads 1.52 mm = core's column.
- `FlexibleSquishCoarsenTests` (2): the Swift twin is the bridge's rule (off by one voxel: RED).
- Opt-in: `FlexibleSquishEvidenceProbe` (the renders; the M2 stand's case is new), `FlexibleSquishPerfProbe`
  and `FlexibleFEPassPerfTests` (Release).

RE-PINNED, each with its reason in the test:
- `FlexibleSqueezeGroupsTests` and `FlexibleSqueezeGroupsReviewUITests`: "All at once" → "Play all".
- `FlexibleSqueezeGroupsReviewUXTests`: comments only (the note on "all").
- `FlexibleLatticePassTests`: the FE block in the uniform echo.
- `FlexibleSqueezeGroupsModelTests`: the pick is held on the column path (the sims landing mid-test
  would race it), and its default is now Play all.

Deleted-test sweep (`git diff f7c30c10 -- app/TopOptKit/Tests`, this batch only): no test was
deleted or renamed.

Mutation runs: each breaks one production rule in a separate build, runs the test that pins it, then
restores the file (`g/mut_run.log`). All 15 are RED (G11 first ran GREEN — not caught — and its
test was strengthened: the renormalisation is pinned on the ×2 grid):
```
G1  the shader never dispatches to the FE field      ⇒ the walls' pull-back lands 1.66 / 1.57 mm from the ghost (2)
G2  the renderer swaps the field without its mesh    ⇒ mesh -1 ≠ the field's (2)
G3  the calibration band off                         ⇒ "his covered pad is held by the band" (1)
G4  every rest bonded (the design's rule)            ⇒ 0 free modes, the sole does not slide, 3.73 < 7.79 mm (3)
G5  Play all plays the first group only              ⇒ the sequence 1 ≠ 2 (2)
G6  H4 hands a copy taken at refresh                 ⇒ H4 ≠ the renderer's mesh (1)
G7  the Stress solve does not wait for a sim         ⇒ "the Stress solve waits for the sim" (1)
G8  a sim of an old lattice is stored                ⇒ the stale result shown (1)
G9  the overlay not cut to the sim's grid            ⇒ the longest edge 1.82 > 1.5626 mm (1)
G10 the page's ×k keeps the column clamp in FE mode  ⇒ ×4 > the field's safe ×2.43 (1)
G11 the loads not renormalised to the design force   ⇒ 90.52 ≠ 98.07 N on the ×2 grid (2)
G12 the work budget off: the old fixed 600           ⇒ the M2 stand's sim does not land (1)
G13 the bonded retry never said behind the (i)       ⇒ the five-face (i) is silent about it (2)
G14 the deadline measured from the request           ⇒ the queued sim: "deadline passed before … began" (1)
G15 GenEO left armed for the sim                     ⇒ the M2 stand with GenEO armed: core's deadline, 74.8 s (1)
```

### Build and suite (raw lines, this Mac)

iOS (Debug, the simulator 147E56A1…, DerivedData flexA1), on the final tree:
```
** BUILD SUCCEEDED **
```
The app's `TopOpt.debug.dylib` is stamped 17:40:49 and holds the new bridge string ("ms of solving,
at CG iteration"). It was NOT installed or launched.

Targeted suite (`swift test --filter` with the classes of `g/filter2.txt`, 175 suites), on the tree
before the last one-line fix:
```
Executed 1185 tests, with 21 tests skipped and 15 failures (0 unexpected) in 2139.900 (2140.025) seconds
   2 AppModelTests.testReopenedThreeMFProjectReimportsTheStlWorkingCopy          (known)
   4 AppModelTests.testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance (known)
   2 AppModelTests.testThreeMFImportOptimisesOnDeviceEndToEnd                    (known)
   1 LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds          (known)
   6 FlexibleSquishSolverTests.testFailureFallsBackToTheColumnSquish             (mine — fixed below)
FLEX-G M2 STAND: 13287 elements · … · 2556 of 3763 iterations · 3914 ms · … 0.00149
```
- The fallback test forced a failure with a 1 ms deadline. Now that the deadline starts once the
  sim holds the solver, 1 ms outlives a solve that converges before core's first poll. The control
  is now 1 ns (`FlexibleSquishSolver`, one line).
- Re-run after that fix (the solver, Play all, bridge, coarsen, modulus and pass classes):
  `Executed 31 tests, with 0 failures (0 unexpected) in 140.290 seconds`.
- No test process crashed in either run.

### Commits (PR #362's branch `claude/flexible-screens`; nothing pushed)

- `d599e0d2` the squish sim's bridge (the FE solve on core's matrix-free MG-CG).
- `4fc983b4` each squeeze group's 3D sim wired through the app; Play all.
- `b2345866` never two solves in core's pool; the bounded display solve; the bonded retry.
- `40ceff62` the work budget, the posture's GenEO / recycling pin, the deadline start, the (i)
  lines, the M2 stand's test and renders.
- The next commit: this section and DECISIONS D-R5-G1…G7 (D-R4-15 and D-R4-18 amended).

## Round 4 · batch C2 — verification pass

The C2 verifier reported 14 findings: 4 majors and 10 minors (two of them are the same "Building…"
tap, seen from the code and from the screen). I checked each one on YOUR project 0004, restored
through `AppModel.open`, and on the plain pad. I fixed all four majors and every cheap minor.
The view row was hosted offscreen at 11" and 13" in both orientations and clicked. The app was NOT
launched, so none of this has been seen on a screen yet.

**What changes for you on the main Flexible page:**
- **The big Lattice button is green "Ready" only when core can take the job.** On your project as
  saved (Face 3 and Face 5 pinch the pad) C2 showed the green "Lattice · Ready". A tap then ended
  on "Not sent" with nothing to do. Now:
  - the pill reads **"Lattice · Preview · core can't pinch yet"**, grey with a green outline. The
    lattice preview is built and shown as before;
  - a tap opens the Export step on **"Not sent: core can't press Face 3 and Face 5 at once"**, with
    **[Send with Face 5 resting] [Send with Face 3 resting]**;
  - [Send with Face 5 resting] sends the job with Face 5 resting in the job only. Core answers
    **"Core designed it · Face 5 resting · Gyroid · 240 °C · 3 faces"**. Your pinch stays in
    Settings and in the preview;
  - tapping the pill again keeps core's answer and both buttons.
- **Two squeeze groups (your img 4, the sides in Group 2):** the pill reads **"Preview · core runs
  one group at a time"**. The step offers **[Send Group 1 only] [Send Group 2 only, Face 5
  resting]** (Group 2 holds your pinch, so one end of it rests too). Group 2 gives "Core designed
  it · Group 2 only, Face 5 resting · Gyroid · 190 °C · 1 face".
- **TPU 95A (img 1):** the pill keeps your label, **"TPU 95A: shape only — no squish predicted"**,
  in the preview look, not the green.
  - A tap says **"Not sent: TPU 95A has no squish data yet"**, with core's own sentence behind the
    (i), and one button: **[Use colorFabb varioShore TPU]**.
  - That button switches the filament and closes the step. The lattice rebuilds, "Lattice ready"
    appears, Ready turns green, and the next tap sends it: core designs it.
  - The job is no longer sent just to be refused. Core refuses it from the same catalogue entry the
    app reads. A test asks core's runner directly and gets the same code (`calibrate_first`) and
    sentence.
- **Ready on another stage sends what you set NOW.** C2 sent the job from BEFORE an edit you made on
  Topology. Example: you change the "Top" Load group from 10 to 20 kg on Topology, then tap
  "Lattice · Ready":
  - C2: core got 10 kg (the stage re-reads the main page only while it shows);
  - now: nothing is sent. You are taken to the Lattice stage, where "Still building — it shows here
    when ready" appears and the lattice rebuilds with 20 kg. Ready comes back, and the next tap
    sends 20 kg (the face's `weight_n` in core's job: 98.07 → 196.13 N).
- **"Lattice · Building…" tapped on Topology or Surface takes you to the Lattice stage** (no
  Settings). C2's tap did nothing you could see: builds only start on the Lattice stage, and the
  note is only drawn there.
- **The "Lattice ready" note is now on the same line as the three view buttons, to their left.**
  It was under them.
  - The legends stay where batch C put them. On your project at 13" landscape, with the Gravity
    chip, all three are back in one column at the right edge. C2 moved Stress and Lattice 260 pt
    to the left, over the part.
  - The whole note is [Show]'s tap target (40 pt tall). It was the 13 pt word alone.
- **The Export step:**
  - "Waits on core's Flexible exporter" is said once, under core's line. [Export STL] and
    [Export G-code] are plain greyed buttons.
  - The (i) no longer shows a temp-folder path. The previous run's temp folder is deleted when the
    next job is sent.
  - The scrim, outline and shadow now use DS tokens.
- **A project with no part file** says "Not sent: the part's file is missing". C2 said "press a face
  first".

**Each finding, checked:**

| # | finding | verdict | evidence (raw lines below) |
|---|---|---|---|
| 1 | major · Ready on Topology sends the weight from before his edit | CONFIRMED, fixed | RED run on C2: `tap Ready → runs 1 · to the Lattice stage 0× · face 1000103 10.0 → 10.0 kg · stale false · pill 'Ready'` |
| 2 | major · "Building…" on another stage is a dead tap | CONFIRMED, fixed (H10) | RED run on C2: `designing at Exit true … off-stage 2 s: lattice false building false · pill 'Building…'`, no navigation |
| 3 | minor · Swift 6 warning in FlexibleCoreRun.swift:168 | CONFIRMED, fixed | now `await self?.land(result, for: job)` (a main-actor method); no warning in any file this pass touched (build logs) |
| 4 | minor · the targeted filter missed 10 suites | CONFIRMED, fixed | the filter is now built from CLASS names: every class in a Flexible* file, the brief's list, and every class in a file that mentions WorkspacePlaceholder (157 classes, including all 10) |
| 5 | minor · no file ⇒ "press a face first" | CONFIRMED, fixed | `EncodeError.noPart`; C2's line was `Not sent: press a face first` |
| 6 | major · pinch / two groups: green Ready, then a dead end | CONFIRMED, fixed | RED run on C2: `pill 'Ready' tone ready`, step `Not sent: core can't press both ends yet`, no button |
| 7 | major · TPU 95A: green pill, job sent to be refused, no fix | CONFIRMED, fixed | RED run on C2: `("ready") is not equal to ("preview")`, `runs 1` |
| 8 | minor · the note band pushes legends into a second column | CONFIRMED, fixed | control (C2's band, 13l, chips 222): `lattice (844,590) · stress (844,454)`; now `dent (1104,294) lattice (1104,566) stress (1104,430)` |
| 9 | minor · "Building…" off the Lattice stage does nothing visible | the same as #2 | — |
| 10 | minor · a failed build opens Settings with no pop-up | CONFIRMED, NOT changed | a failed build has no fix the app knows; Settings' top line gives core's words, and Save & Exit already retries once (`didExitSettings → retryFailedBuild`). A [Try again] pop-up would only repeat Exit. Your call |
| 11 | minor · the step is text only; a temp path behind (i) | PARTLY fixed | path dropped, old folders deleted; core's heat maps are SVG files, which SwiftUI on iOS 16 cannot draw without an SVG renderer (not done) |
| 12 | minor · the wait line twice; raw colours | CONFIRMED, fixed | once; `DS.Color.scrim`, `DS.Color.strokePanel`, `DS.Shadow.sheet` |
| 13 | minor · [Show] is a 13 pt word | CONFIRMED, fixed | the whole 40 pt note; a hosted click on its ICON shows the lattice (RED on C2) |
| 14 | minor · carried over: the flap past the pressed side walls | CONFIRMED, not C2's | batch G's displacement field |

One finding needed a narrower claim than the verifier's (#8). At 11" landscape with the Gravity
chip, batch C's own layout already used a second legend column. With the note beside the row,
that column's top legend sits at y 491, as it did in C2; batch C had it at y 219. At every size the
note never pushes a legend out of the trailing column. Everywhere else — 13" in both orientations,
11" portrait, 820 and 744 pt wide screens, and 11" landscape without the chip — the legends are
exactly where batch C put them (the test compares every frame).

**Not done (and why):**
- **Nothing has been seen on a device or simulator.** I must not launch the app. The iOS build
  succeeds (below). The view row was hosted and clicked offscreen.
- **A failed build still opens Settings without a pop-up** (#10). Its fix is unknown to the app, and
  Exit retries it.
- **Core's heat maps are not shown in the Export step** (#11). They are SVG files.
- **Core still cannot run a pinch or several squeeze groups** (core brief #1, #2, #6). The buttons
  send what it can: one end resting, or one group.
- **The render defects from B** (seam speckle, the flap, the torn side face) are batch G's.
- **#354's latent Surface / Settings overlap** (4b11beb3) is carried over.

**Your call:**
- A "send with one end resting" answer is core's design for THAT job, not for your pinch. Should
  the step show both ends' answers side by side?
- [Use colorFabb varioShore TPU] changes your filament in one tap. Should it open Settings on the
  filament row instead?
- C2's three questions still stand: "Tap to open" from Topology still opens Settings; only the
  Lattice button's Exit turns the view on; the note shows for 4 s (now beside the row).

### Hook lines in #354 files (this pass)

| hook | file · anchor | ± | why |
|---|---|---|---|
| H10' | WorkspacePlaceholder · `if project.lattice.flexible == nil { latticeThisButton } else { FlexibleMainStatusPill(main: flexibleMain, open: { if stage != .lattice { goToStage(.lattice) }; showFlexiblePage = true }` | 1 line edited (+0 −0 lines) | appends `, goToLattice: { if stage != .lattice { goToStage(.lattice) } })`, so "Building…" on another stage goes to the Lattice stage, and so does a Ready whose lattice your edits there made stale. No Settings. |

WorkspacePlaceholder in this pass: `git diff --numstat` 1 1 (one line edited). H5, the Export mount,
`requestLatticeRun`, `startStressSolveIfNeeded` (its first 900 characters) and every other pinned
string are untouched. MetalMeshView, LatticeSettings, ProjectModel and LatticeStageMode are
untouched. No case was added. core/ is untouched.

New file: `FlexibleCoreHold.swift` (the rule: what core can't take, and what it can). Edited track
files: `FlexibleCoreRun.swift`, `FlexibleExportSheet.swift`, `FlexibleMainLatticeView.swift`,
`FlexibleMainStage.swift`, `FlexibleMainStatusPill.swift`, `FlexibleStageModel.swift`
(`runJobJSON(resting:)`, `.noPart`), `FlexibleJob.swift` (`EncodeError.noPart`).

### Decisions (00-decisions.md)

- New rows: D-R4-24 (the pill never promises what core will refuse: the preview tone and the
  step's 1–3 buttons), D-R4-25 (Ready sends what you set now; "Building…" on another stage goes to
  the Lattice stage), D-R4-26 (the note beside the row; the wait said once).
- D-R4-22 and D-R4-23 are amended to point at them.

### Tests

Written FIRST and run RED against C2's code, with stubs of the new API that keep C2's behaviour
(`c2v/red1_keep.log`): **11 of 11 failed, 94 failures** — `Executed 11 tests, with 94 failures (0
unexpected) in 32.638 (32.639) seconds`. The two hosted tests failed on C2's note under the row
and on a click on the note's icon.

NEW: `FlexibleMainPageRound4VerifyTests` (9):
- **Ready on another stage** (his project, Face 5 resting, the "Top" group 10 → 20 kg on Topology):
  nothing sent, taken to the Lattice stage, the model has 20 kg, stale; there it rebuilds, Ready,
  and the job core receives carries 20 kg.
- **"Building…" off the Lattice stage**: it goes there. Control: on the Lattice stage it goes
  nowhere. Also the real case: Exit, then ‹ Topology while the designs are in flight.
- **The hold rule as values**: one pinch, two pinches, two groups, a group with a pinch inside,
  four groups (3 buttons), the order, the pill's line ≤ 44 characters, the preview fill ≠ the
  Ready green (control: Ready IS the green).
- **His pinch**: a preview, the named line, two buttons; each end sent and answered (core's parser
  reads the pressed faces); his settings unchanged; the answer stands on a second tap; the first
  run's temp folder deleted; no path behind the (i).
- **Two groups (img 4)**: a preview; both groups offered; each button's job parsed by core; Group 2
  sent and answered.
- **TPU 95A**: a preview with his label; not sent; core's catalogue sentence behind the (i).
  POSITIVE CONTROL: core's own runner, asked directly, refuses this job with the same code and
  sentence. [Use colorFabb varioShore TPU] → the step closes, the lattice rebuilds, Ready, sent,
  designed.
- **A part with no file**: `.noPart`, its own line (control: ≠ "press a face first").
- **The note beside the row** at 13l / 13p / 11l / 11p / 820 / 744 pt, with and without the chip
  column: on the row's line, left of it, clear of the left panel. No legend leaves the trailing
  column. Where batch C's row-only keep-out held them all there, every frame is identical. RED
  CONTROL: C2's band under the row, at 13l with 222 pt of chips, puts Stress and Lattice at
  x 844.
- **The Export step's source**: the wait line once and not in `card(`; no raw colours; the fix
  buttons; no `MainActor.run { guard let self` in the run.

Re-pinned, each with its reason in the test:
- `FlexibleMainPageRound4Tests`: the pill's source (`goToLattice`); the pinch's line names the
  faces; TPU 95A is a preview and is not sent (core's own runner gives the one-line refusal);
  `testTheNoteBandIsReservedUnderTheViewRow` → `testTheNoteBandIsReservedBesideTheViewRow`; H10.
- `FlexibleMainPageRound4HostedTests`: `testTheRowAndTheNoteSitInTheirReservedFrames` →
  `testTheRowAndTheNoteSitSideBySideInTheirFrames` (beside the row, clear of the left panel;
  control: not in C2's band); the note's [Show] is clicked on its icon.
- `FlexibleMainPageHookTests` (H10).
- `FlexibleMainStageTests` and `FlexibleBatchBReviewTests`: his pinch rebuilt, and TPU 95A, are a
  PREVIEW pill, not the green Ready.

Deleted-test sweep of this pass (`git diff 38963bbe..HEAD -- app/TopOptKit/Tests`): no test
deleted. Two were renamed with their re-pin (above); 9 were added.

Mutation runs. Each breaks one rule, rebuilds, runs the test that pins it, then restores the file
from git (`git status` clean afterwards). All 12 are RED:
```
V1  Ready sends without catching up (C2)          ⇒ ("1") is not equal to ("0") - the job from before his edit is never sent (8)
V2  Building… off-stage stays put (C2)            ⇒ ("0") is not equal to ("1") - off the Lattice stage: the tap goes there (3)
V3  the pill ignores the hold                     ⇒ ("ready") is not equal to ("preview") - never the green Ready while core can't take it (2)
V4  a calibrate-first filament not held           ⇒ ("ready") is not equal to ("preview") - not the green Ready (5)
V5  the step ignores the hold (C2's bare line)    ⇒ ("Not sent: core can't press both ends yet") is not equal to (… Face 3 and Face 5 at once) (2)
V6  a fix's resting faces ignored                 ⇒ ("0") is not equal to ("1") — nothing reached core (2)
V7  the previous temp folder kept                 ⇒ the previous run's temp folder is deleted (1)
V8  a group's own pinch not rested                ⇒ (["Send Group 1 only"]) is not equal to ([… "Send Group 2 only, Face 5 resting"]) (2)
V9  the note back under the row (C2)              ⇒ ("303.5") is not equal to ("255.5") — on the row's line (23)
V10 only the word "Show" is the target (C2)       ⇒ [Show] shows the lattice (2, hosted click on the icon)
V11 no file says "press a face first" (C2)        ⇒ (Mark at least one face …) is not equal to (The part's file is missing …) (2)
V12 the pill's hold blind to squeeze groups       ⇒ ("Preview · core can't pinch yet") is not equal to ("Preview · core runs one group at a time") (2)
```

Raw lines (the green run):
```
FLEX-C2V TPU 95A: pill 'TPU 95A: shape only — no squish predicted' tone preview · step 'Not sent: TPU 95A has no squish data yet' · button [Use colorFabb varioShore TPU] · core's own runner: calibrate_first
FLEX-C2V V1 designing at Exit true building false · off-stage 2 s: lattice false building false · pill 'Building…' tap wait
FLEX-C2V pinch: pill 'Preview · core can’t pinch yet' tone preview
FLEX-C2V pinch: step 'Not sent: core can’t press Face 3 and Face 5 at once' · (i) 'A pinch is the app's preview for now: core designs one squish profile per stack.' · buttons ["Send with Face 5 resting", "Send with Face 3 resting"]
FLEX-C2V pinch: [Send with Face 5 resting] → 'Core designed it · Face 5 resting · Gyroid · 240 °C · 3 faces' · (i) 'Core wrote its receipt, heat maps and CSVs (21 files). It designs the density, not the printable file yet.'
FLEX-C2V V4 group 92E96F3A-D8F7-4FB0-AF8D-56230DFB6BC0: 10.0 → 20.0 kg on Topology · tap Ready → runs 0 · to the Lattice stage 1× · note Optional(TopOptFlows.FlexibleMainNote.Kind.building) · face 1000103 10.0 → 20.0 kg · stale true · pill 'Building…'
FLEX-C2V V4 sent: face 1000103 weight_n 98.06649999999999 → 196.13299999999998 · core 'Core designed it · Gyroid · 240 °C · 3 faces'
FLEX-C2V note 13l chips 222.0: note (928.0, 235.0, 280.0, 41.0) · legends ["dent (1104.0, 294.0, 248.0, 124.0)", "lattice (1104.0, 566.0, 248.0, 124.0)", "stress (1104.0, 430.0, 248.0, 124.0)"]
FLEX-C2V note 11l chips 222.0: note (746.0, 235.0, 280.0, 41.0) · legends ["dent (922.0, 355.0, 248.0, 124.0)", "lattice (662.0, 491.0, 248.0, 124.0)", "stress (662.0, 355.0, 248.0, 124.0)"]
FLEX-C2V note control 13l chips 222 with C2's under-row band: ["dent (1104.0, 454.0, 248.0, 124.0)", "lattice (844.0, 590.0, 248.0, 124.0)", "stress (844.0, 454.0, 248.0, 124.0)"]
FLEX-C2V groups: ["Group 1 · Top A + Top B · Squeeze 10 kg", "Group 2 · Face 3 + Face 5 · Squeeze 10 kg"] · pill 'Preview · core runs one group at a time' · buttons ["Send Group 1 only", "Send Group 2 only, Face 5 resting"]
FLEX-C2V groups: [Send Group 2 only, Face 5 resting] → 'Core designed it · Group 2 only, Face 5 resting · Gyroid · 190 °C · 1 face'
```

The targeted suite ran on the committed tree (d85a8bb0), after the mutation runs. Its filter is
built from CLASS names (`c2v/filter.txt`, 157 classes): every class in a Flexible* file, the
brief's list, and every class in a file that mentions WorkspacePlaceholder. That includes the 10
the C2 filter missed, and AppModelTests, which brings in its three known 3MF failures. Raw:
```
Executed 1043 tests, with 15 tests skipped and 9 failures (0 unexpected) in 1662.039 (1662.132) seconds
  failing cases (all known, pre-existing):
  AppModelTests testReopenedThreeMFProjectReimportsTheStlWorkingCopy
  AppModelTests testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance
  AppModelTests testThreeMFImportOptimisesOnDeviceEndToEnd
  LatticeSimSolveTriggerTests testTheTriggerRefusesOnAllThreeGrounds
Test Suite 'GroupViewEnforcementTests' passed … 'SurfaceStageNoRegressionTests' passed … 'TransformGizmoTests' passed
```

**iOS build (the committed tree, d85a8bb0):** `xcodebuild -project app/TopOpt.xcodeproj -scheme
TopOpt -configuration Debug -destination id=147E56A1… -derivedDataPath …/flexA1 build` → `** BUILD
SUCCEEDED **` (exit 0), with no warning in any file this pass touched. The SwiftPM build shows no
warning in them either (C2's `FlexibleCoreRun.swift:168` Swift 6 warning is gone). The app was not
launched.

### Commits (on claude/flexible-screens, not pushed)

61daa708 the verification fixes and their tests · d85a8bb0 the pill's preview tone has ONE source,
the hold · (this handoff + DECISIONS D-R4-24 … 26, D-R4-22 / 23 amended).

## Round 4 · batch C2 — the main Flexible page

Your notes on the main page after testing batches A + B (img 5, img 6) and your answer 2, built on
the main Flexible page. Judged headlessly on the pad and on YOUR project 0004 restored through
`AppModel.open`; the view row was hosted offscreen at 11" and 13" in both orientations and
clicked. The app was NOT launched, so none of this has been seen on a screen yet.

**What you will see on the main Flexible page:**
- **No X-ray button** (img 5). The view row under the gizmo is **[Dent heat] [Stress] [Lattice]**.
  X-ray is now simply how the Lattice view draws:
  - Lattice shown: the part is the X-ray ghost with the walls inside (as before).
  - Lattice hidden: the solid part, with the dent heat or the stress on it.
  - The two can no longer disagree (before: X-ray off hid the walls while the Lattice button
    stayed on; X-ray on with Lattice off was an empty ghost).
  - Dent heat, Stress and Lattice keep their legends and tap-to-read, unchanged.
- **The Lattice button shows or hides the lattice** (your answer 2).
  - It is lit only when there is a lattice to show: one drawn, or one on its way without
    Settings (building, or its designs in flight).
  - **With nothing that can come** (no pressed face, no filament, a failed build), a tap opens
    Settings, with the one thing to fix popping up as it does today. **Save & Exit then turns the
    view on**: the lattice builds and shows.
  - An Exit that did not come from the Lattice button keeps your choice (a lattice you hid stays
    hidden).
- **"Lattice ready"** (your answer 2: "a notification should show up when it is ready"). When a
  build lands, a one-line note appears under the view row for 4 seconds: "✓ Lattice ready". If
  you had hidden the lattice it adds **[Show]**. It shows once per build (after Save & Exit, after a
  main-page edit that rebuilds), never when you merely come back to a lattice that was already
  there. Its place under the row is reserved, so a note coming and going never moves a legend.
- **The big bottom Lattice button** (img 6, your answer 2):
  - **"Lattice · Ready" → Send to core and the Export step.** It no longer opens Settings (img 6:
    "When I clicked Lattice after already having a lattice preview, it brought me to the
    settings page"). While core runs, the pill reads "Sending to core…"; the Export step is
    already open.
  - **"Lattice · Fix: …"** still opens Settings on that fix's pop-up.
  - **"Lattice · Building…"**: nothing opens; the note under the view row says "Still building —
    it shows here when ready".
  - From another stage (Topology, Surface) the same rules hold; "Tap to open" (the stage not yet
    opened this session) goes to the Lattice stage and Settings, as before.
- **The Export step** (the modal you asked for in round 1: "export gcode or an stl"):
  - Its top line is core's answer, ONE line, core's whole sentence behind the (i):
    - on your pad (top pressed, varioShore): **"Core designed it · Gyroid · 240 °C · 1 face"**,
      in 0.21 s;
    - on your project with Face 5 resting: **"Core designed it · Gyroid · 240 °C · 3 faces"**;
    - on your project as saved (faces 3 and 5 pinch the pad): **"Not sent: core can't press both
      ends yet"** — core designs one squish profile per stack; the pinch is the app's preview
      (D2). Several squeeze groups: "Not sent: core runs one squeeze group at a time";
    - a calibrate-first filament (TPU 95A on your pad): **"Core refused it: no squish data for this
      filament yet"**. Core's own sentence names five brands, so it goes behind the (i); the known
      refusal codes each have a short line, anything else shows core's first sentence.
  - The (i) says where core wrote its receipt, heat maps and CSVs (21 files on your project).
  - **STL** and **G-code** stay disabled, each with ONE line: **"Waits on core's Flexible
    exporter"**. Core's Flexible runner designs the density; it writes no printable file yet.
  - The same job is not sent twice: tapping Ready again reopens the step with core's answer.

**How it is routed (what I found):**
- **The other sections' Lattice button:** `requestLatticeRun` → `model.makeLatticeRunRequest()`
  → `RunModel.start` → `latticeBridgeRunner` writes `lattice_job.json` beside the part and calls
  `TopOptKit.runLatticeJob` → the bridge's `run_lattice_job` → core's `lattice_variant_job`,
  output in a temp folder → the results screen and its exports. On a Mac worker, the job document
  goes to the worker's `run`.
- **Core C1 does NOT run a Flexible job on that path.** The bridge's `run_lattice_job` takes only
  `lattice_part` / `lattice_variant` (the Flexible document says `analyze`), and core's
  `run_job`, `analyze_job`, `lattice_variant_job` and `preflight_job` each call
  `refuse_flexible_job`: "… this job carries a "flexible" block, which runs with `topopt-cli
  flexible`". The test sends your pad's Flexible job down the other sections' path as its
  control: `run_lattice_job: mode must be "lattice_part" or "lattice_variant" (got "analyze")`.
- **Core's one entry point is `run_flexible_job`** (`core/src/flexible/run.cpp`, the
  `topopt-cli flexible` subcommand). It is in the always-built library the iPad already links (the
  symbol is in all three xcframework slices). The app's bridge now calls it
  (`flexible_run_job` in `flexible_bridge.cpp`, app side; core untouched).
- So Ready sends the SAME document the Settings page encodes (`FlexibleStageModel.runJobJSON`,
  round-trip tested against core's `parse_job`), with the part's folder as the job dir and the
  output in a temp folder (the lattice path's rules), off the main thread. `RunModel`,
  `RunRequest`, `requestLatticeRun` and the results screen are untouched, so Structural and
  Aesthetic run exactly as before.

**Not done (and why):**
- **Nothing has been seen on a device or simulator.** I must not launch the app. The iOS build
  succeeds (below); the view row was hosted and clicked offscreen.
- **No STL or G-code.** Core's Flexible runner writes receipts, heat maps and CSVs, not a mesh
  (core's C2/C3 exporter; core brief #9, #16). The cards say so in one line.
- **Not on a Mac worker.** The worker runs `run` jobs, which refuse the Flexible block. The
  Flexible run is on this device only (0.2 s on your pad).
- **Core cannot run a pinch or several squeeze groups** (core brief #1, #2, #6). Those projects
  say "Not sent: …" instead of sending a job core would refuse.
- **Core's receipt is not shown in the app** beyond the one line (the heat maps are files in a
  temp folder). Showing core's heat maps next to the preview's is a later step.
- **The render defects from B's renders** (the seam speckle, the flap past a pressed side wall,
  the torn side face) are untouched: C2 does not draw the dent or the walls. Batch G's
  displacement field replaces the per-column squish.
- **The note is not shown on other stages.** It sits under the view row, which only the Lattice
  stage has; the pill's own line says "Building…" / "Ready" there.
- Carried over: #354's latent Surface / Settings overlap (4b11beb3).

**Your call:**
- **"Tap to open" from Topology still lands in Settings** (the stage has not opened your part yet
  this session, so it cannot know whether it is set up). Should it go to the Lattice stage only,
  and open Settings only if something is missing? (One more line in #354's bottom-bar hook.)
- **Save & Exit turns the view on only after the Lattice button sent you there.** Should every
  Exit that rebuilds the lattice show it?
- **Where the "Lattice ready" note sits:** under the view row, beside the Lattice button that
  shows the lattice, for 4 seconds. The app's usual toast is bottom-centre, where the squish
  player is. Say if you want it there instead, or longer.

### Hook lines in #354 files

| hook | file · anchor | ± | why |
|---|---|---|---|
| H5'' | WorkspacePlaceholder · `if flexibleMain.owns(project, stage) { FlexibleMainViewToggles(main: flexibleMain, solver: FlexibleStressSolver(app: model, sim: latticeSim)` | ~1 | `, openSettings: { showFlexiblePage = true })`: the Lattice button, with nothing to show, opens Settings |
| X1 | WorkspacePlaceholder · after the `FlexibleStagePage(…)` mount's `.transition(.opacity).zIndex(48)` block | +1 | `if project.lattice.flexible != nil { FlexibleExportMount(run: flexibleMain.coreRun).zIndex(48) }`: the Export step, on any stage |

WorkspacePlaceholder in C2: `git diff --numstat` 2 1 (one line edited, one added). H10 (the pill's
mount) is NOT edited: the pill's own body decides what a tap does. `requestLatticeRun`,
`startStressSolveIfNeeded` (its first 900 characters, pinned) and every other pinned string are
untouched. MetalMeshView, LatticeSettings, ProjectModel and LatticeStageMode are untouched; no
case was added.

App-side bridge (#362's own files, not core): `FlexibleBridge.hpp` +19 (`FlexRunResult`,
`flexible_run_job`), `flexible_bridge.cpp` +26 (the call into core's `run_flexible_job`),
`FlexibleKit.swift` +30 (`FlexRunInfo`, `FlexibleCore.runJob`).

New files: `FlexibleCoreRun.swift` (the run, its report, the pill's tap rule),
`FlexibleMainLatticeView.swift` (the view rule, the note, the Lattice button, the pill's tap).
Edited track files: `FlexibleMainStage.swift` (X-ray derived, availability, the note's trigger,
Exit shows the view), `FlexibleMainStatusPill.swift` (three buttons, the note under them, the
reserved band, the pill body), `FlexibleExportSheet.swift` (core's line, one line per card, the
mount).

### Decisions (00-decisions.md)

- New rows D-R4-20 … D-R4-23: no X-ray button; the Lattice button (and Exit shows the view); the
  "Lattice ready" note; Ready sends to core's Flexible runner and opens the Export step.
- D-R3-11 is amended: the pill no longer opens Settings when Ready.
- D-R3-15 is amended: "[X-ray]" struck from the view row.

### Tests

Written FIRST and run RED against stubs of the new API (`c2/red1.log`, before any hook): **11 of 11
failed** — the X-ray button still there, the Lattice button a bare toggle, no note within 5 s of
the build, the pill opening Settings when Ready, nothing sent to core, no "Not sent" line, no
reserved band, the hooks absent.

NEW:
- `FlexibleMainPageRound4Tests` (12): the row has no X-ray; X-ray == the Lattice view (the body's
  alpha follows it); on the pad with nothing pressed the Lattice button opens Settings and Exit
  shows the lattice (built, walls drawn), then it hides / shows and never opens Settings; the
  "Lattice ready" note once per build, [Show] when hidden; the pill's tap rule; Ready sends the
  pad's job to core's runner (0.21 s, 9 files, run_info.json, `face1_density.svg`) and the same job
  is not sent twice; your project as saved says "Not sent" and nothing reaches core, with Face 5
  resting it is sent (core designs 3 faces); TPU 95A is core's refusal in one short line; every
  "Not sent" line ≤ 56 characters; the export step's source; the reserved note band at 11" / 13";
  the two hook lines.
- `FlexibleMainPageRound4HostedTests` (2, hosted and CLICKED, added after the first green run): the
  three buttons fill their slot (136 pt wide, no X-ray) and the note — both its forms, [Show]
  included — lies inside its reserved band at 11" and 13", both orientations; clicking Lattice
  hides / shows it, and with nothing to show opens Settings; Exit shows the view; the note's
  [Show] shows it.

Inline RED controls:
- a bare toggle (batch C's button) shows nothing when there is no lattice;
- the other sections' runner refuses your pad's Flexible job: `run_lattice_job: mode must be
  "lattice_part" or "lattice_variant" (got "analyze")`;
- a stage that did not see the build posts no note (the note is keyed on the build);
- batch B's pill body (Settings on every tap) is gone from the source;
- the row-only frame (batch C's keep-out) does not hold the note, source and hosted;
- core's calibrate-first sentence is over 80 characters (why it goes behind the (i));
- with the pinch undone the same tap reaches core (the "nothing sent" counter can move).

Re-pinned, each with its reason in the test:
- FlexibleBatchBReviewUXTests.testTheLatticeViewTurnsXRayOn: no X-ray button; the button shows
  what is drawn (control: `latticeAvailable` false leaves it unlit while `latticeOn` is true).
- FlexibleMainViewsTests: "X-ray off" is now the lattice hidden (`latticeOn = false`).
- FlexibleMainPageHookTests (H5), FlexibleBatchCHookTests (H5'): the `openSettings` closure.

Deleted-test sweep of my diff (`git diff c0a7ff42..HEAD -- app/TopOptKit/Tests`): none deleted; 14
test functions added.

Mutation runs. Each breaks one rule, rebuilds, runs the test that pins it, then restores the file
from git (`git status` clean afterwards). All 10 are RED:
```
M1  X-ray independent of the Lattice view      ⇒ ("true") is not equal to ("false") "X-ray is the Lattice view's rendering" (2)
M2  the Lattice button a bare toggle           ⇒ ("0") is not equal to ("1") "nothing set up: the tap opens Settings" (3)
M3  availability ignored                       ⇒ "no lattice can come without Settings" (8)
M4  Exit does not turn the view on             ⇒ "Exit turned the view on" (9)
M5  no note when a build lands                 ⇒ "timed out waiting for the note" (6)
M6  a note on every refresh with a lattice     ⇒ ("3") is not equal to ("1") "once per build, not per refresh" (3)
M7  the pill opens Settings when Ready         ⇒ "a ready lattice never opens Settings" (8)
M8  the same job sent to core twice            ⇒ ("2") is not equal to ("1") "the same job is not sent twice" (1)
M9  the note band not reserved                 ⇒ "the note band is inside the reserved frame at 13l" (5)
M10 a pinch sent to core                       ⇒ "not sent: sending" (1)
```

Raw lines:
```
FLEX-CORE pad: 'Core designed it · Gyroid · 240 °C · 1 face' in 0.21 s · files 9: ["face1_target_depth.svg", "face1_columns.csv", "face1_buildable_depth.svg", "face1_density.svg", "face1_cell_size.svg", "face1_tier_flags.svg", "field_xz_density.svg", "field_xz_owner.svg"] …
FLEX-CORE control: the other sections' runner says 'run_lattice_job: mode must be "lattice_part" or "lattice_variant" (got "analyze")'
FLEX-CORE his project as saved: 'Not sent: core can’t press both ends yet' · (i) 'A pinch is the app's preview for now: core designs one squish profile per stack.'
FLEX-CORE his project, face 5 resting: 'Core designed it · Gyroid · 240 °C · 3 faces' · (i) 'Core’s receipt, heat maps and CSVs (21 files) are in …/T/flexible-7CA37B9B-…. It designs the density, not the printable file yet.'
FLEX-CORE TPU 95A: 'Core refused it: no squish data for this filament yet' · code calibrate_first · (i) 'TPU 95A (Bambu 95A HF, Polymaker PolyFlex TPU95, eSUN, Elegoo ...) has no lattice squish data. It can be built, but no squish is predicted unti…'
FLEX-NOTE 11l: row+note (870.0, 235.0, 300.0, 83.0) · note (870.0, 283.0, 300.0, 35.0) · legends ["dent (922.0, 331.0, 248.0, 124.0) open", "lattice (922.0, 603.0, 248.0, 124.0) open", "stress (922.0, 467.0, 248.0, 124.0) open"]
FLEX-HOSTED 11l ready: drawn [(1034.0, 235.0, 136.0, 41.0), (996.0, 283.0, 174.0, 35.0)] · row slot (1034.0, 235.0, 136.0, 41.0) · note band (870.0, 283.0, 300.0, 35.0)
FLEX-HOSTED 11l building: drawn [(1034.0, 235.0, 136.0, 41.0), (870.0, 283.0, 300.0, 35.0)] · row slot (1034.0, 235.0, 136.0, 41.0) · note band (870.0, 283.0, 300.0, 35.0)
```
(at 11" landscape the three legends still open in one column: 331–727, above the bar at 740.)

The targeted suite: every Flexible* suite (both new ones included), the brief's list, and every
suite that scans WorkspacePlaceholder (D2's filter, `c2/filter.txt`). It ran on the committed tree
after the last source change and after the mutation runs. Raw:
```
Executed 777 tests, with 10 tests skipped and 1 failure (0 unexpected) in 827.484 (827.552) seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
```

**iOS build (the committed tree):** `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt
-configuration Debug -destination id=147E56A1… -derivedDataPath …/flexA1 build` → `** BUILD
SUCCEEDED **` (exit 0), no warning in a file C2 touched. The app was not launched.

### Commits (on claude/flexible-screens, not pushed)

15d915aa the app's bridge reaches core's own Flexible runner · 140c8d45 the main Flexible page (no
X-ray button, the Lattice view button, "Lattice ready", Ready → core and the Export step) · (this
handoff + DECISIONS D-R4-20 … 23, D-R3-11 / D-R3-15 amended).

## Round 4 · batch D2 — verification pass

The D2 verifier reported 20 findings: 1 blocker, 10 majors and 9 minors. Two of them are the same
pinched-face warning, seen from the code side and from the screen side. I checked each one on YOUR
project 0004, restored through `AppModel.open`, and fixed every blocker and major and the cheap
minors. The Settings page was hosted offscreen at 11" and 13" in both orientations and clicked.
The app was NOT launched, so none of this has been seen on a screen yet.

**What changes for you on the Settings page:**
- **Each squeeze group is now a header in the face list, with its force in its pill.** It reads
  "● Group 1 · Squeeze [10 kg ✎]" (with × and (i)), and the group's faces are listed under it.
  Resting faces come after the groups. With one pressed face the header just says "Squeeze".
  - D2's single line ("Group 1 · Top A + Top B · Squeeze 10 kg") was cut at the force on every
    iPad. It was drawn 125–143 pt wide where the words need 248–261 pt, so it read "…Squ…".
  - The new header is drawn whole: 114 of 114 pt at all four sizes (measured).
- **The group you are working on is on the panel.** After + New, the new group's header and its ×
  sit right above the open face, at all four iPad sizes. In landscape, D2's group section started
  at y 958 (11") and y 1091 (13"), below the panel's bottom edge at 796 and 994.
- **The card no longer has its own "10 kg ✎".** That pencil changed the whole group's force, and
  the main page's Load group, without saying so. The force now has ONE control: the header's pill.
  The card shows the face's own weight only where it differs from the group's force, for example
  "5 kg of Top's 10 kg" when the main page's Top covers both top sectors. The card's dot is now
  its group's colour (Face 5 in Group 2 is blue, not green).
- **Before you Exit, a group that will squish less than you drew says so.** On your pad, with the
  sides in Group 2:
  - the top line reads "Ready · Group 1 squishes ~0.3 of 2.6 mm · firmer wins" in orange, with
    [Fix];
  - the move that caused it opens the pop-up. It selects Top A and says "Group 1 would squish ~0.3
    of 2.6 mm: Group 2 needs firmer material", with [Join the groups] and [Keep apart];
  - Group 1's header adds one line: "Squishes ~0.3 of 2.6 mm · Group 2 firmer".
  The estimate comes with the designs, column by column, using the same rule as the build. It
  gives 0.331 mm; the built lattice gives 0.330 mm. The pop-up opens once per new miss, and never
  just because you opened the page.
- **A pinched face's warning counts its two halves.** Face 3 now says "Can't reach your curve on
  412 columns" and Face 5 says 476. Both said 832 before, which was core's figure for the whole
  column. The lattice is built from the halves.
- **Top + Bottom pinched: the two heat maps no longer cross.** The drawn dent's exaggeration is
  now ×2 (it was ×4, which drew both maps 12 mm into your 20 mm pad). The depth chip and the
  Deepest-squish pad stop at the half its design uses: 10 of 20 mm on Top A.
- **Removing a group gives its faces the other group's force.** D2 left "Squeeze 6–10 kg", and the
  next face you pressed then asked for the number pad.
- **Undo and redo on this page keep the group's force right.** D2 kept the undone weight: the line
  read "Squeeze 10–12 kg" and the pad offered 12. The redo still works after an undo.
- **A main-page Load group is one hand, so its faces move together.** If the main page's Top covers
  Top A and Top B, "+ New" on Top B takes Top A with it. "+ New" is not offered when that hand is
  the whole group. So setting one group's force no longer changes another group's through the
  main page (D2: "Group 1 · Squeeze 4–10 kg").

**What changes on the main page:**
- **The player's group picker "[● Group 1 ▾]" and its one-line note now sit in a row above the
  play bar.** The timeline you drag stays at least 121 pt wide at every iPad size. D2 put the
  picker inside the bar; at 11" portrait, in the same 294 pt bar, that left the timeline 4 pt
  (hosted measurement). The picker is now outside the bar's 30 Hz redraw.
- **"All at once" shows the note too**, for example "Group 1 squishes 0.3 of 2.6 mm · firmer
  wins".
- **With five pressed faces, the animation never splits a pinch.** The animation can squish at most
  four faces. With the bottom pressed as well, D2 squished Face 3 while Face 5 stood still. Now
  the top and bottom squish together, and the line says "Squish shown on 3 of 5 faces · pinches
  whole". Picking Group 2 squishes Face 3 and Face 5 together.

**Also fixed (you will not see these):**
- If one face's two-half design fails, the other faces keep theirs. That face keeps core's single
  design for now, and its card says "Pinched with Face 5 · one profile for now".
- A face that the main page rests, then presses again, no longer lands in a leftover "Group 2" that
  nobody made.
- The combined lattice field is no longer kept in memory after a build. At 128³ it is about 24 MB,
  and only tests read it.
- The run-job encoder itself now refuses a pinch (`FlexibleJob.Inputs.pinches`), not only the
  model.

**Not done (and why):**
- **Nothing has been seen on a device or simulator.** I must not launch the app. The iOS build
  succeeds, and offscreen renders of the Settings page are in the scratchpad (`e2/out/`).
- **The part does not show which face is in which group while its heat map is drawn.** The map
  covers the face, so the colour is on the list, the headers and the card only. Outlining each map
  in its group colour needs an edge pass in the overlay. Not done.
- **Group colours 3 and 4 stay orange and red. I rejected this finding.** They come from DS's own
  face-group palette (`DS.Color.groupPalette`: red, blue, green, orange, purple), which the main
  page's groups already use; the squeeze palette is that palette without purple. The only other
  tokens that are not purple are cyan, which is the Rests dot, and blues too close to Group 2's.
- **The rendering defects on a pinch (the flap past a pressed side wall, the torn side faces) stay
  for batch G's displacement field**, as D2 said.
- **With five faces, three are animated** ({bottom, Top A, Top B}; {3, 5} does not fit beside
  them). Four slots is a limit in the shader. Raising it would change the pass's texture slots.
- **The Settings page's own player has no group picker.** It plays your drawing, every face at
  once. **"Play all" still plays the groups together**, not one after another.
- **Where a pinch's two halves meet is still the middle of the column** (core brief #6). **The
  "~0.3 mm" is an estimate** (core brief #4).
- **At 11" portrait the timeline is 121 pt**, just over the 120 pt minimum the test enforces.

**Your call:**
- The "Group 1 would squish ~0.3 of 2.6 mm" pop-up opens once, on the move that caused it, with
  [Join the groups] [Keep apart]. Is once enough, or should it come back at Exit?
- One hand moves as one: moving Top B out of the main page's Top group's squeeze group takes Top A
  along. Should a single face be able to leave its main-page group instead? (Its weight would then
  become its own.)
- With one pressed face, the header reads just "Squeeze [10 kg ✎]", with no "Group 1".

### Each finding, confirmed on the code → what changed
| # | Finding | Verdict | Fix (file) | Pinned by |
|---|---|---|---|---|
| C1 | remove leaves two forces | CONFIRMED (V1: "6–10 kg", pad asked) | `mergeGroup` takes the target's force (FlexibleStageModel+Groups) | Review · testRemovingAGroup… (E1 RED) |
| C2 | Settings undo shows a stale force | CONFIRMED (V6: "10–12 kg") | `FlexibleStagePage.history` re-reads the loads (no edit); hands read the project live | Review · testTheSettingsPageUndo… (E2 RED) |
| C3 / U4 | pinched warning = whole column | CONFIRMED (832 vs 412 / 476) | `FlexibleFaceRows.warning` counts `segments[k].status`; the showBuildable branch reads the halves | Review · testAPinchedFacesWarning… (E3 RED) |
| C4 | a main-page hand across two groups | CONFIRMED (V2: "4–10 kg") | a hand moves whole (`FlexibleSqueezeGroups.hand`, `move(hand:)`, `uniteHands`); "+ New" only outside the hand; handoff D2 bullet corrected | Review · testAMainPageHandMoves… (E4 RED) |
| C5 | adopt keeps a stale group id | CONFIRMED (V4: a "Group 2" nobody made) | `FlexibleStageModel.adopt` = adopt + `uniteHands` (normalises) | Review · testTheMainPageResting… (E5 RED) |
| C6 | one throw drops every pinch | CONFIRMED (one do/catch) | per-face catch, `segmentErrors`, "one profile for now" | Review · testOneFacesThrow… (E6 RED) |
| C7 | 24 MB field kept for tests | CONFIRMED | `keepCombinedField` (test only) | Review · testTheCombinedField… (E7 RED) |
| C8 | static runJobJSON sends a pinch | CONFIRMED | `Inputs.pinches`, `.pinch` thrown in the encoder | Review · testTheStaticRunJob… (E8 RED) |
| U1 | group line cut at the force (BLOCKER) | CONFIRMED (hosted: 125/261 pt) | headers in the list, force in the pill (`FlexibleSqueezeGroupHeader`, `FlexValuePill`) | ReviewUI · testTheGroupHeadersAreWhole… (E16 RED; D2's line in place: cut at all 4 sizes) |
| U2 | firmer-wins learnt after Exit | CONFIRMED | `FlexibleGroupEstimate` with the designs; readiness `.groupsCompete`; pop-up on the action; header line; "All at once" note | ReviewUX · testSeparateGroupsSayTheMiss… (E9/E10/E11 RED) |
| U3 | groups below the fold | CONFIRMED (11l/13l) | headers in the list; the reveal follows a group move | ReviewUI (the old place is below the fold at 11l and 13l) |
| U5 | card's "10 kg ✎" moves the group silently | CONFIRMED | no force control on the card; `weightLine` only for a share; Info.weight | ReviewUX · testTheCardSaysOnly… (E14 RED) |
| U6 | 5+ faces: one-sided pinch | CONFIRMED (squished [0, A, B, 3]) | `squishSlots` keeps a pinch whole; `squishFaces` to the pass; readiness line | ReviewUX · testThePassSlots…, testFivePressedFaces… (E12 RED) |
| U7 | Top + Bottom dents cross | CONFIRMED (k 4, 468 columns cross) | `effectiveLattice` halves pinched columns: thinCap, prismCap, dragLimit, latticeMax | ReviewUX · testATopAndBottomPinch… (E13 RED) |
| U8 | 11" portrait timeline ~32 pt | CONFIRMED (hosted: 4 pt) | picker + note in a row above the capsule; `minTimeline` 120 | ReviewUI · testTheTimelineKeeps… (E17 RED) |
| U9 | groups not on the model; card dot green | card dot CONFIRMED and fixed; the model tint NOT done | `FlexibleFaceRows.dot` | ReviewUX (E15 RED) |
| U10 | orange / red group colours | REJECTED | DS's own group palette minus purple (see above) | — |
| U11 | pinch render defects | disclosed, batch G | — | — |
| U12 | (a) how to make a group (b) Settings player (c) Menu in the TimelineView | (a) fixed in Info.groups; (b) not done; (c) fixed — the picker is outside the TimelineView | FlexibleRowCopy, FlexibleSquishPlayer | — |

### Hook lines in #354 files

None. `git diff HEAD --stat` touches no #354 or main file: WorkspacePlaceholder, MetalMeshView,
LatticeSettings, ProjectModel and LatticeStageMode are untouched, and no case was added. Every
edit is in a Flexible track file:
- New: `FlexibleGroupEstimate.swift` (+123).
- Edited (+/−):
  - FlexibleSqueezeGroupRows +132 −56 (the header and the value pill);
  - FlexibleStageModel+Groups +110 −16 (merge, hands, estimate hook, pinched columns, per-face
    catch);
  - FlexibleSqueezeGroups +90 −18 (hand-aware move and new, uniteHands, live force,
    squishSlots);
  - FlexibleFaceList +64 −17 (sections under headers, row frames);
  - FlexibleStageModel +61 −13 (the estimate and pinch errors in the pipeline, the field flag,
    derive/refresh/adopt, the pinch-aware order, the job's pinches);
  - FlexibleReadiness +58 −5 (`.groupsCompete`, `popping`, `competing`, the fixes, squishShown);
  - FlexibleSquishPlayer +53 −24 (the row above the capsule);
  - FlexibleFacePanel +47 −11 (warning, weightLine, dot, the pinch fallback line, the pad clamp);
  - FlexibleShownValues +33 −12 (half caps, the halves' buildable depths);
  - FlexibleLatticeGeneration +31 −7 (pinchedWith, squishFaces, simNote);
  - FlexibleRowCopy +31 −2;
  - FlexibleDepthPrism +21 −3;
  - FlexibleStagePage +16 −5 (`history`, popping, the notice);
  - FlexibleFixPopup +8 (the join / keep-apart fixes, button frames);
  - FlexibleJob +6;
  - FlexibleDepthChips +4 −2;
  - FlexibleSettingsPanel +3 −1 (the reveal follows a group move);
  - FlexibleMainStage and FlexibleMainStage+Views, +1 −1 each (the note, the probe's faces).

### Decisions (00-decisions.md)
- D-R4-12, D-R4-14 and D-R4-15 amended: headers in the list, one force control, the hand, the
  merge's force, the miss said before Exit with the pop-up, and the picker above the capsule.
- New rows:
  - D-R4-17: a pinched column is half a column for the dent, the chip, the pad and the warning;
  - D-R4-18: the four squish slots keep a pinch whole;
  - D-R4-19: undo re-reads the main page; no 24 MB field is kept; the encoder refuses a pinch.

### Tests
Every new test states its RED control inline: D2's behaviour, computed beside it, must differ.
Each fix was also mutated back to D2's behaviour, rebuilt, and its pinning test run. All 17
mutations went RED (`e2/mut_run.log`):
- E1 remove keeps its own force;
- E2 undo without the re-read;
- E3 whole-column warning;
- E4 a hand split;
- E5 adopt without uniting;
- E6 one catch for all;
- E7 field always kept;
- E8 the encoder sends a pinch;
- E9 no estimate;
- E10 the prompt pops blockers only;
- E11 no "All at once" note;
- E12 the four largest;
- E13 whole-column caps;
- E14 the card says the force;
- E15 green dot;
- E16 D2's long header line;
- E17 the picker inside the capsule.

NEW:
- `FlexibleSqueezeGroupsReviewTests` (8, his project): remove, undo, pinched warning, hand,
  adopt, one throw, combined field, the static encoder.
- `FlexibleSqueezeGroupsReviewUXTests` (5): the miss before Exit and its choice (the estimate
  against the built lattice; the positive control is that with no other group's material it
  misses nothing), the pass's slots (pure), five faces on his pad, Top + Bottom, the card.
- `FlexibleSqueezeGroupsReviewUITests` (2, hosted): the headers whole and on the panel, with the
  pop-up clicked; the timeline with the picker at four sizes.

RE-PINNED, each with its reason in the test:
- `FlexibleSqueezeGroupsUITests`: the header lines; the pop-up goes through [Keep apart]; group
  1's miss line; the player is taller, not wider.
- `FlexibleSettingsRound4Tests`: the list's source pins.
- `FlexibleSqueezeGroupsModelTests`: it asks for the combined field.
- `FlexibleRowCopyTests`: the card's warning is a static the tests call.

Raw results:
```
Targeted suite (every Flexible* suite + the brief's list + the WorkspacePlaceholder scanners; D2's filter):
Executed 763 tests, with 10 tests skipped and 2 failures (0 unexpected) in 822.797 (822.866) seconds
  LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds — known, pre-existing
  FlexibleRowCopyTests.testRefusalsUnreachedColumnsAndAutoSayItOnThePanel — its source pin, re-pinned; rerun: Executed 4 tests, with 0 failures
FLEX-REVIEW remove: ["Group 1 · Top A + 3 more · Squeeze 10 kg"] · face 3 10.0 kg · first force Optional(10.0)
FLEX-REVIEW undo: ["Group 1 · Top A + 3 more · Squeeze 10 kg"] · header Group 1 · Squeeze [10 kg] seed 10.0 · first force Optional(10.0)
FLEX-REVIEW face 3 warning: 'Can't reach your curve on 412 columns' · halves 412 · core's whole column 832
FLEX-REVIEW face 5 warning: 'Can't reach your curve on 476 columns' · halves 476 · core's whole column 832
FLEX-REVIEW hand: ["Group 1 · Face 3 + Face 5 · Squeeze 10 kg", "Group 2 · Top A + Top B · Squeeze 4 kg"] · Top 4.0 kg
FLEX-REVIEW one throw: segments [3] · errors [5: "columnsDoNotMatch"]
FLEX-REVIEW combined field: 53248 voxels · held only on request
FLEX-REVIEW compete: estimate 0.331 of 2.630 mm · top line 'Ready · Group 1 squishes ~0.3 of 2.6 mm · firmer wins' · pop-up 'Group 1 would squish ~0.3 of 2.6 mm: Group 2 needs firmer material' · fixes [joinGroups(from: 1, into: 2), keepApart]
FLEX-REVIEW compete: built lattice 0.330 mm · estimate 0.331 mm · note 'Group 1 squishes 0.3 of 2.6 mm · firmer wins'
FLEX-REVIEW top+bottom: k 2.0 (D2's cap 4.0) · worst k·d / half 0.600 · D2 crossing columns 468 · top A lattice 20.0 mm, chip stops at 10.0 mm
FLEX-REVIEW five faces: line 'Ready · Squish shown on 3 of 5 faces · pinches whole' · group-1 [0, A, B] · group-2 [3, 5] · all [0, A, B]
FLEX-REVIEW card share: '5 kg of Top's 10 kg'
FLEX-REVIEW-HOSTED headers (the pop-up opened on the move, [Keep apart] clicked, face 5 reopened):
  11l: G1 line 114/114 pt G2 line 116/116 pt · G2 header y 446–490, × y 468, card y 550–796, scroll 187–796 · D2's section would start at y 958 · D2 'Group 1 · Top A + Top B · Squeeze 10 kg' 126/248 pt · D2 'Group 2 · Face 3 + Face 5 · Squeeze 10 kg' 125/261 pt
  11p: G1 line 114/114 pt G2 line 116/116 pt · G2 header y 644–688, × y 666, card y 748–994, scroll 252–1156 · D2's section would start at y 1156 · D2 … 143/248 pt · … 138/261 pt
  13p: G1 line 114/114 pt G2 line 116/116 pt · G2 header y 826–870, × y 848, card y 930–1176, scroll 434–1338 · D2's section would start at y 1338 · D2 … 143/248 pt · … 138/261 pt
  13l: G1 line 114/114 pt G2 line 116/116 pt · G2 header y 579–623, × y 601, card y 683–929, scroll 187–994 · D2's section would start at y 1091 · D2 … 126/248 pt · … 125/261 pt
FLEX-REVIEW-HOSTED player:
  11l capsule 340 pt → timeline 167 pt · D2: capsule 444 pt → timeline 154 pt
  11p capsule 294 pt → timeline 121 pt · D2: capsule 294 pt → timeline 4 pt
  13p capsule 340 pt → timeline 167 pt · D2: capsule 444 pt → timeline 154 pt
  13l capsule 340 pt → timeline 167 pt · D2: capsule 444 pt → timeline 154 pt
FLEX-GROUPS-HOSTED (re-pinned): 11l + New → 2 groups · × clicked → 1 group (D2: "× under the fold — removed through the model") | 13p the same
Mutations (e2/mut_run.log): E1–E17 all RED.
iOS: xcodebuild … -destination id=147E56A1-C8CA-4B9D-BE6C-CF230589A83A … build → ** BUILD SUCCEEDED ** (exit 0), no warning or error in a Flexible file. The app was not launched.
```

### Commits (on claude/flexible-screens, not pushed)
- 1ee4f364 — the code, three new suites, re-pins.
- "A1 round 4 batch D2 verification: handoff section and DECISIONS …" — this section,
  D-R4-12/14/15 amended, D-R4-17..19 new.

## Round 4 · batch D2 — squeeze groups and the pinch

Your img 3 ("when squeezing something with your hands, you would absolutely squeeze the two sides
together. One side wouldn't rest"), img 4 ("Groups faces together … group two sides together with
another two sides as a different group") and your answer 1 (ONE force per group, "like two hands
pressing equally; each face keeps its own curve"). Judged on YOUR project 0004 restored through
`AppModel.open`; the Settings page was hosted offscreen and clicked. The app was NOT launched, so
none of this has been seen on a screen yet.

**What you will see on the Settings page:**
- **Your faces 3 and 5 no longer stop the lattice.** Your project as saved now reads "Ready: Exit
  builds the lattice". Round 3 said "1 thing to fix: Face 3 and Face 5 press the same material"
  and offered [Face 5 rests] [Face 3 rests]. That blocker, its two buttons and the orange
  "conflict" tint on the part are gone.
- **Squeeze groups, under the face list.** (★ Superseded by the verification pass above: each group
  is now a header IN the face list, its force in its pill — this one line was cut at the force.)
  Every pressed face starts in Group 1. One line per group, its faces and its ONE force:
  - "Group 1 · Top A + 3 more · Squeeze 10 kg" on your project as saved;
  - "Group 1 · Top A + Top B · Squeeze 10 kg" / "Group 2 · Face 3 + Face 5 · Squeeze 10 kg"
    once the sides are apart (your img 4).
  Each line has the group's colour dot (green, blue, orange, red — never purple), a pencil for the
  force, and with two or more groups an × that removes the group (its faces join the first other
  group). The face list's dots take the group colour too.
- **Moving a face.** A pressed face's card has a new row: "Squeeze group [1] [2] [+ New]". + New
  makes a new group from that face; a number moves it there.
- **One force per group.** "Squeeze 10 kg" is every HAND's force (★ corrected in the verification
  pass: not "every face with 10 kg" — a main-page Load group over two faces splits its 10 kg by
  area, 5 kg each; a face of your own takes the full 10 kg). A face that
  comes from a main-page Load group is that group's hand: the pencil writes the main page's group
  back (one source of truth), and its faces share it by area, as core spreads a group. A weight
  typed on one face is its group's force. A face you press here joins Group 1 at its force, with
  no number pad.
- **A pinch says so, in one plain line.** Face 3's card: "Pinched with Face 5 · two halves".
- **Two groups that share material say so:** "Groups share material: the firmer one wins".

**What you will see on the main page:**
- **The squish player has a group picker** once there are two or more groups: "[Group 1 ▾]" lists
  "Group 1 · Top A + Top B", "Group 2 · Face 3 + Face 5" and "All at once" (your "Play all").
  Picking a group squishes only its faces, the dent and the walls. It is the same lattice: the
  pick re-uploads the squish faces only, never the lattice. It opens on Group 1.
- **A group that squishes less than it was designed for says so**, one line above the player:
  "Group 1 squishes 0.3 of 2.6 mm · firmer wins".

**What it does to the lattice (your pad):**
- **The pinch is two halves.** Every one of face 3's 832 columns runs 100 mm to face 5. Each column
  is split in the middle. The half nearer face 3 is designed for face 3's own drawing, at face 3's
  own pressure. It uses core's own density_for / strain_under / cell_size_mm through the bridge,
  column by column, as core's design_face does, with the height halved. The field gives every voxel
  to the NEARER face (core's own handover rule), so the two halves meet in the middle.
  - With nothing pinched, this design IS core's: |Δρ| ≤ 1.7e-16 over all 5,760 columns of your
    four faces.
  - Your drawing is met better. Over 100 mm, face 3's one profile missed your drawing by 1.42 mm
    on average (every column "too soft": even the firmest lattice squishes further than drawn).
    Over its half it misses by 0.48 mm (412 columns still too soft).
- **Core refuses this** ("faces 3 and 5 push the same material along the same axis (one profile
  per stack)"). So a group with a pinch is assembled by the app. The app's assembler is core's rule
  in Swift: on a set core CAN assemble (top A, top B, face 3) it equals core's field on every one of
  the 53,248 lattice voxels (|Δρ| = 0, the same owner).
- **Separate groups: the firmer wins.** Take your img 4, the top in Group 1 and the sides in
  Group 2. The lattice must carry both squeezes, so each voxel takes the firmer group's density.
  - The sides' 100 mm columns at 10 kg need a dense lattice. Group 2 is firmer on 45,831 of the
    53,248 voxels.
  - So the top, designed to squish 2.6 mm, squishes about 0.3 mm in that lattice. The player says
    so. This is the honest consequence of firmer-wins: a compromise density that serves both is
    core's job (core brief #1).

**Not done (and why):**
- **Nothing has been seen on a device or simulator.** I must not launch the app.
- **Where the halves meet is the column's middle, not a force balance.** Two faces pressed equally
  meet where the nearest-face rule puts them (d_A = d_B). Core should place it (core brief #6).
- **"As built" across groups is an estimate.** It uses the mean density along each column's span
  through core's strain_under, not a series column (core brief #4). It is used only with two or
  more groups; one group shows its designed depths, as before.
- **Core's run job cannot carry groups or a pinch yet.** `runJobJSON` throws
  `.squeezeGroups` / `.pinch` with one sentence, instead of sending a job core would refuse. Nothing
  in the app sends it yet (your answer 2's export path is another batch).
- **Auto (More) still weighs each face over its whole column.** For a pinched face its pick may fit
  the whole column but not the half (core brief #7).
- **The render defects seen in B's renders** (the seam speckle, the flap past a pressed side wall,
  the torn-looking pressed side face) are untouched. A pinch now squishes BOTH side faces at once,
  so the side-face tearing may show more. Batch G's displacement field replaces the per-column
  squish.
- **The group colour on the part** shows only where a pressed face has no map yet. Once its map is
  drawn, the heat map covers the face. The list and the group rows carry the colour.
- **At 11" portrait the player with its picker narrows to 294 pt**, so the timeline is short there.
- **The player's "Play all" is "All at once"** (every group squeezing together, each face at its
  group's as-built depth). It does not play the groups one after another.

**Your call:**
- **One force per group, counted per hand.** A main-page Load group over two faces (say Top A +
  Top B) is ONE hand: "Squeeze 10 kg" puts 10 kg on the top, split by area. It is not 10 kg on each
  sector. Faces of your own each take the full 10 kg (face 3 and face 5: two hands pressing
  equally). Say if you want every face at the full force instead.
- **A face you press joins Group 1 at its force, without asking.** Say if you want the pad to ask.
- **Firmer-wins makes the top nearly rigid when the sides are a separate group** (0.3 of 2.6 mm).
  Keep the sides in Group 1 (a pinch together with the top) to keep each face's own squish, or wait
  for core's compromise design.
- **"Play all" plays everything at once.** Say if you want the groups played one after another
  instead.

### Core brief (D2 — everything core cannot do; the plan's items 1–15 and D1's #16 stand)

The app does each of these itself today. Each item says what the app does and what core should
own instead.
- **#1 (now concrete) MULTI-SQUEEZE DESIGN.** Design ONE field that meets every squeeze group, a
  compromise with each group's miss reported.
  - Today the app combines the groups firmer-wins. On your pad (top | sides), Group 1 was designed
    for 2.6 mm and squishes about 0.3 mm: Group 2 is firmer on 45,831 of 53,248 voxels.
- **#2 (now concrete) THE JOB SCHEMA**: `flexible.squeeze_groups: [{faces: [face_region_id],
  force_n}]`.
  - One force per HAND: a main-page Load group is one hand, split by area; any other face is its
    own hand.
  - Until then `runJobJSON` throws `.squeezeGroups` for two or more groups.
- **#4 SERIES COLUMNS.** The app's "as built" across groups is the mean ρ along a column's designed
  span, put through strain_under (≈). Core should integrate the column in series.
- **#6 (now concrete) THE PINCH**:
  - `design_face` over a column SEGMENT (a per-column height);
  - `assemble_density_field` without its one-profile refusal for two faces of one group;
  - `find_stack_conflicts` telling a pinch (two faces pressing against each other) from two
    faces pressing the same way on one stack (a step), which the app also treats as nearest-face;
  - the split placed by FORCE BALANCE. The app splits where d_A = d_B: the column's middle for two
    parallel faces, and each half at its own face's pressure.
  - Today the app does this in `FlexiblePinch.design` (core's design_face, column by column, with
    the height halved) and `FlexibleGroupField.assemble` (core's assembler in Swift, without the
    refusal).
  - Until core owns it, `runJobJSON` throws `.pinch`.
- **#7 AUTO OVER GROUPS AND PINCHES.** `recommend` designs every face over its whole column. A
  pinched face's half runs at twice the strain, so Auto's family or temperature may suit the whole
  column but not the half.
- **#9 C2/C3 EXPORT** from the combined field (the groups, and the pinches' two halves).
- **#17 (new) A RECEIPT PER GROUP**: each group's squish in the combined field, and the lattice the
  groups compete for. The app counts it (`FlexibleGeneratedLattice.sharedVoxels`, `simNotes`).

### Hook lines in #354 files

None. `git diff 956c9587..HEAD --stat` touches no #354 file: WorkspacePlaceholder, MetalMeshView,
LatticeSettings, ProjectModel and LatticeStageMode are untouched, and no case was added.
- The renderer's new branch lives in `MeshRenderer+FlexibleLattice.swift` (#362's own file): a
  faces-only upload when the lattice token is the same and the faces token changed.
- New files: FlexibleSqueezeGroups, FlexiblePinch, FlexibleGroupField, FlexibleStageModel+Groups
  and FlexibleSqueezeGroupRows.
- Edited track files (small, each marked ★ ROUND 4 (D2)): FlexibleSettings (+1 optional field),
  FlexibleStageModel (segments; the group-aware build; press / rest / setWeight; the run job; the
  stale-refusal rule), FlexibleReadiness (the blocker removed), FlexibleFaceList / FlexibleFacePanel
  (group rows, the card's group row, the pinch line), FlexiblePageChannels / FlexibleOverlay (the
  conflict tint gone, group tint), FlexibleFixPopup (press asks the pad only when needed),
  FlexibleRowCopy, FlexibleLatticeGeneration (sims, `showing`), FlexibleSquish (facesToken),
  FlexibleLatticePass (`uploadFaces`), FlexibleMainStage(+Views) (the pick), FlexibleSquishPlayer
  and FlexibleMainStatusPill (the picker), and FlexibleJob (the throws).

### Decisions (00-decisions.md)

- New rows D-R4-12 … D-R4-16: the squeeze groups, the pinch, firmer-wins, the player's picker, and
  the stale refusal.
- D-R3-10 is amended: its shared-stack blocker, its [Face N rests] fixes and the two-face camera
  sentence are struck.
- R11's "refuse and name them" is amended.
- M13 stands for core; D-R4-13 overrides it inside a group.

### Tests

Each new suite was written FIRST and run RED against the round-3 code. Its API surface was stubbed
so it compiled (`d2_red1.log`): the pinch blocked ("Face 3 and Face 5 press the same material"), no
lattice was built within 120 s, the player had no sims, a typed weight moved one face, and the run
job did not throw.

NEW:
- `FlexibleSqueezeGroupsTests` (8): the groups as values, the one-line copy, the colours, pinch vs
  shared material, Codable, the sims, firmer-wins.
- `FlexiblePinchTests` (7): on your project — core refuses the pinch; nothing pinched = core's
  design; 832 / 832 columns pinched; the assembler = core's field; your project READY and building;
  two segments; core's in_stack with a straddling cut.
- `FlexibleSqueezeGroupsModelTests` (7): on your project — one group at 10 kg; the force writes the
  main page back; a moved face takes its group's force; nothing blocks in or across groups;
  separate groups firmer-wins; the player's pick; the run job's throws.
- `FlexibleSqueezeGroupsUITests` (4): the Settings page hosted and CLICKED (+ New and ×); the group
  tint; a pick re-uploads the faces alone (Metal); the player with its picker kept clear of every
  button and legend.
- `FlexibleGroupFieldPerfTests` (1, opt-in, Release): the cost.

Inline RED controls:
- the old rule's blocker on your project;
- core's own refusal of 3 + 5;
- a halved column changes 727 of 832 densities;
- no partner, nothing pinched;
- the assembler without R11's blend is off by 0.100;
- a point across a cut is in the column without the cut;
- min-combine is softer on 49,564 voxels;
- the old per-face write left face 5 at 10 kg;
- a required `squeezeGroup` breaks old JSON;
- `groupPalette[4]` is purple;
- the lattice unpicked squishes 4 faces;
- round 3's layer equality ignored a pick;
- one profile (0.202) is neither half.

Re-pinned, each with its reason in the test:
- FlexibleReadinessTests:
  - your project has NOTHING to fix (round 3's rule copied as the control);
  - TPU 95A: nothing blocks;
  - [Face 5 rests] is applied directly;
  - the rule's pair and the prompt use a no-weight blocker.
- FlexibleBatchBReviewUXTests: the prompt, the pill and the fix list without the shared-stack case;
  no issue names both ends of a stack.
- FlexibleMainStageTests: the pill's rule on a weight blocker (it caught D-R4-16).
- FlexibleBatchBReviewTests: the undo of [Face 5 rests] REBUILDS the pinch; it no longer says
  "share a stack".
- FlexibleRowCopyTests: the one-line table.
- FlexibleSettingsRound4Tests: D1's marker now holds the group rows.
- FlexibleSquishTests: the drawn-lattice call site takes the pick.

Deleted-test sweep of my diff: no test deleted. Two are renamed by their re-pin
(`testHisProjectAsSavedHasOneThingToFix` → `…HasNothingToFix`,
`testWithTPU95AStillOnlyTheSharedStackBlocks` → `testWithTPU95ANothingBlocks`).

Mutation runs. Each run breaks one rule, rebuilds, and runs the test that pins it; the file is then
restored from git. All 14 are RED:
```
M1  the pinch group handed to core            ⇒ his pinch: "faces 3 and 5 push the same material … (one profile per stack)" (2 failures)
M2  no split (a pinched column over 100 mm)   ⇒ 100.0 ≠ 50.0 "half of his 100 mm columns" (3)
M3  separate groups combined SOFTER-wins      ⇒ |combined − max| 0.215 (4)
M4  the assembler without R11's blend         ⇒ 0.09998 not < 1e-5 "the app's assembler is core's rule" (1)
M5  membership ignores a sector's cuts        ⇒ "(col: 0, depth: 3.0)" across the cut (2)
M6  a typed weight changes its face alone     ⇒ face 5 12.0 ≠ 9.0 "the other side of the pinch follows" (2)
M7  the player's pick ignored                 ⇒ group 1's layer squishes [−Z, −X, +X] (5)
M8  the renderer re-uploads nothing on a pick ⇒ "a pick redraws" (3)
M9  a pinch across groups too                 ⇒ "separate groups: no pinch" (2)
M10 a stale refusal said during the new run   ⇒ "Fix: Face 5 can't be designed" ≠ "Building…" (1)
M11 the group palette reaches purple          ⇒ group 1 red, not green; purple at group 5 (3)
M12 the run job sent for groups / a pinch     ⇒ "did not throw — one group with a pinch" (1)
M13 the player placed at its old size         ⇒ the slot's source pin (1)
M14 a moved face keeps its own weight         ⇒ 10.0 ≠ 6.0 "face 5 joins group 2 at its 6 kg" (2)
```

The targeted suite: every Flexible* suite, the brief's list, and every suite that scans
WorkspacePlaceholder (D1's filter, unchanged: no #354 file is touched). It ran after the last source
change. Raw:
```
Executed 748 tests, with 10 tests skipped and 1 failure (0 unexpected) in 750.553 (750.617) seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
FLEX-PINCH core on 3 + 5: faces 3 and 5 push the same material along the same axis (one profile per stack)
FLEX-PINCH face 3 pinched by face 5: 832 of 832
FLEX-PINCH face 3 mean miss of its drawing: one profile over 100 mm 1.4204065801731192 mm (too soft on 832) · its half 0.47520234869831113 mm (too soft on 412)
FLEX-PINCH his project as saved: blocking [] · line 'Ready: Exit builds the lattice'
FLEX-PINCH nothing pinched vs core's design: 5760 columns · |Δρ| ≤ 1.6653345369377348e-16 · |Δdepth| ≤ 1.5987211554602254e-14 mm
FLEX-PINCH face 3 halved: 727 of 832 columns change density
FLEX-ASSEMBLE app vs core on top A + top B + face 3: 53248 lattice voxels · |Δρ| ≤ 0.0 · owners differ on 0
FLEX-ASSEMBLE his split without cuts: owners differ on 0, |Δρ| ≤ 0.0
FLEX-ASSEMBLE control, no blend: |Δρ| ≤ 0.09997618198394775, owners differ on 0
FLEX-PINCH two segments: near face 3 ρ 0.16584753 (its half 0.16574399775724688) · near face 5 ρ 0.26536065 (its half 0.26507709097617244)
FLEX-PINCH control: one profile (face 3's, 100 mm) ρ 0.20215404914798032 beside face 5
FLEX-READY his project as saved: 0 blocking — Ready: Exit builds the lattice | pinches ["3|5"]
FLEX-GROUPS his top | sides: shared voxels 53248 · notes ["group-1": "Group 1 squishes 0.3 of 2.6 mm · firmer wins"]
FLEX-GROUPS firmer wins: |combined − max| ≤ 0.0 · group 2 firmer on 45831 voxels · min-combine softer on 49564
FLEX-PLAYER group 2: dented vertices top A 0 · face 3 4992 · face 5 4992
FLEX-PLAYER pick: volume uploads 1 · face uploads 1 · faces 1
FLEX-GROUPS-HOSTED 11l: + New at (311, 668) → 2 groups · rows 44 pt / 44 pt · × under the fold (removed through the model) | 13p: + New at (328, 918) → 2 groups · rows 44 pt / 44 pt · × clicked → 1 group
FLEX-PLAYER with picker + note: 11l 444×68 at (489, 664) · 11p 294×68 at (384, 1024) · 13p 444×68 at (408, 1206) · 13l 444×68 at (466, 862) · old size would collide at 2 of 4
FLEX-REVIEW undo of [Face 5 rests]: pill 'Ready' ready · pinches 1
```
(Face 3's half near face 3 is 0.166 and face 5's is 0.265 with both sides drawn as the same dome,
face 3 at 4 mm and face 5 at 1 mm. Your own face 3 is drawn FIRM in the middle: its flipped curve
is 0 there.)

Cost on a Release build (Mac; `FLEX_D2_PERF=1`), paid only when a lattice is built (Exit, or a
main-page edit) or a design lands, never per drag:
```
FLEX-PERF assemble 128³ (2097152 voxels), 4 faces, 2 pinches: 0.383 / 0.389 / 0.381 s (3 runs) · two groups 0.606 s + firmer 0.027 s
FLEX-PERF two-segment design, 4096 columns through core's table: 0.065 s
```
Your pad's grid is 64 × 64 × 13, where the assembly takes milliseconds. An iPad is slower than this
Mac, so on a 128³ part expect about 1 s more on Exit.

**iOS build (final tree):** `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration
Debug -destination id=147E56A1… -derivedDataPath …/flexA1 build` → `** BUILD SUCCEEDED **` (exit
0), with no warning in a Flexible file. The app was not launched.

### Commits (on claude/flexible-screens, not pushed)

75641936 the squeeze groups and the pinch (code and tests, re-pins) · e0643a7f a moved face takes its
group's force, the two-segment test's premise, the cost probe · (this handoff and the DECISIONS rows
D-R4-12…16).


## Round 4 · batch D1 — verification pass

A verifier read batch D1 against your rules on YOUR project 0004. It rendered the page headlessly,
hosted it in an offscreen window and clicked it; the app was not launched. I confirmed each
finding myself on the code and on your restored project, and none turned out wrong. Every blocker
and major, and the cheap minors, now has a test that is RED on the code D1 left: an inline
control on the old rule, plus the mutation runs below. The one blocker, every major and those
minors are fixed; the rest are listed under "Not done".

**What changes for you on the Settings page:**
- **Tap a face in the list and its rows open right there** (the blocker). D1 put the face's rows
  under the whole list. On your project the list alone is 392 pt, so on every iPad the rows sat
  off the panel, and a tap seemed to move only the tick. On 11" landscape none of them showed.
  - The tapped row now opens in place as a card, filled and outlined in blue. Its first line is
    the row itself with [Pressed | Rests] on it, so the list's "· Pressed · 10 kg" is not said
    twice. Under it, inside the card: the weight, Shape (and the stamp's rows), and the depth.
  - The panel scrolls the card into view when you tap a row, tap the part, or use the fix
    pop-up, and when the card grows (Stamp's rows, a warning line). It moves only as far as the
    card's last row needs, so a card already on the panel stays put.
  - The panel may now grow up to the top chrome (the Exit row, the top line, the fix pop-up while
    it is up). The old cap was 62 % of the page, and your Stamp card (446 pt) could not fit on
    11" landscape. It still hugs its rows, so a short panel stays short.
  - Measured hosted on your project, the page's own frames, at 11" and 13" in both orientations.
    Each step is as opened, then a tap on top A, Stamp on top A, face 5, and face 4 (the last
    row). The card was on the panel every time (table in Tests).
- **The curves never draw under the panel, the legend or the player**, and can't be touched
  there (img 6's class, now for the curves as well). D1 fixed this for the stamp only; a curve
  point still sat on the filament row's "squish data" text. A point under the chrome is hidden,
  as the depth chip is, until you turn the part. (Rendered: 1,976 px of curve under a panel
  before, 0 now.)
- **A Stamp face's pit is a smooth bowl, and its prism a smooth outline.** D1 drew the thumb's pit
  as a row of teeth and the purple prism with a sawtooth crown. The stamp's footprint was a 0/1
  step one column wide, so along its staircase edge the dent's corners alternated between ¼ and
  ¾ of a 12 mm (3 mm × 4) cliff.
  - The footprint is now smoothed on the column grid (≈ 1.4 column pitches), and the deepest
    squish is still reached under the stamp.
  - On your top A, corners at one distance from the stamp's edge now differ by 0.13 of the
    deepest squish, where D1's differed by 0.33.
  - The prism stands on the smoothed footprint's half-depth outline. 7 % of its outline edges run
    along the grid, where D1's staircase had 100 %.
- **The stamp's handle keeps clear of the depth chip.** Seen from above they sat 3.6 pt apart,
  and the handle took the chip's drag. The handle now stays at least 56 pt from the chip, with a
  thin line to the stamp's centre. Its drag is relative, so where it sits doesn't move the stamp.
- **Finish** has a picture and one line under its chips: a small square of the part's outside
  (None: lattice to the edge · Rim: a solid band · Skin: solid with holes · Covered: solid). It
  redraws the moment you tap. Under Rim or Skin the line says **"Rim: preview only · prints as
  None for now"**; that used to be said only behind the (i). (Beside the chips, the picture cut
  "Finish" to "Fin…".)
- **Stamp says what the main page shows.** Under the stamp's rows: "Main page: whole face sinks,
  for now". On the main page, the dent legend reads "Squish · stamp: whole face" while a Stamp
  face's squish is shown there (core brief #10: core sinks the whole face today).
- **Smaller fixes:**
  - A lattice that lands while Settings is open no longer turns the map into "What can be built
    (estimate)" or jumps your tab to Face. The map stays "What you drew" (D-R4-6), which nothing
    reset before.
  - Choosing Stamp before the face's stack has landed no longer drops an 80 × 95 mm palm on the
    pad's corner. The stamp is seeded when the stack lands: centred, fitting, square or turned a
    quarter (your pad: Thumb pad 20 × 26 mm at 50, 50).
  - Tapping the Shape chip that is already chosen changes nothing. It used to stale the main
    page's lattice and re-run the designs.
  - The folded legend is smaller than the open one: 34 × 94 pt, where it was 34 × 180 against an
    open 264 × 124. Its bar is now a button, and a click on it brings the legend back (tested).
  - **The Skin holes are 3 mm across** (1.5 mm is the radius), about a third of the skin open. D1's
    prose said "1.5 mm holes". The handoff, D-R4-4 and core brief #16 now say what the code draws.

**Not done (and why):**
- **Nothing has been seen on a device or simulator.** I must not launch the app. The page was
  hosted offscreen on macOS; the iOS build succeeds (below).
- **The finish on the MAIN page is still hard to see.** In X-ray, a solid skin shows only as
  where the lattice stops. Drawing the skin itself (a frosted shell, the rim band, the holes)
  needs the lattice shader or a MetalMeshView hook. That is a #354-file change, not a cheap one,
  so it is your call. The Settings picture and line are the fix in this pass.
- **The main page's Stamp squish** is core's (the whole face sinks), and its pit there has the
  same teeth, because that map is core's per-column numbers. Smoothing core's numbers would draw
  something core did not say. It is said on both pages instead (core brief #10).
- **The camera the fix pop-up picks** can still put a curve point under the chrome. It is hidden
  there now, not covered; turn the part to reach it.
- **The check-stamp plumbing** (`checkStampShown`, `checks`, its branches) has no UI since D1. It
  is marked "kept for D2's load cases / G's case picker", not deleted.

**Your call:**
- **Rim and Skin print as None today** (core brief #16). One alternative is to send Skin as
  Covered (a skin two-thirds solid is closer to Covered than to None). Say if you want that.
- **The panel now grows up to the top chrome**, not to 62 %. Say if you want it lower.

### Hook lines in #354 files

None in this pass. Every change is in a Flexible track file. The new files are
`FlexibleStampFootprint.swift` and `FlexibleFinishSwatch.swift`. The edited files are
FlexibleFaceList, FlexibleFacePanel, FlexibleSettingsPanel, FlexibleStagePage,
FlexibleCurveEditor, FlexibleFaceStamp, FlexibleDepthPrism, FlexibleDepthChips, FlexibleFinish,
FlexibleRowCopy, FlexibleStageModel, FlexibleMainStage+Views and FlexibleStageChrome (a comment).
WorkspacePlaceholder, MetalMeshView, LatticeSettings and ProjectModel are untouched, and
LatticeStageMode gains no case.

### Decisions (00-decisions.md, in f75351ff)

D-R4-4 is corrected (3 mm holes, 1.5 mm radius). New rows:
- D-R4-8: the selected face's card, the reveal, and the panel's cap;
- D-R4-9: the smoothed footprint and the contour prism;
- D-R4-10: the chrome keep-out for the curves, and the handle clear of the chip;
- D-R4-11: said on the panel, and the smaller fixes.

### Tests

NEW:
- `FlexibleSettingsVerifyD1Tests` (10 tests);
- `FlexibleSettingsPageHostedTests` (2 tests: the page hosted in an offscreen window on your
  project, read through its own frames; clicks).

Inline RED controls:
- the page's old flag relabels the map;
- the old seed centres a palm on the corner;
- a 1.5 mm hole leaves 1.2 mm covered;
- Rim's and Skin's job is None's;
- the old write of "curves" changes the settings;
- the old handle sat 3.6 pt from the chip;
- D1's footprint spread 0.33, and its prism outline 100 % along the grid;
- the old curve band ran under the panel, and 1,976 px drew there;
- your Face tab (787 pt with face 5 open) is taller than the old cap;
- D1's bar was taller than the open legend;
- the picture beside the chips left the row no room.

Re-pinned (my batch's own tests, each with its reason):
- `FlexibleSettingsRound4Tests`: the list takes the pad binding; the selected row is the card;
  the stamp handle reads k;
- the finish row's width test measures the chips alone (the picture moved to its own line);
- the job test's force-unwrap is now an XCTUnwrap (the verifier's nit).

Mutation runs. Each run restores the rule this pass replaced, rebuilds, and runs the test that pins it; the
file is then restored byte for byte. All 12 are RED:
```
M1  the selected card never scrolled to            ⇒ hosted: 11l as opened — card 691–937 below the scroll's 312–796 (4 failures)
M2  the panel capped at 62 % again                 ⇒ hosted: 11l top A · Stamp — card 350–796 above the scroll's 400–796
M3  the stamp's footprint not smoothed             ⇒ teeth 0.264 not < 0.2
M4  the prism back on whole columns                ⇒ the page's prism call pinned (footprint:, not columns:)
M5  the stamp handle at the stamp's centre         ⇒ 0 / 5 / 30 pt from the chip, not ≥ 44 (4 failures)
M6  the curves not clipped out of the chrome       ⇒ 1,976 px under the panel, not 0
M7  Rim / Skin say nothing on the row              ⇒ "rim": no note
M8  a fresh lattice flips the Settings map         ⇒ showBuildable = true, and the tab switched (2 failures)
M9  re-tapping the chosen shape writes it          ⇒ the settings (and their hash) change (2 failures)
M10 Stamp before the stack seeds at 0 × 0          ⇒ a palm 80 × 95 at (0, 0) (5 failures)
M11 the folded legend's bar 150 pt again           ⇒ folded 180 pt not < open 124 pt
M12 the main dent legend silent on a stamp         ⇒ the legend line pinned
```
M2 was GREEN on its first run: the hosted check measured the card against the whole panel, so a
card tucked under the panel's header and tabs passed. The check now measures what the panel's
scroll SHOWS (a `panelScroll` frame), and M2 is RED.

The targeted suite: it covers every Flexible* suite, the brief's list, and every
suite that scans WorkspacePlaceholder (batch D1's `filter.txt`, unchanged: no #354 file is
touched). It ran after the last source change. Raw:
```
Executed 721 tests, with 9 tests skipped and 1 failure (0 unexpected) in 706.793 (706.854) seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
FLEX-HOSTED his Face tab 787 pt tall · the panel's cap at 11" landscape 517 pt
  11l as opened: card 550–796 in the panel's scroll 312–796 (246 pt) ✓
  11l top A: card 529–754 in the panel's scroll 312–796 (225 pt) ✓
  11l top A · Stamp: card 350–796 in the panel's scroll 312–796 (446 pt) ✓
  11l face 5 (last pressed): card 550–796 in the panel's scroll 312–796 (246 pt) ✓
  11l face 4 (last row): card 742–796 in the panel's scroll 312–796 (54 pt) ✓
  11p as opened: card 748–994 in the panel's scroll 369–1156 (246 pt) ✓
  11p top A: card 607–832 in the panel's scroll 390–1156 (225 pt) ✓
  11p top A · Stamp: card 583–1029 in the panel's scroll 366–1156 (446 pt) ✓
  11p face 5 (last pressed): card 748–994 in the panel's scroll 369–1156 (246 pt) ✓
  11p face 4 (last row): card 1102–1156 in the panel's scroll 561–1156 (54 pt) ✓
  13p as opened: card 930–1176 in the panel's scroll 551–1338 (246 pt) ✓
  13p top A: card 789–1014 in the panel's scroll 572–1338 (225 pt) ✓
  13p top A · Stamp: card 568–1014 in the panel's scroll 351–1338 (446 pt) ✓
  13p face 5 (last pressed): card 930–1176 in the panel's scroll 551–1338 (246 pt) ✓
  13p face 4 (last row): card 1284–1338 in the panel's scroll 743–1338 (54 pt) ✓
  13l as opened: card 691–937 in the panel's scroll 312–994 (246 pt) ✓
  13l top A: card 529–754 in the panel's scroll 312–994 (225 pt) ✓
  13l top A · Stamp: card 529–975 in the panel's scroll 312–994 (446 pt) ✓
  13l face 5 (last pressed): card 691–937 in the panel's scroll 312–994 (246 pt) ✓
  13l face 4 (last row): card 940–994 in the panel's scroll 399–994 (54 pt) ✓
FLEX-TEETH his top A, Thumb pad: dent spread among corners at one distance from the stamp's edge — D1's footprint 0.33 of the deepest (2016 corners) · smoothed 0.13 (2016)
FLEX-PRISM-STAMP his top A: outline edges along the grid — columns (old) 100% of 32 · contour 7% of 56
FLEX-HANDLE pad top from above (el 1.5): stamp centre ↔ chip 3.6 pt (old handle) → handle ↔ chip 56.0 pt
FLEX-CURVE-KEEPOUT pixels drawn under the panel: 0 (without the keep-out 1976)
FLEX-LEGEND open 264 × 124 · folded 34 × 94 · after a click on the bar 264 × 124
FLEX-SWATCH solid pixels: covered 6154 · skin 4186 · rim 3850 · none 0
FLEX-SEED pad top 100.0 × 100.0 mm: Thumb pad 20.0 × 26.0 mm at (50.0, 50.0), turned 0.0°
FLEX-PANEL pad: open 542.0 pt · minimized 64.0 pt (offered 900.0)
```
Before it, every Flexible* suite alone: `Executed 242 tests, with 4 tests skipped and 0 failures`.
Before and after renders of your top A under the thumb pad (D1's footprint vs the fix, with and
without the prism) are in the session's scratch, not committed: they are renders, not the app.

**iOS build:** `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration Debug
-destination id=147E56A1… -derivedDataPath …/flexA1 build` → `** BUILD SUCCEEDED **` (exit 0) on
the final source tree, with FlexibleStampFootprint and FlexibleFinishSwatch compiled and no
warning in a Flexible file. The app was not launched.

### Commits (on claude/flexible-screens, not pushed)

This pass: f75351ff (the fixes, their tests and the DECISIONS rows D-R4-4 corrected, D-R4-8…11), then
this handoff section.


## Round 4 · batch D1 — the Settings page

Your notes after testing batches A + B (your images 1, 2, 4, 5, 6, 7) and your answers 3
(stamps) and 4 (the finish), built on the Settings page. Judged headlessly on YOUR project 0004
restored through `AppModel.open`, and on the pad. The app was NOT launched, so none of this has
been seen on a screen yet.

**What you will see on the Settings page:**
- **Your faces are listed** (img 1). Under the filament, feel and finish rows there is a
  **Faces** list: every face set on the main page (and here), one big row each:
  - "Top A · Pressed · 10 kg", "Top B · Pressed · 10 kg", "Face 3 · Pressed · 10 kg",
    "Face 5 · Pressed · 10 kg", "Face 0 · Rests", "Face 2 · Rests", "Face 4 · Rests" on your
    project;
  - pressed faces come first. Each row is 48 pt tall with a chevron. The selected row is filled,
    outlined in blue and ticked.
  - **Tap a row:** the rows below it (Pressed / Rests, weight, Shape, depth) show and edit THAT
    face, and the part shows it selected. A split sector is selected as itself: tapping "Top B"
    selects top B, not the whole top face.
  - A marked place under the list waits for the squeeze-group rows (batch D2).
- **The panel is only as tall as its rows** (img 1). The pad's panel with one face is 577 pt,
  where round 3 took 62 % of the screen. Long content still scrolls.
- **Minimize** (img 1):
  - A chevron in the panel's header folds it to its header line ("Flexible · Top A", 64 pt).
    The same chevron opens it again.
  - The legend has a chevron too. It folds to the lattice legend's own bar (the scale alone,
    with the reading's arrow). A tap on the bar brings the legend back.
- **Shape [Curves | Stamp] is a real either/or** (img 1, img 4, your answer 3):
  - **Stamp can be pressed.** The face's ONE stamp appears at once on the part, at the face
    centre. It is the palm, a thumb pad or a fingertip: the first of these that fits the face
    (a thumb pad on your top A).
  - **The curves leave the part at once**, and the stamp's rows appear in their place, one line
    each: "Stamp · Thumb pad" [pick from the list, or import an SVG / image] · "Size 20 × 26 mm"
    [pencil] · "Turned 0°" [quarter turn] · Press [Soft | Rigid].
  - The stamp's weight IS the face's weight: the weight row above it, which a main-page group may
    own.
  - Drag the stamp's handle on the part to move it.
  - The map shows the stamp SINKING where it sits: the deepest squish under it, nothing beside
    it. On the pad, 174 of 4,096 columns dent, where the curves dent all 4,096. The depth prism
    stands on the stamp's footprint.
  - **Curves** hides the stamp and brings the curves back. The stamp is kept for a switch back
    and never sent.
  - **The Stamps tab and the check stamps are gone.** The tabs are Face | More; the tap-to-read
    legend gives dent values.
  - Your project's two check stamps (thumb on face 3, four fingers on face 5) are simply not
    read any more. A face designed under one stamp before round 4 keeps it as its Stamp shape.
- **The black circles are gone** (img 6). They were round 3's check-stamp handles, seen through
  the panel. Only the selected Stamp face's handle is drawn now, and never under the panel or the
  legend. Its outline is clipped out of them too.
- **The depth prism and its chip are the lattice stage's face-prism purple** (img 2, your
  request):
  - the prism is `latticeRegionTint(.include)`, the same (124, 111, 214) as the Lattice groups'
    prisms. A test reads #354's line, so the two cannot drift apart;
  - the chip wears the lattice depth knob's glass, brighter while dragged.
  - Batch C's "never violet" main-page hook is reverted, so there is ONE purple for every face
    prism, the main page's included.
- **Finish [None | Rim | Skin | Covered], for the whole part** (img 5, your answer 4). It is a
  row on the Face tab and replaces the per-face "Solid skin" row:
  - **None:** the lattice runs to the surface everywhere;
  - **Rim:** a solid band 2 mm round every face edge, with the faces open;
  - **Skin:** a 0.8 mm skin with round 3 mm holes (1.5 mm radius; this line said "1.5 mm holes"
    until the verification pass) on a 5 mm hex grid, about a third open, laid in each face's own
    plane;
  - **Covered:** a solid skin everywhere. This is the default, and what a project saved before
    reads.
  - Measured under the pad's top face (400 points 0.25 mm in), the points that are NOT solid:
    Covered 0 · None 317 · Rim 317 · Skin 97. Along the top edge, 60 of 60 points are solid
    under Rim (None: 18).
  - It shows on the main page's lattice after Save & Exit.
- **No lattice on the Settings page** (img 6). The part is X-ray and the map is your drawing
  ("What you drew", played by the page's own player). The lattice is drawn on the main page only.
- **More: Auto and Physics open below their titles** (img 7). The whole row is the button. A
  round caret points down and turns up when open (36 pt closed → 244 pt with Physics' 200 pt of
  details). The (i) popover that floated beside the panel is gone.

**Not done (and why):**
- **No simulator check, no screenshots.** I must not launch the app. `xcodebuild` for the
  simulator succeeds (below); everything else was measured headlessly.
- **Not in this batch** (the plan puts them elsewhere):
  - the squeeze groups: img 3, squeezing two sides at once; img 4, grouping faces; your answer 1,
    one force per group. This is batch D2; its place in the face list is marked;
  - img 5's X-ray / Lattice view selector on the main page;
  - img 6 / your answer 2, the big bottom Lattice button (send to core and export; the view
    button, the "ready" note);
  - the render defects in B's renders (the sector-seam speckle, the flap, the torn side face).
    The Settings page no longer draws the lattice. The map's own seam is left to batch G's
    displacement field.
- **A Stamp face's lattice on the main page squishes evenly.** Core designs a stamp face so the
  stamp "sinks that far" where it sits and spreads weight ÷ footprint elsewhere (core brief #10).
  The walls then squish by core's buildable depths (flat curves ⇒ the deepest everywhere). The
  Settings page's map shows the stamp sinking where it sits; that is your drawing, not a
  prediction.
- **Rim and Skin exist in the app's preview only.** Core's Flexible block has one `skin_on` per
  face. The job says true only under Covered (core brief #16 below).
- **The stamp turns in quarter turns only** (a one-tap button). The number pad cannot take 0°.
- The panel's and the legend's folded state is not remembered: they open unfolded each time the
  Settings page opens.

**Your call:**
- **A project saved before the finish existed reads Covered.** Your face 3 had its per-face
  "Solid skin" off; it is now covered like the rest. Pick None to open every face. Covered
  changes the one face; None would have changed every other face.
- **The finish's sizes are my choice until core owns them:** Rim 2 mm; Skin 0.8 mm thick with
  3 mm holes (1.5 mm radius), 5 mm apart.
- **The Finish row sits on the Face tab**, under Feel. Say if you want it in More.
- **The default stamp** is the palm, a thumb pad or a fingertip, whichever fits first.

### Core brief (additions from D1; items 1–15 are the plan's, carried by batch D)

- **16. A MODEL-WIDE FINISH in the Flexible block**: `flexible.finish: none | rim | skin |
  covered`, with rim width and perforation (hole size, pitch, skin thickness) as core's numbers.
  - Today `job_block.cpp:180` reads one `skin_on` per face, and `run.cpp` only echoes it.
  - The app sends `skin_on = (finish == covered)` on every face.
  - C2 / C3 (the export) must build Rim's band and Skin's holes the way the preview draws them
    (`FlexibleFinish`: the distance to the face edges; a hex hole grid in each face's plane —
    holes 3 mm ACROSS, `holeRadiusMM` = 1.5 is a radius, 5 mm pitch, ~33 % of the skin open).
- **#10 is now in use:** the Stamp shape sends flat curves, `deepest` = the chip, and
  `design_stamp` = the face's one stamp at the face's weight.

### Hook lines in #354 files

| hook | file · anchor | ± | why |
|---|---|---|---|
| H13 reverted | WorkspacePlaceholder · `latticeRegionTint(_ role:` | −1 | the `FlexibleMainTints.depthPlane` line is gone: #354's violet include tint again |
| H13 reverted | · `latticeDepthKnob(active:` | ~1 | `LatticeDensityProxy.densityColor(fraction: 0.6),` (#354's own line again) |
| H13 reverted | · `latticeExpandKnob(active:` | ~1 | `LatticeDensityProxy.densityColor(fraction: 0.25),` (#354's own line again) |

WorkspacePlaceholder in D1: `git diff --numstat` 2 3 (the revert commit 8de48a83 alone). No other
#354 file is touched. MetalMeshView, LatticeSettings and ProjectModel are untouched. New code
lives in new files: FlexibleFinish, FlexibleFaceList, FlexibleFaceStamp, FlexibleSettingsPanel
and FlexibleDisclosure.

### Decisions (00-decisions.md)

- §1c adds D-R4-1 … D-R4-7.
- D-R3-8 is amended: the prism and the chip are purple.
- D-R3-19 is struck (reverted).

### Tests

NEW `FlexibleSettingsRound4Tests` (14 tests). Each carries an inline positive control on the
rule it replaces:

- **Face list:** a tap through the part's face selects the whole split face, not top B.
- **Panel height:** round 3's ScrollView in a max-height frame takes all 900 pt offered for
  300 pt of rows.
- **Stamp handles:** your project's two check stamps were two handles.
- **Job:**
  - Curves sends the drawing and never the stored stamp;
  - the per-face skin said off, and Covered covers it.
- **Finish:**
  - with no finish, the edge is latticed;
  - Covered has skin in a hole.
- **Stamp map:** under Curves, every column dents.
- **Settings page:** a drawn lattice owned the map.
- **Colour:** the on-part white is not the purple.
- **Migration:** a required `finish` would not decode your project.
- **Carets:** the (i) row never grows.

Mutation runs. Each restores the rule D1 replaces in the source, rebuilds, runs
FlexibleSettingsRound4Tests, FlexibleShownValuesTests and FlexibleStageTests, then restores the
file. Afterwards `grep MUTATION` finds no marker of mine. Every one is RED:
```
M1  the panel scroll takes every point offered  ⇒ testThePanelIsOnlyAsTallAsItsContent: ("900.0") is not equal to ("300.0"); testThePanelAndTheLegendMinimize: ("900.0") is not less than ("800.0")
M2  a list tap resolved through the part's face ⇒ testTheFaceListListsHisFacesAndATapSelectsThatFace: ("Optional(1)") is not equal to ("Optional(1000104)"); ("[]") is not equal to ("[1000104]")
M3  the job's skin_on from the per-face switch  ⇒ testTheFinishReachesTheJob: 5 failures (covered / none / rim / skin, "…and Covered covers it"); FlexibleStageTests.testRunJobRoundTrips…: "Covered, the default finish"
M4  the builder ignores the finish (Covered)    ⇒ testTheFinishShapesTheLatticeField: None 0 > 100, Rim 0 > 100, the edge control 60 < 60, Skin 0 > 0, "no skin in a hole" 0.482 < 0
M5  a stored stamp is used under Curves too     ⇒ testShapeIsATrueEitherOr: "Curves never sends a stamp"; testTheStampShapeWritesFlatCurvesAndItsStamp: the Palm grid sent under Curves
M6  a Stamp face's map dents the whole face     ⇒ testTheStampSinks…: ("4096") is not less than ("2048"); max 2.998 ≠ 3.0
M7  the prism back in the on-part white         ⇒ testTheDepthPrismAndChip…: (0.949, 0.949, 0.961) ≠ (0.486, 0.435, 0.839); FlexibleShownValuesTests: "the prism"
M8  the migration keeps the check stamps        ⇒ testNoStampHandleIsDrawnUnderThePanel: ("2") is not equal to ("0"); testTheMigrationDrops…: the list kept
M9  the caret never opens inline                ⇒ testAutoAndPhysicsAreDisclosureCarets: ("36.0") is not greater than ("186.0")
M10 round 3's handles (every stamp of every face) ⇒ testNoStampHandleIsDrawnUnderThePanel: ("1") is not equal to ("0") "another face selected: none"
```
(M2 then crashed the run on a force-unwrap in the test; that line is now an XCTUnwrap. The only
`MUTATION` left in Sources is a word in a comment in GroupViewState.swift, which is not mine.)

Re-pinned on purpose (each carries its reason in the test):
- FlexibleBatchBReviewUXTests: the Settings page's renderer loop (there is no lattice on that
  page now);
- FlexibleSquishTests: the drawn-lattice call site moves to the main stage;
- FlexibleShownValuesTests: the prism and chip colour (purple);
- FlexibleStageTests:
  - the job's `skin_on` follows the finish;
  - the stamp round trip is under Shape = Stamp;
- FlexibleRowCopyTests:
  - the tabs are Face | More;
  - the one-line table gains the round-4 lines.

**Deleted-test sweep (my diff):** `FlexibleNeverVioletTests.swift` is deleted by the revert of
f968ee40. It pinned the Flexible accent on the main page's depth prism and knobs, which your
explicit request overrides. Its replacement pin is
`testTheDepthPrismAndChipAreTheLatticeStagesFacePrismPurple`: the hook is gone, #354's knob line
is its own again, and FlexibleDepthAccent.swift does not exist. No other test is deleted.

The targeted suite ran after the last source change. It covers every Flexible* suite, the
brief's list, and every suite that scans a touched file (WorkspacePlaceholder's readers: batch C's
`filter.txt`, unchanged). Raw:
```
Executed 709 tests, with 9 tests skipped and 1 failure (0 unexpected) in 623.831 (623.891) seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
FLEX-LIST his faces: Top A · Pressed · 10 kg ✓ | Top B · Pressed · 10 kg | Face 3 · Pressed · 10 kg | Face 5 · Pressed · 10 kg | Face 0 · Rests | Face 2 · Rests | Face 4 · Rests
FLEX-PANEL hug: 300 pt content → 300.0 · 2000 pt content → 900.0 (offered 900.0)
FLEX-PANEL pad: open 577.0 pt · minimized 64.0 pt (offered 900.0)
FLEX-STAMP pad top: 4096 columns · curves dent 4096 · the stamp dents 174 (167 under it) · deepest shown 3.0 mm
FLEX-FINISH gaps under the top (of 400): covered 0 · none 317 · rim 317 · skin 97 | solid along the top edge (of 60): covered 60 · none 18 · rim 60 · skin 60
FLEX-FINISH row 338 pt of 372
FLEX-CARET closed 36.0 pt · open 244.0 pt
```
Before the re-pins, the whole Flexible filter (230 tests) had 9 failures in 6 tests. Each was a
rule D1 changes on purpose: the renderer-loop pin, the tabs, the prism / chip colour, the
drawn-lattice call site, the job's skin_on, and the stamp round trip under Curves. All 6 are
re-pinned above.

**iOS build (final tree):** `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration
Debug -destination id=147E56A1… -derivedDataPath …/flexA1 build` → `** BUILD SUCCEEDED **` (exit
0), no warning in a Flexible file. The app was not launched.

### Commits (on claude/flexible-screens, not pushed)

8de48a83 revert f968ee40 (one purple for every face prism) · 90c3f758 the Settings page (face
list, hug, minimize, Shape either/or, purple prism, Finish, no lattice, carets) · (this handoff
and the DECISIONS rows).


## Round 3 · batch C — verification pass

A verifier read batch C against your rules on YOUR project 0004 (headless renders and his real
solid-part FEA; the app was not launched). I confirmed each finding myself, on the code and on
your restored project. Every blocker and major now has a test that is RED on the code batch C
left (a mutation run restoring the old line, or an inline control on the old rule). I fixed the
blocker, every major and the cheap, safe minors. Three minors are not done; they are listed below
with the reason.

**What changes for you:**
- **Stress now appears on your project.** The Stress button's solve threw at once:
  `face region 101 "add": face id 23 out of range — the model carries 6 faces`. Region 101
  ("Face 23 & like it") is a stale region nothing uses, and the app sends every region to core.
  The Flexible solve now sends only the regions its anchors and loads reach, plus their parents
  (Top = 103, and 102). Your pad solves in about 0.9 s, with a peak of 0.0462 MPa on a
  64 × 64 × 13 grid.
- **The solve says what it is doing.** It used to fail silently, and the legend said "No stress
  yet" for ever. The Stress legend now shows one of:
  - "Simulating…" while it runs. This is the only place the wait is said. The #354 banner ("A
    finite-element solve is grading your lattice") stands down under Flexible, and the caption
    under the view row is gone. The button still spins.
  - "Couldn't simulate" with **[Retry]**, and core's own words behind the (i).
  - What to add first, when the solve cannot start: "Stress needs an anchor on Topology" or
    "Stress needs a load on Topology".
- **Tapping Stress shows the stress in the view you are in.** Before, with Heat on, Heat kept the
  map (the pressed faces, where the load goes in), and Stress got the part's ghosted sides. On
  your pad those sides are 12 triangles whose 24 corners all read 0.000 MPa, so they were one
  flat blue. Now:
  - **Dent heat and Stress are the two colourings of the map, one at a time.** Turning Stress on
    turns Dent heat off; turning Dent heat on turns Stress off.
  - **X-ray and the lattice are left alone.** Stress used to turn X-ray off, which took the walls
    and their legend with it.
  - On your project, tapping Stress in the default view changes 41,015 px of the 52,648 px the
    part covers. Batch C's mix changed 0 px.
- **The colour under your finger is the number a tap reads there.** The main page cuts the part's
  own triangles to about 2.1 mm for colour (26k triangles on your pad; the dent's geometry is
  unchanged to 1e-7 mm).
  - Across 2,000 points on your part, the gap between colour and reading was p99 0.656 and mean
    0.068 of the ramp. It is now p99 0.081 and mean 0.004.
  - The worst single point is still about 0.9, at the anchored bottom corners. That is the FEA's
    corner singularity, and it is sharper than any vertex spacing.
- **MPa to three significant digits**: "0.0462 MPa", not "0.05".
- **Save & Exit hands the solver over.** The first Exit used to have none: the solver only came
  from the view toggles, which had not been drawn yet when Settings opened in the same tap that
  made the part Flexible. **Exit now solves only while Stress shows.** It used to solve every
  time, which competed with the lattice build that Exit starts. The Stress button starts it
  otherwise.
- **The Settings legend no longer swallows your curve points.** Only its "TAP TO READ" tab row
  takes a tap. Its body lets touches through, so a curve point or the curve line under it stays
  live (img 9: the Y curve's end point sat inside the legend).
- **Readings:**
  - Every tapped value is in the accent blue, in its own squircle (#354's `LatticeLegendReading`,
    your standing rule), with its arrow on the point, on both pages.
  - While a legend reads, the squish holds still at full, so the value stays on the surface it
    was read from. It plays again when you stop reading. A player you paused stays paused.
  - A tap on a legend never moves the legends. At 11" landscape the tapped one had jumped 260 pt.
- **Words:**
  - The dent legend says **"What you drew · mm"** while the map is your drawing (no lattice yet,
    or a shape-only lattice that predicts no squish). It says "Squish · mm" only for a lattice
    core designed (varioShore).
  - Each (i) is one sentence.
  - The lattice reading's cell is the one DRAWN (the ladder's rung, "≈" inside a blend). It used
    to be the law's: your ends now read "14% · ≈10.1 mm" … "36% · ≈3.7 mm".
- **The squish player keeps off the Selections column.** It sat at x 130 at 11" portrait. It now
  centres right of the column where the page centre would overlap it.
- **Navigation:**
  - [‹ Flexible] on Surface is never greyed out as "Flexible — needs …".
  - VoiceOver reads "Flexible", not "Lattice".
  - The extra [Surface] has its own id beside #354's hidden forward one.
- **Lighter:**
  - H4' does nothing off the Flexible stage: no field noted, and the group colours are not even
    evaluated.
  - The lattice legend's ends are scanned once per lattice, not on every orbit frame.

**Rejected:** none. Every finding reproduced (details in the table).

**Not done (and why):**
- **Stress ignores faces pressed only on the Flexible page** (top B and face 3 on your project).
  The plan's rule is the main page's loads (your answer: the group is the one source of truth for
  a weight). Adding Flexible-only presses to the solid part's FEA is a physics choice. The
  legend's line still says "in the solid part", and the (i) says "the main page's loads". Your
  call is below.
- **The lattice reading does not name the OWNER** (which pressed face's walls). The plan's
  decision (5.2) says the tap reads "density and owner". The generated lattice carries no owner
  field today (core's mask has one; the app drops it), so it needs plumbing through
  `FlexibleLatticeInputs`.
- **11" legends:** the second-column-or-pills choice was already your call (below). The player
  part of this finding is fixed.
- Carried over: no simulator check (the launch is refused to me); #354's Surface / Settings
  overlap (4b11beb3); the main-page mesh swap reframes the camera.

**Your call:**
- **Dent heat and Stress are one at a time now** (a radio pair). Say if you want both at once;
  the map can only show one of them.
- **Exit solves only while Stress shows.** Say if it should warm the field up on every Exit (the
  plan's first rule).
- **Faces pressed only on the Flexible page in the stress solve** (their kg, split by area,
  along gravity)? Or keep the main page's loads only?
- Still open from batch C: the second legend column at 11" landscape instead of pills.

### Each finding, confirmed on the code (RED before the fix → after)

| # | finding (verifier) | confirmed by | before → after |
|---|---|---|---|
| U-B | Stress never appears on his project, silently | `testHisProjectsStressSolvesWithTheRegionsItsLoadsReach` (his project, the real FEA) | the app's context THROWS on region 101 (control, kept) → reached regions [102, 103], 0.84 s, peak 0.0462 MPa. Mutation (no filter) ⇒ red |
| C-6 / U-B | a failed solve says "No stress yet" for ever | `testAFailedOrBlockedSolveIsSaidAndRetryRunsItAgain` | the sim's `.failed` had no reader → state `failed(core's words)`, "Couldn't simulate" + Retry, Retry re-runs, blocked says "Stress needs an anchor on Topology" and never runs. Mutation (the failure ignored) ⇒ 9 failures |
| C-1 | the first Save & Exit starts no FEA | `testTheFirstSaveAndExitHasTheSolverAndSolvesOnlyWhileStressShows` | `didExitSettings()` with no solver: nothing (control) → `didExitSettings(solver:)` runs it while Stress shows. Mutation (solver ignored) ⇒ red |
| U-12 | Exit solves unasked under a banner that says "grading your lattice"; the wait said four times | same test + `FlexibleBatchCHookTests` B1 pin | Stress off: Exit starts nothing; the banner has `!flexibleMain.owns(project, stage)`; the row caption removed; the legend says "Simulating…" once |
| U-9 | Stress invisible in the default mix; colour ≠ reading; "%.2f" | `testTappingStressShowsItInTheDefaultView` (his project, real field, offscreen renders), `testTheStressColourUnderAPointIsTheNumberATapReadsThere`, `testMPaReadsToThreeSignificantDigits` | tapping Stress: 0 px moved > 30/255 (batch C's mix, control) → 41,015 of 52,648; colour vs reading p99 0.656 → 0.081, mean 0.068 → 0.004; the dent unchanged (8.6e-8 mm); "0.05" (control) → "0.0462". Mutations (no subdivision on the stage; Stress turning X-ray off) ⇒ red |
| U-10 | Stress turns X-ray and the lattice off | `testStressTakesTheMapFromHeatAndLeavesXrayAndTheLatticeAlone`, `FlexibleMainViewsTests.testStressUnderFlexibleSolvesOnce` | Mutation (X-ray off again) ⇒ 10 failures |
| U-11 | the Settings legend swallows curve points | `testTheSettingsPageLegendDrillsInAndTapsDoNotSelect` (re-pinned) | the whole legend took the tap (control: gone) → body pass-through, a tab-height target only |
| C-2 | H4' works on every page | `testTheTintHookIsInertOffTheFlexibleStage` | octet page: nil, nothing noted, roles evaluated 0 times; control: the Flexible stage notes and composes |
| C-3 | the cell is the law, not the rung drawn | `testTheLatticeProbeReadsTheRestPointOfASquishedWall` (re-pinned) | the drawn rung / blend; your ends "14% · ≈10.1 mm" … "36% · ≈3.7 mm" |
| C-4 / U-18 | nav: label, duplicate id, [‹ Flexible] gated | `FlexibleSurfaceNavTests.testTheHookIsInPlace` | the three #354 lines as edited; controls: the old lines gone |
| C-5 | the lattice span scanned twice per body pass | `testTheStageReadsHisDentAndSwitchesToStress` (his lattice) | 1 scan for two reads, cached per generation |
| C-7 | handoff arithmetic; the (i) two sentences | this section; `testEveryTappedValueIsInTheBlueSquircle` | WorkspacePlaceholder in batch C: **+4 lines, 8 edited** (it said 9); every (i) one sentence |
| U-13 | "Squish · mm" over a shape-only lattice | `testTheDentLegendSaysWhatYouDrewUnlessCoreDesignedTheLattice` | "What you drew · mm" for his drawing / shape-only; "Squish · mm" on his varioShore lattice |
| U-14 | tapping a legend swaps them (11" landscape) | `testALegendTapNeverReordersTheLegends` | the old priority moved the stress legend (control) → no move |
| U-15 | the tapped value not in the blue squircle | `testEveryTappedValueIsInTheBlueSquircle` | white capsule (control: gone) → `LatticeLegendReading` on both pages, 88 × 61 pt / 149 × 61 pt |
| U-17 | the player in the Selections column | `testThePlayerKeepsOffTheSelectionsColumn`, `FlexibleLegendPlacementTests` (re-pinned) | x 130 at 11" portrait (control) → x 427 |
| U-19 | the reading floats while the squish plays | `testTheSquishHoldsStillWhileALegendReads` | a playing loop moves the map (control) → held at full while reading, plays after |
| U-16 | Flexible-only presses not in Stress | — | **not done** (your call) |

### Hook lines in #354 files changed this pass (each grepped after the edit; pinned)

| hook | file · anchor | ± | why |
|---|---|---|---|
| H5' | WorkspacePlaceholder · `if flexibleMain.owns(project, stage) { FlexibleMainViewToggles(main: flexibleMain` | ~1 | `, solver: FlexibleStressSolver(app: model, sim: latticeSim)) }`. It is now shorter: the solve, its region filter and its state live in `FlexibleStressSolve.swift` |
| H2' | · `onExit: { showFlexiblePage = false; latticeSettingsSavedThisSession = true; flexibleMain.didExitSettings(` | ~1 | `solver: FlexibleStressSolver(app: model, sim: latticeSim))`. The plan's H11, so the first Exit has the solver |
| B1 | · `if latticeSimIsRunning, !simBannerDismissed` | ~1 | `, !flexibleMain.owns(project, stage)` before `{ simRunningBanner }`. The banner says "grading your lattice", which is false under Flexible |
| H9' | · `let enabled = dest != .lattice` in `stageNavButton` | ~1 | `|| title != nil`, so [‹ Flexible] is never gated |
| H9' | · `.accessibilityIdentifier("stage-nav-\(dest.rawValue)` | ~1 | `\(title == nil ? "" : "-flexible")`, its own id |
| H9' | · `.accessibilityLabel(enabled ? dest.title` | ~1 | `(title ?? dest.title)`, so VoiceOver reads what it says |

WorkspacePlaceholder this pass: 0 added, 6 edited (`git diff --numstat`: 6 6). MetalMeshView: none.
`startStressSolveIfNeeded` is not touched (its first 900 characters are pinned again).

### Added / changed (track files)

- NEW `FlexibleStressSolve.swift`:
  - `FlexibleStressContext.reached` (the regions the load case reaches, and their ancestors);
  - `blocker` (no file / anchor / load, as one line);
  - `FlexibleStressState` (idle, running, ready, failed, blocked);
  - `FlexibleStressSolver` (start once, never twice, never while running).
- `FlexibleMainStage` / `+Views`:
  - Solver: `attach(_:)` (the sim's phase observed, delivered off the view update), `stressState`,
    `retryStress`, `didExitSettings(solver:)` (re-solves only while Stress shows).
  - Views: `toggleStress` / `toggleHeat` (one colouring of the map), H4' inert off the stage (`roles`
    an autoclosure).
  - Legends: `legendTapped` (no reorder), `noteDrill` (the squish holds), `legendTitle`,
    `stressInfo`, `stressEnds`, `latticeEnds()` (cached).
  - Readings: stress read on the drawn map at its rest place.
- `FlexibleOverlay`: `build(maxEdgeMM:)`, longest-edge bisection for colour. The dent of a
  sub-vertex is the blend of its kept triangle's corner dents (`Subdivision`). `stressEdgeMM`.
- `FlexibleProbe`:
  - `mpa`, `drawnCell` / `cellBlended`, `dentTitle`;
  - `drawnMapHit` (a DentHit now carries its rest place);
  - one-sentence (i)s;
  - Stress on the map held opaque.
- `FlexibleMainLegends`: the Stress legend's state + [Retry]; `FlexibleReadingTag` (the blue
  squircle); ends once per body; no `simulating` keep-out.
- `FlexibleMainStatusPill`: the toggles take `solver:`; no caption; the player keeps off the left
  strip.
- `FlexibleSquishPlayer`: `holdWhileReading` (and `autoPlay` respects it).
- `FlexibleStagePage`: the legend passes touches through, a tab-height tap target; the loop holds
  while reading; the callout is `FlexibleReadingTag`.

### Decisions rows amended (00-decisions.md §1b)

- D-R3-15: the reading squircle, no reorder, the hold while reading, "What you drew · mm", the
  drawn cell, 3 s.f., one-sentence (i), the Settings legend's tab, the player.
- D-R3-16: Heat and Stress one at a time; Stress on the map opaque; the colour subdivision.
- D-R3-17: "Stress turns X-ray off" struck. Exit re-solves only while Stress shows; the solver
  from Exit; the reached regions; the state said; the banner stands down.
- D-R3-18: the nav extras (not gated, label, id).

### Tests (raw)

Mutation runs. Each restores batch C's line in source, runs the suite, then restores the file.
`grep -c MUTATION` finds no marker afterwards.
```
A  no region filter        ⇒ testHisProjectsStressSolves…: reached [104, 101, 102, 103]; analyzeSolidLoadCase: caught error "face region 101 "add": face id 23 out of range"
                              (and the colour and view tests throw the same)
B  Exit ignores the solver ⇒ testTheFirstSaveAndExit…: ("idle") is not equal to ("running"); ("0") is not equal to ("1")
E  a failure not said      ⇒ testAFailedOrBlockedSolve…: ("running") is not equal to ("failed("face region 9 out of range")"); line "Simulating…"; no Retry; 9 failures
F  Stress turns X-ray off  ⇒ testStressTakesTheMap…: 8 failures; testTappingStressShowsIt…: "Stress took the map; X-ray stayed"; FlexibleMainViewsTests:307 "X-ray is left alone"
D  no subdivision on stage ⇒ testTappingStressShowsIt…: "the main page draws the overlay subdivided for colour"
C  Stress map not opaque   ⇒ testHeatAndStressComposeIntoOneTintArray: ("0.0") is not equal to ("1.0")
   (alone, the render still moves 40,766 px, so the opaque flag is consistency with Heat, not what makes Stress visible; the comment says so)
nav: #354's three lines   ⇒ FlexibleSurfaceNavTests.testTheHookIsInPlace: 5 failures (the three pins, the two controls)
```
The targeted suite ran after the last source change. It covers every Flexible* suite, the brief's
list, SurfaceRound7, LatticePage and LatticeStressTint, and every suite that scans a touched
file (`verify_fixC/filter.txt`). Raw:
```
Executed 696 tests, with 9 tests skipped and 1 failure (0 unexpected) in 640.117 (640.185) seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
FLEX-STRESS his regions: sent by the app [101, 102, 103, 104] · reached [102, 103] · anchors [0] · loads ["[]/[103]"]
FLEX-STRESS the app's context: THROWS 'face region 101 "add": face id 23 out of range — the model carries 6 faces (valid ids 0..5)'
FLEX-STRESS reached context: 1.58 s, nonConvergent no, peak 0.0462 MPa, grid 64x64x13 @ 1.56 mm
FLEX-STRESS failed: state failed("face region 9 out of range") · line 'Couldn't simulate' · (i) 'Core could not solve the solid part: face region 9 out of range'
FLEX-STRESS view: part covers 52648 px of 262144; pixels moved > 30/255 by tapping Stress — batch C's mix 0 (control), now 41015
FLEX-STRESS gap distribution (8 part triangles): p50 0.0 p90 0.4329940207003857 p99 0.6555924242145883 worst 0.919175967520226 at SIMD3<Float>(99.77736, 0.0, 16.258484)
FLEX-STRESS gap distribution (25888 part triangles): p50 0.0 p90 0.0001223871748524877 p99 0.08084654396086854 worst 0.9306080160090178 at SIMD3<Float>(98.44118, 100.0, 2.1169252)
FLEX-STRESS dent on the subdivided part: 77178 of 77664 vertices move; worst off the unsubdivided dented surface 8.58e-08 mm
FLEX-LEGEND lattice ends '14% · ≈10.1 mm' … '36% · ≈3.7 mm' · scans for two reads: 1
FLEX-TAG '2.01 mm': (88.0, 61.0)
FLEX-TAG '22% density · ≈6.1 mm cell': (149.0, 61.0)
FLEX-PLAYER 11" portrait chip 0: (427.0, 1062.0, 340.0, 46.0)
FLEX-PLAYER 11" portrait chip 221: (427.0, 826.0, 340.0, 46.0)
FLEX-PLAYER 13" portrait chip 0: (526.0, 1244.0, 340.0, 46.0)
FLEX-PROBE stage: column 1086 1.07 mm · k 4.0 · reading '1.07 mm'
FLEX-PROBE stage side tap with the dent drilled in: '1.50 MPa' (stress)
```
The step-1 commit (without the three nav lines) was built and tested on its own: 48 tests in
the Flexible hook, view, verify and Surface suites, 0 failures. The step-2 tree (= the final
tree) passed 24 nav / hook / Surface tests, and the full targeted run above.

**iOS build (final tree):** `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration
Debug -destination id=147E56A1… -derivedDataPath …/flexA1 build` → `** BUILD SUCCEEDED **` (exit 0), no warning in a Flexible file. The app was not
launched.

**Deleted-test sweep (my diff):** none deleted. Re-pinned on purpose (each with the reason in
the test):
- FlexibleBatchCHookTests: H5', the Settings legend's tap target, the solver line.
- FlexibleMainPageHookTests: H2, H5.
- FlexibleSurfaceNavTests: H2.
- FlexibleMainViewsTests:
  - the drawn cell;
  - Stress on the map is opaque;
  - the Stress trigger test now drives the real solver;
  - the reading's MPa format.
- FlexibleLegendPlacementTests: the main player is centred right of the Selections column where
  the page centre would overlap it.

### Commits (on claude/flexible-screens, not pushed)

07eb7d1e Stress appears on his project and says what it is doing; Heat and Stress one at a time;
readings stay put · facfad6d [‹ Flexible] never gated, its label and ids (H9') · (this handoff +
DECISIONS amendments).

## Round 3 · batch C — the main Flexible page: views, legends, tap-to-read, Surface

(Superseded where the verification pass above says so: Stress no longer turns X-ray off, Exit
solves only while Stress shows, Heat and Stress are one at a time.)

**What you will see** (judged headlessly on YOUR project 0004 restored through `AppModel.open`
and on the pad; the app was NOT launched — nothing here has been seen on a screen yet):

- **Four views under the gizmo: [X-ray] [Dent heat] [Stress] [Lattice].** X-ray, Dent heat and
  Lattice are on by default; any mix works. Lattice turns X-ray on (batch B); **Stress turns
  X-ray off** so its colours read on a solid part (a ghost shows them only at its outline —
  turn X-ray back on and they stay, ghosted). While the FEA solves, the Stress button spins and
  a "Simulating…" line sits under the row.
- **Each data view has its own legend on the right edge** — #354's key squircle, (i) and
  caret: **"Squish · mm"** (the dent's own deep blue → cyan → white ramp, 0 … deepest, "×k"),
  **"Stress in the solid part · MPa"** (Stress's rainbow, 0 … peak; "Simulating…" while it
  solves), **"Lattice · density"** (the walls' pale → green, each end as "18 % · 9.2 mm").
  X-ray has none (your answer). The (i) holds the one sentence (the dent's says "What you
  drew" / "What the lattice was built from" and that it is drawn k× deeper).
- **Tap a legend → it reads "TAP THE PART TO READ"** (outlined in the accent). A tap on the part
  then pins a callout **at that spot: value and unit** ("2.01 mm", "1.50 MPa", "22% density ·
  6.1 mm cell") and a small arrow on the legend's ramp. It rides the part when you orbit.
  **A double tap anywhere (or the legend again) comes back out.** While reading, a tap never
  selects a face and the group primitives hide (#354's own drill-in, reused).
  - **The dent is read where you SEE it**: the tap's ray is cast against the map AS DRAWN (×k,
    at the squish on screen) and that column's number is read — the same number its colour
    came from. Read off the undented surface instead, a 30° view lands on a neighbour column
    (the test's red control: column 1017 instead of 1022 on your top A).
  - **The stress** is the solid part's field at the tapped point; **a wall** is read at its
    REST point (the squish pulled back), so density and cell are the wall's own, not the
    squished point's.
  - A tap that has nothing for the open legend reads another view that has something there,
    and the legend follows (a side of the part with Squish open and Stress on → "1.50 MPa",
    the Stress legend opens). Nothing at all → "— no squish here".
- **The Settings page's legend reads too**: "TAP TO READ" → tap it, tap the map → the true mm
  there; taps never select a face while it reads; double tap out. It is always X-ray (batch A).
- **Legends never cover a button**: placed on the trailing edge from the middle out, clear of
  the gizmo, the view row, the nav / Settings column, the bottom bar, the bottom-right chip
  column and the left panel; when the edge is full (11" landscape with the chip column) a second
  column opens to their left; a legend with no room at all becomes a small pill (tap it: it
  opens first). The squish player is placed after them and never covers one. Measured at 13" /
  11", portrait / landscape, with and without the chip column (raw lines below).
- **The Surface button**: top-left, **[‹ Topology] [Surface]** in identical chrome on the
  Flexible lattice stage; on Surface a Flexible project also has **[‹ Flexible]** straight
  back. Coming back does not re-pop Settings once Settings was saved this session (#354's own
  `latticeSettingsSavedThisSession`, set by Exit).
- **Never violet under Flexible**: the main page's lattice-depth prism of a Lattice group and
  its depth / expand knobs take the Flexible accent (a Solid group's prism: DS grey).
- **Stress runs by itself**: on Save & Exit, when you turn Stress on, and — while Stress shows —
  after a main-page edit that moves the loads (the solve checks its own fingerprint; nothing
  runs twice). It is the SOLID part's FEA with the main page's loads and the project's rigid
  material (hidden ABS) — the legend's title says "in the solid part", the (i) says it is not
  the TPU lattice.

**Not done (honestly):**
- **No simulator check, no screenshots.** The plan's step 5 (every combination of the four
  toggles on your project, tap each legend then the part, double tap out, the Surface round
  trip, screenshots of X-ray + Heat + Lattice and Heat + Stress) needs the app launched, which
  I must not do. `xcodebuild` for the simulator succeeds (below); everything else was measured
  headlessly.
- **#354's latent Surface / Settings overlap (4b11beb3) is NOT fixed**: on every Lattice page
  the forward [Surface] button (top-right) is still drawn under Settings
  (`settingsButtonTopInset` is computed and never used). Under Flexible the new top-left
  [Surface] reaches it; Structural / Aesthetic keep the hidden one.
- **The dent's callout is pinned where the drawn map was at the moment of the tap.** While the
  squish plays, the map moves under the arrow (the renderer steps the loop; nothing publishes
  per frame, so the callout cannot follow the dent). Pause the player to read at full squish.
- **Stress uses the main page's loads, not the Flexible weights** — since batch A the group IS
  the weight (a Flexible weight writes back), so they agree for every face a group presses; a
  face pressed only on the Flexible page (top B, faces 3 / 5 on your project) is not in the
  solid part's FEA.
- **Large parts**: the composed tint array is rebuilt only when an input changes, but the
  stress colours sample the field once per flat vertex then (fine on your pad; worth a look on
  the M2 stand). #354's per-update `VertexTintKey` hash (batch B's note) still applies.
- **The main page's mesh swap still reframes the camera** (batch B, #354's `applyMesh`).
- The octet's own Stress legend / view toggle can still show if `stressViewOn` was left on in
  an octet session of the same page before the part became Flexible (the octet toggle is not
  reachable under Flexible). Not seen; noted.

**Your call:**
- **Stress turns X-ray off.** I chose it so the button never paints something you cannot see
  (a ghost shows the colours only at its outline). Say if Stress should leave X-ray alone.
- **Stress solves on every Save & Exit when there is no current field** (the plan's rule), even
  with Stress off — about a coarse 64³ FEA of the solid part. Say if it should wait for the
  Stress button.
- **The second legend column** (11" landscape with the chip column): the Stress / Lattice
  legends open left of the Squish one rather than turning into pills. Say if you prefer pills.

### Hooks in #354 / main files (every line, grepped after the edit; pinned by FlexibleBatchCHookTests / FlexibleSurfaceNavTests / FlexibleNeverVioletTests / FlexibleMainPageHookTests)

| hook | file · anchor | ± | why |
|---|---|---|---|
| H4' | WorkspacePlaceholder · `vertexTints: visible.surfaceEditing ? surfaceVertexTints : flexibleMain.tints(project, on: stage` | ~1 | `, roles: roleTints, stress: latticeStressField)` — the ONE tint array (heat, stress, group colours, ghost); `stressTints` stays nil under Flexible (batch B) |
| H5' | · `if flexibleMain.owns(project, stage) { FlexibleMainViewToggles(main: flexibleMain` | ~1 | `, stressReady: latticeStressField != nil, stressRunning: latticeSimIsRunning, solve: { if let ctx = model.makeLatticeSimContext(), FlexibleStressTrigger.shouldRun(hasField: latticeSim.field != nil, stale: latticeSim.isStale(against: ctx.fingerprint), running: latticeSimIsRunning) { latticeSim.run(ctx) } })` — Stress, solved directly (the plan's H11 folded in: no +1 in H2's onExit — `didExitSettings()` asks the handed-over solver) |
| H6 | · after `latticeDensityLegend` / `latticeProbeCallout` inside `} else if !fullScreenPageUp {` | +1 | `if flexibleMain.owns(project, stage) { FlexibleMainLegends(main: flexibleMain, mode: $latticeLegendMode, projection: projection, settle: settleQuat, bottomClearance: bottomBarClearance, chipColumnWidth: …) }` |
| H7 | · onPickPoint, before `if latticeLegendMode.drilledIn { return true }` | +1 | `if flexibleMain.read(project, mode: latticeLegendMode, face: fid, point: pt) { return true }` — #354's consumption line stays, pinned |
| H8 | · `onLatticeProbe: latticeLegendMode.drilledIn` | ~1 | `&& flexibleMain.wantsWallProbe(latticeLegendMode)` — the wall probe only for the lattice legend (it claims any tap near a wall first) |
| H8 | · the probe closure, before `setLatticeProbe(at: model, world: world,` | +1 | `if flexibleMain.readLattice(project, mode: latticeLegendMode, model: model) { return }` |
| H9 | · `if let back = stage.back {` in `stageNavigationButtonOverlay` | ~1 | `HStack(spacing: PageChrome.gap) { stageNavButton(to: back, icon: "chevron.left"); if let x = FlexibleStageNav.extra(stage, flexible: …) { stageNavButton(to: x.dest, icon: x.icon, title: x.title) } }` — keep-out and `StageNavPlacement` stay on it |
| H9 | · `private func stageNavButton(to dest: WorkspaceStage, icon: String` | ~1 | `, title: String? = nil` |
| H9 | · `Text(dest.title)` in `stageNavButton` | ~1 | `Text(title ?? dest.title)` ("Flexible") |
| H13 | · `private func latticeRegionTint(_ role:` | +1 | `if let t = FlexibleMainTints.depthPlane(role, flexible: …) { return t }` — never violet under Flexible |
| H13 | · `latticeDepthKnob` / `latticeExpandKnob` · `LatticeDensityProxy.densityColor(fraction: 0.6)` / `(0.25)` | ~2 | wrapped in `FlexibleMainTints.knob(flexible: …, …)` |
| M4 | MetalMeshView · `func latticeProbe(` first guard | 1 token | `latticeInFrame || flexibleLatticeInFrame` — a tap on a Flexible wall is found (RED before: "⇒ nil") |

WorkspacePlaceholder: +4 lines, 8 lines edited (it said 9; corrected by the verification pass —
`git diff 8a7b3e39..0eae1ab7 --numstat` 12 / 8); MetalMeshView: 1 line edited. `startStressSolveIfNeeded`
is not edited (LatticeSimSolveTriggerTests reads its first 900 characters; pinned again here).
Every other pinned string holds (LatticeLegendColourTests 154 / 158 / 192 / 215 / 273,
LatticePreviewBodyAlphaTests, SmoothingPageRound2Tests' `fullScreenPageUp`, the viewModeToggles
cube). **Re-pinned on purpose:** FlexibleMainPageHookTests' H4 and H5 lines (their new text).

### Added / changed (track files)

- NEW `FlexibleProbe.swift` — `FlexibleReadKind` (three fixed ids, titles, units, ramps),
  `FlexibleReading`, `FlexibleProbe` (the dent ray against the drawn map, stress at the rest
  point, the wall pulled back, the lattice span / colour / cell), `FlexibleMainTints.compose`
  (the ONE array), `FlexibleStressTrigger`.
- NEW `FlexibleMainLegends.swift` — `FlexibleMainLegendLayout` (keep-outs, one stack on the
  edge, then a second column, then pills) and the legends + callout view (H6).
- NEW `FlexibleMainStage+Views.swift` — Stress (toggle, solver hand-over, field stash), the
  composed tints (H4'), the legend kinds / frames, tap-to-read (H7, H8).
- NEW `FlexibleStageNav.swift` (H9), `FlexibleDepthAccent.swift` (H13).
- `FlexibleMainStage` — Stress / reading / minimised state; channels built without the ghost
  (composed later); the drawn lattice and the map's deepest value kept; Save & Exit and a
  main-page edit (while Stress shows) ask for the solve.
- `FlexibleMainStatusPill` — the toggles gain Stress ("Simulating…"); the player keeps clear
  of the legends' real frames.
- `FlexibleStagePage` — the legend takes a tap ("TAP TO READ" → "TAP THE PART TO READ"), a tap
  reads the dent (never `tapFace`), a double tap out, the callout.

### Decisions rows (00-decisions.md §1b)

D-R3-15 the views, legends and tap-to-read · D-R3-16 the ONE tint array · D-R3-17 Stress under
Flexible (solved directly; Stress turns X-ray off) · D-R3-18 the Surface button · D-R3-19 never
violet under Flexible.

### Tests (raw)

RED first (the new suites against stubs of the new API — every test failing for its stated
reason, before any hook; `c_red1`):
```
Executed 16 tests, with 102 failures (4 unexpected) in 6.756 (6.762) seconds
FLEX-PROBE wall: covered 19521 px; probe at (0.501953125, 0.501953125) ⇒ nil · |F| inf
FLEX-TINT heat + stress: part 0/24 stress (ghosted), map 7200/7200 heat (opaque)
(and: every legend kind unplaced, no read / readLattice consumed, the hook pins absent, the
stress trigger never ran, the probes nil)
```
Mutation runs (each reverted in source, the tests run, the file restored; grep shows no marker):
```
M4 token removed (latticeInFrame alone) ⇒ testTheProbeFindsAFlexibleWall: "a tap on a Flexible wall is found" failed · probe ⇒ nil · |F| inf
dent read off the UNDENTED map (scale 0) ⇒ testTheDentProbeReadsTheColumnHeSees: ("1.68") is not equal to ("2.01"); callout 16.2 mm from the tap
                                         ⇒ testTheStageReadsHisDentAndSwitchesToStress: callout 8.56 mm from the tap (not < 1.5)
```
(The stage test's VALUE did not change under that mutation — its neighbour column 1081 carries the
same 1.07 mm on the built lattice — so it also pins the callout's place; the probe test is the
one whose value moves.)

Targeted suite after the last source change (every Flexible* suite + UnifiedShading,
LatticePreviewBodyAlpha, LatticeGBufferMask, LatticeThreeAlgorithmsDraw, OrganicCapsuleImpostor,
Viewer, StageBackdrop, SmoothingPageRound2, LatticeStageMode, LatticeSettingsPersist,
ProjectStore, UndoHistory, SurfaceStage, SurfaceRound7, LatticeSimSolveTrigger, and every suite
that scans or drives a file I touched — LatticeLegendColour, LatticeStressTint, LatticeBandChips,
OrganicPreviewBakeInputs, OrganicWalk0907Evening, LatticePreviewConfetti, SmoothingStrokeCamera,
SmoothingUsablePath, BottomBarMeasurement, LatticePageRound2, LatticeMode, SmoothingViewer,
VariantEntryGating, GroupViewState, LatticePreviewNoticeCaption, FrozenRegionAsMaterial,
LatticeGradingWiring, LatticeProbeSampling, LatticeRegionCap, LatticeSDFAlignment,
LatticeShellAndMarchAgree, OrganicAutoGradeAndFreeze, OrganicDeadWallParity,
OrganicLookAndVisibility, OrganicPreviewParameterParity, OrganicPreviewSpeedAndRim,
OrganicSolidRim, ProtectFreezeVsSolidity, SmoothingPage, SmoothingPreviewGate, SmoothingRound3,
SmoothingRound4, SurfaceStageGestures, VariantRetention), raw:
```
Executed 673 tests, with 9 tests skipped and 1 failure (0 unexpected) in 651.129 (651.208) seconds
  the one failure: LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (known, pre-existing)
FLEX-PROBE wall: covered 19521 px; probe at (0.501953125, 0.501953125) ⇒ SIMD3<Float>(27.295109, 27.983433, 19.390156) · |F| 1.0609627e-05
FLEX-TINT heat + stress: part 24/24 stress (ghosted), map 7200/7200 heat (opaque)
FLEX-TINT control: a part-sized stress buffer on the overlay mesh changes 0 px; an overlay-sized one 4532 px
FLEX-PROBE dent: column 1022 (2.01 mm) ⇒ drawn hit 1000103/1022 · reading '2.01 mm' · rest surface under the ray: 1000103/1017
FLEX-PROBE stage: column 1086 1.07 mm · k 4.0 · reading '1.07 mm'
FLEX-PROBE stage control: the rest surface under the ray is column 1081
FLEX-PROBE stage side tap with the dent drilled in: '1.50 MPa' (stress)
FLEX-PLACE legends 13" portrait chip 221: dent (760.0, 490.0, 248.0, 124.0) · stress (760.0, 626.0, 248.0, 124.0) · lattice (760.0, 762.0, 248.0, 124.0) · player (346.0, 1244.0, 340.0, 46.0)
FLEX-PLACE legends 13" landscape chip 221: dent (1104.0, 314.0, 248.0, 124.0) · stress (1104.0, 450.0, 248.0, 124.0) · lattice (1104.0, 586.0, 248.0, 124.0) · player (518.0, 900.0, 340.0, 46.0)
FLEX-PLACE legends 11" portrait chip 221: dent (562.0, 399.0, 248.0, 124.0) · stress (562.0, 535.0, 248.0, 124.0) · lattice (562.0, 671.0, 248.0, 124.0) · player (130.0, 1062.0, 341.0, 46.0)
FLEX-PLACE legends 11" landscape chip 0: dent (922.0, 311.0, 248.0, 124.0) · stress (922.0, 447.0, 248.0, 124.0) · lattice (922.0, 583.0, 248.0, 124.0) · player (427.0, 702.0, 340.0, 46.0)
FLEX-PLACE legends 11" landscape chip 221: dent (922.0, 355.0, 248.0, 124.0) · stress (662.0, 355.0, 248.0, 124.0) · lattice (662.0, 219.0, 248.0, 124.0) · player (427.0, 702.0, 340.0, 46.0)
```
(An earlier targeted run, before the legend stack / left-panel keep-out / file split: 672 tests,
9 skipped, the same one known failure.) Every Flexible suite alone at that stage: 203 tests,
4 skipped, 0 failures.

**iOS build:** `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration Debug
-destination id=147E56A1… -derivedDataPath …/flexA1 build` → `** BUILD SUCCEEDED **` (exit 0), no
warning in a batch-C file. The app was not launched.

**Deleted-test sweep (my diff):** none deleted. Re-pinned on purpose: FlexibleMainPageHookTests'
H4 and H5 lines (the tints call gained `roles:` / `stress:`, the toggles gained Stress).
The intermediate commits were not built one by one; the final tree was (above).

### Commits (on claude/flexible-screens, not pushed)

06951923 the views, the legends, tap-to-read, Stress (H4' H5' H6 H7 H8, M4) · 234e0495 the Surface
button and [‹ Flexible] (H9) · f968ee40 never violet under Flexible (H13) · (this handoff +
DECISIONS rows D-R3-15..19).

## Round 3 · batch B — verification pass

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
| #354 `claude/topopt-holes-quilting-298212` | `8f2504c2` Handoff, round 3: regions follow the slab … (round 5 merge, `4fb372e8`) |
| #358 `claude/raster-receipt-fields` | `90d9f874` Five follow-ups … (`f7c30c10`); **`4764ca7e` NOT merged — conflicts in core/src/cli/job.cpp (see "Round 5 · merge")** |
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
~~None. No core brief was needed: every number on screen comes from the C1 bridge contract.~~ **Superseded (round 4):** the plan's Core brief (items 1–15), plus #16 in round 4 batch D1 at the top.

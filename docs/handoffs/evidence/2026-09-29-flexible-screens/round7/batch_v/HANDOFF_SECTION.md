## Round 7 · batch R7-V — the views on both pages: icons only, Play, his pause holds, X-ray back, Settings' Heat and Bend (2026-10-14)

Your 2026-10-14 breakdown, the views half (img1, img3, img4, img5), with your two sets of answers. Built hook-free: **no #354 or
main file was touched** (WorkspacePlaceholder, MetalMeshView, ProjectModel unchanged). **The app was not launched**; the pictures
are offscreen — the shipping renderer for the part, the pages' SwiftUI chrome hosted over it — not device screenshots, and the
camera is the probe's (your img1 / img5 views), not the page's own framing.

**What you will see — the main Flexible page:**
- **Icons only.** "Role colours off" and "Prism after a pick" are gone. Both behaviours are now fixed on: the model wears no
  Selections role colour, and a group's prism and number show only after you pick the group in Selections (nothing on open,
  none for a Pending group).
- **Six view icons:** Heat · Stress · Lattice · Prisms · **X-ray** · **Play**. They sit on one line where the "Lattice ready"
  note still fits beside them; otherwise (11" portrait, the iPad mini) they wrap three over three.
- **Play is OFF when a project opens.** There is no play bar, and the model sits at rest. Heat keeps its full-load colours.
  Tap Play: the bar comes back and the squish plays. Play combines with every other view, and no other icon turns it off.
  While the sims run or refine, the Play icon carries a small spinning ring, because the bar's "Simulating…" line is hidden
  with the bar.
- **Your pause holds.** After you pause (❚❚, or a drag on the timeline), nothing restarts the squish: not an edit, a rebuilt
  lattice, its sims landing, Save & Exit, a Stress retry, or a legend's reading ending. Only Play restarts it (▶, or the Play
  icon).
- **X-ray is its own icon again, off by default.** The default view is the opaque model, with the heat on the pressed faces.
  For a Covered finish this is exactly the model. **Your pad is saved with Finish None** (pure lattice): its openings over the
  lattice are R7-X's printed view (step 2), so for now your pad's default view is the opaque model. X-ray on is today's look:
  the ghost, with the walls inside.
- **The Lattice icon is lit while its walls are seen**, which means in X-ray for now. Turning it on turns X-ray on too,
  following your rule "a view that needs another turns it on itself". [Prisms] also turns X-ray on, because a prism sits
  inside the part. Turning the lattice off leaves X-ray as you set it.

**What you will see — the Settings (squish) page:** three new icons under the gizmo, after [Prisms] [Groups]:
- **[Heat]** (the main page's thermometer).
  - It opens showing the **current group's** heat; the other groups' maps are uncoloured.
  - A **tap** hides the heat; another tap brings the current group's back.
  - A **3-second hold** shows **every group's** heat (fuller thermometer); its release does not undo it. A tap then hides it.
  - **The added layer is gone:** no group glass is drawn over a face that shows heat. Glass appears only where heat is hidden.
  - The legend card's heat rows show only while heat shows.
- **[Bend]** (a compress glyph).
  - It shows the current group **at full depth, every face at once, frozen**. On your pad, Group 2's Face 4 and Face 2 pinch
    together, and with a current lattice the 3D sim moves the whole part.
  - **Bend alone** (Heat hidden, no Prisms or Groups, no Play) shows only the bent model: no curve, chip, tag, prism or
    glass. With Heat or Prisms, the curves, chip, tags and prisms come back.
  - **With Play**, the bar animates and the full-depth pose shows as a faint ghost.
  - An edges/corners group says "No bend yet · core support pending".
- **[Play]**, the same Play view as the main page, shared: turning it on on one page turns it on on the other. With Play off
  there is no bar and the model sits at rest. With Play on, the squish plays, your drawing too.

### Your words → the fix → the test that pins it (tests FIRST: 15 tests red against API stubs, 71 failures — round7/batch_v/r7v_red_run.txt)
| your words (2026-10-14) | the fix | pinned by (RED control, run inside the test) |
|---|---|---|
| img1: "All view buttons should be icons - never full words. Remove the two full worded view icons." + your answer: no role colours on the main model, a group's prism only after a pick | the two chips, their store and copy deleted (`FlexibleMainViewSettings.swift` gone); `FlexibleMainPickSession` keeps the pick session fixed on (never a Pending group); `tints` never evaluates #354's roles; `roleMarks: false` on the main page; the toggles' frame = the row ∪ the note | `FlexibleRound7ViewsTests.testTheMainPageModelWearsNoRoleColourWhateverRolesAreHandedOver` (RED `controlRolesOnMain`: the roles and marks are found) · `testAGroupsPrismShowsOnlyAfterHisPickNeverOnOpenNorForAPendingGroup` (RED `controlPrismOnOpen`: the Top's prism on open) · hosted `FlexibleRound7ViewsHostedTests.testEveryViewRowIsIconsOnlyAndEachPageHasOneLegendCard` (RED: a worded chip beside the row is found by the same pixel scan — 17 420 px) |
| img1: "add a Play button icon … When it is on the simulation plays - otherwise, remove the play-bar from the bottom of the screen entirely." + img3: "Add a play-button view to show the animation play-bar or not." + your answer: Play OFF on open, at rest | `FlexibleStageViews.play` (shared, session only); the main page's [Play] (`togglePlay`, `playerShown` needs it); the loop's `playView` gate (off: every hold at rest, nothing automatic plays); Settings' [Play] gates its bar and opens its loop | `testPlayIsOffOnOpenAndOnlyPlayShowsTheBarAndPlays` (RED `controlPlayerIgnoresPlayView`: the bar is back with Play off) · hosted `testThePlayBarComesOnlyWithPlayOnBothPages` (both pages, 13" portrait and 11" landscape, the bar clear of every keep-out; Play on the main page is Play on Settings) |
| img1: "When the pause is selected for the simulator, any action taken anywhere automatically re-starts the simulation. Only by pressing Play should the sim actually restart." | `FlexibleSquishLoop.pausedByHim`: set by ❚❚ and a drag, cleared only by ▶ and the Play icon; `autoPlay` / `restartFromRest` / a reading's end only position the loop while it is set | `FlexibleSquishPlayerTests.testHisPauseHoldsUntilHePressesPlay` (RED `controlIgnoreHisPause`: autoPlay plays over it) · `testHisPauseHoldsAcrossAnEditUntilHePressesPlay` (his 0004 split: an edit → rebuild → sims landing, Save & Exit after a change, a reading — 0 plays; control 3) · `testAStressRetryLandingNeverUndoesHisPause` · `FlexibleSquishVerifyGTests.testSaveAndExitPausedByHimStaysPausedWhenItsFieldLands` (the twin of "plays once it lands") · hosted `testTheSettingsPagesLoopKeepsHisPauseAcrossAnEditAndARebuild` (0 plays; control 2) |
| img5: "Please re-add the x-ray view icon." (step 1) | `FlexibleMainStage.xrayOn` (off by default), `xray = xrayOn`; the [X-ray] icon (`square.stack.3d.up`); `ghostWalls` only in X-ray; [Prisms] and the Lattice icon turn X-ray on themselves; the lattice legend only while its walls are seen | `testXrayIsItsOwnIconOffByDefaultAndTheDefaultIsTheOpaqueModel` (RED `controlXrayIsLatticeView` = C2 + M6: the 0.04 ghost) · hosted `testXrayOffUnderTheCoveredFinishIsThePlainModel` (the shipping renderer, his pad set to Covered: lattice on vs off 0 px with X-ray off; control 59 601 px) |
| img3: "make the heatmap view actually show/hide the actual heatmap on the model. Turning it on should show all the Groups' heatmap … Holding it down for 3 seconds allows for all heatmaps across all groups/faces." + your answer: tap = the current group, hold 3 s = every group, tap again = hide (Settings only) | [Heat] on Settings (`heatOff` / `heatAll` bits); `FlexibleViewButton.onLongPress` (3 s, the release tap swallowed by the press — ViewModeHold, copied from #354's pattern, not edited); `composeTints` colours only the scope's maps (`FlexiblePageChannels.channels(heatRegions:)`) | `testTheSettingsHeatShowsTheCurrentGroupEveryGroupOrNone` (Group 2 open: off [] · group [2, 4] · all [1…5]; RED `controlHeatAlwaysOn`: Face 1 coloured under off and group) · hosted `testTheHeatIconTapCyclesAndAThreeSecondHoldShowsEveryGroup` (RED `controlNoSwallow`: the release tap undoes the hold) |
| img3: "… it adds a layer of a heat map? I don't understand? Remove that." | no group glass over a face whose heat shows (`FlexibleStageVolumes.items(heated:)`); a hidden-heat face's glass is judged over the page's ground (`heatSamples` keeps the heat's own colours only); the legend's heat rows only while heat shows | the same test (glass with every heat shown [0, 1, 3, 5] — none over heated 2, 4; heat hidden: every group's glass) · re-pinned `FlexibleRound6Tests.testEachGroupsGlassReadsAsItsColourOverTheHeat` (measured where the glass is drawn: heat hidden) |
| img4: "There should also be a 'bend' icon view … the entire group's bend at the full depth - all together … turned on on its own, showing the entire 3d model at its full squish depth." + your answer: every face of the group, full depth, frozen | [Bend] on Settings: `dentScale = k × 1` while Bend shows without Play (the current group's dents — the FE field moves the whole part; stale: every face's column dent); Bend alone hides the overlays and the rest-pose prisms and glass; Bend + Play: the full pose as a faint ghost (`FlexibleBendGhost`); an edges group says "No bend yet · core support pending" | `testTheBendViewHoldsTheWholeGroupAtFullDepth` (his pad, Group 2: face 4 11.7 and face 2 10.6 mm/k, the Top's part vertices 11.3 — the whole part; stale: face 4 23.5, face 2 19.0, Face 1 0; RED: no Bend → k × amount, below k mid-cycle) · hosted `testBendAloneShowsOnlyTheBentModelAndHeatBringsTheOverlaysBack` (overlay px: editing 5 554 · Bend alone 0 · Bend + Heat 5 554) |
| (2f) one legend card on each page | the main page's scales ride the ONE card; Settings builds ONE `FlexibleLegend` | hosted `testEveryViewRowIsIconsOnlyAndEachPageHasOneLegendCard` |

### Rulings this batch reverses (your 2026-10-14 words win)
- **C2** (commit 140c8d454, your round-4 img 5: "remove the xray view selector … the lattice view is going to use the
  rendering anyways"): X-ray is its own icon again, and the Lattice view no longer IS the X-ray.
- **M6** (batch M, your round-5 img 6: "When the dent view is selected, the xray view should also initiate"): the dent view no
  longer turns X-ray on. It still decides whether the walls are a ghost under its solid planes *in* X-ray.
- **Batch V's two view settings** (your 2026-10-10 request, "Bring both back as a view setting that can each be turned off at
  will"): removed, with both behaviours fixed on. The settings are no longer kept per project in the app's defaults; your
  stale keys (`flexible.mainViewSettings.<id>`) are removed once, when a project opens.
- **Round 3's Settings "editing hold at full squish"** ("while he edits it holds still"): with Play on, the squish plays,
  your drawing too ("When it is on the simulation plays"). With Play off, the default, it sits at rest (your answer).
- **R6's Groups glass over the heat** (R6 review: each glass's alpha set over its own heat): no glass is drawn over a heated
  face now. The alpha rule still applies wherever heat is hidden.

### Decisions to flag (not asked, said here)
- The Heat view's bit is stored as **"heat hidden"** (`FlexibleStageViews.heatOff`, with `heatAll` for every group). That
  way the page opens with the current group's heat with no first-open flag, and FlexibleStageModel.swift is not edited
  (R7-S's file). The brief named the bits `.heat` / `.heatAll`; the behaviour is the same.
- **Play is shared session state** (`FlexibleStageViews.play`), never a setting: Exit stays "Exit".
- **The pause latch lives in the loop class** (`FlexibleSquishLoop.pausedByHim`), so the Settings page's own loop keeps your
  pause too. While paused, a new lattice or sequence starts where you left it: held there, cycle 0, the new field bound at once.
- **Play all while paused:** the group on screen is held, and a new lattice resets it to its first group (cycle 0).


### Re-pins (each attributed in the test to your 2026-10-14 words, naming the ruling it reverses)
| class | what changed |
|---|---|
| FlexibleBatchVHostedTests | V1a / V1b keep their fixed-state cases. The OFF flips are gone; their positive controls are now `controlRolesOnMain` / `controlPrismOnOpen`. V1c (kept per project) and V1d (the chips) are removed with the toggles; the legend card's two places beside the icon row stay pinned (`testTheLegendCardKeepsItsPlacesBesideTheIconRow`). `mainStage()` no longer takes a store. |
| FlexibleBatchVReviewTests | VR1 → `testTheMainPageModelShowsNoSelectionsColourAtHisCamera` (the ticked case, fixed: no Top blue, no Anchor green at your img1 camera). VR2 (Undo/Redo is never a pick) is carried over unchanged, except its `viewSettings.prismAfterPick` premise line. |
| FlexibleBatchVEvidenceProbe | its OFF renders are gone |
| FlexibleS1bMainTagsTests ×2, FlexibleRound6HostedTests (`testSelectingAGroupOnTheMainPageShowsItsSquishAtOnce`) | S1b's rule (the active group's prism, a Pending group's too) is now only the test control `controlPrismOnOpen`. These pin the tags' placement, not the rule. A plain pick cannot show Group C, which is Pending. |
| FlexibleRound6HostedTests (`testTheMainPageWearsNoGroupColourInAnyViewOrTurn`), FlexibleBatchCVerifyTests (`testTheTintHookIsInertOffTheFlexibleStage`) | the roles and marks come only through `controlRolesOnMain` |
| FlexibleRound6HostedTests ×3 | six icons (one line of six; three over three at 11" portrait and on the iPad mini); [Prisms] turns X-ray on itself (C2 reversed); the [Prisms] / Lattice click positions in both layouts |
| FlexibleMainPageRound4Tests ×4, FlexibleMainPageRound4HostedTests ×2, FlexibleMainPageRound4VerifyTests ×1 | X-ray back as its own toggle and Play added (C2 reversed); X-ray follows your icon; the dent view no longer keeps the part a ghost (M6 reversed); the note sits beside the row again (batch V's settings line gone); the Lattice click: lit while its walls are seen |
| FlexibleBatchBReviewUXTests (`testTheLatticeViewTurnsXRayOn`) | X-ray off by default; turning the lattice on turns X-ray on; turning it off leaves X-ray alone |
| FlexibleBatchCVerifyTests ×2, FlexibleMainViewsTests ×2 | your X-ray on where they pinned batch C's default X-ray view; the dent read at full squish opens the loop's Play gate |
| FlexibleBatchMXrayTests, FlexibleBatchMVerifyTests, FlexibleBatchMLegendTests | their fixtures turn your X-ray on (M6 reversed: X-ray is no longer derived). M6's rule is now the red control `controlXrayIsLatticeView`, used with `controlDentXrayOnFallback` for batch M's fallback control. |
| FlexibleSquishVerifyGTests, FlexibleRound5SquishExitTests, FlexibleSquishSolverTests, FlexibleBatchMGroupTests | their fixtures turn Play on (Play is OFF on open); no assertion changed. A new twin, `testSaveAndExitPausedByHimStaysPausedWhenItsFieldLands`, pins "paused stays paused" beside "plays once it lands". FlexibleBatchNRefineTests, FlexibleSquishPlayAllTests and FlexibleBatchCVerifyTests' loop tests passed unchanged (the brief expected them to need Play inserted). |
| FlexibleRound6Tests ×2 | the page composes R6's tints with every group's heat (`heatAll`); the glass is measured where it is drawn now, with the heat hidden (`heatOff`); the page-source pin includes `heated:` |
| FlexibleSquishPlayerTests | +1 test (the latch) |


### What looking found (the pictures: round7/batch_v/)
- **Bend alone drew the group's glass and the stamp prism at the REST pose** beside the bent model: a floating pink outline
  and a purple prism where the faces used to be. **Fixed:** with Bend alone, `FlexibleStageVolumes.items` returns nothing.
  This is pinned in the hosted bend test, with a positive control. R7V_S_13p_bend_alone.png is the fixed render; the first
  render was overwritten.
- The first Settings composite put the model under the panel; the probe now places it where the page leaves room. This was
  an evidence fix only, not a code change.
- The Play icon's working ring is small and grey: macOS renders its mini spinner faintly. It shows; it is not tinted.
- On your pad with X-ray off, nothing of the lattice shows: Finish None, step 1 (open question 1).

### The runs (round7/batch_v/r7v_runs.txt, r7v_red_run.txt)
- **Red run first:** 15 tests against the API stubs, all red, 71 failures.
- **Green:** the 15 new tests, plus the twin `testSaveAndExitPausedByHimStaysPausedWhenItsFieldLands`.
- **Targeted suite, run 1:** 110 classes (every Flexible* class, plus LatticeSettingsPersistTests, LatticeSimSolveTriggerTests,
  LatticeStaleTypeTests (6/6), ProjectStoreTests, SmoothingPageRound2Tests, UndoHistoryTests and ViewerTests), 10 per run,
  unseeded, no xctest death. 16 classes failed: 14 were the re-pins above (that binary predates the test edits), and 2 are
  known.
- **Re-run of those classes after the re-pins:** all green except the 2 known.
- **Targeted suite, run 2, on the final code:** 108 of 110 classes pass. 682 tests, 45 skipped, 9 failures, every one known
  and pre-existing:
  - FlexibleBatchNVerifyTests.testEveryRefineLineIsWholeBesideTheLivePlayAllPicker ×8 (Xcode 27 text metrics);
  - LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds ×1.

  Every re-pinned class was green twice in a row (the re-run, then run 2).
- **Goldens:** FlexibleAngledGoldenTests 0 DIFFERS in both modes.
  - Deterministic: 38 identical, 0 DIFFERS.
  - Unseeded: 32 identical, 0 DIFFERS, 1 PART-SKIP (the raw subtree bytes need the deterministic hash, as before).
- **The 16 stage-job hashes:** every row byte-identical to batch I2's (stage_job_hashes_r7v.txt vs
  angled_presses/stage_job_hashes_i2.txt; the diff is empty). The stage job never reads Flexible.
- **iOS:** BUILD SUCCEEDED at the final code (05:57:50, ~/Library/Developer/Xcode/DerivedData/flexA1). The built
  TopOpt.debug.dylib carries "flexible-main-view-xray", "flexible-main-view-play", "flexible-settings-view-bend" and "No bend
  yet". It was **not installed** (that is the merge step's) and **never launched**.

### Files
- **New:**
  - FlexibleRound7Views.swift: the view bits, the Heat scope, FlexibleStageHeat, FlexibleBendGhost.
  - FlexibleMainStage+Play.swift: togglePlay, toggleXray, showLatticeView, viewsChanged.
  - FlexibleMainPickSession.swift: replaces FlexibleMainViewSettings.swift, which is deleted.
  - FlexibleRowCopy+Views.swift.
  - Tests: FlexibleRound7ViewsTests, FlexibleRound7ViewsHostedTests, FlexibleRound7ViewsEvidenceProbe.
- **Edited (all Flexible, ours):** FlexibleSquishPlayer (the latch and the Play gate), FlexibleMainStage, +Views, +Squish,
  FlexibleMainStatusPill (six icons, no chips), FlexibleMainLatticeView, FlexibleProbe (rolesOverMarks gone),
  FlexibleRowCopy (the chips' copy gone), FlexiblePageChannels (heatRegions), FlexibleStagePage, FlexibleStageViews,
  FlexibleStageVolumes, FlexibleViewControls (onLongPress), FlexibleGroupWalls (heatSamples: the heat's colours only).
- **The R7-S overlap:**
  - FlexibleStagePage: my hunks are the init, the stubs-turned-statics after it, the ticker, the new `.onAppear` /
    `.onChange(of: model.views)` after the legend-drill line, the clearance line, the overlay gate in `stage`, composeTints,
    refreshChannels' play / scale / ghost block, `player(in:)`, the legend call and FlexibleLegend.shows. I did not touch
    present() or FlexibleStageOverlays.
  - FlexibleRowCopy: only the four batch-V lines were deleted.

### Open questions
1. **His pad is saved with Finish None (pure lattice).** With X-ray off, the default view on it is the opaque model until R7-X's
   printed view shows the lattice through the openings (step 2). Ship step 1 as is? (It is exact for Covered; pinned by H6.)
2. **The Lattice icon turns X-ray on**, and it is lit only while the walls are seen. This follows your "a view that needs
   another turns it on itself" for step 1, where walls are drawn only in X-ray. Keep it, or should the Lattice icon stay a
   pure show/hide until R7-X?
3. **While paused, the loop is still positioned** by the existing rules: your drawing at full while the lattice is stale, then
   rest while the sims run (r7v_playing_trace.txt: held 0.38 → 1.00 → 0.00, never playing). Should your pause also freeze the
   position where you left it?
4. **Settings with Play on:** the squish now plays your drawing too. Round 3's "while he edits it holds still" is reversed
   by "When it is on the simulation plays". Confirm.
5. **Glass over a face whose heat is hidden** is judged over the page's ground, as a resting face's is. The re-pinned R6
   measurement passes (ΔE ≥ 10, ≤ 32), but the open group's glass in the Groups view now sits over the X-ray ghost, not over
   heat.
6. (From the plan) **The Stress icon** stays on the main page; Heat in X-ray reusing the card's Stress row is R7-X.

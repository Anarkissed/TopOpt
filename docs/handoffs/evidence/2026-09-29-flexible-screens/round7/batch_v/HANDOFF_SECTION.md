## Round 7 · batch R7-V — the views on both pages: icons only, Play, his pause holds, X-ray back, Settings' Heat and Bend (2026-10-14, with the verify's fixes)

Your 2026-10-14 breakdown, the views half (img1, img3, img4, img5), with your two sets of answers. Built hook-free: **no #354 or
main file was touched** (WorkspacePlaceholder, MetalMeshView, ProjectModel unchanged). **The app was not launched**; the pictures
are offscreen — the shipping renderer for the part, the pages' SwiftUI chrome hosted over it — not device screenshots, and the
camera is the probe's (your img1 / img5 views), not the page's own framing.

**What you will see — the main Flexible page:**
- **Icons only.** "Role colours off" and "Prism after a pick" are gone. Both behaviours are now fixed on: the model wears no
  Selections role colour, and a group's faint prism shows only after you pick the group in Selections (nothing on open, none
  for a Pending group).
- **No squish number on the main page** (your answer: "The squish number: only on the Squish page") — not after a pick, not
  under [Prisms]. Your img2 "12.0 mm" is gone. The face-prism's own number, tap-to-edit and equal to the list, is R7-M's.
- **Six view icons:** Heat · Stress · Lattice · Prisms · **X-ray** · **Play**. They sit on one line where the "Lattice ready"
  note still fits beside them; otherwise (11" portrait, the iPad mini) they wrap three over three.
- **Play is OFF when a project opens.** There is no play bar, and the model sits at rest. Heat keeps its full-load colours.
  Tap Play: the bar comes back and the squish plays. Play combines with every other view, and no other icon turns it off.
  While the sims run or refine, the Play icon carries a **turning blue arc** on its rim; when a sim failed (or its refine did
  not land) it carries an **orange dot** — turn Play on and the bar says why. (The bar's lines are hidden with the bar.)
- **Your pause holds — and the model stays where you paused it.** After you pause (❚❚, or a drag on the timeline), nothing
  restarts or moves the squish: not an edit, a rebuilt lattice, its sims landing, Save & Exit, a Stress retry, or a legend's
  reading ending; a new field binds at your paused amount. Only Play restarts it (▶, or the Play icon). Play off puts it at
  rest.
- **X-ray is its own icon again; its starting state follows your finish.** With **Covered**, X-ray starts OFF: the opaque
  model, which is the print (the skin hides the lattice). With **None, Rim or Skin**, X-ray starts ON, so your lattice shows —
  **your pad is saved with Finish None**, so it opens in X-ray, the lattice inside the ghost. This lasts until R7-X's printed
  view, which will show the lattice through the finish with X-ray off. Your tap on X-ray wins and is kept for the session
  (per project). X-ray off hides the walls under every finish for now.
- **The Lattice icon is lit while its walls are seen**, which means in X-ray for now (so it is lit as your None pad opens). Turning it on turns X-ray on too,
  following your rule "a view that needs another turns it on itself". [Prisms] also turns X-ray on, because a prism sits
  inside the part. Turning the lattice off leaves X-ray as you set it.

**What you will see — the Settings (squish) page:** three new icons under the gizmo, after [Prisms] [Groups]:
- **[Heat]** (the main page's thermometer).
  - It opens showing the **current group's** heat; the other groups' maps are uncoloured.
  - A **tap** hides the heat; another tap brings the current group's back. Hiding the heat also ends a legend reading, so a
    tap on the part selects again.
  - A **3-second hold** shows **every group's** heat — the icon then carries **three small dots in your groups' colours**, so
    "every group" is told from "this group" at a glance. Its release does not undo it. A tap then hides it.
  - **The added layer is gone:** no group glass is drawn over a face that shows heat. Glass appears only where heat is hidden.
  - The legend card's heat rows show only while heat shows.
- **[Bend]** (a compress glyph).
  - It shows the current group **at full depth, every face at once, frozen**. On your pad, Group 2's Face 4 and Face 2 pinch
    together, and with a current lattice the 3D sim moves the whole part.
  - **Bend alone** (Heat hidden, no Prisms or Groups, no Play) shows only the bent model — **opaque and shaded**, so the
    full-depth shape reads (it was a near-black ghost): no curve, chip, tag, prism or glass. With Heat, the heat colours the
    bent faces over the X-ray ghost, and the curves, chip, tags and prisms come back (they stand at the rest pose — open
    question 4). With the heat hidden and Prisms, Groups or Play, the body is at 30 %.
  - **With Play**, the bar animates and the full-depth pose shows as a faint ghost.
  - An edges/corners group says "No bend yet · core support pending".
- **[Play]**, the same Play view as the main page, shared: turning it on on one page turns it on on the other. With Play off
  there is no bar and the model sits at rest (your curve shows as colour only — turn on Bend to see the full dent). With Play
  on, the squish plays, your drawing too. Its icon carries the same blue arc (the 3D sim running) and orange dot (it failed).
  At 11" portrait the bar's line takes a shorter form when the long one would be cut ("Column preview").

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

### The verify's findings → the fix → the test (2026-10-14; tests FIRST: 12 red against stubs, 47 failures — round7/batch_v/r7v_review_red_run.txt)
The verify looked at this batch on your pad (simulator-style hosted pages and the shipping renderer) and confirmed 4 majors
and 13 minors. Every major and the cheap, safe minors are fixed; the rest are questions below.
| finding (verify) | the fix | pinned by (RED control, run inside the test) |
|---|---|---|
| MAJOR — your pad (Finish None) opened as an opaque grey block with **no lattice at all**, the Lattice icon unlit; your img5: "we should be able to see the model +the finish in the latticed area (and pure lattice if 'off' is set)" | X-ray's starting state follows the finish (`FlexibleMainStage.xrayDefault`): off for Covered, ON for None / Rim / Skin, until R7-X's printed view; your tap wins, kept per project for the session (`xrayChoice`) | `FlexibleRound7ViewsTests.testXrayOpensOnForAFinishThatShowsTheLatticeAndOffForCovered` (None: X-ray on, walls drawn, Lattice icon lit; Covered off; Rim / Skin on; your choice outlives a finish change — RED `controlXrayOffOnOpen`: the opaque block, no wall, icon unlit) · hosted `testANonePadOpensInXrayAndXrayOffHidesTheWallsUnderAnyFinish` (the shipping renderer: walls seen on open 4 671 px; X-ray off hides them under None too, 0 px — H6 had proved it for Covered only; RED: 0 px) |
| MAJOR — Settings, **Bend alone** drew the bent part as a near-black smudge (the page is always X-ray, and no heat was on it); your img4: "showing the entire 3d model at its full squish depth" | Bend with the heat hidden draws the part to read (`FlexibleStagePage.bodyAlpha(views:…)`): Bend alone OPAQUE and shaded; with Prisms / Groups / Play at the dent's 30 %; Bend with Heat keeps the X-ray ghost under the opaque heat | hosted `testBendAloneDrawsTheBentPartReadableAtItsFullDepth` (his Group 2 pinch, its 3D field, the shipping renderer: the part reads — bright px and the bend against the rest pose, many times the ghost's; RED `controlBendGhost`: the 0.04 ghost) |
| MAJOR — picking the Top drew **"12.0 mm"**, the squish number your img2 asked off ("this 12mm is completely worthless … please remove whatever it is"); your answer: "The squish number: only on the Squish page" | the main page draws NO squish number — after a pick or under [Prisms] (`prismTags` returns none; the faint prism after your pick stays). The face-prism's own depth, tap-to-edit, is R7-M's | `testNoSquishNumberOnTheMainPageAfterAPickOrUnderPrisms` (after the pick: the Top's prism, no tag; [Prisms]: 5 prisms, no tag — RED `controlSquishTagsOnMain`: "12.0 mm", "19.0 mm", "24.5 mm", "22.5 mm", "19.5 mm") |
| MAJOR — Settings: hiding the heat **while the legend read** left the page stuck reading (every tap on the part read; none selected a face); with the heat hidden, its TAP TO READ strip still drilled in | the reading ends when the heat goes hidden (`.onChange(of: reads(…))`), and the strip takes a tap only while it can read (`FlexibleStagePage.reads`: a dent AND the heat shown) | hosted `testHidingTheHeatEndsTheReadingAndItsStripNeedsTheHeat` (his pad, the page hosted: drilled → Heat hidden → reading over; RED `controlKeepReadingWithoutHeat`: still reading. The strip's rule pinned. The hosted harness's clicks land on the MTKView under the chrome, so the drill is driven through a test seam, `testDrill`) |
| minor — your **paused pose still jumped** after an edit (0.38 → 1.00 → 0.00): it looked like the sim restarting | your pause FREEZES the pose (`FlexibleSquishLoop.hold` keeps it while you paused; a new field binds at it); Play off still sits at rest | `testHisPauseFreezesThePoseUntilHePressesPlay` (paused at 0.75: holds 1 / 0, a landing, a reading → 0.75; RED `controlPauseMovesPose`: → 1.00) · the trace, round7/batch_v/r7v_playing_trace.txt |
| minor — with Play off the sims' status was a **faint grey speck**, a failed sim said nothing, and the Settings Play icon had no status | both Play icons: a turning blue arc while the sims run / refine, an orange dot when one failed (`FlexiblePlayBadge`); the spoken value says it too | `testThePlayIconsSayWhenTheSimsWorkOrFail` (main: running, refining → working; failed, skipped, refine kept → failed; Settings from its bar's line) · hosted `testThePlayIconsRingAndDotAreSeenWithPlayOff` (ring 404 px, dot 180 px; RED `controlMiniSpinner`: 0 / 0) |
| minor — Settings [Heat]: **"this group" and "every group" looked the same** | under your 3 s hold the icon carries three small dots in your groups' colours (`FlexibleHeatAllBadge`) | hosted `testTheHeatIconSaysEveryGroupAtAGlance` (416 px between the two; RED `controlNoHeatAllBadge`: 24 px, the glyph alone) |
| minor — Settings at 11" portrait, Play on: the bar's line was **cut** ("Column preview · no lattic…") | the line takes the first shorter form that fits beside the picker ("Columns · no lattice yet", "Column preview", "Columns"; `FlexibleRowCopy.shortForms`) | `testEverySettingsPlayerLineHasShorterForms` · hosted `testTheSettingsPlayerNoteIsWholeAtElevenInchPortrait` (the full line needs 220 pt, 111.5 pt free; the drawn form is whole; RED: no short forms — the cut line) |
| minor — the re-pinned VR1 pixel test **could not fail** (its positive control had gone) | its positive control is back, in the same frame and probe | `FlexibleBatchVHostedTests.testTheMainPageModelShowsNoSelectionsColourAtHisCamera` (fixed 0 px; control, the roles composed in: 2 366 px Top blue) |

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
- **S1b's main-page squish tags** (round 6 item 3, your img3 then: "we should automatically be able to see the amount of
  squish it has been set to"): reversed by your 2026-10-14 img2 and answer ("The squish number: only on the Squish page").
  The faint squish prism after your pick and under [Prisms] stays; the placement code stays for R7-M's face-prism chips.

### Decisions to flag (not asked, said here)
- The Heat view's bit is stored as **"heat hidden"** (`FlexibleStageViews.heatOff`, with `heatAll` for every group). That
  way the page opens with the current group's heat with no first-open flag, and FlexibleStageModel.swift is not edited
  (R7-S's file). The brief named the bits `.heat` / `.heatAll`; the behaviour is the same.
- **Play is shared session state** (`FlexibleStageViews.play`), never a setting: Exit stays "Exit".
- **The pause latch lives in the loop class** (`FlexibleSquishLoop.pausedByHim`), so the Settings page's own loop keeps your
  pause too. While paused, a new lattice or sequence starts where you left it: held there, cycle 0, the new field bound at once.
- **Play all while paused:** the group on screen is held, and a new lattice resets it to its first group (cycle 0).
- **(review) X-ray's starting state follows the finish** — a stopgap until R7-X's printed view, so your None pad never opens
  with its lattice hidden. The reviewer may rule otherwise (the verify offered three options); it is one property
  (`xrayDefault`).
- **(review) Your pause freezes the pose** (my open question 3, answered by your img1 words: "Only by pressing Play should the
  sim actually restart" — a model that moves after your pause reads as a restart).
- **(review) The squish number left the main page now**, not with R7-M: these batches are installed one by one, and the 12 mm
  would have stayed in front of you until R7-M. R7-M keeps its plan (face-prism chips, tap-to-edit).
- **(review) A test seam on the Settings page** (`FlexibleStagePage.testDrill`, a subject nothing in the app sends): the hosted
  harness's clicks land on the MTKView under the chrome (AppKit's hit test), so the legend's drill is driven through it.


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
| (review) FlexibleRound7ViewsTests (`testXrayIsItsOwnIconOffByDefaultAndTheDefaultIsTheOpaqueModel`) | X-ray off by default is pinned under the Covered finish (set first); your None pad now opens in X-ray (the review's RV1) |
| (review) FlexibleRound6HostedTests (`testPrismsTurnsTheLatticeViewOnItself`) | your None pad starts in X-ray; X-ray is turned off first, then [Prisms] turns it on itself |
| (review) FlexibleRound6HostedTests (`testSelectingAGroupOnTheMainPageShowsItsSquishAtOnce`), FlexibleS1bMainTagsTests ×4 | the main page draws no squish tag now (your img2 / answer); S1b's tags come through `controlSquishTagsOnMain`. They pin the tags' placement (leader, greedy pass, axis slide, keep-outs), which R7-M's face-prism chips reuse — not that the number shows |
| (review) FlexibleBatchVHostedTests (V1b) | after your pick: the Top's prism, NO number; S1b's "12.0 mm" is the red control |
| (review) FlexibleBatchVReviewTests (VR1) | its positive control is back (the roles composed in: 2 366 px Top blue; fixed 0) |


### What looking found (the pictures: round7/batch_v/)
- **Bend alone drew the group's glass and the stamp prism at the REST pose** beside the bent model: a floating pink outline
  and a purple prism where the faces used to be. **Fixed:** with Bend alone, `FlexibleStageVolumes.items` returns nothing.
  This is pinned in the hosted bend test, with a positive control. R7V_S_13p_bend_alone.png is the fixed render; the first
  render was overwritten.
- The first Settings composite put the model under the panel; the probe now places it where the page leaves room. This was
  an evidence fix only, not a code change.
- (first build) The Play icon's working ring was small and grey — the verify confirmed it read as a speck. **Fixed in the
  review:** the blue arc and the orange dot (R7V_review_13p_main_play_working.png / _failed.png).
- (first build) On your pad with X-ray off, nothing of the lattice showed (Finish None, step 1). **Fixed in the review:** a
  None pad opens in X-ray — R7V_M_img1_default_none_xray_on_13p.png / _img5_… / _11l: the walls on the side faces, the heat
  opaque on the Top (the dent view's plane, as before: the walls under the Top show once Heat is off — R7-X's heat in X-ray).
  R7V_M_img1_xray_off_13p.png is your tap (the opaque model). R7V_M_img1_default_covered_xray_off_13p.png is the Covered
  finish's default (opaque); the finish change made the lattice stale, so that frame shows your drawing's heat on every
  pressed face until the rebuild.
- (review) **Bend alone now reads**: R7V_S_13p_bend_alone.png — the opaque, shaded part with Group 2's pinch at full depth;
  R7V_RH2_bend_alone_fixed.png vs R7V_RH2_bend_alone_control_ghost.png (the first build's near-black ghost), same camera.
- (review) The Heat icon under the hold: R7V_review_13p_settings_heat_all_badge.png (three dots, top right).
- (review) 11" portrait, Play on: R7V_review_11p_settings_player_note.png — "Column preview", whole, beside "Group 2".
- (review) The trace: r7v_playing_trace.txt — paused at 0.37, the edit, the rebuild, the sims pending and landing: held 0.37
  throughout, never playing, until your ▶. (The first build's trace went 0.38 → 1.00 → 0.00; the probe's wait also stopped
  before the sims had started — it now waits for them to land.)
- Superseded pictures removed: R7V_M_img1_default_xray_off_play_off_13p / _11l, R7V_M_img5_default_xray_off_play_off_13p,
  R7V_M_img1_xray_on_13p, R7V_M_img5_xray_on_13p (the first build's default and its X-ray tap; replaced by the files above).

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

### The review's runs (round7/batch_v/r7v_review_runs.txt, r7v_review_red_run.txt)
- **Red run first:** 12 tests (the 11 new + VR1's restored control) against API stubs keeping the first build's behaviour —
  47 failures, each for its reason (RH3's click premise also failed there: the harness's clicks land on the MTKView, so RH3
  drives the drill through `testDrill`; VR1's control threshold came from batch V's frame and was set to what the control
  finds).
- **Green:** the 11 new tests and VR1, after three test-side fixes (RH1's threshold within X-ray; RH2 counting pixels that
  READ, not pixels off the ground; RH6's shortest form "Columns").
- **The likely-affected classes** (23): only the re-pins failed (FlexibleRound6HostedTests ×2 tests, FlexibleS1bMainTagsTests
  ×4, FlexibleBatchVHostedTests V1b) and the known FlexibleBatchNVerifyTests ×8. Re-pinned, then green; green again in run 3.
- **Targeted suite, run 3, on the final code:** 108 of 110 classes pass. 693 tests (682 + the 11 new), 45 skipped, 9
  failures, every one known and pre-existing: FlexibleBatchNVerifyTests.testEveryRefineLineIsWholeBesideTheLivePlayAllPicker
  ×8 (Xcode 27 text metrics), LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds ×1. LatticeStaleTypeTests 6/6.
  No xctest death.
- **Goldens:** FlexibleAngledGoldenTests 0 DIFFERS in both modes — deterministic 38 identical; unseeded 32 identical, 1
  PART-SKIP (as before).
- **The 16 stage-job hashes:** re-dumped at the review's code — the whole file byte-identical to batch I2's
  (stage_job_hashes_r7v.txt vs angled_presses/stage_job_hashes_i2.txt; the diff is empty).
- **iOS:** BUILD SUCCEEDED at the final code (10:29, ~/Library/Developer/Xcode/DerivedData/flexA1; the dylib carries the
  review's strings). **Not installed** (the merge step's), **never launched**.

### Files
- **New:**
  - (review) FlexiblePlayBadge.swift: the Play icons' status (arc / dot) and the Heat icon's "every group" dots.
  - (review) Tests: FlexibleRound7ViewsReviewTests (an extension of FlexibleRound7ViewsTests), FlexibleRound7ViewsReviewHostedTests
    (an extension of FlexibleRound7ViewsHostedTests).
  - FlexibleRound7Views.swift: the view bits, the Heat scope, FlexibleStageHeat, FlexibleBendGhost.
  - FlexibleMainStage+Play.swift: togglePlay, toggleXray, showLatticeView, viewsChanged.
  - FlexibleMainPickSession.swift: replaces FlexibleMainViewSettings.swift, which is deleted.
  - FlexibleRowCopy+Views.swift.
  - Tests: FlexibleRound7ViewsTests, FlexibleRound7ViewsHostedTests, FlexibleRound7ViewsEvidenceProbe.
- **(review) Edited:** FlexibleMainStage (`xrayChoice` / `xrayDefault`, `prismTags` gated), FlexibleSquishPlayer (the frozen
  pose; the note's shorter forms), FlexibleStagePage (`bodyAlpha(views:…)`, `reads`, the reading's reset, the strip's gate,
  the player's short forms, `testDrill`, `import Combine`), FlexibleStageViews (the two badges), FlexibleMainStatusPill (the
  Play badge), FlexibleRowCopy+Views (the short forms, the Play icon's spoken status).
- **Edited (all Flexible, ours):** FlexibleSquishPlayer (the latch and the Play gate), FlexibleMainStage, +Views, +Squish,
  FlexibleMainStatusPill (six icons, no chips), FlexibleMainLatticeView, FlexibleProbe (rolesOverMarks gone),
  FlexibleRowCopy (the chips' copy gone), FlexiblePageChannels (heatRegions), FlexibleStagePage, FlexibleStageViews,
  FlexibleStageVolumes, FlexibleViewControls (onLongPress), FlexibleGroupWalls (heatSamples: the heat's colours only).
- **The R7-S overlap:**
  - FlexibleStagePage: my hunks are the init, the stubs-turned-statics after it, the ticker, the new `.onAppear` /
    `.onChange(of: model.views)` after the legend-drill line, the clearance line, the overlay gate in `stage`, composeTints,
    refreshChannels' play / scale / ghost block, `player(in:)`, the legend call and FlexibleLegend.shows. I did not touch
    present() or FlexibleStageOverlays. (review) Also: `import Combine` at the top; the statics after `overlaysHidden`; the
    reset `.onChange` and `.onReceive(Self.testDrill)` beside the legend-drill lines; the `bodyAlpha:` line beside the
    clearance line; one `shortNotes:` line in `player(in:)`; the TAP TO READ strip's `.allowsHitTesting` in `legend(in:)`.
  - FlexibleRowCopy: only the four batch-V lines were deleted.

### Open questions
1. **X-ray's starting state follows your finish** (review): your None pad opens in X-ray so its lattice shows; Covered opens
   opaque. Keep this until R7-X's printed view (the lattice through the finish with X-ray off), or would you rather it
   always open opaque (the lattice only after a tap), or have the printed view brought forward?
2. **The Lattice icon turns X-ray on**, and it is lit only while the walls are seen. On a Covered pad it starts unlit though
   the lattice is on — and Save & Exit still bakes by the Lattice view (S9), not by the icon's look. Carry into R7-X: keep,
   or should the icon stay a pure show/hide?
3. **The Squish page and Play:** with Play on, the squish plays, your drawing too (round 3's "while he edits it holds still"
   reversed by "When it is on the simulation plays"). With Play off — the default — your curve shows as colour only, no dent;
   turn on Bend to see the full dent. Right?
4. **Bend with Heat or Prisms** (the verify's S15 / S17): the curves, the depth chip, the stamp handle, the prisms and the
   group outline stand at the REST pose, beside the bent faces. Hide them while Bend shows, or move them with the bend?
   (Built as planned: they come back with Heat or Prisms.)
5. **The main page with Play off:** the group picker (which group's heat or Stress shows) lives in the hidden bar, so after
   the sims land the heat follows the first group until you turn Play on and pick. The redesign re-houses the picker.
6. **The face-prism's own number on the main page** (tap to type, always equal to the list) is R7-M's; for now the main page
   shows no number at all, and a Pending group (your frozen pad's Group C) shows no prism.
7. **Glass over a face whose heat is hidden** is judged over the page's ground, as a resting face's is. The re-pinned R6
   measurement passes (ΔE ≥ 10, ≤ 32), but the open group's glass in the Groups view now sits over the X-ray ghost, not over
   heat.
8. (From the plan) **The Stress icon** stays on the main page; Heat in X-ray reusing the card's Stress row is R7-X.

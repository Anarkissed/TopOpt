## Round 7 · batch X1 — the X-ray rule: X-ray off by default, the lattice seen without it (the printed view), X-ray sees through the solid, the Squish page's bend prism — and the verify's fixes: Heat on the walls (2026-10-14/15)

Branch `claude/flexible-screens-r7x` (side worktree `wt-r7x`), from `1c0a27be` (M1's last commit); for the MERGE step to bring
onto `claude/flexible-screens` (PR #362). **Not pushed. Not installed and never launched** from the side worktree (built for the
iPad Pro 13 simulator only — the merge step installs). Every picture is offscreen: the shipping renderer draws the part, the
page's own SwiftUI chrome is hosted over it; none is a device screenshot, and the camera is the probe's (your img1 / img5
views). **No #354 or main file was touched** (WorkspacePlaceholder, MetalMeshView, ProjectModel, UnifiedShading, core/: no
diff from `1c0a27be`) — the fallback MetalMeshView hook the plan held in reserve was NOT needed.

### ★ The verify's fixes (read this first — it changes what X1's pictures further down show with Heat on)

Branch `claude/flexible-screens-r7x`, tests FIRST at `c5362148` (9 tests, 19 failures against stubs —
`verify/r7x1v_red_run.txt`), code at `6bdf3dd1`, re-pins at `7ecb4d93`, this section and the runs at the commit after it. Still
**hook-free** (no #354, main or core file), **not pushed, not installed**. Pictures: `round7/batch_x1/verify/` (offscreen, the
shipping renderer under the page's own hosted chrome, the probe's cameras — his img1 / img5 views and a low front view).

#### What you will see now, in plain words
- **Heat on (the default) colours the LATTICE ITSELF.** Each wall takes the squish of the pressed face's column it stands in
  — the same number the face's heat map showed there, on the same rainbow and the same scale as the legend (the 3D sim's
  squish when it has landed; core's buildable depth until then). Where a wall is under no pressed face it reads 0 mm (blue).
  - **Default view (X-ray off):** the solid part is the plain part — no flat blue lid on it any more (it does not squish) —
    and the strips of lattice show their squish, hot at the edges that move most (`VX1V_default_none_heat_img5_13p.png`,
    `_img1_13p.png`). Heat off: the walls go back to the green density ramp (`VX1V_default_none_heat_off_img5_13p.png`).
  - **X-ray on:** you see through the solid. From the top (your img5 view) the lattice and its squish are there — before,
    X-ray showed one heat-coloured square and none of the lattice. The pressed face is a faint skin in its heat colours, lit
    at its edges (`VX1V_xray_heat_img5_13p.png`, `_img1_13p.png`); Play squishes the coloured walls
    (`VX1V_xray_heat_play_0.6_img1_13p.png`); with Group C picked, its face-prisms hold the lattice
    (`VX1V_xray_heat_groupC_picked_img5_13p.png`).
  - **The legend** shows "Squish · mm" only while the heat is really drawn, and no "Lattice · density" row while the walls
    wear the squish. **Tap to read** a wall: "11.0 mm · 14% density" — its squish and its density. A tap on the solid part in
    the default view reads "0 mm · solid here".
- **Covered:** turning the Lattice icon on with X-ray off now says why nothing changes — "Covered hides the lattice · See in
  X-ray" — and a tap on that note turns X-ray on (`VX1V_covered_lattice_icon_note_img1_13p.png`,
  `VX1V_covered_note_tapped_xray_img1_13p.png`). Nothing turns X-ray on by itself.
- **The Squish page's X-ray prism** is now a clear white glass (the purple one vanished on the heat's blue — your Group 1's
  prism could not be seen under the Top's heat), with **its depth in a box at its floor** ("3.8 mm") and **one row in the
  legend card**: "Prism = bend at full load", or "Prism = bend at full load, less than drawn" when the 3D sim's bend is well
  short of the curve you drew (your Group 1: 3.8 mm of your 12 mm; Group 2: 11.7 mm; Group 3: 7.2 mm)
  (`VX1V_S_G1_xray_heat_13p.png`, `_G2_`, `_G3_`). On an edges group's tab, X-ray says "No bend yet · core support pending",
  as Bend and Heat do.

#### The verify's findings → the fix → the test (RED control run inside each)
| finding (lens, severity) | the fix | pinned by |
|---|---|---|
| X-ray with Heat on hid the inside of the part from above (ux, BLOCKER) | the walls carry the heat (`FlexibleWallHeat`; MSL `flx_wall_heat`, textures 7–10; the frame's `rhoSpan` z = 2, w = 1 / the legend's top); in X-ray the pressed faces' map is unflagged (a faint ghost skin), the walls solid (`FlexibleMainStage.heatOnWalls`, `lidWithoutHeat`, `FlexibleMainTints.compose(lidWithoutHeat:)`) | `FlexibleR7X1VerifyHostedTests.testXrayWithHeatOnSeesTheLatticeAndItsHeatFromAbove` (his strips, img5 top: wall edges 53.1 % of the strip pixels, the lid alone 3.4 %; Group C picked 32.0 %; RED `controlHeatOnLid` = X1's frame 2.7 %) · `FlexibleR7X1VerifyTests.testHeatGoesOnTheWallsWhereverTheWallsAreDrawn` (no solid map vertex in X-ray; the lid back only with no walls drawn) |
| Heat in the default view coloured only the solid part, a flat 0 mm blue (ux, MAJOR) | the same: the walls wear the heat; the printed view's closed map is the plain part | `testThePrintedViewsHeatIsOnTheWallsNotAFlatLid` (Heat on vs off: inside the strips 92.3 % differ, on the solid part 0.53 %; RED: 0.0 % / 100.0 %) |
| The Squish row and TAP TO READ where no heat was drawn (correct, MAJOR; ruling 3 of 19:45) | the row needs the heat drawn (`heatDrawn`: the walls, or a lid that carries it); no density row while the walls wear the squish; a wall's reading is its column's squish (`readLattice`), the solid part "0 mm · solid here"; the scale's top is the hottest column's (the legend's own top) | the whole-Top fixture in `testThePrintedViewsHeatIsOnTheWallsNotAFlatLid` (walls drawn in heat on 91.6 % of the model; Squish row, no density row; RED: no heat drawn 0.00 % yet the Squish row showed) · `testAWallReadsTheSquishOfItsColumn` ("11.0 mm · 14% density"; RED: the density reading) |
| Squish page prism: no number, no legend key, depth unlike Deepest squish (ux, MAJOR) | its deepest mm in a box at its floor (`FlexibleBendPrism.tag`); the card's row (`FlexibleLegendViewRows.bend`, `FlexibleRowCopy.legendBendRow`), "less than drawn" when the sim's bend is < 90 % of what he drew and > 0.5 mm short (`shortOfDrawn`) | `testTheSquishPagesBendPrismReadsOverTheHeatWithItsNumberAndRow` (Groups 1 and 2: the glass ΔE ≥ 47 from every heat colour; the number = the shell's depth at its deepest corner; RED `FlexibleBendPrism.controlFirstBuild`: violet, no number, no row) |
| Covered: the Lattice icon changes nothing and says nothing (ux, minor) | the note "Covered hides the lattice · See in X-ray" (40 characters), the whole note one tap to X-ray (`coveredNoteTapped`) | `testCoveredSaysWhyTheLatticeIconShowsNothingWithItsFix` (RED `controlNoCoveredNote`) |
| Body alpha and the closed-surface drawing from different rules (correct, minor) | ONE rule, `printedReady` = the printed view drawn AND an overlay (its open surface known): the layer's `printed`, the body alpha 0, the tints' open flags | `testThePrintedViewsLayerBodyAndTintsFollowOneRule` (no overlay: body opaque, layer not printed; RED `controlPrintedRulesApart`: see-through with nothing flagged solid — the part vanished) |
| X-ray on an edges tab: an empty ghost, no reason (correct, minor) | "No bend yet · core support pending" (`FlexibleStageViewButtons.edgesPendingLine`) | `testXrayOnAnEdgesGroupSaysWhyThereIsNoPrism` |
| Comments and four test names said the opposite of the rule (correct, minor) | fixed; renamed: `testANonePadOpensInXrayAndXrayOffHidesTheWallsUnderAnyFinish` → `testANonePadOpensWithXrayOffItsLatticeSeenAndCoveredThePlainModel`, `testXrayOpensOnForAFinishThatShowsTheLatticeAndOffForCovered` → `testXrayOpensOffWhateverTheFinish`, `testTheLatticeViewTurnsXRayOn` → `testTheLatticeViewNeverTurnsXRayOn`, `testPrismsTurnsTheLatticeViewOnItself` → `testPrismsLeavesXrayAsItIs` | — |
| XH1's "X-ray = R7-V's frame byte for byte" could not fail (correct, minor) | reworded: with Heat off the printed view's switch leaves X-ray's frame alone (asserted); that it IS R7-V's rests on code reading (every new branch keys on `shape2.w`, 0 in X-ray). With Heat on, X-ray is no longer R7-V's frame (the walls wear the heat) | `FlexibleR7X1HostedTests` XH1's message |
| The wall heat in both twins | the GPU `flx_heat_probe` against `FlexibleWallHeat.value` | `FlexibleLatticePassTests.testTheWallHeatMatchesTheSwiftTwin` (max \|gpu − swift\| 0.0 over 3000 points, two faces at right angles; RED: the tables in the wrong slots miss by 7.2 mm) |

#### Ruling this reverses (said here and posted — please rule)
- **Batch M's M6 ghost walls under a solid dent lid** (his round-5 img 6: "showing the lattice … as a ghost and the dents bending
  through the ghosts"), in X-ray with Heat on: reversed by his 2026-10-14 Q9 answer ("If the user adds x-ray, we see through
  the solid") and the verify's blocker — the solid lid hid the lattice from above. The machinery stays (the ghost composite,
  the planes' depth) and is pinned through the red control `controlHeatOnLid`; X2 (stress through the lattice in X-ray) can
  swap the walls' colour to Stress on the same tables.

#### Found, not fixed (and why)
- **M1's face-prism glass whitens the wall tops** (#354's volume contact line where the prism's face meets the walls), and its
  edges show through the solid middle: M1's `facePrismItems` — which the M1 verify rewrote on the main tree — draws them in
  #354's active look. The fix is one argument (the items' own alphas → the faint pass, no contact line); it belongs in the
  merge or B1, not in a second copy here.
- **The Squish page opens with Heat lit** (his answer 12: "nothing but the curve without any view turned on"): not X1's change;
  raised with the reviewer for the short follow-up batch.
- **No contact shadow under the printed view on the device** (likely; the offscreen pictures draw no floor): #354's
  `latticeOnly = bodyAlpha <= 0.5` reads the see-through printed body as lattice-only and, with no octet layer on the Flexible
  stage, draws no shadow. The fix is a #354 line — posted for review, NOT written: `MetalMeshView.swift | :4085 | +1 −1 |
  let latticeOnly = bodyAlpha <= 0.5 && !flexibleBodyPrinted | gate: flexibleLatticeInFrame && printed (ours) | the solid part
  floats with no shadow in None / Rim / Skin`. Not a regression for your pad (it opened in X-ray before: no shadow either).
- **The low front view in X-ray** (looked at: the dashed blue "streaks" at the strips' inner sides are the walls' cut ends at the
  pocket's boundary seen edge-on, the dark band under the Top is the solid middle seen through (nothing is inside it), the blue
  band on top is the Top's faint skin at its silhouette — the geometry and the ghost's rim, not a fault; left as they are — `VX1V_xray_heat_img2_front_13p.png`).
- **[Prisms] with nothing picked draws nothing** in this tree (M1's rule at `1c0a27be`); the M1 verify changed [Prisms] to every
  group's face-prisms — that arrives with the merge.

#### Re-pins (each attributed in the test to his 2026-10-14 Q9 answer and the X1 verify)
| class | what changed |
|---|---|
| FlexibleBatchMXrayTests (fixture; `testTheDentViewTurnsXRayOnAndGhostsTheWalls`) | M6's ghost walls under the solid dent lid are pinned through the red control `controlHeatOnLid`; the new rule pinned beside it (the walls wear the heat, no ghost walls, the card's one Squish row) |
| FlexibleBatchMLegendTests (its shared fixture) | the one card with both rows (Squish + density) pinned through `controlHeatOnLid` — with Heat on in X-ray the density row is gone now |
| FlexibleBatchMVerifyTests (both fixtures) | the ghost walls' depth order and the column fallback pinned through `controlHeatOnLid` |
| FlexibleBatchCVerifyTests (`testTappingStressShowsItInTheDefaultView`) | runs with the Lattice view off — it is about the MAP's colouring (Heat or Stress), which the map carries only with no walls drawn |
| FlexibleR7X1HostedTests (XH1's red control 2) | the solid-flags-only mis-sort is shown on X1's heat lid (`controlHeatOnLid`): with the solid part plain, a far face over the Top is clay over clay |
| (source pins kept, not re-pinned) FlexibleBatchVHostedTests, FlexibleRound6HostedTests | the verify's code was reshaped so the pinned lines stand as they were (the overlays' keep-out line; the legend's rule line — the bend prism's tag and row are their own argument / term) |

#### Merge notes (the M1 verify, `f7b83031` on the main tree, touches some of the same files)
- **HAZARD — [Prisms] turns X-ray on again** in the M1 verify (`togglePrisms`: `if m.views.contains(.prisms), !xrayOn,
  legendPrismsRow { xrayOn = true }`, asserted at `FlexibleR7M1VerifyTests.swift:126`). Take X1's `togglePrisms` (never X-ray —
  his Q9 answer) and re-pin that line to X-ray off, crediting his Q9 answer.
- `FlexibleMainStage.refresh()`'s channels key: both sides edited its last line (M1 verify `"\(prisms)"`, X1 `printedReady(m)`
  + a second line for the walls' heat) — keep all three.
- `FlexibleMainStage.volumes` / `facePrismItems` / `legendPrismsRow` / status: the M1 verify's; X1 does not touch them.
- `FlexibleMainLatticeView.swift`: M1 verify adds `.toSelections` to `pillTapped`; X1 adds the note's `coveredHidesLattice` kind,
  `coveredNoteTapped` and the note view's branch — separate hunks.
- `FlexibleStagePage.swift`: M1 verify changes one line (`noticeFix`); X1's hunks are the legend, the overlays' `bendTag`,
  `refreshChannels`' prism lines and `bodyAlpha` — separate.
- `FlexibleRound6HostedTests.swift`: both sides edit the clicked [Prisms] test (~:605–:690) — resolve by hand: M1 verify's
  volumes line, X1's X-ray lines (X-ray stays off), X1's rename.

#### The verify's runs (raw in `verify/r7x1v_runs.txt`)
- **Red run first** (tests against stubs, `c5362148`): 9 tests, 19 failures. Two tests were rewritten before any code and re-run
  red: V3 (the one rule is an overlay-guarded `printedReady`, not a synchronous `pageUp` — the workspace evaluates the tints and
  the body alpha BEFORE the layer, so a remembered `pageUp` would always be a pass late; 3 failures) and VH1 (its Group C number
  passed for the wrong reason — the glass made the two frames differ — so it counts the walls' EDGES, calibrated on run 1's
  frames: the opaque lid 0.9 %, the glass over it 2.0 %, the lattice seen 50 %; 3 failures). `verify/r7x1v_red_run.txt`.
- **Green** at `6bdf3dd1`: the 11 verify and parity tests (one xctest exit with signal 6 AFTER all 11 passed; not seen again in
  the suite, the re-run or the evidence runs).
- **Targeted suite, run 1, at `6bdf3dd1`** (from a clone of the build, so the evidence probe could be written meanwhile): 125
  classes (every Flexible* class + LatticeStaleTypeTests, ProjectStoreTests, UndoHistoryTests, LatticeSettingsPersistTests,
  ViewerTests, SmoothingPageRound2Tests, LatticeSimSolveTriggerTests, BottomBarMeasurementTests, LatticeIncludeGateTests,
  LatticeSectorHisProjectTests, LatticeSectorOutlineTests; no other class source-pins a touched file), 12 per run, unseeded.
  **770 tests: 708 passed, 50 skipped, 12 failed (37 assertions):**
  - known and pre-existing: FlexibleBatchNVerifyTests.testEveryRefineLineIsWholeBesideTheLivePlayAllPicker (×8 assertions),
    LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds ×1, FlexibleRound7ViewsHostedTests.testThePlayIconsRing…
    (16 px — the offscreen capture of its TimelineView, as M1 and X1 recorded);
  - caused by the verify, all handled: 7 re-pinned (the table above) and 2 source pins kept by reshaping the verify's own lines
    (FlexibleBatchVHostedTests' overlays line, FlexibleRound6HostedTests' legend rule).
  - LatticeStaleTypeTests 6/6; ProjectStore, UndoHistory, LatticeSettingsPersist, Viewer, SmoothingPageRound2, BottomBarMeasurement,
    LatticeIncludeGate all green. No xctest death, no exit signal.
- **Re-run at `7ecb4d93`** (every class that failed in run 1 or source-pins FlexibleStagePage.swift, FlexibleR7X1Tests, the
  verify classes, FlexibleLatticePassTests — 25 classes): **204 tests, 1 skipped, 1 failure — the Play ring (18 px).**
- **Goldens** (FlexibleAngledGoldenTests 13/13 each, at `7ecb4d93`): deterministic 38 identical, 0 DIFFERS; unseeded 32 identical,
  0 DIFFERS, 1 PART-SKIP (as before).
- **The 16 stage-job hashes:** `verify/stage_job_hashes_r7x1v.txt` is byte-identical to X1's, the R7 merge's and I2's (the whole
  file). The stage job never reads the view state.
- **iOS:** BUILD SUCCEEDED at `7ecb4d93` (derived data `flexA1r7x`, 01:49; TopOpt.debug.dylib 79 655 136 bytes; it carries
  `flx_wall_heat`, `flx_heat_probe`, `FlexibleWallHeat`, `coveredHidesLattice`, `flexible-bend-prism-tag`,
  `flexible-legend-bend-row`). **Not installed, never launched** (the merge step installs).
- **What looking found and was undone:** the bend prism over your Group 1 covers the whole Top (a light wash over its heat); I
  tried drawing it only where the face bends — but the 3D sim moves the whole pressed face (every triangle of Group 1 travels
  ≥ 2 % of the deepest), so it cut nothing on your pad. Reverted (no untested code left); the white edges and the number carry
  the prism.

#### Open questions (replacing X1's four, further down)
1. ~~Heat in the default view~~ — answered by the verify's fix (the walls wear the squish). If you would rather the walls stay
   green by density in the default view and wear the heat only in X-ray, say so (one line).
2. X-ray and the face-prisms without a pick — the M1 verify's [Prisms] (every group's face-prisms) arrives with the merge; still
   yours to rule whether X-ray alone should show them.
3. M1's face-prism glass over the open lattice (the white contact lines): an outline only, fainter glass, or leave it to B1?
4. The Squish page with [Prisms] and X-ray off is see-through at 30 %. Or opaque until X-ray?
5. NEW: the Squish page opens with Heat lit — should it open with no view on (your answer 12's "nothing but the curve")?

---

### What X1 itself built (before the verify), in plain words


**The main Flexible page**
- **X-ray is off when a project opens — every finish.** Your pad (Finish None) no longer opens as the X-ray ghost.
- **With X-ray off you see the solid part AND the lattice** (your Q9 answer: "If lattice is on without x-ray view, we see the
  lattice plus the solid"). What shows depends on the finish:
  - **None:** the solid part, and in the face-prism areas the lattice runs right to the surface — on your pad's Group C, the
    two strips are open lattice and the middle stays solid (`R7X1_default_none_img5_13p.png`, `_img1_13p.png`, `_11l.png`).
    Where the lattice pocket meets the solid, you see the pocket's own wall.
  - **Rim:** a solid band along each edge of the part, the lattice open between the bands (`R7X1_default_rim_*`).
  - **Skin:** a thin solid skin with round holes; the lattice shows through the holes (`R7X1_default_skin_*`).
  - **Covered:** the plain model — the skin hides the lattice, as it will print (`R7X1_default_covered_*`).
- **The Lattice icon is a plain show / hide.** It never turns X-ray on. Off: the plain model (`R7X1_lattice_off_plain_model_*`).
- **[Prisms] no longer turns X-ray on either.** X-ray is only ever your tap.
- **X-ray on: you see through the solid** — the ghost body, the lattice inside it, the heat on the pressed faces (the bend
  amount), and after you pick a group its face-prisms' extent (`R7X1_xray_on_*`, `R7X1_xray_on_groupC_picked_face_prisms_*`).
  ★ SUPERSEDED by the verify: with Heat on, the heat is on the walls and the face a faint skin (those X-ray pictures with Heat
  on show X1's opaque heat lid — the verify's blocker); the `VX1V_*` pictures show it now.
  Covered in X-ray shows its lattice inside the skin (`R7X1_covered_xray_on_img1_13p.png`).
- **Play works in the printed view too:** the walls squish with the part (`R7X1_default_none_play_at_0.6_img1_13p.png`).
- With no face-prism set (your pad as saved) it is the plain model, X-ray off (`R7X1_no_face_prism_plain_model_img1_13p.png`).

**The Squish page**
- **A new [X-ray] icon** (the main page's glyph), between [Bend] and [Play]. Icons only; still one legend card.
- **X-ray is off when the page opens: the part is opaque** — your curve as colour only (Heat), nothing else drawn
  (`R7X1_S_13p_default_xray_off.png`). [Prisms] makes the part see-through (30 %) so its prisms inside show
  (`R7X1_S_13p_prisms_xray_off.png`); Bend alone stays the opaque bent part (`R7X1_S_13p_bend_alone_xray_off.png`).
- **X-ray on: "a prism view of the actual bend INTO the model"** (your answer 12) — the ghost body, and the open group's bend
  drawn as a prism (★ verify: now a clear white glass with its depth in a box): its faces at rest, the same faces bent to
  the full depth, and the sides between. On your pad's
  Group 2 pinch that is two prisms reaching 11.7 mm into the part from Face 4 and Face 2 (`R7X1_S_13p_xray_on_bend_prism.png`;
  with Bend the bent faces sit on the prism's floor: `R7X1_S_13p_xray_on_bend_prism_with_bend.png`).

### The spike: how the solid part is cut open over the lattice (the go / no-go, posted to the reviewer)
- **The plan's solid-flag route alone is NO-GO.** It draws the body see-through with its closed surface flagged opaque. #354's
  see-through body writes no depth, so whichever triangle is drawn last wins: on your pad the far side face painted over the
  Top (`spike/R7X1_spike_a_solidflag_alpha0_img1.png`, `_top.png`). The plan's "body alpha just below 1" cannot work either:
  the open surface would be ~opaque (`spike/R7X1_spike_a_solidflag_alpha0998_img1.png`).
- **GO, still hook-free:** the same flags, PLUS the closed body written into the G-buffer by OUR pass (new `flx_body_vertex` /
  `flx_body_gbuffer`, eye-Z pushed 0.5 mm back). #354's shade then writes its depth into the main buffer, so the see-through
  body drawn after it keeps only its nearest closed surface; the walls are marched against the same buffer, so a wall behind
  the closed body is never drawn (`spike/R7X1_spike_b_printed_bodyInGBuffer_img1.png`, `_top.png`). The pass is fed through
  the existing map-depth hook (it notes the renderer's buffers; no new hook). Taps still pick the face under them (by
  construction: the pick pass draws the unchanged body mesh — not measured by a click here).
- **The printed term in both twins** (MSL `flx_field` under the reserved `shape2.w`; Swift
  `FlexibleLatticeField.lattice(at:printed:)`): S = max(dPart, min(max(dRegion, −dSkin), −dRegion)), field = min(F, S).
  **One extension to the plan's term** min(F, max(dRegion, dPart, −dSkin)): the part OUTSIDE the region (−dRegion) is solid
  too — the pocket's own wall and floor. Without it a ray through the voids ran on through your pad's solid middle to the
  other strip. The march's early-out bound is min(max(dRegion, dPart, dSkin), S) in the printed view (both bounds hold).
- **AO check** (the plan's): the solid part next to the strips against #354's opaque body, mean ΔE 0.00 (img5 top, 900 and
  2064 px) and 0.05 (img1) — no crease loss: the printed body's occlusion comes from the G-buffer (body and walls together).
- **At your 13" pixel size** (2064 px, the G-buffer capped at 1152 below it) the body's edges stay crisp (it is still drawn
  full-size, multisampled); only the walls are at the G-buffer's size, as before.

### Your words → the fix → the test (tests FIRST: 7 tests red against stage stubs, 30 failures — r7x1_red_run.txt)
| your words (2026-10-14) | the fix | pinned by (RED control, run inside the test) |
|---|---|---|
| Q9: "X-ray mode should show the inside of the SOLID … These two things are not mutually exclusive" — X-ray off by default | `FlexibleMainStage.xrayDefault` only under the control; `xrayOn` = your session choice or off. Squish page: `FlexibleStageViews.xray`, `FlexibleStagePage.bodyAlpha(views:…)` opaque unless X-ray (30 % with [Prisms] or Bend + Play) | `FlexibleR7X1Tests.testXrayIsOffByDefaultOnBothPagesWhateverTheFinish` (RED `controlXrayByFinish` = R7-V's stopgap; `FlexibleStagePage.controlAlwaysXray` = the page always X-ray) |
| Q9 / Q10: the Lattice view never forces X-ray (nor [Prisms]) | `showLatticeView`, `toggleLatticeView` (plain show / hide), `togglePrisms`; `latticeIconLit` = your view | `testTheLatticeViewAndPrismsNeverTurnXrayOn` (icon, note's [Show], pill path, [Prisms], Exit — RED `controlViewsForceXray` = R7-V's rule) |
| Q9: "The lattice should be visible without x-ray on as long as finish is set to something that isn't 'covered'" | the printed view: `printedView` / `printedDrawn` (one rule for the layer's `printed`, body alpha 0 and the tints' solid flags); `FlexibleLatticePreview.inputs(printed:)` hidden = building ∥ !latticeShows ∥ (!xray ∧ !printed); `FlexibleMainTints.compose(open:)` / `overLattice`; the pass's body and printed term | `testThePrintedViewDrawsTheLatticeWithXrayOffUnlessCovered` (RED `controlNoPrintedView` = R7-V: walls only in X-ray) · hosted `FlexibleR7X1HostedTests.testFinishNoneShowsTheSolidPartAndTheLatticeWithXrayOff` (his strips, img5 top at 900 and 2064 px and img1: outside the strips 99.75–100 % of the solid part within ΔE 3, < 0.2 % grossly off; inside 98.3–99.0 % differ; X-ray = R7-V's frame byte for byte; RED 1: R7-V's rule 0.0 % inside; RED 2: the solid flags alone 83.8 % grossly off) · `testCoveredIsThePlainModelSkinAndRimSitBetween` (inside the strips: None 98.3 %, Rim 91.8 %, Skin 42.3 %, Covered 0.0 %) |
| the printed term "in BOTH twins" (the plan) | MSL `flx_printed_solid` / `flx_terms` / the march bound; Swift `printedSolid` / `terms` / `lattice(at:printed:)` | `FlexibleLatticePassTests.testThePrintedTermMatchesTheSwiftTwin` (max \|gpu − swift\| 0.0016 mm over 3000 points, both topologies; the printed solid decides at 2124 / 1966 of them; RED: the gate off misses by 32.0 / 4.65 mm) |
| answer 12: "Turning x-ray on shows a prism view of the actual bend INTO the model" | `FlexibleBendPrism` (new), `FlexibleStagePage.xrayItems`, the page's `bendPrism` | `testTheSquishPagesXrayIsTheBendsPrismIntoTheModel` (his Group 2: off → no prism, no ghost flag; on → a prism 11.66 mm deep = k × the dent at full load; RED `controlAlwaysXray`: always the ghost, no prism) |

### Rulings this batch reverses (your 2026-10-14 words win)
- **R7-V review's X-ray stopgap** (`xrayDefault`: X-ray on for None / Rim / Skin, so your None pad's lattice was not hidden):
  retired by your Q9 answer. It is now only the red control `controlXrayByFinish`.
- **R7-V's "a view that needs another turns it on itself"** for the Lattice icon and [Prisms] (both turned X-ray on, and Exit /
  the note / the pill went through it): reversed by your Q9 answer (it also answers R7-V's Q10). The Lattice icon is lit by
  your view, not by "walls seen".
- **Round 3–7's Squish page "always in X-ray"** (your round-3 words: "Simply have the model in xray view in the settings"):
  reversed by "X-ray is OFF by default on both pages" and your answer 12. R7-V's Bend rules now apply only inside the red control.

### Decisions to flag (not asked, said here)
- **The pocket's wall and floor are drawn** (the printed term's extension above) — a change to the plan's formula, posted.
- **On the Squish page, X-ray off is opaque except with [Prisms] or Bend + Play** (30 %, so what sits inside the part shows).
  Bend alone stays opaque, as R7-V made it.
- **The Squish page's X-ray is its own** (a bit of the page's views, session only); the main page keeps its own X-ray. Play
  stays the one shared view.
- ~~The heat in the default view shows only on the solid part of a pressed face~~ — ★ the verify: the walls wear the heat
  now, and the solid part none.
- **Taps** still pick the face under them in the printed view (the mesh is unchanged; only its drawing is cut — by construction,
  not measured by a click).
- **Not measured as the plan wrote it:** Rim's "opaque band of rimMM at the strip edges" is measured as Rim sitting between None
  and Covered inside the strips (91.8 % differ); the band itself is in the pictures (`R7X1_default_rim_*`).

### Re-pins (each attributed in the test to your 2026-10-14 Q9 words, naming the ruling it reverses)
| class | what changed |
|---|---|
| FlexibleRound7ViewsReviewTests (RV1) | X-ray off for every finish; the walls drawn out of X-ray (body alpha 0); RED `controlXrayByFinish` (R7-V's stopgap) |
| FlexibleRound7ViewsReviewHostedTests (RH1) | your None pad opens with X-ray off and its lattice SEEN (the printed view, > 2 000 px); Covered draws no wall; RED `controlNoPrintedView` (0 px) |
| FlexibleBatchBReviewUXTests ×2 | `testTheLatticeViewTurnsXRayOn`: the Lattice icon a plain show / hide that never turns X-ray on (RED `controlViewsForceXray`); `testTheSettingsPageLetsTheRendererStepTheSquish`: its source pin follows the layer call's new `printed:` argument |
| FlexibleMainPageRound4HostedTests | the Lattice click: hide → show → hide, X-ray never touched (R7-V: the first click showed the walls in X-ray) |
| FlexibleMainPageRound4Tests | Exit after the Lattice icon opened Settings shows the view and leaves X-ray off; that pad keeps the default finish, Covered, so it is the plain model until his X-ray tap |
| FlexibleR7M1Tests (one line) | [Prisms] leaves X-ray off (M1 had pinned R7-V's "turns X-ray on") |
| FlexibleRound6HostedTests ×2 | [Prisms] (unit and clicked, both layouts and the iPad mini) leaves X-ray off; RED `controlViewsForceXray` |
| FlexibleRound6Tests | the Squish page's X-ray tints are composed with his [X-ray] on (`[.heatAll, .xray]`) |
| FlexibleRound7ViewsReviewHostedTests (RH2) | Bend with Heat and the editing view are opaque out of X-ray; his X-ray gives the ghost; the red control is always-X-ray + R7-V's Bend ghost |
| FlexibleRound7ViewsTests | [Prisms] leaves X-ray off |

### What looking found (round7/batch_x1/)
- **The plan's solid-flag route mis-sorted the body** (the spike) → the closed body goes into the G-buffer (above).
- **The first measurement could not see that mis-sort** at img5's top camera with Heat off (98.85 % of the solid part still
  matched) → the red control now runs at img1 with Heat on (the spike's condition), and the solid part is measured a few
  pixels in from the silhouette and the strip edges (an edge pixel is half background in one frame). The code did not change.
- **The first finish pictures were taken before the rebuilt lattice's sims landed** (Covered showed the column fallback's heat
  blocks) and with Group C picked (its face-prism glass over the lattice) → re-shot after the sims land, Group C picked only
  in its own pictures.
- **Not fixed (M1's prisms, R7-M's file area):** with a group picked, M1's face-prism glass sits over the open lattice; the
  bright wall tops show through it as light streaks (`R7X1_default_groupC_picked_img1_13p.png`; M1's X-ray picture shows the
  same). Question 3 below.

### The runs (raw in r7x1_red_run.txt, r7x1_first_runs.txt, r7x1_runs.txt)
- **Red run first:** 7 tests against stage stubs, 30 failures (XH2 first passed for the wrong reason — the stub opened your
  None pad in X-ray; it now forces X-ray off and was re-run red, 5 failures). The parity test passed in the red run because its
  twin was written in the spike; its red controls run inside.
- **Green:** the 7 X1 tests (XH1's mis-sort control moved to img1 with Heat on, and the solid part measured a few pixels in from
  the edges — the measurement, not the code).
- **Targeted suite, run 1, at `8ffd6b34` (the final code):** 123 classes (every Flexible* class, LatticeStaleTypeTests,
  ProjectStoreTests, UndoHistoryTests, LatticeSettingsPersistTests, ViewerTests, SmoothingPageRound2Tests,
  LatticeSimSolveTriggerTests, BottomBarMeasurementTests, LatticeIncludeGateTests, the two Lattice sector classes that name
  Flexible; no other class source-pins a touched file), 12 per run, unseeded. **757 tests: 694 passed, 50 skipped, 13 failed:**
  - known and pre-existing: FlexibleBatchNVerifyTests.testEveryRefineLineIsWholeBesideTheLivePlayAllPicker (×8 assertions),
    LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds ×1;
  - the 10 re-pins above (31 assertions);
  - **not known, not X1:** FlexibleRound7ViewsHostedTests.testThePlayIconsRingAndDotAreSeenWithPlayOff — the turning ring is
    counted at 18–20 px (needs > 120) in every run tonight. Reverting X1's only change near it (the Lattice icon's lit state)
    still counts 18 px, and M1 recorded the same 16–23 px at its own base this evening ("the machine's state changed"; R7-V
    counted 404 px). The ring IS drawn (its snapshot shows the arc); the offscreen capture of its TimelineView is what changed.
  - LatticeStaleTypeTests 6/6. No xctest death, no exit signal.
- **Re-run of the 8 re-pinned classes at `745a94b0`:** 71 passed, 1 failed (the Play ring, as above).
- **Goldens** (FlexibleAngledGoldenTests 13/13 each, at `745a94b0`): deterministic 38 identical, 0 DIFFERS; unseeded
  32 identical, 0 DIFFERS, 1 PART-SKIP (as before).
- **The 16 stage-job hashes:** `stage_job_hashes_r7x1.txt` is byte-identical to `round7/merge/stage_job_hashes_r7merge.txt`
  and `angled_presses/stage_job_hashes_i2.txt` (the whole file). The stage job never reads the view state.
- **iOS:** BUILD SUCCEEDED at `745a94b0` (derived data `flexA1r7x`, 21:03; TopOpt.debug.dylib 79 478 960 bytes; it carries
  `flexible-settings-view-xray`, `flx_body_gbuffer`, `flx_printed_solid` and `FlexibleBendPrism`). **Not installed, never
  launched** (the merge step installs).

### Files
- **New:** FlexibleBendPrism.swift; tests FlexibleR7X1Tests, FlexibleR7X1HostedTests, FlexibleLatticePassTests+Printed,
  FlexibleR7X1EvidenceProbe (opt-in).
- **Edited (all Flexible, ours):** FlexibleLatticeShader, FlexibleLatticePass, FlexibleLatticeField, FlexibleSquish (the layer's
  `printed`), MeshRenderer+FlexibleLattice (ours), FlexibleLatticeGeneration, FlexibleMainStage, +Play, +Views,
  FlexibleMainStatusPill, FlexibleMainLatticeView, FlexibleProbe, FlexibleRound7Views, FlexibleStagePage, FlexibleStageViews.
- **Merge notes (M1 / M2 on the main tree):** FlexibleMainStage's X-ray block — M1's `1c0a27be` added a no-face-prism clause
  to `xrayDefault`; X1 keeps that clause INSIDE the stopgap's red control and makes the default off (with no face-prism the
  default is the plain model either way — M1's intent kept). Take X1's block. FlexibleMainStage `layer(…)` / `bodyAlpha(…)`
  and `togglePrisms` are X1's; `volumes` / `prismTags` / status are M1's (untouched here). FlexibleR7M1Tests'
  `XCTAssertFalse(s.xrayOn)` (no face-prism) still holds.

### Open questions (X1, before the verify — superseded by the verify's list above)
1. **Heat in the default view:** over the lattice a pressed face is open, so its heat colour shows only on the solid part (on
   your pad's Top: the middle, 0 mm). Keep it so (the squish colour is seen in X-ray), or should the default view colour the
   walls by their squish?
2. **X-ray and the face-prisms:** in X-ray a group's face-prisms show after you pick the group (your "prism only after a pick"
   rule). Should X-ray show every face-prism's extent without a pick?
3. **M1's face-prism glass over the open lattice** (light streaks of the wall tops through it, after a pick). Fainter glass,
   an outline only, or leave it for the redesign (B1)?
4. **The Squish page with [Prisms] and X-ray off** is see-through at 30 % so the prisms inside show. Or should [Prisms] stay
   opaque (the prisms then hidden until X-ray)?

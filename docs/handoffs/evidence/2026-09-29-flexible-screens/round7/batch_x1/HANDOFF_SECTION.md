## Round 7 · batch X1 — the X-ray rule: X-ray off by default, the lattice seen without it (the printed view), X-ray sees through the solid, the Squish page's bend prism (2026-10-14)

Branch `claude/flexible-screens-r7x` (side worktree `wt-r7x`), from `1c0a27be` (M1's last commit); for the MERGE step to bring
onto `claude/flexible-screens` (PR #362). **Not pushed. Not installed and never launched** from the side worktree (built for the
iPad Pro 13 simulator only — the merge step installs). Every picture is offscreen: the shipping renderer draws the part, the
page's own SwiftUI chrome is hosted over it; none is a device screenshot, and the camera is the probe's (your img1 / img5
views). **No #354 or main file was touched** (WorkspacePlaceholder, MetalMeshView, ProjectModel, UnifiedShading, core/: no
diff from `1c0a27be`) — the fallback MetalMeshView hook the plan held in reserve was NOT needed.

### What you will see, in plain words

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
  Covered in X-ray shows its lattice inside the skin (`R7X1_covered_xray_on_img1_13p.png`).
- **Play works in the printed view too:** the walls squish with the part (`R7X1_default_none_play_at_0.6_img1_13p.png`).
- With no face-prism set (your pad as saved) it is the plain model, X-ray off (`R7X1_no_face_prism_plain_model_img1_13p.png`).

**The Squish page**
- **A new [X-ray] icon** (the main page's glyph), between [Bend] and [Play]. Icons only; still one legend card.
- **X-ray is off when the page opens: the part is opaque** — your curve as colour only (Heat), nothing else drawn
  (`R7X1_S_13p_default_xray_off.png`). [Prisms] makes the part see-through (30 %) so its prisms inside show
  (`R7X1_S_13p_prisms_xray_off.png`); Bend alone stays the opaque bent part (`R7X1_S_13p_bend_alone_xray_off.png`).
- **X-ray on: "a prism view of the actual bend INTO the model"** (your answer 12) — the ghost body, and the open group's bend
  drawn as a purple prism: its faces at rest, the same faces bent to the full depth, and the sides between. On your pad's
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
  the existing map-depth hook (it notes the renderer's buffers; no new hook). Taps still pick the face under them (the body
  mesh is unchanged).
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
- **The heat in the default view shows only on the solid part of a pressed face**: over the lattice the face is open (the
  walls show), so on your pad's Top the colour that changes is seen in X-ray or under Covered. (Question 1 below.)
- **Taps** still pick the face under them in the printed view (the mesh is unchanged; only its drawing is cut).

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

### Open questions
1. **Heat in the default view:** over the lattice a pressed face is open, so its heat colour shows only on the solid part (on
   your pad's Top: the middle, 0 mm). Keep it so (the squish colour is seen in X-ray), or should the default view colour the
   walls by their squish?
2. **X-ray and the face-prisms:** in X-ray a group's face-prisms show after you pick the group (your "prism only after a pick"
   rule). Should X-ray show every face-prism's extent without a pick?
3. **M1's face-prism glass over the open lattice** (light streaks of the wall tops through it, after a pick). Fainter glass,
   an outline only, or leave it for the redesign (B1)?
4. **The Squish page with [Prisms] and X-ray off** is see-through at 30 % so the prisms inside show. Or should [Prisms] stay
   opaque (the prisms then hidden until X-ray)?

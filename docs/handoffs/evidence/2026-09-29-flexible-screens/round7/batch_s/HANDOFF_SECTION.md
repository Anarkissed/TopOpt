## Round 7 · batch S — the Settings page: the open group never shifts, only its numbers show, Reset all leaves [Model] [New], a trash and a name on every group (2026-10-14)

Branch `claude/flexible-screens-r7s` (side worktree `wt-r7s`), from `61cfce05`; for the MERGE step to bring onto
`claude/flexible-screens` (PR #362) beside R7-V. **Not pushed. The app was NOT launched and NOT installed** by this
batch (built for the iPad Pro 13 simulator only — the MERGE step installs). Every picture is offscreen (the shipping
renderer for the part, the page's own overlays hosted over it, the panel hosted beside it), not a device screenshot.
**No #354 / main file touched** (`git diff 61cfce05..HEAD` on WorkspacePlaceholder, ProjectModel, MetalMeshView,
LatticeSettings, SelectionModel, ForceModel and core/: empty). The two group lists stay separate: nothing here reaches the
main page's Selections.

**What you will see on the Settings page:**
- **The tab you opened stays open.** Whatever you change — a Strip width, a corner added, a force, a colour, a curve, a
  face deleted in another group or this one, an undo, a redo, the part re-opening after a cut — the tab is still the group
  you were on. A group's number can change (an earlier group deleted: Group 3 becomes Group 2) and the tab moves with it.
  Only YOUR picks move the tab: a face tapped on the part, a row tapped, [+ New], the player's group picker, a fix you tap
  in the pop-up. A pop-up that opens by itself about a face in another group names it and pulses it, and leaves the tab.
- **An edges group's tab shows only its own numbers.** No face is selected there (it has none): no "3.0 mm" chip, no Top
  curves, no stamp handle from Group 1 (his img4's chip and curves were Group 1's Face 1, drawn behind Group 2's tab). On
  the Prisms view every group's prism stays, faint, but only the open group's carry their mm. The squish that plays is the
  open tab's group.
- **Reset all clears everything: the rail is [Model] and [+ New].** No group, no Rests, every edge/corner strip given back
  to its face. No pop-up opens over it. [+ New] is always on the rail. With nothing pressed, a tap on any face starts
  Group 1: at the main page's weight when a Load group presses that face, otherwise the keypad asks "How much weight
  presses here?". With faces pressed, a tap on a face no group holds starts the next group (added by the verify, below).
  One undo brings everything back.
- **Every group has a trash, the only group too** (44 pt, next to the (i)). It DELETES the group (it used to merge its
  faces into another group): its faces leave the Flexible setup (one undo step); an edges group gives its strips back to
  its faces. The last group gone leaves [Model] and [+ New] (and [Rests] while a face rests).
- **Tap a group's name to rename it**: one line, 12 characters at most (16 before the verify); empty is "Group 2" again. The name shows on its
  rail tab, its header, a face's group menu, the Settings player's picker, the "In <group>" grey line of pick mode and the
  miss line. It is display only (the lattice never goes stale for it) and it stays with its group through a renumber.

### After the verify (2026-10-14): what the review found — fixed, tested, or asked

The verifier hosted the WHOLE page on his pad (his img3/img4 flow, the page's own renderer under its chrome) and found
three majors and twelve minors. Each was confirmed here first (the verifier's pictures and logs, then the code).
Commits: `79b62b1d` tests FIRST against red stubs (red run: `round7/batch_s/r7s_verify_red_run.txt`), `20356410` the
fixes. The two group lists stay separate. No #354 / main file was touched (`git diff 61cfce05..HEAD` on
WorkspacePlaceholder, ProjectModel, MetalMeshView, LatticeSettings, SelectionModel, ForceModel and core/ is empty).

**What you will see now:**
- **A name goes to the group you typed it on.** Suppose you tap Group 2's name, type "Thumbs", then tap Group 1's tab
  before pressing Return. Group 2 is now "Thumbs", Group 1 is unchanged, and Group 1's header has no open field.
- **The rail's tab shows the new name, or the new colour, as soon as you change it.**
- **Names are 12 characters at most. They are never cut on the rail.** A long name wraps onto two lines in its tab:
  "Index finger" fits on one line, and the widest 12 characters take two.
- **Reset all leaves only [Model] and [+ New], with no pop-up.** The top line still says what is missing, and Exit still
  reads "Fix 1 thing" (question 5 below asks whether an empty setup may leave). With today's rule, the
  "[Press Face 1]" pop-up would have put the Top back. It also turned the camera to the top view.
- **[+ New] does what its line says ("Tap the face that starts it") once faces are pressed.** A tap on a face that no
  group holds starts the next group. If no main-page group gives that face a weight, the keypad row
  "Face 3 → Group 4 [#]" asks for one. Your weight starts the group in one undo step, and its tab opens. Before, the
  tap opened Group 1. On [Model], a tap on such a face opens the group you were last working on, where the face's card
  offers [Press it].

His words these findings go back to (2026-10-14):
- img3: "their names should be editable by tapping "group 1" or whatever the default name is."
- img4: "please make it stay on the same group and never shift".
- img4: "All that should be viewed is the "model" folder tab and the "New" one."
- His rule: ONE visible line per setting, never cut.

| finding (verifier) | confirmed? | the fix | pinned by (RED control run inside the test) |
|---|---|---|---|
| MAJOR: a name typed for one group is saved on another (the open field moved with the tab's header) | yes (`name13p/R1–R3`, log `after Return: names 1=Thumbs`) | `FlexibleGroupNameField` remembers the group he TAPPED by what it holds (its faces and presses; a renumber changes its id, not its members). When the header shows another group, the field closes and the text goes to the tapped group. Only a changed name is written, and leaving the header also commits. | `FlexibleR7SettingsHostedTests.testTheNameFieldNamesItsOwnGroupAndTheRailTabSaysItWhole`, on his pad at 13" portrait, typed through the real field: names `[Group 1, Thumbs, Group 3]`, no field left open. RED `FlexibleGroupNameField.controlCommitsToTheHeadersGroup` (today's field): Group 1 is named "Palms" and the field stays open on `groupNameField-1`. |
| MAJOR: the rail tab still says "Group N" right after a rename | yes (`R3`/`R4`: header "Thumbs", rail "Group 1") | `setGroupName` and `setGroupColour` (same path) publish before the edit. `settings` is computed over the project, so an edit with `recompute: false` published nothing to the rail. | The same test: after the field and Return, with nothing else in between, the rail's drawn title (`railTitle:<tab>:<title>`) reads "Index finger". RED `controlNameEditPublishesNothing`: the tab keeps the old name. |
| MAJOR: Reset all pops a blocker at once (the [Press Face 1] pop-up over [Model] [New], still up beside the keypad) and locks Exit as "Fix 1 thing" | yes (`flow13p/18–19`; my probe: the pop-up opened on `noPressedFace`) | `FlexibleStagePage.popsAtOnce`: "nothing pressed" does not pop while [+ New] is open, because that tab asks for exactly that. It stays in the top line. Every other blocker still pops at once. **Exit is unchanged** ("Fix 1 thing" opens the pop-up when you tap it); question 5. | `FlexibleR7SettingsTests.testResetAllPopsNothingOverModelAndNew`, and the hosted `testResetAllOnHisPadOpensNoPopUpOverModelAndNew` (his pad; [Reset all] and [Reset] clicked; no `fix-*` button; none beside the keypad's ask for Face 3; the Exit title is read). RED `controlPopOnNewTab`: `fix-press-1`, today's pop-up. |
| minor: long names cut in the rail tab and the player | rail yes; player yes | 12 characters at most; the rail title wraps instead of being cut. **The player's line beside a long name is NOT fixed**: "Column preview · no lattice buil…" beside "Index finger". The player's row belongs to R7-V (Play view) and to the redesign; question 8. | The hosted test: "Index finger" is drawn 66×14 (needs 14) and "WWWWWWWWWWWW" 66×28 (needs 28), inside the 72 pt tab. RED `FlexibleSettingsRailView.controlOneLineTitle`: one line, 10 pt, cut. The player's widths are printed (Group 3: 190 of 196 pt; Index finger: 166; widest 12: 93), not asserted. |
| minor: the face card's group chips still read "1 2 3 + New" | yes | not changed; question 6 | — |
| minor: the edges tab still shows other groups' heat legend and the player ("All") | yes | R7-V's scope (heat for the current group; the player only with Play); not changed here | — |
| minor: Strip width / Patch size rows and cut I2 lines on the edge/corner cards | yes | R7-E's scope; not changed | — |
| minor: the open group's cut face shows no depth chip | **not reproduced** | Probe on his pad (Face 1 is a 12 mm stamp): after Edge 9's cut, Face 1's rest (1000105) draws its chip (stack 3712 columns, stamp grid, footprint, prism all present). It still draws after an undo/redo. (The probe's Strip width 15 call left the rest's columns unchanged, and its answer was not read, so that step proves nothing.) The verifier's missing chip came after more steps: Strip width 15, a corner group and its strip width, then undo/redo. That longer sequence is left for I2/R7-E with these steps. | — |
| minor: one tap on the trash deletes a whole group with no confirm; two identical trash icons with different reach | yes | not changed (one undo step brings it back); question 7 | — |
| correct: Reset all (and trashing the last group) pops `noPressedFace` — undisclosed, untested | yes | as the MAJOR above (option b); disclosed here | as above |
| correct: on [+ New] (with faces pressed) and on [Model], tapping a face no group holds still opens Group 1 | yes (probe: rail `group(1)`) | [+ New]: `startNewGroup` starts the next group (main-page weight, else the keypad row `FlexibleNewGroupAsk`, now for any next number; one undo step; its tab opens). [Model]: `lastWorkTab`, the group (or Rests) he last had open. The line "Press two faces first" now shows only when no face is free. | `FlexibleR7SettingsTests.testATapOnNewStartsAGroupFromAFaceNoGroupHolds`, on his pad with face 3 out of the setup: [+ New] stays open, the keypad asks, 2 kg starts Group 4 = [3], the other groups are untouched, one undo step; on [Model] Group 3 opens. RED `controlNewTabOpensGroupOne`: Group 1 from both. `FlexibleRound5SettingsVerifyTests` (a candidate face tapped on [+ New]) is green unchanged. |
| correct: some Settings lines still print "Group N" after a rename (the readiness pop-up lines, the disc's accessibility label, toasts) | yes | not changed: the readiness text is shared with the main page's pill. This waits on question 1. | — |
| correct: no test exercised present()'s new rule | yes (the loop ran over an empty list) | — (already built) | `FlexibleR7SettingsTests.testAPopUpAboutAnotherGroupsFaceLeavesTheTab`: an issue stands on Group 1's face (noLatticeUnder, core's share set to 10 %). With the edges tab or Group 2's tab open, the pop-up selects nothing and the tab and selection stay; with Group 1 open it selects the face. RED `controlRailFollowsSelection` (today's present()): Face 1 is selected and the tab jumps to Group 1. **Green against the stubs**: it pins what was built, and its red control is the proof it can fail. |
| correct: `controlNoNameRemap` was not reset if the test threw | yes | `defer` | — |
| correct: the 16-character maximum was never laid out | yes | the cap is now 12, laid out in the hosted test (above) | as above |

**Pictures** (`round7/batch_s/`, composite: the part from the page's own renderer, with the page's chrome over it, his
pad at 13" portrait; offscreen, NOT device screenshots):
- `R7S_verify_name_1_typing_Thumbs_on_group2.png`: the field open on Group 2.
- `R7S_verify_name_2_group1_tab_no_field.png`: after Group 1's tab is tapped. Group 1 is open with no field; the rail
  and the player read "Thumbs". A picture taken 0.8 s after the tap caught the panel half redrawn (Group 1's header
  over Group 2's list); at 1.5 s it is whole.
- `R7S_verify_name_3_index_finger_on_tab_header_player.png`: "Index finger" on its tab, its header and the player's
  picker. **The player's line beside it is cut ("…no lattice buil…")**; question 8.
- `R7S_verify_name_4_widest_12_whole_on_the_rail.png`: the widest 12 characters on two lines in the tab.
- `R7S_verify_reset_1_page_model_and_new_no_popup.png`: Reset all leaves [Model] [+ New] with no pop-up; the top line
  and "Fix 1 thing" remain.
- `R7S_verify_reset_2_keypad_asks_face3_no_popup.png`: the ask row "Face 3 → Group 1 [#]" with no pop-up.
- `R7S_verify_reset_CONTROL_todays_popup.png`: the red control, today's [Press Face 1] pop-up (the camera turned to
  the top view).

**What looking at these pictures found:**
1. The 0.8 s picture of the tab switch (above); the test now waits for the panel's height animation.
2. With the ask row up for Face 3, the top line still says "Press Face 1 or tap the face that carries weight": the
   readiness suggests the Top while nothing is selected. Left as it is; question 5.
3. The player's line beside a 12-character name (above).

**Runs (verify fixes, head `20356410`; raw: `round7/batch_s/r7s_verify_runs.txt`):**
- **Tests first**: `79b62b1d`, against the stubs: 6 tests, 5 red for their reasons, 18 failures. The sixth pins present()'s
  rule, which was already built; it is green, and its red control runs inside it.
- **The new tests at `20356410`**: green, each with its red control shown red inside the test.
- **The targeted suite at `20356410`**: 149 classes (12 per run), 07:41 to 08:53, while R7-V's suite ran on the same
  machine (load 8 to 9).
  - TopOptFlowsTests: 143 classes, 966 tests, 48 skipped, 14 failures. 13 are the known pre-existing ones:
    - FlexibleBatchNVerifyTests ×8 (Xcode 27 text metrics)
    - LatticeSlotOriginTests ×4 (#354's)
    - LatticeSimSolveTriggerTests ×1
  - The 14th was this batch's hosted reset test: its click on [Reset all] missed under load and no confirm appeared. It
    now waits for the pad to settle, makes the window key, re-reads the frame and tries up to 3 times (`3d112b35`, test
    only). After that, the three R7-S classes passed twice in a row, and suite chunk 005 passed whole (73 tests, 0
    failures).
  - TopOptKitTests: 6 classes, 39 tests, 2 skipped, 0 failures.
  - No xctest death.
  - LatticeStaleTypeTests 6/6; ProjectStoreTests, UndoHistoryTests, LatticeSettingsPersistTests, ViewerTests and
    SmoothingPageRound2Tests green.
- **Goldens** (FlexibleAngledGoldenTests, 13/13 each), 0 DIFFERS in both modes:
  - deterministic: 38 identical
  - unseeded: 32 identical, 1 PART-SKIP
- **Stage-job hashes**: `stage_job_hashes_r7s_verify.txt` is identical to `angled_presses/stage_job_hashes_i2.txt`, the
  whole file (16 rows plus the controls). Nothing here reaches a job: names, the selection, the rail and the pop-up are
  display only, and a new group goes through the same press and newGroup path as before.
- **iOS**: built at `3d112b35` (BUILD SUCCEEDED; derived data flexA1r7s; the dylib carries "railTitle:"). **Not installed,
  never launched.**
- **Merge notes**:
  - FlexibleStagePage: ONE line changed in the prompt block (`fixShown == nil, Self.popsAtOnce(i, model: model)`). It
    sits 4 unchanged lines below R7-V's ghost hunk, so the 3-way merge should be clean.
  - R7-V's verify work (in flight on the main tree) changes the player's note ("shorter forms"). Re-check question 8
    with a 12-character name after the merge.
  - The other files changed here are R7-S only.

**Questions for you (from the verify):**
5. After Reset all, Exit reads "Fix 1 thing", and tapping it opens the pop-up [Press Face 1]. Should Exit be able to
   leave an EMPTY Flexible setup (for example "Exit · nothing to squish"), or must a face be pressed first, as now? Should
   the top line, with nothing selected, keep suggesting the Top?
6. Once groups have names, should the face card's group chips (1 2 3 + New) show them? For example: the selected chip
   shows its name, the segment becomes the name menu, or each chip gets a colour dot like the rail.
7. Should the group trash ask first with one line, "Delete Group 2? [Delete] [Cancel]", as Reset all does? Or show a
   toast, "Group 2 deleted · Undo"? And should the face row's trash look different, since it removes only that face?
8. Beside a long name, the Settings player's status line is cut. The player's row is R7-V's and the redesign's.
   Fit the line there, or cap names shorter?

### Your words → the fix → the test (tests FIRST: 6 red against the stubs, 77 failures, then 21 on the corrected 4f test — round7/batch_s/r7s_red_run.txt)
| his words (2026-10-14) | the fix | pinned by (RED control, run inside the test) |
|---|---|---|
| img4: "After creating the first group, and in particular adding a corner modification, automatically brings me back to Group 1. It does this after every change I make, please make it stay on the same group and never shift." | 4f. The OPEN tab is the master (FlexibleSettingsOpenGroup): its members (faces, presses, the regions they were read through) are remembered; after every edit and every undo/redo the tab is the group — or Rests — that holds them now (a strip's re-cut rest is found on its own face among the NEW regions); its members all gone: the group at the same rank, else the one before; no group: [+ New]. The tab follows a face only on his pick (tapFace, select, startGroup, a group made from a face's card, the player's picker, the pop-up's own fix); a selection the code makes moves no tab. An edges tab selects no face and its first press. A removed face, a re-cut rest, the re-open's adopt and both panels' onAppear select inside the open tab, never `loadedFaces.first`. Issue ids carry the face's ROOT (`issueKey`): a strip's re-cut rest is the same issue, so "Little lattice under Face 1" never pops again and opens Group 1. The pop-up selects its face only in the open tab. `playingGroup` is the open tab's. | `FlexibleR7SettingsTests.testTheOpenGroupNeverShiftsAfterAnyChange` — his pad + Edge 9 (4 groups); EACH tab: open, setGroupForce, setGroupColour, a curve edit (another group's and its own), setStripWidth, the re-open, undo, redo, the panels' onAppear rule, every pop-up's selection; then a face removed in another group, a lower group deleted (renumber), a face removed in the same group: the tab is always the group holding the same members, the selection none or inside it; noLatticeUnder made to stand on Face 1's rest keeps its id `noLatticeUnder|1` through a re-cut (RED `controlRailFollowsSelection`: Group 1 after Strip width and after the re-open; RED `controlIssueIdByRegion`: the rest's new id pops again). `testAnExplicitPickStillMovesTheTabAndTheTabIsWhatPlays`. `FlexibleRound5SettingsTests.testTheRailFollowsTheSelectedFaceAndThePlayingGroupIsTheTabs` green unchanged (explicit taps still move the tab). |
| img4: "What is this 3mm? I don't see anything listed in the group with that number? I should only be able to view numbers associated to what I'm working on." | 4g. `FlexibleStageOverlays.workingRegion`: the selected face only where the open tab admits it (a face of the open group — an edges group has none; a resting face on [Rests]; the face on [Model]; nothing on [+ New]). The depth chip, the curve editors, the stamp handle and the selected prism read it; the Prisms view's mm tags list only the open group's faces. | `testOnlyTheOpenGroupsNumbersShow` — Face 1 Curves 3 mm as in his img3; the edges tab with Face 1's rest selected: no chip, no curves, no stamp handle; Group 2's tags only Group 2's; Group 1 open: Face 1's chip, "3.0 mm", its curves (RED `controlGateOnSelectionOnly`: Face 1's chip and curves over the edges tab — his img4 — and every group's tags). Hosted: the edges tab mounts no `depthChip-*`, a faces tab its own face's only (positive control: chips seen on the faces tabs; RED: his img4's chip mounted over the edges tab at 13" landscape). |
| img4: "The "reset all" button does not clear out *all* groups, currently. It should absolutely do that. All that should be viewed is the "model" folder tab and the "New" one." | 4h. One sealed edit: every strip given back (`FlexibleEdgeStrips.plan` with no pick left, on a copy of `project.faceRegions`); fresh settings with NOTHING read in (no face, press, colour or name; the unit kept); every main-page Load/Anchor face remembered as deleted so the re-open reads none in (pressing one brings it back); [+ New] opens, nothing selected; the part re-opens on whole faces. [+ New] always on the rail; with nothing pressed a tap on a face starts Group 1 (`startFirstGroup`; the keypad row `FlexibleNewGroupAsk` where no main-page weight exists). | `testResetAllLeavesOnlyModelAndNew` — his pad + Edge 9: titles `["Model","New"]`, faces empty, presses nil, the regions as before the strip, still so after the re-open; one undo: every tab and the strip back; redo; face 3 (no main-page load): the keypad asks, 2 kg starts Group 1 (one undo step); the Top: Group 1 at the main page's Top weight, linked (RED `controlResetAdopts`, today's: `["Model","Group 1","Rests","New"]` and the strip still cut). |
| img3: "All groups should have a trash icon next to them and their names should be editable by tapping "group 1" or whatever the default name is." | 4d. Trash (SF trash, 44 pt) on every group header and the face list's, always; it DELETES the group (faces leave by removeFace's rule — a face a main-page group holds is remembered as deleted; an edges group gives its strips back; renumber; one undo step). `FlexibleStageSettings.groupNames` (by stored id; nil in `designInputs`; omitted when nil; carried by `normalise`); `FlexibleGroupNameField` (one line, 16 characters; 12 since the verify). | `testEveryGroupHasATrashAndATapToRenameName` — an old project encodes with no names key and round-trips byte-identical; "Thumbs" on the tab, the header, the player's picker; designInputs unchanged; 16 characters at most (12 since the verify); cleared → "Group 2"; Group 1 deleted (its face out of the setup, remembered as deleted): Group 2 is Group 1 and keeps "Thumbs"; one undo; the only group has its trash and deleting it leaves `["Model","New"]` (RED `controlNoNameRemap`: the name lost on the renumber; RED `controlRemovableOnlyWithTwo`: the only group has no trash). Hosted (11" and 13", both ways): every header's trash 44 × 44, the name 19 pt (one line), a tap opens the one-line field (26 pt) where the header is in the scroll's view (11" landscape: Group 2's header sat above the fold behind the open card — not clicked there), the only group's trash. |

### Rulings and rules this batch reverses (his 2026-10-14 words win)
- **S5 (round 5): "Reset all = a brand-new setup with the main page's loads read in"** → nothing read in; only [Model] [New].
- **S8 (round 5): "the rail follows the selected face after every edit"** → the open tab is the master; only his picks move it
  (round 5's rule is the red control).
- **D2 / round 5: the × MERGES a group into another, shown only with two or more groups** → a trash on every group that
  DELETES it. ("Join the groups", the pop-up's fix, still merges — `mergeGroup`.)
- **R6 item 3: the Prisms view tags every pressed face** → only the open group's (the prisms themselves stay).
- **[+ New] hidden when nothing is pressed** → always shown.

### Where I departed from the brief (and why)
1. **His pad already has three groups**, so the brief's "Group 2 = newGroup(with: 3), Group 3 = edges" is Group 4 = Edge 9
   here; the test runs every tab of the four.
2. **"Face 1's chip reads 3.0 mm"**: his saved pad's Face 1 is a 12 mm Stamp face; the 4g test first sets it to Curves,
   3 mm, as his img3 shows it, then checks "3.0 mm".
3. **noLatticeUnder does not stand on A1_0003 as saved**, so the 4f test makes it stand on Face 1's rest by setting core's
   latticed share to 10 % in the readiness inputs (nothing else changed).
4. **Names stay on the Settings page.** The main page's player picker and the "Group 2 would squish …" warning (the shared
   readiness, also the main page's pill) keep "Group N" — "nothing on the main page changes". Asked below.
5. **newGroup(with:) opens the new group only when made from the face he works on** (its card's [+ New] chip); a face
   moved to another group by its chips leaves the tab where it is (the face leaves its list).
6. **An edit never gains or moves a selection the code made elsewhere** (found by the suite: the main page's shared model
   gained a selection from an edit made on its page). Opening a tab still selects its first face.
7. **Reset's regions are compared by `regions`**: FaceRegionModel's id counter keeps advancing (ids are never reused), so
   the model differs only in that counter.
8. **The hosted tests run synchronously**: the page's Metal view publishes its projection only with the run loop pumped
   (an async hosted test drew no overlay at all, so its chip check would have been empty).

### Re-pinned (each to his 2026-10-14 words)
| test | it said | now |
|---|---|---|
| FlexibleRound5SettingsTests.testResetAllIsABrandNewSetupOfThisPartAndUndoable | one group; the deleted main-page face back | nothing read in; `["Model","New"]`; top A remembered as deleted (4h) |
| FlexibleRound5SettingsHostedTests.testTheRailTheBoxesTheTrashAndTheExitOnHisProject | after [Reset]: "top A back" | nothing read in, top A remembered as deleted, `["Model","New"]` (4h) |
| FlexibleRound6HostedTests.testThePrismsViewDrawsEveryPressedFacesPrismWithItsNumber | ≥ 2 tags, every pressed face's | the open group's other face's tag only (4g) |
| FlexibleSqueezeGroupsReviewTests.testRemovingAGroupGivesItsFacesTheOtherGroupsOneForce | removeGroup merges at the other group's force | the same through `mergeGroup` ([Join the groups]) — the trash deletes now (4d) |
| FlexibleSqueezeGroupsUITests.testNewGroupAndRemoveGroupByClickingThePage | the × merged group 2 into group 1 | the trash deletes group 2, faces 3 and 5 leave the setup (pressed again for the next size) (4d) |

### Files (all Flexible*; ours)
New: FlexibleSettingsOpenGroup (4f/4g), FlexibleGroupNames (4d), FlexibleNewGroupAsk (4h); tests FlexibleR7SettingsTests,
FlexibleR7SettingsHostedTests, FlexibleR7SettingsEvidence. Edited: FlexibleStageModel (railKeep, newGroupAsk; tapFace /
select follow; adopt, removeFace, press, rest select inside the open tab), FlexibleSettingsRail (selectionChanged,
railChanged, playingGroup, [New] always, the header's name and trash, onAppear), FlexibleStageModel+EdgePick (the
re-point; "In <name>"), +Groups (removeGroup deletes; newGroup opens from its card), +Presses (historyRestored syncs the
tab), FlexibleSettingsReset (4h), FlexibleSettings (`groupNames`), FlexibleSqueezeGroups (normalise carries names),
FlexibleSqueezeGroupRows (trash always, names), FlexibleSettingsSquish (the picker's names), FlexibleRowCopy and +Edges
(name overloads), FlexibleReadiness and FlexibleLatticeUnder (`issueKey`), FlexibleFixPopup (its fix follows),
FlexibleDepthChips, FlexibleFaceStamp, FlexibleDepthPrism, FlexibleStageViewTags (workingRegion), FlexibleFacePanel
(onAppear), FlexibleStagePage (present() and FlexibleStageOverlays only — R7-V's hunks :205-214, :347-381, :420-441 are
untouched; FlexibleRowCopy :309-312 untouched).
The verify fixes changed these files:
- FlexibleGroupNames: the field's tapped group, the publish, the 12 cap.
- FlexibleGroupColours: the publish.
- FlexibleSettingsRail: the title wraps, `lastWorkTab`, railTab's [+ New]/[Model] case, the [+ New] tab's ask row and
  line.
- FlexibleSettingsOpenGroup: `popsAtOnce`, `startNewGroup`, `hasFreeFace`.
- FlexibleStageModel: `lastWorkTab`, the tapFace branch.
- FlexibleNewGroupAsk: any next number.
- FlexibleStagePage: one line in the prompt block.
- Tests: FlexibleR7SettingsTests, FlexibleR7SettingsHostedTests.

### Raw runs
(all raw: round7/batch_s/r7s_runs.txt; the red runs: r7s_red_run.txt)
- **Tests first**: the API as RED STUBS with today's rules (ddd0feaf); 6 tests, 6 red, 77 failures, each for its reason
  (the tab back on Group 1 — the edges tab even after a force or a colour —, Face 1's chip and curves over the edges tab,
  the Reset leaving `[Model, Group 1, Rests, New]` and the strip cut, the name ignored, the only group with no trash, the
  32 pt ×). The 4f test then had a bug of its own (it read each tab's regions before the earlier tabs' re-cuts) and got a
  standing noLatticeUnder; its second red run: 21 failures. Then the four items, one commit each (1eb96aff 4f, a4825bd9 4g,
  79f50538 4h, 1af69007 4d), each green with its red controls.
- **Targeted suite, first run at 1af69007** (148 classes = I2's 146 + the two new; 12 per run): 999 tests, 49 skipped, 26
  failures — the 13 known (below) and 13 in five tests of this batch's: three that pinned the merge and round 5's Reset
  (re-pinned above, with attribution) and two that showed an edit giving the MAIN page's shared model a selection (fixed,
  7170ad84: an edit never gains or moves a selection the code made elsewhere); then FlexibleRound5SettingsTests' rail test
  caught newGroup's first fix (green after the second). One chunk's xctest died with signal 11
  after all its tests passed — pre-existing (see Not done).
- **Targeted suite at the final head 45ddf18e** (149 classes: + FlexibleR7SettingsEvidence, skipped without its env; no
  xctest death): TopOptFlowsTests 143 classes, 961 tests, 48 skipped, **13 failures, all known pre-existing** —
  FlexibleBatchNVerifyTests ×8 (Xcode 27 text metrics), LatticeSlotOriginTests ×4 (#354's), LatticeSimSolveTriggerTests ×1;
  TopOptKitTests 6 classes, 39 tests, 2 skipped, 0 failures. LatticeStaleTypeTests 6/6. The load flakes
  (FlexibleBatchNRefineTests, FlexibleRound5SettingsHostedTests, FlexibleCoreClaimTests) did not fire.
- **Goldens** (FlexibleAngledGoldenTests, 13 tests, 0 failures each): deterministic 38 identical, 0 DIFFERS; unseeded 32
  identical, 0 DIFFERS, 1 PART-SKIP — as I2. Every existing face press keeps its job bytes.
- **Stage-job hashes**: stage_job_hashes_r7s.txt is byte-identical to angled_presses/stage_job_hashes_i2.txt (all 16 rows
  and the controls). Nothing here reaches a job: names and the selection are display only; Reset all's regions are the
  project's own before the strips.
- **iOS**: built at 45ddf18e for 147E56A1 (BUILD SUCCEEDED; derived data flexA1r7s); TopOpt.debug.dylib 78 797 136 B,
  carries "flexible-new-group-ask" and "groupNameField-". **Not installed, never launched** (the MERGE step installs).

### Evidence (round7/batch_s/; offscreen — NOT device screenshots)
- `R7S_img4_BEFORE_edges_tab_with_face1_chip_and_curves.png` — his img4 reproduced with the red controls on: Group 2 (Edge
  14 · Face 2 + Face 3, Edge 13 · Face 2 + Face 5) open, Group 1's Face 1 (Curves, 3 mm) still selected: its "↓ 3.0 mm"
  chip and its curves over the edges tab.
- `R7S_img4_BEFORE_after_strip_width_back_on_group1.png` — the same after a Strip width change: Group 1's tab ("Can't reach
  your curve on 2324 columns", Curves, 3 mm — his img3).
- `R7S_img4_AFTER_edges_tab_no_chip_no_curves.png` / `R7S_img4_AFTER_strip_width_stays_on_the_edges_group.png` — fixed:
  the edges tab, no chip, no curves (Face 1's rest was FORCED selected to stand for his img4's state — nothing of it is
  drawn); after Strip width 50 → 45 mm, still Group 2.
- `R7S_group1_open_face1_chip_and_curves.png` — Group 1 opened: Face 1's own chip and curves (what he works on).
- `R7S_reset_BEFORE_his_pad.png` / `R7S_reset_AFTER_model_and_new_only.png` — Reset all: the rail [Model] [New], "New:
  Group 1 · Tap the face that starts it", the part bare.
- `R7S_trash_on_every_group_and_Group2_renamed_Thumbs.png` — "Thumbs" on its tab and header (its trash beside the (i)), the
  Settings player's picker "● Thumbs"; Face 4's own "22.5 mm" chip.

### What LOOKING at the evidence found
1. **The heat of every group stays on the part over the edges tab** (Face 1's heat under Group 2's tab) — the heat view is
   R7-V's item 4c (the current group's heat on a tap), not changed here.
2. **"Can't reach your curve on 2324 columns"** on Face 1 (his img3's line) — the whole-face press, 4a (the lattice section
   under a face-prism), not this batch's.
3. **The face card's group chips read numbers ("1 2 3 + New")**, not names; its menu form reads names. Left as is (a chip of
   "Thumbs" would not fit five groups on one line).

### Not done / open
- **Nothing seen on a device or the simulator** — built (BUILD SUCCEEDED, never installed, never launched).
- **The press card** the brief lists under 4g: an edges group's press rows are its own tab's; nothing else draws a face's
  press card, so nothing changed there.
- **The grey "In <group>" line, the miss line and the picker read names; the readiness / pop-up warnings and the main page
  keep "Group N"** (asked below).
- **An intermittent xctest SIGSEGV at process exit** in one suite chunk (FlexibleGroupFieldPerfTests … FlexibleLatticeUnderTests),
  after every test in it passed; it reproduces at the base 61cfce05 too (1 of 2 runs there; 3 of 5 here, none in the final suite; never with one
  class alone) — pre-existing, not loosened, reported.
- **I edited FlexibleSettingsOpenGroup.swift once while the first suite was running** (`--skip-build`, so the run's binary
  was unaffected, and no test reads that new file); the whole suite was then run again at the final head.

### Questions for you
1. **Group names on the main page**: the main page's player picker and the "Group 2 would squish …" warnings still say
   "Group N". Should your names show there too, or stay on the Squish/Settings page only (as now)?
2. **The trash on a group whose face the main page also presses** (e.g. the Top): the face leaves the Settings setup and is
   remembered as deleted; the main page still presses it in the main run (the S6 rule). Right?
3. **After Reset all, a tap on the Top** starts Group 1 at the main page's Top weight (linked) with no keypad; the keypad
   asks only where the main page gives no weight. Right?
4. **Moving a face to another group with its card's chips** keeps the tab you are on (the face leaves its list); "+ New" on
   the card opens the new group. Right?
5–8. See "After the verify" above.

# 2026-10-24 — the redesign build on #354 (batches B1…)

Branch `claude/lattice-stage-frontend-37bee1`. B1 = `2353efb4..b0eee77f` (the "Lattice depth" section and the slab removed).
B2 = the shared components lifted from #362 at `b472880b` (reviewer ruling 2026-10-24 07:30, option (a)).

## Flexible hook anchors (#362, b472880b)

Source: every `// Flexible (PR #362) H<n>` comment in #362's shared (non-`Flexible*`) files at `b472880b`, read with
`git show b472880b:<path>`, plus the merged hook table in `docs/handoffs/2026-09-29-flexible-screens.md` (§ "The merged hook
table"). "Anchor" is #354's own text the hook attaches to; each was grepped in this tree at `b0eee77f` (line = this tree).
WP = `WorkspacePlaceholder.swift`. "owns" = `flexibleMain.owns(project, stage)`. Later batches fill the rest of this file.

| hook | file | anchor (#354 text; line here) | gate (#362) | redesign status |
|---|---|---|---|---|
| (none) | WP | `@StateObject private var cameraModel` block (the `@State` list) | `@StateObject private var flexibleMain = FlexibleMainStage()` | unchanged by B1/B2/B3 |
| H3 | WP | `latticeLayer: latticeLayerIsDrawn` … MetalMeshView's last argument (1066) | `flexibleLattice: flexibleMain.layer(project, stage:, pageUp: fullScreenPageUp)` | unchanged by B1/B2/B3 |
| H4 | WP | `MetalMeshView(mesh: stageMesh,` (715); `vertexTints: … : nil` (736); `settleAnimated: !reduceMotion,` (767); `stressTints: stageSurfaceTints` (917); `bodyAlpha: latticePreviewBodyAlpha,` (1018) | `flexibleMain.mesh/tints/dents/bodyAlpha(…) ?? today's`; snap on owns | unchanged by B1/B2/B3 |
| H5 | WP | `if viewerMesh != nil, visible.wireframe, !visible.surfaceEditing {` (1296) | `if owns { FlexibleMainViewToggles(…) } else if …` | B3: line unchanged (1318); `viewModeToggles` gained Forces and Design box buttons on Topology only · B5: line unchanged (1326); `visible.surfaceEditing` is now the Edit faces MODE (`WorkspaceStageVisibility.of(stage, editingFaces:)`), not a stage · B6: line unchanged (1331); its Design box view button is labelled "Design primitives" and shows whenever the list has a row |
| H6 | WP | before `// ★ "Simulation running", top-centre (maintainer, 2026-08-18).` (1318) | `if owns { FlexibleMainLegends(…) }` | unchanged by B1/B2/B3 |
| H7 | WP | `onPickPoint: { fid, pt in` (779), first line | `if flexibleMain.read(project, mode:, face:, point:) { return true }` | unchanged by B1/B2/B3 · B5: unchanged (811); its `visible.surfaceEditing` branch (the face tools) is the mode now |
| H8 | WP | `onLatticeProbe: legendDrilledIn` (811); `setLatticeProbe(at: model, world: world,` (813) | `&& flexibleMain.wantsWallProbe(mode)`; `if flexibleMain.readLattice(…) { return }` | unchanged by B1/B2/B3 |
| H9 | WP | `stageNavButton(to: back, icon: "chevron.left")` (5480); `private func stageNavButton(to dest: WorkspaceStage, icon: String` (5603) | `title:` param ("Flexible"); `FlexibleStageNav.extra(stage, flexible:)`; never gated with a title | B3 moved: `stageNavButton(to: back, icon: "chevron.left")` (5524) is now the `else if let back = stage.back` of `if stage == .topology { … topologyCapsuleOverlay }` (5522); `private func stageNavButton(to dest:` unchanged (5648); the forward column's `ForEach` reads `stage.drawsForwardButtons ? stage.forward : []` (Topology draws none) · B4 moved: `stageNavButton(to: back, icon: "chevron.left")` (5573) is now the `else if let back = stage.back` after `} else if stage == .lattice { latticeCapsuleOverlay }` — it draws on the Surface stage only; #362's `title:` param is untouched · B5 DELETED: the `else if let back = stage.back { stageNavButton(to: back, …) }` branch and the forward `ForEach` are gone with the Surface stage (the only stage that drew them); `stageNavigationButtonOverlay`'s first branch is now `if editFaces.isEditing { editFacesHeader }` (5574). `private func stageNavButton(to dest:` is KEPT, uncalled (5654), so #362's `title:` hunk still applies; Done (`finishEditFaces`) is the way back that replaces it (P5 Q-B5g) |
| H10 | WP | `latticeThisButton` in bottomBar (11705) | `project.lattice.flexible == nil` → today's, else `FlexibleMainStatusPill` | B3 moved: `latticeThisButton` (11783) is now inside the `else` of `if stage == .topology { topologyCornerPair }` in bottomBar (lattice / surface stages only); on Topology the same action and gate are the Optimize split's ⌃ row (`topologyOptimizeSplit`, id `topology-split-lattice`) · B4 moved: `latticeThisButton` is drawn on the lattice stage inside `latticeSplit` (12532, the split's main button, ⌃ = Preview / Core / Export) and on the Surface stage in bottomBar's last `else` (11843); #362's pill swap goes on both · B5 moved: the bottom bar's last `else` (today's four, `latticeThisButton` 11752) is now what EDIT FACES shows (the branches read `if !editFaces.isEditing, stage == .topology` / `else if !editFaces.isEditing, stage == .lattice`, 11738); the lattice split's `latticeThisButton` (12512) unchanged |
| H12 | LatticeSettings.swift | `previewBakeInputs`: `s.organicForecast = nil` (1577) | `s.flexible = nil` (a Flexible edit never re-keys the bake) | unchanged by B1/B2/B3 |
| H14 | WP | `latticeLegendMounted && !latticeLegendMinimized && latticeLegendMode.drilledIn` (7565) | `\|\| flexibleMain.keyDrilledIn(project, stage, mode:)` | unchanged by B1/B2/B3 |
| H15' | WP | `clearanceVolumes:` (987) | owns → `[]` + `flexibleMain.volumes(…)` | unchanged by B1/B2/B3 |
| H20 | WP | `// ★ §3d — THE 3D DEPTH-PLANE HANDLES` / `if visible.latticeDepthPlanes, !legendDrilledIn {` (1224–1225) | `, !owns` | unchanged by B1/B2/B3 (B1 removed the depth *section*, not the 3D handles) |
| H22 | WP | `guard let m = viewerMesh else { return false }` in onPickPoint (798) | `owns, force.phase == .edit, !fullScreenPageUp` → `tapFace`; return true | unchanged by B1/B2/B3 · B5: line unchanged (830) |
| H23 | WP | `onMiss: {` (860), first line | `owns, !fullScreenPageUp` → `missTap()`; return | unchanged by B1/B2/B3 · B5: line unchanged (892); `guard visible.surfaceEditing` now reads the mode |
| H24 | WP | `if force.gravityIsSet { bottomRightControls }` (1265) | `, !owns` | B3: line unchanged (1287); what it mounts changed — on Topology `visibleSettingsChips` keeps Paint only (its other chips are the Setup chip's rows); lattice / surface stages unchanged · B5 changed what it mounts (1297): the chip column's Paint chip shows ONLY in Edit faces (the column's one chip there; greyed on STEP with one line, `EditFacesPaint`), on no stage outside it; lattice stage's other chips unchanged |
| H25 | WP | `if selectionsCollapsed { latticePreviewNotice }` (9544) / `private var selectionsLibraryCard` (9621) | `owns, !fullScreenPageUp` → `FlexibleSelectionsList(…)` else `selectionsLibraryCard` | B3 moved: in `selectionsPanel`, `if selectionsCollapsed { latticePreviewNotice }` unchanged (9603); the `selectionsLibraryCard` line (9606) is now the `else` of `if stage == .topology, !showLatticePage { topologySelectionsList }`; `private var selectionsLibraryCard` unchanged (9683). #362's owns-swap goes on the else branch · B4 moved: `selectionsLibraryCard` (9659) is now the `else` of `else if stage == .lattice, !showLatticePage { latticeSelectionsList }` (9658) — the lattice stage draws SelectionsList; the card stays for the Surface stage and the lattice page's library; #362's `owns` swap goes before the new branch · B5 moved: a new first branch `if editFaces.isEditing { selectionsLibraryCard }` (9564) — the card the Surface stage drew; Topology's and the lattice list's lines are unchanged text, now `else if` — #362's owns-swap goes after the mode branch (P5) · B8: `latticeSelectionsList` (12760): the Grade pair under the list is DELETED (Grade lives only on the Cells page); the list itself and `selectionsLibraryCard` are unchanged |
| H26 | WP | `if viewerMesh != nil, regionsOpen { regionsPanelOverlay }` (1273) | `, !owns` | unchanged by B1/B2/B3 · B5: mount unchanged (1305); `regionsOpen` is now reached only from Edit faces (its library card's header toggle) and is shut on Done |
| H27 | WP | `if viewerMesh != nil { stageNavigationButtonOverlay }` (1278) | `owns` → `FlexibleStageCapsule(…).modifier(StageNavPlacement(stage:))` else today's | B3: line unchanged (1300); inside `stageNavigationButtonOverlay` Topology draws `topologyCapsuleOverlay` (StageCapsule, 5522) while its Results page is shut, and a second mount over ResultsScreen (1546) while it is up; lattice / surface stages draw today's buttons · B4: mount line unchanged (1310); inside `stageNavigationButtonOverlay` the lattice stage draws `latticeCapsuleOverlay` (● <Type> ⌄ | Regions | Cells | ✂), and a second mount sits over the Cells page (`if showLatticeWizard, stage == .lattice, viewerMesh != nil { latticeCapsuleOverlay }`); #362's `owns → FlexibleStageCapsule` goes before `else if stage == .lattice` · B5: mount unchanged (1310); inside, `if editFaces.isEditing { editFacesHeader }` comes FIRST (5574), then Topology's / the lattice stage's capsule; #362's `owns → FlexibleStageCapsule` goes after the mode branch · B8: mount unchanged (1312); `topologyCapsuleOverlay` (12083) passes `hidden: TopologyPage.hiddenSegments(hasResults:)` — Results and Smooth are not DRAWN until the project has results (StageCapsule's new defaulted `hidden`, `drawnPages`); the ✂ always draws. `editFacesHeader` (12186) gained Discard beside Done (asks in place). #362's `owns → FlexibleStageCapsule` placement is unchanged |
| H28 | WP | `if viewerMesh != nil { latticeSettingsButtonOverlay }` (1280) | `, !owns` | unchanged by B1/B2/B3 · B4: mount line unchanged (1312); `latticeSettingsButtonOverlay` now draws nothing on the lattice stage (`Self.latticeSettingsButtonDrawn = false`: the capsule's Cells replaces Settings) — #362's `, !owns` is harmless · B5: unchanged (1312) |
| H29 | WP | — (#362's own FlexibleStageChip branch, −3) | — | unchanged by B1/B2/B3 (no #354 anchor) |
| H30 | WP | bottomBar `Spacer()` → `ComputeLocationControl(compute: compute)` (11701) | `owns` → `FlexibleCornerPair(…)` else today's four lines | B3 moved: bottomBar's `Spacer()` is now followed by `if stage == .topology { topologyCornerPair } else {` and today's four lines (`ComputeLocationControl(compute: compute)` 11779 … `optimizeButton`); #362's owns-swap goes on the else branch · B4 moved: bottomBar is now `if stage == .topology { topologyCornerPair } else if stage == .lattice { Compute · Print parameters · latticeSplit } else { today's four }` (11835–11845); #362's `owns → FlexibleCornerPair` goes before the lattice branch · B5 moved: `if !editFaces.isEditing, stage == .topology { topologyCornerPair } else if !editFaces.isEditing, stage == .lattice { … } else { today's four }` (11738–11753); #362's `owns → FlexibleCornerPair` goes before, gated `!editFaces.isEditing` |
| H31 | WP | — (#362's own C2 Export-step line) | `, !owns` | unchanged by B1/B2/B3 (no #354 anchor) |
| H32 | WP | after `latticeEdgeLight` (1300) | `owns` → `FlexibleOnModelLayer(…)` | unchanged by B1/B2/B3 |
| H33 / H34 | WP | — (#362's own H6 legend / P player lines) | `chipColumnWidth: 0` | unchanged by B1/B2/B3 (no #354 anchor) |
| H35 | ProjectModel | `latticeEligibleRoles()` | WITHDRAWN (his ruling 2026-10-18) | not applicable |
| H36 | WP | — (#362's own FlexibleStagePage mount) | `onLeave: { goToStage($0) }, onAbout: …` | unchanged by B1/B2/B3 (no #354 anchor) · B5 ADDED the API #362 calls instead of `goToStage(.surface)`: `enterEditFaces(from: .host("flexible.<page>"), onReturn: { origin in <put that page back> })` (12113); Done (`finishEditFaces`, 12125) calls `onReturn` with the same origin. `goToStage` is unchanged in signature · B8: `enterEditFaces` (12133) now also calls `project.openFaceEditing()` (what Discard goes back to); Done = `finishEditFaces` (12147, calls `project.closeFaceEditing()`); NEW `discardEditFaces()` (12173) = `project.discardFaceEdits()` (one undo step) then `finishEditFaces()`, so a `.host` origin's `onReturn` runs on Discard too |
| H37 | WP | first line of `func openLatticeSettingsIfUnconfigured()` (3851) | `if project.lattice.flexible != nil { return }` | unchanged by B1/B2/B3 · B4: line unchanged (3935); `showLatticeWizard = true` now opens the CELLS page (LatticeSetupWizard's `.cellsPage` presentation), not the full-screen settings page — #362's early return is unchanged · B8: line unchanged (3948); the full-screen settings page is DELETED (LatticeSetupWizard draws only the Cells page; no sample cube, cinematics, Save & Exit or Refresh; `wizardCamera` / `.stageCamera` gone) — #362's early return is unchanged |
| H38 / H38' | WP | — (#362's own onChooseFlexible lines; `onChooseFlexible` is absent here) | `showLatticeWizard = false`; `.newSetup()` | unchanged by B1/B2/B3 (no #354 anchor) · B4: the selector's mount `LatticeStageModeModal { mode in` (1389) is unchanged; its gate is `LatticeTypeSelector.isShown(…)` and its second line `LatticeTypeSelector.oneTypeLine`; this tree offers two cards (`LatticeTypeChoice.offered(flexibleStageBuilt: false)`) — #362's `onChooseFlexible` card lands as before. ALSO MOVED (no H number in #362; its own line): `latticeStageModeNeeded` is now `LatticeTypeSelector.isShown(onLatticeStage:typeInUse:)` — #362's `&& project.lattice.flexible == nil` goes after that call; and onChoose's `project.lattice.stageMode = mode` is now `project.lattice.chooseLatticeType(mode)` (LatticeStage.swift), whose `clearLatticeType()` is where #362's merge must add `flexible = nil` (reviewer 08:45; pinned by `LatticeStageTests.testPickingStructuralOrAestheticClearsAnyOtherType`) |
| H39 | WP | the Selections header's Regions toggle, `square.on.square.dashed` (5509) | `.flexibleDrawn(when: !owns)` | B3: anchor unchanged (9709) — it is in `selectionsLibraryCard`, which Topology no longer draws; Topology's list has its own "Regions" button under it (`topology-regions`) · B4: anchor unchanged (9762) — `selectionsLibraryCard`, which the lattice stage no longer draws either; its list has a "Regions" button under it (`lattice-regions`) · B5: anchor unchanged (9670) — the Regions toggle is now an EDIT FACES control (the library card draws only there); B3's `topology-regions` and B4's `lattice-regions` buttons are DELETED (moved into Edit faces) |
| H40 | MetalMeshView.swift | `let latticeOnly = bodyAlpha <= 0.5` (4051) | `&& !flexibleBodyPrinted` | unchanged by B1/B2/B3 (anchor intact; the branch it gates now builds `LatticePrismMesh.build(r)`, B1 `2353efb4`, the same whole-prism footprint) |
| H41 | ImportSheet.swift | the sheet's `@StateObject` list | `@StateObject private var flexDraft = FlexibleImportDraft(…)` | unchanged by B1/B2/B3 |
| H42 | ImportSheet.swift | the process picker's five lines | `flexDraft.available` → three segments, else today's five lines | unchanged by B1/B2/B3 |
| H43 | ImportSheet.swift | `materialDropdown` (52) | `flexDraft.on` → `FlexibleImportFilamentMenu`, else `materialDropdown` | unchanged by B1/B2/B3 |
| H44 | ImportSheet.swift | `model.continueToWorkspace()` (62) | `flexDraft.on` → `continueFlexible`, else today's | unchanged by B1/B2/B3 |
| H45 | WP | `DS.Color.background.color.ignoresSafeArea()` (714) | `.onAppear { FlexibleNewProject.takeLatticeStage(for:) → goToStage(.lattice) }` | B3: line unchanged (731); it now carries an `.onAppear` (Results notice seed + H50c) — #362's H45 `.onAppear` goes beside it · B4: line unchanged (739); its `.onAppear` gained `LatticeStageOpen.take(for:)` → `goToStage(.lattice)` (a copy made to choose a type, or the lattice card's Save as new project) · B5: unchanged (739) · B8: line unchanged (739); the `.onAppear` seed is unchanged — the reopen fix is in `.onChange(of: acceptedVariantCount)` (`landedByRun: TopologyResultsNotice.landedByRun(run.phase)`) |
| H46 | HomeView.swift | `Text(project.meta)` (169) | `FlexibleHomeCard.meta(project) ?? project.meta` | unchanged by B1/B2/B3 |
| H47 | TopOptKit.swift | `importMesh(path:linearDeflectionMM:)`: `return convert(raw)` (2591) | `.step/.stp` AND not watertight → `StepMeshRepair` | unchanged by B1/B2/B3 |
| H48 | WP | `case .paint:` → `paintChip.background(chipWidthReader(id))` (5927) | `.flexibleRepairedStepPaintGate(path:)` | unchanged by B1/B2/B3 · B5: line unchanged (5922); `paintChip` now wraps the button (`paintChipButton`) and greys it on STEP with "Not for STEP: its CAD faces are already exact."; the chip shows only in Edit faces. #362's `.flexibleRepairedStepPaintGate(path:)` still goes on this line (R9: keep or retire) · B8: line unchanged (5924); the enabled line is now "Drag across the mesh to paint a face." (any non-STEP mesh: STL, 3MF, OBJ) |
| H49a | WP | `project.clearanceVolumes()` mapping (2145) | `project.groupView.showing(…)` (a hidden group draws no volume) | unchanged by B1/B2/B3 |
| H49b | WP | `project.clearanceHandles()` loop (6777) | `groupView.showing(…, group:)` | unchanged by B1/B2/B3 |
| H49c | WP | `if let proj = projection, let gid = selection.activeGroupID` (8863) | `, project.groupView.drawsPrimitiveKnobs(forActive: gid)` | unchanged by B1/B2/B3 |
| H50a | WP | `canOptimize`'s `lastRunRequest` check (184 is the first use) | `RerunCard.greysOut(sameInputsAsLastRun:existing:)` | B3 built here, as #362's: the `canOptimize` line is `RerunCard.greysOut(sameInputsAsLastRun:existing:)` (11855) |
| H50b | WP | `.alert(…, isPresented: replacementPromptBinding)` (3008) | the re-run card: Re-run here / Save as new project / Cancel | B3 built here, as #362's: `.alert(RerunCard.title, isPresented: replacementPromptBinding)` (3046) — Re-run here / Save as new project (`saveAsNewProjectAndRun`) / Cancel · B4: the Topology alert is unchanged (3079); the LATTICE run has its own card below it, `.alert(LatticeRerunChoice.title, isPresented: latticeRerunBinding)` (3091): Re-run the lattice here (`startLatticeRequest()`, never `startRun()`) / Save as new project (opens the copy on Lattice) / Cancel |
| H50c | WP | `.onAppear` beside H45 (714) | `RerunCard.takeRunOnOpen(for:)` → `startRun()` | B3 built here, as #362's: the `.onAppear` on `DS.Color.background…` (731) — `RerunCard.takeRunOnOpen(for:)` → `startRun()` · B4: unchanged; the lattice card's copy does NOT run on open (it opens on Lattice and says "press Lattice") |
| H50d | WP | `@State private var pendingReplacement: ResultsReplacementPrompt?` (496); `pendingReplacement = prompt` (1643) | `rerunOffersCopy` (Optimize re-run only) | B3 built here, as #362's: `@State private var rerunOffersCopy`; `rerunOffersCopy = true; pendingReplacement = prompt` (1669) in requestRun, `= false` in requestLatticeRun · B4 moved: `requestLatticeRun` no longer touches `rerunOffersCopy` / `pendingReplacement`; it sets `pendingLatticeRerun = prompt` (1707); `rerunOffersCopy = true; pendingReplacement = prompt` (1689) is Optimize's alone |
| H51 | HomeView.swift | the card's `contextMenu` (198) | the long-press "Duplicate" → `duplicateProject(id:)` | unchanged by B1/B2/B3 |
| H52 | AppModel.swift | — (a new function; `duplicateProject` is absent here) | `duplicateProject(id:)` (ProjectDuplication) | B3 built here, #362's code unchanged: `AppModel.duplicateProject(id:)` (756) and `ProjectDuplication.swift` (lifted) |
| H53 | RootView.swift | `WorkspacePlaceholder(model: model, project: project)` (26) | `.id(project.id)` | B3 built here, as #362's: `.id(project.id)` on `WorkspacePlaceholder(model: model, project: project)` (RootView 29) |

Named in the handoff only, with no `H<n>` comment in #362's shared files at `b472880b` (superseded, reverted, folded or never
built — the handoff says which): H1, H2, H2', H4', H5', H5'', H7', H9', H10', H11, H13, H16, H17, H18 (removed with H24), H18',
H19, H21, H25', H29', H35', H39', H42'.

**B1 moved or deleted no hook anchor** (0 of 49 rows): its WorkspacePlaceholder hunks are the wizard-cover state, the bake key's
`wallThickness`, the wall stress field, the slab regions and the bake's wall arguments; its MetalMeshView hunk is inside H40's
branch, not on H40's line.

**B3 (Topology) moved 15 of 49 rows** (the rows above that name B3): H5, H9, H10, H24, H25, H27, H30, H39, H45 moved or
changed what they mount; H50a–d, H52, H53 are built here with #362's code (RerunCard / ProjectDuplication), so #362's own lines
land as no-ops or conflicts with identical text. No Flexible code was added or changed; every other anchor is untouched.

**B4 (Lattice) moved 12 of 49 rows** (H9, H10, H25, H27, H28, H30, H37, H38, H39, H45, H50b, H50d; H50c noted): the lattice stage's
back button, Settings button, stage-button column and bottom bar became its capsule, its Cells page and its lattice split; its
Selections card became SelectionsList; the lattice run got its own re-run card. No Flexible code was added or changed. Line numbers
above in the B4 notes are this tree's after B4.

H41–H44 (ImportSheet, New TopOpt's Flexible process): untouched by B4 — the lattice type selector is the Lattice stage's first-entry modal, not the import sheet, so it does not replace New TopOpt's Flexible tab.

**B5 (Edit faces) moved or changed 16 rows** (H5, H7, H9 deleted-branch, H10, H22, H23, H24, H25, H26, H27, H28, H30, H36 API added,
H39, H45, H48; the unchanged ones are marked so a re-seat need not re-check them). No Flexible code was added or changed; #362's
`WorkspaceStage.surface` uses (FlexibleStageCapsule.swift:68/:84, FlexibleStageNav.swift:21-22) stop compiling at the sync, as its
plan's P5 expects — swap them for `.editFaces` / `enterEditFaces(from: .host(…), onReturn:)`.

**B6 (Design primitives) moved no hook anchor** (0 of 49; H5's row notes its view button's new label): no anchor's text
changed. WorkspacePlaceholder lines after the `@State` list shift by +3, after the MetalMeshView design-box arguments by +5 (H5
1331, H15' 1024, H24 1302, H3 1103), and after the Setup panel by about +150. No Flexible code was added or changed.

## B6: what a Topology run sends while the primitive list is not sent

**A Topology run sends the FIRST POSITIVE BOX row as today's single design box, and every NEGATIVE BOX row as today's
keep-outs, exactly as today's job carries both** (his answer 2026-10-24: "Run with just the first design box for now. It's only
me working on the app right now."). Cylinders and Positive boxes after the first are not sent until core takes the list; there is
no card in the UI. A list with no Positive Box sends no design box and no keep-outs (as today). `DesignBoxModel.bridgeBox` = the
first Positive Box's bounds; `bridgeKeepOuts` = every Negative Box's bounds in list order (eyes are view-only: hidden rows still
send). Coordinator's correction to the B6 build: the builder had made `bridgeKeepOuts` empty, which silently dropped an old
project's keep-outs (drawn "no mass here", not sent) — core already takes keep-outs, so Negative boxes keep going out. Pinned: the cube's job with one Positive Box equal to today's design box is
byte-identical to 9735ed42 (`DesignPrimitivesTests.jobWithBoxAtHEAD`, sorted-key SHA-256 c4af7bfa…), hidden or shown.

Saved projects: today's `designBox` (`box`, `keepOuts`) opens as row 1 (Box, Positive) then Negative box rows; an untouched list
encodes as before (the same two keys); a list the old keys cannot hold adds a `primitives` key beside them. Decoding never fails
(an unreadable `primitives` falls back to the old keys, then to an empty list).

## CORE LIST

- **Design primitives list: up to 6, Box/Cylinder, Positive/Negative — core takes one design box today; a new core agent will
  take the list.** The app holds the list (`DesignBoxModel.primitives`: shape, sign, bounds, cylinder axis, eye); the send for
  the full list stays off (B6 above).
- **Grade direction: Through the depth / Across the face — core's grading reads only stress today; key map to #358.** The app
  saves `LatticeSettings.gradeAlong` (`depth` / `face` / `load`) and the preview DRAWS the first two (below); no job key carries
  it (`LatticeStageTests` pins the stage lattice job at b39c1560… with either pick). Core needs a grading key for the direction
  (e.g. `grading.grade_along`: `stress` | `depth` | `face`, absent = `stress`) and a density law per direction: ρ from
  `grading.max_relative_density`'s side at the face plane (or the outline) to the floor at the prism's far end (or the face's
  middle), per lattice region, through the printability floor and the cap as today. `stepped_cells[].rho` would then follow it.

## APP LIST (this branch)

- **Along, drawn (ruling 2026-10-24 17:46: no notice; draw it).** Both picks are drawn by the octree bake
  (`LatticePreviewOccupancy.alongFraction`, LatticeOctreeBake.swift): "Through the depth" maps each texel's depth in from the
  face plane (inward normal ÷ `depthMM`) onto the drawn band, top at the face → floor at the far end; "Across the face" maps
  its in-plane distance from the outline (`inPlaneDistance`, ÷ that region's largest) the same way, top at the outline → floor
  at the middle. Both go through the band raise, the bead's floor and the job's cap as today. Only the DRAWN activation moves:
  each plan cell's ρ (what `stepped_cells` sends) keeps the demand's value. `gradeAlong` is now a bake input
  (`previewBakeInputs` no longer strips it), so a pick rebakes. "Saved, not sent" is gone. Pinned:
  `LatticeGradeAlongPreviewTests`. Not drawn yet: the older stepped (non-octree) path, the organic preview, and a texel no face
  region owns (a body/primitive region keeps the demand's draw) — none of these grades by Along until core does.

## Per-region lattice values: what it would take

Not built (ruling 2026-10-24 17:46). Today every Cells row is global (`LatticeSettings`: topology, cell, density band,
grade from→to, Along, strength, transition); the approved design has a tab per region.

APP
- **Model (M).** Per-region overrides keyed by the selectable key, as already done for `selectableCellMM`, `selectableDensity`,
  `selectableDepthMM`, `selectableExpandMM`, `selectableRoles`, `selectableSyntheticFoci` (LatticeSettings): add the rest —
  grade from/to, Along, strength — as `[String: …]` maps (or one `selectableCells: [String: RegionCellsOverride]`), nil =
  inherits the global row. Codec: `decodeIfPresent` + an untouched project writes no new key.
- **Cells page (M).** The tab per region (B4 already lays out the tabs): a tab edits that key's overrides, the "All" tab the
  globals; a row shows "inherits" vs its own value; Duplicate / Continue carry the maps.
- **Preview bake (M).** The octree bake takes the band, gamma, Along and grade strength as globals; it needs them per owning
  region (`owner[i]` → region → its key's values) in `shapedRho` / `alongFraction`, and `previewBakeInputs` already re-keys on
  every map. The legend and the face card read per-region bands.
- **Persistence (S).** The maps above live in `project.json` like today's `selectable*` maps; the variant / re-lattice copies
  carry them.

CORE (core/src/cli/job.cpp, read only)
- **Per region today** (`lattice.regions[]`): `role`, `kind`, `face_id` / `region_id`, `relative_density` (a stated density),
  `synthetic_stress` / `_foci` / `_soft_mm`, and `geometry` (`depth_mm`, `outline_uv`, `slot_origin_mm`,
  `plan_base_cell_mm`, frame); the plan's `lattice.stepped_cells[]` carry a cell size and ρ per region. Depth protections are
  per face (`face_protections[].depth_mm`).
- **Global only** (`grading.*`): `topology`, `cell_mm`, `cell_mode` / `cell_min_mm` / `cell_max_mm`, `demand_exponent`,
  `max_relative_density`, the aesthetic ρ min/max, `shape_grade` / `shape_grade_band_mm`, `algorithm` and the organic keys.
- **What core would need (L).** Per-region grading overrides on `lattice.regions[]` (a density band min/max, demand exponent,
  cell size or cell window, shape grade band, and Along once it exists), each falling back to `grading.*`; the grader and the
  plan check read them per region. One topology per project stays global (B4's one type). Goes to #358's key map with Along.

## B5 — Edit faces: what #362 and core get

- **Mode flag / entry point.** `EditFacesSession` (EditFaces.swift): `isEditing` is the flag, `origin` where Done returns.
  One entry point, `WorkspacePlaceholder.enterEditFaces(from:onReturn:)`; Done is `finishEditFaces()`. Origins:
  `.topology(.setup|.results|.smooth, smoothVariant:)`, `.lattice(.regions|.cells)`, `.host(String)` (Flexible's pages).
- **Post-edit hook.** `ProjectModel.onFaceEdit(_ key:, _ hook:)` / `removeFaceEditHook(_:)`: runs after every Edit faces
  edit (cut, isolate, union, pattern, region verbs, paint) INSIDE its undo step, with a `FaceEditEvent` (kind, regions made /
  removed, painted faces). Region edits are sealed before AND after (`beginFaceEdit` / `endFaceEdit`, APP LIST 1's undo-merge);
  a paint stroke is a drag folded by the settle, so its hook runs inside the stroke's settled step and is not sealed.
- **Edited faces.** `EditedFaces.leaves(mesh:regions:paint:)` — one `EditedFace` per edited face, `.face(id)` (CAD or
  painted) or `.region(rid)`, with `lineage` (the CAD faces it came from); `outline(_:mesh:regions:paint:)` — one outline
  each (triangle-granular boundary); `leaf(face:point:mesh:regions:fallback:)` — the edited face under a tap (the piece tap on
  every stage now calls it). FaceRegionModel ids (100…) and `.faces` / `exportRemap` are unchanged, so 1M + rid keys
  (his_0004's 1000103 / 1000104) keep resolving (`EditFacesModeTests.testSavedRegionIdsKeepResolvingAsEditedFaces`).
- **No new storage.** `sidecarSuffixes` unchanged (`.faces`, `.clearances.json`). The Mac worker upload now carries `.faces`
  (multipart `faces`, saved by topopt_worker.py as `<model>.faces`); before B5 a worker run dropped every painted face.
- **CORE DEPENDENCY (reviewer (j)) — a clearance on a CUT piece.** Core's clearance takes `face_id` or `geometry`, never a
  region (job.cpp:722-735). The app never sends the original CAD face for a cut half (pinned), but the half's own Keep clear
  is not sent at all (`clearanceSpecs` walks `g.faces`; a half lives in `regionIDs`). Needs a core change: a clearance
  `region_id` (as `face_protections` has, job.cpp:825-855), in #362's shared job_block.cpp schema too. A PAINTED piece is fine:
  it is a face in core's face space (`.faces`), and its run id is sent.
- **CORE DEPENDENCY (reviewer (k), item 43 / #358).** Core keys the protection-vs-lattice depth tie and its receipts by face
  id (job.cpp:2548-2554, `r.face_id`), so a cut or painted piece on a LATTICE stage loses that tie and its receipt. Not worked
  around in the app; waits for core to key them by region as well.


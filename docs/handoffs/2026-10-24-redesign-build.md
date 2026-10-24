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
| (none) | WP | `@StateObject private var cameraModel` block (the `@State` list) | `@StateObject private var flexibleMain = FlexibleMainStage()` | unchanged by B1/B2 |
| H3 | WP | `latticeLayer: latticeLayerIsDrawn` … MetalMeshView's last argument (1066) | `flexibleLattice: flexibleMain.layer(project, stage:, pageUp: fullScreenPageUp)` | unchanged by B1/B2 |
| H4 | WP | `MetalMeshView(mesh: stageMesh,` (715); `vertexTints: … : nil` (736); `settleAnimated: !reduceMotion,` (767); `stressTints: stageSurfaceTints` (917); `bodyAlpha: latticePreviewBodyAlpha,` (1018) | `flexibleMain.mesh/tints/dents/bodyAlpha(…) ?? today's`; snap on owns | unchanged by B1/B2 |
| H5 | WP | `if viewerMesh != nil, visible.wireframe, !visible.surfaceEditing {` (1296) | `if owns { FlexibleMainViewToggles(…) } else if …` | unchanged by B1/B2 |
| H6 | WP | before `// ★ "Simulation running", top-centre (maintainer, 2026-08-18).` (1318) | `if owns { FlexibleMainLegends(…) }` | unchanged by B1/B2 |
| H7 | WP | `onPickPoint: { fid, pt in` (779), first line | `if flexibleMain.read(project, mode:, face:, point:) { return true }` | unchanged by B1/B2 |
| H8 | WP | `onLatticeProbe: legendDrilledIn` (811); `setLatticeProbe(at: model, world: world,` (813) | `&& flexibleMain.wantsWallProbe(mode)`; `if flexibleMain.readLattice(…) { return }` | unchanged by B1/B2 |
| H9 | WP | `stageNavButton(to: back, icon: "chevron.left")` (5480); `private func stageNavButton(to dest: WorkspaceStage, icon: String` (5603) | `title:` param ("Flexible"); `FlexibleStageNav.extra(stage, flexible:)`; never gated with a title | unchanged by B1/B2 |
| H10 | WP | `latticeThisButton` in bottomBar (11705) | `project.lattice.flexible == nil` → today's, else `FlexibleMainStatusPill` | unchanged by B1/B2 |
| H12 | LatticeSettings.swift | `previewBakeInputs`: `s.organicForecast = nil` (1577) | `s.flexible = nil` (a Flexible edit never re-keys the bake) | unchanged by B1/B2 |
| H14 | WP | `latticeLegendMounted && !latticeLegendMinimized && latticeLegendMode.drilledIn` (7565) | `\|\| flexibleMain.keyDrilledIn(project, stage, mode:)` | unchanged by B1/B2 |
| H15' | WP | `clearanceVolumes:` (987) | owns → `[]` + `flexibleMain.volumes(…)` | unchanged by B1/B2 |
| H20 | WP | `// ★ §3d — THE 3D DEPTH-PLANE HANDLES` / `if visible.latticeDepthPlanes, !legendDrilledIn {` (1224–1225) | `, !owns` | unchanged by B1/B2 (B1 removed the depth *section*, not the 3D handles) |
| H22 | WP | `guard let m = viewerMesh else { return false }` in onPickPoint (798) | `owns, force.phase == .edit, !fullScreenPageUp` → `tapFace`; return true | unchanged by B1/B2 |
| H23 | WP | `onMiss: {` (860), first line | `owns, !fullScreenPageUp` → `missTap()`; return | unchanged by B1/B2 |
| H24 | WP | `if force.gravityIsSet { bottomRightControls }` (1265) | `, !owns` | unchanged by B1/B2 |
| H25 | WP | `if selectionsCollapsed { latticePreviewNotice }` (9544) / `private var selectionsLibraryCard` (9621) | `owns, !fullScreenPageUp` → `FlexibleSelectionsList(…)` else `selectionsLibraryCard` | unchanged by B1/B2 (B2: neutral `SelectionsList` now exists, not wired) |
| H26 | WP | `if viewerMesh != nil, regionsOpen { regionsPanelOverlay }` (1273) | `, !owns` | unchanged by B1/B2 |
| H27 | WP | `if viewerMesh != nil { stageNavigationButtonOverlay }` (1278) | `owns` → `FlexibleStageCapsule(…).modifier(StageNavPlacement(stage:))` else today's | unchanged by B1/B2 (B2: neutral `StageCapsule` exists, not wired) |
| H28 | WP | `if viewerMesh != nil { latticeSettingsButtonOverlay }` (1280) | `, !owns` | unchanged by B1/B2 |
| H29 | WP | — (#362's own FlexibleStageChip branch, −3) | — | unchanged by B1/B2 (no #354 anchor) |
| H30 | WP | bottomBar `Spacer()` → `ComputeLocationControl(compute: compute)` (11701) | `owns` → `FlexibleCornerPair(…)` else today's four lines | unchanged by B1/B2 (B2: neutral `CornerPair` exists, not wired) |
| H31 | WP | — (#362's own C2 Export-step line) | `, !owns` | unchanged by B1/B2 (no #354 anchor) |
| H32 | WP | after `latticeEdgeLight` (1300) | `owns` → `FlexibleOnModelLayer(…)` | unchanged by B1/B2 |
| H33 / H34 | WP | — (#362's own H6 legend / P player lines) | `chipColumnWidth: 0` | unchanged by B1/B2 (no #354 anchor) |
| H35 | ProjectModel | `latticeEligibleRoles()` | WITHDRAWN (his ruling 2026-10-18) | not applicable |
| H36 | WP | — (#362's own FlexibleStagePage mount) | `onLeave: { goToStage($0) }, onAbout: …` | unchanged by B1/B2 (no #354 anchor) |
| H37 | WP | first line of `func openLatticeSettingsIfUnconfigured()` (3851) | `if project.lattice.flexible != nil { return }` | unchanged by B1/B2 |
| H38 / H38' | WP | — (#362's own onChooseFlexible lines; `onChooseFlexible` is absent here) | `showLatticeWizard = false`; `.newSetup()` | unchanged by B1/B2 (no #354 anchor) |
| H39 | WP | the Selections header's Regions toggle, `square.on.square.dashed` (5509) | `.flexibleDrawn(when: !owns)` | unchanged by B1/B2 |
| H40 | MetalMeshView.swift | `let latticeOnly = bodyAlpha <= 0.5` (4051) | `&& !flexibleBodyPrinted` | unchanged by B1/B2 (anchor intact; the branch it gates now builds `LatticePrismMesh.build(r)`, B1 `2353efb4`, the same whole-prism footprint) |
| H41 | ImportSheet.swift | the sheet's `@StateObject` list | `@StateObject private var flexDraft = FlexibleImportDraft(…)` | unchanged by B1/B2 |
| H42 | ImportSheet.swift | the process picker's five lines | `flexDraft.available` → three segments, else today's five lines | unchanged by B1/B2 |
| H43 | ImportSheet.swift | `materialDropdown` (52) | `flexDraft.on` → `FlexibleImportFilamentMenu`, else `materialDropdown` | unchanged by B1/B2 |
| H44 | ImportSheet.swift | `model.continueToWorkspace()` (62) | `flexDraft.on` → `continueFlexible`, else today's | unchanged by B1/B2 |
| H45 | WP | `DS.Color.background.color.ignoresSafeArea()` (714) | `.onAppear { FlexibleNewProject.takeLatticeStage(for:) → goToStage(.lattice) }` | unchanged by B1/B2 |
| H46 | HomeView.swift | `Text(project.meta)` (169) | `FlexibleHomeCard.meta(project) ?? project.meta` | unchanged by B1/B2 |
| H47 | TopOptKit.swift | `importMesh(path:linearDeflectionMM:)`: `return convert(raw)` (2591) | `.step/.stp` AND not watertight → `StepMeshRepair` | unchanged by B1/B2 |
| H48 | WP | `case .paint:` → `paintChip.background(chipWidthReader(id))` (5927) | `.flexibleRepairedStepPaintGate(path:)` | unchanged by B1/B2 |
| H49a | WP | `project.clearanceVolumes()` mapping (2145) | `project.groupView.showing(…)` (a hidden group draws no volume) | unchanged by B1/B2 |
| H49b | WP | `project.clearanceHandles()` loop (6777) | `groupView.showing(…, group:)` | unchanged by B1/B2 |
| H49c | WP | `if let proj = projection, let gid = selection.activeGroupID` (8863) | `, project.groupView.drawsPrimitiveKnobs(forActive: gid)` | unchanged by B1/B2 |
| H50a | WP | `canOptimize`'s `lastRunRequest` check (184 is the first use) | `RerunCard.greysOut(sameInputsAsLastRun:existing:)` | unchanged by B1/B2 (B2: `RerunCard` now in this tree, same name) |
| H50b | WP | `.alert(…, isPresented: replacementPromptBinding)` (3008) | the re-run card: Re-run here / Save as new project / Cancel | unchanged by B1/B2 |
| H50c | WP | `.onAppear` beside H45 (714) | `RerunCard.takeRunOnOpen(for:)` → `startRun()` | unchanged by B1/B2 |
| H50d | WP | `@State private var pendingReplacement: ResultsReplacementPrompt?` (496); `pendingReplacement = prompt` (1643) | `rerunOffersCopy` (Optimize re-run only) | unchanged by B1/B2 |
| H51 | HomeView.swift | the card's `contextMenu` (198) | the long-press "Duplicate" → `duplicateProject(id:)` | unchanged by B1/B2 |
| H52 | AppModel.swift | — (a new function; `duplicateProject` is absent here) | `duplicateProject(id:)` (ProjectDuplication) | unchanged by B1/B2 (no #354 anchor) |
| H53 | RootView.swift | `WorkspacePlaceholder(model: model, project: project)` (26) | `.id(project.id)` | unchanged by B1/B2 |

Named in the handoff only, with no `H<n>` comment in #362's shared files at `b472880b` (superseded, reverted, folded or never
built — the handoff says which): H1, H2, H2', H4', H5', H5'', H7', H9', H10', H11, H13, H16, H17, H18 (removed with H24), H18',
H19, H21, H25', H29', H35', H39', H42'.

**B1 moved or deleted no hook anchor** (0 of 49 rows): its WorkspacePlaceholder hunks are the wizard-cover state, the bake key's
`wallThickness`, the wall stress field, the slab regions and the bake's wall arguments; its MetalMeshView hunk is inside H40's
branch, not on H40's line.

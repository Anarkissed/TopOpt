// FlexibleRound7ScreenHookTests — round 7, the redesign's SCREEN (batch R7-D1: his pick 1, A2's capsule + A1's corner
// pair). The hooks it lays in #354's WorkspacePlaceholder, pinned by text: the reviewer's approved list (2026-10-14 19:45),
// condition (e): "pin tests (each hook once with its gate; removing a gate goes red)".
//
//   H24  the bottom-right chip column is not drawn on the Flexible stage (the Setup chip holds Quality, Plate up, Gravity
//        and Print parameters) — and H18's line is GONE (condition b: "H24 supersedes H18: remove H18's line in the same
//        commit")
//   H26  no Regions popover on the Flexible stage
//   H27  the capsule replaces the stage navigation on the Flexible stage; every other stage keeps it (the else branch)
//   H28  no Settings button on the Flexible stage (the capsule's Squish opens the same page)
//   H29  our own FlexibleStageChip branch of the identity row is deleted; #354's LatticeStageModeChip branch is untouched
//   H30  the corner pair inside #354's bottomBar on the Flexible stage; the four lines between its two added lines stay
//        byte-identical (H10 among them, exactly once)
//   H31  the full-screen Export step is not mounted on the Flexible stage
//   H33  the legend's chip column is 0 (our own H6 line, already owns-gated)
//   H34  the player's chip column is 0 (our own P line, already owns-gated)
//   H36  the Squish page's capsule closures (onLeave / onAbout) in our FlexibleStagePage mount; both H2 pins keep their text
//   H37  the Squish page never opens by itself (the first line of #354's openLatticeSettingsIfUnconfigured)
//   H38  choosing Flexible lands on the Lattice page (our own onChooseFlexible line)
//
// Each hook is checked ONCE at its anchor (the line before it, as the file has it), with its gate, and with today's
// statement in its else branch where it has one. RED CONTROL inside: a copy of the source with any one gate removed fails
// the check.
import XCTest
@testable import TopOptFlows

final class FlexibleRound7ScreenHookTests: XCTestCase {

    struct Hook {
        let id: String
        /// The hook's exact text (it carries its gate).
        let pin: String
        /// The gate inside `pin` (removed by the red control).
        let gate: String
        /// What the file has immediately before the hook (its anchor).
        let anchor: String
    }

    static let owns = "flexibleMain.owns(project, stage)"

    static let hooks: [Hook] = [
        Hook(id: "H24",
             pin: "                if force.gravityIsSet, !flexibleMain.owns(project, stage) { bottomRightControls }   // Flexible (PR #362) H24: ",
             gate: ", !flexibleMain.owns(project, stage)",
             anchor: "                // is no longer placed separately here.\n"),
        Hook(id: "H26",
             pin: "                if viewerMesh != nil, regionsOpen, !flexibleMain.owns(project, stage) { regionsPanelOverlay }   // Flexible (PR #362) H26: ",
             gate: ", !flexibleMain.owns(project, stage)",
             anchor: "                // disclosure mechanism in that panel (bar R12).\n"),
        Hook(id: "H27",
             // ★ RE-PINNED (the redesign P5; H60 / H61 approved in the overnight release ruling of 2026-10-26): the positive owns() gates carry `!editFaces.isEditing` (Flexible is off under Edit faces), and H27 / H36 hand Edit faces its closure; ★ and the redesign P4 (H62): H27 / H36 hand "Change lattice type…" its closure.
             pin: "                if viewerMesh != nil, flexibleMain.owns(project, stage), !editFaces.isEditing { FlexibleStageCapsule(main: flexibleMain, project: project, page: .lattice, go: { goToStage($0) }, squish: { showFlexiblePage = true }, about: { showLatticeModeSheet = true }, editFaces: { flexibleMain.editFacesOpens(); enterEditFaces(from: FlexibleEditFaces.origin(.lattice), onReturn: { if flexibleMain.editFacesReturns($0) { showFlexiblePage = true } }) }, changeType: { flexibleMain.askChangeType() }).latticeBandChipKeepOut().modifier(StageNavPlacement(stage: stage)) }   // Flexible (PR #362) H27: ",
             gate: ", flexibleMain.owns(project, stage)",
             anchor: "                // ★ §1b — the ONE button: it NAVIGATES between the two stages.\n"),
        Hook(id: "H28",
             pin: "                if viewerMesh != nil, !flexibleMain.owns(project, stage) { latticeSettingsButtonOverlay }   // Flexible (PR #362) H28: ",
             gate: ", !flexibleMain.owns(project, stage)",
             anchor: "                if viewerMesh != nil { latticeStageModeOverlay }\n"),
        Hook(id: "H30",
             pin: "            if flexibleMain.owns(project, stage), !editFaces.isEditing { FlexibleCornerPair(main: flexibleMain, project: project, app: model, openSquish: { showFlexiblePage = true }, changeGravity: { force.enterGravitySetup(); selection.clearActive(); gravityDraft = nil; gravitySnapLabel = nil }) } else {   // Flexible (PR #362) H30: ",
             gate: "flexibleMain.owns(project, stage)",
             anchor: "            Spacer()\n"),
        Hook(id: "H31",
             pin: "            if project.lattice.flexible != nil, !flexibleMain.owns(project, stage) { FlexibleExportMount(run: flexibleMain.coreRun).zIndex(48) }   // Flexible (PR #362) C2 + H31: ",
             gate: ", !flexibleMain.owns(project, stage)",
             anchor: "                    .transition(.opacity).zIndex(48)\n            }\n"),
        Hook(id: "H33",
             pin: "                if flexibleMain.owns(project, stage), !editFaces.isEditing { FlexibleMainLegends(main: flexibleMain, mode: $latticeLegendMode, projection: projection, settle: settleQuat, bottomClearance: bottomBarClearance, chipColumnWidth: 0) }   // Flexible (PR #362) H6",
             gate: "flexibleMain.owns(project, stage)",
             anchor: "                    latticeProbeCallout\n                }\n"),
        Hook(id: "H34",
             pin: "                if flexibleMain.owns(project, stage), !editFaces.isEditing { FlexibleMainPlayerSlot(main: flexibleMain, bottomClearance: bottomBarClearance, chipColumnWidth: 0) }   // Flexible (PR #362)",
             gate: "flexibleMain.owns(project, stage)",
             anchor: "                            bottomBarHeight = ok\n                        }\n                    }\n"),
        Hook(id: "H36",
             pin: "                                  onLeave: { goToStage($0) }, onAbout: { showLatticeModeSheet = true }, onEditFaces: { flexibleMain.editFacesOpens(); enterEditFaces(from: FlexibleEditFaces.origin(.squish), onReturn: { if flexibleMain.editFacesReturns($0) { showFlexiblePage = true } }) }, onChangeType: { flexibleMain.askChangeType() },   // Flexible (PR #362) H36: ",
             gate: "onLeave: { goToStage($0) }",
             anchor: "stampsPath: FlexibleResources.stampsPath, persist: { model.persistCurrentProject() }),\n"),
        Hook(id: "H37",
             pin: "        if project.lattice.flexible != nil { return }   // Flexible (PR #362) H37: ",
             gate: "project.lattice.flexible != nil",
             anchor: "    private func openLatticeSettingsIfUnconfigured() {\n"),
        Hook(id: "H38",
             pin: "                    showLatticeWizard = false   // Flexible (PR #362) H38: ",
             gate: "showLatticeWizard = false   //",
             // ★ RE-PINNED (round 7 · U21 batch A, his Img7 of 2026-10-21: "I don't think there should be any automatic squish/rest
             // selections whatsoever. Please remove them from *new* models coming in."): the line before is H38' (`.newSetup()`)
             anchor: "                    project.lattice.flexible = .newSetup()   // Flexible (PR #362) H38': a new setup reads nothing in from Topology (his Img7)\n"),
    ]

    /// Every rule the hooks must keep, on a copy of WorkspacePlaceholder's text. Empty = all pinned.
    static func failures(_ ws: String) -> [String] {
        var out: [String] = []
        for h in hooks {
            let n = ws.components(separatedBy: h.pin).count - 1
            if n != 1 { out.append("\(h.id): the hook appears \(n) times (must be exactly once): \(h.pin)"); continue }
            if !h.pin.contains(h.gate) { out.append("\(h.id): its gate '\(h.gate)' is not in it") }
            if !ws.contains(h.anchor + h.pin) { out.append("\(h.id): not at its anchor (the line before it moved): \(h.anchor)") }
        }
        // the else branches keep today's statements
        let elses: [(String, String)] = [
            // ★ RE-PINNED (the redesign P5, H60 approved in the overnight release ruling of 2026-10-26): the capsule takes Edit faces' closure; ★ P4 (H62): and Change lattice type's
            ("H27", "{ FlexibleStageCapsule(main: flexibleMain, project: project, page: .lattice, go: { goToStage($0) }, squish: { showFlexiblePage = true }, about: { showLatticeModeSheet = true }, editFaces: { flexibleMain.editFacesOpens(); enterEditFaces(from: FlexibleEditFaces.origin(.lattice), onReturn: { if flexibleMain.editFacesReturns($0) { showFlexiblePage = true } }) }, changeType: { flexibleMain.askChangeType() }).latticeBandChipKeepOut().modifier(StageNavPlacement(stage: stage)) }   // Flexible (PR #362) H27: "),
        ]
        for (id, head) in elses {
            guard let r = ws.range(of: head), let nl = ws[r.upperBound...].firstIndex(of: "\n") else { out.append("\(id): no line"); continue }
            let next = ws[ws.index(after: nl)...].prefix { $0 != "\n" }
            if next != "                else if viewerMesh != nil { stageNavigationButtonOverlay }" {
                out.append("\(id): the else branch is not today's `stageNavigationButtonOverlay` mount (\(next))")
            }
        }
        // H30: the four lines between its two added lines stay byte-identical and are not re-indented; H10 once
        // ★ RE-PINNED (sync of #354 at 89af86dd): #354's bottom bar is now a chain (B3 7e37c45f Topology's corner pair, B4 564db991 the
        // lattice split, B5 3f293974 the Edit faces gate); today's four lines are its last branch. H30's line stays exact at
        // `Spacer()` with that chain inside its else, and `H30 end` closes after the chain's own `}`. Anchor only.
        let h30 = hooks.first { $0.id == "H30" }!.pin
        // ★ H57 (2026-10-25): the chain sits inside AnyView(Group { … }) and topologyCornerPair is AnyView-wrapped (iPad stack overflow).
        let chain354 = "\n            AnyView(Group {   // Flexible (PR #362) H57: the bar's chain, type-erased (its nested type overflowed the iPad main thread's stack; crash 2026-10-25)"
            + "\n            // ★ B5: Edit faces keeps the bar the Surface stage had (today's four, the last branch).\n"
            + "            if !editFaces.isEditing, stage == .topology {\n"
            + "                // ★ B3 (A1): Topology's bar is the CORNER PAIR — the Setup chip (iPad | Mac, Print\n"
            + "                // parameters and the chip column, as rows) and the Optimize split button.\n"
            + "                AnyView(topologyCornerPair)   // Flexible (PR #362) H57\n"
            + "            } else if !editFaces.isEditing, stage == .lattice {\n"
            + "                // ★ B4: the lattice split — Lattice, and ⌃ for its steps (Preview → Core → Export)\n"
            + "                ComputeLocationControl(compute: compute)\n"
            + "                printParamsButton\n"
            + "                latticeSplit\n"
            + "            } else {"
        let between = chain354 + "\n            ComputeLocationControl(compute: compute)\n            printParamsButton\n"
            + "            // ★ LATTICE, TO THE LEFT OF OPTIMIZE (maintainer, 2026-08-17: \"Make\n"
            + "            // it exactly like Optimize button, but to the left of it\").\n"
            + "            if project.lattice.flexible == nil { latticeThisButton } else { FlexibleMainStatusPill(main: flexibleMain, open: { if stage != .lattice { goToStage(.lattice) }; showFlexiblePage = true }, goToLattice: { if stage != .lattice { goToStage(.lattice) } }) }   // Flexible (PR #362) H10: "
        if let r = ws.range(of: h30), let nl = ws[r.upperBound...].firstIndex(of: "\n") {
            if !ws[nl...].hasPrefix(between) { out.append("H30: the lines after its first line are not today's bar, unindented") }
            if let o = ws[nl...].range(of: "\n            optimizeButton\n            }\n            })   // Flexible (PR #362) H57\n            }   // Flexible (PR #362) H30 end\n") {
                if ws[nl..<o.lowerBound].contains("            }   // Flexible (PR #362) H30 end") { out.append("H30: its end comes before optimizeButton") }
            } else { out.append("H30: no `}   // Flexible (PR #362) H30 end` right after optimizeButton and the chain's `}`") }
        }
        if ws.components(separatedBy: "if project.lattice.flexible == nil { latticeThisButton } else { FlexibleMainStatusPill(").count - 1 != 1 {
            out.append("H10: must appear exactly once")
        }
        // H29: the Flexible branch is gone, #354's mode chip branch is byte-identical (pre-#362 shape)
        // ★ RE-PINNED (sync of #354 at 89af86dd): B4 564db991 deleted #354's own LatticeStageModeChip branch (the capsule names the
        // type now); the slot is #354's B4 note, byte for byte, with nothing of ours in it. Was: the chip branch.
        if ws.contains("FlexibleStageChip") { out.append("H29: WorkspacePlaceholder still names FlexibleStageChip") }
        let chip = "            // ★ B4: the type is named by the capsule (● Structural ⌄); its About row opens the mode sheet that\n"
            + "            // this chip opened, so the chip is gone from the row.\n"
            + "\n        }\n"
        if ws.components(separatedBy: chip).count - 1 != 1 { out.append("H29: #354's LatticeStageModeChip branch is not byte-identical") }
        // condition (b): H18's line removed with H24
        if ws.contains("FlexibleMainChips") || ws.contains("(PR #362) H18") { out.append("H18: its line is still in WorkspacePlaceholder (H24 supersedes it)") }
        // H36: both H2 pins keep their exact text
        for p in ["FlexibleStagePage(project: project, model: flexibleMain.model(for: project, materialsPath: FlexibleResources.materialsPath,",
                  "onExit: { showFlexiblePage = false; latticeSettingsSavedThisSession = true; flexibleMain.didExitSettings(solver: FlexibleStressSolver(app: model, sim: latticeSim)) })"]
        where ws.components(separatedBy: p).count - 1 != 1 { out.append("H36: the H2 pin moved: \(p)") }
        // H37: #354's own guard stays the next statement in the window FlexibleSurfaceNavTests reads (900 characters)
        if let o = ws.range(of: "private func openLatticeSettingsIfUnconfigured() {") {
            if !ws[o.upperBound...].prefix(900).contains("guard !latticeSettingsSavedThisSession, !showLatticeWizard else { return }") {
                out.append("H37: #354's guard left FlexibleSurfaceNavTests' 900-character window")
            }
        } else { out.append("H37: no openLatticeSettingsIfUnconfigured") }
        // nothing a #354 source guard counts
        if let b = ws.range(of: "public var body: some View {"), let e = ws.range(of: "\n    private var seeResultsChip"), b.upperBound < e.lowerBound,
           ws[b.upperBound..<e.lowerBound].contains("!showLatticePage") { out.append("body: '!showLatticePage' appeared") }
        if ws.components(separatedBy: "private var selectionsPanel").count - 1 != 1 { out.append("the selections panel's declaration string is not exactly once") }
        return out
    }

    func testEachHookIsOnceAtItsAnchorWithItsGateAndTodaysElse() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        let f = Self.failures(ws)
        XCTAssertEqual(f, [], f.joined(separator: "\n"))
        print("FLEX-R7D1-HOOKS \(Self.hooks.map(\.id).joined(separator: " ")) + H29 + H18 removed · failures \(f.count)")
    }

    /// ★ RED CONTROL (condition e): a copy of the source with any ONE gate removed fails the check.
    func testRemovingAnyGateTurnsThePinRed() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        try XCTSkipIf(!Self.failures(ws).isEmpty, "the hooks are not in yet (the red run)")
        for h in Self.hooks {
            let broken = ws.replacingOccurrences(of: h.pin, with: h.pin.replacingOccurrences(of: h.gate, with: ""))
            XCTAssertNotEqual(broken, ws, "\(h.id): the red control must change the source")
            XCTAssertFalse(Self.failures(broken).isEmpty, "★ \(h.id): without its gate the pin must go red")
        }
        // and H29 / H18 / H30's else: putting today's lines back is red too
        // ★ RE-PINNED (sync of #354 at 89af86dd): the branch goes back into B4 564db991's slot (#354's chip branch is gone)
        let withChip = ws.replacingOccurrences(of: "            // this chip opened, so the chip is gone from the row.\n\n        }\n",
            with: "            // this chip opened, so the chip is gone from the row.\n            if stage == .lattice, project.lattice.flexible != nil {\n                FlexibleStageChip { showLatticeModeSheet = true }\n                    .padding(.trailing, PageChrome.gizmoClearance + Self.settingsClearance)\n            }\n        }\n")
        XCTAssertNotEqual(withChip, ws, "the red control must change the source")
        XCTAssertFalse(Self.failures(withChip).isEmpty, "★ H29: the Flexible chip branch back is red")
        let withH18 = ws.replacingOccurrences(of: "SettingsChipID.allCases.filter { id in\n",
            with: "SettingsChipID.allCases.filter { id in\n            if flexibleMain.owns(project, stage), FlexibleMainChips.hidden.contains(id) { return false }   // Flexible (PR #362) H18: x\n")
        XCTAssertFalse(Self.failures(withH18).isEmpty, "★ condition (b): H18's line back is red")
    }

    /// The ONE gate every hook reads: the Flexible stage is the lattice stage of a Flexible project — nothing else.
    @MainActor func testTheGateIsTheFlexibleStageOnly() throws {
        let code = try FlexibleSource.code("FlexibleMainStage.swift")
        XCTAssertTrue(code.contains("public func owns(_ project: ProjectModel, _ stage: WorkspaceStage) -> Bool {\n        stage == .lattice && project.lattice.flexible != nil\n    }"))
        let main = FlexibleMainStage()
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        for s in [WorkspaceStage.topology, .lattice] { XCTAssertFalse(main.owns(p, s), "a project that is not Flexible: never") }
        p.lattice.stageMode = .structural
        XCTAssertFalse(main.owns(p, .lattice), "Structural: never")
        p.lattice.stageMode = nil
        p.lattice.flexible = FlexibleStageSettings()
        XCTAssertTrue(main.owns(p, .lattice))
        XCTAssertFalse(main.owns(p, .topology), "a Flexible project on Topology keeps today's screen")
        // ★ SYNC #354 (89af86dd) COMPILE FIX ONLY: B5 (3f293974) removed WorkspaceStage.surface (its `.surface` checks dropped; P5 owns this test)
    }

    /// H31 and H24 together: off the Flexible stage the Export step mounts for a Flexible project, and the chip column is
    /// #354's own filter with nothing of ours in it.
    func testOffTheFlexibleStageTodaysExportStepAndChipColumn() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let filter = try XCTUnwrap(ws.range(of: "SettingsChipID.allCases.filter { id in\n"))
        // ★ RE-PINNED (sync of #354 at 89af86dd): #354's own first statements now come before its switch (B3 7e37c45f's Topology
        // rule, B5 3f293974's Edit faces rule); nothing of ours is in the filter. Was: the switch first.
        let filter354 = "            // ★ B3: on Topology the chip column's settings are the Setup chip's rows. ★ B5: Paint lives in Edit faces —\n"
            + "            // there it is the column's one chip (greyed on STEP, `EditFacesPaint`), and on no stage outside it.\n"
            + "            if editFaces.isEditing { return id == .paint && viewerMesh != nil }\n"
            + "            if stage == .topology { return false }\n"
        // (this test reads FlexibleSource.code: comments cut at `//`, so #354's two comment lines are their indent)
        let filter354Code = filter354.split(separator: "\n", omittingEmptySubsequences: false)
            .map { l in l.range(of: "//").map { String(l[..<$0.lowerBound]) } ?? String(l) }.joined(separator: "\n")
        XCTAssertTrue(ws[filter.upperBound...].hasPrefix(filter354Code + "            switch id {"), "★ the chips' filter is #354's switch again (H18 gone)")
        XCTAssertTrue(ws.contains("case .cadFaces: return isStepPart"), "CAD surfaces: #354's rule, untouched")
    }
}

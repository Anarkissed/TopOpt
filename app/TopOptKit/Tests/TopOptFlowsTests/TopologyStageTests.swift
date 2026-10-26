import XCTest
import CryptoKit
import simd
import TopOptKit
@testable import TopOptFlows

/// B3 (the redesign's TOPOLOGY stage, his picks 2026-10-24): a RE-LAYOUT of existing function.
/// The job a Topology run sends must not move by one byte; what moved is where the controls sit.
@MainActor
final class TopologyStageTests: XCTestCase {

    // MARK: - fixtures (mirrors GravityDirectionTests)

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/settings/rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-topology-stage-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// The cube, opened, with one anchor, one 4.2 kg load and gravity set: a full Topology load case.
    private func loadedCube() throws -> (AppModel, ProjectModel, anchor: UUID, load: UUID) {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                         store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Bracket.stl"))
        m.continueToWorkspace()
        let p = try XCTUnwrap(m.project)
        let anchor = p.selection.addGroup()
        p.selection.pickFace(10)
        p.force.makeAnchor(anchor)
        let load = p.selection.addGroup()
        p.selection.pickFace(20)
        p.force.makeLoad(load)
        p.force.setWeight(load, kg: 4.2)
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        p.force.sync(groups: p.selection.groups)
        return (m, p, anchor, load)
    }

    /// The job's bytes, canonical: core reads a JSON object, and `JSONSerialization` writes a
    /// dictionary in hash order (per-process seeded), so the bytes are taken with sorted keys.
    private func canonicalJob(_ m: AppModel) throws -> Data {
        let req = try XCTUnwrap(m.makeRunRequest())
        let raw = try RemoteRun.buildJobJSON(req)
        let obj = try JSONSerialization.jsonObject(with: raw)
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// The cube's Topology job, taken at 3cbc6605 (before B3). A pure re-layout leaves it alone.
    static let jobAtB2 = "411647b780a8b7c3003201a05289697d19982738386e51b122b8f48da1ce4b13"

    func testTheTopologyJobIsByteIdenticalToB2() throws {
        let (m, _, _, _) = try loadedCube()
        let job = try canonicalJob(m)
        XCTAssertEqual(sha(job), Self.jobAtB2, "the Topology job moved: B3 is a re-layout and must send the same bytes")
    }

    // MARK: - T2: Results never opens by itself

    func testALandedRunDotsResultsAndNeverOpensIt() {
        var n = TopologyResultsNotice()
        n.note(accepted: 1, streaming: true, resultsOpen: false)
        XCTAssertTrue(n.dot)
        XCTAssertEqual(n.message, "1 variant ready \u{2014} more on the way.")
        n.note(accepted: 4, streaming: false, resultsOpen: false)
        n.noteFinished(accepted: 4, resultsOpen: false)
        XCTAssertEqual(n.message, "Optimization finished \u{2014} 4 variants.")
        n.dismiss()
        XCTAssertNil(n.message); XCTAssertTrue(n.dot, "the dot stays until Results is opened")
        n.opened()
        XCTAssertFalse(n.dot)
        // the page is the caller's: only his tap opens Results
        XCTAssertEqual(TopologyPage.current(resultsOpen: false, smoothing: false, hasResults: true), .setup)
        XCTAssertFalse(TopologyPage.enabled(.results, hasResults: false))
        XCTAssertFalse(TopologyPage.enabled(.smooth, hasResults: false))
        XCTAssertTrue(TopologyPage.enabled(.setup, hasResults: false))
        // a project reopened with results: no dot (nothing landed)
        var o = TopologyResultsNotice(); o.seed(accepted: 3); o.note(accepted: 3, streaming: false, resultsOpen: false)
        XCTAssertFalse(o.dot)
    }

    /// The workspace: Results starts shut and startRun no longer opens it (RED CONTROL: B2 had `viewOriginal = false` in
    /// startRun and `@State private var viewOriginal = false`).
    func testTheWorkspaceNeverOpensResultsOnARun() throws {
        let ws = try Self.workspaceSource()
        XCTAssertTrue(ws.contains("@State private var viewOriginal = true"))
        let start = try XCTUnwrap(ws.range(of: "private func startRun() {"))
        let body = String(ws[start.lowerBound...].prefix(3000))
        XCTAssertFalse(body.contains("viewOriginal = false"), "a run must not open Results")
        XCTAssertTrue(ws.contains("topoNotice.note(accepted: n, streaming: run.isStreaming, resultsOpen: !viewOriginal,"))
    }

    // MARK: - B1: the eye is view-only; the trash asks, then one Undo

    func testAHiddenGroupStillGoesInTheJob() throws {
        let (m, p, anchor, load) = try loadedCube()
        let before = try canonicalJob(m)
        p.groupView.toggleHidden(anchor)
        p.groupView.toggleHidden(load)
        XCTAssertTrue(p.groupView.isHidden(anchor))
        XCTAssertEqual(try canonicalJob(m), before, "the eye is a view: a hidden group is still anchored, still loaded")
        XCTAssertTrue(TopologySelectionsCopy.hiddenToast.contains("still counts in the run"))
    }

    func testTrashThenUndoRestoresTheGroupInOneStep() throws {
        let (m, p, anchor, load) = try loadedCube()
        p.sealUndoStep()
        let before = try canonicalJob(m)
        p.groupView.toggleHidden(load)
        // an edit made just before the trash, not yet settled (APP LIST 1: it must not ride the trash's Undo)
        p.selection.rename(anchor, to: "Wall mount")
        let t = try XCTUnwrap(p.trashGroup(load))
        XCTAssertFalse(p.selection.groups.contains { $0.id == load })
        XCTAssertFalse(p.groupView.isHidden(load), "its view state went with it")
        XCTAssertTrue(p.canUndoTrash(t))
        p.undoTrash(t)
        XCTAssertTrue(p.selection.groups.contains { $0.id == load }, "Undo puts the group back")
        XCTAssertTrue(p.groupView.isHidden(load), "…with its eye as it was")
        XCTAssertEqual(p.selection.groups.first { $0.id == anchor }?.name, "Wall mount",
                       "one step: the rename before the trash is NOT undone with it")
        XCTAssertEqual(try canonicalJob(m), before, "the restored group is in the job exactly as before")
        // a later edit retires the trash's Undo (it would undo that edit instead)
        let t2 = try XCTUnwrap(p.trashGroup(load))
        p.selection.rename(anchor, to: "Other")
        XCTAssertFalse(p.canUndoTrash(t2))
        XCTAssertEqual(TopologySelectionsCopy.deleteAsk("Top load"), "Delete Top load from every stage?")
    }

    func testTheFaceChipJoinsAPendingFaceToTheGroup() throws {
        let (_, p, anchor, _) = try loadedCube()
        let pending = p.selection.addGroup()
        p.selection.pickFace(30)
        XCTAssertEqual(p.joinTarget(excluding: pending)?.name, p.selection.groups.last { $0.id != pending }?.name)
        p.joinPending(pending, into: anchor)
        XCTAssertFalse(p.selection.groups.contains { $0.id == pending })
        XCTAssertTrue(p.selection.groups.first { $0.id == anchor }?.faces.contains(30) == true)
    }

    // MARK: - the re-run card

    func testTheRerunCardOffersThreeChoices() throws {
        XCTAssertEqual(TopologyRerunChoice.choices(offersCopy: true).map(\.label),
                       ["Re-run here", "Save as new project", "Cancel"])
        XCTAssertEqual(TopologyRerunChoice.choices(offersCopy: false).map(\.label), ["Re-run here", "Cancel"])
        let ws = try Self.workspaceSource()
        let card = try XCTUnwrap(ws.range(of: ".alert(RerunCard.title, isPresented: replacementPromptBinding) {"))
        let body = String(ws[card.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("startRun()"), "Re-run here runs here")
        XCTAssertTrue(body.contains("saveAsNewProjectAndRun()"), "Save as new project copies, then runs in the copy")
        XCTAssertTrue(body.contains("TopologyRerunChoice.cancel.label, role: .cancel"))
        XCTAssertFalse(ws.contains("\"Replace your results?\""), "the old two-button alert is gone")
    }

    func testSaveAsNewProjectCopiesTheSetupWithoutResults() throws {
        let (m, p, _, _) = try loadedCube()
        m.persistCurrentProject()
        let copy = try XCTUnwrap(m.duplicateProject(id: p.id))
        XCTAssertNotEqual(copy.id, p.id)
        XCTAssertEqual(copy.name, ProjectDuplication.copyName(of: p.name, existing: [p.name]))
        XCTAssertFalse(copy.optimized)
    }

    // MARK: - S3 amended: no Surface button; ✂ and the ● menu reach Edit faces

    func testTopologyHasNoSurfaceButtonAndTheMenuReachesEditFaces() throws {
        XCTAssertFalse(WorkspaceStage.topology.drawsForwardButtons, "Topology draws no stage buttons")
        XCTAssertFalse(WorkspaceStage.lattice.drawsForwardButtons, "B4: the lattice stage's capsule carries them")
        let gate = LatticeEntryButtonGate.compute(gravitySet: true, anchors: 1, loads: 1)
        let rows = TopologyStageMenu.rows(typeInUse: nil, latticeGate: gate)
        XCTAssertEqual(rows.map(\.title), ["Topology", "Lattice\u{2026}", "Edit faces\u{2026}"])
        XCTAssertEqual(TopologyStageMenu.rows(typeInUse: .aesthetic, latticeGate: gate)[1].title, "Aesthetic",
                       "the ONE lattice type in use")
        XCTAssertNil(TopologyStageMenu.stage(for: .editFaces), "B5: Edit faces is a mode, not a stage")
        let closed = TopologyStageMenu.rows(typeInUse: nil, latticeGate: .compute(gravitySet: false, anchors: 0, loads: 0))
        XCTAssertFalse(closed[1].enabled, "the lattice row is gated as the Lattice button was")
        let ws = try Self.workspaceSource()
        XCTAssertFalse(ws.contains("ForEach(stage.drawsForwardButtons ? stage.forward : [], id: \\.rawValue)"),
                       "B5: the forward column of stage buttons is gone with the Surface stage")
        XCTAssertTrue(ws.contains("editFaces: { openEditFaces() },"), "the capsule's ✂ opens Edit faces")
        // the capsule's menu row and the ✂ both take the same action
        var went: [WorkspaceStage] = []; var edited = 0
        StageCapsule.perform(.editFaces, fold: nil, go: { went.append($0) }, about: {}, editFaces: { edited += 1 })
        XCTAssertEqual(edited, 1); XCTAssertTrue(went.isEmpty)
        StageCapsule.perform(.lattice, fold: nil, go: { went.append($0) }, about: {})
        XCTAssertEqual(went, [.lattice])
        // greyed pages do nothing
        var tapped = 0
        StageCapsule.tapSegment(.secondary, on: .primary, fold: nil, primary: {}, secondary: { tapped += 1 },
                                greyed: [.secondary, .tertiary])
        XCTAssertEqual(tapped, 0)
    }

    // MARK: - the growth ladder's words

    func testTheGrowthModeSaysItRedesignsThePart() {
        XCTAssertEqual(LadderMode.growth.title, "Redesign to strengthen")
        XCTAssertFalse(LadderMode.growth.title.hasPrefix("Add"), "it is not add-only: it removed 7.6–14.8 % of his part")
        XCTAssertTrue(LadderMode.growth.oneLine.contains("whole part"))
        XCTAssertTrue(LadderMode.growth.oneLine.contains("remove"))
        XCTAssertEqual(LadderMode.reduction.title, "Minimize plastic", "Minimize plastic's words do not move")
    }

    // MARK: - the Setup chip's rows

    func testTheSetupChipCarriesTheChipColumnAndTheBar() {
        XCTAssertEqual(TopologySetupRow.visible(protectCount: 0, isStep: false, designBoxDrawn: true).map(\.title),
                       ["Quality", "Plate", "Gravity", "Runs on", "Units", "Plastic", "Design primitives", "Print parameters"])
        XCTAssertTrue(TopologySetupRow.visible(protectCount: 1, isStep: true, designBoxDrawn: true).contains(.protectSkin))
        XCTAssertTrue(TopologySetupRow.visible(protectCount: 1, isStep: true, designBoxDrawn: true).contains(.cadFaces))
    }

    static func workspaceSource() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift"),
                   encoding: .utf8)
    }
}

/// ★ His iPad (2026-10-26, problem 6): the bottom-left hint covered the collapsed Selections pill. With Selections collapsed
/// the hint never shows, whatever hint the stage would show; expanded, it shows as before.
@MainActor
final class SelectionsPillNeverCoveredTests: XCTestCase {
    func testTheHintNeverShowsOverTheCollapsedPill() throws {
        for showsHint in [true, false] {
            XCTAssertFalse(WorkspacePlaceholder.hintShows(showsSelectionHint: showsHint, selectionsCollapsed: true),
                           "★ collapsed: no hint over the pill")
        }
        XCTAssertTrue(WorkspacePlaceholder.hintShows(showsSelectionHint: true, selectionsCollapsed: false), "expanded: as before")
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let src = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("if Self.hintShows(showsSelectionHint: visible.showsSelectionHint, selectionsCollapsed: selectionsCollapsed) {"),
                      "the bar's one hint goes through the rule")
    }
}

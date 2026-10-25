import XCTest
import CryptoKit
import simd
import TopOptKit
@testable import TopOptFlows

/// B4 (the redesign's LATTICE stages, his picks 2026-10-24: L1 amended, one lattice type per project).
/// A RE-LAYOUT of existing function: the stage's lattice job and a variant's re-lattice job must not move by one byte.
@MainActor
final class LatticeStageTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-lattice-stage-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// The cube, opened, latticed under Structural: an include wall through a protected group (as
    /// LatticeRunSpecSharedTests' stage request), an anchor, a 4.2 kg load and gravity.
    private func latticedCube() throws -> (AppModel, ProjectModel, include: UUID, load: UUID) {
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                         rulesPath: Self.core("src/settings/rules.json"),
                         store: ProjectStore(rootDir: tempDir),
                         presetStore: PrintParamsPresetStore(rootDir: tempDir))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.core("tests/fixtures/stl/cube_10mm.stl"), displayName: "Cube.stl"))
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
        let gid = p.selection.addGroup()
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        _ = p.force.addManualPrimitive(.defaultBolt(at: SIMD3(5, 5, 5), radiusMM: 2, halfLengthMM: 3), to: gid)
        p.lattice.enabled = true
        p.lattice.densityMode = .sim
        p.lattice.stageMode = .structural
        p.lattice.groupRoles[gid] = .include
        return (m, p, gid, load)
    }

    private func stageLatticeJob(_ m: AppModel) throws -> Data {
        let req = try XCTUnwrap(m.makeLatticeRunRequest())
        let obj = try JSONSerialization.jsonObject(with: try RemoteRun.buildJobJSON(req))
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private func variantJobs() throws -> [String: String] {
        let (p, _, _) = VariantFacePrismFixture.project()
        p.lattice.stageMode = .structural
        var out: [String: String] = [:]
        for (label, doc) in try VariantFacePrismFixture.variantDocuments(p) {
            let obj = try JSONSerialization.jsonObject(with: doc)
            out[label] = sha(try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
        }
        return out
    }

    // MARK: - the job bytes (a pure re-layout)

    /// Taken at 7e37c45f (B3, before B4) with SWIFT_DETERMINISTIC_HASHING=1.
    static let stageLatticeJobAtB3 = "b39c15601235cfee723b7713b665e2e03b6aeacec0d8714352d63bc0e7604cce"
    static let variantRunJobAtB3 = "dda8f4c1ce16e8dc94c8ff4d37ee964aea910bf79c23baaa6b093af2535770a5"
    static let variantForecastJobAtB3 = "222dad739d1223cdb82e4ab20a28df513df3514c72ea911a32ad3a11655c093a"

    func testTheStageLatticeJobIsByteIdenticalToB3() throws {
        let (m, _, _, _) = try latticedCube()
        let a = sha(try stageLatticeJob(m))
        let (m2, _, _, _) = try latticedCube()
        XCTAssertEqual(sha(try stageLatticeJob(m2)), a, "control: two builds give one byte string")
        print("PIN stage \(a)")
        XCTAssertEqual(a, Self.stageLatticeJobAtB3, "the stage's lattice job moved: B4 is a re-layout")
    }

    func testTheVariantRelatticeJobIsByteIdenticalToB3() throws {
        let v = try variantJobs()
        XCTAssertEqual(try variantJobs(), v, "control: two builds give one byte string")
        print("PIN variant run \(v["run"] ?? "-") forecast \(v["forecast"] ?? "-")")
        XCTAssertEqual(v["run"], Self.variantRunJobAtB3, "the re-lattice job moved")
        XCTAssertEqual(v["forecast"], Self.variantForecastJobAtB3, "the forecast job moved")
    }

    // MARK: - sources

    private static func src(_ file: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/\(file)"), encoding: .utf8)
    }
    private static func member(_ text: String, _ signature: String, _ n: Int = 1400) throws -> String {
        let r = try XCTUnwrap(text.range(of: signature), "missing: \(signature)")
        return String(text[r.lowerBound...].prefix(n))
    }

    // MARK: - L1 amended: one type, a selector on first entry

    /// RED CONTROL: at B3 there was no selector type and the modal said the choice "cannot be changed afterwards".
    func testTheSelectorShowsOnFirstEntryOnly() throws {
        XCTAssertTrue(LatticeTypeSelector.isShown(onLatticeStage: true, typeInUse: nil), "first entry: the selector")
        XCTAssertFalse(LatticeTypeSelector.isShown(onLatticeStage: true, typeInUse: .structural), "after a pick: never again")
        XCTAssertFalse(LatticeTypeSelector.isShown(onLatticeStage: false, typeInUse: nil), "only on the Lattice stage")
        XCTAssertEqual(LatticeTypeChoice.offered(flexibleStageBuilt: false).map(\.title), ["Structural", "Aesthetic"],
                       "this tree has no Flexible stage (#362 adds its card)")
        XCTAssertEqual(LatticeTypeChoice.offered(flexibleStageBuilt: true).map(\.title), ["Structural", "Aesthetic", "Flexible"])
        XCTAssertNil(LatticeTypeChoice.flexible.mode, "Flexible records no grading intent")
        let ws = try Self.src("WorkspacePlaceholder.swift")
        XCTAssertTrue(try Self.member(ws, "private var latticeStageModeNeeded: Bool {", 400)
            .contains("LatticeTypeSelector.isShown(onLatticeStage: stage == .lattice || showLatticePage"))
        let modal = try Self.src("LatticeStageModeModal.swift")
        XCTAssertTrue(modal.contains("Text(LatticeTypeSelector.oneTypeLine)"))
        XCTAssertFalse(modal.contains("This is set once for the Lattice stage"), "the old line is gone")
        XCTAssertTrue(LatticeTypeSelector.oneTypeLine.contains("Change lattice type"))
    }

    /// The ● menu names the ONE type in use, never two; the capsule draws it.
    func testTheMenuNamesOneType() throws {
        let s = LatticeStageMenu.rows(typeInUse: .structural, anchors: 1, loads: 1)
        XCTAssertEqual(s.map(\.title), ["\u{2039} Topology", "Structural", "Change lattice type\u{2026}", "Edit faces\u{2026}",
                                        "About Structural\u{2026}"])
        XCTAssertFalse(s.contains { $0.title.contains("Aesthetic") }, "never a second type")
        XCTAssertEqual(LatticeStageMenu.rows(typeInUse: .aesthetic, anchors: 0, loads: 0)[1].title, "Aesthetic")
        let none = LatticeStageMenu.rows(typeInUse: nil, anchors: 0, loads: 0).map(\.title)
        XCTAssertEqual(none, ["\u{2039} Topology", "Lattice\u{2026}", "Edit faces\u{2026}"], "no type yet: nothing to change")
        XCTAssertEqual(LatticeStageMenu.title(typeInUse: .structural), "Structural")
        XCTAssertEqual(LatticeStageMenu.capsuleAction(.changeType), .changeType)
        var asked = 0
        StageCapsule.perform(.changeType, fold: nil, go: { _ in XCTFail("not a stage change") }, about: {},
                             changeType: { asked += 1 })
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(LatticeStagePage.allCases.map(\.title), ["Regions", "Cells"])
        XCTAssertEqual(LatticeStagePage.current(cellsUp: true), .cells)
        XCTAssertFalse(WorkspaceStage.lattice.drawsForwardButtons, "the capsule carries the stage buttons")
        let ws = try Self.src("WorkspacePlaceholder.swift")
        let nav = try Self.member(ws, "@ViewBuilder private var stageNavigationButtonOverlay: some View {", 1300)
        XCTAssertTrue(nav.contains("} else if stage == .lattice {") && nav.contains("latticeCapsuleOverlay"))
        let cap = try Self.member(ws, "@ViewBuilder var latticeCapsuleOverlay: some View {", 2200)
        XCTAssertTrue(cap.contains("title: LatticeStageMenu.title(typeInUse: mode)"))
        XCTAssertTrue(cap.contains("changeType: { showChangeLatticeType = true }"))
        XCTAssertTrue(cap.contains("editFaces: { openEditFaces() }"), "✂ and the menu reach Edit faces (B5: the mode closes Cells)")
        XCTAssertFalse(ws.contains("LatticeStageModeChip(mode: mode) { showLatticeModeSheet = true }"),
                       "the identity row's type chip is gone: the capsule names it")
        XCTAssertEqual(LatticeStageCopy.builtOn(achievedVolumeFraction: nil), "on the part")
        XCTAssertEqual(LatticeStageCopy.builtOn(achievedVolumeFraction: 0.65), "on \u{2212}35 %")
        XCTAssertEqual(LatticeStageCopy.builtOn(achievedVolumeFraction: 1.2), "on +20 %")
    }

    // MARK: - "Change lattice type…": three ways

    func testChangeLatticeTypeOffersThreeWays() throws {
        XCTAssertEqual(ChangeLatticeTypeChoice.allCases.map(\.label),
                       ["Create a duplicate and choose a type", "Continue and lose all work", "Cancel"])
        XCTAssertTrue(ChangeLatticeTypeChoice.duplicate.detail(was: "Structural")?.hasPrefix("Recommended") == true)
        let ws = try Self.src("WorkspacePlaceholder.swift")
        let choose = try Self.member(ws, "func chooseLatticeTypeChange(_ c: ChangeLatticeTypeChoice) {", 800)
        XCTAssertTrue(choose.contains("model.duplicateAndChooseLatticeType(id: project.id)"))
        XCTAssertTrue(choose.contains("deleteLatticeForMode()"))
        XCTAssertTrue(choose.contains("case .cancel:\n            break"), "Cancel changes nothing")
    }

    func testTheDuplicateCarriesEverythingAndOpensTheSelector() throws {
        let (m, p, include, _) = try latticedCube()
        p.lattice.cellMM = 7.5
        p.lattice.selectableExpandMM["probe"] = 1.25
        m.persistCurrentProject()
        let groups = p.selection.groups.map(\.name)
        let roles = p.lattice.groupRoles
        let original = p.id
        let copy = try XCTUnwrap(m.duplicateAndChooseLatticeType(id: original))
        XCTAssertNotEqual(copy.id, original)
        let c = try XCTUnwrap(m.project)
        XCTAssertEqual(c.id, copy.id, "the copy is open")
        XCTAssertNil(c.lattice.stageMode, "…with no type, so its selector asks")
        XCTAssertEqual(c.selection.groups.map(\.name), groups, "groups carried over")
        XCTAssertEqual(c.lattice.groupRoles, roles, "regions (the lattice roles) carried over")
        XCTAssertEqual(c.lattice.groupRoles[include], .include)
        XCTAssertEqual(c.lattice.cellMM, 7.5, "settings carried over")
        XCTAssertEqual(c.lattice.selectableExpandMM["probe"], 1.25)
        XCTAssertTrue(c.lattice.enabled)
        XCTAssertEqual(LatticeStageOpen.take(for: copy.id), "", "the copy opens on the Lattice stage")
        XCTAssertNil(LatticeStageOpen.take(for: copy.id), "once")
        // the original keeps its type
        m.open(try XCTUnwrap(m.recentProjects.first { $0.id == original }))
        XCTAssertEqual(m.project?.lattice.stageMode, .structural, "the original keeps its Structural lattice")
    }

    func testLoseAllClearsTheLatticeAndKeepsTopology() throws {
        let (m, p, _, load) = try latticedCube()
        p.lattice.cellMM = 7.5
        p.clearLatticeWork()
        XCTAssertEqual(p.lattice, LatticeSettings(), "every lattice setting goes")
        XCTAssertNil(p.lattice.stageMode, "…so the selector asks again")
        XCTAssertTrue(p.selection.groups.contains { $0.id == load }, "Topology's groups stay")
        XCTAssertNotNil(m.makeRunRequest(), "and Topology still runs")
        let ws = try Self.src("WorkspacePlaceholder.swift")
        XCTAssertTrue(try Self.member(ws, "private func deleteLatticeForMode()", 600)
            .contains("clearedLattice = project.clearLatticeWork()"))
        XCTAssertTrue(ws.contains("project.undoClearLattice(c); clearedLattice = nil"), "its Undo is on screen")
    }

    /// ★ "Continue and lose all work" is ONE undo step, as every delete (reviewer 08:56): one Undo restores the lattice work,
    /// and an edit made just before it does not ride along. RED CONTROL: at B3 the reset returned nothing to undo with.
    func testLoseAllUndoesInOneStep() throws {
        let (m, p, include, load) = try latticedCube()
        p.lattice.cellMM = 7.5
        p.sealUndoStep()
        let lattice = p.lattice
        XCTAssertNotNil(m.makeLatticeRunRequest())
        p.selection.rename(load, to: "Top load")   // just before, unsettled: it must not be undone with the reset
        let c = p.clearLatticeWork()
        XCTAssertEqual(c.type, "Structural")
        XCTAssertNil(p.lattice.stageMode)
        XCTAssertTrue(p.canUndoClearLattice(c))
        p.undoClearLattice(c)
        XCTAssertEqual(p.lattice, lattice, "★ one Undo restores the lattice work")
        XCTAssertEqual(p.lattice.groupRoles[include], .include)
        XCTAssertEqual(p.selection.groups.first { $0.id == load }?.name, "Top load", "one step: the rename stays")
        // a later edit retires the Undo
        let c2 = p.clearLatticeWork()
        p.selection.rename(load, to: "Other")
        XCTAssertFalse(p.canUndoClearLattice(c2))
        XCTAssertTrue(ChangeLatticeTypeChoice.loseAll.detail(was: "Structural")?.contains("Undo") == true)
    }

    /// ★ The selector's pick goes through the ONE "type" place (reviewer 08:45): any other type is cleared, so a project
    /// that was Flexible cannot stay claimed by Flexible. This tree has no `flexible` field (it is #362's; its key is not
    /// read here, as today); the pin is the saved bytes: after a Structural pick no "flexible" key survives. #362's merge
    /// must keep this green by clearing `flexible` in `clearLatticeType()`.
    func testPickingStructuralOrAestheticClearsAnyOtherType() throws {
        var s = LatticeSettings()
        let withFlex = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(s)) as? [String: Any] ?? [:]
        var obj = withFlex; obj["flexible"] = ["setup": 1]
        s = try JSONDecoder().decode(LatticeSettings.self, from: try JSONSerialization.data(withJSONObject: obj))
        s.chooseLatticeType(.aesthetic)
        XCTAssertEqual(s.stageMode, .aesthetic)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(s)) as? [String: Any])
        XCTAssertNil(saved["flexible"], "★ no Flexible claim survives a Structural / Aesthetic pick")
        var t = s; t.clearLatticeType()
        XCTAssertNil(t.stageMode, "a pending type: the selector asks")
        let ws = try Self.src("WorkspacePlaceholder.swift")
        XCTAssertTrue(try Self.member(ws, "LatticeStageModeModal { mode in", 300).contains("project.lattice.chooseLatticeType(mode)"))
        let dup = try Self.member(try Self.src("LatticeStage.swift"), "public func duplicateAndChooseLatticeType(id: UUID)", 500)
        XCTAssertTrue(dup.contains("project?.lattice.clearLatticeType()"), "the copy's type pending, through the same place")
    }

    // MARK: - the Regions page: one list, trash from every stage, one Undo

    func testTrashOnTheLatticePagesDeletesEverywhereAndUndoes() throws {
        let (m, p, include, load) = try latticedCube()
        p.sealUndoStep()
        let before = try stageLatticeJob(m)
        for gid in [include, load] {   // a lattice region and a Topology group, both on the Regions list
            let t = try XCTUnwrap(p.trashGroup(gid))
            XCTAssertFalse(p.selection.groups.contains { $0.id == gid }, "gone from the ONE selection every stage reads")
            let gone = m.makeLatticeRunRequest().flatMap { try? RemoteRun.buildJobJSON($0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            XCTAssertNotEqual(gone, before, "control: the delete reached the job")
            XCTAssertTrue(p.canUndoTrash(t))
            p.undoTrash(t)
            XCTAssertTrue(p.selection.groups.contains { $0.id == gid }, "one Undo puts it back")
            XCTAssertEqual(try stageLatticeJob(m), before, "…exactly")
        }
        XCTAssertEqual(TopologySelectionsCopy.deleteAsk("Top load"), "Delete Top load from every stage?")
        let ws = try Self.src("WorkspacePlaceholder.swift")
        let list = try Self.member(ws, "var latticeSelectionsList: some View {", 3600)
        XCTAssertTrue(list.contains("ask: TopologySelectionsCopy.deleteAsk"), "the trash asks \"from every stage\"")
        XCTAssertTrue(list.contains("confirmDelete: { confirmTopologyTrash() }"), "…and deletes through trashGroup")
        XCTAssertTrue(list.contains("project.undoTrash(t)"), "one Undo")
        XCTAssertTrue(list.contains("toggleEye: { toggleTopologyEye($0) }"), "the eye, view only")
        XCTAssertTrue(list.contains("rows: { g in AnyView(groupRow(g, inList: true)) }"), "today's depth and expand boxes")
        XCTAssertTrue(ws.contains("else if stage == .lattice, !showLatticePage { latticeSelectionsList }"))
    }

    // MARK: - the Cells page

    func testGradeAlongKeepsThreeValuesAndOnlyByStressIsSent() throws {
        // ★ ruling 2026-10-24 17:46: no notice for what core can't do yet — the preview draws it, core hears via the CORE LIST
        for f in ["LatticeStage.swift", "LatticeSetupWizard.swift", "WorkspacePlaceholder.swift"] {
            XCTAssertFalse(try Self.src(f).contains("Saved, not sent"), "\(f): no Along notice")
        }
        XCTAssertEqual(LatticeGradeAlong.allCases.map { $0.title(.structural) },
                       ["Through the depth", "Across the face", "By stress"])
        XCTAssertEqual(LatticeGradeAlong.load.title(.aesthetic), "Along the load")
        var s = LatticeSettings()
        s.densityMode = .uniform
        s.simulateStresses = true
        var w = LatticeWizardModel(settings: s)
        XCTAssertNil(LatticeGradeAlong.lit(stored: w.gradeAlong, densityMode: w.densityMode), "uniform: none lit")
        XCTAssertTrue(w.chooseAlong(.load))
        XCTAssertEqual(w.densityMode, .sim, "By stress IS today's simulated density")
        XCTAssertEqual(LatticeGradeAlong.lit(stored: w.gradeAlong, densityMode: w.densityMode), .load)
        XCTAssertTrue(w.chooseAlong(.depth))
        XCTAssertEqual(w.densityMode, .sim, "a drawn pick moves nothing core reads")
        XCTAssertEqual(LatticeGradeAlong.lit(stored: w.gradeAlong, densityMode: w.densityMode), .depth)
        var off = LatticeWizardModel(settings: s)
        off.simulateStresses = false
        XCTAssertFalse(off.chooseAlong(.load), "no simulation: By stress is refused, as Sim is")
        XCTAssertEqual(w.applied(to: s).gradeAlong, .depth, "saved")
        // the job does not move for either drawn pick (the B4 pin); the preview re-bakes to draw it
        let (m, p, _, _) = try latticedCube()
        let bake = p.lattice.previewBakeInputs
        p.lattice.gradeAlong = .depth
        XCTAssertEqual(sha(try stageLatticeJob(m)), Self.stageLatticeJobAtB3, "Through the depth is not sent")
        p.lattice.gradeAlong = .face
        XCTAssertEqual(sha(try stageLatticeJob(m)), Self.stageLatticeJobAtB3, "Across the face is not sent")
        XCTAssertNotEqual(p.lattice.previewBakeInputs, bake, "…but the preview re-bakes to draw it")
        // it survives a save, and an unknown value never fails the project
        let enc = try JSONEncoder().encode(p.lattice)
        XCTAssertEqual(try JSONDecoder().decode(LatticeSettings.self, from: enc).gradeAlong, .face)
        let bad = Data(String(decoding: enc, as: UTF8.self).replacingOccurrences(of: "\"gradeAlong\":\"face\"",
                                                                              with: "\"gradeAlong\":\"zzz\"").utf8)
        XCTAssertNil(try JSONDecoder().decode(LatticeSettings.self, from: bad).gradeAlong)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(LatticeSettings()), as: UTF8.self).contains("gradeAlong"),
                       "an untouched project writes no new key")
    }

    func testTheCellsPageRowsAndItsOneWayIn() throws {
        XCTAssertEqual(LatticeCellsRow.rows(.structural), [.grade, .along, .strength])
        XCTAssertEqual(LatticeCellsRow.rows(.aesthetic), [.grade, .along, .ties, .overhangs])
        // the Grade pair is today's density band; reading and writing it back is the identity
        var s = LatticeSettings(); s.minRelativeDensity = 0.12; s.maxRelativeDensity = 0.30
        let back = LatticeWizardModel(settings: s).applied(to: s)
        XCTAssertEqual(back.minRelativeDensity, 0.12, "the band's low end goes back as read")
        XCTAssertEqual(back.maxRelativeDensity, 0.30)
        let ws = try Self.src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains(".cellsPage(regions: latticeRegionTabNames, closeToken: cellsCloseToken)"))
        XCTAssertTrue(ws.contains("static let latticeSettingsButtonDrawn = false"), "no second way in: the Settings button goes")
        let wiz = try Self.src("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains(".onChange(of: cellsPage?.closeToken) { _ in saveAndClose() }"), "Regions leaves through Save")
        XCTAssertTrue(wiz.contains("if cellsPage != nil, model.stage == .lattice { cellsAddedRows }"))
    }

    // MARK: - APP LIST 6: the lattice re-run card; Results never opens by itself

    /// RED CONTROL: at B3 the lattice run's prompt set `pendingReplacement`, whose card's first button is `startRun()`.
    func testTheLatticeRerunCardNeverCallsStartRun() throws {
        XCTAssertEqual(LatticeRerunChoice.title, "Re-running clears this lattice\u{2019}s results")
        XCTAssertEqual(LatticeRerunChoice.allCases.map(\.label), ["Re-run the lattice here", "Save as new project", "Cancel"])
        let ws = try Self.src("WorkspacePlaceholder.swift")
        let card = try Self.member(ws, ".alert(LatticeRerunChoice.title, isPresented: latticeRerunBinding) {", 700)
        XCTAssertTrue(card.contains("startLatticeRequest()"), "its first button starts the lattice request")
        XCTAssertFalse(card.contains("startRun()"), "★ never Topology's run")
        XCTAssertTrue(card.contains("saveAsNewProjectForLattice()"))
        let req = try Self.member(ws, "private func requestLatticeRun() {", 900)
        XCTAssertTrue(req.contains("pendingLatticeRerun = prompt"))
        XCTAssertFalse(req.contains("pendingReplacement"), "not the Optimize card")
        XCTAssertFalse(req.contains("startRun()"))
        let start = try Self.member(ws, "private func startLatticeRequest() {", 400)
        XCTAssertTrue(start.contains("model.makeLatticeRunRequest()") && start.contains("run.start(request)"))
        XCTAssertFalse(start.contains("startRun()"))
        XCTAssertTrue(try Self.member(ws, "func saveAsNewProjectForLattice() {", 300)
            .contains("model.saveAsNewProjectForLattice(id: project.id)"))
        let model = try Self.member(try Self.src("LatticeStage.swift"), "public func saveAsNewProjectForLattice(id: UUID)", 400)
        XCTAssertFalse(model.contains("RerunCard.runOnOpen"), "★ the copy runs nothing on open")
    }

    /// The lattice card's Save as new project: a COPY (setup only, his rule) that runs NOTHING.
    func testTheLatticeCardsSaveAsNewMakesACopyAndRunsNothing() throws {
        let (m, p, include, _) = try latticedCube()
        m.persistCurrentProject()
        let original = p.id
        let copy = try XCTUnwrap(m.saveAsNewProjectForLattice(id: original))
        XCTAssertNotEqual(copy.id, original)
        XCTAssertFalse(copy.optimized, "setup only — never results")
        let c = try XCTUnwrap(m.project)
        XCTAssertEqual(c.id, copy.id, "the copy is open")
        XCTAssertEqual(c.lattice.groupRoles[include], .include, "…with the setup")
        XCTAssertEqual(c.lattice.stageMode, .structural, "…and its type (no selector: nothing to choose)")
        XCTAssertFalse(c.run.phase.isRunning, "★ it runs nothing")
        XCTAssertFalse(m.runningIDs.contains(copy.id))
        XCTAssertFalse(RerunCard.takeRunOnOpen(for: copy.id), "★ no Optimize waits for its open")
        XCTAssertEqual(LatticeStageOpen.take(for: copy.id), LatticeRerunChoice.copyOpenToast, "it opens on Lattice and says so")
    }

    /// RED CONTROL: at B3 `startRelatticeRun` set `viewOriginal = false` (the variant's re-lattice opened Results).
    func testResultsNeverOpensByItselfFromTheLatticeStage() throws {
        let ws = try Self.src("WorkspacePlaceholder.swift")
        let relattice = try Self.member(ws, "private func startRelatticeRun() {", 6000)
        let end = relattice.range(of: "\n    private var latticePageOverlay").map { String(relattice[..<$0.lowerBound]) } ?? relattice
        XCTAssertFalse(end.contains("viewOriginal = false"), "★ a re-lattice never opens Results")
        XCTAssertFalse(try Self.member(ws, "private func requestLatticeRun() {", 900).contains("viewOriginal"))
        XCTAssertFalse(try Self.member(ws, "private func startLatticeRequest() {", 400).contains("viewOriginal"))
    }

    // MARK: - APP LIST 2: the Expand keypad's "+"

    func testTheExpandKeypadShowsThePlus() throws {
        XCTAssertEqual(NumberPad.Config.expandSymbol, "plus")
        XCTAssertNotEqual(NumberPad.Config(title: "Expand", titleSymbol: "plus"), NumberPad.Config(title: "Expand"))
        XCTAssertNil(NumberPad.Config(title: "Depth").titleSymbol, "every other keypad as before")
        let ws = try Self.src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("titleSymbol: row.kind == .expand ? NumberPad.Config.expandSymbol : nil"))
    }
}

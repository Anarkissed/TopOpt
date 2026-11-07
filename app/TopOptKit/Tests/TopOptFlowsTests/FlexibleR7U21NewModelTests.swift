// FlexibleR7U21NewModelTests — round 7 · U21, batch A (his notes of 2026-10-21).
//   NEW-FLEX-TAB (Img4/5): "There should be a flexible tab next to "filament" and "resin" that has a drop down of the different
//   flexible filaments we have listed. This should then lead right to the Flexible Lattice stage."
//   NO-AUTO-SQUISH (Img7): "I don't think there should be any automatic squish/rest selections whatsoever. Please remove them
//   from *new* models coming in."
//   HOME CARD (the reviewer's ruling of 2026-10-22 06:38): "a Flexible project must NOT read "ABS"".
// On HIS live projects of 2026-10-21 (round7/batch_u21/his_live_1021_lbracket, his_live_1021_pad). Each RED control is asserted
// red inside its test.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7U21NewModelTests: XCTestCase {

    static var lbracketDir: URL { FlexibleU21DeleteUndoTests.lbracketDir }
    static var padDir: URL { FlexibleU21DeleteUndoTests.padDir }
    static let modelCardOrder = ["varioshore_tpu", "bambu_tpu_for_ams", "ninjaflex_85a", "peba_85a", "peba_95a", "siraya_tpu_air",
                                 "siraya_peba_air", "siraya_roamr_tpu_air_hr", "tpu95a_generic", "esun_tpu_lw"]

    override func setUp() {
        super.setUp()
        FlexibleImportDraft.testMaterialsPath = FlexibleHisProject.materialsPath
    }
    override func tearDown() {
        FlexibleImportDraft.testMaterialsPath = nil
        FlexibleImportDraft.controlNoFlexibleTab = false
        FlexibleImportDraft.controlSegmentsKeepFlexible = false
        FlexibleStageModel.controlNewSetupReadsIn = false
        FlexibleHomeCard.testStoreRoot = nil
        FlexibleHomeCard.testMaterialsPath = nil
        FlexibleHomeCard.resetForTests()
        super.tearDown()
    }

    func appModel() -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("u21a-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let m = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                         rulesPath: core.appendingPathComponent("src/settings/rules.json").path, store: ProjectStore(rootDir: root))
        m.loadMaterials()
        m.newTopOpt()
        XCTAssertTrue(m.importFile(atPath: core.appendingPathComponent("tests/fixtures/stl/cube_10mm.stl").path,
                                   displayName: "cube_10mm.stl"))
        return (m, root)
    }

    // MARK: NEW-FLEX-TAB

    func testTheSheetOffersFlexibleWithTheModelCardsList() {
        FlexibleImportDraft.controlNoFlexibleTab = true
        let red = FlexibleImportDraft(materialsPath: nil).segments.map(\.label)
        FlexibleImportDraft.controlNoFlexibleTab = false
        XCTAssertEqual(red, ["Filament (FDM)", "Resin (SLA)"], "RED CONTROL: today's two segments")

        let d = FlexibleImportDraft(materialsPath: nil)
        XCTAssertTrue(d.available)
        XCTAssertEqual(d.segments.map(\.label), ["Filament (FDM)", "Resin (SLA)", "Flexible"], "★ [Flexible] beside Filament and Resin")
        XCTAssertEqual(d.catalogue.map(\.id), Self.modelCardOrder, "★ the 10 flexible filaments in the Model card's order")
        let card = FlexibleStageModel(project: ProjectModel(id: UUID(), name: "x", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil),
                                      materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        XCTAssertEqual(d.catalogue.map(\.id), card.catalogue.map(\.id), "★ the same order as the Model card's own list")
        XCTAssertEqual(d.materialID, "varioshore_tpu", "★ the one with squish data preselected")
        XCTAssertEqual(d.materialID, card.defaultMaterialID)
        for c in d.catalogue {
            let line = FlexibleImportDraft.menuLine(c)
            XCTAssertTrue(line.hasPrefix(c.displayName) && !line.contains("…"), "★ full name: \(line)")
        }
        print("FLEX-U21A menu: " + d.catalogue.map(FlexibleImportDraft.menuLine).joined(separator: " | "))

        let (m, _) = appModel()
        m.selectMaterial("PLA")
        m.process = .resin; m.selectMaterial("Resin_Tough"); m.process = .fdm
        d.select(.flexible, m)
        XCTAssertTrue(d.on); XCTAssertEqual(m.process, .fdm, "★ a Flexible project is an FDM print")
        XCTAssertEqual(d.selected(m), .flexible)
        XCTAssertEqual(m.selectedMaterial, "PLA", "★ the FDM pick stays under Flexible (hidden)")
        d.select(.resin, m)
        XCTAssertFalse(d.on); XCTAssertEqual(m.process, .resin); XCTAssertEqual(m.selectedMaterial, "Resin_Tough", "★ Resin restores its material")
        d.select(.filament, m)
        XCTAssertFalse(d.on); XCTAssertEqual(m.process, .fdm); XCTAssertEqual(m.selectedMaterial, "PLA")
        XCTAssertTrue(d.canContinue)
    }

    func testContinueOnFlexibleLandsOnTheFlexibleLatticeStage() throws {
        // RED: today's Continue
        let (r, _) = appModel()
        r.continueToWorkspace()
        let rp = try XCTUnwrap(r.project)
        XCTAssertNil(rp.lattice.flexible, "RED CONTROL: today's Continue makes no Flexible setup")
        XCTAssertFalse(FlexibleNewProject.takeLatticeStage(for: rp.id), "RED CONTROL: and asks for no landing")

        let (m, root) = appModel()
        let d = FlexibleImportDraft(materialsPath: nil)
        d.select(.flexible, m)
        XCTAssertTrue(m.canContinue && d.canContinue)
        d.continueFlexible(m)
        let p = try XCTUnwrap(m.project)
        XCTAssertEqual(m.screen, .workspace)
        XCTAssertEqual(p.lattice.flexible?.materialID, "varioshore_tpu", "★ the picked filament")
        XCTAssertEqual(p.lattice.flexible?.readsMainPageGroups, false, "★ a new setup: nothing read in")
        XCTAssertNil(p.lattice.stageMode, "★ the mode modal is never asked (Flexible is the answer)")
        XCTAssertTrue(m.printParamsSheetPresented, "★ the print parameters still come first")
        XCTAssertEqual(p.process, .fdm); XCTAssertEqual(p.material, "ABS", "★ Topology runs as ABS (as his pad)")
        XCTAssertFalse(FlexibleNewProject.takeLatticeStage(for: UUID()), "★ another project does not take it")
        XCTAssertTrue(FlexibleNewProject.takeLatticeStage(for: p.id), "★ this project's workspace lands on the Lattice stage")
        XCTAssertFalse(FlexibleNewProject.takeLatticeStage(for: p.id), "★ once")
        let saved = try String(contentsOf: root.appendingPathComponent(p.id.uuidString).appendingPathComponent("project.json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("\"materialID\":\"varioshore_tpu\"") && saved.contains("\"readsMainPageGroups\":false"), "★ saved at once")
        print("FLEX-U21A continue: undo steps \(p.undo.past.count), recents \(m.recentProjects.map(\.meta))")
    }

    // MARK: NO-AUTO-SQUISH

    func openStage(_ r: FlexibleHisProject.Restored, _ what: String) async throws -> FlexibleStageModel {
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, what)
        return m
    }
    func lbracket(_ flexible: FlexibleStageSettings) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(Self.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        r.project.lattice.flexible = flexible
        return (r, try await openStage(r, "his l-bracket, a new setup"))
    }
    func faces(_ m: FlexibleStageModel) -> [String] { m.settings.faces.map { "\($0.faceRegionID):\($0.role)" } }

    func testANewSetupOnHisLBracketReadsNothingIn() async throws {
        let (_, red) = try await lbracket(FlexibleStageSettings(materialID: "varioshore_tpu"))
        print("FLEX-U21A RED (a setup saved before 10-21, nil flag) faces \(faces(red))")
        XCTAssertEqual(red.settings.faces.count, 6, "RED CONTROL: his Topology groups read in (5 Rests + 1 squish, his Img7)")
        FlexibleStageModel.controlNewSetupReadsIn = true
        let (_, red2) = try await lbracket(.newSetup(materialID: "varioshore_tpu"))
        FlexibleStageModel.controlNewSetupReadsIn = false
        XCTAssertEqual(red2.settings.faces.count, 6, "RED CONTROL: today's adopt on a new setup")

        let (_, m) = try await lbracket(.newSetup(materialID: "varioshore_tpu"))
        print("FLEX-U21A new setup faces \(faces(m)) rail \(FlexibleSettingsRailView.tabs(model: m).map(\.title))")
        XCTAssertEqual(m.settings.faces.count, 0, "★ nothing read in")
        XCTAssertEqual(FlexibleSettingsRailView.tabs(model: m).map(\.tab), [.model, .newGroup], "★ the rail is [Model] [+ New]")
        m.adoptMainPageLoads()   // a write-back's re-sync
        XCTAssertEqual(m.settings.faces.count, 0, "★ still nothing after a write-back")
        XCTAssertEqual(m.settings.readsMainPageGroups, false)
        XCTAssertEqual(m.freshSettings().readsMainPageGroups, false, "★ Reset all keeps a new setup a new setup")
        XCTAssertNil(red.freshSettings().readsMainPageGroups, "★ and an old setup old")
    }

    func testAFacePressedOnANewSetupStillTakesItsTopologyWeight() async throws {
        let (r, m) = try await lbracket(.newSetup(materialID: "varioshore_tpu"))
        let groupB = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Group B" }?.id, "his Group B (10 lb on face 6)")
        let region = 2000002
        XCTAssertEqual(m.mainPageLoads.entry(region)?.role, .pressed, "premise: Group B presses region \(region)")
        XCTAssertTrue(m.press(region))
        let f = try XCTUnwrap(m.settings.face(region))
        XCTAssertEqual(f.weightKg, 4.535929094356398, accuracy: 1e-9, "★ his Topology weight (10 lb)")
        XCTAssertEqual(f.weightFrom, groupB, "★ linked to Group B")
        m.adoptMainPageLoads()
        XCTAssertEqual(faces(m), ["\(region):loaded"], "★ the re-sync keeps it and adds none of Group A's Rests")
        XCTAssertEqual(m.settings.face(region)?.weightFrom, groupB, "★ still linked")
    }

    func testHisPadKeepsItsGroups() async throws {
        let r = try FlexibleHisProject.restore(Self.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let before = try enc.encode(XCTUnwrap(r.project.lattice.flexible))
        let m = try await openStage(r, "his pad of 10-21")
        let after = try enc.encode(XCTUnwrap(r.project.lattice.flexible))
        print("FLEX-U21A pad faces \(faces(m)) bytes \(before.count) → \(after.count)")
        XCTAssertNil(m.settings.readsMainPageGroups)
        XCTAssertFalse(String(decoding: after, as: UTF8.self).contains("readsMainPageGroups"), "★ no new key in his pad")
        XCTAssertEqual(before, after, "★ his pad's setup byte-identical through the open")
    }

    func testTheFlagDecodesAndDesignInputsDropIt() throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let old = try enc.encode(FlexibleStageSettings(materialID: "varioshore_tpu"))
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("readsMainPageGroups"), "★ nil is never written")
        let new = try enc.encode(FlexibleStageSettings.newSetup(materialID: "varioshore_tpu"))
        XCTAssertTrue(String(decoding: new, as: UTF8.self).contains("\"readsMainPageGroups\":false"))
        XCTAssertEqual(try JSONDecoder().decode(FlexibleStageSettings.self, from: new).readsMainPageGroups, false)
        XCTAssertNil(try JSONDecoder().decode(FlexibleStageSettings.self, from: old).readsMainPageGroups)
        XCTAssertEqual(FlexibleStageSettings.newSetup(materialID: "varioshore_tpu").designInputs,
                       FlexibleStageSettings(materialID: "varioshore_tpu").designInputs, "★ no lattice key moves")
    }

    // MARK: HOME CARD

    func testTheHomeCardNamesTheFilament() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("u21a-home-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let flex = UUID(), topo = UUID()
        for (id, src) in [(flex, Self.lbracketDir), (topo, Self.lbracketDir)] {
            let d = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var json = try String(contentsOf: src.appendingPathComponent("project.json"), encoding: .utf8)
            if id == topo {   // a Topology project: no Flexible block
                var o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                var l = try XCTUnwrap(o["lattice"] as? [String: Any]); l["flexible"] = nil; o["lattice"] = l
                json = String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
            }
            try json.write(to: d.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        }
        FlexibleHomeCard.testStoreRoot = root
        FlexibleHomeCard.testMaterialsPath = FlexibleHisProject.materialsPath
        FlexibleHomeCard.resetForTests()
        let flexCard = RecentProject(id: flex, name: "l bracket large", materialName: "ABS", process: .fdm)
        let topoCard = RecentProject(id: topo, name: "bracket", materialName: "ABS", process: .fdm)
        XCTAssertEqual(flexCard.meta, "ABS · Just now", "RED CONTROL: today's card reads ABS for his Flexible bracket")
        XCTAssertEqual(FlexibleHomeCard.meta(flexCard), "colorFabb varioShore TPU · Just now", "★ the filament, the Model card's short name")
        XCTAssertNil(FlexibleHomeCard.meta(topoCard), "★ a Topology project: today's label")
        XCTAssertEqual(FlexibleHomeCard.meta(topoCard) ?? topoCard.meta, "ABS · Just now", "★ byte-identical for Topology")
        let reads = FlexibleHomeCard.reads
        _ = FlexibleHomeCard.meta(flexCard); _ = FlexibleHomeCard.meta(topoCard)
        XCTAssertEqual(FlexibleHomeCard.reads, reads, "★ cached by id + modification date")
        let url = root.appendingPathComponent(flex.uuidString).appendingPathComponent("project.json")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        _ = FlexibleHomeCard.meta(flexCard)
        XCTAssertEqual(FlexibleHomeCard.reads, reads + 1, "★ re-read after a save")
        XCTAssertNil(FlexibleHomeCard.meta(RecentProject(name: "gone", materialName: "PLA", process: .fdm)), "★ no file: today's label")
    }
}

// Headless macOS tests for M7.params: the print-parameters capture, its persistence
// round-trip (survives relaunch), and the infill-% threading into the run request.
// Layout is maintainer device QA (per DECISIONS 2026-07-09); everything asserted
// here is pure data + flow logic driven through the real store/bridge fixtures.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class PrintParamsTests: XCTestCase {

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
            .appendingPathComponent("topopt-params-tests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }
    private func appModel(store: ProjectStore,
                          presetStore: PrintParamsPresetStore? = nil) -> AppModel {
        AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                 store: store, presetStore: presetStore ?? PrintParamsPresetStore(rootDir: tempDir))
    }

    // MARK: - the value type

    func testFDMDefaults() {
        let d = PrintParams.fdmDefault
        XCTAssertEqual(d.layerHeightMM, 0.2)
        XCTAssertEqual(d.wallLoops, 3)
        XCTAssertEqual(d.topLayers, 4)
        XCTAssertEqual(d.bottomLayers, 4)
        XCTAssertEqual(d.infillPercent, 20)
        XCTAssertEqual(d.infillPattern, "gyroid")
        XCTAssertTrue(PrintParams.patternOptions.contains(d.infillPattern))
    }

    func testClampToSaneFDMBounds() {
        let wild = PrintParams(layerHeightMM: 9.0, wallLoops: -3, topLayers: 99,
                               bottomLayers: -1, infillPercent: 250, infillPattern: "nonsense")
        let c = wild.clamped()
        XCTAssertEqual(c.layerHeightMM, 1.0)     // capped at 1.0 mm
        XCTAssertEqual(c.wallLoops, 0)           // floored at 0
        XCTAssertEqual(c.topLayers, 15)          // capped at 15
        XCTAssertEqual(c.bottomLayers, 0)
        XCTAssertEqual(c.infillPercent, 100)     // capped at 100 %
        XCTAssertEqual(c.infillPattern, "gyroid", "an unknown pattern falls back to the default")
    }

    func testClampLeavesValidValuesUntouched() {
        let ok = PrintParams(layerHeightMM: 0.28, wallLoops: 4, topLayers: 5,
                             bottomLayers: 3, infillPercent: 35, infillPattern: "cubic")
        XCTAssertEqual(ok.clamped(), ok)
    }

    // MARK: - infill numeric-input logic (M7.params c: precise entry)

    func testSteppingInfillClampsToRange() {
        var p = PrintParams.fdmDefault
        p.infillPercent = 20
        XCTAssertEqual(p.steppingInfill(by: 1), 21)
        XCTAssertEqual(p.steppingInfill(by: -1), 19)
        p.infillPercent = 0
        XCTAssertEqual(p.steppingInfill(by: -1), 0, "floored at 0 — the − stepper can't go negative")
        p.infillPercent = 100
        XCTAssertEqual(p.steppingInfill(by: 1), 100, "capped at 100 — the + stepper can't overshoot")
    }

    func testInfillSliderValuePinsIntoTrack() {
        var p = PrintParams.fdmDefault
        p.infillPercent = 37
        XCTAssertEqual(p.infillSliderValue, 37)
        // The tap-to-edit field can briefly hold an out-of-range value before the
        // on-close clamp; the slider still reads a value inside its 0...100 track.
        p.infillPercent = 500
        XCTAssertEqual(p.infillSliderValue, 100)
        p.infillPercent = -20
        XCTAssertEqual(p.infillSliderValue, 0)
    }

    func testSlicerOverrideDropsLayerHeight() {
        // The override projects onto the M5.1 engine's FDM field set — layer height
        // is captured but NOT part of that set (it has no engine field).
        let p = PrintParams(layerHeightMM: 0.3, wallLoops: 5, topLayers: 6,
                            bottomLayers: 4, infillPercent: 42, infillPattern: "grid")
        XCTAssertEqual(p.slicerOverride,
                       SlicerOverride(walls: 5, topLayers: 6, bottomLayers: 4,
                                      infillPercent: 42, infillPattern: "grid"))
    }

    // MARK: - capture + persistence round-trip

    func testSnapshotCarriesPrintParams() throws {
        let params = PrintParams(layerHeightMM: 0.16, wallLoops: 6, topLayers: 7,
                                 bottomLayers: 5, infillPercent: 55, infillPattern: "honeycomb")
        let snap = ProjectSnapshot(id: UUID(), name: "Bracket", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "Bracket.stl",
                                   savedAt: Date(timeIntervalSince1970: 1000),
                                   selection: SelectionModel(), force: ForceModel(),
                                   printParams: params)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.printParams, params)
    }

    func testPreParamsSnapshotDecodesToDefault() throws {
        // A snapshot written before M7.params (no printParams key) still decodes, and
        // a restored project treats the missing field as the FDM default (back-compat,
        // matching the minimizePlastic/quality optional pattern).
        let snap = ProjectSnapshot(id: UUID(), name: "Old", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "Old.stl",
                                   savedAt: Date(timeIntervalSince1970: 5),
                                   selection: SelectionModel(), force: ForceModel())
        XCTAssertNil(snap.printParams)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        XCTAssertNil(back.printParams)

        let mesh = try TopOptKit.importMesh(path: Self.cubeSTL)
        let file = ImportedFile(name: "Old.stl", path: Self.cubeSTL,
                                triangleCount: mesh.triangleCount, faceCount: mesh.faceCount,
                                watertight: mesh.watertight)
        let pm = ProjectModel(restoring: back, importedFile: file, importedMesh: mesh)
        XCTAssertEqual(pm.printParams, .fdmDefault)
    }

    func testPrintParamsSurviveAppRelaunch() throws {
        // Launch 1: import, edit print parameters, leave to Home (autosave).
        let m1 = appModel(store: ProjectStore(rootDir: tempDir))
        m1.loadMaterials(); m1.newTopOpt(); m1.selectMaterial("PLA")
        XCTAssertTrue(m1.importFile(atPath: Self.cubeSTL, displayName: "Wall_Bracket.stl"))
        m1.continueToWorkspace()
        let project1 = try XCTUnwrap(m1.project)
        XCTAssertEqual(project1.printParams, .fdmDefault, "seeded with FDM defaults")

        project1.printParams = PrintParams(layerHeightMM: 0.12, wallLoops: 5, topLayers: 6,
                                           bottomLayers: 5, infillPercent: 65, infillPattern: "cubic")
        m1.backHome()   // autosave

        // Launch 2: a brand-new AppModel over the same directory.
        let m2 = appModel(store: ProjectStore(rootDir: tempDir))
        let recent = try XCTUnwrap(m2.recentProjects.first)
        m2.open(recent)
        let restored = try XCTUnwrap(m2.project)
        XCTAssertFalse(restored === project1)
        XCTAssertEqual(restored.printParams.wallLoops, 5)
        XCTAssertEqual(restored.printParams.topLayers, 6)
        XCTAssertEqual(restored.printParams.bottomLayers, 5)
        XCTAssertEqual(restored.printParams.infillPercent, 65)
        XCTAssertEqual(restored.printParams.infillPattern, "cubic")
        XCTAssertEqual(restored.printParams.layerHeightMM, 0.12)
    }

    // MARK: - sheet lifecycle: clamp + persist on close

    func testClosePrintParamsClampsAndPersists() throws {
        let store = ProjectStore(rootDir: tempDir)
        let m = appModel(store: store)
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        let project = try XCTUnwrap(m.project)

        m.openPrintParams()
        XCTAssertTrue(m.printParamsSheetPresented)
        // Simulate live edits that go out of bounds (the numeric fields allow it).
        project.printParams.infillPercent = 500
        project.printParams.wallLoops = -2
        m.closePrintParams()

        XCTAssertFalse(m.printParamsSheetPresented)
        XCTAssertEqual(project.printParams.infillPercent, 100, "clamped on close")
        XCTAssertEqual(project.printParams.wallLoops, 0)
        // And the clamped values are on disk.
        let snap = try XCTUnwrap(store.snapshot(id: project.id))
        XCTAssertEqual(snap.printParams?.infillPercent, 100)
        XCTAssertEqual(snap.printParams?.wallLoops, 0)
    }

    func testOpenPrintParamsNoOpWithoutProject() {
        let m = appModel(store: ProjectStore(rootDir: tempDir))
        m.openPrintParams()
        XCTAssertFalse(m.printParamsSheetPresented, "nothing to edit with no open project")
    }

    // MARK: - auto-present after import (M7.params b)

    func testSheetAutoPresentsAfterImport() throws {
        // A freshly imported model prompts for print params: the sheet is presented
        // as the workspace opens, without the user tapping the Print Parameters pill.
        let m = appModel(store: ProjectStore(rootDir: tempDir))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertFalse(m.printParamsSheetPresented, "not shown during import")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        XCTAssertEqual(m.screen, .workspace)
        XCTAssertTrue(m.printParamsSheetPresented,
                      "the sheet auto-presents over the new workspace after import")
    }

    func testOpeningRecentDoesNotAutoPresentSheet() throws {
        // Auto-present is for a NEW import only. Reopening an existing project from
        // Home lands in the workspace without re-prompting for print params.
        let m1 = appModel(store: ProjectStore(rootDir: tempDir))
        m1.loadMaterials(); m1.newTopOpt(); m1.selectMaterial("PLA")
        XCTAssertTrue(m1.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m1.continueToWorkspace()
        m1.closePrintParams()   // dismiss the auto-presented sheet
        m1.backHome()

        let m2 = appModel(store: ProjectStore(rootDir: tempDir))
        let recent = try XCTUnwrap(m2.recentProjects.first)
        m2.open(recent)
        XCTAssertEqual(m2.screen, .workspace)
        XCTAssertFalse(m2.printParamsSheetPresented, "reopening a recent doesn't re-prompt")
    }

    func testSheetRoundTripThroughAutoPresentPersists() throws {
        // The full UX path the fix delivers: import → sheet auto-presents → the user
        // edits every field live (as the sheet's bindings do) → Done → the values are
        // persisted and survive an app relaunch.
        let m1 = appModel(store: ProjectStore(rootDir: tempDir))
        m1.loadMaterials(); m1.newTopOpt(); m1.selectMaterial("PLA")
        XCTAssertTrue(m1.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m1.continueToWorkspace()
        let project = try XCTUnwrap(m1.project)
        XCTAssertTrue(m1.printParamsSheetPresented)

        project.printParams.layerHeightMM = 0.16
        project.printParams.wallLoops = 5
        project.printParams.topLayers = 6
        project.printParams.bottomLayers = 5
        project.printParams.infillPercent = 42
        project.printParams.infillPattern = "grid"
        m1.closePrintParams()   // the sheet's Done
        XCTAssertFalse(m1.printParamsSheetPresented)

        let m2 = appModel(store: ProjectStore(rootDir: tempDir))
        m2.open(try XCTUnwrap(m2.recentProjects.first))
        let restored = try XCTUnwrap(m2.project)
        XCTAssertEqual(restored.printParams,
                       PrintParams(layerHeightMM: 0.16, wallLoops: 5, topLayers: 6,
                                   bottomLayers: 5, infillPercent: 42, infillPattern: "grid"))
    }

    // MARK: - infill threading into the run request

    func testRunRequestCarriesInfillOverride() throws {
        let m = appModel(store: ProjectStore(rootDir: tempDir))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        let project = try XCTUnwrap(m.project)
        project.printParams.infillPercent = 45

        let request = try XCTUnwrap(m.makeRunRequest())
        XCTAssertEqual(request.infillPercent, 45,
                       "the project's infill override is threaded into the run request → bridge")
    }

    func testInfillIsPartOfRequestIdentity() {
        // Changing infill % must change the request (it feeds the M7.infill-margin
        // ladder knockdown), so Optimize re-enables after an infill edit.
        let base = RunRequest(modelPath: "/m.step", material: "PLA", materialsPath: "/mat",
                              rulesPath: "/rules", resolution: 64, projectName: "P",
                              infillPercent: 20)
        let changed = RunRequest(modelPath: "/m.step", material: "PLA", materialsPath: "/mat",
                                 rulesPath: "/rules", resolution: 64, projectName: "P",
                                 infillPercent: 40)
        XCTAssertNotEqual(base, changed)
    }

    // MARK: - app-wide named presets (M7.params "save")

    func testPresetStoreRoundTrip() throws {
        let store = PrintParamsPresetStore(rootDir: tempDir)
        XCTAssertTrue(store.load().isEmpty, "nothing saved yet")
        let presets = [
            PrintParamsPreset(name: "Strong", params: PrintParams(
                layerHeightMM: 0.2, wallLoops: 6, topLayers: 6, bottomLayers: 6,
                infillPercent: 60, infillPattern: "gyroid")),
            PrintParamsPreset(name: "Draft", params: .fdmDefault),
        ]
        try store.save(presets)
        XCTAssertEqual(PrintParamsPresetStore(rootDir: tempDir).load(), presets,
                       "a fresh store over the same dir reads the saved presets back")
    }

    func testAllPresetsAlwaysLeadsWithBuiltInDefault() {
        let m = appModel(store: ProjectStore(rootDir: tempDir))
        XCTAssertEqual(m.allPresets.first, .builtInDefault)
        XCTAssertEqual(m.allPresets.first?.params, .fdmDefault)
        XCTAssertEqual(m.allPresets.count, 1, "just Default on a fresh install")
    }

    func testSavePresetPersistsAppWideAcrossLaunches() throws {
        let presetStore = PrintParamsPresetStore(rootDir: tempDir)
        // Launch 1: save a named preset from the current values.
        let m1 = appModel(store: ProjectStore(rootDir: tempDir), presetStore: presetStore)
        let params = PrintParams(layerHeightMM: 0.16, wallLoops: 5, topLayers: 6,
                                 bottomLayers: 5, infillPercent: 45, infillPattern: "cubic")
        let saved = try XCTUnwrap(m1.savePreset(named: "  My Bracket Preset  ", params: params))
        XCTAssertEqual(saved.name, "My Bracket Preset", "trimmed")
        XCTAssertEqual(m1.savedPresets, [saved])
        XCTAssertEqual(m1.allPresets.map(\.name), ["Default", "My Bracket Preset"])

        // Launch 2: a brand-new AppModel over the same preset store sees it (app-wide).
        let m2 = appModel(store: ProjectStore(rootDir: tempDir),
                          presetStore: PrintParamsPresetStore(rootDir: tempDir))
        XCTAssertEqual(m2.savedPresets, [saved])
        XCTAssertEqual(m2.allPresets.last?.params, params.clamped())
    }

    func testSavePresetIgnoresBlankName() {
        let m = appModel(store: ProjectStore(rootDir: tempDir))
        XCTAssertNil(m.savePreset(named: "   ", params: .fdmDefault))
        XCTAssertTrue(m.savedPresets.isEmpty)
    }

    func testApplyPresetLoadsValuesIntoOpenProject() throws {
        let m = appModel(store: ProjectStore(rootDir: tempDir))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()   // unlocked creation sheet
        let project = try XCTUnwrap(m.project)
        let preset = PrintParamsPreset(name: "Fine", params: PrintParams(
            layerHeightMM: 0.12, wallLoops: 4, topLayers: 5, bottomLayers: 5,
            infillPercent: 35, infillPattern: "grid"))
        m.applyPreset(preset)
        XCTAssertEqual(project.printParams, preset.params, "the preset loads into the sheet")
    }

    // MARK: - lock at creation (M7.params lock-at-creation)

    func testNewProjectStartsUnlockedThenLocksOnCreationSheetDone() throws {
        let m = appModel(store: ProjectStore(rootDir: tempDir))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        let project = try XCTUnwrap(m.project)
        XCTAssertFalse(project.paramsLocked, "editable during the auto-presented creation sheet")
        project.printParams.infillPercent = 30
        m.closePrintParams()   // the creation sheet's Done commits + LOCKS
        XCTAssertTrue(project.paramsLocked, "fixed for the life of the project after creation")
        XCTAssertEqual(project.printParams.infillPercent, 30)
    }

    func testApplyPresetIsNoOpOnceLocked() throws {
        let m = appModel(store: ProjectStore(rootDir: tempDir))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        let project = try XCTUnwrap(m.project)
        project.printParams.infillPercent = 25
        m.closePrintParams()   // lock it
        let before = project.printParams
        m.applyPreset(PrintParamsPreset(name: "Other", params: .fdmDefault))
        XCTAssertEqual(project.printParams, before, "presets can't override a locked project")
    }

    func testRestoredProjectIsLocked() throws {
        // Launch 1: create + commit params, leave to Home.
        let m1 = appModel(store: ProjectStore(rootDir: tempDir))
        m1.loadMaterials(); m1.newTopOpt(); m1.selectMaterial("PLA")
        XCTAssertTrue(m1.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m1.continueToWorkspace()
        m1.closePrintParams()
        m1.backHome()

        // Launch 2: reopening the restored project is already created → locked.
        let m2 = appModel(store: ProjectStore(rootDir: tempDir))
        m2.open(try XCTUnwrap(m2.recentProjects.first))
        XCTAssertTrue(try XCTUnwrap(m2.project).paramsLocked,
                      "a restored project's parameters are fixed")
    }
}

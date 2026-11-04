// Headless macOS tests for the M7.3 home + import flow (AppModel).
//
// The M7 verification standard for /app/ is `xcodebuild test` on this package
// (raw output in the handoff) — /app/ is not on Linux CI. These drive the flow
// logic against the committed core fixtures through the real bridge (so they
// would fail if import/material wiring were stubbed) and force the error paths
// via injected closures.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class AppModelTests: XCTestCase {

    // Repo paths resolved from this source file: .../app/TopOptKit/Tests/
    // TopOptFlowsTests/AppModelTests.swift -> up 5 -> repo root.
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String {
        repoRoot.appendingPathComponent("core/\(rel)").path
    }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }
    private static var brokenSTL: String { core("tests/fixtures/stl/broken_open_cube.stl") }

    /// An isolated on-disk store per test, so persistence (M7.x-persist-b) never
    /// touches the real Application Support or leaks state between tests.
    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-appmodel-tests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// A model wired to the real committed materials.json + real bridge importer,
    /// with an isolated per-test project store.
    private func realModel() -> AppModel {
        AppModel(materialsPath: Self.materialsPath, store: ProjectStore(rootDir: tempDir))
    }

    // MARK: materials

    func testMaterialsSplitByFamily() {
        let m = realModel()
        m.loadMaterials()
        // Every material lands in exactly one family list; counts sum to the file.
        XCTAssertEqual(m.fdmMaterials.count + m.resinMaterials.count, 12)
        XCTAssertTrue(m.fdmMaterials.contains(MaterialOption("PLA")))
        XCTAssertTrue(m.resinMaterials.contains(MaterialOption("Resin_Standard")))
        XCTAssertFalse(m.fdmMaterials.contains(MaterialOption("Resin_Standard")))
        XCTAssertFalse(m.resinMaterials.contains(MaterialOption("PLA")))
        // Bridge returns name-sorted; each list stays sorted.
        XCTAssertEqual(m.fdmMaterials.map(\.name), m.fdmMaterials.map(\.name).sorted())
        XCTAssertEqual(m.resinMaterials.map(\.name), m.resinMaterials.map(\.name).sorted())
    }

    func testDefaultSelectionSeededPerFamily() {
        let m = realModel()
        m.loadMaterials()
        XCTAssertEqual(m.selectedFDMMaterial, m.fdmMaterials.first?.name)
        XCTAssertEqual(m.selectedResinMaterial, m.resinMaterials.first?.name)
        // Current (fdm by default) resolves to the fdm default.
        XCTAssertEqual(m.selectedMaterial, m.fdmMaterials.first?.name)
    }

    func testMaterialsLoadErrorToasts() {
        // Injected loader that throws — the dropdowns stay empty and a toast shows.
        struct LoadFailure: Error {}
        let m = AppModel(materialsPath: "/no/such/materials.json",
                         materialsLoader: { _ in throw LoadFailure() },
                         store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        XCTAssertTrue(m.fdmMaterials.isEmpty)
        XCTAssertTrue(m.resinMaterials.isEmpty)
        XCTAssertNotNil(m.toast)
    }

    func testCurrentMaterialsFollowProcess() {
        let m = realModel()
        m.loadMaterials()
        XCTAssertEqual(m.currentMaterials, m.fdmMaterials)
        m.process = .resin
        XCTAssertEqual(m.currentMaterials, m.resinMaterials)
        XCTAssertEqual(m.selectedMaterial, m.selectedResinMaterial)
    }

    func testSelectMaterialIsPerFamily() {
        let m = realModel()
        m.loadMaterials()
        m.process = .fdm
        m.selectMaterial("PLA")
        m.process = .resin
        m.selectMaterial("Resin_Tough")
        XCTAssertEqual(m.selectedResinMaterial, "Resin_Tough")
        m.process = .fdm
        XCTAssertEqual(m.selectedMaterial, "PLA")  // fdm choice retained across switch
    }

    // MARK: import sheet + file import

    func testNewTopOptOpensSheetAndClearsFile() {
        let m = realModel()
        m.loadMaterials()
        m.newTopOpt()
        XCTAssertTrue(m.importSheetPresented)
        XCTAssertNil(m.importedFile)
    }

    func testImportWatertightAccepts() {
        let m = realModel()
        let ok = m.importFile(atPath: Self.cubeSTL)
        XCTAssertTrue(ok)
        let file = m.importedFile
        XCTAssertNotNil(file)
        XCTAssertEqual(file?.triangleCount, 12)
        XCTAssertTrue(file?.watertight == true)
        XCTAssertNil(m.toast)  // no error toast on success
    }

    // Handoff 134 CHANGED THIS. A broken mesh used to be rejected with a toast
    // saying "not watertight". The picker now routes through `pickedFile`,
    // which inspects first and raises the plain-language REFUSAL SHEET — a
    // toast is the wrong surface for the end of the user's attempt.
    func testBrokenMeshIsRefusedWithASheetNotAToast() {
        let m = realModel()
        m.pickedFile(atPath: Self.brokenSTL, displayName: "broken_open_cube.stl")
        XCTAssertNil(m.importedFile)
        XCTAssertNil(m.pendingUnitPrompt)          // never gets as far as units
        let refusal = m.importRefusal
        XCTAssertNotNil(refusal)
        XCTAssertEqual(refusal?.diagnostics?.defects, [.openBoundary])
        XCTAssertEqual(refusal?.fileName, "broken_open_cube.stl")
        // The sheet explains in the user's terms and admits the scope limit.
        XCTAssertTrue(refusal?.reasons.first?.headline.contains("holes") == true)
        XCTAssertFalse(refusal?.suggestions.isEmpty == true)
        XCTAssertTrue(refusal?.scopeNote.isEmpty == false)

        m.dismissRefusal()
        XCTAssertNil(m.importRefusal)
    }

    // The direct `importFile` path still fails closed (it is the backstop for a
    // file that slips past inspection, and the STEP path's only guard).
    func testImportFileStillRejectsABrokenMesh() {
        let m = realModel()
        let ok = m.importFile(atPath: Self.brokenSTL)
        XCTAssertFalse(ok)
        XCTAssertNil(m.importedFile)
        XCTAssertNotNil(m.toast)
    }

    // A clean mesh asks the unit question BEFORE importing — an STL carries no
    // unit, and guessing wrong is a 25.4x error in every downstream number.
    func testCleanMeshAsksForUnitsThenImports() {
        let m = realModel()
        m.pickedFile(atPath: Self.cubeSTL, displayName: "cube_10mm.stl")
        XCTAssertNil(m.importRefusal)
        XCTAssertNil(m.importedFile)               // not imported yet
        let prompt = m.pendingUnitPrompt
        XCTAssertNotNil(prompt)
        XCTAssertEqual(prompt?.fileName, "cube_10mm.stl")
        XCTAssertEqual(prompt?.largestDimension ?? 0, 10.0, accuracy: 1e-6)
        XCTAssertEqual(prompt?.suggestedUnit, .millimetres)  // 10 mm is part-sized

        XCTAssertTrue(m.resolveUnits(.millimetres))
        XCTAssertNil(m.pendingUnitPrompt)
        XCTAssertEqual(m.importedFile?.name, "cube_10mm.stl")
        XCTAssertEqual(m.importedFile?.faceCount, 6)   // pseudo-faces, tappable
        XCTAssertTrue(m.importedFile?.pseudoFaces == true)
        XCTAssertNil(m.toast)
    }

    // Answering "inches" rescales the working copy, so everything downstream
    // reads a file already in millimetres.
    func testInchUnitChoiceRescalesTheWorkingCopy() {
        let m = realModel()
        m.pickedFile(atPath: Self.cubeSTL, displayName: "cube_10mm.stl")
        XCTAssertTrue(m.resolveUnits(.inches))
        let path = m.importedFile?.path
        XCTAssertNotNil(path)
        XCTAssertNotEqual(path, Self.cubeSTL)      // a NEW, rescaled copy
        let d = try? TopOptKit.inspectPart(path: path ?? "")
        XCTAssertEqual(d?.largestDimension ?? 0, 254.0, accuracy: 1e-2)
        XCTAssertEqual(m.importedFile?.faceCount, 6)
    }

    // A 3MF import is NORMALISED to an STL working copy — even in millimetres —
    // so the optimize path (bridge AND worker) never re-parses 3MF (handoff
    // 2026-07-26-3mf-optimize-path). This drives the REAL bridge on the committed
    // plate_bore.3mf, so it fails if the macOS slice lacks lib3mf (== the iOS slice
    // path the iPad runs). The provenance survives: the model file is .stl, but the
    // display name and `sourceFormat` still say 3MF, and the run request carries it.
    func testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance() throws {
        let threeMF = Self.core("tests/fixtures/mesh/plate_bore.3mf")
        let m = realModel()
        m.loadMaterials()
        m.pickedFile(atPath: threeMF, displayName: "plate_bore.3mf")
        // A real 3MF parse happened (needs lib3mf in this slice) → unit prompt, no refusal.
        XCTAssertNil(m.importRefusal, "3MF should parse; refusal means the slice has no lib3mf")
        XCTAssertNotNil(m.pendingUnitPrompt)

        XCTAssertTrue(m.resolveUnits(.millimetres))
        let file = try XCTUnwrap(m.importedFile)
        // The working file the optimize path reads is STL, NOT the .3mf.
        XCTAssertEqual((file.path as NSString).pathExtension.lowercased(), "stl",
                       "3MF must be normalised to an STL working copy")
        XCTAssertNotEqual(file.path, threeMF)
        // Provenance is preserved for run_info + the UI.
        XCTAssertEqual(file.name, "plate_bore.3mf")
        XCTAssertEqual(file.sourceFormat, "3mf")
        XCTAssertTrue(file.watertight)
        // The STL working copy re-imports cleanly with the same manufactured faces
        // the 3MF gave (plate_bore has 7 pseudo-faces — see core test_3mf_import).
        XCTAssertEqual(file.faceCount, 7)
    }

    // Reopening a persisted 3MF project re-imports the STL WORKING COPY, not the
    // .3mf. The stored model is named model.stl (its actual content), so the reopen
    // dispatches an STL reader — a model.3mf name would both mis-dispatch and fail on
    // a lib3mf-less relaunch. The provenance (.3mf name, sourceFormat) survives the
    // round-trip via originalFileName.
    func testReopenedThreeMFProjectReimportsTheStlWorkingCopy() throws {
        let threeMF = Self.core("tests/fixtures/mesh/plate_bore.3mf")
        // Launch 1: import the 3MF (→ STL working copy), enter the workspace, persist.
        let m1 = AppModel(materialsPath: Self.materialsPath, store: ProjectStore(rootDir: tempDir))
        m1.loadMaterials()
        m1.newTopOpt(); m1.selectMaterial("PLA")
        m1.pickedFile(atPath: threeMF, displayName: "plate_bore.3mf")
        XCTAssertTrue(m1.resolveUnits(.millimetres))
        m1.continueToWorkspace()
        let id = try XCTUnwrap(m1.project?.id)
        m1.backHome()   // persists the snapshot + copies the model into the store

        // Launch 2: reopen from disk.
        let m2 = AppModel(materialsPath: Self.materialsPath, store: ProjectStore(rootDir: tempDir))
        m2.loadMaterials()
        let recent = try XCTUnwrap(m2.recentProjects.first { $0.id == id })
        m2.open(recent)
        let file = try XCTUnwrap(m2.project?.importedFile)
        XCTAssertEqual((file.path as NSString).lastPathComponent, "model.stl",
                       "the persisted model must be the STL working copy, not model.3mf")
        XCTAssertEqual(file.name, "plate_bore.3mf")   // provenance display preserved
        XCTAssertEqual(file.sourceFormat, "3mf")
        XCTAssertTrue(file.watertight)
        XCTAssertEqual(file.faceCount, 7)
    }

    // END TO END, on the ON-DEVICE path: import a real .3mf and OPTIMISE it through
    // the same bridge entry the iPad's Optimize button calls (`run_minimize_plastic`).
    // The import normalises 3MF → STL working copy, and the optimizer reads THAT — so
    // the whole flow never re-parses 3MF, yet the part the user chose is a .3mf. This
    // is the on-device half of the reported bug's fix (the worker half is the LAN
    // worker E2E in the handoff). Real bridge + real optimizer, so it fails if either
    // the slice's lib3mf or the mesh optimize path regresses.
    func testThreeMFImportOptimisesOnDeviceEndToEnd() throws {
        let threeMF = Self.core("tests/fixtures/mesh/plate_bore.3mf")
        let rulesPath = Self.core("src/settings/rules.json")
        let m = realModel()
        m.loadMaterials()
        m.pickedFile(atPath: threeMF, displayName: "plate_bore.3mf")
        XCTAssertTrue(m.resolveUnits(.millimetres))
        let file = try XCTUnwrap(m.importedFile)
        XCTAssertEqual((file.path as NSString).pathExtension.lowercased(), "stl")

        // The exact call RunModel makes for an on-device self-weight run, pointed at
        // the STL working copy the 3MF was normalised to.
        let outcome = try TopOptKit.minimizePlastic(
            stlPath: file.path, material: "PLA",
            materialsPath: Self.materialsPath, rulesPath: rulesPath, resolution: 32)
        XCTAssertFalse(outcome.variants.isEmpty,
                       "the on-device optimizer must produce variants for a normalised 3MF part")
    }

    // Cancelling the unit question imports nothing and leaves no residue.
    func testCancellingTheUnitPromptImportsNothing() {
        let m = realModel()
        m.pickedFile(atPath: Self.cubeSTL, displayName: "cube_10mm.stl")
        XCTAssertNotNil(m.pendingUnitPrompt)
        m.cancelUnitPrompt()
        XCTAssertNil(m.pendingUnitPrompt)
        XCTAssertNil(m.importedFile)
        XCTAssertFalse(m.resolveUnits(.millimetres))  // nothing pending to resolve
    }

    func testImportMissingFileToastsDiagnostic() {
        let m = realModel()
        let ok = m.importFile(atPath: "/no/such/part.stl")
        XCTAssertFalse(ok)
        XCTAssertNil(m.importedFile)
        XCTAssertNotNil(m.toast)
    }

    func testImportRejectClearsPriorAcceptedFile() {
        let m = realModel()
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL))
        XCTAssertNotNil(m.importedFile)
        XCTAssertFalse(m.importFile(atPath: Self.brokenSTL))  // reject
        XCTAssertNil(m.importedFile)                          // replaces prior draft
    }

    // MARK: Continue gating + navigation

    func testCanContinueRequiresFileAndMaterial() {
        let m = realModel()
        m.loadMaterials()                 // seeds a material selection
        XCTAssertFalse(m.canContinue)     // …but no file yet
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL))
        XCTAssertTrue(m.canContinue)
    }

    func testContinueRecordsRecentAndEntersWorkspace() {
        let m = realModel()
        m.loadMaterials()
        m.newTopOpt()
        m.process = .fdm
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Wall_Bracket_v4.stl"))
        m.continueToWorkspace()
        XCTAssertEqual(m.screen, .workspace)
        XCTAssertFalse(m.importSheetPresented)
        XCTAssertEqual(m.recentProjects.count, 1)
        XCTAssertEqual(m.recentProjects.first?.materialName, "PLA")
        XCTAssertEqual(m.recentProjects.first?.process, .fdm)
        // Name derived from the file name (extension dropped, separators → spaces).
        XCTAssertEqual(m.projectName, "Wall Bracket v4")
        XCTAssertEqual(m.recentProjects.first?.name, "Wall Bracket v4")
    }

    func testContinueGeneratesLibraryThumbnail() {
        let m = realModel()
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        // A real mesh renders a thumbnail keyed by the recent's id.
        let id = try! XCTUnwrap(m.recentProjects.first).id
        let thumb = try! XCTUnwrap(m.thumbnails[id], "imported mesh should render a thumbnail")
        XCTAssertGreaterThan(thumb.width, 0)
        XCTAssertGreaterThan(thumb.height, 0)
    }

    func testRenameRecentUpdatesGridAndSnapshot() {
        let m = realModel()
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        let id = try! XCTUnwrap(m.recentProjects.first).id
        m.renameRecent(id: id, to: "  Renamed Bracket  ")   // trimmed
        XCTAssertEqual(m.recentProjects.first?.name, "Renamed Bracket")
        XCTAssertEqual(m.projectName, "Renamed Bracket")     // open project follows
        // The on-disk snapshot is rewritten too (survives relaunch).
        let reloaded = AppModel(materialsPath: Self.materialsPath,
                                store: ProjectStore(rootDir: tempDir))
        reloaded.loadMaterials()
        XCTAssertEqual(reloaded.recentProjects.first { $0.id == id }?.name, "Renamed Bracket")
    }

    func testRenameRecentIgnoresBlankName() {
        let m = realModel()
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        let id = try! XCTUnwrap(m.recentProjects.first).id
        m.renameRecent(id: id, to: "   ")
        XCTAssertEqual(m.recentProjects.first?.name, "Cube")   // unchanged
    }

    func testOptimizedFlagDefaultsFalseAndPersists() {
        // A fresh recent is "Ready" (not optimized); the flag survives a snapshot
        // round-trip when set true.
        let m = realModel()
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Cube.stl"))
        m.continueToWorkspace()
        XCTAssertEqual(m.recentProjects.first?.optimized, false)

        let store = ProjectStore(rootDir: tempDir)
        var snap = try! XCTUnwrap(store.loadAllSnapshots().first)
        snap.optimized = true
        try! store.save(snap)
        let reloaded = AppModel(materialsPath: Self.materialsPath, store: store)
        reloaded.loadMaterials()
        XCTAssertEqual(reloaded.recentProjects.first?.optimized, true)
    }

    func testContinueBlockedWithoutFile() {
        let m = realModel()
        m.loadMaterials()
        m.newTopOpt()
        m.continueToWorkspace()           // no file imported
        XCTAssertEqual(m.screen, .home)
        XCTAssertTrue(m.recentProjects.isEmpty)
        XCTAssertNotNil(m.toast)
    }

    func testCancelImportDismisses() {
        let m = realModel()
        m.newTopOpt()
        XCTAssertTrue(m.importSheetPresented)
        m.cancelImport()
        XCTAssertFalse(m.importSheetPresented)
        XCTAssertEqual(m.screen, .home)
    }

    func testOpenRecentNavigatesAndRestoresProcess() {
        let m = realModel()
        m.loadMaterials()
        let proj = RecentProject(name: "Sensor Bracket", materialName: "Resin_Tough", process: .resin)
        m.open(proj)
        XCTAssertEqual(m.screen, .workspace)
        XCTAssertEqual(m.projectName, "Sensor Bracket")
        XCTAssertEqual(m.process, .resin)
        XCTAssertEqual(m.selectedResinMaterial, "Resin_Tough")
    }

    func testBackHomeReturnsToHome() {
        let m = realModel()
        m.loadMaterials()
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL))
        m.continueToWorkspace()
        XCTAssertEqual(m.screen, .workspace)
        m.backHome()
        XCTAssertEqual(m.screen, .home)
    }

    // MARK: SwiftUI screens compile & construct (values are what the logic tests pin)

    func testScreensInstantiate() {
        let m = realModel()
        m.loadMaterials()
        _ = RootView(model: m)
        _ = HomeView(model: m)
        _ = ImportSheet(model: m)
        let project = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                                   importedFile: nil, importedMesh: nil)
        _ = WorkspacePlaceholder(model: m, project: project)
    }

    // MARK: - Project deletion (Home / Library card)

    /// Import two projects, then delete one from Home: it leaves the recents grid and
    /// its whole on-disk folder (snapshot + copied model + any results) is erased; the
    /// other project is untouched.
    func testDeleteRemovesProjectFromRecentsAndDisk() throws {
        let store = ProjectStore(rootDir: tempDir)
        let m = AppModel(materialsPath: Self.materialsPath, store: store)
        m.loadMaterials()

        m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "A.stl"))
        m.continueToWorkspace()
        let idA = try XCTUnwrap(m.project?.id)
        m.backHome()

        m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "B.stl"))
        m.continueToWorkspace()
        let idB = try XCTUnwrap(m.project?.id)
        m.backHome()

        XCTAssertEqual(m.recentProjects.count, 2)
        XCTAssertNotNil(store.snapshot(id: idA))

        m.deleteProject(id: idA)

        XCTAssertEqual(m.recentProjects.count, 1)
        XCTAssertFalse(m.recentProjects.contains { $0.id == idA })
        XCTAssertTrue(m.recentProjects.contains { $0.id == idB })
        XCTAssertNil(store.snapshot(id: idA), "the on-disk snapshot is erased")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(idA.uuidString).path),
            "the whole project folder (snapshot + model + results) is removed")
        XCTAssertNotNil(store.snapshot(id: idB), "the other project is untouched")
    }

    /// Deleting the project that's currently open returns to Home and clears it.
    func testDeleteOpenProjectReturnsHome() throws {
        let m = realModel()
        m.loadMaterials()
        m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Open.stl"))
        m.continueToWorkspace()
        let id = try XCTUnwrap(m.project?.id)
        XCTAssertEqual(m.screen, .workspace)

        m.deleteProject(id: id)

        XCTAssertEqual(m.screen, .home)
        XCTAssertNil(m.project, "the open project is cleared")
        XCTAssertFalse(m.printParamsSheetPresented, "any open sheet is dismissed")
        XCTAssertTrue(m.recentProjects.isEmpty)
    }

    /// A restored project's persisted results are gone after deletion: a fresh
    /// AppModel over the same store no longer lists it.
    func testDeletePersistsAcrossRelaunch() throws {
        let m1 = AppModel(materialsPath: Self.materialsPath, store: ProjectStore(rootDir: tempDir))
        m1.loadMaterials()
        m1.newTopOpt(); m1.selectMaterial("PLA")
        XCTAssertTrue(m1.importFile(atPath: Self.cubeSTL, displayName: "Gone.stl"))
        m1.continueToWorkspace()
        let id = try XCTUnwrap(m1.project?.id)
        m1.backHome()

        // Relaunch, then delete an id that was NOT loaded live this launch (disk-only).
        let m2 = AppModel(materialsPath: Self.materialsPath, store: ProjectStore(rootDir: tempDir))
        XCTAssertTrue(m2.recentProjects.contains { $0.id == id })
        m2.deleteProject(id: id)
        XCTAssertFalse(m2.recentProjects.contains { $0.id == id })

        // A third launch confirms it's gone from disk (nothing to seed the grid).
        let m3 = AppModel(materialsPath: Self.materialsPath, store: ProjectStore(rootDir: tempDir))
        XCTAssertFalse(m3.recentProjects.contains { $0.id == id })
    }
}

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

    /// A model wired to the real committed materials.json + real bridge importer.
    private func realModel() -> AppModel {
        AppModel(materialsPath: Self.materialsPath)
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
                         materialsLoader: { _ in throw LoadFailure() })
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

    func testImportNonWatertightRejectedWithToast() {
        let m = realModel()
        let ok = m.importFile(atPath: Self.brokenSTL)
        XCTAssertFalse(ok)
        XCTAssertNil(m.importedFile)
        XCTAssertNotNil(m.toast)
        XCTAssertTrue(m.toast?.lowercased().contains("watertight") == true)
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
        _ = WorkspacePlaceholder(model: m)
    }
}

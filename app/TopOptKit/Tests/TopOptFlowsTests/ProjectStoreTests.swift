// Headless macOS tests for M7.x-persist-b: cross-launch project persistence.
// A ProjectStore writes each project (working-state snapshot + a copy of the
// imported model) to disk; a fresh AppModel over the same directory reloads the
// recents and restores the full setup on open. These drive that against a temp
// directory + the committed cube fixture through the real bridge importer.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ProjectStoreTests: XCTestCase {

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
            .appendingPathComponent("topopt-persist-tests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func appModel(store: ProjectStore) -> AppModel {
        AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath, store: store)
    }

    // MARK: - snapshot Codable round-trip

    func testSnapshotCodableRoundTrip() throws {
        var selection = SelectionModel()
        let g = selection.addGroup()
        selection.pickFace(7)
        var force = ForceModel()
        force.setGravity(faceNormal: SIMD3<Float>(0, 0, -1), face: 2)
        force.makeLoad(g)
        force.setWeight(g, kg: 3.5)
        force.unit = .lbs

        let snap = ProjectSnapshot(id: UUID(), name: "Bracket", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "Bracket.stl",
                                   savedAt: Date(timeIntervalSince1970: 1000),
                                   selection: selection, force: force)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.force.kind(for: g).weightKg, 3.5)
        XCTAssertTrue(back.force.gravityIsSet)
        XCTAssertEqual(back.selection.groups.count, 1)
    }

    // MARK: - store save / load / model copy

    func testStoreSavesSnapshotAndCopiesModel() throws {
        let store = ProjectStore(rootDir: tempDir)
        let id = UUID()
        let snap = ProjectSnapshot(id: id, name: "Cube", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "cube.stl",
                                   savedAt: Date(timeIntervalSince1970: 5),
                                   selection: SelectionModel(), force: ForceModel())
        try store.save(snap, modelSource: URL(fileURLWithPath: Self.cubeSTL))

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.modelPath(id: id, fileName: "model.stl")))
        XCTAssertEqual(store.snapshot(id: id), snap)
        XCTAssertEqual(store.loadAllSnapshots().map(\.id), [id])
    }

    func testStoreSkipsNewerSchema() throws {
        let store = ProjectStore(rootDir: tempDir)
        var snap = ProjectSnapshot(id: UUID(), name: "X", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "x.stl",
                                   savedAt: Date(), selection: SelectionModel(), force: ForceModel())
        snap.schemaVersion = ProjectSnapshot.currentSchema + 1
        try store.save(snap, modelSource: URL(fileURLWithPath: Self.cubeSTL))
        XCTAssertNil(store.snapshot(id: snap.id), "a newer schema is skipped, not force-decoded")
        XCTAssertTrue(store.loadAllSnapshots().isEmpty)
    }

    // MARK: - the payoff: state survives a fresh AppModel (relaunch)

    func testProjectSurvivesAppRelaunch() throws {
        // Launch 1: import, set up a load case, leave to Home (autosave).
        let m1 = appModel(store: ProjectStore(rootDir: tempDir))
        m1.loadMaterials(); m1.newTopOpt(); m1.selectMaterial("PLA")
        XCTAssertTrue(m1.importFile(atPath: Self.cubeSTL, displayName: "Wall_Bracket.stl"))
        m1.continueToWorkspace()
        let project1 = try XCTUnwrap(m1.project)
        project1.force.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 4)
        let anchor = project1.selection.addGroup()
        project1.selection.pickFace(11)
        project1.force.makeAnchor(anchor)
        let load = project1.selection.addGroup()
        project1.selection.pickFace(22)
        project1.force.makeLoad(load)
        project1.force.setWeight(load, kg: 6.0)
        m1.backHome()   // autosave

        // Launch 2: a brand-new AppModel over the same directory.
        let m2 = appModel(store: ProjectStore(rootDir: tempDir))
        XCTAssertEqual(m2.recentProjects.count, 1, "recents reloaded from disk")
        let recent = try XCTUnwrap(m2.recentProjects.first)
        XCTAssertEqual(recent.name, "Wall Bracket")

        m2.open(recent)
        let restored = try XCTUnwrap(m2.project)
        XCTAssertFalse(restored === project1, "a fresh launch rebuilds from disk, not the live instance")
        XCTAssertEqual(restored.material, "PLA")
        XCTAssertNotNil(restored.viewerMesh, "the model was re-imported from the store copy")
        XCTAssertTrue(restored.force.gravityIsSet)
        XCTAssertEqual(restored.selection.groups.count, 2)
        XCTAssertTrue(restored.force.kind(for: anchor).isAnchor)
        XCTAssertEqual(restored.force.kind(for: load).weightKg, 6.0)
    }

    func testUnknownRecentWithNoDiskOpensEmpty() throws {
        // A recents entry with nothing on disk (should not happen, but be robust):
        // opens an empty workspace rather than failing.
        let m = appModel(store: ProjectStore(rootDir: tempDir))
        let ghost = RecentProject(name: "Ghost", materialName: "PETG", process: .fdm)
        m.open(ghost)
        let project = try XCTUnwrap(m.project)
        XCTAssertNil(project.viewerMesh)
        XCTAssertEqual(project.material, "PETG")
    }
}

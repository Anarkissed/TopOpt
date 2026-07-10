// Headless macOS tests for M7.x-persist-a: the workspace's working state
// (mesh + selection groups + force/gravity + run) now lives in a ProjectModel
// OWNED by AppModel, so it survives navigating away from the workspace and back.
// These drive that persistence through the real AppModel + committed fixtures.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ProjectModelTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/settings/rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }

    /// Isolated per-test store so persist-b writes never touch Application Support.
    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-projectmodel-tests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Import a model + open a workspace project, returning (model, project, recent).
    private func openedProject() throws -> (AppModel, ProjectModel, RecentProject) {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                         store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Bracket.stl"))
        m.continueToWorkspace()
        let project = try XCTUnwrap(m.project)
        let recent = try XCTUnwrap(m.recentProjects.first)
        return (m, project, recent)
    }

    // MARK: - the bug: state must survive navigation

    func testWorkspaceStateSurvivesHomeAndBack() throws {
        let (m, project, recent) = try openedProject()

        // Simulate a workspace setup: gravity + an anchor group + a load group.
        project.force.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 1)
        let anchor = project.selection.addGroup()
        project.selection.pickFace(10)
        project.force.makeAnchor(anchor)
        let load = project.selection.addGroup()
        project.selection.pickFace(20)
        project.force.makeLoad(load)
        project.force.setWeight(load, kg: 4.2)

        // Leave the workspace for Home, then reopen the project from the recents grid.
        m.backHome()
        XCTAssertEqual(m.screen, .home)
        m.open(recent)
        XCTAssertEqual(m.screen, .workspace)

        let restored = try XCTUnwrap(m.project)
        XCTAssertTrue(restored === project, "the exact same ProjectModel is restored")
        XCTAssertTrue(restored.force.gravityIsSet, "gravity survived")
        XCTAssertEqual(restored.selection.groups.count, 2, "both groups survived")
        XCTAssertTrue(restored.force.kind(for: anchor).isAnchor)
        XCTAssertTrue(restored.force.kind(for: load).isLoad)
        XCTAssertEqual(restored.selection.groups.map(\.id).sorted(by: { $0.uuidString < $1.uuidString }),
                       [anchor, load].sorted(by: { $0.uuidString < $1.uuidString }))
    }

    func testNewImportStartsAFreshEmptyProject() throws {
        let (m, first, _) = try openedProject()
        first.force.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 1)
        _ = first.selection.addGroup()

        // A brand-new import → a distinct project with empty state.
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Other.stl"))
        m.continueToWorkspace()
        let second = try XCTUnwrap(m.project)

        XCTAssertFalse(second === first, "a new import is a new project")
        XCTAssertFalse(second.force.gravityIsSet, "fresh project has no gravity")
        XCTAssertTrue(second.selection.groups.isEmpty, "fresh project has no groups")
        // The first project is still intact in the recents grid.
        XCTAssertTrue(first.force.gravityIsSet)
    }

    // MARK: - project construction

    func testProjectBuildsViewerMeshFromImport() throws {
        let (_, project, _) = try openedProject()
        XCTAssertNotNil(project.viewerMesh, "the render mesh is built from the import at project creation")
        XCTAssertEqual(project.material, "PLA")
        XCTAssertEqual(project.importedFile?.name, "Bracket.stl")
    }

    func testMakeRunRequestReadsFromProject() throws {
        let (m, _, _) = try openedProject()
        let req = try XCTUnwrap(m.makeRunRequest(resolution: 32))
        XCTAssertEqual(req.material, "PLA")
        XCTAssertEqual(req.resolution, 32)
        XCTAssertEqual(req.projectName, "Bracket")   // extension dropped
        XCTAssertTrue(req.modelPath.hasSuffix("cube_10mm.stl"))
    }

    func testLegacyRecentWithoutLiveProjectOpensEmpty() throws {
        // A recent not created this launch (no live project) opens an empty
        // workspace for its material — the seam M7.x-persist-b will fill from disk.
        let m = AppModel(materialsPath: Self.materialsPath, store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        let recent = RecentProject(name: "From Last Launch", materialName: "PETG", process: .fdm)
        m.open(recent)
        let project = try XCTUnwrap(m.project)
        XCTAssertEqual(project.material, "PETG")
        XCTAssertNil(project.importedMesh)
        XCTAssertNil(project.viewerMesh)
    }
}

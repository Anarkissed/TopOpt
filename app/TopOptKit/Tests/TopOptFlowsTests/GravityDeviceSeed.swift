// GravityDeviceSeed — a DEV-ONLY helper (not a real assertion) used to seed the
// maintainer's bracket as a persisted project directly into a running iOS Simulator's app
// container, so the round-2 gravity widget can be exercised on-device (BAR V8) without the
// document picker (which does not present in this headless-driven simulator).
//
// It runs ONLY when TOPOPT_SEED_DIR points at the app's ProjectStore root
// (…/Library/Application Support/TopOpt/Projects); otherwise it early-returns. It reuses the
// SAME AppModel import + persist path the app uses, so the seeded project.json + copied STL
// are byte-for-byte what a real import would write.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class GravityDeviceSeed: XCTestCase {
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }

    func testSeedBracketIntoSimulatorIfRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["TOPOPT_SEED_DIR"] else {
            throw XCTSkip("set TOPOPT_SEED_DIR to seed a device project")
        }
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                         rulesPath: Self.core("src/settings/rules.json"),
                         store: ProjectStore(rootDir: root))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.core("tests/fixtures/mesh/WallMount_ShelfBracket.stl"),
                                   displayName: "WallMount_ShelfBracket.stl"))
        m.continueToWorkspace()
        let project = try XCTUnwrap(m.project)
        project.name = "Wall Bracket (round2)"
        m.persistCurrentProject()
        print("SEEDED project \(project.id) into \(root.path)")
    }
}

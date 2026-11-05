import XCTest
@testable import TopOptFlows

/// The app writes a model's sidecars (`ProjectStore.sidecarSuffixes`: `.faces`, `.clearances.json`) BESIDE the imported
/// file, so a test that imports a tracked fixture in place and then persists (an Undo's restore, a manual primitive's
/// edit) writes into core/tests/fixtures. Seen 2026-11-05: an untracked `cube_10mm.stl.clearances.json` (one group's
/// bolt at 5,5,5) after runs with LatticeStageTests, whose Undo tests persist the bolt its cube carries.
/// A test that edits a project imports `fixtureCopy(_:)`; `FixtureSidecars.strays()` says whether any sidecar is left.
enum FixtureSidecars {
    static let fixturesDir: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core/tests/fixtures", isDirectory: true)
    }()

    /// Every app sidecar under `dir`, as paths relative to it, sorted — empty when clean.
    static func strays(in dir: URL = fixturesDir) -> [String] {
        guard let all = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        return all.compactMap { $0 as? String }
            .filter { p in ProjectStore.sidecarSuffixes.contains { p.hasSuffix($0) } }
            .sorted()
    }
}

extension XCTestCase {
    /// A copy of core/tests/fixtures/`rel` in a fresh temporary folder (removed at teardown), under the SAME file name —
    /// a job names its model by the last path component, so the job bytes do not move. Import this, never the fixture.
    func fixtureCopy(_ rel: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent((rel as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: FixtureSidecars.fixturesDir.appendingPathComponent(rel), to: copy)
        return copy.path
    }
}

/// The run leaves core/tests/fixtures as checked in.
final class FixtureSidecarTests: XCTestCase {

    /// A class that imports a fixture in place and persists leaves its sidecar here (this test then fails in every later
    /// run until the file is deleted and the writer imports a `fixtureCopy`).
    func testNoSidecarSitsBesideAFixture() {
        XCTAssertEqual(FixtureSidecars.strays(), [], "a sidecar beside a fixture: delete it, and import fixtureCopy(_:) in its writer")
    }

    /// POSITIVE CONTROL: the guard sees both sidecars, nested too, and not the model beside them.
    func testTheGuardSeesASidecar() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-fixture-guard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("stl"), withIntermediateDirectories: true)
        for name in ["stl/cube_10mm.stl", "stl/cube_10mm.stl.clearances.json", "stl/cube_10mm.stl.faces"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(FixtureSidecars.strays(in: dir), ["stl/cube_10mm.stl.clearances.json", "stl/cube_10mm.stl.faces"])
    }
}

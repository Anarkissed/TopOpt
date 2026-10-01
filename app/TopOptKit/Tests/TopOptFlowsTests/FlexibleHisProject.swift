// FlexibleHisProject — HIS project, restored the way the APP restores it (task
// 2026-09-29-flexible-screens, round 3; memory: "judge with HIS project restored, not a
// hand-built scene").
//
// ★ WHICH PROJECT. 'Pad split top (Flexible)' (A1000001-…-0004): the 100 × 100 × 20 pad,
// its top split at x = 50 into 'top A' (FaceRegion 103, x ≥ 50) and 'top B' (104), the
// main page's groups (bottom = face 0 anchor, Top = region 103 loaded 10 kg under gravity,
// sides = faces 4 and 2) and the Flexible faces he tapped (top A, top B, 3, 5 loaded; 0, 2,
// 4 resting). A copy of the simulator's folder is committed beside the evidence, so every
// run restores the SAME bytes; HIS_PROJECT_DIR points it at another copy (the live one).
//
// ★ HOW. `AppModel` + `ProjectStore` over a copy of the folder, `open(recent)` — the
// app's own restore — then a `FlexibleStageModel` over the restored project with the
// repo's catalogue, its scene opened and its stacks built exactly as the page does.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
enum FlexibleHisProject {

    nonisolated static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["HIS_PROJECT_DIR"] { return URL(fileURLWithPath: d) }
        return repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/his_project_0004")
    }

    struct Restored {
        let app: AppModel
        let project: ProjectModel
        let root: URL
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// ★ BATCH G VERIFICATION: his project as he left it for round 5 (his screenshots r5_16…r5_21):
    /// copied from the simulator's store (saved 2026-09-30 16:52) — 'Pad split top', stamps on Top A,
    /// Face 3 (Group 2) and Face 5 (a 10 kg thumb, Group 1).
    static var round5Dir: URL {
        repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/his_project_0004_r5")
    }

    /// His folder under a store of our own, opened through `AppModel.open` (`source`: another copy).
    static func restore(_ source: URL? = nil) throws -> Restored {
        let src = source ?? dir
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("his-flexible-\(UUID().uuidString)", isDirectory: true)
        let pdir = root.appendingPathComponent(snap.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        for f in try FileManager.default.contentsOfDirectory(atPath: src.path) {
            try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: pdir.appendingPathComponent(f))
        }
        let core = repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                           rulesPath: core.appendingPathComponent("src/settings/rules.json").path,
                           store: ProjectStore(rootDir: root))
        app.loadMaterials()
        let recent = try XCTUnwrap(app.recentProjects.first { $0.id == snap.id })
        app.open(recent)
        let pm = try XCTUnwrap(app.project)
        XCTAssertNotNil(pm.viewerMesh, "his part must restore")
        return Restored(app: app, project: pm, root: root)
    }

    static var materialsPath: String { repoRoot.appendingPathComponent("core/src/materials/flexible_materials.json").path }
    static var stampsPath: String { repoRoot.appendingPathComponent("docs/design/flexibles/data/stamps.json").path }

    /// A Flexible stage model over `project`, its scene open and every loaded face's stack
    /// and geometry built (the page's own pipeline). Waits up to `timeout` seconds.
    /// `test` gets a teardown that waits until nothing is still inside core (a bridge call
    /// running past the test's end crashed the process at exit).
    static func openedModel(_ project: ProjectModel, test: XCTestCase, timeout: Double = 60) async throws -> FlexibleStageModel {
        let m = FlexibleStageModel(project: project, materialsPath: materialsPath, stampsPath: stampsPath, persist: {})
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await waitFor(timeout, "the scene and every loaded stack") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
        }
        return m
    }

    static func waitFor(_ timeout: Double, _ what: String, _ cond: () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// C1's plain pad (100 × 100 × 20, pseudo-faces) as a project the Flexible model can
    /// open: the same STL his project uses, with no groups and no split.
    static func padProject(_ flexible: FlexibleStageSettings) throws -> ProjectModel {
        let path = repoRoot.appendingPathComponent(
            "docs/handoffs/evidence/2026-09-28-flexible-squish-maths/a_pad_centre_soft/pad_100x100x20.stl").path
        let m = try TopOptKit.importMesh(path: path)
        let file = ImportedFile(name: "pad_100x100x20.stl", path: path, triangleCount: m.triangleCount,
                                faceCount: m.faceCount, watertight: m.watertight, pseudoFaces: m.pseudoFaces)
        let pm = ProjectModel(id: UUID(), name: "pad", material: "ABS", process: .fdm, importedFile: file, importedMesh: m)
        pm.lattice.flexible = flexible
        return pm
    }

    /// The pad's top face id (its triangles sit at z = 20).
    static func topFace(_ mesh: ViewerMesh) -> Int {
        for t in 0..<mesh.triangleCount {
            let z = (0..<3).map { mesh.positions[Int(mesh.indices[3 * t + $0]) * 3 + 2] }
            if z.allSatisfy({ abs($0 - 20) < 1e-3 }) { return Int(mesh.faceIDs[t]) }
        }
        return -1
    }

    /// The region id of 'top A' / 'top B' in his project (sector ids).
    nonisolated static let topA = FlexibleRegions.sectorBase + 103
    nonisolated static let topB = FlexibleRegions.sectorBase + 104
}

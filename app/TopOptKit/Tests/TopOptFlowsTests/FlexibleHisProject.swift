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

    /// His folder under a store of our own, opened through `AppModel.open`.
    static func restore() throws -> Restored {
        let src = dir
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
    static func openedModel(_ project: ProjectModel, timeout: Double = 60) async throws -> FlexibleStageModel {
        let m = FlexibleStageModel(project: project, materialsPath: materialsPath, stampsPath: stampsPath, persist: {})
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

    /// The region id of 'top A' / 'top B' in his project (sector ids).
    nonisolated static let topA = FlexibleRegions.sectorBase + 103
    nonisolated static let topB = FlexibleRegions.sectorBase + 104
}

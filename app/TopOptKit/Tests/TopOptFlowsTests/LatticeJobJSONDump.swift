import XCTest
import Foundation
@testable import TopOptFlows

/// ★ DUMP THE JOB DOCUMENT THE APP WOULD SUBMIT, for a project that exists on the
/// simulator. Instrumentation, run by hand:
///
///     TOPOPT_PROJECT_ROOT="…/Application Support/TopOpt/Projects" \
///     TOPOPT_PROJECT_ID=68BF7B74-3C2A-4ED6-A46D-AC040A9CA649 \
///     TOPOPT_JOB_OUT=/tmp/job.json \
///     swift test --filter LatticeJobJSONDump
///
/// There is no `job.json` on disk anywhere: the app builds the document in memory and
/// hands it to core, so the only honest way to produce one is to build it the way a
/// submit does — open the real project through `ProjectStore`, ask `AppModel` for the
/// request, and run `RemoteRun`'s own serializer. Re-authoring the JSON by hand is how
/// two front-ends drift, which is the mistake `makeLatticeRunRequest` exists to avoid.
@MainActor
final class LatticeJobJSONDump: XCTestCase {

    private static var repoRoot: URL {
        // …/app/TopOptKit/Tests/TopOptFlowsTests/<file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TopOptFlowsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TopOptKit
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
    }
    private static func core(_ rel: String) -> String {
        repoRoot.appendingPathComponent("core/\(rel)").path
    }

    func testDumpTheLatticeJobForARealProject() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["TOPOPT_PROJECT_ROOT"],
              let idStr = env["TOPOPT_PROJECT_ID"],
              let id = UUID(uuidString: idStr) else {
            throw XCTSkip("set TOPOPT_PROJECT_ROOT and TOPOPT_PROJECT_ID")
        }
        let out = env["TOPOPT_JOB_OUT"] ?? NSTemporaryDirectory() + "job.json"

        let store = ProjectStore(rootDir: URL(fileURLWithPath: root))
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                         rulesPath: Self.core("src/settings/rules.json"),
                         store: store)
        m.loadMaterials()
        guard let recent = m.recentProjects.first(where: { $0.id == id }) else {
            throw XCTSkip("no project \(idStr) under \(root); "
                          + "found \(m.recentProjects.map { $0.id.uuidString })")
        }
        m.open(recent)
        let snap = try XCTUnwrap(store.snapshot(id: id))
        let project = try XCTUnwrap(m.project, "project did not open")
        print("project: \(project.name)  model: \(snap.modelFileName)")

        let emitted = project.latticeJobRegions()
        let inc = emitted.regions.filter { $0.role == .include }
        print("lattice regions emitted: \(emitted.regions.count) "
              + "(include \(inc.count), skipped faces \(emitted.skippedFaces))")
        for r in emitted.regions {
            print(String(format: "   %@ kind=%@ face=%@ depth=%.2f mm "
                         + "normal=(%.2f,%.2f,%.2f) origin=(%.2f,%.2f,%.2f)",
                         "\(r.role)", "\(r.kind)", r.faceID.map(String.init) ?? "-",
                         r.depthMM, r.normal.x, r.normal.y, r.normal.z,
                         r.origin.x, r.origin.y, r.origin.z))
        }

        let request = try XCTUnwrap(m.makeLatticeRunRequest(),
                                    "makeLatticeRunRequest returned nil — "
                                    + "lattice not enabled, or not runnable-as-certified")
        let data = try RemoteRun.buildJobJSON(request)
        // Re-emit sorted + pretty so it is readable and diffable.
        let obj = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try pretty.write(to: URL(fileURLWithPath: out))
        print("job.json (\(pretty.count) bytes) -> \(out)")
        if let s = String(data: pretty, encoding: .utf8) { print(s) }
    }
}

// LatticeFileExportTests — the Export button (his go 2026-11-13; contract docs/design/lattice-rebuild/04-layout-file-job.md):
//   * the job carries EVERY setting the preview lays with (held to `Settings` itself: a field added later fails here), under the
//     bridge's names, the lists flattened, bars always on, the same bytes for the same settings;
//   * the report is read as core writes it;
//   * OPT-IN end to end: LATTICE_FILE_CLI = the worker's topopt-cli → the app's own job for core's cube is accepted by core's
//     strict job reader and makes a file; LATTICE_FILE_WORKER = host:port → the same through the real worker (health, upload,
//     poll, fetch).
//   * on the real Lattice Setup at the six windows: the Export button is drawn, 44 pt, inside the window, clear of the lines;
//     with no Mac chosen, a tap says so in one line.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeFileExportTests: XCTestCase {

    static func sample() -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        s.algorithm = "stepped"
        s.regions = [.init(id: 1, faces: [20], depthMM: 16.3, expandMM: -1.375), .init(id: 2, noLattice: true, faces: [7, 8], depthMM: 2.5)]
        s.protect = [.init(id: 3, faces: [13, 14, 15], depthMM: 1)]
        s.regionDials = [(region: 1, dial: 0.3)]
        s.perRegion = true
        s.smallCellsInThinWalls = true
        s.skin = true
        return s
    }

    func testTheJobCarriesEverySettingUnderTheBridgesNames() throws {
        let labels = Set(Mirror(reflecting: LatticeLayoutSession.Settings()).children.compactMap(\.label))
        XCTAssertEqual(labels, Set(LatticeFileJob.fieldKeys.keys), "★ every setting the preview lays with has its key in the job")
        let data = try LatticeFileJob.build(Self.sample(), modelName: "part.step")
        XCTAssertEqual(data, try LatticeFileJob.build(Self.sample(), modelName: "part.step"), "★ the same settings, the same bytes")
        let job = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(job["mode"] as? String, "lattice_file")
        XCTAssertEqual(job["output"] as? String, LatticeFileJob.outputName, "a bare file name")
        let l = try XCTUnwrap(job["layout"] as? [String: Any])
        XCTAssertEqual(l["bars"] as? Bool, true, "★ a file needs its struts")
        XCTAssertEqual(l["small_cells_in_thin_walls"] as? Bool, true)
        XCTAssertEqual(l["skin"] as? Bool, true)
        XCTAssertEqual(l["region_faces"] as? [Int], [20, 7, 8])
        XCTAssertEqual(l["region_face_counts"] as? [Int], [1, 2])
        XCTAssertEqual(l["region_no_lattice"] as? [Int], [0, 1])
        XCTAssertEqual(l["protect_faces"] as? [Int], [13, 14, 15])
        XCTAssertEqual(l["dial_region"] as? [Int], [1])
        XCTAssertEqual(l["dial_value"] as? [Double], [0.3])
        XCTAssertEqual(l["min_strut_lines"] as? Double, 2, "★ two lines")
    }

    func testTheReportIsReadAsCoreWritesIt() throws {
        let doc = #"{"ok": true, "code": "ok", "why": "", "layout": {"bars": 36}, "mesh": {"mm3": 452.9, "part_mm3": 1000},"#
            + #" "print_check": {"clean": true, "posts": [[1, 2, 0, 3]]}}"#
        let r = try XCTUnwrap(LatticeFileReport.parse(Data(doc.utf8)))
        XCTAssertEqual(r, LatticeFileReport(ok: true, why: "", bars: 36, plasticMM3: 452.9, partMM3: 1000, clean: true, posts: 1))
        XCTAssertEqual(r.line, "Print file ready · 36 bars · 45% of the solid part · layer check clean")
        let refused = try XCTUnwrap(LatticeFileReport.parse(Data(#"{"ok": false, "why": "Nothing to lattice"}"#.utf8)))
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.why, "Nothing to lattice")
    }

    /// Core's 10 mm STEP cube, the whole part latticed (copied to a scratch folder: the job's model is beside the job).
    func cubeJob() throws -> (dir: URL, job: Data, model: String) {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("cube.step").path
        try FileManager.default.copyItem(atPath: root.appendingPathComponent("core/tests/fixtures/step/cube.step").path, toPath: model)
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.cellMM = 5
        return (dir, try LatticeFileJob.build(s, modelName: "cube.step"), model)
    }

    /// ★ OPT-IN: the app's job is accepted by core's strict job reader and makes a file (the worker's own CLI).
    func testCoreAcceptsTheAppsJobAndMakesTheFile() throws {
        guard let cli = ProcessInfo.processInfo.environment["LATTICE_FILE_CLI"] else { throw XCTSkip("opt-in: LATTICE_FILE_CLI") }
        let (dir, job, _) = try cubeJob()
        try job.write(to: dir.appendingPathComponent("job.json"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["lattice-file", dir.appendingPathComponent("job.json").path, "--out", dir.appendingPathComponent("out").path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "★ core accepted the app's job")
        let r = try XCTUnwrap(LatticeFileReport.parse(try Data(contentsOf: dir.appendingPathComponent("out/\(LatticeFileJob.reportName)"))))
        print("LATTICE-FILE cube via the CLI: \(r.line)")
        XCTAssertTrue(r.ok)
        XCTAssertGreaterThan(r.bars, 0)
        XCTAssertGreaterThan((try Data(contentsOf: dir.appendingPathComponent("out/\(LatticeFileJob.outputName)"))).count, 84, "★ the file")
    }

    /// ★ OPT-IN: the same through the real worker on this Mac (health, upload, poll, fetch).
    func testTheWorkerMakesTheFile() throws {
        guard let hp = ProcessInfo.processInfo.environment["LATTICE_FILE_WORKER"], let colon = hp.lastIndex(of: ":"),
              let port = Int(hp[hp.index(after: colon)...]) else { throw XCTSkip("opt-in: LATTICE_FILE_WORKER=host:port") }
        let (_, job, model) = try cubeJob()
        let config = RemoteRunnerConfig(host: String(hp[..<colon]), port: port, expectedFingerprint: CoreFingerprint.value)
        let (stl, r) = try LatticeFileRun.drive(config: config, modelPath: model, jobJSON: job, projectName: "Export test cube")
        print("LATTICE-FILE cube via the worker: \(r.line), \(stl.count) bytes")
        XCTAssertTrue(r.ok)
        XCTAssertGreaterThan(stl.count, 84)
    }

    /// ★ On the real Lattice Setup, the switch on, at the six windows: the button is drawn, 44 pt, inside the window and clear of the
    /// lines; with no Mac chosen a tap says so in one line.
    func testTheExportButtonOnLatticeSetupAtTheSixWindows() throws {
        let settings = AppSettings.shared
        let was = settings.newEngineTest
        addTeardownBlock { @MainActor in AppSettings.shared.newEngineTest = was }
        for size in AppBuildHost.sweep {
            settings.newEngineTest = true
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            p.lattice.flexible = nil
            p.lattice.clearLatticeType()
            p.lattice.chooseLatticeType(.structural)
            p.lattice.enabled = true
            let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
            h.pump(3)
            try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
            h.pump(1.5)
            if h.frames.all["view-Lattice preview-on"] == nil { try h.tap("view-Lattice preview", "the lattice preview", settle: 1.5) }
            if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleSetup", "the page's Save", settle: 1.5) }
            let end = Date().addingTimeInterval(60)
            while h.frames.all["new-engine-export"] == nil, Date() < end { h.pump(0.5) }
            try h.probe("new-engine-export", "★ \(size): Export print file", covers: ["new-engine-lines"])
            try h.tap("new-engine-export", "Export print file", settle: 1)
            if h.frames.all["new-engine-export-failed"] != nil {
                _ = try h.onScreen("new-engine-export-failed", "★ \(size): no Mac chosen: said in one line")
            } else {
                _ = try h.onScreen("new-engine-export-making", "★ \(size): a Mac is chosen: making")
                try h.tap("new-engine-export-cancel", "Cancel", settle: 0.5)
            }
        }
    }
}
#endif

// HeadLossReproTests.swift — THE PRE-FIX REPRODUCTION for task
// 2026-08-03-variant-entry-gating-and-retention, bar AJ1.
//
// This file is written against HEAD's API ONLY (no type or method the fix adds),
// so it compiles and runs on the tree AS IT WAS, and both tests FAIL there. The
// shipped suite (VariantRetentionTests) asserts the same two facts on the fixed
// tree, where they pass.
//
// Mechanism 1 — RunModel.swift:999 (`start`) + RunModel.swift:1293 (`finish`).
// Mechanism 2 — AppModel.swift:915 (`persist`, `optimized: hasResults`) +
//               AppModel.swift:968 (`restoreFromDisk`, `snap.optimized == true`).

import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class HeadLossReproTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String {
        repoRoot.appendingPathComponent("core/\(rel)").path
    }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/materials/print_rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-headrepro-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func request() -> RunRequest {
        RunRequest(modelPath: Self.cubeSTL, material: "PLA",
                   materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                   resolution: 32, projectName: "Bracket")
    }

    private func variant(_ vf: Double) -> OptimizeVariant {
        OptimizeVariant(requestedVolumeFraction: vf, achievedVolumeFraction: vf,
                        massGrams: 41.2, supportVolumeVoxels: 0, meshTriangleCount: 12,
                        worstCaseMargin: 2.31, accepted: true, v3Passes: true,
                        minFeatureViolations: 0, minFeatureWarning: "",
                        meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
                        vonMisesField: [1, 2, 3, 4])
    }

    private func finished(_ n: Int = 2) -> OptimizeOutcome {
        OptimizeOutcome(variants: (0..<n).map { variant(0.8 - 0.2 * Double($0)) },
                        stoppedOnMargin: true, cancelled: false, acceptedCount: n,
                        gridNx: 2, gridNy: 2, gridNz: 1, spacing: 1,
                        computedRemotely: true)
    }

    /// MECHANISM 1. A run refused by the core's pre-flight — nothing imported,
    /// nothing voxelized, nothing solved — destroys the completed run's variants.
    func testHEAD_ARefusedRunDestroysTheCompletedRunsVariants() {
        let m = RunModel(scheduler: SynchronousRunScheduler(),
                         watchdog: DisabledRunWatchdog())
        m.restoreOutcome(finished())
        XCTAssertEqual(m.outcome?.variants.count, 2, "precondition: two finished variants")

        m.runner = { _, _, _ in
            throw TopOptError(message: "lattice certification does not support a "
                              + "design box (add-material) run")
        }
        m.start(request())

        XCTAssertEqual(m.phase, .failed)
        XCTAssertEqual(m.outcome?.variants.count, 2,
                       "AJ1 MECHANISM 1: a run that produced NOTHING must not take "
                       + "the finished run's variants with it")
    }

    /// MECHANISM 2. A save taken while the live run has no outcome writes
    /// `optimized: false` over a project whose results.plist is still on disk, and
    /// `restoreFromDisk` then never reads it again.
    func testHEAD_ASaveWithNoLiveOutcomeOrphansThePersistedResults() throws {
        let store = ProjectStore(rootDir: tempDir)
        let m1 = AppModel(materialsPath: Self.materialsPath, store: store)
        m1.loadMaterials()
        m1.newTopOpt(); m1.selectMaterial("PLA")
        m1.pickedFile(atPath: Self.cubeSTL, displayName: "cube.stl")
        XCTAssertTrue(m1.resolveUnits(.millimetres))
        m1.continueToWorkspace()
        let project = try XCTUnwrap(m1.project)
        let id = project.id

        project.run.restoreOutcome(finished())
        m1.persistCurrentProject()

        let resultsPath = store.resultsURL(id: id).path
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: resultsPath), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultsPath),
                      "precondition: the results blob landed")

        project.run.reset()          // a run that produced nothing leaves no outcome
        m1.persistCurrentProject()   // Home, or the app backgrounding

        let snap = try XCTUnwrap(store.snapshot(id: id))
        XCTAssertEqual(snap.optimized, true,
                       "AJ1 MECHANISM 2: the flag describes the DURABLE record. "
                       + "Written false over a live results.plist it orphans the "
                       + "file forever — restoreFromDisk only reads it when true")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultsPath),
                      "the blob itself survives — only the flag lost it")
    }
}

@MainActor
final class HeadRetentionNeverProducedTests: XCTestCase {

    /// MECHANISM 0 — why the maintainer hit the smoothing modal AT ALL. PR 274
    /// defined `RelatticeArtifacts`, persisted them and read them back, but at HEAD
    /// nothing in the app ever PRODUCES a pair from a live run: the only assignment
    /// to `ProjectModel.relatticeArtifacts` outside tests is the restore-from-disk
    /// path. So every run made in the app reported "kept no job document" forever,
    /// and both the smoothing page and "Lattice this variant" were unreachable for
    /// any result this app had actually produced.
    func testHEAD_NothingEverCapturesTheRetentionPairFromALiveRun() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }   // -> app/TopOptKit
        let sources = root.appendingPathComponent("Sources/TopOptFlows")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
        var writers: [String] = []
        for f in files where f.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(f),
                                  encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard !s.hasPrefix("//") else { continue }
                if s.contains("relatticeArtifacts =") || s.contains("relatticeArtifacts=") {
                    writers.append("\(f): \(s)")
                }
            }
        }
        XCTAssertTrue(writers.contains { !$0.contains("AppModel.swift") },
                      "MECHANISM 0: the ONLY writer of the retention pair is the "
                      + "restore-from-disk path in AppModel — nothing captures one "
                      + "from a live run, so PR 274's retention never engages. "
                      + "Writers found: \(writers)")
    }
}

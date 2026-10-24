// ProjectDuplicationTests.swift — Flexible (PR #362) round 9: Duplicate / Save as new project.
//
// A copy carries the SETUP (snapshot, model file, sidecars) and never the RESULTS
// (results.plist, run_job.json, run_design.bin) — a re-run in the copy starts clean.

import XCTest
@testable import TopOptFlows

final class ProjectDuplicationTests: XCTestCase {

    private var root: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-dup-tests-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: root)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A saved project with a model, a `.faces` sidecar and a full set of results.
    private func savedProjectWithResults() throws -> ProjectSnapshot {
        let src = root.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("part.stl")
        try Data("solid part".utf8).write(to: model)
        try Data("faces".utf8).write(to: URL(fileURLWithPath: model.path + ".faces"))
        let snap = ProjectSnapshot(id: UUID(), name: "Bracket", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "part.stl",
                                   savedAt: Date(timeIntervalSince1970: 5),
                                   selection: SelectionModel(), force: ForceModel(),
                                   optimized: true)
        try store.save(snap, modelSource: model)
        try store.saveResults(Data("results".utf8), id: snap.id)
        try store.saveRelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1, 2]), id: snap.id)
        return snap
    }

    func testTheCopyKeepsTheSetupAndDropsTheResults() throws {
        let src = try savedProjectWithResults()
        let copy = try store.duplicate(id: src.id, name: "Bracket copy",
                                       now: Date(timeIntervalSince1970: 9))
        XCTAssertNotEqual(copy.id, src.id)
        XCTAssertEqual(copy.name, "Bracket copy")
        XCTAssertNotEqual(copy.optimized, true)
        XCTAssertEqual(copy.savedAt, Date(timeIntervalSince1970: 9))
        XCTAssertEqual(copy.material, src.material)
        XCTAssertEqual(copy.selection, src.selection)
        XCTAssertEqual(copy.force, src.force)

        let fm = FileManager.default
        let model = store.modelPath(id: copy.id, fileName: copy.modelFileName)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: model)), Data("solid part".utf8))
        XCTAssertTrue(fm.fileExists(atPath: model + ".faces"), "the painted faces travel with the copy")
        XCTAssertFalse(store.hasPersistedResults(id: copy.id))
        XCTAssertNil(store.loadRelatticeArtifacts(id: copy.id))
        XCTAssertEqual(store.snapshot(id: copy.id), copy)
        // the original is untouched
        XCTAssertTrue(store.hasPersistedResults(id: src.id))
        XCTAssertEqual(store.snapshot(id: src.id), src)
    }

    func testAMissingProjectCannotBeDuplicated() {
        XCTAssertThrowsError(try store.duplicate(id: UUID(), name: "x", now: Date()))
    }

    func testCopyNamesNeverCollide() {
        XCTAssertEqual(ProjectDuplication.copyName(of: "Bracket", existing: ["Bracket"]), "Bracket copy")
        XCTAssertEqual(ProjectDuplication.copyName(of: "Bracket", existing: ["Bracket", "Bracket copy"]),
                       "Bracket copy 2")
        XCTAssertEqual(ProjectDuplication.copyName(of: "Bracket copy", existing: ["Bracket copy"]),
                       "Bracket copy 2", "a copy of a copy counts on, not 'copy copy'")
        XCTAssertEqual(ProjectDuplication.copyName(
            of: "Bracket copy 2", existing: ["Bracket copy", "Bracket copy 2", "Bracket copy 3"]),
            "Bracket copy 4")
    }

    func testTheLibraryEntryIsNotOptimized() throws {
        let src = try savedProjectWithResults()
        let copy = try store.duplicate(id: src.id, name: "Bracket copy", now: Date())
        let recent = ProjectDuplication.recent(for: copy)
        XCTAssertEqual(recent.id, copy.id)
        XCTAssertEqual(recent.name, "Bracket copy")
        XCTAssertEqual(recent.materialName, "PLA")
        XCTAssertFalse(recent.optimized)
    }
}

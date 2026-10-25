// LibraryGroupingTests.swift — the Library's first-launch grouping (approved mockup 2026-10-25, batch 1).
//
// The reviewer's bars: every existing project still opens with identical content; grouping then
// ungrouping is lossless; the migration moves or deletes NOTHING; copies are grouped by the model
// file's bytes and drop their old names (his decision 9).

import XCTest
import CryptoKit
@testable import TopOptFlows

@MainActor
final class LibraryGroupingTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static var materialsPath: String { repoRoot.appendingPathComponent("core/src/materials/materials.json").path }
    private static var cubeSTL: URL { repoRoot.appendingPathComponent("core/tests/fixtures/stl/cube_10mm.stl") }

    private var root: URL!
    private var store: ProjectStore!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("topopt-library-tests-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(rootDir: root)
    }
    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: fixtures

    /// Save a project whose model file holds `bytes` (or the real cube when nil), with a `.faces`
    /// sidecar, and — when `results` — a results blob and re-lattice artifacts.
    @discardableResult
    private func save(_ name: String, bytes: Data?, saved: TimeInterval, results: Bool,
                      quality: RunQuality = .fast) throws -> ProjectSnapshot {
        let src = root.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("part.stl")
        if let bytes { try bytes.write(to: model) } else { try fm.copyItem(at: Self.cubeSTL, to: model) }
        // a painted-faces sidecar travels with a stand-in model only: the real cube must re-import
        if bytes != nil { try Data("faces of \(name)".utf8).write(to: URL(fileURLWithPath: model.path + ".faces")) }
        let snap = ProjectSnapshot(id: UUID(), name: name, material: "PA12-CF", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "part.stl",
                                   savedAt: Date(timeIntervalSince1970: saved),
                                   selection: SelectionModel(), force: ForceModel(),
                                   quality: quality, optimized: results ? true : nil)
        try store.save(snap, modelSource: model)
        try fm.removeItem(at: src)
        if results {
            try store.saveResults(Data("results of \(name)".utf8), id: snap.id)
            try store.saveRelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1, 2, 3]), id: snap.id)
        }
        return snap
    }

    /// His five Carriage Arms copies (same model bytes; the last one never optimized) and two Pads
    /// whose model files differ.
    private func hisLibrary() throws -> (arms: [ProjectSnapshot], pad: ProjectSnapshot, pad2: ProjectSnapshot) {
        let armsBytes = Data("solid carriage arms".utf8)
        var arms: [ProjectSnapshot] = []
        // saved out of name order on purpose: the order is by date saved, never by name
        for (i, (n, t)) in [("Carriage Arms", 10.0), ("Carriage Arms copy", 20), ("Carriage Arms copy 3", 40),
                            ("Carriage Arms copy 2", 30), ("Carriage Arms copy 4", 50)].enumerated() {
            arms.append(try save(n, bytes: armsBytes, saved: t, results: i < 4))
        }
        let pad = try save("Pad", bytes: Data("solid pad".utf8), saved: 15, results: true)
        let pad2 = try save("Pad copy", bytes: Data("solid pad v2".utf8), saved: 25, results: false)
        return (arms, pad, pad2)
    }

    /// Every file under the root (but the index) → its bytes' hash, by relative path.
    private func tree(excludingIndex: Bool = true) throws -> [String: String] {
        var out: [String: String] = [:]
        // the enumerator reports /private/var/… for a /var/… root: compare resolved paths
        let base = root.resolvingSymlinksInPath().path
        let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in e where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let full = url.resolvingSymlinksInPath().path
            XCTAssertTrue(full.hasPrefix(base), full)
            let rel = String(full.dropFirst(base.count))
            if excludingIndex, rel == "/library.json" { continue }
            out[rel] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    private func groupedFromDisk() -> LibraryIndex {
        LibraryGrouping.group(store.loadAll().readable, hash: { self.store.modelHash(of: $0) })
    }

    // MARK: grouping

    func testCopiesWithTheSameModelBytesBecomeOnePartOldestFirst() throws {
        let lib = try hisLibrary()
        let index = groupedFromDisk()
        XCTAssertEqual(index.parts.count, 3, "Carriage Arms + two Pads whose model files differ")
        let arms = try XCTUnwrap(index.part(containing: lib.arms[0].id))
        XCTAssertEqual(arms.name, "Carriage Arms")
        // by date saved: copy 2 (30) comes before copy 3 (40) although it was created after it here
        XCTAssertEqual(arms.versions.map(\.folderID),
                       [lib.arms[0], lib.arms[1], lib.arms[3], lib.arms[2], lib.arms[4]].map(\.id))
        XCTAssertEqual(arms.versions.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(arms.versions.map(\.parentNumber), [nil, 1, 2, 3, 4])
        XCTAssertEqual(arms.modelHash, store.modelHash(of: lib.arms[0]))
    }

    func testGroupedCopiesDropTheirOldNames() throws {
        _ = try hisLibrary()
        let index = groupedFromDisk()
        XCTAssertTrue(index.parts.flatMap(\.versions).allSatisfy { $0.name == nil },
                      "his decision 9: no 'copy 4' — versions are told apart by number")
        XCTAssertEqual(Set(index.parts.map(\.name)), ["Carriage Arms", "Pad", "Pad 2"],
                       "a second part whose base name is taken is numbered, never called 'copy'")
    }

    func testSameNameButDifferentModelBytesStaySeparateParts() throws {
        let lib = try hisLibrary()
        let index = groupedFromDisk()
        XCTAssertNotEqual(index.part(containing: lib.pad.id)?.id, index.part(containing: lib.pad2.id)?.id)
    }

    func testAProjectWithoutResultsIsADraftNoProjectIsDropped() throws {
        let lib = try hisLibrary()
        let index = groupedFromDisk()
        let all = store.loadAll().readable
        XCTAssertEqual(Set(index.folderIDs), Set(all.map(\.id)), "every readable project is filed")
        XCTAssertEqual(index.folderIDs.count, all.count, "and filed once")
        let last = try XCTUnwrap(index.part(containing: lib.arms[4].id)?.version(folderID: lib.arms[4].id))
        XCTAssertTrue(LibraryGrouping.isDraft(store.snapshot(id: last.folderID)!), "copy 4 never ran: a draft")
    }

    func testAMissingModelFileIsAPartOfItsOwn() throws {
        let a = try save("Bracket", bytes: Data("x".utf8), saved: 1, results: true)
        let b = try save("Bracket copy", bytes: Data("x".utf8), saved: 2, results: true)
        try fm.removeItem(atPath: store.modelPath(id: b.id, fileName: b.modelFileName))
        let index = groupedFromDisk()
        XCTAssertEqual(index.parts.count, 2)
        XCTAssertNil(index.part(containing: b.id)?.modelHash)
        XCTAssertNotNil(index.part(containing: a.id)?.modelHash)
    }

    // MARK: the reviewer's bars

    func testGroupingThenUngroupingIsLosslessAndMovesNothing() throws {
        _ = try hisLibrary()
        let before = try tree()
        let index = try LibraryGrouping.groupAndSave(store: store)
        XCTAssertFalse(index.parts.isEmpty)
        XCTAssertEqual(try tree(), before, "grouping writes only library.json")
        XCTAssertNotNil(store.loadLibrary())
        store.ungroupLibrary()
        XCTAssertNil(store.loadLibrary())
        XCTAssertEqual(try tree(excludingIndex: false), before, "ungrouping leaves every byte as it was")
    }

    func testEveryProjectStillOpensWithIdenticalContentAfterGrouping() throws {
        var saved: [ProjectSnapshot] = []
        for (i, name) in ["Cube", "Cube copy", "Cube copy 2"].enumerated() {
            saved.append(try save(name, bytes: nil, saved: Double(i), results: false, quality: i == 2 ? .fine : .fast))
        }
        func openAll() -> [UUID: ProjectSnapshot] {
            let m = AppModel(materialsPath: Self.materialsPath, store: ProjectStore(rootDir: root))
            m.loadMaterials()
            var out: [UUID: ProjectSnapshot] = [:]
            for r in m.recentProjects {
                m.open(r)
                out[r.id] = m.project?.snapshot(savedAt: Date(timeIntervalSince1970: 0))
            }
            return out
        }
        let before = openAll()
        XCTAssertEqual(before.count, saved.count)
        XCTAssertTrue(before.values.allSatisfy { $0.modelFileName == "model.stl" }, "each one really re-imported")
        _ = try LibraryGrouping.groupAndSave(store: store)
        XCTAssertEqual(openAll(), before)
        for s in saved { XCTAssertEqual(store.snapshot(id: s.id), s) }
    }

    func testUnreadableProjectsStayListedAndUntouched() throws {
        _ = try hisLibrary()
        let bad = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: bad, withIntermediateDirectories: true)
        let junk = Data("{ not json".utf8)
        try junk.write(to: bad.appendingPathComponent("project.json"))
        let index = try LibraryGrouping.groupAndSave(store: store)
        XCTAssertFalse(index.folderIDs.contains(UUID(uuidString: bad.lastPathComponent)!))
        XCTAssertEqual(try Data(contentsOf: bad.appendingPathComponent("project.json")), junk)
        let m = AppModel(materialsPath: nil, store: store)
        XCTAssertEqual(m.unreadableProjects.map(\.id), [UUID(uuidString: bad.lastPathComponent)!],
                       "round 3 ruling (c) still holds after grouping")
    }

    // MARK: keeping the index honest

    func testReconcileFilesANewCopyAsTheNextVersionAndANewModelAsANewPart() throws {
        let lib = try hisLibrary()
        var index = groupedFromDisk()
        index.projects = [LibraryProject(name: "Squish Mechanism", partIDs: [index.part(containing: lib.arms[0].id)!.id])]
        let copy = try save("Carriage Arms copy 5", bytes: Data("solid carriage arms".utf8), saved: 60, results: false)
        let lid = try save("Carriage Lid", bytes: Data("solid lid".utf8), saved: 70, results: false)
        let r = LibraryGrouping.reconcile(index, with: store.loadAll().readable, hash: { self.store.modelHash(of: $0) })
        let arms = try XCTUnwrap(r.part(containing: copy.id))
        XCTAssertEqual(arms.id, index.part(containing: lib.arms[0].id)?.id)
        XCTAssertEqual(arms.version(folderID: copy.id)?.number, 6)
        XCTAssertEqual(arms.version(folderID: copy.id)?.parentNumber, 5)
        XCTAssertEqual(r.part(containing: lid.id)?.name, "Carriage Lid")
        XCTAssertEqual(r.parts.count, index.parts.count + 1)
        XCTAssertEqual(r.projects, index.projects, "his project folders are kept")
    }

    func testReconcileDropsADeletedFolderAndAnEmptyPart() throws {
        let lib = try hisLibrary()
        var index = groupedFromDisk()
        let padPart = index.part(containing: lib.pad.id)!.id
        index.projects = [LibraryProject(name: "Squish Mechanism", partIDs: [padPart])]
        store.delete(id: lib.arms[1].id)
        store.delete(id: lib.pad.id)
        let r = LibraryGrouping.reconcile(index, with: store.loadAll().readable, hash: { self.store.modelHash(of: $0) })
        XCTAssertNil(r.part(containing: lib.arms[1].id))
        XCTAssertEqual(r.part(containing: lib.arms[0].id)?.versions.map(\.number), [1, 3, 4, 5],
                       "numbers are never reused or shifted")
        XCTAssertFalse(r.parts.contains { $0.id == padPart })
        XCTAssertEqual(r.projects.first?.partIDs, [], "a project never points at a part that is gone")
    }

    func testReconcileWithNothingNewChangesNothing() throws {
        _ = try hisLibrary()
        let index = groupedFromDisk()
        XCTAssertEqual(LibraryGrouping.reconcile(index, with: store.loadAll().readable,
                                                 hash: { self.store.modelHash(of: $0) }), index)
    }

    // MARK: the index on disk

    func testTheIndexRoundTripsAndANewerOneIsNeverReadOrTouched() throws {
        let lib = try hisLibrary()
        var index = groupedFromDisk()
        var v = index.parts[0].versions[0]
        v.setMark(ResultMark(result: 0, stars: 4.5, printThis: true))
        v.pickedResult = 0
        index.parts[0].versions[0] = v
        try store.saveLibrary(index)
        XCTAssertEqual(store.loadLibrary(), index)
        XCTAssertNotNil(index.part(containing: lib.pad.id))

        let newer = Data(#"{"schemaVersion": 99, "projects": [], "parts": []}"#.utf8)
        try newer.write(to: store.libraryURL)
        XCTAssertNil(store.loadLibrary())
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), newer)
        XCTAssertEqual(store.loadAll().readable.count, 7, "library.json is never listed as a project")
    }

    func testStarsAreHalfStepsInsideZeroToFive() {
        XCTAssertEqual(ResultMark(result: 0, stars: 3.3).stars, 3.5)
        XCTAssertEqual(ResultMark(result: 0, stars: 3.2).stars, 3.0)
        XCTAssertEqual(ResultMark(result: 0, stars: 7).stars, 5)
        XCTAssertEqual(ResultMark(result: 0, stars: -1).stars, 0)
        XCTAssertEqual(ResultMark(result: 0, stars: .nan).stars, 0)
        var v = LibraryVersion(folderID: UUID(), number: 1)
        v.setMark(ResultMark(result: 1, rejected: true))
        XCTAssertTrue(v.mark(for: 1).rejected)
        v.setMark(ResultMark(result: 1))
        XCTAssertTrue(v.marks.isEmpty, "an empty mark is not kept")
        XCTAssertEqual([0, 1, 2].map(ResultMark.letter), ["a", "b", "c"])
    }
}

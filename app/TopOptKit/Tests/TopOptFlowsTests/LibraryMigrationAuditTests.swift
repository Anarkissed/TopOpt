// LibraryMigrationAuditTests.swift — an adversarial check of the Library migration (2026-10-25).
//
// The owner's rule: the first launch groups his project folders into parts and versions and moves,
// copies or deletes NOTHING; it writes one new file, library.json. Ungroup deletes it and every byte
// is as before. Every project stays listed and opens the same; an unreadable one stays "Can't open"
// and is never written.
//
// Every test asserts the BEHAVIOUR WANTED. A failing test here is a finding, not a broken fixture.

import XCTest
import CryptoKit
@testable import TopOptFlows

@MainActor
final class LibraryMigrationAuditTests: XCTestCase {

    private var base: URL!
    private var root: URL!
    private var outside: URL!
    private var store: ProjectStore!
    private var locked: [URL] = []
    private let fm = FileManager.default
    private let past = Date(timeIntervalSince1970: 1_600_000_000)

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("topopt-library-audit-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Projects", isDirectory: true)
        outside = base.appendingPathComponent("Outside", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        store = ProjectStore(rootDir: root)
    }
    override func tearDownWithError() throws {
        for u in locked { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
        if let base { try? fm.removeItem(at: base) }
    }

    // MARK: fixtures

    enum ModelKind { case file, symlink, directory, missing }

    @discardableResult
    private func project(_ name: String, bytes: Data, saved: TimeInterval, results: Bool = false,
                         kind: ModelKind = .file) throws -> ProjectSnapshot {
        let src = outside.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("part.stl")
        try bytes.write(to: model)
        try Data("faces of \(name)".utf8).write(to: URL(fileURLWithPath: model.path + ".faces"))
        try Data(#"{"deleted":[]}"#.utf8).write(to: URL(fileURLWithPath: model.path + ".clearances.json"))
        let snap = ProjectSnapshot(id: UUID(), name: name, material: "PA12-CF", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "part.stl",
                                   savedAt: Date(timeIntervalSince1970: saved),
                                   selection: SelectionModel(), force: ForceModel(),
                                   quality: .fast, optimized: results ? true : nil)
        try store.save(snap, modelSource: model)
        try fm.removeItem(at: src)
        if results {
            try store.saveResults(Data("results of \(name)".utf8), id: snap.id)
            try store.saveRelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1, 2, 3]), id: snap.id)
        }
        let m = URL(fileURLWithPath: store.modelPath(id: snap.id, fileName: snap.modelFileName))
        switch kind {
        case .file: break
        case .symlink:
            let target = outside.appendingPathComponent("linked-\(snap.id.uuidString).stl")
            try bytes.write(to: target)
            try fm.removeItem(at: m)
            try fm.createSymbolicLink(at: m, withDestinationURL: target)
        case .directory:
            try fm.removeItem(at: m)
            try fm.createDirectory(at: m, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: m.appendingPathComponent("x.stl"))
        case .missing:
            try fm.removeItem(at: m)
        }
        return snap
    }

    private func rawFolder(_ projectJSON: Data?) throws -> UUID {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let projectJSON { try projectJSON.write(to: dir.appendingPathComponent("project.json")) }
        return id
    }

    private func projectJSON(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("project.json")
    }

    /// Readable projects of every odd kind, unreadable ones of every kind, and strays at the root.
    private struct Zoo { var readable: [ProjectSnapshot] = []; var unreadable: [UUID] = []
                         var symlinked: ProjectSnapshot!; var dirModel: ProjectSnapshot!
                         var noModel: ProjectSnapshot!; var empty: ProjectSnapshot! }

    private func zoo() throws -> Zoo {
        var z = Zoo()
        let arm = Data("solid arm".utf8)
        z.readable.append(try project("Arm", bytes: arm, saved: 100, results: true))
        z.readable.append(try project("Arm copy", bytes: arm, saved: 100, results: true))   // same savedAt
        z.empty = try project("Empty", bytes: Data(), saved: 110)
        z.readable.append(z.empty)
        z.readable.append(try project("Also empty", bytes: Data(), saved: 111))
        var big = Data(count: 9 << 20)
        big.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] = UInt8(truncatingIfNeeded: (i &* 2654435761) >> 13) } }
        z.readable.append(try project("Binary", bytes: big, saved: 120, results: true))
        z.symlinked = try project("Linked", bytes: Data("solid linked".utf8), saved: 130, kind: .symlink)
        z.dirModel = try project("Dir model", bytes: Data("solid dir".utf8), saved: 140, kind: .directory)
        z.noModel = try project("No model", bytes: Data("solid gone".utf8), saved: 150, kind: .missing)
        z.readable += [z.symlinked, z.dirModel, z.noModel]
        let lockedOne = try project("Locked", bytes: Data("solid locked".utf8), saved: 160, results: true)
        z.readable.append(lockedOne)

        z.unreadable.append(try rawFolder(Data("{ not json".utf8)))
        z.unreadable.append(try rawFolder(nil))
        z.unreadable.append(try rawFolder(Data(#"{"schemaVersion": 99, "name": "From the future"}"#.utf8)))
        z.unreadable.append(try rawFolder(Data(#"{"schemaVersion": 1, "name": "Half"}"#.utf8)))
        let dirJSON = try rawFolder(nil)
        try fm.createDirectory(at: projectJSON(dirJSON), withIntermediateDirectories: true)
        z.unreadable.append(dirJSON)
        let fileNamedLikeAProject = UUID()
        try Data("not a folder".utf8).write(to: root.appendingPathComponent(fileNamedLikeAProject.uuidString))
        z.unreadable.append(fileNamedLikeAProject)

        try Data([0, 0, 0, 1]).write(to: root.appendingPathComponent(".DS_Store"))
        try Data("his notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        try fm.copyItem(at: projectJSON(z.readable[0].id), to: backups.appendingPathComponent("project.json"))

        try backdate()
        let lockedDir = root.appendingPathComponent(lockedOne.id.uuidString)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)
        locked.append(lockedDir)
        return z
    }

    /// Every entry's modification date → a fixed past date, so any write shows.
    private func backdate() throws {
        let paths = (fm.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
        for rel in paths.sorted(by: { $0.count > $1.count }) {
            let p = root.appendingPathComponent(rel).path
            let t = (try fm.attributesOfItem(atPath: p))[.type] as? FileAttributeType
            if t != .typeSymbolicLink { try fm.setAttributes([.modificationDate: past], ofItemAtPath: p) }
        }
    }

    private struct Entry: Equatable { let type: String; let size: Int; let perms: Int; let mtime: Double
                                      let inode: Int; let sha: String?; let link: String? }

    /// Every entry under the root, NOT following links: type, size, mode, mtime, inode, bytes, link.
    private func fullTree() throws -> [String: Entry] {
        var out: [String: Entry] = [:]
        for rel in (fm.enumerator(atPath: root.path)?.allObjects as? [String]) ?? [] {
            let p = root.appendingPathComponent(rel).path
            let a = try fm.attributesOfItem(atPath: p)
            let t = a[.type] as? FileAttributeType
            out[rel] = Entry(type: t?.rawValue ?? "?", size: (a[.size] as? NSNumber)?.intValue ?? -1,
                             perms: (a[.posixPermissions] as? NSNumber)?.intValue ?? -1,
                             mtime: (a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1,
                             inode: (a[.systemFileNumber] as? NSNumber)?.intValue ?? -1,
                             sha: t == .typeRegular ? SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: p)))
                                .map { String(format: "%02x", $0) }.joined() : nil,
                             link: t == .typeSymbolicLink ? try fm.destinationOfSymbolicLink(atPath: p) : nil)
        }
        return out
    }

    private func listing() -> (readable: [UUID: ProjectSnapshot], unreadable: [UUID: UnreadableProject]) {
        let all = store.loadAll()
        return (Dictionary(all.readable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                Dictionary(all.unreadable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    private func hash() -> (ProjectSnapshot) -> String? { { [store] in store!.modelHash(of: $0) } }
    private func exists() -> (UUID) -> Bool { { [store] in store!.folderExists($0) } }
    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: 1. nothing but library.json, byte for byte, mtime for mtime, inode for inode

    func testZooGroupThenUngroupTouchesNothingButLibraryJSON() throws {
        let z = try zoo()
        let before = try fullTree()
        let listedBefore = listing()
        XCTAssertEqual(listedBefore.readable.count, z.readable.count)
        XCTAssertEqual(Set(listedBefore.unreadable.keys), Set(z.unreadable))

        let index = try LibraryGrouping.groupAndSave(store: store)

        var after = try fullTree()
        XCTAssertNotNil(after.removeValue(forKey: "library.json"), "library.json was written")
        XCTAssertEqual(Set(after.keys), Set(before.keys), "no other entry was created or removed")
        for (k, v) in before where after[k] != v { XCTFail("\(k) changed: \(v) → \(String(describing: after[k]))") }
        let listedAfter = listing()
        XCTAssertEqual(listedAfter.readable, listedBefore.readable)
        XCTAssertEqual(listedAfter.unreadable, listedBefore.unreadable, "Can't open cards unchanged, dates included")

        XCTAssertEqual(Set(index.folderIDs), Set(z.readable.map(\.id)), "every readable project filed")
        XCTAssertEqual(index.folderIDs.count, z.readable.count, "and filed once")
        XCTAssertTrue(Set(index.folderIDs).isDisjoint(with: z.unreadable), "an unreadable one is never filed")
        XCTAssertEqual(Set(index.parts.map(\.name)).count, index.parts.count, "part names are never shared")
        XCTAssertEqual(store.modelHash(of: z.symlinked), sha(Data("solid linked".utf8)), "a link is read, never replaced")
        XCTAssertNil(store.modelHash(of: z.dirModel), "a directory model has no hash and no crash")
        XCTAssertNil(store.modelHash(of: z.noModel))
        XCTAssertEqual(store.modelHash(of: z.empty), sha(Data()))

        store.ungroupLibrary()
        XCTAssertEqual(try fullTree(), before, "ungroup: every byte, date and inode as before")
        XCTAssertEqual(listing().readable, listedBefore.readable)

        // positive control: the detector goes RED on a same-bytes rewrite of one project.json
        XCTAssertGreaterThan(before.count, 40, "the tree really was walked")
        let p = projectJSON(z.readable[0].id)
        try Data(contentsOf: p).write(to: p, options: .atomic)
        XCTAssertNotEqual(try fullTree(), before, "a rewrite with identical bytes is still seen")
    }

    // MARK: 2. the app's own Library listing

    func testAppModelListingIsIdenticalBeforeGroupedAndUngrouped() throws {
        _ = try zoo()
        let presets = PrintParamsPresetStore(rootDir: base.appendingPathComponent("Presets"))
        let suite = "topopt-library-audit-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        func listed() -> ([RecentProject], [UnreadableProject]) {
            let m = AppModel(materialsPath: nil, store: ProjectStore(rootDir: root), presetStore: presets,
                             remoteJobDefaults: UserDefaults(suiteName: suite)!)
            return (m.recentProjects.sorted { $0.id.uuidString < $1.id.uuidString },
                    m.unreadableProjects.sorted { $0.id.uuidString < $1.id.uuidString })
        }
        let before = listed()
        XCTAssertEqual(before.0.count, 9)
        XCTAssertEqual(before.1.count, 6)
        try LibraryGrouping.groupAndSave(store: store)
        let grouped = listed()
        XCTAssertEqual(grouped.0, before.0)
        XCTAssertEqual(grouped.1, before.1)
        store.ungroupLibrary()
        let ungrouped = listed()
        XCTAssertEqual(ungrouped.0, before.0)
        XCTAssertEqual(ungrouped.1, before.1)
    }

    // MARK: 3. an index already on disk

    func testGroupAndSaveLeavesANewerSchemaIndexUntouched() throws {
        try project("Arm", bytes: Data("solid arm".utf8), saved: 1)
        let newer = Data(#"{"schemaVersion": 2, "projects": [{"id":"X"}], "parts": [], "futureField": true}"#.utf8)
        try newer.write(to: store.libraryURL)
        XCTAssertNil(store.loadLibrary(), "a newer index is not read")
        _ = try? LibraryGrouping.groupAndSave(store: store)   // what a caller does when loadLibrary() is nil
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), newer,
                       "a newer app's index (his marks, folders) must never be overwritten by an older one")
    }

    func testGroupAndSaveRunTwiceKeepsHisMarksAndFolders() throws {
        let a = try project("Arm", bytes: Data("solid arm".utf8), saved: 1, results: true)
        try project("Arm copy", bytes: Data("solid arm".utf8), saved: 2)
        var index = try LibraryGrouping.groupAndSave(store: store)
        let part = try XCTUnwrap(index.part(containing: a.id))
        index.projects = [LibraryProject(name: "Squish Mechanism", partIDs: [part.id])]
        let p = try XCTUnwrap(index.parts.firstIndex { $0.id == part.id })
        index.parts[p].versions[0].setMark(ResultMark(result: 0, stars: 4.5, printThis: true))
        index.parts[p].versions[0].name = "The good one"
        try store.saveLibrary(index)
        let saved = try Data(contentsOf: store.libraryURL)
        _ = try LibraryGrouping.groupAndSave(store: store)    // a second "first launch"
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), saved, "grouping again must not wipe his Library")
    }

    func testCorruptOrForeignIndexesAreNeverRewrittenByReading() throws {
        let a = try project("Arm", bytes: Data("solid arm".utf8), saved: 1)
        let listed = listing()
        for bad in [Data("{ not json".utf8), Data(), Data([0xff, 0xfe, 0x00]),
                    Data(#"{"schemaVersion": "1", "projects": [], "parts": []}"#.utf8),
                    Data(#"{"projects": [], "parts": []}"#.utf8)] {
            try bad.write(to: store.libraryURL)
            XCTAssertNil(store.loadLibrary())
            XCTAssertEqual(try Data(contentsOf: store.libraryURL), bad)
            XCTAssertEqual(listing().readable, listed.readable, "a bad index never hides a project")
        }
        // an index that lists folders that do not exist: they are dropped, his real one is filed
        let ghost = LibraryIndex(parts: [LibraryPart(name: "Ghost", modelHash: "00",
                                                     versions: [LibraryVersion(folderID: UUID(), number: 1)])])
        let r = LibraryGrouping.reconcile(ghost, with: store.loadAll().readable, hash: hash(), exists: exists())
        XCTAssertEqual(r.folderIDs, [a.id])
    }

    // MARK: 4. a folder that is unreadable for a while (a bad write, a newer build, data protection)

    func testABrieflyUnreadableFolderKeepsItsNumberNameAndMarks() throws {
        let bytes = Data("solid arm".utf8)
        let v1 = try project("Arm", bytes: bytes, saved: 1, results: true)
        let v2 = try project("Arm copy", bytes: bytes, saved: 2, results: true)
        try project("Arm copy 2", bytes: bytes, saved: 3)
        var index = LibraryGrouping.group(store.loadAll().readable, hash: hash())
        let p = try XCTUnwrap(index.parts.firstIndex { $0.version(folderID: v1.id) != nil })
        let i = try XCTUnwrap(index.parts[p].versions.firstIndex { $0.folderID == v2.id })
        index.parts[p].versions[i].setMark(ResultMark(result: 1, stars: 5, printThis: true))
        index.parts[p].versions[i].name = "Stiff one"
        index.parts[p].versions[i].pickedResult = 1
        let kept = index.parts[p].versions[i]

        let good = try Data(contentsOf: projectJSON(v2.id))
        try Data("{ not json".utf8).write(to: projectJSON(v2.id))
        let whileBad = LibraryGrouping.reconcile(index, with: store.loadAll().readable, hash: hash(), exists: exists())
        XCTAssertEqual(whileBad.part(containing: v2.id)?.version(folderID: v2.id), kept,
                       "Can't open is not gone: its version stays filed")
        try good.write(to: projectJSON(v2.id))
        let again = LibraryGrouping.reconcile(whileBad, with: store.loadAll().readable, hash: hash(), exists: exists())
        XCTAssertEqual(again.part(containing: v2.id)?.version(folderID: v2.id), kept,
                       "readable again: same number, his name, his marks")
    }

    func testABrieflyUnreadableSoleVersionStaysInItsProjectFolder() throws {
        let pad = try project("Pad", bytes: Data("solid pad".utf8), saved: 1, results: true)
        var index = LibraryGrouping.group(store.loadAll().readable, hash: hash())
        let part = try XCTUnwrap(index.part(containing: pad.id))
        index.projects = [LibraryProject(name: "Squish Mechanism", partIDs: [part.id])]
        let good = try Data(contentsOf: projectJSON(pad.id))
        try Data(#"{"schemaVersion": 2}"#.utf8).write(to: projectJSON(pad.id))   // saved by a newer build
        let whileBad = LibraryGrouping.reconcile(index, with: store.loadAll().readable, hash: hash(), exists: exists())
        try good.write(to: projectJSON(pad.id))
        let again = LibraryGrouping.reconcile(whileBad, with: store.loadAll().readable, hash: hash(), exists: exists())
        XCTAssertEqual(again.projects.first?.partIDs, [part.id], "Pad is still in Squish Mechanism, not Unfiled")
    }

    func testReconcileAgainstAnEmptyListingKeepsTheIndex() throws {
        try project("Arm", bytes: Data("solid arm".utf8), saved: 1)
        try project("Pad", bytes: Data("solid pad".utf8), saved: 2)
        let index = LibraryGrouping.group(store.loadAll().readable, hash: hash())
        // loadAll returns ([], []) when the root cannot be listed (a transient error, before first unlock)
        let r = LibraryGrouping.reconcile(index, with: [], hash: hash(), exists: exists())
        XCTAssertEqual(r, index, "a failed listing must not empty his Library")
    }

    // MARK: 5. ids that appear twice

    func testAFolderWhoseProjectJSONNamesAnotherFolderIsNotFiledTwice() throws {
        let a = try project("Arm", bytes: Data("solid arm".utf8), saved: 1)
        // a hand-copied folder: new folder name, the original's project.json (same id inside)
        let copyDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.copyItem(at: root.appendingPathComponent(a.id.uuidString), to: copyDir)
        XCTAssertEqual(store.loadAll().readable.map(\.id), [a.id, a.id], "today's listing (pre-existing)")
        let index = LibraryGrouping.group(store.loadAll().readable, hash: hash())
        XCTAssertEqual(index.folderIDs.count, Set(index.folderIDs).count, "the index files a folder once each")
    }

    func testAnIndexListingAFolderTwiceIsRepairedByReconcile() throws {
        let a = try project("Arm", bytes: Data("solid arm".utf8), saved: 1)
        let twice = LibraryIndex(parts: [
            LibraryPart(name: "Arm", modelHash: store.modelHash(of: a), versions: [LibraryVersion(folderID: a.id, number: 1)]),
            LibraryPart(name: "Arm 2", modelHash: "00", versions: [LibraryVersion(folderID: a.id, number: 1)]),
        ])
        let r = LibraryGrouping.reconcile(twice, with: store.loadAll().readable, hash: hash(), exists: exists())
        XCTAssertEqual(r.folderIDs, [a.id], "one project, one card")
    }

    // MARK: 6. numbering and names

    func testDeletingTheNewestVersionNeverReusesItsNumber() throws {
        let bytes = Data("solid arm".utf8)
        try project("Arm", bytes: bytes, saved: 1)
        let v2 = try project("Arm copy", bytes: bytes, saved: 2)
        let index = LibraryGrouping.group(store.loadAll().readable, hash: hash())
        store.delete(id: v2.id)
        let dropped = LibraryGrouping.reconcile(index, with: store.loadAll().readable, hash: hash(), exists: exists())
        let v3 = try project("Arm copy 2", bytes: bytes, saved: 3)
        let r = LibraryGrouping.reconcile(dropped, with: store.loadAll().readable, hash: hash(), exists: exists())
        XCTAssertEqual(r.part(containing: v3.id)?.version(folderID: v3.id)?.number, 3,
                       "LibraryGrouping's own rule: version numbers are never reused")
    }

    func testIdenticalSavedAtGroupsTheSameWayEveryTime() throws {
        let bytes = Data("solid arm".utf8)
        for n in ["Arm", "Arm copy", "Arm copy 2", "Arm copy 3"] { try project(n, bytes: bytes, saved: 5) }
        let all = store.loadAll().readable
        let orders = (0..<6).map { _ in LibraryGrouping.group(all.shuffled(), hash: hash()).parts.map { $0.versions.map(\.folderID) } }
        XCTAssertEqual(Set(orders.map { "\($0)" }).count, 1)
    }

    func testOddCopyNamesNeverShareOrBreakAPartName() throws {
        let names = ["copy", " copy", "Pad copy copy", "Pad Copy", "copy of Pad", "Pad copy 2 copy 3",
                     "Pad copy 0", "Pad", "Pad 2", "Pad copy", "Pad 2 copy", "Pad\ncopy", "Pad copy 9999999999999999999999"]
        for (i, n) in names.enumerated() { try project(n, bytes: Data("model \(i)".utf8), saved: Double(i)) }
        let before = try fullTree()
        let index = try LibraryGrouping.groupAndSave(store: store)
        XCTAssertEqual(index.parts.count, names.count)
        XCTAssertEqual(Set(index.parts.map(\.name)).count, names.count, "never two parts with one name")
        var after = try fullTree(); after.removeValue(forKey: "library.json")
        XCTAssertEqual(after, before, "renaming in the index never renames a project")
    }

    /// Two projects he named apart, started from the same STL: same bytes ⇒ one part, and the second
    /// one's name is no longer shown anywhere (decision 9 drops "copy N" names; this is not one).
    func testADifferentlyNamedProjectFromTheSameModelKeepsItsName() throws {
        let bytes = Data("solid bracket".utf8)
        try project("Bracket stiff", bytes: bytes, saved: 1, results: true)
        let light = try project("Bracket light", bytes: bytes, saved: 2, results: true)
        let index = LibraryGrouping.group(store.loadAll().readable, hash: hash())
        let part = try XCTUnwrap(index.part(containing: light.id))
        let shown = part.version(folderID: light.id)?.name ?? (part.versions.count == 1 ? part.name : nil)
        XCTAssertEqual(shown, "Bracket light", "his own name, not 'Bracket stiff v2'")
    }
}

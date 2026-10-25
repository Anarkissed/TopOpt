import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ ROUND 3 RULING (c) (maintainer, 2026-10-01): project 102117B9 ("M2 verticalStand") was missing
/// from his list. Its one wall-thickness entry was saved, at 2026-09-21 22:43, by a build whose
/// `LatticeFaceWallThickness` wrote only {endMM, profile}. bc3cf67f (22:56) brought `startMM` back
/// as a stored field with synthesized decoding, which ignores the `= 0` default and threw
/// keyNotFound; the store turned that into nil and dropped the project silently.
/// Proof on a COPY of his project.json (`Fixtures/102117B9_project.json`) — never the live file.
@MainActor
final class UnreadableProjectTests: XCTestCase {

    static let hisID = UUID(uuidString: "102117B9-DDD2-4597-9BDE-49DD47EBF393")!
    static let wallKey = "f:820422E9-A2C0-4546-95C2-B1AD18E207DC:2"
    static var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }
    static var repoCore: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }
        return u.deletingLastPathComponent().appendingPathComponent("core")
    }

    private func sortedJSON<T: Encodable>(_ v: T) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(v), as: UTF8.self)
    }

    /// The saved shape decodes with the start at 0; ENCODING is unchanged, byte for byte.
    func testAWallSavedWithoutItsStartDecodesAtZero() throws {
        let saved = try JSONDecoder().decode(LatticeFaceWallThickness.self, from: Data(#"{"profile":{"ends":[0.5]}}"#.utf8))
        XCTAssertEqual(saved.startMM, 0, "★ absent ⇒ 0, where every wall started then")
        XCTAssertNil(saved.endMM)
        XCTAssertEqual(saved.profile?.ends, [0.5])
        // a present start is still read
        XCTAssertEqual(try JSONDecoder().decode(LatticeFaceWallThickness.self, from: Data(#"{"startMM":2.5}"#.utf8)).startMM, 2.5)
        // encoding stays synthesized: the strings this type wrote before the fix
        XCTAssertEqual(try sortedJSON(LatticeFaceWallThickness()), #"{"startMM":0}"#)
        XCTAssertEqual(try sortedJSON(LatticeFaceWallThickness(startMM: 2, endMM: 6)), #"{"endMM":6,"startMM":2}"#)
        for w in [LatticeFaceWallThickness(), LatticeFaceWallThickness(startMM: 1.5, endMM: 9),
                  LatticeFaceWallThickness(startMM: 0, endMM: nil, profile: saved.profile)] {
            XCTAssertEqual(try JSONDecoder().decode(LatticeFaceWallThickness.self, from: try JSONEncoder().encode(w)), w, "round trip")
        }
    }

    /// His project, decoded through the real snapshot decoder, and opened the way the app opens it.
    /// The walls it shows are the walls the file declares: Group C ("include") over its 15 faces —
    /// faces 2 and 15 at their own 12 and 11 mm, the rest at the group's 4 mm — and face 2's drawn
    /// profile, 43 columns, starting at the surface.
    func testHisProjectDecodesAndShowsTheSameWalls() throws {
        let fixture = Self.fixtures.appendingPathComponent("102117B9_project.json")
        let data = try Data(contentsOf: fixture)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        XCTAssertEqual(snap.id, Self.hisID)
        XCTAssertEqual(snap.name, "M2 verticalStand")
        let wall = try XCTUnwrap(snap.lattice?.wallThickness.faces[Self.wallKey])
        XCTAssertEqual(wall.startMM, 0, "★ the start his build never wrote")
        XCTAssertEqual(wall.profile?.ends.count, 43, "★ his drawn grade, intact")
        // the file's own declaration, read straight from the JSON (the oracle)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try XCTUnwrap((obj["selection"] as? [String: Any])?["groups"] as? [[String: Any]])
        let groupC = try XCTUnwrap(groups.first { ($0["id"] as? String)?.hasPrefix("820422E9") == true })
        let declared = Set(try XCTUnwrap(groupC["faces"] as? [Int]))
        XCTAssertEqual(declared.count, 15)

        // open a COPY through a temp store, with the stand's STEP (byte-identical to his model.step)
        let step = Self.fixtures.appendingPathComponent("M2_verticalStand.step")
        guard FileManager.default.fileExists(atPath: step.path) else { throw XCTSkip("stand STEP fixture absent") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(Self.hisID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: dir.appendingPathComponent("project.json"))
        try FileManager.default.copyItem(at: step, to: dir.appendingPathComponent("model.step"))
        let model = AppModel(materialsPath: Self.repoCore.appendingPathComponent("src/materials/materials.json").path,
                             rulesPath: Self.repoCore.appendingPathComponent("src/settings/rules.json").path,
                             store: ProjectStore(rootDir: root))
        model.loadMaterials()
        let recent = try XCTUnwrap(model.recentProjects.first { $0.id == Self.hisID }, "★ listed, not dropped")
        model.open(recent)
        let pm = try XCTUnwrap(model.project)
        XCTAssertNotNil(pm.viewerMesh, "the part opened")
        let emission = pm.latticeJobRegions()
        let faces = emission.regions.filter { $0.role == .include && $0.rawFaceID != nil }
        var byFace: [Int: (n: Int, depth: Double)] = [:]
        for r in faces { let f = Int(r.rawFaceID!); byFace[f] = ((byFace[f]?.n ?? 0) + 1, r.depthMM) }
        print("UNREADABLE-102117B9 emitted \(emission.regions.count) prism(s) over \(byFace.count) face(s): "
              + byFace.keys.sorted().map { "f\($0)×\(byFace[$0]!.n)@\(LatticeVariantProtectionTie.mm(byFace[$0]!.depth))" }
                .joined(separator: " ") + "; skippedFaces \(emission.skippedFaces)")
        XCTAssertEqual(emission.skippedFaces, 0, "every declared face has a shape to lattice")
        XCTAssertEqual(Set(faces.compactMap { $0.rawFaceID.map(Int.init) }), declared,
                       "★ the walls it shows are the walls the file declares")
        for r in faces where r.kind == .face {
            let expect: Double = r.rawFaceID == 2 ? 12 : r.rawFaceID == 15 ? 11 : 4
            XCTAssertEqual(r.depthMM, expect, accuracy: 1e-9, "face \(r.rawFaceID!) depth")
        }
    }
    /// "Every project currently in the store decodes; list them" — run on a COPY of the store
    /// (env TOPOPT_STORE_COPY = a folder of project folders), through the real snapshot decoder and
    /// the store itself. Never the live container.
    func testEveryProjectInTheStoreCopyDecodes() throws {
        guard let path = ProcessInfo.processInfo.environment["TOPOPT_STORE_COPY"] else {
            throw XCTSkip("set TOPOPT_STORE_COPY to a copy of the Projects folder")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let ids = try FileManager.default.contentsOfDirectory(atPath: root.path).compactMap(UUID.init(uuidString:)).sorted { $0.uuidString < $1.uuidString }
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            let data = try Data(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent("project.json"))
            do {
                let s = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
                print("STORE-DECODE \(id.uuidString.prefix(8)) OK  \"\(s.name)\" schema \(s.schemaVersion) saved \(s.savedAt)")
            } catch {
                XCTFail("\(id): \(error)")
                print("STORE-DECODE \(id.uuidString.prefix(8)) FAILS \(error)")
            }
        }
        XCTAssertEqual(Set(ProjectStore(rootDir: root).loadAllSnapshots().map(\.id)), Set(ids), "★ the store lists every one")
    }
    // MARK: fix 2 — the store never drops a project silently

    /// A folder of folders, each a different way a project can be unreadable, plus one readable.
    private func storeWithUnreadables() throws -> (root: URL, ids: [String: UUID]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unreadable-store-\(UUID().uuidString)", isDirectory: true)
        var ids: [String: UUID] = [:]
        let fixture = try Data(contentsOf: Self.fixtures.appendingPathComponent("102117B9_project.json"))
        func folder(_ key: String, _ data: Data?) throws {
            let id = key == "readable" ? Self.hisID : UUID()
            ids[key] = id
            let d = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            if let data { try data.write(to: d.appendingPathComponent("project.json")) }
        }
        try folder("readable", fixture)                                     // his, now readable
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        obj["material"] = nil
        try folder("missingKey", try JSONSerialization.data(withJSONObject: obj))
        try folder("notJSON", Data("{ this is not json".utf8))
        try folder("noFile", nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-project"), withIntermediateDirectories: true)
        return (root, ids)
    }

    private func fingerprint(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let u as URL in e where !u.hasDirectoryPath {
            out[u.path] = try Data(contentsOf: u)
        }
        return out
    }

    /// ★ Every UUID folder is listed: readable ones as projects, the rest as "Can’t open" with the
    /// reason. Reading writes NOTHING — every file is byte-identical after.
    func testTheStoreListsEveryProjectAndTouchesNothing() throws {
        let (root, ids) = try storeWithUnreadables()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try fingerprint(root)
        let all = ProjectStore(rootDir: root).loadAll()
        XCTAssertEqual(all.readable.map(\.id), [Self.hisID])
        let byID = Dictionary(uniqueKeysWithValues: all.unreadable.map { ($0.id, $0) })
        XCTAssertEqual(Set(byID.keys), Set([ids["missingKey"]!, ids["notJSON"]!, ids["noFile"]!]), "★ none dropped")
        XCTAssertEqual(byID[ids["missingKey"]!]?.reason, "“material” is missing")
        XCTAssertEqual(byID[ids["missingKey"]!]?.name, "M2 verticalStand", "its name, read from the file")
        XCTAssertEqual(byID[ids["notJSON"]!]?.reason, "project.json is not valid JSON")
        XCTAssertNil(byID[ids["notJSON"]!]?.name)
        XCTAssertEqual(byID[ids["noFile"]!]?.reason, "project.json is missing")
        XCTAssertEqual(try fingerprint(root), before, "★ never modified")
        XCTAssertEqual(ProjectStore(rootDir: root).loadAllSnapshots().map(\.id), [Self.hisID], "the readable list is as before")
        // the reason his own file gave before fix 1, in the same words
        let keyErr = DecodingError.keyNotFound(TestKey("startMM"), .init(
            codingPath: [TestKey("lattice"), TestKey("wallThickness"), TestKey("faces"), TestKey(Self.wallKey)],
            debugDescription: ""))
        XCTAssertEqual(ProjectReadFailure.reason(keyErr),
                       "“startMM” is missing in lattice › wallThickness › faces › f:820422E9-A2C0-4546-95C2-B1AD18E207DC:2")
    }

    /// ★ ROUND 3 REVIEW (2026-10-01): a deleted project never comes back. Results and re-lattice
    /// artifacts are written on a serial background queue; a write still queued when he deletes the
    /// project used to recreate its folder WITHOUT project.json — which fix 2 would now list as a
    /// "Can’t open" card nobody can remove. Forced deterministically: the queue is held, the writes
    /// are queued, the project is deleted, then the queue is released and drained.
    func testADeletedProjectsQueuedWritesNeverBringItBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootDir: root)
        let model = AppModel(materialsPath: Self.repoCore.appendingPathComponent("src/materials/materials.json").path,
                             rulesPath: Self.repoCore.appendingPathComponent("src/settings/rules.json").path, store: store)
        model.loadMaterials(); model.newTopOpt(); model.selectMaterial("PLA")
        XCTAssertTrue(model.importFile(atPath: Self.repoCore.appendingPathComponent("tests/fixtures/stl/cube_10mm.stl").path,
                                       displayName: "Race.stl"))
        model.continueToWorkspace()
        let pm = try XCTUnwrap(model.project)
        let id = pm.id
        let variant = OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 1,
                                      supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
                                      v3Passes: true, meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        pm.run.restoreOutcome(OptimizeOutcome(variants: [variant], stoppedOnMargin: false, cancelled: false, acceptedCount: 1))
        pm.relatticeArtifacts = RelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1, 2, 3]))
        XCTAssertTrue(pm.hasResults, "control: there are results to write")
        let dir = root.appendingPathComponent(id.uuidString)

        let gate = DispatchSemaphore(value: 0)
        AppModel.resultsQueue.async { gate.wait() }            // hold the serial queue
        model.persistCurrentProject()                           // results + artifacts queued behind it
        XCTAssertTrue(store.holdsProject(id: id), "control: saved")
        model.deleteProject(id: id)                             // the folder goes now
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        gate.signal()
        AppModel.resultsQueue.sync {}                           // drain every queued write
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "★ the queued writes did not bring it back")
        XCTAssertTrue(store.loadAll().unreadable.isEmpty, "★ no ghost Can’t open card")

        // the guard itself: a write aimed at a project that no longer exists creates nothing
        try store.saveRelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1]), id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "★ no folder without its project")
        var src = URL(fileURLWithPath: #filePath); for _ in 0..<3 { src.deleteLastPathComponent() }
        let app = try String(contentsOf: src.appendingPathComponent("Sources/TopOptFlows/AppModel.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("guard resultsStore.holdsProject(id: resultsID),"), "the results write checks first")
        XCTAssertTrue(app.contains("Self.resultsQueue.async { s.delete(id: id) }"), "and the delete runs again behind it")
    }

    /// ★ The app lists them apart from the projects it can open, and never deletes one.
    func testTheAppShowsThemButNeverOpensOrDeletesThem() throws {
        let (root, ids) = try storeWithUnreadables()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(materialsPath: nil, store: ProjectStore(rootDir: root))
        XCTAssertEqual(model.recentProjects.map(\.id), [Self.hisID])
        XCTAssertEqual(Set(model.unreadableProjects.map(\.id)), Set([ids["missingKey"]!, ids["notJSON"]!, ids["noFile"]!]))
        let before = try fingerprint(root)
        for u in model.unreadableProjects { model.deleteProject(id: u.id) }
        XCTAssertEqual(try fingerprint(root), before, "★ delete refuses an unreadable project: its file is never deleted")
        XCTAssertEqual(model.unreadableProjects.count, 3, "still listed")
        // Home: one card each, titled "Can’t open", with nothing to tap
        var src = URL(fileURLWithPath: #filePath); for _ in 0..<3 { src.deleteLastPathComponent() }
        let home = try String(contentsOf: src.appendingPathComponent("Sources/TopOptFlows/HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("ForEach(model.unreadableProjects) { UnreadableProjectCard(entry: $0) }"))
        XCTAssertEqual(UnreadableProjectCard.title, "Can’t open")
        let card = String(home[home.range(of: "struct UnreadableProjectCard: View {")!.lowerBound...])
        let body = String(card[..<card.range(of: "\n}\n")!.lowerBound])
        for action in ["Button", ".contextMenu", "onTapGesture", "model.open", "deleteProject", "onDelete", "onOpen"] {
            XCTAssertFalse(body.contains(action), "★ nothing to tap on a Can’t open card: \(action)")
        }
    }
}

private struct TestKey: CodingKey {
    var stringValue: String; var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

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
}

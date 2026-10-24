import XCTest
import CryptoKit
import simd
import TopOptKit
@testable import TopOptFlows

/// B6 (the redesign's DESIGN PRIMITIVES list, his picks + the reviewer's rulings 2026-10-24): the Setup panel's one Design
/// box row is a list of up to 6 primitives (Box or Cylinder, Positive or Negative, eye, trash + Undo). Front end first: a
/// Topology run sends the FIRST POSITIVE BOX as today's single design box and nothing else, so the job a single-box project
/// sends must not move by one byte.
@MainActor
final class DesignPrimitivesTests: XCTestCase {

    // MARK: - fixtures (mirrors TopologyStageTests)

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }
    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-design-primitives-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func loadedCube() throws -> (AppModel, ProjectModel) {
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                         rulesPath: Self.core("src/settings/rules.json"),
                         store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.core("tests/fixtures/stl/cube_10mm.stl"), displayName: "Bracket.stl"))
        m.continueToWorkspace()
        let p = try XCTUnwrap(m.project)
        let anchor = p.selection.addGroup()
        p.selection.pickFace(10)
        p.force.makeAnchor(anchor)
        let load = p.selection.addGroup()
        p.selection.pickFace(20)
        p.force.makeLoad(load)
        p.force.setWeight(load, kg: 4.2)
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        p.force.sync(groups: p.selection.groups)
        return (m, p)
    }

    private func canonicalJob(_ m: AppModel) throws -> Data {
        let req = try XCTUnwrap(m.makeRunRequest())
        let raw = try RemoteRun.buildJobJSON(req)
        let obj = try JSONSerialization.jsonObject(with: raw)
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Today's design box for the cube (a literal, so HEAD and B6 build the same box).
    static let todaysBox = DesignBoxBounds(min: SIMD3<Float>(-5, -4, -3), max: SIMD3<Float>(15, 14, 13))
    static let part = MeshBounds(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(10, 10, 10), isEmpty: false)

    private static func row(_ id: Int, _ shape: DesignPrimitiveShape, _ sign: DesignPrimitiveSign,
                            _ b: DesignBoxBounds) -> DesignPrimitive {
        DesignPrimitive(id: id, name: "Box \(id)", shape: shape, sign: sign, bounds: b)
    }

    // MARK: - the job bytes (pinned against HEAD 9735ed42)

    /// The cube's Topology job with today's design box `todaysBox`, taken at 9735ed42 (before B6) with
    /// `p.designBox = DesignBoxModel(box: todaysBox)`.
    static let jobWithBoxAtHEAD = "c4af7bfaaadcc52d4a89cb3ca85b4cd73c250f8f17f2aa53f14bbd95bcd9efde"

    func testTheSingleBoxJobIsByteIdenticalToHEAD() throws {
        let (m, p) = try loadedCube()
        p.designBox = DesignBoxModel(primitives: [Self.row(1, .box, .positive, Self.todaysBox)])
        let job = try canonicalJob(m)
        XCTAssertTrue(String(decoding: job, as: UTF8.self).contains("design_box"), "the box must be in the job")
        XCTAssertEqual(sha(job), Self.jobWithBoxAtHEAD, "a one-positive-box list must send today's bytes")
        // ★ the eye is VIEW-ONLY: a hidden row still sends
        p.designBox.setShown(1, false)
        XCTAssertEqual(sha(try canonicalJob(m)), Self.jobWithBoxAtHEAD, "hiding the box changed the job")
    }

    // MARK: - what a run sends

    func testARunSendsTheFirstPositiveBoxOnly() throws {
        let neg = DesignBoxBounds(min: SIMD3<Float>(1, 1, 1), max: SIMD3<Float>(3, 3, 3))
        let cyl = DesignBoxBounds(min: SIMD3<Float>(2, 2, 0), max: SIMD3<Float>(6, 6, 20))
        let box2 = DesignBoxBounds(min: SIMD3<Float>(-2, -2, -2), max: SIMD3<Float>(12, 12, 30))
        var m = DesignBoxModel(primitives: [Self.row(1, .box, .negative, neg), Self.row(2, .cylinder, .positive, cyl),
                                            Self.row(3, .box, .positive, box2)])
        XCTAssertEqual(m.bridgeBox, TopOptKit.DesignBoxSpec(min: SIMD3<Double>(box2.min), max: SIMD3<Double>(box2.max)))
        XCTAssertEqual(m.bridgeKeepOuts, [TopOptKit.DesignBoxSpec(min: SIMD3<Double>(neg.min), max: SIMD3<Double>(neg.max))],
                       "★ a Negative BOX is today's keep-out and goes out as one (core takes it today)")
        m = DesignBoxModel(primitives: [Self.row(1, .box, .negative, neg), Self.row(2, .cylinder, .positive, cyl)])
        XCTAssertNil(m.bridgeBox, "no positive box: no design box")
        XCTAssertEqual(m.bridgeKeepOuts, [], "no design box ⇒ no keep-outs, as today")

        // through the real request
        let (app, p) = try loadedCube()
        p.designBox = DesignBoxModel(primitives: [Self.row(1, .box, .negative, neg), Self.row(2, .cylinder, .positive, cyl),
                                                  Self.row(3, .box, .positive, box2)])
        var req = try XCTUnwrap(app.makeRunRequest())
        XCTAssertEqual(req.designBox, TopOptKit.DesignBoxSpec(min: SIMD3<Double>(box2.min), max: SIMD3<Double>(box2.max)))
        XCTAssertEqual(req.keepOutBoxes, [TopOptKit.DesignBoxSpec(min: SIMD3<Double>(neg.min), max: SIMD3<Double>(neg.max))])
        p.designBox = DesignBoxModel(primitives: [Self.row(1, .box, .negative, neg), Self.row(2, .cylinder, .positive, cyl)])
        req = try XCTUnwrap(app.makeRunRequest())
        XCTAssertNil(req.designBox)
        XCTAssertFalse(String(decoding: try canonicalJob(app), as: UTF8.self).contains("design_box"))
    }

    // MARK: - the list

    func testTheListAddsUpToSixAndAddGreysAtSix() {
        var m = DesignBoxModel()
        XCTAssertTrue(m.primitives.isEmpty)
        for n in 1...6 {
            XCTAssertTrue(m.canAdd)
            XCTAssertEqual(m.add(around: Self.part), n)
        }
        XCTAssertEqual(m.primitives.count, DesignBoxModel.maxPrimitives)
        XCTAssertFalse(m.canAdd)
        XCTAssertNil(m.add(around: Self.part), "the 7th add does nothing")
        XCTAssertEqual(m.primitives.count, 6)
        XCTAssertEqual(m.primitives.map(\.name), ["Box 1", "Box 2", "Box 3", "Box 4", "Box 5", "Box 6"])
        XCTAssertTrue(m.primitives.allSatisfy { $0.shape == .box && $0.sign == .positive && $0.isShown })
        XCTAssertEqual(m.primitives[0].bounds, DesignBoxModel.defaultBox(around: Self.part), "row 1 is today's default box")
        XCTAssertEqual(DesignPrimitivesCopy.addNote(count: 6), "Up to 6 design primitives")
        XCTAssertEqual(DesignPrimitivesCopy.addNote(count: 2), "Positive: allow mass to grow here \u{00B7} Negative: no mass here")
        XCTAssertEqual(DesignPrimitivesCopy.count(2), "2 of 6")
        XCTAssertEqual(TopologySetupRow.designBox.title, "Design primitives")
    }

    func testBoxAndCylinderFields() {
        var m = DesignBoxModel(primitives: [Self.row(1, .box, .positive, Self.todaysBox)])
        m.setBoxSize(1, length: 30, width: 20, height: 10)
        var r = m.primitives[0]
        XCTAssertEqual(r.length, 30, accuracy: 1e-4); XCTAssertEqual(r.width, 20, accuracy: 1e-4)
        XCTAssertEqual(r.height, 10, accuracy: 1e-4)
        XCTAssertEqual(r.bounds.center, Self.todaysBox.center, "a size edit keeps the centre")
        m.setShape(1, .cylinder)
        r = m.primitives[0]
        XCTAssertEqual(r.shape, .cylinder)
        XCTAssertEqual(r.name, "Cylinder 1", "a default name follows the shape")
        XCTAssertEqual(r.axis, 2)
        m.setCylinder(1, diameter: 8, height: 25)
        r = m.primitives[0]
        XCTAssertEqual(r.diameter, 8, accuracy: 1e-4); XCTAssertEqual(r.height, 25, accuracy: 1e-4)
        XCTAssertEqual(r.bounds.size.x, 8, accuracy: 1e-4); XCTAssertEqual(r.bounds.size.y, 8, accuracy: 1e-4)
        XCTAssertEqual(r.bounds.size.z, 25, accuracy: 1e-4)
        m.setAxis(1, 0)
        r = m.primitives[0]
        XCTAssertEqual(r.axis, 0)
        XCTAssertEqual(r.bounds.size.x, 25, accuracy: 1e-4); XCTAssertEqual(r.bounds.size.y, 8, accuracy: 1e-4)
        XCTAssertEqual(r.bounds.size.z, 8, accuracy: 1e-4)
        XCTAssertEqual(r.bounds.center, Self.todaysBox.center)
        // a cylinder's cross face dragged on the model keeps it round
        let dragged = r.bounds.movingFace(axis: 1, isMax: true, to: r.bounds.max.y + 4, minSize: 0.1)
        m.writeBounds(1, dragged, draggedAxis: 1)
        r = m.primitives[0]
        XCTAssertEqual(r.bounds.size.y, 12, accuracy: 1e-4); XCTAssertEqual(r.bounds.size.z, 12, accuracy: 1e-4)
        m.setShape(1, .box)
        XCTAssertEqual(m.primitives[0].name, "Box 1")
        XCTAssertEqual(m.primitives[0].bounds, r.bounds, "back to a box keeps its extent")
    }

    func testPositiveAndNegative() {
        var m = DesignBoxModel(primitives: [Self.row(1, .box, .positive, Self.todaysBox)])
        XCTAssertEqual(DesignPrimitiveSign.positive.meaning, "Allow mass to grow here")
        XCTAssertEqual(DesignPrimitiveSign.negative.meaning, "No mass here")
        XCTAssertEqual(DesignPrimitiveSign.positive.title, "Positive")
        XCTAssertEqual(DesignPrimitiveSign.negative.title, "Negative")
        m.setSign(1, .negative)
        XCTAssertEqual(m.primitives[0].sign, .negative)
        XCTAssertNil(m.bridgeBox, "a negative box is not the design box")
        m.setSign(1, .positive)
        XCTAssertNotNil(m.bridgeBox)
    }

    func testTheEyeIsViewOnly() {
        var m = DesignBoxModel(primitives: [Self.row(1, .box, .positive, Self.todaysBox),
                                            Self.row(2, .box, .negative, DesignBoxBounds(min: .zero, max: .one))])
        let sent = m.bridgeBox
        m.setShown(1, false)
        XCTAssertFalse(m.primitives[0].isShown)
        XCTAssertEqual(m.bridgeBox, sent, "hiding a row never changes what the run sends")
        XCTAssertEqual(m.shownPrimitives.map(\.id), [2], "a hidden row is not drawn")
        m.setShown(1, true)
        XCTAssertEqual(m.shownPrimitives.map(\.id), [1, 2])
    }

    func testTrashThenUndoRestoresTheRowInOneStep() throws {
        let (_, p) = try loadedCube()
        p.designBox = DesignBoxModel(primitives: [Self.row(1, .box, .positive, Self.todaysBox),
                                                  Self.row(2, .cylinder, .negative, DesignBoxBounds(min: .zero, max: .one)),
                                                  Self.row(3, .box, .positive, DesignBoxBounds(min: .zero, max: .one))])
        let before = p.designBox
        let t = try XCTUnwrap(p.trashPrimitive(2))
        XCTAssertEqual(t.name, "Box 2")
        XCTAssertEqual(p.designBox.primitives.map(\.id), [1, 3])
        XCTAssertTrue(p.canUndoTrashPrimitive(t))
        p.undoTrashPrimitive(t)
        XCTAssertEqual(p.designBox, before, "Undo puts the row back where it was")
        XCTAssertEqual(DesignPrimitivesCopy.deleteAsk("Box 2"), "Delete Box 2?")
        XCTAssertEqual(DesignPrimitivesCopy.deletedToast("Box 2"), "Deleted Box 2.")
    }

    // MARK: - saved projects

    func testAnOldProjectsDesignBoxOpensAsRow1() throws {
        let b = Self.todaysBox
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let old = try enc.encode(OldDesignBoxModel(box: b, keepOuts: []))
        let m = try JSONDecoder().decode(DesignBoxModel.self, from: old)
        XCTAssertEqual(m.primitives.count, 1)
        XCTAssertEqual(m.primitives[0].shape, .box)
        XCTAssertEqual(m.primitives[0].sign, .positive)
        XCTAssertEqual(m.primitives[0].bounds, b)
        XCTAssertTrue(m.primitives[0].isShown)
        XCTAssertEqual(m.bridgeBox, TopOptKit.DesignBoxSpec(min: SIMD3<Double>(b.min), max: SIMD3<Double>(b.max)))
        // an untouched project encodes as before
        XCTAssertEqual(try enc.encode(m), old, "an untouched project must encode as before")
        // 102117B9's `{"keepOuts":[]}` opens with an empty list, and a keep-out opens as a Negative box row
        let empty = try JSONDecoder().decode(DesignBoxModel.self, from: Data(#"{"keepOuts":[]}"#.utf8))
        XCTAssertTrue(empty.primitives.isEmpty)
        let ko = DesignBoxBounds(min: .zero, max: .one)
        let withKO = try JSONDecoder().decode(DesignBoxModel.self,
                                              from: try JSONEncoder().encode(OldDesignBoxModel(box: b, keepOuts: [ko])))
        XCTAssertEqual(withKO.primitives.map(\.sign), [.positive, .negative])
        XCTAssertEqual(withKO.primitives[1].bounds, ko)
        // a list the old keys can't hold round-trips through the new key
        var edited = m
        edited.setShape(1, .cylinder)
        let back = try JSONDecoder().decode(DesignBoxModel.self, from: try JSONEncoder().encode(edited))
        XCTAssertEqual(back, edited)
    }

    // MARK: - a primitive that stops short is plainly visible

    func testAPrimitiveThatStopsShortIsFlagged() {
        // his case: the keep-out ends 2 mm short of the design box's face
        let design = DesignBoxBounds(min: SIMD3<Float>(-10, -10, -10), max: SIMD3<Float>(20, 20, 20))
        let keepOut = DesignBoxBounds(min: SIMD3<Float>(2, 2, 12), max: SIMD3<Float>(8, 8, 18))
        let gaps = DesignPrimitiveGaps.find([Self.row(1, .box, .positive, design), Self.row(2, .box, .negative, keepOut)],
                                            part: Self.part)
        let g = try? XCTUnwrap(gaps.first { $0.primitiveID == 2 && $0.reference == .primitive(1) })
        XCTAssertNotNil(g)
        XCTAssertEqual(g?.mm ?? 0, 2, accuracy: 1e-4)
        XCTAssertEqual(g?.axis, 2)
        XCTAssertEqual(g?.region.min.z ?? 0, 18, accuracy: 1e-4); XCTAssertEqual(g?.region.max.z ?? 0, 20, accuracy: 1e-4)
        XCTAssertEqual(DesignPrimitivesCopy.gapNote(mm: 2, of: "Box 1"), "Stops 2.0 mm short of Box 1")
        // a box that stops 1.5 mm short of the part
        let shy = DesignBoxBounds(min: SIMD3<Float>(2, 2, 11.5), max: SIMD3<Float>(8, 8, 16))
        let partGaps = DesignPrimitiveGaps.find([Self.row(1, .box, .positive, shy)], part: Self.part)
        XCTAssertEqual(partGaps.first?.reference, .part)
        XCTAssertEqual(partGaps.first?.mm ?? 0, 1.5, accuracy: 1e-4)
        // a box that reaches is not flagged
        let flush = DesignBoxBounds(min: SIMD3<Float>(2, 2, 10), max: SIMD3<Float>(8, 8, 16))
        XCTAssertTrue(DesignPrimitiveGaps.find([Self.row(1, .box, .positive, flush)], part: Self.part).isEmpty)
    }
}

/// Today's (9735ed42) on-disk shape of `DesignBoxModel`: `box` (omitted when nil) and `keepOuts`.
private struct OldDesignBoxModel: Codable {
    var box: DesignBoxBounds?
    var keepOuts: [DesignBoxBounds]
}

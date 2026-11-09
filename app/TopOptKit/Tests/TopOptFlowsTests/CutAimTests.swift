// CutAimTests — B8 (rows 36, R1; P6; plan §B8 CutLiesOnFace / HoleAlongAcross / PlaneAsk): where a cut lies, by its face, on
// the committed WallMount_ShelfBracket.stl (its bores, flat faces and rounded edges are the importer's own fits).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class CutAimTests: XCTestCase {

    static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    func bracket() throws -> ViewerMesh {
        let m = try TopOptKit.importMesh(path: Self.repoRoot.appendingPathComponent("core/tests/fixtures/mesh/WallMount_ShelfBracket.stl").path)
        return ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, faceGeometry: m.faceGeometry,
                          pseudoFaces: m.pseudoFaces)
    }

    func aim(_ f: FaceID, _ m: ViewerMesh) throws -> CutAim {
        try XCTUnwrap(CutAim.make(face: f, piece: nil, regions: FaceRegionModel(), mesh: m), "face \(f)'s aim")
    }

    /// ★ CutLiesOnFace: on a flat face the cut is a line ON it — the plane's normal lies in the face at every Rotate, Rotate
    /// turns it, and the mm slides it across without turning it. No Tilt, no question.
    func testOnAFlatFaceTheCutLiesOnTheFace() throws {
        let m = try bracket()
        let flat = try XCTUnwrap(FaceTopology.faceIDs(in: m).first { m.faceGeometry($0)?.kind == .plane }, "a flat face")
        var a = try aim(flat, m)
        XCTAssertEqual(a.way, .line); XCTAssertNil(a.asks); XCTAssertFalse(a.showsTilt); XCTAssertTrue(a.moves)
        let fn = SurfaceCut.faceNormal(of: flat, in: m)
        for r in stride(from: 0.0, to: 360, by: 15) {
            a.setRotate(r)
            let n = try XCTUnwrap(a.plane).normal
            XCTAssertEqual(simd_dot(n, fn), 0, accuracy: 1e-9, "★ at \(r)° the cut stands square to the face: its line lies on it")
        }
        a.setRotate(30)
        let n30 = try XCTUnwrap(a.plane).normal
        a.setOffset(2)
        let moved = try XCTUnwrap(a.plane)
        XCTAssertEqual(simd_dot(moved.normal, n30), 1, accuracy: 1e-12, "★ the mm never turns it (R1)")
        XCTAssertEqual(simd_dot(moved.point - a.centre, n30), 2, accuracy: 1e-9, "the mm slides it across the face")
        a.setRotate(-15); XCTAssertEqual(a.rotateDeg, 345, accuracy: 1e-9, "Rotate wraps 0–359")
        a.setOffset(1e6); XCTAssertEqual(a.offsetMM, a.reach.upperBound, "the slide stays on the face")
    }

    /// ★ HoleAlongAcross: a hole asks first; Across is a ring (its plane square to the bore, moved along it by the mm, leant by
    /// Tilt toward Rotate and never moved by it); Along is a line down the bore (its plane holds the axis; Rotate carries it
    /// round; Tilt slants it).
    func testAHoleAsksAlongOrAcrossAndTheCutFollowsTheAxisOrTheRing() throws {
        let m = try bracket()
        let bore = try XCTUnwrap(FaceTopology.faceIDs(in: m).first { FaceTopology.isFastenerBore($0, in: m) }, "a bore")
        var a = try aim(bore, m)
        XCTAssertEqual(a.asks, .hole, "★ a hole asks Along or Across first")
        XCTAssertNil(a.plane, "no line before the answer")
        let axis = a.axis
        // Across: a ring
        a.answer(.across)
        XCTAssertTrue(a.showsTilt && a.moves)
        XCTAssertEqual(abs(simd_dot(try XCTUnwrap(a.plane).normal, axis)), 1, accuracy: 1e-9, "★ across: square to the bore")
        a.setOffset(1)
        XCTAssertEqual(simd_dot(try XCTUnwrap(a.plane).point - a.centre, axis), min(1, a.reach.upperBound), accuracy: 1e-9,
                       "★ the mm moves it up the bore")
        a.setTilt(30); a.setRotate(60)
        let leant = try XCTUnwrap(a.plane)
        XCTAssertEqual(acos(min(1, abs(simd_dot(leant.normal, axis)))) * 180 / .pi, 30, accuracy: 1e-6, "★ Tilt leans it 30°")
        XCTAssertEqual(simd_dot(leant.point - a.centre, axis), min(1, a.reach.upperBound), accuracy: 1e-9,
                       "★ Tilt never moves it (R1)")
        let lean = simd_normalize(leant.normal - axis * simd_dot(leant.normal, axis))
        XCTAssertEqual(simd_dot(lean, a.around(60)), 1, accuracy: 1e-9, "★ Rotate says which way it leans (P6)")
        a.setTilt(90); XCTAssertEqual(a.tiltDeg, 60, "Tilt stops at 60°")
        // Along: a line down the bore
        a.answer(.along)
        XCTAssertFalse(a.moves, "an along line turns round (⟲), it has no mm")
        for r in [0.0, 90, 200] {
            a.setRotate(r)
            let pl = try XCTUnwrap(a.plane)
            XCTAssertEqual(simd_dot(pl.normal, axis), 0, accuracy: 1e-9, "★ along: the plane holds the axis")
            XCTAssertEqual(simd_dot(pl.normal, a.around(r)), 0, accuracy: 1e-9, "★ … at Rotate's side of the bore")
        }
        a.setTilt(20)
        XCTAssertGreaterThan(abs(simd_dot(try XCTUnwrap(a.plane).normal, axis)), 0.3, "Tilt slants the line down the bore")
        // the ⟲ handle carries it round
        a.setTilt(0); a.setRotate(0)
        let start = a, r = start.radius
        a.drag(byMM: r * .pi / 2, from: start)
        XCTAssertEqual(a.rotateDeg, 90, accuracy: 1e-6, "★ a quarter of the bore's way round is 90°")
    }

    /// ★ PlaneAsk: anything else — a rounded edge — asks "Which plane?" first; Around it is a ring, Down it a line along its
    /// axis, At an angle a ring leaning 30°.
    func testAnyOtherFaceAsksWhichPlane() throws {
        let m = try bracket()
        let names = FaceNames.names(in: m, frame: .init(gravity: nil))
        let edge = try XCTUnwrap(names.first { $0.value.hasPrefix("Rounded edge") }?.key, "a rounded edge")
        var a = try aim(edge, m)
        XCTAssertEqual(a.asks, .plane, "★ not obvious: Which plane? first")
        a.answer(.across, atAnAngle: true)
        XCTAssertEqual(a.tiltDeg, CutAim.atAnAngleDeg, "At an angle leans it")
        a.answer(.across)
        XCTAssertEqual(abs(simd_dot(try XCTUnwrap(a.plane).normal, a.axis)), 1, accuracy: 1e-9, "Around it: square to its axis")
        a.answer(.along)
        XCTAssertEqual(simd_dot(try XCTUnwrap(a.plane).normal, a.axis), 0, accuracy: 1e-9, "Down it: along its axis")
        // its axis is the edge's own cylinder
        if let g = m.faceGeometry(edge), g.isCylinder {
            XCTAssertEqual(abs(simd_dot(a.axis, simd_normalize(g.axisDir))), 1, accuracy: 1e-9)
        }
    }

    /// The fitted axis of a free-form face: a ring of normals square to Z has Z as its axis.
    func testTheFittedAxisIsTheDirectionTheNormalsTurnLeastAbout() {
        // a half cylinder of radius 5 about Z, as triangles
        var v: [Float] = [], idx: [Int32] = [], ids: [Int32] = []
        let n = 12
        for i in 0...n {
            let t = Float(i) / Float(n) * .pi
            v += [5 * cos(t), 5 * sin(t), 0, 5 * cos(t), 5 * sin(t), 10]
        }
        for i in 0..<n {
            let a = Int32(i * 2), b = a + 1, c = a + 2, d = a + 3
            idx += [a, c, b, b, c, d]; ids += [0, 0]
        }
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: ids)
        let axis = CutAim.fittedAxis(0, mesh)
        XCTAssertEqual(abs(axis.z), 1, accuracy: 1e-6)
        let pts = CutAim.points(face: 0, piece: nil, regions: FaceRegionModel(), mesh: mesh)
        let fit = CutAim.circle(pts, axis: axis, near: pts.reduce(.zero, +) / Double(pts.count))
        XCTAssertEqual(fit.radius, 5, accuracy: 1e-3, "the circle through it")
        XCTAssertEqual(fit.centre.x, 0, accuracy: 1e-3); XCTAssertEqual(fit.centre.y, 0, accuracy: 1e-3)
    }
}

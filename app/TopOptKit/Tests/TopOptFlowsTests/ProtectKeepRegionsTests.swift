import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// ★ EXACT PROTECT (his ruling 2026-10-26 23:44): the region builder. A hole → a cylinder; a rectangular face → one box; an
/// L-shaped face → boxes inside its outline only; tilted, a half hole or a boss → nothing.
final class ProtectKeepRegionsTests: XCTestCase {
    /// Triangles (each three points) per face id, with the face's CAD geometry.
    private func mesh(_ faces: [(tris: [[SIMD3<Double>]], geo: StepFaceGeometry)]) -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        for (f, face) in faces.enumerated() {
            for t in face.tris {
                for p in t { idx.append(Int32(v.count / 3)); v += [Float(p.x), Float(p.y), Float(p.z)] }
                fid.append(Int32(f))
            }
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fid, faceGeometry: faces.map(\.geo))
    }

    /// The inner wall of a bore along Z (radius r, z0…z1, angles a0…a1), wound so its normal faces the axis.
    private func bore(r: Double, z0: Double, z1: Double, from a0: Double = 0, to a1: Double = 2 * .pi, n: Int = 48,
                      inward: Bool = true) -> [[SIMD3<Double>]] {
        var out: [[SIMD3<Double>]] = []
        for i in 0..<n {
            let t0 = a0 + (a1 - a0) * Double(i) / Double(n), t1 = a0 + (a1 - a0) * Double(i + 1) / Double(n)
            let A = SIMD3(r * cos(t0), r * sin(t0), z0), B = SIMD3(r * cos(t1), r * sin(t1), z0)
            let C = SIMD3(r * cos(t1), r * sin(t1), z1), D = SIMD3(r * cos(t0), r * sin(t0), z1)
            out += inward ? [[A, C, B], [A, D, C]] : [[A, B, C], [A, C, D]]
        }
        return out
    }

    private let zBore = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 3, axisPoint: .zero, axisDir: SIMD3(0, 0, 1))

    func testAFullRoundHoleIsOneCylinderOfBorePlusDepth() throws {
        let m = mesh([(bore(r: 3, z0: 0, z1: 10), zBore)])
        // outwardMM 0: the shape alone (the open-end reach is insideSolid's, tested below on a closed part)
        let r = ProtectKeepRegions.regions([.init(id: 0, depthMM: 2)], in: m, outwardMM: 0)
        XCTAssertEqual(r.count, 1)
        guard case let .cylinder(lo, hi, axis) = try XCTUnwrap(r.first) else { return XCTFail("\(r)") }
        XCTAssertEqual(axis, 2)
        XCTAssertEqual(lo.x, -5, accuracy: 1e-4); XCTAssertEqual(hi.x, 5, accuracy: 1e-4)   // radius 3 + depth 2
        XCTAssertEqual(lo.y, -5, accuracy: 1e-4); XCTAssertEqual(hi.y, 5, accuracy: 1e-4)
        XCTAssertEqual(lo.z, 0, accuracy: 1e-4); XCTAssertEqual(hi.z, 10, accuracy: 1e-4)   // the face's own length
        let j = r[0].json
        XCTAssertEqual(j["shape"] as? String, "cylinder"); XCTAssertEqual(j["axis"] as? Int, 2)
    }

    func testABoreSplitInTwoHalvesIsOneCylinderOnlyWhenBothAreProtected() {
        let m = mesh([(bore(r: 3, z0: 0, z1: 10, from: 0, to: .pi), zBore),
                      (bore(r: 3, z0: 0, z1: 10, from: .pi, to: 2 * .pi), zBore)])
        XCTAssertEqual(ProtectKeepRegions.regions([.init(id: 0, depthMM: 2), .init(id: 1, depthMM: 2)], in: m, outwardMM: 1).count, 1)
        XCTAssertTrue(ProtectKeepRegions.regions([.init(id: 0, depthMM: 2)], in: m, outwardMM: 1).isEmpty,
                      "★ half a bore: a full cylinder would put back the other half's material")
    }

    /// ★ his iPad 2026-10-27 (note 3): a round hole the STEP split into two halves is still a hole — the auto keep-clear
    /// primitive is made for it, once.
    func testAHoleSplitInHalvesIsABoreOnceAndALoneHalfIsNot() {
        let m = mesh([(bore(r: 3, z0: 0, z1: 10, from: 0, to: .pi), zBore),
                      (bore(r: 3, z0: 0, z1: 10, from: .pi, to: 2 * .pi), zBore)])
        XCTAssertTrue(FaceTopology.isFastenerBore(0, in: m), "★ each half of a full hole is a bore")
        XCTAssertTrue(FaceTopology.isFastenerBore(1, in: m))
        XCTAssertTrue(FaceTopology.isBoreRepresentative(0, among: [0, 1], in: m))
        XCTAssertFalse(FaceTopology.isBoreRepresentative(1, among: [0, 1], in: m), "one cylinder, not two")
        XCTAssertTrue(FaceTopology.isBoreRepresentative(1, among: [1], in: m), "a group with only the second half still has it")
        let slot = mesh([(bore(r: 3, z0: 0, z1: 10, from: 0, to: .pi), zBore)])
        XCTAssertFalse(FaceTopology.isFastenerBore(0, in: slot), "a lone half (a U-slot's end) is not a hole")
    }

    /// The open-end probe: a point inside a closed 10 mm cube is inside, one past its face is not.
    func testInsideSolidReadsAClosedPart() {
        let c = { (x: Double, y: Double, z: Double) in SIMD3(x, y, z) }
        let v = [c(0,0,0), c(10,0,0), c(10,10,0), c(0,10,0), c(0,0,10), c(10,0,10), c(10,10,10), c(0,10,10)]
        let q = [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
        let m = mesh([(q.map { $0.map { v[$0] } }, StepFaceGeometry(kind: .other))])
        XCTAssertTrue(ProtectKeepRegions.insideSolid(c(5, 5, 5), m))
        XCTAssertTrue(ProtectKeepRegions.insideSolid(c(5, 5, 9.6), m), "just under the top: part (a blind floor)")
        XCTAssertFalse(ProtectKeepRegions.insideSolid(c(5, 5, 10.4), m), "just past the top: air (an open end)")
    }

    func testABossIsNeverKept() {
        let m = mesh([(bore(r: 3, z0: 0, z1: 10, inward: false), zBore)])
        XCTAssertTrue(ProtectKeepRegions.regions([.init(id: 0, depthMM: 2)], in: m, outwardMM: 1).isEmpty,
                      "★ a pin's cylinder would hold its whole unfrozen core")
    }

    private func plane(_ n: SIMD3<Double>, _ o: SIMD3<Double>) -> StepFaceGeometry {
        StepFaceGeometry(kind: .plane, planeNormal: n, planeOrigin: o)
    }

    func testARectangularFaceIsOneBoxDepthInsideAndALittleOver() throws {
        // top face z = 10, 20 × 10, outward +Z
        let a = SIMD3(0.0, 0, 10), b = SIMD3(20.0, 0, 10), c = SIMD3(20.0, 10, 10), d = SIMD3(0.0, 10, 10)
        let m = mesh([([[a, b, c], [a, c, d]], plane(SIMD3(0, 0, 1), a))])
        let r = ProtectKeepRegions.regions([.init(id: 0, depthMM: 2)], in: m, outwardMM: 1)
        XCTAssertEqual(r.count, 1)
        guard case let .box(lo, hi) = try XCTUnwrap(r.first) else { return XCTFail("\(r)") }
        XCTAssertEqual(lo, SIMD3(0, 0, 8)); XCTAssertEqual(hi, SIMD3(20, 10, 11))
        // a bottom face (outward −Z) slabs upward into the part
        let e = SIMD3(0.0, 0, 0), f = SIMD3(20.0, 0, 0), g = SIMD3(20.0, 10, 0), h = SIMD3(0.0, 10, 0)
        let m2 = mesh([([[e, g, f], [e, h, g]], plane(SIMD3(0, 0, -1), e))])
        guard case let .box(lo2, hi2) = try XCTUnwrap(ProtectKeepRegions.regions([.init(id: 0, depthMM: 2)], in: m2, outwardMM: 1).first)
        else { return XCTFail() }
        XCTAssertEqual(lo2.z, -1, accuracy: 1e-9); XCTAssertEqual(hi2.z, 2, accuracy: 1e-9)
    }

    func testAnLShapedFaceGetsBoxesInsideItsOutlineOnly() {
        // L: [0,20]×[0,5] ∪ [0,5]×[0,20] on z = 0, outward +Z
        let p = { (x: Double, y: Double) in SIMD3(x, y, 0) }
        let tris = [[p(0, 0), p(20, 0), p(20, 5)], [p(0, 0), p(20, 5), p(5, 5)], [p(0, 0), p(5, 5), p(5, 20)],
                    [p(0, 0), p(5, 20), p(0, 20)]]
        let m = mesh([(tris, plane(SIMD3(0, 0, 1), .zero))])
        let r = ProtectKeepRegions.regions([.init(id: 0, depthMM: 3)], in: m, outwardMM: 1)
        XCTAssertGreaterThanOrEqual(r.count, 2)
        var area = 0.0
        for k in r {
            guard case let .box(lo, hi) = k else { return XCTFail("\(k)") }
            let inL = { (x: Double, y: Double) in (x >= -1e-6 && x <= 20 + 1e-6 && y >= -1e-6 && y <= 5 + 1e-6)
                || (x >= -1e-6 && x <= 5 + 1e-6 && y >= -1e-6 && y <= 20 + 1e-6) }
            for (x, y) in [(lo.x, lo.y), (hi.x, lo.y), (lo.x, hi.y), (hi.x, hi.y)] {
                XCTAssertTrue(inL(x, y), "★ a box corner (\(x), \(y)) lies outside the L")
            }
            XCTAssertEqual(lo.z, -3, accuracy: 1e-9); XCTAssertEqual(hi.z, 1, accuracy: 1e-9)
            area += (hi.x - lo.x) * (hi.y - lo.y)
        }
        XCTAssertGreaterThan(area, 0.95 * 175, "the boxes cover the L (175 mm²) — \(area)")
        XCTAssertLessThanOrEqual(area, 175 + 1e-6, "and never overlap past it")
    }

    func testTiltedFacesAndHolesSendNothingWithoutTheOrientedForm() {
        ProtectKeepRegions.orientedAvailable = false
        let c = cos(Double.pi / 6), s = sin(Double.pi / 6)
        // a 20 × 10 face tilted 30° about X, outward (0, −s, c)
        let n = SIMD3(0, -s, c), u = SIMD3(1.0, 0, 0), v = SIMD3(0, c, s)
        let q = { (a: Double, b: Double) in u * a + v * b }
        let m = mesh([([[q(0, 0), q(20, 0), q(20, 10)], [q(0, 0), q(20, 10), q(0, 10)]], plane(n, .zero))])
        XCTAssertTrue(ProtectKeepRegions.regions([.init(id: 0, depthMM: 2)], in: m, outwardMM: 1).isEmpty)
        XCTAssertTrue(ProtectKeepRegions.info.contains("X, Y or Z"), "the (i) keeps its X/Y/Z line")
    }

    func testTheJobCarriesKeepRegionsAndOmitsThemWhenEmpty() throws {
        var r = RunRequest(modelPath: "/m.step", material: "PLA", materialsPath: "/x", rulesPath: "/y", resolution: 40, projectName: "p")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(r)) as? [String: Any])
        XCTAssertNil(plain["keep_regions"], "no Protect: the job is exactly today's")
        r.keepRegions = [.box(min: SIMD3(0, 0, 8), max: SIMD3(20, 10, 11))]
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(r)) as? [String: Any])
        let k = try XCTUnwrap(job["keep_regions"] as? [[String: Any]])
        XCTAssertEqual(k.first?["shape"] as? String, "box")
        XCTAssertEqual(k.first?["min"] as? [Double], [0, 0, 8]); XCTAssertEqual(k.first?["max"] as? [Double], [20, 10, 11])
    }
}

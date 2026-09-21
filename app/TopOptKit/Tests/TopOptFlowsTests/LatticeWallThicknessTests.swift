import XCTest
import simd
@testable import TopOptFlows

/// ★ THE LATTICE'S THICKNESS THROUGH THE WALL (his 2026-09-20/21): a slab inside the
/// declared prism — its start, and its thickness at every face point — applied preview
/// first, through the one region distance every reader clips against.
final class LatticeWallThicknessTests: XCTestCase {

    /// A 20 × 20 mm face at z = 0 looking into +z, 10 mm deep.
    private func face() -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(0, 0, 0); r.normal = SIMD3(0, 0, 1); r.depthMM = 10
        r.outlineLoops = [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]]
        return r
    }

    /// The region's own (u, v) for a point of the face plane — the basis is the mask's,
    /// not (x, y).
    private func uv(_ x: Double, _ y: Double) -> SIMD2<Double> {
        let (bu, bv) = LatticeRegionMask.basisForTests(SIMD3(0, 0, 1))
        let p = SIMD3<Double>(x, y, 0)
        return SIMD2(simd_dot(p, bu), simd_dot(p, bv))
    }

    /// A field over the prism: stress rising with x, 0 at x = −10 to 10 MPa at x = +10.
    private func field() -> StressField {
        let n = 24, h: Float = 1.0
        var v = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let x = -12 + (Float(i) + 0.5) * h
            v[(k * n + j) * n + i] = max(0, (x + 10) / 20 * 10)
        } } }
        return StressField(nx: n, ny: n, nz: n, origin: SIMD3(-12, -12, -2), spacing: h, values: v)
    }

    func testThroughAsksForNothingAndTheSettingsStayByteIdentical() throws {
        XCTAssertTrue(LatticeWallThickness.through.isThrough)
        XCTAssertNil(LatticeWallThicknessBuilder.build(region: face(), spec: .through, field: nil,
                                                       referenceMPa: 0, floorMM: 1))
        let s = LatticeSettings(enabled: true)
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("wallThickness"), "★ an untouched project writes no thickness key")
        var moved = s; moved.wallThicknessMode = .manualSingle; moved.wallThicknessShare = 0.4
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(moved))
        XCTAssertEqual(back.wallThicknessMode, .manualSingle)
        XCTAssertEqual(back.wallThicknessShare, 0.4)
        XCTAssertEqual(back.wallThickness, moved.wallThickness)
    }

    func testAManualSlabCutsTheRegionDistanceAndTheContainment() {
        var r = face()
        r.thickness = LatticeWallThickness(mode: .manualSingle, startShare: 0.2, share: 0.5)
        let attached = LatticeWallThicknessBuilder.attach([r], field: nil, floorMM: 1)[0]
        let m = try! XCTUnwrap(attached.thicknessMap)
        // start 2 mm in, half of the 8 mm left ⇒ the slab is z ∈ [2, 6]
        XCTAssertEqual(m.startMM, 2, accuracy: 1e-9)
        XCTAssertEqual(attached.slabRange(uv: .zero).end, 6, accuracy: 1e-9)
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(0, 0, 1), region: attached), "before the slab")
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(0, 0, 4), region: attached), "inside the slab")
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(0, 0, 8), region: attached), "past the slab")
        XCTAssertLessThan(LatticeRegionMask.signedDistance(SIMD3(0, 0, 4), region: attached), 0)
        XCTAssertGreaterThan(LatticeRegionMask.signedDistance(SIMD3(0, 0, 8), region: attached), 0)
        XCTAssertGreaterThan(LatticeRegionMask.signedDistance(SIMD3(0, 0, 1), region: attached), 0)
        // the whole-prism test still sees the declared depth
        XCTAssertTrue(LatticeRegionMask.containsWholePrism(SIMD3(0, 0, 8), region: attached))
        // and the untouched face is unchanged
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(0, 0, 8), region: face()))
    }

    /// His rule: thickness = depth × the column's peak stress over the part's p95,
    /// floored at one cell. A face stressed 0 → 10 MPa across x grades thin → thick.
    func testTheSimRuleGradesThicknessWithTheStressAndFloorsAtOneCell() throws {
        var r = face(); r.thickness = LatticeWallThickness(mode: .sim)
        let a = LatticeWallThicknessBuilder.attach([r], field: field(), floorMM: 2)[0]
        let m = try XCTUnwrap(a.thicknessMap)
        XCTAssertGreaterThan(m.nu * m.nv, 1, "a varying map, not a constant")
        let thin = a.slabRange(uv: uv(-9, 0)).end
        let thick = a.slabRange(uv: uv(9, 0)).end
        XCTAssertEqual(thin, 2, accuracy: 0.6, "★ the unloaded edge sits on the one-cell floor")
        XCTAssertGreaterThan(thick, 8, "★ the loaded edge is (nearly) the whole depth")
        XCTAssertGreaterThan(a.slabRange(uv: uv(0, 0)).end, thin)
        XCTAssertLessThan(a.slabRange(uv: uv(0, 0)).end, thick)
        // the cap follows the slab: every cap vertex sits at that point's slab end
        let cap = LatticeRegionCap.build(regions: [a])
        let stride = 6
        var checked = 0
        for i in Swift.stride(from: 0, to: cap.interleaved.count, by: stride) {
            let p = SIMD3<Double>(Double(cap.interleaved[i]), Double(cap.interleaved[i + 1]), Double(cap.interleaved[i + 2]))
            let want = a.slabRange(uv: uv(p.x, p.y)).end
            XCTAssertEqual(p.z, want, accuracy: 1e-6)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 3 * 4, "★ subdivided — more than the two outline triangles")
    }

    func testAutoSingleAndGradeBoundTheSameRule() throws {
        var auto = face(); auto.thickness = LatticeWallThickness(mode: .autoSingle)
        let ma = try XCTUnwrap(LatticeWallThicknessBuilder.attach([auto], field: field(), floorMM: 1)[0].thicknessMap)
        XCTAssertEqual(ma.nu * ma.nv, 1, "one thickness for the wall")
        XCTAssertGreaterThan(ma.share(at: .zero), 0.8, "the wall's p95 is near the top")
        var grade = face(); grade.thickness = LatticeWallThickness(mode: .manualGrade, loShare: 0.3, hiShare: 0.6)
        let g = LatticeWallThicknessBuilder.attach([grade], field: field(), floorMM: 1)[0]
        XCTAssertEqual(g.slabRange(uv: uv(-9, 0)).end, 3, accuracy: 0.6, "low share where the stress is lowest")
        XCTAssertEqual(g.slabRange(uv: uv(9, 0)).end, 6, accuracy: 0.6, "high share where it peaks")
    }

    /// The request never reaches the job: the wire dictionary is the declared depth.
    func testTheSlabNeverReachesTheJob() {
        var r = face(); r.thickness = LatticeWallThickness(mode: .manualSingle, share: 0.3)
        let a = LatticeWallThicknessBuilder.attach([r], field: nil, floorMM: 1)[0]
        let geometry = a.wireDictionary["geometry"] as? [String: Any] ?? a.wireDictionary
        XCTAssertEqual(geometry["depth_mm"] as? Double, 10, "the declared depth, untouched")
        let text = String(describing: a.wireDictionary).lowercased()
        XCTAssertFalse(text.contains("thickness") || text.contains("slab") || text.contains("share"),
                       "★ preview first: nothing of the slab reaches the job")
    }
}

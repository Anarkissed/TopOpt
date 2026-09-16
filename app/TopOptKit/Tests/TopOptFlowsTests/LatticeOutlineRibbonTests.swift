import XCTest
import simd
@testable import TopOptFlows

/// The solid outline as GEOMETRY (his 2026-09-16 rule: "a singular beam bent around
/// the entirety of the face-prism outline; something inherently smooth"): one beam
/// of rectangular section swept round the face outline, offset in by the region's
/// in-plane offset, as deep as the wall.
final class LatticeOutlineRibbonTests: XCTestCase {
    private func square(_ half: Double, ccw: Bool, offset: Double = 0) -> LatticeRegionSpec {
        var spec = LatticeRegionSpec(role: .include, kind: .face)
        spec.origin = SIMD3<Double>(10, 20, 30)
        spec.normal = SIMD3<Double>(0, 1, 0)
        spec.halfUMM = 40; spec.halfWMM = 40
        spec.depthMM = 5
        spec.inPlaneOffsetMM = offset
        let loop = [SIMD2(-half, -half), SIMD2(half, -half), SIMD2(half, half), SIMD2(-half, half)]
        spec.outlineLoops = [ccw ? loop : loop.reversed()]
        return spec
    }

    func testABeamOfTheStatedSectionRunsRoundTheOutline() {
        for ccw in [true, false] {
            let r = square(10, ccw: ccw)
            let mesh = LatticeOutlineRibbon.build(regions: [r], widthMM: 1.2) { _, _ in 5 }
            XCTAssertEqual(mesh.vertexCount, 4 * 4 * 6, "four edges × four faces × two triangles")
            let n = LatticeRegionMask.unit(r.normal)
            let (bu, bv) = LatticeRegionMask.basis(n)
            var onOuter = 0, onInner = 0
            for i in 0..<mesh.vertexCount {
                let p = SIMD3<Double>(Double(mesh.interleaved[i * 6]), Double(mesh.interleaved[i * 6 + 1]), Double(mesh.interleaved[i * 6 + 2]))
                let nn = SIMD3<Double>(Double(mesh.interleaved[i * 6 + 3]), Double(mesh.interleaved[i * 6 + 4]), Double(mesh.interleaved[i * 6 + 5]))
                XCTAssertEqual(simd_length(nn), 1, accuracy: 1e-4, "unit normals")
                let rel = p - r.origin
                let u = simd_dot(rel, bu), v = simd_dot(rel, bv), s = simd_dot(rel, n)
                XCTAssertTrue(abs(s) < 1e-4 || abs(s - 5) < 1e-4, "every vertex sits on the face or the far cap; depth \(s)")
                let ring = max(abs(u), abs(v))
                if abs(ring - 10) < 1e-4 { onOuter += 1 } else if abs(ring - 8.8) < 1e-4 { onInner += 1 }
                else { XCTFail("a vertex off both rings at \(ring) mm (ccw \(ccw))") }
            }
            XCTAssertEqual(onOuter, onInner, "as many vertices on the outline as on the inner edge")
            XCTAssertGreaterThan(onOuter, 0)
        }
    }

    func testTheInPlaneOffsetMovesTheWholeBeamIn() {
        let r = square(10, ccw: true, offset: 0.5)
        let mesh = LatticeOutlineRibbon.build(regions: [r], widthMM: 1.0) { _, _ in 3 }
        var rings = Set<Int>()
        for i in 0..<mesh.vertexCount {
            let p = SIMD3<Double>(Double(mesh.interleaved[i * 6]), Double(mesh.interleaved[i * 6 + 1]), Double(mesh.interleaved[i * 6 + 2]))
            let rel = p - r.origin
            rings.insert(Int((max(abs(rel.x), abs(rel.z)) * 100).rounded()))
        }
        XCTAssertEqual(rings, [950, 850], "outer ring at 10 − 0.5, inner at 10 − 0.5 − 1.0")
    }

    func testTheDepthFollowsTheWall() {
        let r = square(10, ccw: true)
        let mesh = LatticeOutlineRibbon.build(regions: [r], widthMM: 1.0) { _, p in p.x > r.origin.x ? 2 : 4 }
        var depths = Set<Int>()
        for i in 0..<mesh.vertexCount {
            let y = Double(mesh.interleaved[i * 6 + 1]) - r.origin.y
            depths.insert(Int((y * 100).rounded()))
        }
        XCTAssertEqual(depths, [0, 200, 400], "the far cap follows the wall's thickness at each vertex")
    }

    func testNothingWithoutABand() {
        let r = square(10, ccw: true)
        XCTAssertEqual(LatticeOutlineRibbon.build(regions: [r], widthMM: 0) { _, _ in 5 }.vertexCount, 0)
    }
}

import XCTest
import simd
@testable import TopOptFlows

/// ★★ THE SOLID BEYOND A FACE PRISM'S CAP (his 2026-09-18): the cap mesh, and the shader
/// rule that draws it only where the part continues past the cap.
final class LatticeRegionCapTests: XCTestCase {
    func testEarClippingCoversTheLoopExactly() {
        let square: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let tris = LatticeRegionCap.triangulate(square)
        XCTAssertEqual(tris.count, 2)
        // an L: 6 vertices, 4 triangles, area 300 — concave, either winding
        let L: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 10), SIMD2(10, 10), SIMD2(10, 20), SIMD2(0, 20)]
        for loop in [L, L.reversed()] {
            let t = LatticeRegionCap.triangulate(loop)
            XCTAssertEqual(t.count, 4, "\(t)")
            var area = 0.0
            for (a, b, c) in t {
                let p = loop[a], q = loop[b], r = loop[c]
                area += abs((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)) * 0.5
            }
            XCTAssertEqual(area, 300, accuracy: 1e-9)
        }
    }

    func testTheCapSitsAtTheDepthAndFacesBackOut() {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(1, 2, 3); r.normal = SIMD3(0, 1, 0); r.depthMM = 12
        r.halfUMM = 20; r.halfWMM = 20
        r.outlineLoops = [[SIMD2(-5, -5), SIMD2(5, -5), SIMD2(5, 5), SIMD2(-5, 5)]]
        let m = LatticeRegionCap.build(regions: [r])
        XCTAssertEqual(m.triangleCount, 2)
        for v in 0..<m.vertexCount {
            XCTAssertEqual(m.interleaved[6 * v + 1], 2 + 12, accuracy: 1e-5, "every cap vertex is 12 mm in along +y")
            XCTAssertEqual(m.interleaved[6 * v + 4], -1, accuracy: 1e-6, "the cap faces back toward the open face")
        }
        var e = LatticeRegionSpec(role: .exclude, kind: .face)
        e.origin = r.origin; e.normal = r.normal; e.depthMM = r.depthMM; e.outlineLoops = r.outlineLoops
        XCTAssertEqual(LatticeRegionCap.build(regions: [e]).vertexCount, 0, "exclude regions have no cap")
    }

    func testTheShaderDrawsTheCapOnlyWhereThePartContinues() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TopOptFlows/MetalMeshView.swift")
        let s = try String(contentsOf: src, encoding: .utf8)
        XCTAssertTrue(s.contains("float3 p = in.mpos + inward * c.margin.x;"), "★ the sample is taken PAST the cap")
        XCTAssertTrue(s.contains("if (sdfTex.sample(s, uvw).r >= 0.0) { discard_fragment(); }"), "★ no material beyond ⇒ no cap")
        XCTAssertTrue(s.contains("o.albedo = float4(u.tint.xyz, 1.0);\n    return o;\n}\n\"\"\""), "★ the cap writes a PAINTED albedo — zero was invisible")
        XCTAssertTrue(s.contains("du.tint = LatticeRegionCap.wallTint"), "★ …in the body's grey")
        XCTAssertTrue(s.contains("margin: SIMD4(1.5 * voxel, 0, 0, 0)"), "★ a voxel and a half beyond the cap")
    }
}

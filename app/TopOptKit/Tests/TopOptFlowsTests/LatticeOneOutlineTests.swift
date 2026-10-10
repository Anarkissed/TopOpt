import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE ONE OUTLINE (the reviewer, 2026-10-10 21:27, P1-P6 as one set, approved by the maintainer): "the
/// generated polygon is the ONLY outline, for every reader: the bake's dOut/dOutFast, the shader's qC, the
/// side-rim tiles, the owner query, and the wire. The shader's depth-dependent seam flare is retired. The preview
/// draws the same vertical prism core builds, with the seam strip at min(depth, cap) x tilt through the full
/// depth." P2 no wedges; P3 inside chords within 0.01 mm; the proof: "point-sample core's region_contains through
/// the bridge against the preview's function, outside a 0.01 mm band; the positive control goes red on today's
/// mitred wire; record the bridge cost and the vertex counts".
final class LatticeOneOutlineTests: XCTestCase {

    private func face(_ loops: [[SIMD2<Double>]], expand: Double = 0, depth: Double = 4,
                      seams: [[Bool]] = [], tilts: [[Double]] = [], caps: [[Double]] = []) -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = .zero; r.normal = SIMD3(0, 0, 1); r.depthMM = depth
        var hu = 0.0, hw = 0.0
        for l in loops { for q in l { hu = Swift.max(hu, abs(q.x)); hw = Swift.max(hw, abs(q.y)) } }
        r.halfUMM = hu; r.halfWMM = hw
        r.outlineLoops = loops; r.inPlaneOffsetMM = expand
        r.outlineSeams = seams; r.outlineSeamTilt = tilts; r.outlineSeamDepthMM = caps
        return r
    }
    private func square(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [SIMD2<Double>] {
        [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]
    }
    private func point(_ r: LatticeRegionSpec, _ uv: SIMD2<Double>, depth s: Double) -> SIMD3<Double> {
        let n = LatticeRegionMask.unit(r.normal)
        let (bu, bv) = LatticeRegionMask.basis(n)
        return r.origin + bu * uv.x + bv * uv.y + n * s
    }
    /// Core's containment of each point, the region sent as `wire` (its wire dictionary unless one is given).
    private func core(_ r: LatticeRegionSpec, _ pts: [SIMD3<Double>], wire: [String: Any]? = nil) throws -> [Bool] {
        let o = try XCTUnwrap(TopOptKit.steppedRegionOwners(regions: [wire ?? r.wireDictionary], points: pts),
                              TopOptKit.lastCoreRefusal ?? "")
        return o.owners.map { $0 == 1 }
    }
    /// Today's wire before P1, rebuilt: each loop's MITRED ring (`offsetRing`), the seams pushed by
    /// min(depth, cap)·tilt — the positive control.
    private func mitredWire(_ r: LatticeRegionSpec) -> [String: Any] {
        var d = r.wireDictionary
        let e = r.inPlaneOffsetMM
        let loops: [[SIMD2<Double>]] = r.outlineLoops.enumerated().map { (l, loop) in
            let sm = l < r.outlineSeams.count ? r.outlineSeams[l] : []
            let tl = l < r.outlineSeamTilt.count ? r.outlineSeamTilt[l] : []
            let grow: [Double] = loop.indices.map { i in
                guard i < sm.count, sm[i] else { return -e }
                guard i < tl.count, tl[i] > 1e-9 else { return 0 }
                return -(r.depthMM * tl[i])
            }
            return LatticeOutlineRibbon.offsetRing(loop, by: 0, seams: [], edgeOffset: grow)
        }
        var g = d["geometry"] as! [String: Any]
        g["outline_uv"] = loops.map { $0.map { [$0.x, $0.y] } }
        var hu = 0.0, hw = 0.0
        for l in loops { for q in l { hu = Swift.max(hu, abs(q.x)); hw = Swift.max(hw, abs(q.y)) } }
        g["half_u_mm"] = Swift.max(hu, r.halfUMM); g["half_w_mm"] = Swift.max(hw, r.halfWMM)
        d["geometry"] = g
        return d
    }
    /// Distance from `uv` to the generated polygon's boundary.
    private func toBoundary(_ r: LatticeRegionSpec, _ uv: SIMD2<Double>) -> Double {
        var best = Double.greatestFiniteMagnitude
        for loop in r.outlinePolygon {
            for i in loop.indices {
                let a = loop[i], b = loop[(i + 1) % loop.count], d = b - a
                let l2 = simd_dot(d, d)
                let t = l2 > 1e-18 ? Swift.max(0, Swift.min(1, simd_dot(uv - a, d) / l2)) : 0
                best = Swift.min(best, simd_length(uv - (a + d * t)))
            }
        }
        return best
    }

    /// ★ The expand is ROUND, in the preview and in core alike; today's mitred wire claims the corner (RED control).
    func testARoundExpandIsTheSameSetInThePreviewAndInCore() throws {
        let r = face([square(0, 0, 10, 10)], expand: 2)
        let corner = SIMD2(11.6, 11.6), nearCorner = SIMD2(11.3, 11.3)   // 2.26 and 1.84 mm from (10, 10)
        XCTAssertFalse(LatticeRegionMask.contains(point(r, corner, depth: 1), region: r))
        XCTAssertTrue(LatticeRegionMask.contains(point(r, nearCorner, depth: 1), region: r))
        XCTAssertEqual(try core(r, [point(r, corner, depth: 1), point(r, nearCorner, depth: 1)]), [false, true],
                       "★ core reads the round corner the preview draws")
        XCTAssertEqual(try core(r, [point(r, corner, depth: 1)], wire: mitredWire(r)), [true],
                       "★ control: today's mitred wire claims the corner")
    }

    /// ★ The seam strip is the SAME at every depth (P1: the flare is retired) — preview and core.
    func testASeamStripIsAVerticalPrism() throws {
        // a 10 mm square whose +x edge (edge 1) is a diverging seam: tilt 0.5, neighbour as deep → 2 mm at depth 4
        let r = face([square(0, 0, 10, 10)], depth: 4, seams: [[false, true, false, false]], tilts: [[0, 0.5, 0, 0]], caps: [[0, 4, 0, 0]])
        let inStrip = SIMD2(11.5, 5.0), pastStrip = SIMD2(12.5, 5.0)
        for s in [0.1, 2.0, 3.9] {
            XCTAssertTrue(LatticeRegionMask.contains(point(r, inStrip, depth: s), region: r), "1.5 mm past the seam at depth \(s)")
            XCTAssertFalse(LatticeRegionMask.contains(point(r, pastStrip, depth: s), region: r), "2.5 mm past at depth \(s)")
        }
        XCTAssertEqual(try core(r, [0.1, 2.0, 3.9].map { point(r, inStrip, depth: $0) }), [true, true, true])
        XCTAssertEqual(try core(r, [0.1, 2.0, 3.9].map { point(r, pastStrip, depth: $0) }), [false, false, false])
        // ★ P2: no wedge past the seam's END — a point beyond the corner (10, 10), outside the strip
        let wedge = SIMD2(11.0, 10.8)
        XCTAssertFalse(LatticeRegionMask.contains(point(r, wedge, depth: 2), region: r))
        XCTAssertEqual(try core(r, [point(r, wedge, depth: 2)]), [false])
    }

    /// ★ THE PROOF on fixtures that exercise every rule — round grow, shrink, a hole, a diverging seam with an
    /// expand: thousands of points, the preview's own containment against core's region_contains through the
    /// bridge, every point outside a 0.01 mm band agreeing. Bridge cost and vertex counts recorded.
    func testThePreviewAndCoreAgreeEverywhereOutsideATenMicronBand() throws {
        let fixtures: [(String, LatticeRegionSpec)] = [
            ("grow 2", face([square(0, 0, 10, 10)], expand: 2)),
            ("shrink 1.5", face([square(0, 0, 10, 10)], expand: -1.5)),
            ("hole, grow 1", face([square(0, 0, 20, 20), square(8, 8, 12, 12)], expand: 1)),
            ("seam + grow 1", face([square(0, 0, 10, 10)], expand: 1, depth: 4, seams: [[false, true, false, false]],
                                   tilts: [[0, 0.5, 0, 0]], caps: [[0, 4, 0, 0]])),
            ("notch, grow 1", face([[SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 10), SIMD2(10.5, 10), SIMD2(10.5, 7),
                                     SIMD2(9.5, 7), SIMD2(9.5, 10), SIMD2(0, 10)]], expand: 1)),
        ]
        var rows: [String] = []
        for (name, r) in fixtures {
            var pts: [SIMD3<Double>] = [], uvs: [SIMD2<Double>] = []
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<4000 {
                let uv = SIMD2(Double.random(in: -4...24, using: &rng), Double.random(in: -4...24, using: &rng))
                guard toBoundary(r, uv) > 0.01 else { continue }
                uvs.append(uv); pts.append(point(r, uv, depth: Double.random(in: 0.05...(r.depthMM - 0.05), using: &rng)))
            }
            let t0 = Date()
            let c = try core(r, pts)
            let dt = Date().timeIntervalSince(t0)
            let p = pts.map { LatticeRegionMask.contains($0, region: r) }
            let disagree = zip(c, p).filter { $0 != $1 }.count
            XCTAssertEqual(disagree, 0, "★ \(name): \(disagree) of \(pts.count) disagree")
            let mitred = try core(r, pts, wire: mitredWire(r))
            let mDisagree = zip(mitred, p).filter { $0 != $1 }.count
            let verts = r.outlinePolygon.map(\.count).reduce(0, +)
            rows.append(String(format: "%@: %d points, %d disagree (mitred wire: %d); %d vertices; core %.1f ms",
                               name, pts.count, disagree, mDisagree, verts, dt * 1000))
        }
        print("ONE-OUTLINE proof\n  " + rows.joined(separator: "\n  "))
    }

    /// ★ P3: arcs are INSIDE chords within 0.01 mm — every capsule chord's midpoint lies within the expand of a true
    /// edge, and no more than 0.01 mm short of it.
    func testArcChordsAreInsideAndWithinTenMicrons() {
        let r = face([square(0, 0, 10, 10), square(20, 0, 30, 10)], expand: 2.5)
        var worst = 0.0, outward = 0
        for loop in r.outlinePolygon {
            for i in loop.indices {
                let mid = 0.5 * (loop[i] + loop[(i + 1) % loop.count])
                let sd = LatticeFaceOutline.signedDistance(mid, loops: r.outlineLoops)
                guard sd > 0.5 else { continue }   // a capsule edge, outside the raw outline
                let gap = r.inPlaneOffsetMM - sd
                if gap < -1e-6 { outward += 1 }
                worst = Swift.max(worst, gap)
            }
        }
        XCTAssertEqual(outward, 0, "★ no chord stands outside its arc")
        XCTAssertLessThanOrEqual(worst, 0.01, "★ the largest chord gap")
        print(String(format: "ONE-OUTLINE largest chord gap %.4f mm", worst))
    }
}

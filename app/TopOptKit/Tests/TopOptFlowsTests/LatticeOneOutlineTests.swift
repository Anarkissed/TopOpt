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

    /// ★★ THE BAND'S DATUM IS THE EXPANDED EDGE (the reviewer, 2026-10-10 23:32, (ii): "at a true edge, the
    /// band's solid width is measured from the polygon's boundary. With an expand, that is the expanded edge, not
    /// the raw one. The band is the subject of the beam measure, so its datum must be pinned.") A 16 mm square
    /// face grown 4 mm (the polygon is the 24 mm square, round corners) and a 1.21 mm band (the preview's band at
    /// a 1.719 mm voxel): `inPlaneDistance` is 0 on the expanded edge and 4 on the raw one; the bake keeps every
    /// whole base cell the band's width clear of the EXPANDED edge, and its whole cells reach past the RAW edge
    /// into the expand ring — which a raw-edge datum (cells ≥ 1.21 mm inside ±8 mm) could not do.
    func testTheBandIsMeasuredFromTheExpandedEdge() throws {
        let n = 44, origin = SIMD3<Float>(-2, -2, -2)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let p = SIMD3<Float>(Float(i), Float(j), Float(k)) + origin + 0.5
            if p.x > 0, p.x < 40, p.y > 0, p.y < 40, p.z > 0, p.z < 40 { vals[(k * n + j) * n + i] = 1 }
        }}}
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(20, 0, 20); r.normal = SIMD3(0, 1, 0); r.halfUMM = 19; r.halfWMM = 19; r.depthMM = 12
        r.outlineLoops = [square(-8, -8, 8, 8)]
        r.inPlaneOffsetMM = 4
        let band = 1.21
        // the distance's datum, at a true edge: 0 on the expanded edge, the band's width inside it, 4 on the raw edge
        XCTAssertEqual(r.inPlaneDistance(SIMD2(12, 0)), 0, accuracy: 1e-6, "★ zero on the expanded edge")
        XCTAssertEqual(r.inPlaneDistance(SIMD2(12 - band, 0)), band, accuracy: 1e-6)
        XCTAssertEqual(r.inPlaneDistance(SIMD2(8, 0)), 4, accuracy: 1e-6, "the raw edge is 4 mm inside it")
        XCTAssertLessThan(r.inPlaneDistance(SIMD2(12.5, 0)), 0, "outside the polygon")
        let sp = SIMD3<Float>(repeating: 1)
        let occ = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: sp, values: vals)
        let dem = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: sp,
                                   values: [Float](repeating: 0.3, count: vals.count))
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let field = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: occ, demand: dem, regions: [r], cellMM: [6], lineWidthMM: 0.45, realFloorMM: 2.25,
            shapeFitBandMM: 0, shapeFit: false, solidBandMM: band, densityLo: 0.1, densityHi: 0.3, densityGamma: 1,
            latticeID: "octet", dyadicSteps: true, stats: &st))
        let (bu, bv) = LatticeRegionMask.basis(LatticeRegionMask.unit(r.normal))
        func uv(_ p: SIMD3<Double>) -> SIMD2<Double> { let d = p - r.origin; return SIMD2(simd_dot(d, bu), simd_dot(d, bv)) }
        // ★ the bake tests each corner nudged eps = min(0.05·S, 0.2) mm into the cell on every axis (`fits`), so a whole
        // cell's TRUE corner may stand up to eps (√2·eps at a round corner) inside the band: measured and reported
        var whole = 0, reachPastRaw = 0, tooClose: [String] = [], trueCornerMin = Double.greatestFiniteMagnitude
        for c in field.steppedCells where c.sizeMM > 3.0 + 1e-6 {   // the 6 mm base cells: only ever laid whole
            whole += 1
            let eps = Swift.min(0.05 * c.sizeMM, 0.2)
            var nudged = Double.greatestFiniteMagnitude, outermost = 0.0
            for cx in 0...1 { for cz in 0...1 {
                let corner = c.originMM + SIMD3(Double(cx), 0, Double(cz)) * c.sizeMM
                let sgn = SIMD3<Double>(cx == 0 ? 1 : -1, 0, cz == 0 ? 1 : -1)
                nudged = Swift.min(nudged, r.inPlaneDistance(uv(corner + sgn * eps)))
                trueCornerMin = Swift.min(trueCornerMin, r.inPlaneDistance(uv(corner)))
                let q = uv(corner)
                outermost = Swift.max(outermost, Swift.max(abs(q.x), abs(q.y)))
            }}
            if nudged < band - 1e-9 { tooClose.append(String(format: "(%.2f, %.2f) %.3f", c.originMM.x, c.originMM.z, nudged)) }
            if outermost > 8 + 1e-6 { reachPastRaw += 1 }
        }
        print("ONE-OUTLINE band datum: \(whole) whole 6 mm cells, \(reachPastRaw) reach past the raw edge; "
              + String(format: "nearest TRUE corner %.3f mm from the expanded edge (band %.2f); cells %d",
                       trueCornerMin, band, field.steppedCells.count))
        XCTAssertGreaterThanOrEqual(trueCornerMin, band - 0.2 * 2.0.squareRoot() - 1e-6, "within the bake's eps")
        XCTAssertGreaterThan(whole, 0, "control: base cells are laid")
        XCTAssertEqual(tooClose, [], "★ no whole cell inside the band (at the bake's own test points), from the EXPANDED edge")
        XCTAssertGreaterThan(reachPastRaw, 0, "★ whole cells reach into the expand ring: the datum is not the raw edge")
        // CONTROL: the same face with no expand — the polygon IS the raw square, and no whole cell reaches past it
        var raw = r; raw.inPlaneOffsetMM = 0
        var st0 = LatticePreviewOccupancy.OctreeBakeStats()
        let f0 = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: occ, demand: dem, regions: [raw], cellMM: [6], lineWidthMM: 0.45, realFloorMM: 2.25,
            shapeFitBandMM: 0, shapeFit: false, solidBandMM: band, densityLo: 0.1, densityHi: 0.3, densityGamma: 1,
            latticeID: "octet", dyadicSteps: true, stats: &st0))
        let past0 = f0.steppedCells.filter { c in
            c.sizeMM > 3.0 + 1e-6 && [0.0, 1.0].contains { cx in [0.0, 1.0].contains { cz in
                let q = uv(c.originMM + SIMD3(cx, 0, cz) * c.sizeMM); return Swift.max(abs(q.x), abs(q.y)) > 8 + 1e-6 } }
        }.count
        XCTAssertEqual(past0, 0, "control: with no expand no whole cell passes the raw edge")
    }
}

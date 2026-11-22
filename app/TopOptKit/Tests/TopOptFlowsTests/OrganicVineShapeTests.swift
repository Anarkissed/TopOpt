// OrganicVineShapeTests — the vines as the preview draws them (his 11-19 note; LatticeReview's conditions 21:56Z): smooth
// through the engine's points, never further than 0.2 mm from its bars, the bar ends never moved, joints where vines meet
// (end-end and T, never a near-miss found by the app). RED CONTROL: the clamp off lets the curve swing further.
// His later pick 11-19: the app draws `capsules(runs:)` (release (10)'s round struts); the smooth shape is parked for v2 and
// keeps its tests so it can come back.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class OrganicVineShapeTests: XCTestCase {

    func run(_ pts: [SIMD3<Float>], width: Float = 1.0) -> LatticeLayoutSession.Run {
        LatticeLayoutSession.Run(region: 1, marks: [], endA: 0, endB: 0, points: pts,
                                 widthMM: [Float](repeating: width, count: pts.count), spacingMM: [Float](repeating: 4, count: pts.count))
    }

    func testTheCurvePassesThroughEveryPointAndStaysOnTheBars() {
        // a zig-zag with sharp corners: the spline would swing well past its bars
        let pts: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(4, 3, 0), SIMD3(8, 0, 0), SIMD3(12, 3, 0), SIMD3(16, 0, 0)]
        let s = OrganicVineShape(runs: [run(pts)])
        XCTAssertGreaterThan(s.pieces.count, pts.count - 1, "★ the curve is sampled between the engine's points")
        // every engine point is a piece end (the bar ends never move)
        let ends = Set(s.pieces.flatMap { [$0.a, $0.b] }.map { SIMD3<Int32>(($0 * 1000).rounded(.toNearestOrEven)) })
        for p in pts { XCTAssertTrue(ends.contains(SIMD3<Int32>((p * 1000).rounded(.toNearestOrEven))), "★ \(p) is on the curve") }
        // the largest departure from the bar each piece smooths
        func worst(_ s: OrganicVineShape) -> Float {
            var w: Float = 0
            for q in s.pieces {
                let bars = zip(pts, pts.dropFirst())
                let d = bars.map { OrganicVineShape.offset(q.b, $0.0, $0.1) }.min() ?? 0
                w = Swift.max(w, d)
            }
            return w
        }
        XCTAssertLessThanOrEqual(worst(s), 0.2 + 1e-4, "★ within 0.2 mm of the bars (core's organic_smooth_max_offset_mm)")
        var loose = OrganicVineShape.Params(); loose.maxOffsetMM = .greatestFiniteMagnitude
        XCTAssertGreaterThan(worst(OrganicVineShape(runs: [run(pts)], params: loose)), 0.3, "RED CONTROL: no clamp swings further")
        // smooth: consecutive pieces turn by little except where the clamp bends them back at a corner
        XCTAssertTrue(s.pieces.allSatisfy { $0.ra == 0.5 && $0.rb == 0.5 }, "the radius is half the width")
    }

    func testAStraightRunIsOnePiecePerBar() {
        let pts: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]
        XCTAssertEqual(OrganicVineShape(runs: [run(pts)]).pieces.count, 2, "★ nothing to bend: no extra pieces")
    }

    func testJointsWhereVinesMeetOnly() {
        // a T: run 1 ends on run 0's middle; run 2 far away
        let a = run([SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(10, 0, 0)])
        let b = run([SIMD3(5, 6, 0), SIMD3(5, 0.2, 0)])
        let c = run([SIMD3(0, 20, 0), SIMD3(10, 20, 0)])
        let s = OrganicVineShape(runs: [a, b, c])
        XCTAssertFalse(s.joints.isEmpty, "★ the T is a joint")
        for j in s.joints {
            let vines = Set(j.pieces.map { s.pieces[Int($0)].vine })
            XCTAssertTrue(vines.count >= 2, "a joint blends two vines or more")
            XCTAssertFalse(vines.contains(2), "★ the far vine is in no joint")
            XCTAssertLessThanOrEqual(j.pieces.count, OrganicVineShape.maxJointPieces)
        }
        var off = OrganicVineShape.Params(); off.blendMM = 0
        XCTAssertTrue(OrganicVineShape(runs: [a, b, c], params: off).joints.isEmpty, "RED CONTROL: no blend, no joints")
    }

    /// ★ His pick 11-19 ("I prefer release 10's ... more like vines and less like 'goo'"): release (10)'s round struts.
    @MainActor
    func testCapsulesAreReleaseTensRoundStruts() {
        // a bent run whose widths change point to point, and a T landing on it
        var a = run([SIMD3(0, 0, 0), SIMD3(4, 3, 0), SIMD3(8, 0, 0)])
        a.widthMM = [1.0, 2.0, 1.2]
        let b = run([SIMD3(4, 9, 0), SIMD3(4, 3, 0)], width: 0.8)
        let s = OrganicVineShape.capsules(runs: [a, b])
        XCTAssertEqual(s.pieces.count, 3, "★ one straight piece per bar, nothing curved")
        let bars = LatticeLayoutPreview.segments([a, b])
        for (k, q) in s.pieces.enumerated() {
            XCTAssertEqual(q.ra, q.rb, "★ one width along a bar")
            XCTAssertEqual(q.ra, 0.5 * bars.bars[7 * k + 6], accuracy: 1e-6, "★ the width release (10) drew: the two points' mean")
            XCTAssertEqual(simd_length(q.a - SIMD3(bars.bars[7 * k], bars.bars[7 * k + 1], bars.bars[7 * k + 2])), 0, accuracy: 1e-6)
            XCTAssertEqual(simd_length(q.b - SIMD3(bars.bars[7 * k + 3], bars.bars[7 * k + 4], bars.bars[7 * k + 5])), 0, accuracy: 1e-6)
            let d = simd_normalize(q.b - q.a)
            XCTAssertEqual(simd_dot(q.ta, d), 1, accuracy: 1e-5, "both rings square to the bar: a plain cylinder")
            XCTAssertEqual(simd_dot(q.tb, d), 1, accuracy: 1e-5)
        }
        XCTAssertEqual(s.caps.count, 3 + 2, "★ a round ball at every point")
        XCTAssertEqual(s.caps[1].w, 0.8, accuracy: 1e-6,   // bars there: 0.75 (1.0 to 2.0) and 0.8 (2.0 to 1.2)
                       "★ the bend's ball as wide as the widest bar there: a round knuckle")
        XCTAssertTrue(s.joints.isEmpty, "★ nothing blended: a plain union")
        XCTAssertEqual(s.params.blendMM, 0)
        XCTAssertFalse(OrganicVineShape(runs: [a, b]).joints.isEmpty, "RED CONTROL: the parked smooth shape blends the T")
    }

    /// ★ His rule 11-19: "The drawing follows the print file. Always." The file's tube rule (LatticeReview 01:39Z / 01:52Z).
    func testTubesFollowThePrintFilesRule() {
        // a gentle bend (30 degrees), then a sharp one (90 degrees); its start a node, its end cut by the part's surface
        let p: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(4 + 4 * cos(.pi / 6), 4 * sin(.pi / 6), 0),
                                 SIMD3(4 + 4 * cos(.pi / 6), 4 * sin(.pi / 6) + 4, 0)]
        var r = run(p)
        r.widthMM = [1.0, 1.2, 1.4, 1.4]
        r.endA = 0; r.endB = 2
        let s = OrganicVineShape.tubes(runs: [r])
        XCTAssertEqual(s.pieces.count, 3, "★ one piece per bar")
        XCTAssertTrue(s.joints.isEmpty, "★ nothing blended")
        for (k, q) in s.pieces.enumerated() {
            XCTAssertEqual(q.ra, r.widthMM[k] / 2, accuracy: 1e-6, "★ the ring has its point's width; the tube tapers between")
            XCTAssertEqual(q.rb, r.widthMM[k + 1] / 2, accuracy: 1e-6)
        }
        // the gentle bend is a MITRE: both bars' rings are one ring, on the bisecting plane, point for point
        let m = simd_normalize(simd_normalize(p[1] - p[0]) + simd_normalize(p[2] - p[1]))
        var worstGap: Float = 0, worstOff: Float = 0
        for i in 0..<16 {
            let ang = Float(i) * 2 * .pi / 16
            let e = OrganicVineShape.tubeRingPoint(s.pieces[0], atB: true, angle: ang)
            let f = OrganicVineShape.tubeRingPoint(s.pieces[1], atB: false, angle: ang)
            worstGap = Swift.max(worstGap, simd_length(e - f))
            worstOff = Swift.max(worstOff, abs(simd_dot(e - p[1], m)))
        }
        XCTAssertLessThan(worstGap, 1e-4, "★ a mitre: no crack, no twist")
        XCTAssertLessThan(worstOff, 1e-4, "★ the ring lies on the plane bisecting the two bars")
        // balls: the node start, the sharp turn (the tube ends and starts again); none at the mitre, none at the cut end
        func ballAt(_ q: SIMD3<Float>) -> Bool { s.caps.contains { simd_length(SIMD3($0.x, $0.y, $0.z) - q) < 1e-5 } }
        XCTAssertTrue(ballAt(p[0]), "★ a node end is round")
        XCTAssertFalse(ballAt(p[1]), "★ no ball at a gentle bend")
        XCTAssertTrue(ballAt(p[2]), "★ a turn over 60 degrees ends the tube: round")
        XCTAssertFalse(ballAt(p[3]), "★ an end cut by the part's surface is flat")
        XCTAssertTrue(s.pieces[2].flatB, "★ and closed by a flat disc, never hollow")
        XCTAssertFalse(s.pieces[0].flatA, "a round end needs no disc")
        XCTAssertFalse(s.pieces[0].flatB || s.pieces[1].flatA || s.pieces[1].flatB || s.pieces[2].flatA, "no disc inside a run")
        r.endB = 1
        XCTAssertFalse(OrganicVineShape.tubes(runs: [r]).caps.contains { simd_length(SIMD3($0.x, $0.y, $0.z) - p[3]) < 1e-5 },
                       "★ an end in the solid is flat")
        r.endB = 4
        XCTAssertTrue(OrganicVineShape.tubes(runs: [r]).caps.contains { simd_length(SIMD3($0.x, $0.y, $0.z) - p[3]) < 1e-5 },
                      "★ a joined end is round")
        // the sharp turn's rings are square to their own bars
        let sq = OrganicVineShape.tubeRingPoint(s.pieces[1], atB: true, angle: 0.7) - p[2]
        XCTAssertEqual(simd_dot(sq, simd_normalize(p[2] - p[1])), 0, accuracy: 1e-4, "★ a split's ring is square")
        XCTAssertEqual(OrganicVineShape.capsules(runs: [r]).caps.count, 4, "RED CONTROL: release (10)'s drawing balls every point")
    }

    /// ★ The print file's bridges (packed version 2's section; weave_tubes.cpp sweep_section): the D or the square bar, side
    /// level, flat side down, the mitre ring the mean of the two bars' sections; every end flat, no ball.
    func testBridgesAreTheFilesSections() {
        // a shallow run turning 30 degrees in plan, rising a little
        let p: [SIMD3<Float>] = [SIMD3(0, 0, 5), SIMD3(4, 0, 5.4), SIMD3(4 + 4 * cos(.pi / 6), 4 * sin(.pi / 6), 5.8)]
        var r = run(p)
        r.widthMM = [1.0, 1.2, 1.2]
        r.section = 1
        let s = OrganicVineShape.tubes(runs: [r])
        XCTAssertEqual(OrganicVinePass.sides, 16, "premise: sectionPoint's default is the pass's side count")
        XCTAssertEqual(s.pieces.count - s.pucks, 2)
        XCTAssertEqual(s.pucks, 2, "★ OS1 B: its two node ends are pucks")
        XCTAssertTrue(s.capDomes.allSatisfy { $0 } && s.caps.count == 2, "★ a bridge has no whole ball anywhere: dome tops only")
        XCTAssertTrue(s.pieces[0].flatA && s.pieces[1].flatB, "★ both its pieces' ends flat")
        XCTAssertTrue(s.pieces.prefix(2).allSatisfy { $0.section == 1 })
        // the mitre: both pieces' rings are one ring (the mean of the two sections pushed onto the bisecting plane)
        var worst: Float = 0
        for j in 0..<OrganicVinePass.sides {
            worst = Swift.max(worst, simd_length(OrganicVineShape.sectionRingPoint(s.pieces[0], atB: true, j)
                                                 - OrganicVineShape.sectionRingPoint(s.pieces[1], atB: false, j)))
        }
        XCTAssertLessThan(worst, 1e-4, "★ no crack at a bridge's bend")
        // a square end: the D itself, its underside level and down, as wide as the bar
        let t = simd_normalize(p[1] - p[0])
        let f = OrganicVineShape.sectionFrame(t, fallback: s.pieces[0].va)
        XCTAssertEqual(f.side.z, 0, accuracy: 1e-6, "★ its side is level")
        XCTAssertGreaterThan(f.up.z, 0, "★ its flat side down")
        let c0 = OrganicVineShape.sectionRingPoint(s.pieces[0], atB: false, 0), c1 = OrganicVineShape.sectionRingPoint(s.pieces[0], atB: false, 1)
        XCTAssertEqual(simd_length(c1 - c0), 1.0, accuracy: 1e-5, "★ the underside as wide as the bar")
        XCTAssertEqual(simd_dot(c0 - p[0], f.up), -0.5, accuracy: 1e-5, "★ half a width below the centre line")
        let top = OrganicVineShape.sectionRingPoint(s.pieces[0], atB: false, 2 + (OrganicVinePass.sides - 3) / 2)
        XCTAssertGreaterThan(simd_dot(top - p[0], f.up), 0.49, "★ the round top")
        r.section = 2
        let sq = OrganicVineShape.tubes(runs: [r])
        let corner = OrganicVineShape.sectionRingPoint(sq.pieces[0], atB: false, OrganicVinePass.sides / 2)
        XCTAssertEqual(simd_dot(corner - p[0], f.up), 0.5, accuracy: 1e-5, "★ the square bar's top is flat")
        r.section = 0
        XCTAssertFalse(OrganicVineShape.tubes(runs: [r]).caps.isEmpty, "RED CONTROL: a round run's node ends are balls")
    }

    /// ★ The flat cut (his 11-20 skin note): what reaches the part's surface carries that surface's plane; what does not,
    /// and what the file lets stand proud, carries none.
    func testTheFlatCutFindsThePartsSurface() throws {
        // a box 0..20 x 0..10 x 0..20, both windings
        let v: [Float] = [0, 0, 0, 20, 0, 0, 20, 10, 0, 0, 10, 0, 0, 0, 20, 20, 0, 20, 20, 10, 20, 0, 10, 20]
        let outward: [Int32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
        let inward = stride(from: 0, to: outward.count, by: 3).flatMap { [outward[$0], outward[$0 + 2], outward[$0 + 1]] }
        for idx in [outward, inward] {
            let surface = OrganicVineShape.CutSurface(vertices: v, indices: idx)
            var top = run([SIMD3(2, 10, 10), SIMD3(10, 10, 10), SIMD3(18, 10, 10)], width: 2)   // ON the face y = 10
            top.marks = .net
            let inside = run([SIMD3(2, 5, 5), SIMD3(18, 5, 5)], width: 1)
            var proud = run([SIMD3(10, 10, 2), SIMD3(10, 10, 18)], width: 2)
            proud.proudMM = 0.5
            var s = OrganicVineShape.tubes(runs: [top, inside, proud])
            s.cut(runs: [top, inside, proud], surface: surface)
            for q in s.pieces where q.vine == 0 {
                let c = try XCTUnwrap(q.cut, "★ a vine on the face is cut")
                XCTAssertFalse(c.union, "a box is convex")
                XCTAssertEqual(c.planes.first?.y ?? 0, 1, accuracy: 1e-5, "★ the nearest: the face's outward normal")
                XCTAssertEqual(c.planes.first?.w ?? 0, -10, accuracy: 1e-4, "★ its plane, y = 10")
                let mid = (q.a + q.b) / 2
                XCTAssertTrue(c.outside(mid + SIMD3(0, 0.5, 0)), "★ above the face: outside")
                XCTAssertFalse(c.outside(mid - SIMD3(0, 0.5, 0)), "★ under it: inside")
            }
            XCTAssertTrue(s.pieces.filter { $0.vine == 1 }.allSatisfy { !$0.isCut }, "★ a vine inside is never cut")
            XCTAssertTrue(s.pieces.filter { $0.vine == 2 }.allSatisfy { !$0.isCut }, "★ a run the file lets stand proud is left whole")
            XCTAssertEqual(s.capCuts.count, s.caps.count)
            for k in s.caps.indices { XCTAssertEqual(s.capCuts[k] != nil, s.capVines[k] == 0, "★ only the face's run's ends are cut") }
            // a net bar wrapping the box's top edge: both faces (a convex edge)
            let edge = run([SIMD3(10, 10, 19.8), SIMD3(10, 10, 20.2)], width: 2)
            var e = OrganicVineShape.tubes(runs: [edge])
            e.cut(runs: [edge], surface: surface)
            let c = try XCTUnwrap(e.pieces[0].cut)
            XCTAssertGreaterThanOrEqual(c.planes.count, 2, "★ both faces where the piece wraps a convex edge")
            XCTAssertTrue(c.outside(SIMD3(10, 10.5, 20.5)), "★ past the edge: outside")
            XCTAssertFalse(c.outside(SIMD3(10, 9.5, 19.5)), "★ under both faces: inside")
            XCTAssertTrue(c.outside(SIMD3(10, 9.5, 20.5)), "★ past one face of a convex edge: outside")
        }
    }

    /// ★ Two struts crossing on a CURVED face (a faceted cylinder) are cut alike: every point both reach is inside or outside
    /// the part for both, as the part's own facets say (the dashed seams on his curved faces were two cuts a hair apart).
    /// RED CONTROL: each cut by its nearest facet alone disagrees with the part.
    func testCrossingStrutsOnACurvedFaceAreCutAlike() throws {
        let R: Float = 15, sides = 48
        var v: [Float] = [], idx: [Int32] = []
        func tri(_ p: [SIMD3<Float>], _ n: SIMD3<Float>) {
            let base = Int32(v.count / 3)
            for q in p { v += [q.x, q.y, q.z] }
            idx += simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) < 0 ? [base, base + 2, base + 1] : [base, base + 1, base + 2]
        }
        func on(_ x: Float, _ k: Int) -> SIMD3<Float> {
            let a = Float(k) * 2 * .pi / Float(sides)
            return SIMD3(x, R * cos(a), R * sin(a))
        }
        for k in 0..<sides {   // the sides (axis along x, 0 to 40) and the two ends
            let n = SIMD3<Float>(0, cos((Float(k) + 0.5) * 2 * .pi / Float(sides)), sin((Float(k) + 0.5) * 2 * .pi / Float(sides)))
            tri([on(0, k), on(40, k), on(40, k + 1)], n)
            tri([on(0, k), on(40, k + 1), on(0, k + 1)], n)
            tri([SIMD3(0, 0, 0), on(0, k), on(0, k + 1)], SIMD3(-1, 0, 0))
            tri([SIMD3(40, 0, 0), on(40, k), on(40, k + 1)], SIMD3(1, 0, 0))
        }
        let surface = OrganicVineShape.CutSurface(vertices: v, indices: idx)
        // A round the cylinder at x = 20, B along it over the top; they cross at (20, 0, 15)
        let a = run((0...4).map { i -> SIMD3<Float> in let t = Float(60 + 15 * i) * .pi / 180; return SIMD3(20, R * cos(t), R * sin(t)) }, width: 2)
        let b = run((0...4).map { SIMD3(15 + 2.5 * Float($0), 0, R) }, width: 2)
        var s = OrganicVineShape.tubes(runs: [a, b])
        s.cut(runs: [a, b], surface: surface)
        func piece(_ vine: Int32, _ p: SIMD3<Float>) -> OrganicVineShape.Piece? {
            s.pieces.first { $0.vine == vine && OrganicVineShape.offset(p, $0.a, $0.b) <= $0.ra && simd_dot(p - $0.a, $0.b - $0.a) >= 0
                && simd_dot(p - $0.b, $0.a - $0.b) >= 0 }
        }
        // the part's own inside: inside every facet (a cylinder is convex)
        let all = OrganicVineShape.CutSurface(vertices: v, indices: idx)
        func truth(_ p: SIMD3<Float>) -> Bool { all.tris.contains { simd_dot(SIMD3($0.plane.x, $0.plane.y, $0.plane.z), p) + $0.plane.w > 1e-4 } }
        var both = 0, disagree = 0, wrong = 0, nearestWrong = 0
        for i in 0..<41 { for j in 0..<41 { for h in 0..<9 {
            let x = 19.2 + 0.04 * Float(i), ang = (84 + 0.3 * Float(j)) * .pi / 180, rr = R - 0.5 + 0.08 * Float(h)
            let p = SIMD3<Float>(x, rr * cos(ang), rr * sin(ang))
            guard let qa = piece(0, p), let qb = piece(1, p), let ca = qa.cut, let cb = qb.cut else { continue }
            both += 1
            if ca.outside(p) != cb.outside(p) { disagree += 1 }
            if ca.outside(p) != truth(p) { wrong += 1 }
            if OrganicVineShape.Cut(planes: [ca.planes[0]], union: false).outside(p) != truth(p) { nearestWrong += 1 }
        } } }
        print("VINE CUT CURVED: \(both) points in both struts; disagree \(disagree), wrong \(wrong); nearest facet alone wrong at \(nearestWrong)")
        XCTAssertGreaterThan(both, 500, "premise: the two struts overlap where they cross")
        XCTAssertEqual(disagree, 0, "★ the two struts are cut alike")
        XCTAssertEqual(wrong, 0, "★ and as the part's own facets say")
        XCTAssertGreaterThan(nearestWrong, 0, "RED CONTROL: one facet per strut is not the part's surface")
    }

    /// ★ A concave corner (an L's inner edge): the part is the UNION of its two faces' half-spaces (the cut's `union`); a vine
    /// curving round the inner corner keeps what lies under either face.
    func testTheFlatCutAtAConcaveCorner() throws {
        // an L in plan, (0,0) (20,0) (20,10) (10,10) (10,20) (0,20), 10 deep in z
        var v: [Float] = [], idx: [Int32] = []
        func quad(_ p: [SIMD3<Float>], _ n: SIMD3<Float>) {
            let base = Int32(v.count / 3)
            for q in p { v += [q.x, q.y, q.z] }
            let flip = simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), n) < 0
            idx += flip ? [base, base + 2, base + 1, base, base + 3, base + 2] : [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let ring: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 10), SIMD2(10, 10), SIMD2(10, 20), SIMD2(0, 20)]
        for k in 0..<6 {   // the sides, outward to the right of each edge (the ring runs anticlockwise)
            let a = ring[k], b = ring[(k + 1) % 6], d = b - a
            quad([SIMD3(a.x, a.y, 0), SIMD3(b.x, b.y, 0), SIMD3(b.x, b.y, 10), SIMD3(a.x, a.y, 10)], SIMD3(d.y, -d.x, 0))
        }
        for (z, n) in [(Float(0), SIMD3<Float>(0, 0, -1)), (10, SIMD3<Float>(0, 0, 1))] {   // the ends: two rectangles each
            quad([SIMD3(0, 0, z), SIMD3(20, 0, z), SIMD3(20, 10, z), SIMD3(0, 10, z)], n)
            quad([SIMD3(0, 10, z), SIMD3(10, 10, z), SIMD3(10, 20, z), SIMD3(0, 20, z)], n)
        }
        let surface = OrganicVineShape.CutSurface(vertices: v, indices: idx)
        let r = run([SIMD3(13, 10, 5), SIMD3(10, 13, 5)], width: 2)   // from the face y = 10 round to the face x = 10
        var s = OrganicVineShape.tubes(runs: [r])
        s.cut(runs: [r], surface: surface)
        let c = try XCTUnwrap(s.pieces[0].cut)
        XCTAssertTrue(c.union, "★ a concave corner: the part is inside either face")
        XCTAssertEqual(c.planes.count, 2)
        XCTAssertFalse(c.outside(SIMD3(12, 9, 5)), "★ under the face y = 10: inside")
        XCTAssertFalse(c.outside(SIMD3(9, 12, 5)), "★ behind the face x = 10: inside")
        XCTAssertTrue(c.outside(SIMD3(11, 11, 5)), "★ in the corner's open air: outside")
        let meet = OrganicVineShape.Cut(planes: c.planes, union: false)
        XCTAssertTrue(meet.outside(SIMD3(12, 9, 5)) || meet.outside(SIMD3(9, 12, 5)),
                      "RED CONTROL: read as convex, the corner would cut away vine that is inside the part")
    }
}

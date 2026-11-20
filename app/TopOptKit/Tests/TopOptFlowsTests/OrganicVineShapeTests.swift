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
}

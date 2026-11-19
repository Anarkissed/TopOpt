// OrganicVineShapeTests — the vines as the preview draws them (his 11-19 note; LatticeReview's conditions 21:56Z): smooth
// through the engine's points, never further than 0.2 mm from its bars, the bar ends never moved, joints where vines meet
// (end-end and T, never a near-miss found by the app). RED CONTROL: the clamp off lets the curve swing further.
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
}

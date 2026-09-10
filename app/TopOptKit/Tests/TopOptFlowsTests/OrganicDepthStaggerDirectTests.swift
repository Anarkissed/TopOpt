import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class OrganicDepthStaggerDirectTests: XCTestCase {
    func testTheStaggerMovesSpansItShouldMove() {
        var w = LatticeRegionSpec(role: .include, kind: .face)
        w.origin = SIMD3<Double>(20, 0, 20)
        w.normal = SIMD3<Double>(0, 1, 0)
        w.halfUMM = 14; w.halfWMM = 14; w.depthMM = 11
        w.outlineLoops = [[SIMD2(-14, -14), SIMD2(14, -14), SIMD2(14, 14), SIMD2(-14, 14)]]
        w.faceID = 15
        w.selectableKey = "f:x:15"
        // Spans at four depths, all well inside the outline.
        var spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)] = []
        for d in [1.0, 4.0, 7.0, 10.0] {
            spans.append((a: SIMD3(18, d, 20), b: SIMD3(22, d, 20), r: 0.5))
        }
        let out = OrganicDepthStagger.apply(spans: spans, regions: [w], cellMM: 3.0)
        var moved = 0
        for (i, s) in out.enumerated() where simd_length(s.a - spans[i].a) > 1e-9 { moved += 1 }
        print("── stagger moved \(moved) of \(spans.count) spans")
        for (i, s) in out.enumerated() {
            print(String(format: "   depth %.1f → shifted %.3f mm",
                         spans[i].a.y, simd_length(s.a - spans[i].a)))
        }
        XCTAssertEqual(moved, spans.count, "★ every span inside the region must move")
        // consecutive layers must land far apart
        let d0 = out[0].a - spans[0].a, d1 = out[1].a - spans[1].a
        print(String(format: "   layers 0 and 1 differ by %.3f mm", simd_length(d1 - d0)))
        // ★ HALF A PITCH between consecutive layers: enough to put a strut behind a
        // window, not so much that a layer re-registers on the NEXT strut along (which
        // is what a 0.93-cell offset did).
        XCTAssertEqual(simd_length(d1 - d0), 0.5 * 3.0, accuracy: 0.15 * 3.0,
                       "★ consecutive layers land half a pitch apart")
    }

    /// ★★★ A BLOCK WITH NO DECLARED FACE STAGGERS TOO (his walk, 2026-09-08: "almost no
    /// difference in the sample cube").
    ///
    /// The deformation takes its depth direction from a face region's normal, and the
    /// sample cube is a bare block with no region at all — so the guard returned every
    /// span untouched and the toggle did nothing on the cube however it was set. The
    /// caller names a fallback axis; for the cube that is the build direction, which is
    /// the direction a printer stacks and the one a viewer reads as layers.
    func testABlockWithNoRegionStaggersOnTheFallbackAxis() {
        var spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)] = []
        for d in [0.0, 3.0, 6.0, 9.0] {
            spans.append((a: SIMD3(0, 0, d), b: SIMD3(4, 0, d), r: 0.5))
        }
        // No regions, no fallback: unchanged, exactly as before.
        let none = OrganicDepthStagger.apply(spans: spans, regions: [], cellMM: 3.0)
        for (i, s) in none.enumerated() {
            XCTAssertEqual(simd_length(s.a - spans[i].a), 0, accuracy: 1e-12,
                           "no axis to stagger along ⇒ untouched")
        }
        // With the build direction named, every span moves and layers differ.
        let out = OrganicDepthStagger.apply(spans: spans, regions: [], cellMM: 3.0,
                                            fallbackAxis: SIMD3<Double>(0, 0, 1))
        var moved = 0
        for (i, s) in out.enumerated() where simd_length(s.a - spans[i].a) > 1e-9 { moved += 1 }
        let d0 = out[0].a - spans[0].a, d1 = out[1].a - spans[1].a
        print("── block fallback: moved \(moved) of \(spans.count); layers 0→1 differ by "
              + String(format: "%.3f mm", simd_length(d1 - d0)))
        XCTAssertGreaterThanOrEqual(moved, spans.count - 1,
                                    "★ the block's spans must move (layer 0 may sit at 0)")
        XCTAssertEqual(simd_length(d1 - d0), 0.5 * 3.0, accuracy: 0.15 * 3.0,
                       "★ and consecutive layers land half a pitch apart")
    }
}

import XCTest
import TopOptKit
import simd
@testable import TopOptFlows

/// ★ THE TOPOLOGY/THICKNESS SPLIT (2026-09-04): the bridge bakes the CENTRELINE
/// distance and the SURFACE distance. The surface channel must equal the old surface
/// bake exactly inside its footprint (nearest-centreline-minus-its-radius was tried
/// first and was off on 366 voxels of this fixture where radii differ); the centreline
/// channel is what a live uniform radius offsets. Pinned against
/// `OrganicSpanIndex.bakeField`, the surface bake the render tests already trust.
final class OrganicCentrelineFieldTests: XCTestCase {
    func testCentrelineMinusRadiusIsTheSurfaceDistance() throws {
        let spans: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)] = [
            (a: SIMD3(1, 1, 1), b: SIMD3(7, 1, 1), r: 0.3),
            (a: SIMD3(7, 1, 1), b: SIMD3(7, 6, 4), r: 0.5),
            (a: SIMD3(2, 5, 2), b: SIMD3(5, 5, 6), r: 0.21)]
        let dims = (40, 36, 34); let origin = SIMD3<Float>(0, 0, 0); let vox = 0.25; let band = 1.0
        let b = try XCTUnwrap(TopOptKit.organicSpansField(spans: spans, fieldDims: dims, fieldOrigin: SIMD3<Double>(origin),
                                                          fieldSpacingMM: vox, bandMM: band))
        XCTAssertEqual(b.spanCount, 3)
        XCTAssertEqual(b.reachMM, band + 0.5, accuracy: 1e-12, "reach = band + the largest radius")
        XCTAssertEqual(b.bandMM, band, accuracy: 1e-12)
        // the reference: the old surface SDF, per span reach r + band' — use a band big
        // enough that every voxel within OUR reach is exact in the reference too
        let idx = OrganicSpanIndex(gridOrigin: origin, gridSpacing: 1, gridDims: SIMD3<Int32>(10, 10, 10),
                                   segments: spans.map { OrganicSpanIndex.Segment(a: SIMD3<Float>($0.a), b: SIMD3<Float>($0.b), r: Float($0.r)) }, cellMM: 2)
        let ref = idx.bakeField(origin: origin, spacing: SIMD3<Float>(repeating: Float(vox)), dims: SIMD3<Int>(dims.0, dims.1, dims.2), bandMM: 3)
        var checked = 0, mismatches = 0
        for i in 0..<b.field.count where b.surfaceField[i] < Float(band) - 1e-4 {
            if abs(b.surfaceField[i] - ref.values[i]) > 1e-4 { mismatches += 1 }
            checked += 1
            // the centreline channel is never farther than the surface plus the thickest strut
            XCTAssertLessThanOrEqual(b.field[i], b.surfaceField[i] + 0.5 + 1e-4)
            XCTAssertGreaterThanOrEqual(b.field[i], b.surfaceField[i] + 0.21 - 1e-4)
        }
        XCTAssertEqual(mismatches, 0, "the surface channel IS the old surface bake inside its footprint")
        XCTAssertGreaterThan(checked, 1000, "the footprint was stamped")
        // outside every footprint: centreline reads reach, surface reads band — lower
        // bounds, never a false hit
        let outside = b.field.indices.filter { b.field[$0] >= Float(b.reachMM) - 1e-6 }
        XCTAssertFalse(outside.isEmpty)
        XCTAssertTrue(outside.allSatisfy { b.surfaceField[$0] >= Float(band) - 1e-6 })
    }
}

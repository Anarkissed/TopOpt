import XCTest
import simd
@testable import TopOptFlows

/// The tracer's grid is the preview's, not the coarse solve's (2026-09-21).
final class OrganicTraceGridTests: XCTestCase {

    /// A tensor linear in position is reproduced EXACTLY at every interior fine centre.
    func testALinearFieldResamplesExactlyAtTwiceTheResolution() throws {
        let (nx, ny, nz) = (6, 5, 4), h = 3.4, origin = SIMD3<Double>(1, 2, 3)
        func f(_ p: SIMD3<Double>, _ c: Int) -> Double { 0.5 * p.x - 0.25 * p.y + 2 * p.z + Double(c) * 10 }
        var t = [Double](repeating: 0, count: 6 * nx * ny * nz)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let p = origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * h
            for c in 0..<6 { t[6 * ((k * ny + j) * nx + i) + c] = f(p, c) }
        } } }
        let r = try XCTUnwrap(OrganicTraceGrid.resample(tensor: t, dims: (nx, ny, nz), originMM: origin,
                                                         spacingMM: h, toVoxelMM: 1.7))
        XCTAssertEqual(r.factor, 2)
        XCTAssertEqual(r.dims.0, 12); XCTAssertEqual(r.dims.1, 10); XCTAssertEqual(r.dims.2, 8)
        XCTAssertEqual(r.spacingMM, 1.7, accuracy: 1e-12)
        XCTAssertEqual(r.tensor.count, 6 * 12 * 10 * 8)
        var checked = 0
        for k in 1..<7 { for j in 1..<9 { for i in 1..<11 {
            let p = origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * r.spacingMM
            for c in 0..<6 {
                XCTAssertEqual(r.tensor[6 * ((k * 10 + j) * 12 + i) + c], f(p, c), accuracy: 1e-9)
                checked += 1
            }
        } } }
        XCTAssertGreaterThan(checked, 1000)
    }

    /// Already fine enough ⇒ nil, the caller keeps the solve's grid; a mismatched tensor ⇒ nil.
    func testAFieldAtOrBelowTheTargetIsLeftAlone() {
        let t = [Double](repeating: 1, count: 6 * 8)
        XCTAssertNil(OrganicTraceGrid.resample(tensor: t, dims: (2, 2, 2), originMM: .zero, spacingMM: 1.7, toVoxelMM: 1.7))
        XCTAssertNil(OrganicTraceGrid.resample(tensor: t, dims: (2, 2, 2), originMM: .zero, spacingMM: 2.2, toVoxelMM: 1.7),
                     "a ratio that rounds to 1 is no resample")
        XCTAssertNil(OrganicTraceGrid.resample(tensor: [1, 2, 3], dims: (2, 2, 2), originMM: .zero, spacingMM: 3.4, toVoxelMM: 1.7))
    }

    /// The voxel budget lowers the factor before it refuses.
    func testTheVoxelBudgetLowersTheFactor() throws {
        let t = [Double](repeating: 1, count: 6 * 1000)
        let r = try XCTUnwrap(OrganicTraceGrid.resample(tensor: t, dims: (10, 10, 10), originMM: .zero,
                                                         spacingMM: 4, toVoxelMM: 1, maxVoxels: 30_000))
        XCTAssertEqual(r.factor, 3, "×4 would be 64 000 voxels; ×3 is 27 000")
        XCTAssertNil(OrganicTraceGrid.resample(tensor: t, dims: (10, 10, 10), originMM: .zero,
                                               spacingMM: 4, toVoxelMM: 1, maxVoxels: 5_000))
    }
}

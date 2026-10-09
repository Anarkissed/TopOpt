import XCTest
import simd
@testable import TopOptFlows

/// Grade-to-fit-shape: the cell must shrink toward the edge of the declared region.
final class LatticeBoundaryDistanceTests: XCTestCase {

    /// A solid slab in the middle of the grid. The distance has to be the true
    /// millimetre distance to the nearest empty voxel, isotropically — a chamfer would
    /// over-read the diagonals, which is exactly where a face prism's chamfered edges are.
    func testDistanceIsExactEuclideanInMillimetres() {
        let n = 9
        var cand = [Bool](repeating: false, count: n * n * n)
        // A 5^3 block inset by 2 on every side.
        for k in 2..<7 { for j in 2..<7 { for i in 2..<7 {
            cand[(k * n + j) * n + i] = true
        } } }
        let d = LatticeBoundaryDistance.millimetres(
            candidate: cand, nx: n, ny: n, nz: n, spacing: SIMD3<Float>(repeating: 2))
        XCTAssertEqual(d.count, n * n * n)

        func at(_ i: Int, _ j: Int, _ k: Int) -> Double { d[(k * n + j) * n + i] }
        // Centre of the block: 2 voxels of clearance on every side, 2 mm each ⇒ 4 mm
        // to the nearest EMPTY voxel... the nearest empty voxel centre is 3 voxels away
        // along an axis (indices 4 -> 1), so 6 mm.
        XCTAssertEqual(at(4, 4, 4), 6.0, accuracy: 1e-9)
        // A face voxel of the block is one voxel from empty ⇒ 2 mm.
        XCTAssertEqual(at(2, 4, 4), 2.0, accuracy: 1e-9)
        // A corner voxel is empty-adjacent on three axes: still 2 mm (the nearest empty
        // is face-adjacent), NOT 2*sqrt(3).
        XCTAssertEqual(at(2, 2, 2), 2.0, accuracy: 1e-9)
        // One in from the corner along all three axes: the nearest empty voxel is TWO
        // voxels away on each axis (index 3 -> 1) ⇒ 4 mm, not 2.
        XCTAssertEqual(at(3, 3, 3), 4.0, accuracy: 1e-9)
        // Empty voxels report 0.
        XCTAssertEqual(at(0, 0, 0), 0.0)
    }

    /// Anisotropic voxels still measure millimetres, not indices.
    func testAnisotropicSpacingMeasuresMillimetres() {
        let n = 7
        var cand = [Bool](repeating: false, count: n * n * n)
        for k in 1..<6 { for j in 1..<6 { for i in 1..<6 {
            cand[(k * n + j) * n + i] = true
        } } }
        let d = LatticeBoundaryDistance.millimetres(
            candidate: cand, nx: n, ny: n, nz: n,
            spacing: SIMD3<Float>(10, 1, 1))
        func at(_ i: Int, _ j: Int, _ k: Int) -> Double { d[(k * n + j) * n + i] }
        // At the centre the cheapest escape is along Y or Z (1 mm per voxel, 3 voxels)
        // rather than X (10 mm per voxel), so 3 mm — not 30.
        XCTAssertEqual(at(3, 3, 3), 3.0, accuracy: 1e-9)
    }

    /// No boundary ⇒ nothing to grade to. Returning zeros would read as "every voxel is
    /// ON the boundary" and collapse the whole part to the finest rung.
    func testNoBoundaryReturnsEmptyRatherThanZeros() {
        let n = 4
        let all = [Bool](repeating: true, count: n * n * n)
        XCTAssertTrue(LatticeBoundaryDistance.millimetres(
            candidate: all, nx: n, ny: n, nz: n,
            spacing: SIMD3<Float>(repeating: 1)).isEmpty)
        let none = [Bool](repeating: false, count: n * n * n)
        XCTAssertTrue(LatticeBoundaryDistance.millimetres(
            candidate: none, nx: n, ny: n, nz: n,
            spacing: SIMD3<Float>(repeating: 1)).isEmpty)
    }

    /// The ceiling is a CEILING: it may only make a cell finer.
    func testCeilingNeverCoarsensAnExistingWant() {
        var wants: [Double] = [8, 8, 8]
        let d: [Double] = [1, 10, 0]          // 2d = 2, 20, 0
        let cand = [true, true, true]
        LatticeBoundaryDistance.applyCeiling(to: &wants, distanceMM: d, candidate: cand)
        XCTAssertEqual(wants[0], 2.0, accuracy: 1e-9)   // near the edge ⇒ finer
        XCTAssertEqual(wants[1], 8.0, accuracy: 1e-9)   // deep ⇒ untouched, NOT 20
        XCTAssertEqual(wants[2], 8.0, accuracy: 1e-9)   // no distance ⇒ untouched
    }

    /// A voxel core marked "not fitted" (0) stays solid — the boundary has no standing
    /// to lattice material the derivation refused.
    func testCeilingLeavesUnfittedVoxelsAtZero() {
        var wants: [Double] = [0]
        LatticeBoundaryDistance.applyCeiling(
            to: &wants, distanceMM: [5], candidate: [true])
        XCTAssertEqual(wants[0], 0.0)
    }

    /// ★ THE POINT OF THE WHOLE CHANGE: a mode that derived NO per-voxel want still
    /// grades to the shape, clamped to its own window. Without this, plain swept and
    /// fixed stay flat and "works on EVERY grade option" is false.
    func testEmptyWantsAreFilledFromTheBoundaryWithinTheWindow() {
        var wants: [Double] = []
        let d: [Double] = [0.4, 3, 50]        // 2d = 0.8, 6, 100
        let cand = [true, true, true]
        LatticeBoundaryDistance.applyCeiling(
            to: &wants, distanceMM: d, candidate: cand, fallbackWindow: 1...8)
        XCTAssertEqual(wants.count, 3)
        XCTAssertEqual(wants[0], 0.0)                    // under the window's floor ⇒ solid
        XCTAssertEqual(wants[1], 6.0, accuracy: 1e-9)    // inside the window ⇒ the boundary's
        XCTAssertEqual(wants[2], 8.0, accuracy: 1e-9)    // capped at HIS typed ceiling
    }

    /// With no window to clamp to there is nothing honest to ask for, so the mode is
    /// left exactly as it was rather than inventing a cell.
    func testEmptyWantsWithNoWindowStayEmpty() {
        var wants: [Double] = []
        LatticeBoundaryDistance.applyCeiling(
            to: &wants, distanceMM: [1, 2], candidate: [true, true])
        XCTAssertTrue(wants.isEmpty)
    }

    /// The grading is MONOTONE in the distance — that is the visible property he asked
    /// for ("getting smaller as it gets closer to the boundary").
    func testCellSizeIsMonotoneInDistanceToTheBoundary() {
        let n = 21
        var cand = [Bool](repeating: false, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            // A thick slab: |i - 10| <= 8, open in y/z so the boundary is the two faces.
            if abs(i - 10) <= 8 { cand[(k * n + j) * n + i] = true }
        } } }
        let d = LatticeBoundaryDistance.millimetres(
            candidate: cand, nx: n, ny: n, nz: n, spacing: SIMD3<Float>(repeating: 1))
        var wants = [Double](repeating: 100, count: n * n * n)
        LatticeBoundaryDistance.applyCeiling(to: &wants, distanceMM: d, candidate: cand)
        func w(_ i: Int) -> Double { wants[(10 * n + 10) * n + i] }
        // Walking in from the slab's face, the ceiling must never decrease.
        var prev = -1.0
        for i in 2...10 {
            let cur = w(i)
            XCTAssertGreaterThanOrEqual(cur, prev, "cell shrank while moving inward at i=\(i)")
            prev = cur
        }
        // And the edge really is finer than the middle.
        XCTAssertLessThan(w(2), w(10))
    }
}

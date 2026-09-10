import XCTest
@testable import TopOptFlows

/// ★ THE MIRROR OF CORE'S SHAPE FIT, PINNED (run_job.cpp ~4160–4290). Hand-computed on
/// a 5×5×5 all-candidate block at 1 mm voxels: the chamfer distance is 1 on every grid
/// face, 2 one voxel in, 3 at the centre (depth 3).
final class OrganicShapeFitTests: XCTestCase {
    private let n = 5
    private var all: [Bool] { [Bool](repeating: true, count: 125) }
    private func at(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * 5 + j) * 5 + i }

    func testChamferDistanceIsOneOnTheFacesAndGrowsInward() {
        let d = OrganicShapeFit.boundaryDistance(candidate: all, nx: n, ny: n, nz: n)
        XCTAssertEqual(d[at(0, 2, 2)], 1); XCTAssertEqual(d[at(4, 2, 2)], 1)
        XCTAssertEqual(d[at(2, 0, 2)], 1); XCTAssertEqual(d[at(2, 2, 4)], 1)
        XCTAssertEqual(d[at(1, 2, 2)], 2); XCTAssertEqual(d[at(2, 2, 2)], 3)
        XCTAssertEqual(d[at(0, 0, 0)], 1, "a corner is still on a face")
        // a non-candidate neighbour is a wall too
        var mask = all; mask[at(2, 2, 2)] = false
        let d2 = OrganicShapeFit.boundaryDistance(candidate: mask, nx: n, ny: n, nz: n)
        XCTAssertEqual(d2[at(2, 2, 2)], 0, "non-candidates read 0")
        XCTAssertEqual(d2[at(1, 2, 2)], 1, "its neighbour is now at the boundary")
    }

    func testShapeFitCapsTheSeparationAtTwiceTheBoundaryDistance() {
        // uniform 6 mm separation, window 3–6, 1 mm voxels
        let r = OrganicShapeFit.apply(spacing: [Double](repeating: 6, count: 125), candidate: all,
                                      nx: n, ny: n, nz: n, voxelMM: 1, window: (3, 6), only: false)
        XCTAssertEqual(r.spacing[at(0, 2, 2)], 3, "face: cap 2·1·1 = 2 < floor 3 ⇒ floor")
        XCTAssertEqual(r.spacing[at(1, 2, 2)], 4, "one in: cap 2·2·1 = 4")
        XCTAssertEqual(r.spacing[at(2, 2, 2)], 6, "centre: cap 6 is not < 6 ⇒ untouched")
        XCTAssertEqual(r.depthVoxels, 3)
        XCTAssertEqual(r.shrunk, 125 - 1, "everything but the single centre voxel shrank")
        XCTAssertEqual(r.minRatio, 0.5, accuracy: 1e-12)
    }

    func testShapeFitOnlyIsTheDepthRampAndIgnoresTheStressWindow() {
        var stressed = [Double](repeating: 6, count: 125)
        stressed[at(2, 2, 2)] = 3   // a stressed centre the ramp must overwrite upward
        let r = OrganicShapeFit.apply(spacing: stressed, candidate: all,
                                      nx: n, ny: n, nz: n, voxelMM: 1, window: (3, 6), only: true)
        XCTAssertEqual(r.spacing[at(0, 2, 2)], 4, accuracy: 1e-12, "face: 3 + 3·(1/3)")
        XCTAssertEqual(r.spacing[at(1, 2, 2)], 5, accuracy: 1e-12, "one in: 3 + 3·(2/3)")
        XCTAssertEqual(r.spacing[at(2, 2, 2)], 6, accuracy: 1e-12, "centre: the top of the window, stress unread")
    }

    func testNoWindowMeansNoOnlyModeAndARelativeFloor() {
        let r = OrganicShapeFit.apply(spacing: [Double](repeating: 10, count: 125), candidate: all,
                                      nx: n, ny: n, nz: n, voxelMM: 1, window: nil, only: true)
        XCTAssertEqual(r.spacing[at(0, 2, 2)], 5, "cap 2 < floor 0.5·10 ⇒ floor 5 (only-mode needs a window)")
        XCTAssertEqual(r.spacing[at(2, 2, 2)], 6, "cap 2·3·1 = 6 < 10")
    }
}

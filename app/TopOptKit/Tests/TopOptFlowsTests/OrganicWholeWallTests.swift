import XCTest
@testable import TopOptFlows

/// ★ A DEAD WALL IS DEAD AS A WHOLE (2026-09-18): under core's threshold the wall's real
/// tensor is zeroed everywhere; a wall above it is untouched.
final class OrganicWholeWallTests: XCTestCase {
    func testTheWallUnderTheThresholdIsZeroedAndTheLoadedOneKept() {
        // two regions of 100 voxels: region 1 hovers at 0.004 MPa (his front wall),
        // region 2 at 0.02 (his back wall); the part peak 0.03 sets thr = max(0.0006, 0.005)
        var ids = [Int32](repeating: 0, count: 200)
        var t = [Double](repeating: 0, count: 6 * 200)
        for i in 0..<100 { ids[i] = 1; t[6 * i] = 0.004; t[6 * i + 1] = 0.001 }
        for i in 100..<200 { ids[i] = 2; t[6 * i] = 0.02; t[6 * i + 1] = 0.005 }
        t[6 * 150] = 0.03                                             // the part's peak, in wall 2
        let v = OrganicSyntheticStress.deadenWholeWalls(tensor: &t, regionIDs: ids)
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].regionID, 1)
        XCTAssertEqual(v[0].zeroed, 100)
        XCTAssertEqual(v[0].thr, 0.005, accuracy: 1e-12, "the absolute floor binds on a lightly loaded part")
        XCTAssertTrue((0..<100).allSatisfy { t[6 * $0] == 0 && t[6 * $0 + 1] == 0 }, "wall 1 zeroed")
        XCTAssertEqual(t[6 * 120], 0.02, "wall 2 untouched")
        // a wall right at the threshold is a live wall
        var t2 = [Double](repeating: 0, count: 6 * 100)
        let ids2 = [Int32](repeating: 1, count: 100)
        for i in 0..<100 { t2[6 * i] = 0.0051 }
        XCTAssertTrue(OrganicSyntheticStress.deadenWholeWalls(tensor: &t2, regionIDs: ids2).isEmpty)
    }
}

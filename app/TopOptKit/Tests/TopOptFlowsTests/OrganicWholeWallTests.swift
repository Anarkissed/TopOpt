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

extension OrganicWholeWallTests {
    /// A dead wall is graded at the window's MIDDLE, not the coarsest end its zero
    /// stress would put it at; the loaded wall's grading is unchanged.
    func testADeadWallTakesTheWindowsMiddleSpacing() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regs = [(15, 12.0), (2, 11.0)].compactMap { f, d in
            LatticeRegionEmission.planeFor(face: FaceID(f), in: mesh).flatMap {
                LatticeRegionEmission.spec(for: $0, role: .include, depthMM: d, faceID: f) }
        }
        try XCTSkipIf(regs.isEmpty)
        let n = 40
        let e = mesh.bounds.max - mesh.bounds.min
        let sp = Double(max(e.x, max(e.y, e.z))) / Double(n)
        let origin = SIMD3<Double>(mesh.bounds.min)
        let plan = OrganicSyntheticStress.plan(regions: regs, dims: (n, n, n), originMM: origin, spacingMM: sp,
                                               defaultFoci: 2, statedFoci: [:])
        // wall 1 (face 15) at noise, wall 2 (face 2) loaded and varied
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for i in 0..<(n * n * n) where plan.regionIDs[i] == 2 { tensor[6 * i] = 0.01 + 0.02 * Double(i % 7) / 6; tensor[6 * i + 1] = 0.003 }
        for i in 0..<(n * n * n) where plan.regionIDs[i] == 1 { tensor[6 * i] = 0.004 }
        var input = LatticeOrganicInput(tensor: tensor, dims: (n, n, n), originMM: origin, spacingMM: sp,
                                        minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                        separationMinMM: 3.47, separationMaxMM: 5.2, rhoMin: 0.073, rhoMax: 0.9)
        input.regionIDs = plan.regionIDs
        input.syntheticRegions = plan.regions
        let v = OrganicSyntheticStress.deadenWholeWalls(tensor: &input.tensor, regionIDs: plan.regionIDs)
        XCTAssertEqual(v.map { $0.regionID }, [1], "the noise wall is dead as a whole; the loaded one is not")
        input.deadRegionIDs = Set(v.map { $0.regionID })
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                    algorithm: "organic", organic: input, maxDim: 64, regions: regs, whenEmpty: .latticeNothing)
        print("DEADWALL: \(scene.organicSummary.prefix(240))")
        XCTAssertTrue(scene.organicSummary.contains("dead-wall voxels at the window's middle 4.34 mm"), scene.organicSummary)
    }
}

import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ A DEAD WALL IS DEAD AS A WHOLE (2026-09-18) — and since ruling C (2026-09-29) it is
/// CORE that says so: the app hands core the real tensor and reads the dead walls from
/// its report (`fully_synthetic > 0`). The app's own zeroing is gone.
final class OrganicWholeWallTests: XCTestCase {
    /// His two walls on the verdict core returns: region 1 hovers at 0.004 MPa (his front
    /// wall), region 2 carries 0.02 (his back wall); the part peak 0.03 sets
    /// thr = max(0.0006, 0.005). Core calls the first dead and leaves the second alone.
    func testCoreCallsTheQuietWallDeadAndLeavesTheLoadedOneAlone() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let n = 200
        var ids = [Int32](repeating: 0, count: n)
        var t = [Double](repeating: 0, count: 6 * n)
        for i in 0..<100 { ids[i] = 1; t[6 * i] = 0.004; t[6 * i + 1] = 0.001 }
        for i in 100..<200 { ids[i] = 2; t[6 * i] = 0.02; t[6 * i + 1] = 0.005 }
        t[6 * 150] = 0.03                                             // the part's peak, in wall 2
        let rep = try XCTUnwrap(TopOptKit.organicSyntheticReport(
            nx: n, ny: 1, nz: 1, spacingMM: 1, origin: .zero,
            candidate: [Bool](repeating: true, count: n), stressTensor: t, regionIDs: ids,
            syntheticRegions: [.init(regionID: 1, faceID: 11, foci: 2), .init(regionID: 2, faceID: 12, foci: 2)]))
        XCTAssertEqual(rep.deadRegionIDs, [1], "the quiet wall is dead as a whole; the loaded one is not")
        XCTAssertEqual(rep.deadThreshold, 0.005, accuracy: 1e-12, "the absolute floor binds on a lightly loaded part")
        XCTAssertTrue(rep.deadFloorBound)
        let r1 = try XCTUnwrap(rep.regions.first { $0.regionID == 1 })
        XCTAssertEqual(r1.fullySynthetic, 100, "the WHOLE wall takes the focal field")
        XCTAssertEqual(r1.blended, 0, "no per-voxel blend since #358")
        let r2 = try XCTUnwrap(rep.regions.first { $0.regionID == 2 })
        XCTAssertEqual(r2.fullySynthetic, 0); XCTAssertFalse(r2.wholeRegion)
    }
}

extension OrganicWholeWallTests {
    /// A dead wall is graded at the window's MIDDLE, not the coarsest end its low stress
    /// would put it at; the loaded wall's grading is unchanged. The scene takes the dead
    /// wall from core's verdict on the untouched tensor.
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
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                    algorithm: "organic", organic: input, maxDim: 64, regions: regs, whenEmpty: .latticeNothing)
        print("DEADWALL: \(scene.organicSummary.prefix(240))")
        XCTAssertEqual(scene.organicSyntheticReport?.deadRegionIDs, [1],
                       "★ core's verdict, on the tensor as the solve gave it")
        XCTAssertTrue(scene.organicSummary.contains("dead-wall voxels at the window's middle 4.3"), scene.organicSummary)
    }
}

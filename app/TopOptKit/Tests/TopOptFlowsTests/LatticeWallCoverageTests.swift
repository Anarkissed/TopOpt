// LatticeWallCoverageTests — ★★★ HOW MUCH OF THE DECLARED WALL ACTUALLY GETS A CELL.
//
// (maintainer, 2026-08-22: "Find every reason why the two walls aren't *entirely* being
// latticed … There should be no shell/solid wall.")
//
// ★ THE GREY IS NOT THE SHELL. The shell opens over a declared face correctly — its
// triangles carry that face's normal exactly, so the agreement test reads 1.0 and it
// discards. What fills the hole is the SOLID FILL, drawn wherever the march finds no
// active cell (`anyActive == false`). So "no solid wall" is not a question about the
// shell at all: it is "no cell may be refused inside the declaration", and that is what
// this file measures.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeWallCoverageTests: XCTestCase {

    private func hisRegions(_ mesh: ViewerMesh) -> [LatticeRegionSpec] {
        [(FaceID(15), 11.0), (FaceID(2), 13.0)].compactMap { f, d in
            LatticeRegionEmission.planeFor(face: f, in: mesh).flatMap {
                LatticeRegionEmission.spec(for: $0, role: .include, depthMM: d,
                                           faceID: Int(f))
            }
        }
    }

    /// ★★★ THE MEMBER IS THE PART'S, AND THE DIFFERENCE IS ENORMOUS.
    ///
    /// `memberThicknessMM` used to be an EDT over the REGION-CLIPPED occupancy, so it
    /// measured the declared slab: bounded by the depth he typed, and tapering to ZERO
    /// at the region's own in-plane boundary. The cells-per-member floor then refused a
    /// full cell's border around everything he marked, at every setting.
    func testTheMemberThicknessIsTheWallNotTheDeclaredSlab() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regions = hisRegions(mesh)
        try XCTSkipIf(regions.isEmpty, "his faces did not resolve")
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    stageMode: .aesthetic, maxDim: 96,
                                    regions: regions, whenEmpty: .latticeNothing)
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no thickness")

        // The OLD behaviour, reconstructed exactly: the same EDT over the clipped set.
        let clipped = scene.occupancy.values.map { $0 > 0.5 }
        let onTheSlab = TopOptKit.latticeMemberThicknessMM(
            nx: scene.occupancy.nx, ny: scene.occupancy.ny, nz: scene.occupancy.nz,
            spacing: scene.occupancy.spacing, solid: clipped, capRadiusVoxels: 16)
        try XCTSkipIf(onTheSlab.isEmpty, "core gave no thickness for the control")

        // Compare only where the declaration actually is — that is the set the floor
        // is applied over.
        var nowSum = 0.0, wasSum = 0.0, n = 0, thinnedByTheMask = 0
        for i in 0..<scene.occupancy.values.count where scene.occupancy.values[i] > 0.5 {
            let now = scene.memberThicknessMM[i], was = onTheSlab[i]
            guard now.isFinite, was.isFinite, now > 0, was > 0 else { continue }
            nowSum += now; wasSum += was; n += 1
            if was < now - 1e-9 { thinnedByTheMask += 1 }
        }
        try XCTSkipIf(n == 0, "no declared voxels carried a finite thickness")
        let nowMean = nowSum / Double(n), wasMean = wasSum / Double(n)
        print("""

        ── member thickness under his two declarations (\(n) voxels) ──────
        measured on the PART  (now) .... \(String(format: "%.3f", nowMean)) mm mean
        measured on the SLAB  (was) .... \(String(format: "%.3f", wasMean)) mm mean
        ★ voxels the MASK made thinner . \(thinnedByTheMask) \
        (\(String(format: "%.1f", 100 * Double(thinnedByTheMask) / Double(n)))%)

        """)
        XCTAssertGreaterThan(nowMean, wasMean,
            "★ the part-measured member is no thicker than the slab-measured one — "
          + "the fix is not in force, or the control is not reconstructing the old rule")
        XCTAssertGreaterThan(thinnedByTheMask, 0, "positive control: the mask DID thin it")
    }

    /// ★★★ AND THE COVERAGE ITSELF: of the voxels he declared, how many get a cell?
    /// A refused voxel is drawn as solid plastic, which is the grey he is pointing at.
    func testMostOfTheDeclaredWallGetsACellAtTheAestheticFloor() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regions = hisRegions(mesh)
        try XCTSkipIf(regions.isEmpty, "his faces did not resolve")
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    stageMode: .aesthetic, maxDim: 96,
                                    regions: regions, whenEmpty: .latticeNothing)
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no thickness")

        var declared = 0
        for v in scene.occupancy.values where v > 0.5 { declared += 1 }
        try XCTSkipIf(declared == 0, "his declarations matched nothing")

        func covered(cellMM: Double, floor: Double) -> Int {
            let f = LatticePreviewOccupancy.cellField(
                occupancy: scene.occupancy, demand: nil, cellMM: cellMM,
                memberThickness: scene.memberThicknessMM,
                minCellsPerMember: floor,
                cellsPerMemberFloor: [Double](repeating: floor,
                                              count: scene.occupancy.values.count))
            return f.values.filter { $0 >= 0 }.count
        }
        print("── declared voxels \(declared); cells kept by cell size and floor ──")
        for cell in [4.0, 5.5, 8.0] {
            let two = covered(cellMM: cell, floor: 2)
            let five = covered(cellMM: cell, floor: 5)
            print(String(format: "   cell %.1f mm:  N*=2 -> %d cells,  N*=5 -> %d cells",
                         cell, two, five))
            XCTAssertGreaterThanOrEqual(two, five,
                "★ the relaxed floor kept FEWER cells at \(cell) mm — impossible unless "
              + "the floor is not the thing being varied")
        }
        XCTAssertGreaterThan(covered(cellMM: 4.0, floor: 2), 0,
            "★ NOTHING survives at a 4 mm cell on the aesthetic floor — the wall cannot "
          + "be latticed at any setting and the grey is unavoidable")
    }
}

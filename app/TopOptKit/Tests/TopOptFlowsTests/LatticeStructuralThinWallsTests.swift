// ★ his iPad notes 11-09 (2:36 PM): "the front and back sides weren't able to lattice (I think there should be some kind of
// notice about that)" — Structural's cells-per-member floor leaves a wall thinner than N* × the smallest cell solid.
import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeStructuralThinWallsTests: XCTestCase {
    /// Walls under N* × the smallest cell are counted; the line says the bound and the share; quiet off Structural, with no
    /// measured walls, or under 5 %.
    func testTheLineCountsWallsTooThinForTheCellFloor() throws {
        let occ: [Float] = [1, 1, 1, 1, 0, 1, 1, 1, 1, 1]
        let walls: [Double] = [8, 8, 8, 30, 8, 30, 30, 30, 30, 30]   // 3 of 9 set-to-lattice voxels in an 8 mm wall
        let f = try XCTUnwrap(LatticeStructuralThinWalls.finding(structural: true, occupancy: occ, memberThicknessMM: walls,
                                                                 cellsPerMember: 5, smallestCellMM: 4))
        XCTAssertEqual(f.minWallMM, 20, accuracy: 1e-9)
        XCTAssertEqual(f.share, 3.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(f.caption, "Structural: walls under 20 mm stay solid")
        XCTAssertTrue(f.sentence.contains("At least 33 %"), f.sentence)
        XCTAssertTrue(f.sentence.contains("Aesthetic lattices thin walls."))
        XCTAssertNil(LatticeStructuralThinWalls.finding(structural: false, occupancy: occ, memberThicknessMM: walls,
                                                        cellsPerMember: 5, smallestCellMM: 4), "★ quiet under Aesthetic")
        XCTAssertNil(LatticeStructuralThinWalls.finding(structural: true, occupancy: occ, memberThicknessMM: [],
                                                        cellsPerMember: 5, smallestCellMM: 4), "quiet with no measured walls")
        let thick = [Double](repeating: 30, count: occ.count)
        XCTAssertNil(LatticeStructuralThinWalls.finding(structural: true, occupancy: occ, memberThicknessMM: thick,
                                                        cellsPerMember: 5, smallestCellMM: 4), "quiet when every wall holds its cells")
    }

    /// ★ HIS STAND (HIS_PROJECT_DIR), the whole part latticed (Start from −), Structural then Aesthetic: under Structural the
    /// line names the walls the floor leaves solid; under Aesthetic it is quiet.
    @MainActor
    func testHisStandUnderStructuralSaysItsThinWallsStaySolid() throws {
        let s = try HisStand1109LatticeTests.restore()
        let pm = s.pm
        pm.lattice.wholePart = true
        func finding(_ mode: LatticeStageMode) -> LatticeStructuralThinWalls.Finding? {
            pm.lattice.stageMode = mode
            let lat = pm.lattice
            let emission = pm.latticeJobRegions()
            let scene = LatticeSDFScene(mesh: s.mesh, field: nil, latticeID: lat.topologyID,
                                        statedDensityGoverns: true, allowQuilt: lat.allowQuilt, stageMode: mode,
                                        gradeAlong: lat.gradeAlong, algorithm: lat.algorithm, allowableMPa: 50,
                                        boundaryFinishWritten: lat.singleCellMembers, organic: nil,
                                        regions: pm.latticePreviewRegions(emission.regions), rhoMin: 0.05, rhoMax: 0.9, gamma: 1,
                                        whenEmpty: pm.latticeStartsWhole ? .latticeEverything : .latticeNothing,
                                        skinMM: lat.boundary.faceSkinMM(wallRingMM: pm.printParams.wallRingMM),
                                        skippedFaces: emission.skippedFaces, skippedRegionNames: emission.skippedRegionNames,
                                        bandOverrides: lat.bandTreatments, octetBand: lat.algorithm != "organic",
                                        bandGradeMM: lat.gradingMode.fitsShape ? lat.shapeFitBandMM : 0,
                                        beadMM: pm.printParams.strutLineWidthMM)
            let f = LatticeStructuralThinWalls.finding(
                structural: mode == .structural, occupancy: scene.occupancy.values, memberThicknessMM: scene.memberThicknessMM,
                cellsPerMember: scene.minCellsPerMember,
                smallestCellMM: lat.cellSizeMode == .fixed ? lat.cellMM : Swift.min(lat.cellMM, lat.cellMinMM > 0 ? lat.cellMinMM : lat.cellMM))
            print("HIS1109 thin walls \(mode): \(f.map { "\($0.caption) · \(Int(($0.share * 100).rounded())) %" } ?? "none") · N* \(scene.minCellsPerMember) · walls measured \(scene.memberThicknessMM.count)")
            return f
        }
        XCTAssertNotNil(finding(.structural), "★ Structural says its thin walls stay solid")
        XCTAssertNil(finding(.aesthetic), "★ Aesthetic says nothing")
    }
}

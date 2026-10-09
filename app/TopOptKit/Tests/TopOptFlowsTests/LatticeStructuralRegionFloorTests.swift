import XCTest
@testable import TopOptFlows
import TopOptKit

/// ★ THE 2.4 mm WALL (his 2026-09-20: "all that came out was a consistent 2.4mm cell
/// across the entirety of the front face (face2) and 2mm on the back face (face15).
/// There should be a grade happening"). DIAG 20:45: `regionCell measuredW=12.03 floor=5.0
/// coreCell=2.406 final=2.4` — under Structural the per-region cell is the wall over
/// core's HOMOGENISED accuracy floor of five cells, and from 2.4 mm no rung clears the
/// 1.8 mm printable floor. The beam-network certificate has no such floor.
final class LatticeStructuralRegionFloorTests: XCTestCase {

    /// ★ Ruling 1 (2026-10-02): the relaxation now keys on core's beam-network SET, not a
    /// schema probe — see `LatticeBeamNetworkFactTests`. Under a set that holds the algorithm
    /// the strut network is solved and the aesthetic floor applies; under today's set
    /// ({"organic"}) the homogenised floor stays — his 2.4 mm wall.
    func testStructuralSteppedTakesTheAestheticFloorOnlyUnderTheBeamCertificate() throws {
        let homog = LatticeStageMode.structural.cellsPerMemberFloor(topology: "octet", utilisation: .nan)
        let aesthetic = LatticeStageMode.aesthetic.cellsPerMemberFloor(topology: "octet", utilisation: .nan)
        guard homog > 0, aesthetic > 0 else { throw XCTSkip("no octet law in this core") }
        XCTAssertGreaterThan(homog, aesthetic, "core's homogenised floor (5) sits above the aesthetic one (2)")
        for alg in ["stepped", "doubled"] {
            XCTAssertEqual(LatticeStageMode.structural.regionCellsPerMemberFloor(
                topology: "octet", boundaryFinishWritten: false, algorithm: alg, beamNetworkAlgorithms: [alg]),
                aesthetic, "★ \(alg) under a beam-network certificate: the strut network is solved, not homogenised")
            XCTAssertEqual(LatticeStageMode.structural.regionCellsPerMemberFloor(
                topology: "octet", boundaryFinishWritten: false, algorithm: alg, beamNetworkAlgorithms: ["organic"]),
                homog, "★ \(alg) on a core that does not certify it so: the homogenised floor stays — his 2.4 mm wall")
        }
        // organic and the aesthetic stage are untouched by the rule
        XCTAssertEqual(LatticeStageMode.structural.regionCellsPerMemberFloor(
            topology: "octet", boundaryFinishWritten: false, algorithm: "organic", beamNetworkAlgorithms: ["organic"]), homog)
        XCTAssertEqual(LatticeStageMode.aesthetic.regionCellsPerMemberFloor(
            topology: "octet", boundaryFinishWritten: false, algorithm: "stepped", beamNetworkAlgorithms: ["stepped"]), aesthetic)
    }

    /// The numbers he saw, reproduced: a 12.03 mm wall at floor 5 is a 2.4 mm cell.
    func testHisWallAtTheHomogenisedFloorIsTheCellHeSaw() throws {
        let d = TopOptKit.latticeRegionDerivation(topology: "octet", memberWidthMM: 12.03,
                                                  minExtrudableWidthMM: 0.45, cellsPerMemberFloor: 5)
        guard d.valid, d.cellMM > 0 else { throw XCTSkip("no octet law in this core") }
        let n = Swift.max(1, (12.03 / d.cellMM).rounded())
        XCTAssertEqual(12.03 / n, 2.4, accuracy: 0.02, "the DIAG's `final=2.4`")
    }

    /// The wizard offers "Allow single-cell members" in Aesthetic only (his 2026-09-20).
    func testTheSingleCellSwitchIsNotOfferedUnderStructural() throws {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent(); url.deleteLastPathComponent()
        let src = try String(contentsOf: url.appendingPathComponent("Sources/TopOptFlows/LatticeSetupWizard.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("if (project.lattice.stageMode ?? .structural) == .aesthetic {\n                    singleCellSwitch\n                }"),
                      "★ the switch lowers the AESTHETIC floor; under Structural it is decorative and must not show")
        // and the sample cube KEEPS core's emission stage (core reply 8, 2026-09-20)
        XCTAssertTrue(src.contains("layerHeightMM: project.printParams.layerHeightMM,\n                                       showRepairs: organicShowRepairs)"),
                      "★ core: do NOT stop sending the emission for the sample — the collapse was two core bugs, fixed in 6d6177c4")
    }

}

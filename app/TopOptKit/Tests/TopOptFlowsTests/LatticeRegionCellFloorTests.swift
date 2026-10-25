// LatticeRegionCellFloorTests — ★★★ THE 2.20 mm CELL, AND WHY IT WAS 2.20.
//
// (maintainer, 2026-08-22, on a Stepped preview: "the cell size is stuck at 2.2mm which
// doesn't make sense unless that wall is only 4.4mm thick? … Why aren't I getting
// bigger cell sizes?")
//
// ★ THE WALL IS 11 mm AND THE DIVISOR WAS 5. The per-region cell is `width / floor`,
// and `lattice_region_derivation` in the BRIDGE hard-coded the floor as
// `lattice_cells_per_member_min(topo)` — core's ACCURACY floor — whatever mode the
// stage was in. 11.0 / 5 = 2.20, exactly the number on his card. Core's own
// `lattice_derive_cell_for_member` has taken a floor as a parameter all along; the
// bridge simply never passed one.
//
// ★ SO THE AESTHETIC RELAXATION WAS REACHING THE WRONG HALF. It reached the per-VOXEL
// planner (`cellsPerMemberFloorPerVoxel`) and never the per-REGION derivation that Fit
// and Stepped are both built from. These bars are on the arithmetic itself.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeRegionCellFloorTests: XCTestCase {

    private let topo = "octet"
    private let bead = 0.42
    /// His wall, as the card reported it: 2.20 mm × 5 cells.
    private let wallMM = 11.0

    /// ★★★ HIS NUMBER, REPRODUCED — then fixed by stating the floor.
    func testHisElevenMillimetreWallDerivesTwoTwentyAtFiveAndFiveFiftyAtTwo() {
        let atAccuracy = TopOptKit.latticeRegionDerivation(
            topology: topo, memberWidthMM: wallMM, minExtrudableWidthMM: bead,
            cellsPerMemberFloor: 0)          // 0 = core's accuracy floor, the old behaviour
        let atAesthetic = TopOptKit.latticeRegionDerivation(
            topology: topo, memberWidthMM: wallMM, minExtrudableWidthMM: bead,
            cellsPerMemberFloor: 2)
        let atOne = TopOptKit.latticeRegionDerivation(
            topology: topo, memberWidthMM: wallMM, minExtrudableWidthMM: bead,
            cellsPerMemberFloor: 1)

        print("""

        ── an 11.00 mm wall, cell = width / floor ─────────────────────────
        floor 5 (accuracy, the old hard-coded one) .. \(String(format: "%.3f", atAccuracy.cellMM)) mm
        floor 2 (aesthetic) ......................... \(String(format: "%.3f", atAesthetic.cellMM)) mm
        floor 1 (single-cell members) ............... \(String(format: "%.3f", atOne.cellMM)) mm

        """)

        XCTAssertTrue(atAccuracy.valid && atAesthetic.valid && atOne.valid)
        // The number he measured, to the pixel the card prints.
        XCTAssertEqual(atAccuracy.cellMM, 2.20, accuracy: 0.005,
                       "★ the old behaviour is no longer reproduced — this bar has "
                     + "stopped measuring the defect it was written for")
        XCTAssertEqual(atAesthetic.cellMM, 5.50, accuracy: 0.005,
                       "★ stating the aesthetic floor must halve-and-a-bit the divisor")
        XCTAssertEqual(atOne.cellMM, 11.00, accuracy: 0.005,
                       "★ at one cell across a member the cell IS the wall — which is "
                     + "the 11 mm he asked for on an 11 mm wall")
    }

    /// ★ AND THE FLOOR NEVER BEATS PRINTABILITY. `cell = max(width/floor, minPrintable)`,
    /// so a huge floor cannot drive the cell below what the bead can build. Without this
    /// the relaxation would be a way to ask for struts the printer cannot lay.
    func testPrintabilityStillBoundsTheCellFromBelow() {
        let thin = TopOptKit.latticeRegionDerivation(
            topology: topo, memberWidthMM: 2.0, minExtrudableWidthMM: bead,
            cellsPerMemberFloor: 40)         // absurd on purpose
        guard thin.valid, thin.feasible else { return }   // core may refuse outright
        // 2.0 / 40 = 0.05 mm, far below anything a 0.42 mm bead can lay — so if the
        // floor governed unchecked the cell would be 0.05. It is clamped instead.
        XCTAssertGreaterThan(thin.cellMM, 0.05 * 2,
                             "★ the floor drove the cell below the printable one")
        XCTAssertTrue(thin.prints, "★ the derived cell does not print")
    }

    /// ★★ THE HOST ASKS FOR THE MODE'S FLOOR, and the two modes must differ. This is the
    /// bar that fails if someone re-hardcodes the divisor anywhere on the path.
    func testTheTwoModesAskForDifferentFloors() {
        let structural = LatticeStageMode.structural
            .cellsPerMemberFloor(topology: topo, utilisation: .nan)
        let aesthetic = LatticeStageMode.aesthetic
            .cellsPerMemberFloor(topology: topo, utilisation: .nan)
        XCTAssertEqual(structural, 5, accuracy: 1e-9)
        XCTAssertEqual(aesthetic, 2, accuracy: 1e-9)
        XCTAssertEqual(
            TopOptKit.latticeRegionDerivation(topology: topo, memberWidthMM: wallMM,
                                              minExtrudableWidthMM: bead,
                                              cellsPerMemberFloor: structural).cellMM,
            2.20, accuracy: 0.005)
        XCTAssertEqual(
            TopOptKit.latticeRegionDerivation(topology: topo, memberWidthMM: wallMM,
                                              minExtrudableWidthMM: bead,
                                              cellsPerMemberFloor: aesthetic).cellMM,
            5.50, accuracy: 0.005)
    }
}

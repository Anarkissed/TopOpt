// LatticeMeasuredRegionWidthTests — ★ A 20 mm WALL MUST GET A 4 mm CELL
// (maintainer, 2026-08-20: "I made sure the walls here are *exactly* 20mm wide. That's
// 4mm cells 5x wide. Yet, I am seeing holes, and much smaller sized cells than what
// should be expected when I put 'auto' on everything … With minimize_plastic on, it
// should automatically go for the largest cell size and the thinnest density possible.
// And yet, the cells are tiny or non-existent").
//
// ★★ HE WAS RIGHT. Auto's ceiling is W / N*, and W was being read off the region's
// declared DEPTH instead of the wall's measured thickness. Measured at his 0.42 mm bead
// with core's N* = 5:
//
//     declared depth   5 mm  ->  Auto's window  1.09 mm
//     declared depth  10 mm  ->                 2.00 mm
//     declared depth  11 mm  ->                 2.20 mm
//     declared depth  20 mm  ->                 4.00 mm
//
// The two quantities are only equal when the lattice is declared through the FULL
// thickness of the wall. Everywhere else the declared depth is smaller — a depth cannot
// exceed the material it is declared into — so the cell came out too FINE, every time.
// Finer cells mean more struts and more plastic, which is precisely backwards under
// "minimize plastic".
//
// ★ AND THE HOLES ARE THE SAME DEFECT. A finer cell needs a DENSER strut to clear one
// bead. Core's own planner, over a slab exactly 20 mm thick:
//
//     rho 0.05  ->    0 cells,  864 rejected `unprintable`
//     rho 0.08  ->  864 cells,    0 rejected
//     rho 0.20  ->  864 cells,    0 rejected
//     rho 0.90  ->  864 cells,    0 rejected
//
// Driving the cell below what the wall can hold pushes the thin end of a graded band
// under the nozzle, and those cells fall back to SOLID — holes, in the middle of
// material easily thick enough to lattice.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeMeasuredRegionWidthTests: XCTestCase {

    /// A slab exactly `thickMM` thick in Y, on a cubic grid — a member whose width is
    /// known by construction, so core's measurement can be checked against it.
    private func slab(thickMM: Double, spacing: Double = 0.5,
                      nx: Int = 64, nz: Int = 64)
        -> (occ: LatticeVoxelGrid, width: [Double]) {
        let ny = Int(thickMM / spacing) + 24
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        let y0 = 12, y1 = y0 + Int(thickMM / spacing)
        for k in 0..<nz { for j in y0..<y1 { for i in 0..<nx {
            vals[(k * ny + j) * nx + i] = 1
        } } }
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: .zero,
                                   spacing: SIMD3<Float>(repeating: Float(spacing)),
                                   values: vals)
        let w = TopOptKit.latticeMemberThicknessMM(
            nx: nx, ny: ny, nz: nz, spacing: occ.spacing,
            solid: vals.map { $0 > 0.5 }, capRadiusVoxels: 32)
        return (occ, w)
    }

    /// ★★★ THE HEADLINE. His wall is 20 mm; core's ceiling is 20 / 5 = 4 mm; Auto must
    /// reach it. Every number here comes from core — the thickness from
    /// `local_member_thickness_mm`, N* and the window from `LatticeAutoPosture`.
    func testATwentyMillimetreWallReachesAFourMillimetreCell() throws {
        let (occ, width) = slab(thickMM: 20)
        try XCTSkipIf(width.isEmpty, "core gave no widths in this build")
        let bounds = LatticeMeasuredRegionWidth.boundsMM(occupancy: occ,
                                                         memberThicknessMM: width)
        XCTAssertFalse(bounds.isEmpty, "positive control: core measured the slab")
        XCTAssertEqual(bounds.max() ?? 0, 20.0, accuracy: 1.0,
                       "★ core must measure his 20 mm wall at about 20 mm — got "
                       + "\(bounds.max() ?? 0)")

        let win = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(
            regionWidthsMM: bounds, lineWidthMM: 0.42, topology: "octet"),
            "Auto must produce a window from a measured wall")
        XCTAssertEqual(win.max, 4.0, accuracy: 0.25,
                       "★ HIS NUMBER: a 20 mm wall holds a 4 mm cell (W / N* = 20 / 5). "
                       + "Auto's ceiling must be that cell, not a fraction of it — got "
                       + "\(win.max) mm")
    }

    /// ★★ THE DEFECT, PINNED AS A COMPARISON. The declared depth and the measured width
    /// give DIFFERENT cells whenever the lattice does not reach through the whole wall,
    /// and the declared one is always the finer. A positive control first, so this
    /// cannot pass by both numbers being equal.
    func testTheDeclaredDepthGivesAFinerCellThanTheMeasuredWall() throws {
        let (occ, width) = slab(thickMM: 20)
        try XCTSkipIf(width.isEmpty, "core gave no widths")
        let measured = LatticeMeasuredRegionWidth.boundsMM(occupancy: occ,
                                                           memberThicknessMM: width)
        let declaredDepth = 8.0          // a lattice 8 mm into a 20 mm wall
        XCTAssertLessThan(declaredDepth, measured.max() ?? 0,
                          "positive control: the declaration must be SHALLOWER than "
                          + "the wall, or there is no defect to demonstrate")

        let fromMeasured = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(
            regionWidthsMM: measured, lineWidthMM: 0.42, topology: "octet"))
        let fromDeclared = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(
            regionWidthsMM: [declaredDepth], lineWidthMM: 0.42, topology: "octet"))
        XCTAssertGreaterThan(fromMeasured.max, fromDeclared.max,
                             "★ THE DEFECT: reading the DECLARED depth gave "
                             + "\(fromDeclared.max) mm where the wall holds "
                             + "\(fromMeasured.max) mm. Finer cells mean more struts "
                             + "and more plastic — backwards under minimize plastic.")
    }

    /// ★ AND THE FLOOR AGREES WITH THE CEILING. The whole point of measuring is that the
    /// cell Auto reaches for is one the cells-per-member floor will accept — the two
    /// laws read the SAME field, so a cell derived from it cannot be culled by it.
    func testTheCellAutoReachesForSurvivesTheMemberFloor() throws {
        let (occ, width) = slab(thickMM: 20)
        try XCTSkipIf(width.isEmpty, "core gave no widths")
        let bounds = LatticeMeasuredRegionWidth.boundsMM(occupancy: occ,
                                                         memberThicknessMM: width)
        let win = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(
            regionWidthsMM: bounds, lineWidthMM: 0.42, topology: "octet"))
        let nStar = TopOptKit.latticeLimits(topology: "octet").minCellsPerMember
        let drawn = LatticePreviewOccupancy.cellField(
            occupancy: occ, demand: nil, cellMM: win.max,
            memberThickness: width, minCellsPerMember: nStar)
            .values.filter { $0 >= 0 }.count
        XCTAssertGreaterThan(drawn, 0,
                             "★ a cell derived from core's own width measurement must "
                             + "survive core's own width floor — if this is 0 the two "
                             + "laws are reading different numbers again")
    }

    /// ★★★ ONE RUNG, NOT A LADDER — the regression he caught in one look ("It's worse
    /// now....") and the reason this test exists.
    ///
    /// The first version returned the thinnest AND thickest measured width, widening
    /// Auto's window from one rung to several. Core's swept planner walks DOWN a ladder,
    /// not up — `plan_cell_sizes` takes the level printability demands (`need_max == L`,
    /// the FINEST that prints) — so every rung added below the ceiling is one it will
    /// descend to. The picture went from uniformly-too-fine to sparse clumps in an empty
    /// wall, because the finer cells it chose could not print at the thin end of the
    /// band and were culled to solid.
    func testTheWindowIsASingleRungAtTheCoarsestHoldableCell() throws {
        let (occ, width) = slab(thickMM: 20)
        try XCTSkipIf(width.isEmpty, "core gave no widths")
        let bounds = LatticeMeasuredRegionWidth.boundsMM(occupancy: occ,
                                                         memberThicknessMM: width)
        XCTAssertEqual(bounds.count, 1,
                       "★ ONE width. Handing `autoWindowMM` a range gives the planner "
                       + "rungs to descend to, and it descends: \(bounds)")

        let win = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(
            regionWidthsMM: bounds, lineWidthMM: 0.42, topology: "octet"))
        XCTAssertEqual(win.min, win.max, accuracy: 1e-9,
                       "★ a single rung — the coarsest cell the material holds, with "
                       + "nowhere finer for the planner to go. Got \(win.min)–\(win.max)")

        // ★ AND THE PLANNER STAYS THERE. Asked with that window, every cell it plans is
        // the ceiling cell — the assertion that would have failed on the version he saw.
        let nStar = TopOptKit.latticeLimits(topology: "octet").minCellsPerMember
        var cand = [Bool](repeating: false, count: occ.values.count)
        var rho = [Double](repeating: 0, count: occ.values.count)
        for i in 0..<occ.values.count where occ.values[i] > 0.5 {
            cand[i] = true; rho[i] = 0.20
        }
        let plan = try XCTUnwrap(TopOptKit.latticeCellSizePlan(
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing,
            origin: occ.origin, candidate: cand, relativeDensity: rho,
            memberWidthMM: width, minCellMM: win.min, maxCellMM: win.max,
            minExtrudableWidthMM: 0.42, capRadiusVoxels: 32, topology: "octet"))
        XCTAssertEqual(plan.maxLevel, 0,
                       "★ one rung means level 0 is the only level")
        let planned = plan.level.filter { $0 >= 0 }
        XCTAssertGreaterThan(planned.count, 0,
                             "positive control: the planner must plan SOMETHING, or the "
                             + "equality below holds over an empty set")
        XCTAssertTrue(planned.allSatisfy { $0 == 0 },
                      "★ every planned cell is the coarsest the wall holds")
        XCTAssertEqual(plan.baseCellMM, 20.0 / nStar, accuracy: 0.25,
                       "★ …and that cell is W / N* = \(20.0 / nStar) mm")
    }

    /// ★ A `+inf` WIDTH CANNOT BOUND A CEILING. Core returns `+infinity` for material
    /// thicker than the EDT cap it measured; it means "at least this", not a length, and
    /// using it as W would produce an unbounded cell.
    func testTheInfiniteSentinelIsNotTreatedAsAWidth() {
        let occ = LatticeVoxelGrid(nx: 2, ny: 1, nz: 1, origin: .zero,
                                   spacing: SIMD3<Float>(repeating: 1),
                                   values: [1, 1])
        XCTAssertTrue(
            LatticeMeasuredRegionWidth.boundsMM(
                occupancy: occ, memberThicknessMM: [.infinity, .infinity]).isEmpty,
            "★ an all-sentinel field bounds nothing and must return NO width")
        XCTAssertEqual(
            LatticeMeasuredRegionWidth.boundsMM(
                occupancy: occ, memberThicknessMM: [.infinity, 6.0]), [6.0],
            "★ …and a real measurement beside a sentinel is still the width")
    }

    /// ★ A MISMATCHED FIELD ANSWERS NOTHING rather than indexing into whatever is there.
    func testAMismatchedThicknessFieldIsRefused() {
        let occ = LatticeVoxelGrid(nx: 2, ny: 1, nz: 1, origin: .zero,
                                   spacing: SIMD3<Float>(repeating: 1), values: [1, 1])
        XCTAssertTrue(LatticeMeasuredRegionWidth.boundsMM(
            occupancy: occ, memberThicknessMM: [3.0]).isEmpty)
        XCTAssertEqual(LatticeMeasuredRegionWidth.widthMM(
            region: LatticeRegionSpec(role: .include, kind: .face),
            occupancy: occ, memberThicknessMM: [3.0]), 0)
    }
}

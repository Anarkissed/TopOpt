// LatticePerLocalMemberCellTests — ★★★ EVERY VOXEL GETS THE COARSEST CELL ITS OWN
// MEMBER CAN HOLD, AND NOTHING IS CULLED (his ruling, 2026-08-20).
//
//   1. Auto + minimize_plastic ON — biggest cell AND thinnest struts possible.
//   3. Auto vs Fit is the GRADING. Auto always grades.
//   4. Auto picks the sweepable cell sizes FOR you. "It is meant to make life easy."
//   5. Per LOCAL member, not per declared region.
//   6. A wall that cannot hold one certifiable cell goes SOLID, never a hole.
//
// ★★ WHY THE SHIPPED BEHAVIOUR COULD NOT DELIVER ANY OF THAT. One cell size cannot
// serve a part whose walls run 3.69 mm to 55.38 mm, and both window-shaped attempts
// proved it on his own `M2_verticalStand_THICK` (N* = 5, bead 0.45 mm, rho 0.20):
//
//     strategy                                   planned   culled            cells
//     his typed swept window 3–8 mm ..........      92%    3,302 thin    all 3.00 mm
//     one rung at the widest wall (11.08 mm) .       3%    1,106 thin    11.08 x 34
//     per-local, ladder from finest printable .     100%        0        1.17 mm mostly
//     per-local, ladder anchored at the top ...     100%        0        1.38 / 2.77
//     PER-LOCAL, RUNG ON THE DOMINANT WALL ...      100%        0    2.30 / 4.60 / 9.20
//
// The swept window descends to the FINEST rung that prints (`need_max == L`) and then
// culls everything that cannot hold it. One rung at the widest culls everything that is
// not the widest. Only a per-voxel derivation escapes both, because the cell is chosen
// to FIT the material rather than imposed on it and then refused.
//
// ★ AND WHERE THE LADDER IS ANCHORED IS NOT A DETAIL. It is dyadic — every rung a
// doubling — so there is no rung between 2.77 and 5.54 mm and a wall that can hold
// 4.43 mm falls to 2.77, about 2.5x more struts than it needs. Anchoring a rung on the
// thickness the part is MOSTLY MADE OF is what turns 2.77 mm into 4.60 mm on his walls.
//
// ★ THE TRAP THAT HID ALL OF THIS. `plan_cell_sizes_fit` THROWS when any voxel wants a
// cell finer than the base rung ("emitted a cell coarser than the derivation asked
// for"), and the bridge catches it and returns NO PLAN — silently taking the whole
// part's lattice with it. His thinnest member wanted 0.738 mm against a 1.17 mm rung,
// so one voxel class killed the plan for all 156,313. Clamping sub-printable walls to
// "ask for nothing" is both the fix and his rule 6: they go SOLID.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticePerLocalMemberCellTests: XCTestCase {

    private static let bead = 0.45

    /// A solid built from stacked slabs of stated thickness, on a cubic grid — a part
    /// whose member widths are known by construction and deliberately NOT related by
    /// doublings, so the dyadic ladder has to cope rather than land on them by luck.
    private func stepped(_ thicknessesMM: [Double], spacing: Double = 0.5)
        -> (occ: LatticeVoxelGrid, width: [Double], nStar: Double) {
        let pad = 8
        let ny = thicknessesMM.map { Int($0 / spacing) + pad }.reduce(0, +) + pad
        let nx = 128, nz = 128
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        var y = pad
        for t in thicknessesMM {
            let h = Int(t / spacing)
            for k in 0..<nz { for j in y..<(y + h) { for i in 0..<nx {
                vals[(k * ny + j) * nx + i] = 1
            } } }
            y += h + pad
        }
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: .zero,
                                   spacing: SIMD3<Float>(repeating: Float(spacing)),
                                   values: vals)
        let w = TopOptKit.latticeMemberThicknessMM(
            nx: nx, ny: ny, nz: nz, spacing: occ.spacing,
            solid: vals.map { $0 > 0.5 }, capRadiusVoxels: 32)
        return (occ, w, TopOptKit.latticeLimits(topology: "octet").minCellsPerMember)
    }

    /// Plan a part the way Auto now does, and report what core made of it.
    private func planned(_ p: (occ: LatticeVoxelGrid, width: [Double], nStar: Double))
        throws -> (planned: Int, culled: Int, cells: [Double: Int], base: Double) {
        let printable = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(
            regionWidthsMM: [], lineWidthMM: Self.bead, topology: "octet")).min
        let base = LatticeMeasuredRegionWidth.ladderBaseCellMM(
            occupancy: p.occ, memberThicknessMM: p.width,
            minCellsPerMember: p.nStar, finestPrintableMM: printable)
        let widest = LatticeMeasuredRegionWidth.boundsMM(
            occupancy: p.occ, memberThicknessMM: p.width).first ?? 0
        let ceiling = max(widest / p.nStar, base)
        let desired = LatticeMeasuredRegionWidth.desiredCellMM(
            occupancy: p.occ, memberThicknessMM: p.width,
            minCellsPerMember: p.nStar, baseCellMM: base,
            capMM: 32 * Double(p.occ.spacing.x))
        var cand = [Bool](repeating: false, count: p.occ.values.count)
        var rho = [Double](repeating: 0, count: p.occ.values.count)
        for i in 0..<p.occ.values.count where p.occ.values[i] > 0.5 {
            cand[i] = true; rho[i] = 0.20
        }
        let plan = try XCTUnwrap(TopOptKit.latticeCellSizePlan(
            nx: p.occ.nx, ny: p.occ.ny, nz: p.occ.nz, spacing: p.occ.spacing,
            origin: p.occ.origin, candidate: cand, relativeDensity: rho,
            memberWidthMM: p.width, minCellMM: base, maxCellMM: ceiling,
            minExtrudableWidthMM: Self.bead, capRadiusVoxels: 32,
            topology: "octet", desiredCellMM: desired),
            "★ core must RETURN A PLAN. A nil here is `plan_cell_sizes_fit` throwing and "
            + "the bridge swallowing it — the failure that silently emptied the whole part.")
        var cells: [Double: Int] = [:]
        for l in plan.level where l >= 0 {
            cells[(plan.baseCellMM * pow(2, Double(l)) * 100).rounded() / 100,
                  default: 0] += 1
        }
        let culled = plan.rejectReason.filter { $0 == 1 || $0 == 2 }.count
        return (plan.level.filter { $0 >= 0 }.count, culled, cells, plan.baseCellMM)
    }

    // MARK: - ★★★ his rule 6, on several differently-shaped parts

    /// ★★★ NOTHING IS CULLED, ON ANY OF THEM. This is the bar that answers "will this
    /// work regardless of whatever model I add?" — asked of five parts whose walls are
    /// deliberately awkward: uniform, doubling, non-doubling, a 15x spread, and one with
    /// material too thin to lattice at all.
    func testNoPartIsEverCulledIntoHoles() throws {
        let parts: [(String, [Double])] = [
            ("uniform 20 mm",             [20]),
            ("his part: 22 and 44 mm",    [22, 44]),
            ("non-doubling 9, 14, 23 mm", [9, 14, 23]),
            ("wide spread 4 … 60 mm",     [4, 12, 30, 60]),
            ("one wall too thin to hold a cell", [2, 25])]
        var report: [String] = []
        for (name, walls) in parts {
            let p = stepped(walls)
            try XCTSkipIf(p.width.isEmpty, "core gave no widths in this build")
            let r = try planned(p)
            let sizes = r.cells.keys.sorted().map {
                String(format: "%.2fx%d", $0, r.cells[$0] ?? 0)
            }.joined(separator: " ")
            report.append(String(format: "  %-36@ base %5.2f  planned %6d  culled %4d   %@",
                                 name as NSString, r.base, r.planned, r.culled, sizes))
            XCTAssertEqual(r.culled, 0,
                           "★ HIS RULE: a wall that cannot hold a cell goes SOLID, never "
                           + "a hole. \(name) culled \(r.culled) cells.")
            XCTAssertGreaterThan(r.planned, 0,
                                 "positive control: \(name) must produce a lattice at "
                                 + "all, or `culled == 0` passes over an empty plan")
        }
        print("""

        ================================================================================
        PER-LOCAL-MEMBER, ACROSS PART SHAPES — culled must be 0 everywhere
        \(report.joined(separator: "\n"))
        ================================================================================
        """)
    }

    /// ★★ AND THE CELL FOLLOWS THE MEMBER — his rule 5, asked of REAL GEOMETRY.
    ///
    /// ★ WHY NOT THE STACKED-SLAB FIXTURE. It was tried and it is the wrong instrument:
    /// with a base rung of 2.2 mm a 10 mm wall wants 2.0 mm, holds no rung at all, and
    /// correctly goes SOLID — so the part comes back with ONE cell size and the test
    /// fails for a reason that is the law working. A fixture whose thin wall is below
    /// the ladder cannot demonstrate grading. His own part can: its walls run 3.46 to
    /// 27.71 mm and the middle of that range is squarely inside the ladder.
    func testTheCellActuallyVariesWithTheMember() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet")
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no widths")
        let r = try planned((scene.occupancy, scene.memberThicknessMM,
                             scene.minCellsPerMember))
        print("""

        ================================================================================
        THE CELL FOLLOWS THE MEMBER — his own part, whole
          base \(r.base) mm   planned \(r.planned)   culled \(r.culled)
          cells: \(r.cells.keys.sorted().map { "\($0)mm x\(r.cells[$0] ?? 0)" }
                     .joined(separator: "  "))
        ================================================================================
        """)
        XCTAssertEqual(r.culled, 0, "★ still nothing culled on his real part")
        XCTAssertGreaterThan(r.cells.count, 1,
                             "★ a part whose walls run 3.46–27.71 mm must not get ONE "
                             + "cell size — got \(r.cells)")
        let coarsest = r.cells.keys.max() ?? 0
        let finest = r.cells.keys.min() ?? 0
        XCTAssertGreaterThan(coarsest, finest * 1.9,
                             "★ …and the spread must be a real doubling, not a rounding: "
                             + "\(finest) – \(coarsest) mm")
    }

    /// ★★ THE ANCHOR PUTS A RUNG ON THE DOMINANT WALL — the difference between a 4.60 mm
    /// cell and a 2.77 mm one on his part, which is ~2.5x the struts.
    func testTheLadderIsAnchoredOnTheDominantMember() throws {
        // Mostly 23 mm, with a little 45 mm — his part's shape.
        let p = stepped([23, 23, 23, 45])
        try XCTSkipIf(p.width.isEmpty, "core gave no widths")
        let printable = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(
            regionWidthsMM: [], lineWidthMM: Self.bead, topology: "octet")).min
        let base = LatticeMeasuredRegionWidth.ladderBaseCellMM(
            occupancy: p.occ, memberThicknessMM: p.width,
            minCellsPerMember: p.nStar, finestPrintableMM: printable)
        XCTAssertGreaterThan(base, 0, "positive control: an anchor must be found")
        // Some rung of the ladder must land on what the dominant wall can hold.
        let want = 23.0 / p.nStar
        let rungs = (0..<6).map { base * pow(2, Double($0)) }
        let nearest = rungs.min { abs($0 - want) < abs($1 - want) } ?? 0
        XCTAssertEqual(nearest, want, accuracy: want * 0.25,
                       "★ a rung must land within 25% of the dominant wall's own cell "
                       + "(\(want) mm) — rungs were \(rungs.map { ($0 * 100).rounded() / 100 })")
    }

    /// ★ AND A PART WITH NO MEASURABLE MATERIAL ANSWERS NOTHING rather than anchoring to
    /// a number it invented.
    func testAnUnmeasuredPartGetsNoAnchor() {
        let occ = LatticeVoxelGrid(nx: 2, ny: 1, nz: 1, origin: .zero,
                                   spacing: SIMD3<Float>(repeating: 1), values: [0, 0])
        XCTAssertEqual(LatticeMeasuredRegionWidth.ladderBaseCellMM(
            occupancy: occ, memberThicknessMM: [0, 0], minCellsPerMember: 5,
            finestPrintableMM: 1), 0)
    }
}

// LatticeMemberFloorTests — ★ THE PREVIEW MUST NOT LATTICE WHAT THE RUN LEAVES SOLID
// (task 2026-08-20, from the preview/algorithm audit).
//
// ★★ THE DIVERGENCE. Core refuses to lattice a member too thin to hold
// `lattice_cells_per_member_min` (N* = 5) cells at a printable size — it stays SOLID
// (grading.hpp, bar L4). The preview modelled neither member width nor that floor, so
// on a part with thin ribs it drew lattice the run would never build.
//
// ★ THE THICKNESS COMES FROM CORE, NOT FROM A SECOND IMPLEMENTATION. The app already
// grew its own strut law that way and it ended up 1.4-1.7x adrift. This uses
// `topopt::local_member_thickness_mm` through the bridge.

import XCTest
import simd
@testable import TopOptFlows
import TopOptKit

final class LatticeMemberFloorTests: XCTestCase {

    /// A solid slab `t` voxels thick in Y, embedded in empty space — a member whose
    /// thickness is known by construction.
    private func slab(nx: Int, ny: Int, nz: Int, thickY: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: nx * ny * nz)
        let y0 = (ny - thickY) / 2
        for k in 0..<nz { for j in y0..<(y0 + thickY) { for i in 0..<nx {
            out[(k * ny + j) * nx + i] = true
        } } }
        return out
    }

    func testCoreMeasuresASlabsThicknessThroughTheBridge() throws {
        let nx = 24, ny = 24, nz = 24, thick = 6
        let sp = SIMD3<Float>(repeating: 0.5)          // 0.5 mm voxels
        let t = TopOptKit.latticeMemberThicknessMM(nx: nx, ny: ny, nz: nz, spacing: sp,
                                                   solid: slab(nx: nx, ny: ny, nz: nz,
                                                               thickY: thick))
        try XCTSkipIf(t.isEmpty, "core returned no thickness in this build")
        XCTAssertEqual(t.count, nx * ny * nz)

        // At the slab's mid-plane the member is `thick` voxels = 3.0 mm across.
        let mid = ((nz / 2) * ny + ny / 2) * nx + nx / 2
        XCTAssertGreaterThan(t[mid], 0, "a solid voxel must have a thickness")
        XCTAssertEqual(t[mid], Double(thick) * 0.5, accuracy: 1.0,
                       "★ core must measure the slab at about its real thickness — "
                       + "got \(t[mid]) mm for a \(Double(thick) * 0.5) mm slab")

        // A void voxel has none.
        let air = ((nz / 2) * ny + 1) * nx + nx / 2
        XCTAssertEqual(t[air], 0, "void voxels report no thickness")
    }

    /// ★ THE FLOOR ITSELF, from core, applied the way the run applies it: a member
    /// narrower than N* cells cannot be latticed at that cell.
    func testTheFloorRefusesACellTooCoarseForTheMember() throws {
        let limits = TopOptKit.latticeLimits(topology: "octet")
        try XCTSkipUnless(limits.certifiable, "core carries no octet band in this build")
        let n = limits.minCellsPerMember
        XCTAssertGreaterThan(n, 0, "core must state a cells-per-member floor")

        // A 3 mm member at a 1 mm cell holds 3 cells — below a floor of 5.
        XCTAssertLessThan(3.0 / 1.0, n, "3 cells is below core's floor")
        // The same member at 0.5 mm holds 6 — above it.
        XCTAssertGreaterThanOrEqual(3.0 / 0.5, n, "6 cells clears it")
    }

    /// ★ A NON-CUBIC GRID GETS NO ANSWER, rather than a wrong one. Core's grid carries
    /// ONE spacing; the preview's occupancy is only cubic because its dims are chosen
    /// proportional to the extents, and that is worth checking rather than assuming.
    func testANonCubicGridIsRefused() {
        let solid = [Bool](repeating: true, count: 8 * 8 * 8)
        let skewed = SIMD3<Float>(1.0, 1.0, 2.0)
        XCTAssertTrue(TopOptKit.latticeMemberThicknessMM(nx: 8, ny: 8, nz: 8,
                                                         spacing: skewed,
                                                         solid: solid).isEmpty,
                      "★ a distorted grid must return nothing, not a plausible number")
    }

    /// ★★ AND IT CHANGES THE PICTURE ON HIS OWN PART — measured, so nobody has to
    /// wonder whether the gate is inert.
    ///
    ///     cell 4 mm ....  2555 cells -> 1960   (595 left solid, 23%)
    ///     cell 8 mm ....   417 cells ->  228   (189 left solid, 45%)
    ///
    /// The 8 mm figure is the striking one: N* = 5 means an 8 mm cell needs a 40 mm
    /// member, and his part's median thickness is 27.7 mm — so at that cell setting
    /// the RUN leaves nearly half of what the preview used to draw as solid.
    func testTheFloorRemovesCellsOnHisPart() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 60
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no thickness")
        XCTAssertEqual(scene.minCellsPerMember, 5, accuracy: 0.001,
                       "core's N* for octet")

        let without = LatticePreviewOccupancy.cellField(
            occupancy: scene.occupancy, demand: scene.demand, cellMM: 8)
        let with = LatticePreviewOccupancy.cellField(
            occupancy: scene.occupancy, demand: scene.demand, cellMM: 8,
            memberThickness: scene.memberThicknessMM,
            minCellsPerMember: scene.minCellsPerMember)
        let a = without.values.filter { $0 >= 0 }.count
        let b = with.values.filter { $0 >= 0 }.count
        XCTAssertGreaterThan(a, 0, "positive control: there are cells to gate")
        XCTAssertLessThan(b, a,
                          "★ the floor must actually remove cells on a part whose "
                          + "members cannot hold an 8 mm cell — otherwise the preview "
                          + "is still drawing lattice the run leaves solid")
    }

    /// ★★ AND IT ASKS EVERY VOXEL UNDER THE CELL, NOT THE CENTRE (measured on his
    /// part, 2026-08-20 — the defect his own testing surfaced).
    ///
    /// The gate read one voxel at the cell centre and said `if t > 0`, so a centre
    /// landing in free space returned 0 and "nothing measured here" passed as
    /// "nothing objects". Measured on his 13 mm region:
    ///
    ///     voxels clearing N* at a 4 mm cell ....  0 of 6,276   (0%)
    ///     cells surviving the floor ............  374
    ///
    /// Zero qualifying voxels and 374 cells drawn. Manual 4 mm looked the most
    /// complete of every mode because it was the most wrong.
    func testTheFloorAsksTheWholeCellNotItsCentre() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 13
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no widths")
        let occ = scene.occupancy

        // ★★ THE TOO-COARSE CELL IS DERIVED FROM THE MATERIAL, NOT TYPED.
        //
        // ★ THIS SAID "a 4 mm cell needs 20 mm and this region measures at most
        // ~13.9 mm", and both halves have since moved: `memberThicknessMM` is now an
        // EDT over the PART rather than over the region-clipped slab (it was measuring
        // the declaration, which tapered to zero at its own boundary), and the floor is
        // now the stage MODE's rather than always the accuracy 5. A fixture that hard-
        // codes either number goes stale the next time one of them is right to change,
        // and this one already had — twice. So it asks the material.
        let inside = (0..<occ.count).filter { occ.values[$0] > 0.5 }
        let finite = inside.compactMap {
            scene.memberThicknessMM[$0].isFinite ? scene.memberThicknessMM[$0] : nil
        }
        XCTAssertFalse(finite.isEmpty, "positive control: the region has measured material")
        // A cell no voxel here can hold: 20% coarser than the thickest material allows.
        let tooCoarse = 1.2 * (finite.max() ?? 0) / Swift.max(scene.minCellsPerMember, 1)
        XCTAssertGreaterThan(tooCoarse, 0)
        let qualifying = finite.filter { $0 / tooCoarse >= scene.minCellsPerMember }.count
        XCTAssertEqual(qualifying, 0,
                       "★ fixture check: at \(tooCoarse) mm nothing here clears "
                       + "\(scene.minCellsPerMember) cells across")

        let with = LatticePreviewOccupancy.cellField(
            occupancy: occ, demand: scene.demand, cellMM: tooCoarse,
            memberThickness: scene.memberThicknessMM,
            minCellsPerMember: scene.minCellsPerMember)
        let drawn = with.values.filter { $0 >= 0 }.count
        let without = LatticePreviewOccupancy.cellField(
            occupancy: occ, demand: scene.demand, cellMM: tooCoarse)
        XCTAssertGreaterThan(without.values.filter { $0 >= 0 }.count, 0,
                             "positive control: there are cells to cull")
        XCTAssertEqual(drawn, 0,
                       "★ if NO voxel can hold this cell, none may be drawn. 374 were "
                       + "once, because a centre in free space read as consent — that "
                       + "is the defect this bar holds, and it is independent of the "
                       + "particular width.")

        // ★ AND THE FLOOR STILL LETS THE HONEST CASE THROUGH — 2 mm needs 10 mm and
        // 96% of this region clears it, so this must NOT become a blanket refusal.
        let fine = LatticePreviewOccupancy.cellField(
            occupancy: occ, demand: scene.demand, cellMM: 2.0,
            memberThickness: scene.memberThicknessMM,
            minCellsPerMember: scene.minCellsPerMember)
        XCTAssertGreaterThan(fine.values.filter { $0 >= 0 }.count, 1000,
                             "★ negative control: a cell the material CAN hold must "
                             + "still be drawn")
    }
}

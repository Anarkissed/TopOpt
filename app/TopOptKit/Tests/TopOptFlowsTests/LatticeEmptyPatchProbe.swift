import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ HIS 2026-08-25 REPORT: "empty space where lattice is supposed to be", and his
/// ruling that the printable floor must NEVER produce empty areas. "Too thin to see"
/// is not an explanation — the preview draws far thinner struts elsewhere. So
/// something DELETES cells. This counts them, on his own part, at HIS resolution
/// (Fast · 64³, where the occupancy voxel is ~3.4 mm), and splits the cause:
///
///   A. the inside-fraction gate (the cell holds too little material), or
///   B. the CELLS-PER-MEMBER FLOOR (any voxel under the cell reads too thin ⇒ the
///      WHOLE cell is switched off and the run leaves it solid).
final class LatticeEmptyPatchProbe: XCTestCase {

    func testWhatDeletesTheCells() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let s = LatticeRegionEmission.spec(for: r, role: .include,
                                                     depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("no plane for face \(face)") }
            specs.append(s)
        }
        // ★ HIS RESOLUTION. The member thickness the floor tests is measured on this
        // grid, so its blockiness is part of the mechanism — a 128³ probe would be
        // measuring a part he is not looking at.
        for maxDim in [64, 128] {
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        maxDim: maxDim, regions: specs,
                                        whenEmpty: .latticeNothing)
            let occ = scene.occupancy
            let voxel = Double(max(occ.spacing.x, max(occ.spacing.y, occ.spacing.z)))
            let base = 10.312240362167358          // his finest stated cell
            let finest = 1.2890300452709198        // his printable floor

            func count(_ g: LatticeVoxelGrid) -> (inRegion: Int, painted: Int) {
                var inRegion = 0, painted = 0
                var i = 0
                for k in 0..<g.nz {
                    for j in 0..<g.ny {
                        for x in 0..<g.nx {
                            let p = SIMD3<Double>(
                                Double(g.origin.x) + Double(x) * Double(g.spacing.x),
                                Double(g.origin.y) + Double(j) * Double(g.spacing.y),
                                Double(g.origin.z) + Double(k) * Double(g.spacing.z))
                            if specs.contains(where: {
                                LatticeRegionMask.contains(p, region: $0) }) {
                                inRegion += 1
                                if g.values[i] >= 0 { painted += 1 }
                            }
                            i += 1
                        }
                    }
                }
                return (inRegion, painted)
            }

            // 1. EXACTLY what the stepped bake asks for (floor 1 = his single-cell
            //    aesthetic setting), tested at the finest cell the grade can reach.
            let withFloor = LatticePreviewOccupancy.cellField(
                occupancy: occ, demand: scene.demand, cellMM: base,
                memberThickness: scene.memberThicknessMM,
                minCellsPerMember: 1,
                floorTestCellMM: finest)
            // 2. The same bake with the member floor DISABLED — the difference is
            //    exactly what the floor deleted.
            let noFloor = LatticePreviewOccupancy.cellField(
                occupancy: occ, demand: scene.demand, cellMM: base,
                memberThickness: [], minCellsPerMember: 0,
                floorTestCellMM: finest)
            // 3. And with a floor of 2 — what the STRUCTURAL / non-single-cell path
            //    would delete, for scale.
            let floorTwo = LatticePreviewOccupancy.cellField(
                occupancy: occ, demand: scene.demand, cellMM: base,
                memberThickness: scene.memberThicknessMM,
                minCellsPerMember: 2,
                floorTestCellMM: finest)

            let a = count(withFloor), b = count(noFloor), c = count(floorTwo)
            print("=== EMPTY PATCH PROBE maxDim \(maxDim) (voxel \(String(format: "%.2f", voxel)) mm) ===")
            print(String(format: "in-region base cells: %d", a.inRegion))
            print(String(format: "  floor 1  painted %d  DELETED %d (%.1f%%)",
                         a.painted, a.inRegion - a.painted,
                         100 * Double(a.inRegion - a.painted) / Double(max(1, a.inRegion))))
            print(String(format: "  no floor painted %d  DELETED %d (%.1f%%)",
                         b.painted, b.inRegion - b.painted,
                         100 * Double(b.inRegion - b.painted) / Double(max(1, b.inRegion))))
            print(String(format: "  floor 2  painted %d  DELETED %d (%.1f%%)",
                         c.painted, c.inRegion - c.painted,
                         100 * Double(c.inRegion - c.painted) / Double(max(1, c.inRegion))))
            print(String(format: "  ⇒ member floor deleted %d cells the geometry could hold",
                         b.painted - a.painted))
        }
    }
}

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ WHY THE STRUTS ARE IN PIECES (his 2026-08-25 close-up: strut ends terminating
/// in flat, ragged stubs with no nodes joining them, IDENTICAL at 64³ and 128³ —
/// so not a sampling artefact).
///
/// Two neighbouring cells share nodes only when one size is a WHOLE-NUMBER division
/// of the other AND their tilings are phase-aligned. 12.00 mm beside 13.00 mm never
/// meshes: the strut leaving one cell has nothing to land on in the next, and the
/// march cuts it at the boundary. This counts the boundaries where that is true.
final class LatticeNeighbourMeshProbe: XCTestCase {

    func testHowManyCellBoundariesCannotMesh() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let s = LatticeRegionEmission.spec(for: r, role: .include,
                                                     depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("no plane for face \(face)") }
            specs.append(s)
        }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    maxDim: 64, regions: specs,
                                    whenEmpty: .latticeNothing)
        let occ = scene.occupancy
        let cand = occ.values.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: specs, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let widths = specs.map { r in
            Optional(LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
                region: r, occupancy: occ, partSDF: scene.partSDF))
        }
        let cells = [10.312240362167358, 12.030947089195251]
        let phase = LatticeSDFRenderer.faceTilingPhase(
            regions: specs, cellMM: cells, fallbackCellMM: cells[0],
            origin: occ.origin)

        /// One bake, then: for every pair of side-by-side painted cells, can their
        /// tilings share a node? Ratio must be a whole number (1, 2, 3 …) either way.
        func survey(_ label: String, widthPerRegion: [[Double]?]) {
            guard let baked = LatticePreviewOccupancy.steppedCellField(
                occupancy: occ, demand: nil, regions: specs,
                cellMM: cells, baseCellMM: cells[0], regionPhase: phase,
                memberThickness: scene.memberThicknessMM,
                boundaryDistancePerRegion: boundary,
                widthPerRegion: widthPerRegion,
                finestCellMM: 1.2890300452709198, shapeFitBandMM: 10) else {
                return XCTFail("no bake for \(label)")
            }
            let g = baked.field
            let s = baked.steppedCellMM
            var sizes = Set<Float>()
            for v in s where v > 0 { sizes.insert(v) }
            var pairs = 0, bad = 0
            func idx(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * g.ny + y) * g.nx + x }
            for z in 0..<g.nz {
                for y in 0..<g.ny {
                    for x in 0..<g.nx {
                        let a = s[idx(x, y, z)]
                        guard a > 0 else { continue }
                        for (dx, dy, dz) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
                            let nx = x + dx, ny = y + dy, nz = z + dz
                            guard nx < g.nx, ny < g.ny, nz < g.nz else { continue }
                            let b = s[idx(nx, ny, nz)]
                            guard b > 0 else { continue }
                            pairs += 1
                            let hi = Double(max(a, b)), lo = Double(min(a, b))
                            let ratio = hi / lo
                            // Whole-number ratio ⇒ the coarse cell's nodes are a
                            // subset of the fine one's ⇒ the strut has somewhere
                            // to land. Anything else cuts.
                            if abs(ratio - ratio.rounded()) > 0.01 { bad += 1 }
                        }
                    }
                }
            }
            print(String(format: "%@: %d distinct sizes, %d neighbour pairs, "
                         + "%d CANNOT MESH (%.1f%%)",
                         label, sizes.count, pairs, bad,
                         100 * Double(bad) / Double(max(1, pairs))))
            print("   sizes: " + sizes.sorted().map {
                String(format: "%.2f", $0) }.joined(separator: " "))
        }

        print("=== NEIGHBOUR MESH PROBE (his two faces) ===")
        survey("per-spot ON  (shipped)", widthPerRegion: widths)
        survey("per-spot OFF (region cell only)", widthPerRegion: [])
    }
}

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE CELL READS ITS OWN MATERIAL — his ruling, 2026-08-24: "it should read the
/// actual depth of that area. so preferably per voxel."
///
/// Before this, the whole face took ONE width — the p05 — so his 12.03 mm front wall
/// was pinned to its 8.59 mm sliver and drew a 6.50 mm cell across a face he had set
/// to single-cell/member. Now the region's cell anchors on the wall's MEDIAN and each
/// painted cell divides down to what its OWN wall holds, by the same nearest-whole-fit
/// law the region uses (`round`, not `ceil` — the region cell legitimately overshoots
/// the measured wall by up to half a cell and a ceil would cut every such cell in two).
final class LatticePerVoxelWidthTests: XCTestCase {

    /// His two faces at their true depths (project.json: face 15 → 12, face 2 → 13).
    private func hisScene() throws -> (LatticeSDFScene, [LatticeRegionSpec]) {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: r, role: .include,
                                                        depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("face \(face) has no planar geometry") }
            specs.append(spec)
        }
        return (LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                regions: specs, whenEmpty: .latticeNothing), specs)
    }

    /// The width FIELD carries both the sliver and the bulk — the information the p05
    /// was collapsing away.
    func testTheWidthFieldReadsEachAreasOwnWall() throws {
        let (scene, specs) = try hisScene()
        let field = LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
            region: specs[1], occupancy: scene.occupancy, partSDF: scene.partSDF)
        let seen = field.filter { $0 > 0 }.sorted()
        XCTAssertFalse(seen.isEmpty)
        let p05 = seen[Int(0.05 * Double(seen.count - 1))]
        let med = seen[Int(0.5 * Double(seen.count - 1))]
        // The sliver is real and the bulk is real — the field must hold BOTH.
        XCTAssertEqual(p05, 8.59, accuracy: 0.2,
                       "face 2's thin sliver should still be measured")
        XCTAssertEqual(med, 12.03, accuracy: 0.2,
                       "face 2's wall is mostly 12 mm and the median must say so")
        // And the statistic wrapper agrees with the field it is built on.
        XCTAssertEqual(
            LatticeMeasuredRegionWidth.wallWidthAlongNormalMM(
                region: specs[1], occupancy: scene.occupancy,
                partSDF: scene.partSDF, percentile: 0.5),
            med, accuracy: 1e-9)
    }

    /// Through the REAL bake: with the region cell at the median-derived 13.0 mm, the
    /// bulk of face 2 keeps one 13 mm cell and only the cells whose own wall is the
    /// 8.59 mm sliver divide — the sliver no longer pins the whole face, and the face
    /// no longer hands the sliver a cell it cannot hold.
    func testASliverNoLongerPinsTheWholeFace() throws {
        let (scene, specs) = try hisScene()
        let occ = scene.occupancy
        let cand = occ.values.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: [specs[1]], candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let widths = [Optional(LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
            region: specs[1], occupancy: occ, partSDF: scene.partSDF))]
        // ★ NEVER-OVERSHOOT (his ruling, 2026-08-24 evening): the fit depth clamps
        // to the material, so the region cell is the wall's median 12.03 — never
        // the declared 13.0 that used to sit on a 12 mm wall.
        let regionCell = 12.03
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: scene.demand, regions: [specs[1]],
            cellMM: [regionCell], baseCellMM: regionCell,
            minCellsPerMember: 1,
            boundaryDistancePerRegion: boundary,
            widthPerRegion: widths,
            finestCellMM: 1.625) else {
            return XCTFail("stepped bake produced nothing")
        }
        var hist: [Float: Int] = [:]
        for v in baked.steppedCellMM where v > 0 { hist[v, default: 0] += 1 }
        let full = hist.filter { abs(Double($0.key) - 12.03) < 0.1 }.values.reduce(0, +)
        let halved = hist.filter { abs(Double($0.key) - 6.02) < 0.1 }.values.reduce(0, +)
        XCTAssertGreaterThan(full, 0, "the bulk must keep the 12.03 mm cell; sizes=\(hist)")
        XCTAssertGreaterThan(halved, 0,
                             "the sliver's cells must divide to ~6.0; sizes=\(hist)")
        XCTAssertGreaterThan(full, halved,
                             "the sliver is a sliver — most of the face is 12 mm thick")
    }

    /// ★ THE NEVER-OVERSHOOT INVARIANT ITSELF (his ruling, 2026-08-24 evening: "a
    /// 13mm cell never be on a 12mm wall"): no painted cell may exceed the wall
    /// measured at its own centre, and the bulk of a wall whose cell equals its
    /// width must KEEP that cell — the ceil must not divide an exact fit.
    func testNoCellExceedsItsOwnWall() throws {
        let (scene, specs) = try hisScene()
        let occ = scene.occupancy
        let cand = occ.values.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: [specs[0]], candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let widthField = LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
            region: specs[0], occupancy: occ, partSDF: scene.partSDF)
        let regionCell = 10.31          // face 15's never-overshoot cell = its wall
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: scene.demand, regions: [specs[0]],
            cellMM: [regionCell], baseCellMM: regionCell,
            minCellsPerMember: 1,
            boundaryDistancePerRegion: boundary,
            widthPerRegion: [widthField],
            finestCellMM: 1.625) else {
            return XCTFail("stepped bake produced nothing")
        }
        let g = baked.field
        var kept = 0, overshoots = 0, painted = 0
        for i in 0..<baked.steppedCellMM.count where baked.steppedCellMM[i] > 0 {
            painted += 1
            let size = Double(baked.steppedCellMM[i])
            // The wall at this cell's own centre, from the same field the bake read.
            let z = i / (g.nx * g.ny), y = (i / g.nx) % g.ny, x = i % g.nx
            let p = SIMD3<Float>(g.origin.x + Float(x) * g.spacing.x,
                                 g.origin.y + Float(y) * g.spacing.y,
                                 g.origin.z + Float(z) * g.spacing.z)
            let og = (p - occ.origin) / occ.spacing
            let a = Int(og.x.rounded()), b = Int(og.y.rounded()), c = Int(og.z.rounded())
            guard a >= 0, a < occ.nx, b >= 0, b < occ.ny, c >= 0, c < occ.nz
            else { continue }
            let w = widthField[(c * occ.ny + b) * occ.nx + a]
            guard w > 0 else { continue }   // unmeasured centre = unconstrained cell
            // Half a voxel of quantisation slack: the walk steps in whole voxels.
            if size > w + Double(occ.spacing.x) { overshoots += 1 }
        }
        for v in baked.steppedCellMM where v > 0 && abs(Double(v) - regionCell) < 0.1 {
            kept += 1
        }
        XCTAssertGreaterThan(painted, 0)
        var hist: [Float: Int] = [:]
        for v in baked.steppedCellMM where v > 0 { hist[v, default: 0] += 1 }
        print("INVARIANT sizes=\(hist) painted=\(painted) kept=\(kept)")
        XCTAssertEqual(overshoots, 0,
                       "no cell may exceed the wall at its own centre")
        XCTAssertGreaterThan(kept, 0,
                             "an exact fit must be KEPT, not divided by the ceil")
    }
}

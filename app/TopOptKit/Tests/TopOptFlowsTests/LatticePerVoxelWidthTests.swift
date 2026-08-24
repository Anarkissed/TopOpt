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
        // The cell the median width derives at floor 1: round(13 / 12.03) = 1 → 13.0.
        let regionCell = 13.0
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
        let full = hist.filter { abs(Double($0.key) - 13.0) < 0.1 }.values.reduce(0, +)
        let halved = hist.filter { abs(Double($0.key) - 6.5) < 0.1 }.values.reduce(0, +)
        XCTAssertGreaterThan(full, 0, "the bulk must keep the 13 mm cell; sizes=\(hist)")
        XCTAssertGreaterThan(halved, 0,
                             "the sliver's cells must divide to 6.5; sizes=\(hist)")
        XCTAssertGreaterThan(full, halved,
                             "the sliver is a sliver — most of the face is 12 mm thick")
    }

    /// Control: a wall whose width never demands a division is untouched by the new
    /// field — face 15 at its 12.0 mm cell reads 10.31–12.03 everywhere, and
    /// round(12/10.31) = 1, so no cell shrinks and the bake is what it always was.
    func testAUniformWallIsUntouched() throws {
        let (scene, specs) = try hisScene()
        let occ = scene.occupancy
        let cand = occ.values.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: [specs[0]], candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let widths = [Optional(LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
            region: specs[0], occupancy: occ, partSDF: scene.partSDF))]
        let regionCell = 12.0
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: scene.demand, regions: [specs[0]],
            cellMM: [regionCell], baseCellMM: regionCell,
            minCellsPerMember: 1,
            boundaryDistancePerRegion: boundary,
            widthPerRegion: widths,
            finestCellMM: 1.625) else {
            return XCTFail("stepped bake produced nothing")
        }
        // The shape-fit near the outline may still grade; the WIDTH must not. So the
        // check is against the same bake WITHOUT the width field: identical output.
        guard let control = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: scene.demand, regions: [specs[0]],
            cellMM: [regionCell], baseCellMM: regionCell,
            minCellsPerMember: 1,
            boundaryDistancePerRegion: boundary,
            finestCellMM: 1.625) else {
            return XCTFail("control bake produced nothing")
        }
        XCTAssertEqual(baked.steppedCellMM, control.steppedCellMM,
                       "a wall that holds its cell everywhere must bake byte-identical")
    }
}

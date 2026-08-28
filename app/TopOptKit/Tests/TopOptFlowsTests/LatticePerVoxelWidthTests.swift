import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE CELL READS ITS OWN MATERIAL — his rulings, 2026-08-24 ("it should read
/// the actual depth of that area. so preferably per voxel") and 2026-08-25
/// ("per-spot cell = min(prism depth, local material depth), both directions,
/// stepped algorithm only").
///
/// Before this, the whole face took ONE width — the p05 — so his 12.03 mm front wall
/// was pinned to its 8.59 mm sliver. Now each painted cell is fitted to ITS OWN
/// material in BOTH directions: a thin spot gets its own (smaller) wall as the cell,
/// and a spot whose wall reaches the declared depth grows to span it — which is what
/// puts the far cap on a cell boundary everywhere it touches material.
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

    /// Through the REAL bake, under his 2026-08-25 ruling: "per-spot cell =
    /// min(prism depth, local material depth), both directions". The bulk of
    /// face 2 keeps its ~12 mm cell, the cells whose own wall REACHES the
    /// declared 13 mm GROW to span it (the far cap lands flush by
    /// construction), and a thin spot gets its own wall — never a division of
    /// someone else's cell. The sliver no longer pins the face in either
    /// direction.
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
        XCTAssertGreaterThan(full, 0, "the bulk must keep the 12.03 mm cell; sizes=\(hist)")
        XCTAssertGreaterThan(full, hist.values.reduce(0, +) / 2,
                             "most of the face is ~12 mm thick and must carry the "
                             + "region's own cell; sizes=\(hist)")
        // ★★★ SUPERSEDED 2026-08-26 — THE WHOLE-NUMBER-DIVISION RULE IS GONE.
        //
        // This used to assert that every size is `regionCell / n` for whole n, on the
        // reasoning that only then do neighbouring cells share nodes. He replaced the
        // rule directly:
        //
        //   "single-cell/member means make the largest single cell across the entire
        //    model — per voxel. So this will change based on the thickness of the area
        //    it's in. If the area is 13 mm, the cell is 13 mm, if the area next to it
        //    is 12 mm the cell next to it is 12 mm."
        //
        // The S/n ladder could not express that: a 10.31 mm wall under a 12.03 mm
        // region cell had no permitted size between 12.03 (overshoot) and 6.02 (HALF
        // the wall), so it took 6.02 — and a wall carrying S beside S/2 beside S/3 is
        // the quilt. What is asserted instead is the rule he actually stated, plus the
        // one he stated in the same breath about which divisors stepped may use.
        let floorAcross = 1.0                       // single-cell: one cell across
        for (size, count) in hist {
            let mm = Double(size)
            // ★ NEVER OVERSHOOT (§8) — still binding, and now by construction: the
            // cell is min(declared depth, local wall) / cellsAcross, so it can never
            // exceed the material. 13.0 is face 2's declared depth and is the cap.
            XCTAssertLessThanOrEqual(
                mm, 13.0 / floorAcross + 1e-6,
                "\(count) cells at \(size) mm exceed the declared depth — "
                + "the face prism cannot make a wall thicker than it is")
            // ★ AND S/2 IS NEVER A STEPPED SIZE (his 2026-08-26 rule: "Stepped grade
            // means NOT dyadic (any number but 1/2 is ok)"). This is the size his tap
            // callouts kept reporting while the wall looked like fabric.
            XCTAssertGreaterThan(
                abs(mm - regionCell / 2), 0.05,
                "\(count) cells sit at exactly half the \(regionCell) mm region "
                + "cell — S/2 is the one divisor stepped may never produce")
        }
        // ★ AND THE BODY OF THE FACE FOLLOWS ITS OWN WALL. Face 2 measures ~12.03 mm
        // over most of its area and reaches the declared 13.0 where the material is
        // thicker; both are legitimate, and neither is a division of the other.
        let followsWall = hist.filter {
            let mm = Double($0.key)
            return mm >= 10.0 && mm <= 13.01
        }.values.reduce(0, +)
        XCTAssertGreaterThan(
            followsWall, hist.values.reduce(0, +) / 2,
            "most of the face must carry a cell that spans its OWN wall, not a "
            + "division of someone else's; sizes=\(hist)")
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

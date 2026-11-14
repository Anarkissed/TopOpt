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
        let widths = LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
            region: specs[1], occupancy: occ, partSDF: scene.partSDF)
        // ★ NEVER-OVERSHOOT (his ruling, 2026-08-24 evening): the fit depth clamps
        // to the material, so the region cell is the wall's median 12.03 — never
        // the declared 13.0 that used to sit on a 12 mm wall.
        let regionCell = 12.03
        // ★ THE OCTREE BAKE (2026-09-14) is what the app draws: the region's own cell
        // wherever its corners fit inside the outline AND the material, split into the
        // nesting rungs where they do not. A thin spot therefore gets a smaller cell
        // of ITS OWN ladder, and the bulk keeps the region cell; nothing is a division
        // of some other wall's cell. (His 2026-08-26 ban on S/2 was lifted on
        // 2026-09-14 — "why is it ALWAYS 1/2?" was answered with the nesting rule and
        // he accepted 12 → 6 → 2 — so the rungs here are 12.03 → 6.015 → 3.0075.)
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        guard let baked = LatticePreviewOccupancy.octreeCellField(
            occupancy: occ, demand: scene.demand, regions: [specs[1]],
            cellMM: [regionCell], lineWidthMM: 0.45, realFloorMM: 1.625,
            shapeFitBandMM: 0, shapeFit: false,
            densityLo: 0.05, densityHi: 0.9, densityGamma: 1, latticeID: "octet",
            stats: &st) else {
            return XCTFail("octree bake produced nothing")
        }
        var hist: [Float: Int] = [:]
        for v in baked.steppedCellMM where v > 0 { hist[v, default: 0] += 1 }
        let full = hist.filter { abs(Double($0.key) - regionCell) < 0.1 }.values.reduce(0, +)
        XCTAssertGreaterThan(full, 0, "the bulk must keep the 12.03 mm cell; sizes=\(hist)")
        XCTAssertGreaterThan(st.slotsKept[regionCell] ?? 0, 10,
                             "the 8.59 mm sliver must not pin the face: whole 12.03 mm cells "
                             + "are expected over the 12 mm bulk; kept=\(st.slotsKept)")
        // 12.03 / 4 = 3.0075 is the finest tile: 2.005 would put a bead-wide strut at
        // 26.5 % of the cell (core's law), over `finestRungMaxDensity`. Stepped's menu
        // (2026-09-17, any step) is every multiple of the halves, thirds and quarters:
        // and fifths (2.41 mm prints open at a 0.45 bead, just under the ceiling):
        // 12.03, 9.62, 9.02, 8.02, 7.22, 6.015, 4.81, 4.01, 3.0075, 2.41 — the same
        // list the bake builds. Never 10.03 or 11.03: they would need a 2.0 or 1.0 mm
        // tile behind them, and neither prints open ("exclude 10 and 11").
        let rungs = LatticePreviewOccupancy.steppedSizeMenu(base: 12.03, floorMM: 1.625,
                                                            lineWidthMM: 0.45, latticeID: "octet")
        for want in [12.03, 9.0225, 8.02, 6.015, 4.01, 3.0075] {
            XCTAssertTrue(rungs.contains { abs($0 - want) < 1e-6 }, "\(want) missing from \(rungs)")
        }
        for never in [12.03 * 10 / 12, 12.03 * 11 / 12, 12.03 / 6] {
            XCTAssertFalse(rungs.contains { abs($0 - never) < 1e-6 }, "\(never) must not be on the menu: \(rungs)")
        }
        for (size, count) in hist {
            let mm = Double(size)
            XCTAssertLessThanOrEqual(
                mm, 13.0 + 1e-6,
                "\(count) cells at \(size) mm exceed the declared depth — "
                + "the face prism cannot make a wall thicker than it is")
            XCTAssertTrue(rungs.contains { abs($0 - mm) < 0.02 },
                          "\(count) cells at \(size) mm are not a rung of the region's own ladder "
                          + "\(rungs) — a division of someone else's cell")
        }
        // ★ AND OVER THE SLIVER the region cell cannot stand: a 12.03 mm cell's far
        // corners lie outside an 8.59 mm wall, so those texels carry a smaller rung.
        let g = baked.field
        var overSliver = 0, overSliverFull = 0
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let idx = (k * g.ny + j) * g.nx + i
            guard baked.steppedCellMM[idx] > 0 else { continue }
            let mid = SIMD3<Double>(g.origin) + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * Double(g.spacing.x)
            let r = (SIMD3<Float>(mid) - occ.origin) / occ.spacing
            let vi = Int(r.x.rounded()), vj = Int(r.y.rounded()), vk = Int(r.z.rounded())
            guard vi >= 0, vj >= 0, vk >= 0, vi < occ.nx, vj < occ.ny, vk < occ.nz else { continue }
            let w = widths[(vk * occ.ny + vj) * occ.nx + vi]
            guard w > 0, w < 9.5 else { continue }
            overSliver += 1
            if abs(Double(baked.steppedCellMM[idx]) - regionCell) < 0.1 { overSliverFull += 1 }
        }}}
        XCTAssertGreaterThan(overSliver, 0, "the sliver must be measured — vacuous otherwise")
        XCTAssertLessThan(Double(overSliverFull), 0.05 * Double(overSliver) + 1,
                          "\(overSliverFull) of \(overSliver) texels over the thin sliver carry the full 12.03 mm cell")
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

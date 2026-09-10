import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ WHAT THE MARCH DRAWS AS **SOLID** — the maintainer's "quilt", identified.
///
/// His 2026-08-26 capture (evidence/2026-08-26-holes-and-quilt/02) shows flat pink
/// blobs with NO strut structure inside them. They are not a fine lattice; they are
/// the march drawing solid material. This counts every solid term on his own bake.
///
/// MEASURED: the OUTLINE RIM draws **82 of 528 painted cells (15.5%)** solid. The
/// "no same-size neighbour" path draws ZERO (a cell is its own neighbour at offset
/// 0, so `anyActive` is effectively always true for a painted cell) — that theory
/// was refuted by this probe, do not re-run it.
///
/// Replicates the shader's own tests on the CPU: for every painted cell,
/// walk the 3x3x3 neighbourhood exactly as `lsdf_march` does (block centre, phase,
/// same-CELL-SIZE gate) and count the cells that find NO same-size active
/// neighbour. Those are the ones the march draws as SOLID — his "quilt".
final class LatticeSolidFillProbe: XCTestCase {
    func testHowManyCellsTheMarchWillDrawSolid() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let pl = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let s = LatticeRegionEmission.spec(for: pl, role: .include,
                                                     depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("no plane") }
            specs.append(s)
        }
        let sc = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                 maxDim: 64, regions: specs, whenEmpty: .latticeNothing)
        let occ = sc.occupancy
        let cells = [10.312240362167358, 12.030947089195251]
        let cand = occ.values.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: specs, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let widths = specs.map { r in
            Optional(LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
                region: r, occupancy: occ, partSDF: sc.partSDF))
        }
        let phase = LatticeSDFRenderer.faceTilingPhase(
            regions: specs, cellMM: cells, fallbackCellMM: cells[0], origin: occ.origin)
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: nil, regions: specs,
            cellMM: cells, baseCellMM: cells[0], regionPhase: phase,
            memberThickness: sc.memberThicknessMM,
            boundaryDistancePerRegion: boundary, widthPerRegion: widths,
            finestCellMM: 1.2890300452709198, shapeFitBandMM: 10) else {
            return XCTFail("no bake")
        }
        let g = baked.field
        let S0 = baked.baseCellMM
        func sizeAt(_ x: Int, _ y: Int, _ z: Int) -> Double {
            guard x >= 0, y >= 0, z >= 0, x < g.nx, y < g.ny, z < g.nz else { return -1 }
            return Double(baked.steppedCellMM[(z * g.ny + y) * g.nx + x])
        }
        var painted = 0, solid = 0
        var sizesOfSolid: [Double: Int] = [:]
        for z in 0..<g.nz { for y in 0..<g.ny { for x in 0..<g.nx {
            let i = (z * g.ny + y) * g.nx + x
            let S = Double(baked.steppedCellMM[i])
            guard S > 0 else { continue }
            painted += 1
            let m = S / S0
            let packed = Double(baked.steppedPhase[i])
            let ax = Int(packed + 1e-4)
            let frac = packed - Double(ax)
            var ph = SIMD3<Double>(0, 0, 0)
            if ax >= 0, ax <= 2 { ph[ax] = frac * m }
            let cb = SIMD3<Double>(Double(x), Double(y), Double(z))
            let blk = SIMD3<Double>(((cb.x - ph.x) / m).rounded(.down),
                                    ((cb.y - ph.y) / m).rounded(.down),
                                    ((cb.z - ph.z) / m).rounded(.down))
            var any = false
            outer: for oz in -1...1 { for oy in -1...1 { for ox in -1...1 {
                let nb = blk + SIMD3<Double>(Double(ox), Double(oy), Double(oz))
                let cc = SIMD3<Double>(((nb.x + 0.5) * m + ph.x).rounded(.down),
                                       ((nb.y + 0.5) * m + ph.y).rounded(.down),
                                       ((nb.z + 0.5) * m + ph.z).rounded(.down))
                let ns = sizeAt(Int(cc.x), Int(cc.y), Int(cc.z))
                if ns > 0, abs(ns - S) <= 1e-3 * max(S, 1.0) { any = true; break outer }
            } } }
            if !any { solid += 1; sizesOfSolid[S, default: 0] += 1 }
        } } }
        // ★ THE OTHER SOLID TERM: the outline rim. The march does
        //     if (stepped && outlineBand > 0) F = min(F, max(dClip, dOutline - band))
        // so EVERY cell whose baked outline distance is under the band renders
        // SOLID, wherever it happens to sit.
        let voxel = Double(max(occ.spacing.x, max(occ.spacing.y, occ.spacing.z)))
        let band = max(1.2890300452709198, voxel)
        var rimSolid = 0
        var minD = Double.infinity, maxD = -Double.infinity
        var carriers = 0
        for i in 0..<baked.level.count where baked.steppedCellMM[i] > 0 {
            let d = Double(baked.level[i])
            guard d > 0, d < 1e3 else { continue }
            carriers += 1
            minD = min(minD, d); maxD = max(maxD, d)
            if d <= band { rimSolid += 1 }
        }
        print(String(format: "painted cells %d", painted))
        print(String(format: "OUTLINE RIM: band %.2f mm, %d cells carry a distance (%.2f..%.2f), %d are INSIDE the band -> drawn SOLID (%.1f%% of painted)",
                     band, carriers, minD, maxD, rimSolid,
                     100 * Double(rimSolid) / Double(max(1, painted))))
        print(String(format: "cells the march will draw SOLID (no same-size neighbour): %d (%.1f%%)",
                     solid, 100 * Double(solid) / Double(max(1, painted))))
        print("  their sizes: " + sizesOfSolid.keys.sorted()
            .map { String(format: "%.2f=%d", $0, sizesOfSolid[$0]!) }.joined(separator: " "))
    }
}

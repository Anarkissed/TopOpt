import XCTest
import simd
@testable import TopOptFlows

/// ★ A SHRUNK CELL'S CAPS STAY ON ITS OWN BOUNDARIES. `faceTilingPhase` measures the
/// cap's offset in REGION cells; the shader shifts each cell's tiling by
/// `pfrac × the LOCAL cell` (`lsdf_cell_frame_at`). A cell the grade shrinks to S/n
/// therefore needs the fraction rescaled — `frac·n mod 1` — or its caps slice
/// mid-cell: the quilt, re-created exactly in the graded bands (measured on his
/// face 15, frac 0.1011: 107 of 304 cells at S/2–S/3, caps 0.51–0.68 mm off).
///
/// This test drives the REAL encoder and the REAL bake on a synthetic slab whose
/// face plane deliberately does NOT land on the tiling origin (frac ≈ 0.3), lets the
/// shape-fit band shrink the outline cells, and then asserts — with the shader's own
/// tiling rule — that the near cap lands on a boundary of EVERY painted cell size.
final class LatticeSteppedShrunkPhaseTests: XCTestCase {

    func testShrunkCellsKeepTheCapOnTheirOwnBoundary() throws {
        // A 30×16×30 mm slab of material on a 1 mm grid, its face plane 1.8 mm above
        // the grid origin along y — 0.3 of the 6 mm region cell, so the encoder must
        // produce a non-trivial fraction for the test to mean anything.
        let nx = 34, ny = 20, nz = 34
        let origin = SIMD3<Float>(0.37, 0.63, 0.11)
        let spacing = SIMD3<Float>(repeating: 1)
        let cell = 6.0
        let faceY = Double(origin.y) + 1.8
        let depth = 12.0
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        for k in 2..<(nz - 2) {
            for j in 0..<ny {
                let y = Double(origin.y) + Double(j)
                guard y >= faceY - 0.5, y <= faceY + depth + 0.5 else { continue }
                for i in 2..<(nx - 2) {
                    vals[(k * ny + j) * nx + i] = 1
                }
            }
        }
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin,
                                   spacing: spacing, values: vals)
        var spec = LatticeRegionSpec(role: .include, kind: .face)
        spec.origin = SIMD3<Double>(Double(origin.x) + 17, faceY, Double(origin.z) + 17)
        spec.normal = SIMD3<Double>(0, 1, 0)
        spec.halfUMM = 40
        spec.halfWMM = 40
        spec.depthMM = depth
        let regions = [spec]
        let cand = vals.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: regions, candidate: cand,
            nx: nx, ny: ny, nz: nz, spacing: spacing)
        let phase = LatticeSDFRenderer.faceTilingPhase(
            regions: regions, cellMM: [cell], fallbackCellMM: cell, origin: origin)
        let packedRegion = Double(phase[0])
        let regionFrac = packedRegion - packedRegion.rounded(.down)
        XCTAssertGreaterThan(regionFrac, 0.05,
                             "the fixture must put the face OFF the tiling origin, or "
                             + "the test is vacuous — every fraction is 0")

        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: nil, regions: regions,
            cellMM: [cell], baseCellMM: cell,
            regionPhase: phase,
            boundaryDistancePerRegion: boundary,
            finestCellMM: 1.5, shapeFitBandMM: 6) else {
            return XCTFail("the bake produced nothing")
        }

        // The shader's tiling rule: boundaries at origin[axis] + (k + pfrac)·sLocal.
        // The near cap must land on one, for EVERY painted size.
        let capNear = spec.origin.y - Double(origin.y)
        var sizes: [Float: Float] = [:]   // size → packed phase
        for idx in 0..<baked.steppedCellMM.count where baked.steppedCellMM[idx] > 0 {
            sizes[baked.steppedCellMM[idx]] = baked.steppedPhase[idx]
        }
        XCTAssertGreaterThan(sizes.count, 1,
                             "the band shrank nothing — the fixture no longer "
                             + "exercises the rescaling and the test is vacuous")
        for (size, packed) in sizes {
            let sLocal = Double(size)
            let p = Double(packed)
            let paxis = Int(p + 1e-4)
            XCTAssertEqual(paxis, 1, "the phase must stay on the region's own axis")
            let pfrac = p - Double(paxis)
            var r = (capNear - pfrac * sLocal).truncatingRemainder(dividingBy: sLocal)
            if r < 0 { r += sLocal }
            let off = Swift.min(r, sLocal - r)
            XCTAssertLessThan(off, 0.02 * sLocal,
                              String(format: "cap %.3f mm off a boundary of the "
                                     + "%.3f mm cell (frac %.4f) — a shrunk cell "
                                     + "kept the REGION's fraction", off, sLocal, pfrac))
        }
    }
}

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ FOUND BY THE DEFAULT GRADE PROOF (ruling 4, 2026-10-02): the octree bake kept each texel's
/// first-claiming region in an `Int8`, so the 128th include region to paint a texel trapped
/// ("Not enough bits to represent the passed value", LatticeOctreeBake.swift:651). 102117B9
/// converted to Default Grade has 177 regions; any Stepped or Default Grade project past 127
/// include regions crashed the preview. 130 disjoint 6 mm patches on one plate, so regions past
/// 127 each own texels of their own (overlapping regions would let the first 128 claim
/// everything and never reach the narrowing).
final class LatticeOctreeManyRegionsTests: XCTestCase {

    func testABakeWithMoreThan127RegionsPaintsEveryRegion() throws {
        let tilesX = 13, tilesZ = 10, tile = 6, ny = 12
        let nx = tilesX * tile, nz = tilesZ * tile
        let origin = SIMD3<Float>(0, 0, 0), depth = 6.0, faceY = 1.8
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let y = Double(j)
            if y >= faceY - 0.5, y <= faceY + depth + 0.5 { vals[(k * ny + j) * nx + i] = 1 }
        }}}
        var regions: [LatticeRegionSpec] = []
        for tz in 0..<tilesZ { for tx in 0..<tilesX {
            var spec = LatticeRegionSpec(role: .include, kind: .face)
            spec.origin = SIMD3<Double>(Double(tx * tile) + 3, faceY, Double(tz * tile) + 3)
            spec.normal = SIMD3<Double>(0, 1, 0)
            spec.halfUMM = 3; spec.halfWMM = 3
            spec.depthMM = depth
            let h = 2.4
            spec.outlineLoops = [[SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]]
            regions.append(spec)
        }}
        XCTAssertEqual(regions.count, 130)
        let spacing = SIMD3<Float>(repeating: 1)
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing, values: vals)
        let demand = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing,
                                      values: [Float](repeating: 0.3, count: vals.count))
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let baked = LatticePreviewOccupancy.octreeCellField(
            occupancy: occ, demand: demand, regions: regions,
            cellMM: [Double](repeating: 3, count: regions.count), lineWidthMM: 0.45, realFloorMM: 1.2,
            shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3, densityGamma: 1,
            latticeID: "octet", dyadicSteps: true, stats: &st)
        XCTAssertNotNil(baked, "★ the bake completes past 127 regions")
        let past = st.paintedByRegion.filter { $0.key >= 128 && $0.value > 0 }
        XCTAssertEqual(past.count, 2, "★ regions 128 and 129 paint their own patches: \(past)")
        XCTAssertEqual(st.paintedByRegion.filter { $0.value > 0 }.count, 130, "every patch is painted")
    }
}

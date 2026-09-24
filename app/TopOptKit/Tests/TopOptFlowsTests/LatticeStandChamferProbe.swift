import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ PROBE (2026-09-24, his image 4): the chamfers at the leg's outer corners (f56 between
/// face 15 and face 23, f57 between face 2 and face 23). The shell keeps a fragment where
/// the region field sampled AT THE SURFACE is ≥ 0; here that sample is taken at every
/// chamfer triangle's centroid and at the voxels either side of the surface.
final class LatticeStandChamferProbe: XCTestCase {
    func testTheChamferSurfaceSample() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [15, 2, 23], regionIDs: [])
        let key23 = LatticeSelectableRef.face(group: gid, face: 23).key
        let solidGrid = LatticePreviewOccupancy.occupancy(positions: mesh.positions, indices: mesh.indices, bounds: mesh.bounds, maxDim: 128)
        func solidAt(_ p: SIMD3<Double>) -> Bool {
            let g = (SIMD3<Float>(p) - solidGrid.origin) / solidGrid.spacing
            let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
            guard i >= 0, j >= 0, k >= 0, i < solidGrid.nx, j < solidGrid.ny, k < solidGrid.nz else { return false }
            return solidGrid.values[(k * solidGrid.ny + j) * solidGrid.nx + i] > 0.5
        }
        let regions = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include], primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 12,
            selectableDepthMM: [LatticeSelectableRef.face(group: gid, face: 2).key: 13, key23: 20],
            selectableExpandMM: [key23: 4.15],
            facets: { LatticeFaceFacets.facets(face: $0, in: mesh) },
            solidAt: solidAt,
            resolve: { LatticeRegionEmission.planeFor(face: $0, in: mesh) }).regions
        let n = 8
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for i in 0..<(n * n * n) { tensor[6 * i] = 10; tensor[6 * i + 1] = 3; tensor[6 * i + 2] = 1 }
        var o = LatticeOrganicInput(tensor: tensor, dims: (n, n, n), originMM: SIMD3(Double(mesh.bounds.min.x), Double(mesh.bounds.min.y), Double(mesh.bounds.min.z)),
                                    spacingMM: 30, minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                    separationMinMM: 3, separationMaxMM: 3, rhoMin: 0.05, rhoMax: 0.9, showRepairs: false)
        o.solidRimMM = 3.41
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                    algorithm: "organic", organic: o, regions: regions, whenEmpty: .latticeNothing)
        guard let f = scene.regionSDF, let pr = scene.prismSDF else { XCTFail("no field"); return }
        func sample(_ g: LatticeVoxelGrid, _ p: SIMD3<Double>) -> Double { LatticeCurvedOutlineBandProbe.sampleLinear(g, p) }
        func nearest(_ g: LatticeVoxelGrid, _ p: SIMD3<Double>) -> Float {
            let q = (SIMD3<Float>(p) - g.origin) / g.spacing
            let i = Int(q.x.rounded()), j = Int(q.y.rounded()), k = Int(q.z.rounded())
            guard i >= 0, j >= 0, k >= 0, i < g.nx, j < g.ny, k < g.nz else { return .nan }
            return g.values[(k * g.ny + j) * g.nx + i]
        }
        let h = Double(f.spacing.x)
        for fid in [56, 57, 48, 68, 73, 76, 77] {
            var tris = 0, surfNeg = 0, inNeg = 0, outNeg = 0, outInPrism = 0
            var worst = (v: 1e9, p: SIMD3<Double>(0, 0, 0))
            var t = 0
            while t + 2 < mesh.indices.count {
                let tri = t / 3
                let id = tri < mesh.faceIDs.count ? Int(mesh.faceIDs[tri]) : -1
                let i0 = Int(mesh.indices[t]) * 3, i1 = Int(mesh.indices[t + 1]) * 3, i2 = Int(mesh.indices[t + 2]) * 3
                t += 3
                guard id == fid else { continue }
                let p0 = SIMD3<Double>(Double(mesh.positions[i0]), Double(mesh.positions[i0 + 1]), Double(mesh.positions[i0 + 2]))
                let p1 = SIMD3<Double>(Double(mesh.positions[i1]), Double(mesh.positions[i1 + 1]), Double(mesh.positions[i1 + 2]))
                let p2 = SIMD3<Double>(Double(mesh.positions[i2]), Double(mesh.positions[i2 + 1]), Double(mesh.positions[i2 + 2]))
                let cr = simd_cross(p1 - p0, p2 - p0)
                guard simd_length(cr) > 1e-12 else { continue }
                let nOut = simd_normalize(cr)
                // several points across the triangle, not just the centroid
                for (wa, wb) in [(1.0 / 3, 1.0 / 3), (0.6, 0.2), (0.2, 0.6), (0.2, 0.2)] {
                    let c = p0 * wa + p1 * wb + p2 * (1 - wa - wb)
                    tris += 1
                    let s = sample(f, c)
                    if s < 0 { surfNeg += 1; if s < worst.v { worst = (s, c) } }
                    if sample(f, c - nOut * h) < 0 { inNeg += 1 }
                    let outP = c + nOut * h
                    if sample(f, outP) < 0 { outNeg += 1 }
                    if nearest(pr, outP) < 0 { outInPrism += 1 }
                }
            }
            print(String(format: "PROBE chamfer f%d: %d surface samples · field < 0 AT the surface %d · one voxel inside %d · one voxel OUTSIDE %d (of which inside a prism %d) · worst %.2f at (%.1f,%.1f,%.1f)",
                         fid, tris, surfNeg, inNeg, outNeg, outInPrism, worst.v, worst.p.x, worst.p.y, worst.p.z))
        }
        // the selected face 15's mouth: its own surface sample must stay open away from the edges
        var mouthOpen = 0, mouthTot = 0
        for z in stride(from: 30.0, through: 190.0, by: 10) { for x in stride(from: 20.0, through: 180.0, by: 10) {
            let p = SIMD3<Double>(x, 3.68, z)
            guard solidAt(p - SIMD3(0, 1, 0)) else { continue }
            mouthTot += 1; if sample(f, p) < 0 { mouthOpen += 1 }
        } }
        print("PROBE face 15 mouth (interior points): open \(mouthOpen) of \(mouthTot)")
    }
}

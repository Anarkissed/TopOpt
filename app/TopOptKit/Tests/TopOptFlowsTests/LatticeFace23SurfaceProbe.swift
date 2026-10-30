import XCTest
import simd
@testable import TopOptFlows
/// ★ PROBE (2026-09-23 02:50, his image 1): is the drawn pocket SOLID at face 23's surface,
/// and if so which unselected face makes it so.
final class LatticeFace23SurfaceProbe: XCTestCase {
    func testTheRegionFieldJustInsideFace23() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [15, 2, 23], regionIDs: [])
        let key23 = LatticeSelectableRef.face(group: gid, face: 23).key
        let solidGrid = LatticePreviewOccupancy.occupancy(positions: mesh.positions, indices: mesh.indices, bounds: mesh.bounds, maxDim: 128)
        let regions = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include], primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 12,
            selectableDepthMM: [LatticeSelectableRef.face(group: gid, face: 2).key: 13, key23: 20],
            selectableExpandMM: [key23: 4.2],
            facets: { LatticeFaceFacets.facets(face: $0, in: mesh) },
            solidAt: { p in
                let g = (SIMD3<Float>(p) - solidGrid.origin) / solidGrid.spacing
                let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
                guard i >= 0, j >= 0, k >= 0, i < solidGrid.nx, j < solidGrid.ny, k < solidGrid.nz else { return false }
                return solidGrid.values[(k * solidGrid.ny + j) * solidGrid.nx + i] > 0.5
            },
            resolve: { LatticeRegionEmission.planeFor(face: $0, in: mesh) }).regions
        // the app's own numbers: organic, rim 3.41 (one base cell), shape band 10
        var input = LatticeOrganicInput(tensor: [], dims: (1, 1, 1), originMM: SIMD3<Double>(mesh.bounds.min),
                                        spacingMM: 1.7, minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                        separationMinMM: 1.71, separationMaxMM: 3.87, rhoMin: 0.05, rhoMax: 0.9)
        input.solidRimMM = 3.41; input.shapeBandMM = 10
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                    algorithm: "organic", organic: input, maxDim: 128, regions: regions, whenEmpty: .latticeNothing)
        guard let f = scene.regionSDF, let sk = scene.skinInSDF else { return XCTFail("no field") }
        func sample(_ g: LatticeVoxelGrid, _ p: SIMD3<Double>) -> Float {
            let q = (SIMD3<Float>(p) - g.origin) / g.spacing
            let i = Int(q.x.rounded()), j = Int(q.y.rounded()), k = Int(q.z.rounded())
            guard i >= 0, j >= 0, k >= 0, i < g.nx, j < g.ny, k < g.nz else { return .nan }
            return g.values[(k * g.ny + j) * g.nx + i]
        }
        // nearest triangle's face id (any face) to a point
        func nearestFace(_ p: SIMD3<Float>) -> (Int32, Float) {
            var best: (Int32, Float) = (-1, .greatestFiniteMagnitude); var t = 0
            while t + 2 < mesh.indices.count {
                var c = SIMD3<Float>.zero
                for k in 0..<3 { let b = Int(mesh.indices[t + k]) * 3; c += SIMD3<Float>(mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2]) }
                c /= 3; let d = simd_length(c - p)
                if d < best.1 { best = (t / 3 < mesh.faceIDs.count ? mesh.faceIDs[t / 3] : -1, d) }
                t += 3
            }
            return best
        }
        print("PROBE skin \(scene.unselectedSkinMM) rim \(scene.unselectedRimMM)")
        for r in regions where r.faceID == 23 {
            let n = LatticeRegionMask.unit(r.normal); let (bu, bv) = LatticeRegionMask.basis(n)
            var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
            for loop in r.outlineLoops { for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
            for depth in [0.5, 1.5, 3.0] {
                var line = ""
                var v = lo.y + 8; while v <= hi.y - 8 {           // the MIDDLE of the face, 8 mm in from both edges
                    var solid = 0, total = 0, worst: Float = 1e3, wp = SIMD3<Double>.zero, zsum = 0.0
                    var u = lo.x + 8; while u <= hi.x - 8 {
                        let uv = SIMD2(u, v)
                        if LatticeFaceOutline.contains(uv, loops: r.outlineLoops) {
                            let p = r.origin + bu * u + bv * v + n * depth
                            let val = sample(f, p), sIn = sample(sk, p)
                            if val.isFinite { total += 1; zsum += p.z; if val >= 0 { solid += 1; if sIn < worst { worst = sIn; wp = p } } }
                        }
                        u += 2 }
                    if total > 0 {
                        let z = zsum / Double(total)
                        if solid > 0 { let nf = nearestFace(SIMD3<Float>(wp)); line += String(format: " z%.0f:%d/%d(skinIn %.1f, face %d %.1fmm)", z, solid, total, worst, nf.0, nf.1) }
                    }
                    v += 2 }
                print(String(format: "PROBE facet n=(%.2f,%.2f,%.2f) %.1f mm in, middle only — solid rows:%@", n.x, n.y, n.z, depth, line.isEmpty ? " none" : line))
            }
        }
    }
}

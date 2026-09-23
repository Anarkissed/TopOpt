import XCTest
import simd
@testable import TopOptFlows
/// ★ PROBE (2026-09-23 03:00, his image 1): where does face 23's surface sit relative to
/// each facet's prism plane? s < 0 = the surface is OUTSIDE the prism (a solid patch).
final class LatticeFacetPlaneProbe: XCTestCase {
    func testFace23SurfaceAgainstItsFacetPlanes() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let facets = LatticeFaceFacets.facets(face: 23, in: mesh)
        // every vertex of face 23
        var verts: [SIMD3<Double>] = []
        var t = 0
        while t + 2 < mesh.indices.count {
            if t / 3 < mesh.faceIDs.count, mesh.faceIDs[t / 3] == 23 {
                for k in 0..<3 { let b = Int(mesh.indices[t + k]) * 3; verts.append(SIMD3<Double>(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))) }
            }
            t += 3
        }
        for f in facets {
            guard case let .plane(c, n, _, _, loops, _) = f else { continue }
            let nn = LatticeRegionMask.unit(-n)          // the spec's inward normal is −(outward)
            let (bu, bv) = LatticeRegionMask.basis(nn)
            var sMin = 1e9, sMax = -1e9, count = 0, outside = 0
            var zlo = 1e9, zhi = -1e9
            for v in verts {
                let d = v - c
                let uv = SIMD2<Double>(simd_dot(d, bu), simd_dot(d, bv))
                guard LatticeFaceOutline.contains(uv, loops: loops) else { continue }
                let s = simd_dot(d, nn)                   // + = inside the part from the plane
                sMin = min(sMin, s); sMax = max(sMax, s); count += 1; if s < -0.05 { outside += 1 }
                zlo = min(zlo, v.z); zhi = max(zhi, v.z)
            }
            print(String(format: "PROBE facet n=(%.2f,%.2f,%.2f) z %.0f…%.0f: %d surface vertices inside its outline, s from %.2f to %.2f mm, %d OUTSIDE the prism plane", nn.x, nn.y, nn.z, zlo, zhi, count, sMin, sMax, outside))
        }
    }
}

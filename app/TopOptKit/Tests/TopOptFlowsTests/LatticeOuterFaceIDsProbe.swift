import XCTest
import simd
@testable import TopOptFlows
/// ★ PROBE (2026-09-23 02:25, his image 1): which CAD faces make up the leg's OUTER curved
/// surface (the −x side) at several heights — the grey patch is one of them.
final class LatticeOuterFaceIDsProbe: XCTestCase {
    func testOuterSurfaceFaceIDsByHeight() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var byFace: [Int32: (zmin: Float, zmax: Float, tris: Int, nx: Float, xmin: Float, xmax: Float)] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            var c = SIMD3<Float>.zero
            var p: [SIMD3<Float>] = []
            for k in 0..<3 { let b = Int(mesh.indices[t + k]) * 3; let q = SIMD3<Float>(mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2]); p.append(q); c += q }
            c /= 3
            let n = simd_normalize(simd_cross(p[1] - p[0], p[2] - p[0]))
            // the outer surface: x within 25 mm of the part's −x bound and the normal facing −x-ish
            if n.x < -0.5, tri < mesh.faceIDs.count {
                let f = mesh.faceIDs[tri]
                var e = byFace[f] ?? (c.z, c.z, 0, 0, c.x, c.x)
                e.zmin = min(e.zmin, c.z); e.zmax = max(e.zmax, c.z); e.tris += 1; e.nx += n.x
                e.xmin = min(e.xmin, c.x); e.xmax = max(e.xmax, c.x)
                byFace[f] = e
            }
            t += 3
        }
        for (f, e) in byFace.sorted(by: { $0.value.zmin < $1.value.zmin }) where e.tris >= 4 {
            print(String(format: "PROBE −x-facing: face %d spans z %.0f…%.0f mm, x %.0f…%.0f (%d tris, mean nx %.2f)", f, e.zmin, e.zmax, e.xmin, e.xmax, e.tris, e.nx / Float(e.tris)))
        }
    }
}

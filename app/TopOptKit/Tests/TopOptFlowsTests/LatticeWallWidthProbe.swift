import XCTest
import simd
@testable import TopOptFlows

/// ★ WHY A 13 mm WALL DERIVES A 6.5 mm CELL — the width distribution, printed.
///
/// His report, 2026-08-24: single-cell/member gives 12.00 mm on the back wall (its full
/// depth) but only 6.50 mm on the front. Same setting, same bake — so the floor is not
/// what differs; the MEASURED WIDTH is.
final class LatticeWallWidthProbe: XCTestCase {

    func testTheWidthDistributionOfEachWall() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        for (face, depth) in [(FaceID(15), 13.0), (FaceID(2), 12.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: r, role: .include,
                                                        depthMM: depth, faceID: Int(face))
            else { continue }
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        regions: [spec], whenEmpty: .latticeNothing)
            let occ = scene.occupancy
            let n = simd_normalize(spec.normal)
            let h = Double(min(occ.spacing.x, min(occ.spacing.y, occ.spacing.z)))
            let sdf = scene.partSDF
            func solid(_ p: SIMD3<Double>) -> Bool {
                let g = (SIMD3<Float>(p) - sdf.origin) / sdf.spacing
                let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
                guard a >= 0, a < sdf.nx, b >= 0, b < sdf.ny, c >= 0, c < sdf.nz
                else { return false }
                return sdf.values[(c * sdf.ny + b) * sdf.nx + a] < 0
            }
            var seen: [Double] = []
            for k in 0..<occ.nz { for j in 0..<occ.ny { for i in 0..<occ.nx {
                let idx = (k * occ.ny + j) * occ.nx + i
                guard occ.values[idx] > 0.5 else { continue }
                let p = SIMD3<Double>(
                    Double(occ.origin.x) + Double(i) * Double(occ.spacing.x),
                    Double(occ.origin.y) + Double(j) * Double(occ.spacing.y),
                    Double(occ.origin.z) + Double(k) * Double(occ.spacing.z))
                guard LatticeRegionMask.contains(p, region: spec) else { continue }
                var fwd = 0.0, back = 0.0, q = p
                while fwd < 400, solid(q + n * h) { q += n * h; fwd += h }
                q = p
                while back < 400, solid(q - n * h) { q -= n * h; back += h }
                seen.append(fwd + back + h)
            } } }
            guard !seen.isEmpty else { continue }
            seen.sort()
            func pct(_ f: Double) -> Double { seen[Int(f * Double(seen.count - 1))] }
            print(String(format:
                "FACE %d depth %.1f  n=%d  min %.2f  p05 %.2f  p25 %.2f  MEDIAN %.2f  p75 %.2f  max %.2f",
                Int(face), depth, seen.count, seen.first!, pct(0.05), pct(0.25),
                pct(0.5), pct(0.75), seen.last!))
        }
    }
}

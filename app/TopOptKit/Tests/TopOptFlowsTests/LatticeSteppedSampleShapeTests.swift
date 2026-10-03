// LatticeSteppedSampleShapeTests — is the stepped sample ONE object or two?
//
// Maintainer, 2026-08-22, on the build that was supposed to fix exactly this: "there are
// two samples when Stepped is selected. Please remove the default sample."

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeSteppedSampleShapeTests: XCTestCase {

    private func bounds(_ m: ViewerMesh) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var i = 0
        while i + 2 < m.positions.count {
            let p = SIMD3<Float>(m.positions[i], m.positions[i + 1], m.positions[i + 2])
            lo = simd_min(lo, p); hi = simd_max(hi, p); i += 3
        }
        return (lo, hi)
    }

    func testWhatTheSteppedSampleActuallyIs() throws {
        let lat = LatticeType.named("octet")
        for cells in [2, 3, 4, 5] {
            let stepped = LatticeSamplePatch.mesh(
                lattice: lat, cellMM: 8, cells: cells, relativeDensity: 0.3,
                boundary: .none, transition: .stepped)
            let plain = LatticeSamplePatch.mesh(
                lattice: lat, cellMM: 8, cells: cells, relativeDensity: 0.3,
                boundary: .none, transition: .defaultGrade)
            let b = bounds(stepped), p = bounds(plain)
            // Split the stepped mesh at x = 0 and bound each side independently.
            var loL = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hiL = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            var loR = loL, hiR = hiL
            var i = 0
            while i + 2 < stepped.positions.count {
                let q = SIMD3<Float>(stepped.positions[i], stepped.positions[i + 1],
                                     stepped.positions[i + 2])
                if q.x <= 0 { loL = simd_min(loL, q); hiL = simd_max(hiL, q) }
                else { loR = simd_min(loR, q); hiR = simd_max(hiR, q) }
                i += 3
            }
            func f(_ v: SIMD3<Float>) -> String {
                String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
            }
            print("""
            cells \(cells)   plain extent \(f(p.hi - p.lo))   stepped extent \(f(b.hi - b.lo))
                 left  half  \(f(loL)) … \(f(hiL))
                 right half  \(f(loR)) … \(f(hiR))
                 y/z match   \(abs(hiL.y - hiR.y) < 0.01 && abs(hiL.z - hiR.z) < 0.01)
                 gap at seam \(String(format: "%.3f mm", loR.x - hiL.x))
            """)
        }
    }
}

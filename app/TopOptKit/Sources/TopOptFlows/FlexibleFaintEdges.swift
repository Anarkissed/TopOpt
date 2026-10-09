// FlexibleFaintEdges — which side edges a FAINT clearance shell draws (task 2026-09-29-flexible-screens, round 6 review).
// (stub: every boundary vertex, today's look)

import Foundation
import simd
import TopOptKit

enum FlexibleFaintEdges {
    /// The boundary vertices whose side edge (base → floor) a faint shell draws.
    static func sideVertices(_ s: FaceOffsetShell, minTurnDegrees: Double = 20) -> Set<UInt32> {
        var use: [UInt64: Int] = [:], first: [UInt64: UInt32] = [:]
        var k = 0
        while k + 2 < s.indices.count {
            for e in 0..<3 {
                let a = s.indices[k + e], b = s.indices[k + (e + 1) % 3]
                let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
                use[key, default: 0] += 1
                first[key] = a
            }
            k += 3
        }
        return Set(use.filter { $0.value == 1 }.compactMap { first[$0.key] })
    }
}

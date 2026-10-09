// FlexibleFaintEdges — which SIDE edges a FAINT clearance shell draws (task 2026-09-29-flexible-screens, round 6 review).
//
// ★ THE VERIFIER'S FINDING (his img3's faint prism, the Prisms view): MetalMeshView's clearance pass draws a shell's
// side edge (base → floor) at EVERY boundary vertex. A Stamp face's prism stands on its stamp's smooth ½ contour —
// a vertex every few degrees — so at rest, faint, it read as a dense vertical barcode (four fingertips, the 12 mm
// cylinder), and with five prisms the hatching ruled the middle of the part. A FAINT shell (an item with its own
// alphas — FlexibleDepthPrism's at rest and in the Prisms view) now draws its side edge only where its outline TURNS
// by at least `minTurnDegrees`: a rectangle keeps its four corners, a disc none (its base and floor rings and its
// faint walls carry it), a fingertip's cusp its own. The base and floor outlines are unchanged; the dragged prism
// (nil alphas) and every other clearance item keep every side edge (byte-identical — R6-1d's hash).
// The pass reads this rule (hook A2: `let sides = target == 1 ? FlexibleFaintEdges.sideVertices(s) : nil`).

import Foundation
import simd
import TopOptKit

enum FlexibleFaintEdges {

    /// The smallest turn of the outline that stands a side edge.
    static let minTurnDegrees = 20.0

    /// The boundary vertices (each the first vertex of its boundary edge, as the pass walks them) whose side edge a
    /// faint shell draws: where the base outline turns by at least `minTurnDegrees`, and wherever the outline is not a
    /// simple chain (a vertex with other than one edge in and one out).
    static func sideVertices(_ s: FaceOffsetShell, minTurnDegrees: Double = minTurnDegrees) -> Set<UInt32> {
        var use: [UInt64: Int] = [:], dir: [UInt64: (UInt32, UInt32)] = [:]
        var k = 0
        while k + 2 < s.indices.count {
            for e in 0..<3 {
                let a = s.indices[k + e], b = s.indices[k + (e + 1) % 3]
                let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
                use[key, default: 0] += 1
                dir[key] = (a, b)
            }
            k += 3
        }
        var next: [UInt32: [UInt32]] = [:], prev: [UInt32: [UInt32]] = [:]
        for (key, n) in use where n == 1 {
            guard let (a, b) = dir[key] else { continue }
            next[a, default: []].append(b)
            prev[b, default: []].append(a)
        }
        let cosLimit = cos(minTurnDegrees * .pi / 180)
        var out = Set<UInt32>()
        for (v, outs) in next {
            guard outs.count == 1, let ins = prev[v], ins.count == 1 else { out.insert(v); continue }
            let p = SIMD3<Double>(s.base[Int(ins[0])]), c = SIMD3<Double>(s.base[Int(v)]), n = SIMD3<Double>(s.base[Int(outs[0])])
            let d0 = c - p, d1 = n - c
            guard simd_length(d0) > 1e-9, simd_length(d1) > 1e-9 else { out.insert(v); continue }
            if simd_dot(simd_normalize(d0), simd_normalize(d1)) < cosLimit { out.insert(v) }
        }
        return out
    }
}

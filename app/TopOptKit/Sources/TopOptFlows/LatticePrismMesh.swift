import Foundation
import simd

/// ★ A face region's WHOLE PRISM as a closed mesh: its outline polygon (the one outline,
/// `outlinePolygon`) extruded from the face, s = 0, to s = depthMM. The lattice always fills the
/// prism (his 2026-10-11: "the actual lattice depth NEVER changes"), so this is the lattice's
/// footprint — what the lattice-only contact shadow casts. The one piece kept from the withdrawn
/// `LatticeWallSlabMesh` (its whole-prism case), for that one reader.
public enum LatticePrismMesh {
    public static func build(_ r: LatticeRegionSpec) -> ViewerMesh {
        let empty = ViewerMesh(vertices: [], indices: [], faceIDs: [])
        guard r.kind == .face, r.depthMM > 0, !r.outlineLoops.isEmpty else { return empty }
        let n = LatticeRegionMask.unit(r.normal)
        guard simd_length(n) > 0.5 else { return empty }
        let (bu, bv) = LatticeRegionMask.basis(n)
        var v: [Float] = [], idx: [Int32] = []
        func add(_ uv: SIMD2<Double>, _ s: Double) -> Int32 {
            let p = r.origin + bu * uv.x + bv * uv.y + n * s
            v += [Float(p.x), Float(p.y), Float(p.z)]
            return Int32(v.count / 3 - 1)
        }
        for poly in r.outlinePolygon where poly.count >= 3 {
            let top = poly.map { add($0, 0) }, bottom = poly.map { add($0, r.depthMM) }
            for (a, b, c) in LatticeRegionCap.triangulate(poly) {
                idx += [top[a], top[c], top[b], bottom[a], bottom[b], bottom[c]]
            }
            for k in poly.indices {
                let k1 = (k + 1) % poly.count
                idx += [top[k], bottom[k], bottom[k1], top[k], bottom[k1], top[k1]]
            }
        }
        return idx.isEmpty ? empty : ViewerMesh(vertices: v, indices: idx, faceIDs: [Int32](repeating: 1, count: idx.count / 3))
    }
}

import Foundation
import simd

// ★★★ THE OUTLINE IS GEOMETRY, NOT A FIELD. His rule (2026-09-16, 00:19):
//
//   "I'd prefer the outline be a singular beam bent around the entirety of the
//    face-prism outline; something *inherently* smooth — not something with
//    definitive pixel sizes!"
//
// A closed beam of rectangular section — `widthMM` in-plane, the wall deep — swept
// around each include face's outline (the polygon offset in by `inPlaneOffsetMM`),
// built as triangles with position + normal interleaved (the depth-prepass vertex
// layout) and drawn as a mesh in the rim colour by `MetalMeshView`. The lattice's
// struts end inside it (the march clips them half a width in), so it reads as one
// separate frame holding the lattice and joining it to the body. Only when the shape
// grade is on: the bake hands out `solidBandMM` only then.
public enum LatticeOutlineRibbon {
    public struct Mesh: Equatable {
        /// 6 floats per vertex: position xyz, normal xyz — `FlatMesh.interleaved()`'s layout.
        public var interleaved: [Float] = []
        public var vertexCount: Int { interleaved.count / 6 }
        public var triangleCount: Int { vertexCount / 3 }
        public init(interleaved: [Float] = []) { self.interleaved = interleaved }
    }

    /// Per-vertex INWARD offset directions for a loop: the mitred bisector of the two
    /// edge normals, scaled so an offset of `d` along it moves both edges by `d`
    /// (clamped to 2× at sharp corners). Orientation-independent.
    static func inwardMiter(_ loop: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let m = loop.count
        guard m >= 3 else { return [] }
        var area = 0.0
        for i in 0..<m { let a = loop[i], b = loop[(i + 1) % m]; area += a.x * b.y - b.x * a.y }
        let ccw = area > 0
        func edgeInward(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
            let e = b - a
            let l = simd_length(e)
            guard l > 1e-9 else { return .zero }
            let left = SIMD2(-e.y, e.x) / l
            return ccw ? left : -left
        }
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(m)
        for i in 0..<m {
            let n0 = edgeInward(loop[(i + m - 1) % m], loop[i])
            let n1 = edgeInward(loop[i], loop[(i + 1) % m])
            var s = n0 + n1
            let l = simd_length(s)
            if l < 1e-6 {
                s = simd_length(n1) > 0 ? n1 : n0
            } else {
                s /= l
                let cosHalf = Swift.max(simd_dot(s, n1), 0.5)   // miter, clamped to 2×
                s /= cosHalf
            }
            out.append(s)
        }
        return out
    }

    /// `depthAt(regionIndex, point)` answers how deep the beam runs into the part at a
    /// point on the outline (the wall's thickness there); it is clamped to the
    /// region's depth.
    public static func build(regions: [LatticeRegionSpec], widthMM: Double,
                             depthAt: (Int, SIMD3<Double>) -> Double) -> Mesh {
        var mesh = Mesh()
        guard widthMM > 0 else { return mesh }
        var v: [Float] = []
        func emit(_ p: SIMD3<Double>, _ n: SIMD3<Double>) {
            v.append(Float(p.x)); v.append(Float(p.y)); v.append(Float(p.z))
            v.append(Float(n.x)); v.append(Float(n.y)); v.append(Float(n.z))
        }
        func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>,
                  _ na: SIMD3<Double>, _ nb: SIMD3<Double>, _ nc: SIMD3<Double>, _ nd: SIMD3<Double>) {
            emit(a, na); emit(b, nb); emit(c, nc)
            emit(a, na); emit(c, nc); emit(d, nd)
        }
        for (ri, region) in regions.enumerated()
        where region.role == .include && region.kind == .face && !region.outlineLoops.isEmpty {
            let n = LatticeRegionMask.unit(region.normal)
            guard simd_length(n) > 0.5, region.depthMM > 0 else { continue }
            let (bu, bv) = LatticeRegionMask.basis(n)
            func at(_ uv: SIMD2<Double>, _ s: Double) -> SIMD3<Double> {
                region.origin + bu * uv.x + bv * uv.y + n * s
            }
            func dir3(_ d: SIMD2<Double>) -> SIMD3<Double> {
                let w = bu * d.x + bv * d.y
                let l = simd_length(w)
                return l > 1e-9 ? w / l : bu
            }
            for loop in region.outlineLoops {
                let m = loop.count
                guard m >= 3 else { continue }
                let miter = inwardMiter(loop)
                let outer = (0..<m).map { loop[$0] + miter[$0] * region.inPlaneOffsetMM }
                let inner = (0..<m).map { loop[$0] + miter[$0] * (region.inPlaneOffsetMM + widthMM) }
                let depth = (0..<m).map { i -> Double in
                    let mid = at(loop[i] + miter[i] * (region.inPlaneOffsetMM + 0.5 * widthMM), 1.0)
                    return Swift.max(0.5, Swift.min(region.depthMM, depthAt(ri, mid)))
                }
                for i in 0..<m {
                    let j = (i + 1) % m
                    let oi0 = at(outer[i], 0), oj0 = at(outer[j], 0)
                    let oi1 = at(outer[i], depth[i]), oj1 = at(outer[j], depth[j])
                    let ii0 = at(inner[i], 0), ij0 = at(inner[j], 0)
                    let ii1 = at(inner[i], depth[i]), ij1 = at(inner[j], depth[j])
                    // Smooth per-vertex normals along the sweep: the outer wall faces out
                    // of the prism, the inner wall faces the lattice.
                    let outI = -dir3(miter[i]), outJ = -dir3(miter[j])
                    quad(oi0, oj0, oj1, oi1, outI, outJ, outJ, outI)
                    quad(ii0, ii1, ij1, ij0, -outI, -outI, -outJ, -outJ)
                    // The face cap (the declared face looks along −n) and the far cap.
                    quad(oi0, ii0, ij0, oj0, -n, -n, -n, -n)
                    quad(oi1, oj1, ij1, ii1, n, n, n, n)
                }
            }
        }
        mesh.interleaved = v
        return mesh
    }
}

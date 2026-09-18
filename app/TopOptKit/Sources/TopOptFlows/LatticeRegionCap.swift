import Foundation
import simd

/// ★★ THE SOLID BEYOND A FACE PRISM'S FAR CAP (his 2026-09-18: "Since the face-prism
/// didn't go all the way through a model, the model should always be assumed to be
/// 100% solid. So the area beneath the floor should have a wall there and in the
/// middle"). A face region is latticed only as deep as it was declared; where the part
/// continues past that depth the material there is solid, and the preview used to show
/// NOTHING at the cap — a hole into the base through the open face. This is the cap:
/// each outline loop triangulated at the region's depth, facing back toward the open
/// face. The fragment shader draws it only where the part actually continues past the
/// cap (`region_cap_fragment` samples the part SDF a voxel and a half beyond), so a
/// prism that spans a whole wall draws no cap and the wall stays see-through.
public enum LatticeRegionCap {
    /// Ear-clipping triangulation of one simple loop (any orientation). Returns index
    /// triples into `loop`. Degenerate or self-crossing loops fall back to a fan.
    static func triangulate(_ loop: [SIMD2<Double>]) -> [(Int, Int, Int)] {
        let m = loop.count
        guard m >= 3 else { return [] }
        var area = 0.0
        for i in 0..<m { let a = loop[i], b = loop[(i + 1) % m]; area += a.x * b.y - b.x * a.y }
        let ccw = area >= 0
        var idx = Array(0..<m)
        var out: [(Int, Int, Int)] = []
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func inside(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
            let s = ccw ? 1.0 : -1.0
            return cross(a, b, p) * s >= -1e-12 && cross(b, c, p) * s >= -1e-12 && cross(c, a, p) * s >= -1e-12
        }
        var guardCount = 0
        while idx.count > 3 && guardCount < 4 * m {
            guardCount += 1
            var clipped = false
            for k in 0..<idx.count {
                let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = loop[i0], b = loop[i1], c = loop[i2]
                let convex = ccw ? cross(a, b, c) > 1e-12 : cross(a, b, c) < -1e-12
                guard convex else { continue }
                var empty = true
                for j in idx where j != i0 && j != i1 && j != i2 {
                    if inside(loop[j], a, b, c) { empty = false; break }
                }
                guard empty else { continue }
                out.append((i0, i1, i2))
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if idx.count == 3 { out.append((idx[0], idx[1], idx[2])) }
        else if idx.count > 3 {           // could not clip: a fan, better than nothing
            for k in 1..<(idx.count - 1) { out.append((idx[0], idx[k], idx[k + 1])) }
        }
        return out
    }

    /// The caps of every include face region, as a flat mesh (6 floats per vertex:
    /// position, normal = −inward, the same layout as the outline ribbon).
    public static func build(regions: [LatticeRegionSpec]) -> LatticeOutlineRibbon.Mesh {
        var v: [Float] = []
        func emit(_ p: SIMD3<Double>, _ n: SIMD3<Double>) {
            v.append(Float(p.x)); v.append(Float(p.y)); v.append(Float(p.z))
            v.append(Float(n.x)); v.append(Float(n.y)); v.append(Float(n.z))
        }
        for region in regions where region.role == .include && region.kind == .face && !region.outlineLoops.isEmpty {
            let n = LatticeRegionMask.unit(region.normal)
            guard simd_length(n) > 0.5, region.depthMM > 0 else { continue }
            let (bu, bv) = LatticeRegionMask.basis(n)
            let cap = region.depthMM
            for loop in region.outlineLoops where loop.count >= 3 {
                let ring = LatticeOutlineRibbon.offsetRing(loop, by: region.inPlaneOffsetMM)
                guard ring.count >= 3 else { continue }
                for (a, b, c) in triangulate(ring) {
                    for uv in [ring[a], ring[b], ring[c]] {
                        emit(region.origin + bu * uv.x + bv * uv.y + n * cap, -n)
                    }
                }
            }
        }
        return LatticeOutlineRibbon.Mesh(interleaved: v)
    }
}

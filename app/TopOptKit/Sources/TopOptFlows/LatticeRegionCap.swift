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
    /// The wall's colour: the body's own grey, so the cap reads as the part it is.
    public static let wallTint = SIMD4<Float>(0.58, 0.60, 0.64, 1)
    /// Ear-clipping triangulation of one simple loop (any orientation). Returns index
    /// triples into `loop`. ★ ROBUST TO A CAD OUTLINE: near-collinear vertices are
    /// dropped as degenerate ears, the inside test is strict with a tolerance scaled to
    /// the loop, and only REFLEX vertices can block an ear (a convex vertex never lies
    /// inside another ear). A first cut used an inclusive test and fell back to a fan on
    /// his 75-vertex outline — every cap triangle landed outside the part (2026-09-18).
    static func triangulate(_ loop: [SIMD2<Double>]) -> [(Int, Int, Int)] {
        let m = loop.count
        guard m >= 3 else { return [] }
        var lo = loop[0], hi = loop[0]
        for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let scale = Swift.max(hi.x - lo.x, hi.y - lo.y, 1e-9)
        let eps = 1e-9 * scale * scale
        var area = 0.0
        for i in 0..<m { let a = loop[i], b = loop[(i + 1) % m]; area += a.x * b.y - b.x * a.y }
        var idx = Array(0..<m)
        if area < 0 { idx.reverse() }                         // work counter-clockwise
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        // INCLUSIVE: a vertex ON the ear's diagonal blocks it too (the L's notch corner
        // sits exactly on the diagonal (0,20)–(20,0); a strict test let that ear through
        // and the triangle covered the notch). Collinear boundary vertices are removed
        // before this can see them, so "on an edge" here means the diagonal.
        func blocks(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
            cross(a, b, p) >= -eps && cross(b, c, p) >= -eps && cross(c, a, p) >= -eps
        }
        var out: [(Int, Int, Int)] = []
        var stall = 0
        while idx.count > 3 && stall <= idx.count {
            var clipped = false
            var k = 0
            while k < idx.count {
                let n = idx.count
                let i0 = idx[(k + n - 1) % n], i1 = idx[k], i2 = idx[(k + 1) % n]
                let a = loop[i0], b = loop[i1], c = loop[i2]
                let cr = cross(a, b, c)
                if abs(cr) <= eps {                           // collinear: a degenerate ear
                    idx.remove(at: k); clipped = true; break
                }
                if cr < 0 { k += 1; continue }                // reflex: not an ear
                var empty = true
                for (jj, j) in idx.enumerated() where j != i0 && j != i1 && j != i2 {
                    let q = loop[j]
                    // only a reflex vertex can lie inside a convex ear
                    let jp = loop[idx[(jj + idx.count - 1) % idx.count]], jn = loop[idx[(jj + 1) % idx.count]]
                    if cross(jp, q, jn) > eps { continue }
                    if simd_length(q - a) < 1e-9 || simd_length(q - b) < 1e-9 || simd_length(q - c) < 1e-9 { continue }
                    if blocks(q, a, b, c) { empty = false; break }
                }
                guard empty else { k += 1; continue }
                out.append((i0, i1, i2))
                idx.remove(at: k); clipped = true; break
            }
            if clipped { stall = 0; continue }
            // no ear found: shed the flattest vertex and carry on
            stall += 1
            var flattest = 0; var best = Double.greatestFiniteMagnitude
            for k in 0..<idx.count {
                let n = idx.count
                let cr = abs(cross(loop[idx[(k + n - 1) % n]], loop[idx[k]], loop[idx[(k + 1) % n]]))
                if cr < best { best = cr; flattest = k }
            }
            idx.remove(at: flattest)
        }
        if idx.count == 3 { out.append((idx[0], idx[1], idx[2])) }
        return out
    }

    /// The caps of every include face region, as a flat mesh (6 floats per vertex:
    /// position, normal = −inward, the same layout as the outline ribbon).
    /// `endsInsideMaterial(regionIndex, worldPoint)` says whether the prism's declared end
    /// at that point sits INSIDE the part with material beyond it. Nil ⇒ assume it does.
    /// ★ THE PRISM THAT GOES THROUGH THE WHOLE WALL GETS NO CAP (his 2026-09-21 03:25,
    /// image 1: "The face-prism go through entire wall; therefore there should be NO
    /// WALL"). His 12.03 mm wall with a 12.0 mm prism drew a plate at 12.0 — the wall's
    /// own inner face — because the fragment's "is the part 1.5 voxels past the cap"
    /// test read the surface voxel as solid. The CPU knows the wall's measured width at
    /// every vertex; a triangle whose three corners all lie within a voxel of the far
    /// surface is simply not built.
    public static func build(regions: [LatticeRegionSpec],
                             endsInsideMaterial: ((Int, SIMD3<Double>) -> Bool)? = nil) -> LatticeOutlineRibbon.Mesh {
        var v: [Float] = []
        func emit(_ p: SIMD3<Double>, _ n: SIMD3<Double>) {
            v.append(Float(p.x)); v.append(Float(p.y)); v.append(Float(p.z))
            v.append(Float(n.x)); v.append(Float(n.y)); v.append(Float(n.z))
        }
        for (ri, region) in regions.enumerated() where region.role == .include && region.kind == .face && !region.outlineLoops.isEmpty {
            let n = LatticeRegionMask.unit(region.normal)
            guard simd_length(n) > 0.5, region.depthMM > 0 else { continue }
            let (bu, bv) = LatticeRegionMask.basis(n)
            // ★ THE CAP IS THE PRISM'S DECLARED END, NEVER THE SLAB'S (his 2026-09-21
            // 02:55: "No walls should EVER get created. It is meant only for where and how
            // much lattice there is along the depth of the face-prism"). The slab's start
            // and end draw nothing; the one plate stays where the prism ends inside
            // material, as he asked on 09-19.
            let cap = region.depthMM
            for (li, loop) in region.outlineLoops.enumerated() where loop.count >= 3 {
                let ring = LatticeOutlineRibbon.offsetRing(loop, by: -region.inPlaneOffsetMM,
                                                           seams: li < region.outlineSeams.count ? region.outlineSeams[li] : [])
                guard ring.count >= 3 else { continue }
                for (a, b, c) in triangulate(ring) {
                    let corners = [ring[a], ring[b], ring[c]].map { region.origin + bu * $0.x + bv * $0.y + n * cap }
                    // ★ ALL THREE CORNERS (review 2026-09-22 #22): "any corner" drew a
                    // whole triangle for one measured corner, and on a fanned outline
                    // that one corner reached across the open face — a plate over air.
                    if let test = endsInsideMaterial, !corners.allSatisfy({ test(ri, $0) }) { continue }
                    // ★ AND NEVER INSIDE ANOTHER LATTICED PRISM (the pocket rule + the seam
                    // rule): where a second prism continues past this one's end, the end
                    // is lattice, not a wall.
                    let other = regions.enumerated().contains { (oi, o) in
                        oi != ri && o.role == .include && corners.contains { q in
                            LatticeRegionMask.containsWholePrism(q - n * 0.01, region: o) }
                    }
                    if other { continue }
                    for p in corners { emit(p, -n) }
                }
            }
        }
        return LatticeOutlineRibbon.Mesh(interleaved: v)
    }
}

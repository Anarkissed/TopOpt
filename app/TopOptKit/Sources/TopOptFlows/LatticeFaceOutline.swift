// LatticeFaceOutline — ★ A FACE'S REAL OUTLINE, NOT ITS BOUNDING BOX
// (maintainer, 2026-08-18: "the negative expansion created an area *above* and
// *around* the entire latticed face … This is not reflected when the lattice
// preview is turned on", and "I am still seeing artifacts on the model face -
// this leads me to believe the lattice still exists *behind* the model face").
//
// ★★ THE TWO REPORTS ARE ONE DEFECT, AND IT IS THE REGION'S SHAPE.
//
// A face region has always been emitted as an axis-aligned SLAB: `origin`,
// `normal`, `halfU`, `halfW`, `depth`, built from `ViewerMesh.facePlaneOutline`,
// which is `PlaneOutline.fit` — a BOUNDING-BOX fit over the face's vertices. For a
// rectangular face that is exact. For a face with anything cut out of it, it is
// the bounding box of the hole as well.
//
// Measured on his own part, share of the emitted rectangle that is actually the
// face:
//
//     face 15 ....  17,099.6 mm² of 41,548.5 mm²  =  41.2%
//     face  2 ....  12,381.2 mm² of 41,548.5 mm²  =  29.8%
//     faces 18/20/24 (true rectangles) .........  100.0%
//
// So on his two lattice walls 59% and 70% of the declared region is NOT the face.
// Struts land in the solid material around the scoop — inside the shell, behind
// the face — which is the artifact he photographed. And the PURPLE PRIMITIVE he
// compares it against is `FaceOffsetShell`, which follows the face's real
// outline: the two were never the same shape, so a negative expand shrank both
// and still did not make them agree.
//
// ★ THIS FILE IS THE OUTLINE ITSELF. The boundary of a face's own triangles —
// edges used by exactly one of them — chained into loops and projected into the
// face plane's (u, v) basis. `LatticeRegionMask.basis` supplies that basis, so
// the polygon is measured on the same two axes the slab's half-extents always
// were, and a rectangular face still produces exactly its rectangle.

import Foundation
import simd

public enum LatticeFaceOutline {

    /// A closed loop in the face plane's (u, v) millimetres, relative to the
    /// plane origin. Counter-clockwise-ness is NOT normalised: the containment
    /// test below is a crossing count, which does not care.
    public typealias Loop = [SIMD2<Double>]

    /// Quantised endpoint key, so two triangles that share an edge agree it is
    /// shared. The tessellator emits identical Float bit patterns for a shared
    /// vertex, but a 1e-4 mm grid costs nothing and survives a rebuild.
    private struct Key: Hashable {
        let x: Int64, y: Int64, z: Int64
        init(_ p: SIMD3<Double>) {
            x = Int64((p.x * 1e4).rounded())
            y = Int64((p.y * 1e4).rounded())
            z = Int64((p.z * 1e4).rounded())
        }
    }

    private struct EdgeK: Hashable {
        let a: Key, b: Key
        init(_ p: SIMD3<Double>, _ q: SIMD3<Double>) {
            let ka = Key(p), kb = Key(q)
            // Undirected: the same two endpoints hash the same either way round.
            if (ka.x, ka.y, ka.z) <= (kb.x, kb.y, kb.z) { a = ka; b = kb }
            else { a = kb; b = ka }
        }
    }

    /// The face's boundary loops, in the plane's (u, v) mm relative to `origin`.
    ///
    /// Returns `[]` when the face contributes no triangles, or when its boundary
    /// does not close — a caller that gets nothing must fall back to the slab
    /// rather than latticing an empty region.
    public static func loops(face: FaceID, in mesh: ViewerMesh,
                             normal: SIMD3<Double>, origin: SIMD3<Double>) -> [Loop] {
        let n = simd_length(normal) > 1e-9 ? simd_normalize(normal) : SIMD3<Double>(0, 0, 1)
        let (u, v) = LatticeRegionMask.basis(n)
        let want = Int32(face)

        func vertex(_ i: UInt32) -> SIMD3<Double>? {
            let b = Int(i) * 3
            guard b + 2 < mesh.positions.count else { return nil }
            return SIMD3<Double>(Double(mesh.positions[b]),
                                 Double(mesh.positions[b + 1]),
                                 Double(mesh.positions[b + 2]))
        }

        // Boundary edges: used by exactly ONE of this face's triangles. The same
        // rule `SurfaceCutLines.alignmentDegrees` uses to find a face's own rim.
        var count: [EdgeK: Int] = [:]
        var ends: [EdgeK: (SIMD3<Double>, SIMD3<Double>)] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            if tri < mesh.faceIDs.count, mesh.faceIDs[tri] == want,
               let p0 = vertex(mesh.indices[t]),
               let p1 = vertex(mesh.indices[t + 1]),
               let p2 = vertex(mesh.indices[t + 2]) {
                let p = [p0, p1, p2]
                for e in 0..<3 {
                    let a = p[e], b = p[(e + 1) % 3]
                    let k = EdgeK(a, b)
                    count[k, default: 0] += 1
                    ends[k] = (a, b)
                }
            }
            t += 3
        }
        let border = count.filter { $0.value == 1 }.keys
        guard !border.isEmpty else { return [] }

        // Chain them: each boundary vertex has exactly two boundary edges on a
        // manifold patch, so walking from any unused edge closes a loop.
        var adjacency: [Key: [EdgeK]] = [:]
        for k in border {
            guard let e = ends[k] else { continue }
            adjacency[Key(e.0), default: []].append(k)
            adjacency[Key(e.1), default: []].append(k)
        }
        var unused = Set(border)
        var out: [Loop] = []
        while let seed = unused.first {
            guard let e0 = ends[seed] else { unused.remove(seed); continue }
            unused.remove(seed)
            var loop3: [SIMD3<Double>] = [e0.0, e0.1]
            var here = Key(e0.1)
            let start = Key(e0.0)
            var guardCount = 0
            while here != start, guardCount < border.count + 2 {
                guardCount += 1
                guard let next = adjacency[here]?.first(where: { unused.contains($0) }),
                      let ne = ends[next] else { break }
                unused.remove(next)
                let ka = Key(ne.0)
                let step = (ka == here) ? ne.1 : ne.0
                loop3.append(step)
                here = Key(step)
            }
            guard loop3.count >= 3 else { continue }
            // Drop the duplicated closing point if the walk came all the way back.
            if Key(loop3[loop3.count - 1]) == start { loop3.removeLast() }
            let flat: Loop = loop3.map { p in
                let d = p - origin
                return SIMD2<Double>(simd_dot(d, u), simd_dot(d, v))
            }
            if flat.count >= 3 { out.append(flat) }
        }
        return out
    }

    // MARK: - containment + distance, in the plane

    /// Crossing-count containment against a set of loops. An odd number of
    /// crossings is inside — which handles a face with a HOLE for free, because
    /// the hole is its own loop and points inside it cross twice.
    public static func contains(_ p: SIMD2<Double>, loops: [Loop]) -> Bool {
        var inside = false
        for loop in loops {
            var j = loop.count - 1
            for i in 0..<loop.count {
                let a = loop[i], b = loop[j]
                if (a.y > p.y) != (b.y > p.y) {
                    let dy = b.y - a.y
                    if abs(dy) > 1e-12 {
                        let x = a.x + (p.y - a.y) / dy * (b.x - a.x)
                        if p.x < x { inside.toggle() }
                    }
                }
                j = i
            }
        }
        return inside
    }

    /// Signed distance (mm) to the loops in plane — negative inside. Used to bake
    /// the region field the preview and the shell clip both read, so the cut is a
    /// true distance and a sphere-trace step stays safe.
    public static func signedDistance(_ p: SIMD2<Double>, loops: [Loop]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for loop in loops {
            var j = loop.count - 1
            for i in 0..<loop.count {
                let a = loop[i], b = loop[j]
                let ab = b - a
                let l2 = simd_dot(ab, ab)
                let t = l2 > 1e-12 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
                best = min(best, simd_length(p - (a + ab * t)))
                j = i
            }
        }
        if best == .greatestFiniteMagnitude { return .greatestFiniteMagnitude }
        return contains(p, loops: loops) ? -best : best
    }

    /// The loops' own bounding half-extents — so a caller can keep emitting the
    /// slab's `halfU`/`halfW` (core still reads them) from the SAME outline the
    /// mask is built from, rather than from a second fit.
    public static func halfExtents(_ loops: [Loop]) -> (halfU: Double, halfW: Double)? {
        var lo = SIMD2<Double>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = SIMD2<Double>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var any = false
        for loop in loops { for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q); any = true } }
        guard any else { return nil }
        return (max(0, (hi.x - lo.x) * 0.5), max(0, (hi.y - lo.y) * 0.5))
    }
}

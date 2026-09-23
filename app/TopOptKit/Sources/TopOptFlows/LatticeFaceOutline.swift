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
        loopsWithNeighbours(face: face, in: mesh, normal: normal, origin: origin).map { $0.loop }
    }
    public static func loopsWithNeighbours(face: FaceID, in mesh: ViewerMesh,
                                           normal: SIMD3<Double>, origin: SIMD3<Double>) -> [(loop: Loop, neighbours: [FaceID?])] {
        let want = Int32(face)
        return loopsWithNeighbours(triangles: { tri in tri < mesh.faceIDs.count && mesh.faceIDs[tri] == want },
                                   in: mesh, normal: normal, origin: origin)
    }
    /// The same, over any subset of the mesh's triangles (`triangles(tri)` says which) — a
    /// curved face's facets (`LatticeFaceFacets`) are outlined this way.
    public static func loops(triangles belongs: (Int) -> Bool, in mesh: ViewerMesh,
                             normal: SIMD3<Double>, origin: SIMD3<Double>) -> [Loop] {
        loopsWithNeighbours(triangles: belongs, in: mesh, normal: normal, origin: origin).map { $0.loop }
    }

    /// ★ The mesh's edge → faces map, built once per mesh (the emission runs often).
    private static var adjacencyLock = NSLock()
    private static var adjacencyKey: (Int, UInt64, UInt64)? = nil
    private static var adjacency: [EdgeK: [Int32]] = [:]
    private static func edgeFaces(in mesh: ViewerMesh) -> [EdgeK: [Int32]] {
        adjacencyLock.lock(); defer { adjacencyLock.unlock() }
        let key = (mesh.indices.count, mesh.signature.contentHash, mesh.signature.topologyHash)
        if let k = adjacencyKey, k == key { return adjacency }
        var map: [EdgeK: [Int32]] = [:]
        var t = 0
        func vertex(_ i: UInt32) -> SIMD3<Double>? {
            let b = Int(i) * 3
            guard b + 2 < mesh.positions.count else { return nil }
            return SIMD3<Double>(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
        }
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            let f: Int32 = tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1
            if let p0 = vertex(mesh.indices[t]), let p1 = vertex(mesh.indices[t + 1]), let p2 = vertex(mesh.indices[t + 2]) {
                let p = [p0, p1, p2]
                for e in 0..<3 { map[EdgeK(p[e], p[(e + 1) % 3]), default: []].append(f) }
            }
            t += 3
        }
        adjacencyKey = key; adjacency = map
        return map
    }

    /// The loops AND, per edge (loop[i] → loop[i+1]), the face across it — nil at a free
    /// edge or where the neighbour is one of this very subset.
    public static func loopsWithNeighbours(triangles belongs: (Int) -> Bool, in mesh: ViewerMesh,
                                           normal: SIMD3<Double>, origin: SIMD3<Double>) -> [(loop: Loop, neighbours: [FaceID?])] {
        let n = simd_length(normal) > 1e-9 ? simd_normalize(normal) : SIMD3<Double>(0, 0, 1)
        let (u, v) = LatticeRegionMask.basis(n)

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
        var ownFace: [EdgeK: Int32] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            if belongs(tri),
               let p0 = vertex(mesh.indices[t]),
               let p1 = vertex(mesh.indices[t + 1]),
               let p2 = vertex(mesh.indices[t + 2]) {
                let p = [p0, p1, p2]
                for e in 0..<3 {
                    let a = p[e], b = p[(e + 1) % 3]
                    let k = EdgeK(a, b)
                    count[k, default: 0] += 1
                    ends[k] = (a, b)
                    ownFace[k] = tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1
                }
            }
            t += 3
        }
        let border = count.filter { $0.value == 1 }.keys
        guard !border.isEmpty else { return [] }
        // the face across each boundary edge: the mesh's other triangle on that edge
        let all = edgeFaces(in: mesh)
        func across(_ k: EdgeK) -> FaceID? {
            guard let fs = all[k], fs.count >= 2 else { return nil }
            let own = ownFace[k] ?? -1
            // the other triangle's face; a seam inside one face reads the face itself
            if let other = fs.first(where: { $0 != own }) { return other }
            return fs.count >= 2 ? own : nil
        }

        // Chain them: each boundary vertex has exactly two boundary edges on a
        // manifold patch, so walking from any unused edge closes a loop.
        var adjacency: [Key: [EdgeK]] = [:]
        for k in border {
            guard let e = ends[k] else { continue }
            adjacency[Key(e.0), default: []].append(k)
            adjacency[Key(e.1), default: []].append(k)
        }
        var unused = Set(border)
        var out: [(loop: Loop, neighbours: [FaceID?])] = []
        while let seed = unused.first {
            guard let e0 = ends[seed] else { unused.remove(seed); continue }
            unused.remove(seed)
            var loop3: [SIMD3<Double>] = [e0.0, e0.1]
            var edgeKeys: [EdgeK] = [seed]
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
                edgeKeys.append(next)
                here = Key(step)
            }
            guard loop3.count >= 3 else { continue }
            // Drop the duplicated closing point if the walk came all the way back.
            if Key(loop3[loop3.count - 1]) == start { loop3.removeLast() }
            let flat: Loop = loop3.map { p in
                let d = p - origin
                return SIMD2<Double>(simd_dot(d, u), simd_dot(d, v))
            }
            // edge i is loop[i] → loop[i+1]; the walk appended one key per step in order
            var nb: [FaceID?] = (0..<flat.count).map { i in i < edgeKeys.count ? across(edgeKeys[i]) : nil }
            if nb.count < flat.count { nb += [FaceID?](repeating: nil, count: flat.count - nb.count) }
            if flat.count >= 3 { out.append((flat, nb)) }
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
    /// ★ SEAMS (his 2026-09-22 01:58, images 2–5: rims and walls where two lattice
    /// prisms meet). `seams[l][i]` marks the edge loop[l][i] → loop[l][i+1] as a SEAM —
    /// an edge shared with another latticed prism (the next facet of a curved wall, or a
    /// neighbouring latticed face). A seam is not an outline: no rim, no band, no offset
    /// there. The SIGN still comes from the whole loop (inside is inside); the DISTANCE
    /// is measured to the true outline edges only. All edges seams ⇒ far from any rim.
    public static func signedDistance(_ p: SIMD2<Double>, loops: [Loop], seams: [[Bool]] = []) -> Double {
        var best = Double.greatestFiniteMagnitude
        for (l, loop) in loops.enumerated() {
            let sm = l < seams.count ? seams[l] : []
            var j = loop.count - 1
            for i in 0..<loop.count {
                // the edge from j to i is edge index j
                if j < sm.count, sm[j] { j = i; continue }
                let a = loop[i], b = loop[j]
                let ab = b - a
                let l2 = simd_dot(ab, ab)
                let t = l2 > 1e-12 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
                best = min(best, simd_length(p - (a + ab * t)))
                j = i
            }
        }
        if best == .greatestFiniteMagnitude {
            guard !loops.isEmpty, !seams.isEmpty else { return .greatestFiniteMagnitude }
            return contains(p, loops: loops) ? -1e6 : 1e6
        }
        return contains(p, loops: loops) ? -best : best
    }

    /// The loops' own bounding half-extents — so a caller can keep emitting the
    /// slab's `halfU`/`halfW` (core still reads them) from the SAME outline the
    /// mask is built from, rather than from a second fit.
    /// ★ INSIDE, WITH THE SEAMS FLARED (2026-09-22): a point outside the polygon still
    /// belongs to the prism when it lies beyond a seam edge by no more than depth × tilt
    /// (the bisector plane with the neighbouring prism); a point inside the polygon leaves
    /// it when a converging seam's bisector has cut it off. `s` is the depth along the normal.
    public static func insideWithFlare(_ p: SIMD2<Double>, loops: [Loop], seams: [[Bool]],
                                       tilts: [[Double]], caps: [[Double]] = [], depth s: Double) -> Bool {
        var inside = contains(p, loops: loops)
        guard s > 0, !tilts.isEmpty else { return inside }
        for (l, loop) in loops.enumerated() {
            let sm = l < seams.count ? seams[l] : []
            let tl = l < tilts.count ? tilts[l] : []
            let cl = l < caps.count ? caps[l] : []
            let m = loop.count
            guard m >= 3 else { continue }
            // the polygon's winding decides which side of an edge is outside
            var area = 0.0
            for i in 0..<m { let a = loop[i], b = loop[(i + 1) % m]; area += a.x * b.y - b.x * a.y }
            let ccw = area > 0
            for i in 0..<m where i < sm.count && sm[i] && i < tl.count && abs(tl[i]) > 1e-9 {
                let a = loop[i], b = loop[(i + 1) % m]
                let d = b - a, l2 = simd_dot(d, d)
                guard l2 > 1e-12 else { continue }
                let t = simd_dot(p - a, d) / l2
                guard t >= -1e-6, t <= 1 + 1e-6 else { continue }
                // outward normal of this edge: right of the direction for CCW, left for CW
                let nOut = ccw ? SIMD2(d.y, -d.x) / sqrt(l2) : SIMD2(-d.y, d.x) / sqrt(l2)
                let out = simd_dot(p - a, nOut)          // > 0 outside this edge
                // ★ only as deep as the neighbour's prism (2026-09-22 15:30): a 20 mm prism
                // cut by a 12 mm neighbour's bisector past 12 mm lost a strip nobody owned
                let cap = i < cl.count ? cl[i] : 0
                let flare = (cap > 0 ? Swift.min(s, cap) : s) * tl[i]
                if flare > 0, !inside, out >= 0, out <= flare { inside = true }
                // ★★★ NO CONVERGING CUT (his 2026-09-23 00:27, the wall "SHAPED the same
                // shape as the overlap"): where two prisms OVERLAP each used to yield to
                // its neighbour up to the bisector — but the two seam edges do not meet on
                // the corner line (a fillet sits between the faces), so each cut started a
                // couple of millimetres short of the true corner, BOTH prisms yielded along
                // the diagonal, and a strip belonging to neither ran down every corner as
                // a solid wall. Overlapping prisms never lose material: the union is the
                // pocket. Ownership inside an overlap is first-match, as core's is.
            }
        }
        return inside
    }

    /// ★ THE SIGN ACROSS A SEAM, for in-plane readers with no depth (the octree's outline
    /// raster): a point outside the polygon whose NEAREST edge is a seam is not outside the
    /// lattice — the next prism continues there — so it reads as inside, at the distance to
    /// the nearest true outline edge.
    public static func signedDistanceAcrossSeams(_ p: SIMD2<Double>, loops: [Loop], seams: [[Bool]]) -> Double {
        let sd = signedDistance(p, loops: loops, seams: seams)
        guard sd > 0, !seams.isEmpty else { return sd }
        var nearest = Double.greatestFiniteMagnitude, nearestIsSeam = false
        for (l, loop) in loops.enumerated() {
            let sm = l < seams.count ? seams[l] : []
            let m = loop.count
            for i in 0..<m {
                let a = loop[i], b = loop[(i + 1) % m]
                let d = b - a, l2 = simd_dot(d, d)
                let t = l2 > 1e-12 ? max(0, min(1, simd_dot(p - a, d) / l2)) : 0
                let dist = simd_length(p - (a + d * t))
                if dist < nearest { nearest = dist; nearestIsSeam = i < sm.count && sm[i] }
            }
        }
        return nearestIsSeam ? -sd : sd
    }

    public static func halfExtents(_ loops: [Loop]) -> (halfU: Double, halfW: Double)? {
        var lo = SIMD2<Double>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = SIMD2<Double>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var any = false
        for loop in loops { for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q); any = true } }
        guard any else { return nil }
        return (max(0, (hi.x - lo.x) * 0.5), max(0, (hi.y - lo.y) * 0.5))
    }
}

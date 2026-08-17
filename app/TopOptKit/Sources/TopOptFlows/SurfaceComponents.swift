// SurfaceComponents.swift — ★ A CUT THAT DETACHES A SCRAP MAKES IT ITS OWN PIECE.
//
// Maintainer, 2026-08-16:
//
//   "If a cut leaves a small piece alone, it should be its own part. So if I cut an
//    irregular shape in half, and part of it crosses an arc, the end of that arc,
//    even if it's a tiny piece, should be its *own* face."
//
// ── WHY A CUT DOES NOT ALREADY DO THIS ───────────────────────────────────────
//
// `splitManual` makes exactly two children, one per side of the plane. That is the
// right answer for the PLANE — but not for the SURFACE. Slice an L, a C or an arc
// off-centre and one side of the plane holds two patches of surface with nothing
// joining them: the body of the face, and a scrap round the far end. They share a
// region, so they share a role, a depth, a lattice choice and a row in Selections,
// and there is no way to give the scrap its own. To the user that is one piece
// that is visibly two.
//
// ── WHAT MAKES IT EXPRESSIBLE ────────────────────────────────────────────────
//
// A region is `faces ∩ (intersection of half-spaces)`, and "the connected patch
// containing this triangle" is not a half-space. But it does not have to be: two
// patches that are disconnected ON THE SURFACE are usually also APART IN SPACE, and
// when they are, a plane between them separates them exactly. So each component
// keeps its parent's cuts and gains one separating plane per sibling.
//
// ★ AND WHERE NO SUCH PLANE EXISTS, NOTHING IS SPLIT. A C-shaped scrap curling back
// around the body has no separating plane, and manufacturing one that ALMOST works
// would produce regions that quietly claim each other's surface — the same class of
// defect as the pattern tool's old lateral box, which overlapped its neighbours by
// a quarter of their length. So every candidate split is VERIFIED against the
// triangles it is supposed to contain before it is offered, and a split that does
// not separate cleanly is not made at all.
//
// Pure geometry on value types — no view, no GPU.

import Foundation
import simd
import TopOptKit

public enum SurfaceComponents {

    /// More patches than this and something is wrong with the mesh rather than
    /// with the cut — a tessellation with unwelded seams can shatter into hundreds.
    /// Splitting into that many rows would be worse than not splitting at all.
    public static let maxComponents = 16

    /// ★ THE CONNECTED PATCHES OF A REGION'S SURFACE, as lists of triangle indices.
    ///
    /// A triangle is IN the region when its centroid satisfies every half-space —
    /// the same test a voxel centre gets, so what is drawn, what is tapped and what
    /// the run tags cannot disagree. Two included triangles are adjacent when they
    /// share an edge, keyed by quantised POSITION rather than by index: a
    /// tessellated STEP part gives each face its own copies of shared corners, so
    /// index keys would find no adjacency at all and every triangle would be its
    /// own island.
    ///
    /// Sorted largest first, so "the body" comes before "the scrap".
    public static func components(of region: FaceRegion,
                                  in mesh: ViewerMesh) -> [[Int]] {
        let faces = Set(FaceRegionGeometry.members(of: region, in: mesh))
        guard !faces.isEmpty else { return [] }

        var included: [Int] = []
        var corners: [Int: [SIMD3<Double>]] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            guard tri < mesh.faceIDs.count, faces.contains(mesh.faceIDs[tri]) else {
                t += 3; continue
            }
            var p: [SIMD3<Double>] = []
            for k in 0..<3 {
                let vi = Int(mesh.indices[t + k]) * 3
                guard vi + 2 < mesh.positions.count else { break }
                p.append(SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                    mesh.positions[vi + 1],
                                                    mesh.positions[vi + 2])))
            }
            t += 3
            guard p.count == 3 else { continue }
            let centre = (p[0] + p[1] + p[2]) / 3
            guard FaceRegionGeometry.inside(centre, region.cuts) else { continue }
            included.append(tri)
            corners[tri] = p
        }
        guard !included.isEmpty else { return [] }

        // Adjacency by shared edge.
        struct EdgeKey: Hashable {
            let lo: SIMD3<Int64>, hi: SIMD3<Int64>
            init(_ a: SIMD3<Double>, _ b: SIMD3<Double>) {
                func q(_ v: SIMD3<Double>) -> SIMD3<Int64> {
                    SIMD3<Int64>(Int64((v.x * 10_000).rounded()),
                                 Int64((v.y * 10_000).rounded()),
                                 Int64((v.z * 10_000).rounded()))
                }
                let qa = q(a), qb = q(b)
                let first = (qa.x, qa.y, qa.z) <= (qb.x, qb.y, qb.z)
                lo = first ? qa : qb
                hi = first ? qb : qa
            }
        }
        var byEdge: [EdgeKey: [Int]] = [:]
        for tri in included {
            guard let p = corners[tri] else { continue }
            for e in 0..<3 { byEdge[EdgeKey(p[e], p[(e + 1) % 3]), default: []].append(tri) }
        }
        var links: [Int: [Int]] = [:]
        for (_, tris) in byEdge where tris.count >= 2 {
            for a in tris {
                for b in tris where b != a { links[a, default: []].append(b) }
            }
        }

        var seen = Set<Int>()
        var out: [[Int]] = []
        for start in included where !seen.contains(start) {
            var stack = [start]
            var group: [Int] = []
            seen.insert(start)
            while let cur = stack.popLast() {
                group.append(cur)
                for n in links[cur] ?? [] where !seen.contains(n) {
                    seen.insert(n)
                    stack.append(n)
                }
            }
            out.append(group)
        }
        return out.sorted { $0.count > $1.count }
    }

    /// ★ WHICH FACES TOUCH WHICH — KEYED ON POSITION, NOT ON VERTEX INDEX.
    ///
    /// `FaceTopology.adjacency` keys an edge on `(min, max)` VERTEX INDEX. That is
    /// right for a welded mesh and finds NOTHING on an unwelded one: a tessellated
    /// STEP part is usually written with each face carrying its own copies of the
    /// shared corner vertices, so the two sides of a B-rep edge have different
    /// indices at identical coordinates. `SurfaceWireframe.edges` already documents
    /// this and keys on the quantised position for the same reason.
    ///
    /// Connectivity decides whether an isolate produces one piece or several, so it
    /// has to be right on both kinds of import — an unwelded part would otherwise
    /// shatter every isolate into one piece per face.
    public static func faceAdjacency(in mesh: ViewerMesh) -> [FaceID: Set<FaceID>] {
        struct EdgeKey: Hashable {
            let lo: SIMD3<Int64>, hi: SIMD3<Int64>
            init(_ a: SIMD3<Double>, _ b: SIMD3<Double>) {
                func q(_ v: SIMD3<Double>) -> SIMD3<Int64> {
                    SIMD3<Int64>(Int64((v.x * 10_000).rounded()),
                                 Int64((v.y * 10_000).rounded()),
                                 Int64((v.z * 10_000).rounded()))
                }
                let qa = q(a), qb = q(b)
                let first = (qa.x, qa.y, qa.z) <= (qb.x, qb.y, qb.z)
                lo = first ? qa : qb
                hi = first ? qb : qa
            }
        }
        var byEdge: [EdgeKey: Set<FaceID>] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            guard tri < mesh.faceIDs.count else { break }
            let f = mesh.faceIDs[tri]
            var p: [SIMD3<Double>] = []
            for k in 0..<3 {
                let vi = Int(mesh.indices[t + k]) * 3
                guard vi + 2 < mesh.positions.count else { break }
                p.append(SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                    mesh.positions[vi + 1],
                                                    mesh.positions[vi + 2])))
            }
            t += 3
            guard p.count == 3 else { continue }
            for e in 0..<3 { byEdge[EdgeKey(p[e], p[(e + 1) % 3]), default: []].insert(f) }
        }
        var adj: [FaceID: Set<FaceID>] = [:]
        for faces in byEdge.values where faces.count > 1 {
            for f in faces { adj[f, default: []].formUnion(faces.subtracting([f])) }
        }
        return adj
    }

    /// The vertices of a set of triangles.
    static func points(_ tris: [Int], in mesh: ViewerMesh) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        for tri in tris {
            let base = tri * 3
            guard base + 2 < mesh.indices.count else { continue }
            for k in 0..<3 {
                let vi = Int(mesh.indices[base + k]) * 3
                guard vi + 2 < mesh.positions.count else { continue }
                out.append(SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                      mesh.positions[vi + 1],
                                                      mesh.positions[vi + 2])))
            }
        }
        return out
    }

    /// The centroid of a triangle, for the membership test.
    static func centroid(_ tri: Int, in mesh: ViewerMesh) -> SIMD3<Double>? {
        let base = tri * 3
        guard base + 2 < mesh.indices.count else { return nil }
        var acc = SIMD3<Double>.zero
        for k in 0..<3 {
            let vi = Int(mesh.indices[base + k]) * 3
            guard vi + 2 < mesh.positions.count else { return nil }
            acc += SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                              mesh.positions[vi + 1],
                                              mesh.positions[vi + 2]))
        }
        return acc / 3
    }

    /// ★ A PLANE THAT PUTS `keep` ON ONE SIDE AND `drop` ON THE OTHER, or nil when
    /// no direction separates them.
    ///
    /// The directions tried are the line between the two patches' centroids — the
    /// one that separates two things sitting apart — and the three coordinate axes,
    /// which catch the cases where the centroids happen to coincide (a ring and the
    /// scrap inside it). The plane is placed in the MIDDLE of the gap, so a
    /// tessellation vertex sitting exactly on a bound cannot flip sides.
    static func separator(keep: [Int], drop: [Int], in mesh: ViewerMesh) -> RegionCut? {
        let a = points(keep, in: mesh), b = points(drop, in: mesh)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        let ca = a.reduce(SIMD3<Double>.zero, +) / Double(a.count)
        let cb = b.reduce(SIMD3<Double>.zero, +) / Double(b.count)

        var directions: [SIMD3<Double>] = []
        let between = cb - ca
        if simd_length(between) > 1e-9 { directions.append(simd_normalize(between)) }
        directions += [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]

        for d in directions {
            for sign in [1.0, -1.0] {
                let n = d * sign
                let hiKeep = a.map { simd_dot($0, n) }.max() ?? 0
                let loDrop = b.map { simd_dot($0, n) }.min() ?? 0
                guard loDrop > hiKeep else { continue }
                let mid = (hiKeep + loDrop) / 2
                // Keep the side with the SMALLER projection: normal points back at
                // `keep`, so `dot(p - point, -n) >= 0` iff `dot(p, n) <= mid`.
                return RegionCut(point: n * mid, normal: -n)
            }
        }
        return nil
    }

    /// ★ THE CUTS THAT ISOLATE ONE COMPONENT — VERIFIED.
    ///
    /// Returns the parent's cuts plus one separator per sibling, but ONLY when the
    /// result contains exactly this component's triangles and none of anyone
    /// else's. Nil means "no honest split", and the caller must then leave the
    /// region whole rather than ship one that overlaps.
    public static func cuts(isolating index: Int, of components: [[Int]],
                            parent: FaceRegion, in mesh: ViewerMesh) -> [RegionCut]? {
        guard components.indices.contains(index) else { return nil }
        let mine = components[index]
        var cuts = parent.cuts
        for (k, other) in components.enumerated() where k != index {
            guard let s = separator(keep: mine, drop: other, in: mesh) else { return nil }
            cuts.append(s)
        }

        // ★ VERIFY. Every triangle of this component must be in, and every triangle
        // of every other component must be out. A separator that merely looked
        // plausible fails here rather than on the maintainer's screen.
        for tri in mine {
            guard let c = centroid(tri, in: mesh),
                  FaceRegionGeometry.inside(c, cuts) else { return nil }
        }
        for (k, other) in components.enumerated() where k != index {
            for tri in other {
                guard let c = centroid(tri, in: mesh) else { continue }
                if FaceRegionGeometry.inside(c, cuts) { return nil }
            }
        }
        return cuts
    }

    /// ★ THE WHOLE DECISION, IN ONE ANSWER: the cuts for each detached patch, or
    /// nil when this region should stay as it is.
    ///
    /// Nil for the ordinary case — one connected patch, which is what a cut through
    /// the middle of a simple face produces — so the common path costs one
    /// adjacency walk and changes nothing.
    public static func detachedPieces(of region: FaceRegion,
                                      in mesh: ViewerMesh) -> [[RegionCut]]? {
        let parts = components(of: region, in: mesh)
        guard parts.count >= 2, parts.count <= maxComponents else { return nil }
        var out: [[RegionCut]] = []
        for i in parts.indices {
            guard let c = cuts(isolating: i, of: parts, parent: region, in: mesh)
            else { return nil }        // ★ all or nothing — see the file header.
            out.append(c)
        }
        return out
    }
}

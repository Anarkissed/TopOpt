// SurfaceWireframe.swift — ★ §6(b): SHOW THE MODEL'S WIREFRAME SO FACES ARE EASY
// TO SEE (task 2026-08-15-lattice-and-face-ui, Surface stage).
//
// ★ WHY THIS IS NOT "DRAW EVERY TRIANGLE EDGE". The renderer already draws
// `.line` primitives in five places (ground grid, load path, flow guides, the
// clearance x-ray, the strut preview), so line drawing was never the missing
// piece. What was missing is the right SET of lines.
//
// A STEP part arrives TESSELLATED: a cylinder is fifty flat strips, a fillet is a
// grid of quads. Drawing every triangle edge turns a bore into a fan of spokes and
// a blend into a mesh of noise — which is the opposite of "so faces are easy to
// see". What a user means by the wireframe of a CAD model is the B-REP EDGES: the
// curves where one FACE meets another.
//
// ★ AND THAT SET IS ALREADY IN THE MESH. `ViewerMesh.faceIDs` is per-triangle, so
// an edge shared by two triangles with DIFFERENT face ids is exactly a B-rep edge,
// and an edge used by only ONE triangle is a boundary (an open shell, or the rim
// of a surface patch). Both are drawn; every other edge — the interior of a face's
// own tessellation — is not.
//
// ★ IT WORKS ON AN STL TOO. A mesh import has manufactured pseudo-faces from the
// dihedral segmenter (handoff 134), so `faceIDs` still partitions the surface and
// the same rule finds the same kind of boundary. A mesh with NO face ids at all
// falls back to the silhouette-free case and draws nothing rather than drawing
// everything — a wireframe of every triangle would be worse than none.
//
// Pure geometry on Float arrays, so the edge set is headlessly testable: no GPU,
// no view, no camera.

import Foundation
import simd

public enum SurfaceWireframe {

    /// The B-rep edge set as a flat line-list: x,y,z per vertex, two vertices per
    /// segment. Empty when the mesh carries no face partition to find edges in.
    ///
    /// ★ DEDUPED BY VERTEX POSITION, NOT BY INDEX. A tessellated STEP part is
    /// usually written with each face's triangles carrying their OWN copies of the
    /// shared corner vertices, so the two sides of a B-rep edge have DIFFERENT
    /// indices at identical coordinates. Keying on the index would find no shared
    /// edges at all and draw the whole tessellation; keying on the quantised
    /// position finds the real ones.
    /// ★ AND A UNION ERASES THE EDGE BETWEEN ITS PARTS.
    ///
    /// Maintainer, 2026-08-16: "The wireframe doesn't reflect the unions or cuts I
    /// made. This needs to be updated live." The CUT half of that is served by
    /// `SurfaceCutLines.committed`, which adds a trace where a piece was divided.
    /// This is the other half: when two whole faces are combined they are ONE face,
    /// and the B-rep edge that used to run between them is no longer a boundary of
    /// anything. Left in, the wireframe says they are still two — which is exactly
    /// what a union is supposed to have stopped being true.
    ///
    /// `welded` is one face set per union. An edge is dropped when EVERY face that
    /// touches it is in the same set: an edge on the union's outer rim still has a
    /// face outside it, so it survives.
    ///
    /// ★ WHOLE FACES ONLY. A union of two PIECES of a face has no B-rep edge
    /// between them to remove (they share one face id — layer 1 is never
    /// re-partitioned), and dropping the shared edge of a face only PARTLY in the
    /// union would erase a boundary that is still real for the rest of it. The
    /// caller decides which faces qualify; see `ProjectModel.surfaceWeldedFaces`.
    public static func edges(of mesh: ViewerMesh,
                             welded: [Set<FaceID>] = []) -> [Float] {
        guard !mesh.indices.isEmpty, !mesh.faceIDs.isEmpty else { return [] }

        // Quantise to 1e-4 mm so two coordinates that differ only in float noise
        // hash together. The parts here are tens of millimetres, so this is far
        // below anything geometric and far above the noise.
        func key(_ i: UInt32) -> SIMD3<Int64> {
            let b = Int(i) * 3
            return SIMD3<Int64>(Int64((mesh.positions[b] * 10_000).rounded()),
                                Int64((mesh.positions[b + 1] * 10_000).rounded()),
                                Int64((mesh.positions[b + 2] * 10_000).rounded()))
        }

        /// One undirected edge, identified by its two quantised endpoints in a
        /// canonical order so (a,b) and (b,a) are the same key.
        struct EdgeKey: Hashable {
            let lo: SIMD3<Int64>
            let hi: SIMD3<Int64>
            init(_ a: SIMD3<Int64>, _ b: SIMD3<Int64>) {
                let aFirst = (a.x, a.y, a.z) <= (b.x, b.y, b.z)
                lo = aFirst ? a : b
                hi = aFirst ? b : a
            }
        }

        /// What we have seen on an edge: which faces touch it, and one concrete
        /// index pair so it can be drawn from real coordinates.
        struct Seen {
            var faces: Set<Int32> = []
            var uses = 0
            var a: UInt32 = 0
            var b: UInt32 = 0
        }

        var seen: [EdgeKey: Seen] = [:]
        seen.reserveCapacity(mesh.indices.count)

        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            let owner: Int32 = tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1
            let v = (mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2])
            for (x, y) in [(v.0, v.1), (v.1, v.2), (v.2, v.0)] {
                let k = EdgeKey(key(x), key(y))
                var e = seen[k] ?? Seen(faces: [], uses: 0, a: x, b: y)
                e.faces.insert(owner)
                e.uses += 1
                seen[k] = e
            }
            t += 3
        }

        var out: [Float] = []
        out.reserveCapacity(seen.count * 3)
        func push(_ i: UInt32) {
            let b = Int(i) * 3
            out.append(mesh.positions[b])
            out.append(mesh.positions[b + 1])
            out.append(mesh.positions[b + 2])
        }
        for (_, e) in seen {
            // ★ A B-REP EDGE: two different faces meet here.
            // ★ OR A BOUNDARY: only one triangle uses it (an open shell's rim).
            guard e.faces.count > 1 || e.uses == 1 else { continue }
            // ★ …UNLESS A UNION HAS SWALLOWED BOTH SIDES OF IT.
            if !welded.isEmpty, e.faces.count > 1,
               welded.contains(where: { $0.isSuperset(of: e.faces) }) { continue }
            push(e.a)
            push(e.b)
        }
        return out
    }

    /// How many segments `edges(of:)` will produce — for the cost note and the
    /// tests, without building the buffer.
    public static func segmentCount(of mesh: ViewerMesh,
                                    welded: [Set<FaceID>] = []) -> Int {
        edges(of: mesh, welded: welded).count / 6
    }
}

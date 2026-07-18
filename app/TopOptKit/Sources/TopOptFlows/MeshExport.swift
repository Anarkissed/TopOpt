// MeshExport.swift — app-side STL export + honest mesh mass (EXPORT task, Open #6).
//
// The results screen's Export button ships a REAL binary STL of the selected
// variant, written from the mesh buffers `OptimizeVariant` already carries
// (`meshVertices`/`meshIndices`) — for BOTH local and remote variants, since a
// remote variant's mesh is a local buffer too. The core's `write_stl_file` stays
// for the CLI path; this is the app path, so no bridge / core change is needed.
//
// It also closes the mass gap flagged in handoff 086 (Open #6): the displayed
// voxel-count mass runs a percent or two HEAVY on lacy parts versus the mesh that
// actually exports (marching cubes encloses slightly less volume than the printed
// voxel count). At export we compute the MESH volume by the divergence theorem
// (signed tetrahedra from the origin) and derive the mesh mass from the material
// density, so the number describes the file the user is holding — never a
// different object. Both numbers are shown, labeled, when they diverge.
//
// Everything here is pure value math (no SwiftUI, no bridge), so it is verified
// headlessly (the M7 /app/ standard): the round-trip STL test and the unit-cube /
// two-cube volume tests exercise it directly.

import Foundation
import simd

/// Pure STL writer / reader + mesh mass math for the results-screen export.
public enum MeshExport {

    // MARK: - Binary STL

    /// The fixed byte length of a binary-STL header (the format reserves exactly 80
    /// bytes before the UInt32 triangle count).
    public static let headerByteCount = 80

    /// Build an 80-byte binary-STL header naming the app + variant. The string is
    /// UTF-8 encoded, then truncated / zero-padded to exactly 80 bytes (the binary
    /// STL header is a fixed-size field, NOT length-prefixed, so slicers read it as
    /// free-form text). It must NOT begin with "solid" — some readers sniff that as
    /// ASCII STL — so the app name leads.
    public static func header(app: String = "TopOpt", detail: String) -> Data {
        let text = "\(app) · \(detail)"
        var bytes = Array(text.utf8.prefix(headerByteCount))
        if bytes.count < headerByteCount {
            bytes.append(contentsOf: repeatElement(0, count: headerByteCount - bytes.count))
        }
        return Data(bytes)
    }

    /// Serialize an indexed triangle mesh to binary little-endian STL bytes. Vertex
    /// positions are written verbatim (units are whatever the buffers store — mm in
    /// this app), the triangle count is the true count (`indices.count / 3`), and each
    /// facet normal is COMPUTED from the triangle's winding (`(b−a)×(c−a)`, normalized;
    /// zero for a degenerate triangle, which is the STL convention "normal unknown").
    ///
    /// `indices` shorter than a whole triangle has its tail ignored; an index out of
    /// range drops that one triangle rather than crashing (a defensive guard — the
    /// variant buffers are always consistent, but export must never trap on bad data).
    public static func binarySTL(vertices: [Float], indices: [Int32], header headerData: Data) -> Data {
        let triCount = indices.count / 3
        var head = headerData
        if head.count != headerByteCount {
            // Normalize any mis-sized header to exactly 80 bytes.
            head = Data((Array(head).prefix(headerByteCount))
                + repeatElement(UInt8(0), count: max(0, headerByteCount - head.count)))
        }
        var out = Data(capacity: headerByteCount + 4 + triCount * 50)
        out.append(head)
        appendLE(&out, UInt32(triCount))

        let vertexCount = vertices.count / 3
        func vertex(_ i: Int32) -> SIMD3<Float>? {
            let idx = Int(i)
            guard idx >= 0, idx < vertexCount else { return nil }
            return SIMD3<Float>(vertices[idx * 3], vertices[idx * 3 + 1], vertices[idx * 3 + 2])
        }

        var written: UInt32 = 0
        var body = Data(capacity: triCount * 50)
        for t in 0..<triCount {
            guard let a = vertex(indices[t * 3]),
                  let b = vertex(indices[t * 3 + 1]),
                  let c = vertex(indices[t * 3 + 2]) else { continue }
            let n = facetNormal(a, b, c)
            appendFloat(&body, n.x); appendFloat(&body, n.y); appendFloat(&body, n.z)
            for v in [a, b, c] {
                appendFloat(&body, v.x); appendFloat(&body, v.y); appendFloat(&body, v.z)
            }
            appendLE(&body, UInt16(0))   // attribute byte count (unused)
            written += 1
        }

        // If any triangle was dropped, rewrite the count so the header stays honest
        // (a reader trusts the count field, not the byte length).
        if written != UInt32(triCount) {
            out.removeAll(keepingCapacity: true)
            out.append(head)
            appendLE(&out, written)
        }
        out.append(body)
        return out
    }

    /// Parse binary little-endian STL bytes back to an interleaved-xyz vertex array +
    /// a triangle-soup index array (each triangle its own three vertices — STL shares
    /// none). Mirrors the reader `RemoteRunner` uses for a worker's returned mesh, so
    /// the round-trip test reparses through the SAME logic the remote path relies on.
    /// Returns empty arrays for a truncated / non-STL buffer rather than trapping.
    public static func parseBinarySTL(_ data: Data) -> (vertices: [Float], indices: [Int32]) {
        guard data.count > headerByteCount + 4 else { return ([], []) }
        let count = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: headerByteCount, as: UInt32.self)
        }
        var verts: [Float] = []; var idx: [Int32] = []
        verts.reserveCapacity(Int(count) * 9)
        var off = headerByteCount + 4
        for _ in 0..<Int(count) {
            guard off + 50 <= data.count else { break }
            for v in 0..<3 {
                let base = off + 12 + v * 12   // skip the 12-byte normal
                for c in 0..<3 {
                    let f = data.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: base + c * 4, as: Float32.self)
                    }
                    verts.append(f)
                }
            }
            let n = Int32(idx.count)
            idx.append(contentsOf: [n, n + 1, n + 2])
            off += 50
        }
        return (verts, idx)
    }

    /// The outward facet normal for a triangle in winding order (a, b, c): the
    /// normalized `(b−a)×(c−a)`. Zero for a degenerate (zero-area) triangle — the STL
    /// convention for "normal not supplied; derive from vertices".
    public static func facetNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        return len > 0 ? n / len : .zero
    }

    // MARK: - Mesh volume & mass (Open #6)

    /// The enclosed volume of a closed triangle mesh, by the divergence theorem: the
    /// signed sum of tetrahedra `(origin, a, b, c)`, one per triangle, `V = (1/6)·Σ
    /// a·(b×c)`, absolute-valued so a consistently-wound mesh gives a positive volume
    /// regardless of orientation. Units are the CUBE of the vertex units (mm³ in this
    /// app). A unit cube returns 1.0; a mesh scaled ×k returns k³. Double-precision
    /// accumulation (vertices upcast from Float) keeps the sum stable over many
    /// triangles. Returns 0 for fewer than one triangle.
    public static func meshVolume(vertices: [Float], indices: [Int32]) -> Double {
        let vertexCount = vertices.count / 3
        let triCount = indices.count / 3
        guard triCount > 0 else { return 0 }
        func vertex(_ i: Int32) -> SIMD3<Double>? {
            let idx = Int(i)
            guard idx >= 0, idx < vertexCount else { return nil }
            return SIMD3<Double>(Double(vertices[idx * 3]),
                                 Double(vertices[idx * 3 + 1]),
                                 Double(vertices[idx * 3 + 2]))
        }
        var six = 0.0   // 6·V, divided once at the end
        for t in 0..<triCount {
            guard let a = vertex(indices[t * 3]),
                  let b = vertex(indices[t * 3 + 1]),
                  let c = vertex(indices[t * 3 + 2]) else { continue }
            six += simd_dot(a, simd_cross(b, c))
        }
        return abs(six) / 6.0
    }

    /// The mesh's mass in grams from its enclosed volume and the material density:
    /// `density(g/cm³) × volume(mm³) / 1000` (1 cm³ = 1000 mm³). This is the SAME
    /// definition the core applies to the voxel count (`minimize_plastic.cpp`:
    /// `density × printedVoxels × voxelVolume / 1000`), only measured on the exported
    /// mesh's true enclosed volume instead of the voxel count — so the number
    /// describes the file. 0 when the density is not positive (unknown material).
    public static func meshMassGrams(vertices: [Float], indices: [Int32], densityGCm3: Double) -> Double {
        guard densityGCm3 > 0 else { return 0 }
        return densityGCm3 * meshVolume(vertices: vertices, indices: indices) / 1000.0
    }

    /// Whether the indexed mesh is watertight (closed + manifold), by the SAME
    /// criterion the core's `check_watertight` uses: every undirected edge is shared
    /// by exactly two triangles (no boundary edge, no non-manifold edge > 2). The
    /// variant mesh carries no stored flag, so the export derives it from the topology
    /// — used to label the mesh mass an ESTIMATE when the surface is not closed (an
    /// open mesh has no well-defined enclosed volume; the divergence sum is then only
    /// approximate). Empty mesh → false.
    public static func isWatertight(vertices: [Float], indices: [Int32]) -> Bool {
        let triCount = indices.count / 3
        guard triCount > 0 else { return false }
        var edgeCount: [UInt64: Int] = [:]
        edgeCount.reserveCapacity(triCount * 3)
        func key(_ x: Int32, _ y: Int32) -> UInt64 {
            let lo = UInt64(UInt32(bitPattern: min(x, y)))
            let hi = UInt64(UInt32(bitPattern: max(x, y)))
            return (hi << 32) | lo
        }
        for t in 0..<triCount {
            let i = indices[t * 3], j = indices[t * 3 + 1], k = indices[t * 3 + 2]
            edgeCount[key(i, j), default: 0] += 1
            edgeCount[key(j, k), default: 0] += 1
            edgeCount[key(k, i), default: 0] += 1
        }
        return edgeCount.values.allSatisfy { $0 == 2 }
    }

    // MARK: - Little-endian byte helpers

    private static func appendLE(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    private static func appendLE(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    private static func appendFloat(_ data: inout Data, _ value: Float) {
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

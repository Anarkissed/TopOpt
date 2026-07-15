// ViewerMesh.swift — render-ready geometry for the M7.4 Metal viewer.
//
// The bridge (TopOptKit.ImportedMesh) supplies flattened vertices, triangle
// indices and per-triangle B-rep face ids, but NOT normals (the core mesh is a
// welded triangle soup — see core/include/topopt/mesh.hpp). Matcap-style shading
// needs per-vertex normals, so the viewer derives them here from the supplied
// positions + indices (area-weighted, the standard smooth-normal estimate).
//
// Everything in this file is pure value-type math on plain Float/Int arrays so it
// is unit-testable headlessly on macOS (the M7 /app/ verification standard) without
// a GPU or a booted simulator; the Metal draw that consumes it lives in
// MetalMeshView.swift.

import Foundation
import simd

/// Axis-aligned bounds of a mesh, plus the derived framing quantities the camera
/// uses. `radius` is the bounding-sphere radius (half the diagonal), so a camera
/// framed at `distance = radius / sin(fovY/2)` fits the whole part.
public struct MeshBounds: Equatable, Sendable {
    public let min: SIMD3<Float>
    public let max: SIMD3<Float>
    public let isEmpty: Bool

    public init(min: SIMD3<Float>, max: SIMD3<Float>, isEmpty: Bool) {
        self.min = min
        self.max = max
        self.isEmpty = isEmpty
    }

    /// The centre of the box (the camera's orbit target).
    public var center: SIMD3<Float> { (min + max) * 0.5 }

    /// The bounding-sphere radius: half the space diagonal. `>= 0`, and `0` only
    /// for a degenerate (single-point or empty) mesh.
    public var radius: Float { simd_length((max - min) * 0.5) }
}

/// Pure geometry helpers for the viewer: bounds and smooth vertex normals.
public enum MeshGeometry {

    /// Axis-aligned bounds over a flattened xyz vertex array. An empty (or
    /// malformed, size not a multiple of 3) array yields `isEmpty == true` with a
    /// zero box, so callers can render an empty stage without special-casing.
    public static func bounds(vertices: [Float]) -> MeshBounds {
        guard vertices.count >= 3 else {
            return MeshBounds(min: .zero, max: .zero, isEmpty: true)
        }
        var lo = SIMD3<Float>(vertices[0], vertices[1], vertices[2])
        var hi = lo
        var i = 0
        while i + 2 < vertices.count {
            let p = SIMD3<Float>(vertices[i], vertices[i + 1], vertices[i + 2])
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
            i += 3
        }
        return MeshBounds(min: lo, max: hi, isEmpty: false)
    }

    /// Area-weighted per-vertex normals for an indexed triangle mesh. Returns a
    /// flattened xyz array with one unit normal per vertex (same vertex count as
    /// `vertices`). Each triangle contributes its (un-normalized) cross product —
    /// whose magnitude is twice the triangle area — to its three corners, so
    /// larger faces weigh more; the accumulated normal is then normalized. A
    /// vertex touched only by degenerate triangles gets `(0,0,1)` rather than a
    /// NaN. Triangle winding sets the sign: the core meshes wind outward.
    public static func vertexNormals(vertices: [Float], indices: [Int32]) -> [Float] {
        let vertexCount = vertices.count / 3
        var accum = [SIMD3<Float>](repeating: .zero, count: vertexCount)

        func position(_ idx: Int32) -> SIMD3<Float> {
            let b = Int(idx) * 3
            return SIMD3<Float>(vertices[b], vertices[b + 1], vertices[b + 2])
        }

        var t = 0
        while t + 2 < indices.count {
            let i0 = indices[t], i1 = indices[t + 1], i2 = indices[t + 2]
            t += 3
            if i0 < 0 || i1 < 0 || i2 < 0 { continue }
            if Int(i0) >= vertexCount || Int(i1) >= vertexCount || Int(i2) >= vertexCount {
                continue
            }
            let p0 = position(i0), p1 = position(i1), p2 = position(i2)
            let faceNormal = simd_cross(p1 - p0, p2 - p0)  // ‖·‖ == 2 × area
            accum[Int(i0)] += faceNormal
            accum[Int(i1)] += faceNormal
            accum[Int(i2)] += faceNormal
        }

        var out = [Float](repeating: 0, count: vertexCount * 3)
        for v in 0..<vertexCount {
            let n = accum[v]
            let len = simd_length(n)
            let unit = len > 1e-12 ? n / len : SIMD3<Float>(0, 0, 1)
            out[v * 3] = unit.x
            out[v * 3 + 1] = unit.y
            out[v * 3 + 2] = unit.z
        }
        return out
    }

    /// Read a flattened xyz vertex at an index, `.zero` if out of range.
    private static func position(_ idx: Int32, in vertices: [Float], vertexCount: Int) -> SIMD3<Float> {
        guard idx >= 0, Int(idx) < vertexCount else { return .zero }
        let b = Int(idx) * 3
        return SIMD3<Float>(vertices[b], vertices[b + 1], vertices[b + 2])
    }

    /// Geometric per-triangle face normals: for each triangle, the normalized
    /// cross product of its two edges, constant across the face (the crisp CAD
    /// look). Exactly one entry per triangle, in triangle order; a degenerate or
    /// out-of-range triangle yields `(0,0,1)`. Triangle winding sets the sign (the
    /// core meshes wind outward).
    public static func faceNormals(vertices: [Float], indices: [Int32]) -> [SIMD3<Float>] {
        let vertexCount = vertices.count / 3
        var out = [SIMD3<Float>]()
        out.reserveCapacity(indices.count / 3)
        var t = 0
        while t + 2 < indices.count {
            let p0 = position(indices[t], in: vertices, vertexCount: vertexCount)
            let p1 = position(indices[t + 1], in: vertices, vertexCount: vertexCount)
            let p2 = position(indices[t + 2], in: vertices, vertexCount: vertexCount)
            t += 3
            let n = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(n)
            out.append(len > 1e-12 ? n / len : SIMD3<Float>(0, 0, 1))
        }
        return out
    }

    /// Flat-shade expansion: unshare vertices so each triangle carries its own
    /// constant face normal. Flat shading needs unshared vertices — you cannot
    /// force per-face normals onto a shared-vertex index buffer — so every triangle
    /// emits its three positions, each paired with the triangle's face normal.
    /// The result has exactly `3 * triangleCount` vertices and is drawn
    /// non-indexed.
    public static func flatShaded(vertices: [Float], indices: [Int32]) -> FlatMesh {
        let vertexCount = vertices.count / 3
        let normals = faceNormals(vertices: vertices, indices: indices)
        var pos = [Float]()
        var nor = [Float]()
        pos.reserveCapacity(indices.count * 3)
        nor.reserveCapacity(indices.count * 3)
        var t = 0
        var tri = 0
        while t + 2 < indices.count {
            let fn = normals[tri]
            tri += 1
            for k in 0..<3 {
                let p = position(indices[t + k], in: vertices, vertexCount: vertexCount)
                pos.append(p.x); pos.append(p.y); pos.append(p.z)
                nor.append(fn.x); nor.append(fn.y); nor.append(fn.z)
            }
            t += 3
        }
        return FlatMesh(positions: pos, normals: nor)
    }

    /// Smooth-shade expansion (M-stairstep 083): same unshared-vertex layout as
    /// `flatShaded` — every triangle emits its three positions in triangle order,
    /// so the `3 * triangleCount` vertex ordering is BYTE-IDENTICAL and every
    /// per-flat-vertex attribute buffer (stress tint, flex displacement, id) stays
    /// aligned — but each emitted vertex carries the shared-vertex SMOOTH normal
    /// (area-weighted, `vertexNormals`) looked up by its original index instead of
    /// the triangle's constant face normal. Only the normals differ; positions,
    /// count, order, and the exported geometry are untouched. This is the correct
    /// shading for an ORGANIC marching-cubes surface (the optimized result), where
    /// flat per-face normals turn every 64³ lattice facet into a visible terrace.
    /// It changes the VIEW only: the surface geometry, mass, and exported STL/3MF
    /// are unchanged (the exporter uses the core mesh, not these normals), and the
    /// silhouette still shows the true voxel stepping.
    public static func flatShadedSmooth(vertices: [Float], indices: [Int32]) -> FlatMesh {
        let vertexCount = vertices.count / 3
        let smooth = vertexNormals(vertices: vertices, indices: indices)  // 3 per shared vertex
        var pos = [Float]()
        var nor = [Float]()
        pos.reserveCapacity(indices.count * 3)
        nor.reserveCapacity(indices.count * 3)
        var t = 0
        while t + 2 < indices.count {
            for k in 0..<3 {
                let idx = indices[t + k]
                let p = position(idx, in: vertices, vertexCount: vertexCount)
                pos.append(p.x); pos.append(p.y); pos.append(p.z)
                if idx >= 0, Int(idx) < vertexCount {
                    let b = Int(idx) * 3
                    nor.append(smooth[b]); nor.append(smooth[b + 1]); nor.append(smooth[b + 2])
                } else {
                    nor.append(0); nor.append(0); nor.append(1)
                }
            }
            t += 3
        }
        return FlatMesh(positions: pos, normals: nor)
    }
}

/// A flat-shaded render buffer: unshared vertices (`3 * triangleCount`), each
/// carrying its triangle's constant geometric face normal. This is what the M7.4
/// viewer draws by default — mechanical CAD parts read with flat faces and crisp
/// edges, which the shared-vertex smooth normals blur away.
public struct FlatMesh {
    /// Flattened xyz positions, one per emitted vertex (`3 * 3 * triangleCount`).
    public let positions: [Float]
    /// Flattened xyz face normals, matching `positions` (constant per triangle).
    public let normals: [Float]

    public var vertexCount: Int { positions.count / 3 }

    /// Positions and normals interleaved as `[px,py,pz,nx,ny,nz]` per vertex (the
    /// stride-24 layout the Metal vertex shader reads), drawn non-indexed.
    public func interleaved() -> [Float] {
        let n = vertexCount
        var out = [Float](repeating: 0, count: n * 6)
        for v in 0..<n {
            out[v * 6] = positions[v * 3]
            out[v * 6 + 1] = positions[v * 3 + 1]
            out[v * 6 + 2] = positions[v * 3 + 2]
            out[v * 6 + 3] = normals[v * 3]
            out[v * 6 + 4] = normals[v * 3 + 1]
            out[v * 6 + 5] = normals[v * 3 + 2]
        }
        return out
    }
}

/// Render-ready mesh: positions + derived normals + indices (+ optional per-
/// triangle face ids, unused until M7.5 selection) and the precomputed bounds.
public struct ViewerMesh {
    /// Flattened xyz positions, one per vertex (`3 * vertexCount`).
    public let positions: [Float]
    /// Flattened xyz smooth normals, one per vertex (`3 * vertexCount`).
    public let normals: [Float]
    /// Triangle corner indices into the vertex arrays (`3 * triangleCount`).
    public let indices: [UInt32]
    /// Per-triangle B-rep face id (empty for STL; kept for M7.5 face selection).
    public let faceIDs: [Int32]
    /// Axis-aligned bounds (drives camera framing).
    public let bounds: MeshBounds
    /// The flat-shaded render buffer (unshared vertices + per-face normals). This
    /// is what the viewer draws by default: mechanical CAD parts keep flat faces
    /// and crisp edges. The smooth `normals` above stay available for a future
    /// organic/optimized mesh that wants smoothing, but are unused by default.
    public let flat: FlatMesh

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }

    /// Build from the bridge's flattened buffers: derives the flat render buffer,
    /// the smooth normals (available), the bounds, and converts the signed indices
    /// to the unsigned form a Metal index buffer wants.
    ///
    /// `smoothShaded` picks how the `flat` render buffer is normal-shaded (the
    /// unshared-vertex layout is identical either way, so all per-flat-vertex
    /// attribute buffers stay aligned): `false` (default) = per-face normals, the
    /// crisp CAD look for prismatic imported parts; `true` = smooth per-vertex
    /// normals, the correct look for an ORGANIC optimized marching-cubes result
    /// (M-stairstep 083) where flat shading turns every voxel-lattice facet into a
    /// visible terrace. Smooth shading is display-only — geometry, mass, and the
    /// exported STL/3MF are unchanged.
    public init(vertices: [Float], indices: [Int32], faceIDs: [Int32],
                smoothShaded: Bool = false) {
        self.positions = vertices
        self.normals = MeshGeometry.vertexNormals(vertices: vertices, indices: indices)
        self.indices = indices.map { UInt32(bitPattern: $0) }
        self.faceIDs = faceIDs
        self.bounds = MeshGeometry.bounds(vertices: vertices)
        self.flat = smoothShaded
            ? MeshGeometry.flatShadedSmooth(vertices: vertices, indices: indices)
            : MeshGeometry.flatShaded(vertices: vertices, indices: indices)
    }

    /// Positions and normals interleaved as `[px,py,pz,nx,ny,nz]` per vertex — the
    /// single-buffer layout the Metal vertex shader reads (stride 24 bytes).
    public func interleaved() -> [Float] {
        let n = vertexCount
        var out = [Float](repeating: 0, count: n * 6)
        for v in 0..<n {
            out[v * 6] = positions[v * 3]
            out[v * 6 + 1] = positions[v * 3 + 1]
            out[v * 6 + 2] = positions[v * 3 + 2]
            out[v * 6 + 3] = normals[v * 3]
            out[v * 6 + 4] = normals[v * 3 + 1]
            out[v * 6 + 5] = normals[v * 3 + 2]
        }
        return out
    }

    /// The outward model-space normal of B-rep face `faceID`: the area-weighted
    /// average of its triangles' geometric normals, normalized. Nil if the face id
    /// is absent, or the mesh carries no face ids (STL). Used by M7.6 gravity setup
    /// to turn a tapped "floor" face into the gravity direction (MOD-F1 D2).
    public func faceNormal(_ faceID: Int32) -> SIMD3<Float>? {
        guard !faceIDs.isEmpty else { return nil }
        let vc = vertexCount
        var accum = SIMD3<Float>.zero
        var found = false
        var t = 0
        while t + 2 < indices.count {
            let tri = t / 3
            if tri < faceIDs.count, faceIDs[tri] == faceID {
                let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
                if i0 < vc, i1 < vc, i2 < vc {
                    let p0 = SIMD3<Float>(positions[i0 * 3], positions[i0 * 3 + 1], positions[i0 * 3 + 2])
                    let p1 = SIMD3<Float>(positions[i1 * 3], positions[i1 * 3 + 1], positions[i1 * 3 + 2])
                    let p2 = SIMD3<Float>(positions[i2 * 3], positions[i2 * 3 + 1], positions[i2 * 3 + 2])
                    accum += simd_cross(p1 - p0, p2 - p0)   // ‖·‖ == 2 × area, outward winding
                    found = true
                }
            }
            t += 3
        }
        guard found else { return nil }
        let len = simd_length(accum)
        return len > 1e-12 ? accum / len : nil
    }

    /// The model-space centroid of B-rep face `faceID`: the mean of its triangles'
    /// corner positions. Nil if the face id is absent / the mesh has no face ids.
    /// Feeds M7.6 overlay + arrow placement (the group centroid).
    public func faceCentroid(_ faceID: Int32) -> SIMD3<Float>? {
        guard !faceIDs.isEmpty else { return nil }
        let vc = vertexCount
        var sum = SIMD3<Float>.zero
        var count = 0
        var t = 0
        while t + 2 < indices.count {
            let tri = t / 3
            if tri < faceIDs.count, faceIDs[tri] == faceID {
                for k in 0..<3 {
                    let i = Int(indices[t + k])
                    if i < vc {
                        sum += SIMD3<Float>(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
                        count += 1
                    }
                }
            }
            t += 3
        }
        return count > 0 ? sum / Float(count) : nil
    }
}

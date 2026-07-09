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

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }

    /// Build from the bridge's flattened buffers: derives normals and bounds and
    /// converts the signed indices to the unsigned form a Metal index buffer wants.
    public init(vertices: [Float], indices: [Int32], faceIDs: [Int32]) {
        self.positions = vertices
        self.normals = MeshGeometry.vertexNormals(vertices: vertices, indices: indices)
        self.indices = indices.map { UInt32(bitPattern: $0) }
        self.faceIDs = faceIDs
        self.bounds = MeshGeometry.bounds(vertices: vertices)
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
}

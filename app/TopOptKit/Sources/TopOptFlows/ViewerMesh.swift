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
import TopOptKit

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

    /// The closest point on triangle `abc` to `p` (Ericson, *Real-Time Collision
    /// Detection* §5.1.5 — the barycentric Voronoi-region test). Handles the vertex,
    /// edge and interior cases; pure, so the gravity widget's magnetic base-attach
    /// (2026-07-27 round 2) can be tested headlessly.
    public static func closestPointOnTriangle(_ p: SIMD3<Float>, _ a: SIMD3<Float>,
                                              _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }                       // vertex region A
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }                      // vertex region B
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {                       // edge AB
            let v = d1 / (d1 - d3)
            return a + ab * v
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }                      // vertex region C
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {                       // edge AC
            let w = d2 / (d2 - d6)
            return a + ac * w
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {         // edge BC
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return b + (c - b) * w
        }
        let denom = 1 / (va + vb + vc)                           // interior
        let v = vb * denom, w = vc * denom
        return a + ab * v + ac * w
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

/// WHAT MESH THIS IS — the value the renderer compares to decide whether to
/// re-upload its GPU buffers (task 2026-08-04-smoothing-viewer-and-ui, bar V1).
///
/// THE DEFECT THIS REPLACES. The renderer used to compare
/// `(vertexCount, triangleCount, bounds.min, bounds.max)`. That tuple cannot see
/// a mesh whose vertices MOVED — which is exactly what smoothing does: Taubin
/// preserves the welded topology vertex-for-vertex and triangle-for-triangle, and
/// a LOCAL brush moves only the painted patch, so the bounding box is decided by
/// vertices that never moved. `smooth_viewer_identity_probe` measured it on the
/// maintainer's own bracket: brushing the middle of the part left counts AND all
/// six bounds planes bit-identical at every strength, while 23 vertices had moved
/// by up to 0.59 mm. The renderer skipped the upload and kept drawing the
/// ORIGINAL — so "Original" and "Smoothed" rendered identically, not because the
/// smoothed mesh was missing but because it was never sent to the GPU.
///
/// The bounding box only separated them when the painted patch happened to
/// contain the part's own extreme, which made the whole thing a coin flip on
/// WHERE you brushed. A signature that answers "is this a different mesh?" has to
/// read the mesh.
///
/// DETERMINISTIC BY CONSTRUCTION (bar B6). FNV-1a over the float32 bit patterns
/// of every position and then every index: a fixed basis, a fixed prime, a fixed
/// traversal order. Deliberately NOT Swift's `Hasher`, whose seed is randomised
/// per process — the same mesh would sign differently on every launch, which is
/// the opposite of what a cache key needs.
///
/// The counts ride along so a collision has to agree on all three, and so a
/// degenerate all-zero mesh still compares by size.
public struct ViewerMeshSignature: Equatable, Sendable {
    public let vertexCount: Int
    public let triangleCount: Int
    /// FNV-1a over positions then indices.
    public let contentHash: UInt64

    private static let offsetBasis: UInt64 = 1469598103934665603
    private static let prime: UInt64 = 1099511628211

    public init(vertices: [Float], indices: [Int32]) {
        var h = Self.offsetBasis
        // `&*`, not `*`: FNV is defined on wrapping arithmetic, and an overflow
        // trap here would be a crash in the render path.
        func mix(_ word: UInt32) {
            var w = word
            for _ in 0..<4 {
                h ^= UInt64(w & 0xFF)
                h = h &* Self.prime
                w >>= 8
            }
        }
        for p in vertices { mix(p.bitPattern) }
        for i in indices { mix(UInt32(bitPattern: i)) }
        self.vertexCount = vertices.count / 3
        self.triangleCount = indices.count / 3
        self.contentHash = h
    }

    /// The empty mesh's signature — an explicit value rather than an optional, so
    /// "no mesh" and "a mesh" compare through the same path.
    public static let empty = ViewerMeshSignature(vertices: [], indices: [])
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
    /// Per-B-rep-face EXACT surface geometry, indexed by face id (empty for STL or
    /// an optimized-result mesh). Keep-clear v2: the axis/radius/normal the app
    /// draws clearance volumes and derives "Auto · N mm" labels from — the SAME
    /// numbers the core rasterizer freezes.
    public let faceGeometry: [StepFaceGeometry]
    /// Axis-aligned bounds (drives camera framing).
    public let bounds: MeshBounds
    /// The flat-shaded render buffer (unshared vertices + per-face normals). This
    /// is what the viewer draws by default: mechanical CAD parts keep flat faces
    /// and crisp edges. The smooth `normals` above stay available for a future
    /// organic/optimized mesh that wants smoothing, but are unused by default.
    public let flat: FlatMesh
    /// True when `faceIDs` are pseudo-faces from the core dihedral segmenter (an
    /// STL/3MF import) rather than a B-rep's real faces (a STEP import). A pseudo-
    /// face IS the intended selection unit, so the tap layer must NOT run the B-rep
    /// curved-face loop walk on it (that walk reunites a hole OCCT split into
    /// cylinder+cone; the mesh segmenter never splits a hole like that, and running
    /// the walk anyway unions the whole connected curved run — the over-selection
    /// fixed in handoff 2026-07-25-tap-overselect).
    public let pseudoFaces: Bool
    /// WHAT THIS MESH IS, as one comparable value — see `ViewerMeshSignature`.
    /// Computed ONCE here, so the renderer's per-update-pass comparison stays a
    /// scalar compare no matter how large the mesh is.
    public let signature: ViewerMeshSignature

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
                faceGeometry: [StepFaceGeometry] = [],
                pseudoFaces: Bool = false,
                smoothShaded: Bool = false) {
        self.positions = vertices
        self.normals = MeshGeometry.vertexNormals(vertices: vertices, indices: indices)
        self.indices = indices.map { UInt32(bitPattern: $0) }
        self.faceIDs = faceIDs
        self.faceGeometry = faceGeometry
        self.pseudoFaces = pseudoFaces
        self.bounds = MeshGeometry.bounds(vertices: vertices)
        self.flat = smoothShaded
            ? MeshGeometry.flatShadedSmooth(vertices: vertices, indices: indices)
            : MeshGeometry.flatShaded(vertices: vertices, indices: indices)
        self.signature = ViewerMeshSignature(vertices: vertices, indices: indices)
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

    /// The EXACT B-rep surface geometry of face `faceID` (keep-clear v2), or nil if
    /// the face id is out of range / the mesh carries none (STL, optimized result).
    public func faceGeometry(_ faceID: Int32) -> StepFaceGeometry? {
        let i = Int(faceID)
        guard i >= 0, i < faceGeometry.count else { return nil }
        return faceGeometry[i]
    }

    /// The signed span of face `faceID`'s tessellated vertices projected onto the
    /// ray through `axisPoint` along the UNIT `axisDir` (t=0 at axisPoint). This is
    /// the bore's through-part axial extent the swept-cylinder clearance sweeps
    /// from — computed from the SAME tessellation the core reads, so the app's
    /// rendered cylinder length matches the run. Nil if the face has no triangles.
    public func faceAxialSpan(_ faceID: Int32, axisPoint: SIMD3<Float>,
                              axisDir: SIMD3<Float>) -> (lo: Float, hi: Float)? {
        guard !faceIDs.isEmpty else { return nil }
        let vc = vertexCount
        let dir = simd_length(axisDir) > 1e-9 ? simd_normalize(axisDir) : axisDir
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        var found = false
        var t = 0
        while t + 2 < indices.count {
            let tri = t / 3
            if tri < faceIDs.count, faceIDs[tri] == faceID {
                for k in 0..<3 {
                    let i = Int(indices[t + k])
                    if i < vc {
                        let p = SIMD3<Float>(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
                        let s = simd_dot(p - axisPoint, dir)
                        lo = Swift.min(lo, s); hi = Swift.max(hi, s); found = true
                    }
                }
            }
            t += 3
        }
        return found ? (lo, hi) : nil
    }

    /// The in-plane bounding rectangle (slab footprint) of planar face `faceID`,
    /// from its tessellated corner positions projected onto `planeBasis(normal)` —
    /// the same in-plane extent the core's bounded slab extrudes. Nil if the face
    /// has no triangles / the mesh has no face ids.
    public func facePlaneOutline(_ faceID: Int32, planeNormal: SIMD3<Float>,
                                 planeOrigin: SIMD3<Float>) -> PlaneOutline? {
        guard !faceIDs.isEmpty else { return nil }
        let vc = vertexCount
        var pts: [SIMD3<Float>] = []
        var t = 0
        while t + 2 < indices.count {
            let tri = t / 3
            if tri < faceIDs.count, faceIDs[tri] == faceID {
                for k in 0..<3 {
                    let i = Int(indices[t + k])
                    if i < vc {
                        pts.append(SIMD3<Float>(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]))
                    }
                }
            }
            t += 3
        }
        return PlaneOutline.fit(points: pts, normal: planeNormal, origin: planeOrigin)
    }

    /// A large flat face of the part, as an outward-normal snap candidate for the gravity
    /// DIRECTION widget (2026-07-27 round 2). `area` is mm² (used to rank + threshold).
    public struct FlatFace: Equatable, Sendable {
        public let normal: SIMD3<Float>
        public let faceID: Int32
        public let area: Float
        public init(normal: SIMD3<Float>, faceID: Int32, area: Float) {
            self.normal = normal; self.faceID = faceID; self.area = area
        }
    }

    /// The part's own large FLAT faces, as outward-normal snap targets for the gravity
    /// direction widget. This is the round-2 fix for "Gravity set · custom": PR 199 snapped
    /// to the six MODEL axes, which only coincide with the part's faces when the part is
    /// modelled axis-aligned — on the maintainer's imported (arbitrarily-oriented) bracket
    /// they don't, so the snap never engaged. Snapping to these ACTUAL face normals makes
    /// gravity land perpendicular to whatever floor/wall the part sits on, however it is
    /// oriented in model space.
    ///
    /// Candidate selection (stated for the handoff):
    ///   • group the tessellation by its per-triangle face id (STL pseudo-faces or STEP
    ///     B-rep faces — both work);
    ///   • for each face accumulate `Σ(cross)` (a vector whose length is 2× the FLAT-
    ///     projected area and whose direction is the area-weighted normal) and `Σ|cross|`
    ///     (2× the total triangle area). Their ratio is a FLATNESS score: 1 for a planar
    ///     face, →0 as it curves (opposing facet normals cancel in the vector sum). So a
    ///     bore/fillet is rejected and only genuine flat seating faces qualify;
    ///   • keep faces with flatness ≥ `minFlatness` (default 0.9 ≈ within ~25° of planar)
    ///     AND area ≥ `minAreaFraction` of the largest flat face (drop slivers);
    ///   • merge near-parallel normals within `mergeAngleDeg` (default 6°, keeping the
    ///     larger face) so coplanar facets don't flood the set, and cap to `maxCount`.
    /// Returns [] for a mesh with no face ids (an optimized result) → the widget falls back
    /// to the six principal axes only.
    public func flatFaceNormals(maxCount: Int = 32, minFlatness: Float = 0.9,
                                minAreaFraction: Float = 0.02,
                                mergeAngleDeg: Float = 6) -> [FlatFace] {
        guard !faceIDs.isEmpty else { return [] }
        let vc = vertexCount
        func pos(_ i: UInt32) -> SIMD3<Float> {
            let b = Int(i) * 3
            return SIMD3<Float>(positions[b], positions[b + 1], positions[b + 2])
        }
        var accumVec: [Int32: SIMD3<Float>] = [:]
        var accumArea2: [Int32: Float] = [:]                     // Σ|cross| == 2 × area
        var t = 0
        while t + 2 < indices.count {
            let tri = t / 3
            if tri < faceIDs.count {
                let id = faceIDs[tri]
                let i0 = indices[t], i1 = indices[t + 1], i2 = indices[t + 2]
                if Int(i0) < vc, Int(i1) < vc, Int(i2) < vc {
                    let cr = simd_cross(pos(i1) - pos(i0), pos(i2) - pos(i0))
                    accumVec[id, default: .zero] += cr
                    accumArea2[id, default: 0] += simd_length(cr)
                }
            }
            t += 3
        }
        var faces: [FlatFace] = []
        for (id, vec) in accumVec {
            let vlen = simd_length(vec)
            let area2 = accumArea2[id] ?? 0
            guard vlen > 1e-9, area2 > 1e-9, vlen / area2 >= minFlatness else { continue }
            faces.append(FlatFace(normal: vec / vlen, faceID: id, area: vlen / 2))
        }
        guard let maxArea = faces.map(\.area).max(), maxArea > 0 else { return [] }
        faces = faces.filter { $0.area >= minAreaFraction * maxArea }
        faces.sort { $0.area > $1.area }
        let cosMerge = Foundation.cos(Double(mergeAngleDeg) * .pi / 180)
        var kept: [FlatFace] = []
        for f in faces {
            if kept.contains(where: { Double(simd_dot($0.normal, f.normal)) >= cosMerge }) { continue }
            kept.append(f)
            if kept.count >= maxCount { break }
        }
        return kept
    }

    /// The closest point on the mesh SURFACE to model-space point `p`, with that face's
    /// outward unit normal — or nil if nothing is within `maxDist`. This is the "magnet"
    /// behind the gravity arrow's movable base (round 2, item 2): as the base is dragged it
    /// attaches to the nearest face. O(triangles) per query — fine for the imported prismatic
    /// parts this runs on (a few thousand triangles); it is only called while the base is
    /// being dragged, never in the run path.
    public func nearestSurfacePoint(to p: SIMD3<Float>,
                                    within maxDist: Float) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard !indices.isEmpty else { return nil }
        let vc = vertexCount
        func pos(_ i: UInt32) -> SIMD3<Float> {
            let b = Int(i) * 3
            return SIMD3<Float>(positions[b], positions[b + 1], positions[b + 2])
        }
        var bestD2 = maxDist * maxDist
        var best: (SIMD3<Float>, SIMD3<Float>)?
        var t = 0
        while t + 2 < indices.count {
            let i0 = indices[t], i1 = indices[t + 1], i2 = indices[t + 2]
            t += 3
            guard Int(i0) < vc, Int(i1) < vc, Int(i2) < vc else { continue }
            let a = pos(i0), b = pos(i1), c = pos(i2)
            let q = MeshGeometry.closestPointOnTriangle(p, a, b, c)
            let d2 = simd_length_squared(q - p)
            if d2 < bestD2 {
                bestD2 = d2
                let n = simd_cross(b - a, c - a)
                let nl = simd_length(n)
                best = (q, nl > 1e-12 ? n / nl : SIMD3<Float>(0, 1, 0))
            }
        }
        return best
    }
}

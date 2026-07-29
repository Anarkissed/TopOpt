// FaceSelection.swift — the M7.5 face-pick + face-loop logic (GPU-free).
//
// Two pieces, both pure simd/array math so they are unit-tested headlessly (the
// M7 /app/ verification standard); the on-device Metal id-buffer pass mirrors the
// picker and is maintainer device QA (see MetalMeshView):
//
//   * FacePicker  — resolve a tapped screen point to the B-rep face id under it,
//     by ray-casting the tap through the OrbitCamera against the mesh triangles.
//     This is the CPU reference for the "render face ids to an offscreen target and
//     read back the tapped pixel" id-pass: same input (a pixel), same output (a
//     face id), so a test can pin a known pixel to the expected face id without a
//     GPU, and the device id-pass is checked against it.
//
//   * FaceTopology — the "tap inside a hole selects the hole's whole face loop"
//     walk. A hole is one or more *curved* (cylindrical/conical) B-rep faces; the
//     surrounding material is *planar*. Face adjacency and curvature are DERIVED
//     from the tessellation the bridge already exposes (per-triangle face ids +
//     the welded index buffer) — no bridge widening. Tapping a curved face walks
//     the connected run of curved faces (the whole tube, incl. a counterbore's
//     cylinder+cone) and stops at the planar faces bounding the hole; tapping a
//     planar face just selects that face. (A more robust classifier would use the
//     core's exact StepSurfaceKind, which the bridge does not forward today — see
//     the M7.5 handoff's recommendation.)

import Foundation
import simd

/// Ray-cast face picking against a `ViewerMesh` using the viewer's `OrbitCamera`.
public enum FacePicker {

    /// Resolve the B-rep face id under a normalized tap point.
    ///
    /// - Parameters:
    ///   - point: the tap in normalized view coordinates, x,y ∈ [0,1], origin at the
    ///     top-left (UIKit/tap convention: y grows downward).
    ///   - aspect: the view's width / height.
    /// - Returns: the face id of the nearest triangle the tap ray hits, or nil if the
    ///   ray misses the mesh or the mesh carries no face ids (an STL import).
    public static func pick(mesh: ViewerMesh, camera: OrbitCamera,
                            aspect: Float, point: CGPoint) -> FaceID? {
        guard let t = pickTriangle(mesh: mesh, camera: camera, aspect: aspect, point: point),
              t < mesh.faceIDs.count else { return nil }
        return mesh.faceIDs[t]
    }

    /// Resolve the index of the nearest triangle a normalized tap hits (face-id-
    /// agnostic, so it also works for an STL). Returns nil on a miss / empty mesh.
    public static func pickTriangle(mesh: ViewerMesh, camera: OrbitCamera,
                                    aspect: Float, point: CGPoint) -> Int? {
        guard !mesh.isEmpty else { return nil }
        let (origin, dir) = ray(camera: camera, aspect: aspect, point: point)

        var bestT = Float.greatestFiniteMagnitude
        var bestTri: Int? = nil
        let idx = mesh.indices
        var tri = 0
        var i = 0
        while i + 2 < idx.count {
            let p0 = position(idx[i], mesh)
            let p1 = position(idx[i + 1], mesh)
            let p2 = position(idx[i + 2], mesh)
            if let hit = rayTriangle(origin: origin, dir: dir, p0: p0, p1: p1, p2: p2),
               hit < bestT {
                bestT = hit
                bestTri = tri
            }
            i += 3
            tri += 1
        }
        return bestTri
    }

    /// The world-space ray (origin at the eye, unit direction) through a normalized
    /// tap point. Unprojects the near and far clip points and connects them.
    static func ray(camera: OrbitCamera, aspect: Float,
                    point: CGPoint) -> (origin: SIMD3<Float>, dir: SIMD3<Float>) {
        let ndcX = Float(point.x) * 2 - 1
        let ndcY = 1 - Float(point.y) * 2          // flip: tap y is down, NDC y is up
        let invVP = (camera.projectionMatrix(aspect: aspect) * camera.viewMatrix()).inverse
        let near = unproject(invVP, ndcX, ndcY, 0)  // Metal clip z ∈ [0,1]
        let far = unproject(invVP, ndcX, ndcY, 1)
        return (near, simd_normalize(far - near))
    }

    private static func unproject(_ invVP: simd_float4x4, _ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        let clip = SIMD4<Float>(x, y, z, 1)
        let w = invVP * clip
        return SIMD3<Float>(w.x, w.y, w.z) / w.w
    }

    private static func position(_ idx: UInt32, _ mesh: ViewerMesh) -> SIMD3<Float> {
        let b = Int(idx) * 3
        return SIMD3<Float>(mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2])
    }

    /// Möller–Trumbore ray/triangle intersection. Returns the ray parameter t (> 0)
    /// of the hit, or nil on a miss. Two-sided (no back-face cull) so a tap into a
    /// hole wall registers regardless of winding.
    static func rayTriangle(origin: SIMD3<Float>, dir: SIMD3<Float>,
                            p0: SIMD3<Float>, p1: SIMD3<Float>, p2: SIMD3<Float>) -> Float? {
        let eps: Float = 1e-7
        let e1 = p1 - p0
        let e2 = p2 - p0
        let pv = simd_cross(dir, e2)
        let det = simd_dot(e1, pv)
        if abs(det) < eps { return nil }           // ray parallel to triangle
        let inv = 1 / det
        let tv = origin - p0
        let u = simd_dot(tv, pv) * inv
        if u < 0 || u > 1 { return nil }
        let qv = simd_cross(tv, e1)
        let v = simd_dot(dir, qv) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = simd_dot(e2, qv) * inv
        return t > eps ? t : nil
    }
}

/// Derived B-rep face topology over a tessellated mesh: which faces are curved
/// (holes) and which faces are edge-adjacent, used for the hole face-loop walk.
public enum FaceTopology {

    /// Default angle (degrees) above which a face's triangle normals are considered
    /// to sweep — i.e. the face is curved (cylinder/cone), not planar.
    public static let curveThresholdDeg: Float = 5

    /// The distinct B-rep face ids present in the mesh (STL → empty).
    public static func faceIDs(in mesh: ViewerMesh) -> [FaceID] {
        Array(Set(mesh.faceIDs)).sorted()
    }

    /// The triangle indices belonging to a face.
    public static func triangles(ofFace face: FaceID, in mesh: ViewerMesh) -> [Int] {
        var out: [Int] = []
        for (t, f) in mesh.faceIDs.enumerated() where f == face { out.append(t) }
        return out
    }

    /// Whether a face is curved: some pair of its triangle normals differ by more
    /// than `thresholdDeg`. A planar face's normals are all (nearly) equal → false;
    /// a cylindrical hole wall's normals fan around the axis → true.
    public static func isCurved(_ face: FaceID, in mesh: ViewerMesh,
                                thresholdDeg: Float = curveThresholdDeg) -> Bool {
        let normals = faceTriangleNormals(face, in: mesh)
        guard normals.count > 1 else { return false }
        let cosThresh = cos(thresholdDeg * .pi / 180)
        for i in 0..<normals.count {
            for j in (i + 1)..<normals.count {
                if simd_dot(normals[i], normals[j]) < cosThresh { return true }
            }
        }
        return false
    }

    /// Every curved face in the mesh (the holes / fillets). For the l-bracket this
    /// is exactly the two Ø5 through-holes.
    public static func curvedFaceIDs(in mesh: ViewerMesh,
                                     thresholdDeg: Float = curveThresholdDeg) -> [FaceID] {
        faceIDs(in: mesh).filter { isCurved($0, in: mesh, thresholdDeg: thresholdDeg) }
    }

    // MARK: - fastener-bore predicate (auto-clearance, handoff 2026-07-29)

    /// Minimum angular WRAP (degrees) about a fitted bore axis for the face to
    /// count as a fastener through-hole rather than a rounded pocket-corner /
    /// chamfer arc. A through-hole encircles its axis (~360°); the widest non-hole
    /// concave arc measured across the mesh fixtures wrapped 198° (evidence
    /// 2026-07-29), so 300° separates real holes from misfits with a wide margin.
    public static let fastenerWrapMinDeg: Float = 300

    /// Whether `face` is an auto-clearance FASTENER BORE — the bore predicate the
    /// auto keep-clear rule, its chips, and its rendered volumes all read, REPLACING
    /// the old `isCurved` test (handoff 2026-07-29, clearance-heuristic-fix; PR 188
    /// diagnosis).
    ///
    /// `isCurved` (5° normal fan) marked ANY curved region a bore — pocket-corner
    /// blends, outer rounded edges, fillets, whole spheres — so a 290 mm truss shelf
    /// bracket with 3 bolt holes proposed 24 primitives, 8 of them BLANK (curved but
    /// not a fitted cylinder → no Auto radius to show) and several with absurd
    /// tens-to-hundreds-of-mm margins. A fastener bore is instead a face that is ALL
    /// of:
    ///   • a fitted CYLINDER with a real radius (`mesh.faceGeometry(face).isCylinder`)
    ///     — so a proposed bore ALWAYS has an Auto margin/axial: no blank rows (C2);
    ///   • CONCAVE — its wall faces the axis (a hole), not away from it (a boss, or a
    ///     round plate's OUTER rim, which a least-squares fit also reads as a cylinder
    ///     — e.g. the 22 mm filleted-plate rim `isCurved` mis-offered as a bolt hole);
    ///   • nearly FULLY WRAPPED about the axis (≥ `wrapMinDeg`) — a through-hole
    ///     encircles its axis; a rounded corner covers only a shallow arc.
    /// The three discriminators were measured to separate real holes from wall /
    /// corner misfits on every mesh fixture (evidence 2026-07-29). STL / optimized
    /// meshes carry no `faceGeometry` → never a bore (auto keep-clear stays a no-op,
    /// byte-identical). A hole the segmenter FRAGMENTS into sub-`wrapMinDeg` arcs (the
    /// PR-167 coarse-tessellation caveat) is left to the manual "+ primitive" escape
    /// hatch rather than loosening the gate into the false positives this fixes.
    public static func isFastenerBore(_ face: FaceID, in mesh: ViewerMesh,
                                      wrapMinDeg: Float = fastenerWrapMinDeg) -> Bool {
        guard let geo = mesh.faceGeometry(face), geo.isCylinder else { return false }
        let axisDir = SIMD3<Float>(geo.axisDir)
        guard simd_length(axisDir) > 1e-6 else { return false }
        let m = boreAxisMetrics(face, in: mesh, axisPoint: SIMD3<Float>(geo.axisPoint),
                                axisDir: simd_normalize(axisDir))
        return m.concave && m.wrapDeg >= wrapMinDeg
    }

    /// The angular WRAP (degrees, 0…360) a face's triangles cover about the axis ray
    /// (`axisPoint` + t·`axisDir`, `axisDir` UNIT) plus a CONCAVITY vote (majority of
    /// triangles whose geometric normal faces the axis). Pure geometry — the exact
    /// measure the diagnosis evidence (`analyze.cpp`) used, mirrored here so the app
    /// gate and the offline probe agree. A face with < 2 usable triangles wraps 0.
    static func boreAxisMetrics(_ face: FaceID, in mesh: ViewerMesh,
                                axisPoint: SIMD3<Float>, axisDir: SIMD3<Float>)
        -> (wrapDeg: Float, concave: Bool) {
        // A stable (u, v) basis spanning the plane perpendicular to the axis.
        let seed = abs(axisDir.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        var u = seed - axisDir * simd_dot(seed, axisDir)
        let lu = simd_length(u)
        u = lu > 1e-6 ? u / lu : SIMD3<Float>(1, 0, 0)
        let v = simd_normalize(simd_cross(axisDir, u))
        let idx = mesh.indices
        var angles: [Float] = []
        var concave = 0, convex = 0
        for t in triangles(ofFace: face, in: mesh) {
            let i = t * 3
            guard i + 2 < idx.count else { continue }
            let p0 = position(idx[i], mesh), p1 = position(idx[i + 1], mesh), p2 = position(idx[i + 2], mesh)
            let nRaw = simd_cross(p1 - p0, p2 - p0)
            let nl = simd_length(nRaw)
            guard nl > 1e-12 else { continue }              // degenerate: no normal
            let normal = nRaw / nl
            let centroid = (p0 + p1 + p2) / 3
            let rel = centroid - axisPoint
            angles.append(atan2(simd_dot(rel, v), simd_dot(rel, u)))
            let radial = rel - axisDir * simd_dot(rel, axisDir)     // component ⊥ axis
            let rl = simd_length(radial)
            if rl > 1e-9 {
                // normal toward the axis (opposite the outward radial) ⇒ concave (a hole).
                if simd_dot(normal, radial / rl) < 0 { concave += 1 } else { convex += 1 }
            }
        }
        guard angles.count > 1 else { return (0, false) }
        angles.sort()
        var maxGap: Float = 0
        for i in 1..<angles.count { maxGap = Swift.max(maxGap, angles[i] - angles[i - 1]) }
        maxGap = Swift.max(maxGap, (angles[0] + 2 * .pi) - angles[angles.count - 1])
        let wrapDeg = (2 * Float.pi - maxGap) * 180 / .pi
        return (wrapDeg, concave > convex)
    }

    /// Face-level edge adjacency: two faces are adjacent iff a triangle of one and a
    /// triangle of the other share a mesh edge (an undirected vertex-index pair).
    public static func adjacency(in mesh: ViewerMesh) -> [FaceID: Set<FaceID>] {
        // edge (min,max vertex index) → the set of distinct faces incident to it.
        var edgeFaces: [UInt64: Set<FaceID>] = [:]
        let idx = mesh.indices
        var tri = 0
        var i = 0
        while i + 2 < idx.count {
            guard tri < mesh.faceIDs.count else { break }
            let f = mesh.faceIDs[tri]
            let a = idx[i], b = idx[i + 1], c = idx[i + 2]
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let lo = UInt64(Swift.min(u, v)), hi = UInt64(Swift.max(u, v))
                edgeFaces[lo << 32 | hi, default: []].insert(f)
            }
            i += 3
            tri += 1
        }
        var adj: [FaceID: Set<FaceID>] = [:]
        for faces in edgeFaces.values where faces.count > 1 {
            for f in faces {
                adj[f, default: []].formUnion(faces.subtracting([f]))
            }
        }
        return adj
    }

    /// The face loop a tap resolves to. Tapping a *curved* face walks the connected
    /// run of curved faces reachable from it (the whole hole/tube), stopping at the
    /// planar faces around it; tapping a *planar* face selects just that face. The
    /// returned set always includes the tapped face and is sorted for determinism.
    ///
    /// For a single-face hole (e.g. every l-bracket hole) this returns just the
    /// tapped cylinder face — that face alone *is* the whole hole.
    ///
    /// The curved-face walk is a B-rep concept: OCCT can split one physical hole into
    /// several faces (a counterbore's cylinder + cone), which this reunites. It must
    /// NOT run on a mesh's PSEUDO-faces. The core dihedral segmenter never splits a
    /// hole across pseudo-faces — each segmented region already *is* the selection
    /// unit — so on a mesh the walk only unions the whole connected run of regions the
    /// app's own 5° `isCurved` happens to call "curved" (a bracket's strut, fillets and
    /// load region), which is the "one tap selects half the model" over-selection
    /// (handoff 2026-07-25-tap-overselect). For a pseudo-face mesh, a tap selects
    /// exactly the tapped face.
    public static func loop(fromFace face: FaceID, in mesh: ViewerMesh,
                            thresholdDeg: Float = curveThresholdDeg) -> [FaceID] {
        if mesh.pseudoFaces { return [face] }
        guard isCurved(face, in: mesh, thresholdDeg: thresholdDeg) else { return [face] }
        let adj = adjacency(in: mesh)
        var visited: Set<FaceID> = [face]
        var stack: [FaceID] = [face]
        while let f = stack.popLast() {
            for n in adj[f] ?? [] where !visited.contains(n) {
                if isCurved(n, in: mesh, thresholdDeg: thresholdDeg) {
                    visited.insert(n)
                    stack.append(n)
                }
            }
        }
        return visited.sorted()
    }

    // MARK: - internals

    /// The unit geometric normals of a face's triangles (degenerate → skipped).
    private static func faceTriangleNormals(_ face: FaceID, in mesh: ViewerMesh) -> [SIMD3<Float>] {
        let idx = mesh.indices
        var out: [SIMD3<Float>] = []
        for t in triangles(ofFace: face, in: mesh) {
            let i = t * 3
            guard i + 2 < idx.count else { continue }
            let p0 = position(idx[i], mesh)
            let p1 = position(idx[i + 1], mesh)
            let p2 = position(idx[i + 2], mesh)
            let n = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(n)
            if len > 1e-12 { out.append(n / len) }
        }
        return out
    }

    private static func position(_ idx: UInt32, _ mesh: ViewerMesh) -> SIMD3<Float> {
        let b = Int(idx) * 3
        return SIMD3<Float>(mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2])
    }
}

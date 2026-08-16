// FaceOffsetShell.swift — ★ A PRIMITIVE IS ALWAYS CREATED, AND ITS SHAPE IS THE
// SHAPE OF WHAT WAS SELECTED (task 2026-08-15-lattice-and-face-ui §2a/§2b).
//
// ★ HIS REPORT: "In many cases, when I press 'Lattice' on a face, NO PRIMITIVE
// APPEARS. It ALWAYS has to create a primitive. IF THERE ISN'T ONE MADE, IT IS
// BROKEN."
//
// ★ THE ROOT CAUSE, WITH FILE AND LINE. `ProjectModel.latticeDepthPlanes()` built
// the visible primitive as a bounded SLAB, and slabs need a plane:
//
//     ProjectModel.swift:925   guard ..., let geo = mesh.faceGeometry(f), geo.isPlane,
//                                    let outline = mesh.facePlaneOutline(...) else { continue }
//
// `isPlane` is `kind == .plane` (TopOptKit.swift:65). A cylinder or an `Other`
// surface fails the guard and is SILENTLY SKIPPED — no primitive, no refusal, no
// message. The region path has the same shape (ProjectModel.swift:1011 requires a
// member to be a plane before it contributes to the region's normal at all).
//
// ★ MEASURED ON HIS OWN PART (`lattice_primitive_probe`, evidence s0):
//
//     whole part          36 of 78 faces are planes; 42 (53.8%) DRAW NOTHING
//     his load group      3 of 22 declared faces get a primitive
//                         ★ 19 GET NOTHING — 86.4% of his own selection
//
// So "in many cases" is 86.4% of the faces he actually selected.
//
// ── THE RULE (§2b) ─────────────────────────────────────────────────────────────
//
// ★ THE PRIMITIVE IS THE ISOSURFACE OF DISTANCE-TO-THE-FACE AT THE DEPTH VALUE.
// Not a per-type special case — ONE rule, evaluated on the face's own
// tessellation:
//
//     PLANE     -> a slab            (every vertex moves along one normal)
//     CYLINDER  -> an annular tube   (every vertex moves radially: his "doughnut")
//     ANY OTHER -> a shell following the surface
//
// There is no `switch` on `kind` anywhere in this file, which is the point: the
// three rows above are what the ONE rule produces, not three branches.
//
// ★ AND IT CANNOT SELF-INTERSECT. A true surface offset folds on a CONCAVE face
// as soon as the depth exceeds the local radius of curvature — his arc will hit
// that. A distance field simply stops growing where the offset fronts meet, so
// this clamps each vertex's travel at the local feature size it measures from the
// face's own geometry (`curvatureLimitMM`). The clamp is REPORTED
// (`clampedFromMM`), never silent — §9(f)'s rule applied here.
//
// Pure value types over arrays: no view, no model, no Metal. The geometry rule is
// therefore headlessly testable, which is what `FaceOffsetShellTests` holds it to.

import Foundation
import simd

/// The primitive one face (or one region) casts into the part: the face's own
/// surface, and that surface pushed `depthMM` inward along the distance field.
public struct FaceOffsetShell: Equatable, Sendable {

    /// The surface as selected — the face's own tessellation, in model space.
    public let base: [SIMD3<Float>]
    /// The same points, moved inward. `offset[i]` corresponds to `base[i]`.
    public let offset: [SIMD3<Float>]
    /// Triangle corners, indexing BOTH arrays (they share one topology).
    public let indices: [UInt32]
    /// The depth actually reached, in mm — the requested depth unless the
    /// curvature clamp bound it.
    public let reachedDepthMM: Double
    /// The depth that was ASKED for, when the clamp bound it; nil when the shell
    /// reached the full requested depth. ★ Surfaced, never swallowed.
    public let clampedFromMM: Double?

    public init(base: [SIMD3<Float>], offset: [SIMD3<Float>], indices: [UInt32],
                reachedDepthMM: Double, clampedFromMM: Double? = nil) {
        self.base = base
        self.offset = offset
        self.indices = indices
        self.reachedDepthMM = reachedDepthMM
        self.clampedFromMM = clampedFromMM
    }

    public var isEmpty: Bool { indices.isEmpty }
    /// True when the curvature clamp bound the offset (§2b's concave case).
    public var wasClamped: Bool { clampedFromMM != nil }

    // MARK: - the builder

    /// ★ THE ONE RULE. Build the offset shell for a set of B-rep faces.
    ///
    /// `faces` may be one face (a face row) or many (a REGION — a union resolves
    /// to its members and they are offset together, so a union's primitive is the
    /// shape of the union, §2b).
    ///
    /// Returns nil ONLY when the faces contribute no triangles at all, which is
    /// the one honest failure: there is no surface to offset. Every other
    /// input — plane, cylinder, torus, spline, a mixed union — produces a shell.
    public static func build(faces: [FaceID], in mesh: ViewerMesh,
                             depthMM: Double) -> FaceOffsetShell? {
        let want = Swift.max(0, depthMM)
        let wanted = Set(faces.map { Int32($0) })
        guard !wanted.isEmpty, !mesh.indices.isEmpty else { return nil }

        // ── 1. gather the faces' own triangles, re-indexed compactly ────────────
        var remap: [UInt32: UInt32] = [:]
        var base: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        var triFace: [Int32] = []
        func vertex(_ i: UInt32) -> SIMD3<Float> {
            let b = Int(i) * 3
            return SIMD3<Float>(mesh.positions[b], mesh.positions[b + 1],
                                mesh.positions[b + 2])
        }
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            let owner: Int32 = tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1
            if wanted.contains(owner) {
                for k in 0..<3 {
                    let src = mesh.indices[t + k]
                    if let m = remap[src] {
                        idx.append(m)
                    } else {
                        let m = UInt32(base.count)
                        remap[src] = m
                        base.append(vertex(src))
                        idx.append(m)
                    }
                }
                triFace.append(owner)
            }
            t += 3
        }
        guard !idx.isEmpty else { return nil }

        // ── 2. the INWARD direction at each vertex ──────────────────────────────
        // Area-weighted mean of the incident triangle normals, then flipped to
        // point INTO the part — the same flip `LatticeRegionEmission.spec` makes,
        // so the primitive on screen is the region in the job.
        //
        // ★ THE DECLARED B-REP NORMAL WINS THE SIGN, and that is not a per-type
        // branch — the SHAPE rule is unchanged, this only orients it. Winding
        // alone is not safe here: the emission reads `StepFaceGeometry.planeNormal`
        // and a mesh whose winding disagrees with the declared normal would put
        // the picture on the opposite side of the wall from the region the run
        // actually freezes. When a face declares no normal (a cylinder, an
        // `Other`) the winding IS the answer and is used unchanged.
        var normal = [SIMD3<Float>](repeating: .zero, count: base.count)
        var i = 0
        while i + 2 < idx.count {
            let a = base[Int(idx[i])], b = base[Int(idx[i + 1])], c = base[Int(idx[i + 2])]
            // Un-normalized cross product IS the area weight.
            var n = simd_cross(b - a, c - a)
            let owner = triFace[i / 3]
            if let g = mesh.faceGeometry(owner) {
                let declared = SIMD3<Float>(g.planeNormal)
                if simd_length(declared) > 1e-9, simd_dot(n, declared) < 0 { n = -n }
            }
            for k in 0..<3 { normal[Int(idx[i + k])] += n }
            i += 3
        }
        for k in 0..<normal.count {
            let l = simd_length(normal[k])
            normal[k] = l > 1e-9 ? -(normal[k] / l) : SIMD3<Float>(0, 0, 0)
        }

        // ── 3. the curvature clamp (§2b — it cannot self-intersect) ─────────────
        let limit = curvatureLimitMM(base: base, inward: normal, indices: idx)
        let reached = limit > 0 ? Swift.min(want, limit) : want
        let clamped = reached < want - 1e-9 ? want : nil

        var out = [SIMD3<Float>](repeating: .zero, count: base.count)
        for k in 0..<base.count { out[k] = base[k] + normal[k] * Float(reached) }

        return FaceOffsetShell(base: base, offset: out, indices: idx,
                               reachedDepthMM: reached, clampedFromMM: clamped)
    }

    /// ★ HOW FAR THE OFFSET MAY TRAVEL BEFORE THE FRONTS MEET.
    ///
    /// On a CONVEX surface the offset fronts spread apart and any depth is safe.
    /// On a CONCAVE one they converge, and they meet at the local radius of
    /// curvature — which is exactly where a distance field stops growing and where
    /// a naive surface offset folds through itself.
    ///
    /// The estimate is per-EDGE and conservative. For an edge (a,b) whose inward
    /// normals differ, the fronts converge at
    ///
    ///     r  =  |b - a|  /  |n_b - n_a|
    ///
    /// (the discrete radius of curvature: arc length over turned angle, to first
    /// order). Only CONCAVE edges are counted — an edge whose normals diverge as
    /// you move inward cannot pinch — and the minimum over them is the limit.
    /// Returns 0 when nothing binds, meaning "no limit".
    static func curvatureLimitMM(base: [SIMD3<Float>], inward: [SIMD3<Float>],
                                 indices: [UInt32]) -> Double {
        var limit = Double.greatestFiniteMagnitude
        var i = 0
        while i + 2 < indices.count {
            let e = [(indices[i], indices[i + 1]), (indices[i + 1], indices[i + 2]),
                     (indices[i + 2], indices[i])]
            for (ia, ib) in e {
                let a = base[Int(ia)], b = base[Int(ib)]
                let na = inward[Int(ia)], nb = inward[Int(ib)]
                let d = b - a
                let len = Double(simd_length(d))
                guard len > 1e-6 else { continue }
                let dn = nb - na
                let turn = Double(simd_length(dn))
                guard turn > 1e-6 else { continue }   // flat: never pinches
                // CONCAVE iff the normals converge along the edge: moving from a
                // to b, the inward direction turns TOWARD the edge.
                guard Double(simd_dot(dn, d)) < 0 else { continue }
                limit = Swift.min(limit, len / turn)
            }
            i += 3
        }
        return limit == .greatestFiniteMagnitude ? 0 : limit
    }
}

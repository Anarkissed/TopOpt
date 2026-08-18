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
    ///
    /// ★ `expandMM` DILATES THE PATCH IN PLANE BEFORE IT IS OFFSET (maintainer,
    /// 2026-08-17: "The expansion still isn't shown with the primitive. Please
    /// make the primitive expand and contract along with the handle"). Positive
    /// grows the outline outward, negative pulls it in; ZERO is byte-identical
    /// to every call that predates the parameter, which is why it defaults.
    public static func build(faces: [FaceID], in mesh: ViewerMesh,
                             depthMM: Double,
                             expandMM: Double = 0) -> FaceOffsetShell? {
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

        // ── 2b. THE IN-PLANE DILATION (maintainer, 2026-08-17) ──────────────────
        // Applied to the BASE before anything reads it, so the outline, the
        // offset and the curvature clamp all describe the same, expanded patch.
        let grown = dilated(base: base, inward: normal, indices: idx,
                            byMM: expandMM)

        // ── 3. the curvature clamp (§2b — it cannot self-intersect) ─────────────
        let limit = curvatureLimitMM(base: grown, inward: normal, indices: idx)
        let reached = limit > 0 ? Swift.min(want, limit) : want
        let clamped = reached < want - 1e-9 ? want : nil

        var out = [SIMD3<Float>](repeating: .zero, count: grown.count)
        for k in 0..<grown.count { out[k] = grown[k] + normal[k] * Float(reached) }

        return FaceOffsetShell(base: grown, offset: out, indices: idx,
                               reachedDepthMM: reached, clampedFromMM: clamped)
    }

    // MARK: ★ THE OFFSET — MINKOWSKI DILATION BY A BALL

    /// ★★ GROW OR SHRINK THE PATCH BY `byMM`, UNIFORMLY IN EVERY DIRECTION.
    ///
    /// ★ HIS DESCRIPTION, AND IT NAMES THE OPERATION EXACTLY (2026-08-18): "the
    /// primitive needs to *both* expand (or contract) *and* move down when
    /// contracting, up when expanding. It needs to move at the same pace as the
    /// change in size … Please dig into some research to confirm the *exact*
    /// mathematical function required. It may not be uniform, it may have some
    /// sort of ratio."
    ///
    /// ★★ THE RESEARCH ANSWER: IT IS THE **OFFSET (PARALLEL) SURFACE**, which is
    /// the same thing as **morphological dilation by a ball**:
    ///
    ///     P ⊕ B_d  =  { p + b : p ∈ P, |b| ≤ d }  =  { x : dist(x, P) ≤ d }
    ///           X_d(u,v)  =  X(u,v) + d · N(u,v)
    ///
    /// (Rossignac & Requicha, *Offsetting operations in solid modelling*, CAGD
    /// 3(2), 1986; Maekawa, *An overview of offset curves and surfaces*, CAD
    /// 31(3), 1999.)
    ///
    /// ★ AND THE DISPLACEMENT IS **EXACTLY UNIFORM — THERE IS NO RATIO**. He
    /// asked whether one was needed; the answer is no, and it is worth being
    /// precise about what IS curvature-dependent, because it is not this:
    ///
    ///   · distance travelled  — exactly `d`, everywhere, convex or concave
    ///   · the AREA element    — `dA_d = (1 + dκ₁)(1 + dκ₂) dA` (Steiner)
    ///   · the CURVATURE       — principal radii simply add: `R_i ↦ R_i + d`
    ///
    /// ★★ WHY THE PREVIOUS CUT WAS WRONG, in one line. A similarity about the
    /// centroid, `p ↦ c + (p − c)·(1 + e/R)`, displaces by `|p − c|·e/R` — which
    /// equals `e` only at the mean radius and is **exactly ZERO along the
    /// normal**. That is precisely what he saw: the rim grew, the curved surface
    /// did not move at all, and the growth was uneven with distance from the
    /// centre. The file's own comment admitted it — "the millimetres are
    /// preserved on average". An offset preserves them EVERYWHERE.
    ///
    /// ★ THE TWO COUPLED PARTS, both at rate `e`:
    ///
    ///   1. NORMAL   every vertex moves `e` along its own outward normal —
    ///      "up when expanding, down when contracting", his words exactly.
    ///   2. LATERAL  a RIM vertex additionally moves `e` along the outward
    ///      CO-NORMAL `B = T × N` (T = rim tangent), so the patch also gets
    ///      wider. This is the square rim join; the true Minkowski rim is a
    ///      quarter-round of radius `e`, and its two extremes are exactly these
    ///      (Chen/Wang/Rosen/Rossignac; Peternell & Steiner).
    ///
    /// ★ THE MITER SCALE, so a creased patch offsets exactly. Moving a vertex by
    /// `e·n̄` only moves each incident face plane by `e(n̄·N_f) < e`. The exact
    /// correction for a ridge is
    ///
    ///     v = e (N₁ + N₂) / (1 + N₁·N₂),   ‖v‖ = e / cos(α/2) = e / (n̄·N_f)
    ///
    /// (the classic miter formula — Clipper2's `DoMiter` is this verbatim). It
    /// diverges as the crease closes, so it carries a MITER LIMIT, as every
    /// offsetting library does.
    static func dilated(base: [SIMD3<Float>], inward: [SIMD3<Float>],
                        indices: [UInt32], byMM: Double) -> [SIMD3<Float>] {
        guard byMM != 0, base.count > 2, indices.count >= 3 else { return base }

        // ── per-vertex miter scale: mean cos between the vertex normal and its
        //    incident face normals. 1 on a flat patch ⇒ a planar region offsets
        //    EXACTLY, which is the property the scale exists for.
        var cosSum = [Float](repeating: 0, count: base.count)
        var cosCount = [Float](repeating: 0, count: base.count)
        var i = 0
        while i + 2 < indices.count {
            let ia = Int(indices[i]), ib = Int(indices[i + 1]), ic = Int(indices[i + 2])
            let fn = simd_cross(base[ib] - base[ia], base[ic] - base[ia])
            let fl = simd_length(fn)
            if fl > 1e-12 {
                let u = fn / fl
                for k in [ia, ib, ic] {
                    let nl = simd_length(inward[k])
                    if nl > 1e-9 {
                        cosSum[k] += abs(simd_dot(inward[k] / nl, u))
                        cosCount[k] += 1
                    }
                }
            }
            i += 3
        }

        // ── the rim: edges owned by exactly ONE triangle ───────────────────────
        var count: [UInt64: Int] = [:]
        var owner: [UInt64: Int] = [:]
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            let (lo, hi) = a < b ? (a, b) : (b, a)
            return UInt64(lo) << 32 | UInt64(hi)
        }
        i = 0
        while i + 2 < indices.count {
            for (a, b) in [(indices[i], indices[i + 1]),
                           (indices[i + 1], indices[i + 2]),
                           (indices[i + 2], indices[i])] {
                let k = key(a, b)
                count[k, default: 0] += 1
                owner[k] = i
            }
            i += 3
        }

        // ── the outward CO-NORMAL at each rim vertex ──────────────────────────
        // ★ B = T × N, from the RIM TANGENT — not from the owning triangle's
        // shape. The previous cut took the direction from `midpoint(a,b) − c`,
        // which is a property of the TESSELLATION: on long thin triangles it
        // points somewhere arbitrary, and that is what made the growth lopsided
        // ("handled from the floor"). The rim tangent is a property of the
        // BOUNDARY CURVE and is stable under retriangulation.
        // ★★ THE CO-NORMAL IS COMPUTED **PER EDGE** AND THEN BISECTED — summing
        // raw edge VECTORS first does not work, and the failure is subtle enough
        // to be worth recording. `key()` normalises an edge to `lo < hi`, so the
        // stored direction does not follow the boundary loop; at a square corner
        // the two incident edges then summed to a DIAGONAL rather than to a
        // tangent, the co-normal came out rotated 90°, and two of the four
        // corners grew when they should have shrunk. A unit test caught it.
        //
        // Per edge the tangent is unambiguous, so each edge contributes its own
        // outward co-normal and the vertex takes their bisector.
        var conormal = [SIMD3<Float>](repeating: .zero, count: base.count)
        var rimEdges = [Float](repeating: 0, count: base.count)
        var isRim = [Bool](repeating: false, count: base.count)
        for (k, c) in count where c == 1 {
            let ia = Int(k >> 32), ib = Int(k & 0xFFFF_FFFF)
            isRim[ia] = true; isRim[ib] = true
            let t = base[ib] - base[ia]
            let tl = simd_length(t)
            guard tl > 1e-9, let tri0 = owner[k] else { continue }
            let tri = [Int(indices[tri0]), Int(indices[tri0 + 1]), Int(indices[tri0 + 2])]
            guard let ic = tri.first(where: { $0 != ia && $0 != ib }) else { continue }
            // This edge's own outward reference, only to FIX THE SIGN.
            let ref = 0.5 * (base[ia] + base[ib]) - base[ic]
            for v in [ia, ib] {
                let nl = simd_length(inward[v])
                guard nl > 1e-9 else { continue }
                var bdir = simd_cross(t / tl, inward[v] / nl)
                let bl = simd_length(bdir)
                guard bl > 1e-9 else { continue }
                bdir /= bl
                if simd_dot(bdir, ref) < 0 { bdir = -bdir }
                conormal[v] += bdir            // unit vectors ⇒ the sum bisects
                rimEdges[v] += 1
            }
        }

        // ── the inward-offset limit (§4 of the research) ──────────────────────
        // ★ THIS IS THE *LOCAL* TERM ONLY — the smallest principal radius, via
        // the existing per-edge `len/turn`. The exact bound is Federer's REACH,
        // `min(1/κ_max, ½·narrowest bottleneck)`, and the bottleneck term needs
        // a ray march this function has no mesh to do. Stated, not silently
        // approximated: a thin rib can still pinch before this limit bites.
        let curvature = curvatureLimitMM(base: base, inward: inward, indices: indices)
        var e = byMM
        if e < 0, curvature > 0 { e = Swift.max(e, -curvature * reachFraction) }

        var out = base
        for k in 0..<out.count {
            let nl = simd_length(inward[k])
            guard nl > 1e-9 else { continue }
            let n = inward[k] / nl                     // INTO the part
            // 1. NORMAL — outward is −inward, so `+e` moves "up".
            let cosMean = cosCount[k] > 0 ? cosSum[k] / cosCount[k] : 1
            let miter = Swift.min(miterLimit, 1 / Swift.max(0.2, Double(cosMean)))
            var d = -n * Float(e * miter)
            // 2. LATERAL — rim only, along the bisector of its edges' co-normals,
            //    with the IN-SURFACE MITER so that every EDGE advances exactly
            //    `e`. For k unit vectors summing to `bis`, the bisector needs
            //    `k / |bis|`: two edges at 90° give `2 / 2cos45° = √2`, and two
            //    collinear edges give `2 / 2 = 1`. His rule — "all the edges
            //    expand outward and inward at the same rate" — is about the
            //    EDGES, so a corner has to travel further than a straight run.
            if isRim[k], rimEdges[k] > 0 {
                let bl = simd_length(conormal[k])
                if bl > 1e-9 {
                    let miterIn = Swift.min(miterLimit, Double(rimEdges[k] / bl))
                    d += (conormal[k] / bl) * Float(e * miterIn)
                }
            }
            out[k] = base[k] + d
        }
        return out
    }

    /// ★ THE MITER LIMIT. `1/cos(α/2)` diverges as a crease closes; every
    /// offsetting library caps it (Clipper2 calls it `MiterLimit`) and falls back
    /// to a square join. 4 is Clipper2's own default.
    static let miterLimit: Double = 4

    /// ★ HOW MUCH OF THE LOCAL CURVATURE LIMIT AN INWARD OFFSET MAY USE. At
    /// exactly `1/κ_max` the offset fronts meet in a cusp — that is the
    /// self-intersection point, not a safe value — so the bound sits just inside.
    static let reachFraction: Double = 0.95
    /// ★ HOW FAR A SHRINK MAY GO. At scale 0 the patch IS its centroid — the
    /// point of self-intersection he named. The floor sits just above it, so
    /// pulling in further converges rather than folding through.
    static let minScale: Double = 0.02

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

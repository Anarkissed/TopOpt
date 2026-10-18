// FlexibleFlatPrism — the edge/corner FLAT PRISM (task 2026-09-29-flexible-screens, round 7 batch R7-E1). His words, 2026-10-18
// (binding): "There should be a prism that the user can drag to show how far it can squish in … It should also be able to be
// angled up or down based on the user's choice." and, ~15:10: "There shouldn't be a strip width. It should be a Flat prism that
// gets wider as it gets dragged further towards the centre of the model from the edge. We should be able to change the angle
// up/down and left/right of the prism. With this, there is no need for a strip width." His answers: LEFT/RIGHT = a TWIST along
// the edge (one end deeper); a corner = the same flat cut across the corner (a triangle on each face); the twist stops when the
// shallow end reaches 0 mm; the half-face rule is DROPPED — the flat prism goes as deep as the lattice allows, as long as each
// face keeps some of itself.
//
// ★ THE OBJECT: ONE FLAT PLANE (a chamfer). The arrow d is the plane's normal and the press's direction (press.direction, AP1:
// stored bit for bit, core's press_direction); h is the deepest squish (press.settings.deepestMM, the job's deepest_squish_mm).
// The plane is P = {p : dot(p − A, d) = h}, A the APEX: a corner's vertex, an edge's end with the least dot(p, d) (an untwisted
// edge: its start, so the bits are stable). What is pressed on each member face is the face ∩ {dot(p − A, d) ≤ h} — so the
// footprint on each face (the old "strip") is IMPLIED by d and h: deeper is wider on every face.
// ★ THE CUT LIES IN EACH MEMBER'S OWN FACE (the design's choice B): core and the bridge test a region's cuts at VOXEL CENTRES
// (passes_cuts), so a 3D cut with normal −d would move each face's slab boundary by up to half a voxel. The in-face cut —
// t_i = d − dot(d, n_i)·n_i, RegionCut(point: A + t_i·h/|t_i|², normal: −t_i/|t_i|) — is the same line on the surface (A lies in
// every member's plane) and is the Surface tool's own kind of cut.
// ★ ONE SOURCE: CORE. Every normal here comes from the strip's members, which strip(for:) built from core's inward normals and
// centroids; the halfway is core's (loadEdgePick's pressAim over the WHOLE member faces, stored as FlexibleStrip.halfway). No
// frame, column, design or squish of the press is computed here: the lattice cap reads core's press stack (`latticeCap`).
// ★ A STRIP SAVED WITH A WIDTH (M2's form, FlexibleStrip.widthMM) READS THROUGH (`depth(of:)`): h = widthMM × min dot(a_i, d0)
// (a corner: min dot(e_j, d0)) — the same reach on each face of a box edge — and keeps its own half-spaces, bit for bit, until
// his next edit of that press writes the flat form (`isLegacy`, `planCut`).

import Foundation
import simd
import TopOptKit

public enum FlexibleFlatPrism {

    /// The plane: its apex A, its normal d (the arrow, into the part) and its depth h past A.
    public struct Cut: Equatable, Hashable, Sendable {
        public var apex: SIMD3<Double>
        public var direction: SIMD3<Double>
        public var depthMM: Double
        public init(apex: SIMD3<Double>, direction: SIMD3<Double>, depthMM: Double) {
            self.apex = apex; self.direction = direction; self.depthMM = depthMM
        }
        /// How far a point is past the apex along the arrow: 0 at the apex, h on the plane.
        public func height(_ p: SIMD3<Double>) -> Double { simd_dot(p - apex, direction) }
        /// `p` carried along the arrow onto the plane.
        public func onPlane(_ p: SIMD3<Double>) -> SIMD3<Double> { p + direction * (depthMM - height(p)) }
    }

    /// The shallowest a flat prism goes (FlexibleDepthPrism.minMM).
    public static let minDepthMM = 0.5
    /// ★ A new pick's depth (a face's default deepest squish — the design's §16 default, told to him).
    public static let defaultDepthMM = 3.0
    /// ★ HIS ANSWER (the half-face rule dropped): each face keeps SOME of itself — at least this much beyond the cut.
    public static let restMarginMM = 0.5
    /// ★ RED CONTROL only (FlexibleFlatPrismTests): no convexity rule — an inside edge or corner is offered.
    nonisolated(unsafe) static var controlNoConvexity = false
    /// ★ RED CONTROL only: the cut drawn as one 3D plane per member (normal −d), not in each face.
    nonisolated(unsafe) static var controlThreeDCut = false

    // MARK: - a member's planes

    /// A member's face-plane normal, sign-free (from its in-face directions, which strip(for:) took from core's normal).
    public static func planeNormal(_ m: FlexibleStrip.Member) -> SIMD3<Double>? {
        if let e = m.along, let a = m.away.first { return FlexiblePressAim.unit(simd_cross(e, a)) }
        if m.away.count >= 2 { return FlexiblePressAim.unit(simd_cross(m.away[0], m.away[1])) }
        if let es = m.edges, es.count >= 2 { return FlexiblePressAim.unit(simd_cross(es[0], es[1])) }
        return nil
    }

    /// A member's INWARD normal: its plane normal on the side `d` points (d presses into every member of a convex pick).
    public static func inwardNormal(_ m: FlexibleStrip.Member, toward d: SIMD3<Double>) -> SIMD3<Double>? {
        guard let n = planeNormal(m) else { return nil }
        return simd_dot(n, d) >= 0 ? n : SIMD3<Double>.zero - n
    }

    /// A corner member's two edge directions from the corner: stored (`edges`, strip(for:)'s `dirs`), or — a corner saved
    /// before them — each one ⟂ its away direction in the face, toward the other.
    public static func edges(_ m: FlexibleStrip.Member) -> [SIMD3<Double>] {
        if let e = m.edges, e.count == 2 { return e }
        guard m.away.count == 2, let n = planeNormal(m) else { return [] }
        return (0..<2).compactMap { i -> SIMD3<Double>? in
            guard var e = FlexiblePressAim.unit(simd_cross(n, m.away[i])) else { return nil }
            if simd_dot(e, m.away[1 - i]) < 0 { e = SIMD3<Double>.zero - e }
            return e
        }
    }

    /// A corner's edge directions from its vertex (each once).
    public static func cornerEdges(_ s: FlexibleStrip) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        for m in s.members {
            for e in edges(m) where !out.contains(where: { simd_length(simd_cross($0, e)) < 1e-6 && simd_dot($0, e) > 0 }) { out.append(e) }
        }
        return out
    }

    /// An edge's line: its start, its unit direction, where the candidate starts and stops along it (mm).
    public static func line(_ s: FlexibleStrip) -> (origin: SIMD3<Double>, dir: SIMD3<Double>, s0: Double, s1: Double)? {
        guard s.kind == .edge, let m = s.members.first, let e = m.along, let sp = m.span, sp.count == 2 else { return nil }
        return (m.origin, e, sp[0], sp[1])
    }

    /// An edge's length (0 for a corner).
    public static func length(_ s: FlexibleStrip) -> Double { line(s).map { $0.s1 - $0.s0 } ?? 0 }

    // MARK: - the plane

    /// ★ THE APEX: a corner's vertex; an edge's end with the least dot(p, d) — an untwisted edge (a tie within 1e-9 of its
    /// length) its start, so an untwisted cut's bits never move.
    public static func apex(_ s: FlexibleStrip, direction d: SIMD3<Double>) -> SIMD3<Double> {
        guard let l = line(s) else { return s.members.first?.origin ?? .zero }
        let p0 = l.origin + l.dir * l.s0
        let k = simd_dot(l.dir, d) * (l.s1 - l.s0)   // dot(end − start, d)
        if Swift.abs(k) <= 1e-9 * Swift.max(1, l.s1 - l.s0) { return l.s0 == 0 ? l.origin : p0 }
        return k > 0 ? p0 : l.origin + l.dir * l.s1
    }

    /// The plane of a strip along `direction`, `depthMM` past its apex.
    public static func cut(_ s: FlexibleStrip, direction: SIMD3<Double>, depthMM: Double) -> Cut {
        Cut(apex: apex(s, direction: direction), direction: direction, depthMM: depthMM)
    }

    // MARK: - the one accessor (every route reads h and d through it)

    /// The halfway the arrow starts at and snaps back to: core's, over the WHOLE member faces, stored at pick time — or, a
    /// strip saved before it (M2), the press's own direction while its snap kind is "halfway".
    public static func halfway(of p: FlexiblePress) -> SIMD3<Double>? {
        guard let s = p.strip else { return nil }
        if let h = s.halfway { return h }
        return p.snapTarget == .halfway ? p.direction : nil
    }

    /// A strip still saved with M2's width (read through until his next edit of that press writes the flat form).
    public static func isLegacy(_ p: FlexiblePress) -> Bool { p.strip?.widthMM != nil }

    /// ★ M2's width READ THROUGH as a depth: h = widthMM × min dot(a_i, d0) (a corner: min dot(e_j, d0)) — the narrower implied
    /// reach is the old width (on a box edge or corner: every face's). nil without a width or a direction into every face.
    public static func legacyDepth(_ s: FlexibleStrip, d0: SIMD3<Double>) -> Double? {
        guard let w = s.widthMM else { return nil }
        let dots: [Double] = s.kind == .corner ? cornerEdges(s).map { simd_dot($0, d0) }
            : s.members.compactMap { m in m.away.first.map { simd_dot($0, d0) } }
        guard let least = dots.min(), least > 0 else { return nil }
        return w * least
    }

    /// ★ THE DEPTH h of a strip press: its deepest squish — or, saved with M2's width, the width read through.
    public static func depth(of p: FlexiblePress) -> Double? {
        guard let s = p.strip else { return nil }
        if s.widthMM != nil { return legacyDepth(s, d0: halfway(of: p) ?? p.direction) }
        return p.settings.deepestMM
    }

    /// ★ THE ONE ACCESSOR: (A, d, h) of a strip press (nil: a press with no strip).
    public static func cut(of p: FlexiblePress) -> Cut? {
        guard let s = p.strip, let h = depth(of: p) else { return nil }
        return cut(s, direction: p.direction, depthMM: h)
    }

    /// What the plan and the sectors cut a press with: its plane — nil for a strip saved with M2's width, which keeps its own
    /// half-spaces bit for bit until his next edit of it (the M2 migration's "the same cuts, bit for bit").
    public static func planCut(of p: FlexiblePress) -> Cut? { isLegacy(p) ? nil : cut(of: p) }

    // MARK: - the cut per member

    /// ★ THE CUT ON EACH MEMBER, IN ITS OWN FACE: the line P ∩ face, kept on the apex's side — and an edge's span caps (where the
    /// candidate starts and stops along it, as before). On a flat member this is exactly P ∩ face.
    public static func memberCuts(_ s: FlexibleStrip, _ c: Cut) -> [[RegionCut]] {
        s.members.map { m in
            var out: [RegionCut] = []
            if controlThreeDCut {
                out.append(RegionCut(point: c.apex + c.direction * c.depthMM, normal: SIMD3<Double>.zero - c.direction))
            } else if let n = planeNormal(m) {
                let t = c.direction - simd_dot(c.direction, n) * n
                let tt = simd_dot(t, t)
                if tt > 1e-18 {
                    out.append(RegionCut(point: c.apex + t * (c.depthMM / tt), normal: SIMD3<Double>.zero - t / tt.squareRoot()))
                }
            }
            if let e = m.along, let sp = m.span, sp.count == 2 {
                out.append(RegionCut(point: m.origin + e * sp[0], normal: e))
                out.append(RegionCut(point: m.origin + e * sp[1], normal: SIMD3<Double>.zero - e))
            }
            return out
        }
    }

    /// The cuts the plan and the sectors lay: the plane's (`cut`), or — nil, a strip saved with M2's width — its old half-spaces.
    public static func pieceCuts(_ s: FlexibleStrip, cut: Cut?) -> [[RegionCut]] {
        if let c = cut { return memberCuts(s, c) }
        return s.members.map { FlexibleEdgeStrips.legacyHalfSpaces($0, width: s.widthMM ?? 0) }
    }

    /// The in-face direction the cut line moves along on member `m` as the plane goes deeper (unit), or nil (edge-on).
    public static func inFace(_ m: FlexibleStrip.Member, _ d: SIMD3<Double>) -> SIMD3<Double>? {
        guard let n = planeNormal(m) else { return nil }
        return FlexiblePressAim.unit(d - simd_dot(d, n) * n)
    }

    // MARK: - the implied reach

    /// ★ THE IMPLIED REACH on member `k`: an edge's at `along` mm from its line's start (nil: at the apex — the most), w_i =
    /// (h − dot(E − A, d)) / dot(a_i, d); a corner's leg along each of its edges, h / dot(e_j, d) (the least of its two).
    public static func reach(_ s: FlexibleStrip, member k: Int, _ c: Cut, along: Double? = nil) -> Double? {
        guard k < s.members.count else { return nil }
        let m = s.members[k]
        if s.kind == .corner {
            let legs = edges(m).map { e -> Double in
                let de = simd_dot(e, c.direction)
                return de > 0 ? c.depthMM / de : .infinity
            }
            return legs.min()
        }
        guard let a = m.away.first, let l = line(s) else { return nil }
        let da = simd_dot(a, c.direction)
        guard da > 0 else { return .infinity }
        let at = along.map { l.origin + l.dir * $0 } ?? c.apex
        return (c.depthMM - c.height(at)) / da
    }

    // MARK: - what is drawn

    /// A face's triangles clipped by the member's cuts: the footprint on that face.
    public static func footprint(_ tris: [[SIMD3<Double>]], _ cuts: [RegionCut]) -> [[SIMD3<Double>]] {
        tris.map { FlexibleMeet.clipPolygon($0, cuts) }.filter { $0.count >= 3 && FlexibleMeet.area($0) > 1e-12 }
    }

    /// The TRACE: the footprint's edges lying on the plane (the dashed line on each face).
    public static func traces(_ polys: [[SIMD3<Double>]], _ c: Cut, tolerance: Double = 1e-6) -> [[SIMD3<Double>]] {
        var out: [[SIMD3<Double>]] = []
        for p in polys where p.count >= 2 {
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                guard simd_distance(a, b) > 1e-6, Swift.abs(c.height(a) - c.depthMM) < tolerance,
                      Swift.abs(c.height(b) - c.depthMM) < tolerance else { continue }
                out.append([a, b])
            }
        }
        return out
    }

    /// ★ THE WEDGE, TRUE SIZE (× 1): base = the footprints (welded at 1 µm), offset = each base point carried along the arrow
    /// onto the plane — so the rim (on the plane already) is its own offset and the flat face is the plane. nil when empty.
    public static func wedge(_ polys: [[SIMD3<Double>]], _ c: Cut) -> FaceOffsetShell? {
        struct K: Hashable { let x: Int64, y: Int64, z: Int64 }
        var index: [K: UInt32] = [:]
        var base: [SIMD3<Float>] = [], offset: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        func vertex(_ p: SIMD3<Double>) -> UInt32 {
            let q = (p / 0.001).rounded(.toNearestOrEven)
            let k = K(x: Int64(q.x), y: Int64(q.y), z: Int64(q.z))
            if let i = index[k] { return i }
            let i = UInt32(base.count)
            index[k] = i
            base.append(SIMD3<Float>(p))
            offset.append(SIMD3<Float>(c.onPlane(p)))
            return i
        }
        var deepest = 0.0
        for poly in polys where poly.count >= 3 {
            let v = poly.map(vertex)
            for p in poly { deepest = Swift.max(deepest, c.depthMM - c.height(p)) }
            for j in 1..<(v.count - 1) where v[0] != v[j] && v[j] != v[j + 1] && v[0] != v[j + 1] { idx += [v[0], v[j], v[j + 1]] }
        }
        guard !idx.isEmpty, deepest > 1e-6 else { return nil }
        return FaceOffsetShell(base: base, offset: offset, indices: idx, reachedDepthMM: deepest)
    }

    // MARK: - what can have a flat prism

    /// ★ CONVEX ONLY: an edge needs dot(a_i, d0) > 0 on both faces, a corner dot(e_j, d0) > 0 on all three edges — on an inside
    /// edge or corner the half-space would swallow the whole face. nil when it can; else the one line.
    public static func convexityLine(_ s: FlexibleStrip, d0: SIMD3<Double>) -> String? {
        guard !controlNoConvexity else { return nil }
        if s.kind == .corner {
            let es = cornerEdges(s)
            if es.contains(where: { simd_dot($0, d0) <= 0 }) { return FlexibleRowCopy.insideCorner }
            return nil
        }
        if s.members.contains(where: { ($0.away.first.map { simd_dot($0, d0) } ?? 0) <= 0 }) { return FlexibleRowCopy.insideEdge }
        return nil
    }

    /// ★ HIS RULE (the half-face rule dropped): does member `m`'s face keep some of itself — at least `restMarginMM` beyond the
    /// cut somewhere — under plane `c`? `tris`: the face's triangles.
    public static func keepsRest(_ tris: [[SIMD3<Double>]], member m: FlexibleStrip.Member, _ c: Cut) -> Bool {
        guard let t = inFace(m, c.direction) else { return true }
        let dt = simd_dot(t, c.direction)
        guard dt > 1e-12 else { return true }
        // the cut line in the face: dot(p − A, t) = h / dt·|t|… — the point on it nearest A, then the margin beyond
        let onLine = c.apex + t * (c.depthMM / dt)
        let beyond = RegionCut(point: onLine + t * restMarginMM, normal: t)
        return FlexibleEdgeStrips.area(tris, [beyond]) > 1e-6
    }

    // MARK: - the lattice the plane may press (core's press stack)

    /// ★ THE LATTICE CAP from core's registered press stack: h ≤ min over its columns of (lattice_k + entry_t_k − t_A), t_A the
    /// apex's t in core's press frame (core's to_uvt): the squish target per column δ_k = (t_A + h) − entry_t_k then stays within
    /// the lattice that column starts in. lattice_k is the run CONTIGUOUS from the entry (FlexStackInfo.latticeRunMM — core's own
    /// samples read until the first off the lattice); core's lattice_mm (every latticed sample, another face-prism's lattice far
    /// down the column too) only where the run is not given. nil: no column.
    public static func latticeCap(_ st: FlexStackInfo, apexT: Double) -> Double? {
        guard !st.columns.isEmpty else { return nil }
        let run = st.latticeRunMM.count == st.columns.count ? st.latticeRunMM : st.columns.map(\.latticeMM)
        return st.columns.indices.map { run[$0] + st.columns[$0].entryT - apexT }.min()
    }
}

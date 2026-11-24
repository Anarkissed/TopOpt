// PrintOrientationPatches — ★ notes28 (his iPad notes on release 18, img 80 → img 81: "The face selection looks awful. [Bambu
// Studio's] is a sample of how BambuSlicer does it, please implement something similar. The corners should have their own
// 'face' to select.").
//
// What Manual orientation draws to tap, as Bambu Studio's Lay on face does: every face of the part's hull a flat translucent
// patch, inset from its edges; every edge rest (the tilted rests his stand supports hold) its OWN small face — a narrow bevel
// facet along that edge, the chamfer the two faces would have there — never a line. The patches sit on the hull, which wraps
// the part, so a face turned toward him is in front of the part. The facet's plane leans on both faces equally: its up is the
// edge's up, the way it would print.
import Foundation
import simd

public struct PrintPatches: Equatable, Sendable {
    /// What a patch stands the part on.
    public enum Target: Hashable, Sendable {
        case face(Int)
        case edge(Int)
    }
    public struct Patch: Equatable, Sendable {
        public var target: Target
        /// Its corners on the hull (the part's own mm), counter-clockwise seen from outside.
        public var outline: [SIMD3<Double>]
        /// Outward: the up it prints with is −normal.
        public var normal: SIMD3<Double>
    }
    public var faces: [Patch]
    public var edges: [Patch]
    /// How far a face's patch keeps from its edges, and how far an edge's facet reaches onto each face (mm).
    public var insetMM: Double
    public var bevelMM: Double

    /// The facet's reach onto each face: a small share of the part's size (a few mm on his stand), never more than a
    /// quarter of the narrower face across the edge.
    public enum Rule {
        public static let bevelShare = 0.035, bevelMinMM = 1.0, bevelMaxMM = 6.0
        /// The gap between a face's patch and the facets beside it, as a share of the facet's reach.
        public static let gapShare = 0.35
    }

    public static func of(_ h: PrintHull) -> PrintPatches {
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for f in h.faces { for p in f.outline { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
        let size = lo.x.isFinite ? simd_length(hi - lo) : 0
        let bevel = Swift.min(Swift.max(size * Rule.bevelShare, Rule.bevelMinMM), Rule.bevelMaxMM)
        let inset = bevel * (1 + Rule.gapShare)
        var faces: [Patch] = []
        for (i, f) in h.faces.enumerated() where f.outline.count >= 3 {
            faces.append(Patch(target: .face(i), outline: Self.inset(f.outline, normal: f.normal, by: inset), normal: f.normal))
        }
        var edges: [Patch] = []
        for (i, e) in h.edges.enumerated() {
            // never wider than a quarter of the narrower face across it
            let across = [e.n1, e.n2].compactMap { n in h.faces.first { simd_dot($0.normal, n) > 0.99999 } }
                .map { Self.width($0.outline, normal: $0.normal, along: simd_normalize(e.b - e.a)) }
            let w = Swift.min(bevel, (across.min() ?? .infinity) / 4)
            guard let q = Self.facet(e, reachMM: w) else { continue }
            edges.append(Patch(target: .edge(i), outline: q, normal: -e.up))
        }
        return PrintPatches(faces: faces, edges: edges, insetMM: inset, bevelMM: bevel)
    }

    /// The bevel facet along an edge: from the edge `reachMM` onto each of its two faces, its ends kept off the corners by as
    /// much (so the facets of two edges meeting at a corner never overlap). A flat quad: its plane leans on both faces equally.
    static func facet(_ e: PrintHull.Edge, reachMM w: Double) -> [SIMD3<Double>]? {
        let len = simd_distance(e.a, e.b)
        guard w > 0, len > 2 * w else { return nil }
        let d = simd_normalize(e.b - e.a)
        // into face 1 (in its plane, square to the edge, away from face 2's outside), and into face 2
        func into(_ n: SIMD3<Double>, away other: SIMD3<Double>) -> SIMD3<Double>? {
            let c = simd_cross(n, d)
            guard simd_length(c) > 1e-9 else { return nil }
            let t = simd_normalize(c)
            return simd_dot(t, other) < 0 ? t : -t
        }
        guard let t1 = into(e.n1, away: e.n2), let t2 = into(e.n2, away: e.n1) else { return nil }
        let a = e.a + d * w, b = e.b - d * w
        let quad = [a + t1 * w, b + t1 * w, b + t2 * w, a + t2 * w]
        // counter-clockwise seen from outside (along the facet's outward normal)
        let n = simd_cross(quad[1] - quad[0], quad[2] - quad[0])
        return simd_dot(n, -e.up) >= 0 ? quad : quad.reversed()
    }

    /// A convex outline moved in by `d` mm on its own plane (each side moved in, the corners where they meet); a face too small
    /// for it shrinks toward its middle instead, to a fifth of its size at least.
    static func inset(_ outline: [SIMD3<Double>], normal n: SIMD3<Double>, by d: Double) -> [SIMD3<Double>] {
        let m = outline.count
        guard m >= 3, d > 0 else { return outline }
        let (u, v) = PrintHull.basis(n)
        let o = outline[0]
        let p2 = outline.map { SIMD2(simd_dot($0 - o, u), simd_dot($0 - o, v)) }
        // the outline's own turn (outside → counter-clockwise in (u, v) when u × v = n)
        var area = 0.0
        for i in 0..<m { let a = p2[i], b = p2[(i + 1) % m]; area += a.x * b.y - b.x * a.y }
        let ccw = area > 0
        var lines: [(p: SIMD2<Double>, dir: SIMD2<Double>)] = []
        for i in 0..<m {
            let a = p2[i], b = p2[(i + 1) % m]
            let e = b - a
            let l = simd_length(e)
            guard l > 1e-9 else { continue }
            let dir = e / l
            let inward = ccw ? SIMD2(-dir.y, dir.x) : SIMD2(dir.y, -dir.x)
            lines.append((a + inward * d, dir))
        }
        var out: [SIMD2<Double>] = []
        if lines.count >= 3 {
            for i in 0..<lines.count {
                let l1 = lines[(i + lines.count - 1) % lines.count], l2 = lines[i]
                let den = l1.dir.x * l2.dir.y - l1.dir.y * l2.dir.x
                guard abs(den) > 1e-9 else { continue }   // a straight run: the next corner holds it
                let w = l2.p - l1.p
                let t = (w.x * l2.dir.y - w.y * l2.dir.x) / den
                out.append(l1.p + l1.dir * t)
            }
        }
        // it must still be the same way round and inside the face; else shrink toward the middle
        func signedArea(_ q: [SIMD2<Double>]) -> Double {
            var a = 0.0
            for i in 0..<q.count { let x = q[i], y = q[(i + 1) % q.count]; a += x.x * y.y - y.x * x.y }
            return a
        }
        let shrunk = out.count >= 3 && (signedArea(out) > 0) == ccw && abs(signedArea(out)) < abs(area)
            && out.allSatisfy { PrintHull.inside($0, p2) }
        if !shrunk {
            let mid = p2.reduce(SIMD2<Double>.zero, +) / Double(m)
            let reach = p2.map { simd_distance($0, mid) }.min() ?? 0
            let k = Swift.max(0.2, reach > 0 ? 1 - d / reach : 0.2)
            out = p2.map { mid + ($0 - mid) * k }
        }
        return out.map { o + u * $0.x + v * $0.y }
    }

    /// How wide an outline is across a direction on its plane (square to `along`).
    static func width(_ outline: [SIMD3<Double>], normal n: SIMD3<Double>, along: SIMD3<Double>) -> Double {
        let across = simd_cross(n, along)
        guard simd_length(across) > 1e-9 else { return 0 }
        let a = simd_normalize(across)
        let s = outline.map { simd_dot($0, a) }
        return (s.max() ?? 0) - (s.min() ?? 0)
    }

    /// Which patch the flow's shown way stands on (the one he picked), if any.
    public func picked(_ p: PrintPick?, hull h: PrintHull) -> Target? {
        guard let p else { return nil }
        let up = simd_normalize(p.up)
        if p.onEdge {
            return h.edges.indices.first { simd_dot(simd_normalize(h.edges[$0].up), up) > 0.9998 }.map(Target.edge)
        }
        return h.faces.indices.first { simd_dot(h.faces[$0].up, up) > 0.9998 }.map(Target.face)
    }
}

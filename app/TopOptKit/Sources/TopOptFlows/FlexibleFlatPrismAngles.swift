// FlexibleFlatPrismAngles — the flat prism's two angles (task 2026-09-29-flexible-screens, round 7 batch R7-E1). His answers,
// 2026-10-18 (binding): "drag the prism's ARROW — a handle on the edge/corner prism's arrow tilts it toward one face or the other;
// it starts at halfway (core's halfway) and snaps back there; the angle shows on the handle (tap to type, keypad)"; LEFT/RIGHT =
// a TWIST along the edge (one end deeper); UP/DOWN = tip toward one face or the other; a corner: UP/DOWN tips the arrow more
// into the Top or more into the sides, LEFT/RIGHT swings it between the two side faces; the twist stops when the shallow end
// reaches 0 mm; the half-face rule is dropped (each face keeps some of itself).
//
// ★ DISPLAY ONLY: d (press.direction) stays the one store. compose(θ, φ) = cosφ·(cosθ·d0 + sinθ·u) + sinφ·r on an orthonormal
// frame (d0, u, r) — d0 the halfway (core's), u the tilt direction (toward the first face named / the Top), r the twist axis
// (away from the named end, so + makes it deeper / toward the second side face) — and compose(0, 0) IS d0, bit for bit.
// ★ SNAP: each angle on its own, to exactly 0 within 3° (a drag only; a typed value is kept as typed) — "starts at halfway and
// snaps back there". AP3's 12° snap would swallow a third of the twist's range.
// ★ LIMITS (per axis, by bisection — FlexiblePressAim.clamp's pattern), each stop said in one line:
//   L1 1° short of edge-on to every footprint triangle's CORE normal (FlexiblePressAimSet.footprintNormals);
//   L2 the plane crosses every member: dot(a_i, d) ≥ sin 1° on an edge, dot(e_j, d) ≥ sin 1° on all three corner edges;
//   L3 each face keeps some of itself (his answer — FlexibleFlatPrism.keepsRest);
//   L4 a twist keeps its shallow end at ≥ 0 mm: h ≥ L·|dot(e, d)|.
// The depth's own stops: 0.5 mm (or the twist's far end), L3, and the LATTICE from core's press stack (FlexibleFlatPrism.
// latticeCap).

import Foundation
import simd
import TopOptKit

public enum FlexibleFlatPrismAngles {

    /// Each angle snaps to exactly 0 within this many degrees (a drag only).
    public static let snapDeg = 3.0

    /// The frame the two angles are measured in.
    public struct Frame: Equatable, Sendable {
        /// The halfway (core's): (0°, 0°).
        public let d0: SIMD3<Double>
        /// + θ leans the arrow toward it (an edge: toward the first face named; a corner: into the cap face — the Top).
        public let tilt: SIMD3<Double>
        /// + φ leans the arrow toward it (an edge: away from the named end, so that end goes deeper; a corner: toward the second
        /// side face).
        public let twist: SIMD3<Double>
        public let corner: Bool
        /// The member + θ leans toward (an edge: 0; a corner: its cap face).
        public let tiltMember: Int
        /// A corner: the side member + φ swings toward.
        public let twistMember: Int?
        /// An edge: the end + φ deepens ("top end").
        public let namedEnd: String
        /// ★ R7-E1b: a STEEP edge (≥ 30° up the build direction): θ moves the arrow left/right on the part and φ up/down, so θ is
        /// called "Twist" and φ "Tilt" (his words: Tilt = up/down, Twist = left/right).
        public var thetaIsTwist = false
    }

    /// The frame of strip `s` about halfway `d0`, `up` = core's build direction (nil: no member normal, or d0 along a member).
    public static func frame(_ s: FlexibleStrip, d0: SIMD3<Double>, up: SIMD3<Double>) -> Frame? {
        guard let d = FlexiblePressAim.unit(d0) else { return nil }
        func ortho(_ v: SIMD3<Double>, _ against: [SIMD3<Double>]) -> SIMD3<Double>? {
            var w = v
            for a in against { w -= simd_dot(w, a) * a }
            return FlexiblePressAim.unit(w)
        }
        let normals = s.members.map { FlexibleFlatPrism.inwardNormal($0, toward: d0) }
        if s.kind == .corner {
            guard normals.count == 3, normals.allSatisfy({ $0 != nil }) else { return nil }
            let ns = normals.map { $0! }
            // the cap: the member most along ±up (the Top of a top corner); the other two are the sides
            let cap = ns.indices.max { Swift.abs(simd_dot(ns[$0], up)) < Swift.abs(simd_dot(ns[$1], up)) } ?? 0
            let sides = ns.indices.filter { $0 != cap }
            guard let u = ortho(ns[cap], [d]) else { return nil }
            guard var r = ortho(simd_cross(ns[cap], d), [d, u]) else { return nil }
            let b = sides.count > 1 ? sides[1] : sides.first ?? 0
            if simd_dot(r, ns[b]) < 0 { r = SIMD3<Double>.zero - r }
            return Frame(d0: d0, tilt: u, twist: r, corner: true, tiltMember: cap, twistMember: b, namedEnd: "")
        }
        guard let n0 = normals.first ?? nil, let l = FlexibleFlatPrism.line(s), let u = ortho(n0, [d]) else { return nil }
        let e0 = l.origin + l.dir * l.s0, e1 = l.origin + l.dir * l.s1
        // the named end: the top one of a steep edge; else the right (+X) or the back (+Y) one — the gizmo's words
        let named: SIMD3<Double>, word: String
        if Swift.abs(simd_dot(l.dir, up)) >= 0.5 {
            (named, word) = simd_dot(e1 - e0, up) >= 0 ? (e1, "top end") : (e0, "top end")
        } else if Swift.abs(l.dir.x) >= Swift.abs(l.dir.y) {
            (named, word) = e1.x >= e0.x ? (e1, "right end") : (e0, "right end")
        } else {
            (named, word) = e1.y >= e0.y ? (e1, "back end") : (e0, "back end")
        }
        let other = named == e1 ? e0 : e1
        guard let r = ortho(other - named, [d, u]) else { return nil }
        return Frame(d0: d0, tilt: u, twist: r, corner: false, tiltMember: 0, twistMember: nil, namedEnd: word,
                     thetaIsTwist: Swift.abs(simd_dot(l.dir, up)) >= 0.5)
    }

    /// ★ The direction at (θ, φ) degrees: d0 ITSELF at (0, 0) (its bits — the halfway exactly), else unit and canonical.
    public static func compose(_ f: Frame, theta: Double, phi: Double) -> SIMD3<Double> {
        if theta == 0, phi == 0 { return f.d0 }
        let t = theta * .pi / 180, p = phi * .pi / 180
        let v = cos(p) * (cos(t) * f.d0 + sin(t) * f.tilt) + sin(p) * f.twist
        return FlexiblePressAim.canon(FlexiblePressAim.unit(v) ?? f.d0)
    }

    /// The angles of direction `d`, degrees ((0, 0) when d is the halfway's own bits).
    public static func decompose(_ f: Frame, _ d: SIMD3<Double>) -> (theta: Double, phi: Double) {
        if FlexiblePressAim.bits(d) == FlexiblePressAim.bits(f.d0) { return (0, 0) }
        guard let u = FlexiblePressAim.unit(d) else { return (0, 0) }
        let phi = asin(Swift.min(1, Swift.max(-1, simd_dot(u, f.twist))))
        let theta = atan2(simd_dot(u, f.tilt), simd_dot(u, f.d0))
        return (theta * 180 / .pi, phi * 180 / .pi)
    }

    /// A dragged angle: exactly 0 within 3°.
    public static func snapped(_ deg: Double) -> Double { Swift.abs(deg) < snapDeg ? 0 : deg }

    // MARK: - the limits

    /// Why a handle stops.
    public enum Stop: Equatable, Sendable {
        /// L1: member k would be edge-on.
        case edgeOn(Int)
        /// L2: the plane would miss member k (a corner: any of its three edges).
        case cross(Int)
        /// L3: member k would keep none of itself.
        case rest(Int)
        /// L4 (or the depth's floor on a twist): the shallow end reaches 0 mm.
        case farEnd
        /// L5: the lattice (core's columns) ends at this depth.
        case lattice(Double)
        /// The depth's floor.
        case shallow
    }

    /// What the limits are checked against.
    public struct Limits {
        /// Core's inward normal of every footprint triangle (L1); empty: L1 not checked.
        public var loads: [SIMD3<Double>]
        /// L3: the member that would keep none of itself under (d, h), else nil.
        public var keepsRest: (SIMD3<Double>, Double) -> Int?
        /// L5: the depth the lattice allows (core's columns), when known.
        public var latticeCapMM: Double?
        public init(loads: [SIMD3<Double>], keepsRest: @escaping (SIMD3<Double>, Double) -> Int? = { _, _ in nil },
                    latticeCapMM: Double? = nil) {
            self.loads = loads; self.keepsRest = keepsRest; self.latticeCapMM = latticeCapMM
        }
    }

    /// The first limit (d, h) breaks, or nil.
    public static func check(_ s: FlexibleStrip, d: SIMD3<Double>, h: Double, limits: Limits) -> Stop? {
        guard let u = FlexiblePressAim.unit(d) else { return .edgeOn(0) }
        if !limits.loads.isEmpty, !FlexiblePressAim.admissible(u, loads: limits.loads) {
            let k = s.members.indices.min { a, b in
                (FlexibleFlatPrism.inwardNormal(s.members[a], toward: u).map { simd_dot($0, u) } ?? 1)
                    < (FlexibleFlatPrism.inwardNormal(s.members[b], toward: u).map { simd_dot($0, u) } ?? 1)
            } ?? 0
            return .edgeOn(k)
        }
        let s1 = sin(FlexiblePressAim.edgeOnMarginDeg * .pi / 180)
        if s.kind == .corner {
            if FlexibleFlatPrism.cornerEdges(s).contains(where: { simd_dot($0, u) < s1 }) { return .cross(-1) }
        } else {
            for (k, m) in s.members.enumerated() where (m.away.first.map { simd_dot($0, u) } ?? 0) < s1 { return .cross(k) }
        }
        if let k = limits.keepsRest(u, h) { return .rest(k) }
        if s.kind == .edge, h < FlexibleFlatPrism.length(s) * Swift.abs(simd_dot(FlexibleFlatPrism.line(s)!.dir, u)) - 1e-9 {
            return .farEnd
        }
        return nil
    }

    /// ★ One axis held at its limit: the last value on the way from `from` to `to` (degrees) that passes, with `at(value)` the
    /// direction; the stop that held it (nil: `to` passes). A start that does not pass holds where it is.
    static func bisect(from: Double, to: Double, _ fails: (Double) -> Stop?) -> (value: Double, stop: Stop?) {
        guard let stop = fails(to) else { return (to, nil) }
        if fails(from) != nil { return (from, stop) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if fails(from + mid * (to - from)) == nil { lo = mid } else { hi = mid }
        }
        return (from + lo * (to - from), fails(from + hi * (to - from)) ?? stop)
    }

    /// ★ A DRAG (or a typed pair) landed: θ first along its own way (φ at its start), then φ (θ where it landed) — each held at its
    /// limit and the first stop said. `h`: the depth.
    public static func clamp(_ s: FlexibleStrip, frame f: Frame, h: Double, from: (theta: Double, phi: Double),
                             to: (theta: Double, phi: Double), limits: Limits) -> (theta: Double, phi: Double, stop: Stop?) {
        let t = bisect(from: from.theta, to: to.theta) { check(s, d: compose(f, theta: $0, phi: from.phi), h: h, limits: limits) }
        let p = bisect(from: from.phi, to: to.phi) { check(s, d: compose(f, theta: t.value, phi: $0), h: h, limits: limits) }
        return (t.value, p.value, t.stop ?? p.stop)
    }

    /// The farthest an axis goes from (θ, φ) toward `sign` (+1 / −1), degrees — for the tests and the guide arc's ticks.
    public static func limit(_ s: FlexibleStrip, frame f: Frame, h: Double, at: (theta: Double, phi: Double), tilt: Bool, sign: Double,
                             limits: Limits) -> (deg: Double, stop: Stop?) {
        let far = sign * 89.9
        if tilt {
            let r = bisect(from: at.theta, to: far) { check(s, d: compose(f, theta: $0, phi: at.phi), h: h, limits: limits) }
            return (r.value, r.stop)
        }
        let r = bisect(from: at.phi, to: far) { check(s, d: compose(f, theta: at.theta, phi: $0), h: h, limits: limits) }
        return (r.value, r.stop)
    }

    /// ★ THE DEPTH'S RANGE along `d`: from 0.5 mm (or the twist's far end) to the first of each face keeping some of itself (L3)
    /// and the lattice (L5, core's columns); with the stops that set its ends.
    public static func depthRange(_ s: FlexibleStrip, d: SIMD3<Double>, limits: Limits, probeMM: Double = 1000)
        -> (min: Double, max: Double, minStop: Stop, maxStop: Stop?) {
        let far = s.kind == .edge ? FlexibleFlatPrism.length(s) * Swift.abs(simd_dot(FlexibleFlatPrism.line(s)!.dir, d)) : 0
        let lo = Swift.max(FlexibleFlatPrism.minDepthMM, far)
        let minStop: Stop = far > FlexibleFlatPrism.minDepthMM ? .farEnd : .shallow
        var hi = probeMM, maxStop: Stop? = nil
        if let k = limits.keepsRest(d, probeMM) {
            var a = lo, b = probeMM
            if limits.keepsRest(d, a) != nil { return (lo, lo, minStop, .rest(k)) }
            for _ in 0..<60 { let m = (a + b) / 2; if limits.keepsRest(d, m) == nil { a = m } else { b = m } }
            hi = a
            maxStop = .rest(limits.keepsRest(d, b) ?? k)
        }
        if let cap = limits.latticeCapMM, cap < hi { hi = Swift.max(lo, cap); maxStop = .lattice(cap) }
        return (lo, Swift.max(lo, hi), minStop, maxStop)
    }

    // MARK: - the lines (his rule: one line, ≤ 44 characters)

    /// A stop as he reads it, next to the handle for 2 s. `name`: member k's face name.
    public static func line(_ stop: Stop, strip s: FlexibleStrip, name: (Int) -> String) -> String {
        switch stop {
        case .rest(let k): return FlexibleRowCopy.fit("Stops here \u{00B7} \(name(k)) keeps the rest")
        case .edgeOn(let k): return FlexibleRowCopy.fit("Stops here \u{00B7} \(name(k)) would be edge-on")
        case .farEnd: return FlexibleRowCopy.flatFarEnd
        case .cross(let k):
            return s.kind == .corner ? FlexibleRowCopy.flatCrossAll(s.members.count)
                : FlexibleRowCopy.fit("The flat prism must cross \(name(Swift.max(0, k)))")
        case .lattice(let mm): return FlexibleRowCopy.flatLatticeEnds(mm)
        case .shallow: return FlexibleRowCopy.flatShallowest
        }
    }

    /// A typed value that was clamped: "Held at 32.8° · Face 2 keeps the rest".
    public static func heldLine(_ value: Double, unit: String, stop: Stop, strip s: FlexibleStrip, name: (Int) -> String) -> String {
        let why = line(stop, strip: s, name: name)
        let reason = why.components(separatedBy: " \u{00B7} ").dropFirst().joined(separator: " \u{00B7} ")
        let head = "Held at " + FlexNumberSpec.format(value, decimals: 1) + unit
        return FlexibleRowCopy.fit(reason.isEmpty ? head : head + " \u{00B7} " + reason)
    }
}

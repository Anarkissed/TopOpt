// FlexiblePressShape — the edge/corner flat prism in CORE's own map modes (task 2026-09-29-flexible-screens, round 7 batch R7-E2).
// His answer, 2026-10-18 ~16:50 (binding): "CORE: do NOT ask #361 yet (neither 'flat_cut' nor squish_envelope); ship the twist with
// its honest line saying how close core's profile is." The reviewer's rulings: one source — core; nothing app-side stands in as
// the bend limit.
//
// ★ WHAT CORE IS SENT. The flat prism's target per column is δ_k = (t_A + h) − entry_t_k (FlexibleFlatPrism: 0 at the rim, h at
// the apex). Core's SquishMap has only both = X(u)·Y(v), either and centre_edge = C(t) (field.hpp), so the press is sent as the
// closest map in core's own modes, built from CORE's press frame (its stack's axes, extents and columns, and core's to_uvt of the
// edge's ends) — ONE function for the design, the lattice and the job:
//   * an untwisted edge → "both": the axis ALONG the edge ≡ 1, the axis ACROSS it a tent that peaks at the edge's own coordinate
//     (core's to_uvt), 16 collinear points a side so core's monotone PCHIP rounds only the two segments beside the peak. The
//     across axis is whichever of core's X / Y is more ⟂ to the edge's projection: core's X is the footprint's principal axis,
//     which flips on his 20 mm Edge 16 at h = 10 mm (20 along vs 2h across);
//   * a corner → "centre_edge" with C = [(0, 0), (1, 1)]: core's edge fraction (the column grid's distance to the footprint's
//     boundary over its largest) — exact to the grid on a box corner at halfway (the roof of an equilateral triangle);
//   * a twisted edge → "both" with the along axis a RAMP (the shallow end's δ over h on the edge, from core's t of its two ends) ×
//     the across tent: the closest product (the plane is a sum, not a product).
// ★ HOW CLOSE (`offPercent`): N = max over core's columns of |S_k·h − δ_k| / h, S from core's own squish_fraction of this map — said
// on the card when N > 2 ("Twisted · squish shape up to 6% off"); the footprint and the direction are sent exactly.

import Foundation
import simd
import TopOptKit

public enum FlexiblePressShape {

    /// What the map needs of the press beyond core's stack: a corner, or an edge's two ends in core's press frame (u, v, t — core's
    /// to_uvt of the ends of the edge's line).
    public struct Press: Equatable, Sendable {
        public var corner: Bool
        public var endsUVT: [SIMD3<Double>]
        public init(corner: Bool, endsUVT: [SIMD3<Double>]) { self.corner = corner; self.endsUVT = endsUVT }
    }

    /// The tent's collinear points per side (core's PCHIP is linear between collinear points; only the peak's neighbours round).
    public static let pointsPerSide = 16
    /// The card says how far off core's profile is above this (percent of the deepest squish).
    public static let warnPercent = 2.0
    /// ★ RED CONTROL only (FlexibleR7E2Tests): the across axis assumed to be core's Y (X along the edge) — at h = 14 on his Edge 16
    /// the tent then lies along the 20 mm edge.
    nonisolated(unsafe) static var controlAcrossIsY = false
    /// ★ RED CONTROL only: a twist's map said nothing about how close it is.
    nonisolated(unsafe) static var controlSilent = false

    /// Is the edge twisted (its two ends at different depths along core's load)? A corner: false.
    public static func twisted(_ p: Press) -> Bool {
        guard !p.corner, p.endsUVT.count == 2 else { return false }
        // an untwisted edge lies ⟂ the arrow: its two ends at one t (to rounding); a 1° twist on a 20 mm edge is 0.35 mm
        return Swift.abs(p.endsUVT[1].z - p.endsUVT[0].z) > twistToleranceMM
    }
    /// Two ends whose t differ by less than this are one depth (an untwisted edge, to core's rounding).
    public static let twistToleranceMM = 1e-6

    /// The axis ACROSS the edge: true = core's X, false = core's Y (nil: a corner).
    public static func acrossIsX(_ st: FlexStackInfo, _ p: Press) -> Bool? {
        guard !p.corner, p.endsUVT.count == 2 else { return nil }
        if controlAcrossIsY { return false }   // (RED CONTROL: X assumed along the edge)
        // the edge's projection in core's (u, v): the axis it runs LESS along is the one across it
        let du = Swift.abs(p.endsUVT[1].x - p.endsUVT[0].x), dv = Swift.abs(p.endsUVT[1].y - p.endsUVT[0].y)
        return du < dv
    }

    /// ★ THE MAP core is sent for a flat press `depthMM` deep, from core's press stack `st` and core's t of the apex `apexT`.
    public static func map(_ st: FlexStackInfo, apexT: Double, depthMM h: Double, press p: Press) -> FlexMap {
        // a corner: core's edge fraction, linear — the roof of the footprint (exact to the grid on a box corner at halfway)
        if p.corner { return FlexMap(mode: "centre_edge", x: .flat, y: .flat, centreEdge: FlexCurve(x: [0, 1], y: [0, 1]), deepestMM: h) }
        guard let ax = acrossIsX(st, p), h > 0 else {
            return FlexMap(mode: "both", x: .flat, y: .flat, centreEdge: .flat, deepestMM: h)
        }
        let e0 = p.endsUVT[0], e1 = p.endsUVT[1]
        let acrossExtent = ax ? st.uExtentMM : st.vExtentMM, alongExtent = ax ? st.vExtentMM : st.uExtentMM
        func across(_ q: SIMD3<Double>) -> Double { ax ? q.x : q.y }
        func along(_ q: SIMD3<Double>) -> Double { ax ? q.y : q.x }
        // the tent: 0 at both rims (each face's trace), 1 at the edge's own coordinate across (core's to_uvt of its ends)
        let peak = acrossExtent > 0 ? (across(e0) + across(e1)) / 2 / acrossExtent : 0.5
        let tentCurve = tent(peak: peak)
        // along: ≡ 1 untwisted; twisted, a ramp from the deep end's 1 to the shallow end's δ/h on the edge (core's t of each end)
        var alongCurve = FlexCurve.flat
        if twisted(p), alongExtent > 0 {
            let y0 = Swift.min(1, Swift.max(0, (apexT + h - e0.z) / h)), y1 = Swift.min(1, Swift.max(0, (apexT + h - e1.z) / h))
            alongCurve = ramp(along(e0) / alongExtent, y0, along(e1) / alongExtent, y1)
        }
        return FlexMap(mode: "both", x: ax ? tentCurve : alongCurve, y: ax ? alongCurve : tentCurve, centreEdge: .flat, deepestMM: h)
    }

    /// The tent: `pointsPerSide` collinear points from (0, 0) up to (peak, 1), as many down to (1, 0). x strictly increasing, from 0
    /// to exactly 1 (core's pen-curve rules).
    static func tent(peak raw: Double) -> FlexCurve {
        let n = pointsPerSide
        let lo = 1.0 / Double(4 * n * n), p = Swift.min(1 - lo, Swift.max(lo, raw.isFinite ? raw : 0.5))
        var x: [Double] = [], y: [Double] = []
        for i in 0...n { x.append(p * Double(i) / Double(n)); y.append(Double(i) / Double(n)) }
        for j in 1...n { x.append(p + (1 - p) * Double(j) / Double(n)); y.append(1 - Double(j) / Double(n)) }
        x[0] = 0; x[x.count - 1] = 1; y[0] = 0; y[y.count - 1] = 0; y[n] = 1
        return FlexCurve(x: x, y: y)
    }

    /// A ramp along the edge: (b0, y0) to (b1, y1) on `pointsPerSide` collinear points, flat beyond the edge's ends; from 0 to 1.
    static func ramp(_ b0: Double, _ y0: Double, _ b1: Double, _ y1: Double) -> FlexCurve {
        var (bl, yl, bh, yh) = b0 <= b1 ? (b0, y0, b1, y1) : (b1, y1, b0, y0)
        func at(_ b: Double) -> Double { bh - bl > 1e-12 ? yl + (yh - yl) * (b - bl) / (bh - bl) : yh }
        // the edge's ends inside [0, 1] (the footprint's extent along it)
        let cl = Swift.min(1, Swift.max(0, bl)), ch = Swift.min(1, Swift.max(0, bh))
        (yl, yh) = (at(cl), at(ch))
        (bl, bh) = (cl, ch)
        guard bh - bl > 1e-6 else { return FlexCurve(x: [0, 1], y: [Swift.max(yl, yh), Swift.max(yl, yh)]) }
        let n = pointsPerSide
        var x: [Double] = [], y: [Double] = []
        if bl > 1e-9 { x.append(0); y.append(yl) }
        for i in 0...n { x.append(bl + (bh - bl) * Double(i) / Double(n)); y.append(yl + (yh - yl) * Double(i) / Double(n)) }
        if bh < 1 - 1e-9 { x.append(1); y.append(yh) }
        x[0] = 0; x[x.count - 1] = 1
        return FlexCurve(x: x, y: y.map { Swift.min(1, Swift.max(0, $0)) })
    }

    // MARK: - how close core's profile is

    /// The flat prism's target per column of core's press stack: δ_k = (t_A + h) − entry_t_k (0 at the rim, h at the apex).
    public static func delta(_ st: FlexStackInfo, apexT: Double, depthMM: Double) -> [Double] {
        st.columns.map { (apexT + depthMM) - $0.entryT }
    }

    /// ★ N: the most core's S_k·h is off the flat prism's δ_k, in percent of h (either way).
    public static func offPercent(s: [Double], delta: [Double], depthMM: Double) -> Double {
        guard depthMM > 0, !s.isEmpty, s.count == delta.count else { return 0 }
        var worst = 0.0
        for k in s.indices { worst = Swift.max(worst, Swift.abs(s[k] * depthMM - delta[k])) }
        return 100 * worst / depthMM
    }

    /// The card's one line when core's profile is more than 2 % off the flat prism (nil: within 2 %).
    public static func line(offPercent: Double, corner: Bool = false) -> String? {
        guard !controlSilent, offPercent > warnPercent else { return nil }   // (RED CONTROL: silent)
        return corner ? FlexibleRowCopy.cornerOff(offPercent) : FlexibleRowCopy.twistOff(offPercent)
    }
}

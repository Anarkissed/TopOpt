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
        false   // ★ R7-E2 STUB
    }

    /// The axis ACROSS the edge: true = core's X, false = core's Y (nil: a corner).
    public static func acrossIsX(_ st: FlexStackInfo, _ p: Press) -> Bool? {
        nil   // ★ R7-E2 STUB
    }

    /// ★ THE MAP core is sent for a flat press `depthMM` deep, from core's press stack `st` and core's t of the apex `apexT`.
    public static func map(_ st: FlexStackInfo, apexT: Double, depthMM: Double, press p: Press) -> FlexMap {
        FlexMap(mode: "both", x: .flat, y: .flat, centreEdge: .flat, deepestMM: depthMM)   // ★ R7-E2 STUB
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
    public static func line(offPercent: Double) -> String? {
        nil   // ★ R7-E2 STUB
    }
}

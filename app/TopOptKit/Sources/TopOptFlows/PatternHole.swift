// PatternHole.swift — B8 (row 37; plan §B8 "Pattern follows the same rules: on a hole, rows run down its axis; either count
// can be 0 (round 3, P5)"; mockup #cut-pattern, #cut-pattern-zero, #cut-pattern-none): THE PATTERN ON A HOLE.
//
// His note (row 37): "a hole does not pattern down the hole as it should, but at random angles". Every face went through
// the spine walk (`SurfacePatternAxis.grid`), which on a bore follows whatever path the triangles give. On a hole the grid
// now hangs on the bore's own axis (CutAim's: the CAD cylinder's):
//   • n AROUND: n lines down the bore, each a half-plane through its axis, spaced evenly round it. On a whole ring n lines
//     make n pieces (one line cannot part a ring, so 1 around cuts nothing); on part of a ring (a STEP's half bore, or a
//     piece already cut along) they make n + 1.
//   • n DOWN THE HOLE: n rings square to the axis, spaced evenly along the piece's length: n + 1 pieces.
//   • Either count can be 0: no cuts that way. With no cut either way there is nothing to cut.
//
// Each cell is the bore's half-spaces only (`FaceRegionGeometry.GridCell`); `drawn` names each divider once (its lower
// side's), so the preview and the committed wireframe draw every line once.
// Pure geometry over value types: no view, no camera.

import Foundation
import simd

public enum PatternHole {

    /// The bar's limits (mockup NUMLIM: pa 0–24, pd 0–12) and its first numbers (mockup S.pa, S.pd).
    public static let aroundRange = 0...24
    public static let downRange = 0...12
    public static let defaultAround = 6
    public static let defaultDown = 3
    /// The bar's line when no count cuts anything (mockup #cut-pattern-none).
    public static let nothingToCut = "nothing to cut"
    /// A gap round the axis wider than this is the edge of the face: the face is part of a ring, not a whole one.
    public static let wholeRingGapDegrees = 90.0

    /// The part of a ring a face covers, in degrees about the axis from `Bore.direction(0)`.
    public struct Arc: Equatable, Sendable {
        public let start: Double
        public let span: Double
    }

    /// The bore as the pattern sees it: the tapped piece of a hole.
    public struct Bore: Equatable, Sendable {
        public let face: FaceID
        /// Unit.
        public let axis: SIMD3<Double>
        /// On the axis, at the middle of the piece's length.
        public let centre: SIMD3<Double>
        /// The piece's length along the axis, from `centre`.
        public let reach: ClosedRange<Double>
        public let radius: Double
        /// nil: a whole ring.
        public let arc: Arc?

        /// A unit direction square to the axis at `deg` round it (CutAim's own 0°).
        public func direction(_ deg: Double) -> SIMD3<Double> {
            let u = CutAim.orthogonal(to: axis), v = simd_cross(axis, u), t = deg * .pi / 180
            return simd_normalize(u * cos(t) + v * sin(t))
        }

        /// Where a point sits round the axis, 0..<360.
        public func degrees(of p: SIMD3<Double>) -> Double {
            let u = CutAim.orthogonal(to: axis), v = simd_cross(axis, u), d = p - centre
            var a = atan2(simd_dot(d, v), simd_dot(d, u)) * 180 / .pi
            if a < 0 { a += 360 }
            return a
        }
    }

    /// ★ THE BORE UNDER A PATTERN TAP: the face (or piece) when it is a hole — CutAim's own test (a fastener bore with a CAD
    /// cylinder) — else nil, and the face keeps today's grid. `points` are the piece's own vertices (CutAim.points).
    public static func bore(_ aim: CutAim, points: [SIMD3<Double>]) -> Bore? {
        guard case .hole(let axis, let radius) = aim.shape, !points.isEmpty else { return nil }
        let a = CutAim.unit(axis)
        let whole = Bore(face: aim.face, axis: a, centre: aim.centre, reach: aim.reach, radius: radius, arc: nil)
        let angles = points.map { whole.degrees(of: $0) }.sorted()
        // the widest gap round the axis between neighbouring points (the wrap included)
        var gap = angles.first! + 360 - angles.last!, after = angles.first!
        for k in 1..<angles.count where angles[k] - angles[k - 1] > gap {
            gap = angles[k] - angles[k - 1]; after = angles[k]
        }
        guard gap > wholeRingGapDegrees else { return whole }
        return Bore(face: aim.face, axis: a, centre: aim.centre, reach: aim.reach, radius: radius,
                    arc: Arc(start: after, span: 360 - gap))
    }

    /// The pieces n around and m down make (0 when nothing is cut).
    public static func pieces(_ bore: Bore, around: Int, down: Int) -> Int {
        let cols = columns(bore, around: around), rows = Swift.max(0, down) + 1
        return cols == 1 && rows == 1 ? 0 : cols * rows
    }

    /// How many pieces round the bore n lines make.
    static func columns(_ bore: Bore, around n: Int) -> Int {
        guard n > 0 else { return 1 }
        return bore.arc == nil ? (n == 1 ? 1 : n) : n + 1
    }

    /// ★ THE CELLS: lines round the axis, rings down it. A refusal says why there is nothing to make.
    public static func cells(_ bore: Bore, around: Int, down: Int)
        -> Result<[FaceRegionGeometry.GridCell], SurfacePatternArc.Refusal> {
        let n = Swift.min(aroundRange.upperBound, Swift.max(0, around))
        let m = Swift.min(downRange.upperBound, Swift.max(0, down))
        guard pieces(bore, around: n, down: m) > 0 else { return .failure(.init(nothingToCut)) }
        let cols = angularBands(bore, around: n)
        let rows = axialBands(bore, down: m)
        var out: [FaceRegionGeometry.GridCell] = []
        for (i, c) in cols.enumerated() {
            for (j, r) in rows.enumerated() {
                out.append(FaceRegionGeometry.GridCell(i: i, j: j, cuts: c.cuts + r.cuts, drawn: c.drawn + r.drawn))
            }
        }
        return .success(out)
    }

    typealias Band = (cuts: [RegionCut], drawn: [RegionCut])

    /// The half-space on the far side of the line at `deg` (the side the turn goes on to), non-strict: the lower side of a
    /// wedge. Its plane holds the axis.
    static func from(_ bore: Bore, _ deg: Double) -> RegionCut {
        RegionCut(point: bore.centre, normal: simd_cross(bore.axis, bore.direction(deg)))
    }

    /// The half-space before the line at `deg`, strict: the upper side of a wedge, so a point on a divider is in one piece.
    static func before(_ bore: Bore, _ deg: Double) -> RegionCut {
        RegionCut(point: bore.centre, normal: -simd_cross(bore.axis, bore.direction(deg)), strict: true)
    }

    /// The columns round the axis. A wedge is its two sides (each under 180°); a half ring is one plane.
    static func angularBands(_ bore: Bore, around n: Int) -> [Band] {
        let cols = columns(bore, around: n)
        guard cols > 1 else { return [([], [])] }
        if let arc = bore.arc {
            // part of a ring: n lines inside the arc; the outer sides sit a little past its ends, inside the gap
            let step = arc.span / Double(cols)
            let margin = Swift.min(5, (360 - arc.span) / 4)
            return (0..<cols).map { k in
                let lo = k == 0 ? arc.start - margin : arc.start + step * Double(k)
                let hi = k == cols - 1 ? arc.start + arc.span + margin : arc.start + step * Double(k + 1)
                let low = from(bore, lo)
                return ([low, before(bore, hi)], k == 0 ? [] : [low])
            }
        }
        if cols == 2 {
            // a whole ring halved: one plane through the axis, its two sides
            let c = from(bore, 0)
            let flip = RegionCut(point: c.point, normal: -c.normal, strict: true)
            return [([c], [c]), ([flip], [])]
        }
        let step = 360 / Double(cols)
        return (0..<cols).map { k in
            let low = from(bore, step * Double(k))
            return ([low, before(bore, step * Double(k + 1))], [low])
        }
    }

    /// The rows down the axis: m rings spaced evenly along the piece's length.
    static func axialBands(_ bore: Bore, down m: Int) -> [Band] {
        guard m > 0 else { return [([], [])] }
        let lo = bore.reach.lowerBound, len = bore.reach.upperBound - bore.reach.lowerBound
        func ring(_ k: Int) -> SIMD3<Double> { bore.centre + bore.axis * (lo + len * Double(k) / Double(m + 1)) }
        return (0...m).map { j in
            var cuts: [RegionCut] = [], drawn: [RegionCut] = []
            if j > 0 {
                let low = RegionCut(point: ring(j), normal: bore.axis)
                cuts.append(low); drawn.append(low)
            }
            if j < m { cuts.append(RegionCut(point: ring(j + 1), normal: -bore.axis, strict: true)) }
            return (cuts, drawn)
        }
    }
}

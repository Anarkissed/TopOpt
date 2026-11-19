// OrganicVineShape — his 11-19 note on Organic ("redo the entirety of how you generate the organic vines ... no caps ...
// phasing through one another ... straight, hard lines") and his verdict on the prototype ("The organic looks great now!").
// The vines as the preview draws them, from the engine's runs, by the numbers core reproduces for the print file (LatticeReview
// 20:48Z: one smoothing function, the preview and the file the same shape):
//   * each run a centripetal Catmull-Rom spline (alpha 0.5) through its points, sampled where it bends (`maxTurnDeg` per
//     piece, never longer than `maxPieceMM`), its radius linear between the engine's points;
//   * each piece a ROUND CONE (round in section, round at its ends): a vine is the plain union of its pieces;
//   * where vines meet (a run end shared by runs, or an end landing on another vine), a JOINT: the vines there blend by a
//     polynomial smooth-min of `blendMM` (a vine with itself stays a plain union, so nothing bulges along a vine).
// Prototype and pictures: agent-scratch/organic1/vines/vinelook.swift (styles today / grown).
import Foundation
import simd
import TopOptKit

public struct OrganicVineShape: Equatable, Sendable {
    public struct Params: Equatable, Sendable {
        public var blendMM: Float = 0.6
        public var maxTurnDeg: Float = 8
        public var maxPieceMM: Float = 1.5
        /// The curve's largest departure from the straight bar it smooths (core's `organic_smooth_max_offset_mm`,
        /// LatticeReview's first figure): the checks judge the bars, so the drawn vine stays on them.
        public var maxOffsetMM: Float = 0.2
        /// How close the drawn pieces keep to the curve (core's `organic_smooth_flatness_mm` for Exact), and the most per bar.
        public var flatnessMM: Float = 0.012
        public var maxPieces = 6
        public init() {}
    }
    /// One piece: a round cone from a (radius ra) to b (radius rb), on vine `vine`.
    public struct Piece: Equatable, Sendable {
        public var a: SIMD3<Float>, ra: Float, b: SIMD3<Float>, rb: Float, vine: Int32
        /// The tube's frame at each end: the curve's tangent there and a side vector carried along the vine (parallel
        /// transport), the SAME at a point two pieces share, so their rings meet exactly (no crack, no twist).
        public var ta = SIMD3<Float>(0, 0, 1), tb = SIMD3<Float>(0, 0, 1), va = SIMD3<Float>(1, 0, 0), vb = SIMD3<Float>(1, 0, 0)
        public init(a: SIMD3<Float>, ra: Float, b: SIMD3<Float>, rb: Float, vine: Int32) {
            self.a = a; self.ra = ra; self.b = b; self.rb = rb; self.vine = vine
        }
    }
    /// One joint: the vines meeting at `centre` blend inside `radius`; `pieces` are every piece that reaches the sphere.
    public struct Joint: Equatable, Sendable {
        public var centre: SIMD3<Float>, radius: Float, pieces: [Int32]
    }
    public var pieces: [Piece] = []
    public var joints: [Joint] = []
    /// The round ends: every run end, a sphere of its radius (xyz, r).
    public var caps: [SIMD4<Float>] = []
    public var params = Params()
    public init() {}

    /// The most pieces one joint blends (the shader's loop bound); a joint with more keeps the nearest.
    public static let maxJointPieces = 12

    public init(runs original: [LatticeLayoutSession.Run], params p: Params = Params()) {
        params = p
        let turnCos = cos(p.maxTurnDeg * .pi / 180)
        let runs = Self.pulledBack(original)
        for (vi, r) in runs.enumerated() where r.points.count >= 2 {
            let n = r.points.count
            let first = pieces.count
            caps.append(SIMD4(r.points[0], r.widthMM[0] / 2))
            caps.append(SIMD4(r.points[n - 1], r.widthMM[n - 1] / 2))
            for i in 0..<(n - 1) {
                let p1 = r.points[i], p2 = r.points[i + 1]
                let r1 = r.widthMM[i] / 2, r2 = r.widthMM[i + 1] / 2
                let p0 = i > 0 ? r.points[i - 1] : 2 * p1 - p2
                let p3 = i + 2 < n ? r.points[i + 2] : 2 * p2 - p1
                // the curve, finely, to find how far it leaves this bar
                let fine = (1..<8).map { Self.catmull(p0, p1, p2, p3, Float($0) / 8) }
                let swing = fine.map { Self.offset($0, p1, p2) }.max() ?? 0
                // the curve stays on the bars the checks judge (LatticeReview 21:56Z, condition 2, the rule of record): its
                // largest departure from this bar is at most `maxOffsetMM`; a span that swings further is drawn nearer the bar
                // by one factor
                let dev0 = swing > p.maxOffsetMM ? p.maxOffsetMM : swing
                // pieces: as few as keep the drawn curve within `flatnessMM` of the true one (a chord's error falls as 1/m^2)
                let m = dev0 <= p.flatnessMM ? 1 : Swift.min(p.maxPieces, Int((dev0 / p.flatnessMM).squareRoot().rounded(.up)))
                _ = turnCos
                let raw = (1..<Swift.max(m, 1)).map { Self.catmull(p0, p1, p2, p3, Float($0) / Float(m)) }
                let worst = Swift.max(swing, raw.map { Self.offset($0, p1, p2) }.max() ?? 0)
                let f: Float = worst > p.maxOffsetMM && worst > 0 ? p.maxOffsetMM / worst : 1
                let qs = raw.map { q -> SIMD3<Float> in let c = Self.onBar(q, p1, p2); return c + (q - c) * f }
                var prev = p1, prevR = r1
                for k in 1...m {
                    let t = Float(k) / Float(m)
                    let q = k == m ? p2 : qs[k - 1]
                    let rq = r1 + (r2 - r1) * t
                    pieces.append(Piece(a: prev, ra: prevR, b: q, rb: rq, vine: Int32(vi)))
                    prev = q; prevR = rq
                }
            }
            Self.frame(&pieces, first..<pieces.count)
        }
        joints = Self.joints(runs: original, pieces: pieces, blend: p.blendMM)   // the joints at the lay's own meeting points
    }

    /// LatticeReview's ruling 22:33Z (the rule of record; core copies it): a run END that meets another vine (a shared node, or
    /// landing on its body) and is wider than the widest other vine there keeps its full radius, but its end point is pulled
    /// back along its own line by (its radius - that vine's radius), so its round end finishes flush with the far side of the
    /// vine it meets (no ball beyond it). Never further back than half its last bar. Ends that meet nothing, or are no wider
    /// than what they meet, are unchanged.
    static func pulledBack(_ runs: [LatticeLayoutSession.Run]) -> [LatticeLayoutSession.Run] {
        let cell: Float = 2
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((p / cell).rounded(.down)) }
        var hash: [SIMD3<Int32>: [(Int, Int)]] = [:]
        for (ri, r) in runs.enumerated() where r.points.count >= 2 {
            for k in 0..<(r.points.count - 1) {
                let rad = Swift.max(r.widthMM[k], r.widthMM[k + 1]) / 2
                let lo = key(simd_min(r.points[k], r.points[k + 1]) - rad), hi = key(simd_max(r.points[k], r.points[k + 1]) + rad)
                for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x { hash[SIMD3(x, y, z), default: []].append((ri, k)) } } }
            }
        }
        var out = runs
        for (ri, r) in runs.enumerated() where r.points.count >= 2 {
            for endFirst in [true, false] {
                let i = endFirst ? 0 : r.points.count - 1, j = endFirst ? 1 : r.points.count - 2
                let e = r.points[i], own = r.widthMM[i] / 2
                // the widest other vine whose body holds this end
                var other: Float = -1
                for (rj, k) in hash[key(e)] ?? [] where rj != ri {
                    let a = runs[rj].points[k], b = runs[rj].points[k + 1]
                    let ab = b - a
                    let t = Swift.min(Swift.max(simd_dot(e - a, ab) / Swift.max(simd_dot(ab, ab), 1e-12), 0), 1)
                    let rad = (runs[rj].widthMM[k] + (runs[rj].widthMM[k + 1] - runs[rj].widthMM[k]) * t) / 2
                    if simd_length(e - (a + t * ab)) <= rad + 1e-3 { other = Swift.max(other, rad) }
                }
                guard other > 0, own > other else { continue }
                let back = r.points[j] - e
                let len = simd_length(back)
                guard len > 1e-6 else { continue }
                let pull = Swift.min(own - other, 0.5 * len)
                out[ri].points[i] = e + back / len * pull
            }
        }
        return out
    }

    /// One vine's tube frames: the tangent at a shared point is the mean of its two pieces' directions; the side vector is
    /// carried from piece to piece (projected off each new tangent), so neighbouring rings are the same ring.
    static func frame(_ ps: inout [Piece], _ range: Range<Int>) {
        guard !range.isEmpty else { return }
        func dir(_ q: Piece) -> SIMD3<Float> {
            let d = q.b - q.a
            return simd_length(d) > 1e-9 ? simd_normalize(d) : SIMD3(0, 0, 1)
        }
        var tangents = [SIMD3<Float>]()   // one per point: range.count + 1
        tangents.append(dir(ps[range.lowerBound]))
        for i in range.lowerBound..<(range.upperBound - 1) {
            let m = dir(ps[i]) + dir(ps[i + 1])
            tangents.append(simd_length(m) > 1e-6 ? simd_normalize(m) : dir(ps[i + 1]))
        }
        tangents.append(dir(ps[range.upperBound - 1]))
        func side(_ t: SIMD3<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
            var s = v - simd_dot(v, t) * t
            if simd_length(s) < 1e-4 {
                s = simd_cross(t, abs(t.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0))
            }
            return simd_normalize(s)
        }
        var v = side(tangents[0], SIMD3(0, 0, 1))
        for (k, i) in range.enumerated() {
            let t0 = tangents[k], t1 = tangents[k + 1]
            ps[i].ta = t0; ps[i].va = v
            v = side(t1, v)
            ps[i].tb = t1; ps[i].vb = v
        }
    }

    /// The nearest point of bar a-b to q, and q's distance from it.
    static func onBar(_ q: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a
        let t = Swift.min(Swift.max(simd_dot(q - a, ab) / Swift.max(simd_dot(ab, ab), 1e-12), 0), 1)
        return a + t * ab
    }
    static func offset(_ q: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(q - onBar(q, a, b)) }

    /// Centripetal Catmull-Rom (alpha 0.5, Barry-Goldman) between p1 and p2 at t in 0...1.
    public static func catmull(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        func kt(_ ti: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { ti + Swift.max(simd_length(b - a).squareRoot(), 1e-4) }
        let t0: Float = 0, t1 = kt(t0, p0, p1), t2 = kt(t1, p1, p2), t3 = kt(t2, p2, p3)
        let u = t1 + (t2 - t1) * t
        let a1 = (t1 - u) / (t1 - t0) * p0 + (u - t0) / (t1 - t0) * p1
        let a2 = (t2 - u) / (t2 - t1) * p1 + (u - t1) / (t2 - t1) * p2
        let a3 = (t3 - u) / (t3 - t2) * p2 + (u - t2) / (t3 - t2) * p3
        let b1 = (t2 - u) / (t2 - t0) * a1 + (u - t0) / (t2 - t0) * a2
        let b2 = (t3 - u) / (t3 - t1) * a2 + (u - t1) / (t3 - t1) * a3
        return (t2 - u) / (t2 - t1) * b1 + (u - t1) / (t2 - t1) * b2
    }

    /// The joints: every run end shared by two runs or more, and every run end that lands on another vine (within that vine's
    /// radius, its own and the blend). Each holds the pieces that reach its sphere (any vine), the nearest first.
    static func joints(runs: [LatticeLayoutSession.Run], pieces: [Piece], blend: Float) -> [Joint] {
        guard blend > 0, !pieces.isEmpty else { return [] }
        // pieces by a coarse hash of their boxes
        let cell: Float = 2
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((p / cell).rounded(.down)) }
        var hash: [SIMD3<Int32>: [Int32]] = [:]
        for (i, q) in pieces.enumerated() {
            let r = Swift.max(q.ra, q.rb)
            let lo = key(simd_min(q.a, q.b) - r), hi = key(simd_max(q.a, q.b) + r)
            for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x { hash[SIMD3(x, y, z), default: []].append(Int32(i)) } } }
        }
        func distance(_ p: SIMD3<Float>, _ q: Piece) -> (Float, Float) {   // to the centre line, and the radius there
            let ab = q.b - q.a
            let t = Swift.min(Swift.max(simd_dot(p - q.a, ab) / Swift.max(simd_dot(ab, ab), 1e-9), 0), 1)
            return (simd_length(p - (q.a + t * ab)), q.ra + (q.rb - q.ra) * t)
        }
        func near(_ c: SIMD3<Float>, within R: Float) -> [Int32] {
            let lo = key(c - R), hi = key(c + R)
            var seen = Set<Int32>(), out: [(Float, Int32)] = []
            for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x {
                for i in hash[SIMD3(x, y, z)] ?? [] where seen.insert(i).inserted {
                    let (d, r) = distance(c, pieces[Int(i)])
                    if d - r < R { out.append((d - r, i)) }
                }
            } } }
            return out.sorted { $0.0 < $1.0 }.prefix(maxJointPieces).map(\.1)
        }
        // run ends, and how many runs share each
        var ends: [SIMD3<Int32>: (p: SIMD3<Float>, runs: Set<Int>, r: Float)] = [:]
        func ekey(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((p * 50).rounded(.toNearestOrEven)) }
        for (ri, r) in runs.enumerated() where r.points.count >= 2 {
            for k in [0, r.points.count - 1] {
                let e = ends[ekey(r.points[k])] ?? (r.points[k], [], 0)
                ends[ekey(r.points[k])] = (e.p, e.runs.union([ri]), Swift.max(e.r, r.widthMM[k] / 2))
            }
        }
        var out: [Joint] = []
        for (_, e) in ends {
            let R = e.r + blend   // the fillet lies within the blend of the vines' surfaces at the joint
            let ps = near(e.p, within: R)
            let vines = Set(ps.map { pieces[Int($0)].vine })
            // a joint only where two vines or more are there to blend
            if vines.count >= 2 {
                out.append(Joint(centre: e.p, radius: R, pieces: ps))
            }
        }
        return out.sorted { ($0.centre.x, $0.centre.y, $0.centre.z) < ($1.centre.x, $1.centre.y, $1.centre.z) }
    }
}

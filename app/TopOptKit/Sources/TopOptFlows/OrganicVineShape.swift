// OrganicVineShape — his 11-19 note on Organic ("redo the entirety of how you generate the organic vines ... no caps ...
// phasing through one another ... straight, hard lines") and his verdict on the prototype ("The organic looks great now!").
// The vines as the preview draws them, from the engine's runs, by the numbers core reproduces for the print file (LatticeReview
// 20:48Z: one smoothing function, the preview and the file the same shape):
//   * each run a centripetal Catmull-Rom spline (alpha 0.5) through its points, sampled where it bends (`maxTurnDeg` per
//     piece, never longer than `maxPieceMM`), its radius linear between the engine's points;
//   * each piece a ROUND CONE (round in section, round at its ends): a vine is the plain union of its pieces;
//   * where vines meet (a run end shared by runs, or an end landing on another vine), a JOINT: the vines there blend by a
//     polynomial smooth-min of `blendMM` (a vine with itself stays a plain union, so nothing bulges along a vine).
// Prototype and pictures: agent-scratch/organic1/vines/vinelook.swift (styles today / grown / capsule).
// ★ HIS RULE 11-19 (later): "The drawing follows the print file. Always." The app draws `tubes(runs:)`, the print file's own
// tube rule. `capsules(runs:)` (release (10)'s balls at every point) is kept for comparison; the smooth blended shape below
// is kept, unused, for v2 (his "ideas for v2" sheet). Neither is a reference for core.
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
        /// The file closes this end with a flat disc (a run end into the solid or cut by the part's surface).
        public var flatA = false, flatB = false
        /// The print file's section (the run's): 0 round; 1 a bridge's D (flat level underside, round top); 2 a square bar.
        public var section: UInt8 = 0
        /// ★ The flat cut (his 11-20 skin note, "the cutting along the plane ... gives it its unique feel"): the part's
        /// surface where this piece reaches it (nil: it does not). The print file trims every tube to the part, so the
        /// drawing cuts it there and paints the cut face in the vine's colour.
        public var cut: Cut?
        public var isCut: Bool { cut != nil }
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
    /// `tubes(runs:)`: the run each cap ends (one per cap).
    public var capVines: [Int32] = []
    /// `tubes(runs:)` (OS1 B): per cap, true where it is a bridge's puck top: the upper half of the ball only (the puck's wall,
    /// from the bar's underside up to the ball's centre, is a vertical piece of `pieces`).
    public var capDomes: [Bool] = []
    /// `tubes(runs:)` (OS1 B): how many of `pieces`, at its end, are the pucks' vertical pieces.
    public var pucks = 0
    /// ★ notes29 (his print orientation): the up the print file stands along, in the part's own coordinates (+Z: as placed).
    /// A bridge's level side and flat underside, and its pucks, stand along it, as the file's do; `OrganicVinePass` draws by
    /// it. Exactly +Z: every number as before.
    public var up = SIMD3<Float>(0, 0, 1)
    static let zUp = SIMD3<Float>(0, 0, 1)
    /// The print's up for the drawing (nil: +Z).
    public static func drawnUp(_ up: SIMD3<Double>?) -> SIMD3<Float> {
        guard let u = up else { return zUp }
        return SIMD3<Float>(Float(u.x), Float(u.y), Float(u.z))
    }
    /// The up as the shape keeps it (`tubes(up:)`): +Z exactly as given, any other made unit.
    public static func keptUp(_ up: SIMD3<Float>) -> SIMD3<Float> { up == zUp ? zUp : simd_normalize(up) }
    /// `cut(runs:surface:)`: each cap's cut (as Piece.cut), or empty (none cut).
    public var capCuts: [Cut?] = []
    /// ★ The part's surface near a piece, as the drawing cuts it: EVERY facet plane of the part's mesh within the piece's
    /// reach, (outward normal, w); a point x is outside a plane where dot(n, x) + w > 0. Convex there (`union` false): the
    /// part is inside them all; concave (true): inside any. Either way it is the part's own faceted surface where the piece
    /// lies, so two pieces that overlap are cut by the same facets (no step where one meets the other).
    public struct Cut: Equatable, Sendable {
        public var planes: [SIMD4<Float>]
        public var union: Bool
        public init(planes: [SIMD4<Float>], union: Bool) { self.planes = planes; self.union = union }
        /// Whether `p` is outside the part, as the shader reads it (cut_outside).
        public func outside(_ p: SIMD3<Float>) -> Bool {
            func out(_ P: SIMD4<Float>) -> Bool { simd_dot(SIMD3(P.x, P.y, P.z), p) + P.w > 1e-4 }
            return union ? planes.allSatisfy(out) : planes.contains(where: out)
        }
    }
    /// The most facets one cut holds (the shader's loop bound); a piece with more keeps the nearest.
    public static let maxCutPlanes = 16
    public var params = Params()
    public init() {}

    /// The most pieces one joint blends (the shader's loop bound); a joint with more keeps the nearest.
    public static let maxJointPieces = 12

    /// OS1 F (packed version 2): a run end that is not an end of the file's tube: the next run (at end B) or the previous run
    /// (at end A) continues the same tube there. No ball, no flat end: the two runs' rings meet as one mitre.
    public static let endContinues: UInt8 = 5
    /// OS1 B as the engine's file makes it (`weave_bridge_domes`, file_mesh_defaults): true, a bridge's rounded end is a puck;
    /// false, every bridge end flat (release 12's shape). Follows the engine taken for the install.
    public static let bridgeDomes = true

    /// ★ HIS RULE 11-19: "The drawing follows the print file. Always." The vines as the print file's tubes route makes them
    /// (core weave_tubes.cpp, read out by LatticeReview 01:39Z at 0ed96521; OS1 at e95b7852):
    ///   * each run one tube; the ring at a point has that point's width (core's weave_runs gives the two bars' mean at an
    ///     inner point where the file takes the larger: the one place the drawing can differ, by half a width step);
    ///     between rings the tube tapers straight;
    ///   * a point inside a run whose turn is at most 60 degrees is a MITRE: both bars' rings lie on the plane bisecting
    ///     them, so the tube bends with a clean elbow of its own width, no ball;
    ///   * a sharper turn ends the tube and starts it again: square ends, a round ball there;
    ///   * a run end is square, with a round half-sphere at a node, a loose or joined end; flat (no ball) where it runs
    ///     into the solid or is cut by the part's surface; OPEN where the run CONTINUES (OS1 F, end kind 5): the next or
    ///     previous run is the same tube, its ring the same mitre ring;
    ///   * a BRIDGE run (packed version 2's section, a run lying flatter than 30 degrees) is swept with its own section, the
    ///     file's D (a level flat underside, a round top) or square bar, its side level and its flat side down at every bar;
    ///     at an inner point the ring is the mean of where the two bars' sections meet the bisecting plane; its pieces end
    ///     flat. OS1 B: wherever a round tube's end would get a half-sphere (a node, a loose or joined end, a proud end, a
    ///     split at a sharp turn), the file adds a PUCK there: the section revolved about the vertical through the end point,
    ///     its underside one level disc at the bar's own underside height (c.z - r up.z, up.z the bar's horizontal share),
    ///     its side straight up to c.z, its top the D's round top revolved (a half-sphere; the square bar's top flat at
    ///     the bar's top height). One puck per place, the wider kept (a corner). Drawn as a vertical piece (its bottom flat)
    ///     and, for the D, the upper half of a ball (`capDomes`). (The file runs a flat end on by a fraction of a
    ///     millimetre into whatever it meets: not drawn.) A dome the print check held flat (R2) is drawn flat where the
    ///     Exact preview lists it (`heldFlat`); the Draft has no list.
    /// Ring side vectors are carried round each bend by the rotation that turns one bar onto the next, so the two rings
    /// at a mitre are the same ring point for point (no crack), across a continuing run too. Drawn by `OrganicVinePass`
    /// (its tube shader puts each ring on its end's plane: `tubeRingPoint` is the same arithmetic).
    /// ★ notes29: `up`, the print's up (a lattice laid standing on the face he kept): "vertical" and "level" above are along it.
    public static func tubes(runs: [LatticeLayoutSession.Run], mitreLimitDeg: Float = 60,
                             heldFlat: [SIMD3<Float>] = [], up: SIMD3<Float> = SIMD3(0, 0, 1)) -> OrganicVineShape {
        var s = OrganicVineShape()
        s.params.blendMM = 0
        let up = keptUp(up)
        s.up = up
        let cosLimit = cos(mitreLimitDeg * .pi / 180)
        func perp(_ t: SIMD3<Float>) -> SIMD3<Float> {
            simd_normalize(simd_cross(t, abs(t.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)))
        }
        func dir(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float>? {
            let d = b - a
            return simd_length(d) > 1e-6 ? simd_normalize(d) : nil
        }
        // OS1 B: the pucks, one per place (the file's map keyed at 1e-5 mm; the wider kept), in the order first met
        struct Puck { var c: SIMD3<Float>; var r: Float; var upZ: Float; var section: UInt8; var vine: Int32 }
        var pucks: [Puck] = [], puckAt: [SIMD3<Int64>: Int] = [:]
        // R2 (LatticeReview's ruling 11-21): the Exact preview lists the points where the print check held a dome flat
        func held(_ c: SIMD3<Float>) -> Bool { heldFlat.contains { simd_length($0 - c) < 1e-4 } }
        func puck(_ c: SIMD3<Float>, _ rad: Float, along t: SIMD3<Float>, section: UInt8, vine: Int32) {
            guard bridgeDomes, !held(c) else { return }   // flat there: the bar's own flat end, no puck
            let key = SIMD3<Int64>(Int64((c.x * 1e5).rounded()), Int64((c.y * 1e5).rounded()), Int64((c.z * 1e5).rounded()))
            let level = up == zUp ? (t.x * t.x + t.y * t.y).squareRoot() : simd_length(t - simd_dot(t, up) * up)   // ★ notes29
            let p = Puck(c: c, r: rad, upZ: level, section: section, vine: vine)
            if let i = puckAt[key] { if pucks[i].r < rad { pucks[i] = p } } else { puckAt[key] = pucks.count; pucks.append(p) }
        }
        // where the previous run's tube goes on into this one (OS1 F): its last side vector and direction
        var carry: (v: SIMD3<Float>, u: SIMD3<Float>, at: SIMD3<Float>)?
        for (vi, r) in runs.enumerated() {
            guard r.points.count >= 2 else { carry = nil; continue }
            let n = r.points.count
            let bridge = r.section == 1 || r.section == 2
            func ball(_ c: SIMD3<Float>, _ rad: Float) {
                s.caps.append(SIMD4(c, rad)); s.capVines.append(Int32(vi)); s.capDomes.append(false)
            }
            var u = [SIMD3<Float>](), keep = [Int]()
            for k in 0..<(n - 1) {
                if let d = dir(r.points[k], r.points[k + 1]) { u.append(d); keep.append(k) }
            }
            guard !u.isEmpty else { carry = nil; continue }
            // OS1 F: the runs this one continues (end A) and goes on into (end B), when they meet it there
            var prevU: SIMD3<Float>?, nextU: SIMD3<Float>?
            if r.endA == endContinues, keep.first == 0, let c = carry, simd_length(c.at - r.points[0]) < 1e-4 { prevU = c.u }
            if r.endB == endContinues, keep.last == n - 2, vi + 1 < runs.count {
                let nx = runs[vi + 1]
                if nx.endA == endContinues, nx.points.count >= 2, simd_length(nx.points[0] - r.points[n - 1]) < 1e-4 {
                    nextU = (1..<nx.points.count).lazy.compactMap { dir(nx.points[0], nx.points[$0]) }.first
                }
            }
            // per kept bar k: points keep[k] and keep[k]+1
            var v = perp(u[0])
            if let p = prevU, let c = carry { v = Self.carried(c.v, from: p, to: u[0]) }
            for (bi, k) in keep.enumerated() {
                let a = r.points[k], b = r.points[k + 1]
                let ra = r.widthMM[k] / 2, rb = r.widthMM[k + 1] / 2
                var q = Piece(a: a, ra: ra, b: b, rb: rb, vine: Int32(vi))
                q.va = v; q.vb = v
                // the plane each end's ring lies on: a mitre with a gentle neighbour, else square
                func plane(_ other: SIMD3<Float>?, outgoing: Bool) -> (SIMD3<Float>, Bool) {
                    guard let o = other else { return (u[bi], false) }
                    let c = simd_dot(outgoing ? u[bi] : o, outgoing ? o : u[bi])
                    if c >= cosLimit { return (simd_normalize(u[bi] + o), false) }
                    return (u[bi], true)   // a split: square, a ball
                }
                let prevBar = bi > 0 ? (keep[bi - 1] + 1 == k ? u[bi - 1] : nil) : prevU
                let nextBar = bi + 1 < keep.count ? (keep[bi + 1] == k + 1 ? u[bi + 1] : nil) : nextU
                var (na, splitA) = plane(prevBar, outgoing: false)
                var (nb, splitB) = plane(nextBar, outgoing: true)
                if bi == 0, prevU != nil, splitA { na = u[bi]; splitA = false }   // the file's tube goes on: never a ball
                if bi + 1 == keep.count, nextU != nil, splitB { nb = u[bi]; splitB = false }
                q.ta = na; q.tb = nb
                q.section = bridge ? r.section : 0
                if bridge {   // a bridge's piece ends flat; a split gets a puck (OS1 B)
                    q.flatA = splitA; q.flatB = splitB
                    s.pieces.append(q)
                    if splitA { puck(a, ra, along: u[bi], section: r.section, vine: Int32(vi)) }
                    if splitB { puck(b, rb, along: u[bi], section: r.section, vine: Int32(vi)) }
                } else {
                    s.pieces.append(q)
                    if splitA { ball(a, ra) }
                    if splitB { ball(b, rb) }
                }
                // carry the side vector onto the next bar: the rotation turning this bar onto it
                if let o = nextBar { v = Self.carried(v, from: u[bi], to: o) }
                else if bi + 1 < u.count { v = Self.carried(v, from: u[bi], to: u[bi + 1]) }
            }
            // the run's own ends: rounded (a ball, or a bridge's puck) unless it runs into the solid, is cut flush by the
            // part's surface, or goes on in the next run; a proud Surface end (OG2: proud_a / proud_b > 0) is rounded too
            // (core's Bar::End: 0 node, 1 solid, 2 surface, 3 loose, 4 joined, 5 continues; LatticeReview 11-21: any other
            // kind is flat, e.g. a dome the print check holds flat)
            func rounded(_ e: UInt8, proud: Float) -> Bool { e == 0 || e == 3 || e == 4 || (e == 2 && proud > 0) }
            let first = s.pieces.count - keep.count, last = s.pieces.count - 1
            if keep.first == 0 {
                if rounded(r.endA, proud: r.proudA) {
                    if bridge { s.pieces[first].flatA = true; puck(r.points[0], r.widthMM[0] / 2, along: u[0], section: r.section, vine: Int32(vi)) }
                    else { ball(r.points[0], r.widthMM[0] / 2) }
                } else if prevU == nil { s.pieces[first].flatA = true }
            }
            if keep.last == n - 2 {
                if rounded(r.endB, proud: r.proudB) {
                    if bridge { s.pieces[last].flatB = true; puck(r.points[n - 1], r.widthMM[n - 1] / 2, along: u[u.count - 1], section: r.section, vine: Int32(vi)) }
                    else { ball(r.points[n - 1], r.widthMM[n - 1] / 2) }
                } else if nextU == nil { s.pieces[last].flatB = true }
            }
            carry = nextU != nil ? (s.pieces[last].vb, u[u.count - 1], r.points[n - 1]) : nil   // the last piece's own side
        }
        // OS1 B: each puck, a vertical piece from its underside (its bottom flat) and, for the D, the upper half of a ball
        for p in pucks where p.r > 0 {
            var q: Piece, tall: Float
            if up == zUp {
                let zb = p.c.z - p.r * p.upZ
                let top = p.section == 1 ? p.c.z : zb + 2 * p.r * p.upZ
                q = Piece(a: SIMD3(p.c.x, p.c.y, zb), ra: p.r, b: SIMD3(p.c.x, p.c.y, top), rb: p.r, vine: p.vine)
                tall = top - zb
            } else {   // ★ notes29: the puck stands along the print's up
                let a = p.c - p.r * p.upZ * up
                let b = p.section == 1 ? p.c : a + 2 * p.r * p.upZ * up
                q = Piece(a: a, ra: p.r, b: b, rb: p.r, vine: p.vine)
                tall = simd_dot(b - a, up)
            }
            q.ta = up; q.tb = up
            q.flatA = true; q.flatB = p.section != 1
            if tall > 1e-6 { s.pieces.append(q); s.pucks += 1 }
            if p.section == 1 { s.caps.append(SIMD4(p.c, p.r)); s.capVines.append(p.vine); s.capDomes.append(true) }
        }
        return s
    }

    /// `v` turned by the rotation that takes unit `a` onto unit `b` (about a x b): parallel transport round a bend.
    static func carried(_ v: SIMD3<Float>, from a: SIMD3<Float>, to b: SIMD3<Float>) -> SIMD3<Float> {
        let axis = simd_cross(a, b)
        let sn = simd_length(axis), cs = simd_dot(a, b)
        var out: SIMD3<Float>
        if sn < 1e-6 {
            out = v
        } else {
            let k = axis / sn
            out = v * cs + simd_cross(k, v) * sn + k * simd_dot(k, v) * (1 - cs)
        }
        out -= simd_dot(out, b) * b
        if simd_length(out) < 1e-5 { out = simd_cross(b, abs(b.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)) }
        return simd_normalize(out)
    }

    /// A ring point exactly as `OrganicVinePass`'s tube shader places it (without its 16-gon scale): end `atB` of piece `q`
    /// at angle `ang`: the bar's own circle, pushed along the bar onto that end's plane.
    public static func tubeRingPoint(_ q: Piece, atB: Bool, angle ang: Float) -> SIMD3<Float> {
        let d = q.b - q.a
        let t = simd_length(d) > 1e-9 ? simd_normalize(d) : SIMD3<Float>(0, 0, 1)
        let c = atB ? q.b : q.a, rad = atB ? q.rb : q.ra
        let n = atB ? q.tb : q.ta
        var v = atB ? q.vb : q.va
        v = simd_normalize(v - simd_dot(v, t) * t)
        let w = simd_cross(t, v)
        let off = (cos(ang) * v + sin(ang) * w) * rad
        let dn = simd_dot(t, n)
        let sAlong = abs(dn) > 1e-3 ? -simd_dot(off, n) / dn : 0
        return c + off + t * sAlong
    }

    // ── the bridges' sections (core weave_tubes.cpp sweep_section, kinds 1 and 2), as the tube shader draws them ──

    /// A bridge's frame on a bar of direction `t` (the file's): its side level, square to the bar; up = t x side, upward.
    /// ★ notes29: level and upward along `printUp` (the print's up; +Z as placed, every number as before).
    public static func sectionFrame(_ t: SIMD3<Float>, fallback v: SIMD3<Float>, printUp: SIMD3<Float> = SIMD3(0, 0, 1))
        -> (side: SIMD3<Float>, up: SIMD3<Float>) {
        if printUp != zUp {
            var sd = simd_cross(printUp, t)
            if simd_length(sd) < 1e-6 { sd = v }
            sd = simd_normalize(sd)
            var up = simd_cross(t, sd)
            if simd_dot(up, printUp) < 0 { up = -up; sd = -sd }
            return (sd, up)
        }
        var sd = SIMD3<Float>(-t.y, t.x, 0)
        if simd_length(sd) < 1e-6 { sd = v }
        sd = simd_normalize(sd)
        var up = simd_cross(t, sd)
        if up.z < 0 { up = -up; sd = -sd }
        return (sd, up)
    }

    /// The section's outline point `j` (0 ..< sides, in order round it) at half width r, in (side, up). The D (section 1):
    /// its two bottom corners, then its round top from (r, 0) over to (-r, 0) in sides - 3 facets. The square (2): four points
    /// a side from its bottom-left corner.
    public static func sectionPoint(_ section: UInt8, _ j: Int, _ r: Float, sides: Int = 16) -> SIMD2<Float> {   // the pass's sides
        let j = j % sides
        if section == 1 {
            if j == 0 { return SIMD2(-r, -r) }
            if j == 1 { return SIMD2(r, -r) }
            let a = Float.pi * Float(j - 2) / Float(sides - 3)
            return SIMD2(r * cos(a), r * sin(a))
        }
        let per = sides / 4, f = Float(j % per) / Float(per), sideNo = j / per
        switch sideNo {
        case 0: return SIMD2(-r + 2 * r * f, -r)
        case 1: return SIMD2(r, -r + 2 * r * f)
        case 2: return SIMD2(r - 2 * r * f, r)
        default: return SIMD2(-r, r - 2 * r * f)
        }
    }

    /// A bridge's ring point exactly as the tube shader places it: outline point `j` at end `atB` of piece `q`, on that end's
    /// plane; at a mitre the mean of this bar's section and the neighbouring bar's, each pushed along its own bar onto the
    /// plane (the file's rule). The neighbour's direction is the plane's mirror of this one (the plane bisects the two).
    public static func sectionRingPoint(_ q: Piece, atB: Bool, _ j: Int, printUp: SIMD3<Float> = SIMD3(0, 0, 1)) -> SIMD3<Float> {
        let d = q.b - q.a
        let t = simd_length(d) > 1e-9 ? simd_normalize(d) : SIMD3<Float>(0, 0, 1)
        let c = atB ? q.b : q.a, rad = atB ? q.rb : q.ra
        let n = atB ? q.tb : q.ta
        let xy = sectionPoint(q.section, j, rad)
        func pushed(_ t: SIMD3<Float>) -> SIMD3<Float> {
            let f = sectionFrame(t, fallback: q.va, printUp: printUp)
            let off = f.side * xy.x + f.up * xy.y
            let dn = simd_dot(t, n)
            return c + off + t * (abs(dn) > 1e-3 ? -simd_dot(off, n) / dn : 0)
        }
        let dn = simd_dot(t, n)
        let t2 = 2 * dn * n - t
        if simd_dot(t2, t) < 0.99999, simd_length(t2) > 0.5 { return 0.5 * (pushed(t) + pushed(simd_normalize(t2))) }
        return pushed(t)
    }

    // ── the flat cut (his 11-20 skin note) ──

    /// The part's surface, for cutting the vines flat where they cross it (the print file trims every tube to the part:
    /// core weave_tubes.cpp, OF3). Triangles with their planes (outward), found by a 2 mm hash.
    public struct CutSurface: Sendable {
        struct Tri: Sendable {
            var a, b, c: SIMD3<Float>; var plane: SIMD4<Float>; var face: Int32
            var lo: SIMD3<Float> { simd_min(a, simd_min(b, c)) }
            var hi: SIMD3<Float> { simd_max(a, simd_max(b, c)) }
        }
        var tris: [Tri] = []
        var hash: [SIMD3<Int32>: [Int32]] = [:]
        static let cell: Float = 2
        static func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((p / cell).rounded(.down)) }

        /// `vertices` xyz, `indices` three per triangle, `faceIDs` one per triangle (optional). Outward is read from the
        /// mesh's signed volume, so either winding works.
        public init(vertices: [Float], indices: [Int32], faceIDs: [Int32] = []) {
            let nt = indices.count / 3
            func v(_ i: Int32) -> SIMD3<Float> { let k = 3 * Int(i); return SIMD3(vertices[k], vertices[k + 1], vertices[k + 2]) }
            var vol: Float = 0
            for t in 0..<nt {
                let a = v(indices[3 * t]), b = v(indices[3 * t + 1]), c = v(indices[3 * t + 2])
                vol += simd_dot(a, simd_cross(b, c))
            }
            let sign: Float = vol < 0 ? -1 : 1
            tris.reserveCapacity(nt)
            for t in 0..<nt {
                let a = v(indices[3 * t]), b = v(indices[3 * t + 1]), c = v(indices[3 * t + 2])
                let cr = simd_cross(b - a, c - a)
                let l = simd_length(cr)
                guard l > 1e-12 else { continue }
                let n = sign * cr / l
                let k = Int32(tris.count)
                tris.append(Tri(a: a, b: b, c: c, plane: SIMD4(n, -simd_dot(n, a)), face: t < faceIDs.count ? faceIDs[t] : -1))
                let lo = Self.key(simd_min(a, simd_min(b, c))), hi = Self.key(simd_max(a, simd_max(b, c)))
                for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x { hash[SIMD3(x, y, z), default: []].append(k) } } }
            }
        }

        /// The nearest point of triangle t to p (Ericson, Real-Time Collision Detection 5.1.5).
        static func closest(_ p: SIMD3<Float>, _ t: Tri) -> SIMD3<Float> {
            let a = t.a, b = t.b, c = t.c
            let ab = b - a, ac = c - a, ap = p - a
            let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
            if d1 <= 0 && d2 <= 0 { return a }
            let bp = p - b
            let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
            if d3 >= 0 && d4 <= d3 { return b }
            let vc = d1 * d4 - d3 * d2
            if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
            let cp = p - c
            let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
            if d6 >= 0 && d5 <= d6 { return c }
            let vb = d5 * d2 - d1 * d6
            if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
            let va = d3 * d6 - d5 * d4
            if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
            let den = 1 / (va + vb + vc)
            return a + ab * (vb * den) + ac * (vc * den)
        }

        /// The triangles within `reach` of any of `pts`, nearest first.
        func near(_ pts: [SIMD3<Float>], reach: Float) -> [(d: Float, t: Int32)] {
            guard !tris.isEmpty, let first = pts.first else { return [] }
            var lo = first, hi = first
            for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            let boxLo = lo - reach, boxHi = hi + reach
            let kl = Self.key(boxLo), kh = Self.key(boxHi)
            var cand: [Int32] = []
            for z in kl.z...kh.z { for y in kl.y...kh.y { for x in kl.x...kh.x {
                if let ts = hash[SIMD3(x, y, z)] { cand += ts }
            } } }
            guard !cand.isEmpty else { return [] }
            cand.sort()
            var out: [(d: Float, t: Int32)] = []
            var last: Int32 = -1
            for t in cand where t != last {
                last = t
                let tri = tris[Int(t)]
                // cheap rejects first: the triangle's box, then its plane (a lower bound on the distance to it)
                if any(tri.lo .> boxHi) || any(tri.hi .< boxLo) { continue }
                let n = SIMD3(tri.plane.x, tri.plane.y, tri.plane.z)
                var bound = Float.greatestFiniteMagnitude
                for p in pts { bound = Swift.min(bound, abs(simd_dot(n, p) + tri.plane.w)) }
                if bound > reach { continue }
                var d = Float.greatestFiniteMagnitude
                for p in pts { d = Swift.min(d, simd_length(p - Self.closest(p, tri))) }
                if d <= reach { out.append((d, t)) }
            }
            return out.sorted { $0.d < $1.d }
        }

        /// Whether triangle j lies behind (or on) triangle i's plane: the pair is CONVEX there (the part is the two
        /// half-spaces' common part); in front, CONCAVE (their union).
        func convex(_ i: Int32, _ j: Int32) -> Bool {
            let p = tris[Int(i)].plane, q = tris[Int(j)]
            return simd_dot(SIMD3(p.x, p.y, p.z), (q.a + q.b + q.c) / 3) + p.w <= 1e-4
        }
        func samePlane(_ i: Int32, _ j: Int32) -> Bool {
            let p = tris[Int(i)].plane, q = tris[Int(j)].plane
            return simd_dot(SIMD3(p.x, p.y, p.z), SIMD3(q.x, q.y, q.z)) > 0.99999 && abs(p.w - q.w) < 1e-4
        }
        /// Every distinct facet plane within `reach` of `pts`, nearest first, as one Cut: the nearest facet, then each further
        /// facet that keeps the set of one kind (each convex to all the others: the part inside them all; each concave to all
        /// the others: inside any), at most `maxCutPlanes`. nil when the surface is not within reach.
        func cut(near pts: [SIMD3<Float>], reach: Float) -> Cut? {
            let all = near(pts, reach: reach)
            guard let first = all.first?.t else { return nil }
            var chosen: [Int32] = [first]
            var union: Bool?
            for c in all.dropFirst() where chosen.count < OrganicVineShape.maxCutPlanes {
                guard !chosen.contains(where: { samePlane($0, c.t) }) else { continue }
                let conv = chosen.allSatisfy { convex($0, c.t) && convex(c.t, $0) }
                let conc = chosen.allSatisfy { !convex($0, c.t) && !convex(c.t, $0) }
                if let u = union {
                    if u ? !conc : !conv { continue }
                } else if conv {
                    union = false
                } else if conc {
                    union = true
                } else {
                    continue
                }
                chosen.append(c.t)
            }
            return Cut(planes: chosen.map { tris[Int($0)].plane }, union: union ?? false)
        }
    }

    /// ★ The flat cut: every piece and round end that reaches the part's surface gets that surface's plane(s), so the drawing
    /// cuts it there and paints the cut face in the vine's colour, as the print file trims it. A run the file lets stand
    /// proud (OG2: a proud end, or a run along an open face with depth variation) is left whole.
    public mutating func cut(runs: [LatticeLayoutSession.Run], surface: CutSurface) {
        func free(_ vine: Int32) -> Bool {
            let i = Int(vine)
            return i < 0 || i >= runs.count || runs[i].standsProud || runs[i].marks.contains(.along)
        }
        for i in pieces.indices {
            let q = pieces[i]
            pieces[i].cut = nil
            guard !free(q.vine) else { continue }
            // its reach: the widest its section gets from the centre line (the square bar's corner), and past an open end
            // the radius on (the next piece or the ball there: the shader takes the cut face one radius past such an end)
            let widest = Swift.max(q.ra, q.rb) * (q.section == 0 ? 1.02 : 1.4143)
            let len = simd_length(q.b - q.a)
            let m = Swift.max(1, Int((len / 0.5).rounded(.up)))
            var pts = (0...m).map { q.a + (q.b - q.a) * (Float($0) / Float(m)) }
            if len > 1e-6 {
                let t = (q.b - q.a) / len
                if !q.flatA { pts.insert(q.a - t * q.ra, at: 0) }
                if !q.flatB { pts.append(q.b + t * q.rb) }
            }
            pieces[i].cut = surface.cut(near: pts, reach: widest + 0.5 * len / Float(m) + 0.01)
        }
        capCuts = []
        guard capVines.count == caps.count else { return }
        var out = [Cut?](repeating: nil, count: caps.count)
        for (k, c) in caps.enumerated() where !free(capVines[k]) {
            out[k] = surface.cut(near: [SIMD3(c.x, c.y, c.z)], reach: c.w + 0.01)
        }
        if out.contains(where: { $0 != nil }) { capCuts = out }
    }

    /// Release (10)'s drawing (option A of LatticeReview's sheet for him): kept so it can be shown and compared.
    /// Release (10)'s round struts: each bar straight, ONE width (its two points' mean, as `LatticeLayoutPreview.segments`),
    /// a round ball at every point (the widest bar there), a plain union, nothing blended, nothing curved. It is the shape of
    /// today's print file. Drawn by `OrganicVinePass`'s fast tubes and sphere ends, so Grown and the net skin get it too
    /// (release (10) gave them six-sided tubes with flat ends). The smooth blended look (`init(runs:)`) is parked for v2 (his
    /// sheet "TopOpt: ideas for v2", row "Smooth, blended Organic vines").
    public static func capsules(runs: [LatticeLayoutSession.Run]) -> OrganicVineShape {
        var s = OrganicVineShape()
        s.params.blendMM = 0
        for (vi, r) in runs.enumerated() where r.points.count >= 2 {
            let n = r.points.count
            var ball = [Float](repeating: 0, count: n)
            for i in 0..<(n - 1) {
                let a = r.points[i], b = r.points[i + 1]
                let rad = 0.25 * (r.widthMM[i] + r.widthMM[i + 1])
                var q = Piece(a: a, ra: rad, b: b, rb: rad, vine: Int32(vi))
                let d = b - a
                let t = simd_length(d) > 1e-9 ? simd_normalize(d) : SIMD3<Float>(0, 0, 1)
                let v = simd_normalize(simd_cross(t, abs(t.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)))
                q.ta = t; q.tb = t; q.va = v; q.vb = v   // a plain cylinder: both rings square to the bar
                s.pieces.append(q)
                ball[i] = Swift.max(ball[i], rad); ball[i + 1] = Swift.max(ball[i + 1], rad)
            }
            for i in 0..<n { s.caps.append(SIMD4(r.points[i], ball[i])) }
        }
        return s
    }

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

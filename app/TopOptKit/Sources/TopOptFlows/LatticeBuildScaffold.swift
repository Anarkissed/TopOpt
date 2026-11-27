// LatticeBuildScaffold — ★ notes30, his word on the strut lattice's build for SLOW parts (2026-11-26): "open up the walls first,
// then start with the vertical struts and horizontal struts - like having scaffolding put in place"; "I don't think scaffolds
// ever differ in heights"; "little stair/diagonal sections to really hammer in the 'Scaffold' effect"; "we can remove the
// scaffolding afterwards". The scaffold's look, made from the ROUGH cut-open (LatticeLayoutSession.gridRough: the lattice's
// area before its cells are laid) the moment it is made, before the lay — the same for every lay that shows it (judged slow at
// the ask, or switched to a second after it), any part, any view:
//   * ONE EVEN GRID: uprights on square bays, every lift one height (a lift is one of the timelapse's floors, so the real floors
//     replace the scaffold lift for lift);
//   * ★ his verdict on the clips (11-26 22:40): "make all animation have scaffolding throughout the entire hole" — the grid
//     FILLS the whole opened lattice area, not its rim;
//   * ★ (22:30) "There needs to be connecting pieces to the scaffolding to make a 'floor' outline. It can't just float." —
//     each lift is the grid squares inside the area at its height (one connected piece, standing on the lift below's); every
//     level is a FLOOR of ledgers over the squares of the lifts below and above it (its outline one closed loop round them,
//     stepped, moving in or out lift by lift on a curved part; where the area steps in or out, the squares of the step are part
//     of it: a landing); every upright stands on a floor and reaches the next; nothing ends in mid-air;
//   * diagonal braces in some bays of each lift's outer frames, turning each lift (a zig-zag); one stair tower (a flight a
//     lift in one closed bay, turning back each lift, with its treads);
//   * ★ (22:40) "please ensure the floors are generated before the walls ... the walls go up before the stairs. It should go:
//     floors and walls, then stairs for the entire level." — each member carries its own snap (`code`): a lift's FLOOR, then
//     its WALLS (uprights and braced frames, rising to the next level), then its STAIRS; the top lift's roof last;
//   * THIN and PALE (`widthShare`, `colour`): clearly temporary, never mistakable for the lattice's struts; at most
//     `membersMost` members (the bays grow when a part would need more: the frame rate kept);
//   * only where it stands whole in the area (every member sampled along its length: never out through a wall).
// Pure: the rough map and the frame in, the members and their snaps out (7 floats each, as core's bars; one code each, in the
// bars' flags). The renderer draws them with the bars' own pass (LatticeLayoutBarsPass: `bar_build_hidden` reads the code), one
// pale colour, lift by lift by LatticeBuildTimelapse.
import Foundation
import simd

enum LatticeBuildScaffold {
    // MARK: the look (his to tune)

    /// The bays: one even grid, each bay this share of a lift's height (1: square bays) — narrower only where the area is
    /// thinner than one bay (never under `bayLeastShare`: then no scaffold), wider when the part would need more than
    /// `membersMost` members.
    static let bayShare: Float = 1.0
    static let bayLeastShare: Float = 0.3
    static let membersMost = 8000
    /// A member's width: this share of a lift's height, between `widthLeastMM` and `widthMostMM` — thin, never a strut's.
    static let widthShare: Float = 0.035
    static let widthLeastMM: Float = 0.3
    static let widthMostMM: Float = 0.8
    /// Pale straw: clearly temporary, never the lattice's colour.
    static let colour = SIMD4<Float>(0.96, 0.89, 0.60, 1)
    /// A diagonal brace in every `braceEvery`-th bay of a lift's outer frames, its direction turning each lift (a zig-zag).
    static let braceEvery = 3
    /// The stair: one flight a lift in one bay, turning back each lift (a zig-zag stair), this many treads a flight.
    static let stairTreads = 4
    /// The stair's near stringer this share of a bay inside its bay, its width this share of a bay.
    static let stairInsetShare: Float = 0.15
    static let stairWidthShare: Float = 0.4
    /// The ground floor stands this share of a lift over the area's floor, the roof this share under its top (both on the
    /// area's own edge otherwise).
    static let edgeShare: Float = 0.02
    /// The grid kept this share of a bay inside the area's box.
    static let edgeInsetShare: Float = 0.05
    /// The rough cut-open's voxel: this many times the exact map's (`LatticeLayoutPreview.mapGeometry`): a few tens of
    /// milliseconds before the lay, never a wait.
    static let roughVoxelScale: Float = 2
    /// A member is in the area when these points along it are (open and inside the part).
    static let samples: [Float] = [0.04, 0.27, 0.5, 0.73, 0.96]

    /// RED CONTROLS (tests): the rim alone (the clips of 11-26 22:15); the walls before the floor; no landing (a level only
    /// its own lift's floor, the stair without its bay — the 22:15 clips' floating pieces).
    nonisolated(unsafe) static var controlRimOnly = false
    nonisolated(unsafe) static var controlWallsFirst = false
    nonisolated(unsafe) static var controlNoLandings = false

    // MARK: the rough cut-open

    /// The rough cut-open as the engine made it: 2 signed bytes a voxel (open, inside), x fastest; voxel (0,0,0)'s centre at
    /// `origin`, model mm.
    struct Rough: Sendable {
        var origin: SIMD3<Float>
        var voxel: Float
        var dims: SIMD3<Int32>
        var rg: [Int8]

        var isWhole: Bool { dims.x > 0 && dims.y > 0 && dims.z > 0 && rg.count == 2 * Int(dims.x) * Int(dims.y) * Int(dims.z) }

        /// `p` lies in the lattice's area (its nearest voxel open and inside the part).
        func inArea(_ p: SIMD3<Float>) -> Bool {
            let q = (p - origin) / voxel
            let i = Int(q.x.rounded()), j = Int(q.y.rounded()), k = Int(q.z.rounded())
            guard i >= 0, j >= 0, k >= 0, i < Int(dims.x), j < Int(dims.y), k < Int(dims.z) else { return false }
            let v = 2 * ((k * Int(dims.y) + j) * Int(dims.x) + i)
            return rg[v] > 0 && rg[v + 1] > 0
        }

        /// The area's box in the part's own coordinates (nil: nothing open).
        var openBox: (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
            guard isWhole else { return nil }
            let nx = Int(dims.x), ny = Int(dims.y), nz = Int(dims.z)
            var lo = SIMD3<Int>(repeating: .max), hi = SIMD3<Int>(repeating: .min)
            var v = 0
            for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
                if rg[v] > 0 && rg[v + 1] > 0 {
                    lo = pointwiseMin(lo, SIMD3(i, j, k)); hi = pointwiseMax(hi, SIMD3(i, j, k))
                }
                v += 2
            }}}
            guard lo.x <= hi.x else { return nil }
            let h = SIMD3<Float>(repeating: voxel / 2)
            return (origin + SIMD3<Float>(lo) * voxel - h, origin + SIMD3<Float>(hi) * voxel + h)
        }
    }

    /// What is made off the main thread from the rough cut-open: the members (7 floats each) and their snaps, the frame they
    /// stand on, its plan (`Layout`), and the map drawn (smoothed, the solid view; nil in X-ray).
    struct Made: Sendable {
        var frame: LatticeBuildTimelapse.Frame
        var layout: Layout
        var rough: Rough
        var drawn: [Int8]?
        var bars: [Float] { layout.bars }
        var members: Int { layout.bars.count / 7 }
    }

    /// The scaffold on the rough cut-open `r`, its floors along `up`, its bays along `across` (the view's, or the print's):
    /// nil — no area.
    static func make(_ r: Rough, up: SIMD3<Float>, across: SIMD3<Float>, walls: Bool) -> Made? {
        guard let box = r.openBox else { return nil }
        let f = LatticeBuildTimelapse.Frame(lo: box.lo, hi: box.hi, up: up, across: across)
        let dp = f.depth
        var dLo = Float.greatestFiniteMagnitude, dHi = -dLo
        for i in 0..<8 {
            let p = SIMD3<Float>(i & 1 == 0 ? box.lo.x : box.hi.x, i & 2 == 0 ? box.lo.y : box.hi.y, i & 4 == 0 ? box.lo.z : box.hi.z)
            let d = simd_dot(dp, p)
            dLo = Swift.min(dLo, d); dHi = Swift.max(dHi, d)
        }
        let plan = layout(f, depthLow: dLo, depthW: Swift.max(dHi - dLo, 1e-3), inArea: r.inArea)
        let drawn = walls ? LatticeLayoutSolidGrid.cutSmoothed(r.rg, dims: r.dims) : nil
        return Made(frame: f, layout: plan, rough: r, drawn: drawn)
    }

    /// The scaffold the show holds and the renderer draws with its own bars pass: its pieces in the order they come (the
    /// timelapse draws a run of them), and how many each lift has.
    struct Drawing {
        let token: Int
        let inputs: LatticeLayoutBarsInputs
        let frame: LatticeBuildTimelapse.Frame
        let liftPieces: [Int]
        var members: Int { inputs.bars.count / 7 }
    }
    static func drawing(_ m: Made, token: Int) -> Drawing {
        let n = m.members
        let map = m.drawn.map { LatticeLayoutSolidGrid(token: token, origin: m.rough.origin, voxel: m.rough.voxel,
                                                       dims: m.rough.dims, rg: $0, smooth: true) }
        let inputs = LatticeLayoutBarsInputs(token: token, bars: m.layout.bars, solid: map, flags: [],
                                             colours: [SIMD4<Float>](repeating: colour, count: n), colourKey: token)
        return Drawing(token: token, inputs: inputs, frame: m.frame, liftPieces: m.layout.liftPieces)
    }

    // MARK: the order: a lift's floor, then its walls, then its stairs (the top lift's roof last) — a piece at a time

    /// What a piece is (tests: the order is his).
    enum Part: Int, Sendable { case floor = 0, walls = 1, stairs = 2, roof = 3 }

    /// A level's ledgers in the order they come: its floor's outline walked round from its front-left node, then the rest row by
    /// row, front to back, each row left to right.
    static func walked(_ edges: Set<Edge>, round squares: Set<Square>) -> [Edge] {
        let rim = outline(squares).intersection(edges)
        func key(_ e: Edge) -> (Int, Int, Int, Int) { (Swift.min(e.a.j, e.b.j), e.a.j == e.b.j ? 0 : 1, Swift.min(e.a.i, e.b.i), e.b.j) }
        var byNode: [Node: [Edge]] = [:]
        for e in rim { byNode[e.a, default: []].append(e); byNode[e.b, default: []].append(e) }
        var left = rim, out: [Edge] = []
        while let start = left.flatMap({ [$0.a, $0.b] }).min(by: { ($0.j, $0.i) < ($1.j, $1.i) }) {
            var at = start
            while let e = (byNode[at] ?? []).filter({ left.contains($0) }).min(by: { key($0) < key($1) }) {
                left.remove(e); out.append(e)
                at = e.a == at ? e.b : e.a
            }
        }
        return out + edges.subtracting(rim).sorted { key($0) < key($1) }
    }

    // MARK: the plan

    /// A member's width on lifts `liftH` tall.
    static func width(liftH: Float) -> Float { Swift.min(widthMostMM, Swift.max(widthLeastMM, liftH * widthShare)) }

    /// A node of the grid (`i` across, `j` along the depth), a square of it (by its low corner), an edge between two nodes.
    struct Node: Hashable, Sendable { var i: Int; var j: Int }
    struct Square: Hashable, Sendable { var i: Int; var j: Int }
    struct Edge: Hashable, Sendable {
        let a: Node, b: Node
        init(_ p: Node, _ q: Node) {
            if (p.i, p.j) < (q.i, q.j) { a = p; b = q } else { a = q; b = p }
        }
    }
    /// A square's four edges: its front and back (across), its left and right (along the depth).
    static func edges(_ q: Square) -> [Edge] {
        let n00 = Node(i: q.i, j: q.j), n10 = Node(i: q.i + 1, j: q.j), n01 = Node(i: q.i, j: q.j + 1), n11 = Node(i: q.i + 1, j: q.j + 1)
        return [Edge(n00, n10), Edge(n01, n11), Edge(n00, n01), Edge(n10, n11)]
    }
    /// The outline of a lift's squares: the edges between a square of it and one outside it (one closed loop round a piece
    /// without holes) — its outer frames.
    static func outline(_ set: Set<Square>) -> Set<Edge> {
        var out = Set<Edge>()
        for q in set {
            let e = edges(q)
            if !set.contains(Square(i: q.i, j: q.j - 1)) { out.insert(e[0]) }
            if !set.contains(Square(i: q.i, j: q.j + 1)) { out.insert(e[1]) }
            if !set.contains(Square(i: q.i - 1, j: q.j)) { out.insert(e[2]) }
            if !set.contains(Square(i: q.i + 1, j: q.j)) { out.insert(e[3]) }
        }
        return out
    }
    /// The ledgers a floor lays over a lift's squares: every edge of them (the grid through the whole area); RED CONTROL
    /// `controlRimOnly`: the outline alone.
    static func floorEdges(_ set: Set<Square>) -> Set<Edge> {
        if controlRimOnly { return outline(set) }
        var out = Set<Edge>()
        for q in set { out.formUnion(edges(q)) }
        return out
    }

    /// The scaffold planned on a frame: its grid; each lift's squares (inside the area at its height: their uprights whole,
    /// their edges whole at its foot and its top — one connected piece, standing on the lift below's); each level's floor
    /// (level `l` is lift `l`'s floor and lift `l − 1`'s top: the ledgers over both lifts' squares, the step between them a
    /// landing); the stair's bay and the lifts it climbs; the members, each with its snap.
    struct Layout: Sendable {
        var bay: Float = 0
        var nA = 0, nD = 0
        /// Node (0, 0) along across and along the depth (node (i, j) stands at a0 + i × bay, d0 + j × bay).
        var a0: Float = 0, d0: Float = 0
        /// The lowest lift standing (its floor on the area's floor); nil — no scaffold.
        var ground: Int?
        var squares: [Set<Square>] = []
        /// Per level 0…floors: its floor's ledgers, the height they stand at, and whose snap they are (lift, part).
        var levels: [Set<Edge>] = []
        var levelHeights: [Float] = []
        var stair: Square?
        var flights: Set<Int> = []
        /// The members in the order they come (a lift's floor, walls, stairs; the top lift's roof last), what each is, and how
        /// many each lift has.
        var bars: [Float] = []
        var parts: [Part] = []
        var liftPieces: [Int] = []
        var low: Float = 0, liftH: Float = 1
        func height(_ l: Int) -> Float { low + Float(l) * liftH }
        var members: Int { bars.count / 7 }
    }

    /// The scaffold's plan and members on `f` (its floors the lifts), every member whole in the area (`inArea`); `depthLow`,
    /// `depthW` — the area along the frame's depth. At most `membersMost` members (the bays grow by a quarter until it fits).
    static func layout(_ f: LatticeBuildTimelapse.Frame, depthLow dLo: Float, depthW dW: Float,
                       inArea: (SIMD3<Float>) -> Bool) -> Layout {
        var scale: Float = 1
        var L = layoutOnce(f, depthLow: dLo, depthW: dW, inArea: inArea, bayScale: scale)
        var tries = 0
        while L.members > membersMost, tries < 8 {
            scale *= 1.25; tries += 1
            L = layoutOnce(f, depthLow: dLo, depthW: dW, inArea: inArea, bayScale: scale)
        }
        return L
    }

    private static func layoutOnce(_ f: LatticeBuildTimelapse.Frame, depthLow dLo: Float, depthW dW: Float,
                                   inArea: (SIMD3<Float>) -> Bool, bayScale: Float) -> Layout {
        var L = Layout()
        L.low = f.low; L.liftH = f.floorH
        let up = f.up, ac = f.across, dp = f.depth
        let s0 = Swift.max(f.floorH * bayShare * bayScale, 1e-3), inset = edgeInsetShare * s0
        let s = Swift.min(s0, f.acrossW - 2 * inset, dW - 2 * inset)
        guard f.floors > 0, s >= bayLeastShare * f.floorH else { return L }
        let nA = Swift.min(200, Swift.max(1, Int(((f.acrossW - 2 * inset) / s + 1e-4).rounded(.down))))
        let nD = Swift.min(200, Swift.max(1, Int(((dW - 2 * inset) / s + 1e-4).rounded(.down))))
        let a0 = f.acrossLow + (f.acrossW - Float(nA) * s) / 2, d0 = dLo + (dW - Float(nD) * s) / 2
        L.bay = s; L.nA = nA; L.nD = nD; L.a0 = a0; L.d0 = d0
        let floors = f.floors, e = edgeShare * f.floorH
        func at(_ a: Float, _ d: Float, _ h: Float) -> SIMD3<Float> { ac * (a0 + a * s) + dp * (d0 + d * s) + up * h }
        func node(_ n: Node, _ h: Float) -> SIMD3<Float> { at(Float(n.i), Float(n.j), h) }
        func fits(_ p: SIMD3<Float>, _ q: SIMD3<Float>) -> Bool { samples.allSatisfy { inArea(p + (q - p) * $0) } }
        func edgeFits(_ x: Edge, _ h: Float) -> Bool { fits(node(x.a, h), node(x.b, h)) }
        let H = { (l: Int) in L.height(l) }
        // a lift's foot and top, where its floors are tried (the area's own floor and roof a hair inside)
        let foot = { (k: Int) in k == 0 ? H(0) + e : H(k) }, top = { (k: Int) in k == floors - 1 ? H(floors) - e : H(k + 1) }

        // each lift's squares inside the area
        var candidates: [Set<Square>] = []
        for k in 0..<floors {
            var stand = [[Bool]](repeating: [Bool](repeating: false, count: nD + 1), count: nA + 1)
            for i in 0...nA { for j in 0...nD { stand[i][j] = fits(at(Float(i), Float(j), H(k)), at(Float(i), Float(j), H(k + 1))) } }
            var set = Set<Square>()
            for i in 0..<nA { for j in 0..<nD where stand[i][j] && stand[i + 1][j] && stand[i][j + 1] && stand[i + 1][j + 1] {
                let q = Square(i: i, j: j)
                if edges(q).allSatisfy({ edgeFits($0, foot(k)) && edgeFits($0, top(k)) }) { set.insert(q) }
            }}
            candidates.append(set)
        }
        // one connected piece a lift: the ground lift's largest; above it, the piece standing most on the lift below (or
        // touching it); none — the scaffold stops there
        func pieces(_ set: Set<Square>) -> [Set<Square>] {
            var left = set, out: [Set<Square>] = []
            while let seed = left.first {
                var piece: Set<Square> = [seed], todo = [seed]
                left.remove(seed)
                while let q = todo.popLast() {
                    for n in [Square(i: q.i + 1, j: q.j), Square(i: q.i - 1, j: q.j), Square(i: q.i, j: q.j + 1), Square(i: q.i, j: q.j - 1)]
                    where left.contains(n) { left.remove(n); piece.insert(n); todo.append(n) }
                }
                out.append(piece)
            }
            return out
        }
        func touches(_ p: Set<Square>, _ below: Set<Square>) -> Bool {
            p.contains { q in (-1...1).contains { di in (-1...1).contains { dj in below.contains(Square(i: q.i + di, j: q.j + dj)) } } }
        }
        var below = Set<Square>()
        for k in 0..<floors {
            let ps = pieces(candidates[k])
            var pick: Set<Square>?
            if L.ground == nil {
                pick = ps.max { ($0.count, -($0.map(\.j).min() ?? 0)) < ($1.count, -($1.map(\.j).min() ?? 0)) }
                if pick != nil { L.ground = k }
            } else if !below.isEmpty {
                let scored = ps.map { ($0, $0.intersection(below).count) }
                pick = scored.filter { $0.1 > 0 }.max { ($0.1, $0.0.count) < ($1.1, $1.0.count) }?.0
                    ?? ps.filter { touches($0, below) }.max { $0.count < $1.count }
            }
            L.squares.append(pick ?? [])
            below = pick ?? []
        }
        guard let ground = L.ground else { return L }

        // the stair tower: the bay most lifts share (the front row first, then the left), a flight in each lift it stands in
        var count: [Square: Int] = [:]
        for set in L.squares { for q in set { count[q, default: 0] += 1 } }
        L.stair = count.max { a, b in (a.value, -a.key.j, -a.key.i) < (b.value, -b.key.j, -b.key.i) }?.key
        func flight(_ k: Int, _ q: Square) -> [(SIMD3<Float>, SIMD3<Float>)] {
            let turn = k % 2 == 1
            let d1 = Float(q.j) + stairInsetShare, d2 = d1 + stairWidthShare
            let u0: Float = turn ? 1 : 0, u1: Float = turn ? 0 : 1
            let h0 = H(k), h1 = H(k + 1)
            var out = [(at(Float(q.i) + u0, d1, h0), at(Float(q.i) + u1, d1, h1)), (at(Float(q.i) + u0, d2, h0), at(Float(q.i) + u1, d2, h1))]
            for t in 1...Swift.max(1, stairTreads) {
                let x = Float(t) / Float(stairTreads + 1)
                let u = u0 + (u1 - u0) * x, h = h0 + (h1 - h0) * x
                out.append((at(Float(q.i) + u, d1, h), at(Float(q.i) + u, d2, h)))
            }
            return out
        }
        var flights: [Int: [(SIMD3<Float>, SIMD3<Float>)]] = [:]
        if let st = L.stair {
            for k in 0..<floors where L.squares[k].contains(st) {
                let m = flight(k, st)
                if m.allSatisfy({ fits($0.0, $0.1) }) { flights[k] = m }
            }
        }
        L.flights = Set(flights.keys)
        let stairBay = L.stair.map { Set(edges($0)) } ?? []

        // each level's floor: the ledgers over the lifts below and above it (the step between them its landing), the stair's
        // bay; lift l's FLOOR, or — nothing standing above — the lift below's roof
        L.levels = [Set<Edge>](repeating: [], count: floors + 1)
        L.levelHeights = [Float](repeating: 0, count: floors + 1)
        var levelSquares = [Set<Square>](repeating: [], count: floors + 1)
        for l in ground...floors {
            let lower: Set<Square> = l >= 1 ? L.squares[l - 1] : [], upper: Set<Square> = l < floors ? L.squares[l] : []
            if lower.isEmpty && upper.isEmpty { continue }
            var set = floorEdges(upper)
            if !controlNoLandings || upper.isEmpty { set.formUnion(floorEdges(lower)) }
            if controlRimOnly, !controlNoLandings, !lower.isEmpty, !upper.isEmpty {   // (the rim alone: its landing, as 22:15's)
                for q in lower.symmetricDifference(upper) { set.formUnion(edges(q)) }
            }
            if !controlNoLandings, L.flights.contains(l) || L.flights.contains(l - 1) { set.formUnion(stairBay) }
            L.levels[l] = set
            L.levelHeights[l] = l == ground ? H(l) + e : (upper.isEmpty ? H(l) - e : H(l))
            levelSquares[l] = lower.union(upper)
        }

        // the members, a lift at a time in the order they come — ★ his (23:50) "a piece at a time": its FLOOR's ledgers walked
        // round its outline then across, its WALLS' uprights one by one (front row first, left to right) then its braces, its
        // STAIRS' stringers then treads one by one; the top lift's roof last (RED CONTROL `controlWallsFirst`: walls first)
        let w = width(liftH: f.floorH)
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ p: Part) {
            L.bars += [a.x, a.y, a.z, b.x, b.y, b.z, w]
            L.parts.append(p)
        }
        func deck(_ l: Int, _ p: Part) {
            let h = L.levelHeights[l]
            for x in walked(L.levels[l], round: levelSquares[l]) { add(node(x.a, h), node(x.b, h), p) }
        }
        for k in 0..<floors {
            let before = L.parts.count
            defer { L.liftPieces.append(L.parts.count - before) }
            guard !L.squares[k].isEmpty else { continue }
            func walls() {
                var posts = Set<Node>()
                for x in floorEdges(L.squares[k]) { posts.insert(x.a); posts.insert(x.b) }
                if !controlNoLandings, L.flights.contains(k) { for x in stairBay { posts.insert(x.a); posts.insert(x.b) } }
                for n in posts.sorted(by: { ($0.j, $0.i) < ($1.j, $1.i) }) { add(node(n, H(k)), node(n, H(k + 1)), .walls) }
                let turn = k % 2 == 1   // the braces turn back each lift: a zig-zag
                for x in walked(outline(L.squares[k]), round: L.squares[k]) where !(L.flights.contains(k) && stairBay.contains(x)) {
                    let alongAcross = x.a.j == x.b.j
                    guard alongAcross ? (x.a.i + 2 * x.a.j) % braceEvery == 0 : (2 * x.a.i + x.a.j) % braceEvery == 1 else { continue }
                    let (p, q) = turn ? (x.b, x.a) : (x.a, x.b)
                    let a = node(p, H(k)), b = node(q, top(k))
                    if fits(a, b) { add(a, b, .walls) }
                }
            }
            if controlWallsFirst { walls(); deck(k, .floor) } else { deck(k, .floor); walls() }
            for (a, b) in flights[k] ?? [] { add(a, b, .stairs) }
            // the roof over the last lift standing
            let next = k + 1 < floors ? L.squares[k + 1] : []
            if next.isEmpty { deck(k + 1, .roof) }
        }
        return L
    }

    /// The scaffold's members on `f` (`layout`'s).
    static func members(_ f: LatticeBuildTimelapse.Frame, depthLow dLo: Float, depthW dW: Float,
                        inArea: (SIMD3<Float>) -> Bool) -> [Float] {
        layout(f, depthLow: dLo, depthW: dW, inArea: inArea).bars
    }
}

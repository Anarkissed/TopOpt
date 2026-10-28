// FlexibleLatticeWalls — the walls of one lattice face-prism and the solid each one touches (task 2026-09-29-flexible-screens,
// round 7 · U21 batch I, part I2; his answer of 2026-10-21 ~15:35: "I did a negative expansion. I expect the 4 walls around the
// lattice to hold the lattice up … you can select any wall of the lattice and select any wall of the solid/non-latriced areas
// and link them together"; his picks ~15:45: "link targets = ONLY solid faces the lattice wall touches … with a negative expand
// the inner sides of the border around the lattice are pickable 'solid walls' even though they are not model faces").
//
// ★ ONE SOURCE: the include `LatticeRegionSpec` core reads — its `wireOutlineLoops` (the outline offset by the expand) and its
//   `depthMM` (on the wire: depth + expand; his l-bracket's box says 33.5, the wire carries 30.5). Never the voxel mask, never
//   the drawn prism glass. PURE: nothing is stored; every read re-derives the walls (memoised on what they are made from).
// ★ WHICH WALLS. A SIDE per maximal run of consecutive ORIGINAL outline edges sharing one neighbour face (a free edge splits
//   where the direction turns > 10°); a HOLE the same on an inner loop; the FLOOR at s = depth, only where the part continues
//   beyond it. The top (the pushed face) and the far end of a through-lattice are never walls. Seam edges are never walls.
// ★ KEYS AND NAMES (what a link stores): `side:f<neighbour>` (`.k` when one neighbour borders several runs), `side:e<n>` with
//   no neighbour, `hole:f<neighbour>`, `floor` — from the ORIGINAL outline, so a depth or expand edit keeps them; "Side N" is
//   numbered on the original outer loop from LatticeFaceOutline's canonical start (never the camera).
// ★ WHAT IT TOUCHES. Each wall's cells: the point 0.25 mm into the lattice inside the part (and in no Solid prism) is lattice;
//   the point one bead (the strut line width) beyond it classifies it — inside the part and in no other lattice: SOLID (the
//   target: `wall` for a side or hole, `under` for the floor); inside another lattice: a seam; outside: open (a Covered / Skin
//   finish on a model face the wall lies on: that face's skin). Touched ≥ max(cellMin², 5 % of the wall's lattice) or no target.
// The part's inside is a SLICE test: the mesh cut by the plane the samples lie on, even–odd in 2D (one slice per wall per
// offset).

import Foundation
import simd

public enum FlexibleLatticeWalls {

    // MARK: red controls (each the rule it replaces)

    /// The walls from the FACE's outline at the BOX depth (no expand offset, no wire depth).
    nonisolated(unsafe) static var controlWallsFromTheFaceOutline = false
    /// A model face counts as solid without a skin (the side lying on it becomes a "Face N" target).
    nonisolated(unsafe) static var controlBareFaceIsATarget = false
    /// The floor at the box's depth (depth − expand), not the wire's.
    nonisolated(unsafe) static var controlBoxDepth = false
    /// Any contact is a target: threshold 0 and no bead check (a 0.3 mm border, a 2 × 2 patch).
    nonisolated(unsafe) static var controlAnyContact = false
    /// Keys by the WIRE edge's index (they drift when an inset eats an edge).
    nonisolated(unsafe) static var controlIndexKeys = false

    /// How far into the lattice a wall's own cell is sampled (mm).
    static let inMM = 0.25
    /// How far beyond a wall "solid at all" is sampled (a border thinner than a bead is still solid here).
    static let touchMM = 0.05

    public enum Kind: String, Sendable { case side, hole, floor }
    /// What a wall is: a target (it touches solid), open to air, a seam into another lattice, solid thinner than a bead, or
    /// gone (the expand ate every edge of it).
    public enum Status: String, Sendable { case target, open, seam, thin, gone }

    public struct Wall: Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let kind: Kind
        /// Side N / Hole N (the floor: 0).
        public let number: Int
        /// The B-rep face across it (a side or hole), or nil.
        public let neighbour: Int?
        public var status: Status
        /// "wall" | "under" | "skin:f<N>" — nil when it touches nothing.
        public var target: String?
        public var latticeAreaMM2: Double
        public var touchedAreaMM2: Double
        public var thinAreaMM2: Double
        public var seamAreaMM2: Double
        /// Outward (away from the lattice; the floor: into the part, +n).
        public let m: SIMD3<Double>
        /// The wall's lattice side, merged into rectangles (model mm, 4 corners each).
        public var quads: [[SIMD3<Double>]]
        /// The wall's whole surface (each wire edge × the depth) — drawn when it has no lattice cell.
        public var frame: [[SIMD3<Double>]]

        public var name: String {
            switch kind {
            case .side: return "Side \(number)"
            case .hole: return "Hole \(number)"
            case .floor: return "Floor"
            }
        }
        public var tappable: Bool { status == .target }
        public var touchedShare: Double { latticeAreaMM2 > 0 ? touchedAreaMM2 / latticeAreaMM2 : 0 }
        /// The lattice side's area-weighted centre (the tag's first spot), else the frame's.
        public var centre: SIMD3<Double>? {
            var sum = SIMD3<Double>.zero, a = 0.0
            for q in (quads.isEmpty ? frame : quads) where q.count == 4 {
                let area = simd_length(simd_cross(q[1] - q[0], q[3] - q[0]))
                sum += (q[0] + q[1] + q[2] + q[3]) / 4 * area; a += area
            }
            return a > 0 ? sum / a : nil
        }
    }

    /// One lattice's walls.
    public struct Result: Equatable, Sendable {
        public let key: String
        public let face: Int?
        /// The depth on the wire (box depth + expand), and the expand.
        public let depthMM: Double
        public let expandMM: Double
        public let walls: [Wall]

        public func wall(_ key: String) -> Wall? { walls.first { $0.key == key } }
        public var sides: [Wall] { walls.filter { $0.kind == .side } }
        public var floor: Wall? { walls.first { $0.kind == .floor } }
        public var targets: [Wall] { walls.filter { $0.status == .target } }
        /// No wall of it touches solid (every side open, no floor): the card says so at once.
        public var nothingTouches: Bool { targets.isEmpty }
        /// ★ HIS ONE-TAP SUGGESTION ("Attach to the 4 walls around it" when a lattice is inset): the sides with a `wall` target
        /// not linked yet — only with a negative expand and ≥ 2 such sides; nil = no row. The floor is never in it.
        public func suggestion(linked: Set<String>) -> [String]? {
            guard expandMM < 0 else { return nil }
            let around = sides.filter { $0.status == .target && $0.target == "wall" }
            guard around.count >= 2 else { return nil }
            let missing = around.map(\.key).filter { !linked.contains($0) }
            return missing.isEmpty ? nil : missing
        }
    }

    /// A target key's words: "wall", "solid under it", "Face 7 skin".
    public static func targetName(_ t: String) -> String {
        if t == "wall" { return "wall" }
        if t == "under" { return "solid under it" }
        if t.hasPrefix("skin:f"), let n = Int(t.dropFirst(6)) { return "Face \(n) skin" }
        return t
    }

    // MARK: - the runs of the face's own outline (keys and names)

    /// One run of the ORIGINAL outline: its key, kind and number, the neighbour, and its edges in model mm.
    public struct Run: Equatable, Sendable {
        public let key: String
        public let kind: Kind
        public let number: Int
        public let neighbour: Int?
        public let edges: [[SIMD3<Double>]]
    }

    /// The face's runs: Side 1…N on its outer loop from the canonical start, Hole 1…M on the inner loops.
    public static func runs(face: Int, mesh: ViewerMesh) -> [Run] {
        guard let nf = mesh.faceNormal(Int32(face)), let cf = mesh.faceCentroid(Int32(face)) else { return [] }
        let n = SIMD3<Double>(nf), c = SIMD3<Double>(cf)
        let (u, v) = LatticeRegionMask.basis(n)
        let loops = LatticeFaceOutline.loopsWithNeighbours(face: FaceID(face), in: mesh, normal: n, origin: c)
        guard !loops.isEmpty else { return [] }
        let areas = loops.map { abs(FlexibleLatticeSections.signedArea($0.loop)) }
        let outer = areas.indices.max { areas[$0] < areas[$1] } ?? 0
        var out: [Run] = []
        var holeNo = 0
        for li in ([outer] + loops.indices.filter { $0 != outer }) {
            let l = loops[li]
            let pts = l.loop.map { c + u * $0.x + v * $0.y }
            let groups = grouped(pts, neighbours: l.neighbours.map { $0.map(Int.init) })
            let kind: Kind = li == outer ? .side : .hole
            var perNb: [Int: Int] = [:]
            for g in groups { if let nb = g.nb { perNb[nb, default: 0] += 1 } }
            var seenNb: [Int: Int] = [:]
            for g in groups {
                let number: Int
                if kind == .side { number = out.filter { $0.kind == .side }.count + 1 } else { holeNo += 1; number = holeNo }
                let p = kind == .side ? "side" : "hole"
                var key: String
                if let nb = g.nb {
                    key = "\(p):f\(nb)"
                    if (perNb[nb] ?? 0) > 1 { seenNb[nb, default: 0] += 1; key += ".\(seenNb[nb]!)" }
                } else {
                    key = "\(p):e\(number)"
                }
                out.append(Run(key: key, kind: kind, number: number, neighbour: g.nb,
                               edges: g.edges.map { [pts[$0], pts[($0 + 1) % pts.count]] }))
            }
        }
        return out
    }

    /// Consecutive edges with one neighbour (a free edge: no turn over 10°), the run holding edge 0 first.
    static func grouped(_ pts: [SIMD3<Double>], neighbours nb: [Int?]) -> [(nb: Int?, edges: [Int])] {
        let k = pts.count
        guard k >= 3 else { return [] }
        func dir(_ i: Int) -> SIMD3<Double> {
            let d = pts[(i + 1) % k] - pts[i]
            return simd_length(d) > 1e-12 ? simd_normalize(d) : d
        }
        func nbr(_ i: Int) -> Int? { i < nb.count ? nb[i] : nil }
        func joins(_ i: Int, _ j: Int) -> Bool {   // edge j follows edge i in one run
            if nbr(i) != nbr(j) { return false }
            if nbr(i) != nil { return true }
            return simd_dot(dir(i), dir(j)) >= cos(10 * Double.pi / 180)
        }
        var groups: [(nb: Int?, edges: [Int])] = [(nbr(0), [0])]
        for i in 1..<k {
            if joins(i - 1, i) { groups[groups.count - 1].edges.append(i) } else { groups.append((nbr(i), [i])) }
        }
        // the last run continues into edge 0: one run, the one holding edge 0
        if groups.count > 1, joins(k - 1, 0) {
            let last = groups.removeLast()
            groups[0].edges = last.edges + groups[0].edges
        }
        return groups
    }

    // MARK: - the walls

    /// The walls of include spec `spec` (planar, one per key): `includes` every include spec (the others are seams),
    /// `excludes` the Solid prisms (solid), `mesh` the part, `finish` the model-wide finish, `beadMM` the strut line width,
    /// `cellMinMM` the smallest cell (the touch threshold).
    public static func walls(spec: LatticeRegionSpec, includes: [LatticeRegionSpec], excludes: [LatticeRegionSpec],
                             mesh: ViewerMesh, finish: FlexibleFinish, beadMM: Double, cellMinMM: Double) -> Result? {
        let key = memoKey(spec, includes, excludes, mesh, finish, beadMM, cellMinMM)
        memoLock.lock()
        if let hit = memo[key] { memoLock.unlock(); return hit }
        memoLock.unlock()
        let r = compute(spec: spec, includes: includes, excludes: excludes, mesh: mesh, finish: finish, beadMM: beadMM, cellMinMM: cellMinMM)
        memoLock.lock()
        if memo.count > 48 { memo.removeAll() }
        memo[key] = r
        memoLock.unlock()
        return r
    }

    nonisolated(unsafe) private static var memo: [String: Result?] = [:]
    private static let memoLock = NSLock()

    private static func memoKey(_ s: LatticeRegionSpec, _ inc: [LatticeRegionSpec], _ exc: [LatticeRegionSpec], _ mesh: ViewerMesh,
                                _ finish: FlexibleFinish, _ bead: Double, _ cell: Double) -> String {
        func one(_ r: LatticeRegionSpec) -> String {
            "\(r.selectableKey ?? "-")|\(r.origin)|\(r.normal)|\(r.depthMM)|\(r.inPlaneOffsetMM)|\(r.outlineLoops)|\(r.outlineSeams)|\(r.rawFaceID.map { "\($0)" } ?? "-")"
        }
        return [one(s), inc.map(one).joined(separator: ";"), exc.map(one).joined(separator: ";"),
                "\(mesh.signature.contentHash)|\(mesh.signature.topologyHash)", finish.rawValue, "\(bead)|\(cell)",
                "\([controlWallsFromTheFaceOutline, controlBareFaceIsATarget, controlBoxDepth, controlAnyContact, controlIndexKeys])"]
            .joined(separator: "#")
    }

    static func compute(spec: LatticeRegionSpec, includes: [LatticeRegionSpec], excludes: [LatticeRegionSpec],
                        mesh: ViewerMesh, finish: FlexibleFinish, beadMM: Double, cellMinMM: Double) -> Result? {
        guard spec.role == .include, spec.kind == .face, let face = spec.rawFaceID.map({ Int($0) }) else { return nil }
        let n = LatticeRegionMask.unit(spec.normal)
        guard simd_length(n) > 0.5, !spec.outlineLoops.isEmpty else { return nil }
        let (U, W) = LatticeRegionMask.basis(n)
        let O = spec.origin
        let expand = spec.inPlaneOffsetMM
        let original = spec.outlineLoops
        let wire = controlWallsFromTheFaceOutline ? original : spec.wireOutlineLoops
        let D = (controlWallsFromTheFaceOutline || controlBoxDepth) ? Swift.max(0.1, spec.depthMM - expand) : spec.depthMM
        let solid = FlexibleSolid.of(mesh)
        let others = includes.filter { $0.selectableKey != spec.selectableKey || $0.origin != spec.origin }
        let bead = Swift.max(0.05, beadMM)
        let threshold = controlAnyContact ? 0 : cellMinMM * cellMinMM
        func to3(_ q: SIMD2<Double>) -> SIMD3<Double> { O + U * q.x + W * q.y }
        func inLattice(_ p: SIMD3<Double>, _ slice: FlexibleSolid.Slice) -> Bool {
            slice.contains(p) && !excludes.contains { LatticeRegionMask.contains(p, region: $0) }
        }

        // the runs (keys, names) and which original edge belongs to which run (matched in 3D)
        let runs = runs(face: face, mesh: mesh)
        func runOf(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Int? {
            for (ri, r) in runs.enumerated() {
                for e in r.edges where (simd_distance(e[0], a) < 1e-3 && simd_distance(e[1], b) < 1e-3)
                    || (simd_distance(e[0], b) < 1e-3 && simd_distance(e[1], a) < 1e-3) { return ri }
            }
            return nil
        }

        var acc = [Acc](repeating: Acc(), count: runs.count)
        var indexKeys: [Int: String] = [:]   // (red control) run → the wire edge index of its first wire edge

        for (l, loop) in original.enumerated() {
            let seams = l < spec.outlineSeams.count ? spec.outlineSeams[l] : []
            let wl = l < wire.count ? wire[l] : []
            for i in loop.indices {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                if i < seams.count, seams[i] {                            // a seam is never a wall: the lattice continues there
                    if let ri = runOf(to3(a), to3(b)) { acc[ri].seamEdges += 1 }
                    continue
                }
                guard simd_distance(a, b) > 1e-9, let ri = runOf(to3(a), to3(b)) else { continue }
                // the wire edges on this edge's offset line (matched by LINE, never by index)
                let d = simd_normalize(b - a)
                let len = simd_distance(a, b)
                let g = abs(expand)
                for k in wl.indices {
                    let p = wl[k], q = wl[(k + 1) % wl.count]
                    let L = simd_distance(p, q)
                    guard L > 1e-9 else { continue }
                    let dq = (q - p) / L
                    guard abs(d.x * dq.y - d.y * dq.x) < 1e-6 else { continue }
                    let dp = abs(d.x * (p.y - a.y) - d.y * (p.x - a.x)), dq2 = abs(d.x * (q.y - a.y) - d.y * (q.x - a.x))
                    guard abs(dp - (controlWallsFromTheFaceOutline ? 0 : g)) < 1e-4, abs(dq2 - dp) < 1e-4 else { continue }
                    let tp = simd_dot(p - a, d), tq = simd_dot(q - a, d)
                    guard Swift.max(tp, tq) > -g - 1e-4, Swift.min(tp, tq) < len + g + 1e-4 else { continue }
                    // (red control: the index among the edges that stand — as `halfSpaces` skips zero-length ones)
                    if indexKeys[ri] == nil { indexKeys[ri] = "side:w\((0..<k).filter { simd_distance(wl[$0], wl[($0 + 1) % wl.count]) > 1e-9 }.count)" }
                    // inward (into the wire polygon) in-plane normal
                    let left = SIMD2(-dq.y, dq.x)
                    let mid = (p + q) / 2
                    let inward = LatticeFaceOutline.contains(mid + left * 1e-3, loops: wire) ? left : -left
                    let m3 = -(U * inward.x + W * inward.y)
                    let A = to3(p), dir3 = U * dq.x + W * dq.y
                    acc[ri].hasWire = true
                    acc[ri].m = m3
                    acc[ri].frame.append([A, A + dir3 * L, A + dir3 * L + n * D, A + n * D])
                    sampleSide(A: A, dir: dir3, L: L, n: n, D: D, m: m3, solid: solid, others: others,
                               bead: bead, finish: finish, acc: &acc[ri], inLattice: inLattice)
                }
            }
        }

        var walls: [Wall] = []
        for (ri, r) in runs.enumerated() {
            let a = acc[ri]
            let key = controlIndexKeys ? (indexKeys[ri] ?? r.key) : r.key
            guard a.hasWire else {
                // every edge a seam: it runs into another lattice (greyed); else the expand ate it (gone)
                walls.append(Wall(key: key, kind: r.kind, number: r.number, neighbour: r.neighbour, status: a.seamEdges > 0 ? .seam : .gone, target: nil,
                                  latticeAreaMM2: 0, touchedAreaMM2: 0, thinAreaMM2: 0, seamAreaMM2: 0, m: .zero, quads: [], frame: []))
                continue
            }
            let need = controlAnyContact ? 1e-9 : Swift.max(threshold, 0.05 * a.lattice)
            var status: Status = .open
            var target: String?
            var touched = a.solid
            if a.solid >= need, a.solid > 0 { status = .target; target = "wall" }
            else if let sk = a.skin.max(by: { $0.value < $1.value }), sk.value >= need, sk.value > 0 {
                status = .target; target = "skin:f\(sk.key)"; touched = sk.value
            }
            else if a.thin >= need, a.thin > 0 { status = .thin }
            else if a.seam > a.air, a.seam > 0 { status = .seam }
            walls.append(Wall(key: key, kind: r.kind, number: r.number, neighbour: r.neighbour, status: status, target: target,
                              latticeAreaMM2: a.lattice, touchedAreaMM2: touched, thinAreaMM2: a.thin, seamAreaMM2: a.seam,
                              m: a.m, quads: a.quads, frame: a.frame))
        }

        // the floor: the wire outline at s = D, only where the part continues beyond it
        if let fl = floorWall(O: O, U: U, W: W, n: n, D: D, wire: wire, solid: solid, others: others, excludes: excludes,
                              bead: bead, need: { controlAnyContact ? 1e-9 : Swift.max(threshold, 0.05 * $0) }, inLattice: inLattice) {
            walls.append(fl)
        }
        return Result(key: spec.selectableKey ?? "", face: face, depthMM: D, expandMM: expand, walls: walls)
    }

    /// What one wall's cells add up to (a run may span several wire edges).
    struct Acc {
        var lattice = 0.0, solid = 0.0, thin = 0.0, seam = 0.0, air = 0.0
        var skin: [Int: Double] = [:]
        var quads: [[SIMD3<Double>]] = []
        var frame: [[SIMD3<Double>]] = []
        var hasWire = false
        var seamEdges = 0
        var m = SIMD3<Double>.zero
    }

    /// One wire edge × the depth: its cells (lattice side 0.25 mm in; beyond one bead out), merged rectangles.
    private static func sampleSide(A: SIMD3<Double>, dir: SIMD3<Double>, L: Double, n: SIMD3<Double>, D: Double, m: SIMD3<Double>,
                                   solid: FlexibleSolid, others: [LatticeRegionSpec], bead: Double, finish: FlexibleFinish,
                                   acc: inout Acc, inLattice: (SIMD3<Double>, FlexibleSolid.Slice) -> Bool) {
        let h = Swift.min(1.0, Swift.max(0.25, Swift.min(L, D) / 20))
        let nt = Swift.max(1, Int((L / h).rounded(.up))), ns = Swift.max(1, Int((D / h).rounded(.up)))
        let ht = L / Double(nt), hs = D / Double(ns)
        let cellA = ht * hs
        let sIn = solid.slice(point: A - m * inMM, normal: m)
        let sBead = solid.slice(point: A + m * bead, normal: m)
        let sTouch = solid.slice(point: A + m * touchMM, normal: m)
        // a skin: the wall lies ON a model face whose outward normal is m (Covered / Skin put solid there; the red control: any)
        let skinFace: Int? = (finish == .covered || finish == .skin || controlBareFaceIsATarget)
            ? solid.faceOnPlane(point: A, normal: m, tolMM: touchMM + bead) : nil
        var cells = [Bool](repeating: false, count: nt * ns)
        for j in 0..<ns {
            for i in 0..<nt {
                let q = A + dir * ((Double(i) + 0.5) * ht) + n * ((Double(j) + 0.5) * hs)
                guard inLattice(q - m * inMM, sIn) else { continue }
                cells[j * nt + i] = true
                acc.lattice += cellA
                let pb = q + m * bead, pt = q + m * touchMM
                if controlAnyContact ? sTouch.contains(pt) : sBead.contains(pb) {
                    let at = controlAnyContact ? pt : pb
                    if others.contains(where: { LatticeRegionMask.contains(at, region: $0) }) { acc.seam += cellA } else { acc.solid += cellA }
                } else if sTouch.contains(pt) {
                    acc.thin += cellA
                } else if let f = skinFace {
                    acc.skin[f, default: 0] += cellA
                } else {
                    acc.air += cellA
                }
            }
        }
        for r in mergeRects(cells, nu: nt, nv: ns) {
            let t0 = Double(r.i0) * ht, t1 = Double(r.i1) * ht, s0 = Double(r.j0) * hs, s1 = Double(r.j1) * hs
            acc.quads.append([A + dir * t0 + n * s0, A + dir * t1 + n * s0, A + dir * t1 + n * s1, A + dir * t0 + n * s1])
        }
    }

    /// The floor wall, or nil when the lattice runs through (nothing solid beyond it).
    private static func floorWall(O: SIMD3<Double>, U: SIMD3<Double>, W: SIMD3<Double>, n: SIMD3<Double>, D: Double,
                                  wire: [[SIMD2<Double>]], solid: FlexibleSolid, others: [LatticeRegionSpec],
                                  excludes: [LatticeRegionSpec], bead: Double, need: (Double) -> Double,
                                  inLattice: (SIMD3<Double>, FlexibleSolid.Slice) -> Bool) -> Wall? {
        let pts = wire.flatMap { $0 }
        guard pts.count >= 3 else { return nil }
        let lo = pts.reduce(SIMD2(repeating: Double.infinity)) { simd_min($0, $1) }
        let hi = pts.reduce(SIMD2(repeating: -Double.infinity)) { simd_max($0, $1) }
        let ext = hi - lo
        let h = Swift.min(1.0, Swift.max(0.25, Swift.min(ext.x, ext.y) / 20))
        let nu = Swift.max(1, Int((ext.x / h).rounded(.up))), nw = Swift.max(1, Int((ext.y / h).rounded(.up)))
        let hu = ext.x / Double(nu), hw = ext.y / Double(nw)
        let sIn = solid.slice(point: O + n * (D - inMM), normal: n)
        let sBead = solid.slice(point: O + n * (D + bead), normal: n)
        let sTouch = solid.slice(point: O + n * (D + touchMM), normal: n)
        var cells = [Bool](repeating: false, count: nu * nw)
        var latticeA = 0.0, solidA = 0.0, thinA = 0.0, seamA = 0.0, airA = 0.0
        let cellA = hu * hw
        for j in 0..<nw {
            for i in 0..<nu {
                let q = lo + SIMD2((Double(i) + 0.5) * hu, (Double(j) + 0.5) * hw)
                guard LatticeFaceOutline.contains(q, loops: wire) else { continue }
                let base = O + U * q.x + W * q.y
                guard inLattice(base + n * (D - inMM), sIn) else { continue }
                cells[j * nu + i] = true
                latticeA += cellA
                let pb = base + n * (D + bead)
                if controlAnyContact ? sTouch.contains(base + n * (D + touchMM)) : sBead.contains(pb) {
                    if others.contains(where: { LatticeRegionMask.contains(pb, region: $0) }) { seamA += cellA } else { solidA += cellA }
                } else if sTouch.contains(base + n * (D + touchMM)) { thinA += cellA } else { airA += cellA }
            }
        }
        guard latticeA > 0, solidA > 0 || thinA > 0 else { return nil }
        let quads = mergeRects(cells, nu: nu, nv: nw).map { r -> [SIMD3<Double>] in
            let a = lo + SIMD2(Double(r.i0) * hu, Double(r.j0) * hw), b = lo + SIMD2(Double(r.i1) * hu, Double(r.j1) * hw)
            return [SIMD2(a.x, a.y), SIMD2(b.x, a.y), SIMD2(b.x, b.y), SIMD2(a.x, b.y)].map { O + U * $0.x + W * $0.y + n * D }
        }
        let needA = need(latticeA)
        let status: Status = solidA >= needA && solidA > 0 ? .target : thinA >= needA && thinA > 0 ? .thin : seamA > airA ? .seam : .open
        return Wall(key: "floor", kind: .floor, number: 0, neighbour: nil, status: status, target: status == .target ? "under" : nil,
                    latticeAreaMM2: latticeA, touchedAreaMM2: solidA, thinAreaMM2: thinA, seamAreaMM2: seamA, m: n, quads: quads, frame: [])
    }

    /// Cells merged into rectangles: runs per row, then identical runs stacked (cell index ranges, half-open).
    static func mergeRects(_ cells: [Bool], nu: Int, nv: Int) -> [(i0: Int, i1: Int, j0: Int, j1: Int)] {
        var open: [String: (i0: Int, i1: Int, j0: Int, j1: Int)] = [:]
        var out: [(i0: Int, i1: Int, j0: Int, j1: Int)] = []
        for j in 0..<nv {
            var runs: [(Int, Int)] = []
            var i = 0
            while i < nu {
                guard cells[j * nu + i] else { i += 1; continue }
                let s = i
                while i < nu, cells[j * nu + i] { i += 1 }
                runs.append((s, i))
            }
            var next: [String: (i0: Int, i1: Int, j0: Int, j1: Int)] = [:]
            for (s, e) in runs {
                let k = "\(s)-\(e)"
                if var r = open[k] { r.j1 = j + 1; next[k] = r } else { next[k] = (s, e, j, j + 1) }
            }
            for (k, r) in open where next[k] == nil { out.append(r) }
            open = next
        }
        out += open.values
        return out.sorted { ($0.j0, $0.i0) < ($1.j0, $1.i0) }
    }
}

/// The part as triangles in model mm (Double), and its SLICES: the mesh cut by a plane into 2D segments, the inside of the part
/// on that plane by an even–odd crossing count. One slice answers every sample of a wall at one offset.
final class FlexibleSolid: @unchecked Sendable {
    let tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]
    let faces: [Int32]

    init(tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)], faces: [Int32]) {
        self.tris = tris
        self.faces = faces
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (key: String, solid: FlexibleSolid)?

    static func of(_ mesh: ViewerMesh) -> FlexibleSolid {
        let key = "\(mesh.signature.contentHash)|\(mesh.signature.topologyHash)|\(mesh.indices.count)"
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.key == key { return c.solid }
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        var faces: [Int32] = []
        tris.reserveCapacity(mesh.triangleCount)
        func v(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
        }
        var t = 0
        while t + 2 < mesh.indices.count {
            tris.append((v(mesh.indices[t]), v(mesh.indices[t + 1]), v(mesh.indices[t + 2])))
            faces.append(t / 3 < mesh.faceIDs.count ? mesh.faceIDs[t / 3] : -1)
            t += 3
        }
        let s = FlexibleSolid(tris: tris, faces: faces)
        cache = (key, s)
        return s
    }

    struct Slice {
        let origin: SIMD3<Double>, e1: SIMD3<Double>, e2: SIMD3<Double>
        let segs: [(SIMD2<Double>, SIMD2<Double>)]
        /// Is `p` (on the slice's plane) inside the part? Even–odd along +e1.
        func contains(_ p: SIMD3<Double>) -> Bool {
            let d = p - origin
            let q = SIMD2(simd_dot(d, e1), simd_dot(d, e2))
            var inside = false
            for (a, b) in segs where (a.y > q.y) != (b.y > q.y) {
                let x = a.x + (q.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if x > q.x { inside.toggle() }
            }
            return inside
        }
    }

    /// The part cut by the plane through `point` with normal `normal`.
    func slice(point o: SIMD3<Double>, normal: SIMD3<Double>) -> Slice {
        let n = simd_normalize(normal)
        let (e1, e2) = LatticeRegionMask.basis(n)
        var segs: [(SIMD2<Double>, SIMD2<Double>)] = []
        func flat(_ p: SIMD3<Double>) -> SIMD2<Double> { let d = p - o; return SIMD2(simd_dot(d, e1), simd_dot(d, e2)) }
        for (a, b, c) in tris {
            let da = simd_dot(a - o, n), db = simd_dot(b - o, n), dc = simd_dot(c - o, n)
            let pa = da >= 0, pb = db >= 0, pc = dc >= 0
            if pa == pb && pb == pc { continue }
            var pts: [SIMD3<Double>] = []
            for (p, q, dp, dq, sp, sq) in [(a, b, da, db, pa, pb), (b, c, db, dc, pb, pc), (c, a, dc, da, pc, pa)] where sp != sq {
                let t = dp / (dp - dq)
                pts.append(p + (q - p) * t)
            }
            if pts.count == 2 { segs.append((flat(pts[0]), flat(pts[1]))) }
        }
        return Slice(origin: o, e1: e1, e2: e2, segs: segs)
    }

    /// The model face lying ON the plane (every corner within `tolMM`, its normal within 1° of `normal`) with the most area there.
    func faceOnPlane(point o: SIMD3<Double>, normal: SIMD3<Double>, tolMM: Double) -> Int? {
        let n = simd_normalize(normal)
        var area: [Int32: Double] = [:]
        for (i, (a, b, c)) in tris.enumerated() {
            let x = simd_cross(b - a, c - a)
            let l = simd_length(x)
            guard l > 1e-12, simd_dot(x / l, n) > cos(Double.pi / 180) else { continue }
            guard [a, b, c].allSatisfy({ abs(simd_dot($0 - o, n)) <= tolMM }) else { continue }
            area[faces[i], default: 0] += l / 2
        }
        return area.max { $0.value < $1.value }.map { Int($0.key) }
    }
}

extension FlexibleLatticeWalls {
    /// The include spec(s) emitted for one selectable key.
    public static func specs(_ includes: [LatticeRegionSpec], key: String) -> [LatticeRegionSpec] {
        includes.filter { $0.role == .include && $0.selectableKey == key }
    }

    /// v1: Attach works on ONE planar face spec per key (a curved or multi-facet face-prism, or a hand-placed one, gets the
    /// one line "Curved lattice · Attach not yet").
    public static func attachable(_ includes: [LatticeRegionSpec], key: String) -> Bool {
        let s = specs(includes, key: key)
        return s.count == 1 && s[0].kind == .face && s[0].rawFaceID != nil && !s[0].outlineLoops.isEmpty
    }

    /// The walls of the lattice keyed `key` in `project` (`regions`: the emission, when the caller memoises it).
    @MainActor
    public static func walls(project p: ProjectModel, key: String, regions: [LatticeRegionSpec]? = nil) -> Result? {
        let all = regions ?? p.latticeJobRegions().regions
        let inc = all.filter { $0.role == .include }, exc = all.filter { $0.role == .exclude }
        guard attachable(inc, key: key), let mesh = p.viewerMesh, let spec = specs(inc, key: key).first else { return nil }
        return walls(spec: spec, includes: inc, excludes: exc, mesh: mesh, finish: p.lattice.flexible?.finishMode ?? .covered,
                     beadMM: p.printParams.strutLineWidthMM, cellMinMM: p.lattice.cellMinMM)
    }
}

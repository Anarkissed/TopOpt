// FlexibleEdgeStrips — THE AREA an edge or a corner pick presses (task 2026-10-08, round 6 item 2 as approved: the
// maintainer OKed the area directly — "the strip/patch area with a width box; the face's group keeps the rest; the
// first pick keeps a shared corner" — and the reviewer ruled "build it as posted", 2026-10-09 19:41; r6 spec §3 "AREA").
//
// ★ WHAT A PICK PRESSES. An EDGE presses a STRIP along the edge on each of its two faces: the part of the face within
// w of the edge — and, where the candidate stops before the face does (a sector's end: r5's Top A), no further along
// it. A CORNER presses a w × w PATCH on each face that meets there. Each is an ordinary SECTOR, cut with the Surface
// stage's own straight cut — the calls ProjectModel.commitSurfaceCut makes: an identity region for a face that has none
// (`union(faces:named:)`), `splitManual`, then `splitDetached` on each half — so a strip is a region like any he cuts
// himself (`surfaceCut` below is that path, and FlexibleEdgeGroupsTests pins the two equal). ★ THE MAIN PAGE'S
// SELECTIONS ARE NOT TOUCHED: commitSurfaceCut also adds a new identity region to the Selections group that holds the
// face; this cut never does — the main page's Selections (the lattice) and the Settings squeeze groups (the squish)
// are two separate lists (his 2026-10-10 reversal).
// ★ THE FACE KEEPS THE REST. Whatever of a face no pick takes stays the face's: the stage model moves its settings
// (weight, group, curves, stamp, deepest) onto the rest — one sector beside a strip, two round a corner's L — through
// core's frames (FlexiblePressReframe). This file says which pieces are the rest (`Plan.rests`).
// ★ PICKS NEVER OVERLAP. Each chain is cut in ONE order — corners first (a corner takes its square out of a strip's
// end), then edges in PICK order (where two picked edges meet on a face, the FIRST keeps the shared corner square) —
// each pick cutting only what no earlier pick took (`Plan.free`). A pick whose area on a face would need two separate
// free pieces (core refuses two sectors of one face in one press) or none is refused, with one line. So no region is
// ever in two presses and no press holds two sectors of one face.
// ★ RE-CUT. A strip remembers what it was picked as (`FlexibleStrip`: its faces, the edge's line or the corner, its
// width, its pick order) — so a width change, a removal or a later pick on the same face re-cuts every CHAIN it touches
// from the chain's ROOT (the face's identity region, or his own Surface sector), in the same order. The stage model
// applies a plan as one edit and one undo step.
// ★ ONE SOURCE: CORE for every frame and normal used here (the inward loads the in-face directions come from, the
// flatness, the centroid that says which side is the face). The cut planes are the Surface tool's own geometry
// (half-spaces), as every Surface cut is. No column, design or frame of a press is computed here.

import Foundation
import simd

/// The AREA of one edge or corner press, saved on it (`FlexiblePress.strip`): what it was picked as, how wide it is,
/// and where on each member face its strip or patch lies — so a width change or a removal can re-cut it.
public struct FlexibleStrip: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case edge, corner }

    /// One face the pick presses.
    public struct Member: Codable, Equatable, Hashable, Sendable {
        /// The viewer face it lies on.
        public var face: Int
        /// The FaceRegion the face's chain grows from: the face's identity region, or his own Surface sector. −1: the
        /// face has no region yet — the first cut makes its identity region (as commitSurfaceCut does).
        public var root: Int
        /// The corner, or the edge's start.
        public var origin: SIMD3<Double>
        /// Unit directions IN the face, away from each edge that bounds the pick (one for an edge, two for a corner).
        public var away: [SIMD3<Double>]
        /// An edge's direction along it, and where the candidate starts and stops (mm from `origin`); nil for a corner.
        public var along: SIMD3<Double>?
        public var span: [Double]?
        /// Half the face's extent across the edge (each edge, for a corner): the width's cap on this face.
        public var capMM: Double
        /// ★ R7-E1 STUB: a corner face's two edge directions from the corner.
        public var edges: [SIMD3<Double>]?

        public init(face: Int, root: Int, origin: SIMD3<Double>, away: [SIMD3<Double>], along: SIMD3<Double>? = nil,
                    span: [Double]? = nil, capMM: Double, edges: [SIMD3<Double>]? = nil) {
            self.face = face; self.root = root; self.origin = origin; self.away = away
            self.along = along; self.span = span; self.capMM = capMM; self.edges = edges
        }
    }

    public var kind: Kind
    /// "Edge 3" / "Corner 1" — its number in the list it was picked from (the list renumbers after a cut).
    public var label: String
    /// The strip's width / the patch's side (mm). ★ R7-E1 STUB: optional.
    public var widthMM: Double?
    /// Pick order, across every edges/corners group (the first pick keeps a shared corner square).
    public var order: Int
    public var members: [Member]
    /// ★ R7-E1 STUB: core's halfway over the whole members at pick time.
    public var halfway: SIMD3<Double>?

    public init(kind: Kind, label: String, widthMM: Double? = nil, order: Int, members: [Member], halfway: SIMD3<Double>? = nil) {
        self.kind = kind; self.label = label; self.widthMM = widthMM; self.order = order; self.members = members
        self.halfway = halfway
    }

    /// The width's cap: half the narrowest member face's extent across its edge — a face group always keeps a rest.
    public var capMM: Double { members.map(\.capMM).min() ?? 0 }
}

public enum FlexibleEdgeStrips {

    /// The narrowest strip the width box takes.
    public static let minWidthMM = 0.5
    /// A seam this far off its straight line is curved (no straight cut follows it).
    static let straightMM = 1e-3
    /// A member flatter than this (core's normal spread) is flat.
    static let flatDeg = FlexibleEdgeCandidates.flatSpreadDeg

    /// ★ RED CONTROL (the after-s1 table, "whole-face regions"): a pick presses its WHOLE member faces — the regions the
    /// face groups already hold — instead of strips (`regionsInTwoEntries` then finds them twice: core's refusal).
    @MainActor static var controlWholeFaces = false

    // MARK: - a pick's area, from its candidate

    /// ★ THE DEFAULT WIDTH: the lattice depth under the members — core's stack `latticeMMMax`, the smaller member's —
    /// capped at half of each member face's extent across the edge, so a face group always keeps a rest. A member core
    /// gives no lattice depth for (no stack, or none) does not lower it; nothing at all: the cap.
    public static func defaultWidth(capMM: Double, latticeMM: [Double?]) -> Double {
        let depths = latticeMM.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        let w = depths.min().map { Swift.min($0, capMM) } ?? capMM
        return Swift.max(Swift.min(minWidthMM, capMM), w)
    }

    /// ★ A PICK'S AREA from its candidate (`label`: "Edge 3"): for each member piece, its face, the chain's root, the
    /// edge's line (or the corner) and the in-face directions away from it, from CORE's inward normal and centroid of
    /// the piece (`facts`). The width is the default's (`latticeMM`: core's lattice depth under each member). A
    /// candidate this area cannot cut — a fillet, a curved member or edge, a member over two faces, a corner whose face
    /// is bounded by more than two edges there — is refused with one line (≤ 44 characters).
    public static func strip(for c: FlexibleEdgeCandidates.Candidate, label: String, order: Int, meet: FlexibleMeet,
                             facts: FlexibleMeetFacts, faceRegions: FaceRegionModel, existing: [FlexibleStrip],
                             latticeMM: [Double?] = [], name: (Int) -> String) -> Result<FlexibleStrip, Refusal> {
        guard c.kind != .blend else { return .failure(Refusal(line: FlexibleRowCopy.stripFillet)) }
        var members: [FlexibleStrip.Member] = []
        for p in c.members {
            guard let piece = meet.piece(p), piece.faces.count == 1, let face = piece.faces.first else {
                return .failure(Refusal(line: FlexibleRowCopy.fit("\(name(p)) spans two faces")))
            }
            guard let fr = facts.frames[p], fr.valid, fr.normalSpreadDeg <= flatDeg, let n = FlexiblePressAim.unit(fr.load) else {
                return .failure(Refusal(line: FlexibleRowCopy.fit("\(name(p)) is curved · no straight strip")))
            }
            let poly = clippedPolygons(meet, p)
            let root = rootOf(p, face: face, faceRegions: faceRegions, existing: existing)
            switch c.kind {
            case .edge:
                let others = c.members.filter { $0 != p }
                let pts = others.flatMap { meet.sharedEdge(p, $0) }.flatMap { $0 }
                guard let line = straightLine(pts) else { return .failure(Refusal(line: FlexibleRowCopy.stripCurvedEdge)) }
                guard var u = FlexiblePressAim.unit(simd_cross(n, line.dir)) else {
                    return .failure(Refusal(line: FlexibleRowCopy.stripCurvedEdge))
                }
                if simd_dot(fr.centroid - line.start, u) < 0 { u = -u }
                let extent = poly.flatMap { $0 }.map { simd_dot($0 - line.start, u) }.max() ?? 0
                members.append(.init(face: face, root: root, origin: line.start, away: [u], along: line.dir,
                                     span: [0, line.length], capMM: extent / 2))
            case .corner:
                let others = c.members.filter { $0 != p }
                var dirs: [SIMD3<Double>] = []
                for q in others {
                    for pl in meet.sharedEdge(p, q) {
                        guard let e = awayFromCorner(pl, corner: c.point) else { continue }
                        if !dirs.contains(where: { simd_length(simd_cross($0, e)) < 1e-6 && simd_dot($0, e) > 0 }) { dirs.append(e) }
                    }
                }
                guard dirs.count == 2, simd_length(simd_cross(dirs[0], dirs[1])) > 1e-6 else {
                    return .failure(Refusal(line: FlexibleRowCopy.fit("\(name(p)) meets \(dirs.count) edges here")))
                }
                var aw: [SIMD3<Double>] = []
                for (i, e) in dirs.enumerated() {
                    guard var u = FlexiblePressAim.unit(simd_cross(n, e)) else {
                        return .failure(Refusal(line: FlexibleRowCopy.stripCurvedEdge))
                    }
                    if simd_dot(u, dirs[1 - i]) < 0 { u = -u }
                    aw.append(u)
                }
                let vs = poly.flatMap { $0 }
                let caps = aw.map { u in (vs.map { simd_dot($0 - c.point, u) }.max() ?? 0) / 2 }
                members.append(.init(face: face, root: root, origin: c.point, away: aw, capMM: caps.min() ?? 0))
            case .blend:
                break
            }
        }
        var s = FlexibleStrip(kind: c.kind == .corner ? .corner : .edge, label: label, widthMM: 0, order: order, members: members)
        s.widthMM = defaultWidth(capMM: s.capMM, latticeMM: latticeMM)
        guard s.capMM >= minWidthMM else { return .failure(Refusal(line: FlexibleRowCopy.fit("\(label) · the face is too narrow"))) }
        return .success(s)
    }

    /// One line why a pick cannot be cut.
    public struct Refusal: Error, Equatable { public let line: String }

    /// The chain a piece belongs to: its own Surface sector (or the chain root it was cut from), or — a whole face —
    /// the face's uncut identity region, or −1 (made by the first cut).
    static func rootOf(_ p: Int, face: Int, faceRegions: FaceRegionModel, existing: [FlexibleStrip]) -> Int {
        let roots = Set(existing.flatMap { $0.members.map(\.root) }.filter { $0 >= 0 })
        if FlexibleRegions.isSector(p) {
            var id = p - FlexibleRegions.sectorBase
            var steps = 0
            while let r = faceRegions.region(id), steps < 64 {
                if roots.contains(r.id) { return r.id }
                guard faceRegions.region(r.parentID) != nil else { break }
                id = r.parentID
                steps += 1
            }
            return p - FlexibleRegions.sectorBase
        }
        return identity(of: face, in: faceRegions) ?? -1
    }

    /// An uncut identity region holding exactly `face`, with nothing split off it (the chain root a cut reuses).
    static func identity(of face: Int, in m: FaceRegionModel) -> Int? {
        m.regions.first { r in
            r.isIdentity && !r.isCut && !r.isUnionOfParts && r.add == [FaceID(face)] && r.remove.isEmpty && !r.filter.any
                && m.children(of: r.id).isEmpty
        }?.id
    }

    /// Points on one straight line (within 1e-3 mm): its first point by position along it, its direction and length.
    static func straightLine(_ pts: [SIMD3<Double>]) -> (start: SIMD3<Double>, dir: SIMD3<Double>, length: Double)? {
        guard pts.count >= 2 else { return nil }
        // the two points farthest apart
        var a = pts[0], b = pts[0], best = -1.0
        for p in pts { let d = simd_distance(pts[0], p); if d > best { best = d; b = p } }
        best = -1
        for p in pts { let d = simd_distance(b, p); if d > best { best = d; a = p } }
        guard best > FlexibleMeet.touchMM, let dir = FlexiblePressAim.unit(b - a) else { return nil }
        for p in pts {
            let off = (p - a) - dir * simd_dot(p - a, dir)
            if simd_length(off) > straightMM { return nil }
        }
        // canonical: start at the lower end by position (the same line however it was met)
        let ka = FlexibleMeet.qkey(a), kb = FlexibleMeet.qkey(b)
        return ka.lexicographicallyPrecedes(kb) ? (a, dir, best) : (b, -dir, best)
    }

    /// The unit direction from `corner` along polyline `pl`, when one of its ends is at the corner.
    static func awayFromCorner(_ pl: [SIMD3<Double>], corner: SIMD3<Double>) -> SIMD3<Double>? {
        guard pl.count >= 2 else { return nil }
        if simd_distance(pl[0], corner) <= FlexibleMeet.touchMM { return FlexiblePressAim.unit(pl[1] - pl[0]) }
        if simd_distance(pl[pl.count - 1], corner) <= FlexibleMeet.touchMM {
            return FlexiblePressAim.unit(pl[pl.count - 2] - pl[pl.count - 1])
        }
        return nil
    }

    /// A piece's surface as polygons: its face's triangles clipped by its cuts.
    static func clippedPolygons(_ meet: FlexibleMeet, _ p: Int) -> [[SIMD3<Double>]] {
        let cuts = meet.piece(p)?.cuts ?? []
        return meet.memberTriangles(p).map { t -> [SIMD3<Double>] in
            let (a, b, c) = meet.triangle(t)
            return cuts.isEmpty ? [a, b, c] : FlexibleMeet.clipPolygon([a, b, c], cuts)
        }.filter { $0.count >= 3 }
    }

    // MARK: - the half-spaces

    /// ★ A member's AREA as half-spaces (each kept where dot(p − point, normal) ≥ 0, as a RegionCut): within `w` of
    /// each edge (its plane parallel to the edge, its normal in the face), and an edge's start and end along it.
    public static func legacyHalfSpaces(_ m: FlexibleStrip.Member, width w: Double) -> [RegionCut] {
        var out = m.away.map { u in RegionCut(point: m.origin + u * w, normal: -u) }
        if let e = m.along, let s = m.span, s.count == 2 {
            out.append(RegionCut(point: m.origin + e * s[0], normal: e))
            out.append(RegionCut(point: m.origin + e * s[1], normal: -e))
        }
        return out
    }

    /// The area (mm²) of `triangles` kept by every half-space of `cuts` (closed, as core's clip).
    public static func area(_ triangles: [[SIMD3<Double>]], _ cuts: [RegionCut]) -> Double {
        triangles.reduce(0) { $0 + FlexibleMeet.area(cuts.isEmpty ? $1 : FlexibleMeet.clipPolygon($1, cuts)) }
    }

    /// A face's triangles (model mm) on `mesh`.
    public static func triangles(face: Int, mesh: ViewerMesh) -> [[SIMD3<Double>]] {
        let n = Swift.min(mesh.triangleCount, mesh.faceIDs.count)
        return (0..<n).filter { Int(mesh.faceIDs[$0]) == face }.map { t in
            (0..<3).map { FlexibleMeet.position(mesh, mesh.indices[3 * t + $0]) }
        }
    }

    // MARK: - the Surface tool's own cut

    /// ★ WHAT ProjectModel.commitSurfaceCut DOES TO THE REGIONS for a cut through `face` (no region yet → its identity
    /// region, named as the Surface stage names it; else `target`), the plane through `point` along `normal`: the
    /// identity region, `splitManual`, and `splitDetached` on each half — WITHOUT commitSurfaceCut's Selections join
    /// (the two group lists are separate). Returns the leaves, as commitSurfaceCut does.
    @discardableResult
    public static func surfaceCut(_ m: inout FaceRegionModel, face: Int, target: Int? = nil, point: SIMD3<Double>,
                                  normal: SIMD3<Double>, mesh: ViewerMesh) -> [RegionID] {
        let t = target ?? m.union(faces: [FaceID(face)], named: "Face \(face)")
        let kids = m.splitManual(t, point: point, normal: normal)
        var leaves: [RegionID] = []
        for k in kids {
            let detached = m.splitDetached(k, in: mesh)
            leaves += detached.isEmpty ? [k] : detached
        }
        return leaves
    }

    // MARK: - the plan (every chain re-cut from its root, in one order)

    /// One strip press as the plan sees it: its id, its area, and its regions now (nil: a new pick).
    public struct Entry: Equatable {
        public let id: UUID
        public var strip: FlexibleStrip
        public var regions: [Int]?
        /// ★ R7-E1 STUB: the flat prism's plane (nil: M2's width).
        public var cut: FlexibleFlatPrism.Cut?
        public init(id: UUID, strip: FlexibleStrip, regions: [Int]?, cut: FlexibleFlatPrism.Cut? = nil) {
            self.id = id; self.strip = strip; self.regions = regions; self.cut = cut
        }
    }

    /// The regions after a change, and what each piece is.
    public struct Plan: Equatable {
        public var faceRegions: FaceRegionModel
        /// Every strip press, its roots filled in.
        public var strips: [UUID: FlexibleStrip] = [:]
        /// Each strip press's regions (wire ids, member order).
        public var regions: [UUID: [Int]] = [:]
        /// Each re-cut chain's REST (wire ids), by root; a chain left with no pick: its base piece again.
        public var rests: [Int: [Int]] = [:]
        /// Each re-cut chain's base piece — what the face's settings were keyed on before any strip: the face's id for
        /// an identity root, the sector's wire id for his own Surface sector.
        public var bases: [Int: Int] = [:]
        /// Each re-cut chain's face.
        public var faces: [Int: Int] = [:]
        /// Each re-cut chain's pieces BEFORE the change (wire ids, or the base piece) — where the face's settings were.
        public var before: [Int: [Int]] = [:]
        /// A pick that cannot be cut: one line.
        public var refused: [UUID: String] = [:]
        /// ★ ROUND 7 (M2): the same pieces as FaceRegionModel ids of `faceRegions` (never wire ids — the Flexible sectors
        /// renumber them, FlexibleSectors): each press's piece per member index, and each re-cut chain's rest, by root.
        public var pieceIDs: [UUID: [Int: Int]] = [:]
        public var restIDs: [Int: [Int]] = [:]
    }

    /// ★ RE-CUT every chain in `replay` (FaceRegion ids) and every chain a new pick starts (root −1), from its root, in
    /// one order — corners first, then edges by pick order — over `entries` (every strip press that will exist: the
    /// ones kept, changed and new). `keep`: identity regions the main page refers to (never dissolved).
    public static func plan(_ entries: [Entry], replay: Set<Int>, faceRegions: FaceRegionModel, mesh: ViewerMesh,
                            keep: Set<Int> = []) -> Plan {
        var m = faceRegions
        var all = entries
        var made: [Int: Int] = [:]   // face → its identity root made here
        var roots = replay
        // ── the roots a new pick starts: the face's identity region (made once per face, as the Surface cut makes it)
        for i in all.indices {
            for k in all[i].strip.members.indices where all[i].strip.members[k].root < 0 {
                let f = all[i].strip.members[k].face
                let r: Int
                if let id = made[f] ?? identity(of: f, in: m) { r = id } else {
                    r = m.union(faces: [FaceID(f)], named: "Face \(f)")
                }
                made[f] = r
                all[i].strip.members[k].root = r
                roots.insert(r)
            }
        }
        var out = Plan(faceRegions: m)
        for e in all { out.strips[e.id] = e.strip }
        var pieceOf: [UUID: [Int: Int]] = [:]   // press → member index → its FaceRegion id
        for root in roots.sorted() {
            guard let r = m.region(root) else { continue }
            let face = all.flatMap { $0.strip.members }.first { $0.root == root }?.face
                ?? FaceRegionGeometry.members(of: r, in: mesh).first.map { Int($0) } ?? -1
            let base = r.isCut ? FlexibleRegions.wireID(r) : face
            out.bases[root] = base
            out.faces[root] = face
            let oldLeaves = leaves(of: root, in: m)
            out.before[root] = oldLeaves == [root] ? [base] : oldLeaves.compactMap { m.region($0).map(FlexibleRegions.wireID) }
            m.revertSplit(root)
            let tris = triangles(face: face, mesh: mesh)
            let faceArea = area(tris, [])
            let eps = Swift.max(1e-6, 1e-7 * faceArea)
            // the picks on this chain, in the one order
            var picks: [(id: UUID, k: Int, strip: FlexibleStrip)] = []
            for e in all { for (k, mb) in e.strip.members.enumerated() where mb.root == root { picks.append((e.id, k, e.strip)) } }
            picks.sort { a, b in
                if (a.strip.kind == .corner) != (b.strip.kind == .corner) { return a.strip.kind == .corner }
                return a.strip.order < b.strip.order
            }
            if picks.isEmpty {
                // nothing presses this chain any more: the face is whole again (an identity region made for strips goes)
                if !r.isCut, r.isIdentity, !keep.contains(root), m.children(of: root).isEmpty { _ = m.dissolve(root) }
                out.rests[root] = [base]
                out.restIDs[root] = [root]
                continue
            }
            var free: [Int] = [root]
            for p in picks {
                let h = legacyHalfSpaces(p.strip.members[p.k], width: p.strip.widthMM ?? 0)
                // the free piece the pick's area lies in; where it reaches two (a strip wider than the corner patch
                // beside it: the strip less the patch is an L, and a sector is one convex piece — core refuses two
                // sectors of one face in a press), it takes the piece holding most of it and the sliver stays the rest
                let hits = free.map { id in (id: id, a: area(tris, (m.region(id)?.cuts ?? []) + h)) }.filter { $0.a > eps }
                guard var cur = hits.max(by: { ($0.a, -$0.id) < ($1.a, -$1.id) })?.id else {
                    out.refused[p.id] = FlexibleRowCopy.fit("\(p.strip.label) · taken by an earlier pick")
                    continue
                }
                free.removeAll { $0 == cur }
                var ok = true
                for cut in h {
                    let have = m.region(cur)?.cuts ?? []
                    let outside = area(tris, have + [RegionCut(point: cut.point, normal: -cut.normal)])
                    guard outside > eps else { continue }   // the piece lies inside this plane already
                    let kids = m.splitManual(cur, point: cut.point, normal: cut.normal)
                    guard kids.count == 2 else { ok = false; break }
                    // the Surface cut: a half that fell into separate patches becomes separate pieces
                    var inside = [kids[0]], beyond = [kids[1]]
                    let a = m.splitDetached(kids[0], in: mesh), b = m.splitDetached(kids[1], in: mesh)
                    if !a.isEmpty { inside = a }
                    if !b.isEmpty { beyond = b }
                    let kept = inside.filter { area(tris, m.region($0)?.cuts ?? []) > eps }
                    free += beyond.filter { area(tris, m.region($0)?.cuts ?? []) > eps }
                    guard kept.count == 1 else { ok = false; break }   // two patches inside: two sectors of one face
                    cur = kept[0]
                }
                guard ok else {
                    out.refused[p.id] = FlexibleRowCopy.fit("\(p.strip.label) needs two parts of Face \(face)")
                    continue
                }
                pieceOf[p.id, default: [:]][p.k] = cur
            }
            // names: the pick's piece names its pick and the face; the rest keeps the face's name
            let baseName = r.name.isEmpty ? "Face \(face)" : r.name
            for p in picks { if let id = pieceOf[p.id]?[p.k] { m.rename(id, to: "\(p.strip.label) · \(baseName)") } }
            let rest = free.sorted()
            for (i, id) in rest.enumerated() { m.rename(id, to: rest.count == 1 ? baseName : "\(baseName) · part \(i + 1)") }
            out.rests[root] = rest.compactMap { m.region($0).map(FlexibleRegions.wireID) }
            out.restIDs[root] = rest
        }
        out.faceRegions = m
        out.pieceIDs = pieceOf
        for e in all {
            var regs: [Int] = []
            for (k, mb) in e.strip.members.enumerated() {
                if let id = pieceOf[e.id]?[k], let r = m.region(id) {
                    regs.append(FlexibleRegions.wireID(r))
                } else if !roots.contains(mb.root), let old = e.regions, k < old.count {
                    regs.append(old[k])   // a chain not re-cut keeps its piece
                } else if out.refused[e.id] == nil {
                    out.refused[e.id] = FlexibleRowCopy.fit("\(e.strip.label) · nothing to press on Face \(mb.face)")
                }
            }
            out.regions[e.id] = regs
        }
        return out
    }

    /// The leaf regions under `root` (itself when it has no children).
    public static func leaves(of root: Int, in m: FaceRegionModel) -> [Int] {
        let kids = m.children(of: root)
        guard !kids.isEmpty else { return [root] }
        return kids.flatMap { leaves(of: $0.id, in: m) }.sorted()
    }

    // MARK: - what core refuses

    /// ★ EVERY REGION THAT WOULD BE IN TWO ENTRIES if every face and every press were sent — core refuses the job
    /// ("… appears twice; one entry per face (a region is in one press)", job_block). Empty with strips.
    public static func regionsInTwoEntries(_ s: FlexibleStageSettings) -> [Int] {
        var count: [Int: Int] = [:]
        for f in s.faces { count[f.faceRegionID, default: 0] += 1 }
        for p in s.presses ?? [] { for r in Set(p.regions) { count[r, default: 0] += 1 } }
        return count.filter { $0.value > 1 }.map(\.key).sorted()
    }

    /// ★ Two entries whose footprints SHARE SURFACE (a face and its own sector; #361's A3 "shared_footprint" refusal):
    /// every pair of entries (faces, and each press's regions) whose areas overlap on one face by more than 1e-3 mm².
    public static func sharedSurface(_ s: FlexibleStageSettings, regions: FlexibleRegions, mesh: ViewerMesh) -> [(Int, Int)] {
        var entries: [(id: Int, owner: String)] = s.faces.map { ($0.faceRegionID, "face-\($0.faceRegionID)") }
        for p in s.presses ?? [] { for r in p.regions { entries.append((r, "press-\(p.id)")) } }
        var trisOf: [Int: [[SIMD3<Double>]]] = [:]
        var out: [(Int, Int)] = []
        for i in 0..<entries.count {
            for j in (i + 1)..<entries.count where entries[i].owner != entries[j].owner {
                let a = entries[i].id, b = entries[j].id
                let fa = Set(regions.faces(of: a, mesh: mesh)), fb = Set(regions.faces(of: b, mesh: mesh))
                for f in fa.intersection(fb).sorted() {
                    let t = trisOf[f] ?? triangles(face: f, mesh: mesh)
                    trisOf[f] = t
                    if area(t, regions.cuts(of: a) + regions.cuts(of: b)) > 1e-3 { out.append((a, b)); break }
                }
            }
        }
        return out
    }
}

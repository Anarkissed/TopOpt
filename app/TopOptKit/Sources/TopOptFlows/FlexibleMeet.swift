// FlexibleMeet — which faces meet, where, and along what (task 2026-10-07, angled presses, batch AP2; final spec §5
// "New file F/FlexibleMeet.swift"; round 6 item 2 builds its edges/corners groups on it, r6 spec §3 "Candidates").
//
// ★ WHAT IT IS. Pure geometry over the part the page draws (`project.viewerMesh`) and the Flexible regions it
// declares (`FlexibleRegions`: every face, plus his Surface-stage sectors):
//   * the WHOLE-FACE shared-edge map, keyed by POSITION (1e-4 mm, SurfaceWireframe's key), grouped by face pair —
//     never FaceTopology.adjacency, which is keyed by vertex INDEX and finds nothing on a per-face-vertex mesh. Core's
//     face_adjacency is the whole-face authority; FlexibleMeetTests pins this map equal to it on every fixture;
//   * the SURFACE PARTITION into pieces: a face with sectors is its leaf sectors (a split's parent stays declared but
//     its children cover it), every other face is itself;
//   * the SEAMS between pieces: a shared mesh edge of two faces, CLIPPED by both pieces' cuts (a sector touches a
//     neighbour only where its cuts reach the edge: Top B never touches face 3 on his r5), and the cut line between
//     two sectors of one face. Each seam keeps its segments (with the triangle on each side, for core's 15° verdict
//     in FlexibleEdgeCandidates), its length and its polylines (what the page draws);
//   * the MEETING POINTS: where three or more pieces meet (a box corner; also the end of a cut on an edge — the
//     candidates decide which are corners);
//   * `connected`, `blendChain` (the whole chain of curved pieces between two flats), `anchor` (display only) and
//     the handles' targets in POINTS (≥ 44 pt at every zoom, through the page's CameraProjection).
//
// ★ ONE SOURCE: CORE. Nothing here is a frame, a normal, a column or an ownership: the 15° rule, the halfway and
// the side verdict use core's numbers (FlexibleEdgeCandidates, FlexibleMeetFacts); this file only finds WHERE
// faces meet, from the mesh the page already draws, and is checked against core's own adjacency.
//
// ★ STABLE. Every output is sorted (pairs, pieces, segments in triangle order, meeting points by position), so the
// same mesh and regions give the same answer in any process; FlexibleEdgeCandidates numbers by position.

// ★★ AP2 TESTS-FIRST STUBS: every rule below marked "RED STUB" is the spec's red variant (index-keyed seams, no
// sector clipping, no cut line, no blend chain, the area centroid as anchor, handles sized in mm); the next commit
// replaces each with its rule.

import CoreGraphics
import Foundation
import simd

public struct FlexibleMeet {

    /// Two regions (or two faces), the lower id first.
    public struct Pair: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let a: Int, b: Int
        public init(_ x: Int, _ y: Int) { a = Swift.min(x, y); b = Swift.max(x, y) }
        public static func < (l: Pair, r: Pair) -> Bool { (l.a, l.b) < (r.a, r.b) }
        public var description: String { "\(a)–\(b)" }
    }

    /// One straight piece of a seam (model mm, read from the viewer mesh), and the viewer triangle on each side of
    /// it: `triA` on the pair's `a` side, `triB` on its `b` side (one triangle on both sides of a cut line).
    public struct Segment: Equatable, Sendable {
        public let p: SIMD3<Double>, q: SIMD3<Double>
        public let triA: Int, triB: Int
        public var length: Double { simd_distance(p, q) }
        public init(p: SIMD3<Double>, q: SIMD3<Double>, triA: Int, triB: Int) { self.p = p; self.q = q; self.triA = triA; self.triB = triB }
    }

    /// A piece of the surface partition: a declared Flexible region (a whole face, id = the face id; or a leaf
    /// sector, id = FlexibleRegions.wireID) with its faces and its cuts.
    public struct Piece: Equatable, Sendable {
        public let id: Int
        public let faces: [Int]
        public let cuts: [RegionCut]
    }

    /// `.edge`: pieces on different faces meeting along mesh edges. `.cut`: two pieces of one face meeting along a
    /// cut (never an edge to press: one surface on both sides).
    public enum SeamKind: String, Sendable { case edge, cut }

    public struct Seam: Sendable {
        public let pair: Pair
        public let kind: SeamKind
        public let segments: [Segment]
        public let length: Double
        public let polylines: [[SIMD3<Double>]]
    }

    /// A point where three or more pieces meet.
    public struct Corner: Equatable, Sendable {
        public let point: SIMD3<Double>
        public let regions: [Int]
    }

    /// The position key (SurfaceWireframe's): coordinates that differ only in float noise hash together.
    public static let keyMM = 1e-4
    /// A shared edge shorter than this is a point, not an edge (spec §5).
    public static let touchMM = 1e-3
    /// A point this close outside a cut's plane is on it (the segment clip is closed, as core's triangle clip).
    static let clipMM = 1e-7

    public let mesh: ViewerMesh
    /// Distinct face ids of the mesh.
    public let faceCount: Int
    /// The whole-face shared-edge map (position-keyed), by face pair; segments in triangle order.
    public let faceSeams: [Pair: [Segment]]
    /// The partition, by id.
    public let pieces: [Piece]
    /// The seams between pieces (only those with a segment).
    public let seams: [Pair: Seam]
    /// Every point where three or more pieces meet, ordered by position.
    public let corners: [Corner]
    /// Per face with sectors: triangles (by centroid) no leaf sector of it holds — 0 on a clean split (a fact the
    /// tests print; such a remainder belongs to no piece).
    public let uncovered: [Int: Int]

    private let piecesOnFace: [Int: [Int]]
    private let trianglesOfFace: [Int: [Int]]
    private let pieceByID: [Int: Piece]

    // MARK: - building

    public init(mesh: ViewerMesh, regions: FlexibleRegions) {
        self.mesh = mesh
        let triCount = Swift.min(mesh.triangleCount, mesh.faceIDs.count)
        var byFace: [Int: [Int]] = [:]
        for t in 0..<triCount { byFace[Int(mesh.faceIDs[t]), default: []].append(t) }
        trianglesOfFace = byFace
        faceCount = byFace.count

        // the whole-face shared-edge map, keyed by position
        faceSeams = Self.faceSeams(mesh, triCount: triCount)

        // the partition: leaf sectors, then every face no leaf covers
        let faceSet = Set(byFace.keys)
        let parents = Set(regions.sectors.map(\.parentID))
        var ps: [Piece] = []
        var covered = Set<Int>()
        for s in regions.sectors.sorted(by: { $0.id < $1.id }) where !parents.contains(s.id) {
            let faces = FaceRegionGeometry.members(of: s, in: mesh).map { Int($0) }.filter { faceSet.contains($0) }.sorted()
            guard !faces.isEmpty else { continue }
            ps.append(Piece(id: FlexibleRegions.wireID(s), faces: faces, cuts: s.cuts))
            covered.formUnion(faces)
        }
        for f in faceSet.sorted() where !covered.contains(f) { ps.append(Piece(id: f, faces: [f], cuts: [])) }
        ps.sort { $0.id < $1.id }
        pieces = ps
        let byID = Dictionary(uniqueKeysWithValues: ps.map { ($0.id, $0) })
        pieceByID = byID
        var onFace: [Int: [Int]] = [:]
        for p in ps { for f in p.faces { onFace[f, default: []].append(p.id) } }
        piecesOnFace = onFace

        // what the sectors leave uncovered (a fact): triangles no piece of their face keeps any area of
        var unc: [Int: Int] = [:]
        for (f, ids) in onFace where ids.contains(where: { byID[$0]?.cuts.isEmpty == false }) {
            let n = (byFace[f] ?? []).filter { t in
                let tri = [Self.position(mesh, mesh.indices[3 * t]), Self.position(mesh, mesh.indices[3 * t + 1]),
                           Self.position(mesh, mesh.indices[3 * t + 2])]
                return !ids.contains { Self.area(Self.clipPolygon(tri, byID[$0]?.cuts ?? [])) > 0 }
            }.count
            if n > 0 { unc[f] = n }
        }
        uncovered = unc

        // the seams between pieces
        var segs: [Pair: [Segment]] = [:]
        for (fp, list) in faceSeams.sorted(by: { $0.key < $1.key }) {
            for x in onFace[fp.a] ?? [] {
                for y in onFace[fp.b] ?? [] where x != y {
                    guard let px = byID[x], let py = byID[y] else { continue }
                    for s in list {
                        // ★ AP2 RED STUB: face-level — the whole seam, whatever the pieces' cuts
                        _ = (px, py)
                        let d = (s.p, s.q)
                        // triA belongs to the pair's lower id
                        let seg = x < y ? Segment(p: d.0, q: d.1, triA: s.triA, triB: s.triB)
                                        : Segment(p: d.0, q: d.1, triA: s.triB, triB: s.triA)
                        segs[Pair(x, y), default: []].append(seg)
                    }
                }
            }
        }
        // two pieces of one face meet along their cuts
        var shareFace = Set<Pair>()
        for f in onFace.keys.sorted() {
            let ids = onFace[f] ?? []
            guard ids.count >= 2 else { continue }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    guard let px = byID[ids[i]], let py = byID[ids[j]] else { continue }
                    let pair = Pair(px.id, py.id)
                    shareFace.insert(pair)
                    _ = pair   // ★ AP2 RED STUB: two pieces of one face never meet along their cut
                }
            }
        }
        var out: [Pair: Seam] = [:]
        for (pair, list) in segs {
            let len = list.reduce(0) { $0 + $1.length }
            out[pair] = Seam(pair: pair, kind: shareFace.contains(pair) ? .cut : .edge, segments: list, length: len,
                             polylines: Self.chain(list))
        }
        seams = out
        corners = Self.meetingPoints(out)
    }

    /// The whole-face shared-edge map: an edge used by triangles of two (or more) faces, keyed by its two
    /// quantised endpoints in canonical order — the same edge however the mesh indexes its vertices.
    static func faceSeams(_ mesh: ViewerMesh, triCount: Int) -> [Pair: [Segment]] {
        struct Key: Hashable { let lo: SIMD3<Int64>; let hi: SIMD3<Int64> }
        struct Use { let face: Int; let tri: Int; let a: UInt32; let b: UInt32 }
        // ★ AP2 RED STUB: keyed by vertex INDEX (FaceTopology.adjacency's rule)
        func q(_ i: UInt32) -> SIMD3<Int64> { SIMD3(Int64(i), 0, 0) }
        var uses: [Key: [Use]] = [:]
        var order: [Key] = []
        for t in 0..<triCount {
            let f = Int(mesh.faceIDs[t])
            let v = (mesh.indices[3 * t], mesh.indices[3 * t + 1], mesh.indices[3 * t + 2])
            for (x, y) in [(v.0, v.1), (v.1, v.2), (v.2, v.0)] {
                let kx = q(x), ky = q(y)
                guard kx != ky else { continue }   // a degenerate edge
                let first = (kx.x, kx.y, kx.z) <= (ky.x, ky.y, ky.z)
                let k = Key(lo: first ? kx : ky, hi: first ? ky : kx)
                if uses[k] == nil { order.append(k) }
                uses[k, default: []].append(Use(face: f, tri: t, a: x, b: y))
            }
        }
        var out: [Pair: [Segment]] = [:]
        for k in order {
            guard let us = uses[k] else { continue }
            var firstOf: [Int: Use] = [:]
            var faces: [Int] = []
            for u in us where firstOf[u.face] == nil { firstOf[u.face] = u; faces.append(u.face) }
            guard faces.count >= 2 else { continue }
            faces.sort()
            for i in 0..<faces.count {
                for j in (i + 1)..<faces.count {
                    let ua = firstOf[faces[i]]!, ub = firstOf[faces[j]]!
                    out[Pair(faces[i], faces[j]), default: []].append(
                        Segment(p: position(mesh, ua.a), q: position(mesh, ua.b), triA: ua.tri, triB: ub.tri))
                }
            }
        }
        return out
    }

    // MARK: - adjacency

    /// The face pairs that share an edge (the app's map).
    public var facePairs: Set<Pair> { Set(faceSeams.keys) }

    /// Core's face_adjacency as pairs (element f lists face f's neighbours).
    public static func pairs(coreAdjacency adj: [[Int]]) -> Set<Pair> {
        var out = Set<Pair>()
        for (f, ns) in adj.enumerated() { for g in ns where g != f { out.insert(Pair(f, g)) } }
        return out
    }

    public func piece(_ id: Int) -> Piece? { pieceByID[id] }

    public func seam(_ x: Int, _ y: Int) -> Seam? { seams[Pair(x, y)] }

    /// Do two pieces share an edge longer than 1e-3 mm (clipped by both their cuts)?
    public func touches(_ x: Int, _ y: Int) -> Bool { x != y && (seam(x, y)?.length ?? 0) > Self.touchMM }

    /// The polylines two pieces share.
    public func sharedEdge(_ x: Int, _ y: Int) -> [[SIMD3<Double>]] { touches(x, y) ? seam(x, y)?.polylines ?? [] : [] }

    /// The pieces `x` touches, ascending.
    public func neighbours(of x: Int) -> [Int] {
        seams.keys.compactMap { p -> Int? in
            guard p.a == x || p.b == x, touches(p.a, p.b) else { return nil }
            return p.a == x ? p.b : p.a
        }.sorted()
    }

    /// Do `regions` form one connected footprint through shared edges? (One region: yes.)
    public func connected(_ regions: [Int]) -> Bool {
        let set = Set(regions)
        guard let first = regions.first else { return false }
        var seen: Set<Int> = [first], todo = [first]
        while let x = todo.popLast() {
            for y in set where !seen.contains(y) && touches(x, y) { seen.insert(y); todo.append(y) }
        }
        return seen == set
    }

    /// ★ THE WHOLE CHAIN of curved pieces between flats `a` and `b`: every curved piece on a SHORTEST path from `a`
    /// to `b` through curved pieces joined by smooth seams (`smooth`; core's 15° verdict in FlexibleEdgeCandidates).
    /// A fillet split along its length is returned whole (each part lies on such a path); the corner patches round it
    /// are not (their path is longer). nil when no such chain joins them. Ordered by distance from `a`, then id.
    public func blendChain(_ a: Int, _ b: Int, smooth: (Pair) -> Bool, curved: (Int) -> Bool) -> [Int]? {
        nil   // ★ AP2 RED STUB: no chain is ever found
    }

    // MARK: - triangles

    public static func position(_ mesh: ViewerMesh, _ i: UInt32) -> SIMD3<Double> {
        let b = Int(i) * 3
        return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
    }

    /// Viewer triangle `t`'s corners (model mm).
    public func triangle(_ t: Int) -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        (Self.position(mesh, mesh.indices[3 * t]), Self.position(mesh, mesh.indices[3 * t + 1]), Self.position(mesh, mesh.indices[3 * t + 2]))
    }

    /// The viewer triangles of piece `r`: its faces' triangles that keep some area inside its cuts (core's clip_into
    /// rule: a triangle a cut crosses belongs, in part, to both sides).
    public func memberTriangles(_ r: Int) -> [Int] {
        guard let p = pieceByID[r] else { return [] }
        return p.faces.flatMap { trianglesOfFace[$0] ?? [] }.filter { t in
            guard !p.cuts.isEmpty else { return true }
            let (a, b, c) = triangle(t)
            return Self.area(Self.clipPolygon([a, b, c], p.cuts)) > 0
        }.sorted()
    }

    /// A convex polygon clipped to the closed half-spaces of `cuts` (Sutherland–Hodgman, as core's clip_into).
    static func clipPolygon(_ poly: [SIMD3<Double>], _ cuts: [RegionCut]) -> [SIMD3<Double>] {
        var out = poly
        for c in cuts {
            guard out.count >= 3 else { return [] }
            var next: [SIMD3<Double>] = []
            for i in 0..<out.count {
                let a = out[i], b = out[(i + 1) % out.count]
                let da = simd_dot(a - c.point, c.normal), db = simd_dot(b - c.point, c.normal)
                if da >= 0 { next.append(a) }
                if (da >= 0) != (db >= 0) { next.append(a + (b - a) * (da / (da - db))) }
            }
            out = next
        }
        return out.count >= 3 ? out : []
    }

    /// A planar polygon's area (fan).
    static func area(_ poly: [SIMD3<Double>]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var s = SIMD3<Double>.zero
        for i in 1..<(poly.count - 1) { s += simd_cross(poly[i] - poly[0], poly[i + 1] - poly[0]) }
        return simd_length(s) / 2
    }

    // MARK: - the anchor (display only)

    /// ★ WHERE A PRESS'S ARROW STANDS (display only, spec §5): the corner where the regions meet; else the middle of
    /// the longest edge they share; else where a ray along `direction`, aimed at the regions' area centroid, lands on
    /// their triangles (inside their cuts) — a tilt's footprint, or a fillet's middle. Always ON the faces.
    public func anchor(regions: [Int], direction: SIMD3<Double>) -> SIMD3<Double>? {
        // ★ AP2 RED STUB: the footprint's area centroid (inside the part for an edge or a corner)
        var sum = SIMD3<Double>.zero, total = 0.0
        for r in Set(regions) {
            for t in memberTriangles(r) {
                let (a, b, c) = triangle(t)
                let w = simd_length(simd_cross(b - a, c - a)) / 2
                sum += (a + b + c) / 3 * w
                total += w
            }
        }
        return total > 0 ? sum / total : nil
    }

    /// A ray along `direction` through the regions' area centroid, landed on their nearest triangle inside their
    /// cuts; else the point of their triangles closest to the centroid.
    public func rayAnchor(regions: [Int], direction: SIMD3<Double>) -> SIMD3<Double>? {
        var tris: [(t: Int, cuts: [RegionCut])] = []
        for r in Set(regions).sorted() { for t in memberTriangles(r) { tris.append((t, pieceByID[r]?.cuts ?? [])) } }
        guard !tris.isEmpty else { return nil }
        // the AREA centroid of what the cuts keep (each triangle clipped, fanned)
        var sum = SIMD3<Double>.zero, total = 0.0
        for (t, cuts) in tris {
            let (a, b, c) = triangle(t)
            let poly = cuts.isEmpty ? [a, b, c] : Self.clipPolygon([a, b, c], cuts)
            guard poly.count >= 3 else { continue }
            for i in 1..<(poly.count - 1) {
                let w = simd_length(simd_cross(poly[i] - poly[0], poly[i + 1] - poly[0])) / 2
                sum += (poly[0] + poly[i] + poly[i + 1]) / 3 * w
                total += w
            }
        }
        guard total > 0 else { return nil }
        let centre = sum / total
        let len = simd_length(direction)
        if len.isFinite, len > 1e-12 {
            let d = direction / len
            let diag = Double(simd_length(mesh.bounds.max - mesh.bounds.min))
            let origin = centre - d * (diag + 1)
            var bestT = Double.infinity, hit: SIMD3<Double>? = nil
            for (t, cuts) in tris {
                let (a, b, c) = triangle(t)
                guard let s = Self.ray(origin, d, a, b, c), s < bestT else { continue }
                let p = origin + d * s
                guard cuts.isEmpty || Self.insideClosed(p, cuts) else { continue }
                bestT = s
                hit = p
            }
            if let hit { return hit }
        }
        var best = Double.infinity, point: SIMD3<Double>? = nil
        for (t, cuts) in tris {
            let (a, b, c) = triangle(t)
            let p = Self.closest(centre, a, b, c)
            let dd = simd_distance(p, centre)
            if dd < best, cuts.isEmpty || Self.insideClosed(p, cuts) { best = dd; point = p }
        }
        return point
    }

    // MARK: - handles (points, never mm)

    public enum HandleKind: String, Sendable { case corner, edge }

    /// Something to tap on the model: a corner dot or an edge pill, by its candidate number.
    public struct Spot: Equatable, Sendable {
        public let id: Int
        public let kind: HandleKind
        public let point: SIMD3<Double>
        public init(id: Int, kind: HandleKind, point: SIMD3<Double>) { self.id = id; self.kind = kind; self.point = point }
    }

    /// A handle on screen: where it is drawn and the rectangle a finger hits, in POINTS.
    public struct Handle: Equatable, Sendable {
        public let id: Int
        public let kind: HandleKind
        public let centre: CGPoint
        public let target: CGRect
    }

    /// ★ A TARGET A FINGER CAN HIT (Apple's 44 pt), at every zoom: sized in points, never in mm.
    public static let handleTargetPt: CGFloat = 44
    /// An edge pill is wider than tall, along nothing in particular (it sits at the edge's middle).
    public static let pillWidthPt: CGFloat = 64

    /// The spots' handles through the page's projection; a spot behind the camera has none.
    public static func handles(_ spots: [Spot], projection: CameraProjection) -> [Handle] {
        spots.compactMap { s in
            guard let c = projection.project(SIMD3<Float>(Float(s.point.x), Float(s.point.y), Float(s.point.z))) else { return nil }
            // ★ AP2 RED STUB: a 4 mm target, projected (shrinks as he zooms out)
            let e = projection.project(SIMD3<Float>(Float(s.point.x) + 4, Float(s.point.y), Float(s.point.z))) ?? c
            let side = 2 * CGFloat(hypot(e.x - c.x, e.y - c.y))
            return Handle(id: s.id, kind: s.kind, centre: c, target: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side))
        }
    }

    // MARK: - geometry helpers

    /// The arc-length middle of the longest polyline.
    public static func midpoint(_ polylines: [[SIMD3<Double>]]) -> SIMD3<Double>? {
        guard let pl = polylines.max(by: { length($0) < length($1) }), pl.count >= 2 else { return polylines.first?.first }
        let half = length(pl) / 2
        var run = 0.0
        for i in 1..<pl.count {
            let l = simd_distance(pl[i - 1], pl[i])
            if run + l >= half, l > 0 { return pl[i - 1] + (pl[i] - pl[i - 1]) * ((half - run) / l) }
            run += l
        }
        return pl.last
    }

    public static func length(_ pl: [SIMD3<Double>]) -> Double {
        guard pl.count >= 2 else { return 0 }
        return (1..<pl.count).reduce(0) { $0 + simd_distance(pl[$1 - 1], pl[$1]) }
    }

    /// Inside every cut, closed (a point on a cut's plane is in).
    static func insideClosed(_ p: SIMD3<Double>, _ cuts: [RegionCut]) -> Bool {
        cuts.allSatisfy { simd_dot(p - $0.point, $0.normal) >= -clipMM }
    }

    /// Segment [p, q] clipped to the closed half-spaces of `cuts`; nil when nothing is left.
    static func clip(_ p: SIMD3<Double>, _ q: SIMD3<Double>, _ cuts: [RegionCut]) -> (SIMD3<Double>, SIMD3<Double>)? {
        var t0 = 0.0, t1 = 1.0
        for c in cuts {
            let n = c.normal
            let dp = simd_dot(p - c.point, n), dq = simd_dot(q - c.point, n)
            if dp < -clipMM && dq < -clipMM { return nil }
            if dp >= -clipMM && dq >= -clipMM { continue }
            let t = dp / (dp - dq)
            if dp < -clipMM { t0 = Swift.max(t0, t) } else { t1 = Swift.min(t1, t) }
            if t0 > t1 { return nil }
        }
        let a = t0 == 0 ? p : p + (q - p) * t0, b = t1 == 1 ? q : p + (q - p) * t1
        return (a, b)
    }

    /// The line where two pieces of one face meet: each cut plane of either, through the face's triangles, clipped
    /// to both pieces (closed). Deduplicated (a plane through a mesh edge meets both its triangles there).
    static func cutLine(_ mesh: ViewerMesh, triangles: [Int], _ cx: [RegionCut], _ cy: [RegionCut]) -> [Segment] {
        var planes: [RegionCut] = []
        for c in cx + cy {
            let n = simd_normalize(c.normal)
            let same = planes.contains { o in
                simd_length(simd_cross(o.normal, n)) < 1e-9 && abs(simd_dot(c.point - o.point, o.normal)) < 1e-9
            }
            if !same { planes.append(RegionCut(point: c.point, normal: n)) }
        }
        var out: [Segment] = []
        var seen = Set<[Int64]>()
        for pl in planes {
            for t in triangles {
                let a = position(mesh, mesh.indices[3 * t]), b = position(mesh, mesh.indices[3 * t + 1]), c = position(mesh, mesh.indices[3 * t + 2])
                let d = [simd_dot(a - pl.point, pl.normal), simd_dot(b - pl.point, pl.normal), simd_dot(c - pl.point, pl.normal)]
                let v = [a, b, c]
                var pts: [SIMD3<Double>] = []
                for i in 0..<3 {
                    let j = (i + 1) % 3
                    if abs(d[i]) <= clipMM { pts.append(v[i]) }
                    if (d[i] > clipMM && d[j] < -clipMM) || (d[i] < -clipMM && d[j] > clipMM) {
                        pts.append(v[i] + (v[j] - v[i]) * (d[i] / (d[i] - d[j])))
                    }
                }
                // distinct points only
                var uniq: [SIMD3<Double>] = []
                for p in pts where !uniq.contains(where: { simd_distance($0, p) < keyMM }) { uniq.append(p) }
                guard uniq.count == 2 else { continue }
                guard let s1 = clip(uniq[0], uniq[1], cx), let s2 = clip(s1.0, s1.1, cy), simd_distance(s2.0, s2.1) > 0 else { continue }
                let k1 = qkey(s2.0), k2 = qkey(s2.1)
                let key = k1.lexicographicallyPrecedes(k2) ? k1 + k2 : k2 + k1
                guard seen.insert(key).inserted else { continue }
                out.append(Segment(p: s2.0, q: s2.1, triA: t, triB: t))
            }
        }
        return out
    }

    static func qkey(_ p: SIMD3<Double>) -> [Int64] {
        [Int64((p.x / keyMM).rounded()), Int64((p.y / keyMM).rounded()), Int64((p.z / keyMM).rounded())]
    }

    /// Segments chained into polylines through shared endpoints (by position key), longest first.
    static func chain(_ segs: [Segment]) -> [[SIMD3<Double>]] {
        var ends: [[Int64]: [Int]] = [:]
        for (i, s) in segs.enumerated() {
            ends[qkey(s.p), default: []].append(i)
            ends[qkey(s.q), default: []].append(i)
        }
        var used = [Bool](repeating: false, count: segs.count)
        var out: [[SIMD3<Double>]] = []
        func walk(from start: Int) -> [SIMD3<Double>] {
            used[start] = true
            var line = [segs[start].p, segs[start].q]
            // grow at the tail, then at the head
            for atTail in [true, false] {
                while true {
                    let end = atTail ? line.last! : line.first!
                    guard let next = ends[qkey(end)]?.first(where: { !used[$0] }) else { break }
                    used[next] = true
                    let s = segs[next]
                    let other = qkey(s.p) == qkey(end) ? s.q : s.p
                    if atTail { line.append(other) } else { line.insert(other, at: 0) }
                }
            }
            return line
        }
        // start at a free end (degree 1) so an open chain comes out whole, then any loops left
        for (i, s) in segs.enumerated() where !used[i] && ((ends[qkey(s.p)]?.count ?? 0) == 1 || (ends[qkey(s.q)]?.count ?? 0) == 1) {
            out.append(walk(from: i))
        }
        for i in 0..<segs.count where !used[i] { out.append(walk(from: i)) }
        return out.sorted { length($0) > length($1) }
    }

    /// Every point where three or more pieces meet: the seams' segment ends, gathered within 1e-3 mm. Ordered by
    /// position (−z, y, x); the point is a segment end (on the surface), the lowest by position of the gathered ones.
    static func meetingPoints(_ seams: [Pair: Seam]) -> [Corner] {
        struct End { let p: SIMD3<Double>; let a: Int; let b: Int }
        var ends: [End] = []
        for (pair, s) in seams.sorted(by: { $0.key < $1.key }) {
            for seg in s.segments {
                ends.append(End(p: seg.p, a: pair.a, b: pair.b))
                ends.append(End(p: seg.q, a: pair.a, b: pair.b))
            }
        }
        // union-find within touchMM through a grid of touchMM cells
        var parent = Array(0..<ends.count)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        func cell(_ p: SIMD3<Double>) -> SIMD3<Int64> {
            SIMD3(Int64((p.x / touchMM).rounded(.down)), Int64((p.y / touchMM).rounded(.down)), Int64((p.z / touchMM).rounded(.down)))
        }
        var grid: [SIMD3<Int64>: [Int]] = [:]
        for (i, e) in ends.enumerated() { grid[cell(e.p), default: []].append(i) }
        for (i, e) in ends.enumerated() {
            let c = cell(e.p)
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                for j in grid[c &+ SIMD3(Int64(dx), Int64(dy), Int64(dz))] ?? [] where j > i && simd_distance(e.p, ends[j].p) <= touchMM {
                    let ri = find(i), rj = find(j)
                    if ri != rj { parent[rj] = ri }
                }
            } } }
        }
        var groups: [Int: [Int]] = [:]
        for i in 0..<ends.count { groups[find(i), default: []].append(i) }
        func key(_ p: SIMD3<Double>) -> [Int64] { [Int64((-p.z / keyMM).rounded()), Int64((p.y / keyMM).rounded()), Int64((p.x / keyMM).rounded())] }
        var out: [Corner] = []
        for (_, members) in groups {
            let regions = Set(members.flatMap { [ends[$0].a, ends[$0].b] })
            guard regions.count >= 3 else { continue }
            let point = members.map { ends[$0].p }.min { key($0).lexicographicallyPrecedes(key($1)) }!
            out.append(Corner(point: point, regions: regions.sorted()))
        }
        return out.sorted { l, r in
            let kl = key(l.point), kr = key(r.point)
            return kl != kr ? kl.lexicographicallyPrecedes(kr) : l.regions.lexicographicallyPrecedes(r.regions)
        }
    }

    /// Ray–triangle (two-sided), the distance along the ray, or nil.
    static func ray(_ o: SIMD3<Double>, _ d: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double? {
        let e1 = b - a, e2 = c - a
        let h = simd_cross(d, e2), det = simd_dot(e1, h)
        guard abs(det) > 1e-14 else { return nil }
        let f = 1 / det, s = o - a, u = f * simd_dot(s, h)
        guard u >= -1e-12, u <= 1 + 1e-12 else { return nil }
        let qv = simd_cross(s, e1), v = f * simd_dot(d, qv)
        guard v >= -1e-12, u + v <= 1 + 1e-12 else { return nil }
        let t = f * simd_dot(e2, qv)
        return t > 0 ? t : nil
    }

    /// The point of triangle (a, b, c) closest to p (Ericson).
    static func closest(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let den = 1 / (va + vb + vc)
        return a + ab * (vb * den) + ac * (vc * den)
    }
}

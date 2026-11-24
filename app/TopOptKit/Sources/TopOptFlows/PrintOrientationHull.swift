// PrintOrientationHull — ★ notes27 P6 (builder H; his print orientation, SPEC 2d "Manual orientation": "he taps the face that
// goes on the bed"; his 11-23 evening "Both - flat sides and edges held by supports").
//
// A part can only rest on its convex hull. So, as PrusaSlicer's Place on face does (GLGizmoFlatten) and as core's own
// candidates are made (print_orientation.hpp `print_candidates`, the same numbers): the hull of the part shown, its coplanar
// facets merged into faces (0.5°, 0.02 mm), faces under 5 mm² dropped, the 30 largest kept; and the hull's edges between two
// such faces at least 10 mm long, the 30 longest kept, each up = −(n1 + n2)/|n1 + n2| (both faces lean equally). A face that
// does not hold the centre of mass over it "would tip"; an edge stands on its stand supports (core paints them).
import Foundation
import simd

public struct PrintHull: Equatable, Sendable {
    public struct Face: Equatable, Sendable {
        /// Outward normal (the part's own coordinates); the up it prints with is −normal.
        public var normal: SIMD3<Double>
        /// Its outline on the hull, counter-clockwise seen from outside.
        public var outline: [SIMD3<Double>]
        public var areaMM2: Double
        public var up: SIMD3<Double> { -normal }
    }
    public struct Edge: Equatable, Sendable {
        public var a: SIMD3<Double>
        public var b: SIMD3<Double>
        public var n1: SIMD3<Double>
        public var n2: SIMD3<Double>
        public var lengthMM: Double { simd_distance(a, b) }
        public var up: SIMD3<Double> { let s = n1 + n2; return simd_length(s) > 1e-12 ? -simd_normalize(s) : -n1 }
    }
    public var faces: [Face]
    public var edges: [Edge]
    public var centreOfMass: SIMD3<Double>

    /// core's CandidateRule, the numbers he can change in one place.
    public enum Rule {
        public static let faceMinMM2 = 5.0, coplanarDeg = 0.5, coplanarMM = 0.02, facesMax = 30
        public static let edgeMinMM = 10.0, edgesMax = 30
    }

    /// Whether the part stands on face `f`: its centre of mass, seen along the up, over the face's outline (D1: no margin).
    public func stands(on f: Face) -> Bool {
        let n = f.normal
        let (u, v) = Self.basis(n)
        let p = centreOfMass
        let q = SIMD2(simd_dot(p, u), simd_dot(p, v))
        let poly = f.outline.map { SIMD2(simd_dot($0, u), simd_dot($0, v)) }
        return Self.inside(q, poly)
    }

    /// The hull of a closed mesh (xyz…, triangles), its faces and edges. nil for fewer than four points not all on a plane.
    public static func of(vertices: [Float], indices: [Int32]) -> PrintHull? {
        // dedupe (to 1e-4 mm) and keep the scale for the tolerances
        var seen: [SIMD3<Int64>: Int] = [:]
        var pts: [SIMD3<Double>] = []
        var i = 0
        while i + 2 < vertices.count {
            let p = SIMD3(Double(vertices[i]), Double(vertices[i + 1]), Double(vertices[i + 2]))
            let k = SIMD3<Int64>(Int64((p.x * 1e4).rounded()), Int64((p.y * 1e4).rounded()), Int64((p.z * 1e4).rounded()))
            if seen[k] == nil { seen[k] = pts.count; pts.append(p) }
            i += 3
        }
        guard let tris = QuickHull.hull(pts) else { return nil }
        return from(hull: tris, points: pts, centre: centroid(vertices: vertices, indices: indices))
    }

    /// The faces and edges of a hull's triangles (outward, counter-clockwise).
    static func from(hull tris: [SIMD3<Int>], points pts: [SIMD3<Double>], centre: SIMD3<Double>) -> PrintHull {
        let n = tris.count
        var normal = [SIMD3<Double>](repeating: .zero, count: n), offset = [Double](repeating: 0, count: n)
        var area = [Double](repeating: 0, count: n)
        for (t, tri) in tris.enumerated() {
            let c = simd_cross(pts[tri.y] - pts[tri.x], pts[tri.z] - pts[tri.x])
            let l = simd_length(c)
            area[t] = l / 2
            normal[t] = l > 0 ? c / l : .zero
            offset[t] = simd_dot(normal[t], pts[tri.x])
        }
        // the triangle across each edge
        var across: [Int64: Int] = [:]
        func key(_ a: Int, _ b: Int) -> Int64 { Int64(a) << 32 | Int64(b) }
        for (t, tri) in tris.enumerated() { for (a, b) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] { across[key(a, b)] = t } }
        // merge coplanar neighbours (union-find)
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        let cosTol = cos(Rule.coplanarDeg * .pi / 180)
        for (t, tri) in tris.enumerated() {
            for (a, b) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] {
                guard let o = across[key(b, a)], o != t else { continue }
                if simd_dot(normal[t], normal[o]) >= cosTol, abs(offset[t] - offset[o]) <= Rule.coplanarMM {
                    let ra = find(t), rb = find(o)
                    if ra != rb { parent[ra] = rb }
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for t in 0..<n { groups[find(t), default: []].append(t) }
        struct G { var tris: [Int]; var normal: SIMD3<Double>; var area: Double }
        var gs: [Int: G] = [:]
        for (r, ts) in groups {
            var nn = SIMD3<Double>.zero, a = 0.0
            for t in ts { nn += normal[t] * area[t]; a += area[t] }
            gs[r] = G(tris: ts, normal: simd_length(nn) > 0 ? simd_normalize(nn) : normal[ts[0]], area: a)
        }
        // faces: the largest first, under 5 mm² never
        let kept = gs.filter { $0.value.area >= Rule.faceMinMM2 }.sorted { $0.value.area > $1.value.area }.prefix(Rule.facesMax)
        var faces: [Face] = []
        var faceOf: [Int: Int] = [:]
        for (r, g) in kept {
            var corner = Set<Int>()
            for t in g.tris { corner.insert(tris[t].x); corner.insert(tris[t].y); corner.insert(tris[t].z) }
            let (u, v) = basis(g.normal)
            let flat = corner.map { (p: pts[$0], q: SIMD2(simd_dot(pts[$0], u), simd_dot(pts[$0], v))) }
            let ring = hull2(flat.map(\.q))
            let outline = ring.compactMap { q in flat.first { $0.q == q }?.p }
            faceOf[r] = faces.count
            faces.append(Face(normal: g.normal, outline: outline, areaMM2: g.area))
        }
        // edges: where two kept faces meet on the hull, as one segment (the shared hull edges' farthest ends)
        var shared: [Int64: (ends: [SIMD3<Double>], f1: Int, f2: Int)] = [:]
        for (t, tri) in tris.enumerated() {
            let gt = find(t)
            for (a, b) in [(tri.x, tri.y), (tri.y, tri.z), (tri.z, tri.x)] where a < b {
                guard let o = across[key(b, a)] else { continue }
                let go = find(o)
                guard go != gt, let f1 = faceOf[gt], let f2 = faceOf[go] else { continue }
                let k = key(min(f1, f2), max(f1, f2))
                shared[k, default: (ends: [], f1: min(f1, f2), f2: max(f1, f2))].ends += [pts[a], pts[b]]
            }
        }
        var edges: [Edge] = []
        for (_, s) in shared {
            let n1 = faces[s.f1].normal, n2 = faces[s.f2].normal
            let dir = simd_cross(n1, n2)
            guard simd_length(dir) > 1e-9 else { continue }
            let d = simd_normalize(dir)
            let along = s.ends.map { simd_dot($0, d) }
            guard let lo = along.indices.min(by: { along[$0] < along[$1] }), let hi = along.indices.max(by: { along[$0] < along[$1] })
            else { continue }
            let e = Edge(a: s.ends[lo], b: s.ends[hi], n1: n1, n2: n2)
            if e.lengthMM >= Rule.edgeMinMM { edges.append(e) }
        }
        edges.sort { $0.lengthMM > $1.lengthMM }
        return PrintHull(faces: faces, edges: Array(edges.prefix(Rule.edgesMax)), centreOfMass: centre)
    }

    /// The volume centroid of a closed mesh (the centre of mass of the solid); the vertices' mean for an open one.
    public static func centroid(vertices v: [Float], indices t: [Int32]) -> SIMD3<Double> {
        var vol = 0.0, c = SIMD3<Double>.zero
        var k = 0
        func p(_ i: Int32) -> SIMD3<Double> { let j = Int(i) * 3; return SIMD3(Double(v[j]), Double(v[j + 1]), Double(v[j + 2])) }
        while k + 2 < t.count {
            let a = p(t[k]), b = p(t[k + 1]), d = p(t[k + 2])
            let w = simd_dot(a, simd_cross(b, d)) / 6
            vol += w
            c += (a + b + d) * (w / 4)
            k += 3
        }
        if abs(vol) > 1e-9 { return c / vol }
        var m = SIMD3<Double>.zero
        var i = 0
        while i + 2 < v.count { m += SIMD3(Double(v[i]), Double(v[i + 1]), Double(v[i + 2])); i += 3 }
        return v.count >= 3 ? m / Double(v.count / 3) : .zero
    }

    static func basis(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let a = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u = simd_normalize(simd_cross(n, a))
        return (u, simd_cross(n, u))
    }

    /// The 2D convex hull, counter-clockwise (Andrew's monotone chain).
    static func hull2(_ p: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let unique: Set<SIMD2<Double>> = Set(p)
        let s: [SIMD2<Double>] = unique.sorted { (a: SIMD2<Double>, b: SIMD2<Double>) -> Bool in
            if a.x != b.x { return a.x < b.x }
            return a.y < b.y
        }
        guard s.count > 2 else { return s }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
        for q in s { while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 1e-12 { lower.removeLast() }; lower.append(q) }
        for q in s.reversed() { while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 1e-12 { upper.removeLast() }; upper.append(q) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    static func inside(_ q: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
        guard poly.count >= 3 else { return false }
        var c = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }
}

/// A 3D convex hull (QuickHull with conflict lists): triangles of point indices, counter-clockwise seen from outside.
enum QuickHull {
    static func hull(_ p: [SIMD3<Double>]) -> [SIMD3<Int>]? {
        guard p.count >= 4 else { return nil }
        var lo = p[0], hi = p[0]
        for q in p { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let scale = max(simd_length(hi - lo), 1e-9)
        let eps = scale * 1e-9 * 10
        // the first tetrahedron: two extremes, the farthest from their line, the farthest from their plane
        var i0 = 0, i1 = 0
        for k in p.indices { if p[k].x < p[i0].x { i0 = k }; if p[k].x > p[i1].x { i1 = k } }
        if simd_distance(p[i0], p[i1]) < eps {
            for k in p.indices where simd_distance(p[k], p[i0]) > simd_distance(p[i1], p[i0]) { i1 = k }
        }
        guard simd_distance(p[i0], p[i1]) > eps else { return nil }
        let line = simd_normalize(p[i1] - p[i0])
        var i2 = -1, best = eps
        for k in p.indices {
            let d = simd_length(simd_cross(p[k] - p[i0], line))
            if d > best { best = d; i2 = k }
        }
        guard i2 >= 0 else { return nil }
        let pn = simd_normalize(simd_cross(p[i1] - p[i0], p[i2] - p[i0]))
        var i3 = -1
        best = eps
        for k in p.indices {
            let d = abs(simd_dot(p[k] - p[i0], pn))
            if d > best { best = d; i3 = k }
        }
        guard i3 >= 0 else { return nil }

        struct Face { var v: SIMD3<Int>; var n: SIMD3<Double>; var d: Double; var out: [Int]; var alive = true }
        var faces: [Face] = []
        var edgeFace: [Int64: Int] = [:]
        func key(_ a: Int, _ b: Int) -> Int64 { Int64(a) << 32 | Int64(b) }
        func make(_ a: Int, _ b: Int, _ c: Int) -> Int {
            let n = simd_normalize(simd_cross(p[b] - p[a], p[c] - p[a]))
            faces.append(Face(v: SIMD3(a, b, c), n: n, d: simd_dot(n, p[a]), out: []))
            let f = faces.count - 1
            edgeFace[key(a, b)] = f; edgeFace[key(b, c)] = f; edgeFace[key(c, a)] = f
            return f
        }
        // orient the tetrahedron outward
        let inside = (p[i0] + p[i1] + p[i2] + p[i3]) / 4
        var tet = [(i0, i1, i2), (i0, i3, i1), (i1, i3, i2), (i2, i3, i0)]
        for k in tet.indices {
            let (a, b, c) = tet[k]
            let n = simd_cross(p[b] - p[a], p[c] - p[a])
            if simd_dot(n, inside - p[a]) > 0 { tet[k] = (a, c, b) }
        }
        var first: [Int] = []
        for (a, b, c) in tet { first.append(make(a, b, c)) }
        // every other point to the face it is farthest above
        for k in p.indices where k != i0 && k != i1 && k != i2 && k != i3 {
            var bf = -1, bd = eps
            for f in first {
                let d = simd_dot(faces[f].n, p[k]) - faces[f].d
                if d > bd { bd = d; bf = f }
            }
            if bf >= 0 { faces[bf].out.append(k) }
        }
        var guardSteps = 0
        var work = first
        while let f = work.popLast() {
            guard faces[f].alive, !faces[f].out.isEmpty else { continue }
            guardSteps += 1
            if guardSteps > 4 * p.count + 100 { break }
            // the farthest point above this face
            var eye = faces[f].out[0], ed = -Double.infinity
            for k in faces[f].out {
                let d = simd_dot(faces[f].n, p[k]) - faces[f].d
                if d > ed { ed = d; eye = k }
            }
            // the faces it sees (flood across edges), and the horizon around them
            var visible: [Int] = [f]
            var isVisible: Set<Int> = [f]
            var stack = [f]
            while let g = stack.popLast() {
                let v = faces[g].v
                for (a, b) in [(v.x, v.y), (v.y, v.z), (v.z, v.x)] {
                    guard let h = edgeFace[key(b, a)], !isVisible.contains(h), faces[h].alive else { continue }
                    if simd_dot(faces[h].n, p[eye]) - faces[h].d > eps {
                        isVisible.insert(h); visible.append(h); stack.append(h)
                    }
                }
            }
            var horizon: [(Int, Int)] = []
            for g in visible {
                let v = faces[g].v
                for (a, b) in [(v.x, v.y), (v.y, v.z), (v.z, v.x)] {
                    if let h = edgeFace[key(b, a)], !isVisible.contains(h) { horizon.append((a, b)) }
                }
            }
            var orphans: [Int] = []
            for g in visible {
                faces[g].alive = false
                orphans += faces[g].out
                faces[g].out = []
                let v = faces[g].v
                for (a, b) in [(v.x, v.y), (v.y, v.z), (v.z, v.x)] where edgeFace[key(a, b)] == g { edgeFace[key(a, b)] = nil }
            }
            var made: [Int] = []
            for (a, b) in horizon { made.append(make(a, b, eye)) }
            for k in orphans where k != eye {
                var bf = -1, bd = eps
                for g in made {
                    let d = simd_dot(faces[g].n, p[k]) - faces[g].d
                    if d > bd { bd = d; bf = g }
                }
                if bf >= 0 { faces[bf].out.append(k) }
            }
            work += made
        }
        let out = faces.filter(\.alive).map(\.v)
        return out.count >= 4 ? out : nil
    }
}

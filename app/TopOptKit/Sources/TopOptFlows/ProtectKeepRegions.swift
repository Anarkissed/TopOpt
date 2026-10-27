import Foundation
import simd
import TopOptKit

/// ★ EXACT PROTECT (his ruling 2026-10-26 23:44): a Protected round hole or flat face exports as the CAD drew it, not as
/// ~1 mm voxels. Every Protect group also sends core's `keep_regions` (core/src/cli/job.cpp, CORE LIST item KEEP): inside
/// each region core freezes the part's own material and exports `(export − K) ∪ (part ∩ K)`, so the surface there IS the CAD.
///
/// THE ONE RULE: a region never reaches past that face's frozen Protect layer — anything else would put back unoptimized
/// original material. So:
/// - a ROUND HOLE is a cylinder on the bore's axis, radius = bore + Protect depth, over the face's own length, and only when
///   the protected faces close the full circle (a half-bore's cylinder would restore the other half's material);
/// - a FLAT FACE is box slab(s) on the face, Protect depth into the part, made of rectangles that fit INSIDE its outline (an
///   L-shaped face gets two or more; the leftover edge stays voxel, as today). Each slab also reaches a little OUTWARD, over
///   air, so the voxel surface's bumps above the face are trimmed to the plane;
/// - a tilted hole/face is sent in the oriented form only when the core takes it (`orientedAvailable`); a curved free-form
///   face, a boss (the material inside the cylinder) and a partial bore send nothing (today's behaviour).
public enum KeepRegionSpec: Equatable, Sendable {
    /// Axis-aligned box (core's min/max form).
    case box(min: SIMD3<Double>, max: SIMD3<Double>)
    /// Axis-aligned cylinder along world axis `axis` (0/1/2): min/max is its bounding box, square across the axis.
    case cylinder(min: SIMD3<Double>, max: SIMD3<Double>, axis: Int)
    /// Oriented cylinder (TO-core's oriented keep, 2026-10-26 23:48).
    case orientedCylinder(axisPoint: SIMD3<Double>, axisDir: SIMD3<Double>, radiusMM: Double, halfLengthMM: Double)
    /// Oriented box: `axes` are three orthonormal vectors.
    case orientedBox(center: SIMD3<Double>, axes: [SIMD3<Double>], halfExtentsMM: SIMD3<Double>)

    /// The job.json object (`keep_regions[]`).
    public var json: [String: Any] {
        func a(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }
        switch self {
        case let .box(lo, hi): return ["shape": "box", "min": a(lo), "max": a(hi)]
        case let .cylinder(lo, hi, axis): return ["shape": "cylinder", "min": a(lo), "max": a(hi), "axis": axis]
        case let .orientedCylinder(p, d, r, h):
            return ["shape": "cylinder", "axis_point": a(p), "axis_dir": a(d), "radius_mm": r, "half_length_mm": h]
        case let .orientedBox(c, axes, h):
            return ["shape": "box", "center": a(c), "axes": axes.map(a), "half_extents_mm": a(h)]
        }
    }
}

public enum ProtectKeepRegions {
    /// Whether the core in this release takes the oriented form (TO-core's job, 2026-10-26 23:48). Off ⇒ tilted holes and
    /// faces send nothing, and the Protect (i) keeps its X/Y/Z line.
    public static var orientedAvailable = false

    /// The Protect (i), in plain words.
    public static var info: String {
        orientedAvailable
            ? "Protected flat faces and round holes come out exactly as drawn in your CAD, at any angle. Curved faces keep the printed-grid surface."
            : "Protected flat faces and round holes come out exactly as drawn in your CAD when they line up with the part's X, Y or Z. Tilted and curved faces keep the printed-grid surface."
    }

    /// A direction is "lined up" when it is within ~0.1° of a world axis.
    static let alignCos = 0.99999
    /// At most this many slabs per face (an outline that needs more keeps its leftover edge voxel, as today).
    static let maxBoxesPerFace = 16

    /// One protected face: its id in `mesh` and its Protect depth (mm).
    public struct Face: Equatable, Sendable {
        public let id: Int32
        public let depthMM: Double
        public init(id: Int32, depthMM: Double) { self.id = id; self.depthMM = depthMM }
    }

    /// The keep regions for a run's protected faces. `outwardMM` is how far each flat slab reaches over the air above its
    /// face (the voxel surface's bumps sit within about one voxel of it).
    public static func regions(_ faces: [Face], in mesh: ViewerMesh, outwardMM: Double) -> [KeepRegionSpec] {
        var out: [KeepRegionSpec] = []
        var bores: [(face: Face, geo: StepFaceGeometry)] = []
        for f in faces {
            guard f.depthMM > 0, let geo = mesh.faceGeometry(f.id) else { continue }
            switch geo.kind {
            case .plane: out += slabs(f, geo: geo, mesh: mesh, outwardMM: outwardMM)
            case .cylinder: bores.append((f, geo))
            case .other: continue
            }
        }
        out += boreCylinders(bores, mesh: mesh, endMM: outwardMM)
        return out
    }

    // MARK: round holes

    /// Coaxial protected bore faces (same radius, same axis line) closing the full circle → one cylinder.
    /// TO-core's finding (2026-10-27 04:22): a region flush with the surface leaves the voxel skin poking past it, so the
    /// cylinder runs `endMM` past each end that OPENS INTO AIR — never past a blind hole's floor (solid part beyond it).
    static func boreCylinders(_ bores: [(face: Face, geo: StepFaceGeometry)], mesh: ViewerMesh, endMM: Double = 0) -> [KeepRegionSpec] {
        var sets: [[(face: Face, geo: StepFaceGeometry)]] = []
        for b in bores {
            let d = simd_normalize(b.geo.axisDir)
            guard b.geo.cylinderRadiusMM > 0, simd_length(b.geo.axisDir) > 1e-9,
                  FaceTopology.boreAxisMetrics(b.face.id, in: mesh, axisPoint: SIMD3<Float>(b.geo.axisPoint),
                                               axisDir: SIMD3<Float>(d)).concave else { continue }   // a boss: never
            if let i = sets.firstIndex(where: { s in
                let g = s[0].geo, e = simd_normalize(g.axisDir)
                let off = (b.geo.axisPoint - g.axisPoint) - e * simd_dot(b.geo.axisPoint - g.axisPoint, e)
                return abs(g.cylinderRadiusMM - b.geo.cylinderRadiusMM) < 0.01 && abs(simd_dot(d, e)) > alignCos
                    && simd_length(off) < 0.01
            }) { sets[i].append(b) } else { sets.append([b]) }
        }
        var out: [KeepRegionSpec] = []
        for s in sets {
            let g = s[0].geo
            let dir = simd_normalize(g.axisDir)
            guard fullCircle(s.map(\.face.id), mesh: mesh, axisPoint: g.axisPoint, axisDir: dir) else { continue }
            var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
            for b in s {
                guard let sp = mesh.faceAxialSpan(b.face.id, axisPoint: SIMD3<Float>(g.axisPoint),
                                                  axisDir: SIMD3<Float>(dir)) else { continue }
                lo = min(lo, Double(sp.lo)); hi = max(hi, Double(sp.hi))
            }
            guard hi > lo else { continue }
            let probe = min(0.5, (hi - lo) / 4)   // just past the end, on the axis: air for an open end, part for a floor
            if !insideSolid(g.axisPoint + dir * (lo - probe), mesh) { lo -= endMM }
            if !insideSolid(g.axisPoint + dir * (hi + probe), mesh) { hi += endMM }
            // the shallowest Protect depth among the set: the cylinder never reaches past any face's frozen layer
            let r = g.cylinderRadiusMM + s.map(\.face.depthMM).min()!
            let mid = g.axisPoint + dir * ((lo + hi) / 2)
            if let a = worldAxis(dir) {
                var mn = mid - SIMD3(repeating: r), mx = mid + SIMD3(repeating: r)
                mn[a] = mid[a] - (hi - lo) / 2; mx[a] = mid[a] + (hi - lo) / 2
                out.append(.cylinder(min: mn, max: mx, axis: a))
            } else if orientedAvailable {
                out.append(.orientedCylinder(axisPoint: mid, axisDir: dir, radiusMM: r, halfLengthMM: (hi - lo) / 2))
            }
        }
        return out
    }

    /// Whether the faces' triangles wrap the whole 360° about the axis (5° bins, every one touched).
    static func fullCircle(_ faces: [Int32], mesh: ViewerMesh, axisPoint: SIMD3<Double>, axisDir: SIMD3<Double>) -> Bool {
        let (u, v) = basis(axisDir)
        let bins = 72
        var hit = [Bool](repeating: false, count: bins)
        let want = Set(faces)
        for t in 0..<min(mesh.triangleCount, mesh.faceIDs.count) where want.contains(mesh.faceIDs[t]) {
            var angs: [Double] = []
            for k in 0..<3 {
                let p = point(mesh, Int(mesh.indices[t * 3 + k])) - axisPoint
                angs.append(atan2(simd_dot(p, v), simd_dot(p, u)))
            }
            // unwrap the triangle's corners next to its first one, then mark every bin it spans
            let a0 = angs[0]
            let un = angs.map { a -> Double in var d = a - a0; while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }; return a0 + d }
            let lo = un.min()!, hi = un.max()!
            var x = lo
            while x <= hi + 1e-9 {
                var n = Int(floor((x + .pi) / (2 * .pi) * Double(bins))) % bins
                if n < 0 { n += bins }
                hit[n] = true
                x += 2 * .pi / Double(bins) / 2
            }
        }
        return !hit.contains(false)
    }

    // MARK: flat faces

    /// Box slabs on a flat face: rectangles inside its outline, `depthMM` into the part, `outwardMM` over the air.
    static func slabs(_ f: Face, geo: StepFaceGeometry, mesh: ViewerMesh, outwardMM: Double) -> [KeepRegionSpec] {
        // the OUTWARD normal from the tessellation's own winding (area-weighted), the plane point from the CAD
        var nsum = SIMD3<Double>.zero
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for t in 0..<min(mesh.triangleCount, mesh.faceIDs.count) where mesh.faceIDs[t] == f.id {
            let a = point(mesh, Int(mesh.indices[t * 3])), b = point(mesh, Int(mesh.indices[t * 3 + 1]))
            let c = point(mesh, Int(mesh.indices[t * 3 + 2]))
            nsum += simd_cross(b - a, c - a)
            tris.append((a, b, c))
        }
        guard !tris.isEmpty, simd_length(nsum) > 1e-12 else { return [] }
        // the CAD's exact normal, turned to face the way the winding says is out
        var n = simd_length(geo.planeNormal) > 1e-9 ? simd_normalize(geo.planeNormal) : simd_normalize(nsum)
        if simd_dot(n, nsum) < 0 { n = -n }
        let axis = worldAxis(n)
        guard axis != nil || orientedAvailable else { return [] }
        if let a = axis { n = .zero; n[a] = nsum[a] > 0 ? 1 : -1 }
        let (u, v): (SIMD3<Double>, SIMD3<Double>) = axis.map { a in
            var e1 = SIMD3<Double>.zero, e2 = SIMD3<Double>.zero
            e1[(a + 1) % 3] = 1; e2[(a + 2) % 3] = 1
            return (e1, e2)
        } ?? basis(n)
        let plane = simd_dot(geo.planeOrigin, n)
        let poly = tris.map { (SIMD2(simd_dot($0.0, u), simd_dot($0.0, v)), SIMD2(simd_dot($0.1, u), simd_dot($0.1, v)),
                               SIMD2(simd_dot($0.2, u), simd_dot($0.2, v))) }
        let rects = insideRectangles(poly)
        let lo = plane - f.depthMM, hi = plane + outwardMM   // along n
        return rects.map { r in
            if let a = axis {
                var mn = SIMD3<Double>.zero, mx = SIMD3<Double>.zero
                mn[(a + 1) % 3] = r.min.x; mx[(a + 1) % 3] = r.max.x
                mn[(a + 2) % 3] = r.min.y; mx[(a + 2) % 3] = r.max.y
                // n is ±e_a: the slab runs from `depth` inside to `outward` above, whichever way the face looks
                let s = n[a]
                mn[a] = min(s * lo, s * hi); mx[a] = max(s * lo, s * hi)
                return .box(min: mn, max: mx)
            }
            let c2 = (r.min + r.max) / 2, h2 = (r.max - r.min) / 2
            let center = u * c2.x + v * c2.y + n * ((lo + hi) / 2)
            return .orientedBox(center: center, axes: [u, v, n], halfExtentsMM: SIMD3(h2.x, h2.y, (hi - lo) / 2))
        }
    }

    /// Rectangles (in the face's own u/v) that lie INSIDE the union of its triangles: a grid whose lines fall on the
    /// outline's bounding box, every cell tested at its four corners and centre, then merged greedily into the fewest boxes.
    /// A rectangular face is exactly one box, its own outline.
    static func insideRectangles(_ tris: [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)]) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        var lo = SIMD2<Double>(repeating: .greatestFiniteMagnitude), hi = -lo
        for t in tris { for p in [t.0, t.1, t.2] { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
        let ext = hi - lo
        guard ext.x > 1e-6, ext.y > 1e-6 else { return [] }
        let h = min(max(max(ext.x, ext.y) / 64, 0.1), 2.0)
        let nu = max(1, Int(ceil(ext.x / h))), nv = max(1, Int(ceil(ext.y / h)))
        let hu = ext.x / Double(nu), hv = ext.y / Double(nv)
        let eps = 1e-6 * max(ext.x, ext.y) + 1e-6
        func inside(_ p: SIMD2<Double>) -> Bool {
            tris.contains { t in
                func s(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) }
                let d0 = s(t.0, t.1), d1 = s(t.1, t.2), d2 = s(t.2, t.0)
                // edge tests scaled by the edge's length, so `eps` is a distance
                let l0 = simd_length(t.1 - t.0), l1 = simd_length(t.2 - t.1), l2 = simd_length(t.0 - t.2)
                let e0 = eps * max(l0, 1e-12), e1 = eps * max(l1, 1e-12), e2 = eps * max(l2, 1e-12)
                return (d0 >= -e0 && d1 >= -e1 && d2 >= -e2) || (d0 <= e0 && d1 <= e1 && d2 <= e2)
            }
        }
        // corner (i, j) is inside; a cell is inside when its 4 corners and centre are
        var corner = [[Bool]](repeating: [Bool](repeating: false, count: nv + 1), count: nu + 1)
        for i in 0...nu { for j in 0...nv { corner[i][j] = inside(lo + SIMD2(Double(i) * hu, Double(j) * hv)) } }
        var cell = [[Bool]](repeating: [Bool](repeating: false, count: nv), count: nu)
        for i in 0..<nu { for j in 0..<nv {
            cell[i][j] = corner[i][j] && corner[i + 1][j] && corner[i][j + 1] && corner[i + 1][j + 1]
                && inside(lo + SIMD2((Double(i) + 0.5) * hu, (Double(j) + 0.5) * hv))
        } }
        var used = cell.map { $0.map { _ in false } }
        var rects: [(min: SIMD2<Double>, max: SIMD2<Double>, area: Double)] = []
        for j in 0..<nv { for i in 0..<nu where cell[i][j] && !used[i][j] {
            var w = 1
            while i + w < nu, cell[i + w][j], !used[i + w][j] { w += 1 }
            var hgt = 1
            grow: while j + hgt < nv {
                for k in i..<(i + w) where !cell[k][j + hgt] || used[k][j + hgt] { break grow }
                hgt += 1
            }
            for k in i..<(i + w) { for m in j..<(j + hgt) { used[k][m] = true } }
            let a = lo + SIMD2(Double(i) * hu, Double(j) * hv)
            let b = lo + SIMD2(Double(i + w) * hu, Double(j + hgt) * hv)
            rects.append((a, b, (b.x - a.x) * (b.y - a.y)))
        } }
        return rects.sorted { $0.area > $1.area }.prefix(maxBoxesPerFace).map { ($0.min, $0.max) }
    }

    // MARK: helpers

    /// Whether `p` lies inside the closed part: ray parity along a slightly skewed direction.
    static func insideSolid(_ p: SIMD3<Double>, _ m: ViewerMesh) -> Bool {
        let d = simd_normalize(SIMD3<Double>(0.5773, 0.5774, 0.5775))
        var hits = 0
        for t in 0..<m.triangleCount {
            let a = point(m, Int(m.indices[t * 3])), b = point(m, Int(m.indices[t * 3 + 1])), c = point(m, Int(m.indices[t * 3 + 2]))
            let e1 = b - a, e2 = c - a, h = simd_cross(d, e2), det = simd_dot(e1, h)
            guard abs(det) > 1e-12 else { continue }
            let s = p - a, u = simd_dot(s, h) / det
            guard u >= 0, u <= 1 else { continue }
            let q = simd_cross(s, e1), v = simd_dot(d, q) / det
            guard v >= 0, u + v <= 1 else { continue }
            if simd_dot(e2, q) / det > 1e-9 { hits += 1 }
        }
        return hits % 2 == 1
    }

    static func worldAxis(_ d: SIMD3<Double>) -> Int? {
        let n = simd_normalize(d)
        for a in 0..<3 where abs(n[a]) >= alignCos { return a }
        return nil
    }

    static func basis(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let seed: SIMD3<Double> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(seed - n * simd_dot(seed, n))
        return (u, simd_normalize(simd_cross(n, u)))
    }

    static func point(_ m: ViewerMesh, _ i: Int) -> SIMD3<Double> {
        SIMD3(Double(m.positions[i * 3]), Double(m.positions[i * 3 + 1]), Double(m.positions[i * 3 + 2]))
    }
}

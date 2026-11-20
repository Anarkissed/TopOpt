// OrganicSpotPaint — ★ ORGANIC CUT 2, his certify wizard (11-19): "the area is coloured to show the issue AND outlined. If
// the outline is in view, it is visible, if it is covered it is behind something or around the other side." The weak spots
// come from the strength check's `fields.bin` block 3 (each voxel's spot id, 0 none; LatticeReview's OS15), kept in the
// result's report as `organic_spot_voxels` (the listed spots' voxels only). Here the part's own surface is coloured where it
// lies in an issue's spots, and a thin tube runs round the coloured area: drawn depth-tested like the part, so a covered
// outline is hidden, never seen through.
import Foundation
import simd

/// The listed weak spots' voxels on the check's grid (index i + nx (j + ny k); the grid's origin is its low corner).
public struct OrganicSpotGrid: Equatable, Sendable {
    public var nx: Int, ny: Int, nz: Int
    public var origin: SIMD3<Double>
    public var spacing: Double
    /// Spot id → its voxels.
    public var voxels: [Int: [Int32]]

    public static let reportKey = "organic_spot_voxels"
    /// The most voxels kept (a report stays small; the listed spots are far fewer on any part he has made).
    public static let cap = 300_000

    public init(nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, spacing: Double, voxels: [Int: [Int32]]) {
        self.nx = nx; self.ny = ny; self.nz = nz; self.origin = origin; self.spacing = spacing; self.voxels = voxels
    }

    /// From block 3's per-voxel ids, keeping the listed spots only. nil: no grid, or none of them has a voxel.
    public static func from(ids: [Float], nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, spacing: Double,
                            listed: Set<Int>) -> OrganicSpotGrid? {
        guard nx > 0, ny > 0, nz > 0, spacing > 0, ids.count == nx * ny * nz, !listed.isEmpty else { return nil }
        var out: [Int: [Int32]] = [:]
        var n = 0
        for (i, v) in ids.enumerated() where v > 0.5 {
            let id = Int(v.rounded())
            guard listed.contains(id) else { continue }
            out[id, default: []].append(Int32(i))
            n += 1
            if n >= cap { break }
        }
        return out.isEmpty ? nil : OrganicSpotGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing, voxels: out)
    }

    public var json: [String: Any] {
        ["grid": [nx, ny, nz], "origin": [origin.x, origin.y, origin.z], "spacing": spacing,
         "spots": Dictionary(uniqueKeysWithValues: voxels.map { (String($0.key), $0.value.map { Int($0) }) })]
    }

    public init?(json: Any?) {
        guard let o = json as? [String: Any], let g = o["grid"] as? [NSNumber], g.count == 3,
              let og = o["origin"] as? [NSNumber], og.count == 3, let s = (o["spacing"] as? NSNumber)?.doubleValue, s > 0,
              let spots = o["spots"] as? [String: Any] else { return nil }
        var v: [Int: [Int32]] = [:]
        for (k, list) in spots {
            guard let id = Int(k), let a = list as? [NSNumber] else { continue }
            v[id] = a.map { Int32(truncatingIfNeeded: $0.intValue) }
        }
        guard !v.isEmpty else { return nil }
        self.init(nx: g[0].intValue, ny: g[1].intValue, nz: g[2].intValue,
                  origin: SIMD3(og[0].doubleValue, og[1].doubleValue, og[2].doubleValue), spacing: s, voxels: v)
    }

    /// The voxel a point lies in (nil outside the grid).
    func voxel(_ p: SIMD3<Double>) -> Int32? {
        let q = (p - origin) / spacing
        let i = Int(q.x.rounded(.down)), j = Int(q.y.rounded(.down)), k = Int(q.z.rounded(.down))
        guard i >= 0, j >= 0, k >= 0, i < nx, j < ny, k < nz else { return nil }
        return Int32(i + nx * (j + ny * k))
    }

    /// `set` grown by one voxel each way (the 26 around each).
    func dilated(_ set: Set<Int32>) -> Set<Int32> {
        var out = set
        for v in set {
            let idx = Int(v), i = idx % nx, j = (idx / nx) % ny, k = idx / (nx * ny)
            for dk in -1...1 { for dj in -1...1 { for di in -1...1 {
                let a = i + di, b = j + dj, c = k + dk
                guard a >= 0, b >= 0, c >= 0, a < nx, b < ny, c < nz else { continue }
                out.insert(Int32(a + nx * (b + ny * c)))
            } } }
        }
        return out
    }
}

public enum OrganicSpotPaint {
    /// The weak area's colour on the part, and its outline's.
    public static let fill = SIMD3<Float>(0.98, 0.47, 0.16)
    public static let line = SIMD3<Float>(0.80, 0.16, 0.04)
    public static let fillAlpha: Float = 0.92

    public struct Result: Sendable {
        /// One per flat vertex of the viewer's mesh: the spot colour on its triangles, alpha 0 (the part's own) elsewhere.
        public var tints: [SIMD4<Float>]
        /// The outline's tube faces (model mm; position + premultiplied rgba, stride 7), for the viewer's volume pass.
        public var outline: [Float]
        /// The triangles coloured, and how far the spots had to grow to reach the surface (0: they touch it).
        public var painted: Int
        public var grown: Int
        /// Changes whenever the drawing does (the viewer re-uploads on it).
        public var key: Int
    }

    /// The tube's radius as a share of the part's diagonal (about 0.5 mm wide on a 100 mm part: a few pixels on the iPad).
    static let tubeShare: Float = 0.0025

    /// Colour the flat mesh's triangles that lie in the issue's spots (a triangle's centre, or a point just inside it, in a
    /// spot voxel), and outline them. A spot buried inside the solid, touching no surface, grows a voxel at a time (up to
    /// three) to the surface nearest it. `flatPositions`/`flatNormals`: the viewer's flat mesh (three vertices a triangle).
    public static func paint(flatPositions p: [Float], flatNormals n: [Float], grid: OrganicSpotGrid, ids: [Int]) -> Result {
        let triangles = min(p.count, n.count) / 9
        var set = Set(ids.flatMap { grid.voxels[$0] ?? [] })
        var painted = [Bool](repeating: false, count: triangles)
        var count = 0, grown = 0
        guard triangles > 0, !set.isEmpty else {
            return Result(tints: [], outline: [], painted: 0, grown: 0, key: 0)
        }
        let s = grid.spacing
        func pos(_ v: Int) -> SIMD3<Double> { SIMD3(Double(p[v * 3]), Double(p[v * 3 + 1]), Double(p[v * 3 + 2])) }
        while true {
            for t in 0..<triangles where !painted[t] {
                let c = (pos(3 * t) + pos(3 * t + 1) + pos(3 * t + 2)) / 3
                let nn = SIMD3(Double(n[9 * t]), Double(n[9 * t + 1]), Double(n[9 * t + 2]))
                for probe in [c - nn * (0.5 * s), c, c - nn * (0.25 * s)] {
                    if let v = grid.voxel(probe), set.contains(v) { painted[t] = true; count += 1; break }
                }
            }
            if count > 0 || grown >= 3 { break }
            set = grid.dilated(set)
            grown += 1
        }
        let vertexCount = triangles * 3
        var tints = [SIMD4<Float>](repeating: .zero, count: vertexCount)
        let fillC = SIMD4<Float>(fill.x, fill.y, fill.z, fillAlpha)
        for t in 0..<triangles where painted[t] { tints[3 * t] = fillC; tints[3 * t + 1] = fillC; tints[3 * t + 2] = fillC }

        // ── the outline: each coloured triangle's edges not shared with another coloured triangle ──
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for v in 0..<vertexCount { let q = SIMD3(p[v * 3], p[v * 3 + 1], p[v * 3 + 2]); lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let diag = simd_length(hi - lo)
        let quantum = max(diag * 1e-6, 1e-6)
        struct Q: Hashable { var x: Int32, y: Int32, z: Int32 }
        func q(_ v: Int) -> Q {
            Q(x: Int32((p[v * 3] / quantum).rounded()), y: Int32((p[v * 3 + 1] / quantum).rounded()),
              z: Int32((p[v * 3 + 2] / quantum).rounded()))
        }
        struct E: Hashable { var a: Q, b: Q }
        var edges: [E: (count: Int, a: Int, b: Int, t: Int)] = [:]
        for t in 0..<triangles where painted[t] {
            for (i, j) in [(0, 1), (1, 2), (2, 0)] {
                let va = 3 * t + i, vb = 3 * t + j
                let qa = q(va), qb = q(vb)
                let key = (qa.x, qa.y, qa.z) < (qb.x, qb.y, qb.z) ? E(a: qa, b: qb) : E(a: qb, b: qa)
                if let e = edges[key] { edges[key] = (e.count + 1, e.a, e.b, e.t) } else { edges[key] = (1, va, vb, t) }
            }
        }
        let r = max(diag * tubeShare, 1e-3)
        let lineC = SIMD4<Float>(line.x, line.y, line.z, 1)   // opaque: premultiplied is the colour itself
        var out: [Float] = []
        func push(_ a: SIMD3<Float>) { out += [a.x, a.y, a.z, lineC.x, lineC.y, lineC.z, lineC.w] }
        for e in edges.values where e.count == 1 {
            let a = SIMD3(p[e.a * 3], p[e.a * 3 + 1], p[e.a * 3 + 2]), b = SIMD3(p[e.b * 3], p[e.b * 3 + 1], p[e.b * 3 + 2])
            let nn = simd_normalize(SIMD3(n[9 * e.t], n[9 * e.t + 1], n[9 * e.t + 2]))
            let d = b - a
            guard simd_length(d) > 1e-9, nn.x.isFinite else { continue }
            let u = nn, w = simd_normalize(simd_cross(simd_normalize(d), nn))
            // a three-sided tube round the edge, its lowest side on the surface (the part hides what is behind it)
            let ring = [u, -0.5 * u + 0.866 * w, -0.5 * u - 0.866 * w].map { $0 * r + u * r }
            for k in 0..<3 {
                let p0 = a + ring[k], p1 = a + ring[(k + 1) % 3], p2 = b + ring[(k + 1) % 3], p3 = b + ring[k]
                push(p0); push(p1); push(p2); push(p0); push(p2); push(p3)
            }
        }
        var h = Hasher()
        h.combine(ids); h.combine(count); h.combine(out.count); h.combine(triangles)
        return Result(tints: tints, outline: out, painted: count, grown: grown, key: h.finalize())
    }
}

/// Holds the last paint so a SwiftUI body pass does not repaint (one paint per issue and mesh).
@MainActor public final class OrganicSpotPaintMemo: ObservableObject {
    private var last: (key: String, result: OrganicSpotPaint.Result)?
    public init() {}
    public func paint(issue: String, ids: [Int], grid: OrganicSpotGrid, mesh: ViewerMesh) -> OrganicSpotPaint.Result {
        let key = issue + "·" + ids.map(String.init).joined(separator: ",") + "·\(mesh.flat.vertexCount)·\(mesh.signature.contentHash)"
        if let l = last, l.key == key { return l.result }
        let r = OrganicSpotPaint.paint(flatPositions: mesh.flat.positions, flatNormals: mesh.flat.normals, grid: grid, ids: ids)
        last = (key, r)
        return r
    }
}

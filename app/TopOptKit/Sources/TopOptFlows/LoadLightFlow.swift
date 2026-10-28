// LoadLightFlow — ★ THE LOAD PATH AS LIGHT THROUGH THE PART (his iPad 2026-10-28).
//
// "The load path isn't working … it literally starts in midair then takes a path that doesn't even make sense … Either make a
// GOOD version of this (with maybe a highlight instead of a sperm/arrow) or remove it entirely. I'd prefer a good version.
// Something that feels like a light is flowing through the inside of the body, lighting up the walls and edges and corners as
// it passes through."
//
// The old view seeded comet arrows at the load GROUPS' centroids (the middle of a hole is air) and stepped them through a
// principal-direction field (the shake). This one never leaves the material:
//   * ARRIVAL — how soon the load reaches each printed voxel, walking the printed voxels only (6-neighbour Dijkstra) from
//     the voxels nearest each load point. A step is quicker through stressed material (cost ∝ 1 / (0.15 + σ/σmax)), so the
//     light races down the members that carry the load and lingers in the lightly loaded ones. Normalised to 0…1.
//   * STRENGTH — √(σ/σmax) at the voxel: a load-carrying wall glows brighter than a lightly loaded one.
// Each frame a band of light sweeps arrival 0 → 1 with a fading trail, painted on the part's own surface (per flat vertex),
// so the walls, edges and corners light up as it passes. Pure and deterministic; the drawing is the Results tint path.

import Foundation
import simd

public struct LoadLightFlow: Sendable {
    /// Per flat vertex: when the light reaches it (0…1), or −1 where no material path reaches it.
    public let arrival: [Float]
    /// Per flat vertex: how brightly it glows when lit (0…1).
    public let strength: [Float]

    /// One sweep runs arrival 0 → 1, then the trail fades out before the next.
    public static let sweepEnd: Float = 1.35
    static let headWidth: Float = 0.09
    static let trailLength: Float = 0.4
    static let body = SIMD3<Float>(0.17, 0.19, 0.23)
    static let light = SIMD3<Float>(1.0, 0.9, 0.62)

    /// Build from the shown stress field and the load points (model frame). Nil when there is nothing to flow through.
    public static func build(positions: [Float], field f: StressField, seeds: [SIMD3<Float>]) -> LoadLightFlow? {
        guard !f.isEmpty, !seeds.isEmpty, f.values.count == f.nx * f.ny * f.nz else { return nil }
        let peak = f.values.max() ?? 0
        guard peak > 0 else { return nil }
        let n = f.values.count, nx = f.nx, ny = f.ny, plane = nx * ny
        func center(_ i: Int) -> SIMD3<Float> {
            let k = i / plane, r = i % plane
            return f.origin + SIMD3<Float>(Float(r % nx) + 0.5, Float(r / nx) + 0.5, Float(k) + 0.5) * f.spacing
        }
        // the load enters at the printed voxels nearest each load point — never in the air beside it
        var dist = [Float](repeating: .infinity, count: n)
        var heap = MinHeap()
        for s in seeds {
            var best = Float.infinity
            for i in 0..<n where f.values[i] > 0 { best = min(best, simd_distance(center(i), s)) }
            guard best.isFinite else { continue }
            let reach = best + 1.5 * f.spacing
            for i in 0..<n where f.values[i] > 0 && simd_distance(center(i), s) <= reach && dist[i] > 0 {
                dist[i] = 0; heap.push(0, i)
            }
        }
        // through the printed voxels only; quicker where the load is carried
        while let (d, i) = heap.pop() {
            if d > dist[i] { continue }
            let k = i / plane, r = i % plane, j = r / nx, x = r % nx
            for (di, ok) in [(-1, x > 0), (1, x < nx - 1), (-nx, j > 0), (nx, j < ny - 1), (-plane, k > 0), (plane, k < f.nz - 1)] {
                guard ok else { continue }
                let o = i + di
                guard f.values[o] > 0 else { continue }
                let load = (f.values[i] + f.values[o]) / (2 * peak)
                let nd = d + f.spacing / (0.15 + load)
                if nd < dist[o] { dist[o] = nd; heap.push(nd, o) }
            }
        }
        // EVEN PACING: arrival is the voxel's RANK among the reached ones, so the light keeps moving across the whole part
        // (raw times bunch up — the loaded members are reached early and the light would rush, then crawl)
        let reached = dist.filter { $0.isFinite }.sorted()
        guard reached.count > 1 else { return nil }
        func rank(_ d: Float) -> Float {
            var lo = 0, hi = reached.count
            while lo < hi { let m = (lo + hi) / 2; if reached[m] < d { lo = m + 1 } else { hi = m } }
            return Float(lo) / Float(reached.count - 1)
        }
        // each surface vertex reads its own voxel, or the nearest reached one around it (a surface vertex often sits in the
        // air voxel just outside the wall)
        let count = positions.count / 3
        var arrival = [Float](repeating: -1, count: count), strength = [Float](repeating: 0, count: count)
        for v in 0..<count {
            let p = SIMD3<Float>(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2])
            let g = (p - f.origin) / f.spacing
            let ci = Int(g.x.rounded(.down)), cj = Int(g.y.rounded(.down)), ck = Int(g.z.rounded(.down))
            // its own voxel when that is reached material; else the reached voxel nearest to it in space
            var bestD = Float.infinity, bestI = -1
            for dk in -1...1 { for dj in -1...1 { for dx in -1...1 {
                let a = ci + dx, b = cj + dj, c = ck + dk
                guard a >= 0, a < nx, b >= 0, b < ny, c >= 0, c < f.nz else { continue }
                let i = (c * ny + b) * nx + a
                guard dist[i].isFinite else { continue }
                let w = (dx == 0 && dj == 0 && dk == 0) ? -1 : simd_distance(center(i), p)
                if w < bestD { bestD = w; bestI = i }
            } } }
            guard bestI >= 0 else { continue }
            arrival[v] = min(1, rank(dist[bestI]))
            strength[v] = (f.values[bestI] / peak).squareRoot()
        }
        return LoadLightFlow(arrival: arrival, strength: strength)
    }

    /// How lit a point is at `phase` (0 … `sweepEnd`) when the light reaches it at `arrival`: a bright head, then a trail.
    public static func glow(arrival a: Float, phase p: Float) -> Float {
        guard a >= 0 else { return 0 }
        let d = p - a
        let headX = d / headWidth
        let head: Float = abs(headX) < 1 ? (1 - headX * headX) * (1 - headX * headX) : 0
        let trail: Float = d > 0 && d < trailLength ? 0.5 * (1 - d / trailLength) * (1 - d / trailLength) : 0
        return max(head, trail)
    }

    /// The per-flat-vertex colours at `phase` — the dark body, lit where the light is passing. ★ 10-28: with `lightColours`
    /// (the Stress add-on: each vertex's stress colour) the light IS the stress it passes through.
    public func tints(phase p: Float, lightColours: [SIMD4<Float>]? = nil) -> [SIMD4<Float>] {
        let body = SIMD4(Self.body, 1), light = SIMD4(Self.light, 1)
        let lc = lightColours.flatMap { $0.count == arrival.count ? $0 : nil }
        var out = [SIMD4<Float>](repeating: body, count: arrival.count)
        // tight loop over raw buffers: it runs every frame on ~200k vertices
        let lo = p - Self.trailLength, hi = p + Self.headWidth   // lit: just reached (trail) or about to be (head)
        out.withUnsafeMutableBufferPointer { o in
            arrival.withUnsafeBufferPointer { a in
                strength.withUnsafeBufferPointer { st in
                    for v in 0..<a.count {
                        let av = a[v]
                        guard av >= 0, av > lo - 1e-6, av < hi else { continue }   // only the band and its trail are lit
                        let g = min(1, Self.glow(arrival: av, phase: p) * (0.55 + 0.45 * st[v]) * 1.25)
                        if g > 0 { o[v] = body + ((lc?[v] ?? light) - body) * g }
                    }
                }
            }
        }
        return out
    }
}

/// A small binary min-heap of (distance, voxel).
private struct MinHeap {
    private var a: [(Float, Int)] = []
    mutating func push(_ d: Float, _ i: Int) {
        a.append((d, i)); var c = a.count - 1
        while c > 0 { let p = (c - 1) / 2; if a[p].0 <= a[c].0 { break }; a.swapAt(p, c); c = p }
    }
    mutating func pop() -> (Float, Int)? {
        guard let top = a.first else { return nil }
        let last = a.removeLast()
        if !a.isEmpty {
            a[0] = last; var p = 0
            while true {
                let l = 2 * p + 1, r = l + 1; var m = p
                if l < a.count, a[l].0 < a[m].0 { m = l }
                if r < a.count, a[r].0 < a[m].0 { m = r }
                if m == p { break }
                a.swapAt(p, m); p = m
            }
        }
        return top
    }
}

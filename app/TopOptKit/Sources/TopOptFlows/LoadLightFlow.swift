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
    /// RED CONTROL (tests only): the walk's six face neighbours, as it was before notes27.
    nonisolated(unsafe) static var controlSixNeighbours = false
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
        // ★ notes27 (his 11-24: "To ensure the load goes the right way and passes through all the struts"): to all 26 voxels around
        // — a slanted strut's voxels often meet only at an edge or a corner, so the six faces alone left them dark (his v8.1: 126
        // pieces, 0.4 % of his struts' surface never lit; with the 26: 4 pieces, 0.03 %)
        var steps: [(di: Int, dj: Int, dk: Int, len: Float)] = []
        for dk in -1...1 {
            for dj in -1...1 {
                for di in -1...1 {
                    let n2 = di * di + dj * dj + dk * dk
                    if n2 == 0 || (Self.controlSixNeighbours && n2 > 1) { continue }
                    steps.append((di, dj, dk, Float(n2).squareRoot()))
                }
            }
        }
        while let (d, i) = heap.pop() {
            if d > dist[i] { continue }
            let k = i / plane, r = i % plane, j = r / nx, x = r % nx
            for st in steps {
                let a = x + st.di, b = j + st.dj, c = k + st.dk
                guard a >= 0, a < nx, b >= 0, b < ny, c >= 0, c < f.nz else { continue }
                let o = (c * ny + b) * nx + a
                guard f.values[o] > 0 else { continue }
                let load = (f.values[i] + f.values[o]) / (2 * peak)
                let nd = d + st.len * f.spacing / (0.15 + load)
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

// ★ notes26 (C5, his 11-23: "making the Load path animation a bit more clear. I think it needs more colour and light coming out
// of it"). The band above was paint — a warm tint mixed into the surface's albedo, then lit like the clay, so it read as a pale
// stain on a dark part. It is now LIGHT: the viewer EMITS it (added over the shading, strongest at the rim where the wall turns
// away), colours it by how much load flows there (`strength`: a cool blue where little does, white, a hot amber where the most
// does), lets it show through the X-ray body, and spills a HALO of it past the wall (MetalMeshView `halo_vertex`). The sweep —
// head, trail, pacing — is the one above, so the motion is the same and stays clear.
extension LoadLightFlow {
    /// This frame's light for the GPU: per flat vertex a sentinel tint — alpha −2 − s over the dark body, or −3 − s over its stress
    /// colour (`stressColours`, rgb) — where s is how much load flows there (0…0.99), and how lit it is now (`light`, 0…1).
    public func lightFrame(phase p: Float, stressColours: [SIMD4<Float>]? = nil) -> (tints: [SIMD4<Float>], light: [Float]) {
        let sc = stressColours.flatMap { $0.count == arrival.count ? $0 : nil }
        var tints = [SIMD4<Float>](repeating: .zero, count: arrival.count)
        var light = [Float](repeating: 0, count: arrival.count)
        let lo = p - Self.trailLength, hi = p + Self.headWidth
        for v in 0..<arrival.count {
            let s = min(0.99, max(0, strength[v]))
            if let sc { tints[v] = SIMD4(sc[v].x, sc[v].y, sc[v].z, -3 - s) } else { tints[v] = SIMD4(0, 0, 0, -2 - s) }
            let av = arrival[v]
            guard av >= 0, av > lo - 1e-6, av < hi else { continue }
            light[v] = min(1, Self.glow(arrival: av, phase: p) * (0.55 + 0.45 * s) * 1.25)
        }
        return (tints, light)
    }
}

// ★ notes27 (his 11-24 ~00:15, img 75: "here it's COMPLETELY blown out. The colours are there to show the actual stress amount on
// each area ... Make it show the colours of the stress as it passes through the part. The colours need to be clear and easy to
// see, bright enough to be seen - but not blown out"; ~00:30: "It should also start at a low load and creep up to its highest as
// the cloud gets closer to being centred on the strut ... I want to be able to WATCH the load affect the part and all the areas
// that get affected by it"). Load flow shows only over the stress map (ResultsLayers). As the band (the cloud) passes a place,
// that place wears its stress at the share of the load the band has brought there, on the map's own fixed scale: the bottom of
// the scale, faint, at the band's leading edge; its own full stress colour when the band's centre is on it; easing back into the
// trail C made, dimmer. The viewer MIXES the band's colour in (lifted a little, every channel capped under white) — no light is
// added any more, so a dense lattice's overlapping walls can never sum to white; the halo is the max of itself and what is there.
extension LoadLightFlow {
    /// How much of its load the band has brought to a place (0…1): none before the band, rising to all of it as the band's
    /// centre reaches it, easing back into the trail (half at most), none after — `glow`'s head and trail.
    public static func loadShare(arrival a: Float, phase p: Float) -> Float { min(1, max(0, glow(arrival: a, phase: p))) }

    /// This frame for the viewer: per flat vertex the sentinel tint over the stress map (−3 − s; s how much load flows there)
    /// whose colour is the map's at the share of the load the band has brought (`shares`: each place's share of the scale's top at
    /// your load — the still map's), and how far the band has brought it (`light`, 0…1: the viewer shows the colour that strongly).
    public func loadFrame(phase p: Float, shares: [Float]) -> (tints: [SIMD4<Float>], light: [Float]) {
        let ok = shares.count == arrival.count
        let lut = Self.rampLUT, top = Float(lut.count - 1)
        var tints = [SIMD4<Float>](repeating: .zero, count: arrival.count)
        var light = [Float](repeating: 0, count: arrival.count)
        tints.withUnsafeMutableBufferPointer { t in
            light.withUnsafeMutableBufferPointer { l in
                for v in 0..<arrival.count {
                    let g = Self.loadShare(arrival: arrival[v], phase: p)
                    let u = ok ? min(1, max(0, shares[v])) * g : 0
                    let c = lut[Int((u * top).rounded())]
                    t[v] = SIMD4(c.x, c.y, c.z, -3 - min(0.99, max(0, strength[v])))
                    l[v] = g
                }
            }
        }
        return (tints, light)
    }

    /// The map's colours at 256 steps (ResultsModel.stressColor's five stops and interpolation; pinned equal by the tests).
    static let rampLUT: [SIMD3<Float>] = (0..<256).map { i in
        let stops: [SIMD3<Float>] = [SIMD3(28, 60, 170), SIMD3(0, 170, 220), SIMD3(60, 190, 110), SIMD3(250, 220, 60),
                                     SIMD3(255, 70, 50)]
        let x = Float(i) / 255 * 4, k = min(3, Int(x)), t = x - Float(k)
        return (stops[k] + (stops[k + 1] - stops[k]) * t) / 255
    }

    /// The band's colour over a stress colour: lifted a little toward white, then capped under it — the viewer's `load_band`
    /// (MetalMeshView), the same numbers. Brighter than the map, never blown out.
    public static let bandLift: Float = 0.2, bandGain: Float = 1.08, bandCap: Float = 0.92
    public static func bandColour(_ stress: SIMD3<Float>) -> SIMD3<Float> {
        let s = simd_clamp(stress, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return simd_min((s + (SIMD3(repeating: 1) - s) * bandLift) * bandGain, SIMD3(repeating: bandCap))
    }
}

/// ★ notes26 (C5): one frame of Load paths' light for the viewer (`MetalMeshView.loadLight`). Equal by key.
public struct LoadLightFrame: Equatable {
    public var key: Int
    public var tints: [SIMD4<Float>]
    public var light: [Float]
    public init(key: Int, tints: [SIMD4<Float>], light: [Float]) { self.key = key; self.tints = tints; self.light = light }
    public static func == (a: LoadLightFrame, b: LoadLightFrame) -> Bool { a.key == b.key }
}

extension MetalMeshView {
    /// ★ notes26 (C5): Load paths' light, emitted and haloed on the GPU.
    public func loadLight(_ frame: LoadLightFrame?) -> MetalMeshView {
#if canImport(MetalKit)
        var copy = self
        copy.inputs.loadLight = frame
        return copy
#else
        self
#endif
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

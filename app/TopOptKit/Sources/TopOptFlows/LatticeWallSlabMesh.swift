import Foundation
import simd

// ★ THE WALL IN 3D, FOR ONE FACE CARD (his 2026-09-21: "show a 3d render of what the wall
// would look like beneath each face … Use the exact model of the entire selected wall
// (via the face-prism) including its shape, position/angle"). The slab the profile makes
// — between the start and end surfaces — bounded by the face's own outline, in world
// millimetres: the face prism's origin, normal and outline, so the render IS the wall.
// Where the two lines meet there is no slab, and nothing is drawn (his image 6).
public enum LatticeWallSlabMesh {

    /// The slab inside `region`'s prism for `ask` (its range, its profile), or an EMPTY
    /// mesh when the slab has no thickness anywhere.
    public static func build(region: LatticeRegionSpec, ask: LatticeFaceWallThickness,
                             pct: Double = 100) -> ViewerMesh {
        guard region.kind == .face, region.depthMM > 0, !region.outlineLoops.isEmpty else {
            return ViewerMesh(vertices: [], indices: [], faceIDs: [])
        }
        // the answer for this ask alone, whatever the project's mode is
        var spec = LatticeWallThickness(depthBySim: false,
                                        density: ask.profile != nil ? .manualGrade : .manualSingle,
                                        pct: pct)
        spec.faces[region.selectableKey ?? ""] = ask
        var r = region
        if r.selectableKey == nil { r.selectableKey = "" }
        r.thickness = spec
        r.thicknessMap = LatticeWallThicknessBuilder.build(region: r, spec: spec, field: nil,
                                                           referenceMPa: 0, floorMM: 0)
        return build(attached: r)
    }

    /// The slab of a region whose thickness map is ALREADY attached (or nil: the whole
    /// prism) — what the preview draws, as a solid; the lattice-only shadow casts it.
    public static func build(attached r: LatticeRegionSpec) -> ViewerMesh {
        guard r.kind == .face, r.depthMM > 0, !r.outlineLoops.isEmpty else {
            return ViewerMesh(vertices: [], indices: [], faceIDs: [])
        }
        let n = LatticeRegionMask.unit(r.normal)
        guard simd_length(n) > 0.5 else { return ViewerMesh(vertices: [], indices: [], faceIDs: []) }
        let (bu, bv) = LatticeRegionMask.basis(n)
        func world(_ uv: SIMD2<Double>, _ s: Double) -> SIMD3<Double> { r.origin + bu * uv.x + bv * uv.y + n * s }
        func range(_ uv: SIMD2<Double>) -> (Double, Double) { r.slabRange(uv: uv) }
        let eps = 0.01

        var v: [Float] = []
        var idx: [Int32] = []
        func add(_ p: SIMD3<Double>) -> Int32 { v += [Float(p.x), Float(p.y), Float(p.z)]; return Int32(v.count / 3 - 1) }
        func tri(_ a: Int32, _ b: Int32, _ c: Int32) { idx += [a, b, c] }

        // subdivision count: fine enough for a drawn curve to read
        let m = r.thicknessMap
        var k = 1
        if let m, !m.isConstant {
            var longest = 0.0
            for loop in r.outlineLoops { for i in loop.indices {
                longest = max(longest, simd_length(loop[(i + 1) % loop.count] - loop[i]))
            } }
            k = min(32, max(1, Int((longest / (2 * m.h)).rounded(.up))))
        }
        for loop in r.outlineLoops where loop.count >= 3 {
            let ring = LatticeOutlineRibbon.offsetRing(loop, by: r.inPlaneOffsetMM)
            guard ring.count >= 3 else { continue }
            // the two plates, per sub-triangle, skipped where the slab is nothing
            for (a, b, c) in LatticeRegionCap.triangulate(ring) {
                let A = ring[a], B = ring[b], C = ring[c]
                func P(_ i: Int, _ j: Int) -> SIMD2<Double> {
                    A + (B - A) * (Double(i) / Double(k)) + (C - A) * (Double(j) / Double(k))
                }
                for i in 0..<k { for j in 0..<(k - i) {
                    var tris: [[SIMD2<Double>]] = [[P(i, j), P(i + 1, j), P(i, j + 1)]]
                    if i + j + 1 < k { tris.append([P(i + 1, j), P(i + 1, j + 1), P(i, j + 1)]) }
                    for t in tris {
                        let rs = t.map(range)
                        guard rs.contains(where: { $0.1 - $0.0 > eps }) else { continue }
                        let f = t.enumerated().map { add(world($0.element, rs[$0.offset].0)) }
                        let g = t.enumerated().map { add(world($0.element, rs[$0.offset].1)) }
                        tri(f[0], f[2], f[1])         // the start surface, facing out of the part
                        tri(g[0], g[1], g[2])         // the end surface, facing in
                    }
                } }
            }
            // the sides along the outline, subdivided the same way
            for e in ring.indices {
                let A = ring[e], B = ring[(e + 1) % ring.count]
                var prev: (SIMD2<Double>, Double, Double)? = nil
                for i in 0...k {
                    let uv = A + (B - A) * (Double(i) / Double(k))
                    let (s0, s1) = range(uv)
                    if let (puv, ps0, ps1) = prev, (s1 - s0 > eps || ps1 - ps0 > eps) {
                        let a0 = add(world(puv, ps0)), a1 = add(world(puv, ps1))
                        let b0 = add(world(uv, s0)), b1 = add(world(uv, s1))
                        tri(a0, a1, b1); tri(a0, b1, b0)
                    }
                    prev = (uv, s0, s1)
                }
            }
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: [Int32](repeating: 1, count: idx.count / 3))
    }

    /// The whole prism's twelve-ish edges as line segments (x0 y0 z0 x1 y1 z1 …): the
    /// outline at the face and at the declared depth, joined at the corners.
    public static func prismLines(region r: LatticeRegionSpec) -> [Float] {
        let n = LatticeRegionMask.unit(r.normal)
        guard simd_length(n) > 0.5, r.depthMM > 0 else { return [] }
        let (bu, bv) = LatticeRegionMask.basis(n)
        func world(_ uv: SIMD2<Double>, _ s: Double) -> SIMD3<Float> {
            SIMD3<Float>(r.origin + bu * uv.x + bv * uv.y + n * s)
        }
        var out: [Float] = []
        func seg(_ a: SIMD3<Float>, _ b: SIMD3<Float>) { out += [a.x, a.y, a.z, b.x, b.y, b.z] }
        for loop in r.outlineLoops where loop.count >= 2 {
            for i in loop.indices {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                seg(world(a, 0), world(b, 0))
                seg(world(a, r.depthMM), world(b, r.depthMM))
                seg(world(a, 0), world(a, r.depthMM))
            }
        }
        return out
    }

    // ── the flat-box form, kept for the tests and any wall without an outline ─────

    /// The slab as a plain box: x across the width, y through the thickness, z along
    /// the height. Empty where the slab has no thickness.
    public static func build(widthMM: Double, heightMM: Double, thickMM: Double,
                             ask: LatticeFaceWallThickness, pct: Double = 100,
                             stations: Int = 64) -> ViewerMesh {
        let n = max(2, stations)
        let range = (start: max(0, ask.startMM), end: min(thickMM, ask.endMM ?? thickMM))
        func depths(at x: Double) -> (Double, Double) {
            if let p = ask.profile {
                var s = min(max(p.y(at: x, side: .start) * thickMM, range.start), range.end)
                var e = min(max(p.y(at: x, side: .end) * thickMM, range.start), range.end)
                if e < s { swap(&s, &e) }
                return (s, e)
            }
            let e = range.start + max(0, range.end - range.start) * min(1, max(0, pct / 100))
            return (range.start, e)
        }
        let eps = 0.01
        var v: [Float] = []
        var idx: [Int32] = []
        func add(_ p: SIMD3<Double>) -> Int32 { v += [Float(p.x), Float(p.y), Float(p.z)]; return Int32(v.count / 3 - 1) }
        func quad(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32) { idx += [a, b, c, a, c, d] }
        var prev: (a: Int32, b: Int32, c: Int32, d: Int32, t: Double)? = nil
        var openedRun = false
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            let (s, e) = depths(at: x)
            let X = x * widthMM
            let a = add(SIMD3(X, s, 0)), b = add(SIMD3(X, e, 0))
            let c = add(SIMD3(X, s, heightMM)), d = add(SIMD3(X, e, heightMM))
            let t = e - s
            if let p = prev, t > eps || p.t > eps {
                if !openedRun { quad(p.a, p.b, p.d, p.c); openedRun = true }   // the run's first end
                quad(p.a, a, b, p.b)          // front (z = 0)
                quad(p.c, p.d, d, c)          // back (z = height)
                quad(p.a, p.c, c, a)          // the start surface
                quad(p.b, b, d, p.d)          // the end surface
                if t <= eps { quad(a, c, d, b); openedRun = false }             // the run's last end
            }
            prev = (a, b, c, d, t)
        }
        if let p = prev, openedRun { quad(p.a, p.c, p.d, p.b) }
        if idx.isEmpty { return ViewerMesh(vertices: [], indices: [], faceIDs: []) }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: [Int32](repeating: 1, count: idx.count / 3))
    }

    /// The wall's box as line segments (x0 y0 z0 x1 y1 z1 …), for `extraLines`.
    public static func boxLines(widthMM: Double, heightMM: Double, thickMM: Double) -> [Float] {
        let c: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(Float(widthMM), 0, 0), SIMD3(Float(widthMM), Float(thickMM), 0), SIMD3(0, Float(thickMM), 0),
            SIMD3(0, 0, Float(heightMM)), SIMD3(Float(widthMM), 0, Float(heightMM)),
            SIMD3(Float(widthMM), Float(thickMM), Float(heightMM)), SIMD3(0, Float(thickMM), Float(heightMM)),
        ]
        let e = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        var out: [Float] = []
        for (a, b) in e { out += [c[a].x, c[a].y, c[a].z, c[b].x, c[b].y, c[b].z] }
        return out
    }
}

import Foundation
import simd

// ★ THE WALL IN 3D, FOR ONE FACE CARD (his 2026-09-21: "show a 3d render of what the wall
// would look like beneath each face … Use the exact model of the entire selected wall
// (via the face-prism) including its shape, position/angle"), AS STEPS (his D1: the
// drawing is cell-based, and the preview draws the steps). The slab is the union of one
// box per raster cell — the face outline clipped to the cell, extruded from the surface
// to that cell's end — with risers where neighbouring cells differ and walls along the
// outline. Nothing is interpolated between cells (core note 3). Where a cell's end is
// zero there is no slab, and nothing is drawn.
public enum LatticeWallSlabMesh {

    /// The slab inside `region`'s prism for `ask`, or an EMPTY mesh when it has no depth anywhere.
    public static func build(region: LatticeRegionSpec, ask: LatticeFaceWallThickness,
                             pct: Double = 100, depthSteps: [Double]? = nil) -> ViewerMesh {
        guard region.kind == .face, region.depthMM > 0, !region.outlineLoops.isEmpty else {
            return ViewerMesh(vertices: [], indices: [], faceIDs: [])
        }
        var spec = LatticeWallThickness(depthBySim: false,
                                        density: ask.profile != nil ? .manualGrade : .manualSingle,
                                        pct: pct)
        spec.faces[region.selectableKey ?? ""] = ask
        var r = region
        if r.selectableKey == nil { r.selectableKey = "" }
        r.thickness = spec
        r.thicknessMap = LatticeWallThicknessBuilder.build(region: r, spec: spec, field: nil,
                                                           referenceMPa: 0, floorMM: 0, depthSteps: depthSteps)
        return build(attached: r)
    }

    /// The slab of a region whose thickness map is ALREADY attached (nil: the whole prism).
    public static func build(attached r: LatticeRegionSpec) -> ViewerMesh {
        guard r.kind == .face, r.depthMM > 0, !r.outlineLoops.isEmpty else {
            return ViewerMesh(vertices: [], indices: [], faceIDs: [])
        }
        let n = LatticeRegionMask.unit(r.normal)
        guard simd_length(n) > 0.5 else { return ViewerMesh(vertices: [], indices: [], faceIDs: []) }
        let (bu, bv) = LatticeRegionMask.basis(n)
        func world(_ uv: SIMD2<Double>, _ s: Double) -> SIMD3<Double> { r.origin + bu * uv.x + bv * uv.y + n * s }
        var builder = Builder()
        // the rings, with their seam edges (an offset ring keeps the loop's edge indices)
        let ringsWithSeams: [(ring: [SIMD2<Double>], seams: [Bool])] = r.outlineLoops.enumerated()
            .filter { $0.element.count >= 3 }
            .map { e in
                let sm = e.offset < r.outlineSeams.count ? r.outlineSeams[e.offset] : []
                return (LatticeOutlineRibbon.offsetRing(e.element, by: -r.inPlaneOffsetMM, seams: sm), sm)
            }
            .filter { $0.ring.count >= 3 }
        let rings = ringsWithSeams.map { $0.ring }
        guard !rings.isEmpty else { return ViewerMesh(vertices: [], indices: [], faceIDs: []) }
        // ★ NO WALL ALONG A SEAM (review 2026-09-22 #22): an edge of a clipped cell polygon
        // that lies on a seam segment of its ring is where the neighbouring prism continues
        let seamSegments: [(SIMD2<Double>, SIMD2<Double>)] = ringsWithSeams.flatMap { rs in
            rs.ring.indices.compactMap { i in
                i < rs.seams.count && rs.seams[i] ? (rs.ring[i], rs.ring[(i + 1) % rs.ring.count]) : nil
            }
        }
        func onSeam(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            for (p, q) in seamSegments {
                let d = q - p, l2 = simd_dot(d, d)
                guard l2 > 1e-12 else { continue }
                func on(_ x: SIMD2<Double>) -> Bool {
                    let t = simd_dot(x - p, d) / l2
                    guard t >= -1e-6, t <= 1 + 1e-6 else { return false }
                    return simd_length(x - (p + d * t)) <= 1e-4
                }
                if on(a), on(b) { return true }
            }
            return false
        }

        if let m = r.thicknessMap, !m.isConstant {
            // one box per raster cell; the cell (i, j) covers [origin + (i-½)h, origin + (i+½)h]
            func band(_ i: Int, _ j: Int) -> (Double, Double) {
                guard i >= 0, j >= 0, i < m.nu, j < m.nv else { return (0, 0) }
                let e = Double(m.ends[j * m.nu + i]), s = Double(m.starts[j * m.nu + i])
                guard e.isFinite, s.isFinite else { return (0, 0) }
                let s1 = min(r.depthMM, max(0, s)), e1 = min(r.depthMM, max(s1, e))
                return (s1, e1)
            }
            for j in 0..<m.nv { for i in 0..<m.nu {
                let (s0, e0) = band(i, j)
                guard e0 - s0 > 0.01 else { continue }
                let lo = m.origin + SIMD2(Double(i) - 0.5, Double(j) - 0.5) * m.h
                let hi = lo + SIMD2(m.h, m.h)
                for ring in rings {
                    let poly = clip(ring, lo: lo, hi: hi)
                    guard poly.count >= 3 else { continue }
                    builder.extrude(poly, from: s0, to: e0, world: world, neighbour: { a, b in
                        if onSeam(a, b) { return (s0, e0) }      // the next prism continues here
                        // an edge on a cell boundary faces the neighbour there; the riser is
                        // the difference; an outline edge faces nothing and gets the full wall
                        let mid = 0.5 * (a + b)
                        var ni = i, nj = j
                        if abs(a.x - lo.x) < 1e-9, abs(b.x - lo.x) < 1e-9 { ni = i - 1 }
                        else if abs(a.x - hi.x) < 1e-9, abs(b.x - hi.x) < 1e-9 { ni = i + 1 }
                        else if abs(a.y - lo.y) < 1e-9, abs(b.y - lo.y) < 1e-9 { nj = j - 1 }
                        else if abs(a.y - hi.y) < 1e-9, abs(b.y - hi.y) < 1e-9 { nj = j + 1 }
                        else { return nil }
                        // the neighbour must also hold the outline at that edge, else it is open
                        let neighbourHasOutline = rings.contains { Self.inside(mid + SIMD2(Double(ni - i), Double(nj - j)) * 1e-6, $0) }
                        guard neighbourHasOutline else { return nil }
                        let nb = band(ni, nj)
                        return nb.1 - nb.0 > 0.01 ? nb : nil
                    })
                }
            } }
        } else {
            let (s0, e0) = r.slabRange(uv: rings[0][0])
            guard e0 - s0 > 0.01 else { return ViewerMesh(vertices: [], indices: [], faceIDs: []) }
            for ring in rings { builder.extrude(ring, from: s0, to: e0, world: world, neighbour: { a, b in onSeam(a, b) ? (s0, e0) : nil }) }
        }
        return builder.mesh
    }

    /// The whole prism's edges as line segments (x0 y0 z0 x1 y1 z1 …).
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
    /// the height — one box per drawn column, risers between. Empty where there is no depth.
    public static func build(widthMM: Double, heightMM: Double, thickMM: Double,
                             ask: LatticeFaceWallThickness, pct: Double = 100,
                             stations: Int = 64) -> ViewerMesh {
        // curves are sampled at `stations` columns; steps at their own
        let columns = ask.profile.map { $0.isCurves ? max(2, stations) : max(1, $0.columns) } ?? 1
        let a0 = max(0, ask.startMM), a1 = min(thickMM, ask.endMM ?? thickMM)
        func band(_ c: Int) -> (Double, Double) {
            if let p = ask.profile {
                let x = (Double(c) + 0.5) / Double(columns)
                var s = min(max(p.start(at: x) * thickMM, a0), a1), e = min(max(p.end(at: x) * thickMM, a0), a1)
                if e < s { swap(&s, &e) }
                return (s, e)
            }
            return (a0, a0 + max(0, a1 - a0) * min(1, max(0, pct / 100)))
        }
        var b = Builder()
        func world(_ uv: SIMD2<Double>, _ s: Double) -> SIMD3<Double> { SIMD3(uv.x, s, uv.y) }
        let cw = widthMM / Double(columns)
        for c in 0..<columns {
            let (s0, e0) = band(c)
            guard e0 - s0 > 0.01 else { continue }
            let x0 = Double(c) * cw, x1 = x0 + cw
            let poly = [SIMD2(x0, 0), SIMD2(x1, 0), SIMD2(x1, heightMM), SIMD2(x0, heightMM)]
            b.extrude(poly, from: s0, to: e0, world: world, neighbour: { a, bb in
                var n: (Double, Double)? = nil
                if abs(a.x - x0) < 1e-9, abs(bb.x - x0) < 1e-9, c > 0 { n = band(c - 1) }
                if abs(a.x - x1) < 1e-9, abs(bb.x - x1) < 1e-9, c + 1 < columns { n = band(c + 1) }
                if let n, n.1 - n.0 > 0.01 { return n }
                return nil
            })
        }
        return b.mesh
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

    // ── helpers ────────────────────────────────────────────────────────────────

    /// Even-odd point in polygon.
    static func inside(_ p: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
        var c = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    /// Sutherland–Hodgman: the polygon inside the axis-aligned box [lo, hi].
    static func clip(_ poly: [SIMD2<Double>], lo: SIMD2<Double>, hi: SIMD2<Double>) -> [SIMD2<Double>] {
        var out = poly
        func pass(_ inside: (SIMD2<Double>) -> Bool, _ cross: (SIMD2<Double>, SIMD2<Double>) -> SIMD2<Double>) {
            guard !out.isEmpty else { return }
            var next: [SIMD2<Double>] = []
            for k in out.indices {
                let a = out[k], b = out[(k + 1) % out.count]
                let ia = inside(a), ib = inside(b)
                if ia { next.append(a) }
                if ia != ib { next.append(cross(a, b)) }
            }
            out = next
        }
        func at(_ a: SIMD2<Double>, _ b: SIMD2<Double>, x: Double) -> SIMD2<Double> {
            let t = (x - a.x) / (b.x - a.x); return SIMD2(x, a.y + (b.y - a.y) * t)
        }
        func at(_ a: SIMD2<Double>, _ b: SIMD2<Double>, y: Double) -> SIMD2<Double> {
            let t = (y - a.y) / (b.y - a.y); return SIMD2(a.x + (b.x - a.x) * t, y)
        }
        pass({ $0.x >= lo.x }, { at($0, $1, x: lo.x) })
        pass({ $0.x <= hi.x }, { at($0, $1, x: hi.x) })
        pass({ $0.y >= lo.y }, { at($0, $1, y: lo.y) })
        pass({ $0.y <= hi.y }, { at($0, $1, y: hi.y) })
        // drop degenerate repeats
        var clean: [SIMD2<Double>] = []
        for q in out where clean.last.map({ simd_length($0 - q) > 1e-9 }) ?? true { clean.append(q) }
        if clean.count > 1, simd_length(clean[0] - clean[clean.count - 1]) <= 1e-9 { clean.removeLast() }
        return clean
    }

    struct Builder {
        var v: [Float] = []
        var idx: [Int32] = []
        mutating func add(_ p: SIMD3<Double>) -> Int32 { v += [Float(p.x), Float(p.y), Float(p.z)]; return Int32(v.count / 3 - 1) }
        mutating func tri(_ a: Int32, _ b: Int32, _ c: Int32) { idx += [a, b, c] }
        /// One box: `poly` (in the face plane) from s = `from` to s = `to`; the side along
        /// each edge covers whatever of [from, to] the neighbour's band (`neighbour`, nil ⇒
        /// nothing there) does not — the risers between steps, the whole wall at the outline.
        mutating func extrude(_ poly: [SIMD2<Double>], from: Double, to: Double,
                              world: (SIMD2<Double>, Double) -> SIMD3<Double>,
                              neighbour: (SIMD2<Double>, SIMD2<Double>) -> (Double, Double)?) {
            guard poly.count >= 3, to - from > 1e-9 else { return }
            let top = poly.map { add(world($0, from)) }, bottom = poly.map { add(world($0, to)) }
            for (a, b, c) in LatticeRegionCap.triangulate(poly) {
                tri(top[a], top[c], top[b])          // the start surface, facing out of the part
                tri(bottom[a], bottom[b], bottom[c]) // the end surface, facing in
            }
            for k in poly.indices {
                let a = poly[k], b = poly[(k + 1) % poly.count]
                var pieces: [(Double, Double)] = [(from, to)]
                if let n = neighbour(a, b) {
                    pieces = []
                    if n.0 > from { pieces.append((from, min(to, n.0))) }
                    if n.1 < to { pieces.append((max(from, n.1), to)) }
                }
                for (s0, s1) in pieces where s1 - s0 > 1e-9 {
                    let a0 = add(world(a, s0)), a1 = add(world(a, s1))
                    let b0 = add(world(b, s0)), b1 = add(world(b, s1))
                    tri(a0, a1, b1); tri(a0, b1, b0)
                }
            }
        }
        var mesh: ViewerMesh {
            idx.isEmpty ? ViewerMesh(vertices: [], indices: [], faceIDs: [])
                        : ViewerMesh(vertices: v, indices: idx, faceIDs: [Int32](repeating: 1, count: idx.count / 3))
        }
    }
}

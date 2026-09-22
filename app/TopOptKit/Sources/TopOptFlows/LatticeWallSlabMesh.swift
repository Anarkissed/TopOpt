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
        let rings = r.outlineLoops.filter { $0.count >= 3 }
            .map { LatticeOutlineRibbon.offsetRing($0, by: r.inPlaneOffsetMM) }
            .filter { $0.count >= 3 }
        guard !rings.isEmpty else { return ViewerMesh(vertices: [], indices: [], faceIDs: []) }

        if let m = r.thicknessMap, !m.isConstant {
            // one box per raster cell; the cell (i, j) covers [origin + (i-½)h, origin + (i+½)h]
            func end(_ i: Int, _ j: Int) -> Double {
                guard i >= 0, j >= 0, i < m.nu, j < m.nv else { return 0 }
                let e = Double(m.ends[j * m.nu + i]), s = Double(m.starts[j * m.nu + i])
                return e.isFinite && s.isFinite ? max(0, min(r.depthMM, e) - max(0, s)) : 0
            }
            for j in 0..<m.nv { for i in 0..<m.nu {
                let e = end(i, j)
                guard e > 0.01 else { continue }
                let lo = m.origin + SIMD2(Double(i) - 0.5, Double(j) - 0.5) * m.h
                let hi = lo + SIMD2(m.h, m.h)
                for ring in rings {
                    let poly = clip(ring, lo: lo, hi: hi)
                    guard poly.count >= 3 else { continue }
                    builder.extrude(poly, end: e, world: world, riser: { a, b in
                        // an edge on a cell boundary faces the neighbour there; the riser is
                        // the difference; an outline edge faces nothing and gets the full wall
                        let mid = 0.5 * (a + b)
                        var ni = i, nj = j
                        if abs(a.x - lo.x) < 1e-9, abs(b.x - lo.x) < 1e-9 { ni = i - 1 }
                        else if abs(a.x - hi.x) < 1e-9, abs(b.x - hi.x) < 1e-9 { ni = i + 1 }
                        else if abs(a.y - lo.y) < 1e-9, abs(b.y - lo.y) < 1e-9 { nj = j - 1 }
                        else if abs(a.y - hi.y) < 1e-9, abs(b.y - hi.y) < 1e-9 { nj = j + 1 }
                        else { return 0 }
                        // the neighbour must also hold the outline at that edge, else it is open
                        let neighbourHasOutline = rings.contains { Self.inside(mid + SIMD2(Double(ni - i), Double(nj - j)) * 1e-6, $0) }
                        return neighbourHasOutline ? end(ni, nj) : 0
                    })
                }
            } }
        } else {
            let (s0, e0) = r.slabRange(uv: rings[0][0])
            let e = max(0, e0 - s0)
            guard e > 0.01 else { return ViewerMesh(vertices: [], indices: [], faceIDs: []) }
            for ring in rings { builder.extrude(ring, end: e, world: world, riser: { _, _ in 0 }) }
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
        let columns = ask.profile.map { max(1, $0.columns) } ?? 1
        let allowed = min(thickMM, ask.endMM ?? thickMM)
        func depth(_ c: Int) -> Double {
            if let p = ask.profile { return min(allowed, p.ends[min(c, p.ends.count - 1)] * thickMM) }
            return max(0, allowed) * min(1, max(0, pct / 100))
        }
        var b = Builder()
        func world(_ uv: SIMD2<Double>, _ s: Double) -> SIMD3<Double> { SIMD3(uv.x, s, uv.y) }
        let cw = widthMM / Double(columns)
        for c in 0..<columns {
            let e = depth(c)
            guard e > 0.01 else { continue }
            let x0 = Double(c) * cw, x1 = x0 + cw
            let poly = [SIMD2(x0, 0), SIMD2(x1, 0), SIMD2(x1, heightMM), SIMD2(x0, heightMM)]
            b.extrude(poly, end: e, world: world, riser: { a, bb in
                if abs(a.x - x0) < 1e-9, abs(bb.x - x0) < 1e-9 { return c > 0 ? depth(c - 1) : 0 }
                if abs(a.x - x1) < 1e-9, abs(bb.x - x1) < 1e-9 { return c + 1 < columns ? depth(c + 1) : 0 }
                return 0
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
        /// One box: `poly` (in the face plane) from s = 0 to s = end; the side along each
        /// edge runs from the neighbour's end (`riser`) up to this end — 0 ⇒ the whole wall.
        mutating func extrude(_ poly: [SIMD2<Double>], end: Double,
                              world: (SIMD2<Double>, Double) -> SIMD3<Double>,
                              riser: (SIMD2<Double>, SIMD2<Double>) -> Double) {
            guard poly.count >= 3, end > 0 else { return }
            // the plates
            let top = poly.map { add(world($0, 0)) }, bottom = poly.map { add(world($0, end)) }
            for (a, b, c) in LatticeRegionCap.triangulate(poly) {
                tri(top[a], top[c], top[b])          // the surface, facing out of the part
                tri(bottom[a], bottom[b], bottom[c]) // the end, facing in
            }
            // the sides
            for k in poly.indices {
                let a = poly[k], b = poly[(k + 1) % poly.count]
                let from = min(end, max(0, riser(a, b)))
                guard end - from > 1e-9 else { continue }
                let a0 = add(world(a, from)), a1 = add(world(a, end))
                let b0 = add(world(b, from)), b1 = add(world(b, end))
                tri(a0, a1, b1); tri(a0, b1, b0)
            }
        }
        var mesh: ViewerMesh {
            idx.isEmpty ? ViewerMesh(vertices: [], indices: [], faceIDs: [])
                        : ViewerMesh(vertices: v, indices: idx, faceIDs: [Int32](repeating: 1, count: idx.count / 3))
        }
    }
}

// FlexibleLatticeSections — the part of a face inside a face-prism (task 2026-09-29-flexible-screens, round 7 batch M2;
// his img3 words of 2026-10-14: "only the places with face-prisms get latticed. In this example, when I tapped the top, it
// selected the model's top face, rather than one of the lattice's top faces." and "the pressed curves continue right
// through the entire model rather than the lattice section. It must only be the lattice section - regardless of what shape
// it is."; the reviewer's ruling 3: the sections are FLEXIBLE-ONLY sectors carried in the job).
//
// ★ WHAT A FACE-PRISM IS (Selections' Lattice row): a face-kind include spec — the slab origin + s·normal, s ∈ [0, depth]
// (the normal INTO the part), clipped to `wireOutlineLoops` in core's (u, w) frame (`LatticeRegionMask.basis`). That polygon
// is exactly the one core reads: the expand and the seam flare are already geometry. So a prism is a set of HALF-SPACES:
// s ≥ 0, s ≤ depth, and one plane per outline edge (through the edge, containing the normal, facing into the polygon) —
// exact when the outline is ONE convex loop.
// ★ WHICH FACES ARE CUT (D1, D4). Per ROOT — a whole face, or his own Surface leaf sector (FlexibleMeet's partition over
// the project's regions) — and per prism:
//   * the root lies wholly inside a prism (its area inside the prism with every plane relaxed outward by 1e-4 mm is the
//     whole area): it is WHOLE — its own id, its bytes unchanged (a face lying ON a prism's plane — the bottom at s = depth,
//     Face 3 on its own outline plane — counts as inside);
//   * no area inside: nothing;
//   * partly inside a planar, convex, single-outline prism: a SECTION, carved on a scratch copy of the regions with the
//     Surface tool's own calls (splitManual / splitDetached), only along the planes that really cross it;
//   * partly inside a curved (several facets under one key), bolt, holed, non-convex or hand-placed prism: kept WHOLE with
//     one line, "Curved lattice here · not yet" (a core column-mask press would lift it — #361's optional queue).
// Prisms are taken in emission order; where two overlap, a later one takes the free piece holding most of its area (I2's
// rule). The unlatticed rest of a face is NOT declared. Solid (exclude) prisms are not carved out (D5).

import Foundation
import simd

public enum FlexibleLatticeSections {
    /// ★ RED CONTROL: no section is ever cut — a face partly inside a face-prism is pressed WHOLE (today's).
    nonisolated(unsafe) static var controlWholeFace = false
    /// ★ RED CONTROL: every face a face-prism meets is cut, even one wholly inside it (its id and bytes move).
    nonisolated(unsafe) static var controlAlwaysCut = false
    /// ★ RED CONTROL: a section's key is its GEOMETRY (depth and outline), so a depth change re-keys it.
    nonisolated(unsafe) static var controlFingerprintIDs = false

    /// How far a plane is relaxed for "on the plane counts as inside" (mm).
    static let tolMM = 1e-4

    /// One face-prism as the sections read it.
    struct Prism {
        enum Shape { case planar, other, bolt }
        let index: Int
        /// Its role key in a section's key: the selectable key and the facet ("f:<group>:<face>#0").
        let key: String
        let shape: Shape
        /// The exact half-spaces (planar), or those of the outline's convex hull (other).
        let cuts: [RegionCut]
        /// The half-spaces relaxed outward by `tolMM`.
        let relaxed: [RegionCut]
        let lo: SIMD3<Double>, hi: SIMD3<Double>
        /// The face it was set on (its name in a section's line), or nil (a hand-placed primitive).
        let face: Int?
        // (other) the outline, for "every point of the root inside the polygon"
        let origin: SIMD3<Double>, normal: SIMD3<Double>, u: SIMD3<Double>, w: SIMD3<Double>, depth: Double
        let loops: [[SIMD2<Double>]]
        // (bolt)
        let axisPoint: SIMD3<Double>, axisDir: SIMD3<Double>, radius: Double, halfLength: Double
    }

    /// The include specs as prisms (emission order).
    static func prisms(_ specs: [LatticeRegionSpec]) -> [Prism] {
        var perKey: [String: Int] = [:]
        for s in specs where s.role == .include { if let k = s.selectableKey { perKey[k, default: 0] += 1 } }
        var facet: [String: Int] = [:]
        var out: [Prism] = []
        for (i, s) in specs.enumerated() where s.role == .include {
            let base = s.selectableKey ?? "x\(i)"
            let k = facet[base, default: 0]
            facet[base] = k + 1
            var key = "\(base)#\(k)"
            if controlFingerprintIDs { key += String(format: "@%.4f", s.depthMM) }
            switch s.kind {
            case .bolt:
                let d = simd_length(s.axisDir) > 1e-12 ? simd_normalize(s.axisDir) : SIMD3(0, 0, 1)
                let a = s.axisPoint - d * s.halfLengthMM, b = s.axisPoint + d * s.halfLengthMM
                let r = SIMD3(repeating: s.radiusMM)
                out.append(Prism(index: i, key: key, shape: .bolt, cuts: [], relaxed: [],
                                 lo: simd_min(a, b) - r, hi: simd_max(a, b) + r, face: s.rawFaceID.map { Int($0) },
                                 origin: .zero, normal: .zero, u: .zero, w: .zero, depth: 0, loops: [],
                                 axisPoint: s.axisPoint, axisDir: d, radius: s.radiusMM, halfLength: s.halfLengthMM))
            case .face:
                let n = LatticeRegionMask.unit(s.normal)
                guard simd_length(n) > 0.5, s.depthMM > 0 else { continue }
                let (u, w) = LatticeRegionMask.basis(n)
                var loops = s.wireOutlineLoops
                if loops.isEmpty {
                    let hu = s.halfUMM, hw = s.halfWMM
                    loops = [[SIMD2(-hu, -hw), SIMD2(hu, -hw), SIMD2(hu, hw), SIMD2(-hu, hw)]]
                }
                let single = loops.count == 1
                let convexLoop = single && convex(loops[0])
                let curved = (s.selectableKey.map { perKey[$0, default: 0] } ?? 1) > 1
                let manual = s.rawFaceID == nil
                let planar = convexLoop && !curved && !manual
                let ring = planar ? loops[0] : hull(loops.flatMap { $0 })
                guard ring.count >= 3 else { continue }
                let cuts = halfSpaces(origin: s.origin, normal: n, u: u, w: w, depth: s.depthMM, ring: ring)
                var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
                for q in ring {
                    let p = s.origin + u * q.x + w * q.y
                    for e in [p, p + n * s.depthMM] { lo = simd_min(lo, e); hi = simd_max(hi, e) }
                }
                out.append(Prism(index: i, key: key, shape: planar ? .planar : .other, cuts: cuts,
                                 relaxed: cuts.map(relax), lo: lo, hi: hi, face: s.rawFaceID.map { Int($0) },
                                 origin: s.origin, normal: n, u: u, w: w, depth: s.depthMM, loops: loops,
                                 axisPoint: .zero, axisDir: .zero, radius: 0, halfLength: 0))
            }
        }
        return out
    }

    /// s ≥ 0, s ≤ depth, and one plane per edge of `ring` (in (u, w)), each kept where dot(p − point, normal) ≥ 0.
    static func halfSpaces(origin: SIMD3<Double>, normal n: SIMD3<Double>, u: SIMD3<Double>, w: SIMD3<Double>,
                           depth: Double, ring: [SIMD2<Double>]) -> [RegionCut] {
        var out = [RegionCut(point: origin, normal: n), RegionCut(point: origin + n * depth, normal: -n)]
        let ccw = signedArea(ring) >= 0
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let d = b - a
            guard simd_length(d) > 1e-9 else { continue }
            // the left normal of a counter-clockwise edge points into the polygon
            var m2 = SIMD2(-d.y, d.x)
            if !ccw { m2 = -m2 }
            let m3 = u * m2.x + w * m2.y
            out.append(RegionCut(point: origin + u * a.x + w * a.y, normal: simd_normalize(m3)))
        }
        return out
    }

    /// The plane moved outward by `tolMM` (a point ON it — within float noise — counts as inside).
    static func relax(_ c: RegionCut) -> RegionCut {
        let n = simd_normalize(c.normal)
        return RegionCut(point: c.point - n * tolMM, normal: c.normal)
    }

    /// The part of a piece beyond plane `c`, moved inward by `tolMM` (what is really outside it).
    static func beyond(_ c: RegionCut) -> RegionCut {
        let n = simd_normalize(c.normal)
        return RegionCut(point: c.point - n * tolMM, normal: -c.normal)
    }

    static func signedArea(_ r: [SIMD2<Double>]) -> Double {
        var a = 0.0
        for i in r.indices { let p = r[i], q = r[(i + 1) % r.count]; a += p.x * q.y - q.x * p.y }
        return a / 2
    }

    /// One loop is convex (every turn the same way, collinear points allowed).
    static func convex(_ r: [SIMD2<Double>]) -> Bool {
        guard r.count >= 3 else { return false }
        var sign = 0.0
        let scale = r.map { simd_length($0) }.max() ?? 1
        for i in r.indices {
            let a = r[i], b = r[(i + 1) % r.count], c = r[(i + 2) % r.count]
            let z = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(z) > 1e-9 * max(1, scale * scale) else { continue }
            if sign == 0 { sign = z } else if sign * z < 0 { return false }
        }
        return sign != 0
    }

    /// The convex hull (Andrew's monotone chain), counter-clockwise.
    static func hull(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return p }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
        for q in p { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        for q in p.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Point in polygon (even–odd over every loop: a hole is outside), with `tol` mm of grace on an edge.
    static func inOutline(_ q: SIMD2<Double>, _ loops: [[SIMD2<Double>]], tol: Double = tolMM) -> Bool {
        var inside = false
        for l in loops {
            for i in l.indices {
                let a = l[i], b = l[(i + 1) % l.count]
                // on the edge
                let d = b - a, len2 = simd_length_squared(d)
                if len2 > 0 {
                    let t = max(0, min(1, simd_dot(q - a, d) / len2))
                    if simd_distance(a + d * t, q) <= tol { return true }
                }
                if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
        }
        return inside
    }

    /// What a prism does to a root.
    enum Meeting { case none, whole, partial, notYet }

    /// How prism `pr` meets the root whose surface is `polys` (area `area`, box lo…hi).
    static func meeting(_ pr: Prism, polys: [[SIMD3<Double>]], area: Double, eps: Double,
                        lo: SIMD3<Double>, hi: SIMD3<Double>) -> Meeting {
        guard all(pr.lo .<= hi + tolMM), all(lo .<= pr.hi + tolMM) else { return .none }
        switch pr.shape {
        case .bolt:
            var inN = 0, outN = 0
            for poly in polys {
                let c = poly.reduce(SIMD3<Double>.zero, +) / Double(max(1, poly.count))
                for p in poly + [c] {
                    let v = p - pr.axisPoint, t = simd_dot(v, pr.axisDir)
                    let r = simd_length(v - pr.axisDir * t)
                    if abs(t) <= pr.halfLength + tolMM && r <= pr.radius + tolMM { inN += 1 } else { outN += 1 }
                }
            }
            return inN == 0 ? .none : outN == 0 ? .whole : .notYet
        case .planar, .other:
            let a = polys.reduce(0) { $0 + FlexibleMeet.area(FlexibleMeet.clipPolygon($1, pr.relaxed)) }
            guard a > eps else { return .none }
            if a >= (1 - 1e-6) * area {
                if pr.shape == .planar { return controlAlwaysCut ? .partial : .whole }
                // the hull holds it: every point of the root inside the real outline, too
                let allIn = polys.allSatisfy { poly in poly.allSatisfy { p in
                    let v = p - pr.origin
                    return inOutline(SIMD2(simd_dot(v, pr.u), simd_dot(v, pr.w)), pr.loops)
                } }
                return allIn ? .whole : .notYet
            }
            return pr.shape == .planar ? .partial : .notYet
        }
    }

    /// ★ CARVE a piece by the planes of a prism that really cross it, with the Surface tool's own calls: `splitManual` on
    /// each plane, `splitDetached` on each half; the inside pieces holding surface are kept (several when a non-convex face
    /// falls apart), the outside ones returned as free. Never assigned to the project: `m` is a scratch copy.
    static func carve(_ m: inout FaceRegionModel, piece: RegionID, planes: [RegionCut], tris: [[SIMD3<Double>]],
                      mesh: ViewerMesh, eps: Double) -> (inside: [RegionID], beyond: [RegionID]) {
        func area(_ id: RegionID) -> Double { FlexibleEdgeStrips.area(tris, m.region(id)?.cuts ?? []) }
        var inside = [piece], out: [RegionID] = []
        for c in planes {
            var next: [RegionID] = []
            for cur in inside {
                let have = m.region(cur)?.cuts ?? []
                guard FlexibleEdgeStrips.area(tris, have + [beyond(c)]) > eps else { next.append(cur); continue }
                let kids = m.splitManual(cur, point: c.point, normal: c.normal)
                guard kids.count == 2 else { next.append(cur); continue }
                let a = m.splitDetached(kids[0], in: mesh), b = m.splitDetached(kids[1], in: mesh)
                next += (a.isEmpty ? [kids[0]] : a).filter { area($0) > eps }
                out += (b.isEmpty ? [kids[1]] : b).filter { area($0) > eps }
            }
            inside = next
        }
        return (inside, out)
    }
}

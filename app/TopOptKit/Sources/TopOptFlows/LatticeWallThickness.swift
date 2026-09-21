import Foundation
import simd

// ★★★ THE LATTICE'S THICKNESS THROUGH THE WALL (his 2026-09-20/21: "I want the sim to
// decide the thickness of the lattice wall itself. Currently it should be ALL THE WAY
// THROUGH. It would mean adding a new variable to the existing infrastructure"), built
// to his design `docs/design/lattice-page/Lattice Wall Thickness.dc.html` (2026-09-21).
//
// A face region is a prism: the face outline extruded `depthMM` into the part. Until
// now the lattice filled the whole prism. This is a SLAB inside that prism, and the
// design says it in two questions:
//
//   1. "Depth defined by sim?"  ON  ⇒ the solve decides how deep the lattice goes
//                               OFF ⇒ the user sets, per wall, the ALLOWED range in mm
//                                     (start – end, from the outer surface in), "how
//                                     much of the wall's thickness COULD be used"
//   2. "Density through the wall" (only when the range is the user's): what WILL be used
//        sim           HIS RULE, agreed 2026-09-21: at each face point the slab is the
//                      allowed range × that point's normalised stress (the column's peak
//                      von Mises over the part's 95th percentile), never under one cell
//        autoSingle    one thickness for the wall, the same rule at the wall's own p95
//        manualSingle  one share of the allowed range, typed (%)
//        manualGrade   the profile he DRAWS per wall: a start curve and an end curve
//                      across the wall's width, in the viewer's grading tool
//
// PREVIEW FIRST (his rule, 2026-09-20): the slab is applied where the app builds the
// preview — the one region distance every reader clips against, the organic candidates,
// the octree's cells, the cap walls drawn where the slab starts and ends — and NOTHING
// reaches core's job until it is agreed to work. The job's region still carries the
// declared depth. Untouched projects encode byte-identically.

public enum LatticeWallDensityMode: String, Codable, CaseIterable, Sendable {
    case sim, autoSingle, manualSingle, manualGrade

    public var title: String {
        switch self {
        case .sim: return "Graded by sim"
        case .autoSingle: return "Auto single density"
        case .manualSingle: return "Manual single density"
        case .manualGrade: return "Manual grade"
        }
    }
    public var brief: String {
        switch self {
        case .sim: return "FEA stress field drives density"
        case .autoSingle: return "One value chosen for the part"
        case .manualSingle: return "One value you set"
        case .manualGrade: return "Draw the density profile per wall"
        }
    }
    public var readsTheSolve: Bool { self == .sim || self == .autoSingle }
}

/// One point of a drawn profile, in the wall's normalised box: x across the wall's width
/// (0…1), y through its thickness (0 = outer surface, 1 = inner). `smooth` false is a
/// corner; `tx/ty` an explicit tangent (Catmull-Rom otherwise), as in the design.
public struct LatticeWallProfilePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var smooth: Bool = true
    public var tx: Double? = nil
    public var ty: Double? = nil
    public init(x: Double, y: Double, smooth: Bool = true, tx: Double? = nil, ty: Double? = nil) {
        self.x = x; self.y = y; self.smooth = smooth; self.tx = tx; self.ty = ty
    }
}

/// The drawn profile of one wall: the START curve (kept in the outer half, y ≤ 0.5) and
/// the END curve (the inner half, y ≥ 0.5) — the lattice lives between them.
public struct LatticeWallProfile: Codable, Equatable, Sendable {
    public var start: [LatticeWallProfilePoint]
    public var end: [LatticeWallProfilePoint]
    public var curveStart: Bool = true
    public var curveEnd: Bool = true

    public init(start: [LatticeWallProfilePoint], end: [LatticeWallProfilePoint],
                curveStart: Bool = true, curveEnd: Bool = true) {
        self.start = start; self.end = end; self.curveStart = curveStart; self.curveEnd = curveEnd
    }
    /// Two straight lines at the allowed range's shares.
    public static func flat(start a: Double, end b: Double) -> LatticeWallProfile {
        LatticeWallProfile(start: [.init(x: 0, y: min(a, 0.5)), .init(x: 1, y: min(a, 0.5))],
                           end: [.init(x: 0, y: max(b, 0.5)), .init(x: 1, y: max(b, 0.5))])
    }

    // ── the design's geometry, ported verbatim (`tangent`, `pathD`) ──────────────
    static func tangent(_ pts: [LatticeWallProfilePoint], _ i: Int) -> SIMD2<Double> {
        let p = pts[i]
        if let tx = p.tx, let ty = p.ty { return SIMD2(tx, ty) }
        let a = i > 0 ? pts[i - 1] : p, b = i + 1 < pts.count ? pts[i + 1] : p
        return SIMD2((b.x - a.x) / 6, (b.y - a.y) / 6)
    }

    /// The curve as a polyline in the normalised box, 24 samples per smooth segment,
    /// flattened along the mid-plane where it would cross (`side` start ⇒ y ≤ 0.5).
    public static func polyline(_ pts: [LatticeWallProfilePoint], curved: Bool,
                                side: Side?) -> [SIMD2<Double>] {
        guard pts.count >= 2 else { return pts.map { SIMD2($0.x, $0.y) } }
        func clampY(_ y: Double) -> Double {
            switch side { case .none: return y; case .start: return min(y, 0.5); case .end: return max(y, 0.5) }
        }
        var out = [SIMD2(pts[0].x, clampY(pts[0].y))]
        for i in 0..<(pts.count - 1) {
            let p0 = SIMD2(pts[i].x, pts[i].y), p1 = SIMD2(pts[i + 1].x, pts[i + 1].y)
            if !curved || !pts[i].smooth || !pts[i + 1].smooth {
                out.append(SIMD2(p1.x, clampY(p1.y))); continue
            }
            let t1 = tangent(pts, i), t2 = tangent(pts, i + 1)
            let c1 = p0 + t1, c2 = p1 - t2
            let n = 24
            for k in 1...n {
                let u = Double(k) / Double(n), v = 1 - u
                let q = v*v*v*p0 + 3*v*v*u*c1 + 3*v*u*u*c2 + u*u*u*p1
                out.append(SIMD2(q.x, clampY(q.y)))
            }
        }
        return out
    }

    public enum Side: String, Codable, Sendable { case start, end }

    /// y of a side's curve at x (0…1): the polyline's first crossing of x, its ends
    /// held beyond the range.
    public func y(at x: Double, side: Side) -> Double {
        let pts = side == .start ? start : end
        let curved = side == .start ? curveStart : curveEnd
        let poly = LatticeWallProfile.polyline(pts, curved: curved, side: side)
        guard let first = poly.first, let last = poly.last else { return side == .start ? 0 : 1 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for i in 0..<(poly.count - 1) {
            let a = poly[i], b = poly[i + 1]
            if (a.x <= x && x <= b.x) || (b.x <= x && x <= a.x) {
                let d = b.x - a.x
                let t = abs(d) < 1e-12 ? 0 : (x - a.x) / d
                return a.y + (b.y - a.y) * t
            }
        }
        return last.y
    }
}

/// One wall's own ask: the allowed range in mm from the outer surface (end nil = the
/// declared depth) and, for `manualGrade`, the profile drawn for it.
public struct LatticeFaceWallThickness: Codable, Equatable, Sendable {
    public var startMM: Double = 0
    public var endMM: Double? = nil
    public var profile: LatticeWallProfile? = nil
    public init(startMM: Double = 0, endMM: Double? = nil, profile: LatticeWallProfile? = nil) {
        self.startMM = startMM; self.endMM = endMM; self.profile = profile
    }
    public var isFull: Bool { startMM <= 0 && endMM == nil && profile == nil }
}

/// What the user asked for — the request, not the answer. The default is the whole
/// prism, exactly as before the variable existed.
public struct LatticeWallThickness: Equatable, Sendable, Codable {
    /// ★ ON by default (his 2026-09-21, image 2: "the default it should be set at").
    public var depthBySim: Bool = true
    /// ★ "Graded by sim" first (his 2026-09-21, image 2); manual single at 100 % is the
    /// whole prism.
    public var density: LatticeWallDensityMode = .sim
    /// manualSingle: the share of the allowed range that is latticed, in percent.
    public var pct: Double = 100
    /// per wall, by the region's selectable key ("f:<group>:<face>")
    public var faces: [String: LatticeFaceWallThickness] = [:]
    /// ★ THE SEEDING BOOST (his 2026-09-21), ×1 = core's tracer as it is, up to ×3:
    /// seeds offered closer, short curves kept, curves allowed closer down to the
    /// printable floor. Preview only, like everything here.
    public var seedBoost: Double = 1

    public init() {}

    private enum CodingKeys: String, CodingKey { case depthBySim, density, pct, faces, seedBoost }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        depthBySim = try c.decodeIfPresent(Bool.self, forKey: .depthBySim) ?? true
        density = try c.decodeIfPresent(LatticeWallDensityMode.self, forKey: .density) ?? .sim
        pct = try c.decodeIfPresent(Double.self, forKey: .pct) ?? 100
        faces = try c.decodeIfPresent([String: LatticeFaceWallThickness].self, forKey: .faces) ?? [:]
        seedBoost = try c.decodeIfPresent(Double.self, forKey: .seedBoost) ?? 1
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(depthBySim, forKey: .depthBySim)
        try c.encode(density, forKey: .density)
        try c.encode(pct, forKey: .pct)
        if !faces.isEmpty { try c.encode(faces, forKey: .faces) }
        if seedBoost != 1 { try c.encode(seedBoost, forKey: .seedBoost) }
    }
    public init(depthBySim: Bool, density: LatticeWallDensityMode = .sim, pct: Double = 100,
                faces: [String: LatticeFaceWallThickness] = [:]) {
        self.depthBySim = depthBySim; self.density = density; self.pct = pct; self.faces = faces
    }
    /// The default every project starts from: the solve decides the depth.
    public static let standard = LatticeWallThickness()
    /// The whole prism, as before the variable existed.
    public static let through = LatticeWallThickness(depthBySim: false, density: .manualSingle, pct: 100)

    /// Nothing to apply: the prism is the slab.
    public var isThrough: Bool {
        !depthBySim && density == .manualSingle && pct >= 100 && faces.values.allSatisfy { $0.isFull }
    }
    public func face(_ key: String?) -> LatticeFaceWallThickness { faces[key ?? ""] ?? LatticeFaceWallThickness() }
}

/// The answer for one face: rasters over the face's (u, v) plane holding where the slab
/// STARTS and ENDS, in mm from the outer surface along the normal.
public struct LatticeWallThicknessMap: Equatable, Sendable {
    public let origin: SIMD2<Double>
    public let h: Double
    public let nu: Int, nv: Int
    public var starts: [Float]
    public var ends: [Float]

    public init(origin: SIMD2<Double>, h: Double, nu: Int, nv: Int, starts: [Float], ends: [Float]) {
        self.origin = origin; self.h = h; self.nu = nu; self.nv = nv; self.starts = starts; self.ends = ends
    }
    public static func constant(startMM: Double, endMM: Double) -> LatticeWallThicknessMap {
        LatticeWallThicknessMap(origin: .zero, h: 1, nu: 1, nv: 1, starts: [Float(startMM)], ends: [Float(endMM)])
    }
    public var isConstant: Bool { nu == 1 && nv == 1 }
    public var startMM: Double { Double(starts.min() ?? 0) }

    private func sample(_ a: [Float], at uv: SIMD2<Double>, fallback: Double) -> Double {
        if nu == 1 && nv == 1 { return Double(a[0]) }
        let fx = min(max((uv.x - origin.x) / h, 0), Double(nu - 1))
        let fy = min(max((uv.y - origin.y) / h, 0), Double(nv - 1))
        let i0 = Int(fx), j0 = Int(fy)
        let i1 = min(i0 + 1, nu - 1), j1 = min(j0 + 1, nv - 1)
        let tx = fx - Double(i0), ty = fy - Double(j0)
        func v(_ i: Int, _ j: Int) -> Double { Double(a[j * nu + i]) }
        let r0 = v(i0, j0) * (1 - tx) + v(i1, j0) * tx
        let r1 = v(i0, j1) * (1 - tx) + v(i1, j1) * tx
        let s = r0 * (1 - ty) + r1 * ty
        return s.isFinite ? s : fallback
    }
    /// The slab at `uv`: [start, end] in mm from the outer surface.
    public func range(at uv: SIMD2<Double>, depthMM: Double) -> (start: Double, end: Double) {
        let s = sample(starts, at: uv, fallback: 0), e = sample(ends, at: uv, fallback: depthMM)
        return (min(max(0, s), depthMM), min(max(s, e), depthMM))
    }
    public var summary: (p05: Double, p50: Double, p95: Double) {
        let t = zip(starts, ends).map { Double($1 - $0) }.filter { $0.isFinite }.sorted()
        guard !t.isEmpty else { return (0, 0, 0) }
        func q(_ f: Double) -> Double { t[min(t.count - 1, Int(Double(t.count - 1) * f))] }
        return (q(0.05), q(0.5), q(0.95))
    }
}

public enum LatticeWallThicknessBuilder {

    /// The part's reference stress for the sim rule: the 95th percentile of von Mises over
    /// every voxel inside any include face prism (the WHOLE prism, before any slab), so a
    /// dead wall reads thin and a loaded one thick — per part, not per wall.
    public static func referenceMPa(field: StressField, regions: [LatticeRegionSpec]) -> Double {
        var vals: [Float] = []
        let faces = regions.filter { $0.role == .include && $0.kind == .face && $0.depthMM > 0 }
        guard !faces.isEmpty, field.values.count == field.nx * field.ny * field.nz else { return 0 }
        for k in 0..<field.nz { for j in 0..<field.ny { for i in 0..<field.nx {
            let p = SIMD3<Double>(field.origin) + SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * Double(field.spacing)
            let v = field.values[(k * field.ny + j) * field.nx + i]
            guard v.isFinite, v > 0 else { continue }
            var inside = false
            for r in faces where LatticeRegionMask.containsWholePrism(p, region: r) { inside = true; break }
            if inside { vals.append(v) }
        } } }
        guard !vals.isEmpty else { return 0 }
        vals.sort()
        return Double(vals[min(vals.count - 1, Int(Double(vals.count - 1) * 0.95))])
    }

    /// The face's own frame: (u, v) basis, the outline's bounds, and which in-plane axis
    /// is the wall's WIDTH (the longer one) — the x of a drawn profile.
    public struct FaceFrame {
        public let bu: SIMD3<Double>, bv: SIMD3<Double>
        public let lo: SIMD2<Double>, hi: SIMD2<Double>
        public let widthAlongU: Bool
        public var widthMM: Double { widthAlongU ? hi.x - lo.x : hi.y - lo.y }
        /// 0…1 across the wall's width at `uv`.
        public func x(at uv: SIMD2<Double>) -> Double {
            let w = widthMM
            guard w > 1e-9 else { return 0 }
            return min(1, max(0, (widthAlongU ? uv.x - lo.x : uv.y - lo.y) / w))
        }
    }
    public static func frame(_ r: LatticeRegionSpec) -> FaceFrame? {
        let n = LatticeRegionMask.unit(r.normal)
        guard simd_length(n) > 0.5 else { return nil }
        let (bu, bv) = LatticeRegionMask.basis(n)
        var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
        for loop in r.outlineLoops { for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
        if r.outlineLoops.isEmpty { lo = SIMD2(-r.halfUMM, -r.halfWMM); hi = SIMD2(r.halfUMM, r.halfWMM) }
        guard lo.x < hi.x, lo.y < hi.y else { return nil }
        return FaceFrame(bu: bu, bv: bv, lo: lo, hi: hi, widthAlongU: (hi.x - lo.x) >= (hi.y - lo.y))
    }

    /// The map for one face, or nil when the request is the whole prism. `floorMM` is
    /// one cell — the slab is never thinner where there is room.
    public static func build(region r: LatticeRegionSpec, spec: LatticeWallThickness,
                             field: StressField?, referenceMPa: Double,
                             floorMM: Double) -> LatticeWallThicknessMap? {
        guard r.role == .include, r.kind == .face, r.depthMM > 0, !spec.isThrough else { return nil }
        let depth = r.depthMM
        let ask = spec.face(r.selectableKey)
        // the allowed range, from the outer surface in
        let a0 = spec.depthBySim ? 0 : min(max(0, ask.startMM), depth * 0.95)
        let a1 = spec.depthBySim ? depth : min(max(a0, ask.endMM ?? depth), depth)
        let room = max(0, a1 - a0)
        let floorT = min(room, max(0, floorMM))
        func endFor(share: Double) -> Double { a0 + max(floorT, min(1, max(0, share)) * room) }

        let mode: LatticeWallDensityMode = spec.depthBySim ? .sim : spec.density
        switch mode {
        case .manualSingle:
            return .constant(startMM: a0, endMM: endFor(share: spec.pct / 100))
        case .manualGrade:
            guard let fr = frame(r), let prof = ask.profile else {
                return .constant(startMM: a0, endMM: a1)
            }
            let h = max(0.5, fr.widthMM / 96)
            let nu = Int(((fr.hi.x - fr.lo.x) / h).rounded(.up)) + 1
            let nv = Int(((fr.hi.y - fr.lo.y) / h).rounded(.up)) + 1
            var starts = [Float](repeating: 0, count: nu * nv), ends = [Float](repeating: 0, count: nu * nv)
            for j in 0..<nv { for i in 0..<nu {
                let uv = fr.lo + SIMD2(Double(i), Double(j)) * h
                let x = fr.x(at: uv)
                // the profile is drawn over the WHOLE wall thickness, then held inside the range
                var s = min(max(prof.y(at: x, side: .start) * depth, a0), a1)
                var e = min(max(prof.y(at: x, side: .end) * depth, a0), a1)
                if e < s { swap(&s, &e) }
                if e - s < floorT { e = min(a1, s + floorT); s = max(a0, e - floorT) }
                starts[j * nu + i] = Float(s); ends[j * nu + i] = Float(e)
            } }
            return LatticeWallThicknessMap(origin: fr.lo, h: h, nu: nu, nv: nv, starts: starts, ends: ends)
        case .sim, .autoSingle:
            guard let fr = frame(r), let field, referenceMPa > 0,
                  field.values.count == field.nx * field.ny * field.nz else {
                return .constant(startMM: a0, endMM: a1)      // no solve to read: the range
            }
            let h = max(0.5, Double(field.spacing) * 0.5)
            let lo = fr.lo - SIMD2(h, h), hi = fr.hi + SIMD2(h, h)
            let nu = Int(((hi.x - lo.x) / h).rounded(.up)) + 1
            let nv = Int(((hi.y - lo.y) / h).rounded(.up)) + 1
            var peak = [Float](repeating: .nan, count: nu * nv)
            let (lo3, hi3) = prismBounds(r)
            let g0v = (lo3 - SIMD3<Double>(field.origin)) / Double(field.spacing)
            let g1v = (hi3 - SIMD3<Double>(field.origin)) / Double(field.spacing)
            let g0 = pointwiseMax(SIMD3<Int>(0, 0, 0), SIMD3<Int>(g0v, rounding: .down) &- 1)
            let g1 = pointwiseMin(SIMD3<Int>(field.nx - 1, field.ny - 1, field.nz - 1), SIMD3<Int>(g1v, rounding: .up) &+ 1)
            if g0.x <= g1.x, g0.y <= g1.y, g0.z <= g1.z {
                for k in g0.z...g1.z { for j in g0.y...g1.y { for i in g0.x...g1.x {
                    let p = SIMD3<Double>(field.origin) + SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * Double(field.spacing)
                    guard LatticeRegionMask.containsWholePrism(p, region: r) else { continue }
                    let v = field.values[(k * field.ny + j) * field.nx + i]
                    guard v.isFinite else { continue }
                    let d = p - r.origin
                    let uv = SIMD2<Double>(simd_dot(d, fr.bu), simd_dot(d, fr.bv))
                    let ci = min(nu - 1, max(0, Int((uv.x - lo.x) / h)))
                    let cj = min(nv - 1, max(0, Int((uv.y - lo.y) / h)))
                    let e = cj * nu + ci
                    let s = Float(min(1, Double(max(0, v)) / referenceMPa))
                    if peak[e].isNaN || s > peak[e] { peak[e] = s }
                } } }
            }
            for _ in 0..<3 {                       // cells no voxel landed in take a neighbour's
                var next = peak
                for j in 0..<nv { for i in 0..<nu where peak[j * nu + i].isNaN {
                    var best: Float = .nan
                    for dj in -1...1 { for di in -1...1 {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, jj >= 0, ii < nu, jj < nv else { continue }
                        let v = peak[jj * nu + ii]
                        if v.isFinite, best.isNaN || v > best { best = v }
                    } }
                    next[j * nu + i] = best
                } }
                peak = next
            }
            guard peak.contains(where: { $0.isFinite }) else { return .constant(startMM: a0, endMM: a1) }
            if mode == .autoSingle {
                let s = peak.filter { $0.isFinite }.sorted()
                let p95 = Double(s[min(s.count - 1, Int(Double(s.count - 1) * 0.95))])
                return .constant(startMM: a0, endMM: endFor(share: p95))
            }
            var starts = [Float](repeating: Float(a0), count: nu * nv), ends = [Float](repeating: .nan, count: nu * nv)
            for e in 0..<peak.count where peak[e].isFinite { ends[e] = Float(endFor(share: Double(peak[e]))) }
            for e in 0..<ends.count where ends[e].isNaN { ends[e] = Float(a1); starts[e] = Float(a0) }
            return LatticeWallThicknessMap(origin: lo, h: h, nu: nu, nv: nv, starts: starts, ends: ends)
        }
    }

    /// The world-space box around a face prism (outline bounds × depth), for a bounded scan.
    static func prismBounds(_ r: LatticeRegionSpec) -> (SIMD3<Double>, SIMD3<Double>) {
        let n = LatticeRegionMask.unit(r.normal)
        let (bu, bv) = LatticeRegionMask.basis(n)
        var lo = SIMD3<Double>(repeating: 1e9), hi = SIMD3<Double>(repeating: -1e9)
        for loop in r.outlineLoops { for q in loop { for s in [0.0, r.depthMM] {
            let p = r.origin + bu * q.x + bv * q.y + n * s
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        } } }
        if r.outlineLoops.isEmpty {
            for su in [-r.halfUMM, r.halfUMM] { for sv in [-r.halfWMM, r.halfWMM] { for s in [0.0, r.depthMM] {
                let p = r.origin + bu * su + bv * sv + n * s
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            } } }
        }
        return (lo, hi)
    }

    /// Attach a map to every include face that asked for one. The preview's own regions
    /// carry the answer; the job's copy never sees it.
    public static func attach(_ regions: [LatticeRegionSpec], field: StressField?,
                              floorMM: Double) -> [LatticeRegionSpec] {
        guard regions.contains(where: { $0.thickness.map { !$0.isThrough } ?? false }) else { return regions }
        let needsField = regions.contains { r in
            guard let t = r.thickness else { return false }
            return t.depthBySim || t.density.readsTheSolve
        }
        let ref = (needsField && field != nil) ? referenceMPa(field: field!, regions: regions) : 0
        var out = regions
        for i in out.indices {
            guard let spec = out[i].thickness else { continue }
            out[i].thicknessMap = build(region: out[i], spec: spec, field: field,
                                        referenceMPa: ref, floorMM: floorMM)
        }
        return out
    }
}

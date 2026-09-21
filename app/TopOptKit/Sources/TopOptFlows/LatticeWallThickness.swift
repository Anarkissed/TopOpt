import Foundation
import simd

// ★★★ THE LATTICE'S THICKNESS THROUGH THE WALL (his 2026-09-20/21: "I want the sim to
// decide the thickness of the lattice wall itself. Currently it should be ALL THE WAY
// THROUGH. It would mean adding a new variable to the existing infrastructure").
//
// A face region is a prism: the face outline extruded `depthMM` into the part. Until
// now the lattice filled the whole prism. This is a SLAB inside that prism — where it
// starts (a share of the depth in from the face) and how thick it is at every point of
// the face (a share of what is left). Five ways to pick the thickness:
//
//   through       the whole prism, as it always was (the default; an untouched project
//                 emits byte-identically)
//   sim           HIS RULE, agreed 2026-09-21: thickness at a face point = the depth ×
//                 that point's normalised stress (the column's peak von Mises over the
//                 part's 95th percentile), never thinner than one cell
//   autoSingle    one thickness for the whole face from the same rule, at the face's own
//                 95th percentile
//   manualSingle  one share, typed
//   manualGrade   two shares that BOUND the sim's rule: lo + (hi − lo) × stress
//
// PREVIEW FIRST (his rule, 2026-09-20): the slab is applied where the app builds the
// preview — the region distance every reader clips against, the organic candidates, the
// octree's cells, the cap wall drawn where the prism ends — and NOTHING reaches core's
// job until it is agreed to work. The job's region still carries the declared depth.

public enum LatticeWallThicknessMode: String, Codable, CaseIterable, Sendable {
    case through, sim, autoSingle, manualSingle, manualGrade

    public var title: String {
        switch self {
        case .through: return "Through"
        case .sim: return "Sim"
        case .autoSingle: return "Auto"
        case .manualSingle: return "Manual"
        case .manualGrade: return "Grade"
        }
    }
    /// One line, under the picker.
    public var brief: String {
        switch self {
        case .through: return "The lattice fills the whole depth."
        case .sim: return "The solve sets the thickness at every point."
        case .autoSingle: return "One thickness for the wall, from the solve."
        case .manualSingle: return "One thickness, as a share of the depth."
        case .manualGrade: return "The solve grades between two shares."
        }
    }
    /// The sentence behind (i).
    public var body: String {
        switch self {
        case .through:
            return "Every point of the face is latticed from the face to the declared depth, as before."
        case .sim:
            return "At each point of the face the slab is the declared depth times that point's "
                + "stress, relative to the part's 95th-percentile stress; thick where the load is, "
                + "thin where it is not, never thinner than one cell."
        case .autoSingle:
            return "The same rule, at the wall's own 95th-percentile stress, giving one thickness "
                + "for the whole wall."
        case .manualSingle:
            return "The slab is this share of the declared depth everywhere on the face."
        case .manualGrade:
            return "The solve grades the thickness between the two shares: the low share where "
                + "the stress is lowest, the high share where it peaks."
        }
    }
    public var readsTheSolve: Bool { self == .sim || self == .autoSingle || self == .manualGrade }
}

/// What the user asked for — the request, not the answer. Shares are of the declared
/// depth; `start` is where the slab begins, in from the face.
public struct LatticeWallThickness: Equatable, Sendable, Codable {
    public var mode: LatticeWallThicknessMode = .through
    public var startShare: Double = 0
    public var share: Double = 1          // manualSingle
    public var loShare: Double = 0.5      // manualGrade
    public var hiShare: Double = 1        // manualGrade

    public static let through = LatticeWallThickness()
    public init() {}
    public init(mode: LatticeWallThicknessMode, startShare: Double = 0, share: Double = 1,
                loShare: Double = 0.5, hiShare: Double = 1) {
        self.mode = mode; self.startShare = startShare; self.share = share
        self.loShare = loShare; self.hiShare = hiShare
    }
    /// The default asks for nothing the prism does not already do.
    public var isThrough: Bool { mode == .through && startShare <= 0 }
}

/// The answer for one face: a raster over the face's (u, v) plane holding the slab's
/// thickness as a SHARE of the depth left past `startMM` (0…1), and the start itself.
public struct LatticeWallThicknessMap: Equatable, Sendable {
    public let startMM: Double
    public let origin: SIMD2<Double>
    public let h: Double
    public let nu: Int, nv: Int
    public var shares: [Float]           // nu × nv, u fastest; NaN = never filled

    public init(startMM: Double, origin: SIMD2<Double>, h: Double, nu: Int, nv: Int, shares: [Float]) {
        self.startMM = startMM; self.origin = origin; self.h = h; self.nu = nu; self.nv = nv
        self.shares = shares
    }

    /// A map that is the same share everywhere.
    public static func constant(_ share: Double, startMM: Double) -> LatticeWallThicknessMap {
        LatticeWallThicknessMap(startMM: startMM, origin: .zero, h: 1, nu: 1, nv: 1,
                                shares: [Float(min(1, max(0, share)))])
    }

    /// The share at `uv`, bilinear, clamped to the raster's edge.
    public func share(at uv: SIMD2<Double>) -> Double {
        if nu == 1 && nv == 1 { return Double(shares[0]) }
        let fx = min(max((uv.x - origin.x) / h, 0), Double(nu - 1))
        let fy = min(max((uv.y - origin.y) / h, 0), Double(nv - 1))
        let i0 = Int(fx), j0 = Int(fy)
        let i1 = min(i0 + 1, nu - 1), j1 = min(j0 + 1, nv - 1)
        let tx = fx - Double(i0), ty = fy - Double(j0)
        func v(_ i: Int, _ j: Int) -> Double { Double(shares[j * nu + i]) }
        let a = v(i0, j0) * (1 - tx) + v(i1, j0) * tx
        let b = v(i0, j1) * (1 - tx) + v(i1, j1) * tx
        let s = a * (1 - ty) + b * ty
        return s.isFinite ? s : 1
    }

    /// Where the slab ends (mm in from the face) at `uv`, for a prism `depthMM` deep.
    public func endMM(at uv: SIMD2<Double>, depthMM: Double) -> Double {
        startMM + share(at: uv) * max(0, depthMM - startMM)
    }

    public var summary: (p05: Double, p50: Double, p95: Double) {
        let s = shares.filter { $0.isFinite }.sorted()
        guard !s.isEmpty else { return (1, 1, 1) }
        func q(_ f: Double) -> Double { Double(s[min(s.count - 1, Int(Double(s.count - 1) * f))]) }
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

    /// The map for one face. `floorMM` is one cell — the slab is never thinner. Returns
    /// nil when the request is the whole prism (nothing to apply).
    public static func build(region r: LatticeRegionSpec, spec: LatticeWallThickness,
                             field: StressField?, referenceMPa: Double,
                             floorMM: Double) -> LatticeWallThicknessMap? {
        guard r.role == .include, r.kind == .face, r.depthMM > 0, !spec.isThrough else { return nil }
        let startMM = min(max(0, spec.startShare), 0.95) * r.depthMM
        let left = max(0, r.depthMM - startMM)
        let floorShare = left > 0 ? min(1, max(0, floorMM) / left) : 1
        func clampShare(_ s: Double) -> Double { min(1, max(floorShare, s)) }
        switch spec.mode {
        case .through:
            return .constant(1, startMM: startMM)
        case .manualSingle:
            return .constant(clampShare(spec.share), startMM: startMM)
        case .sim, .autoSingle, .manualGrade:
            // ★ the stress at the face: the column's peak, per (u, v) cell of the raster
            let n = LatticeRegionMask.unit(r.normal)
            guard simd_length(n) > 0.5 else { return .constant(1, startMM: startMM) }
            let (bu, bv) = LatticeRegionMask.basis(n)
            var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
            for loop in r.outlineLoops { for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
            guard lo.x < hi.x, lo.y < hi.y, let field, referenceMPa > 0,
                  field.values.count == field.nx * field.ny * field.nz else {
                // no solve to read: the whole prism, and the wizard says why
                return .constant(1, startMM: startMM)
            }
            let h = max(0.5, Double(field.spacing) * 0.5)
            let pad = h
            lo -= SIMD2(pad, pad); hi += SIMD2(pad, pad)
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
                    let uv = SIMD2<Double>(simd_dot(d, bu), simd_dot(d, bv))
                    let ci = min(nu - 1, max(0, Int((uv.x - lo.x) / h)))
                    let cj = min(nv - 1, max(0, Int((uv.y - lo.y) / h)))
                    let e = cj * nu + ci
                    let s = Float(min(1, Double(max(0, v)) / referenceMPa))
                    if peak[e].isNaN || s > peak[e] { peak[e] = s }
                } } }
            }
            // cells no voxel centre landed in take their neighbours' peak, a few passes
            for _ in 0..<3 {
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
            var shares = [Float](repeating: .nan, count: nu * nv)
            switch spec.mode {
            case .sim:
                for e in 0..<peak.count where peak[e].isFinite { shares[e] = Float(clampShare(Double(peak[e]))) }
            case .manualGrade:
                let a = min(spec.loShare, spec.hiShare), b = max(spec.loShare, spec.hiShare)
                for e in 0..<peak.count where peak[e].isFinite { shares[e] = Float(clampShare(a + (b - a) * Double(peak[e]))) }
            case .autoSingle:
                let s = peak.filter { $0.isFinite }.sorted()
                let p95 = s.isEmpty ? 1 : Double(s[min(s.count - 1, Int(Double(s.count - 1) * 0.95))])
                return .constant(clampShare(p95), startMM: startMM)
            default: break
            }
            if !shares.contains(where: { $0.isFinite }) { return .constant(1, startMM: startMM) }
            return LatticeWallThicknessMap(startMM: startMM, origin: lo, h: h, nu: nu, nv: nv, shares: shares)
        }
    }

    /// The world-space box around a face prism (outline bounds × depth), for a bounded scan.
    static func prismBounds(_ r: LatticeRegionSpec) -> (SIMD3<Double>, SIMD3<Double>) {
        let n = LatticeRegionMask.unit(r.normal)
        let (bu, bv) = LatticeRegionMask.basis(n)
        var lo = SIMD3<Double>(repeating: 1e9), hi = SIMD3<Double>(repeating: -1e9)
        for loop in r.outlineLoops { for q in loop {
            for s in [0.0, r.depthMM] {
                let p = r.origin + bu * q.x + bv * q.y + n * s
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        } }
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
        guard regions.contains(where: { $0.thickness != nil && !($0.thickness!.isThrough) }) else { return regions }
        let needsField = regions.contains { ($0.thickness?.mode.readsTheSolve ?? false) }
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

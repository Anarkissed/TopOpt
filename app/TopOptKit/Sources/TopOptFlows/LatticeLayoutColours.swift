// LatticeLayoutColours — ★ Install 3 (his 11-17 "Implement it as soon as possible"; the old preview retired where the part has
// its model file): the new engine's bars wear the old preview's colour key, so the key, the tap-to-read card and the picture
// keep saying one thing (UnifiedShading's `lsdf_albedo`, LatticeStructureColour):
//   · HUE = what the strut is: a skin bar (boundary work, core's bar_flags bit 2) the rim blue; every other bar the interior
//     violet;
//   · LIGHTNESS = how much material: pale → the hue by the bar's relative density (its width against its own cell, by the
//     lattice type's law), over the layout's own span (a single density is one lightness, the old point-span rule);
//   · THE GRADE BAND: a bar whose cell grade to shape shrank is drawn toward the grade teal by where its cell sits in the band
//     (core's cell band: 0 at the outline, 1 at the band's inner edge and beyond);
//   · STRESS, when the stress view is on with the lattice: the stress ramp at the bar's middle (LatticeStressTint), and only
//     that — as the old overlay did.
// Pure value code: no Metal, no view.

import Foundation
import simd
import TopOptKit

public enum LatticeLayoutColours {

    /// RED CONTROL (tests): every bar the one interior colour, as before Install 3.
    nonisolated(unsafe) public static var controlOneColour = false

    /// What one layout laid, kept for the key, the card and the colours (the session's Result, the parts the app reads).
    public struct Laid: Equatable, Sendable {
        public var bars: [Float] = []          // 7 per bar: a xyz, b xyz, width mm
        public var barFlags: [UInt8] = []
        public var barCell: [Float] = []
        public var barRegion: [Int32] = []
        public var frames: [Float] = []        // 12 per frame: origin, then three unit axes
        public var cellInfo: [Float] = []      // 5 per cell: size, own, band, finest, cut
        public var cellRegion: [Int32] = []
        public var cellWall: [Int32] = []
        public var cellFrame: [Int32] = []
        public var cellLo: [Float] = []        // 3 per cell, frame mm
        public var cellWallMM: [Float] = []    // 1 per cell: its wall's width, mm (0 = no wall)
        public var token = 0
        public init() {}
        public init(_ r: LatticeLayoutSession.Result, token: Int) {
            bars = r.bars; barFlags = r.barFlags; barCell = r.barCell; barRegion = r.barRegion
            frames = r.frames; cellInfo = r.cellInfo; cellRegion = r.cellRegion; cellWall = r.cellWall
            cellFrame = r.cellFrame; cellLo = r.cellLo; cellWallMM = r.cellWallMM
            self.token = token
        }
        public var barCount: Int { bars.count / 7 }
        public var cellCount: Int { cellInfo.count / 5 }
        public static func == (a: Laid, b: Laid) -> Bool { a.token == b.token && a.bars.count == b.bars.count }
    }

    /// What a bar is: boundary work, or fill.
    public static func isSkin(_ flags: UInt8) -> Bool { flags & 2 != 0 }

    /// Each bar's relative density: its width against its own cell by the lattice type's law (nil law: width / cell).
    public static func densities(_ laid: Laid, type: LatticeType?) -> [Double] {
        (0..<laid.barCount).map { i in
            let w = Double(laid.bars[7 * i + 6])
            let cell = i < laid.barCell.count ? Double(laid.barCell[i]) : 0
            guard w > 0, cell > 0 else { return 0 }
            if let t = type {
                let rho = t.relativeDensity(strutRadiusMM: w / 2, cellMM: cell)
                if rho > 0 { return rho }
            }
            return Swift.min(1, w / cell)
        }
    }

    // MARK: - which cell holds a point

    /// The laid cells, binned per frame, so a point finds the cube that holds it.
    public struct CellLookup {
        let laid: Laid
        let bin: Float
        var bins: [SIMD4<Int32>: [Int]] = [:]   // (frame, i, j, k)

        public init(_ laid: Laid) {
            self.laid = laid
            var big: Float = 0.5
            for c in 0..<laid.cellCount { big = Swift.max(big, laid.cellInfo[5 * c]) }
            bin = big
            for c in 0..<laid.cellCount where c < laid.cellFrame.count && 3 * c + 2 < laid.cellLo.count {
                let lo = SIMD3(laid.cellLo[3 * c], laid.cellLo[3 * c + 1], laid.cellLo[3 * c + 2])
                let hi = lo + SIMD3(repeating: laid.cellInfo[5 * c])
                let a = SIMD3<Int32>(Int32((lo.x / bin).rounded(.down)), Int32((lo.y / bin).rounded(.down)), Int32((lo.z / bin).rounded(.down)))
                let b = SIMD3<Int32>(Int32((hi.x / bin).rounded(.down)), Int32((hi.y / bin).rounded(.down)), Int32((hi.z / bin).rounded(.down)))
                for i in a.x...b.x { for j in a.y...b.y { for k in a.z...b.z {
                    bins[SIMD4(laid.cellFrame[c], i, j, k), default: []].append(c)
                } } }
            }
        }

        /// The point in frame `f`'s coordinates (mm).
        func local(_ p: SIMD3<Float>, frame f: Int) -> SIMD3<Float>? {
            let k = 12 * f
            guard k + 11 < laid.frames.count else { return nil }
            let o = SIMD3(laid.frames[k], laid.frames[k + 1], laid.frames[k + 2])
            let d = p - o
            return SIMD3(simd_dot(d, SIMD3(laid.frames[k + 3], laid.frames[k + 4], laid.frames[k + 5])),
                         simd_dot(d, SIMD3(laid.frames[k + 6], laid.frames[k + 7], laid.frames[k + 8])),
                         simd_dot(d, SIMD3(laid.frames[k + 9], laid.frames[k + 10], laid.frames[k + 11])))
        }

        /// The smallest laid cell whose cube holds `p` (within `tol` mm), or nil.
        public func cell(at p: SIMD3<Float>, tol: Float = 1e-3) -> Int? {
            var best: Int?
            for f in 0..<(laid.frames.count / 12) {
                guard let q = local(p, frame: f) else { continue }
                let key = SIMD4<Int32>(Int32(f), Int32((q.x / bin).rounded(.down)), Int32((q.y / bin).rounded(.down)),
                                       Int32((q.z / bin).rounded(.down)))
                for c in bins[key] ?? [] {
                    let lo = SIMD3(laid.cellLo[3 * c], laid.cellLo[3 * c + 1], laid.cellLo[3 * c + 2])
                    let s = laid.cellInfo[5 * c]
                    guard q.x >= lo.x - tol, q.y >= lo.y - tol, q.z >= lo.z - tol,
                          q.x <= lo.x + s + tol, q.y <= lo.y + s + tol, q.z <= lo.z + s + tol else { continue }
                    if best.map({ laid.cellInfo[5 * $0] > s }) ?? true { best = c }
                }
            }
            return best
        }
    }

    // MARK: - the colours

    /// The stress the bars are drawn by (the stress view with the lattice): von Mises at a point, and its peak.
    public struct Stress {
        public var at: (SIMD3<Float>) -> Double?
        public var peakMPa: Double
        public init(at: @escaping (SIMD3<Float>) -> Double?, peakMPa: Double) { self.at = at; self.peakMPa = peakMPa }
        /// The stage's field, read at the nearest voxel (the old card's own reading), against its peak.
        public init(field f: LatticeDemandField) {
            peakMPa = Double(f.vonMises.max() ?? 0)
            at = { p in
                let g = (SIMD3<Double>(p) - f.origin) / Swift.max(f.spacingMM, 1e-6)
                let i = Swift.min(Swift.max(Int(g.x.rounded()), 0), f.nx - 1)
                let j = Swift.min(Swift.max(Int(g.y.rounded()), 0), f.ny - 1)
                let k = Swift.min(Swift.max(Int(g.z.rounded()), 0), f.nz - 1)
                let n = (k * f.ny + j) * f.nx + i
                return n >= 0 && n < f.vonMises.count ? Double(f.vonMises[n]) : nil
            }
        }
    }

    /// One colour per bar (rgb, alpha 1), the old key's rules (see the header). `grade` = grade to shape is on.
    public static func colours(_ laid: Laid, type: LatticeType?, grade: Bool, stress: Stress? = nil,
                               lookup: CellLookup? = nil) -> [SIMD4<Float>] {
        let n = laid.barCount
        func rgb(_ c: RGBAColor) -> SIMD3<Float> { SIMD3(Float(c.r), Float(c.g), Float(c.b)) }
        let interior = rgb(LatticeStructureColour.interior), rim = rgb(LatticeStructureColour.rim)
        let pale = rgb(LatticeStructureColour.pale), teal = rgb(LatticeStructureColour.grade)
        if controlOneColour { return Array(repeating: SIMD4(interior, 1), count: n) }
        if let s = stress, s.peakMPa > 0 {
            return (0..<n).map { i in
                let k = 7 * i
                let mid = (SIMD3(laid.bars[k], laid.bars[k + 1], laid.bars[k + 2])
                           + SIMD3(laid.bars[k + 3], laid.bars[k + 4], laid.bars[k + 5])) / 2
                guard let mpa = s.at(mid) else { return SIMD4(interior, 1) }
                let c = LatticeStressTint.colour(fraction: mpa / s.peakMPa)
                return SIMD4(c.x, c.y, c.z, 1)
            }
        }
        let rho = densities(laid, type: type)
        let lo = rho.min() ?? 0, hi = rho.max() ?? 0
        let span = hi - lo
        let look = grade ? (lookup ?? CellLookup(laid)) : nil
        return (0..<n).map { i in
            let skin = i < laid.barFlags.count && isSkin(laid.barFlags[i])
            let frac = span > 1e-4 ? Float(Swift.min(Swift.max((rho[i] - lo) / span, 0), 1)) : 0
            var c = simd_mix(pale, skin ? rim : interior, SIMD3(repeating: Swift.min(Swift.max(0.25 + 0.75 * frac, 0), 1)))
            if !skin, let look {
                let k = 7 * i
                let mid = (SIMD3(laid.bars[k], laid.bars[k + 1], laid.bars[k + 2])
                           + SIMD3(laid.bars[k + 3], laid.bars[k + 4], laid.bars[k + 5])) / 2
                if let cell = look.cell(at: mid) {
                    let g = 1 - Swift.min(Swift.max(laid.cellInfo[5 * cell + 2], 0), 1)   // 1 at the outline, 0 past the band
                    if g > 0 { c = simd_mix(c, teal, SIMD3(repeating: g)) }
                }
            }
            return SIMD4(c, 1)
        }
    }
}

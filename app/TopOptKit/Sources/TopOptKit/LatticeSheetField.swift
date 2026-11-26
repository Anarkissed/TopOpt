// LatticeSheetField — ★ SHEETS (gyroid, Schwarz-D) on the new lattice engine (notes28 sheets SPEC rev 3, builder C, the app).
//
// A sheet is NOT a new layout: the engine lays cells as for struts, and each laid sheet region carries ONE field (core's
// lattice_layout.hpp, "SHEETS", builder A's contract 3b7d2e76): its frame, a cell corner as the phase anchor, the period,
// and the TRUE wall at the cell centres of the region's grid, read trilinearly (no step anywhere). The print file is
// contoured from that field, the strength check reads it, and the iPad draws it (LatticeLayoutSheetPass). This file is the
// Swift copy of core's field — sheet_local, sheet_wall_at_local, sheet_distance_at_local, sheet_mid_distance_at,
// sheet_param_at, sheet_seam_weight, sheet_blend_distance_at — line for line, so the shader can be held to it (the Flexible
// pass's way: the shader against this copy at 5 µm) and this copy to core's own functions (through the bridge's probe).
//
// The wall law (TRUE wall → the field parameter, core's lattice_sheet_wall_param_mm) is never re-derived here: it is read
// from core once per type as a table over wall / cell (`LatticeSheetLaw`), and the shader reads the same table.
import Foundation
import simd
import TopOptBridge

public struct LatticeSheetField: Sendable, Equatable {
    /// core's TpmsKind (the bridge's sheet_kind: 0 gyroid, 1 schwarz_d).
    public enum Kind: UInt8, Sendable, CaseIterable {
        case gyroid = 0, schwarzD = 1
        /// core's id (tpms_id, the job's topology string)
        public var id: String { self == .gyroid ? "gyroid" : "schwarz_d" }
        public init?(id: String) {
            switch id {
            case "gyroid": self = .gyroid
            case "schwarz_d": self = .schwarzD
            default: return nil
            }
        }
    }

    public var region: Int32
    public var frame: Int32
    public var kind: Kind
    /// The frame (part coordinates): origin and three unit axes at right angles.
    public var origin: SIMD3<Double>
    public var ax: [SIMD3<Double>]
    /// A cell corner of the region, frame coordinates: phase 0 there.
    public var anchor: SIMD3<Double>
    /// The period (one cell size per region).
    public var cellMM: Double
    /// The wall grid: n.x × n.y × n.z TRUE walls (mm) at the cell centres from `lo`, `cellMM` apart, x fastest.
    public var n: SIMD3<Int32>
    public var lo: SIMD3<Double>
    public var wallMM: [Float]
    public var wallMinMM: Double, wallMaxMM: Double

    public init(region: Int32 = 0, frame: Int32 = 0, kind: Kind, origin: SIMD3<Double> = .zero,
                ax: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], anchor: SIMD3<Double> = .zero,
                cellMM: Double, n: SIMD3<Int32> = SIMD3(1, 1, 1), lo: SIMD3<Double> = .zero, wallMM: [Float]) {
        self.region = region; self.frame = frame; self.kind = kind; self.origin = origin; self.ax = ax; self.anchor = anchor
        self.cellMM = cellMM; self.n = n; self.lo = lo; self.wallMM = wallMM
        wallMinMM = Double(wallMM.min() ?? 0); wallMaxMM = Double(wallMM.max() ?? 0)
    }

    /// The frame as the bridge carries it: origin xyz, then the three axes' xyz (12 floats).
    public var axesFlat: [Float] {
        ([origin] + ax).flatMap { [Float($0.x), Float($0.y), Float($0.z)] }
    }
    /// The wall grid has more than one value (By stress: a 3D texture of n.x × n.y × n.z; else one wall).
    public var graded: Bool { wallMM.count > 1 }

    // MARK: the field (core's sheets.cpp, line for line)

    /// Frame coordinates of a point of the part (core's sheet_local).
    public func local(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let r = p - origin
        return SIMD3(simd_dot(r, ax[0]), simd_dot(r, ax[1]), simd_dot(r, ax[2]))
    }

    /// THE WALL at a point (frame coordinates), mm: trilinear between the cell centres, clamped at the grid's edge (core's
    /// sheet_wall_at_local).
    public func wallAt(local q: SIMD3<Double>) -> Double {
        guard let first = wallMM.first else { return 0 }
        if wallMM.count == 1 || !(cellMM > 0) { return Double(first) }
        let qq = [q.x, q.y, q.z], ll = [lo.x, lo.y, lo.z], nn = [Int(n.x), Int(n.y), Int(n.z)]
        var i0 = [0, 0, 0], w = [0.0, 0.0, 0.0]
        for k in 0..<3 {
            let nk = Swift.max(1, nn[k])
            var u = (qq[k] - ll[k]) / cellMM
            if !(u > 0) { u = 0 }   // also NaN
            if u > Double(nk - 1) { u = Double(nk - 1) }
            var i = Int(u.rounded(.down))
            if i > nk - 2 { i = Swift.max(0, nk - 2) }
            i0[k] = i
            w[k] = nk > 1 ? u - Double(i) : 0
        }
        func at(_ i: Int, _ j: Int, _ k: Int) -> Double {
            let ii = Swift.min(i, nn[0] - 1), jj = Swift.min(j, nn[1] - 1), kk = Swift.min(k, nn[2] - 1)
            return Double(wallMM[(kk * nn[1] + jj) * nn[0] + ii])
        }
        var v = 0.0
        for c in 0..<8 {
            let dx = c & 1, dy = (c >> 1) & 1, dz = (c >> 2) & 1
            let wt = (dx != 0 ? w[0] : 1 - w[0]) * (dy != 0 ? w[1] : 1 - w[1]) * (dz != 0 ? w[2] : 1 - w[2])
            if wt != 0 { v += wt * at(i0[0] + dx, i0[1] + dy, i0[2] + dz) }
        }
        return v
    }
    public func wallAt(_ p: SIMD3<Double>) -> Double { wallAt(local: local(p)) }

    /// The field parameter for a TRUE wall here (core's lattice_sheet_wall_param_mm, read from its table): mm.
    public func param(wallMM wall: Double) -> Double {
        guard wall > 0, cellMM > 0 else { return 0 }
        return LatticeSheetLaw.param(kind, wallMM: wall, cellMM: cellMM)
    }
    /// core's sheet_param_at.
    public func paramAt(_ p: SIMD3<Double>) -> Double { param(wallMM: wallAt(p)) }

    /// The implicit function and its gradient (per mm) at (x, y, z) mm from the anchor, period L (core's tpms_eval). The phase
    /// is taken modulo one period first (the shader's float arguments stay small; the value is the same).
    public static func eval(_ kind: Kind, _ x: Double, _ y: Double, _ z: Double, _ L: Double) -> (f: Double, g: SIMD3<Double>) {
        let a = 2 * Double.pi / L
        func phase(_ v: Double) -> Double { let u = v / L; return 2 * Double.pi * (u - u.rounded(.down)) }
        let px = phase(x), py = phase(y), pz = phase(z)
        let sx = sin(px), cx = cos(px), sy = sin(py), cy = cos(py), sz = sin(pz), cz = cos(pz)
        if kind == .gyroid {
            return (sx * cy + sy * cz + sz * cx,
                    SIMD3(a * (cx * cy - sz * sx), a * (-sx * sy + cy * cz), a * (-sy * sz + cz * cx)))
        }
        return (sx * sy * sz + sx * cy * cz + cx * sy * cz + cx * cy * sz,
                SIMD3(a * (cx * sy * sz + cx * cy * cz - sx * sy * cz - sx * cy * sz),
                      a * (sx * cy * sz - sx * sy * cz + cx * cy * cz - cx * sy * sz),
                      a * (sx * sy * cz - sx * cy * sz - cx * sy * sz + cx * cy * cz)))
    }

    /// THE FIELD the file is contoured from and the preview draws (mm, negative inside the wall): core's
    /// sheet_distance_at_local — |f| / |∇f| − t / 2 at (local − anchor), t the parameter of the wall there.
    public func distance(local q: SIMD3<Double>) -> Double {
        guard cellMM > 0 else { return .infinity }
        let t = param(wallMM: wallAt(local: q))
        let v = Self.eval(kind, q.x - anchor.x, q.y - anchor.y, q.z - anchor.z, cellMM)
        let g = simd_length(v.g)
        if !(g > 1e-12) { return cellMM }
        return abs(v.f) / g - 0.5 * t
    }
    public func distance(_ p: SIMD3<Double>) -> Double { distance(local: local(p)) }

    /// The SIGNED distance to the mid-surface (f / |∇f|, mm): core's sheet_mid_distance_at.
    public func midDistance(_ p: SIMD3<Double>) -> Double {
        guard cellMM > 0 else { return .infinity }
        let q = local(p)
        let v = Self.eval(kind, q.x - anchor.x, q.y - anchor.y, q.z - anchor.z, cellMM)
        let g = simd_length(v.g)
        if !(g > 1e-12) { return cellMM }
        return v.f / g
    }

    /// The field's own function in mm (f × L / 2π) and its gradient in the part's axes: what the blend mixes (core's raw_at,
    /// sheet_blend.cpp, builder E).
    public func raw(_ p: SIMD3<Double>) -> (g: Double, grad: SIMD3<Double>) {
        guard cellMM > 0 else { return (0, .zero) }
        let q = local(p)
        let v = Self.eval(kind, q.x - anchor.x, q.y - anchor.y, q.z - anchor.z, cellMM)
        let k = cellMM / (2 * Double.pi)
        return (v.f * k, k * (v.g.x * ax[0] + v.g.y * ax[1] + v.g.z * ax[2]))
    }

    // MARK: the bridge's flat form

    /// The contract's SheetsFlat (LatticeLayoutResult's sheet_* vectors), one field after another; malformed entries are left
    /// out (never a crash on a short vector).
    public static func unflatten(region: [Int32], frame: [Int32], kind: [UInt8], axes: [Float], anchor: [Float], cellMM: [Float],
                                 n: [Int32], lo: [Float], wallCount: [Int32], wallMM: [Float], wallRange: [Float],
                                 seamAB: [Int32], seamBandMM: [Float], seamRaiseMM: [Float], seamSolid: [UInt8],
                                 seamFellBack: [UInt8], seamWhy: [String]) -> ([LatticeSheetField], [LatticeSheetSeam]) {
        var fields: [LatticeSheetField] = []
        var at = 0
        for i in 0..<region.count {
            guard i < frame.count, i < kind.count, 12 * i + 11 < axes.count, 3 * i + 2 < anchor.count, i < cellMM.count,
                  3 * i + 2 < n.count, 3 * i + 2 < lo.count, i < wallCount.count else { break }
            let c = Int(wallCount[i])
            guard c >= 1, at + c <= wallMM.count else { break }
            func v3(_ a: [Float], _ k: Int) -> SIMD3<Double> { SIMD3(Double(a[k]), Double(a[k + 1]), Double(a[k + 2])) }
            var f = LatticeSheetField(region: region[i], frame: frame[i], kind: Kind(rawValue: kind[i]) ?? .gyroid,
                                      origin: v3(axes, 12 * i), ax: [v3(axes, 12 * i + 3), v3(axes, 12 * i + 6), v3(axes, 12 * i + 9)],
                                      anchor: v3(anchor, 3 * i), cellMM: Double(cellMM[i]),
                                      n: SIMD3(n[3 * i], n[3 * i + 1], n[3 * i + 2]), lo: v3(lo, 3 * i),
                                      wallMM: Array(wallMM[at..<(at + c)]))
            if 2 * i + 1 < wallRange.count { f.wallMinMM = Double(wallRange[2 * i]); f.wallMaxMM = Double(wallRange[2 * i + 1]) }
            fields.append(f)
            at += c
        }
        var seams: [LatticeSheetSeam] = []
        for j in 0..<(seamAB.count / 2) {
            seams.append(LatticeSheetSeam(a: Int(seamAB[2 * j]), b: Int(seamAB[2 * j + 1]),
                                          bandMM: j < seamBandMM.count ? Double(seamBandMM[j]) : 0,
                                          raiseMM: j < seamRaiseMM.count ? Double(seamRaiseMM[j]) : 0,
                                          solidWall: j < seamSolid.count ? seamSolid[j] != 0 : true,
                                          fellBack: j < seamFellBack.count ? seamFellBack[j] != 0 : false,
                                          why: j < seamWhy.count ? seamWhy[j] : ""))
        }
        return (fields, seams)
    }
}

/// One pair of laid sheet regions that touch (core's SheetSeamBand): its two fields (indices into the result's `sheets`), the
/// blend band's width, how much the band's loop raised the wall, and whether it is made as the solid wall (asked, or a Blend
/// that fell back — `why` is then core's one plain line for the pop-up).
public struct LatticeSheetSeam: Sendable, Equatable {
    public var a: Int, b: Int
    public var bandMM: Double
    public var raiseMM: Double
    public var solidWall: Bool
    public var fellBack: Bool
    public var why: String
    public init(a: Int, b: Int, bandMM: Double, raiseMM: Double = 0, solidWall: Bool, fellBack: Bool = false, why: String = "") {
        self.a = a; self.b = b; self.bandMM = bandMM; self.raiseMM = raiseMM; self.solidWall = solidWall; self.fellBack = fellBack
        self.why = why
    }

    /// The blend's weight across a seam (core's sheet_seam_weight): smoothstep from 0 at −band/2 (a's side) to 1 at +band/2.
    public static func weight(seamMM: Double, bandMM: Double) -> Double {
        if !(bandMM > 0) { return seamMM >= 0 ? 1 : 0 }
        let t = Swift.min(Swift.max((seamMM + 0.5 * bandMM) / bandMM, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The weight's slope across the seam, per mm (core's seam_weight_slope).
    public static func slope(seamMM: Double, bandMM: Double) -> Double {
        guard bandMM > 0 else { return 0 }
        let x = (seamMM + 0.5 * bandMM) / bandMM
        guard x > 0, x < 1 else { return 0 }
        return 6 * x * (1 - x) / bandMM
    }

    /// How much of the band's raise a point gets (core's sheet_seam_bump, builder E): (4 x (1 − x))², x the place across the
    /// band from 0 (a's edge) to 1 (b's edge): 1 in its middle, 0 with no slope at both edges.
    public static func bump(seamMM: Double, bandMM: Double) -> Double {
        if !(bandMM > 0) { return 0 }
        let x = Swift.min(Swift.max((seamMM + 0.5 * bandMM) / bandMM, 0), 1)
        let q = 4 * x * (1 - x)
        return q * q
    }

    /// The blended mid-surface distance (core's blend_mid): the two fields' own functions mixed, φ = (1 − s) g_a + s g_b, over
    /// the length of φ's own gradient, (1 − s) ∇g_a + s ∇g_b + (g_b − g_a) ∇s; at s = 0 it is a's midDistance, at s = 1 b's.
    public static func blendMid(_ a: LatticeSheetField, _ b: LatticeSheetField, s: Double, gradS: SIMD3<Double>,
                                _ p: SIMD3<Double>) -> Double {
        let ra = s < 1 ? a.raw(p) : (0, .zero), rb = s > 0 ? b.raw(p) : (0, .zero)
        let phi = (1 - s) * ra.g + s * rb.g
        let G = (1 - s) * ra.grad + s * rb.grad + (rb.g - ra.g) * gradS
        return phi / Swift.max(simd_length(G), gradFloor)
    }
    /// core's kBlendGradFloor: the mix's gradient is read no shorter (at a neck the wall is only thicker; a region's own sheet,
    /// whose gradient there is never under √2, is unchanged).
    public static let gradFloor = 0.5

    /// THE BLENDED FIELD (core's sheet_blend_distance_at, builder E's form): F = blendMid (the two fields' own functions mixed
    /// by the smoothstep, over the mix's own gradient), the wall where |F| is under half the blended parameter, (1 − s) t_a +
    /// s t_b + the band's raise × its bump. mm, negative inside the wall. `seamMM`: the signed distance across the seam at p,
    /// + toward b (the map's channel); `seamGrad` its gradient.
    public static func blendDistance(_ a: LatticeSheetField, _ b: LatticeSheetField, seam: LatticeSheetSeam, seamMM: Double,
                                     seamGrad: SIMD3<Double> = .zero, _ p: SIMD3<Double>) -> Double {
        let s = weight(seamMM: seamMM, bandMM: seam.bandMM)
        let F = blendMid(a, b, s: s, gradS: slope(seamMM: seamMM, bandMM: seam.bandMM) * seamGrad, p)
        let ta = s < 1 ? a.paramAt(p) : 0, tb = s > 0 ? b.paramAt(p) : 0
        let t = (1 - s) * ta + s * tb + seam.raiseMM * bump(seamMM: seamMM, bandMM: seam.bandMM)
        return abs(F) - 0.5 * t
    }
}

/// ★ SHEETS: the wall law, read from core once per type (LatticeLayoutBridge.hpp, lattice_layout_sheet_param_table): the field
/// parameter over the cell at `steps + 1` walls over the cell from 0 to `maxShare` (past the widest wall any sheet lays: the
/// touch is 0.4330 of the cell for the gyroid, 0.3507 for Schwarz-D). Linear between samples, linear through the origin past
/// the last (core's own law is linear through the origin past its last row). The shader reads the same table.
public enum LatticeSheetLaw {
    public static let steps = 512
    public static let maxShare = 0.5

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var tables: [LatticeSheetField.Kind: [Double]] = [:]
    }
    private static let cache = Cache()

    /// The table for `kind` (cached: core's law never changes while the app runs). Empty: core gave none.
    public static func table(_ kind: LatticeSheetField.Kind) -> [Double] {
        if let hit = cache.lock.withLock({ cache.tables[kind] }) { return hit }
        let t = Array(topoptbridge.lattice_layout_sheet_param_table(std.string(kind.id), Int32(steps), maxShare))
        if t.count == steps + 1 { cache.lock.withLock { cache.tables[kind] = t } }
        return t
    }

    /// The parameter (mm) for a TRUE wall (mm) in a cell (mm). 0 for no wall.
    public static func param(_ kind: LatticeSheetField.Kind, wallMM: Double, cellMM: Double) -> Double {
        guard wallMM > 0, cellMM > 0 else { return 0 }
        let t = table(kind)
        guard t.count == steps + 1 else { return wallMM }   // no table: the wall itself (core's law is within 2 % of it)
        let u = wallMM / cellMM
        let x = u / maxShare * Double(steps)
        if x >= Double(steps) { return t[steps] / maxShare * u * cellMM }
        let i = Int(x.rounded(.down)), f = x - Double(i)
        return (t[i] + f * (t[i + 1] - t[i])) * cellMM
    }
}

/// ★ SHEETS: sheet_cells.bin as core read it (LatticeLayoutSession.sheetCells): per cell its region, frame (index into the
/// file's frames, the part's model frame), the cube's low corner (frame mm) and size, its wall, the cells across the member
/// there (0: not read), the check's margin (NaN: not judged) and core's flags (SheetCellRecord's bits).
public struct LatticeSheetCells: Sendable, Equatable {
    public var frames: [Float]
    public var region: [Int32]
    public var frame: [Int32]
    public var lo: [Float]
    public var sizeMM: [Float]
    public var wallMM: [Float]
    public var cellsAcross: [Float]
    public var margin: [Float]
    public var flags: [UInt32]
    public var count: Int { region.count }
    /// core's SheetCellRecord flags
    public static let credited: UInt32 = 1, cut: UInt32 = 2, blendBand: UInt32 = 4, outOfBand: UInt32 = 8,
                      underFloor: UInt32 = 16, membrane: UInt32 = 32
    public init(frames: [Float], region: [Int32], frame: [Int32], lo: [Float], sizeMM: [Float], wallMM: [Float],
                cellsAcross: [Float], margin: [Float], flags: [UInt32]) {
        self.frames = frames; self.region = region; self.frame = frame; self.lo = lo; self.sizeMM = sizeMM; self.wallMM = wallMM
        self.cellsAcross = cellsAcross; self.margin = margin; self.flags = flags
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.frames == b.frames && a.region == b.region && a.frame == b.frame && a.lo == b.lo && a.sizeMM == b.sizeMM
            && a.wallMM == b.wallMM && a.cellsAcross == b.cellsAcross && a.flags == b.flags
            && zip(a.margin, b.margin).allSatisfy { $0 == $1 || ($0.isNaN && $1.isNaN) } && a.margin.count == b.margin.count
    }

    /// The cell whose cube holds `p` (part mm, within `tol`), the smallest when cubes overlap; nil when none does.
    public func cell(at p: SIMD3<Float>, tol: Float = 1e-3) -> Int? {
        var best: Int?
        for c in 0..<count {
            let f = Int(frame[c]), k = 12 * f
            guard k + 11 < frames.count, 3 * c + 2 < lo.count else { continue }
            let d = p - SIMD3(frames[k], frames[k + 1], frames[k + 2])
            let q = SIMD3(simd_dot(d, SIMD3(frames[k + 3], frames[k + 4], frames[k + 5])),
                          simd_dot(d, SIMD3(frames[k + 6], frames[k + 7], frames[k + 8])),
                          simd_dot(d, SIMD3(frames[k + 9], frames[k + 10], frames[k + 11])))
            let l = SIMD3(lo[3 * c], lo[3 * c + 1], lo[3 * c + 2]), s = sizeMM[c]
            guard q.x >= l.x - tol, q.y >= l.y - tol, q.z >= l.z - tol,
                  q.x <= l.x + s + tol, q.y <= l.y + s + tol, q.z <= l.z + s + tol else { continue }
            if best.map({ sizeMM[$0] > s }) ?? true { best = c }
        }
        return best
    }
}

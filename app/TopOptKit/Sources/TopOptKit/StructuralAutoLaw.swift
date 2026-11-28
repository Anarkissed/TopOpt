// StructuralAutoLaw — ★ notes30 SA1 (Structural Auto, REMOVE.md): the strength check's strut law, through the bridge, for the
// app's Structural Auto (its thickening reads the law the Mac's check judges a cell by). Its own file, so taking Structural
// Auto out is deleting it.
import Foundation
import TopOptBridge

extension TopOptKit {
    /// The strut law TURNED ROUND over a whole stress field (core's `strut_size_field`): per voxel,
    /// the lightest strut / cell whose law margin reaches `target` — the law the Mac's strength check judges a cell by.
    public struct StrutSizeField: Sendable, Equatable {
        public var ratio: [Float]        // strut / cell, per voxel
        public var rho: [Float]          // its density, per voxel
        public var short: [UInt8]        // 1: even the densest the law covers is short of the target there
        public var loaded = 0, atFloor = 0, shortOfTarget = 0
        public var rhoFloor = 0.0, rhoCeiling = 0.0, ratioFloor = 0.0, ratioCeiling = 0.0, highestRatio = 0.0
        public var touch = 0.0, openLook = 0.0   // the type's, strut / cell
        public init(ratio: [Float], rho: [Float], short: [UInt8]) { self.ratio = ratio; self.rho = rho; self.short = short }
    }
    /// nil with core's reason in `latticeLastRefusal` (an unknown type, one with no law, a bad material or field).
    public static func latticeStrutSizeField(topology: String, tensor: [Double], buildUp: SIMD3<Double>, yieldMPa: Double,
                                             zKnockdown: Double, target: Double) -> StrutSizeField? {
        guard tensor.count % 6 == 0, !tensor.isEmpty else { return nil }
        let n = tensor.count / 6
        var ratio = [Float](repeating: 0, count: n), rho = [Float](repeating: 0, count: n)
        var short = [UInt8](repeating: 0, count: n)
        let s = tensor.withUnsafeBufferPointer { tb in
            ratio.withUnsafeMutableBufferPointer { rb in
                rho.withUnsafeMutableBufferPointer { hb in
                    short.withUnsafeMutableBufferPointer { sb in
                        topoptbridge.lattice_strut_size_field(std.string(topology), tb.baseAddress, tensor.count,
                                                              buildUp.x, buildUp.y, buildUp.z, yieldMPa, zKnockdown, target,
                                                              rb.baseAddress, hb.baseAddress, sb.baseAddress)
                    }
                }
            }
        }
        guard s.ok else { return nil }
        var out = StrutSizeField(ratio: ratio, rho: rho, short: short)
        out.loaded = Int(s.loaded); out.atFloor = Int(s.at_floor); out.shortOfTarget = Int(s.short_of_target)
        out.rhoFloor = s.rho_floor; out.rhoCeiling = s.rho_ceiling
        out.ratioFloor = s.ratio_floor; out.ratioCeiling = s.ratio_ceiling; out.highestRatio = s.highest_ratio
        out.touch = s.touch; out.openLook = s.open_look
        return out
    }
    /// The law's margin at one voxel and density (core's `strut_law_margin_at`, the check's own formula); 0 refused.
    public static func latticeStrutLawMargin(topology: String, rho: Double, vonMisesMPa: Double, pressureMPa: Double,
                                             buildUp: SIMD3<Double>, yieldMPa: Double, zKnockdown: Double) -> Double {
        topoptbridge.lattice_strut_law_margin(std.string(topology), rho, vonMisesMPa, pressureMPa, buildUp.x, buildUp.y,
                                              buildUp.z, yieldMPa, zKnockdown)
    }
}

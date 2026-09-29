// FlexibleKit — Swift wrappers over the Flexible stage's bridge (task
// 2026-09-29-flexible-screens, A1; bridge in FlexibleBridge.hpp).
//
// ★ ONE DEFINITION (M9, DECISIONS 2026-09-27 item 4). These types CARRY core's numbers;
// nothing here evaluates a curve, a frame, a lookup or a smoothing. A value the data
// does not cover arrives as a `FlexRefusal` (core's code + sentence), never as a number.
import Foundation
import simd
import TopOptBridge

// MARK: - value types

/// Core's "the data does not cover this": a stable code and one plain sentence.
public struct FlexRefusal: Equatable, Sendable, Codable {
    public let code: String
    public let reason: String
    public init(code: String, reason: String) { self.code = code; self.reason = reason }
    static func of(_ code: std.string, _ reason: std.string) -> FlexRefusal? {
        let c = String(code)
        return c.isEmpty ? nil : FlexRefusal(code: c, reason: String(reason))
    }
}

/// One filament from flexible_materials.json.
public struct FlexMaterialInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let family: String
    /// literature | proxy_candidate | calibrate_first
    public let tier: String
    public let foaming: Bool
    public let shoreA: Double?
    public let nozzleRangeC: ClosedRange<Double>?
    /// ★ R10: the only temperatures to offer. Empty ⇒ predicts nothing.
    public let testedTempsC: [Double]
    public let offeredTempsNote: String
    public let note: String
    public let sources: [String]
    /// Why this filament predicts nothing (calibrate_first / proxy_candidate), in core's words.
    public let noPrediction: FlexRefusal?
}

public struct FlexErrorBandsInfo: Equatable, Sendable {
    public let literature: Double
    public let calibrated: Double
    public let proxy: Double
    public let status: String
    public let note: String
}

public struct FlexCurveSetInfo: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let coreDensity: Double
        public let entryID: String
        public let source: String
    }
    public let refusal: FlexRefusal?
    public let densityMin: Double
    public let densityMax: Double
    /// The last tabulated strain (the end of "measured").
    public let strainMeasuredMax: Double
    /// Beyond this: refused (R8).
    public let strainLimit: Double
    public let densityBasis: String
    public let tier: String
    public let strainConvention: String
    public let rows: [Row]
}

public struct FlexStressResult: Equatable, Sendable {
    public let ok: Bool
    public let stressMPa: Double
    public let extrapolated: Bool
    public let refusal: FlexRefusal?
}

public struct FlexInverseResult: Equatable, Sendable {
    public let ok: Bool
    /// ok | too_firm | too_soft | beyond_data | no_pressure (or a curve-set refusal code)
    public let status: String
    public let coreDensity: Double
    public let extrapolated: Bool
    public let nearestDensity: Double
    public let nearestStrain: Double
    public let nearestKnown: Bool
    public let refusal: FlexRefusal?
}

public struct FlexStrainResult: Equatable, Sendable {
    public let ok: Bool
    public let strain: Double
    public let extrapolated: Bool
    public let refusal: FlexRefusal?
}

/// One point of σ(ε), sampled by core. `stressMPa == nil` ⇒ past the data: no number.
public struct FlexCurveSample: Equatable, Sendable {
    public let strain: Double
    public let stressMPa: Double?
    public let extrapolated: Bool
}

/// F10: the tier and ± band every squish number carries (R7).
public struct FlexTier: Equatable, Sendable {
    public let tier: String
    public let band: Double
    public let why: String
}

/// A pen curve's control points (x strictly increasing, 0 → 1; y ∈ [0, 1]).
public struct FlexCurve: Equatable, Sendable, Codable, Hashable {
    public var x: [Double]
    public var y: [Double]
    public init(x: [Double], y: [Double]) { self.x = x; self.y = y }
    /// A curve at full squish everywhere — the stand-in for a curve the mode does not read.
    public static let flat = FlexCurve(x: [0, 1], y: [1, 1])
}

/// A face's squish map: mode + curves + deepest squish (02 §12).
public struct FlexMap: Equatable, Sendable, Codable, Hashable {
    /// both | either | centre_edge
    public var mode: String
    public var x: FlexCurve
    public var y: FlexCurve
    public var centreEdge: FlexCurve
    public var deepestMM: Double
    public init(mode: String, x: FlexCurve, y: FlexCurve, centreEdge: FlexCurve, deepestMM: Double) {
        self.mode = mode; self.x = x; self.y = y; self.centreEdge = centreEdge; self.deepestMM = deepestMM
    }
}

public struct FlexBuildParams: Equatable, Sendable, Hashable {
    public var topology: String
    public var beadsPerWall: Int
    public var beadWidthMM: Double
    public init(topology: String, beadsPerWall: Int, beadWidthMM: Double) {
        self.topology = topology; self.beadsPerWall = beadsPerWall; self.beadWidthMM = beadWidthMM
    }
}

/// A stamp's pressure grid in the face frame's (u, v) mm (M14). The APP rasterises it.
public struct FlexStamp: Equatable, Sendable, Codable, Hashable {
    public var name: String
    public var originU: Double
    public var originV: Double
    public var cellMM: Double
    public var nu: Int
    public var nv: Int
    /// nu*nv, row-major in v (index iv*nu + iu), MPa.
    public var valuesMPa: [Double]
    public var forceN: Double
    public var rigid: Bool
    public init(name: String, originU: Double, originV: Double, cellMM: Double, nu: Int, nv: Int,
                valuesMPa: [Double], forceN: Double, rigid: Bool) {
        self.name = name; self.originU = originU; self.originV = originV; self.cellMM = cellMM
        self.nu = nu; self.nv = nv; self.valuesMPa = valuesMPa; self.forceN = forceN; self.rigid = rigid
    }
}

public struct FlexLink: Equatable, Sendable {
    public let id: Int
    public let fraction: Double
}

public struct FlexColumn: Equatable, Sendable {
    public let iu: Int, iv: Int
    public let uMM: Double, vMM: Double
    public let areaMM2: Double
    public let entryT: Double, exitT: Double
    public let latticeMM: Double
    public let exitFace: Int
}

/// A loaded face's frame and stack (F5), exactly as core built them.
public struct FlexStackInfo: Equatable, Sendable {
    public let frameValid: Bool
    public let frameReason: String
    public let load: SIMD3<Double>
    public let xAxis: SIMD3<Double>
    public let yAxis: SIMD3<Double>
    public let centroid: SIMD3<Double>
    public let rotationDeg: Int
    public let uMin: Double, vMin: Double
    public let uExtentMM: Double, vExtentMM: Double
    public let areaMM2: Double, projectedAreaMM2: Double
    public let normalSpreadDeg: Double
    public let normalSpreadFlag: Bool
    public let buildAngleDeg: Double
    /// > 15° from build Z: gyroid only, "estimated" (M12, R6)
    public let side: Bool
    public let principalAxisTied: Bool
    public let pitchMM: Double
    public let nu: Int, nv: Int
    public let cell: [Int]
    public let columns: [FlexColumn]
    /// The linked other end (M13).
    public let exitFaces: [FlexLink]
    public let exitRegions: [FlexLink]
    public let exitUnresolvedFraction: Double
    public let footprintAreaMM2: Double
    public let latticedColumns: Int
    public let latticeMMMin: Double, latticeMMMean: Double, latticeMMMax: Double
    public let stackMMMax: Double
}

public struct FlexColumnDesign: Equatable, Sendable {
    public let s: Double
    public let pressureMPa: Double
    public let heightMM: Double
    public let targetDepthMM: Double
    public let targetStrain: Double
    /// ok | too_firm | too_soft | beyond_data | no_lattice
    public let status: String
    public let targetExtrapolated: Bool
    public let targetDensity: Double
    /// nil = unknown (core's NaN, H1)
    public let nearestDepthMM: Double?
    public let nearestKnown: Bool
    public let clampedDensity: Double
    public let clampedDepthMM: Double?
    public let buildableDensity: Double
    public let buildableDepthMM: Double
    public let buildableOK: Bool
    public let buildableExtrapolated: Bool
    public let cellMM: Double
    public let sigmaMM: Double
}

public struct FlexFaceDesignInfo: Equatable, Sendable {
    public let refusal: FlexRefusal?
    public let columns: [FlexColumnDesign]
    public let tier: FlexTier
    public let ok: Int, tooFirm: Int, tooSoft: Int, beyondData: Int, noLattice: Int
    public let solidUnderMap: Int
    public let targetExtrapolated: Int, buildableExtrapolated: Int, buildableBeyondData: Int
    public let nearEdge: Int
    public let designPressureEvenMPa: Double
    public let designStampUsed: Bool
    public let designStampRigidAveraged: Bool
    public let designStampOffFace: Bool
    public let designStampOffFaceN: Double
    public let maxSmoothingChangeMM: Double
    public let materialVolumeMM3: Double
    public let targetDepthRange: ClosedRange<Double>?
    public let buildableDepthRange: ClosedRange<Double>?
    public let buildableDensityRange: ClosedRange<Double>?
    public let cellRange: ClosedRange<Double>?
    public let sigmaRange: ClosedRange<Double>?
    /// Columns clamped because the table cannot reach the drawn squish.
    public var clamped: Int { tooFirm + tooSoft + beyondData }
}

public struct FlexStampCheckInfo: Equatable, Sendable {
    public let ok: Bool
    public let refusal: FlexRefusal?
    /// per column; nil where the stamp does not press
    public let depthMM: [Double?]
    public let status: [String]
    public let pressedColumns: Int, extrapolatedColumns: Int, beyondDataColumns: Int
    public let rigidUnlatticedColumns: Int
    public let maxDepthMM: Double
    public let rigidDepthMM: Double
    public let stampWidthMM: Double
    public let localCellMM: Double
    public let narrow: Bool
    public let forceOffFaceN: Double
    public let offFace: Bool
    public let tier: FlexTier
}

public struct FlexConflictInfo: Equatable, Sendable {
    public let faceA: Int, faceB: Int
    public let overlapMM3: Double
    public let axisAngleDeg: Double
}

public struct FlexHandover: Equatable, Sendable {
    public let faceA: Int, faceB: Int
    public let overlapMM3: Double, blendedMM3: Double
}

/// One axis-aligned slice of core's density field (−1 not lattice, 0 lattice under no
/// loaded stack, else ρ) and its owner map (C1 problem #3).
public struct FlexFieldSliceInfo: Equatable, Sendable {
    public let width: Int, height: Int
    public let spacing: Double
    public let density: [Double]
    public let owner: [Int]
    public let latticeVoxels: Int, assignedVoxels: Int, unassignedVoxels: Int
    public let handovers: [FlexHandover]
}

public struct FlexFaceRequest: Equatable, Sendable {
    public var face: Int
    public var rotation: Int
    public var map: FlexMap
    public var weightN: Double
    public var stamp: FlexStamp?
    public init(face: Int, rotation: Int, map: FlexMap, weightN: Double, stamp: FlexStamp?) {
        self.face = face; self.rotation = rotation; self.map = map; self.weightN = weightN; self.stamp = stamp
    }
}

public struct FlexReason: Equatable, Sendable {
    public let code: String
    public let text: String
    public let face: Int?
}

public struct FlexCandidate: Equatable, Sendable {
    public let topology: String
    public let tempC: Double
    public let eligible: Bool
    public let hasData: Bool
    public let reachable: Bool
    public let unreachableColumns: Int
    public let nearEdgeColumns: Int
    public let massG: Double?
    public let refusal: FlexRefusal?
}

public struct FlexFailure: Equatable, Sendable {
    public let face: Int
    public let text: String
    public let uRangeMM: ClosedRange<Double>
    public let vRangeMM: ClosedRange<Double>
    /// nil when the nearest achievable squish is itself past the data
    public let nearestDepthRangeMM: ClosedRange<Double>?
    public let tooFirm: Int, tooSoft: Int, beyondData: Int
}

public struct FlexRecommendationInfo: Equatable, Sendable {
    public let chosen: Bool
    public let reachable: Bool
    public let topology: String
    public let tempC: Double
    public let feel: String
    public let sentence: String
    public let reasons: [FlexReason]
    public let candidates: [FlexCandidate]
    public let failures: [FlexFailure]
}

public struct FlexJobFaceInfo: Equatable, Sendable {
    public let faceRegionID: Int
    public let role: String
    public let rotationDeg: Int
    public let weightN: Double
    public let deepestMM: Double
    public let map: FlexMap
    public let designStamp: FlexStamp?
    public let skinOn: Bool
}

public struct FlexJobBlockInfo: Equatable, Sendable {
    public let materialID: String
    public let nozzleTempAuto: Bool
    public let nozzleTempC: Double
    public let topology: String
    public let feel: String
    public let beadsPerWall: Int
    public let minExtrudableWidthMM: Double
    public let regionCount: Int
    public let faces: [FlexJobFaceInfo]
    public let checkStamps: [(face: Int, stamp: FlexStamp)]
    public static func == (a: Self, b: Self) -> Bool {
        a.materialID == b.materialID && a.nozzleTempAuto == b.nozzleTempAuto
            && a.nozzleTempC == b.nozzleTempC && a.topology == b.topology && a.feel == b.feel
            && a.beadsPerWall == b.beadsPerWall && a.minExtrudableWidthMM == b.minExtrudableWidthMM
            && a.regionCount == b.regionCount && a.faces == b.faces
            && a.checkStamps.map(\.face) == b.checkStamps.map(\.face)
            && a.checkStamps.map(\.stamp) == b.checkStamps.map(\.stamp)
    }
}

// MARK: - conversions

enum FlexConv {
    static func d(_ v: [Double]) -> topoptbridge.FlexDoubles {
        var o = topoptbridge.FlexDoubles()
        o.reserve(v.count)
        for x in v { o.push_back(x) }
        return o
    }
    static func i(_ v: [Int]) -> topoptbridge.FlexInts {
        var o = topoptbridge.FlexInts()
        for x in v { o.push_back(Int32(x)) }
        return o
    }
    static func s(_ v: [String]) -> topoptbridge.FlexStrings {
        var o = topoptbridge.FlexStrings()
        for x in v { o.push_back(std.string(x)) }
        return o
    }
    static func v3(_ t: (Double, Double, Double)) -> SIMD3<Double> { SIMD3(t.0, t.1, t.2) }
    static func range(_ lo: Double, _ hi: Double) -> ClosedRange<Double>? {
        (lo.isFinite && hi.isFinite && lo <= hi) ? lo...hi : nil
    }
    static func stamp(_ s: FlexStamp?) -> topoptbridge.FlexStampGrid {
        var g = topoptbridge.FlexStampGrid()
        guard let s else { return g }
        g.present = true
        g.name = std.string(s.name)
        g.origin_u_mm = s.originU
        g.origin_v_mm = s.originV
        g.cell_mm = s.cellMM
        g.nu = Int32(s.nu)
        g.nv = Int32(s.nv)
        g.values_mpa = d(s.valuesMPa)
        g.force_n = s.forceN
        g.rigid = s.rigid
        return g
    }
    static func stamp(_ g: topoptbridge.FlexStampGrid) -> FlexStamp? {
        guard g.present else { return nil }
        return FlexStamp(name: String(g.name), originU: g.origin_u_mm, originV: g.origin_v_mm,
                         cellMM: g.cell_mm, nu: Int(g.nu), nv: Int(g.nv),
                         valuesMPa: Array(g.values_mpa), forceN: g.force_n, rigid: g.rigid)
    }
    static func map(_ m: FlexMap) -> topoptbridge.FlexSquishMap {
        var o = topoptbridge.FlexSquishMap()
        o.mode = std.string(m.mode)
        o.x_x = d(m.x.x); o.x_y = d(m.x.y)
        o.y_x = d(m.y.x); o.y_y = d(m.y.y)
        o.c_x = d(m.centreEdge.x); o.c_y = d(m.centreEdge.y)
        o.deepest_squish_mm = m.deepestMM
        return o
    }
    static func build(_ b: FlexBuildParams) -> topoptbridge.FlexBuild {
        var o = topoptbridge.FlexBuild()
        o.topology = std.string(b.topology)
        o.beads_per_wall = Int32(b.beadsPerWall)
        o.bead_width_mm = b.beadWidthMM
        return o
    }
    static func check(_ e: topoptbridge.BridgeError) throws {
        if !e.ok { throw TopOptError(message: String(e.message)) }
    }
}

// MARK: - stateless calls

/// The Flexible stage's core calls that need no part (F1, F3, F4, F8, F10, F11).
public enum FlexibleCore {

    public static func materials(path: String) throws -> [FlexMaterialInfo] {
        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.flexible_materials(std.string(path), &err)
        try FlexConv.check(err)
        return raw.map { m in
            FlexMaterialInfo(
                id: String(m.id), displayName: String(m.display_name), family: String(m.family),
                tier: String(m.tier), foaming: m.foaming,
                shoreA: m.shore_a_known ? m.shore_a : nil,
                nozzleRangeC: m.nozzle_range_known ? m.nozzle_range_lo...max(m.nozzle_range_lo, m.nozzle_range_hi) : nil,
                testedTempsC: Array(m.tested_temps_c), offeredTempsNote: String(m.offered_temps_note),
                note: String(m.note), sources: m.sources.map { String($0) },
                noPrediction: FlexRefusal.of(m.no_prediction_code, m.no_prediction_reason))
        }
    }

    public static func errorBands(path: String) throws -> FlexErrorBandsInfo {
        var err = topoptbridge.BridgeError()
        let b = topoptbridge.flexible_error_bands(std.string(path), &err)
        try FlexConv.check(err)
        return FlexErrorBandsInfo(literature: b.literature, calibrated: b.calibrated, proxy: b.proxy,
                                  status: String(b.status), note: String(b.note))
    }

    public static func temperatureNote(path: String, materialID: String, tempC: Double) throws -> String {
        var err = topoptbridge.BridgeError()
        let s = topoptbridge.flexible_temperature_note(std.string(path), std.string(materialID), tempC, &err)
        try FlexConv.check(err)
        return String(s)
    }

    public static func penCurveError(x: [Double], y: [Double]) -> String {
        String(topoptbridge.flexible_pen_curve_error(FlexConv.d(x), FlexConv.d(y)))
    }

    public static func penCurveValues(x: [Double], y: [Double], t: [Double]) throws -> [Double] {
        var err = topoptbridge.BridgeError()
        let v = topoptbridge.flexible_pen_curve_values(FlexConv.d(x), FlexConv.d(y), FlexConv.d(t), &err)
        try FlexConv.check(err)
        return Array(v)
    }

    public static func curveSet(path: String, materialID: String, tempC: Double,
                                topology: String) throws -> FlexCurveSetInfo {
        var err = topoptbridge.BridgeError()
        let s = topoptbridge.flexible_curve_set(std.string(path), std.string(materialID), tempC,
                                                std.string(topology), &err)
        try FlexConv.check(err)
        var rows: [FlexCurveSetInfo.Row] = []
        for k in 0..<s.row_density.count {
            rows.append(.init(coreDensity: s.row_density[k], entryID: String(s.row_entry_id[k]),
                              source: String(s.row_source[k])))
        }
        return FlexCurveSetInfo(
            refusal: s.refused ? FlexRefusal(code: String(s.refusal_code), reason: String(s.refusal_reason)) : nil,
            densityMin: s.density_min, densityMax: s.density_max,
            strainMeasuredMax: s.strain_measured_max, strainLimit: s.strain_limit,
            densityBasis: String(s.density_basis), tier: String(s.tier),
            strainConvention: String(s.strain_convention), rows: rows)
    }

    public static func stressAt(path: String, materialID: String, tempC: Double, topology: String,
                                strain: Double, density: Double) throws -> FlexStressResult {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_stress_at(std.string(path), std.string(materialID), tempC,
                                                std.string(topology), strain, density, &err)
        try FlexConv.check(err)
        return FlexStressResult(ok: r.ok, stressMPa: r.stress_mpa, extrapolated: r.extrapolated,
                                refusal: FlexRefusal.of(r.refusal_code, r.refusal_reason))
    }

    public static func densityFor(path: String, materialID: String, tempC: Double, topology: String,
                                  targetStrain: Double, pressureMPa: Double) throws -> FlexInverseResult {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_density_for(std.string(path), std.string(materialID), tempC,
                                                  std.string(topology), targetStrain, pressureMPa, &err)
        try FlexConv.check(err)
        return FlexInverseResult(ok: r.ok, status: String(r.status), coreDensity: r.core_density,
                                 extrapolated: r.extrapolated, nearestDensity: r.nearest_density,
                                 nearestStrain: r.nearest_strain, nearestKnown: r.nearest_known,
                                 refusal: FlexRefusal.of(r.refusal_code, r.refusal_reason))
    }

    public static func strainUnder(path: String, materialID: String, tempC: Double, topology: String,
                                   pressureMPa: Double, density: Double) throws -> FlexStrainResult {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_strain_under(std.string(path), std.string(materialID), tempC,
                                                   std.string(topology), pressureMPa, density, &err)
        try FlexConv.check(err)
        return FlexStrainResult(ok: r.ok, strain: r.strain, extrapolated: r.extrapolated,
                                refusal: FlexRefusal.of(r.refusal_code, r.refusal_reason))
    }

    public static func curveSamples(path: String, materialID: String, tempC: Double,
                                    topology: String, density: Double,
                                    strains: [Double]) throws -> [FlexCurveSample] {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_curve_samples(std.string(path), std.string(materialID), tempC,
                                                    std.string(topology), density, FlexConv.d(strains), &err)
        try FlexConv.check(err)
        return (0..<r.strain.count).map { k in
            FlexCurveSample(strain: r.strain[k], stressMPa: r.ok[k] != 0 ? r.stress_mpa[k] : nil,
                            extrapolated: r.extrapolated[k] != 0)
        }
    }

    public static func tierBand(path: String, setTier: String, side: Bool, beadsPerWall: Int) throws -> FlexTier {
        var err = topoptbridge.BridgeError()
        let t = topoptbridge.flexible_tier_band(std.string(path), std.string(setTier), side,
                                                Int32(beadsPerWall), &err)
        try FlexConv.check(err)
        return FlexTier(tier: String(t.tier), band: t.band, why: String(t.why))
    }

    public static func cellSizeMM(topology: String, density: Double, beadsPerWall: Int,
                                  beadWidthMM: Double) throws -> Double {
        var err = topoptbridge.BridgeError()
        let v = topoptbridge.flexible_cell_size_mm(std.string(topology), density, Int32(beadsPerWall),
                                                   beadWidthMM, &err)
        try FlexConv.check(err)
        return v
    }

    public static func stampError(_ s: FlexStamp) -> String {
        String(topoptbridge.flexible_stamp_grid_error(FlexConv.stamp(s)))
    }
    public static func stampForceN(_ s: FlexStamp) -> Double {
        topoptbridge.flexible_stamp_force_n(FlexConv.stamp(s))
    }
    public static func stampWidthMM(_ s: FlexStamp) -> Double {
        topoptbridge.flexible_stamp_width_mm(FlexConv.stamp(s))
    }

    /// The `flexible` block of `jobJSON`, read by core's own `parse_job` (F11).
    public static func parseJobBlock(_ jobJSON: String) throws -> FlexJobBlockInfo {
        var err = topoptbridge.BridgeError()
        let b = topoptbridge.flexible_parse_job_block(std.string(jobJSON), &err)
        try FlexConv.check(err)
        let faces = b.faces.map { f in
            FlexJobFaceInfo(
                faceRegionID: Int(f.face_region_id), role: String(f.role),
                rotationDeg: Int(f.frame_rotation_deg), weightN: f.weight_n,
                deepestMM: f.deepest_squish_mm,
                map: FlexMap(mode: String(f.mode),
                             x: FlexCurve(x: Array(f.x_x), y: Array(f.x_y)),
                             y: FlexCurve(x: Array(f.y_x), y: Array(f.y_y)),
                             centreEdge: FlexCurve(x: Array(f.c_x), y: Array(f.c_y)),
                             deepestMM: f.deepest_squish_mm),
                designStamp: FlexConv.stamp(f.design_stamp), skinOn: f.skin_on)
        }
        var checks: [(face: Int, stamp: FlexStamp)] = []
        for k in 0..<b.check_face_ids.count {
            if let s = FlexConv.stamp(b.check_stamps[k]) { checks.append((Int(b.check_face_ids[k]), s)) }
        }
        return FlexJobBlockInfo(
            materialID: String(b.material_id), nozzleTempAuto: b.nozzle_temp_auto,
            nozzleTempC: b.nozzle_temp_c, topology: String(b.topology), feel: String(b.feel),
            beadsPerWall: Int(b.beads_per_wall), minExtrudableWidthMM: b.min_extrudable_width_mm,
            regionCount: Int(b.region_count), faces: faces, checkStamps: checks)
    }
}

// MARK: - the scene

/// A part opened for the Flexible stage: model, voxel grid, lattice mask and face
/// regions, with each face's stack cached in core (they do not change while the user
/// draws). Thread-safe: the bridge serialises calls on one scene.
public final class FlexibleScene: @unchecked Sendable {
    public let handle: Int64

    public struct Info: Equatable, Sendable {
        public let nx: Int, ny: Int, nz: Int
        public let spacing: Double
        public let origin: SIMD3<Double>
        public let buildDir: SIMD3<Double>
        public let latticeVoxels: Int
        public let regions: [(id: Int, name: String, faces: [Int])]
        public static func == (a: Info, b: Info) -> Bool {
            a.nx == b.nx && a.ny == b.ny && a.nz == b.nz && a.spacing == b.spacing
                && a.latticeVoxels == b.latticeVoxels && a.regions.map(\.id) == b.regions.map(\.id)
        }
    }

    public init(jobJSON: String, jobDir: String) throws {
        var err = topoptbridge.BridgeError()
        handle = topoptbridge.flexible_scene_open(std.string(jobJSON), std.string(jobDir), &err)
        try FlexConv.check(err)
    }
    deinit { topoptbridge.flexible_scene_close(handle) }

    public func info() throws -> Info {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_scene_info(handle, &err)
        try FlexConv.check(err)
        var regions: [(id: Int, name: String, faces: [Int])] = []
        for k in 0..<r.region_ids.count {
            let a = Int(r.region_face_offsets[k]), b = Int(r.region_face_offsets[k + 1])
            regions.append((Int(r.region_ids[k]), String(r.region_names[k]),
                            (a..<b).map { Int(r.region_faces[$0]) }))
        }
        return Info(nx: Int(r.nx), ny: Int(r.ny), nz: Int(r.nz), spacing: r.spacing,
                    origin: FlexConv.v3(r.origin), buildDir: FlexConv.v3(r.build_dir),
                    latticeVoxels: Int(r.lattice_voxels), regions: regions)
    }

    public func stack(face: Int, rotation: Int) throws -> FlexStackInfo {
        var err = topoptbridge.BridgeError()
        let s = topoptbridge.flexible_scene_stack(handle, Int32(face), Int32(rotation), &err)
        try FlexConv.check(err)
        // ★ hoist every vector once: a C++ member read through Swift interop COPIES the
        // vector, so `s.col_u_mm[k]` in a loop copied 10,000 elements per column (3 s).
        let iu = Array(s.col_iu), iv = Array(s.col_iv), cu = Array(s.col_u_mm), cv = Array(s.col_v_mm)
        let ca = Array(s.col_area_mm2), ce = Array(s.col_entry_t), cx = Array(s.col_exit_t)
        let cl = Array(s.col_lattice_mm), cf = Array(s.col_exit_face)
        var cols: [FlexColumn] = []
        cols.reserveCapacity(cu.count)
        for k in 0..<cu.count {
            cols.append(FlexColumn(iu: Int(iu[k]), iv: Int(iv[k]), uMM: cu[k], vMM: cv[k], areaMM2: ca[k],
                                   entryT: ce[k], exitT: cx[k], latticeMM: cl[k], exitFace: Int(cf[k])))
        }
        let efi = Array(s.exit_face_ids), eff = Array(s.exit_face_fractions)
        let eri = Array(s.exit_region_ids), erf = Array(s.exit_region_fractions)
        let ef = (0..<efi.count).map { FlexLink(id: Int(efi[$0]), fraction: eff[$0]) }
        let er = (0..<eri.count).map { FlexLink(id: Int(eri[$0]), fraction: erf[$0]) }
        return FlexStackInfo(
            frameValid: s.frame_valid, frameReason: String(s.frame_reason),
            load: FlexConv.v3(s.load), xAxis: FlexConv.v3(s.x_axis), yAxis: FlexConv.v3(s.y_axis),
            centroid: FlexConv.v3(s.centroid), rotationDeg: Int(s.rotation_deg),
            uMin: s.u_min, vMin: s.v_min, uExtentMM: s.u_extent_mm, vExtentMM: s.v_extent_mm,
            areaMM2: s.area_mm2, projectedAreaMM2: s.projected_area_mm2,
            normalSpreadDeg: s.normal_spread_deg, normalSpreadFlag: s.normal_spread_flag,
            buildAngleDeg: s.build_angle_deg, side: s.side, principalAxisTied: s.principal_axis_tied,
            pitchMM: s.pitch_mm, nu: Int(s.nu), nv: Int(s.nv), cell: Array(s.cell).map { Int($0) },
            columns: cols, exitFaces: ef, exitRegions: er,
            exitUnresolvedFraction: s.exit_unresolved_fraction, footprintAreaMM2: s.footprint_area_mm2,
            latticedColumns: Int(s.latticed_columns), latticeMMMin: s.lattice_mm_min,
            latticeMMMean: s.lattice_mm_mean, latticeMMMax: s.lattice_mm_max, stackMMMax: s.stack_mm_max)
    }

    /// Core's `FaceFrame::from_uv` for each (u, v) mm point.
    public func fromUV(face: Int, rotation: Int, _ uv: [SIMD2<Double>]) throws -> [SIMD3<Double>] {
        var flat: [Double] = []
        flat.reserveCapacity(uv.count * 2)
        for p in uv { flat.append(p.x); flat.append(p.y) }
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_scene_from_uv(handle, Int32(face), Int32(rotation), FlexConv.d(flat), &err)
        try FlexConv.check(err)
        return (0..<(r.count / 3)).map { SIMD3(r[3 * $0], r[3 * $0 + 1], r[3 * $0 + 2]) }
    }

    public func squishFraction(face: Int, rotation: Int, map: FlexMap) throws -> [Double] {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_scene_squish_fraction(handle, Int32(face), Int32(rotation),
                                                            FlexConv.map(map), &err)
        try FlexConv.check(err)
        return Array(r)
    }

    public func edgeFraction(face: Int, rotation: Int) throws -> [Double] {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_scene_edge_fraction(handle, Int32(face), Int32(rotation), &err)
        try FlexConv.check(err)
        return Array(r)
    }

    public func design(materialsPath: String, materialID: String, tempC: Double, face: Int,
                       rotation: Int, map: FlexMap, weightN: Double, stamp: FlexStamp?,
                       build: FlexBuildParams) throws -> FlexFaceDesignInfo {
        var err = topoptbridge.BridgeError()
        let d = topoptbridge.flexible_scene_design(handle, std.string(materialsPath), std.string(materialID),
                                                   tempC, Int32(face), Int32(rotation), FlexConv.map(map),
                                                   weightN, FlexConv.stamp(stamp), FlexConv.build(build), &err)
        try FlexConv.check(err)
        let tier = FlexTier(tier: String(d.tier), band: d.band, why: String(d.tier_why))
        if d.refused {
            return FlexFaceDesignInfo(
                refusal: FlexRefusal(code: String(d.refusal_code), reason: String(d.refusal_reason)),
                columns: [], tier: tier, ok: 0, tooFirm: 0, tooSoft: 0, beyondData: 0, noLattice: 0,
                solidUnderMap: 0, targetExtrapolated: 0, buildableExtrapolated: 0, buildableBeyondData: 0,
                nearEdge: 0, designPressureEvenMPa: 0, designStampUsed: false,
                designStampRigidAveraged: false, designStampOffFace: false, designStampOffFaceN: 0,
                maxSmoothingChangeMM: 0, materialVolumeMM3: 0, targetDepthRange: nil,
                buildableDepthRange: nil, buildableDensityRange: nil, cellRange: nil, sigmaRange: nil)
        }
        // ★ hoisted: see stack(face:rotation:) — one copy per vector, not per column
        let S = Array(d.s), P = Array(d.pressure_mpa), H = Array(d.height_mm), TD = Array(d.target_depth_mm)
        let TS = Array(d.target_strain), ST = d.status.map { String($0) }, TX = Array(d.target_extrapolated)
        let TR = Array(d.target_density), ND = Array(d.nearest_depth_mm), NK = Array(d.nearest_known)
        let CR = Array(d.clamped_density), CD = Array(d.clamped_depth_mm), BR = Array(d.buildable_density)
        let BD = Array(d.buildable_depth_mm), BO = Array(d.buildable_ok), BX = Array(d.buildable_extrapolated)
        let CM = Array(d.cell_mm), SG = Array(d.sigma_mm)
        let n = S.count
        var cols: [FlexColumnDesign] = []
        cols.reserveCapacity(n)
        for k in 0..<n {
            let nd = ND[k], cd = CD[k]
            cols.append(FlexColumnDesign(
                s: S[k], pressureMPa: P[k], heightMM: H[k], targetDepthMM: TD[k], targetStrain: TS[k],
                status: ST[k], targetExtrapolated: TX[k] != 0, targetDensity: TR[k],
                nearestDepthMM: nd.isFinite ? nd : nil, nearestKnown: NK[k] != 0, clampedDensity: CR[k],
                clampedDepthMM: cd.isFinite ? cd : nil, buildableDensity: BR[k], buildableDepthMM: BD[k],
                buildableOK: BO[k] != 0, buildableExtrapolated: BX[k] != 0, cellMM: CM[k], sigmaMM: SG[k]))
        }
        return FlexFaceDesignInfo(
            refusal: nil, columns: cols, tier: tier, ok: Int(d.ok), tooFirm: Int(d.too_firm),
            tooSoft: Int(d.too_soft), beyondData: Int(d.beyond_data), noLattice: Int(d.no_lattice),
            solidUnderMap: Int(d.solid_under_map), targetExtrapolated: Int(d.target_extrapolated_count),
            buildableExtrapolated: Int(d.buildable_extrapolated_count),
            buildableBeyondData: Int(d.buildable_beyond_data), nearEdge: Int(d.near_edge),
            designPressureEvenMPa: d.design_pressure_even_mpa, designStampUsed: d.design_stamp_used,
            designStampRigidAveraged: d.design_stamp_rigid_averaged,
            designStampOffFace: d.design_stamp_off_face, designStampOffFaceN: d.design_stamp_off_face_n,
            maxSmoothingChangeMM: d.max_smoothing_change_mm, materialVolumeMM3: d.material_volume_mm3,
            targetDepthRange: FlexConv.range(d.target_depth_min, d.target_depth_max),
            buildableDepthRange: FlexConv.range(d.buildable_depth_min, d.buildable_depth_max),
            buildableDensityRange: FlexConv.range(d.buildable_density_min, d.buildable_density_max),
            cellRange: FlexConv.range(d.cell_min, d.cell_max),
            sigmaRange: FlexConv.range(d.sigma_min, d.sigma_max))
    }

    /// Check mode: press `stamp` on the densities core last designed for this face.
    public func checkStamp(materialsPath: String, materialID: String, tempC: Double, face: Int,
                           rotation: Int, stamp: FlexStamp, build: FlexBuildParams) throws -> FlexStampCheckInfo {
        var err = topoptbridge.BridgeError()
        let c = topoptbridge.flexible_scene_check_stamp(handle, std.string(materialsPath), std.string(materialID),
                                                        tempC, Int32(face), Int32(rotation),
                                                        topoptbridge.FlexDoubles(), FlexConv.stamp(stamp),
                                                        FlexConv.build(build), &err)
        try FlexConv.check(err)
        return FlexStampCheckInfo(
            ok: c.ok, refusal: FlexRefusal.of(c.refusal_code, c.refusal_reason),
            depthMM: Array(c.depth_mm).map { $0 < 0 ? nil : $0 }, status: c.status.map { String($0) },
            pressedColumns: Int(c.pressed_columns), extrapolatedColumns: Int(c.extrapolated_columns),
            beyondDataColumns: Int(c.beyond_data_columns),
            rigidUnlatticedColumns: Int(c.rigid_unlatticed_columns), maxDepthMM: c.max_depth_mm,
            rigidDepthMM: c.rigid_depth_mm, stampWidthMM: c.stamp_width_mm, localCellMM: c.local_cell_mm,
            narrow: c.narrow, forceOffFaceN: c.force_off_face_n, offFace: c.off_face,
            tier: FlexTier(tier: String(c.tier), band: c.band, why: String(c.tier_why)))
    }

    public func conflicts(faces: [Int], rotations: [Int]) throws -> [FlexConflictInfo] {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_scene_conflicts(handle, FlexConv.i(faces), FlexConv.i(rotations), &err)
        try FlexConv.check(err)
        return r.map { FlexConflictInfo(faceA: Int($0.face_a), faceB: Int($0.face_b),
                                        overlapMM3: $0.overlap_mm3, axisAngleDeg: $0.axis_angle_deg) }
    }

    /// A slice of the density field assembled from the designs last run for `faces`.
    public func densitySlice(faces: [Int], rotations: [Int], build: FlexBuildParams, axis: Int,
                             index: Int) throws -> FlexFieldSliceInfo {
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_scene_density_slice(handle, FlexConv.i(faces), FlexConv.i(rotations),
                                                          FlexConv.build(build), Int32(axis), Int32(index), &err)
        try FlexConv.check(err)
        let h = (0..<r.handover_a.count).map {
            FlexHandover(faceA: Int(r.handover_a[$0]), faceB: Int(r.handover_b[$0]),
                         overlapMM3: r.handover_overlap_mm3[$0], blendedMM3: r.handover_blended_mm3[$0])
        }
        return FlexFieldSliceInfo(width: Int(r.width), height: Int(r.height), spacing: r.spacing,
                                  density: Array(r.density), owner: Array(r.owner).map { Int($0) },
                                  latticeVoxels: Int(r.lattice_voxels), assignedVoxels: Int(r.assigned_voxels),
                                  unassignedVoxels: Int(r.unassigned_voxels), handovers: h)
    }

    public func recommend(materialsPath: String, materialID: String, temps: [Double],
                          topologies: [String], feel: String, beadsPerWall: Int, beadWidthMM: Double,
                          faces: [FlexFaceRequest]) throws -> FlexRecommendationInfo {
        var req = topoptbridge.FlexFaceRequests()
        for f in faces {
            var q = topoptbridge.FlexFaceRequest()
            q.face_region_id = Int32(f.face)
            q.rotation_deg = Int32(f.rotation)
            q.map = FlexConv.map(f.map)
            q.weight_n = f.weightN
            q.design_stamp = FlexConv.stamp(f.stamp)
            req.push_back(q)
        }
        var err = topoptbridge.BridgeError()
        let r = topoptbridge.flexible_scene_recommend(handle, std.string(materialsPath), std.string(materialID),
                                                      FlexConv.d(temps), FlexConv.s(topologies), std.string(feel),
                                                      Int32(beadsPerWall), beadWidthMM, req, &err)
        try FlexConv.check(err)
        let reasons = (0..<r.reason_code.count).map {
            FlexReason(code: String(r.reason_code[$0]), text: String(r.reason_text[$0]),
                       face: r.reason_face[$0] >= 0 ? Int(r.reason_face[$0]) : nil)
        }
        var cands: [FlexCandidate] = []
        for k in 0..<r.cand_topology.count {
            let mass: Double? = r.cand_mass_known[k] != 0 ? r.cand_mass_g[k] : nil
            let refusal = FlexRefusal.of(r.cand_refusal_code[k], r.cand_refusal_reason[k])
            let c = FlexCandidate(topology: String(r.cand_topology[k]), tempC: r.cand_temp_c[k],
                                  eligible: r.cand_eligible[k] != 0, hasData: r.cand_has_data[k] != 0,
                                  reachable: r.cand_reachable[k] != 0,
                                  unreachableColumns: Int(r.cand_unreachable_columns[k]),
                                  nearEdgeColumns: Int(r.cand_near_edge_columns[k]),
                                  massG: mass, refusal: refusal)
            cands.append(c)
        }
        var fails: [FlexFailure] = []
        for k in 0..<r.fail_face.count {
            let u0: Double = r.fail_u_min[k], u1: Double = max(u0, r.fail_u_max[k])
            let v0: Double = r.fail_v_min[k], v1: Double = max(v0, r.fail_v_max[k])
            let near: ClosedRange<Double>? = r.fail_nearest_known[k] != 0
                ? FlexConv.range(r.fail_nearest_min_mm[k], r.fail_nearest_max_mm[k]) : nil
            let f = FlexFailure(face: Int(r.fail_face[k]), text: String(r.fail_text[k]),
                                uRangeMM: u0...u1, vRangeMM: v0...v1, nearestDepthRangeMM: near,
                                tooFirm: Int(r.fail_too_firm[k]), tooSoft: Int(r.fail_too_soft[k]),
                                beyondData: Int(r.fail_beyond_data[k]))
            fails.append(f)
        }
        return FlexRecommendationInfo(chosen: r.chosen, reachable: r.reachable, topology: String(r.topology),
                                      tempC: r.temp_c, feel: String(r.feel), sentence: String(r.sentence),
                                      reasons: reasons, candidates: cands, failures: fails)
    }
}

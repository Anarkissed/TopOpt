// FlexibleNozzleGrade — round 7 · the ONE nozzle row and its GRADE option (task 2026-09-29-flexible-screens).
//
// His words of 2026-10-23 ~03:05 (verbatim): "temperature also needs a grade... also, what's the difference between "temperature"
// and "nozzle" shouldn't they be the same???" then "Temperature needs a grade **option**".
//
// ★ ONE SETTING. "Temperature" (Manual's Model card) and "Nozzle" (More, Auto) were the same thing — the nozzle temperature
// (varioShore foams more when hotter, so it prints softer). Now ONE row, "Nozzle °C", in More, the same place and look in Auto and
// Manual (Manual has no Auto chip). Its value is the one stored setting (`nozzleTempC`); Manual's old copy (`manual.tempC`) only
// holds Auto's pick while the row says Auto, so nothing jumps when Manual is switched on.
// ★ THE GRADE, UP THE BUILD HEIGHT. A nozzle only changes temperature BETWEEN layers, so the grade runs from the bottom layer (From)
// to the top layer (To). Style Default: a little every layer (smooth); Stepped: bands of one temperature each. The squish estimate
// and the views use each layer's temperature: per scene voxel in the display sim (FlexibleFERequest.tempC), tested 190 / 220 / 240
// °C interpolated between, past them extrapolated and MARKED ("Estimate past tested data"). Core never interpolates between
// temperatures (R10) and its job has one temperature: the grade is the display sim's alone — Auto's JOB BYTES are unchanged (CORE
// LIST: per-layer nozzle temperature in the job/export). The facts line says where the temperature changes, for his slicer.

import Foundation
import simd
import SwiftUI
import TopOptDesign
import TopOptKit

/// The nozzle temperature graded up the build height (bottom layer → top layer).
public struct FlexibleNozzleGrade: Codable, Equatable, Hashable, Sendable {
    public var on: Bool
    /// The bottom layer's temperature (°C).
    public var fromC: Double
    /// The top layer's temperature (°C).
    public var toC: Double
    /// Stepped: bands of one temperature each (else Default: smooth, per layer).
    public var stepped: Bool
    public init(on: Bool = false, fromC: Double, toC: Double, stepped: Bool = false) {
        self.on = on; self.fromC = fromC; self.toC = toC; self.stepped = stepped
    }
}

public enum FlexibleNozzleGradeMath {
    /// What From / To may be set to (°C). Outside the tested temperatures the estimate is extrapolated and marked.
    public static let range: ClosedRange<Double> = 180...260
    /// Stepped: at most this many bands (the slicer line fits two lines).
    public static let maxBands = 4
    /// A slicer step: Default's line says how often the temperature moves by this much.
    public static let slicerStepC = 5.0
    /// ★ RED CONTROL only (FlexibleNozzleGradeTests): Stepped ignored — every grade smooth.
    nonisolated(unsafe) static var controlSteppedSmooth = false

    /// Stepped's band count: one band per ~25 °C of the grade (2…4).
    public static func bandCount(_ g: FlexibleNozzleGrade) -> Int {
        Swift.max(2, Swift.min(maxBands, Int((abs(g.toC - g.fromC) / 25).rounded()) + 1))
    }
    /// Stepped's band temperatures, bottom first (whole °C, From and To at the ends).
    public static func bandTemps(_ g: FlexibleNozzleGrade) -> [Double] {
        let n = bandCount(g)
        return (0..<n).map { i in (g.fromC + (g.toC - g.fromC) * Double(i) / Double(n - 1)).rounded() }
    }
    /// The temperature at height fraction `t` (0 = the bottom layer, 1 = the top).
    public static func temp(_ g: FlexibleNozzleGrade, at t: Double) -> Double {
        let f = Swift.min(1, Swift.max(0, t.isFinite ? t : 0))
        guard g.stepped, !controlSteppedSmooth else { return g.fromC + (g.toC - g.fromC) * f }
        let b = bandTemps(g)
        return b[Swift.min(b.count - 1, Int(f * Double(b.count)))]
    }
    /// Per scene voxel (x fastest), the temperature of the layer its centre sits in. `span`: the part's heights along `up`.
    public static func field(_ g: FlexibleNozzleGrade, nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, spacing h: Double,
                             up: SIMD3<Double>, span: ClosedRange<Double>) -> [Float] {
        let n = nx * ny * nz
        guard n > 0 else { return [] }
        let u = simd_length(up) > 1e-12 ? simd_normalize(up) : SIMD3(0, 0, 1)
        let len = Swift.max(span.upperBound - span.lowerBound, 1e-9)
        var out = [Float](repeating: 0, count: n)
        for k in 0..<nz {
            for j in 0..<ny {
                let base = (k * ny + j) * nx
                for i in 0..<nx {
                    let p = origin + (SIMD3(Double(i), Double(j), Double(k)) + 0.5) * h
                    out[base + i] = Float(temp(g, at: (simd_dot(p, u) - span.lowerBound) / len))
                }
            }
        }
        return out
    }
    /// From or To lies outside the tested temperatures.
    public static func pastTested(_ g: FlexibleNozzleGrade, tested: [Double]) -> Bool {
        guard let lo = tested.min(), let hi = tested.max() else { return false }
        return Swift.min(g.fromC, g.toC) < lo - 1e-9 || Swift.max(g.fromC, g.toC) > hi + 1e-9
    }

    /// "12 mm" / "12.3 mm".
    static func mm(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f mm", r) : String(format: "%.1f mm", r)
    }
    static func c(_ v: Double) -> String { String(format: "%.0f °C", v.rounded()) }

    /// ★ THE SLICER LINE (≤ 44 characters a line, two lines at most): where the temperature changes, from the bed.
    /// Stepped: the band edges — "190 °C to 12 mm · 205 °C to 24 mm · 220 °C". Default: the ends, then how often it moves 5 °C —
    /// "190 °C at the bed → 220 °C at 36 mm" / "+5 °C every 6 mm".
    public static func slicerLines(_ g: FlexibleNozzleGrade, heightMM H: Double) -> [String] {
        if g.stepped {
            let b = bandTemps(g)
            let parts = b.enumerated().map { i, t in
                i == b.count - 1 ? c(t) : "\(c(t)) to \(mm(H * Double(i + 1) / Double(b.count)))"
            }
            var lines: [String] = [""]
            for p in parts {
                let cur = lines[lines.count - 1]
                let next = cur.isEmpty ? p : cur + " · " + p
                if next.count <= FlexibleRowCopy.maxChars { lines[lines.count - 1] = next } else { lines.append(p) }
            }
            if lines.count > 2 { lines = [lines[0], FlexibleRowCopy.fit(lines[1...].joined(separator: " · "))] }
            return lines
        }
        let dT = g.toC - g.fromC
        let first = FlexibleRowCopy.fit("\(c(g.fromC)) at the bed → \(c(g.toC)) at \(mm(H))")
        guard abs(dT) >= slicerStepC else { return [first, "Under 5 °C apart · one temperature is enough"] }
        let every = H * slicerStepC / abs(dT)
        return [first, FlexibleRowCopy.fit("\(dT > 0 ? "+" : "−")5 °C every \(mm(every)) up the part")]
    }
}

extension FlexibleRowCopy {
    public static let nozzleGrade = "Temp grade"
    public static let nozzleGradeFrom = "From °C · bottom"
    public static let nozzleGradeTo = "To °C · top"
    public static let nozzleGradeStyle = "Style"
    /// Manual's chips: the tested temperatures, no Auto.
    public static func temperatureOptionsManual(_ tested: [Double]) -> [(id: String, label: String)] {
        tested.map { (String(Int($0)), "\(Int($0))°") }
    }
    /// "Estimate past tested data (190–240 °C)".
    public static func nozzlePastTested(_ tested: [Double]) -> String {
        guard let lo = tested.min(), let hi = tested.max() else { return "Estimate past tested data" }
        return String(format: "Estimate past tested data (%.0f–%.0f °C)", lo, hi)
    }
    public static let nozzleGradeAutoNote = "Shown in the sim only · core's job: one °C"
    public enum NozzleGradeInfo {
        public static let grade = "A nozzle only changes temperature between layers, so the grade runs up the part: From is the bottom layer, To the top. Default changes it a little every layer; Stepped holds bands. The squish estimate and the views use each layer's temperature (the tested curves, interpolated between them; past them it is an estimate, and says so). Enter the heights below in your slicer: the job sent to core still carries one temperature."
    }
}

// MARK: - the model

extension FlexibleStageModel {
    /// ★ RED CONTROL only (FlexibleNozzleGradeTests): today's two rows — Manual's "Temperature" on the Model card, More's Nozzle row
    /// Auto's alone.
    nonisolated(unsafe) static var controlTwoTemperatureRows = false
    /// ★ RED CONTROL only: the grade leaks into Auto's one temperature (From written as the nozzle setting — the job changes).
    nonisolated(unsafe) static var controlGradeSetsNozzle = false
    /// ★ RED CONTROL only: the grade never reaches the sim (every layer at the one temperature).
    nonisolated(unsafe) static var controlNoGradeInSim = false

    /// The rows under More's nozzle line, in order (the views draw these; the tests read them). `manual`: Manual is on.
    public static func nozzleRows(manual: Bool, hasData: Bool, gradeOn: Bool) -> [String] {
        if manual && controlTwoTemperatureRows { return [] }
        guard hasData else { return ["nozzleNoData"] }
        var r = ["nozzle", "grade"]
        if gradeOn { r += ["from", "to", "style", "facts"] }
        return r
    }

    /// The row's one temperature: Manual's (no Auto), else Auto's setting (nil: the Auto chip).
    public var nozzleRowTempC: Double? { isManual ? manualTempC : settings.nozzleTempC }

    /// The row's chip: Auto's or a tested temperature. ONE setting — Manual's old copy is dropped with it.
    public func setNozzleTemp(_ t: Double?) {
        if isManual { if let t { setManualTemp(t) }; return }
        edit { s in s.nozzleTempC = t; s.manual?.tempC = nil }
    }

    public var nozzleGradeOn: Bool { settings.nozzleGrade?.on == true }

    /// [Off | On]. Switched on the first time: From = the row's temperature, To = the next tested temperature above (else below).
    public func setNozzleGrade(on: Bool) {
        let tested = (material?.testedTempsC ?? []).sorted()
        let from = (isManual ? manualTempC : designTempC) ?? tested.first ?? 220
        let to = tested.first { $0 > from + 1e-9 } ?? tested.last { $0 < from - 1e-9 } ?? Swift.min(from + 20, FlexibleNozzleGradeMath.range.upperBound)
        actionSerial += 1
        edit({ s in
            var g = s.nozzleGrade ?? FlexibleNozzleGrade(fromC: from, toC: to)
            g.on = on
            s.nozzleGrade = g
            if Self.controlGradeSetsNozzle, on { s.nozzleTempC = g.fromC }
        }, recompute: Self.controlGradeSetsNozzle)
        regradeIfNeeded()
    }
    /// From (`top` false) or To (`top` true), °C.
    public func setNozzleGradeEnd(top: Bool, _ c: Double) {
        guard var g = settings.nozzleGrade else { return }
        let v = Swift.min(FlexibleNozzleGradeMath.range.upperBound, Swift.max(FlexibleNozzleGradeMath.range.lowerBound, c.rounded()))
        if top { g.toC = v } else { g.fromC = v }
        actionSerial += 1
        edit({ $0.nozzleGrade = g }, recompute: false)
        regradeIfNeeded()
    }
    public func setNozzleGradeStepped(_ on: Bool) {
        guard var g = settings.nozzleGrade else { return }
        g.stepped = on
        actionSerial += 1
        edit({ $0.nozzleGrade = g }, recompute: false)
        regradeIfNeeded()
    }

    /// The part's heights along the build direction (mm): its mesh's, else the scene grid's.
    public var buildSpanMM: ClosedRange<Double>? {
        let up = sceneInfo?.buildDir ?? SIMD3(0, 0, 1)
        let u = simd_length(up) > 1e-12 ? simd_normalize(up) : SIMD3(0, 0, 1)
        if let mesh = project.viewerMesh, mesh.vertexCount > 0 {
            let k = "\(mesh.positions.count)|\(mesh.triangleCount)|\(mesh.positions.prefix(3))|\(mesh.positions.suffix(3))|\(u)"
            if let c = Self.spanCache[k] { return c }
            var lo = Double.infinity, hi = -Double.infinity
            let p = mesh.positions
            var i = 0
            while i + 2 < p.count {
                let d = Double(p[i]) * u.x + Double(p[i + 1]) * u.y + Double(p[i + 2]) * u.z
                lo = Swift.min(lo, d); hi = Swift.max(hi, d)
                i += 3
            }
            if hi > lo {
                if Self.spanCache.count > 8 { Self.spanCache = [:] }
                Self.spanCache[k] = lo...hi
                return lo...hi
            }
        }
        guard let info = sceneInfo else { return nil }
        var lo = Double.infinity, hi = -Double.infinity
        for c in 0..<8 {
            let q = info.origin + SIMD3(Double(c & 1 == 0 ? 0 : info.nx), Double(c & 2 == 0 ? 0 : info.ny), Double(c & 4 == 0 ? 0 : info.nz)) * info.spacing
            let d = simd_dot(q, u)
            lo = Swift.min(lo, d); hi = Swift.max(hi, d)
        }
        return hi > lo ? lo...hi : nil
    }
    @MainActor private static var spanCache: [String: ClosedRange<Double>] = [:]

    /// The facts under the grade: the slicer heights, then (flagged) past the tested temperatures; in Auto, that core's job keeps
    /// one temperature.
    public func nozzleGradeLines() -> [(text: String, warning: Bool)] {
        guard let g = settings.nozzleGrade, g.on, let span = buildSpanMM else { return [] }
        var out: [(String, Bool)] = FlexibleNozzleGradeMath.slicerLines(g, heightMM: span.upperBound - span.lowerBound).map { ($0, false) }
        let tested = material?.testedTempsC ?? []
        if FlexibleNozzleGradeMath.pastTested(g, tested: tested) { out.append((FlexibleRowCopy.nozzlePastTested(tested), true)) }
        if !isManual { out.append((FlexibleRowCopy.nozzleGradeAutoNote, false)) }
        return out
    }

    /// What the shown sims' temperatures were made from ("" with no grade).
    var nozzleGradeKey: String {
        guard let g = settings.nozzleGrade, g.on, !Self.controlNoGradeInSim, let info = sceneInfo, let span = buildSpanMM else { return "" }
        return "\(g.fromC)|\(g.toC)|\(g.stepped)|\(span)|\(info.nx)x\(info.ny)x\(info.nz)|\(info.buildDir)"
    }
    /// Per scene voxel, its layer's nozzle temperature (empty: no grade).
    func nozzleTempField() -> [Float] {
        guard let g = settings.nozzleGrade, g.on, !Self.controlNoGradeInSim, let info = sceneInfo, let span = buildSpanMM else { return [] }
        return FlexibleNozzleGradeMath.field(g, nx: info.nx, ny: info.ny, nz: info.nz, origin: info.origin, spacing: info.spacing,
                                             up: info.buildDir, span: span)
    }

    /// The grade moved since the shown sims were scheduled (an edit, its Undo): the sims solved again with the new temperatures —
    /// never the lattice (the grade is not in `designInputs`). Cheap when nothing moved (keyed).
    public func regradeIfNeeded() {
        guard let r0 = simRequest, let l = lattice, r0.generation == l.generation else { return }
        let k = nozzleGradeKey
        guard k != r0.tempKey else { return }
        holdEpoch += 1
        restartSims(r0.with(walls: r0.walls, epoch: holdEpoch).with(tempC: nozzleTempField(), key: k))
    }
}

/// ★ More's nozzle rows: ONE "Nozzle °C" row (Auto keeps its Auto chip; Manual has none), then the grade — [Off | On], From, To,
/// Style, the slicer facts. One FlexRow line each, the panel's FlexChips / FlexNumberBox look.
struct FlexibleNozzleRows: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?

    var body: some View {
        let m = model.material
        let hasData = m.map { $0.noPrediction == nil } ?? false
        let g = model.settings.nozzleGrade
        let rows = FlexibleStageModel.nozzleRows(manual: model.isManual, hasData: hasData, gradeOn: g?.on == true)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if rows.contains("nozzleNoData") {
                FlexRow(FlexibleRowCopy.temperatureNoData, info: FlexibleRowCopy.Info.temperature, id: "flexible-row-temp")
            }
            if rows.contains("nozzle"), let m {
                // a temperature core has a note on (not in order, estimated…) is said by the row's colour (Auto); the (i) carries it
                let note = model.isManual ? "" : (model.settings.nozzleTempC.map { model.temperatureNote($0) } ?? "")
                let tested = m.testedTempsC
                FlexRow(FlexibleRowCopy.temperature, info: model.isManual ? FlexibleManualCopy.Info.temperature : FlexibleRowCopy.Info.temperature,
                        id: "flexible-row-temp", warning: !note.isEmpty) {
                    FlexChips(options: model.isManual ? FlexibleRowCopy.temperatureOptionsManual(tested) : FlexibleRowCopy.temperatureOptions(tested),
                              selection: model.nozzleRowTempC.map { String(Int($0)) } ?? "auto", id: "flexible-temp",
                              equalWidths: false) { v in model.setNozzleTemp(v == "auto" ? nil : Double(v)) }
                        .fixedSize()
                } extra: {
                    if let t = model.settings.nozzleTempC, !note.isEmpty {
                        FlexInfoText("\(Int(t)) °C: \(note)", warning: true)
                    }
                }
            }
            if rows.contains("grade") {
                FlexRow(FlexibleRowCopy.nozzleGrade, info: FlexibleRowCopy.NozzleGradeInfo.grade, id: "flexible-row-temp-grade") {
                    FlexChips(options: FlexibleManualCopy.gradeOptions, selection: g?.on == true ? "on" : "off", id: "flexible-temp-grade",
                              equalWidths: false) { v in model.setNozzleGrade(on: v == "on") }
                        .fixedSize()
                }
            }
            if let g, rows.contains("from") {
                ForEach([false, true], id: \.self) { top in
                    FlexRow(top ? FlexibleRowCopy.nozzleGradeTo : FlexibleRowCopy.nozzleGradeFrom, info: FlexibleRowCopy.NozzleGradeInfo.grade,
                            id: "flexible-row-temp-\(top ? "to" : "from")") {
                        FlexNumberBox(key: "nozzle-grade-\(top ? "to" : "from")", title: top ? FlexibleRowCopy.nozzleGradeTo : FlexibleRowCopy.nozzleGradeFrom,
                                      spec: FlexNumberSpec(value: top ? g.toC : g.fromC, unit: "°C", step: 5,
                                                           range: FlexibleNozzleGradeMath.range, decimals: 0),
                                      padTarget: $padTarget, onNote: { model.toast = $0 }) { model.setNozzleGradeEnd(top: top, $0) }
                    }
                }
            }
            if let g, rows.contains("style") {
                FlexRow(FlexibleRowCopy.nozzleGradeStyle, info: FlexibleRowCopy.NozzleGradeInfo.grade, id: "flexible-row-temp-style") {
                    FlexChips(options: FlexibleManualCopy.styleOptions, selection: g.stepped ? "stepped" : "default", id: "flexible-temp-style",
                              equalWidths: false) { v in model.setNozzleGradeStepped(v == "stepped") }
                        .fixedSize()
                }
            }
            if rows.contains("facts") {
                let lines = model.nozzleGradeLines()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, f in
                        Text(f.text)
                            .font(.system(size: 12, weight: f.warning ? .semibold : .regular))
                            .foregroundStyle(f.warning ? DS.Color.warning.color : DS.Color.textTertiary.color)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("flexible-temp-grade-facts")
            }
        }
    }
}

// FlexibleManualPredict — round 7 · MANUAL, part M2: predictions, and Auto removed in Manual (task 2026-09-29-flexible-screens).
//
// His orders of 2026-10-22 ~02:30 (verbatim): "implement the manual add-on. Remove any of the auto processes and make it as simple
// to understand as possible. The views become what the app assumes based on your values, so cards should say that when a view is
// selected." His picks the same night: in Manual the INPUTS are which faces / edges are pressed, the weight (Squeeze), the stamp
// (what presses on it) and an edge's push direction (Tilt / Twist); the depths and the curves become the app's PREDICTION — read
// only, on the views, the cards and in the curve window; Auto's lattice-type pick and the "can't meet your curve" checks disappear.
//
// ★ ONE SOURCE, THE DISPLAY SIM: the squeeze group's own FE squish sim on HIS lattice — the field the views show
// (FlexibleSettingsSquish.field), solved at his lattice's own stiffness under his weight and his stamp (M1's `manualEstimate`: no
// core depth to scale it to). A face's estimate is its deepest latticed column's compression along its load
// (FlexibleFEField.columnCompression on core's stack) ÷ the field's k — a fold cut only shrinks the PICTURE, never the number; an
// edge's or a corner's is the same on core's press stack. Its rings and its curves are those columns (an edge's: its footprint's
// samples, what Play pushes) scaled to the deepest.
// ★ NOTHING ASKED OF CORE IN MANUAL: scheduleDesigns / scheduleAuto return before any request (`manualSkipsCore`;
// `coreDesignRequests` counts), what core said before is dropped, and the Manual lattice is built from core's MASK with each voxel
// owned by the nearest pressed stack by core's rule (FlexibleGroupField.assemble) — never from a design.

import Foundation
import simd
import TopOptKit

/// A depth in Manual: the estimate, still being worked out (the lattice is current, its sim runs), or later (edited since the
/// last build: Save & Exit builds it).
public enum FlexibleManualEstimate: Equatable {
    case mm(Double)
    case working
    case later
}

extension FlexibleManualCopy {
    /// No estimate: edited since the last build (or none built).
    public static let estimateLater = "Squish estimate · Save & Exit to see it"
    /// The lattice is current and its sim still runs.
    public static let estimateWorking = "Squish estimate · working it out…"
    /// The chip with no estimate.
    public static let chipNone = "No estimate yet"
    public static let chipWorking = "Estimating…"
    /// The curve window's one button in Manual.
    public static let done = "Done"

    /// The card's read-only line: "Squishes ≈ 3.2 mm at 10 lb".
    public static func squishes(_ mm: Double, weight: String?) -> String {
        FlexibleRowCopy.fit(String(format: "Squishes \u{2248} %.1f mm", mm) + (weight.map { " at \($0)" } ?? ""))
    }
    public static func line(_ e: FlexibleManualEstimate, weight: String?) -> String {
        switch e {
        case .mm(let v): return squishes(v, weight: weight)
        case .working: return estimateWorking
        case .later: return estimateLater
        }
    }
    /// The depth chip / tag: "≈ 3.2 mm".
    public static func chip(_ mm: Double) -> String { String(format: "\u{2248} %.1f mm", mm) }
    public static func chipText(_ e: FlexibleManualEstimate) -> String {
        switch e {
        case .mm(let v): return chip(v)
        case .working: return chipWorking
        case .later: return chipNone
        }
    }
    /// The curve window's one line in Manual.
    public static func curveNote(_ mm: Double?) -> String {
        mm.map { String(format: "What your lattice does \u{00B7} deepest \u{2248} %.1f mm", $0) }
            ?? "No estimate yet \u{00B7} Save & Exit to see it"
    }
    /// The curve window's title in Manual.
    public static func curveTitle(_ name: String) -> String { FlexibleRowCopy.fit(name + " \u{00B7} what your lattice does") }

    public enum EstimateInfo {
        public static let face = "Manual: the app's estimate of how far this face sinks under its weight, worked out from your lattice. Change the lattice, the weight or what presses it, then Save & Exit, and it is worked out again."
        public static let edge = "Manual: the app's estimate of how far this edge sinks along its arrow under its weight, worked out from your lattice. Tilt, Twist and what presses it are yours; Save & Exit works it out again."
    }
}

extension FlexibleStageModel {
    /// ★ RED CONTROL only (FlexibleM2PredictTests): core's designs and Auto's pick asked in Manual.
    nonisolated(unsafe) static var controlDesignsInManual = false
    /// ★ RED CONTROL only: the depths stay his inputs in Manual (the box, the drag, the keypad).
    nonisolated(unsafe) static var controlManualDepthEditable = false
    /// ★ RED CONTROL only: the curve window edits in Manual.
    nonisolated(unsafe) static var controlManualCurvesEditable = false

    /// ★ Manual, and nothing is asked of core (no design, no Auto pick, no stamp check, no conflict). (M1's red control — core's
    /// design in Manual — and this part's let the designs through.)
    var manualSkipsCore: Bool { isManual && !Self.controlDesignsInManual && !Self.controlManualLatticeOff }

    /// Every depth (a face's Deepest squish, its chip, an edge's) is his input — false in Manual: the app's estimate, read only.
    public var depthIsInput: Bool { !isManual || Self.controlManualDepthEditable }
    /// The curves are his input — false in Manual: the curve window shows what his lattice does.
    public var curvesAreInput: Bool { !isManual || Self.controlManualCurvesEditable }

    // MARK: the estimate

    /// The display sim of `g` when it answers his setup as it is now (the views' own field).
    func estimateField(_ g: FlexibleSqueezeGroup) -> FlexibleFEField? { FlexibleSettingsSquish.field(model: self, group: g) }

    /// No field: still working (the lattice is current, its sim has not landed) or later (edited since the build, or failed).
    private func waiting(_ g: FlexibleSqueezeGroup) -> FlexibleManualEstimate {
        guard let l = lattice, squishGeneration == l.generation,
              !latticeIsStale || FlexibleSettingsSquish.staleEdges(model: self, group: g) else { return .later }
        switch squish[FlexibleSim.groupID(g.number)] {
        case .pending?, nil: return .working
        default: return .later
        }
    }

    /// Each column's estimate (mm at the full weight; 0 off the lattice) — cached per field and stack (the chip, the prism, the
    /// tags and the card all ask on every draw).
    func estimateColumns(_ f: FlexibleFEField, _ st: FlexStackInfo, key: String) -> [Double] {
        let k = "\(f.serial)|\(f.scale)|\(key)|\(st.columns.count)"
        if let c = Self.estimateCache[k] { return c }
        let s = f.scale > 1e-12 ? f.scale : 1
        let v = st.columns.indices.map { c in
            st.columns[c].latticeMM > 0 ? Swift.max(0, f.columnCompression(stack: st, col: c, pinched: false)) / s : 0
        }
        if Self.estimateCache.count > 64 { Self.estimateCache = [:] }
        Self.estimateCache[k] = v
        return v
    }
    @MainActor private static var estimateCache: [String: [Double]] = [:]

    /// ★ A pressed face's estimate (Manual only; `.later` in Auto).
    public func estimate(region r: Int) -> FlexibleManualEstimate {
        guard isManual, let g = squeezeGroup(of: r), let st = stack(r) else { return .later }
        guard let f = estimateField(g) else { return waiting(g) }
        return .mm(estimateColumns(f, st, key: "r\(r)").max() ?? 0)
    }

    /// ★ An edge's or a corner's estimate along its arrow (Manual only).
    public func estimate(press id: UUID) -> FlexibleManualEstimate {
        guard isManual, let g = squeezeGroup(ofPress: id), let st = pressStack(id) else { return .later }
        guard let f = estimateField(g) else { return waiting(g) }
        return .mm(estimateColumns(f, st, key: "p\(id.uuidString)").max() ?? 0)
    }

    /// The deepest estimate over a group's faces and presses (nil: none yet).
    func estimateDeepest(_ g: FlexibleSqueezeGroup) -> Double? {
        let all = g.regions.map { estimate(region: $0) } + g.presses.map { estimate(press: $0) }
        let v = all.compactMap { e -> Double? in if case .mm(let x) = e { return x }; return nil }
        return v.max()
    }

    private func estimateWeight(_ g: FlexibleSqueezeGroup?) -> String? {
        g.flatMap { groupForce($0)?.upperBound }.map { FlexibleRowCopy.weightText($0, weightUnit) }
    }

    /// ★ The face card's read-only line in Manual: "Squishes ≈ 3.2 mm at 10 lb" (nil in Auto).
    public func estimateLine(region r: Int) -> String? {
        guard isManual else { return nil }
        return FlexibleManualCopy.line(estimate(region: r), weight: estimateWeight(squeezeGroup(of: r)))
    }
    /// ★ An edge's card line in Manual (nil in Auto).
    public func estimateLine(press id: UUID) -> String? {
        guard isManual else { return nil }
        return FlexibleManualCopy.line(estimate(press: id), weight: estimateWeight(squeezeGroup(ofPress: id)))
    }

    /// ★ The depth a face's prism is drawn to: his Deepest squish in Auto; the estimate in Manual once there is one.
    public func shownDepthMM(_ f: FlexibleFaceSettings) -> Double {
        guard isManual, case .mm(let v) = estimate(region: f.faceRegionID), v > 0 else { return f.deepestMM }
        return v
    }

    /// What the estimates hang on (the tags' cache key): "" in Auto.
    var estimateKey: String {
        guard isManual else { return "" }
        let serials = squish.values.compactMap { $0.field?.serial }.sorted()
        return "\(lattice?.generation ?? -1)|\(latticeIsStale)|\(serials)|\(refine.count)"
    }

    // MARK: the rings and the curves

    /// ★ The indent rings in Manual: each column's estimate ÷ the deepest (nil: no estimate yet — no rings).
    func estimateFractions(region r: Int) -> [Double]? {
        guard isManual, let g = squeezeGroup(of: r), let st = stack(r), let f = estimateField(g) else { return nil }
        let v = estimateColumns(f, st, key: "r\(r)")
        let top = v.max() ?? 0
        return top > 1e-9 ? v.map { $0 / top } : nil
    }

    /// ★ An edge's or a corner's footprint samples (what Play pushes) with the field's push along the arrow at each, ÷ the deepest.
    func estimatePushes(press id: UUID) -> (samples: FlexiblePressPush.Samples, values: [Double])? {
        guard isManual, let p = press(id), let c = flatCut(id), let g = squeezeGroup(ofPress: id), let f = estimateField(g) else { return nil }
        let s = FlexiblePressPush.samples(p, c)
        let len = simd_length(c.direction)
        guard s.count > 0, len > 1e-12 else { return nil }
        let d = SIMD3<Float>(c.direction / len)
        let v = (0..<s.count).map { i -> Double in
            guard 3 * i + 2 < s.xyz.count else { return 0 }
            let q = SIMD3<Float>(Float(s.xyz[3 * i]), Float(s.xyz[3 * i + 1]), Float(s.xyz[3 * i + 2]))
            return abs(Double(simd_dot(f.sample(q), d)))
        }
        let top = v.max() ?? 0
        return top > 1e-12 ? (s, v.map { $0 / top }) : nil
    }

    /// ★ The curve window in Manual: what his lattice does along each curve, scaled to its deepest (1) — a face's X and Y as the
    /// dent's cross-sections through its deepest column; an edge's across and along through its deepest sample; a corner's from
    /// its rim (0) to its tip (1). nil: no estimate yet (or Auto).
    public func predictedProfiles(_ d: FlexiblePressCurveDraft) -> [FlexiblePressCurveBaselines.Axis: [Double]]? {
        guard isManual else { return nil }
        if let r = d.face {
            guard let fr = estimateFractions(region: r), let st = stack(r), st.nu > 0, st.nv > 0, st.cell.count >= st.nu * st.nv else { return nil }
            // the dent's two cross-sections through its deepest column (the X curve along that row, the Y curve along that column)
            var x = [Double](repeating: 0, count: st.nu), y = [Double](repeating: 0, count: st.nv)
            var hasU = [Bool](repeating: false, count: st.nu), hasV = [Bool](repeating: false, count: st.nv)
            var best = (iu: 0, iv: 0, v: -1.0)
            for iv in 0..<st.nv {
                for iu in 0..<st.nu {
                    let c = st.cell[iv * st.nu + iu]
                    guard c >= 0, c < fr.count else { continue }
                    hasU[iu] = true; hasV[iv] = true
                    if fr[c] > best.v { best = (iu, iv, fr[c]) }
                }
            }
            func at(_ iu: Int, _ iv: Int) -> Double {
                let c = st.cell[iv * st.nu + iu]
                return c >= 0 && c < fr.count ? fr[c] : 0
            }
            for iu in 0..<st.nu { x[iu] = at(iu, best.iv) }
            for iv in 0..<st.nv { y[iv] = at(best.iu, iv) }
            // the face's own span (the grid's empty rows beyond it trimmed)
            func trimmed(_ v: [Double], _ has: [Bool]) -> [Double] {
                guard let a = has.firstIndex(of: true), let b = has.lastIndex(of: true) else { return [] }
                return Array(v[a...b])
            }
            let px = Self.normalised(trimmed(x, hasU)), py = Self.normalised(trimmed(y, hasV))
            guard !px.isEmpty, !py.isEmpty else { return nil }
            return [.along: px, .across: py]
        }
        guard let id = d.press, let p = press(id), let st = p.strip, let e = estimatePushes(press: id) else { return nil }
        let n = FlexiblePressPush.n, n1 = n + 1
        if st.kind == .corner {
            var k = [Double](repeating: 0, count: n1)
            let per = n1 * (n1 + 1) / 2
            var q = 0
            while q + per <= e.values.count {
                for a in 0...n { for b in 0...(n - a) { k[n - a - b] = Swift.max(k[n - a - b], e.values[q]); q += 1 } }
            }
            return [.corner: Self.normalised(k)]
        }
        guard e.values.count == n1 * n1 else { return nil }
        // an edge: the push's two cross-sections through its deepest sample (as a face's)
        let top = e.values.indices.max { e.values[$0] < e.values[$1] } ?? 0
        let (i0, j0) = (top / n1, top % n1)
        let along = (0..<n1).map { e.values[$0 * n1 + j0] }, across = (0..<n1).map { e.values[i0 * n1 + $0] }
        return [.along: Self.normalised(along), .across: Self.normalised(across)]
    }

    /// The window's deepest estimate (its one line).
    public func predictedDeepest(_ d: FlexiblePressCurveDraft) -> Double? {
        let e = d.face.map { estimate(region: $0) } ?? d.press.map { estimate(press: $0) } ?? .later
        if case .mm(let v) = e { return v }
        return nil
    }

    static func normalised(_ v: [Double]) -> [Double] {
        let t = v.max() ?? 0
        return t > 1e-12 ? v.map { $0 / t } : v
    }
}

extension FlexibleStageModel {
    /// ★ MANUAL (M2): an edge card's lines about core's design — "Set up · core is designing it", core's refusal, "Can't reach on 13
    /// columns", how far off core's map is — are not shown in Manual (nothing is designed there; the sim pushes his drawing). Only
    /// what keeps the press out of the lattice itself stays (no stack, two entries, shared surface, a conflict — with its fixes).
    public func manualHidesPressLine(_ id: UUID) -> Bool {
        guard isManual else { return false }
        guard let v = pressSupport[id], !v.inJob else { return true }
        switch v.reason {
        case .notStacked?, .twoEntries?, .shared?, .conflict?: return false
        default: return true
        }
    }
}

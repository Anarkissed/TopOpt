// LatticeStrengthAnswer.swift — ★ notes25 C3 (his iPad 2026-11-23 on release 16: "It says it breaks at 40kg at 1.0x the load but
// in the strength details it says the weakest struts are at 1.3x the load. Why is there a difference? ... ALL INFORMATION SHOULD BE
// SIMPLE TO UNDERSTAND AND CONSISTENT ACROSS ALL AREAS").
//
// 362's investigation (agent-scratch/organic1/notes25/numbers/REPORT.md): the print file's result reached Results as a plain SOLID
// result, so the app knocked the struts down for infill (they are not infill) at a one-voxel stress spike in the lattice and called
// that "1.0x / 40 kg". Core's own answer is: the weakest strut holds 1.34x (it needs 1.5x) and governs; the solid holds 2.66x at
// his infill. This file is that ONE answer, read from core's report, and every place on Results says it the same way:
//   * how strong: the governing margin = the smaller of the solid's margin at his infill and the weakest strut's, two decimals;
//   * where it gives first: the weakest strut when struts govern, else the solid's weakest voxel (fields.bin block 2);
//   * the loads in whole kg, the requirement as "needs 1.5×", widths with two decimals.
// Pure: Notes25StrengthTests reads his stand's report shape.

import Foundation
import simd

public struct LatticeStrengthAnswer: Equatable, Sendable {
    public enum Governs: Equatable, Sendable { case strut, solid }

    /// One of core's listed weakest struts (`strength.weakest`, weakest first).
    public struct Strut: Equatable, Sendable {
        /// The middle of its worst piece (model mm).
        public var at: SIMD3<Double>
        /// Its two ends (model mm), when core sent them.
        public var ends: [SIMD3<Double>]
        public var widthMM: Double
        public var lengthMM: Double
        public var margin: Double
        /// core's word for the limit it hit ("tension", "compression", "buckling").
        public var by: String
        public var axialN: Double?
        public var momentNmm: Double?

        /// ★ C3 (6): "bends" or "in tension" from core's axial force vs its moment (his strut: 0.13 N against 29.8 N·mm, so it
        /// bends): the stress the moment makes at the surface, M / (π w³/32), against the axial stress, N / (π w²/4).
        public var action: String {
            if by == "buckling" { return "buckles" }
            if let n = axialN, let m = momentNmm, widthMM > 0 {
                let axial = abs(n) / (Double.pi * widthMM * widthMM / 4)
                let bending = abs(m) / (Double.pi * widthMM * widthMM * widthMM / 32)
                if bending >= axial { return "bends" }
                return n < 0 ? "in compression" : "in tension"
            }
            return by.isEmpty ? "" : "in " + by
        }
    }

    /// The weakest strut's margin (core: `struts.smallest_margin`, else `strut.margin_worst_case`); nil with no frame check.
    public var strutMargin: Double?
    /// The solid's margin at his infill (core: `solid_margin.effective`, else the old gate's `margin_worst_case`).
    public var solidMargin: Double?
    /// The margin it must keep (`safety_margin`).
    public var required: Double
    /// Core's listed weakest struts, weakest first (at most `frame_weakest`, 20).
    public var weakest: [Strut]
    public var strutsShort: Int?
    public var strutsJudged: Int?
    /// The lowest infill the solid still passes at (`solid_margin.passes_at_infill_percent`).
    public var solidPassesAtInfill: Int?
    /// The share of the load the struts carry where it presses (`frame.load_share`, 0…1).
    public var loadShare: Double?
    /// The solid's weakest voxel (the smallest of fields.bin block 2), when the result carries it.
    public var solidWeakest: SIMD3<Double>?
    /// ★ notes30 (core OS19, the interim guard): a load lands on bare vines, so the check refused to judge it (its margins are
    /// not a verdict until the loaded face is covered); nil: it did not.
    public var bareVines: OrganicBareVines.Found? = nil
    /// ★ 362 (11-26): the printer's wall (the cover a Solid finish lays), when the page knows it — the Checks line then names
    /// only the fixes the wizard offers (LatticeReview's depth rule); nil: unknown (no Solid named when core gave the depth).
    public var solidWallMM: Double? = nil

    /// ★ THE "how strong" number: the smaller of the two.
    public var governing: Double? {
        switch (strutMargin, solidMargin) {
        case let (s?, d?): return Swift.min(s, d)
        case let (s?, nil): return s
        case let (nil, d?): return d
        default: return nil
        }
    }
    /// What governs it: the struts when their margin is the smaller.
    public var governs: Governs? {
        guard let g = governing else { return nil }
        if let s = strutMargin, s <= g { return .strut }
        return .solid
    }
    /// ★ THE "where it gives first": the weakest strut when struts govern, else the solid's weakest voxel.
    public var place: SIMD3<Double>? {
        switch governs {
        case .strut?: return weakest.first?.at ?? solidWeakest
        case .solid?: return solidWeakest ?? weakest.first?.at
        case nil: return nil
        }
    }
    public var holds: Bool { bareVines == nil && (governing ?? 0) >= required - 1e-9 }

    /// A print file's report (`lattice_file.json`: `layout`, `mesh` and a `strength` block with a margin), else nil.
    public static func decode(report r: [String: Any]) -> LatticeStrengthAnswer? {
        guard r["layout"] is [String: Any], r["mesh"] is [String: Any], let s = r["strength"] as? [String: Any] else { return nil }
        func n(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func p(_ v: Any?) -> SIMD3<Double>? {
            guard let a = v as? [NSNumber], a.count == 3 else { return nil }
            return SIMD3(a[0].doubleValue, a[1].doubleValue, a[2].doubleValue)
        }
        let struts = s["struts"] as? [String: Any] ?? [:]
        let strut = s["strut"] as? [String: Any] ?? [:]
        let solid = s["solid_margin"] as? [String: Any] ?? [:]
        let frame = s["frame"] as? [String: Any] ?? [:]
        let strutMargin = n(struts["smallest_margin"]) ?? n(strut["margin_worst_case"])
        let solidMargin = n(solid["effective"]) ?? n(s["margin_worst_case"])
        guard strutMargin != nil || solidMargin != nil else { return nil }
        let weakest = (s["weakest"] as? [[String: Any]] ?? []).compactMap { w -> Strut? in
            guard let at = p(w["at"]), let m = n(w["margin"]) else { return nil }
            let ends = (w["ends"] as? [[String: Any]] ?? []).compactMap { p($0["at"]) }
            return Strut(at: at, ends: ends, widthMM: n(w["width_mm"]) ?? 0, lengthMM: n(w["length_mm"]) ?? 0, margin: m,
                         by: w["by"] as? String ?? "", axialN: n(w["axial_n"]), momentNmm: n(w["moment_nmm"]))
        }.sorted { $0.margin < $1.margin }
        let app = r[SolidMarginVoxels.reportKey] as? [String: Any]
        return LatticeStrengthAnswer(
            strutMargin: strutMargin, solidMargin: solidMargin, required: n(s["safety_margin"]) ?? n(r["safety_margin"]) ?? 1.5,
            weakest: weakest, strutsShort: (struts["under_safety"] as? NSNumber)?.intValue,
            strutsJudged: (struts["judged"] as? NSNumber)?.intValue,
            solidPassesAtInfill: (solid["passes_at_infill_percent"] as? NSNumber)?.intValue,
            loadShare: n(frame["load_share"]), solidWeakest: p(app?["weakest_at"]), bareVines: OrganicBareVines.found(strength: s))
    }

    // MARK: the words (one set, every place)

    /// "Holds 1.34× · needs 1.5×" — the Checks line's sub-line.
    public var checkLine: String {
        "Holds " + StrengthWords.x(governing ?? 0) + " \u{00B7} needs " + StrengthWords.need(required)
    }

    /// The Checks panel's ONE strength line (★ C3 (4): it replaces both the solid's and the struts' lines).
    public func check() -> ResultsCheck {
        // ★ notes30: a load on bare vines — what lands where and the fix (no margin: the check refused to judge it), the place
        // lit on the part, core's sentence behind the (i)
        if let b = bareVines {
            // ★ 362 (11-26): only the fixes offered ("Fix: Protect skin 4.5 mm" when Solid is not)
            let detail = OrganicBareVines.checkDetailLine(OrganicBareVines.offers(b, wallMM: solidWallMM))
            return ResultsCheck(kind: .warn, title: OrganicBareVines.title, detail: detail,
                                places: b.at.map { [$0] } ?? [], more: b.at == nil ? nil : OrganicBareVines.checkMore,
                                tab: .strength, info: b.text)
        }
        return ResultsCheck(kind: holds ? .ok : .warn, title: holds ? "Strong enough" : "Not strong enough", detail: checkLine,
                     places: place.map { [$0] } ?? [], more: place == nil ? nil : "Where it gives way first is lit on the part",
                     tab: .strength)
    }

    /// Details › Strength (★ C3 (6), labels of at most five words). `loadKg`: the load the result was solved under.
    /// ★ notes27 F2 (his 11-23: "Explain it simply. If more information is required, add an (i)"): each row plain, its detail
    /// behind its (i).
    public func rows(loadKg: Double, unit: WeightUnit, infillPercent: Int, plastic: String?) -> [ResultsDetailRow] {
        var r: [ResultsDetailRow] = []
        func add(_ l: String, _ v: String?, info: String? = nil) {
            if let v, !v.isEmpty { r.append(ResultsDetailRow(label: l, value: v, info: info)) }
        }
        if let b = bareVines {
            // ★ notes30: the check refused to judge it — no "Holds" number; what lands where, core's sentence behind the (i)
            add(OrganicBareVines.rowLabel, OrganicBareVines.rowValue, info: b.text)
        } else if let g = governing {
            add("Holds", StrengthWords.x(g) + " your load" + (loadKg > 0 ? " (" + StrengthWords.load(g * loadKg, unit) + ")" : ""))
        }
        add("Needs", StrengthWords.need(required) + " your load"
            + (loadKg > 0 ? " (" + StrengthWords.load(required * loadKg, unit) + ")" : ""))
        // ★ notes30 (362's review): a load on bare vines has no valid margin — no weakest spot, struts short or solid margin
        let checked = bareVines == nil
        if checked { add("Weakest spot", weakestSpot, info: weakestSpotInfo) }   // ★ notes27 F2: was "Gives first at: A strut · …"
        if checked, let short = strutsShort, let judged = strutsJudged, judged > 0 {
            add("Struts short", "\(LatticeFileFacts.number(short)) of \(LatticeFileFacts.number(judged)) checked")
        }
        if checked, let d = solidMargin {
            add("Solid part", StrengthWords.x(d) + (infillPercent < 100 ? " at \(infillPercent)% infill" : "")
                + (solidPassesAtInfill.map { " \u{00B7} OK at \($0)%" } ?? ""))
        }
        add("Plastic", plastic)
        // ★ notes27 F2 (his: "Load on struts: 77% of your load, where it presses — What does that mean?"): where his load
        // pushes on the part, the share of that force the lattice carries; the solid walls carry the rest
        if let s = loadShare, s > 0 {
            let p = Swift.min(100, Int((s * 100).rounded()))
            add("Lattice carries", "\(p)% of the load", info: Self.latticeCarriesInfo(p))
        }
        return r
    }

    /// ★ notes27 F2: what gives way first, in two or three words ("A strut", "The solid part"); the rest is in its (i).
    public var weakestSpot: String? {
        switch governs {
        case .strut?: return "A strut"
        case .solid?: return "The solid part"
        case nil: return nil
        }
    }

    /// ★ notes27 F2: the (i) behind "Weakest spot": what it is, how it fails, its size, where to see it.
    public var weakestSpotInfo: String? {
        let see = " To see it lit on the part, tap the strength line at the top of Checks, or play Break."
        switch governs {
        case .strut?:
            var t = "If the load keeps growing, this strut gives way first."
            if let w = weakest.first {
                if let a = Self.actionWords(w.action) { t += " " + a }
                if w.widthMM > 0 {
                    t += " It is " + StrengthWords.mm(w.widthMM) + " thick"
                        + (w.lengthMM > 0 ? String(format: " and %.1f mm long.", w.lengthMM) : ".")
                }
            }
            return t + see
        case .solid?: return "If the load keeps growing, the solid part gives way first, before any strut." + see
        case nil: return nil
        }
    }

    /// How the weakest strut fails, in plain words (core's axial force against its moment: `Strut.action`).
    static func actionWords(_ action: String) -> String? {
        switch action {
        case "bends": return "It bends rather than stretches."
        case "in tension": return "It is pulled along its length."
        case "in compression": return "It is squashed along its length."
        case "buckles": return "It buckles (bows out sideways)."
        default: return nil
        }
    }

    /// ★ notes27 F2: the (i) behind "Lattice carries".
    static func latticeCarriesInfo(_ p: Int) -> String {
        "Where your load pushes on the part, the lattice takes \(p)% of that force. The solid walls take the other \(100 - p)%."
    }
}

/// ★ C3: the solid's own margin per voxel (fields.bin block 2), only where core judged a voxel as solid, carried in the saved
/// report (the Results screen reads nothing else of fields.bin's later blocks): flat voxel indices and their margins, and the
/// weakest one's centre (the "gives first" place when the solid governs).
public struct SolidMarginVoxels: Equatable, Sendable {
    public static let reportKey = "app_solid_margins"
    public var indices: [Int32]
    public var margins: [Float]
    public var weakestAt: SIMD3<Double>?

    /// From fields.bin's solid-margin block (NaN / infinite / non-positive = not judged as solid).
    public static func from(block values: [Float], nx: Int, ny: Int, origin: SIMD3<Double>, spacing: Double) -> SolidMarginVoxels? {
        var idx: [Int32] = [], m: [Float] = []
        var best = Float.infinity, bestIdx = -1
        for (i, v) in values.enumerated() where v.isFinite && v > 0 {
            idx.append(Int32(i)); m.append(v)
            if v < best { best = v; bestIdx = i }
        }
        guard bestIdx >= 0, nx > 0, ny > 0 else { return nil }
        let plane = nx * ny, k = bestIdx / plane, rem = bestIdx % plane
        let at = origin + SIMD3(Double(rem % nx) + 0.5, Double(rem / nx) + 0.5, Double(k) + 0.5) * spacing
        return SolidMarginVoxels(indices: idx, margins: m, weakestAt: at)
    }

    public var json: [String: Any] {
        var o: [String: Any] = ["index": Self.b64(indices), "margin": Self.b64(margins)]
        if let w = weakestAt { o["weakest_at"] = [w.x, w.y, w.z] }
        return o
    }

    public static func decode(report r: [String: Any]) -> SolidMarginVoxels? {
        guard let o = r[reportKey] as? [String: Any], let i = o["index"] as? String, let m = o["margin"] as? String,
              let idx: [Int32] = unb64(i), let mar: [Float] = unb64(m), idx.count == mar.count, !idx.isEmpty else { return nil }
        let w = (o["weakest_at"] as? [NSNumber]).flatMap { $0.count == 3 ? SIMD3($0[0].doubleValue, $0[1].doubleValue, $0[2].doubleValue) : nil }
        return SolidMarginVoxels(indices: idx, margins: mar, weakestAt: w)
    }

    /// The margins on the whole grid (NaN where not judged).
    public func grid(count: Int) -> [Float] {
        var g = [Float](repeating: .nan, count: Swift.max(0, count))
        for (k, i) in indices.enumerated() where Int(i) >= 0 && Int(i) < g.count { g[Int(i)] = margins[k] }
        return g
    }

    static func b64<T>(_ a: [T]) -> String { a.withUnsafeBytes { Data($0).base64EncodedString() } }
    static func unb64<T>(_ s: String) -> [T]? {
        guard let d = Data(base64Encoded: s), d.count % MemoryLayout<T>.stride == 0 else { return nil }
        return d.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }
}

/// ★ C3 (2): the numbers' one format. A margin with two decimals ("1.34×"); the requirement as he set it ("needs 1.5×"); a width
/// with two decimals ("2.25 mm"); a load in whole units ("55 kg").
public enum StrengthWords {
    public static func x(_ m: Double) -> String { String(format: "%.2f\u{00D7}", m) }
    public static func need(_ m: Double) -> String {
        var s = String(format: "%.2f", m)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "\u{00D7}"
    }
    public static func mm(_ v: Double) -> String { String(format: "%.2f mm", v) }
    public static func load(_ kg: Double, _ unit: WeightUnit) -> String {
        "\(Int(unit.fromKg(kg).rounded())) \(unit.label)"
    }
}

extension ResultVariantVM {
    /// ★ notes25 C3: the same tab with core's governing margin (a print file's one "how strong" number).
    func withWorstCaseMargin(_ m: Double) -> ResultVariantVM {
        ResultVariantVM(index: index, variantIndex: variantIndex, kind: kind, latticeAlternative: latticeAlternative,
                        achievedVolumeFraction: achievedVolumeFraction, savingsPercent: savingsPercent, savingsLabel: savingsLabel,
                        massGrams: massGrams, massLabel: massLabel, supportCm3: supportCm3, supportLabel: supportLabel,
                        orientation: orientation, tiltDegrees: tiltDegrees, orientationSummary: orientationSummary,
                        layerShear: layerShear, maxStressMPa: maxStressMPa, worstCaseMargin: m,
                        minFeatureViolations: minFeatureViolations, minFeatureWarning: minFeatureWarning,
                        isRecommended: isRecommended, isGrowth: isGrowth, addedMaterial: addedMaterial,
                        growthLabel: growthLabel, growthPercent: growthPercent, rungLabel: rungLabel,
                        latticeAccepted: latticeAccepted)
    }
}

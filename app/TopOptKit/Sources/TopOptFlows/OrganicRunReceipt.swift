import Foundation

/// ★★★ WHAT AN ORGANIC RUN SAYS ABOUT ITSELF (2026-09-02) — read from the receipt's
/// `grading` object, never recomputed. The PR 353 amendment added these so an app can
/// tell a good run from a hollow one; the UI's job is to REPORT them and leave the
/// policy to the maintainer (§7: multi-component grown is an OPEN decision — do not
/// refuse it, do not accept it, say what the receipt says).
///
/// ★ NULL-TOLERANT BY CONSTRUCTION. A census stage that did not run is `null` in the
/// JSON, so every field here is optional and `lengthCensusMM` keeps the stage keys the
/// receipt used. Difference two stages only after checking both are present — §5's
/// "TEST FOR NEGATIVE/NULL BEFORE DIFFERENCING".
public struct OrganicRunReceipt: Equatable, Sendable {
    // The span export — the numbers the preview's index must match (§10).
    public var spanCount: Int?
    public var spanLengthMM: Double?
    public var spanPath: String?
    // Growth (grown mode only; `growthRan == false` on a traced run).
    public var growthRan: Bool?
    public var growthTipBudgetHit: Bool?          // ★ TRUE means the run TRUNCATED — surface it
    public var growthLayerHeightMM: Double?
    /// Grown mode: spans the join step refused. Carried, never judged (addendum
    /// 2026-09-03: expose the receipt fields, leave policy out).
    public var growthJoinRefusedSpan: Int?
    /// D2: the separation window core was asked for and what it achieved (mm). Displayed,
    /// never judged. `structurallyCertified` is core's Structural confirmation — a key
    /// core is adding; absent until then.
    public var requestedSpacingMinMM: Double? = nil
    public var requestedSpacingMaxMM: Double? = nil
    public var achievedSpacingMinMM: Double? = nil
    public var achievedSpacingMedianMM: Double? = nil
    public var achievedSpacingMaxMM: Double? = nil
    // ★ D2 — THE CONFIRMED KEYS (maintainer, 2026-09-03), all under `grading.organic`:
    // the fitting set core chose from, the survival bar it applied, what it selected
    // (a window under Auto, one separation under Fit), and the Structural verdict with
    // its numbers. Every one is absent until core's organic auto/fit lands; none is
    // computed here. `structural_verdict == "certified"` is the confirmation.
    public var fittingSeparationsMM: [Double]? = nil
    public var fitSurvivalBar: Double? = nil
    public var selectedWindowMM: [Double]? = nil          // auto: [lo, hi]
    public var selectedSeparationMM: Double? = nil        // fit
    public var structuralVerdict: String? = nil           // "certified" | "refused" | "not_run"
    public var structuralMargin: Double? = nil
    public var structuralStressP50MPa: Double? = nil
    public var structuralStressP95MPa: Double? = nil
    public var structuralStressP99MPa: Double? = nil
    public var structuralStressMaxMPa: Double? = nil
    public var structuralWorstStrut: String? = nil
    public var structuralGoverningLoadCase: String? = nil
    public var structuralKnockdownUsed: Double? = nil

    /// ★ D2, SAID IN ONE LINE — what core chose and from what, then what it achieved,
    /// then its Structural verdict. Displayed, never judged; absent fields are absent.
    public var spacingLine: String? {
        var parts: [String] = []
        if let w = selectedWindowMM, w.count == 2 {
            parts.append(String(format: "core chose window %.1f–%.1f mm", w[0], w[1]))
        } else if let s = selectedSeparationMM {
            parts.append(String(format: "core chose separation %.1f mm", s))
        } else if let lo = requestedSpacingMinMM, let hi = requestedSpacingMaxMM {
            parts.append(abs(hi - lo) < 1e-9 ? String(format: "separation %.1f mm", lo)
                                             : String(format: "window %.1f–%.1f mm", lo, hi))
        }
        if let f = fittingSeparationsMM, !f.isEmpty {
            parts.append("from " + f.map { String(format: "%.1f", $0) }.joined(separator: "/") + " mm that fit")
        }
        if let lo = achievedSpacingMinMM, let hi = achievedSpacingMaxMM {
            var a = String(format: "achieved %.1f–%.1f mm", lo, hi)
            if let m = achievedSpacingMedianMM { a += String(format: " (median %.1f)", m) }
            parts.append(a)
        }
        if let v = structuralVerdict {
            var s = "structural: \(v)"
            if let m = structuralMargin { s += String(format: " (margin %.2f)", m) }
            parts.append(s)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    // Contiguity — reported, never judged here.
    public var lengthSurvival: Double?            // written length / grown length
    public var emittedComponents: Int?
    public var emittedLargestLengthFraction: Double?
    public var emittedStrandedLengthMM: Double?
    /// Per emission stage, `nil` where the stage did not run.
    public var lengthCensusMM: [String: Double?]

    public init(spanCount: Int? = nil, spanLengthMM: Double? = nil, spanPath: String? = nil,
                growthRan: Bool? = nil, growthTipBudgetHit: Bool? = nil,
                growthLayerHeightMM: Double? = nil, lengthSurvival: Double? = nil,
                emittedComponents: Int? = nil, emittedLargestLengthFraction: Double? = nil,
                emittedStrandedLengthMM: Double? = nil, lengthCensusMM: [String: Double?] = [:],
                growthJoinRefusedSpan: Int? = nil) {
        self.spanCount = spanCount; self.spanLengthMM = spanLengthMM; self.spanPath = spanPath
        self.growthRan = growthRan; self.growthTipBudgetHit = growthTipBudgetHit
        self.growthLayerHeightMM = growthLayerHeightMM; self.lengthSurvival = lengthSurvival
        self.emittedComponents = emittedComponents
        self.emittedLargestLengthFraction = emittedLargestLengthFraction
        self.emittedStrandedLengthMM = emittedStrandedLengthMM; self.lengthCensusMM = lengthCensusMM
        self.growthJoinRefusedSpan = growthJoinRefusedSpan
    }

    /// ★ THE RECEIPT, SAID IN ONE LINE — the four fields the reviewer asked the UI to
    /// carry (addendum 2026-09-03: length survival, pieces, largest piece, joins
    /// refused), with nothing judged and nothing invented: absent fields are absent.
    public var contiguityLine: String? {
        var parts: [String] = []
        if let s = lengthSurvival { parts.append(String(format: "%.1f%% of traced length kept", s * 100)) }
        if let n = emittedComponents {
            var p = n == 1 ? "1 piece" : "\(n) pieces"
            if n > 1, let f = emittedLargestLengthFraction { p += String(format: " (largest %.0f%%)", f * 100) }
            parts.append(p)
        }
        if let j = growthJoinRefusedSpan, growthRan == true { parts.append("\(j) joins refused") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// From the receipt's top-level dictionary (the same `info` the strut-strength
    /// reader uses). Absent `grading` ⇒ every field nil — no numbers invented.
    public init(info: [String: Any]?) {
        // ★ THE ORGANIC FIELDS LIVE UNDER `grading.organic`, NOT `grading` (measured
        // on a real run_info.json, 2026-09-02: span_count 1240 / span_length_mm
        // 783.27785 / span_path sat in the nested object and this reader, looking one
        // level up, returned NOTHING — an empty receipt that could never say
        // MISMATCH). The nested object wins; the flat shape stays as the fallback.
        let top = (info?["grading"] as? [String: Any]) ?? [:]
        let g = (top["organic"] as? [String: Any]) ?? top
        func d(_ k: String) -> Double? { (g[k] as? NSNumber)?.doubleValue }
        func i(_ k: String) -> Int? { (g[k] as? NSNumber)?.intValue }
        func b(_ k: String) -> Bool? { (g[k] as? NSNumber)?.boolValue }
        spanCount = i("span_count"); spanLengthMM = d("span_length_mm")
        spanPath = g["span_path"] as? String
        growthRan = b("growth_ran"); growthTipBudgetHit = b("growth_tip_budget_hit")
        growthLayerHeightMM = d("growth_layer_height_mm")
        growthJoinRefusedSpan = i("growth_join_refused_span")
        // ★ D2 (maintainer, 2026-09-03): core decides what fits and what it chose; the
        // app DISPLAYS the window / separation from the receipt. These are the keys
        // core writes today; the fitting SET and the Structural confirmation
        // (`structural_certified`) are core-side additions in progress — read when
        // present, absent otherwise, never inferred here.
        requestedSpacingMinMM = d("requested_spacing_min_mm")
        requestedSpacingMaxMM = d("requested_spacing_max_mm")
        achievedSpacingMinMM = d("achieved_spacing_min_mm")
        achievedSpacingMedianMM = d("achieved_spacing_median_mm")
        achievedSpacingMaxMM = d("achieved_spacing_max_mm")
        func ds(_ k: String) -> [Double]? {
            (g[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        fittingSeparationsMM = ds("fitting_separations_mm")
        fitSurvivalBar = d("fit_survival_bar")
        selectedWindowMM = ds("selected_window_mm")
        selectedSeparationMM = d("selected_separation_mm")
        structuralVerdict = g["structural_verdict"] as? String
        structuralMargin = d("structural_margin")
        structuralStressP50MPa = d("structural_stress_p50_mpa")
        structuralStressP95MPa = d("structural_stress_p95_mpa")
        structuralStressP99MPa = d("structural_stress_p99_mpa")
        structuralStressMaxMPa = d("structural_stress_max_mpa")
        structuralWorstStrut = g["structural_worst_strut"].map { "\($0)" }
        structuralGoverningLoadCase = g["structural_governing_load_case"].map { "\($0)" }
        structuralKnockdownUsed = d("structural_knockdown_used")
        lengthSurvival = d("length_survival"); emittedComponents = i("emitted_components")
        emittedLargestLengthFraction = d("emitted_largest_length_fraction")
        emittedStrandedLengthMM = d("emitted_stranded_length_mm")
        var census: [String: Double?] = [:]
        if let c = g["length_census_mm"] as? [String: Any] {
            // ★ `updateValue`, not subscript: `dict[k] = nil` DELETES the key, and a stage
            // that did not run must stay PRESENT as nil so a caller can tell "did not
            // run" from "not reported" (§5: test for null before differencing).
            for (k, v) in c { census.updateValue((v as? NSNumber)?.doubleValue, forKey: k) }
        }
        lengthCensusMM = census
    }

    /// ★ THE §10 CROSS-CHECK: does an index built from the span file describe the
    /// object the run certified? nil when the receipt carries no export (nothing to
    /// check); otherwise a sentence naming the mismatch, or nil when they agree.
    public func mismatch(againstIndexedCount count: Int, totalLengthMM: Double,
                         lengthTolerance: Double = 1e-3) -> String? {
        guard let n = spanCount, let len = spanLengthMM else { return nil }
        if n != count {
            return "The preview indexed \(count) struts but the run emitted \(n) — "
                 + "the picture would not be the object that was certified."
        }
        let tol = max(lengthTolerance * max(len, 1), 1e-6)
        if abs(len - totalLengthMM) > tol {
            return String(format: "The preview's struts total %.1f mm but the run emitted "
                          + "%.1f mm — the picture would not be the object that was certified.",
                          totalLengthMM, len)
        }
        return nil
    }

    /// What to SAY about contiguity — a report, never a verdict (§7).
    public var contiguityReport: String? {
        guard let c = emittedComponents else { return nil }
        var s = c == 1 ? "One connected piece." : "\(c) separate pieces."
        if let f = emittedLargestLengthFraction {
            s += String(format: " The largest holds %.0f%% of the material.", f * 100)
        }
        if let st = emittedStrandedLengthMM, st > 0 {
            s += String(format: " %.0f mm is attached to nothing.", st)
        }
        if let sv = lengthSurvival { s += String(format: " Survival %.0f%%.", sv * 100) }
        if growthTipBudgetHit == true { s += " ★ The run hit its tip budget and TRUNCATED." }
        return s
    }
}

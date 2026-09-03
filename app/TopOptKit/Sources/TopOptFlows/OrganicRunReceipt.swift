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
                emittedStrandedLengthMM: Double? = nil, lengthCensusMM: [String: Double?] = [:]) {
        self.spanCount = spanCount; self.spanLengthMM = spanLengthMM; self.spanPath = spanPath
        self.growthRan = growthRan; self.growthTipBudgetHit = growthTipBudgetHit
        self.growthLayerHeightMM = growthLayerHeightMM; self.lengthSurvival = lengthSurvival
        self.emittedComponents = emittedComponents
        self.emittedLargestLengthFraction = emittedLargestLengthFraction
        self.emittedStrandedLengthMM = emittedStrandedLengthMM; self.lengthCensusMM = lengthCensusMM
    }

    /// From the receipt's top-level dictionary (the same `info` the strut-strength
    /// reader uses). Absent `grading` ⇒ every field nil — no numbers invented.
    public init(info: [String: Any]?) {
        let g = (info?["grading"] as? [String: Any]) ?? [:]
        func d(_ k: String) -> Double? { (g[k] as? NSNumber)?.doubleValue }
        func i(_ k: String) -> Int? { (g[k] as? NSNumber)?.intValue }
        func b(_ k: String) -> Bool? { (g[k] as? NSNumber)?.boolValue }
        spanCount = i("span_count"); spanLengthMM = d("span_length_mm")
        spanPath = g["span_path"] as? String
        growthRan = b("growth_ran"); growthTipBudgetHit = b("growth_tip_budget_hit")
        growthLayerHeightMM = d("growth_layer_height_mm")
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

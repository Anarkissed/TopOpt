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
    // ★ PR 355 receipt (2026-09-06), read against core/src/simp/observability.cpp.
    public var structuralRefusal: String? = nil
    public var structuralStatistic: String? = nil
    public var structuralKnockdownSource: String? = nil
    public var structuralGoverningCos2: Double? = nil
    public var structuralMaxOverAllowable: Double? = nil
    public var structuralMaxOverAllowableDistributed: Double? = nil
    public var structuralMaxDistributedMPa: Double? = nil
    public var structuralMaxExceedsAllowable: Bool? = nil
    public var transferTiesOn: Bool? = nil
    public var tieSwirl: Double? = nil
    public var tiesSeeded: Int? = nil
    public var tiesLanded: Int? = nil
    public var tiesRefusedReach: Int? = nil
    public var tiesRefusedMinorStress: Int? = nil
    public var overhangFilletOn: Bool? = nil
    public var filletedSpans: Int? = nil
    public var filletSkippedSpans: Int? = nil
    public var solidRimMM: Double? = nil
    public var shapeFitOn: Bool? = nil
    public var shapeFitVoxelsShrunk: Int? = nil
    public var spacingPrintFloorMM: Double? = nil
    public var spacingResolutionFloorMM: Double? = nil
    public var supportGridTooLarge: Bool? = nil
    public var tensorNote: String? = nil
    public var recommendFitFound: Bool? = nil
    public var recommendFitMM: Double? = nil
    public var recommendAutoFound: Bool? = nil
    public var recommendAutoLoMM: Double? = nil
    public var recommendAutoHiMM: Double? = nil
    public var recommendBandLoMM: Double? = nil
    public var recommendBandHiMM: Double? = nil
    public var recommendCollapsed: Bool? = nil
    public var syntheticStressRegions: Int? = nil
    public var syntheticStressVoxels: Int? = nil
    public var syntheticStressFully: Int? = nil
    public var syntheticStressBlended: Int? = nil
    /// Per face_id — receipt C, keyed by face.
    public struct SyntheticStressRow: Equatable, Sendable {
        public let foci: Int
        public let voxels: Int
        public let fully: Int
        public let blended: Int
        public init(foci: Int, voxels: Int, fully: Int, blended: Int) {
            self.foci = foci; self.voxels = voxels; self.fully = fully; self.blended = blended
        }
        /// "synthetic field: 4 foci, 12,480 of 12,480 voxels" / "carried load, untouched".
        public var text: String {
            if fully == 0 && blended == 0 { return "carried load, untouched" }
            return "synthetic field: \(foci) foci, \(fully) of \(voxels) voxels"
        }
    }
    public var syntheticStressByFace: [Int: SyntheticStressRow] = [:]

    /// ★ THE SMALLEST CELL, from the run: max(bead floor, one voxel) (brief §0).
    public var floorMM: Double? {
        guard let p = spacingPrintFloorMM ?? spacingResolutionFloorMM else { return nil }
        return Swift.max(p, spacingResolutionFloorMM ?? 0)
    }

    /// ★ THE CERTIFICATE, in the brief's display rule: the margin is the p99 number;
    /// the worst strut against its allowable comes from the DISTRIBUTED factor; a
    /// refusal names its gate. Never "likely": this is the run's own verdict.
    public var certificateLine: String? {
        guard let v = structuralVerdict, v != "not run", v != "not_run" else { return nil }
        var s: String
        switch v {
        case "certified":
            s = structuralMargin.map { String(format: "Certified · margin %.2f (p99)", $0) } ?? "Certified"
        case "refused":
            s = "Refused"
            if let m = structuralMargin { s += String(format: " · margin %.2f (p99)", m) }
            if let why = structuralRefusal, !why.isEmpty { s += " · " + why }
            else if structuralMaxExceedsAllowable == true { s += " · the worst strut exceeds its allowable" }
        default:
            s = "Certificate: \(v)"
        }
        if let f = structuralMaxOverAllowableDistributed, f > 0 {
            s += String(format: " · worst strut %.2f× allowable", f)
        }
        return s
    }

    /// The repairs the run applied, in one line.
    public var repairsLine: String? {
        var parts: [String] = []
        if let on = overhangFilletOn {
            if on, let n = filletedSpans { parts.append("\(n) spans flared") }
            if !on, let n = filletSkippedSpans { parts.append("\(n) spans left over air") }
        }
        if let on = transferTiesOn, on, let l = tiesLanded { parts.append("\(l) ties landed") }
        if let big = supportGridTooLarge, big { parts.append("support pass skipped (grid too large)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

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
        // ★ On main the approved separation arrives as the recommendation's FIT
        // (`recommend.fit_mm`); the older `fitting_separations_mm` stays as a fallback.
        fittingSeparationsMM = ds("fitting_separations_mm")
            ?? ((g["recommend"] as? [String: Any]).flatMap { r -> [Double]? in
                guard (r["fit_found"] as? NSNumber)?.boolValue == true,
                      let mm = (r["fit_mm"] as? NSNumber)?.doubleValue, mm > 0 else { return nil }
                return [mm]
            })
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
        structuralRefusal = g["structural_refusal"] as? String
        structuralStatistic = g["structural_statistic"] as? String
        structuralKnockdownSource = g["structural_knockdown_source"] as? String
        structuralGoverningCos2 = d("structural_governing_cos2")
        structuralMaxOverAllowable = d("structural_max_over_allowable")
        structuralMaxOverAllowableDistributed = d("structural_max_over_allowable_distributed")
        structuralMaxDistributedMPa = d("structural_max_distributed_mpa")
        structuralMaxExceedsAllowable = b("structural_max_exceeds_allowable")
        transferTiesOn = b("transfer_ties_on"); tieSwirl = d("tie_swirl")
        tiesSeeded = i("ties_seeded"); tiesLanded = i("ties_landed")
        tiesRefusedReach = i("ties_refused_reach"); tiesRefusedMinorStress = i("ties_refused_minor_stress")
        overhangFilletOn = b("overhang_fillet_on"); filletedSpans = i("filleted_spans")
        filletSkippedSpans = i("fillet_skipped_spans")
        solidRimMM = d("solid_rim_mm"); shapeFitOn = b("shape_fit_on")
        shapeFitVoxelsShrunk = i("shape_fit_voxels_shrunk")
        spacingPrintFloorMM = d("spacing_print_floor_mm")
        spacingResolutionFloorMM = d("spacing_resolution_floor_mm")
        supportGridTooLarge = b("support_grid_too_large")
        tensorNote = g["tensor_note"] as? String
        if let rec = g["recommend"] as? [String: Any] {
            func rd(_ k: String) -> Double? { (rec[k] as? NSNumber)?.doubleValue }
            func rb(_ k: String) -> Bool? { (rec[k] as? NSNumber)?.boolValue }
            recommendFitFound = rb("fit_found"); recommendFitMM = rd("fit_mm")
            recommendAutoFound = rb("auto_found")
            recommendAutoLoMM = rd("auto_lo_mm"); recommendAutoHiMM = rd("auto_hi_mm")
            recommendBandLoMM = rd("band_lo_mm"); recommendBandHiMM = rd("band_hi_mm")
            recommendCollapsed = rb("collapsed")
        }
        syntheticStressRegions = i("synthetic_stress_regions"); syntheticStressVoxels = i("synthetic_stress_voxels")
        syntheticStressFully = i("synthetic_stress_fully"); syntheticStressBlended = i("synthetic_stress_blended")
        if let rows = g["synthetic_stress_by_region"] as? [[String: Any]] {
            for r in rows {
                guard let f = (r["face_id"] as? NSNumber)?.intValue, f >= 0 else { continue }
                syntheticStressByFace[f] = SyntheticStressRow(
                    foci: (r["foci"] as? NSNumber)?.intValue ?? 0,
                    voxels: (r["voxels"] as? NSNumber)?.intValue ?? 0,
                    fully: (r["fully"] as? NSNumber)?.intValue ?? 0,
                    blended: (r["blended"] as? NSNumber)?.intValue ?? 0)
            }
        }
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

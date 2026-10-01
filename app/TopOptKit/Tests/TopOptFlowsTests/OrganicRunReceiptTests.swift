import XCTest
@testable import TopOptFlows

final class OrganicRunReceiptTests: XCTestCase {
    func testReadsTheGradingObjectAndTolerateNulls() {
        let info: [String: Any] = ["grading": [
            "span_count": 106464, "span_length_mm": 51234.5, "span_path": "/x/run_SPANS.txt",
            "growth_ran": true, "growth_tip_budget_hit": true, "growth_layer_height_mm": 0.2,
            "length_survival": 1.028, "emitted_components": 1,
            "emitted_largest_length_fraction": 1.0, "emitted_stranded_length_mm": 0.0,
            "length_census_mm": ["grown": 1000.0, "pruned": NSNull(), "emitted": 1028.0],
        ]]
        let r = OrganicRunReceipt(info: info)
        XCTAssertEqual(r.spanCount, 106464); XCTAssertEqual(r.spanPath, "/x/run_SPANS.txt")
        XCTAssertEqual(r.growthTipBudgetHit, true)
        XCTAssertEqual(r.lengthCensusMM["grown"] ?? nil, 1000)
        XCTAssertNotNil(r.lengthCensusMM.index(forKey: "pruned")); XCTAssertNil(r.lengthCensusMM["pruned"] ?? nil,
            "★ a stage that did not run is nil, not 0 — never difference it")
        XCTAssertTrue(r.contiguityReport!.contains("TRUNCATED"), "★ tip budget hit must be surfaced")
        XCTAssertEqual(OrganicRunReceipt(info: nil), OrganicRunReceipt(), "absent grading ⇒ nothing invented")
    }
    func testTheCrossCheckFailsLoudlyOnAnyMismatch() {
        let r = OrganicRunReceipt(spanCount: 10, spanLengthMM: 100)
        XCTAssertNil(r.mismatch(againstIndexedCount: 10, totalLengthMM: 100.00001))
        XCTAssertNotNil(r.mismatch(againstIndexedCount: 9, totalLengthMM: 100))
        XCTAssertNotNil(r.mismatch(againstIndexedCount: 10, totalLengthMM: 90))
        XCTAssertNil(OrganicRunReceipt().mismatch(againstIndexedCount: 5, totalLengthMM: 1),
                     "no export in the receipt ⇒ nothing to check")
    }

    /// ★ THE REAL SHAPE. Pinned from `run_info.json` of a lattice-variant replay of the
    /// on-device job (2026-09-02): core nests every organic field under
    /// `grading.organic`. A reader one level up saw nothing — the first receipt test
    /// built a FLAT dictionary and so passed while the app's receipt was empty.
    func testFieldsAreReadFromTheNestedOrganicObjectCoreActuallyWrites() {
        let info: [String: Any] = ["grading": [
            "algorithm": "organic", "topology": "octet",
            "organic": ["span_count": 1240, "span_length_mm": 783.27785,
                        "span_path": "out/variant_024_lattice_SPANS.txt",
                        "length_survival": 0.1301973212, "tensor_out_of_regime": true,
                        "emitted_components": 1,
                        "length_census_mm": ["traced": 6016.0, "emitted": 783.27785]]
        ]]
        let r = OrganicRunReceipt(info: info)
        XCTAssertEqual(r.spanCount, 1240)
        XCTAssertEqual(r.spanLengthMM ?? 0, 783.27785, accuracy: 1e-9)
        XCTAssertEqual(r.spanPath, "out/variant_024_lattice_SPANS.txt")
        XCTAssertEqual(r.lengthSurvival ?? 0, 0.1301973212, accuracy: 1e-12)
        XCTAssertEqual(r.emittedComponents, 1)
        // the by-hand §10 check on the replay: 1240 SEG lines, 783.28 mm recomputed
        XCTAssertNil(r.mismatch(againstIndexedCount: 1240, totalLengthMM: 783.28))
        XCTAssertNotNil(r.mismatch(againstIndexedCount: 1239, totalLengthMM: 783.28))
    }

    /// ★ THE FOUR FIELDS THE UI CARRIES (addendum 2026-09-03): survival, pieces,
    /// largest, joins refused — one line, absent fields absent, nothing judged. Pinned
    /// to the traced replay of run 2 (survival 0.130, 5 pieces, largest 45.2 %) and to
    /// a grown-shaped receipt for the join count.
    func testTheContiguityLineCarriesTheReceiptAndJudgesNothing() {
        let traced = OrganicRunReceipt(info: ["grading": ["organic": [
            "length_survival": 0.1301973212, "emitted_components": 5,
            "emitted_largest_length_fraction": 0.4518794471, "growth_ran": false]]])
        XCTAssertEqual(traced.contiguityLine, "13.0% of traced length kept · 5 pieces (largest 45%)")
        XCTAssertNil(traced.growthJoinRefusedSpan)
        let grown = OrganicRunReceipt(info: ["grading": ["organic": [
            "length_survival": 0.5, "emitted_components": 1, "growth_ran": true,
            "growth_join_refused_span": 12]]])
        XCTAssertEqual(grown.growthJoinRefusedSpan, 12)
        XCTAssertEqual(grown.contiguityLine, "50.0% of traced length kept · 1 piece · 12 joins refused")
        XCTAssertNil(OrganicRunReceipt(info: nil).contiguityLine, "no receipt ⇒ no line, no invention")
    }

    /// ★ D2: the window / separation is DISPLAYED from the receipt, never computed
    /// here. Pinned to the traced replay of run 2 (requested 5.5–6, achieved
    /// 2.95–8.39, median 5.39); the Structural confirmation key is absent until core
    /// writes it, and then shown verbatim.
    func testTheSpacingLineDisplaysCoresWindowAndNothingElse() {
        let r = OrganicRunReceipt(info: ["grading": ["organic": [
            "requested_spacing_min_mm": 5.5, "requested_spacing_max_mm": 6,
            "achieved_spacing_min_mm": 2.946533982, "achieved_spacing_max_mm": 8.386092124,
            "achieved_spacing_median_mm": 5.386302931]]])
        XCTAssertEqual(r.spacingLine, "window 5.5–6.0 mm · achieved 2.9–8.4 mm (median 5.4)")
        XCTAssertNil(r.structuralVerdict, "absent until core writes it")
        XCTAssertNil(r.fittingSeparationsMM)
        XCTAssertNil(OrganicRunReceipt(info: nil).spacingLine)
    }

    /// ★ THE CONFIRMED D2 KEYS (maintainer, 2026-09-03), under grading.organic: the
    /// fitting set, the survival bar, the selection (window under Auto, one
    /// separation under Fit) and the Structural verdict with its numbers. Read
    /// verbatim, displayed, never inferred; `structural_verdict == "certified"` IS the
    /// confirmation (no bool of the app's own).
    func testTheConfirmedD2KeysAreReadVerbatim() {
        let auto = OrganicRunReceipt(info: ["grading": ["organic": [
            "fitting_separations_mm": [3.0, 3.5, 4.0, 4.5], "fit_survival_bar": 0.6,
            "selected_window_mm": [3.0, 4.5],
            "structural_verdict": "certified", "structural_margin": 1.42,
            "structural_stress_p50_mpa": 3.1, "structural_stress_p95_mpa": 9.8,
            "structural_stress_p99_mpa": 14.2, "structural_stress_max_mpa": 21.7,
            "structural_worst_strut": 118, "structural_governing_load_case": "gravity+10lb",
            "structural_knockdown_used": 0.75]]])
        XCTAssertEqual(auto.fittingSeparationsMM ?? [], [3.0, 3.5, 4.0, 4.5])
        XCTAssertEqual(auto.fitSurvivalBar, 0.6)
        XCTAssertEqual(auto.selectedWindowMM ?? [], [3.0, 4.5]); XCTAssertNil(auto.selectedSeparationMM)
        XCTAssertEqual(auto.structuralVerdict, "certified"); XCTAssertEqual(auto.structuralMargin, 1.42)
        XCTAssertEqual(auto.structuralStressP99MPa, 14.2); XCTAssertEqual(auto.structuralStressMaxMPa, 21.7)
        XCTAssertEqual(auto.structuralWorstStrut, "118")
        XCTAssertEqual(auto.structuralGoverningLoadCase, "gravity+10lb")
        XCTAssertEqual(auto.structuralKnockdownUsed, 0.75)
        XCTAssertEqual(auto.spacingLine,
                       "core chose window 3.0–4.5 mm · from 3.0/3.5/4.0/4.5 mm that fit · structural: certified (margin 1.42)")
        let fit = OrganicRunReceipt(info: ["grading": ["organic": [
            "fitting_separations_mm": [4.0, 6.0], "selected_separation_mm": 6.0,
            "structural_verdict": "not_run"]]])
        XCTAssertEqual(fit.selectedSeparationMM, 6.0)
        XCTAssertEqual(fit.spacingLine, "core chose separation 6.0 mm · from 4.0/6.0 mm that fit · structural: not_run")
    }
}

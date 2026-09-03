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
}

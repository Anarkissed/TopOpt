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
}

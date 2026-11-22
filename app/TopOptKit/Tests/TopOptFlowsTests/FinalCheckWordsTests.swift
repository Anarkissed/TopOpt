import XCTest
@testable import TopOptFlows

/// ★ R-07 (reviewer ruling 11-22): a streamed version the final check on its print file refused is named with why; when
/// none is left, the pop-up names each refused file and the last design's own numbers, never the generic margin line.
final class FinalCheckWordsTests: XCTestCase {
    private func blocks(_ rejected: [[String: Any]]) -> RunReportBlocks {
        RunReportBlocks.decode(report: [
            "variants": [["volume_fraction": 0.6, "accepted": true]],
            "rejected_variants": rejected])
    }
    private let piecesRow: [String: Any] = [
        "volume_fraction": 0.4, "accepted": false, "rejection_reason": "After finishing, it prints in 2 pieces",
        "finish": ["verdict_changed": true, "verdict_reason": "After finishing, it prints in 2 pieces"]]
    private let marginRow: [String: Any] = [
        "volume_fraction": 0.2, "accepted": false, "rejection_reason": "margin below required"]

    func testCoreReasonInPlainWords() {
        XCTAssertEqual(FinalCheckWords.reason("After finishing, it prints in 2 pieces"), "It prints in 2 pieces")
        XCTAssertEqual(FinalCheckWords.reason("After finishing, the file is not one clean solid (2 bad edge(s))"),
                       "The file is not one clean solid (2 bad edges)")
        XCTAssertEqual(FinalCheckWords.reason("After finishing, the file is not one clean solid (1 bad edge(s))"),
                       "The file is not one clean solid (1 bad edge)")
        XCTAssertEqual(FinalCheckWords.reason("With the slim finish, the load no longer reaches an anchor"),
                       "The load no longer reaches an anchor")
        XCTAssertEqual(FinalCheckWords.reason("A Keep clear is sealed inside the part"), "A Keep clear is sealed inside the part")
    }

    func testOnlyTheVersionsTheFinishingRefusedAreNamed() {
        let b = blocks([piecesRow, marginRow])
        XCTAssertEqual(FinalCheckWords.refused(b).map(\.volumeFraction), [0.4])
        let c = FinalCheckWords.checks(b, letters: [0.6: "a", 0.4: "b"])
        XCTAssertEqual(c.map(\.title), ["Version b removed"])
        XCTAssertEqual(c.first?.detail, "Its file failed the final check: it prints in 2 pieces")
        XCTAssertEqual(c.first?.kind, .warn)
        XCTAssertEqual(FinalCheckWords.checks(b, letters: [:]).map(\.title), ["A version removed"])   // never shown: no letter
        XCTAssertTrue(FinalCheckWords.checks(blocks([marginRow]), letters: [0.4: "b"]).isEmpty)   // nothing refused: no line
    }

    func testThePopUpNamesTheRealCauseNotTheMarginLine() {
        let b = blocks([piecesRow, marginRow])
        let last = RunFailure.rejectionBody(worstMargin: 1.21, effectiveMargin: 1.21, violations: 0, diagnosis: nil)
        let f = RunFailure.allRefusedAtFinalCheck(lines: FinalCheckWords.lines(b, letters: [0.4: "b"]), lastTried: last)
        XCTAssertEqual(f.title, "No print file passed the final check")
        XCTAssertTrue(f.message.hasPrefix("The final check on the print file refused every version strong enough:\n• Version b: it prints in 2 pieces"),
                      f.message)
        XCTAssertTrue(f.message.contains("\n\nThe last design the run tried: this design's worst-case stress margin is 1.21×"), f.message)
        XCTAssertFalse(RunFailure.allRefusedAtFinalCheck(lines: ["Version a: it prints in 2 pieces"], lastTried: nil)
            .message.contains("last design"))
    }
}

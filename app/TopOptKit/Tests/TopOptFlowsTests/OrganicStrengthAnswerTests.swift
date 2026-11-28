// OrganicStrengthAnswerTests — ★ A1: the app reads the Organic file's own strength answer (`strength_answer` in lattice_file.json,
// spec build-c2.md "SPEC FOR 362, CORRECTED" + C7-C12). Samples are the spec's pasted real ones (shortened); the red control is a
// file with no `strength_answer`, which keeps today's rod-check reading.
import XCTest
@testable import TopOptFlows

final class OrganicStrengthAnswerTests: XCTestCase {

    /// A report of the shape the app holds: layout + mesh + strength (with `break`), plus the top-level answer.
    private func report(answer: String, brk: String, extra: String = "") -> [String: Any] {
        let json = """
        {"layout": {"bars": 3}, "mesh": {"mm3": 1.0},
         "strength": {"accepted": true, "verdict": "pass", "safety_margin": 1.5, "struts": {"smallest_margin": 0.4, "under_safety": 9},
                      "weakest": [{"at": [1,2,3], "margin": 0.4, "width_mm": 1.0}], "answer": "break", "break": \(brk)},
         "strength_answer": \(answer)\(extra)}
        """
        return try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private func answer(_ r: [String: Any]) -> LatticeStrengthAnswer { LatticeStrengthAnswer.decode(report: r)! }

    func testPassShowsTheBreakCheckNotTheRodNumbers() {
        let a = answer(report(
            answer: #"{"by": "break", "accepted": true, "verdict": "pass", "reason": "", "pass_line": 1.5, "pass_allowance": 1.5}"#,
            brk: #"{"cache": "made", "verdict": "pass", "pass_line": 1.5, "not_proven_because": [], "first_break": {"multiple": 20.4964142, "at": [8.5, 13.1, 14.5], "class": "solid"}}"#))
        XCTAssertNotNil(a.organic)
        XCTAssertEqual(a.check().title, "Strong enough")
        XCTAssertEqual(a.check().detail, "Holds 20.50\u{00D7} \u{00B7} needs 1.5\u{00D7}")
        XCTAssertEqual(a.governing, 20.4964142)
        XCTAssertTrue(a.weakest.isEmpty)               // the rod check's weakest strut (margin 0.4) is not shown
        XCTAssertNil(a.strutMargin)
        XCTAssertEqual(a.place, SIMD3(8.5, 13.1, 14.5))
        let rows = a.rows(loadKg: 2, unit: .kg, infillPercent: 20, plastic: nil).map(\.label)
        XCTAssertTrue(rows.contains("Holds") && !rows.contains("Weakest spot") && !rows.contains("Struts short"))
    }

    func testNotCheckedReasonsIncludingBearingAnchors() {
        for (reason, words) in [("too_big", "Part too big to check"), ("did_not_settle", "Check did not settle"),
                                ("bearing_anchors", "Bolted holds: strength not checked"), ("brand_new_reason", "Strength not checked")] {
            let a = answer(report(answer: #"{"by": "break", "accepted": false, "verdict": "not_checked", "reason": "\#(reason)"}"#,
                                  brk: #"{"verdict": "not_checked", "reason": "\#(reason)", "first_break": null}"#))
            XCTAssertEqual(a.check().title, "Strength not checked")
            XCTAssertEqual(a.check().detail, words)
            XCTAssertNil(a.governing)
            XCTAssertEqual(a.check().kind, .warn)
        }
    }

    func testNotProvenWordsCloseToLimitNullAndUnknownReason() {
        let a = answer(report(
            answer: #"{"by": "break", "accepted": false, "verdict": "not_proven", "reason": "", "pass_line": 1.5, "pass_allowance": 1.5}"#,
            brk: #"{"verdict": "not_proven", "not_proven_because": ["post_load_path_not_resolved", "close_to_pass_line", "unresolved_joint", "something_new"], "first_break": {"multiple": null, "at": null}, "load_path": {"posts": [{"post": 0, "share": 0.15, "blocks": true, "shaft_resolved": false}], "regions_by_load": [{"kind": "connector", "load_share": 2.18, "at": [5.1, 2.7, 2.7], "voxels": 1}, {"kind": "thin_member", "at": [1, 1, 1]}]}}"#,
            extra: #", "posts_step": {"rounds": 1, "by_round": [{"round": 1, "posts": [{"post": 0, "changed": true}, {"post": 1, "changed": false}]}], "still_short": [{"post": 1, "why": "it carries 10 % of the load"}]}"#))
        XCTAssertEqual(a.check().title, "Strength not proven")
        XCTAssertEqual(a.check().detail, "Post too thin to judge")           // the first word; no number for a not-proven verdict
        XCTAssertNil(a.governing)
        XCTAssertEqual(a.organic?.notProvenBecause.map(OrganicStrengthAnswer.provenWords),
                       ["Post too thin to judge", "Close to the limit", "Thin joint carries the load", "Strength not proven"])
        XCTAssertEqual(OrganicStrengthAnswer.regionWords("thin_member"), "Thin strut carries the load")
        XCTAssertEqual(a.organic?.postsStrengthened, 1)
        XCTAssertEqual(a.organic?.stillShort, ["it carries 10 % of the load"])
        let rows = a.rows(loadKg: 0, unit: .kg, infillPercent: 20, plastic: nil)
        XCTAssertEqual(rows.first { $0.label == "Posts strengthened" }?.value, "1")
        XCTAssertNil(a.organic?.firstBreakMultiple)                         // JSON null reads as nil, never a crash
        XCTAssertNotNil(a.place)
    }

    func testRedControlNoAnswerKeepsTheRodReading() {
        var r = report(answer: "{}", brk: "{}")
        r["strength_answer"] = nil
        let a = answer(r)
        XCTAssertNil(a.organic)
        XCTAssertEqual(a.strutMargin, 0.4)
        XCTAssertEqual(a.weakest.count, 1)
        XCTAssertNil(OrganicStrengthAnswer.decode(report: r))
    }
}

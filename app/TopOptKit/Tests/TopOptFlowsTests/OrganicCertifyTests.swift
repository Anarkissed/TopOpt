// OrganicCertifyTests — ★ his certify wizard's model (his design 11-19): one pop-up per issue, the spots of one issue grouped,
// in his order (lattice settings, then infill, then model changes), each with its place and its Solve; infill offered only when
// a higher infill passes. RED CONTROLS: a passing result has no pop-ups; an infill that does not pass is not offered.
import XCTest
import simd
@testable import TopOptFlows

final class OrganicCertifyTests: XCTestCase {

    static func spot(_ id: Int, _ issue: String, _ m: Double, at: [Double]) -> [String: Any] {
        ["id": id, "issue": issue, "kind": issue, "advice": "advice for \(issue)", "worst_at": at, "effective_margin": m,
         "passes_at_infill_percent": 80]
    }

    /// A Grown-like failure: struts short after strengthening, the solid short at 50 % with spots of three kinds.
    static func report(verdict: String = "fail", reason: String = "solid_margin", passAt: Any = 81, under: Int = 3,
                       spots: [[String: Any]]? = nil) -> [String: Any] {
        let list = spots ?? [spot(1, "beside_the_lattice", 0.58, at: [10, 20, 49]), spot(2, "beside_a_fixing", 0.9, at: [1, 2, 3]),
                             spot(3, "beside_the_lattice", 0.71, at: [11, 21, 48]), spot(4, "inside_the_solid", 1.1, at: [5, 5, 5])]
        return [
            "strength": [
                "verdict": verdict, "accepted": verdict != "fail", "fail_reason": reason, "safety_margin": 1.5,
                "struts": ["judged": 900, "under_safety": under, "smallest_margin": 1.38],
                "weakest": [["at": [3, 4, 5], "margin": 1.42], ["at": [6, 7, 8], "margin": 1.38]],
                "solid_margin": ["effective": 0.58, "passes_at_infill_percent": passAt, "spots_total": list.count, "spots": list,
                                 "text": "The solid part is not certifying at 50% infill. 81% infill is one solution."],
            ] as [String: Any],
            LatticeFileButton.strengthenKey: ["code": "limit", "rounds": [[:], [:], [:], [:], [:], [:]]],
        ]
    }

    func testOnePopUpPerIssueInHisOrder() {
        let issues = OrganicCertify.issues(report: Self.report(), infillNow: 50)
        XCTAssertEqual(issues.map(\.id), ["struts_short", "beside_the_lattice", "infill", "beside_a_fixing", "inside_the_solid"],
                       "★ his order: lattice settings, then infill, then model changes")
        XCTAssertEqual(issues.map(\.stage), [.lattice, .lattice, .infill, .model, .model])
        let near = issues[1]
        XCTAssertEqual(Set(near.spotIDs), [1, 3], "★ the spots of one issue grouped: one pop-up")
        XCTAssertEqual(near.title, "2 weak areas beside the lattice")
        XCTAssertEqual(near.at, SIMD3(10, 20, 49), "★ its line goes to the worst of them")
        XCTAssertEqual(near.solve, .keepLatticeAway)
        let struts = issues[0]
        XCTAssertEqual(struts.title, "3 struts are still short")
        XCTAssertTrue(struts.text.contains("1.38×") && struts.text.contains("6 rounds"), struts.text)
        XCTAssertEqual(struts.at, SIMD3(6, 7, 8), "★ the line goes to the weakest strut")
        XCTAssertEqual(struts.solve, .strutThickness)
        let infill = issues[2]
        XCTAssertEqual(infill.solve, .infill(percent: 81), "★ the lowest infill that passes")
        XCTAssertEqual(infill.text, "The solid part is not certifying at 50% infill. 81% infill is one solution.",
                       "★ his own words, as the check writes them")
        XCTAssertEqual(Set(infill.spotIDs), [1, 2, 3, 4])
        XCTAssertNil(issues[3].solve, "★ a model change: Next")
        XCTAssertEqual(issues[3].text, "advice for beside_a_fixing")
        XCTAssertEqual(OrganicCertify.infillLines(from: 50, to: 81, layerMM: 0.2, walls: 6, newVersion: "v4", ranVersion: "v3"),
                       ["Infill 50% → 81%", "Layers 0.2 mm · 6 walls", "Made as v4 · v3 keeps 50%"],
                       "★ the print settings shown, and the new version said")
    }

    func testTheLoadOnOpenLatticeComesFirstAndPassesHaveNone() {
        let open = OrganicCertify.issues(report: Self.report(reason: "load_on_open_lattice", under: 0, spots: []), infillNow: 50)
        XCTAssertEqual(open.first?.id, "load_on_open_lattice")
        XCTAssertEqual(open.first?.solve, .protectLoadedFace)
        XCTAssertFalse(open.contains { $0.id == "infill" }, "the solid is not why it failed: no infill offer")
        XCTAssertTrue(OrganicCertify.issues(report: Self.report(verdict: "pass", under: 0), infillNow: 50).isEmpty,
                      "RED CONTROL: it certifies: no pop-ups")
        XCTAssertFalse(OrganicCertify.issues(report: Self.report(passAt: NSNull()), infillNow: 50).contains { $0.id == "infill" },
                       "RED CONTROL: no infill passes: none offered")
        XCTAssertFalse(OrganicCertify.issues(report: Self.report(passAt: 40), infillNow: 50).contains { $0.id == "infill" },
                       "RED CONTROL: never offered lower than what he prints")
        XCTAssertTrue(OrganicCertify.issues(report: [:], infillNow: 50).isEmpty, "no check: nothing")
    }

    func testSpotsAreReadAsTheCheckWritesThem() {
        let s = OrganicCertify.spots(Self.report()["strength"] as! [String: Any])
        XCTAssertEqual(s.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(s[0].issue, "beside_the_lattice")
        XCTAssertEqual(s[0].worstAt, SIMD3(10, 20, 49))
        XCTAssertEqual(s[0].effectiveMargin, 0.58, accuracy: 1e-12)
        XCTAssertEqual(s[0].passesAtInfill, 80)
    }
}

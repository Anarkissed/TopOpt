// ChecksTapHostedTests — B4, ledger notes 14 and 15 (c) (approved design 2026-11-02, plan.md §B4, mockup #topo-results-checks).
//
// His words: "The results page 'Checks' should be tappable and show what it is talking about with some details if requested."
// Every check is a tap: it lights its places on the part and opens one line under it with "Details ›" (that check's tab); a
// second tap closes it. With E1's finishing the thin-spot row says what core did — "Thin spots fixed · 6" or "2 thin spots
// left" with the reason ("Blocked by Keep clear"). plan.md's test: tap "2 thin spots left"; its line shows, and the markers'
// frames are inside the model area. A result from before E1 keeps today's row. RED before B4 (saved: scratchpad
// b2red/ChecksTap.txt): no finish read, the rows took no tap.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ChecksTapHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()

    /// The redesign's strengthen outcome, its first version finished by E1 with two spots left (and one fixed).
    static func finishedOutcome(left: Int = 2) throws -> OptimizeOutcome {
        let base = try ResultsRedesignTests.strengthenOutcome()
        var report = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(base.reportJSON)) as? [String: Any])
        var variants = try XCTUnwrap(report["variants"] as? [[String: Any]])
        variants[0]["finish"] = [
            "min_thickness_mm": 1.8, "min_thickness_source": "core line-width floor",
            "thin_spots_fixed": [["centre_mm": [0.2, 0.2, 0], "before_mm": 1.2, "after_mm": 1.8]],
            "thin_spots_left": (0..<left).map { i in
                ["centre_mm": [0.3 + 0.2 * Double(i), 0.3, 0], "thickness_mm": 1.1, "reason": "Blocked by Keep clear"] as [String: Any]
            },
            "surface_finish": ["applied": true, "stair_step_removed_pct": 51.6, "style": "slim"],
            "finish_fallback": false, "verdict_changed": false, "verdict_reason": ""] as [String: Any]
        report["variants"] = variants
        return OptimizeOutcome(variants: base.variants, stoppedOnMargin: false, cancelled: false, acceptedCount: base.acceptedCount,
                               gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1,
                               reportJSON: try JSONSerialization.data(withJSONObject: report))
    }

    func testTapTheThinSpotsLeftItsLineShowsAndTheMarkersAreOnThePart() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let o = try Self.finishedOutcome()
            let rm = ResultsModel(projectName: "CarriageArms", outcome: o)
            let h = ui.host(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {}, resultsModel: rm)
                                .frame(width: size.width, height: size.height), size: size)
            ui.pump(2)
            let what = "\(size)"
            let row = try XCTUnwrap(h.frames.all["resultsCheck-2 thin spots left"],
                                    "\(what): ★ the thin-spot row says what core could not fix: \(h.frames.all.keys.filter { $0.hasPrefix("resultsCheck") }.sorted())")
            XCTAssertNil(h.frames.all["resultsCheckMore-2 thin spots left"], "\(what): closed until tapped")
            ui.click(h, CGPoint(x: row.midX, y: row.midY))
            let more = try XCTUnwrap(h.frames.all["resultsCheckMore-2 thin spots left"], "\(what): ★ its one line shows")
            XCTAssertGreaterThan(more.minY, row.minY, "\(what): under the row")
            _ = try XCTUnwrap(h.frames.all["resultsCheckDetails-2 thin spots left"], "\(what): ★ Details › on its line")
            let screen = CGRect(origin: .zero, size: size)
            let panels = ["resultsVersions", "resultsChecks", "resultsViewModes", "resultsExport"].compactMap { h.frames.all[$0] }
            for i in 0..<2 {
                let m = try XCTUnwrap(h.frames.all["resultsCheckMarker-\(i)"], "\(what): ★ spot \(i + 1) is lit on the part")
                XCTAssertTrue(screen.contains(m), "\(what): ★ the marker is on the screen: \(m)")
                for p in panels { XCTAssertFalse(p.intersects(m.insetBy(dx: 2, dy: 2)), "\(what): ★ the marker sits in the model area, not under \(p)") }
            }
            // a second tap closes it, and its markers go
            ui.click(h, CGPoint(x: row.midX, y: row.midY))
            XCTAssertNil(h.frames.all["resultsCheckMore-2 thin spots left"], "\(what): ★ a second tap closes it")
            XCTAssertNil(h.frames.all["resultsCheckMarker-0"])
        }
    }

    func testDetailsOpensThatChecksTab() throws {
        let o = try Self.finishedOutcome()
        let rm = ResultsModel(projectName: "CarriageArms", outcome: o)
        let size = AppBuildHost.landscape13
        let h = ui.host(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {}, resultsModel: rm)
                            .frame(width: size.width, height: size.height), size: size)
        ui.pump(2)
        let row = try XCTUnwrap(h.frames.all["resultsCheck-2 thin spots left"])
        ui.click(h, CGPoint(x: row.midX, y: row.midY))
        let d = try XCTUnwrap(h.frames.all["resultsCheckDetails-2 thin spots left"])
        ui.click(h, CGPoint(x: d.midX, y: d.midY))
        XCTAssertNotNil(h.frames.all["resultsDetailsPanel"], "★ Details opens, on the Printing tab")
    }

    /// The words, all fixed, a fallback, a changed verdict, and a result from before E1.
    func testTheFinishRowsAndAnOlderResult() {
        func f(fixed: Int, left: Int, fallback: Bool = false, verdict: String = "") -> FinishReport {
            let p = FinishReport.Place(centreMM: .zero, beforeMM: 1, afterMM: 1.8, reason: nil)
            let q = FinishReport.Place(centreMM: .zero, beforeMM: 1.1, afterMM: nil, reason: "Blocked by Keep clear")
            return FinishReport(minThicknessMM: 1.8, fixed: Array(repeating: p, count: fixed), left: Array(repeating: q, count: left),
                                stairStepRemovedPct: 51.6, fallback: fallback,
                                fallbackReason: fallback ? "The slim finish would take a member under 1.68 mm." : "",
                                verdictChanged: !verdict.isEmpty, verdictReason: verdict)
        }
        XCTAssertEqual(ResultsChecks.finishChecks(f(fixed: 6, left: 0)).map(\.title), ["Thin spots fixed \u{00B7} 6"])
        XCTAssertEqual(ResultsChecks.finishChecks(f(fixed: 1, left: 2)).first?.title, "2 thin spots left")
        XCTAssertEqual(ResultsChecks.finishChecks(f(fixed: 1, left: 2)).first?.detail, "Blocked by Keep clear", "★ why, in core's words")
        XCTAssertEqual(ResultsChecks.finishChecks(f(fixed: 1, left: 1)).first?.title, "1 thin spot left")
        XCTAssertTrue(ResultsChecks.finishChecks(f(fixed: 0, left: 0)).isEmpty, "nothing to say: no row")
        XCTAssertTrue(ResultsChecks.finishChecks(f(fixed: 0, left: 0, fallback: true)).contains { $0.title == "Finished the safe way" })
        XCTAssertTrue(ResultsChecks.finishChecks(f(fixed: 0, left: 0, verdict: "A Keep clear has material in it")).contains {
            $0.title == "Finishing changed a check" && $0.detail == "A Keep clear has material in it" })
        // a result from before E1: no finish, today's row
        XCTAssertNil(FinishReport.decode(nil))
        let blocks = RunReportBlocks.decode(report: ["variants": [["volume_fraction": 0.2, "accepted": true]]])
        XCTAssertNil(blocks.rows.first?.finish, "★ an older report decodes with no finish")
    }
}
#endif

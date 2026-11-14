// PrintThisWayHostedTests — B4, ledger note 12, Q9 (approved design 2026-11-02, plan.md §B4, mockup #topo-results-orient,
// #topo-results-print).
//
// His words: "The results page should note that the way it is placed is the way they recommend printing. But also; there
// should be a way to go back to the way it was set before." Results' bottom-centre line: "Shown as we'd print it" · Show as
// you placed it; then Print it this way grows the line into its confirm — three lines (support, layers, strength), Keep ours
// · Print it this way. plan.md's test: the confirm stays inside its pill and lists 3 lines. RED before B4 (saved: scratchpad
// b2red/PrintThisWay.txt): Results had no orientation line.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintThisWayHostedTests: XCTestCase {
    final class Calls { var rechecks: [Int] = []; var picks: [String] = []; var yours: Set<Int> = []; var ready = true }
    let ui = LoadScenarioHostedTests()

    /// Ours: 2.10×, layers fine, 12 cm² over air. His placement: 1.62×, layers 1.30× (needs 1.50×), 26 cm².
    static let ours = PrintFacts(margin: 2.10, interlayerMargin: 2.0, marginRequired: 1.5, overhangAreaMM2: 1_200)
    static let yours = PrintFacts(margin: 1.62, interlayerMargin: 1.3, marginRequired: 1.5, overhangAreaMM2: 2_600)

    func screen(_ size: CGSize, _ c: Calls) throws -> (LoadScenarioHostedTests.Host, ResultsModel) {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let rm = ResultsModel(projectName: "CarriageArms", outcome: o)
        let po = ResultsPrintOrientation(printsYours: { c.yours.contains($0) },
                                         changes: { _ in c.ready ? PrintChanges.lines(ours: Self.ours, yours: Self.yours) : nil },
                                         recheck: { c.rechecks.append($0) },
                                         choose: { c.picks.append("\($0):\($1)") })
        let h = ui.host(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {}, resultsModel: rm,
                                      version: "v7", printOrientation: po)
                            .frame(width: size.width, height: size.height), size: size)
        ui.pump(2)
        return (h, rm)
    }

    func tap(_ h: LoadScenarioHostedTests.Host, _ key: String, _ what: String) throws {
        let f = try XCTUnwrap(h.frames.all[key], "\(what): \(key) is there: \(h.frames.all.keys.filter { $0.hasPrefix("resultsOrient") }.sorted())")
        ui.click(h, CGPoint(x: f.midX, y: f.midY))
    }

    func testTheConfirmStaysInsideItsPillAndListsThreeLines() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let c = Calls()
            let (h, rm) = try screen(size, c)
            let what = "\(size)"
            let v = rm.selectedVariantIndex
            let screen = CGRect(origin: .zero, size: size)
            let panels = ["resultsVersions", "resultsChecks", "resultsViewModes", "resultsExport"].compactMap { k in h.frames.all[k].map { (k, $0) } }
            func clear(_ f: CGRect, _ state: String) {
                XCTAssertTrue(screen.contains(f), "\(what) \(state): ★ on the screen: \(f)")
                for (k, p) in panels { XCTAssertFalse(p.intersects(f), "\(what) \(state): ★ never over \(k): \(f) vs \(p)") }
            }
            // ours: the line, Show as you placed it
            let line = try XCTUnwrap(h.frames.all["resultsOrient"], "\(what): ★ the orientation line")
            XCTAssertEqual(line.midX, size.width / 2, accuracy: 1, "\(what): bottom-centre")
            clear(line, "ours")
            XCTAssertNil(h.frames.all["resultsOrient-printThisWay"], "\(what): Print it this way only while his placement shows")
            try tap(h, "resultsOrient-showPlaced", what)
            // placed: Show as we'd print it · Print it this way
            XCTAssertNotNil(h.frames.all["resultsOrient-showOurs"], what)
            try tap(h, "resultsOrient-printThisWay", what)
            XCTAssertEqual(c.rechecks, [v], "\(what): ★ core re-checks it printed his way")
            // the confirm: inside its pill, three lines, Keep ours · Print it this way
            let pill = try XCTUnwrap(h.frames.all["resultsOrient"])
            clear(pill, "confirm")
            for i in 0..<3 {
                let l = try XCTUnwrap(h.frames.all["resultsOrientChange-\(i)"], "\(what): ★ line \(i + 1)")
                XCTAssertTrue(pill.contains(l), "\(what): ★ line \(i + 1) inside its pill: \(l) vs \(pill)")
            }
            XCTAssertNil(h.frames.all["resultsOrientChange-3"], "\(what): ★ three lines, no more")
            for k in ["resultsOrient-keepOurs", "resultsOrient-confirmPrint"] {
                let b = try XCTUnwrap(h.frames.all[k], "\(what): \(k)")
                XCTAssertTrue(pill.insetBy(dx: -0.5, dy: -0.5).contains(b), "\(what): ★ \(k) inside its pill")
                XCTAssertGreaterThanOrEqual(b.height, 43.5, "\(what): a finger's target")
            }
            // Keep ours: back to his placement shown, nothing picked
            try tap(h, "resultsOrient-keepOurs", what)
            XCTAssertNil(h.frames.all["resultsOrientChange-0"], "\(what): the confirm closes")
            XCTAssertNotNil(h.frames.all["resultsOrient-printThisWay"], what)
            XCTAssertTrue(c.picks.isEmpty, "\(what): Keep ours picks nothing")
            // Print it this way: printing as he placed it
            try tap(h, "resultsOrient-printThisWay", what)
            try tap(h, "resultsOrient-confirmPrint", what)
            XCTAssertEqual(c.picks, ["\(v):true"], "\(what): ★ his pick is saved for this version")
            XCTAssertNil(h.frames.all["resultsOrient-printThisWay"], "\(what): printing his way — no second ask")
            XCTAssertNotNil(h.frames.all["resultsOrient-showOurs"], "\(what): the way back to ours")
            clear(try XCTUnwrap(h.frames.all["resultsOrient"]), "yours")
        }
    }

    func testWhileCoreChecksPrintItThisWayWaits() throws {
        let c = Calls(); c.ready = false
        let (h, _) = try screen(AppBuildHost.landscape13, c)
        try tap(h, "resultsOrient-showPlaced", "checking")
        try tap(h, "resultsOrient-printThisWay", "checking")
        let pill = try XCTUnwrap(h.frames.all["resultsOrient"])
        let checking = try XCTUnwrap(h.frames.all["resultsOrientChecking"], "★ it says it is checking")
        XCTAssertTrue(pill.contains(checking))
        try tap(h, "resultsOrient-confirmPrint", "checking")
        XCTAssertTrue(c.picks.isEmpty, "★ nothing to pick until core answers")
    }

    func testAVersionPrintedHisWayOpensSaying() throws {
        let c = Calls()
        let o = try ResultsRedesignTests.strengthenOutcome()
        c.yours = [ResultsModel(projectName: "CarriageArms", outcome: o).selectedVariantIndex]
        let (h, _) = try screen(AppBuildHost.landscape13, c)
        XCTAssertNil(h.frames.all["resultsOrient-showPlaced"], "★ printing his way: no Show as you placed it")
        XCTAssertNotNil(h.frames.all["resultsOrient-showOurs"])
        try tap(h, "resultsOrient-showOurs", "yours")
        XCTAssertEqual(c.picks.count, 1, "★ back to ours is saved")
        XCTAssertNotNil(h.frames.all["resultsOrient-showPlaced"])
    }

    /// The words, the states, and core's block.
    func testTheWordsTheStatesAndCoresBlock() throws {
        XCTAssertEqual(PrintChanges.lines(ours: Self.ours, yours: Self.yours).map(\.text),
                       ["About 14 cm\u{00B2} more to support", "Layers may split", "Strong enough drops to 1.62\u{00D7}"])
        XCTAssertEqual(PrintChanges.lines(ours: Self.ours, yours: Self.yours).map(\.tone), [.warning, .warning, .info])
        var weak = Self.yours; weak.margin = 1.2
        XCTAssertEqual(PrintChanges.lines(ours: Self.ours, yours: weak)[2],
                       PrintChange(text: "Not strong enough: 1.20\u{00D7} (needs 1.50\u{00D7})", tone: .danger))
        XCTAssertEqual(PrintChanges.lines(ours: Self.ours, yours: Self.ours).map(\.text),
                       ["About the same support", "Layers won\u{2019}t split", "Strong enough: 2.10\u{00D7}"])
        for l in PrintChanges.lines(ours: Self.ours, yours: weak) {
            XCTAssertLessThanOrEqual(l.text.split(separator: " ").count, 12, "≤ 12 words: \(l.text)")
        }
        // the states
        XCTAssertEqual(PrintOrientationPhase.ours.after(.showPlaced), .placed)
        XCTAssertEqual(PrintOrientationPhase.placed.after(.printThisWay), .confirm)
        XCTAssertEqual(PrintOrientationPhase.confirm.after(.keepOurs), .placed)
        XCTAssertEqual(PrintOrientationPhase.confirm.after(.confirmPrint), .yours)
        XCTAssertEqual(PrintOrientationPhase.yours.after(.showOurs), .ours)
        XCTAssertEqual(PrintOrientationPhase.ours.after(.confirmPrint), .ours, "no way to print his way without the confirm")
        XCTAssertEqual(PrintOrientationCopy.says(.ours), "Shown as we\u{2019}d print it")
        XCTAssertEqual(PrintOrientationCopy.says(.placed), "Shown as you placed it")
        XCTAssertEqual(PrintOrientationCopy.says(.yours), "Printing as you placed it")
        // core 35764048bba3's analysis.json block
        let a: [String: Any] = ["orientation_recheck": [
            "build_dir": [0.0, 0.0, 1.0], "margin": 1.62, "interlayer_margin": 1.3, "margin_required": 1.5, "accepted": false,
            "overhang_area_mm2": 2600.0, "support_volume_mm3": 14000.0,
            "reason": "Printed this way the layers would split: 1.62\u{00D7} (needs 1.50\u{00D7})",
            "baseline": ["build_dir": [0.0, -1.0, 0.0], "overhang_area_mm2": 1200.0]] as [String: Any]]
        let r = try XCTUnwrap(OrientationRecheck.decode(analysis: a))
        XCTAssertEqual(r.buildDir, SIMD3(0, 0, 1)); XCTAssertEqual(r.baselineBuildDir, SIMD3(0, -1, 0))
        XCTAssertEqual(r.margin, 1.62); XCTAssertFalse(r.accepted); XCTAssertEqual(r.baselineOverhangAreaMM2, 1200)
        XCTAssertNil(OrientationRecheck.decode(analysis: ["margin": 2.0]), "any other analyze job: no block")
    }
}
#endif

// ResultsCornerHostedTests — LOOK PER SCREEN, Results slice R-a (his ruling 11-04; mockup #topo-results and
// #topo-results-details; design-system §4.18): Results' corner is [Compare] [Details] [Export v7b (.stl)] [⌃], 12 pt apart
// and 24 pt from the edges; ⌃ holds Export all N results · Open in Library; Details opens as the full-width drawer from the
// bottom (Details · <result>, its tabs, Close). Nothing in the corner covers a panel: where the results panel would run into
// it (11″ portrait) the panel's foot sits 12 pt above the corner. RED before R-a (scratchpad b2red/ResultsCorner.txt): Export
// sits in the right column under a Details bar, Compare at the foot of the results panel, Details opens upward under the
// view buttons.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ResultsCornerHostedTests: XCTestCase {
    let r = ResultsRedesignHostedTests()
    static let sizes = [CGSize(width: 1376, height: 1032), CGSize(width: 820, height: 1180), CGSize(width: 1032, height: 1376)]

    func testTheCornerIsCompareDetailsExportAndMore() throws {
        for size in Self.sizes {
            let (h, _) = try r.screen(size)
            let keys = ["resultsCompare", "resultsDetailsButton", "resultsExport", "resultsSplitMore"]
            let fs = try keys.map { try r.frame(h, $0) }
            for i in 1..<fs.count {
                XCTAssertEqual(fs[i].minX - fs[i - 1].maxX, DSParts.cornerGap, accuracy: 1, "\(size): ★ §4.18 \(keys[i - 1]) → \(keys[i])")
                XCTAssertEqual(fs[i].maxY, fs[0].maxY, accuracy: 1, "\(size): one row")
            }
            XCTAssertEqual(fs[3].maxX, size.width - DSParts.cornerEdge, accuracy: 1, "\(size): ★ 24 pt from the right")
            XCTAssertEqual(fs[3].maxY, size.height - DSParts.cornerEdge, accuracy: 1, "\(size): ★ 24 pt from the bottom")
            XCTAssertEqual(fs[2].height, DSParts.runHeight, accuracy: 0.5, "Export is the corner's run button")
            XCTAssertEqual(fs[0].height, DSParts.glassHeight, accuracy: 0.5, "Compare and Details are glass buttons")
            for k in ["resultsVersions", "resultsChecks", "resultsViewModes", "resultsScenario"] {
                guard let p = h.frames.all[k] else { continue }
                for (i, f) in fs.enumerated() {
                    XCTAssertFalse(p.insetBy(dx: 1, dy: 1).intersects(f.insetBy(dx: 1, dy: 1)), "\(size): ★ '\(keys[i])' covers '\(k)' \(p)")
                }
            }
        }
    }

    func testDetailsIsTheDrawerFromTheBottom() throws {
        for size in [CGSize(width: 1376, height: 1032), CGSize(width: 820, height: 1180)] {
            let (h, _) = try r.screen(size)
            XCTAssertNil(h.frames.all["resultsDetailsPanel"], "Details starts closed")
            let button = try r.frame(h, "resultsDetailsButton")
            r.ui.click(h, CGPoint(x: button.midX, y: button.midY))
            let drawer = try r.frame(h, "resultsDetailsPanel")
            XCTAssertEqual(drawer.minX, 0, accuracy: 1, "\(size): ★ the drawer is the page's width")
            XCTAssertEqual(drawer.maxX, size.width, accuracy: 1)
            XCTAssertEqual(drawer.maxY, size.height, accuracy: 1, "\(size): ★ from the bottom")
            XCTAssertLessThanOrEqual(drawer.height, size.height * 0.45, "\(size): the model keeps most of the page")
            XCTAssertNotNil(h.frames.all["resultsDetailsRows"], "its rows")
            XCTAssertNotNil(h.frames.all["resultsChecks"], "★ Checks stays where it is")
            let close = try r.frame(h, "resultsDetailsClose")
            XCTAssertTrue(drawer.contains(close), "Close is in the drawer")
            r.ui.click(h, CGPoint(x: close.midX, y: close.midY))
            XCTAssertNil(h.frames.all["resultsDetailsPanel"], "\(size): ★ Close closes it")
        }
    }

    func testMoreHoldsExportAllAndOpenInLibrary() throws {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let h = AppBuildHost(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {},
                                           resultsModel: ResultsModel(projectName: "CarriageArms", outcome: o)),
                             size: AppBuildHost.landscape13, test: self)
        h.pump(2)
        let offered = try h.pickFromMenu("resultsSplitMore", "(none: read the menu only)", what: "⌃")
        XCTAssertTrue(offered.contains { $0.hasPrefix("Export all") }, "★ Export all N results: \(offered)")
        XCTAssertTrue(offered.contains("Open in Library"), "★ Open in Library: \(offered)")
    }

    /// ★ R-c (mockup #topo-results): Checks is §4.3's panel (300 pt, as the mockup draws it), its header "Checks · N to look at";
    /// "Scenario: Worst case ⌄" is one glass chip beside it, top-aligned, both under the view buttons. RED before R-c (scratchpad
    /// b2red/ResultsChecks.txt): Checks 330 pt in the old box; "Scenario" sits above the view buttons.
    func testChecksIsThePanelAndTheScenarioSitsBesideIt() throws {
        for size in [CGSize(width: 1376, height: 1032), CGSize(width: 820, height: 1180)] {
            let (h, _) = try r.screen(size)
            let checks = try r.frame(h, "resultsChecks")
            XCTAssertEqual(checks.width, 300, accuracy: 0.5, "\(size): ★ the mockup's Checks")
            XCTAssertEqual(try r.frame(h, "resultsChecksHeader").height, DSParts.headerHeight, accuracy: 0.5, "\(size): §4.3's header")
            let scenario = try r.frame(h, "resultsScenario"), views = try r.frame(h, "resultsViewModes")
            XCTAssertLessThanOrEqual(scenario.maxX, checks.minX - 7, "\(size): ★ beside Checks, on its left")
            XCTAssertEqual(scenario.minY, checks.minY, accuracy: 7, "\(size): top-aligned with it")
            XCTAssertGreaterThanOrEqual(Swift.min(scenario.minY, checks.minY), views.maxY - 0.5, "\(size): ★ under the view buttons")
            XCTAssertLessThanOrEqual(scenario.height, 44.5, "\(size): one chip")
        }
    }

    /// The bytes and names of every result at once, without changing which one is shown.
    func testExportAllWritesEveryResultAndKeepsTheSelection() throws {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let rm = ResultsModel(projectName: "CarriageArms", outcome: o)
        let shown = rm.selectedIndex
        let files = rm.exportAllSTL()
        XCTAssertEqual(files.count, rm.tabs.filter { !$0.isLatticed && rm.canExport(tab: $0) }.count, "★ one file per exportable result")
        XCTAssertEqual(Set(files.map(\.filename)).count, files.count, "★ never two files under one name")
        XCTAssertTrue(files.allSatisfy { $0.data.count > 84 }, "binary STLs")
        XCTAssertEqual(rm.selectedIndex, shown, "★ the shown result stays")
    }
}
#endif

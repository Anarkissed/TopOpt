// ResultsRedesignHostedTests — ★ the Results redesign on HIS screen (iPad 13" portrait and landscape), hosted offscreen
// (never the app): every panel found by its own laid-out frame, none overlapping another, Details opening UPWARD under the
// view buttons, a version picked from the list, and Compare's "Use this" returning to Results on it.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ResultsRedesignHostedTests: XCTestCase {
    private let ui = LoadScenarioHostedTests()

    func screen(_ size: CGSize) throws -> (LoadScenarioHostedTests.Host, ResultsModel) {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let rm = ResultsModel(projectName: "CarriageArms", outcome: o)
        let h = ui.host(ResultsScreen(projectName: "CarriageArms", outcome: o, undo: {}, redo: {}, resultsModel: rm)
                            .frame(width: size.width, height: size.height), size: size)
        ui.pump(2)
        return (h, rm)
    }

    func frame(_ h: LoadScenarioHostedTests.Host, _ k: String) throws -> CGRect {
        let f = try XCTUnwrap(h.frames.all[k], "★ '\(k)' is not on the screen; frames: \(h.frames.all.keys.sorted())")
        XCTAssertTrue(CGRect(origin: .zero, size: h.size).insetBy(dx: -1, dy: -1).contains(f), "★ '\(k)' leaves the window: \(f)")
        return f
    }

    func testEveryPanelIsOnHisScreenAndNothingOverlaps() throws {
        for size in [CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)] {
            let (h, _) = try screen(size)
            let keys = ["resultsVersions", "resultsScenario", "resultsViewModes", "resultsChecks", "resultsDetailsButton", "resultsExport"]
            let fs = try keys.map { try frame(h, $0) }
            for i in fs.indices { for j in fs.indices where j > i {
                XCTAssertFalse(fs[i].insetBy(dx: 1, dy: 1).intersects(fs[j].insetBy(dx: 1, dy: 1)),
                               "★ \(size): '\(keys[i])' \(fs[i]) overlaps '\(keys[j])' \(fs[j])")
            } }
            // the order he drew: Scenario above the view buttons, above the checks, above Details, above Export — one column
            XCTAssertLessThan(fs[1].maxY, fs[2].minY + 1); XCTAssertLessThan(fs[2].maxY, fs[3].minY + 1)
            XCTAssertLessThan(fs[3].maxY, fs[4].minY + 1); XCTAssertLessThan(fs[4].maxY, fs[5].minY + 1)
            XCTAssertEqual(fs[1].maxX, fs[2].maxX, accuracy: 2, "Scenario sits right-aligned over the views")
            XCTAssertNotNil(h.frames.all["resultsVersion-v3"], "the impossible version is listed (greyed)")
            XCTAssertNil(h.frames.all["resultsDetailsPanel"], "Details starts closed")
            try ui.picture(h, "results_\(Int(size.width))x\(Int(size.height)).png")
        }
    }

    func testDetailsOpenUpwardUnderTheViewsAndScroll() throws {
        let (h, _) = try screen(CGSize(width: 1032, height: 1376))
        let views = try frame(h, "resultsViewModes"), button = try frame(h, "resultsDetailsButton")
        ui.click(h, CGPoint(x: button.midX, y: button.midY))
        let panel = try frame(h, "resultsDetailsPanel")
        XCTAssertNil(h.frames.all["resultsChecks"], "★ the checks fold away while Details is open")
        XCTAssertGreaterThanOrEqual(panel.minY, views.maxY - 1, "★ Details stays under the view buttons")
        XCTAssertLessThan(panel.minY, button.minY - 100, "★ it opened UPWARD from its button")
        XCTAssertNotNil(h.frames.all["resultsDetailsRows"], "its rows scroll inside it")
        try ui.picture(h, "results_details_open.png")
        let close = try frame(h, "resultsDetailsButton")
        XCTAssertGreaterThan(close.minY, panel.midY, "the fold button sits at its foot")
        ui.click(h, CGPoint(x: close.midX, y: close.midY))
        XCTAssertNotNil(h.frames.all["resultsChecks"], "folding it brings the checks back")
    }

    func testPickAVersionAndCompareReturnsOnTheOneHeUses() throws {
        let (h, rm) = try screen(CGSize(width: 1376, height: 1032))
        let first = rm.selectedIndex
        let other = try XCTUnwrap(rm.tabs.map(\.index).first { $0 != first })
        let row = try frame(h, "resultsVersion-t\(other)")
        ui.click(h, CGPoint(x: row.midX, y: row.midY))
        XCTAssertEqual(rm.selectedIndex, other, "★ a tap on a version's line shows it")

        let c = try frame(h, "resultsCompare")
        ui.click(h, CGPoint(x: c.midX, y: c.midY))
        _ = try frame(h, "compareScreen")
        _ = try frame(h, "comparePanel-0"); _ = try frame(h, "comparePanel-1")
        XCTAssertNil(h.frames.all["compareLayout"], "two versions: no layout switch")
        let d = try frame(h, "compareDetailsButton")
        ui.click(h, CGPoint(x: d.midX, y: d.midY))
        XCTAssertNotNil(h.frames.all["compareDetails"], "★ Details expands IN PLACE, on the same screen")
        XCTAssertNotNil(h.frames.all["comparePanel-0"], "the versions stay on screen above it")
        let use = try frame(h, "compareUse-\(first)")
        ui.click(h, CGPoint(x: use.midX, y: use.midY))
        XCTAssertNil(h.frames.all["compareScreen"], "★ Use this returns to Results")
        XCTAssertEqual(rm.selectedIndex, first, "★ on the version he used")
    }

    /// Three versions: the layout switch (two columns / three columns) at the bottom right; "all at once" shows the third.
    func testThreeVersionsOfferTheLayoutSwitch() throws {
        func v(_ vf: Double) -> OptimizeVariant {
            OptimizeVariant(requestedVolumeFraction: vf, achievedVolumeFraction: vf, massGrams: vf * 100, supportVolumeVoxels: 0,
                            meshTriangleCount: 10, worstCaseMargin: 2, accepted: true, v3Passes: true)
        }
        let o = OptimizeOutcome(variants: [v(0.7), v(0.5), v(0.3)], stoppedOnMargin: false, cancelled: false, acceptedCount: 3,
                                gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1)
        let rm = ResultsModel(projectName: "Bracket", outcome: o)
        let size = CGSize(width: 1376, height: 1032)
        let h = ui.host(ResultsScreen(projectName: "Bracket", outcome: o, resultsModel: rm).frame(width: size.width, height: size.height), size: size)
        ui.pump(2)
        let c = try frame(h, "resultsCompare")
        ui.click(h, CGPoint(x: c.midX, y: c.midY))
        let sw = try frame(h, "compareLayout")
        XCTAssertGreaterThan(sw.minX, size.width / 2, "★ bottom right"); XCTAssertGreaterThan(sw.minY, size.height / 2)
        XCTAssertNil(h.frames.all["comparePanel-2"], "one pair at a time first")
        let all = try frame(h, "compareLayoutAll")
        ui.click(h, CGPoint(x: all.midX, y: all.midY))
        _ = try frame(h, "comparePanel-2")
        try ui.picture(h, "compare_all_three.png")
        let p = try frame(h, "comparePanel-0"), d = try frame(h, "compareDetailsButton")
        XCTAssertFalse(sw.intersects(d), "the switch and Details never overlap")
        XCTAssertFalse(p.insetBy(dx: 1, dy: 1).intersects(d), "nor a panel and Details")
    }
}
#endif

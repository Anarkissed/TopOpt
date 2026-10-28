// ResultsRedesignHostedTests — ★ the Results redesign on HIS screen (iPad 13" portrait and landscape), hosted offscreen
// (never the app): every panel found by its own laid-out frame, none overlapping another, Details opening UPWARD under the
// view buttons, a version picked from the list, and Compare's "Use this" returning to Results on it.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ResultsRedesignHostedTests: XCTestCase {
    private let ui = LoadScenarioHostedTests()

    func screen(_ size: CGSize, loaded: Bool = false) throws -> (LoadScenarioHostedTests.Host, ResultsModel) {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let rm = loaded ? ResultsModel(projectName: "CarriageArms", outcome: o, yieldStrengthMPa: 21, appliedLoadKg: 5)
                        : ResultsModel(projectName: "CarriageArms", outcome: o)
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

    /// ★ his note 2026-10-27: the views are ICONS (all four when the run carries the fields); Full screen leaves only the
    /// model, the view cube and the view buttons; folded panels drop to the bottom, and become pills when short of room.
    func testIconViewsFullScreenAndFoldedPanels() throws {
        let (h, rm) = try screen(CGSize(width: 1376, height: 1032))
        XCTAssertTrue(rm.hasStress && rm.hasLoadPath, "premise: the run carries both fields")
        for m in ResultsViewMode.shown(hasStress: true, hasDisplacement: true, canBreak: false) {
            let f = try frame(h, "resultsView-\(m.rawValue)"); XCTAssertEqual(f.width, 44, accuracy: 1)
        }
        XCTAssertNil(h.frames.all["resultsView-Break"], "no load in this run: Break is hidden, not greyed")
        let fs = try frame(h, "resultsFullScreen")
        ui.click(h, CGPoint(x: fs.midX, y: fs.midY))
        for k in ["resultsVersions", "resultsChecks", "resultsScenario", "resultsExport", "resultsDetailsButton"] {
            XCTAssertNil(h.frames.all[k], "★ full screen hides '\(k)'")
        }
        _ = try frame(h, "resultsViewModes")
        try ui.picture(h, "results_full_screen.png")
        let back = try frame(h, "resultsFullScreen")
        ui.click(h, CGPoint(x: back.midX, y: back.midY))
        _ = try frame(h, "resultsChecks")

        // fold Checks: it drops down by Export
        let header = try frame(h, "resultsChecks")
        ui.click(h, CGPoint(x: header.midX, y: header.minY + 25))
        let folded = try frame(h, "resultsChecks"), export = try frame(h, "resultsExport"), views = try frame(h, "resultsViewModes")
        XCTAssertGreaterThan(folded.minY, h.size.height / 2, "★ folded Checks sits low, out of the middle")
        XCTAssertLessThan(export.minY - folded.maxY, 120, "just above Details and Export")
        XCTAssertGreaterThan(folded.minY - views.maxY, 200, "a wide gap where it used to be")
        try ui.picture(h, "results_checks_folded.png")
    }

    /// ★ his note 2026-10-27: the Stress view's key is the Lattice stage's "Tap to explore" key — on screen, clear of the
    /// Versions panel, minimisable to one line. (The tap itself reads `selectedStressField` at the hit point; a synthetic tap
    /// cannot reach the Metal view offscreen, so the reading is asserted on device.)
    func testTheStressKeyIsTapToExplore() throws {
        let (h, rm) = try screen(CGSize(width: 1032, height: 1376))
        XCTAssertTrue(rm.hasStress)
        // ★ his note 2026-10-27: above Checks, minimised to start
        let pill = try frame(h, "resultsStressKey"), checks = try frame(h, "resultsChecks"), views = try frame(h, "resultsViewModes")
        XCTAssertLessThan(pill.height, 60, "minimised to one line")
        XCTAssertGreaterThan(pill.minY, views.maxY - 1); XCTAssertLessThan(pill.maxY, checks.minY + 1, "between the views and Checks")
        XCTAssertEqual(pill.maxX, checks.maxX, accuracy: 2, "right-aligned in the column")
        // open it: Checks folds, Details stays shut
        ui.click(h, CGPoint(x: pill.midX, y: pill.midY))
        let key = try frame(h, "resultsStressKey")
        XCTAssertGreaterThan(key.height, ResultsStressExplore.barH, "the vertical scale, like Lattice's")
        XCTAssertLessThanOrEqual(key.width, ResultsStressExplore.width + 1, "★ no empty space on the right")
        let folded = try frame(h, "resultsChecks")
        XCTAssertLessThan(folded.height, 60, "★ opening the key folds Checks")
        XCTAssertNil(h.frames.all["resultsDetailsPanel"])
        try ui.picture(h, "results_stress_key.png")
        // open Checks: the key minimises
        ui.click(h, CGPoint(x: folded.midX, y: folded.minY + 25))
        XCTAssertLessThan(try frame(h, "resultsStressKey").height, 60, "★ opening Checks minimises the key")
        let x = try frame(h, "resultsView-X-ray")
        ui.click(h, CGPoint(x: x.midX, y: x.midY))
        XCTAssertNil(h.frames.all["resultsStressKey"], "only in the Stress view")
    }

    /// ★ His iPad 2026-10-27: Bend and Break are back beside the other views; each moving view plays on its own, the motion
    /// bar under the view buttons pauses it, and its slider moves it by hand.
    func testTheMovingViewsPlayPauseAndScrub() throws {
        for size in [CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)] {
            let (h, rm) = try screen(size, loaded: true)
            XCTAssertTrue(rm.hasFlex && rm.hasFailurePrediction, "premise: a displacement field, a load and a yield")
            for m in ResultsViewMode.allCases { _ = try frame(h, "resultsView-\(m.rawValue)") }
            XCTAssertNil(h.frames.all["resultsMotionBar"], "Stress does not move: no motion bar")

            let bend = try frame(h, "resultsView-Bend")
            ui.click(h, CGPoint(x: bend.midX, y: bend.midY))
            let bar = try frame(h, "resultsMotionBar"), views = try frame(h, "resultsViewModes")
            XCTAssertGreaterThan(bar.minY, views.maxY - 1, "★ \(size): right under the view buttons")
            XCTAssertTrue(rm.flexOn)
            let p0 = rm.flexPhase
            ui.pump(0.6)
            XCTAssertNotEqual(rm.flexPhase, p0, "★ \(size): the part BENDS on its own")
            let play = try frame(h, "resultsMotionPlay")
            ui.click(h, CGPoint(x: play.midX, y: play.midY))
            let paused = rm.flexPhase
            ui.pump(0.6)
            XCTAssertEqual(rm.flexPhase, paused, accuracy: 1e-9, "★ \(size): Pause holds it")
            let slider = try frame(h, "resultsMotionSlider")
            ui.click(h, CGPoint(x: slider.minX + slider.width * 0.75, y: slider.midY))
            XCTAssertGreaterThan(rm.flexPhase, 0.55, "★ \(size): the slider moves it by hand (\(rm.flexPhase))")
            try ui.picture(h, "results_bend_\(Int(size.width)).png")

            // ★ 10-28: Load paths is light travelling through the part (no arrows): it builds, then sweeps on its own
            let flow = try frame(h, "resultsView-Load paths")
            ui.click(h, CGPoint(x: flow.midX, y: flow.midY))
            XCTAssertFalse(rm.loadPathOn, "★ the old arrows are retired")
            for _ in 0..<40 where rm.lightFlow == nil { ui.pump(0.1) }
            XCTAssertNotNil(rm.lightFlow, "★ \(size): the light flow was built")
            let l0 = rm.lightPhase
            ui.pump(0.6)
            XCTAssertGreaterThan(rm.lightPhase, l0, "★ \(size): the light TRAVELS (a new view starts playing)")

            let brk = try frame(h, "resultsView-Break")
            ui.click(h, CGPoint(x: brk.midX, y: brk.midY))
            XCTAssertTrue(rm.pushActive)
            ui.pump(1.2)
            XCTAssertGreaterThan(rm.pushFactor, 1.05, "★ \(size): the load climbs toward the one that breaks it")
            try ui.picture(h, "results_break_\(Int(size.width)).png")
        }
    }

    /// ★ His iPad 2026-10-27: "I am unable to tap to explore." The Lattice key's process: open the key, tap the part, the key
    /// shows the reading; a double tap anywhere leaves. The bug was in the viewer's tap path itself (Results never turns the
    /// face tool on, and a guard for it dropped every tap), so the tap goes through the viewer's OWN tap handler — the one
    /// his finger reaches. (A synthetic click never fires the recognizer offscreen, so the test hands the handler the tap.)
    func testATapOnThePartReadsTheStressOnTheKey() throws {
        let (h, rm) = try screen(CGSize(width: 1376, height: 1032))
        XCTAssertTrue(rm.hasStress)
        let mtk = try XCTUnwrap(Self.metalView(in: h.view), "the Results viewer")
        let click = try XCTUnwrap(mtk.gestureRecognizers.first { ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 1 })
        let viewer = try XCTUnwrap(click.target as? MetalMeshView.Coordinator)
        func tapAcrossThePart() -> Bool {
            for dy in stride(from: -200.0, through: 200.0, by: 25) {
                for dx in stride(from: -300.0, through: 300.0, by: 25) {
                    viewer.pick(at: CGPoint(x: mtk.bounds.midX + dx, y: mtk.bounds.midY + dy), in: mtk)
                    ui.pump(0.05)
                    if let k = h.frames.all["resultsStressKey"], k.width > ResultsStressExplore.width + 20 { return true }
                }
            }
            return false
        }
        XCTAssertFalse(tapAcrossThePart(), "the key shut: a tap on the part reads nothing")
        let pill = try frame(h, "resultsStressKey")
        ui.click(h, CGPoint(x: pill.midX, y: pill.midY))
        XCTAssertEqual(try frame(h, "resultsStressKey").width, ResultsStressExplore.width, accuracy: 2, "open, no reading yet")
        XCTAssertTrue(tapAcrossThePart(), "★ the key open: a tap on the part puts its stress on the key")
        try ui.picture(h, "results_explore_reading.png")
        // the way out: a double tap anywhere
        let double = try XCTUnwrap(mtk.gestureRecognizers.first { ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 2 })
        XCTAssertTrue(double.isEnabled, "★ the double tap is armed while exploring")
        viewer.handleDoubleClick(double as! NSClickGestureRecognizer)
        ui.pump(0.8)
        XCTAssertLessThan(try frame(h, "resultsStressKey").height, 60, "★ the double tap folds the key and ends exploring")
    }

    static func metalView(in v: NSView) -> MTKView? {
        if let m = v as? MTKView { return m }
        for s in v.subviews { if let m = metalView(in: s) { return m } }
        return nil
    }

    func testOnASmallIPadFoldedPanelsBecomePills() throws {
        let (h, _) = try screen(CGSize(width: 744, height: 1133))   // iPad mini portrait
        let v = try frame(h, "resultsVersions")
        ui.click(h, CGPoint(x: v.midX, y: v.minY + 25))
        let c = try frame(h, "resultsChecks")
        ui.click(h, CGPoint(x: c.midX, y: c.minY + 25))
        let pv = try frame(h, "resultsVersions"), pc = try frame(h, "resultsChecks")
        XCTAssertLessThan(pv.width, 300, "★ Versions folds to a pill: \(pv)")
        XCTAssertLessThan(pc.width, 300, "★ Checks folds to a pill: \(pc)")
        XCTAssertFalse(pv.intersects(pc), "the two pills never meet")
        try ui.picture(h, "results_mini_pills.png")
    }
}
#endif

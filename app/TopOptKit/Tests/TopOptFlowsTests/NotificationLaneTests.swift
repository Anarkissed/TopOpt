// NotificationLaneTests — B2, U16 (approved design 2026-11-02, design-system §4.34 and §6 U16; his Phase 3 note P2:
// "Notifications of actions should NEVER cover up any menu items such as the Undo/Redo buttons. They should stay in the centre
// of the screen, but become two lines to ensure it does not cover or come too close to a required action/button").
//
// The whole workspace (as RootView mounts it, with its toast) at three iPad sizes in both orientations: the Topology "results
// are ready" message after a landed run, and a long toast with the corner's Settings panel open, sit centred, overlap no
// control's frame and are never taller than two lines. RED (NOTIFLANE_RED=1, the old places): the toast, 96 pt off the
// bottom at its full width, runs into the open Settings panel. (The message is short enough to fit between the top rows at
// these sizes even in its old place; the lane's rule for a long one is NotificationLaneRuleTests.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

/// The workspace with RootView's toast.
private struct LaneRoot: View {
    @ObservedObject var model: AppModel
    var body: some View { AppBuildWorkspace(model: model).laneToast($model.toast) }
}

@MainActor
final class NotificationLaneTests: XCTestCase {
    static let sizes = AppBuildHost.sweep   // ★ B10: the same six windows, from one list
    static let longToast = "Hidden from view — it still counts in the run, in every load scenario it belongs to, until you show it again"
    /// Two lines of the lane's type and padding, with a little slack.
    static let twoLines: CGFloat = 62

    func waitUntil(_ h: AppBuildHost, _ s: Double, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while !cond(), Date() < end { h.pump(0.1) }
    }

    /// The controls `lane` must keep clear of: every published frame but the lane's own (and what lies inside it).
    func overlaps(_ h: AppBuildHost, _ lane: CGRect) -> [String] {
        h.frames.all.compactMap { k, f in
            if k.hasPrefix("lane-") || k.hasPrefix("numberPad") { return nil }
            if lane.insetBy(dx: -1, dy: -1).contains(f) { return nil }   // its own buttons
            return f.intersects(lane.insetBy(dx: 0.5, dy: 0.5)) ? "\(k) \(f)" : nil
        }.sorted()
    }

    func testNoNotificationCoversAControlOrRunsPastTwoLines() throws {
        RunModel.hostedTestRunner = { _, _, _ in AppBuildFixtures.outcome() }
        addTeardownBlock { @MainActor in RunModel.hostedTestRunner = nil; NotificationLane.controlOldPlace = false }
        // the saved red run (NOTIFLANE_RED=1): the old places
        if ProcessInfo.processInfo.environment["NOTIFLANE_RED"] != nil { NotificationLane.controlOldPlace = true }
        for size in Self.sizes {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let app = r.app, p = r.project
            p.lattice.flexible = nil
            if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
            let h = AppBuildHost(LaneRoot(model: app), size: size, test: self)
            h.pump(3)
            // a landed run: Topology says so in the top lane (it never opens Results by itself)
            let opt = try h.onScreen("optimizeSplit", "\(size): Optimize")
            h.click(CGPoint(x: opt.minX + (opt.width - 46) / 2, y: opt.midY), settle: 1)
            waitUntil(h, 15) { p.run.phase == .succeeded && h.frames.all["lane-topology-results-message"] != nil }
            h.pump(1)
            let msg = try h.onScreen("lane-topology-results-message", "\(size): ★ the results message, in the top lane")
            XCTAssertEqual(overlaps(h, msg), [], "\(size): ★ U16 — the message covers no control")
            XCTAssertLessThanOrEqual(msg.height, Self.twoLines, "\(size): ★ two lines at most (\(msg))")
            XCTAssertEqual(msg.midX, size.width / 2, accuracy: 1, "\(size): centred on the screen")

            // the corner's Settings panel open: a control column up the right side, in the toast's row
            try h.tap("setupChip", "\(size): Settings")
            app.toast = Self.longToast
            h.pump(0.8)
            let toast = try h.onScreen("lane-toast", "\(size): ★ the toast")
            XCTAssertEqual(overlaps(h, toast), [], "\(size): ★ U16 — the toast covers no control")
            XCTAssertLessThanOrEqual(toast.height, Self.twoLines, "\(size): ★ two lines at most (\(toast))")
            // centred on the screen, unless no row has room there (11″ portrait, both panels open: its row's widest gap). No
            // room = a control in its row nearer the centre than half the narrowest notification and its clearance — not only
            // one ON the centre line (the 348 pt Settings panel, 897fd9ed, leaves the centre 38 pt clear: still no room)
            let cx = size.width / 2, reach = NotificationLane.minWidth / 2 + NotificationLane.sideClearance
            let blocking = h.frames.all.filter { k, f in
                !k.hasPrefix("lane-") && f.maxY > toast.minY && f.minY < toast.maxY && f.maxX > cx - reach && f.minX < cx + reach
            }.keys.sorted()
            if blocking.isEmpty {
                XCTAssertEqual(toast.midX, cx, accuracy: 1, "\(size): centred on the screen")
            } else if abs(toast.midX - cx) > 1 {
                XCTAssertEqual(size, CGSize(width: 820, height: 1180), "\(size): ★ off centre only in 11″ portrait (\(blocking))")
            }
        }
    }
}

/// The lane's rule (pure).
final class NotificationLaneRuleTests: XCTestCase {
    func testTheWidthIsTwiceTheNearestControlsDistanceLessSixteenEachSide() {
        let v = CGSize(width: 1376, height: 1032)
        // redo ends at 568, the cube starts at 808: centre 688 → 120 to the nearer, less 16 → 2 × 104
        let controls = [CGRect(x: 24, y: 24, width: 544, height: 52), CGRect(x: 808, y: 24, width: 544, height: 52)]
        XCTAssertEqual(NotificationLane.width(top: 22, height: 52, cx: 688, viewport: v, controls: controls), 208)
        XCTAssertEqual(NotificationLane.width(top: 200, height: 52, cx: 688, viewport: v, controls: controls), 560, "a free row: its cap")
    }

    func testWithNoRoomItStepsToTheNextFreeRow() {
        let v = CGSize(width: 1180, height: 820)
        let controls = [CGRect(x: 24, y: 24, width: 520, height: 52), CGRect(x: 640, y: 24, width: 516, height: 52)]
        let p = NotificationLane.place(edge: .top, preferred: 22, viewport: v, controls: controls)
        XCTAssertEqual(p.top, 84, "below the top rows (76 + 8)")
        XCTAssertGreaterThanOrEqual(p.width, NotificationLane.minWidth)
        let b = NotificationLane.place(edge: .bottom, preferred: 724, viewport: v,
                                       controls: [CGRect(x: 500, y: 700, width: 200, height: 60)])
        XCTAssertEqual(b.top + NotificationLane.twoLineHeight, 692, "above the control in its way (700 − 8)")
    }

    func testWithNoRoomAnywhereItTakesItsRowsWidestGapNeverAControl() {
        // 11″ portrait, both panels open: the left panel ends at 372, Settings starts at 376, the top rows are full
        let v = CGSize(width: 820, height: 1180)
        let controls = [CGRect(x: 24, y: 24, width: 772, height: 104), CGRect(x: 24, y: 132, width: 348, height: 530),
                        CGRect(x: 376, y: 544, width: 420, height: 612)]
        let p = NotificationLane.place(edge: .bottom, preferred: 1084, viewport: v, controls: controls)
        XCTAssertEqual(p.top, 1032)
        XCTAssertEqual(p.cx ?? 0, 188, accuracy: 0.5, "the middle of the gap left of Settings")
        XCTAssertEqual(p.width, 344, "the gap less 16 each side")
    }

    func testOneStringSplitsIntoWhatHappenedAndTheDetail() {
        XCTAssertEqual(NotificationLane.lines("Hidden from view — it still counts in the run").main, "Hidden from view")
        XCTAssertEqual(NotificationLane.lines("Hidden from view — it still counts in the run").detail, "it still counts in the run")
        XCTAssertEqual(NotificationLane.lines("Kept to 1 to 40").detail, nil)
    }
}
#endif

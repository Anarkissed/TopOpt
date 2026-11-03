// RerunConfirmHostedTests — B3 (design-system §1 U7: "every confirm is a ConfirmInPlace inside its panel's bounds";
// OneWayToSayNoTests), with #362's two conditions (20:30Z) for the card that replaced the system alert:
//   (1) with the card up, another tap on Optimize (or ⌃) starts no run and shows no second card;
//   (2) leaving the card without choosing does what Cancel does — a tap outside it, a change of stage, an edit or an Undo.
// Optimize over finished results asks in place, in a card over the run button's corner: Re-run here · Save as new project ·
// Cancel, each a 44 pt row. RED before B3 (saved: scratchpad b2red/RerunConfirm.txt): a system alert, no card on the page.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class RerunConfirmHostedTests: XCTestCase {
    final class Runs: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func add() { lock.lock(); n += 1; lock.unlock() }
    }

    override func setUp() async throws {
        addTeardownBlock { @MainActor in RunModel.hostedTestRunner = nil }
    }

    func clickOptimize(_ h: AppBuildHost) throws {
        let f = try h.onScreen("optimizeButton", "Optimize")
        h.click(CGPoint(x: f.midX, y: f.midY), settle: 1)
    }

    func waitUntil(_ h: AppBuildHost, _ s: Double, _ what: String, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while !cond(), Date() < end { h.pump(0.1) }
        XCTAssertTrue(cond(), "★ timed out: \(what)")
    }

    /// His pad, a run landed (results on it), the card up after the second Optimize.
    func landed(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, Runs) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        XCTAssertNotEqual(r.app.library.mode, .library, "premise: a flat Library — the card, not the Optimize as v2 sheet")
        let runs = Runs()
        RunModel.hostedTestRunner = { _, _, _ in runs.add(); return AppBuildFixtures.outcome() }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        try clickOptimize(h)
        waitUntil(h, 15, "the first run lands") { p.run.phase == .succeeded }
        XCTAssertEqual(runs.count, 1)
        return (h, p, runs)
    }

    func card(_ h: AppBuildHost) -> CGRect? { h.frames.all["rerunConfirm"] }

    func testOptimizeOverResultsAsksInPlaceAndReRunHereRuns() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let (h, _, runs) = try landed(size)
            let what = "\(size)"
            try clickOptimize(h)
            let c = try h.onScreen("rerunConfirm", "\(what): ★ the re-run card, in place")
            XCTAssertEqual(runs.count, 1, "\(what): nothing runs until he answers")
            let split = try h.onScreen("optimizeSplit", "\(what): Optimize")
            XCTAssertLessThanOrEqual(c.maxY, split.minY + 0.5, "\(what): ★ the card sits above the run button, never over it")
            XCTAssertGreaterThan(c.midX, size.width / 2, "\(what): ★ at the run button's corner")
            for k in ["rerunChoice-rerun", "rerunChoice-cancel"] {
                let f = try h.probe(k, "\(what): \(k)", minHit: 44)
                XCTAssertTrue(c.contains(f), "\(what): \(k) is inside the card")
            }
            try h.tap("rerunChoice-rerun", "\(what): Re-run here")
            waitUntil(h, 15, "\(what): ★ Re-run here runs") { runs.count == 2 }
            XCTAssertNil(card(h), "\(what): the card is gone")
        }
    }

    /// #362's condition (1): with the card up, the next tap on Optimize starts no run and brings no second card — it lands on
    /// the outside of the card, which is Cancel. (requestRun / requestLatticeRun also return at once while it is up.)
    func testAnotherOptimizeWithTheCardUpStartsNothing() throws {
        let (h, p, runs) = try landed(AppBuildHost.landscape13)
        try clickOptimize(h)
        _ = try h.onScreen("rerunConfirm", "the card")
        try clickOptimize(h)
        h.pump(1)
        XCTAssertEqual(runs.count, 1, "★ no run")
        XCTAssertNil(card(h), "★ no second card: the tap outside was Cancel")
        XCTAssertEqual(p.run.phase, .succeeded)
        let ws = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertEqual(ws.components(separatedBy: "guard pendingReplacement == nil else { return }   // ★ B3 (#362's condition 1)").count - 1, 2,
                       "★ requestRun and requestLatticeRun wait for the card")
    }

    /// #362's condition (2): leaving without choosing is Cancel — a tap outside, an edit, an Undo. (A stage change moves the same
    /// token: RerunLeaveToken(stage:edit:).)
    func testLeavingTheCardIsCancel() throws {
        let (h, p, runs) = try landed(AppBuildHost.landscape13)
        // a tap outside, top left of the stage
        try clickOptimize(h)
        _ = try h.onScreen("rerunConfirm", "the card")
        h.click(CGPoint(x: 700, y: 400))
        XCTAssertNil(card(h), "★ a tap outside is Cancel")
        // an edit
        try clickOptimize(h)
        _ = try h.onScreen("rerunConfirm", "the card again")
        p.force.safetyMargin = 2.0
        h.pump(0.6)
        XCTAssertNil(card(h), "★ an edit is Cancel")
        // an Undo
        try clickOptimize(h)
        _ = try h.onScreen("rerunConfirm", "the card a third time")
        p.sealUndoStep()
        p.performUndo()
        h.pump(0.6)
        XCTAssertNil(card(h), "★ an Undo is Cancel")
        // Cancel itself
        try clickOptimize(h)
        try h.tap("rerunChoice-cancel", "Cancel")
        XCTAssertNil(card(h))
        XCTAssertEqual(runs.count, 1, "★ none of them ran")
    }
}
#endif

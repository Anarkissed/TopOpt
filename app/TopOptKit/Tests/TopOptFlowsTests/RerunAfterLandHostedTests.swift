// RerunAfterLandHostedTests — B1, ledger note 3 (approved design 2026-11-02).
//
// His words: "after running an optimization, running it again doesn't work, I have to close and re-open it."
// The design: one run state for the workspace (Ready → Running → Landed → Ready); after a run lands, a change makes a draft
// and Optimize is live again ("Optimize as v2"), and the next version runs.
//
// The whole loop through the REAL page (mounted as RootView mounts it, so a version switch builds a fresh workspace as on his iPad) and REAL
// clicks. The core is replaced by `RunModel.hostedTestRunner` (lookalike results, nothing sent anywhere).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class RerunAfterLandHostedTests: XCTestCase {

    final class Runs: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func add() { lock.lock(); n += 1; lock.unlock() }
    }

    /// Click Optimize, the left of the Optimize │ ⌃ split, as he does.
    func clickOptimize(_ h: AppBuildHost, _ what: String) throws {
        let f = try h.onScreen("optimizeSplit", what)
        h.click(CGPoint(x: f.minX + (f.width - 46) / 2, y: f.midY), settle: 1)
    }

    func waitUntil(_ h: AppBuildHost, _ s: Double, _ what: String, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while !cond(), Date() < end { h.pump(0.1) }
        XCTAssertTrue(cond(), "★ timed out: \(what)")
    }

    func testOptimizeAgainAfterARunLandsMakesTheNextVersionAndRunsIt() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let app = r.app, p = r.project, disk = ProjectStore(rootDir: r.root)
        p.lattice.flexible = nil                 // his Structural part (the lookalike is a Flexible one; in memory only)
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }   // its third group has no role yet
        app.library.refresh()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)
        XCTAssertEqual(app.library.mode, .library, "his Library is grouped")

        let runs = Runs()
        RunModel.hostedTestRunner = { _, _, _ in runs.add(); return AppBuildFixtures.outcome() }
        addTeardownBlock { RunModel.hostedTestRunner = nil }

        let h = AppBuildHost(AppBuildWorkspace(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(3)

        // the first run, his click
        try clickOptimize(h, "Optimize, first run")
        waitUntil(h, 15, "the first run lands") { p.run.phase == .succeeded }
        XCTAssertEqual(runs.count, 1, "the first click ran once")
        waitUntil(h, 10, "its results are saved") { disk.hasPersistedResults(id: p.id) }

        // he changes the Safety margin (a setting; the Setup panel's own row is B2's)
        p.force.safetyMargin = 2.0
        h.pump(0.5)

        // ★ Optimize again: the "Optimize as v2" card shows
        try clickOptimize(h, "Optimize, after the run landed")
        _ = try h.onScreen("nextVersionOptimize", "★ the Optimize as v2 card, after a landed run")

        // ★ its Optimize opens v2 and v2 runs
        try h.tap("nextVersionOptimize", "the card's Optimize v2", settle: 1.5)
        waitUntil(h, 15, "v2 opens and its run lands") { app.project.map { $0.id != p.id && $0.run.phase == .succeeded } ?? false }
        XCTAssertEqual(runs.count, 2, "★ the second run ran")

        // ★ and again, in v2: a third run is not blocked either
        let v2 = try XCTUnwrap(app.project)
        waitUntil(h, 10, "v2's results are saved") { disk.hasPersistedResults(id: v2.id) }
        v2.force.safetyMargin = 2.5
        h.pump(0.5)
        try clickOptimize(h, "Optimize in v2, after its run landed")
        _ = try h.onScreen("nextVersionOptimize", "★ the Optimize as v3 card, in v2")
    }
}
#endif

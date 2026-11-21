// EngineFailureLineHostedTests — B1, ledger O1 (approved design 2026-11-02; screenshot A7C1E0C9).
//
// "An engine failure is one plain line on the button that failed, never the raw engine text in a card." His screenshot
// showed core's own text in a warning card ("topopt-cli: job.json: face region 107 …"). Now the run that core could not
// finish ends with one line on the button that started it — "Couldn't finish · tap to try again" — and no card; a tap tries
// again. (A stall's "Keep waiting" and "Not strong enough to print" stay cards: the question is with the reviewer.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class EngineFailureLineHostedTests: XCTestCase {

    final class Runs: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    func testCoresOwnFailureIsOneLineOnOptimizeNeverACardAndATapTriesAgain() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let runs = Runs()
        // the first run: core refuses with its own words; the second lands
        RunModel.hostedTestRunner = { _, _, _ in
            if runs.next() == 1 { throw TopOptError(message: "topopt-cli: job.json: face region 107 declares neither a filter nor any \"add\" faces") }
            return AppBuildFixtures.outcome()
        }
        addTeardownBlock { RunModel.hostedTestRunner = nil }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(3)

        let f = try h.onScreen("optimizeSplit", "Optimize")
        h.click(CGPoint(x: f.minX + (f.width - 46) / 2, y: f.midY), settle: 2)
        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(h.frames.all["runFailureSheet"], "★ no card with the engine's text")
        _ = try h.onScreen("optimizeCouldntFinish", "★ one line on Optimize: it couldn't finish")
        XCTAssertEqual(p.run.lastEngineFailureText?.hasPrefix("topopt-cli"), true, "the engine's words are kept (for the (i))")
        XCTAssertNotEqual(p.run.phase, .failed, "the failure is not left up")

        // ★ a tap on the same button tries again
        let g = try h.onScreen("optimizeSplit", "Optimize")
        h.click(CGPoint(x: g.minX + (g.width - 46) / 2, y: g.midY), settle: 2)
        let end = Date().addingTimeInterval(10)
        while p.run.phase != .succeeded, Date() < end { h.pump(0.1) }
        XCTAssertEqual(runs.count, 2, "★ the tap ran it again")
        XCTAssertEqual(p.run.phase, .succeeded)
        XCTAssertNil(h.frames.all["optimizeCouldntFinish"], "the line is gone once it ran")
    }
}
#endif

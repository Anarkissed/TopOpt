// TopologyOptimizeOnlyHostedTests — B3 (#362's note from his iPad, 11-03 15:03; app-map §3.3: the corner's ⌃ holds
// "Optimize, then lattice").
//
// Opening the Lattice stage switches the lattice on, even with nothing latticed. With "Allow growth here" on (a design box),
// Topology's Optimize then greyed with "a graded lattice can't use a design box…" on a part with nothing latticed, and its job
// carried the lattice block. Now Topology's Optimize is topology only: no lattice block and no lattice refusal. The lattice
// rides ⌃ "Optimize, then lattice" (and the Lattice stage's own Optimize). RED before B3 (saved: scratchpad
// b2red/TopologyOptimizeOnly.txt): the Optimize click started nothing, and ⌃ had no such run.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class TopologyOptimizeOnlyHostedTests: XCTestCase {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [RunRequest] = []
        func add(_ r: RunRequest) { lock.lock(); all.append(r); lock.unlock() }
        var requests: [RunRequest] { lock.lock(); defer { lock.unlock() }; return all }
    }

    override func setUp() async throws {
        addTeardownBlock { @MainActor in RunModel.hostedTestRunner = nil }
    }

    func host(_ r: FlexibleHisProject.Restored, _ sent: Sent) -> AppBuildHost {
        RunModel.hostedTestRunner = { req, _, _ in sent.add(req); return AppBuildFixtures.outcome() }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: r.project), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        return h
    }

    func clickOptimize(_ h: AppBuildHost) throws {
        let f = try h.onScreen("optimizeButton", "Optimize")
        h.click(CGPoint(x: f.midX, y: f.midY), settle: 1)
    }

    func waitUntil(_ h: AppBuildHost, _ s: Double, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while !cond(), Date() < end { h.pump(0.1) }
    }

    func job(_ r: RunRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(r)) as? [String: Any])
    }

    /// His case: the Lattice stage was opened (the lattice on, nothing latticed, graded), and Allow growth here is on.
    func testTopologysOptimizeSendsNoLatticeAndShowsNoLatticeRefusal() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }   // no group left pending
        p.lattice.enabled = true                      // what opening the Lattice stage leaves behind
        p.lattice.densityMode = .sim                  // graded
        p.designBox = DesignBoxModel(primitives: [DesignPrimitive(id: 1, name: "Box 1", shape: .box, sign: .positive,
            bounds: DesignBoxBounds(min: SIMD3<Float>(-200, -200, -200), max: SIMD3<Float>(200, 200, 200)))])
        XCTAssertNotNil(LatticeCoreCapability.liveConflict(latticeEnabled: p.lattice.enabled, designBoxActive: p.designBox.isActive,
                                                           graded: p.lattice.densityMode == .sim),
                        "premise: the lattice run would be refused for the design box")
        let sent = Sent()
        let h = host(r, sent)

        // ★ Optimize itself is topology only: it runs, and sends no lattice
        try clickOptimize(h)
        waitUntil(h, 10) { !sent.requests.isEmpty }
        let req = try XCTUnwrap(sent.requests.first, "★ Topology's Optimize starts — no lattice refusal greys it")
        XCTAssertNil(req.lattice, "★ no lattice block in Topology's run")
        XCTAssertNil(try job(req)["lattice"], "★ the job carries no lattice")
        XCTAssertNotNil(try job(req)["design_box"], "Allow growth here still goes")

        // ⌃ offers the lattice run, greyed with its reason; choosing it starts nothing
        RunModel.hostedTestRunner = { req, _, _ in sent.add(req); return AppBuildFixtures.outcome() }
        let n = sent.requests.count
        let offered = try h.pickFromMenu("topologySplitMore", "Optimize, then lattice", what: "⌃")
        XCTAssertTrue(offered.contains { $0.hasPrefix("Optimize, then lattice") && $0.hasSuffix("[off]") },
                      "★ ⌃ holds Optimize, then lattice, greyed while the lattice run can't start: \(offered)")
        XCTAssertEqual(TopologyRunCopy.growthClash, "A graded lattice can\u{2019}t use Allow growth here yet",
                       "★ the reviewer's follow-up 2: core's refusal as one plain line on that row, never a card")
        XCTAssertEqual(sent.requests.count, n, "a greyed lattice run starts nothing")
    }

    /// The lattice set on the part (his Top's prism): ⌃ "Optimize, then lattice" carries it; Optimize still does not.
    func testOptimizeThenLatticeCarriesTheLattice() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)   // his Top's face prism: a lattice include
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }   // no group left pending
        XCTAssertNotNil(r.app.makeRunRequest()?.lattice, "premise: the lattice run would carry the block")
        let sent = Sent()
        let h = host(r, sent)
        let offered = try h.pickFromMenu("topologySplitMore", "Optimize, then lattice", what: "⌃")
        XCTAssertTrue(offered.contains { $0.hasPrefix("Optimize, then lattice") && !$0.hasSuffix("[off]") }, "\(offered)")
        waitUntil(h, 10) { !sent.requests.isEmpty }
        let req = try XCTUnwrap(sent.requests.first, "★ Optimize, then lattice starts")
        XCTAssertNotNil(req.lattice, "★ it carries the lattice")
        XCTAssertNotEqual(req.jobMode, "lattice_part", "an optimize run (the ladder), not Lattice the part")
        XCTAssertEqual(r.app.makeRunRequest(lattice: false)?.lattice == nil, true, "Topology's Optimize would send none")
    }

    /// #362's condition (20:42Z): a failed run's Try again re-runs THAT run's flavour — the one recorded where a run starts — never
    /// the flavour of the stage the retry is tapped from.
    func testTryAgainKeepsTheFailedRunsFlavour() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let ws = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("onRetry: { startRun(lattice: startedRunWithLattice) }"), "★ Try again: the failed run's flavour")   // (T5: the card's version follows it)
        XCTAssertEqual(ws.components(separatedBy: "        startedRunWithLattice = ").count - 1, 1, "★ set in one place only (its declaration aside)")
        XCTAssertTrue(ws.contains("        lastRunRequest = request   // Optimize greys out until the inputs change\n        startedRunWithLattice = lattice"),
                      "★ where the run actually starts, after every refusal")
    }
}
#endif

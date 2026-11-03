// TopologyEntriesSendNoLatticeHostedTests — B3, the reviewer's follow-up 1 (23:05Z): makeRunRequest's default carries the
// lattice, so EVERY Topology entry is checked to send none — the button, the re-run card's Re-run here, Try again after a
// failed Topology run, the copy's one-shot run (Save as new project) and Optimize as v2's run (the Library card). A new
// caller that forgets the flavour sends a lattice block on his part with the lattice set, and goes red here.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class TopologyEntriesSendNoLatticeHostedTests: XCTestCase {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [RunRequest] = []
        var failNext = false
        func add(_ r: RunRequest) { lock.lock(); all.append(r); lock.unlock() }
        var requests: [RunRequest] { lock.lock(); defer { lock.unlock() }; return all }
    }
    struct Boom: Error {}

    override func setUp() async throws {
        addTeardownBlock { @MainActor in RunModel.hostedTestRunner = nil }
    }

    func waitUntil(_ h: AppBuildHost, _ s: Double, _ what: String, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while !cond(), Date() < end { h.pump(0.1) }
        XCTAssertTrue(cond(), "★ timed out: \(what)")
    }

    /// Optimize, the left of the Optimize │ ⌃ split, whatever its line says ("Couldn't finish · tap to try again" too).
    func clickOptimize(_ h: AppBuildHost) throws {
        let f = try h.onScreen("optimizeSplit", "Optimize")
        h.click(CGPoint(x: f.minX + (f.width - 46) / 2, y: f.midY), settle: 1)
    }

    /// His pad with his Top latticed (an include) and a Structural type: a lattice run WOULD carry a block.
    func app(library: Bool) throws -> (AppModel, ProjectModel, Sent, URL) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        XCTAssertNotNil(r.app.makeRunRequest()?.lattice, "premise: the lattice flavour would carry the block")
        if library { r.app.library.refresh(); try r.app.library.group(projectName: "Squish Mechanism", partIDs: nil) }
        let sent = Sent()
        RunModel.hostedTestRunner = { req, _, _ in
            sent.add(req)
            if sent.failNext { sent.failNext = false; throw Boom() }
            return AppBuildFixtures.outcome()
        }
        return (r.app, p, sent, r.root)
    }

    func testButtonReRunHereTryAgainAndTheCopysRunSendNoLattice() throws {
        let (app, p, sent, _) = try app(library: false)
        let h = AppBuildHost(AppBuildWorkspace(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        // the button
        try clickOptimize(h)
        waitUntil(h, 15, "the first run lands") { p.run.phase == .succeeded }
        // the re-run card's Re-run here
        try clickOptimize(h)
        try h.tap("rerunChoice-rerun", "Re-run here")
        waitUntil(h, 15, "the re-run lands") { sent.requests.count == 2 && p.run.phase == .succeeded }
        // Try again after a failed Topology run (the button's "Couldn't finish · tap to try again")
        sent.failNext = true
        try clickOptimize(h)
        try h.tap("rerunChoice-rerun", "Re-run here, into a failure")
        waitUntil(h, 15, "the run fails") { sent.requests.count == 3 && p.run.phase != .running }
        h.pump(1)
        try clickOptimize(h)
        if h.frames.all["rerunConfirm"] != nil { try h.tap("rerunChoice-rerun", "Re-run here (its results came back)") }
        waitUntil(h, 15, "Try again runs") { sent.requests.count == 4 }
        waitUntil(h, 15, "and lands") { p.run.phase == .succeeded }
        // Save as new project: the copy opens and runs once
        try clickOptimize(h)
        try h.tap("rerunChoice-copy", "Save as new project")
        waitUntil(h, 20, "the copy's run") { sent.requests.count == 5 }
        XCTAssertNotEqual(app.project?.id, p.id, "the copy is open")
        for (i, r) in sent.requests.enumerated() {
            XCTAssertNil(r.lattice, "★ Topology entry \(i + 1) of 5 sent a lattice block")
        }
    }

    func testOptimizeAsTheNextVersionSendsNoLattice() throws {
        let (app, p, sent, root) = try app(library: true)
        let disk = ProjectStore(rootDir: root)
        let h = AppBuildHost(AppBuildWorkspace(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        try clickOptimize(h)
        waitUntil(h, 15, "the first run lands") { p.run.phase == .succeeded }
        waitUntil(h, 10, "its results are saved") { disk.hasPersistedResults(id: p.id) }
        p.force.safetyMargin = 2.0
        h.pump(0.5)
        try clickOptimize(h)
        try h.tap("nextVersionOptimize", "Optimize as v2", settle: 1.5)
        waitUntil(h, 20, "v2's run") { sent.requests.count == 2 }
        XCTAssertTrue(sent.requests.allSatisfy { $0.lattice == nil }, "★ Optimize as v2 sends no lattice block")
    }
}
#endif

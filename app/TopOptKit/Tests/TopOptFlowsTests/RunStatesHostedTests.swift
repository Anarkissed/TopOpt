// RunStatesHostedTests — B3 (approved design 2026-11-02, plan.md §B3 "Run states", design-system §4.6 / §4.16, ledger O2).
//
// Each state of Topology's run button, as he sees it: ready (the mode and the load case) · blocked (grey, ≤ 5 words, the fix
// chip beside it — the corner's fix line — and the long reason behind its (i)) · same settings ("Same settings as v6") ·
// running (Cancel · Run in background) · landed ("v8 is ready · Open"). Finding your Mac is RememberedMacHostedTests (B1);
// the background pill is NotificationLaneTests (B2); Optimize as v8 is RerunAfterLandHostedTests (B1).
// RED before B3 (saved: scratchpad b2red/RunStates.txt): no fix line; "finish the pending group" on the button; "Optimization
// finished — 3 variants" and "Open Results".
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class RunStatesHostedTests: XCTestCase {
    final class Runs: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func add() { lock.lock(); n += 1; lock.unlock() }
    }

    override func setUp() async throws {
        addTeardownBlock { @MainActor in RunModel.hostedTestRunner = nil }
    }

    func page(_ size: CGSize, pending: Bool = false, results: Int = 3) throws -> (AppBuildHost, ProjectModel, AppModel, Runs) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        if !pending, let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let runs = Runs()
        RunModel.hostedTestRunner = { _, _, _ in runs.add(); return AppBuildFixtures.outcome(results) }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p, r.app, runs)
    }

    func waitUntil(_ h: AppBuildHost, _ s: Double, _ what: String, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while !cond(), Date() < end { h.pump(0.1) }
        XCTAssertTrue(cond(), "★ timed out: \(what)")
    }

    /// Blocked: his pad's third group has faces and no role. The button greys with "A group has no role"; beside it (the fix
    /// line, just above the corner pair) the one-tap fix picks that group.
    func testBlockedIsFiveWordsAndAFixChip() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let (h, p, _, runs) = try page(size, pending: true)
            let what = "\(size)"
            let line = try h.onScreen("topologyFixLine", "\(what): ★ the corner's fix line")
            let split = try h.onScreen("optimizeSplit", "\(what): the run button")
            XCTAssertLessThanOrEqual(line.maxY, split.minY + 0.5, "\(what): ★ just above the pair, never over it")
            XCTAssertLessThanOrEqual(TopologyBlock.pendingGroup.words.split(separator: " ").count, 5, "U6: ≤ 5 words")
            let chip = try h.probe("topologyFixChip", "\(what): ★ the fix chip", minHit: 44)
            XCTAssertTrue(line.contains(chip), "\(what): the chip is in the line")
            _ = try h.onScreen("info-topologyBlock", "\(what): the long reason behind (i)")
            h.click(CGPoint(x: chip.midX, y: chip.midY))
            let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
            XCTAssertEqual(p.selection.activeGroupID, c.id, "\(what): ★ the fix picks the group with no role")
            XCTAssertEqual(runs.count, 0, "\(what): a fix never runs")
            p.force.makeAnchor(c.id)
            h.pump(0.6)
            XCTAssertNil(h.frames.all["topologyFixLine"], "\(what): ★ fixed: the line goes")
        }
    }

    /// Same settings: Optimize greys with "Same settings as v6" when nothing changed since this project's last run and there
    /// are no results to re-run over (a cancelled run; a FAILED run stays live for Try again, B1). The words, and the button's
    /// line reads them from the same grey-out the gate uses.
    func testSameSettingsWords() throws {
        XCTAssertEqual(TopologyRunCopy.sameSettings(nil), "Same settings as last time")
        XCTAssertEqual(TopologyRunCopy.sameSettings("v6"), "Same settings as v6")
        let ws = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("!ok && run.phase != .running && sameSettingsAsLast(lattice: lattice) ? TopologyRunCopy.sameSettings(versionLabel)"))
        XCTAssertTrue(ws.contains("return RerunCard.greysOut(sameInputsAsLastRun: model.makeRunRequest(lattice: lattice) == last, existing: run.outcome)"),
                      "the same grey-out as the gate (H50a)")
    }

    /// Landed: Results never opens by itself; the message says the version is ready, and Open opens it.
    func testLandedSaysReadyAndOpen() throws {
        let (h, p, _, runs) = try page(AppBuildHost.landscape13)
        let f = try h.onScreen("optimizeButton", "Optimize")
        h.click(CGPoint(x: f.midX, y: f.midY), settle: 1)
        waitUntil(h, 15, "the run lands") { runs.count == 1 && p.run.phase == .succeeded }
        h.pump(1)
        XCTAssertEqual(TopologyRunCopy.landed(nil), "Your results are ready")
        XCTAssertEqual(TopologyRunCopy.landed("v8"), "v8 is ready")
        XCTAssertEqual(TopologyResultsNotice.openLabel, "Open")
        let ws = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TopOptFlows/RunScreen.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("\"In background\" : \"Run in background\""), "★ the running card: Cancel · Run in background")
    }

    /// Every block, its words (≤ 5) and its fix.
    func testEveryBlockIsFiveWordsAtMost() {
        let g = UUID()
        for b in [TopologyBlock.gravity, .pendingGroup, .noLoadCase, .noDirection(group: g, why: "w"), .emptyPiece(group: g)] {
            XCTAssertLessThanOrEqual(b.words.split(separator: " ").count, 5, "★ U6: \(b.words)")
            XCTAssertFalse(b.fix.isEmpty)
            XCTAssertNotNil(b.info, "the long reason sits behind (i)")
        }
    }
}
#endif

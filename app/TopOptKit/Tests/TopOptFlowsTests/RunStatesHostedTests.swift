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

    // MARK: ★ LOOK PER SCREEN, Topology slice T5 — the run states as mockup #topo-corner draws them

    /// A scenario's gap is a block BEFORE the press (U6 / U12; mockup #topo-corner "blocked": "No anchor in Held by left plate ·
    /// Switch its anchors on"), from the same rule the press reads (LoadScenarioRule) — never a toast after a ready-looking
    /// Optimize. RED before T5 (scratchpad b2red/RunStates-T5.txt): Optimize stays ready and the press toasts "Scenario … has
    /// no load".
    func testAScenarioGapIsABlockWithItsFixBeforeThePress() throws {
        let (h, p, app, runs) = try page(AppBuildHost.landscape13)
        let gs = p.selection.groups
        let bottom = try XCTUnwrap(gs.first { $0.name == "Bottom" }), top = try XCTUnwrap(gs.first { $0.name == "Top" })
        let c = try XCTUnwrap(gs.first { $0.name == "Group C" })
        p.force.makeAnchor(bottom.id)
        p.force.makeLoad(c.id)   // Scenario 1's load
        let s2 = p.force.addScenario()   // Scenario 2: open, and no load yet
        p.force.sync(groups: p.selection.groups)
        h.pump(0.8)
        XCTAssertNotNil(TopologyBlock.scenarioGap(scenario: s2, name: "Scenario 2", gap: .noLoad).info)
        _ = try h.onScreen("topologyFixLine", "★ the gap is said at once, in the corner's fix line")
        var chip = try h.probe("topologyFixChip", "★ its one-tap fix", minHit: 44)
        let f = try h.onScreen("optimizeButton", "Optimize")
        h.click(CGPoint(x: f.midX, y: f.midY))
        XCTAssertEqual(runs.count, 0, "nothing runs")
        XCTAssertNotEqual(app.toast, LoadScenarioRule.noLoadLine("Scenario 2"), "★ never a toast after a ready-looking Optimize")
        p.force.openScenario(p.force.scenarioList[0].id)
        h.pump(0.4)
        chip = try h.onScreen("topologyFixChip", "the fix")
        h.click(CGPoint(x: chip.midX, y: chip.midY))
        XCTAssertEqual(p.force.activeScenarioID, s2, "★ Show it: the scenario with no load opens")
        // its load given (Top, in Scenario 2 — a fresh role is claimed by the open scenario): the block goes
        p.force.clearKind(top.id)
        p.force.makeLoad(top.id)
        XCTAssertTrue(p.force.group(top.id, isIn: s2), "premise: Top's load is Scenario 2's")
        p.force.sync(groups: p.selection.groups)
        h.pump(0.6)
        XCTAssertNil(h.frames.all["topologyFixLine"], "★ fixed: the line goes")
        // an anchor deleted and the rest off in Scenario 2 → "No anchor in Scenario 2 · Switch its anchors on"
        p.force.scenarios?.scenarios[1].anchorsOff = [bottom.id]
        h.pump(0.6)
        chip = try h.probe("topologyFixChip", "★ Switch its anchors on", minHit: 44)
        h.click(CGPoint(x: chip.midX, y: chip.midY))
        XCTAssertTrue(p.force.anchorIsOn(bottom.id, in: s2), "★ the fix switches them on")
        XCTAssertNil(h.frames.all["topologyFixLine"])
        XCTAssertEqual(runs.count, 0, "a fix never runs")
    }

    /// The gap words: the scenario named, its fix (mockup "No anchor in Held by left plate · Switch its anchors on").
    func testTheScenarioGapsWords() {
        let s = UUID()
        XCTAssertEqual(TopologyBlock.scenarioGap(scenario: s, name: "Held by left plate", gap: .noAnchor(switchable: true)).words,
                       "No anchor in Held by left plate")
        XCTAssertEqual(TopologyBlock.scenarioGap(scenario: s, name: "Held by left plate", gap: .noAnchor(switchable: true)).fix,
                       LoadScenarioRule.switchAnchorsOnLabel)
        XCTAssertEqual(TopologyBlock.scenarioGap(scenario: s, name: "Normal use", gap: .noLoad).words, "No load in Normal use")
        XCTAssertEqual(TopologyBlock.scenarioGap(scenario: s, name: "Normal use", gap: .tooLight("x")).info, "x")
        // the press reads the same rule
        let w = [LoadScenarioWire(name: "A", anchorFaceIDs: [1], loadGroups: []),
                 LoadScenarioWire(name: "B", anchorFaceIDs: [], loadGroups: [])]
        XCTAssertEqual(LoadScenarioRule.gap(w)?.index, 1)
        XCTAssertEqual(LoadScenarioRule.gap(w)?.gap, .noAnchor(switchable: false), "B has no anchor before A's missing load")
    }

    /// Running: the corner's button says so with the time and a tap views the run (mockup "Optimizing v8 · 3:10 left · tap to
    /// view"); the card's Run in background minimises it. RED before T5: the button greys to "Optimize".
    func testWhileItRunsTheButtonSaysOptimizingAndATapShowsTheCard() throws {
        let (h, p, _, _) = try page(AppBuildHost.landscape13)
        RunModel.hostedTestRunner = { _, progress, _ in
            for i in 0..<40 { if !progress(0, 3, i) { break }; Thread.sleep(forTimeInterval: 0.1) }
            return AppBuildFixtures.outcome()
        }
        let f = try h.onScreen("optimizeButton", "Optimize")
        h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.6)
        waitUntil(h, 3, "the run starts") { p.run.phase == .running }
        h.pump(0.4)
        let running = try h.onScreen("optimizeRunning", "★ the button says it is optimizing")
        _ = try h.onScreen("runCard", "the run card")
        try h.tap("runCardBackground", "Run in background")
        XCTAssertTrue(p.run.isMinimized, "the card goes to the background")
        h.click(CGPoint(x: running.midX, y: running.midY))
        XCTAssertFalse(p.run.isMinimized, "★ a tap on the button views the run again")
        p.run.cancel()
        waitUntil(h, 5, "the run stops") { p.run.phase != .running }
    }
}
#endif

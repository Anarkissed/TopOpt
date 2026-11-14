// RememberedMacHostedTests — B1, ledger note 4 (approved design 2026-11-02).
//
// His words: "after I press Optimize, it says that the strengthen must go to the Mac, but the Mac is already selected …
// I have to just OPEN the settings and then it works." The cause: every "is a Mac chosen?" check read
// `compute.activeRemote`, which stays nil until discovery resolves the Mac, and discovery started only when the Settings
// panel's Compute row appeared. The design: the check reads the REMEMBERED Mac; Optimize looks for it for a few seconds
// ("Finding Nadim's Mac mini…"), then runs; if it never answers, one line on the button, and a tap tries again.
//
// Settings is never opened here. Bonjour is replaced by `ComputeLocationModel.hostedTestDiscovery`; the core by
// `RunModel.hostedTestRunner`. Two load scenarios make it a Mac-only run (his refused case).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class RememberedMacHostedTests: XCTestCase {
    static let mac = "Nadim\u{2019}s Mac mini"
    static let key = "topopt.computeLocation.v1"

    final class Runs: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func add() { lock.lock(); n += 1; lock.unlock() }
    }

    override func setUp() async throws {
        let saved = UserDefaults.standard.data(forKey: Self.key)
        UserDefaults.standard.set(try JSONEncoder().encode(ComputeChoice.worker(name: Self.mac)), forKey: Self.key)   // he chose his Mac before
        let find = ComputeLocationModel.findSeconds
        addTeardownBlock { @MainActor in
            if let saved { UserDefaults.standard.set(saved, forKey: Self.key) } else { UserDefaults.standard.removeObject(forKey: Self.key) }
            ComputeLocationModel.hostedTestDiscovery = nil
            ComputeLocationModel.findSeconds = find
            RunModel.hostedTestRunner = nil
        }
    }

    func page(_ runs: Runs) throws -> (AppBuildHost, ProjectModel, AppModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        // two load scenarios (the run must go to the Mac): Scenario 2 pushes on Group C, held by the shared anchor
        let c = try XCTUnwrap(p.selection.groups.first(where: { $0.name == "Group C" }))
        _ = p.force.addScenario()
        p.force.makeLoad(c.id)
        p.force.setWeight(c.id, kg: 51)
        XCTAssertEqual(LoadScenarioRule.refusal(for: try XCTUnwrap(r.app.makeRunRequest()), workerSelected: false), LoadScenarioRule.onDeviceLine,
                       "this setup is a Mac-only run")
        RunModel.hostedTestRunner = { _, _, _ in runs.add(); return AppBuildFixtures.outcome() }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: AppBuildHost.landscape13, test: self)
        return (h, p, r.app)
    }

    func clickOptimize(_ h: AppBuildHost) throws {
        let f = try h.onScreen("optimizeSplit", "Optimize")
        h.click(CGPoint(x: f.minX + (f.width - 46) / 2, y: f.midY), settle: 0.4)
    }

    func waitUntil(_ h: AppBuildHost, _ s: Double, _ what: String, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(s)
        while !cond(), Date() < end { h.pump(0.1) }
        XCTAssertTrue(cond(), "★ timed out: \(what)")
    }

    func testTheRememberedMacIsFoundAndTheRunGoesToItWithoutOpeningSettings() throws {
        let cfg = RemoteRunnerConfig(host: "10.0.0.9", port: 8757, expectedFingerprint: CoreFingerprint.value)
        ComputeLocationModel.hostedTestDiscovery = (Self.mac, cfg, 2.5)   // found 2.5 s after the search starts
        let runs = Runs()
        let (h, p, app) = try page(runs)
        h.pump(0.6)   // he presses Optimize straight away: the Mac is not found yet

        try clickOptimize(h)
        XCTAssertNotEqual(app.toast, LoadScenarioRule.onDeviceLine, "★ never 'must go to the Mac' while his Mac is chosen")
        _ = try h.onScreen("optimizeFindingMac", "★ Optimize says it is finding his Mac")
        XCTAssertEqual(runs.count, 0, "nothing runs on the iPad meanwhile")

        waitUntil(h, 8, "the Mac is found and the run lands") { p.run.phase == .succeeded }
        XCTAssertEqual(runs.count, 1, "★ the run went once")
        XCTAssertNotEqual(app.toast, LoadScenarioRule.onDeviceLine)
        XCTAssertEqual(p.run.outcome?.solvedBy, Self.mac, "★ it ran on his Mac")
    }

    func testAMacThatNeverAnswersSaysSoOnTheButtonAndATapTriesAgain() throws {
        ComputeLocationModel.findSeconds = 2
        ComputeLocationModel.hostedTestDiscovery = (Self.mac, nil, 0)   // never found
        let runs = Runs()
        let (h, p, app) = try page(runs)
        h.pump(0.6)

        try clickOptimize(h)
        _ = try h.onScreen("optimizeFindingMac", "Optimize says it is finding his Mac")
        h.pump(2.6)
        _ = try h.onScreen("optimizeMacNotAnswering", "★ one line on Optimize: his Mac isn't answering")
        XCTAssertNotEqual(app.toast, LoadScenarioRule.onDeviceLine, "★ never 'must go to the Mac'")
        XCTAssertEqual(runs.count, 0)
        // ★ LOOK PER SCREEN (T5, mockup #topo-corner "nomac"): Optimize greys and the corner's fix line says it, with Try again
        _ = try h.onScreen("topologyFixLine", "★ the fix line: Your Mac isn't answering")
        let again = try h.probe("topologyFixChip", "★ Try again", minHit: 44)

        // the Mac comes back; his tap on Try again tries again
        ComputeLocationModel.hostedTestDiscovery = (Self.mac,
                                                    RemoteRunnerConfig(host: "10.0.0.9", port: 8757, expectedFingerprint: CoreFingerprint.value), 0.3)
        h.click(CGPoint(x: again.midX, y: again.midY), settle: 0.4)
        waitUntil(h, 6, "the second try finds it and runs") { p.run.phase == .succeeded }
        XCTAssertEqual(runs.count, 1, "★ Try again ran it")
        XCTAssertNotNil(h.frames.all["optimizeButton"], "the line is gone once it ran")
    }
}
#endif

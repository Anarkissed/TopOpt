// Headless macOS tests for the M7.7 run screen (RunModel + RunProgress +
// RunFailure). The M7 /app/ standard is `xcodebuild test` on this package.
//
// The pure bar math and failure classification are asserted directly; the
// background/cancel/notify orchestration is driven through the injected
// synchronous scheduler + a stub runner + a notifier spy (so no real optimize is
// needed), and one integration test drives the REAL bridge minimize_plastic on
// the committed cube fixture through the production GCD scheduler — that last one
// would fail if the runner were stubbed out or the bridge wiring broke.

import XCTest
import Combine
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RunModelTests: XCTestCase {

    // MARK: repo paths (…/app/TopOptKit/Tests/TopOptFlowsTests/RunModelTests.swift -> up 5 -> root)
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/settings/rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }

    private func request(resolution: Int = 24) -> RunRequest {
        RunRequest(modelPath: Self.cubeSTL, material: "PLA", materialsPath: Self.materialsPath,
                   rulesPath: Self.rulesPath, resolution: resolution, projectName: "Cube")
    }

    // MARK: - RunProgress math

    func testFractionZeroBeforeFirstIteration() {
        let p = RunProgress(rung: 0, rungCount: 3, iteration: 0)
        XCTAssertEqual(p.fractionComplete, 0, accuracy: 1e-12)
        XCTAssertEqual(p.percent, 0)
    }

    func testFractionMonotoneWithinAndAcrossRungs() {
        let a = RunProgress(rung: 0, rungCount: 3, iteration: 10)
        let b = RunProgress(rung: 0, rungCount: 3, iteration: 40)
        let c = RunProgress(rung: 1, rungCount: 3, iteration: 1)   // next rung, fresh
        // Within a rung, more iterations => further along.
        XCTAssertGreaterThan(b.fractionComplete, a.fractionComplete)
        // A completed rung's floor (1/3) exceeds anything still in rung 0 (< 1/3).
        XCTAssertLessThan(b.fractionComplete, 1.0 / 3.0)
        XCTAssertGreaterThan(c.fractionComplete, 1.0 / 3.0)
    }

    func testFractionNeverReachesOne() {
        let deep = RunProgress(rung: 2, rungCount: 3, iteration: 100_000)
        XCTAssertLessThan(deep.fractionComplete, 1.0)
        XCTAssertLessThanOrEqual(deep.fractionComplete, 0.999)
    }

    func testProgressClampsDegenerateInputs() {
        // rungCount 0 -> 1; rung past the end clamps to last; negative iteration -> 0.
        let p = RunProgress(rung: 5, rungCount: 0, iteration: -3)
        XCTAssertEqual(p.rungCount, 1)
        XCTAssertEqual(p.rung, 0)
        XCTAssertEqual(p.iteration, 0)
    }

    func testStageLabelSingleVsMultiRung() {
        XCTAssertEqual(RunProgress(rung: 0, rungCount: 1, iteration: 7).stageLabel,
                       "SIMP iteration 7")
        XCTAssertEqual(RunProgress(rung: 1, rungCount: 3, iteration: 12).stageLabel,
                       "Variant 2 of 3 · SIMP iteration 12")
    }

    // MARK: - RunFailure copy

    func testFailureMessages() {
        XCTAssertEqual(RunFailure.solver("CG did not converge").message, "CG did not converge")
        XCTAssertEqual(RunFailure.solver("x").title, "Optimization couldn’t finish")
        XCTAssertEqual(RunFailure.allRungsRejected.title, "No printable variant found")
        XCTAssertTrue(RunFailure.allRungsRejected.message.contains("printability"))
    }

    // MARK: - orchestration (synchronous scheduler + stub runner)

    private func accepted(count: Int = 1) -> OptimizeOutcome {
        OptimizeOutcome(variants: [], stoppedOnMargin: true, cancelled: false, acceptedCount: count)
    }

    func testSuccessStoresOutcomeAndClearsProgress() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, progress in
            _ = progress(0, 3, 5)
            _ = progress(1, 3, 8)
            return self.accepted(count: 2)
        }
        model.start(request())
        XCTAssertEqual(model.phase, .succeeded)
        XCTAssertEqual(model.outcome?.acceptedCount, 2)
        XCTAssertNil(model.progress)                 // cleared on success
        XCTAssertNil(model.failure)
    }

    func testProgressPublishedFromCallback() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        var lastSeen: RunProgress?
        model.runner = { _, progress in
            _ = progress(0, 3, 4)
            lastSeen = model.progress               // published synchronously by the inline scheduler
            return self.accepted()
        }
        model.start(request())
        XCTAssertEqual(lastSeen, RunProgress(rung: 0, rungCount: 3, iteration: 4))
    }

    func testAllRungsRejectedIsAFailureSheet() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, _ in self.accepted(count: 0) }
        model.start(request())
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.failure, .allRungsRejected)
    }

    func testSolverThrowIsAFailureSheetWithDiagnostic() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, _ in throw TopOptError(message: "CG did not converge in 5000 iters") }
        model.start(request())
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.failure, .solver("CG did not converge in 5000 iters"))
    }

    func testCancelStopsTheCallbackAndYieldsCancelledPhase() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        var returnedAfterCancel: Bool?
        model.runner = { _, progress in
            XCTAssertTrue(progress(0, 3, 1))         // still going
            model.cancel()                            // user hits Cancel
            let keepGoing = progress(0, 3, 2)         // token now flips this to false
            returnedAfterCancel = keepGoing
            // the core returns a cancelled outcome cleanly when told to stop (M7.0a)
            return OptimizeOutcome(variants: [], stoppedOnMargin: false,
                                   cancelled: !keepGoing, acceptedCount: 0)
        }
        model.start(request())
        XCTAssertEqual(returnedAfterCancel, false)   // the callback reported stop
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertNil(model.failure)                  // cancel is not a failure
    }

    // MARK: - Run in Background + notifier

    private final class NotifierSpy: RunNotifier {
        var willCount = 0
        var completions: [String] = []
        func willRunInBackground() { willCount += 1 }
        func runDidComplete(summary: String) { completions.append(summary) }
    }

    func testRunInBackgroundNotifiesOnCompletion() {
        let spy = NotifierSpy()
        let model = RunModel(scheduler: SynchronousRunScheduler(), notifier: spy)
        model.runner = { _, progress in
            _ = progress(0, 3, 1)
            model.runInBackground()                   // user backgrounds mid-run
            XCTAssertTrue(model.runningInBackground)
            return self.accepted(count: 3)
        }
        model.start(request())
        XCTAssertEqual(spy.willCount, 1)
        XCTAssertEqual(spy.completions, ["Cube: 3 variants ready"])
    }

    func testForegroundRunDoesNotNotify() {
        let spy = NotifierSpy()
        let model = RunModel(scheduler: SynchronousRunScheduler(), notifier: spy)
        model.runner = { _, _ in self.accepted() }
        model.start(request())
        XCTAssertEqual(spy.willCount, 0)
        XCTAssertTrue(spy.completions.isEmpty)        // never backgrounded => no notification
    }

    // MARK: - guards

    func testStartIsNoOpWhileRunning() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        var starts = 0
        model.runner = { _, progress in
            starts += 1
            model.start(self.request())               // re-entrant start must be ignored
            _ = progress(0, 1, 1)
            return self.accepted()
        }
        model.start(request())
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(model.phase, .succeeded)
    }

    func testDismissFailureReturnsToIdle() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, _ in self.accepted(count: 0) }
        model.start(request())
        XCTAssertEqual(model.phase, .failed)
        model.dismissFailure()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.failure)
    }

    // MARK: - integration: the REAL bridge on the committed cube fixture

    func testRealMinimizePlasticRunReachesTerminalPhase() {
        // Drives the production GCD scheduler + the real minimize_plastic on the
        // committed cube fixture. Proves the runner is actually wired to the core
        // (a stub couldn't pass) and that progress callbacks marshal back onto
        // main. Small resolution keeps it fast.
        let model = RunModel(scheduler: GCDRunScheduler())
        var progressTicks = 0
        var cancellables = Set<AnyCancellable>()
        let done = expectation(description: "run reaches a terminal phase")
        done.assertForOverFulfill = false

        model.$progress
            .compactMap { $0 }
            .sink { _ in progressTicks += 1 }
            .store(in: &cancellables)
        model.$phase
            .sink { phase in
                if phase == .succeeded || phase == .failed || phase == .cancelled { done.fulfill() }
            }
            .store(in: &cancellables)

        model.start(request(resolution: 20))
        wait(for: [done], timeout: 180)

        XCTAssertFalse(model.phase.isRunning)
        XCTAssertNotEqual(model.phase, .idle)
        XCTAssertGreaterThan(progressTicks, 0, "expected at least one SIMP iteration callback")
    }
}

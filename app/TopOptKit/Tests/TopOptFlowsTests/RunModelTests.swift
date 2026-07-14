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

    // MARK: - load-case routing

    func testRunRequestIsStepModel() {
        func req(_ path: String) -> RunRequest {
            RunRequest(modelPath: path, material: "PLA", materialsPath: "", rulesPath: "",
                       resolution: 20, projectName: "P")
        }
        XCTAssertTrue(req("/x/part.step").isStepModel)
        XCTAssertTrue(req("/x/Part.STP").isStepModel)   // case-insensitive
        XCTAssertFalse(req("/x/part.stl").isStepModel)  // STL → self-weight path
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
        let f = RunFailure.allRejectedOnMargin(worstMargin: 0.90, minFeatureViolations: 952)
        XCTAssertEqual(f.title, "Not strong enough to print")
        XCTAssertTrue(f.message.contains("0.90×"), "names the worst-case margin")
        XCTAssertTrue(f.message.contains("1.5×"), "names the safety minimum")
        XCTAssertTrue(f.message.contains("952"), "names the advisory violation count")
        XCTAssertTrue(f.message.contains("advisory"))
        // With no violations the advisory clause is omitted.
        XCTAssertFalse(RunFailure.allRejectedOnMargin(worstMargin: 1.2, minFeatureViolations: 0)
                        .message.contains("advisory"))
    }

    // MARK: - orchestration (synchronous scheduler + stub runner)

    private func accepted(count: Int = 1) -> OptimizeOutcome {
        OptimizeOutcome(variants: [], stoppedOnMargin: true, cancelled: false, acceptedCount: count)
    }

    /// A stub variant with a chosen margin / acceptance / thin-feature count.
    private func variant(margin: Double, accepted: Bool, violations: Int = 0) -> OptimizeVariant {
        OptimizeVariant(requestedVolumeFraction: 0.7, achievedVolumeFraction: 0.7,
                        massGrams: 10, supportVolumeVoxels: 0, meshTriangleCount: 100,
                        worstCaseMargin: margin, accepted: accepted, v3Passes: true,
                        minFeatureViolations: violations,
                        minFeatureWarning: violations > 0 ? "\(violations) thin features" : "")
    }

    func testSuccessStoresOutcomeAndClearsProgress() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, progress, _ in
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
        model.runner = { _, progress, _ in
            _ = progress(0, 3, 4)
            lastSeen = model.progress               // published synchronously by the inline scheduler
            return self.accepted()
        }
        model.start(request())
        XCTAssertEqual(lastSeen, RunProgress(rung: 0, rungCount: 3, iteration: 4))
    }

    func testStreamedVariantsAppearBeforeFinish() {
        // Progressive results: onVariant grows `outcome` DURING the run (so the
        // results screen can show variant 1 while the rest optimize), and the run
        // still returns the authoritative final outcome.
        let g = { (n: Int) in OptimizeOutcome(
            variants: [self.variant(margin: 3, accepted: true)],
            stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
            gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1) }
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, _, onVariant in
            onVariant(g(1))                              // first variant lands
            XCTAssertEqual(model.outcome?.variants.count, 1, "results available after variant 1")
            XCTAssertTrue(model.isStreaming)
            onVariant(g(2))                              // second variant lands
            XCTAssertEqual(model.outcome?.variants.count, 2)
            return OptimizeOutcome(
                variants: [self.variant(margin: 3, accepted: true),
                           self.variant(margin: 2, accepted: true)],
                stoppedOnMargin: false, cancelled: false, acceptedCount: 2,
                gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1)
        }
        model.start(request())
        XCTAssertEqual(model.phase, .succeeded)
        XCTAssertEqual(model.outcome?.variants.count, 2)
        XCTAssertFalse(model.isStreaming, "streaming clears when the run resolves")
    }

    func testAllRejectedOnMarginIsAFailureSheetWithNumbers() {
        // Every rung rejected on strength: the terminal rung's margin (< 1.5) and
        // its advisory thin-feature count flow into the sheet.
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, _, _ in
            OptimizeOutcome(variants: [self.variant(margin: 0.9, accepted: false, violations: 952)],
                            stoppedOnMargin: true, cancelled: false, acceptedCount: 0)
        }
        model.start(request())
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.failure, .allRejectedOnMargin(worstMargin: 0.9, minFeatureViolations: 952))
    }

    func testMinFeatureViolationsDoNotBlockAcceptance() {
        // A variant with thin-feature violations but a passing margin is ACCEPTED
        // (core policy: min-feature is report-only, never gates). The run SUCCEEDS,
        // and the violation count is surfaced on the outcome, not turned into a
        // failure — this is the exact CLI-vs-app discrepancy the fix targets.
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, _, _ in
            OptimizeOutcome(variants: [self.variant(margin: 2500, accepted: true, violations: 1334)],
                            stoppedOnMargin: false, cancelled: false, acceptedCount: 1)
        }
        model.start(request())
        XCTAssertEqual(model.phase, .succeeded)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.outcome?.variants.first?.minFeatureViolations, 1334)
    }

    func testSolverThrowIsAFailureSheetWithDiagnostic() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, _, _ in throw TopOptError(message: "CG did not converge in 5000 iters") }
        model.start(request())
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.failure, .solver("CG did not converge in 5000 iters"))
    }

    func testCancelStopsTheCallbackAndYieldsCancelledPhase() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        var returnedAfterCancel: Bool?
        model.runner = { _, progress, _ in
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
        XCTAssertNil(model.outcome, "cancel discards results — no results view")
    }

    // MARK: - Run in Background + notifier

    private final class NotifierSpy: RunNotifier {
        var willCount = 0
        var completions: [String] = []
        func willRunInBackground() { willCount += 1 }
        func runDidComplete(summary: String) { completions.append(summary) }
    }

    func testRunInBackgroundMinimizesAndNotifiesOnCompletion() {
        let spy = NotifierSpy()
        let model = RunModel(scheduler: SynchronousRunScheduler(), notifier: spy)
        var minimizedDuringRun = false
        model.runner = { _, progress, _ in
            _ = progress(0, 3, 1)
            model.runInBackground()                   // user leaves the run screen mid-run
            XCTAssertTrue(model.runningInBackground)
            minimizedDuringRun = model.isMinimized    // the card is dismissed; run keeps going
            return self.accepted(count: 3)
        }
        model.start(request())
        XCTAssertTrue(minimizedDuringRun, "card is dismissed while the run continues")
        XCTAssertEqual(spy.willCount, 1)              // background assertion armed
        XCTAssertEqual(spy.completions, ["Cube: 3 variants ready"])  // notified on completion
        XCTAssertFalse(model.isMinimized, "restored on completion so the result can surface")
    }

    func testRestoreReopensAMinimizedRun() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        var reopenedMidRun = false
        model.runner = { _, progress, _ in
            model.runInBackground()
            XCTAssertTrue(model.isMinimized)
            model.restore()                           // tap the chip
            reopenedMidRun = !model.isMinimized
            _ = progress(0, 1, 1)
            return self.accepted()
        }
        model.start(request())
        XCTAssertTrue(reopenedMidRun)
    }

    func testMinimizedFailureIsRestoredSoTheSheetShows() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, _, _ in
            model.runInBackground()                   // minimized, then it fails
            return OptimizeOutcome(variants: [self.variant(margin: 0.5, accepted: false)],
                                   stoppedOnMargin: true, cancelled: false, acceptedCount: 0)
        }
        model.start(request())
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.isMinimized)             // un-minimized so the failure sheet appears
    }

    func testForegroundRunDoesNotNotify() {
        let spy = NotifierSpy()
        let model = RunModel(scheduler: SynchronousRunScheduler(), notifier: spy)
        model.runner = { _, _, _ in self.accepted() }
        model.start(request())
        XCTAssertEqual(spy.willCount, 0)
        XCTAssertTrue(spy.completions.isEmpty)        // never backgrounded => no notification
    }

    // MARK: - guards

    func testStartIsNoOpWhileRunning() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        var starts = 0
        model.runner = { _, progress, _ in
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
        model.runner = { _, _, _ in self.accepted(count: 0) }
        model.start(request())
        XCTAssertEqual(model.phase, .failed)
        model.dismissFailure()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.failure)
    }

    // MARK: - setup-stall watchdog (M7.diag on-device silent failure)

    /// A scheduler that HOLDS the background work instead of running it, so a run
    /// stays in flight (phase `.running`, no progress) — the on-device stall shape.
    private final class HeldRunScheduler: RunScheduler {
        var held: (() -> Void)?
        func runInBackground(_ work: @escaping () -> Void) { held = work }
        func runOnMain(_ work: @escaping () -> Void) { work() }
    }

    /// A watchdog the test fires by hand (standing in for the grace period elapsing).
    private final class ManualRunWatchdog: RunWatchdog {
        var fire: (() -> Void)?
        private(set) var cancelled = false
        func arm(_ onStall: @escaping () -> Void) -> RunWatchdogCancel {
            fire = onStall
            return { [weak self] in self?.cancelled = true }
        }
    }

    /// The core stalls in setup (no progress, no throw): the watchdog converts the
    /// hung run into an honest failure sheet (not a silent 0% hang) and frees the
    /// run out of `.running` so Optimize re-enables.
    func testSetupStallBecomesAFailureSheet() {
        let dog = ManualRunWatchdog()
        let model = RunModel(scheduler: HeldRunScheduler(), watchdog: dog)
        model.runner = { _, _, _ in self.accepted() }   // never actually runs (work is held)
        model.start(request())
        XCTAssertEqual(model.phase, .running)            // in flight, at 0%
        XCTAssertNil(model.progress)

        dog.fire?()                                      // grace elapses with no progress

        XCTAssertEqual(model.phase, .failed, "a stall must not stay stuck in .running")
        XCTAssertEqual(model.failure, .solver(RunFailure.stalledDuringSetup))
        XCTAssertNil(model.outcome)
    }

    /// A stall on a run that used the design box (the confirmed on-device trigger)
    /// names the box in the failure sheet, so the user is pointed at the workaround.
    func testSetupStallWithDesignBoxNamesTheBox() {
        let dog = ManualRunWatchdog()
        let model = RunModel(scheduler: HeldRunScheduler(), watchdog: dog)
        let boxed = RunRequest(
            modelPath: "/tmp/part.step", material: "PLA",
            materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
            resolution: 64, projectName: "Boxed",
            designBox: .init(min: SIMD3(0, 0, 0), max: SIMD3(50, 50, 50)))
        model.runner = { _, _, _ in self.accepted() }
        model.start(boxed)
        dog.fire?()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.failure, .solver(RunFailure.stalledWithDesignBox))
    }

    /// Once a run shows any progress, the watchdog stands down — a slow-but-healthy
    /// run is never aborted, and a late watchdog fire is a no-op.
    func testWatchdogDisarmsOnFirstProgress() {
        let dog = ManualRunWatchdog()
        let model = RunModel(scheduler: SynchronousRunScheduler(), watchdog: dog)
        model.runner = { _, progress, _ in
            _ = progress(0, 2, 1)                        // first tick → disarm
            return self.accepted()
        }
        model.start(request())
        XCTAssertEqual(model.phase, .succeeded)
        XCTAssertTrue(dog.cancelled, "watchdog is stood down once the run shows progress")
        dog.fire?()                                      // a stale fire must do nothing
        XCTAssertEqual(model.phase, .succeeded)
    }

    /// The orphaned core computation from a watchdog-failed run may still return
    /// later; that stale result must not clobber a fresh run (token-identity guard).
    func testLateReturnFromAStalledRunIsDroppedForTheNewRun() {
        let sched = HeldRunScheduler()
        let dog = ManualRunWatchdog()
        let model = RunModel(scheduler: sched, watchdog: dog)

        model.runner = { _, _, _ in self.accepted(count: 3) }   // run 1's (late) result
        model.start(request())
        let run1Work = sched.held                               // capture run 1's held work
        dog.fire?()                                             // run 1 stalls → failed
        XCTAssertEqual(model.phase, .failed)
        model.dismissFailure()

        model.runner = { _, _, _ in self.accepted(count: 1) }   // run 2
        model.start(request())                                  // run 2 in flight (held)
        XCTAssertEqual(model.phase, .running)

        run1Work?()                                             // run 1 finally returns — stale

        XCTAssertEqual(model.phase, .running, "stale run-1 result must not resolve run 2")
        XCTAssertNil(model.outcome)
    }

    // MARK: - integration: the REAL bridge on the committed cube fixture

    func testRealMinimizePlasticRunReachesTerminalPhase() {
        // Drives the production GCD scheduler + the real minimize_plastic on the
        // committed cube fixture. Proves the runner is actually wired to the core
        // (a stub couldn't pass) and that progress callbacks marshal back onto
        // main. Tiny resolution keeps it fast — the bridge now runs the M6.3
        // projection schedule (300 OC iterations/variant), so res is kept small.
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

        model.start(request(resolution: 8))
        wait(for: [done], timeout: 180)

        XCTAssertFalse(model.phase.isRunning)
        XCTAssertNotEqual(model.phase, .idle)
        XCTAssertGreaterThan(progressTicks, 0, "expected at least one SIMP iteration callback")
    }

    // M7.diag: the production runs flip the solver to MultigridCG (bridge.cpp),
    // but the desktop Gate-V2 / minimize_plastic tests never set that solver — they
    // exercise the library-default JacobiCG. So the exact production solver path is
    // otherwise unexercised (the diagnosed on-device stall lives there). res 8 is
    // too small to build a multigrid hierarchy (it falls straight back to Jacobi),
    // so this drives a resolution that engages the MG coarsening at least once,
    // headlessly, and asserts it terminates and streams progress. A regression that
    // stalls the MG path at this scale trips the timeout instead of shipping to a
    // device. Kept modest so it stays a quick guard, not a long solve.
    func testProductionMultigridPathTerminatesAndReportsProgress() {
        let model = RunModel(scheduler: GCDRunScheduler())
        var progressTicks = 0
        var cancellables = Set<AnyCancellable>()
        let done = expectation(description: "MultigridCG run reaches a terminal phase")
        done.assertForOverFulfill = false

        model.$progress.compactMap { $0 }.sink { _ in progressTicks += 1 }.store(in: &cancellables)
        model.$phase.sink { phase in
            if phase == .succeeded || phase == .failed || phase == .cancelled { done.fulfill() }
        }.store(in: &cancellables)

        model.start(request(resolution: 16))
        wait(for: [done], timeout: 300)

        XCTAssertFalse(model.phase.isRunning, "production MultigridCG path must terminate, not hang")
        XCTAssertGreaterThan(progressTicks, 0, "expected at least one SIMP iteration callback")
    }
}

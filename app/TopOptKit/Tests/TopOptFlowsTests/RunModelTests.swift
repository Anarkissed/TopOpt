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

    // MARK: - honest progress readout math (run-progress-visibility)

    func testRungFractionIsDiscreteAndFlatWithinARung() {
        // Rung fraction steps at variant boundaries and makes NO within-rung claim:
        // more iterations in the same rung do not move it (unlike fractionComplete).
        let early = RunProgress(rung: 1, rungCount: 4, iteration: 5)
        let late  = RunProgress(rung: 1, rungCount: 4, iteration: 140)
        XCTAssertEqual(early.rungFractionComplete, 0.25, accuracy: 1e-12)
        XCTAssertEqual(late.rungFractionComplete, 0.25, accuracy: 1e-12)   // flat in-rung
        XCTAssertEqual(RunProgress(rung: 0, rungCount: 4, iteration: 99).rungFractionComplete,
                       0.0, accuracy: 1e-12)
        XCTAssertEqual(RunProgress(rung: 3, rungCount: 4, iteration: 1).rungFractionComplete,
                       0.75, accuracy: 1e-12)
    }

    func testRemainingEstimateNilUntilFirstRungCompletes() {
        // No completed rung => no measured rung rate => no honest estimate.
        let p = RunProgress(rung: 0, rungCount: 4, iteration: 60)
        XCTAssertNil(p.remainingEstimate(elapsed: 600, currentRungElapsed: 600))
        // Also nil with zero elapsed (nothing measured yet).
        XCTAssertNil(RunProgress(rung: 1, rungCount: 4, iteration: 1)
                        .remainingEstimate(elapsed: 0, currentRungElapsed: 0))
    }

    func testRemainingEstimateProjectsFromCompletedRungs() {
        // One rung done in 1200s; 4 rungs total; the current rung just started.
        // perRung = (1200 - 0)/1 = 1200; 2 not-started rungs + a full current rung
        // => ~1200*2 + 1200 = 3600s remaining.
        let p = RunProgress(rung: 1, rungCount: 4, iteration: 3)
        let eta = p.remainingEstimate(elapsed: 1200, currentRungElapsed: 0)
        XCTAssertNotNil(eta)
        XCTAssertEqual(eta!, 3600, accuracy: 1.0)
    }

    func testRemainingEstimateCountsDownWithinARung() {
        // Same rung position, current rung running longer => estimate must DECREASE
        // (never inflate while you wait — the maintainer's honesty constraint).
        let p = RunProgress(rung: 2, rungCount: 4, iteration: 50)
        let early = p.remainingEstimate(elapsed: 2400, currentRungElapsed: 100)!
        let later = p.remainingEstimate(elapsed: 2600, currentRungElapsed: 300)!
        XCTAssertLessThan(later, early)
    }

    func testRemainingEstimateNonNegativeWhenCurrentRungRunsLong() {
        // A current rung that overruns the average must not push the estimate below 0.
        let p = RunProgress(rung: 3, rungCount: 4, iteration: 190)  // last rung
        let eta = p.remainingEstimate(elapsed: 5000, currentRungElapsed: 4000)!
        XCTAssertGreaterThanOrEqual(eta, 0)
    }

    func testStartSetsStartedAtAndResetClearsIt() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        // The stub runs synchronously; capture startedAt from inside the run.
        var startedDuringRun: Date?
        model.runner = { _, _, _ in
            startedDuringRun = model.startedAt
            return self.accepted(count: 1)
        }
        XCTAssertNil(model.startedAt)
        model.start(request())
        XCTAssertNotNil(startedDuringRun, "startedAt is set for the duration of the run")
        model.reset()
        XCTAssertNil(model.startedAt, "reset clears the elapsed-clock anchor")
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

    /// Data-loss regression (state-corruption / data-loss handoff). A user who leaves
    /// an IN-FLIGHT run from the RESULTS screen must not lose the variants already
    /// streamed and shown. The results Back chevron used to `run.cancel()` before going
    /// Home; the core then returned a cancelled outcome and `finish` wiped the accepted
    /// variant the user had just been looking at (rung 0, "-32%, 587 g") — so on reopen
    /// the whole optimization was gone. A run that FINISHED before leaving survived only
    /// because `cancel()` no-ops off `.running`. Cancelling a run that has ALREADY
    /// produced accepted, shown results must KEEP them (they are usable output), exactly
    /// like a mid-run solver throw already does.
    func testStreamedAcceptedVariantSurvivesLeavingAnInFlightRun() {
        let streamed = OptimizeOutcome(
            variants: [variant(margin: 3, accepted: true)],
            stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
            gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1)
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, progress, onVariant in
            onVariant(streamed)                       // variant 1 lands → results visible
            XCTAssertEqual(model.outcome?.variants.count, 1)
            model.cancel()                            // user taps the results Back chevron
            let keepGoing = progress(0, 3, 2)         // the token flips this to false
            // the core returns a cancelled outcome cleanly when told to stop (M7.0a)
            return OptimizeOutcome(variants: [], stoppedOnMargin: false,
                                   cancelled: !keepGoing, acceptedCount: 0)
        }
        model.start(request())
        XCTAssertEqual(model.outcome?.variants.count, 1,
                       "a streamed, already-shown accepted variant must survive leaving the run")
        XCTAssertTrue(model.outcome?.variants.contains { $0.accepted } ?? false)
        XCTAssertEqual(model.phase, .succeeded, "usable accepted results resolve as a success")
        XCTAssertNil(model.failure, "keeping the variants is not a failure")
    }

    /// The clean-cancel case is unchanged: a run cancelled BEFORE any accepted variant
    /// streamed (the only time the progress card's Cancel button is even reachable —
    /// once a variant streams the card yields to the results screen) still discards to a
    /// clean workspace, never opening an empty results view.
    func testCancelBeforeAnyVariantStillDiscardsCleanly() {
        let model = RunModel(scheduler: SynchronousRunScheduler())
        model.runner = { _, progress, _ in
            _ = progress(0, 3, 1)
            model.cancel()
            let keepGoing = progress(0, 3, 2)
            return OptimizeOutcome(variants: [], stoppedOnMargin: false,
                                   cancelled: !keepGoing, acceptedCount: 0)
        }
        model.start(request())
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertNil(model.outcome, "nothing was shown — cancel returns a clean workspace")
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

    /// Handoff 121, requirement 5: a REMOTE run the app OBSERVED finishing fires a
    /// completion notification even in the foreground (a run on the Mac can finish
    /// while the user isn't watching / after a cold-launch re-attach). Signalled by
    /// the outcome's `computedRemotely` flag — no `runInBackground()` needed.
    func testForegroundRemoteCompletionNotifies() {
        let spy = NotifierSpy()
        let model = RunModel(scheduler: SynchronousRunScheduler(), notifier: spy)
        model.runner = { _, _, _ in
            OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: false,
                            acceptedCount: 2, computedRemotely: true)
        }
        model.start(request())
        XCTAssertEqual(spy.willCount, 0, "no background assertion for a foreground run")
        XCTAssertEqual(spy.completions, ["Cube: 2 variants ready"],
                       "an observed remote completion notifies")
    }

    /// A user-cancelled remote run does NOT notify — the user just cancelled it
    /// themselves, so a "cancelled" banner would be noise.
    func testCancelledRemoteRunDoesNotNotify() {
        let spy = NotifierSpy()
        let model = RunModel(scheduler: SynchronousRunScheduler(), notifier: spy)
        model.runner = { _, _, _ in
            OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: true,
                            acceptedCount: 0, computedRemotely: true)
        }
        model.start(request())
        XCTAssertTrue(spy.completions.isEmpty, "a cancelled remote run is not announced")
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
    /// `armCount` lets a test see a re-arm (Keep waiting).
    private final class ManualRunWatchdog: RunWatchdog {
        var graceSeconds: Double = 150
        var fire: (() -> Void)?
        private(set) var cancelled = false
        private(set) var armCount = 0
        func arm(_ onStall: @escaping () -> Void) -> RunWatchdogCancel {
            fire = onStall
            armCount += 1
            cancelled = false
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
        XCTAssertEqual(model.failure, .solver(RunFailure.stalledDuringSetup(graceSeconds: 150)))
        XCTAssertTrue(model.canKeepWaiting, "a stall offers Keep waiting (background not cancelled)")
        // The stall sheet NAMES the grace it actually waited (an honest guard).
        if case .solver(let msg)? = model.failure {
            XCTAssertTrue(msg.contains("2 minutes 30 seconds"), "the sheet names the 150s grace: \(msg)")
        } else { XCTFail("expected a solver failure") }
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
        XCTAssertEqual(model.failure, .solver(RunFailure.stalledWithDesignBox(graceSeconds: 150)))
    }

    /// Keep waiting (an honest guard admits its own timeout): the grace expired but the
    /// background solve was never cancelled, so the sheet's "Keep waiting" returns to
    /// running and RE-ARMS the guard against the same run. A later real progress tick
    /// then resolves it normally.
    func testKeepWaitingReArmsTheGuardAndResumes() {
        let dog = ManualRunWatchdog()
        let model = RunModel(scheduler: HeldRunScheduler(), watchdog: dog)
        model.runner = { _, _, _ in self.accepted() }   // held; never actually runs
        model.start(request())
        XCTAssertEqual(dog.armCount, 1)
        dog.fire?()                                      // grace 1 elapses
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.canKeepWaiting)

        model.keepWaiting()                             // "Keep waiting"
        XCTAssertEqual(model.phase, .running, "keep waiting returns to the running card")
        XCTAssertFalse(model.canKeepWaiting)
        XCTAssertNil(model.failure)
        XCTAssertEqual(dog.armCount, 2, "the guard is re-armed for another grace")
    }

    /// Close / Try Again on a stall ABANDONS the still-running background solve, so its
    /// token is cancelled (unlike Keep waiting).
    func testDismissingAStallCancelsTheBackgroundRun() {
        let sched = HeldRunScheduler()
        let dog = ManualRunWatchdog()
        let model = RunModel(scheduler: sched, watchdog: dog)
        var sawCancel = false
        model.runner = { _, progress, _ in
            sawCancel = !progress(0, 2, 1)   // the held work checks the token when it runs
            return self.accepted()
        }
        model.start(request())
        dog.fire?()                          // stall (token NOT cancelled yet)
        XCTAssertTrue(model.canKeepWaiting)
        model.dismissFailure()               // Close → abandon → cancel the token
        XCTAssertFalse(model.canKeepWaiting)
        sched.held?()                        // the orphaned work finally runs
        XCTAssertTrue(sawCancel, "the abandoned background run sees a cancelled token")
    }

    /// A REMOTE run does NOT arm the local setup-stall watchdog (handoff 129): its
    /// liveness is RemoteRun's (queue- + heartbeat-aware), so a queued or long-first-
    /// solve remote run can never trip this guard.
    func testRemoteRunDoesNotArmTheLocalWatchdog() {
        let dog = ManualRunWatchdog()
        let model = RunModel(scheduler: HeldRunScheduler(), watchdog: dog)
        model.runner = { _, _, _ in self.accepted() }
        model.start(request(), remote: true)
        XCTAssertEqual(dog.armCount, 0, "remote runs never arm the local watchdog")
        XCTAssertNil(dog.fire, "no stall timer exists to fire for a remote run")
        XCTAssertEqual(model.phase, .running)
    }

    /// A LOCAL run arms it as before (the on-device stall guard is intact).
    func testLocalRunArmsTheLocalWatchdog() {
        let dog = ManualRunWatchdog()
        let model = RunModel(scheduler: HeldRunScheduler(), watchdog: dog)
        model.runner = { _, _, _ in self.accepted() }
        model.start(request())                          // remote defaults to false
        XCTAssertEqual(dog.armCount, 1, "a local run arms the setup-stall watchdog")
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

    // MARK: - RunETAEstimator (handoff 111 — the honest per-iteration ETA)

    /// A steady sequence at a fixed rate: within the FIRST rung the estimate is an
    /// UPPER bound built on the iteration cap, and it labels itself `.upper`. At 10
    /// s/iter, iteration 10 of 4 rungs → (cap−10) + cap×3 ≈ 790 iters × 10 s ≈ 7900 s.
    private func steadyRung(rung: Int, count: Int, from t0: Double, iters: Int,
                            perIter: Double, startIter: Int = 1) -> [RunProgressSample] {
        (0..<iters).map { i in
            RunProgressSample(time: t0 + Double(i) * perIter, rung: rung, rungCount: count,
                              iteration: startIter + i)
        }
    }

    func testETAisUpperBoundBeforeFirstRungCompletes() {
        let samples = steadyRung(rung: 0, count: 4, from: 0, iters: 10, perIter: 10)
        let eta = RunETAEstimator.estimate(from: samples)
        let e = try! XCTUnwrap(eta)
        XCTAssertEqual(e.bound, .upper, "no rung has finished → the cap-based upper bound")
        XCTAssertEqual(e.secondsPerIteration, 10, accuracy: 0.01)
        // (200-10) remaining in rung 0 + 200×3 not-started = 790 iters × 10 s.
        XCTAssertEqual(e.secondsRemaining, 7900, accuracy: 50)
        XCTAssertEqual(e.asOf, 90, accuracy: 0.01, "computed at the last event's timestamp")
    }

    func testETAisNilDuringWarmup() {
        // Fewer than the warm-up number of per-iteration samples → no honest estimate.
        let samples = steadyRung(rung: 0, count: 4, from: 0, iters: 3, perIter: 10)
        XCTAssertNil(RunETAEstimator.estimate(from: samples))
    }

    func testETAswitchesToApproximateAfterARungCompletes() {
        // Rung 0 completes at 40 iterations, then rung 1 runs. Once a rung is banked
        // the estimate switches to the OBSERVED iterations-per-rung (40), labelled ~.
        var samples = steadyRung(rung: 0, count: 4, from: 0, iters: 40, perIter: 10)
        samples += steadyRung(rung: 1, count: 4, from: 400, iters: 6, perIter: 10)
        let e = try! XCTUnwrap(RunETAEstimator.estimate(from: samples))
        XCTAssertEqual(e.bound, .approximate, "a completed rung → observed-rate approximation")
        // observed perRung = 40; at rung 1 iter 6: (40-6) + 40×2 = 114 iters × 10 s.
        XCTAssertEqual(e.secondsRemaining, 1140, accuracy: 30)
    }

    func testETAtracksASlowerRung() {
        // Rung 0 at 10 s/iter, rung 1 genuinely 3× slower (30 s/iter): the EMA climbs,
        // so the per-iteration rate reported is well above the fast rung's.
        var samples = steadyRung(rung: 0, count: 3, from: 0, iters: 40, perIter: 10)
        samples += steadyRung(rung: 1, count: 3, from: 400, iters: 20, perIter: 30)
        let e = try! XCTUnwrap(RunETAEstimator.estimate(from: samples))
        XCTAssertGreaterThan(e.secondsPerIteration, 18, "a sustained slower rung pulls the rate up")
    }

    func testETAcountsDownAsARungProgresses() {
        // Deeper into the same rung → fewer remaining iterations → smaller estimate.
        let early = try! XCTUnwrap(RunETAEstimator.estimate(
            from: steadyRung(rung: 0, count: 4, from: 0, iters: 10, perIter: 10)))
        let later = try! XCTUnwrap(RunETAEstimator.estimate(
            from: steadyRung(rung: 0, count: 4, from: 0, iters: 60, perIter: 10)))
        XCTAssertLessThan(later.secondsRemaining, early.secondsRemaining)
    }

    func testETAsurvivesAReconnectGap() {
        // A fast rung, then a single event arriving after a huge silence (a reconnect):
        // the outlier is rejected for the rate, so the estimate stays sane rather than
        // exploding — derived from event timestamps, robust to one bad interval.
        var samples = steadyRung(rung: 0, count: 3, from: 0, iters: 20, perIter: 5)
        // Reconnect: 600 s later, only +2 iterations advanced in the (visible) stream.
        samples.append(RunProgressSample(time: 20 * 5 + 600, rung: 0, rungCount: 3, iteration: 22))
        // Then the stream resumes at the real rate.
        samples += steadyRung(rung: 0, count: 3, from: 20 * 5 + 605, iters: 5, perIter: 5, startIter: 23)
        let e = try! XCTUnwrap(RunETAEstimator.estimate(from: samples))
        XCTAssertEqual(e.secondsPerIteration, 5, accuracy: 2,
                       "the 300 s/iter reconnect spike is rejected, not folded into the rate")
    }

    func testETAplateauEarlyIsBoundedByTheUpperEstimate() {
        // The upper bound assumes the cap; a rung that plateaus EARLY (well under the
        // cap) must land under that bound — the ≤ label is honest.
        let e = try! XCTUnwrap(RunETAEstimator.estimate(
            from: steadyRung(rung: 0, count: 2, from: 0, iters: 30, perIter: 8)))
        // Upper bound at iter 30 of 2 rungs: (200-30) + 200 = 370 iters × 8 s = 2960 s.
        // The true cost if it plateaus at ~120 iters/rung would be far less — so the
        // bound is an over-estimate, as intended.
        XCTAssertEqual(e.bound, .upper)
        XCTAssertGreaterThan(e.secondsRemaining, 100 * 8, "the cap-based bound sits high on purpose")
    }
}

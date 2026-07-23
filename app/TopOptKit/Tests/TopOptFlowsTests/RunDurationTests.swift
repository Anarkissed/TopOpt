// RunDurationTests — handoff 134, item 1: the results/summary duration is a
// property of the RUN, never of when someone looked at it.
//
// The incident: a 40m53s remote solve, opened the next morning after the client had
// been force-quit and re-attached, reported "11 hours" — the app had no carried
// duration, so anything it could show was measured against `now()` or against the
// moment of re-attach. The worker's own menu read 40m53s the whole time, from
// `finished_at - started_at`.
//
// These tests pin the three places that number now travels through: the value type
// (`RunTiming`), the run flow that stamps it (`RunModel.finish` — local measured,
// remote CARRIED, never fabricated), and the persistence round-trip (a reopened
// result must not have to re-derive a duration, because by then the only clock
// available is `now()` again). The network half — a real worker's timestamps over
// HTTP after a re-attach — is the `reattach` case of the E2E harness.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RunDurationTests: XCTestCase {

    // MARK: - RunTiming: the value

    func testClockFormatsAcrossMagnitudes() {
        XCTAssertEqual(RunTiming.clock(0), "0s")
        XCTAssertEqual(RunTiming.clock(38), "38s")
        XCTAssertEqual(RunTiming.clock(60), "1m 0s")
        // The incident's real number: 40m53s, read the same way the worker reads it.
        XCTAssertEqual(RunTiming.clock(2453), "40m 53s")
        XCTAssertEqual(RunTiming.clock(3600), "1h 00m")
        XCTAssertEqual(RunTiming.clock(3864), "1h 04m")
    }

    func testSummaryNamesTheSolveAndOnlyARealQueueWait() {
        XCTAssertEqual(RunTiming(solveSeconds: 2453).summary, "solved 40m 53s")
        // A queue wait is reported SEPARATELY — it is time the user waited, but not
        // time the part was being solved, so neither number absorbs the other.
        XCTAssertEqual(RunTiming(queuedSeconds: 252, solveSeconds: 2453).summary,
                       "waited 4m 12s · solved 40m 53s")
        // A sub-second wait is not a wait worth a clause.
        XCTAssertEqual(RunTiming(queuedSeconds: 0.4, solveSeconds: 2453).summary,
                       "solved 40m 53s")
    }

    func testFromWorkerUsesFinishedMinusStarted() {
        // The worker's own record: created → (queue) → started → (solve) → finished.
        let t = try! XCTUnwrap(RunTiming.fromWorker(createdAt: 1_000, startedAt: 1_252,
                                                   finishedAt: 3_705))
        XCTAssertEqual(t.queuedSeconds, 252, accuracy: 1e-9)
        XCTAssertEqual(t.solveSeconds, 2453, accuracy: 1e-9)
        XCTAssertEqual(t.summary, "waited 4m 12s · solved 40m 53s")
    }

    func testFromWorkerWithoutAFinishHasNoDuration() {
        // A job still running has no truthful duration yet. Returning "now - started"
        // here is exactly the bug: it would grow every time the screen was opened.
        XCTAssertNil(RunTiming.fromWorker(createdAt: 1_000, startedAt: 1_252, finishedAt: nil))
        XCTAssertNil(RunTiming.fromWorker(createdAt: nil, startedAt: nil, finishedAt: nil))
    }

    func testFromWorkerWithoutAStartAttributesTheWholeSpanToTheSolve() {
        // A pre-121 worker records no promotion time. The honest reading is the full
        // created→finished span with NO queue claim we cannot support.
        let t = try! XCTUnwrap(RunTiming.fromWorker(createdAt: 1_000, startedAt: nil,
                                                    finishedAt: 3_453))
        XCTAssertEqual(t.queuedSeconds, 0)
        XCTAssertEqual(t.solveSeconds, 2453, accuracy: 1e-9)
    }

    func testNegativeSpansClampRatherThanRenderNonsense() {
        // A worker clock adjustment (or a garbled field) must not produce "solved -3s".
        let t = try! XCTUnwrap(RunTiming.fromWorker(createdAt: 2_000, startedAt: 1_000,
                                                    finishedAt: 900))
        XCTAssertEqual(t.queuedSeconds, 0)
        XCTAssertEqual(t.solveSeconds, 0)
    }

    // MARK: - RunModel: who is allowed to measure

    private func request() -> RunRequest {
        RunRequest(modelPath: "/x/part.stl", material: "PLA", materialsPath: "",
                   rulesPath: "", resolution: 24, projectName: "Bracket")
    }

    private func acceptedOutcome(timing: RunTiming? = nil) -> OptimizeOutcome {
        let v = OptimizeVariant(requestedVolumeFraction: 0.7, achievedVolumeFraction: 0.7,
                                massGrams: 10, supportVolumeVoxels: 0, meshTriangleCount: 12,
                                worstCaseMargin: 3, accepted: true, v3Passes: true)
        return OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                               acceptedCount: 1, computedRemotely: timing != nil,
                               timing: timing)
    }

    /// A LOCAL run is measured by this process — it IS the thing solving — so the
    /// duration is start→finish on the app's own clock (driven here, not slept).
    func testLocalRunStampsItsMeasuredDuration() {
        var t = Date(timeIntervalSinceReferenceDate: 0)
        let model = RunModel(scheduler: SynchronousRunScheduler(), clock: { t })
        model.runner = { _, _, _ in
            t = t.addingTimeInterval(2453)      // the solve takes 40m53s
            return self.acceptedOutcome()
        }
        model.start(request())
        XCTAssertEqual(model.outcome?.timing?.solveSeconds ?? 0, 2453, accuracy: 1e-6)
        XCTAssertEqual(model.outcome?.timing?.summary, "solved 40m 53s")
    }

    /// A REMOTE run's duration is the WORKER's, carried on the outcome — the client's
    /// own clock is not a fallback for it under any circumstance.
    func testRemoteRunCarriesTheWorkersDurationUnchanged() {
        var t = Date(timeIntervalSinceReferenceDate: 0)
        let model = RunModel(scheduler: SynchronousRunScheduler(), clock: { t })
        let carried = RunTiming(queuedSeconds: 252, solveSeconds: 2453)
        model.runner = { _, _, _ in
            t = t.addingTimeInterval(3)         // the client only watched for 3s
            return self.acceptedOutcome(timing: carried)
        }
        model.start(request(), remote: true)
        XCTAssertEqual(model.outcome?.timing, carried,
                       "the worker's record wins over anything the client measured")
        XCTAssertEqual(model.outcome?.timing?.summary, "waited 4m 12s · solved 40m 53s")
    }

    /// The re-attach shape: a remote run whose worker record could NOT be read gets
    /// NO duration — not the seconds the client happened to be attached. This is the
    /// assertion that forbids the "11 hours" (and its mirror, a bogus "3s" for a
    /// 40-minute solve someone re-attached to at the end).
    func testRemoteRunWithoutAWorkerRecordShowsNoDurationAtAll() {
        var t = Date(timeIntervalSinceReferenceDate: 0)
        let model = RunModel(scheduler: SynchronousRunScheduler(), clock: { t })
        model.runner = { _, _, _ in
            t = t.addingTimeInterval(11 * 3600) // an overnight gap between attach + finish
            return self.acceptedOutcome(timing: nil)
        }
        model.start(request(), remote: true)
        XCTAssertNotNil(model.outcome, "the run still succeeds")
        XCTAssertNil(model.outcome?.timing,
                     "no worker record → no duration; the client's clock is never used")
    }

    // MARK: - the in-flight clock on a re-attach

    /// The other half of the same lie: a run 10 hours into its solve, re-attached
    /// this minute, must not read "0:00 elapsed". The clock anchors to when the run
    /// began (the persisted submit time), so it describes the RUN, not the viewer.
    func testReattachAnchorsTheElapsedClockToWhenTheRunBegan() {
        let model = RunModel(scheduler: HeldScheduler())
        model.runner = { _, _, _ in self.acceptedOutcome() }
        model.start(request(), remote: true)
        let began = Date().addingTimeInterval(-10 * 3600)
        model.anchorElapsed(to: began)
        XCTAssertEqual(model.startedAt?.timeIntervalSince1970 ?? 0,
                       began.timeIntervalSince1970, accuracy: 0.5)
    }

    func testAnchorRejectsAFutureStart() {
        let model = RunModel(scheduler: HeldScheduler())
        model.runner = { _, _, _ in self.acceptedOutcome() }
        model.start(request(), remote: true)
        let anchored = model.startedAt
        model.anchorElapsed(to: Date().addingTimeInterval(3600))  // clock skew
        XCTAssertEqual(model.startedAt, anchored, "a future start is never adopted")
    }

    /// A scheduler that never runs the work, so the run stays `.running` for the
    /// duration of the test (the elapsed clock only exists while a run is in flight).
    private final class HeldScheduler: RunScheduler {
        func runInBackground(_ work: @escaping () -> Void) {}
        func runOnMain(_ work: @escaping () -> Void) { work() }
    }

    // MARK: - persistence: the duration survives a reopen

    func testDurationSurvivesThePersistRoundTrip() throws {
        let o = acceptedOutcome(timing: RunTiming(queuedSeconds: 252, solveSeconds: 2453))
        let restored = try OutcomeCodec.decode(OutcomeCodec.encode(OutcomeCodec.dto(from: o)))
        XCTAssertEqual(restored.timing, o.timing,
                       "a reopened result keeps the run's duration — it cannot re-derive one")
        XCTAssertEqual(restored.timing?.summary, "waited 4m 12s · solved 40m 53s")
    }

    func testPre134BlobDecodesWithNoDuration() throws {
        // A result written before this handoff simply has no recorded duration. The
        // honest restoration is nil (the summary then shows none), never a zero.
        let o = acceptedOutcome(timing: nil)
        let restored = try OutcomeCodec.decode(OutcomeCodec.encode(OutcomeCodec.dto(from: o)))
        XCTAssertNil(restored.timing)
    }

    // MARK: - the summary line the screen renders

    func testResultsModelShowsTheRecordedDuration() {
        let m = ResultsModel(projectName: "Bracket",
                             outcome: acceptedOutcome(timing: RunTiming(solveSeconds: 2453)))
        XCTAssertEqual(m.runDurationLabel, "solved 40m 53s")
    }

    func testResultsModelShowsNoDurationWhenTheRunRecordedNone() {
        let m = ResultsModel(projectName: "Bracket", outcome: acceptedOutcome(timing: nil))
        XCTAssertNil(m.runDurationLabel, "no duration is better than an invented one")
    }

    /// A streamed partial landing after the authoritative outcome must not erase the
    /// recorded duration (`apply` runs for every update, and partials carry none).
    func testAStreamedPartialDoesNotEraseTheDuration() {
        let m = ResultsModel(projectName: "Bracket",
                             outcome: acceptedOutcome(timing: RunTiming(solveSeconds: 2453)))
        m.update(from: acceptedOutcome(timing: nil))
        XCTAssertEqual(m.runDurationLabel, "solved 40m 53s")
    }
}

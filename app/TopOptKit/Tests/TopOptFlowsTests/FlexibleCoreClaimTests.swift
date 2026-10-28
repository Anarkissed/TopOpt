// FlexibleCoreClaimTests — never two solves in core's matrix-free pool, as ONE claim (task
// 2026-09-29-flexible-screens, round 5 batch G verification: the gate was checked in pump() and the
// sim entered core a main-actor hop later; the Stress model's PHASE, which Cancel drops while its
// solve runs on, was the only other gate; a topology run waited 60 s at most, then entered anyway).
// Each with its RED control:
//   * a sim claims core in the step that commits it — RED: the late claim;
//   * a cancelled Stress solve still in core keeps the sims out — RED: the late claim;
//   * a LOCAL run claims core, waits while a sim holds it (its stall watchdog re-armed after the
//     wait), and no sim starts while it holds core; a remote run claims nothing — RED: no run claim.
#if canImport(MetalKit)
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleCoreClaimTests: XCTestCase {

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }

    /// A solve waiting for a sim to leave goes BEFORE the next queued sim (a run or a Stress solve is
    /// never starved by a queue of sims). POSITIVE CONTROL: with nothing waiting, a sim claims at once.
    func testAWaitingSolveGoesBeforeTheQueuedSims() async throws {
        let gate = FlexibleCoreGate.shared
        XCTAssertTrue(gate.tryEnterSim(), "control: nothing waits — a sim claims core")
        let entered = Box(false)
        DispatchQueue.global().async {
            gate.enterOther()
            entered.value = true
            usleep(300_000)
            gate.leaveOther()
        }
        try await FlexibleBatchCVerifyTests.settle(5) { gate.othersWaitingCount == 1 }
        let queued = gate.tryEnterSim()
        gate.leaveSim()
        try await FlexibleBatchCVerifyTests.settle(5) { entered.value }
        let during = gate.tryEnterSim()
        try await FlexibleBatchCVerifyTests.settle(5) { gate.othersInCore == 0 }
        let after = gate.tryEnterSim()
        if after { gate.leaveSim() }
        print("FLEX-GV WAITING SOLVE FIRST: a queued sim while it waits \(queued) · while it runs \(during) · after \(after)")
        XCTAssertFalse(queued, "the next sim waits behind the solve that waits")
        XCTAssertFalse(during)
        XCTAssertTrue(after)
    }

    /// A Stress solve that stays in core `seconds` and records whether a squish sim holds core meanwhile.
    static func slowStress(_ seconds: Double, _ overlap: Box<Bool>) -> LatticeSimModel {
        LatticeSimModel(runner: { _ in
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if FlexibleSquishSolver.solving { overlap.value = true }; usleep(2000) }
            return TopOptKit.SimAnalysisResult(accepted: true, nonConvergent: false, maxStressMPa: 1, marginWorstCase: 2, marginRequired: 1.5,
                                               maxDisplacementMM: 0.1, vonMisesField: [1, 1, 1, 1, 1, 1, 1, 1], gridNX: 2, gridNY: 2, gridNZ: 2,
                                               gridOrigin: .zero, spacingMM: 1)
        })
    }

    func testASimClaimsCoreInTheStepThatCommitsIt() async throws {
        for late in [false, true] {
            let m = try await FlexibleSquishFixture.pad(self, solve: false)
            let r = try XCTUnwrap(m.lastFERequest)
            let ref = await m.squishWorker.sceneRef()
            let scene = try XCTUnwrap(ref)
            let overlap = Box(false)
            let sim = Self.slowStress(4, overlap)
            let stress = FlexibleStressSolver(sim: sim, context: { FlexibleBatchCVerifyTests.context() })
            m.squishSolver.busy = { stress.busy() }
            // ★ RED CONTROL = batch G: the sim counted only once it runs, the Stress solve unclaimed
            m.squishSolver.controlLateClaim = late
            FlexibleCoreGate.shared.controlOthersDoNotClaim = late
            defer { FlexibleCoreGate.shared.controlOthersDoNotClaim = false }
            m.squishSolver.schedule(r, scene: scene, first: nil)
            let claimed = FlexibleSquishSolver.solving
            // his Stress tap handled before the sim's task ran — and the Stress model run straight, as
            // any other caller would: its runner must wait for the sim
            let outcome = stress.start()
            if outcome == .waiting { sim.run(FlexibleBatchCVerifyTests.context()) }
            await m.squishSolver.waitForIdle()
            try await FlexibleBatchCVerifyTests.settle(40) { sim.phase != .running }
            print("FLEX-GV CLAIM\(late ? " control (late)" : ""): claimed at commit \(claimed) · Stress start → \(outcome) · a sim in core beside the Stress solve: \(overlap.value)")
            if late {
                XCTAssertTrue(overlap.value, "control: the late claim let a sim into core beside the Stress solve")
            } else {
                XCTAssertTrue(claimed, "the sim holds core from the step that commits it")
                XCTAssertEqual(outcome, .waiting)
                XCTAssertFalse(overlap.value, "never two solves in core")
            }
            m.squishSolver.controlLateClaim = false
        }
    }

    func testACancelledStressSolveStillInCoreKeepsTheSimsOut() async throws {
        for late in [false, true] {
            let m = try await FlexibleSquishFixture.pad(self, solve: false)
            let r = try XCTUnwrap(m.lastFERequest)
            let ref = await m.squishWorker.sceneRef()
            let scene = try XCTUnwrap(ref)
            let overlap = Box(false)
            let sim = Self.slowStress(6, overlap)
            let stress = FlexibleStressSolver(sim: sim, context: { FlexibleBatchCVerifyTests.context() })
            XCTAssertEqual(stress.start(), .started)
            try await FlexibleBatchCVerifyTests.settle(5) { FlexibleCoreGate.shared.othersInCore > 0 }
            sim.cancel()   // the octet page's banner: the phase drops, the bridge solve runs on
            m.squishSolver.busy = { stress.busy() }
            m.squishSolver.controlLateClaim = late
            let busy = stress.busy()
            m.squishSolver.schedule(r, scene: scene, first: nil)
            await m.squishSolver.waitForIdle(timeoutS: 60)
            try await FlexibleBatchCVerifyTests.settle(20) { FlexibleCoreGate.shared.othersInCore == 0 }
            print("FLEX-GV CANCELLED\(late ? " control (late)" : ""): phase \(sim.phase) busy \(busy) · a sim entered core beside the cancelled solve: \(overlap.value) · solves \(m.squishSolver.solveCount)")
            XCTAssertFalse(busy, "(the phase says idle)")
            XCTAssertEqual(m.squishSolver.solveCount, 1, "the sim ran — after the cancelled solve left core")
            if late { XCTAssertTrue(overlap.value, "control: the phase gate let it in") } else { XCTAssertFalse(overlap.value) }
            m.squishSolver.controlLateClaim = false
        }
    }

    final class WatchdogSpy: RunWatchdog, @unchecked Sendable {
        let arms = Box(0)
        var graceSeconds: Double { 150 }
        func arm(_ onStall: @escaping () -> Void) -> RunWatchdogCancel { arms.value += 1; return {} }
    }
    struct Stop: Error {}

    static var request: RunRequest {
        RunRequest(modelPath: "/tmp/none.stl", material: "PLA", materialsPath: "", rulesPath: "", resolution: 8, projectName: "P")
    }

    func testALocalRunClaimsCoreAndARemoteRunDoesNot() async throws {
        let gate = FlexibleCoreGate.shared
        func run(remote: Bool) -> (RunModel, Box<Bool>, Box<Bool>, WatchdogSpy) {
            let started = Box(false), overlap = Box(false), spy = WatchdogSpy()
            let model = RunModel(scheduler: GCDRunScheduler(), watchdog: spy, runner: { _, _, _ in
                if FlexibleSquishSolver.solving { overlap.value = true }
                started.value = true
                throw Stop()
            })
            model.start(Self.request, remote: remote)
            return (model, started, overlap, spy)
        }
        // a sim holds core: a LOCAL run waits, and its stall watchdog is re-armed after the wait
        gate.increment()
        let (m1, started, overlap, spy) = run(remote: false)
        try await Task.sleep(nanoseconds: 500_000_000)
        let waited = !started.value
        gate.decrement()
        try await FlexibleBatchCVerifyTests.settle(10) { started.value && spy.arms.value == 2 }
        // a REMOTE run never touches the local pool: it does not wait
        gate.increment()
        let (m2, startedR, _, spyR) = run(remote: true)
        try await FlexibleBatchCVerifyTests.settle(5) { startedR.value }
        gate.decrement()
        print("FLEX-GV RUN: local waited for the sim \(waited) · then ran (overlap \(overlap.value)) · watchdog armed \(spy.arms.value)× · remote ran beside it \(startedR.value) (watchdog \(spyR.arms.value)×)")
        XCTAssertTrue(waited, "a local run waits while a sim holds core")
        XCTAssertFalse(overlap.value)
        XCTAssertEqual(spy.arms.value, 2, "the watchdog's grace starts after the wait")
        XCTAssertTrue(startedR.value, "a remote run does not claim the local pool")
        XCTAssertEqual(spyR.arms.value, 0, "(remote arms no local watchdog)")
        _ = (m1, m2)
        // …and while a run holds core, no sim starts
        let pad = try await FlexibleSquishFixture.pad(self, solve: false)
        let r = try XCTUnwrap(pad.lastFERequest)
        let ref = await pad.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        for late in [false, true] {
            pad.latticeLanded(r)
            pad.squishSolver.controlLateClaim = late
            let claim = FlexibleCoreGate.claimForRun()
            let before = pad.squishSolver.solveCount
            pad.squishSolver.schedule(r, scene: scene, first: nil)
            try await Task.sleep(nanoseconds: 800_000_000)
            let during = pad.squishSolver.solveCount - before
            claim.leave()
            await pad.squishSolver.waitForIdle()
            print("FLEX-GV RUN HOLDS CORE\(late ? " control (late)" : ""): sims started while the run held core \(during)")
            if late { XCTAssertEqual(during, 1, "control: the late claim starts a sim beside the run") } else { XCTAssertEqual(during, 0) }
            pad.squishSolver.controlLateClaim = false
        }
        // ★ RED CONTROL: no run claim — the local run starts at once beside the sim
        gate.controlOthersDoNotClaim = true
        defer { gate.controlOthersDoNotClaim = false }
        gate.increment()
        let (m3, startedC, overlapC, _) = run(remote: false)
        try await FlexibleBatchCVerifyTests.settle(5) { startedC.value }
        gate.decrement()
        print("FLEX-GV RUN control (no claim): ran beside the sim \(overlapC.value)")
        XCTAssertTrue(overlapC.value, "control: without the claim the run enters core beside the sim")
        _ = m3
    }
}
#endif

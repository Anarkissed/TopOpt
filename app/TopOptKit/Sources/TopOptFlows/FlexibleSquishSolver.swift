// FlexibleSquishSolver — the squish sims' queue (task 2026-09-29-flexible-screens, round 5
// batch G, §4).
//
// ★ ONE SOLVE AT A TIME, OFF THE COOPERATIVE POOL. A sim is a multi-second blocking C++ call:
// it runs on a SERIAL DispatchQueue at utility QoS (never a Swift-concurrency thread) and comes
// back through `withCheckedContinuation`. The bridge holds a mutex too, and runs core's
// matrix-free apply with ONE thread (the pool is process-global).
// ★ THE SHOWN SIM FIRST, THEN THE OTHERS IN GROUP ORDER; a pick promotes a pending sim. A new
// lattice generation drops every pending sim of the old one; a solve already running finishes
// and its result is dropped (the model keys its cache by generation).
// ★ NEVER BESIDE ANOTHER CORE SOLVE — ONE CLAIM, TAKEN ATOMICALLY (batch G verification). A sim
// CLAIMS core on the main actor, in the same step that commits it (`FlexibleCoreGate.tryEnterSim`),
// and only when no other solve holds core; the Stress / octet solve (LatticeSimModel's runner) and
// a local topology run (RunModel's background closure) hold core for as long as THEY are in it — a
// cancelled Stress solve included — and wait while a sim holds it. The phase checks (`busy()`: the
// Stress view's solve or a topology run — FlexibleStressSolver.busy) stay as a second gate; the
// Stress solve's start() still says "waiting" while a sim holds core (`FlexibleSquishSolver.solving`).
// Before this, the gate was checked in pump() and the sim entered core one main-actor hop later,
// and `busy()` read the Stress model's PHASE, which Cancel drops while its solve keeps running —
// the verifier put a sim inside core beside a running Stress solve both ways.

import Foundation
import TopOptKit

/// A sim's state in the model's cache.
public enum FlexibleSquishState: Equatable, Sendable {
    case pending
    case ready(FlexibleFEField)
    case failed(String)

    public var field: FlexibleFEField? { if case .ready(let f) = self { return f }; return nil }
    public var failure: String? { if case .failed(let w) = self { return w }; return nil }
}

@MainActor
public final class FlexibleSquishSolver {

    /// Process-wide: a sim holds core right now (claimed, queued on the bridge or solving — the
    /// Stress solve waits on it).
    nonisolated public static var solving: Bool { inFlight.value > 0 }
    /// Posted on the main queue when the last sim in core (of ANY model) comes out — a Stress solve
    /// that waited starts then, whichever model's sim it waited for (another project's included).
    public static let idleNotification = Notification.Name("FlexibleSquishSolver.idle")
    /// The process-wide claim on core (the sims' count is its `value`).
    nonisolated static var inFlight: FlexibleCoreGate { FlexibleCoreGate.shared }
    /// The most sims ever inside core at once (tests: must stay 1).
    nonisolated static var maxObservedConcurrency: Int { inFlight.maximum }

    /// Another core solve is running: no sim starts (polled every `busyRetryS`).
    var busy: () -> Bool = { false }
    static let busyRetryS = 0.25
    /// One per finished sim, on the main actor: (generation, sim id, state).
    var onResult: (Int, String, FlexibleSquishState) -> Void = { _, _, _ in }
    /// The queue ran dry (the Stress solve it held back may start).
    var onIdle: () -> Void = {}

    private let queue = DispatchQueue(label: "app.topopt.flexible.fe", qos: .utility)
    private var request: FlexibleFERequest?
    private var scene: FlexibleScene?
    private var order: [String] = []
    private var running: [String] = []
    private var retrying = false
    private(set) var solveCount = 0

    // test controls (the app never sets them)
    /// How many sims may be in flight at once (the rule is ONE; a red control sets 2).
    var controlConcurrency = 1
    /// The bridge's control bits and the sim's deadline (a 1 ms deadline forces a failure).
    var controlBits = 0
    var controlDeadlineMS: Double?
    /// These sims run with a 1 ms deadline (they fail; the others solve).
    var controlFailSimIDs: Set<String> = []
    /// RED CONTROL of the one claim: the pre-verification gate — `busy()` checked in pump(), the sim
    /// counted only once it runs on the queue, whatever else holds core.
    var controlLateClaim = false
    /// The failing sims (controlFailSimIDs) wait this long on the queue first (a failure that lands
    /// after the page saw them pending, deterministically).
    var controlFailDelayS = 0.0

    public init() {}

    /// The generation being solved (nil: nothing scheduled).
    var generation: Int? { request?.generation }
    /// Pending sim ids, in the order they will run.
    var pending: [String] { order }
    var isIdle: Bool { running.isEmpty && (order.isEmpty || request == nil) }

    /// Solve every sim of `r` on `scene` — `first` (the shown sim) before the others.
    func schedule(_ r: FlexibleFERequest, scene: FlexibleScene, first: String?) {
        request = r
        self.scene = scene
        order = r.sims.map(\.id)
        if let first { promote(first) }
        pump()
    }

    /// A pick of a sim still pending: it runs next.
    func promote(_ id: String) {
        guard let i = order.firstIndex(of: id), i > 0 else { return }
        order.remove(at: i)
        order.insert(id, at: 0)
    }

    /// A new lattice (or none): drop what has not started; a running solve's result will be
    /// dropped by its generation.
    func cancel() {
        order = []
        request = nil
        scene = nil
        finishIfIdle()
    }

    /// Returns once nothing is queued or running (tests' teardown: no bridge call outlives them).
    func waitForIdle(timeoutS: Double = 180) async {
        if isIdle { return }
        let start = Date()
        while !isIdle, Date().timeIntervalSince(start) < timeoutS {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func pump() {
        guard let r = request, let scene else { finishIfIdle(); return }
        while running.count < max(1, controlConcurrency), let id = order.first {
            // ★ the claim is taken HERE, on the main actor, in the step that commits the sim
            let late = controlLateClaim
            if busy() || !(late || Self.inFlight.tryEnterSim()) {
                guard !retrying else { return }
                retrying = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.busyRetryS * 1e9))
                    self?.retrying = false
                    self?.pump()
                }
                return
            }
            order.removeFirst()
            guard let sim = r.sims.first(where: { $0.id == id }) else {
                if !late, Self.inFlight.leaveSim() { Self.postIdle() }
                continue
            }
            running.append(id)
            solveCount += 1
            let bits = controlBits
            // a forced failure: a 1 ns budget (the deadline starts once the sim holds the solver, so
            // 1 ms is enough for a solve that converges before core's first poll)
            let deadline = controlFailSimIDs.contains(id) ? 1e-6 : (controlDeadlineMS ?? FlexibleFE.deadlineMS)
            let delay = controlFailSimIDs.contains(id) ? controlFailDelayS : 0
            // (the rule is the SERIAL queue; the red control's concurrency needs a concurrent one)
            let q = controlConcurrency > 1 ? DispatchQueue.global(qos: .utility) : queue
            Task { @MainActor [weak self] in
                let result: Result<FlexibleFEField, FlexibleSquishFailure> = await withCheckedContinuation { cont in
                    q.async {
                        if late { Self.inFlight.increment() }   // (the red control: counted only now)
                        if delay > 0 { usleep(useconds_t(delay * 1e6)) }
                        let out = FlexibleFERequest.solve(sim, of: r, on: scene, control: bits, deadlineMS: deadline)
                        if Self.inFlight.leaveSim() { Self.postIdle() }
                        cont.resume(returning: out)
                    }
                }
                self?.finished(r.generation, id, result)
            }
        }
        finishIfIdle()
    }

    private func finished(_ generation: Int, _ id: String, _ result: Result<FlexibleFEField, FlexibleSquishFailure>) {
        if let i = running.firstIndex(of: id) { running.remove(at: i) }
        switch result {
        case .success(let f): onResult(generation, id, .ready(f))
        case .failure(let e): onResult(generation, id, .failed(e.why))
        }
        if request?.generation == generation, order.isEmpty, running.isEmpty {
            // ★ the per-voxel arrays (~12 B per scene voxel + 4 per sim) are released after the last solve
            request = nil
            self.scene = nil
        }
        pump()
    }

    nonisolated private static func postIdle() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: idleNotification, object: nil) }
    }

    private func finishIfIdle() {
        guard isIdle else { return }
        if request != nil, order.isEmpty { request = nil; scene = nil }
        onIdle()
    }
}

/// ★ THE ONE CLAIM ON CORE'S MATRIX-FREE POOL (batch G verification). Core's ApplyPool is
/// process-global and not safe for two solves at once — two solves in it DEADLOCK (measured: a sim
/// and a direct load-case solve, both waiting on the pool's condition variable for ever). Every
/// solve that enters it from the app claims it here, under ONE lock:
///   * a squish sim with `tryEnterSim` (on the main actor, never blocking — refused while another
///     solve holds core; FlexibleSquishSolver retries), released when its bridge call returns;
///   * the Stress / octet solve (LatticeSimModel's runner — `whileInCore`) and a LOCAL topology run
///     (RunModel's background closure — `claimForRun`) with `enterOther`, which WAITS while a sim
///     holds core, and is released when that solve returns (a cancelled Stress solve keeps it until
///     its bridge call really ends). Remote runs never touch the local pool and never claim.
/// Other solves do not exclude each other here (their own rules stand); core brief #18: a
/// thread-safe pool.
public final class FlexibleCoreGate: @unchecked Sendable {
    static let shared = FlexibleCoreGate()
    private let cond = NSCondition()
    private var sims = 0, peak = 0, others = 0, othersWaiting = 0

    /// Sims holding core now.
    var value: Int { cond.lock(); defer { cond.unlock() }; return sims }
    /// Other solves (Stress, octet, a local run) holding core now.
    var othersInCore: Int { cond.lock(); defer { cond.unlock() }; return others }
    /// Other solves waiting for the sims to leave (they go before the next queued sim).
    var othersWaitingCount: Int { cond.lock(); defer { cond.unlock() }; return othersWaiting }
    /// The most sims ever in core at once.
    var maximum: Int { cond.lock(); defer { cond.unlock() }; return peak }
    func resetPeak() { cond.lock(); peak = sims; cond.unlock() }

    /// A sim claims core — only when no other solve holds it or waits for it (the other goes next:
    /// a run or a Stress solve is never starved by the queue of sims). Never blocks.
    func tryEnterSim() -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard others == 0, othersWaiting == 0 else { return false }
        sims += 1
        peak = max(peak, sims)
        return true
    }
    /// A sim leaves core; true when it was the last.
    @discardableResult
    func leaveSim() -> Bool {
        cond.lock(); defer { cond.unlock() }
        sims = max(0, sims - 1)
        cond.broadcast()
        return sims == 0
    }
    /// Another solve claims core: waits while a sim holds it (a sim is bounded by its deadline and
    /// its work budget). Returns the seconds it waited.
    @discardableResult
    func enterOther() -> Double {
        let t0 = Date()
        cond.lock(); defer { cond.unlock() }
        othersWaiting += 1
        while sims > 0 { cond.wait() }
        othersWaiting -= 1
        others += 1
        return Date().timeIntervalSince(t0)
    }
    func leaveOther() {
        cond.lock(); defer { cond.unlock() }
        others = max(0, others - 1)
        cond.broadcast()
    }
    // tests: count a sim in core without the gate (a sim of another model, the red controls)
    func increment() { cond.lock(); sims += 1; peak = max(peak, sims); cond.unlock() }
    func decrement() { _ = leaveSim() }

    /// ★ LatticeSimModel's runner (the Stress view's solve, the octet's) inside core — its ONE hook.
    public static func whileInCore<T>(_ body: () throws -> T) rethrows -> T {
        if shared.controlOthersDoNotClaim { return try body() }   // (the red control: batch G)
        shared.enterOther()
        defer { shared.leaveOther() }
        return try body()
    }

    /// ★ A LOCAL topology run's claim (RunModel's hook): taken on its background thread before it
    /// enters core, released when its closure ends. `waitedS`: how long a sim held it off (the
    /// run's stall watchdog is re-armed after a wait, so the wait never eats its grace).
    public final class RunClaim: @unchecked Sendable {
        public let waitedS: Double
        private var held: Bool
        private let lock = NSLock()
        init(waitedS: Double, held: Bool = true) { self.waitedS = waitedS; self.held = held }
        public func leave() {
            lock.lock(); defer { lock.unlock() }
            guard held else { return }
            held = false
            FlexibleCoreGate.shared.leaveOther()
        }
    }
    public static func claimForRun() -> RunClaim {
        if shared.controlOthersDoNotClaim { return RunClaim(waitedS: 0, held: false) }
        return RunClaim(waitedS: shared.enterOther())
    }
    /// RED CONTROL (tests only): the other solves take no claim — batch G, where only the PHASE /
    /// runningIDs gated the sims and a run waited at most 60 s.
    var controlOthersDoNotClaim: Bool {
        get { cond.lock(); defer { cond.unlock() }; return othersDoNotClaim }
        set { cond.lock(); othersDoNotClaim = newValue; cond.unlock() }
    }
    private var othersDoNotClaim = false
}

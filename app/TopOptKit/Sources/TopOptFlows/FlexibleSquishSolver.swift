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
// ★ NEVER BESIDE ANOTHER CORE SOLVE. No sim STARTS while `busy()` (the Stress view's solve or a
// topology run — FlexibleStressSolver.busy); the Stress solve's start() waits while a sim runs
// (`FlexibleSquishSolver.solving`).

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

    /// Process-wide: a sim is inside core right now (the Stress solve waits on it).
    nonisolated public static var solving: Bool { inFlight.value > 0 }
    nonisolated static let inFlight = AtomicCount()
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
            if busy() {
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
            guard let sim = r.sims.first(where: { $0.id == id }) else { continue }
            running.append(id)
            solveCount += 1
            let bits = controlBits, deadline = controlDeadlineMS ?? FlexibleFE.deadlineMS
            // (the rule is the SERIAL queue; the red control's concurrency needs a concurrent one)
            let q = controlConcurrency > 1 ? DispatchQueue.global(qos: .utility) : queue
            Task { @MainActor [weak self] in
                let result: Result<FlexibleFEField, FlexibleSquishFailure> = await withCheckedContinuation { cont in
                    q.async {
                        Self.inFlight.increment()
                        let out = FlexibleFERequest.solve(sim, of: r, on: scene, control: bits, deadlineMS: deadline)
                        Self.inFlight.decrement()
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

    private func finishIfIdle() {
        guard isIdle else { return }
        if request != nil, order.isEmpty { request = nil; scene = nil }
        onIdle()
    }
}

/// A thread-safe in-flight counter with its high-water mark.
final class AtomicCount: @unchecked Sendable {
    private var n = 0, peak = 0
    private let lock = NSLock()
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func increment() { lock.lock(); n += 1; peak = max(peak, n); lock.unlock() }
    func decrement() { lock.lock(); n -= 1; lock.unlock() }
    func resetPeak() { lock.lock(); peak = n; lock.unlock() }
}

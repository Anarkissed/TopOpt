// RunModel.swift — the M7.7 "run screen" state machine.
//
// Tapping Optimize hands the declared job to the core's minimize_plastic
// (ROADMAP M5.3) on a BACKGROUND queue, drives the progress bar from the M7.0a
// per-iteration callback, supports Cancel and "Run in Background" (a completion
// notification), and classifies the two failure modes the design renders as
// sheets — CG non-convergence (the core throws) and all-rungs-rejected — instead
// of alerts.
//
// The M7 /app/ verification standard is `xcodebuild test` on this package: all of
// the run LOGIC lives here (pure `RunProgress` math + `RunFailure` classification
// + the phase transitions) and is exercised headlessly through injected seams (a
// synchronous scheduler, a stub runner, a notifier spy). The SwiftUI RunScreen
// over this model, plus the real BGProcessingTask registration in the app target,
// are maintainer device QA — they carry no logic this file doesn't already test.

import Foundation
import TopOptKit
#if canImport(os)
import os
#endif

/// A fully-specified minimize_plastic run — the inputs `TopOptKit.minimizePlastic`
/// needs, gathered from the workspace (imported file, chosen material, resolution).
public struct RunRequest: Equatable, Sendable {
    /// The STL/STEP path the core reads.
    public let modelPath: String
    public let material: String
    public let materialsPath: String
    public let rulesPath: String
    public let resolution: Int
    /// The project title, used in the completion-notification copy.
    public let projectName: String
    /// The user's declared load case (empty for a self-weight / STL run): anchor
    /// B-rep faces + load groups (faces + model-frame force). Consumed only on the
    /// STEP path (`minimizePlasticLoadCase`).
    public let anchorFaceIDs: [Int]
    public let loadGroups: [TopOptKit.LoadGroupSpec]
    /// "Minimize plastic": on → the material-reduction ladder; off → one
    /// conservative variant that just handles the forces.
    public let minimizePlastic: Bool
    /// Print/build direction (model frame) for the interlayer-margin orientation.
    public let buildDirection: SIMD3<Double>
    /// The M7.params user infill-density override (0–100 %), or < 0 for "no override".
    /// Threaded to the core through the bridge (`BridgeLoadCase.infill_percent`) for
    /// the M7.infill-margin ladder knockdown. Part of the request identity, so
    /// changing infill re-enables Optimize (it feeds the optimizer, unlike the other
    /// print parameters, which are slicer-settings overrides only).
    public let infillPercent: Int
    /// The M7.dom-app design box (model space, mm) the optimizer may GROW material
    /// into beyond the import, or nil for the default no-box run (byte-identical to
    /// before). Consumed only on the STEP load-case path. Part of the request
    /// identity, so editing the box re-enables Optimize.
    public let designBox: TopOptKit.DesignBoxSpec?
    /// The M7.dom-app keep-out boxes (regions the optimizer must leave empty). Only
    /// meaningful alongside a `designBox`.
    public let keepOutBoxes: [TopOptKit.DesignBoxSpec]
    /// The "Keep clear" clearances (handoff 100): swept-cylinder bolt keep-outs for
    /// anchored bores + bounded-slab face clearances. Consumed only on the STEP
    /// load-case path. Part of the request identity, so editing a clearance
    /// re-enables Optimize (it forbids growth, changing the design).
    public let clearances: [TopOptKit.ClearanceSpec]
    /// The Face protections (handoff 124): B-rep faces whose OWN material the
    /// optimizer may not touch — the core freezes each face's part-solid skin
    /// FrozenSolid to `faceProtectionDepthMM`. Consumed only on the STEP load-case
    /// path. Part of the request identity, so protecting/un-protecting a face (or
    /// editing the global depth) re-enables Optimize (it changes what is preserved).
    public let faceProtections: [Int]
    /// The ONE global preserve-depth (mm) governing every Face protection; <= 0
    /// means "use the core default". Part of the request identity.
    public let faceProtectionDepthMM: Double
    /// The owning project's id (handoff 119). Carried so a REMOTE run persists which
    /// project it belongs to (`PersistedRemoteJob.projectID`), letting a cold-launch
    /// re-attach reopen that project and land the streamed result in the normal
    /// workspace→results flow. NOT part of the request identity (it doesn't change the
    /// optimization) and unused by the local bridge path; nil for an ad-hoc run.
    public let projectID: UUID?

    /// STEP parts carry a B-rep face selection, so the run uses the load-case path;
    /// STL parts have no faces and fall back to the self-weight path.
    public var isStepModel: Bool {
        let p = modelPath.lowercased()
        return p.hasSuffix(".step") || p.hasSuffix(".stp")
    }

    public init(modelPath: String, material: String, materialsPath: String,
                rulesPath: String, resolution: Int, projectName: String,
                anchorFaceIDs: [Int] = [], loadGroups: [TopOptKit.LoadGroupSpec] = [],
                minimizePlastic: Bool = true, buildDirection: SIMD3<Double> = SIMD3(0, 0, 1),
                infillPercent: Int = -1,
                designBox: TopOptKit.DesignBoxSpec? = nil,
                keepOutBoxes: [TopOptKit.DesignBoxSpec] = [],
                clearances: [TopOptKit.ClearanceSpec] = [],
                faceProtections: [Int] = [], faceProtectionDepthMM: Double = -1,
                projectID: UUID? = nil) {
        self.modelPath = modelPath
        self.material = material
        self.materialsPath = materialsPath
        self.rulesPath = rulesPath
        self.resolution = resolution
        self.projectName = projectName
        self.anchorFaceIDs = anchorFaceIDs
        self.loadGroups = loadGroups
        self.minimizePlastic = minimizePlastic
        self.buildDirection = buildDirection
        self.infillPercent = infillPercent
        self.designBox = designBox
        self.keepOutBoxes = keepOutBoxes
        self.clearances = clearances
        self.faceProtections = faceProtections
        self.faceProtectionDepthMM = faceProtectionDepthMM
        self.projectID = projectID
    }
}

/// A snapshot of a running optimization, from the M7.0a callback (rung index,
/// rung count, OC iteration). The percentage + stage label are derived here so the
/// bar math is unit-tested, not buried in the view.
public struct RunProgress: Equatable, Sendable {
    /// 0-based index of the current volume-fraction rung.
    public let rung: Int
    /// Total rungs in the ladder (clamped ≥ 1).
    public let rungCount: Int
    /// 1-based OC iteration within the current rung (0 before the first callback).
    public let iteration: Int

    public init(rung: Int, rungCount: Int, iteration: Int) {
        self.rungCount = Swift.max(1, rungCount)
        self.rung = Swift.min(Swift.max(0, rung), self.rungCount - 1)
        self.iteration = Swift.max(0, iteration)
    }

    /// Iteration count at which the within-rung ramp reaches ~63% of the rung's
    /// span. SIMP/OC converges in tens–low-hundreds of iterations and the core
    /// exposes no iteration ceiling, so the bar ramps asymptotically within a rung
    /// (honest: it never claims a rung is done until the next rung begins) and
    /// steps cleanly at each rung boundary.
    static let iterationScale = 60.0

    /// Fraction complete, in `0 ..< 1`. Completed rungs contribute their full
    /// share; the current rung contributes a bounded ramp in its own share. Never
    /// reaches 1 — only a resolved run (`succeeded`) shows 100%.
    public var fractionComplete: Double {
        let perRung = 1.0 / Double(rungCount)
        let completed = Double(rung) * perRung
        let within = perRung * (1.0 - exp(-Double(iteration) / Self.iterationScale))
        return Swift.min(0.999, completed + within)
    }

    /// Whole-percent form for the big "NN%" readout.
    public var percent: Int { Int((fractionComplete * 100).rounded()) }

    /// The design's stage line (docs/design/TopOpt.dc.html `_stage`). The only
    /// signal the core emits is the per-OC-iteration tick, so the honest label
    /// names the rung and iteration rather than inventing voxelize/assemble phases.
    public var stageLabel: String {
        rungCount > 1
            ? "Variant \(rung + 1) of \(rungCount) · SIMP iteration \(iteration)"
            : "SIMP iteration \(iteration)"
    }

    /// Fraction of the ladder DONE, measured by completed rungs only (0…1). Unlike
    /// `fractionComplete` this makes no within-rung claim: it steps at each variant
    /// boundary and sits flat while a rung runs (honest — handoff 086 made rung
    /// termination ADAPTIVE, so there is no in-advance sub-rung progress to show).
    /// The progress-readout surfaces (086-mma-plateau-termination) drive the honest
    /// determinate bar from THIS, and lean on the live elapsed/iteration ticks for
    /// the "it's alive" signal, rather than the fabricated `fractionComplete` ramp.
    public var rungFractionComplete: Double {
        Double(rung) / Double(rungCount)
    }

    /// An HONEST remaining-time estimate in seconds, or nil when there isn't yet
    /// enough measured history to project one. `elapsed` is total wall time since the
    /// run began; `currentRungElapsed` is how long THIS rung has been running. It
    /// averages the time per COMPLETED rung (rungs are the only durations we can
    /// actually measure — the bridge callback carries no per-iteration timing) and
    /// counts DOWN within a rung: `currentLeft` shrinks as the current rung runs, so
    /// the estimate never inflates while you wait. nil until ≥1 rung has finished —
    /// before the first variant lands there is no rung rate to extrapolate from, so
    /// the UI says "estimating" rather than inventing a number. Callers must present
    /// the result as an estimate (the maintainer's honesty constraint): it assumes
    /// later rungs cost about what earlier ones did, which is only roughly true.
    public func remainingEstimate(elapsed: TimeInterval,
                                  currentRungElapsed: TimeInterval) -> TimeInterval? {
        let completed = rung                       // 0-based index == finished rungs
        guard completed >= 1, elapsed > 0 else { return nil }
        let completedTime = Swift.max(0, elapsed - currentRungElapsed)
        let perRung = completedTime / Double(completed)
        guard perRung > 0 else { return nil }
        let notStarted = Swift.max(0, rungCount - completed - 1)
        let currentLeft = Swift.max(0, perRung - currentRungElapsed)
        return perRung * Double(notStarted) + currentLeft
    }
}

/// One TIMESTAMPED progress observation (handoff 111 — the honest ETA). The bridge
/// callback carries (rung, rungCount, iteration); `time` is when it was OBSERVED, in
/// seconds on any steady clock (production stamps `Date().timeIntervalSinceReferenceDate`;
/// the pure tests pass synthetic seconds). The ETA is derived from the SPACING of these
/// timestamps rather than accumulated wall-clock, so it survives a reconnect (the gap
/// is one measured interval, not double-counted elapsed time).
public struct RunProgressSample: Equatable, Sendable {
    public let time: TimeInterval
    public let rung: Int
    public let rungCount: Int
    public let iteration: Int
    public init(time: TimeInterval, rung: Int, rungCount: Int, iteration: Int) {
        self.time = time
        self.rungCount = Swift.max(1, rungCount)
        self.rung = Swift.min(Swift.max(0, rung), self.rungCount - 1)
        self.iteration = Swift.max(0, iteration)
    }
}

/// An honest remaining-time estimate (handoff 111): a magnitude, the BOUND it carries
/// (an upper bound before any rung finishes, else a live approximation), the smoothed
/// per-iteration rate it was built from, and the timestamp it was computed AT — so the
/// view ticks it down between events and dims it once the stream goes stale.
public struct RunETA: Equatable, Sendable {
    public enum Bound: Equatable, Sendable {
        /// Built on the iteration CAP (no rung has finished yet) → a true UPPER bound;
        /// the view labels it "≤ …". Plateau termination usually fires well before the
        /// cap, so the real time lands under this.
        case upper
        /// Built on OBSERVED iterations-per-rung (≥1 rung done) → a live approximation;
        /// the view labels it "~ …" and it updates each rung.
        case approximate
    }
    public let secondsRemaining: TimeInterval
    public let bound: Bound
    public let secondsPerIteration: TimeInterval
    public let asOf: TimeInterval
    public init(secondsRemaining: TimeInterval, bound: Bound,
                secondsPerIteration: TimeInterval, asOf: TimeInterval) {
        self.secondsRemaining = Swift.max(0, secondsRemaining)
        self.bound = bound
        self.secondsPerIteration = secondsPerIteration
        self.asOf = asOf
    }
}

/// The pure ETA estimator (handoff 111). Folds a sequence of timestamped progress
/// samples into a smoothed per-iteration rate (EMA) and a remaining-iteration count,
/// then multiplies. Two regimes:
///   * BEFORE the first rung finishes, the per-rung length is unknown, so it uses the
///     iteration CAP: `remainingIters = (cap − doneInRung) + cap × rungsLeft` — an
///     UPPER bound, labelled ≤ (plateau usually terminates a rung early).
///   * ONCE ≥1 rung has finished, it swaps the cap for the running MEAN of observed
///     iterations-per-rung — a live approximation, labelled ~ and refined each rung.
/// The rate EMA folds WITHIN-rung deltas only (a rung boundary spans a full FEA solve,
/// not one iteration) and rejects extreme outliers (a reconnect replay's giant Δtime),
/// so a dropped connection can't corrupt it. Pure + `Equatable`, so it is unit-tested by
/// feeding synthetic sequences and asserting the magnitude/bound transitions.
public struct RunETAEstimator: Equatable, Sendable {
    /// The core's per-rung SIMP safety cap (handoff 086: iter 100–145 typical, cap 200).
    /// Using the cap makes the pre-first-rung estimate a genuine upper bound.
    public static let iterationCap = 200
    /// EMA weight on the newest per-iteration sample — smooths jitter while still
    /// following a rung that genuinely runs slower or faster.
    public static let emaWeight = 0.3
    /// Warm-up: the per-iteration samples required before an ETA is offered (~5
    /// iterations); below this the rate is too noisy to project honestly.
    public static let warmupSamples = 4
    /// Reject a per-iteration sample whose rate exceeds this multiple of the running
    /// EMA — a reconnect gap (huge Δtime over a couple of iterations) is an outlier,
    /// not a real slowdown, and must not pull the estimate.
    public static let outlierFactor = 6.0

    private var ema: Double?
    private var sampleCount = 0
    private var last: RunProgressSample?
    private var completedRungIters: [Int] = []
    private var currentRungMaxIter = 0

    public init() {}

    /// Fold one sample into the running estimate.
    public mutating func ingest(_ s: RunProgressSample) {
        defer { last = s }
        guard let prev = last else {          // first sample: nothing to measure yet
            currentRungMaxIter = s.iteration
            return
        }
        guard s.time >= prev.time else { return }   // drop a stale / replayed event
        if s.rung != prev.rung {
            // Rung boundary: bank the rung that just finished (its final iteration
            // count) and start the new one. No per-iteration sample here — the interval
            // spans a full solve, not one iteration.
            if s.rung > prev.rung { completedRungIters.append(currentRungMaxIter) }
            currentRungMaxIter = s.iteration
        } else {
            currentRungMaxIter = Swift.max(currentRungMaxIter, s.iteration)
            let dIter = s.iteration - prev.iteration
            let dTime = s.time - prev.time
            if dIter > 0, dTime > 0 {
                let perIter = dTime / Double(dIter)
                if let e = ema, perIter > Self.outlierFactor * e {
                    // reconnect-sized outlier → ignore for the rate (but the sample's
                    // rung/iteration bookkeeping above still stands)
                } else {
                    ema = ema.map { Self.emaWeight * perIter + (1 - Self.emaWeight) * $0 } ?? perIter
                    sampleCount += 1
                }
            }
        }
    }

    /// The current estimate, or nil before warm-up (or with no rate yet).
    public var eta: RunETA? {
        guard let ema, let cur = last, sampleCount >= Self.warmupSamples else { return nil }
        let perRung: Double
        let bound: RunETA.Bound
        if completedRungIters.isEmpty {
            perRung = Double(Self.iterationCap)
            bound = .upper
        } else {
            perRung = Double(completedRungIters.reduce(0, +)) / Double(completedRungIters.count)
            bound = .approximate
        }
        let rungsLeft = Swift.max(0, cur.rungCount - cur.rung - 1)
        let remainingInCurrent = Swift.max(0, perRung - Double(cur.iteration))
        let remainingIters = remainingInCurrent + perRung * Double(rungsLeft)
        return RunETA(secondsRemaining: ema * remainingIters, bound: bound,
                      secondsPerIteration: ema, asOf: cur.time)
    }

    /// Fold an entire sequence — the pure entry point the tests drive.
    public static func estimate(from samples: [RunProgressSample]) -> RunETA? {
        var e = RunETAEstimator()
        for s in samples { e.ingest(s) }
        return e.eta
    }
}

/// A run failure the design renders as a sheet (ROADMAP M7.7: "not alerts").
public enum RunFailure: Equatable, Sendable {
    /// The core threw — e.g. CG non-convergence / singular system (the M3.1 guard).
    /// The associated string is the core diagnostic.
    case solver(String)
    /// No variant met the strength-margin gate (`acceptedCount == 0`). Acceptance
    /// is strength-margin ONLY (core policy: `variant.accepted = worst_case >=
    /// margin_stop`; min-feature is report-only, DECISIONS 2026-07-06), so a
    /// genuine all-rejected is always a strength failure. Carries the strongest
    /// (terminal) rung's worst-case margin and its advisory thin-feature count so
    /// the sheet can name the failing check and the numbers.
    case allRejectedOnMargin(worstMargin: Double, minFeatureViolations: Int)

    /// The strength-margin minimum every accepted variant must clear (core
    /// `MinimizePlasticOptions.margin_stop` default / ROADMAP M5.3).
    public static let marginStop = 1.5

    /// Shown when a run stalls in core setup/solve without ever emitting progress
    /// (the M7.diag setup-stall watchdog). Root-cause-agnostic and actionable so it
    /// is honest whatever the underlying stall is, and it frees Optimize to retry. It
    /// NAMES the grace it actually waited (an honest guard admits its own timeout) and
    /// points at "Keep waiting" for a run that may simply need longer.
    public static func stalledDuringSetup(graceSeconds: Double) -> String {
        "The optimizer stalled before it could take its first step, so the run was "
      + "stopped after \(gracePhrase(graceSeconds)) with no progress. This can happen "
      + "on a dense load case or a fine resolution — try the Fast resolution or a "
      + "simpler load case, then run again. If you think it just needs longer, tap "
      + "Keep waiting."
    }

    /// The design-box variant of `stalledDuringSetup`. The design box (growth
    /// space) is the confirmed trigger of the on-device stall — it makes the solver
    /// work on a much larger expanded grid — so when the stalled run used one, point
    /// the user straight at it (turning it off is the reliable workaround today).
    public static func stalledWithDesignBox(graceSeconds: Double) -> String {
        "The optimizer stalled before it could take its first step, so the run was "
      + "stopped after \(gracePhrase(graceSeconds)) with no progress. The growth space "
      + "(design box) makes this much more likely — try turning it off or making it "
      + "smaller, or use the Fast resolution, then run again. If you think it just "
      + "needs longer, tap Keep waiting."
    }

    /// Render a grace duration as human copy for the stall sheet: "45 seconds",
    /// "2 minutes", "2 minutes 30 seconds".
    public static func gracePhrase(_ seconds: Double) -> String {
        let total = Swift.max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) second\(total == 1 ? "" : "s")" }
        let m = total / 60, r = total % 60
        let mins = "\(m) minute\(m == 1 ? "" : "s")"
        return r == 0 ? mins : "\(mins) \(r) second\(r == 1 ? "" : "s")"
    }

    /// Substituted for an EMPTY core diagnostic so a genuine failure never renders
    /// a blank sheet (some core throws carry no `what()` text on device).
    public static let unknownSolverError =
        "The optimizer stopped with an unspecified error. Please try again, or try "
      + "a coarser resolution."

    /// Sheet headline.
    public var title: String {
        switch self {
        case .solver: return "Optimization couldn’t finish"
        case .allRejectedOnMargin: return "Not strong enough to print"
        }
    }

    /// Sheet body copy — names the failing check and the numbers.
    public var message: String {
        switch self {
        case .solver(let diagnostic):
            return diagnostic
        case .allRejectedOnMargin(let worstMargin, let violations):
            let margin = String(format: "%.2f", worstMargin)
            var body = "The strongest variant’s worst-case stress margin was "
                     + "\(margin)× — below the \(String(format: "%.1f", Self.marginStop))× "
                     + "safety minimum, so it isn’t strong enough to print. "
                     + "Try a stronger material, a coarser resolution, or a lighter load."
            if violations > 0 {
                body += " (The \(violations) thin-feature warning"
                      + "\(violations == 1 ? "" : "s") are advisory and did not cause this.)"
            }
            return body
        }
    }
}

/// Where the run phase transitions between: idle → running → one of succeeded /
/// cancelled / failed.
public enum RunPhase: Equatable, Sendable {
    case idle
    case running
    case succeeded
    case cancelled
    case failed

    /// The optimization is in flight (the progress card is shown).
    public var isRunning: Bool { self == .running }
}

/// Thread-safe cancellation flag. The optimize runs on a background queue and its
/// progress callback (also on that queue) reads this directly to decide whether to
/// keep going, so cancellation needs no cross-thread hop and no data race.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Runs the optimize off the main thread and hops UI updates back. Injected so the
/// tests drive everything synchronously; production uses a background queue + main.
public protocol RunScheduler {
    func runInBackground(_ work: @escaping () -> Void)
    func runOnMain(_ work: @escaping () -> Void)
}

/// Production scheduler: a user-initiated background queue + the main queue.
public struct GCDRunScheduler: RunScheduler {
    private let queue: DispatchQueue
    public init(queue: DispatchQueue = DispatchQueue(label: "app.topopt.optimize", qos: .userInitiated)) {
        self.queue = queue
    }
    public func runInBackground(_ work: @escaping () -> Void) { queue.async(execute: work) }
    public func runOnMain(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }
}

/// Test scheduler: run everything inline on the caller (the test's main thread).
public struct SynchronousRunScheduler: RunScheduler {
    public init() {}
    public func runInBackground(_ work: @escaping () -> Void) { work() }
    public func runOnMain(_ work: @escaping () -> Void) { work() }
}

/// The setup-stall watchdog (M7.diag — on-device optimize silent failure). A run
/// that never emits its first progress tick is stuck in the core setup/solve
/// (diagnosed: the production MultigridCG path, on a high-contrast 64³ system,
/// stagnates then runs an effectively-unbounded Jacobi-CG fallback — a core bug,
/// tracked for a core follow-up). That stall throws no exception, so without this
/// the run hangs at 0% forever and leaves Optimize greyed (`phase == .running`).
/// The watchdog is armed at `start`, DISARMED by the first sign of progress (so a
/// genuinely-progressing-but-slow run is never touched), and if it fires it turns
/// the stalled run into an honest failure sheet and re-enables Optimize.
///
/// Injected so tests drive it deterministically; production uses a real timer.
public protocol RunWatchdog {
    /// Arm a one-shot stall timer; invoke `onStall` on the main thread unless the
    /// returned handle is called first to cancel it. Called on the main actor.
    func arm(_ onStall: @escaping () -> Void) -> RunWatchdogCancel
    /// The grace this watchdog waits before firing — surfaced so the stall sheet can
    /// name the timeout it actually enforced ("an honest guard admits its own timeout").
    var graceSeconds: Double { get }
}

/// Cancels an armed watchdog (idempotent).
public typealias RunWatchdogCancel = () -> Void

/// Production watchdog: fire `onStall` after `graceSeconds` of no first progress.
/// The grace must clear the slowest LEGITIMATE first FEA solve (one solve runs
/// before the first OC-iteration tick) so it only ever trips a genuine LOCAL stall.
/// The default is the honest ~150s that window needs. It used to be band-aided up to
/// 1800s because REMOTE runs shared this same guard, and a queued (or long-first-
/// solve) remote run would otherwise trip it; remote no longer arms this watchdog
/// (see `RunModel.start(_:remote:)`), so the local grace is back to 150s.
public struct TimerRunWatchdog: RunWatchdog {
    public let graceSeconds: Double
    public init(graceSeconds: Double = 150) { self.graceSeconds = graceSeconds }
    public func arm(_ onStall: @escaping () -> Void) -> RunWatchdogCancel {
        let work = DispatchWorkItem(block: onStall)
        DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds, execute: work)
        return { work.cancel() }
    }
}

/// A watchdog that never fires (for tests / previews that don't exercise it).
public struct DisabledRunWatchdog: RunWatchdog {
    public init() {}
    public var graceSeconds: Double { .infinity }
    public func arm(_ onStall: @escaping () -> Void) -> RunWatchdogCancel { {} }
}

/// Side effects for the "Run in Background" affordance (ROADMAP M7.7). Injected so
/// the model is tested with a spy; the real implementation posts a local
/// notification (and the app target registers the BGProcessingTask).
public protocol RunNotifier {
    /// The user chose to keep the run going in the background.
    func willRunInBackground()
    /// The (backgrounded) run finished — post the completion notification.
    func runDidComplete(summary: String)
}

/// A notifier that does nothing (the default, and what headless tests use through
/// the spy). The workspace substitutes `LocalRunNotifier` on device.
public struct SilentRunNotifier: RunNotifier {
    public init() {}
    public func willRunInBackground() {}
    public func runDidComplete(summary: String) {}
}

#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The on-device "Run in Background" seam (ROADMAP M7.7): holds a background-
/// execution assertion so the in-flight run keeps going after the user leaves the
/// app, and posts a local notification when it finishes. All system objects are
/// touched lazily (only once the user backgrounds a run, always on the main
/// thread since RunModel is `@MainActor`), so constructing this off-device — or in
/// a SwiftUI preview — is harmless.
///
/// Our run is an in-memory computation, so an execution assertion
/// (`beginBackgroundTask`) is the fitting primitive to let it finish; a
/// `BGTaskScheduler`/BGProcessingTask cold-launch registration (for deferrable,
/// restartable work) is a maintainer device-QA decision, not wired here.
public final class LocalRunNotifier: RunNotifier {
    #if canImport(UIKit)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    public init() {}

    /// Ask for notification permission up front (handoff 121). A remote run can
    /// finish while the user is in the foreground OR via the cold-launch re-attach,
    /// and either fires a completion notification — so we request permission at app
    /// launch rather than only when a run is backgrounded. Idempotent; a denial just
    /// means no banners.
    public static func requestAuthorization() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    public func willRunInBackground() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
        #if canImport(UIKit)
        endAssertion()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "app.topopt.optimize") { [weak self] in
            self?.endAssertion()   // iOS reclaiming time — release cleanly
        }
        #endif
    }

    public func runDidComplete(summary: String) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = "TopOpt"
        content.body = summary
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        #endif
        #if canImport(UIKit)
        endAssertion()
        #endif
    }

    #if canImport(UIKit)
    private func endAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}

/// The run-screen state machine (ROADMAP M7.7).
@MainActor
public final class RunModel: ObservableObject {

    /// The current run phase; drives whether the progress card / a failure sheet
    /// is shown.
    @Published public private(set) var phase: RunPhase = .idle
    /// The latest progress snapshot while running (nil before the first callback).
    @Published public private(set) var progress: RunProgress?
    /// The failure to render as a sheet when `phase == .failed`.
    @Published public private(set) var failure: RunFailure?
    /// True only for a STALL failure (the setup-stall watchdog fired): the background
    /// solve was NOT cancelled, so the sheet offers "Keep waiting" to re-arm the guard
    /// and give it more time. Cleared when the run resolves, is dismissed, or resumes.
    @Published public private(set) var canKeepWaiting = false
    /// Whether the user asked to keep the run going in the background.
    @Published public private(set) var runningInBackground = false
    /// While running, whether the progress card is dismissed ("Run in Background"):
    /// the run keeps executing on the background queue and the workspace shows a
    /// small re-open chip instead of the full-screen card. Cleared when the run
    /// resolves so a failure sheet / success can surface.
    @Published public private(set) var isMinimized = false

    /// The outcome the results screen consumes. Updated INCREMENTALLY as variants
    /// stream in (progressive results), then replaced by the authoritative final
    /// outcome when the run resolves. `@Published` so the results screen grows live.
    @Published public private(set) var outcome: OptimizeOutcome?
    /// True while more variants may still arrive (the optimize is running behind an
    /// already-visible results screen). Drives an "optimizing more…" indicator.
    @Published public private(set) var isStreaming = false

    /// Wall-clock instant the in-flight run started (set in `start`, cleared in
    /// `reset`). PRESENTATION-ONLY — it drives the progress readout's elapsed clock
    /// and the rung-rate ETA (run-progress-visibility task). It is deliberately NOT
    /// part of how runs persist or stream (that is the concurrent data-loss task's
    /// territory): nothing here reads or writes it except the readout. Because the
    /// RunModel is owned by the ProjectModel it survives a Home round-trip, so an
    /// 80-minute run backgrounded and reopened still shows a truthful elapsed time.
    @Published public private(set) var startedAt: Date?

    /// Wall-clock instant of the most recent live signal from the runner — a
    /// progress tick OR a streamed variant (set in `publish`/`appendStreamed`,
    /// cleared in `start`/`reset`). PRESENTATION-ONLY, like `startedAt`: it feeds
    /// the REMOTE run's "last update Xs ago" freshness cue (handoff 101,
    /// requirement 6) so a stalled worker reads as stale instead of an eternally-
    /// spinning pill. A local run updates it too (harmless — the readout only
    /// surfaces the cue for a remote run, via `remoteFreshnessNote`).
    @Published public private(set) var lastProgressAt: Date?

    /// The live remaining-time estimate (handoff 111), recomputed on every progress
    /// tick from the per-iteration event stream (`RunETAEstimator`). nil until warm-up.
    /// PRESENTATION-ONLY, like `startedAt` — the readout ticks it down between events
    /// and dims it when the stream goes stale. Both local and remote runs feed it,
    /// since both drive `publish`.
    @Published public private(set) var eta: RunETA?

    /// The per-iteration ETA estimator, folded in `publish` and reset per run.
    private var etaEstimator = RunETAEstimator()

    /// Instant this LOCAL run's solve began, for the outcome's carried `RunTiming`
    /// (handoff 134, item 1). Distinct from the presentation-only `startedAt` on
    /// purpose: this one becomes a DURABLE number on the result (persisted, shown on
    /// the summary), so its rules are stricter — it is consumed ONLY for a local run,
    /// where this process is the thing doing the solving and start→finish here IS the
    /// run. A REMOTE run never uses it: its client may have slept, been force-quit, or
    /// re-attached hours later, so the honest duration is the worker's own record
    /// (`RemoteRun.fetchTiming`), and this stamp is ignored rather than allowed to
    /// report when someone looked.
    private var localSolveStartedAt: Date?
    /// Clock for the local solve stamp. Injected so the duration is unit-testable
    /// without sleeping; production is `Date()`.
    private let clock: () -> Date

    /// The freshness cue for a REMOTE run's progress readout (handoff 101). Returns
    /// "last update Xs ago" once the gap since the last live signal exceeds ~2× the
    /// worker heartbeat (so a healthy sub-heartbeat cadence shows nothing), else
    /// nil. Pure + static so the threshold/format is unit-tested without a view or a
    /// clock; the RunScreen calls it with `lastProgressAt` only when the run is
    /// remote. The inactivity WATCHDOG (client liveness, in RemoteRunner) is a
    /// separate mechanism keyed off SSE pings; this is the USER-facing "is it still
    /// alive?" honesty cue keyed off visible progress.
    public static func remoteFreshnessNote(lastUpdate: Date?, now: Date = Date(),
                                           heartbeat: TimeInterval = 20) -> String? {
        guard let last = lastUpdate else { return nil }
        let dt = now.timeIntervalSince(last)
        guard dt >= 2 * heartbeat else { return nil }
        return "last update \(Int(dt.rounded()))s ago"
    }

    /// The optimize call. Injected for tests; defaults to the real bridge. Streams
    /// each accepted variant through `onVariant` (a one-variant partial outcome) as
    /// it completes, then returns the full final outcome.
    public typealias Runner = (RunRequest,
                               _ progress: @escaping (_ rung: Int, _ rungCount: Int, _ iteration: Int) -> Bool,
                               _ onVariant: @escaping (OptimizeOutcome) -> Void)
                               throws -> OptimizeOutcome
    var runner: Runner

    private let scheduler: RunScheduler
    private let notifier: RunNotifier
    private let watchdog: RunWatchdog
    private var token = CancelToken()
    /// Cancels the armed setup-stall watchdog; nil when none is armed.
    private var watchdogCancel: RunWatchdogCancel?
    /// The in-flight request, so a watchdog stall can tailor its message (e.g. name
    /// the design box, the confirmed on-device stall trigger). Cleared when the run
    /// resolves.
    private var runningRequest: RunRequest?
    /// Whether the in-flight run is REMOTE (set per run in `start`). A remote run does
    /// NOT arm the local setup-stall watchdog: its liveness — queue-awareness and the
    /// heartbeat/probe loop — is owned by `RemoteRun` (handoff 129).
    private var isRemoteRun = false

    #if canImport(os)
    private static let log = Logger(subsystem: "app.topopt", category: "run")
    #endif

    public init(scheduler: RunScheduler = GCDRunScheduler(),
                notifier: RunNotifier = SilentRunNotifier(),
                watchdog: RunWatchdog = TimerRunWatchdog(),
                runner: @escaping Runner = RunModel.bridgeRunner,
                clock: @escaping () -> Date = { Date() }) {
        self.scheduler = scheduler
        self.notifier = notifier
        self.watchdog = watchdog
        self.runner = runner
        self.clock = clock
    }

    /// Diagnostic log hop (M7.diag). os_log on Apple → Console.app + Xcode; a
    /// no-op elsewhere. Used to record WHY a run failed, so a device failure is
    /// never silent even before the UI sheet renders.
    private func diag(_ message: String) {
        #if canImport(os)
        Self.log.error("\(message, privacy: .public)")
        #endif
    }

    /// The default runner: drive `minimize_plastic` with the M7.0a progress
    /// callback (which doubles as the cancellation signal — returning `false`
    /// stops the run).
    public static func bridgeRunner(_ request: RunRequest,
                                    _ progress: @escaping (Int, Int, Int) -> Bool,
                                    _ onVariant: @escaping (OptimizeOutcome) -> Void) throws -> OptimizeOutcome {
        // STEP: optimize under the user's declared load case (anchors/loads →
        // clamps + tractions), or self-weight when no loads were set. STL: no
        // faces, so the self-weight ladder (ARCHITECTURE §5) is the only option.
        if request.isStepModel {
            return try TopOptKit.minimizePlasticLoadCase(
                stepPath: request.modelPath, material: request.material,
                materialsPath: request.materialsPath, rulesPath: request.rulesPath,
                resolution: request.resolution, anchorFaceIDs: request.anchorFaceIDs,
                loadGroups: request.loadGroups, minimizePlastic: request.minimizePlastic,
                buildDirection: request.buildDirection, infillPercent: request.infillPercent,
                designBox: request.designBox, keepOutBoxes: request.keepOutBoxes,
                clearances: request.clearances,
                faceProtections: request.faceProtections,
                faceProtectionDepthMM: request.faceProtectionDepthMM,
                progress: progress, onVariant: onVariant)
        }
        return try TopOptKit.minimizePlastic(
            stlPath: request.modelPath, material: request.material,
            materialsPath: request.materialsPath, rulesPath: request.rulesPath,
            resolution: request.resolution, progress: progress, onVariant: onVariant)
    }

    // MARK: - Lifecycle

    /// Start an optimize on a background queue. No-op if one is already running.
    /// Restore persisted results (persist-c) into an idle run so the workspace shows
    /// them immediately on reopen — no side effects (phase stays `.idle`, no
    /// notifier). A later Optimize resets and re-runs as normal. No-op if a run is
    /// active or results already loaded (e.g. reopened within the same launch).
    public func restoreOutcome(_ restored: OptimizeOutcome) {
        guard phase == .idle, outcome == nil else { return }
        outcome = restored
    }

    /// Start an optimize. `remote` marks a run offloaded to a LAN worker: such a run
    /// does NOT arm the local setup-stall watchdog (handoff 129) — `RemoteRun` owns its
    /// liveness (a QUEUED job is held open indefinitely by the worker's heartbeat, and
    /// the run fails loudly only when the worker is unreachable, i.e. heartbeats AND
    /// probes both absent). A LOCAL run begins solving immediately, so it arms the
    /// guard here with the honest ~150s grace.
    public func start(_ request: RunRequest, remote: Bool = false) {
        guard phase != .running else { return }
        phase = .running
        progress = nil
        failure = nil
        canKeepWaiting = false
        outcome = nil
        isStreaming = true
        startedAt = Date()      // anchor the elapsed clock / ETA (presentation-only)
        lastProgressAt = Date() // seed the freshness cue (presentation-only)
        localSolveStartedAt = clock()   // the DURABLE local-solve stamp (134) — see the property
        etaEstimator = RunETAEstimator()   // fresh per-iteration ETA history
        eta = nil
        runningInBackground = false
        isMinimized = false

        let token = CancelToken()
        self.token = token
        runningRequest = request
        let runner = self.runner
        let scheduler = self.scheduler

        // Arm the setup-stall watchdog — LOCAL runs only (handoff 129). A local run is
        // already solving, so a 0%-forever hang is the core MultigridCG→Jacobi stall
        // (no exception to surface). A REMOTE run's liveness is `RemoteRun`'s job: it
        // consumes the worker's queued/solving state (POST /jobs response + GET /jobs
        // probes) so a queued job holds fire indefinitely, and it defers to the SSE
        // heartbeat — failing only when heartbeats are ALSO absent (a live worker with
        // no progress is a long first solve, which the freshness UI communicates).
        // Arming this local guard for remote too was the latent bug the 1800s band-aid
        // hid: a queued/long remote run tripping it would cancel the token → RemoteRun
        // reads a user-cancel → DELETEs the Mac's job. So remote does not arm it.
        watchdogCancel?()
        isRemoteRun = remote
        if !remote {
            watchdogCancel = watchdog.arm { [weak self] in self?.watchdogFired(token) }
        }

        scheduler.runInBackground { [weak self] in
            let result: Result<OptimizeOutcome, Error>
            do {
                let o = try runner(request, { rung, count, iter in
                    // Publish the snapshot on main (fire-and-forget); the keep-going
                    // decision reads the token directly — thread-safe, no hop.
                    scheduler.runOnMain { self?.publish(RunProgress(rung: rung, rungCount: count, iteration: iter)) }
                    return !token.isCancelled
                }, { partial in
                    // Progressive results: a variant finished — append it on main so
                    // the results screen can show the first one while the rest run.
                    scheduler.runOnMain { self?.appendStreamed(partial) }
                })
                result = .success(o)
            } catch {
                result = .failure(error)
            }
            scheduler.runOnMain { self?.finish(request, token, result) }
        }
    }

    /// Re-anchor the in-flight ELAPSED clock to when the run actually began, for a
    /// re-attach (handoff 134). `start` anchors it to "now", which for a re-attached
    /// run means the moment the CLIENT arrived — so a run 10 hours into its solve read
    /// "0:03" while the Mac had been at it all night. The persisted submit time is the
    /// client's best honest knowledge of when the run began; the readout then says how
    /// long THE RUN has been going, not how long you have been watching it. Ignored for
    /// a future date (a clock skew must not produce a negative clock) and only while
    /// running. PRESENTATION-ONLY, like `startedAt` itself — the DURABLE duration on
    /// the result comes from the worker's own record (`RunTiming`), never from here.
    public func anchorElapsed(to began: Date) {
        guard phase == .running, began <= Date() else { return }
        startedAt = began
    }

    /// The setup-stall watchdog fired: the run produced no progress and no streamed
    /// variant within the grace period, so it is stuck in core setup/solve (no
    /// exception thrown). Convert it to an honest failure sheet — but only if this
    /// is STILL the run that armed it (`token`) and it truly never came alive.
    private func watchdogFired(_ token: CancelToken) {
        guard token === self.token, phase == .running, progress == nil,
              (outcome?.variants.isEmpty ?? true) else { return }
        // Do NOT cancel the token here (handoff 129): the run may simply be slow, and
        // the sheet offers "Keep waiting" (`keepWaiting`) which re-arms this guard to
        // give the still-running background solve more time. The token is cancelled
        // only when the user ABANDONS the run (dismissFailure / Try Again).
        let hadDesignBox = runningRequest?.designBox != nil
        let grace = watchdog.graceSeconds
        diag("run stalled during setup — no progress within \(Int(grace))s (designBox=\(hadDesignBox)); surfacing a failure sheet with Keep-waiting")
        outcome = nil
        failure = .solver(hadDesignBox ? RunFailure.stalledWithDesignBox(graceSeconds: grace)
                                       : RunFailure.stalledDuringSetup(graceSeconds: grace))
        canKeepWaiting = true
        phase = .failed
        isStreaming = false
        isMinimized = false
        watchdogCancel = nil
    }

    /// "Keep waiting" from the stall sheet (an honest guard admits its own timeout).
    /// The grace expired but the background solve was never cancelled, so give it
    /// another grace period rather than abandoning it: re-arm the watchdog against the
    /// SAME run token and return to the running card.
    public func keepWaiting() {
        guard phase == .failed, canKeepWaiting else { return }
        canKeepWaiting = false
        failure = nil
        phase = .running
        isStreaming = true
        lastProgressAt = Date()   // reset the freshness cue for the extended wait
        let token = self.token
        watchdogCancel?()
        watchdogCancel = watchdog.arm { [weak self] in self?.watchdogFired(token) }
    }

    /// Cancel any armed watchdog (idempotent).
    private func disarmWatchdog() {
        watchdogCancel?()
        watchdogCancel = nil
    }

    /// Append a streamed variant (a one-variant partial outcome carrying the run's
    /// grid metadata) to the growing `outcome`, so the results screen shows the
    /// first optimized variant as soon as it lands (progressive results).
    private func appendStreamed(_ partial: OptimizeOutcome) {
        guard phase == .running else { return }   // ignore ticks after resolve/reset
        disarmWatchdog()                          // a streamed variant is progress
        lastProgressAt = Date()                   // a live signal → freshness cue
        var variants = outcome?.variants ?? []
        variants.append(contentsOf: partial.variants)
        outcome = OptimizeOutcome(
            variants: variants, stoppedOnMargin: false, cancelled: false,
            acceptedCount: variants.count, voxelVolumeMM3: partial.voxelVolumeMM3,
            gridNx: partial.gridNx, gridNy: partial.gridNy, gridNz: partial.gridNz,
            gridOrigin: partial.gridOrigin, spacing: partial.spacing,
            // Carry the remote flag so the live/progressive results screen renders
            // the worker-unavailable fields (mass/stress/flex/playback) as n/a from
            // the first streamed variant, not just after the run resolves (097).
            computedRemotely: partial.computedRemotely)
        // `progress` is deliberately KEPT (handoff 089). Clearing it here bought
        // nothing — the running card yields on `outcome` having variants, not on
        // progress (RunScreen) — and it cost the readout its rung: it forced the
        // readout to latch the last non-nil snapshot in view-local @State, and that
        // latch silently misses the rung whenever this append lands in the SAME
        // runloop turn as the tick before it (SwiftUI then only ever observes
        // nil → nil, `remainingEstimate` never sees a completed rung, and the ETA
        // reads "estimating…" for the rest of an 80-minute run). Holding the last
        // snapshot lets the readout read the model instead of latching a copy.
    }

    /// Request cancellation of the in-flight run (the callback returns `false` on
    /// its next tick; the core returns a cancelled outcome cleanly, M7.0a).
    public func cancel() {
        guard phase == .running else { return }
        disarmWatchdog()
        token.cancel()
    }

    /// Keep the run going in the background: dismiss the progress card (the run
    /// continues on the background queue), take a background-execution assertion,
    /// and arm the completion notification. The workspace shows a re-open chip.
    public func runInBackground() {
        guard phase == .running else { return }
        runningInBackground = true
        isMinimized = true
        notifier.willRunInBackground()
    }

    /// Re-open the full progress card for a minimized in-flight run.
    public func restore() {
        guard phase == .running else { return }
        isMinimized = false
    }

    /// Dismiss a failure sheet back to idle (the workspace stays put so the user
    /// can adjust the load case and retry).
    public func dismissFailure() {
        guard phase == .failed else { return }
        // A stall left the background solve RUNNING (watchdogFired doesn't cancel).
        // Dismissing it — Close, or Try Again which starts a fresh run — abandons that
        // stuck run, so cancel its token now (best-effort; the orphan may never poll).
        if canKeepWaiting { token.cancel() }
        canKeepWaiting = false
        phase = .idle
        failure = nil
    }

    /// Reset after consuming a success (e.g. once M7.8 has taken the outcome).
    public func reset() {
        disarmWatchdog()
        runningRequest = nil
        phase = .idle
        progress = nil
        failure = nil
        canKeepWaiting = false
        outcome = nil
        isStreaming = false
        startedAt = nil
        localSolveStartedAt = nil
        lastProgressAt = nil
        etaEstimator = RunETAEstimator()
        eta = nil
        runningInBackground = false
    }

    // MARK: - Main-thread transitions

    private func publish(_ snapshot: RunProgress) {
        guard phase == .running else { return }   // ignore ticks after cancel/reset
        disarmWatchdog()                          // the run is alive — stand the watchdog down
        let now = Date()
        lastProgressAt = now                      // a live signal → freshness cue
        progress = snapshot
        // Feed the per-iteration ETA estimator with this timestamped event and republish
        // the refined estimate (handoff 111). Both local and remote runs reach here.
        etaEstimator.ingest(RunProgressSample(time: now.timeIntervalSinceReferenceDate,
                                              rung: snapshot.rung, rungCount: snapshot.rungCount,
                                              iteration: snapshot.iteration))
        eta = etaEstimator.eta
    }

    private func finish(_ request: RunRequest, _ token: CancelToken,
                        _ result: Result<OptimizeOutcome, Error>) {
        // Drop a result from a run that is no longer the current one: a reset raced
        // ahead, OR the setup-stall watchdog already failed this run and a fresh run
        // started (its late core return must never clobber the new run).
        guard token === self.token, phase == .running else { return }
        disarmWatchdog()
        runningRequest = nil
        // Resolve the run's DURATION once, here, from the only two honest sources
        // (handoff 134, item 1): a remote outcome already carries the worker's own
        // record; a local run is measured by this process, which is the thing that was
        // solving. A remote run with no worker record gets NO duration — the client's
        // own clock is not a fallback, it is the bug (the "11 hours" a 40-minute solve
        // reported the next morning). `withTiming` never overwrites a carried value.
        let remote = isRemoteRun
        let localTiming = localSolveStartedAt.map {
            RunTiming(solveSeconds: clock().timeIntervalSince($0))
        }
        func stamp(_ o: OptimizeOutcome) -> OptimizeOutcome {
            o.withTiming(o.timing ?? (remote ? nil : localTiming))
        }
        switch result {
        case .success(let o):
            if o.cancelled {
                // The user cancelled. If accepted variants already STREAMED and were
                // shown (progressive results), those are usable output the user was
                // looking at — KEEP them (identical to the mid-run solver-throw case
                // below), so leaving an in-flight run never destroys the variants on
                // screen. Only when nothing was shown does a cancel discard to a clean
                // workspace (a cancel must never open an EMPTY results view).
                if outcome?.variants.contains(where: { $0.accepted }) == true {
                    progress = nil
                    phase = .succeeded
                    // The streamed variants ARE the result the user keeps, so they
                    // keep the run's duration too (the cancel is when it stopped).
                    outcome = outcome.map(stamp)
                } else {
                    outcome = nil
                    phase = .cancelled
                }
            } else if o.acceptedCount == 0 {
                // Nothing strong enough: the terminal rung failed the margin gate.
                outcome = stamp(o)
                let terminal = o.variants.last
                failure = .allRejectedOnMargin(
                    worstMargin: terminal?.worstCaseMargin ?? 0,
                    minFeatureViolations: terminal?.minFeatureViolations ?? 0)
                phase = .failed
            } else {
                outcome = stamp(o)                         // authoritative final
                progress = nil
                phase = .succeeded
            }
        case .failure(let error):
            // A solver error mid-run: keep variants that already streamed + were
            // accepted; otherwise discard and show the failure sheet.
            if outcome?.variants.contains(where: { $0.accepted }) == true {
                progress = nil
                phase = .succeeded
                outcome = outcome.map(stamp)
            } else {
                // Surface the core diagnostic — os_log it first so the reason is in
                // the device log even before the sheet renders, and never leave the
                // sheet blank when the core throw carries no message.
                let raw = (error as? TopOptError)?.message ?? String(describing: error)
                let message = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? RunFailure.unknownSolverError : raw
                diag("run failed: \(message)")
                outcome = nil
                failure = .solver(message)
                phase = .failed
            }
        }
        isStreaming = false
        isMinimized = false   // resolved: let a failure sheet / success surface
        // Fire the completion notification when the app OBSERVED a run finish while
        // the user may not be watching: a backgrounded on-device run (as before), OR
        // a REMOTE run the app was streaming (handoff 121, requirement 5) — whether in
        // the foreground or landed via the cold-launch re-attach. A remote outcome is
        // flagged `computedRemotely`. We skip a user-cancelled remote run (the user
        // just cancelled it themselves — a "cancelled" banner would be noise); a
        // backgrounded local run keeps its prior behaviour unchanged.
        let observedRemoteFinish = (outcome?.computedRemotely ?? false) && phase != .cancelled
        if runningInBackground || observedRemoteFinish {
            notifier.runDidComplete(summary: completionSummary(request))
        }
    }

    private func completionSummary(_ request: RunRequest) -> String {
        switch phase {
        case .succeeded:
            let n = outcome?.acceptedCount ?? 0
            return "\(request.projectName): \(n) variant\(n == 1 ? "" : "s") ready"
        case .cancelled:
            return "\(request.projectName): optimization cancelled"
        case .failed:
            return "\(request.projectName): optimization couldn’t finish"
        default:
            return request.projectName
        }
    }
}

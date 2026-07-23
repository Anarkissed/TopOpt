// RemoteRunner — run the optimizer on a LAN desktop and drive it from the iPad
// (handoff 093, LAN compute offload / STEP 2). It sits BESIDE `RunModel.bridge
// Runner` (the on-device default) and satisfies the SAME `RunModel.Runner`
// contract, so the existing progress readout (PR 107) and streamed-variant path
// (PR 109) work against it unchanged: remote runs surface the exact same
// `progress`/`onVariant` callbacks a local run does.
//
// Local stays the default. Remote is opt-in: construct a `RunModel` with
// `runner: RunModel.remoteRunner(RemoteRunnerConfig(host:port:expectedFingerprint:))`.
// A typed IP/host is enough for v1; mDNS/Bonjour discovery is a later nicety and
// is cross-platform (Avahi on Linux), so nothing here assumes Apple-only.
//
// The remote server is `tools/topopt-worker`, which wraps `topopt-cli`. Because
// STEP 0 made the CLI produce the SAME part the app produces, a remote run
// returns what a local run would have — PROVIDED the worker's core matches the
// app's (see the version-skew guard below).
//
// ── LIVENESS (handoff 101) ─────────────────────────────────────────────────
// The whole point of remote is runs too big for the iPad — a 128³ four-rung run
// is HOURS. So this file must never treat a slow-but-progressing run as a
// failure, and must never destroy the Mac's work. The redesign:
//
//   * NO WALL-CLOCK CEILING. The old `RemoteRunnerConfig.timeout` (a fixed
//     28800s) doubled as the semaphore wait AND URLSession's
//     `timeoutIntervalForResource`, which caps an SSE task's TOTAL lifetime even
//     while data flows. That killed a real 128³ run at exactly 3600s. Gone.
//     Liveness is now PROGRESS-based: an inactivity watchdog, not a clock.
//   * INACTIVITY WATCHDOG. If NO SSE traffic (a typed event OR the worker's
//     keepalive ping) arrives for `inactivityGrace` (~180s), we do NOT fail — we
//     PROBE `GET /jobs/{id}`: `running` → keep waiting; a terminal status →
//     reconnect and drain it; unreachable after retries → fail with a message
//     that says the WORKER became unreachable (and that the Mac keeps solving),
//     never "timed out".
//   * RECONNECT. A dropped/ended events stream is NOT terminal. The worker
//     replays every event from the start on reconnect (handoff 093), so we reopen
//     `/events` with backoff (1,2,4… cap 30s) and DEDUPE the replay by event
//     index (+ variant mesh basename) so progress and variants are never
//     double-emitted.
//   * NEVER CANCEL THE MAC'S JOB except on EXPLICIT USER CANCEL. Watchdog
//     failure, stream loss, app death — the worker keeps solving; its result
//     persists and `/result` works after completion. The DELETE fires ONLY from
//     the user-cancel path.
//   * RE-ATTACH. The active job id + worker address are persisted
//     (`RemoteJobStore`), so a slept/relaunched iPad can reopen `/events` and
//     resume rather than orphaning the Mac's run.
//
// STATUS (handoff 097 — LAN offload Tier 2): this file is COMPILED and exercised
// on the iOS simulator / a macOS test destination against the real worker on
// localhost. It is not covered by the Linux CI host (no Xcode); its verification
// standard is `xcodebuild test` on the package + the `RemoteRunnerE2ETests`
// harness (handoffs 097 + 101).
//
// What comes over the wire (handoff 122 closed most of the old gap):
//   * Each variant's MESH + the scalar report (volume fraction, margins,
//     orientation, stresses, settings) — as before.
//   * NEW: the per-voxel FIELDS container out/fields.bin — von Mises + displacement
//     fields + the voxel mass & support summary — fetched once after the meshes
//     stream (`fetchFields` / `assembleFinalOutcome`). So a remote run now lights up
//     the Stress, Flex and Load-path overlays and shows the voxel mass, identical to
//     a local run. `computedRemotely` stays set (it means "ran on a worker"); the
//     results screen gates each overlay on the field's PRESENCE, so a fetch failure
//     leaves it honestly "computed on Mac" rather than a dead control / fake zero.
//   * STILL Mac-only: the optimization-playback keyframes (not serialised), and the
//     6-component stress tensor (v1 omits it for wire cost → the load→anchor flow
//     sub-mode stays gated). fields.bin is versioned so a later handoff can add them.
//
// 097 review-carry fixes still hold here: `smooth_factor` is sent so remote meshes
// match the local tricubic smoothing; a failed mesh fetch FAILS THE RUN with a
// clear message (never a silent empty part); the authoritative streamed mesh
// basenames drive final assembly (never re-derived from a guessed filename).

import Foundation
import TopOptKit
#if canImport(os)
import os
#endif

/// Where the LAN worker lives, and which core it MUST be running.
public struct RemoteRunnerConfig: Sendable {
    public let host: String
    public let port: Int
    /// The core build fingerprint (git commit) THIS app was built against. The
    /// worker's `/health` fingerprint must equal it or the run is refused — two
    /// cores that differ silently produce different parts (STEP 3d).
    public let expectedFingerprint: String
    /// Inactivity grace (handoff 101). If NO SSE traffic — a typed event OR the
    /// worker's keepalive ping — arrives for this long, the client stops trusting
    /// the stream and PROBES the status endpoint. This is NOT a run ceiling: a
    /// provably-progressing run can take 10+ hours. The default (180s) comfortably
    /// clears the worker's 20s heartbeat even across several missed pings.
    public let inactivityGrace: TimeInterval
    /// Per-request idle timeout for the long-lived events stream. The heartbeat
    /// keeps it fed, so this is generous; the stream task's RESOURCE (total
    /// lifetime) timeout is left effectively unbounded so a 10-hour run is never
    /// capped by the transport.
    public let requestTimeout: TimeInterval
    /// SHORT timeout for the pre-run `/health`, `POST /jobs`, status probes and
    /// artifact fetches — these must FAIL FAST (the offline fast-fail negative
    /// control), never hang.
    public let controlTimeout: TimeInterval

    public init(host: String, port: Int = 8757, expectedFingerprint: String,
                inactivityGrace: TimeInterval = 180,
                requestTimeout: TimeInterval = 120,
                controlTimeout: TimeInterval = 12) {
        self.host = host
        self.port = port
        self.expectedFingerprint = expectedFingerprint
        self.inactivityGrace = inactivityGrace
        self.requestTimeout = requestTimeout
        self.controlTimeout = controlTimeout
    }

    var baseURL: URL { URL(string: "http://\(host):\(port)")! }
}

/// A remote-run failure, mapped to a message the run flow surfaces like any other.
public struct RemoteRunError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// The active remote job, persisted so a slept/relaunched iPad can RE-ATTACH to a
/// run still solving on the Mac instead of orphaning it (handoff 101, requirement
/// 5). Identity is the worker address + the CLI's job id; the fingerprint lets a
/// re-attach re-assert the version guard.
///
/// Handoff 119 (cold-launch re-attach) added three fields the RELAUNCHED app needs
/// to offer the re-attach and land it in the right place — they are ALL OPTIONAL so
/// a record written by a pre-119 build (the `.v1` key is unchanged) still decodes:
///   * `submittedAt` powers the banner's "a run from <time>…" line;
///   * `projectID`/`projectName` let the cold-launch flow reopen the project the run
///     belonged to, so the streamed result lands in the normal workspace→results
///     path rather than an orphaned view.
public struct PersistedRemoteJob: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let fingerprint: String
    public let jobID: String
    /// When the job was SUBMITTED. Preserved across a re-attach re-save so the
    /// banner's age stays truthful. Optional for pre-119 backward compatibility.
    public let submittedAt: Date?
    /// The project the run belongs to, so a cold-launch re-attach reopens it.
    public let projectID: UUID?
    /// The project's display name, for the banner copy. Optional (pre-119 / unknown).
    public let projectName: String?
    public init(host: String, port: Int, fingerprint: String, jobID: String,
                submittedAt: Date? = nil, projectID: UUID? = nil, projectName: String? = nil) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.jobID = jobID
        self.submittedAt = submittedAt
        self.projectID = projectID
        self.projectName = projectName
    }
}

/// MULTI-SLOT store for outstanding remote jobs (UserDefaults). Handoff 121 made
/// the worker human-facing: more than one remote job can be in flight (a queued job
/// behind a running one, or runs from two projects), so a single slot is wrong — a
/// second submit used to OVERWRITE the first, orphaning it (the reproduction
/// incident behind 121). This keeps EVERY outstanding job, keyed by jobID: a submit
/// upserts, a terminal resolution / user dismiss removes just that one, and the
/// others survive.
///
/// Deliberately NOT cleared on a client-side liveness failure (watchdog/unreachable):
/// the Mac keeps solving, so a record must survive for a later re-attach — it is
/// removed only when the WORKER's job is known finished or the user dismisses it.
///
/// A pre-121 record written under the old single-slot key is MIGRATED on first read
/// (the handoff-119 pattern): folded into the multi-slot array exactly once, then
/// the legacy key is dropped.
public enum RemoteJobStore {
    /// Multi-slot key (handoff 121): a JSON array of every outstanding job.
    static let multiKey = "topopt.activeRemoteJobs.v2"
    /// The pre-121 single-slot key. Kept only so an older build's record migrates in.
    static let legacyKey = "topopt.activeRemoteJob.v1"
    /// Back-compat alias — the legacy single-slot location, used by migration tests.
    static let key = legacyKey

    /// Upsert one job: replace any existing record with the same jobID, else append
    /// (newest last). A SECOND submit no longer overwrites the first.
    public static func save(_ job: PersistedRemoteJob, defaults: UserDefaults = .standard) {
        var all = loadAll(defaults: defaults)
        all.removeAll { $0.jobID == job.jobID }
        all.append(job)
        persist(all, defaults: defaults)
    }

    /// Every outstanding remote job (newest last). Migrates a legacy single-slot
    /// record on read: fold it in (dedupe by jobID), rewrite as multi-slot, and drop
    /// the legacy key so the migration happens exactly once.
    public static func loadAll(defaults: UserDefaults = .standard) -> [PersistedRemoteJob] {
        var all: [PersistedRemoteJob] = []
        if let data = defaults.data(forKey: multiKey),
           let arr = try? JSONDecoder().decode([PersistedRemoteJob].self, from: data) {
            all = arr
        }
        if let data = defaults.data(forKey: legacyKey),
           let legacy = try? JSONDecoder().decode(PersistedRemoteJob.self, from: data) {
            if !all.contains(where: { $0.jobID == legacy.jobID }) { all.append(legacy) }
            defaults.removeObject(forKey: legacyKey)
            persist(all, defaults: defaults)
        }
        return all
    }

    /// The most-recently-saved job, or nil. Back-compat for single-job callers.
    public static func load(defaults: UserDefaults = .standard) -> PersistedRemoteJob? {
        loadAll(defaults: defaults).last
    }

    /// Remove just this job (a terminal resolution or a user dismiss); the rest stay.
    public static func remove(jobID: String, defaults: UserDefaults = .standard) {
        var all = loadAll(defaults: defaults)
        let before = all.count
        all.removeAll { $0.jobID == jobID }
        if all.count != before { persist(all, defaults: defaults) }
    }

    /// Clear EVERY record (both keys). The nuclear option; prefer `remove(jobID:)`.
    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: multiKey)
        defaults.removeObject(forKey: legacyKey)
    }

    private static func persist(_ all: [PersistedRemoteJob], defaults: UserDefaults) {
        if all.isEmpty { defaults.removeObject(forKey: multiKey); return }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: multiKey) }
    }
}

public extension RunModel {

    /// Build a `Runner` that offloads the run to a LAN worker. Drop-in beside
    /// `bridgeRunner`; the run flow cannot tell the difference beyond where the
    /// compute happens.
    static func remoteRunner(_ config: RemoteRunnerConfig,
                             defaults: UserDefaults = .standard) -> Runner {
        return { request, progress, onVariant in
            try RemoteRun(config: config, request: request,
                          progress: progress, onVariant: onVariant,
                          defaults: defaults).run()
        }
    }

    /// Build a `Runner` that RE-ATTACHES to a job already running on the worker
    /// (handoff 101, requirement 5): it skips `/health` + `POST /jobs` and streams
    /// the existing job's `/events` (whose replay rebuilds the streamed variants),
    /// then assembles the same final outcome. Used after the iPad slept/relaunched
    /// with a `RemoteJobStore` record.
    static func remoteReattachRunner(_ config: RemoteRunnerConfig, jobID: String,
                                     defaults: UserDefaults = .standard) -> Runner {
        return { request, progress, onVariant in
            try RemoteRun(config: config, request: request,
                          progress: progress, onVariant: onVariant,
                          defaults: defaults, existingJobID: jobID).run()
        }
    }
}

// ---------------------------------------------------------------------------
// One remote run. Synchronous (the Runner contract is `throws -> OptimizeOutcome`
// and RunModel calls it on a background queue), so it drives the event stream via
// URLSession delegate callbacks and blocks the run thread in a poll loop rather
// than adopting async/await.

final class RemoteRun: NSObject, URLSessionDataDelegate {
    private let config: RemoteRunnerConfig
    private let request: RunRequest
    private let progress: (Int, Int, Int) -> Bool
    private let onVariant: (OptimizeOutcome) -> Void
    private let defaults: UserDefaults
    /// Non-nil → re-attach to this existing job (skip health + submit).
    private let existingJobID: String?

    private var jobID: String?

    // MARK: shared state (run thread ⇄ delegate queue) — guarded by `lock`
    private let lock = NSLock()
    /// Instant of the last SSE traffic of ANY kind (event or keepalive ping). The
    /// inactivity watchdog measures against this.
    private var lastActivity = Date()
    /// The current events stream has ended (didCompleteWithError) without a terminal
    /// event — a dropped connection, not a finished run.
    private var streamEnded = false
    /// A terminal event was delivered.
    private var terminal = false
    private var terminalError: String?
    private var terminalCancelled = false
    /// True when the terminal state came from the WORKER (a done/error/cancelled
    /// event) rather than a client-side abort (a mesh-fetch failure). Only a
    /// worker-terminal (or the user cancel) clears the re-attach record — a
    /// client-side failure leaves the Mac's work, and the record, intact.
    private var terminalFromWorker = false
    /// The user cancelled (the progress callback returned false). The ONLY thing
    /// that makes the run DELETE the worker's job.
    private var userCancelled = false
    /// The events task we currently believe is live; a completion from any other
    /// (older, superseded) task is ignored, so a deliberate reconnect never looks
    /// like an unexpected drop.
    private var currentTask: URLSessionTask?
    /// Wakes the run-thread poll loop promptly on any state change.
    private let tick = DispatchSemaphore(value: 0)

    // ── LONG-STREAM RETENTION AUDIT (handoff 119) ──────────────────────────────
    // The incident behind 119: a 7-hour remote run's client was Jetsam-killed, so
    // this path must retain O(1)+O(ladder) across a multi-HOUR stream — NEVER O(events).
    // A 7-hour run emits thousands of `progress` events but only ~4 `variant` events
    // (the ladder). The full inventory of what a live RemoteRun holds:
    //
    //   FIELD            KIND            WHAT / WHY                         BOUND
    //   deliveredCount   Int             dedup high-water mark (event      O(1) — one Int,
    //                                    INDEX, not the body)              not the event log
    //   connIndex        Int             per-connection replay cursor      O(1)
    //   buffer           Data            un-parsed SSE tail; each "\n\n"   O(1 frame) —
    //                                    frame is removed once parsed      drained every frame
    //   lastSeenTask     weak-ish ref    task-identity for replay reset    O(1)
    //   seenMeshes       Set<String>     variant BASENAMES already emitted O(ladder ≈ 4)
    //   streamed         [StreamedVariant] accepted variants' geometry,    O(ladder ≈ 4) —
    //                                    reused by assembleFinalOutcome     NOT per-event
    //   etaEstimator*    (RunModel side) EMA + completedRungIters[]        O(rungs ≈ 4)
    //   outcome*         (RunModel side) accumulated accepted variants     O(ladder ≈ 4)
    //
    // FINDING: dedupe was ALREADY index/basename-based (deliveredCount + seenMeshes) —
    // it never retained full event bodies, so there was no unbounded growth to fix
    // there. The only per-run growth is the accepted-variant MESHES, and those are
    // bounded by the LADDER (≈4), not by run length. DECISION: keep them in memory —
    // the results screen shows every accepted rung SIMULTANEOUSLY for comparison, so
    // no earlier rung is ever "superseded"; disk-backing ≤4 meshes would add fragility
    // for no bounded win. `streamed` and RunModel.outcome each hold a copy of the same
    // ≤4 meshes for the run's life — a known, bounded double-hold, not a leak.
    // The `memoryCheckpoint(rung:)` os_signpost below stamps the live footprint per
    // rung so the NEXT long run PROVES this bound empirically; the synthetic
    // long-stream test (RemoteLongStreamMemoryTests) proves it in CI by asserting the
    // retained collections stay flat across thousands of events.

    // MARK: delegate-queue-only state (URLSession serialises delegate callbacks)
    private var buffer = Data()
    /// Events delivered so far across ALL connections — the dedup high-water mark.
    /// Persists across reconnects (that is the point). An INDEX (Int), never the event
    /// bodies — dedupe stays O(1) across a multi-hour stream (119 retention audit).
    private var deliveredCount = 0
    /// Index within the CURRENT connection's replay; reset when the task changes.
    private var connIndex = 0
    private var lastSeenTask: URLSessionTask?

    /// The AUTHORITATIVE per-variant record built from the VARIANT stream events,
    /// in ladder order: each carries the mesh basename the worker actually wrote
    /// (not a reconstructed guess) and the geometry already fetched for the live
    /// streamed-variant screen. `assembleFinalOutcome` reuses these.
    private struct StreamedVariant {
        let requestedVF: Double
        let achievedVF: Double        // optimizer-achieved (continuous) — report join key
        let printedFraction: Double   // printed/count basis — the savings basis (104)
        let margin: Double
        let accepted: Bool
        let meshName: String
        let vertices: [Float]
        let indices: [Int32]
    }
    /// Guards `streamed` + `seenMeshes`. Held only for the brief append (never
    /// across the mesh network fetch).
    private let streamedLock = NSLock()
    private var streamed: [StreamedVariant] = []
    /// Mesh basenames already emitted — a belt-and-suspenders guard so a replayed
    /// variant is never double-emitted even if the index dedup ever misaligns
    /// (handoff 101: "variants are already recorded by mesh basename — reuse that").
    private var seenMeshes: Set<String> = []

    #if canImport(os)
    private static let log = Logger(subsystem: "app.topopt", category: "remote")
    /// Per-rung memory checkpoint (handoff 119). Emitted as a signpost EVENT so a
    /// long run traced in Instruments shows retained-footprint markers at each rung
    /// boundary — the empirical proof that long-stream retention stays bounded.
    private static let memoryLog = Logger(subsystem: "app.topopt", category: "remote-memory")
    private static let signposter = OSSignposter(logger: memoryLog)
    #endif

    /// Probe retries before declaring the worker unreachable, and the reconnect
    /// backoff schedule (seconds): 1, 2, 4, … capped at 30.
    private let maxProbeFailures = 3
    private let backoffCap: TimeInterval = 30

    init(config: RemoteRunnerConfig, request: RunRequest,
         progress: @escaping (Int, Int, Int) -> Bool,
         onVariant: @escaping (OptimizeOutcome) -> Void,
         defaults: UserDefaults = .standard,
         existingJobID: String? = nil) {
        self.config = config
        self.request = request
        self.progress = progress
        self.onVariant = onVariant
        self.defaults = defaults
        self.existingJobID = existingJobID
    }

    // MARK: run

    func run() throws -> OptimizeOutcome {
        if let existing = existingJobID {
            // RE-ATTACH path: the job already exists on the worker. Skip the
            // version guard + submit; the worker's replay rebuilds progress and
            // variants. (The persisted record already passed the guard at submit.)
            jobID = existing
        } else {
            // 1) VERSION-SKEW GUARD (STEP 3d). Refuse a worker whose core differs
            //    from ours BEFORE running — a silent core mismatch is a different
            //    product. Uses the SHORT control timeout: an offline worker here is
            //    the fast-fail negative control, not a hang.
            let health = try getJSON(config.baseURL.appendingPathComponent("health"))
            let fp = (health["fingerprint"] as? String) ?? "unknown"
            guard fp == config.expectedFingerprint else {
                throw RemoteRunError(
                    "worker core mismatch: worker \(fp), app \(config.expectedFingerprint). " +
                    "Refusing to run — a different core produces a different part. " +
                    "Rebuild the worker's topopt-cli from the same commit.")
            }

            // 2) SUBMIT: POST the STEP/STL + a job.json built from the request.
            let jobJSON = try buildJobJSON()
            let modelData = try Data(contentsOf: URL(fileURLWithPath: request.modelPath))
            let modelName = (request.modelPath as NSString).lastPathComponent
            jobID = try postJob(model: modelData, modelName: modelName, jobJSON: jobJSON)
        }

        // Persist the active job so a slept/relaunched iPad can re-attach rather
        // than orphan the Mac's run (requirement 5). Cleared ONLY on a terminal
        // resolution or user cancel — never on a client-side liveness failure.
        // Carries the 119 banner/routing metadata (submit time + project). On a
        // RE-ATTACH we PRESERVE the original submit time from the stored record so
        // the banner's "run from <time>" never resets to "now"; a fresh submit
        // stamps the current time.
        if let id = jobID {
            // Look the prior record up BY JOB ID (handoff 134). `RemoteJobStore.load`
            // returns the most-recently-saved record, which since the multi-slot store
            // (121) is not necessarily THIS job — re-attaching to an older job while a
            // newer one was outstanding stamped the newer job's submit time onto it,
            // and the banner then reported the wrong age. Same class of bug as the
            // duration this handoff fixes: a time that describes a different object.
            let priorSubmit = existingJobID.flatMap { existing in
                RemoteJobStore.loadAll(defaults: defaults)
                    .first { $0.jobID == existing }?.submittedAt
            }
            RemoteJobStore.save(PersistedRemoteJob(host: config.host, port: config.port,
                                                   fingerprint: config.expectedFingerprint,
                                                   jobID: id,
                                                   submittedAt: priorSubmit ?? Date(),
                                                   projectID: request.projectID,
                                                   projectName: request.projectName),
                                defaults: defaults)
        }

        // 3) STREAM events, driven by the progress-based liveness loop (no clock).
        markActivity()
        openConnection()
        return try driveEvents()
    }

    // MARK: - liveness loop

    /// The progress-based run loop (handoff 101). Polls ~1s; resolves on a terminal
    /// event / user cancel; on a dropped OR silent stream, PROBES the worker and
    /// reconnects (never kills its job); fails ONLY when the worker is unreachable
    /// after retries — with a worker-unreachable message, and WITHOUT a DELETE.
    private func driveEvents() throws -> OptimizeOutcome {
        var backoff: TimeInterval = 1
        var probeFailures = 0
        var nextAttempt = Date.distantPast   // first recovery attempt is immediate

        while true {
            _ = tick.wait(timeout: .now() + 1.0)

            lock.lock()
            let uc = userCancelled
            let te = terminalError
            let tc = terminalCancelled
            let tm = terminal
            let ended = streamEnded
            let last = lastActivity
            let fromWorker = terminalFromWorker
            lock.unlock()

            // Terminal / cancel — checked every tick so cancel stays responsive.
            if uc {
                // The ONLY place a non-terminal DELETE fires: an explicit user cancel.
                cancelRemote()
                clearOwnRecord()
                return cancelledOutcome()
            }
            if let te = te {
                // A worker-reported error is a real terminal outcome (job done on
                // the worker) → clear THIS run's re-attach record. A CLIENT-side abort
                // (a mesh-fetch failure via failStream) leaves the Mac's work + the
                // record intact, so a later attempt can still re-attach.
                if fromWorker { clearOwnRecord() }
                throw RemoteRunError(te)
            }
            if tc {
                clearOwnRecord()
                return cancelledOutcome()
            }
            if tm {
                let outcome = try assembleFinalOutcome()
                clearOwnRecord()
                return outcome
            }

            let stale = Date().timeIntervalSince(last) > config.inactivityGrace
            if ended || stale {
                if Date() < nextAttempt { continue }   // waiting out the backoff

                if probeStatus() != nil {
                    // The worker answered — it is alive. This is where the worker's
                    // queued/solving STATE is consumed (handoff 129): a `queued`,
                    // `running` (or even a just-finished) status is a reachable worker,
                    // so we KEEP WAITING and reconnect — a queue wait or a long first
                    // solve holds fire indefinitely, never a client-side false failure.
                    // Reopen the events stream; the replay rebuilds progress +
                    // variants (deduped) and delivers any terminal event we missed.
                    probeFailures = 0
                    diag("remote stream \(ended ? "dropped" : "went silent") — worker reachable, reconnecting")
                    openConnection()
                } else {
                    probeFailures += 1
                    if probeFailures >= maxProbeFailures {
                        // NEVER a DELETE. The Mac may still be solving; its result
                        // persists and /result works after it finishes. Leave the
                        // re-attach record in place so a later attempt can resume.
                        diag("remote worker unreachable after \(probeFailures) probes — failing WITHOUT cancelling the Mac's job")
                        throw RemoteRunError(Self.workerUnreachableMessage)
                    }
                    diag("remote status probe failed (\(probeFailures)/\(maxProbeFailures)) — retrying, not failing yet")
                }
                nextAttempt = Date().addingTimeInterval(backoff)
                backoff = Swift.min(backoff * 2, backoffCap)
            } else {
                // Healthy (fresh traffic, stream open): reset the recovery schedule.
                backoff = 1
                probeFailures = 0
                nextAttempt = Date.distantPast
            }
        }
    }

    static let workerUnreachableMessage =
        "The Mac worker became unreachable, so this run can’t be followed from the "
      + "iPad any more. This is NOT a timeout — the run was not stopped: the Mac "
      + "keeps solving and its result is saved on the Mac, available when it "
      + "finishes. Check the Mac and your Wi-Fi, then reconnect."

    private func cancelledOutcome() -> OptimizeOutcome {
        OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: true,
                        acceptedCount: 0, computedRemotely: true)
    }

    /// Remove ONLY this run's record from the multi-slot store (handoff 121): a
    /// terminal resolution or user cancel clears this job while leaving any other
    /// outstanding remote jobs (a queued sibling, another project's run) intact.
    private func clearOwnRecord() {
        if let id = jobID { RemoteJobStore.remove(jobID: id, defaults: defaults) }
    }

    private func markActivity() {
        lock.lock(); lastActivity = Date(); lock.unlock()
    }

    private func diag(_ message: String) {
        #if canImport(os)
        Self.log.log("\(message, privacy: .public)")
        #endif
    }

    // MARK: request -> job.json

    /// Export smoothing the CLI must apply so a remote mesh matches what the app's
    /// local bridge produces. MUST equal the bridge's `kSmoothExportFactor`
    /// (bridge.cpp). Kept as a documented mirror (Swift can't read the C++
    /// constexpr); if the bridge factor changes, change this with it.
    static let smoothExportFactor = 2

    private func buildJobJSON() throws -> Data {
        var job: [String: Any] = [
            "model": (request.modelPath as NSString).lastPathComponent,
            "material": request.material,
            "mode": "minimize_plastic",
            "resolution": request.resolution,
            "output": ["report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant",
                       "smooth_factor": Self.smoothExportFactor],
        ]
        // The human-facing project name is NOT put in job.json (handoff 129): it is a
        // worker-level label, not a physics input, and the CLI's job schema is strict
        // (`reject_unknown_keys` — a stray "project" key fails the run ON A DEVICE). It
        // travels as a dedicated MULTIPART FIELD instead (see `postJob`), which the
        // worker already prefers; the worker's job.json strip stays as belt-and-
        // suspenders for older clients. So job.json here contains only the physics.
        if let box = request.designBox {
            job["design_box"] = ["min": [box.min.x, box.min.y, box.min.z],
                                 "max": [box.max.x, box.max.y, box.max.z]]
            if !request.keepOutBoxes.isEmpty {
                job["keep_outs"] = request.keepOutBoxes.map {
                    ["min": [$0.min.x, $0.min.y, $0.min.z],
                     "max": [$0.max.x, $0.max.y, $0.max.z]]
                }
            }
        }
        if request.isStepModel {
            var loads: [String: Any] = [
                "minimize_plastic": request.minimizePlastic,
                "build_dir": [request.buildDirection.x, request.buildDirection.y,
                              request.buildDirection.z],
            ]
            if !request.anchorFaceIDs.isEmpty {
                loads["anchor_face_ids"] = request.anchorFaceIDs
            }
            if !request.loadGroups.isEmpty {
                loads["groups"] = request.loadGroups.map { g -> [String: Any] in
                    ["face_ids": g.faceIDs,
                     "force": [g.force.x, g.force.y, g.force.z]]
                }
            }
            if request.infillPercent >= 0 {
                loads["infill_percent"] = request.infillPercent
            }
            if !request.clearances.isEmpty {
                loads["clearances"] = request.clearances.map { c -> [String: Any] in
                    var entry: [String: Any] = [
                        "face_id": c.faceID,
                        "kind": c.kind == .face ? "face" : "bolt",
                    ]
                    if c.concentricMarginMM > 0 { entry["concentric_margin_mm"] = c.concentricMarginMM }
                    if c.axialClearanceMM > 0 { entry["axial_clearance_mm"] = c.axialClearanceMM }
                    if c.slabDepthMM > 0 { entry["slab_depth_mm"] = c.slabDepthMM }
                    return entry
                }
            }
            // Handoff 124 — Face protections (preserve-skin): the raw face ids + the
            // ONE global depth. The worker's build_production_loadcase freezes each
            // face's part-solid skin FrozenSolid, identically to the local bridge
            // path. Empty list → omitted → byte-identical to a pre-124 job.
            if !request.faceProtections.isEmpty {
                loads["face_protections"] = request.faceProtections
                if request.faceProtectionDepthMM > 0 {
                    loads["face_protection_depth_mm"] = request.faceProtectionDepthMM
                }
            }
            job["loads"] = loads
        } else {
            job["loads"] = ["build_dir": [0, 0, 1]]
        }
        return try JSONSerialization.data(withJSONObject: job)
    }

    // MARK: HTTP sessions

    /// The long-lived events stream. Idle (request) timeout is generous — the
    /// worker heartbeat keeps it fed; the RESOURCE (total lifetime) timeout is left
    /// effectively unbounded so a 10-hour run is NEVER capped by the transport
    /// (the 3600s incident was exactly this cap).
    private lazy var eventSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = config.requestTimeout
        cfg.timeoutIntervalForResource = 60 * 60 * 24 * 365   // ~unbounded
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// SHORT-timeout session for /health, POST /jobs, status probes and artifact
    /// fetches — the offline fast-fail path. Idle timeout is the control timeout;
    /// the resource timeout is bounded but larger so a mesh transfer isn't clipped.
    private lazy var controlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = config.controlTimeout
        cfg.timeoutIntervalForResource = Swift.max(config.controlTimeout, config.requestTimeout)
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private func getJSON(_ url: URL) throws -> [String: Any] {
        let (data, resp) = try syncGET(url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RemoteRunError("unexpected response from \(url.path)") }
        return obj
    }

    private func syncGET(_ url: URL) throws -> (Data, URLResponse) {
        var out: (Data, URLResponse)?
        var err: Error?
        let sem = DispatchSemaphore(value: 0)
        controlSession.dataTask(with: url) { d, r, e in
            if let d = d, let r = r { out = (d, r) } else { err = e }
            sem.signal()
        }.resume()
        sem.wait()
        if let out = out { return out }
        throw RemoteRunError("request failed: \(url.path): \(err?.localizedDescription ?? "no response")")
    }

    /// Probe the status endpoint (handoff 101). Returns the worker's job status
    /// string ("running"/"done"/"error"/"cancelled") when REACHABLE, or nil when
    /// the worker could not be reached — the sole signal that turns a stalled
    /// stream into a run failure. Uses the short control timeout so it fails fast.
    private func probeStatus() -> String? {
        guard let id = jobID else { return nil }
        let url = config.baseURL.appendingPathComponent("jobs").appendingPathComponent(id)
        guard let obj = try? getJSON(url) else { return nil }
        return obj["status"] as? String
    }

    /// Fetch one variant's exported mesh by basename and parse it. THROWS on any
    /// failure (transport error, non-200, or a body that is not a usable STL) —
    /// a missing/corrupt mesh must surface as a run failure, never as a silently-
    /// empty part that renders as a plausible-but-wrong blank result.
    private func fetchMesh(named name: String) throws -> ([Float], [Int32]) {
        guard let id = jobID else { throw RemoteRunError("no job id for mesh \(name)") }
        let url = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
            .appendingPathComponent(name)
        let (data, resp) = try syncGET(url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw RemoteRunError("could not fetch variant mesh \"\(name)\" from the " +
                "worker (HTTP \(code)). The run produced a result on the Mac but its " +
                "geometry could not be transferred — not showing an empty part.")
        }
        let mesh = parseBinarySTL(data)
        guard !mesh.0.isEmpty, !mesh.1.isEmpty else {
            throw RemoteRunError("variant mesh \"\(name)\" arrived empty or unreadable " +
                "(\(data.count) bytes) — not showing an empty part.")
        }
        return mesh
    }

    /// Fetch + parse the run's per-voxel result FIELDS container (handoff 122),
    /// written by the CLI to out/fields.bin at run end and served by the SAME
    /// `/files/{name}` route the meshes use (no protocol change). Returns nil on
    /// ANY failure — a missing file (a pre-122 worker), a transport error, or an
    /// unparseable body — because the fields are ENRICHMENT: without them the run
    /// still shows geometry + margins and the overlays stay honestly gated ("computed
    /// on Mac"). A fields failure must never fail the run the way a missing MESH does
    /// (fetchMesh throws; this does not). Called once after the meshes have already
    /// streamed, so progressive results stay progressive.
    private func fetchFields() -> RemoteFieldsContainer? {
        guard let id = jobID else { return nil }
        let url = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
            .appendingPathComponent("fields.bin")
        // Say WHICH failure this was (handoff 134). "n/a — computed on Mac" is only
        // honest when the fields are genuinely absent; a 404 (a pre-122 worker, or a
        // run whose CLI never wrote one), a transport error, and a truncated body are
        // three different stories, and the device QA for the re-attach repro has to be
        // able to tell them apart from the Console instead of guessing.
        guard let (data, resp) = try? syncGET(url) else {
            diag("remote fields.bin fetch failed (transport) — overlays stay computed-on-Mac")
            return nil
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            diag("remote fields.bin unavailable (HTTP \(code)) — overlays stay computed-on-Mac")
            return nil
        }
        guard let container = RemoteFieldsContainer.parse(data) else {
            diag("remote fields.bin unreadable (\(data.count) bytes) — overlays stay computed-on-Mac")
            return nil
        }
        diag("remote fields.bin fetched: \(data.count) bytes, \(container.variants.count) variant block(s)")
        return container
    }

    /// Read the WORKER's own record of when this job was created, promoted and
    /// finished (`GET /jobs/{id}`, handoff 121 timestamps) and turn it into the run's
    /// `RunTiming` (handoff 134, item 1).
    ///
    /// This is the ONLY honest source for a remote run's duration: the client may have
    /// been asleep, force-quit, or re-attached hours later, so anything the CLIENT
    /// measures describes the observer, not the run. That is precisely how a 40m53s
    /// solve came to be reported as "11 hours" the next morning. Best-effort like
    /// `fetchFields` — a nil simply means no duration is shown (never a guess).
    private func fetchTiming() -> RunTiming? {
        guard let id = jobID else { return nil }
        let url = config.baseURL.appendingPathComponent("jobs").appendingPathComponent(id)
        guard let obj = try? getJSON(url) else {
            diag("remote job record unavailable — no run duration shown for this run")
            return nil
        }
        let t = RunTiming.fromWorker(createdAt: obj["created_at"] as? Double,
                                     startedAt: obj["started_at"] as? Double,
                                     finishedAt: obj["finished_at"] as? Double)
        if t == nil { diag("worker reported no finish time — no run duration shown") }
        return t
    }

    private func postJob(model: Data, modelName: String, jobJSON: Data) throws -> String {
        let boundary = "topopt-\(UUID().uuidString)"
        var body = Data()
        func part(_ headers: String, _ payload: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(headers.data(using: .utf8)!)
            body.append("\r\n\r\n".data(using: .utf8)!)
            body.append(payload)
            body.append("\r\n".data(using: .utf8)!)
        }
        part("Content-Disposition: form-data; name=\"step\"; filename=\"\(modelName)\"\r\n" +
             "Content-Type: application/octet-stream", model)
        part("Content-Disposition: form-data; name=\"job\"; filename=\"job.json\"\r\n" +
             "Content-Type: application/json", jobJSON)
        // The human-facing project name as a dedicated multipart FIELD (handoff 129).
        // The worker prefers this over any job.json key (topopt_worker._create_job) and
        // it never reaches the CLI's strict job schema. Omitted when empty.
        let projectName = request.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !projectName.isEmpty {
            part("Content-Disposition: form-data; name=\"project\"", Data(projectName.utf8))
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: config.baseURL.appendingPathComponent("jobs"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        var out: Data?; var err: Error?
        let sem = DispatchSemaphore(value: 0)
        controlSession.dataTask(with: req) { d, _, e in out = d; err = e; sem.signal() }.resume()
        sem.wait()
        guard let data = out,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["job_id"] as? String
        else { throw RemoteRunError("submit failed: \(err?.localizedDescription ?? "no job_id")") }
        return id
    }

    /// Open (or reopen) the events stream. Supersedes any current task — a
    /// completion from the old one is then ignored, so a deliberate reconnect never
    /// looks like an unexpected drop. Clears the ended flag + refreshes activity so
    /// the loop treats the fresh connection as alive.
    private func openConnection() {
        guard let id = jobID else { return }
        let url = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("events")
        let task = eventSession.dataTask(with: url)
        lock.lock()
        let old = currentTask
        currentTask = task
        streamEnded = false
        lastActivity = Date()
        lock.unlock()
        old?.cancel()
        task.resume()
    }

    /// Cancel the worker's job — the DELETE. Called ONLY from the explicit
    /// user-cancel path (handoff 101, requirement 4).
    private func cancelRemote() {
        guard let id = jobID else { return }
        var req = URLRequest(url: config.baseURL.appendingPathComponent("jobs").appendingPathComponent(id))
        req.httpMethod = "DELETE"
        controlSession.dataTask(with: req).resume()
    }

    // MARK: SSE parsing (URLSessionDataDelegate)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // A new connection's replay starts over — reset the per-connection index +
        // buffer. All of this runs on URLSession's serial delegate queue, so
        // `connIndex`/`deliveredCount`/`buffer` need no lock.
        if dataTask !== lastSeenTask {
            lastSeenTask = dataTask
            connIndex = 0
            buffer = Data()
        }
        // ANY bytes — a typed event OR a ": ping" keepalive comment — are liveness.
        markActivity()

        buffer.append(data)
        // SSE frames are separated by a blank line. A frame's `data:` line is JSON;
        // a `:`-prefixed comment line (the heartbeat) carries no `data:` and is
        // skipped here — it already did its job by refreshing `lastActivity` above.
        while let range = buffer.range(of: Data("\n\n".utf8)) {
            let frame = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let text = String(data: frame, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("data: ") {
                // DEDUPE the replay by event index: the worker replays every event
                // from index 0 on each (re)connect, so anything at or below the
                // high-water mark was already delivered.
                let isReplay = connIndex < deliveredCount
                connIndex += 1
                if isReplay { continue }
                deliveredCount = connIndex          // == old high-water + 1
                handleEvent(String(line.dropFirst(6)))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The stream closed. If this is the CURRENT task and we never saw a terminal
        // event, it is a dropped connection (not a finished run) — record it so the
        // liveness loop probes + reconnects. A completion from a superseded task (a
        // deliberate reconnect) is ignored. A run that finished already set `terminal`.
        lock.lock()
        if task === currentTask && !terminal {
            streamEnded = true
        }
        lock.unlock()
        tick.signal()
    }

    private func handleEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = ev["type"] as? String else { return }
        switch type {
        case "progress":
            let rung = ev["rung"] as? Int ?? 0
            let rungs = ev["rungs"] as? Int ?? 0
            let iter = ev["iter"] as? Int ?? 0
            // The keep-going decision drives cancellation exactly like local runs.
            // A false return is an EXPLICIT user cancel → record it; the run loop
            // (not here) issues the single DELETE.
            if !progress(rung, rungs, iter) {
                lock.lock(); userCancelled = true; lock.unlock()
                tick.signal()
            }
        case "ping":
            break   // a typed keepalive, if a worker ever sends one; liveness only
        case "variant":
            emitStreamedVariant(ev)
        case "done":
            lock.lock(); terminal = true; terminalFromWorker = true; lock.unlock()
            tick.signal()
        case "cancelled":
            lock.lock()
            terminalCancelled = true; terminal = true; terminalFromWorker = true
            lock.unlock()
            tick.signal()
        case "error":
            lock.lock()
            terminalError = (ev["message"] as? String) ?? "remote run failed"
            terminal = true; terminalFromWorker = true
            lock.unlock()
            tick.signal()
        default:
            break  // log lines: ignored for the outcome
        }
    }

    // MARK: outcome assembly

    /// Progressive result: a variant finished on the worker (and its mesh is
    /// already written). Fetch the mesh + build a one-variant OptimizeOutcome and
    /// hand it to `onVariant`, so PR 109's streamed-variant screen grows live.
    private func emitStreamedVariant(_ ev: [String: Any]) {
        guard let meshName = ev["mesh"] as? String, !meshName.isEmpty else {
            failStream("worker reported a completed variant without a mesh file")
            return
        }
        // Variant-basename dedup (handoff 101): a replayed variant we already
        // emitted must never fire `onVariant` twice or double-count. The index
        // dedup above already prevents this on a clean replay; this is the explicit
        // second guard the task asks for.
        streamedLock.lock()
        let already = seenMeshes.contains(meshName)
        if !already { seenMeshes.insert(meshName) }
        streamedLock.unlock()
        if already { return }

        let mesh: ([Float], [Int32])
        do {
            mesh = try fetchMesh(named: meshName)
        } catch {
            failStream((error as? RemoteRunError)?.message ?? "\(error)")
            return
        }
        let requestedVF = ev["vf"] as? Double ?? 0
        let achievedVF = ev["achieved"] as? Double ?? 0
        // Handoff 104: the app's savings uses the printed/count basis (`printed`);
        // fall back to `achieved` if a pre-104 worker omitted it.
        let printedVF = ev["printed"] as? Double ?? achievedVF
        let margin = ev["margin"] as? Double ?? 0
        let accepted = (ev["accepted"] as? Bool) ?? true
        streamedLock.lock()
        streamed.append(StreamedVariant(requestedVF: requestedVF, achievedVF: achievedVF,
                                        printedFraction: printedVF,
                                        margin: margin, accepted: accepted,
                                        meshName: meshName,
                                        vertices: mesh.0, indices: mesh.1))
        streamedLock.unlock()
        // Stamp the live retained footprint at this rung boundary (119 retention
        // audit) so a long run measures its own bound.
        memoryCheckpoint(rung: ev["rung"] as? Int ?? streamedCount)
        let v = OptimizeVariant(
            requestedVolumeFraction: requestedVF,
            // achievedVolumeFraction is the app's savings basis (= printed/count);
            // printedFraction names it. (The continuous achievedVF is the report join
            // key, kept in StreamedVariant.)
            achievedVolumeFraction: printedVF,
            printedFraction: printedVF,
            massGrams: 0,                 // not emitted by the CLI (see file header)
            supportVolumeVoxels: 0,       // not emitted by the CLI
            meshTriangleCount: mesh.1.count / 3,
            worstCaseMargin: margin,
            accepted: accepted,
            v3Passes: true,
            meshVertices: mesh.0, meshIndices: mesh.1)
        onVariant(OptimizeOutcome(variants: [v], stoppedOnMargin: false,
                                  cancelled: false, acceptedCount: 1,
                                  computedRemotely: true))
    }

    /// Abort the run with a diagnostic (used when a streamed mesh can't be fetched).
    /// Records a terminal error and wakes the loop. Handoff 101, requirement 4: it
    /// does NOT DELETE the worker's job — a mesh-transfer failure on the client must
    /// not destroy the Mac's solve; the result persists and /result still works.
    private func failStream(_ message: String) {
        lock.lock()
        if !terminal {
            terminalError = message
            terminal = true
        }
        lock.unlock()
        tick.signal()
    }

    /// Build the authoritative final outcome from report.json + the meshes ALREADY
    /// fetched during streaming, ENRICHED with the per-voxel fields (handoff 122):
    /// after the meshes have streamed, fetch out/fields.bin ONCE and splice each
    /// accepted variant's von Mises / displacement fields + voxel mass & support,
    /// and carry the run's grid metadata so the results screen can index them. The
    /// mesh geometry comes from the recorded streamed variants (never re-derive a
    /// filename); the scalar report supplies margins/orientation. Still flagged
    /// `computedRemotely` (the flag now means "computed on a worker", not "fields
    /// unavailable" — ResultsModel gates each overlay on the field's PRESENCE). When
    /// fields.bin can't be fetched (a pre-122 worker, a transport error), `fields` is
    /// nil and the overlays stay honestly gated, exactly as before this handoff.
    private func assembleFinalOutcome() throws -> OptimizeOutcome {
        guard let id = jobID else { throw RemoteRunError("no job id") }
        let base = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
        let report = try getJSON(base.appendingPathComponent("report.json"))
        let reportVariants = report["variants"] as? [[String: Any]] ?? []

        // Per-voxel fields (best-effort; nil leaves the overlays gated).
        // BOTH the live-completion path and the RE-ATTACH path reach here — this is
        // the single assembly point, so a run whose client force-quit and re-attached
        // the next morning fetches exactly the same fields.bin, with the same presence
        // gate and the same graceful degradation (handoff 134, item 2).
        let fields = fetchFields()
        // The worker's own duration record (handoff 134, item 1) — never the client's
        // wall clock, which on a re-attach measures when someone looked, not the run.
        let timing = fetchTiming()

        streamedLock.lock(); let accepted = streamed; streamedLock.unlock()

        // Join a report variant to a streamed (accepted) one by the OPTIMIZER-ACHIEVED
        // (continuous) volume fraction: the stream carries only accepted variants, the
        // report the whole ladder, so an index join would misalign. The VARIANT event's
        // `achieved` and the report's `volume_fraction` are the same quantity
        // (v.optimization.volume_fraction), so they match to float tolerance. (The
        // savings basis — `printed`/`printed_fraction` — is read separately in
        // makeVariant; it is NOT the join key. Handoff 104.)
        func reportVariant(forAchieved vf: Double) -> [String: Any]? {
            var best: [String: Any]?
            var bestErr = 1e-4      // require a real match, don't grab the nearest
            for rv in reportVariants {
                let rvf = rv["volume_fraction"] as? Double ?? .infinity
                let e = abs(rvf - vf)
                if e < bestErr { bestErr = e; best = rv }
            }
            return best
        }

        if !accepted.isEmpty {
            let variants = accepted.map { s in
                makeVariant(streamed: s,
                            report: reportVariant(forAchieved: s.achievedVF),
                            fields: fields?.variant(forRequestedVF: s.requestedVF))
            }
            return remoteOutcome(variants: variants, acceptedCount: variants.count,
                                 fields: fields, timing: timing)
        }

        // No accepted variant streamed: report-only rows. They carry no mesh, so they
        // are joined to the fields by the report's own requested VF when it has one —
        // a rejected rung has no overlay to light up, but the run's grid + duration
        // still ride along on the outcome below.
        let rejected = reportVariants.map { makeVariant(streamed: nil, report: $0, fields: nil) }
        return remoteOutcome(variants: rejected, acceptedCount: 0, fields: fields,
                             timing: timing)
    }

    /// Wrap remote variants in an OptimizeOutcome, carrying the run's grid metadata
    /// from fields.bin when present (0 otherwise). The overlays need the grid dims to
    /// index a variant's von Mises / displacement field, so without fields.bin they
    /// stay `isEmpty` (gated) even if — hypothetically — a variant carried arrays.
    private func remoteOutcome(variants: [OptimizeVariant], acceptedCount: Int,
                               fields: RemoteFieldsContainer?,
                               timing: RunTiming? = nil) -> OptimizeOutcome {
        OptimizeOutcome(variants: variants, stoppedOnMargin: false, cancelled: false,
                        acceptedCount: acceptedCount,
                        voxelVolumeMM3: fields?.voxelVolumeMM3 ?? 0,
                        gridNx: fields?.gridNx ?? 0, gridNy: fields?.gridNy ?? 0,
                        gridNz: fields?.gridNz ?? 0,
                        gridOrigin: fields?.gridOrigin ?? .zero,
                        spacing: fields?.spacing ?? 0,
                        computedRemotely: true,
                        timing: timing)
    }

    private func makeVariant(streamed s: StreamedVariant?,
                             report rv: [String: Any]?,
                             fields f: RemoteFieldsContainer.Variant?) -> OptimizeVariant {
        let margin = rv?["margin"] as? [String: Any]
        let orient = rv?["orientation"] as? [String: Any]
        // Savings/count basis (handoff 104): the app's savings is 1 - achievedVolume-
        // Fraction, which must stay the PRINTED/count basis. Prefer the streamed
        // printed fraction, else the report's printed_fraction, falling back to the
        // report's volume_fraction only for a pre-104 report that lacks the field.
        let printedVF = s?.printedFraction
            ?? (rv?["printed_fraction"] as? Double)
            ?? (rv?["volume_fraction"] as? Double ?? 0)
        let worst = (margin?["worst_case"] as? Double) ?? (s?.margin) ?? 0
        return OptimizeVariant(
            requestedVolumeFraction: s?.requestedVF ?? printedVF,
            achievedVolumeFraction: printedVF,
            printedFraction: printedVF,
            // Mass + support now come over the wire in fields.bin (handoff 122) when
            // present; 0 when it wasn't fetched (a pre-122 worker / a fetch failure),
            // which ResultsModel renders as n/a — never a plausible-but-wrong 0 g.
            massGrams: f?.massGrams ?? 0,
            supportVolumeVoxels: f?.supportVolumeVoxels ?? 0,
            meshTriangleCount: (s?.indices.count ?? 0) / 3,
            worstCaseMargin: worst,
            accepted: s != nil, v3Passes: true,
            minFeatureViolations: rv?["min_feature_violations"] as? Int ?? 0,
            minFeatureWarning: rv?["min_feature_warning"] as? String ?? "",
            orientation: SIMD3(orient?["x"] as? Double ?? 0,
                               orient?["y"] as? Double ?? 0,
                               orient?["z"] as? Double ?? 1),
            maxStressMPa: rv?["max_stress_mpa"] as? Double ?? 0,
            maxInterlayerTensionMPa: rv?["max_interlayer_tension_mpa"] as? Double ?? 0,
            inPlaneMargin: (margin?["in_plane"] as? Double) ?? 0,
            interlayerMargin: (margin?["interlayer"] as? Double) ?? 0,
            meshVertices: s?.vertices ?? [], meshIndices: s?.indices ?? [],
            // The per-voxel fields the results overlays consume (handoff 122). Empty
            // when fields.bin wasn't fetched → the overlays stay honestly gated. v1
            // does not serialise the 6-component tensor (wire cost), so the load→
            // anchor flow sub-mode stays Mac-only; stress/flex/load-path light up.
            vonMisesField: f?.vonMises ?? [],
            displacementField: f?.displacement ?? [],
            stressTensorField: f?.stressTensor ?? [])
    }

    /// Minimal binary-STL reader → (interleaved xyz floats, triangle-soup indices).
    /// The mesh is unindexed (STL has no shared vertices); fine for display. Shares
    /// the exact reader `MeshExport` writes against, so the app's STL export round-
    /// trips through the same parse the remote mesh path relies on.
    private func parseBinarySTL(_ data: Data) -> ([Float], [Int32]) {
        MeshExport.parseBinarySTL(data)
    }

    // MARK: - long-stream memory checkpoint (handoff 119)

    /// The number of accepted variant meshes currently retained (delegate-queue read;
    /// guarded because the run thread's `assembleFinalOutcome` also reads `streamed`).
    private var streamedCount: Int {
        streamedLock.lock(); defer { streamedLock.unlock() }; return streamed.count
    }

    /// Stamp the process's retained footprint + this run's own retained sizes at a
    /// rung boundary (handoff 119). Emits an os_signpost EVENT (so an Instruments
    /// trace of a long run shows per-rung memory markers) and an os_log line (so the
    /// device Console shows the same without a trace). The point is empirical proof,
    /// on the NEXT real long run, that retention is bounded by the ladder — see the
    /// retention-audit block above.
    private func memoryCheckpoint(rung: Int) {
        let footprintMB = Self.residentFootprintBytes() / 1_000_000
        streamedLock.lock()
        let variants = streamed.count
        // Total mesh scalars held across all accepted variants (vertices + indices) —
        // the dominant per-variant cost; bounded by the ladder, not the event count.
        let meshScalars = streamed.reduce(0) { $0 + $1.vertices.count + $1.indices.count }
        let basenames = seenMeshes.count
        streamedLock.unlock()
        let delivered = deliveredCount   // local (the signpost message is an autoclosure)
        #if canImport(os)
        // A single interpolated literal — os_signpost's message is an OSLogMessage,
        // not a runtime String (no `+` concatenation here).
        Self.signposter.emitEvent("rung-memory", "rung=\(rung) footprintMB=\(footprintMB) variants=\(variants) meshScalars=\(meshScalars) delivered=\(delivered) basenames=\(basenames)")
        #endif
        diag("memory@rung \(rung): footprint=\(footprintMB)MB variants=\(variants) "
           + "meshScalars=\(meshScalars) deliveredEvents=\(delivered) basenames=\(basenames)")
    }

    /// The process's physical footprint in bytes (Jetsam's yardstick), or 0 if the
    /// query fails. Darwin-only; the whole checkpoint compiles to a diag no-op off it.
    static func residentFootprintBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
        #else
        return 0
        #endif
    }

    // MARK: - test support (handoff 119 synthetic long-stream audit)
    // The SSE parse + dedupe path is otherwise reachable only through the network;
    // these let RemoteLongStreamMemoryTests feed thousands of synthetic frames and
    // assert the retained collections stay flat. Internal (not private) so
    // `@testable import` reaches them; never called by production code.

    var testRetainedBufferBytes: Int { buffer.count }
    var testDeliveredEventCount: Int { deliveredCount }
    var testStreamedVariantCount: Int { streamedCount }
    var testSeenMeshCount: Int {
        streamedLock.lock(); defer { streamedLock.unlock() }; return seenMeshes.count
    }
    /// Drive one chunk of raw SSE bytes through the real delegate parse/dedupe path,
    /// tagged with a task identity so the test can simulate a reconnect replay (a new
    /// task resets the per-connection cursor exactly as the network path does).
    func testFeedSSE(_ data: Data, task: URLSessionDataTask) {
        urlSession(eventSession, dataTask: task, didReceive: data)
    }
}

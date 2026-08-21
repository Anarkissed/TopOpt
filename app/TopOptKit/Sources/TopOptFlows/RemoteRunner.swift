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
    /// `onArtifacts` receives the run's RETENTION PAIR — the exact job document
    /// this app submitted and the run's `design.bin` — when both survive (task
    /// 2026-08-03-variant-entry-gating-and-retention). PR 274 defined this pair and
    /// persisted it, but nothing ever produced one from a live run: the app read
    /// `run_job.json` / `run_design.bin` back from disk and never wrote them, so
    /// every finished run reported "this run kept no design file" forever. This is
    /// the missing producer. Called on the run thread; the caller hops to main.
    /// `onLatticeMeshSource` receives a handle to THIS run's latticed meshes on the
    /// worker (task 2026-08-07-lattice-variants-on-screen). It is reported at
    /// submit, the same moment the job document is, and for the same reason: the
    /// results screen needs to be able to ask for a latticed mesh, and by the time
    /// the run resolves its re-attach record has already been cleared. Reported
    /// even on a run that turns out to carry no lattice — the handle costs nothing
    /// and knowing the job id is what makes a LATER answer possible.
    static func remoteRunner(_ config: RemoteRunnerConfig,
                             defaults: UserDefaults = .standard,
                             onArtifacts: ((RelatticeArtifacts) -> Void)? = nil,
                             onLatticeMeshSource: ((LatticeMeshTransferring) -> Void)? = nil)
        -> Runner {
        return { request, progress, onVariant in
            try RemoteRun(config: config, request: request,
                          progress: progress, onVariant: onVariant,
                          defaults: defaults, onArtifacts: onArtifacts,
                          onLatticeMeshSource: onLatticeMeshSource).run()
        }
    }

    /// Build a `Runner` that RE-ATTACHES to a job already running on the worker
    /// (handoff 101, requirement 5): it skips `/health` + `POST /jobs` and streams
    /// the existing job's `/events` (whose replay rebuilds the streamed variants),
    /// then assembles the same final outcome. Used after the iPad slept/relaunched
    /// with a `RemoteJobStore` record.
    /// A RE-ATTACH deliberately reports NO artifacts: the app no longer holds the
    /// document it submitted (the worker keeps `job.json` beside the run, not in the
    /// served `out/`), and a document rebuilt from the current request would be the
    /// re-authored load case this whole path exists to avoid. The variant then says
    /// so with its own reason (`RelatticeUnavailable.jobDocumentNotRecorded`).
    /// A RE-ATTACH reports no artifacts (see above) but it DOES report a lattice
    /// mesh source: the job id is the one thing it definitely knows, and the
    /// latticed meshes are served from that job's own output. So a run resumed the
    /// next morning can still reach its lattices even though it cannot re-lattice
    /// (which needs the submitted document it no longer holds).
    static func remoteReattachRunner(_ config: RemoteRunnerConfig, jobID: String,
                                     defaults: UserDefaults = .standard,
                                     onLatticeMeshSource: ((LatticeMeshTransferring) -> Void)? = nil)
        -> Runner {
        return { request, progress, onVariant in
            try RemoteRun(config: config, request: request,
                          progress: progress, onVariant: onVariant,
                          defaults: defaults, existingJobID: jobID,
                          onLatticeMeshSource: onLatticeMeshSource).run()
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
    /// Where the run's retention pair is handed back (see `remoteRunner`).
    private let onArtifacts: ((RelatticeArtifacts) -> Void)?
    /// Where this run's handle to its LATTICED meshes on the worker is handed back
    /// (task 2026-08-07-lattice-variants-on-screen). Reported once, at submit.
    private let onLatticeMeshSource: ((LatticeMeshTransferring) -> Void)?
    /// The most recent `fields.bin` fetched DURING the run — kept for its GRID, so
    /// a later fetch failure cannot wipe the geometry an earlier rung established
    /// (task 2026-08-03-variant-postprocessing-concurrency). Touched only from the
    /// event thread, like `submittedJobJSON`.
    private var streamedFieldsGrid: RemoteFieldsContainer?

    private var jobID: String?
    /// The EXACT bytes this run submitted, kept so the retention pair is the
    /// document that was sent — not one rebuilt later from anything.
    private var submittedJobJSON: Data?

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

    /// THE LATTICE ANNOUNCEMENTS THIS RUN MADE (task 2026-08-07-lattice-variants-
    /// on-screen), keyed by the rung's requested volume fraction. Core prints one
    /// `LATTICE …` checkpoint line per rung naming that rung's receipt and mesh
    /// (run_job.cpp, `emit_lattice`); the worker forwards it verbatim as a `log`
    /// SSE event, and this reader used to drop it at `handleEvent`'s `default`.
    /// Bounded by the LADDER (≈4) exactly like `streamed`, and holding only the
    /// parsed scalars + two basenames — no geometry, so the retention bound the
    /// 119 audit established is unchanged. Guarded by `streamedLock` alongside the
    /// collection it is joined to.
    private var latticeCheckpoints: [Double: LatticeCheckpoint] = [:]

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
         existingJobID: String? = nil,
         onArtifacts: ((RelatticeArtifacts) -> Void)? = nil,
         onLatticeMeshSource: ((LatticeMeshTransferring) -> Void)? = nil) {
        self.config = config
        self.request = request
        self.progress = progress
        self.onVariant = onVariant
        self.defaults = defaults
        self.existingJobID = existingJobID
        self.onArtifacts = onArtifacts
        self.onLatticeMeshSource = onLatticeMeshSource
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
            submittedJobJSON = jobJSON      // the retention pair's first half
            let modelData = try Data(contentsOf: URL(fileURLWithPath: request.modelPath))
            let modelName = (request.modelPath as NSString).lastPathComponent
            jobID = try postJob(model: modelData, modelName: modelName, jobJSON: jobJSON)
            // THE JOB DOCUMENT IS RETAINED AT SUBMIT (task
            // 2026-08-03-variant-postprocessing-fix). It exists NOW — these are the
            // bytes we just posted — and smoothing needs nothing else. Reporting it
            // only at the end tied it to the design container's fate, so a run whose
            // design never arrived told the user it had kept no LOAD CASE either.
            onArtifacts?(.jobOnly(jobJSON))
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

        // THE HANDLE TO THIS RUN'S LATTICED MESHES (task 2026-08-07-lattice-
        // variants-on-screen). Reported here — after the job id is known and
        // BEFORE the stream — for the same reason the job document is retained at
        // submit: it exists now, and reporting it only at the end would tie it to
        // whether the run reaches its terminal event. It costs nothing on a run
        // that turns out to carry no lattice; the results screen simply never asks.
        if let id = jobID, let report = onLatticeMeshSource {
            report(RemoteLatticeMeshTransfer(config: config, jobID: id))
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

    // `internal` (not `private`) so `@testable` unit tests can diff the emitted
    // job.json across model sources without standing up a worker — the mesh-job-params
    // field-equivalence gate lives in JobJSONEquivalenceTests.
    func buildJobJSON() throws -> Data { try Self.buildJobJSON(request) }

    /// ★ STATIC, SO THE ON-DEVICE PATH RUNS THE SAME DOCUMENT (maintainer,
    /// 2026-08-17: "Can you please make it run on the iPad as well"). The
    /// on-device lattice writes THIS job.json to a temp directory and hands it to
    /// `TopOptKit.runLatticeJob`, which calls core's own parser and core's own
    /// `lattice_variant_job`. One builder, two executors — an on-device lattice
    /// and a worker lattice cannot describe different runs, which is a property
    /// of there being one function rather than of two mappings kept in step.
    ///
    /// It only ever read `request`; nothing about a live connection was involved.
    static func buildJobJSON(_ request: RunRequest) throws -> Data {
        var job: [String: Any] = [
            "model": (request.modelPath as NSString).lastPathComponent,
            "material": request.material,
            // ★ THE RUN'S OWN MODE (maintainer, 2026-08-17). "minimize_plastic"
            // for Optimize; "lattice_part" for the Lattice button, which
            // lattices the selection and runs no ladder at all.
            "mode": request.jobMode,
            "resolution": request.resolution,
            // ★ `project_cad_faces` IS SENT EXPLICITLY, ALWAYS — never omitted to
            // ride core's default (task 2026-08-06-arm-projection-and-void-check,
            // S1b). Core defaults it to TRUE, so omitting it would produce the
            // same run; what it would NOT produce is a record. `run_info` echoes
            // the job it was given, and "the key was absent" and "the user asked
            // for this" are the same bytes there. Writing it makes the receipt
            // unambiguous about what was ASKED FOR versus what was DEFAULTED,
            // which is the only way a run months from now can be attributed.
            //
            // It is also how the two front-ends are kept from diverging: this is
            // the value the user set, not a second opinion about what the default
            // should be. Core still owns the default (topopt/job.hpp).
            "output": ["report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant",
                       "smooth_factor": Self.smoothExportFactor,
                       "project_cad_faces": request.projectCADFaces],
        ]
        // ── ★ THE PARAMETRIC LEVEL SET IS THE APP'S OPTIMISER (task
        // 2026-08-10-plsm-production, maintainer request) ────────────────────
        //
        // SENT EXPLICITLY, ALWAYS, for the same reason `project_cad_faces` is:
        // `run_info` echoes the job it was given, and "the key was absent" and
        // "the user asked for this" are the same bytes there. A run months from
        // now has to be attributable to the algorithm that made it.
        //
        // ★ THIS IS THE MIRROR OF `opts.plsm.mode = PlsmMode::Parametric` IN
        // bridge.cpp's run_minimize_plastic. The on-device path and the LAN path
        // must produce the same part; this codebase has already paid for one
        // drift between them. THE TWO MOVE TOGETHER — change one, change the
        // other in the same commit, exactly as `bake_build_orientation` below.
        //
        // Only `enabled` is sent. Everything else is left to core's own
        // PlsmOptions defaults, and the knot spacing in particular is DELIBERATELY
        // ABSENT: omitting it is what asks for `plsm_knots_for_grid`, the
        // production rule that derives the spacing from the grid's voxel size,
        // per axis. Naming three numbers here would pin the feature scale to one
        // resolution and would be a second opinion about a rule core owns.
        //
        // Core's DEFAULT is still SIMP (`PlsmMode::Off`), so `topopt-cli` and
        // every existing job document are unaffected. The front-end opts in.
        job["plsm"] = ["enabled": true]
        // The true source format when `model` is a working copy in another format
        // (a 3MF normalised to STL at import, handoff 2026-07-26-3mf-optimize-path).
        // The worker echoes it into run_info so the record names the real source even
        // though it imported an STL. Omitted for a plain STL/STEP part, so those jobs
        // are byte-identical to before (the CLI derives "stl"/"step" from the model).
        if !request.sourceFormat.isEmpty {
            job["source_format"] = request.sourceFormat
        }
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
        // The lattice block (handoff 2026-07-29-lattice-mode-ui), a TOP-LEVEL sibling of
        // design_box exactly as the core job schema (`find_key(root, "lattice")`) parses
        // it. Present ONLY when lattice mode is on AND the settings are runnable-as-
        // certified (`LatticeSettings.runSpec`) — so a non-lattice run adds no key and the
        // job.json is byte-identical to today (BAR U1). The worker's topopt-cli generates
        // the streamed lattice artifact; the on-device bridge path has no lattice concept
        // and simply ignores `request.lattice`. The core schema requires at least one of
        // emit_stl / emit_3mf, which `runSpec` guarantees (STL by default).
        if let lat = request.lattice {
            var block: [String: Any] = [
                "topology": lat.topologyID,
                "emit_stl": lat.emitSTL,
                "emit_3mf": lat.emit3MF,
                // The boundary treatment (handoff 2026-07-29-lattice-boundary-finish):
                // "none" | "rim" | "diagrid", the page's three-way choice (bar B7).
                "skin": lat.skin,
                // ★ THE ENCLOSED-VOID RULE, sent EXPLICITLY in both directions
                // (task 2026-08-06-arm-projection-and-void-check, S2). Core
                // defaults it TRUE, so omitting it would run identically — but
                // this is the switch that can REFUSE A RUNG, and when a rung
                // stops the record must say whether the rule was asked for or
                // merely inherited. `RelatticeJobBuilder` writes the same key
                // from the same spec field, so the two paths cannot diverge.
                "require_lattice_void_reaches_exterior":
                    lat.requireVoidReachesExterior,
            ]
            if let grading = lat.gradingDictionary() {
                // GRADED run (task lattice-page-core-hookup stage 4): the schema
                // REJECTS cell_mm/strut_radius_mm alongside a "grading" block —
                // core derives the cell (target raised to its printability floor)
                // and the strut radii from the run's OWN final stress field, and
                // writes the provenance + clamp accounting into each variant's
                // lattice receipt.
                //
                // THE BLOCK ITSELF IS BUILT BY `LatticeSpec.gradingDictionary()`,
                // which `RelatticeJobBuilder` also calls — one builder, so an
                // optimize run and a re-lattice of its result cannot carry
                // different postures (task 2026-08-05-lattice-retention-app-control).
                job["grading"] = grading
            } else {
                block["cell_mm"] = lat.cellMM
                block["strut_radius_mm"] = lat.strutRadiusMM
            }
            if let w = lat.minExtrudableWidthMM {
                // Arms core's OWN skin printability clamp (lattice_skin_min_radius_mm)
                // with the user's outer line width — the number stays core-owned.
                block["min_extrudable_width_mm"] = w
            }
            // Include/exclude regions (`lattice.regions`, PR 256's schema — round-2
            // wired the emission the page copy wrongly said was impossible). The
            // geometry mirrors the manual-clearance encoder below, plus the
            // lattice-face-specific `depth_mm` the schema requires. Empty → key
            // omitted → byte-identical to a pre-regions lattice job.
            if !lat.regions.isEmpty {
                // ONE encoder, shared with RelatticeRunner — see
                // LatticeRegionSpec.wireDictionary for why it is not two.
                block["regions"] = lat.regions.map { $0.wireDictionary }
            }
            job["lattice"] = block
        }
        // The declared load case is emitted for EVERY model source — STEP B-rep
        // faces AND STL/3MF pseudo-faces (handoff 134 made the segmenter's pseudo-face
        // ids share the exact face-id contract, and the mesh-optimize work made the
        // core's run_job / build_production_loadcase honor a `loads` block for a mesh
        // part identically to a STEP part). Gating this on `isStepModel` was the
        // mesh-job-params bug: a mesh job.json shipped a skeleton (`build_dir` only),
        // so the CLI dropped the anchors/loads/infill/resolution and silently fell
        // back to the worst-case self-weight / 100%-infill / cold run that OOM-killed.
        // A mesh RunRequest already carries anchor_face_ids / groups / clearances /
        // protections as pseudo-face ids, so the SAME serializer produces a job.json
        // field-equivalent to the STEP one (only `model` and the face-id provenance
        // differ). No `else` skeleton.
        var loads: [String: Any] = [
            "minimize_plastic": request.minimizePlastic,
            // ★ THE LAYER HEIGHT NOW REACHES CORE. It was captured on the print-params
            // sheet and persisted since M7.params, but never sent — `PrintParams.swift`
            // said so outright ("CAPTURED BUT NOT WIRED"), and core had no field for it.
            // Without it the grading law cannot compare the lattice it produced against
            // the profile it will be printed with, because the overhang limit is
            // c*W/h and h was invisible.
            "layer_height_mm": request.layerHeightMM,
            "build_dir": [request.buildDirection.x, request.buildDirection.y,
                          request.buildDirection.z],
        ]
        if !request.anchorFaceIDs.isEmpty {
            loads["anchor_face_ids"] = request.anchorFaceIDs
        }
        // ── THE REGION LAYER (task 2026-08-14-face-regions §1) ────────────────
        //
        // Declared ONCE, referred to by id below, and emitted ONLY when the user
        // authored a union or a split. ★ NO REGIONS ⇒ NO KEY ⇒ the job is
        // byte-identical to the one this project shipped yesterday (bar R1).
        //
        // ★ WHAT GOES ON THE WIRE IS THE DEFINITION, NOT THE RESULT (§3c): the
        // filter, plus the explicit add/remove list, plus the split half-spaces
        // as model-space geometry. The worker re-evaluates the filter against ITS
        // import and reports the difference against `filter_matched_at_author`,
        // so a CAD edit that renumbers faces is surfaced instead of absorbed.
        if !request.faceRegions.isEmpty {
            loads["face_regions"] = request.faceRegions.map { r -> [String: Any] in
                var e: [String: Any] = ["id": r.id]
                if !r.name.isEmpty { e["name"] = r.name }
                if r.parentID >= 0 { e["parent_id"] = r.parentID }
                if !r.add.isEmpty { e["add"] = r.add.map(Int.init) }
                if !r.remove.isEmpty { e["remove"] = r.remove.map(Int.init) }
                if r.filterMatchedAtAuthor >= 0 {
                    e["filter_matched_at_author"] = r.filterMatchedAtAuthor
                }
                if r.filter.any {
                    var f: [String: Any] = [:]
                    if r.filter.maxAreaMM2 > 0 { f["max_area_mm2"] = r.filter.maxAreaMM2 }
                    if r.filter.minAreaMM2 > 0 { f["min_area_mm2"] = r.filter.minAreaMM2 }
                    if r.filter.minLargerNeighbours > 0 {
                        f["min_larger_neighbours"] = r.filter.minLargerNeighbours
                        f["larger_ratio"] = r.filter.largerRatio
                    }
                    if !r.filter.kind.isEmpty { f["kind"] = r.filter.kind }
                    if r.filter.cylinderRadiusMM > 0 {
                        f["cylinder_radius_mm"] = r.filter.cylinderRadiusMM
                        f["cylinder_radius_tol_mm"] = r.filter.cylinderRadiusTolMM
                    }
                    e["filter"] = f
                }
                if !r.cuts.isEmpty {
                    e["cuts"] = r.cuts.map { c -> [String: Any] in
                        ["point": [c.point.x, c.point.y, c.point.z],
                         "normal": [c.normal.x, c.normal.y, c.normal.z],
                         "strict": c.strict]
                    }
                }
                return e
            }
        }
        if !request.anchorRegionIDs.isEmpty {
            loads["anchor_region_ids"] = request.anchorRegionIDs
        }
        // THE BUILD-PLATE NORMAL, at the job ROOT and not inside `loads` (handoff
        // 2026-08-01-build-direction-separation): `loads.build_dir` above answers
        // "which way is down in service" (the core negates it into gravity), and
        // the root key answers the different question "which way is up on the
        // plate". Emitted ONLY when the user declared one, so a project that never
        // touched the control ships the identical job.json it always did — the
        // load-bearing bar. The on-device bridge sends the same value through
        // BridgeLoadCase.plate_dir_*, so both front-ends agree by construction.
        if request.plateDirection != SIMD3<Double>(0, 0, 0) {
            job["build_direction"] = [request.plateDirection.x, request.plateDirection.y,
                                      request.plateDirection.z]
        }
        if request.wantsOrientationRanking {
            job["build_orientation_report"] = true
        }
        // ── BAKING IS OFF ON THE APP PATH, DELIBERATELY, AND THIS IS WHY ───────
        // (handoff 2026-08-01-bake-build-orientation.)
        //
        // The core's default is "auto": with no declared build direction it
        // CHOOSES one and ROTATES the exported mesh so that direction is +Z in
        // the file. That is right for a file handed to a slicer, and wrong for
        // this app TODAY, because of what this app does with that same file:
        // `fetchMesh` downloads the EXPORTED mesh and the viewer draws it under
        // the MODEL-frame gravity arrow, the MODEL-frame design box, clearances
        // and load groups, and the MODEL-frame per-voxel overlays spliced from
        // fields.bin. Rotate the mesh alone and every one of those lands on the
        // wrong geometry — a frame mix, which is a worse defect than the one
        // baking fixes.
        //
        // So the app asks for the pre-bake pipeline explicitly rather than
        // inheriting a default that would break its viewer. The consequence is
        // stated plainly and is NOT hidden: an app run still certifies the
        // gravity-inferred orientation and still surfaces the recommendation
        // through BuildOrientationView, exactly as it did before — no better, no
        // worse. The CLI / worker-direct path gets the baked file.
        //
        // THE FIX, when it is taken: make the viewer frame-aware — map the
        // fetched mesh back through `export_frame.rotation_row_major` (already
        // published in build_orientation.json, so no second derivation) before
        // display, or render the model-frame mesh the bridge already holds. Then
        // this key comes out and the app inherits "auto" like everything else.
        // The decoder and the announcement banner are ALREADY built and tested
        // for that day; only this line is in the way.
        job["bake_build_orientation"] = "off"
        if !request.loadGroups.isEmpty {
            loads["groups"] = request.loadGroups.map { g -> [String: Any] in
                var e: [String: Any] = ["force": [g.force.x, g.force.y, g.force.z]]
                // Emit "face_ids" only when there ARE face ids: a group that is
                // now ONE region must not ship an empty array where a 23-element
                // one used to be — and a group with no regions must ship exactly
                // what it always did.
                if !g.faceIDs.isEmpty { e["face_ids"] = g.faceIDs }
                if !g.regionIDs.isEmpty { e["region_ids"] = g.regionIDs }
                return e
            }
        }
        if request.infillPercent >= 0 {
            loads["infill_percent"] = request.infillPercent
        }
        // Width-aware knockdown wall metadata (handoff 2026-07-27-wall-loops-plumbing +
        // line-width-plumbing). Emit the user's wall-loop count and the inner/outer wall
        // LINE WIDTHS ALWAYS (0 loops is a meaningful "no walls", and the CLI defaults the
        // absent keys — the exact bug that made a walled part's run_info read the modelling
        // assumption instead of the user's settings). The on-device bridge sends the SAME
        // values via BridgeLoadCase.{wall_loops, wall_line_width_mm, wall_line_width_outer_mm}
        // through the SAME TopOptKit mappings (asserted equal in JobJSONEquivalenceTests).
        loads["wall_loops"] = Int(TopOptKit.bridgeWallLoops(forOverride: request.wallLoops))
        loads["wall_line_width_mm"] =
            TopOptKit.bridgeWallLineWidthMM(forOverride: request.wallLineWidthInnerMM)
        loads["wall_line_width_outer_mm"] =
            TopOptKit.bridgeWallLineWidthOuterMM(forOverride: request.wallLineWidthOuterMM)
        if !request.clearances.isEmpty {
            loads["clearances"] = request.clearances.map { c -> [String: Any] in
                // The kind + distance fields are IDENTICAL for auto and manual (BAR
                // B1); the only structural difference is the geometry SOURCE — a
                // "face_id" for an auto face, or a "geometry" object for a manual
                // primitive that has no B-rep face. Exactly one, matching the core
                // schema's XOR rule (handoff group-editing).
                var entry: [String: Any] = ["kind": c.kind == .face ? "face" : "bolt"]
                if let m = c.manual {
                    entry["geometry"] = c.kind == .face
                        ? [
                            "origin": [m.origin.x, m.origin.y, m.origin.z],
                            "normal": [m.normal.x, m.normal.y, m.normal.z],
                            "half_u_mm": m.halfUMM,
                            "half_w_mm": m.halfWMM,
                        ]
                        : [
                            "axis_point": [m.axisPoint.x, m.axisPoint.y, m.axisPoint.z],
                            "axis_dir": [m.axisDir.x, m.axisDir.y, m.axisDir.z],
                            "radius_mm": m.radiusMM,
                            "half_length_mm": m.halfLengthMM,
                        ]
                } else {
                    entry["face_id"] = c.faceID
                }
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
        //
        // ★ When any face carries its OWN dragged depth (task 2026-08-12 §0a) the
        // OBJECT form goes out instead — {"face_id", "depth_mm"} per face — so the
        // worker freezes exactly the slab that face's lattice region will fill.
        // With no per-face depth the bare-id form is emitted, unchanged.
        if !request.faceProtections.isEmpty {
            let depths = request.faceProtectionDepthsMM
            let perFace = depths.count == request.faceProtections.count
                && zip(request.faceProtections, depths).contains {
                    $0.1 > 0 && abs($0.1 - request.faceProtectionDepthMM) > 1e-9
                }
            if perFace {
                loads["face_protections"] = zip(request.faceProtections, depths).map {
                    ["face_id": $0.0, "depth_mm": $0.1] as [String: Any]
                }
            } else {
                loads["face_protections"] = request.faceProtections
                if request.faceProtectionDepthMM > 0 {
                    loads["face_protection_depth_mm"] = request.faceProtectionDepthMM
                }
            }
        }
        // ★ PROTECTIONS DECLARED ON A REGION. The object form is the only one
        // that can carry a region id, so a job with any region protection uses
        // it throughout — the schema refuses a mix of bare ids and objects, and
        // the two must agree on ONE form. Face protections already in the bare
        // form above are promoted here rather than left to clash.
        if !request.faceProtectionRegionIDs.isEmpty {
            var entries: [[String: Any]] = []
            let faceDepths = request.faceProtectionDepthsMM
            for (k, f) in request.faceProtections.enumerated() {
                var e: [String: Any] = ["face_id": f]
                if k < faceDepths.count, faceDepths[k] > 0 { e["depth_mm"] = faceDepths[k] }
                entries.append(e)
            }
            let regionDepths = request.faceProtectionRegionDepthsMM
            for (k, r) in request.faceProtectionRegionIDs.enumerated() {
                var e: [String: Any] = ["region_id": r]
                if k < regionDepths.count, regionDepths[k] > 0 { e["depth_mm"] = regionDepths[k] }
                entries.append(e)
            }
            loads["face_protections"] = entries
            if request.faceProtectionDepthMM > 0 {
                loads["face_protection_depth_mm"] = request.faceProtectionDepthMM
            }
        }
        job["loads"] = loads
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

    /// Fetch the run's `design.bin` — the per-variant DENSITY FIELDS core writes
    /// beside `fields.bin` (PR 274's design store), served by the SAME
    /// `/files/{name}` route the meshes use. Returns nil on any failure, and says
    /// WHICH failure it was: a 404 is an older worker (or a job whose CLI wrote
    /// none), a transport error is a network story, and an empty body is neither.
    /// A design failure never fails the run — it only makes the variant entries
    /// honestly unavailable.
    private func fetchDesign() -> Data? {
        guard let id = jobID else { return nil }
        let url = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
            .appendingPathComponent("design.bin")
        guard let (data, resp) = try? syncGET(url) else {
            diag("remote design.bin fetch failed (transport) — variants can't be smoothed/latticed")
            return nil
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            diag("remote design.bin unavailable (HTTP \(code)) — variants can't be smoothed/latticed")
            return nil
        }
        guard !data.isEmpty else {
            diag("remote design.bin was empty — variants can't be smoothed/latticed")
            return nil
        }
        diag("remote design.bin fetched: \(data.count) bytes")
        return data
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

    /// The lattice a remote run carried (handoff 2026-07-29-lattice-mode-ui): the
    /// settings echo from `request.lattice` (always, when a lattice was requested) plus
    /// the worker's generated facts parsed from run_info.json's `lattice_export` record
    /// (best-effort — a worker that didn't emit it, or a transport error, leaves the
    /// facts nil and only the requested settings show, honestly labelled). nil when no
    /// lattice was requested, so a non-lattice run's outcome is unchanged.
    /// THE PER-REGION RECEIPT (task 2026-08-05-lattice-retention-app-control, S4).
    /// Core writes it into the per-variant GRADED lattice receipt
    /// (`variant_XXX_lattice.report.json`, `lattice_cert_report_json`) — not into
    /// run_info — so it takes its own fetch, and only when the job asked for it.
    ///
    /// `acceptedRequestedVFs` is the run's accepted rungs in ladder order; the
    /// receipt is read for the LAST of them, which is the rung the export and the
    /// recommendation centre on. The tag convention (`%03d` of vf × 100) is core's
    /// own mesh-prefix convention, the same one `RelatticeRun` fetches by.
    private func fetchRegionCells(acceptedRequestedVFs: [Double]) -> Data? {
        guard request.lattice?.reportRegionCells == true,
              let id = jobID, let vf = acceptedRequestedVFs.last else { return nil }
        let tag = String(format: "%03d", Int((vf * 100).rounded()))
        let url = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
            .appendingPathComponent("variant_\(tag)_lattice.report.json")
        guard let (data, resp) = try? syncGET(url),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            diag("per-region lattice receipt unavailable — no region breakdown shown")
            return nil
        }
        return data
    }

    /// THE LATTICED ALTERNATIVE FOR EVERY RUNG THAT PRODUCED ONE (task
    /// 2026-08-07-lattice-variants-on-screen, S1).
    ///
    /// For each accepted rung the run announced a lattice for, this fetches that
    /// rung's OWN certification receipt — a few kB — and probes the size of its
    /// mesh. It does NOT fetch the mesh. On the maintainer's run the four meshes
    /// are 740 MB / 1.06 GB / 1.42 GB / 1.95 GB, and a measured 4.30 GB of
    /// resident memory goes into an in-memory GET of just the 1.42 GB one
    /// (`LatticeMeshBudget`), so fetching four eagerly at run end is not a thing
    /// this app can do on any device it ships to. The mesh is transferred only
    /// when a latticed variant is SELECTED, and only after the budget agrees.
    ///
    /// `fetchRegionCells` above reads ONE receipt — the last accepted rung's, and
    /// only when the job asked for a region breakdown. That is a different
    /// question (the run-level region roll-up) and is left exactly as it was; this
    /// reads every rung's, unconditionally on the rung having announced a lattice.
    ///
    /// Best-effort per rung, like `fetchFields`: a receipt that does not arrive
    /// leaves that rung with no alternative and the screen shows the solid alone —
    /// but the DIAGNOSTIC says which rung and why, because a lattice that exists
    /// and cannot be reached is exactly what this task exists to stop being silent.
    private func fetchLatticeAlternatives(acceptedRequestedVFs: [Double])
        -> [Double: LatticeVariantAlternative] {
        streamedLock.lock(); let checkpoints = latticeCheckpoints; streamedLock.unlock()
        guard !checkpoints.isEmpty, let id = jobID else { return [:] }
        let files = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
        var out: [Double: LatticeVariantAlternative] = [:]
        for vf in acceptedRequestedVFs {
            // Join by the rung's REQUESTED fraction — the same key the checkpoint
            // line carries and the same one that names the files. Matched with a
            // tolerance because both sides travelled through a decimal print.
            guard let cp = checkpoints.first(where: {
                abs($0.key - vf) < 1e-6
            })?.value else { continue }
            var mass = 0.0
            var accepted = cp.accepted
            var margin = cp.margin
            var receipt: Data?
            if let (data, resp) = try? syncGET(files.appendingPathComponent(cp.reportName)),
               (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                receipt = data
                let facts = LatticeVariantAlternative.receiptFacts(data)
                mass = facts.massGrams
                // The RECEIPT is authoritative where it speaks; the checkpoint
                // line is the fallback. They come from the same computation, so
                // they agree — but a null margin in the receipt (that failure mode
                // carries no load) must not overwrite a real number with 0.
                if let a = facts.accepted { accepted = a }
                if let m = facts.margin { margin = m }
            } else {
                diag("lattice receipt \(cp.reportName) unavailable — the latticed "
                     + "variant for vf=\(vf) will show without its mass")
            }
            // The mesh's SIZE, not the mesh. A HEAD on the same static-file route.
            let bytes = latticeMeshBytes(files.appendingPathComponent(cp.meshName))
            out[vf] = LatticeVariantAlternative(
                requestedVolumeFraction: vf, meshName: cp.meshName,
                massGrams: mass, accepted: accepted, margin: margin,
                triangleCount: cp.triangles, meshBytes: bytes, receiptJSON: receipt)
            diag("latticed alternative vf=\(vf): \(cp.meshName) "
                 + "\(LatticeMeshBudget.byteLabel(bytes)), \(mass) g, "
                 + "accepted=\(accepted)")
        }
        return out
    }

    /// A HEAD request for one artifact's `Content-Length`. 0 when the worker does
    /// not answer HEAD or the header is absent — read downstream as "unknown",
    /// which refuses to promise a transfer rather than starting a blind one.
    private func latticeMeshBytes(_ url: URL) -> Int {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = config.controlTimeout
        var bytes = 0
        let sem = DispatchSemaphore(value: 0)
        controlSession.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200,
               http.expectedContentLength > 0 {
                bytes = Int(http.expectedContentLength)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + config.controlTimeout + 2)
        return bytes
    }

    private func fetchLatticeReport(regionCellsJSON: Data? = nil) -> LatticeReport? {
        guard let lat = request.lattice else { return nil }
        var generated: LatticeReport.Generated? = nil
        var strut: LatticeReport.StrutStrength? = nil
        if let id = jobID {
            let url = config.baseURL.appendingPathComponent("jobs")
                .appendingPathComponent(id).appendingPathComponent("files")
                .appendingPathComponent("run_info.json")
            let info = try? getJSON(url)
            if let le = info?["lattice_export"] as? [String: Any] {
                func d(_ k: String) -> Double { (le[k] as? Double) ?? 0 }
                func i(_ k: String) -> Int { (le[k] as? Int) ?? Int((le[k] as? Double) ?? 0) }
                func b(_ k: String) -> Bool { (le[k] as? Bool) ?? false }
                generated = LatticeReport.Generated(
                    emitSTL: b("emit_stl"), emit3MF: b("emit_3mf"),
                    latticedCells: i("latticed_cells"), regionVoxels: i("region_voxels"),
                    triangles: i("triangles"),
                    strutRadiusMinMM: d("strut_radius_min_mm"),
                    strutRadiusMaxMM: d("strut_radius_max_mm"))
            } else {
                diag("run_info lattice_export unavailable — showing requested lattice only")
            }
            // Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report):
            // the certification "lattice" object carries the report-only de-
            // homogenized strut margins when the worker evaluated the measured law.
            // Absent keys (older worker / non-octet lattice) leave `strut` nil —
            // no numbers invented. A null margin (JSON null → not a Double) reads
            // as +inf: that failure mode carries no load.
            if let lc = info?["lattice"] as? [String: Any],
               lc["strut_margin_in_plane"] != nil {
                func m(_ k: String) -> Double { (lc[k] as? Double) ?? .infinity }
                let sub = ((info?["grading"] as? [String: Any])?["subfloor_retention"]
                           as? [String: Any]) ?? [:]
                strut = LatticeReport.StrutStrength(
                    marginInPlane: m("strut_margin_in_plane"),
                    marginInterlayer: m("strut_margin_interlayer"),
                    zKnockdown: (lc["strut_z_knockdown"] as? Double) ?? 0,
                    minCellsPerMember: m("strut_min_cells_per_member"),
                    outOfRegime: (lc["strut_out_of_regime"] as? Bool) ?? false,
                    // Why the regime flag is set, when the run CHOSE it: the grading
                    // law's sub-floor retention record. Absent on a run that did not
                    // opt in, which leaves both at 0 and the reason unattributed —
                    // correctly, because then it was not a choice.
                    subfloorRetainedVoxels: sub["voxels_retained"] as? Int ?? 0,
                    subfloorRegionStressFraction:
                        sub["region_stress_fraction_measured"] as? Double ?? 0)
            }
        }
        return LatticeReport(
            topologyID: lat.topologyID, cellMM: lat.cellMM,
            generateRelativeDensity: lat.generateRelativeDensity,
            minRelativeDensity: lat.minRelativeDensity,
            maxRelativeDensity: lat.maxRelativeDensity,
            regionScoped: lat.regionScoped, emittedRegions: lat.regions.count,
            generated: generated, strut: strut,
            regionCellsJSON: regionCellsJSON)
    }

    /// The BUILD-ORIENTATION RECEIPT a remote run wrote (handoff
    /// 2026-08-01-build-direction-separation): `<out_dir>/build_orientation.json`,
    /// the SAME document the on-device bridge returns as a string, from the SAME
    /// core emitter. Fetched only when the run armed the ranking; a worker that
    /// wrote none (or a transport error) leaves it nil and the app simply shows no
    /// ranking rather than a half-parsed one.
    private func fetchBuildOrientation() -> Data? {
        guard request.wantsOrientationRanking, let id = jobID else { return nil }
        let url = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
            .appendingPathComponent("build_orientation.json")
        guard let (data, resp) = try? syncGET(url),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            diag("build_orientation.json unavailable — no orientation ranking shown")
            return nil
        }
        return data
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
        case "log":
            // *** THE LATTICE ANNOUNCEMENT ARRIVES HERE (task 2026-08-07-lattice-
            // variants-on-screen). *** Core prints one `LATTICE …` checkpoint per
            // rung — the rung, the topology, the cell, the triangle count, the
            // composite margin, the verdict, and the two filenames — and the
            // worker has no typed event for it, so it falls through
            // `_line_to_event`'s catch-all as `{"type": "log", "line": …}`. That
            // is why the optimize path could not reach a lattice it had produced:
            // not a missing protocol, a dropped line. Everything else on this
            // channel is still ignored for the outcome, exactly as before.
            if let line = ev["line"] as? String,
               let cp = LatticeCheckpoint.parse(line) {
                streamedLock.lock()
                latticeCheckpoints[cp.requestedVolumeFraction] = cp
                streamedLock.unlock()
                diag("lattice checkpoint vf=\(cp.requestedVolumeFraction): "
                     + "\(cp.meshName) (\(cp.triangles) tris, "
                     + "accepted=\(cp.accepted))")
            }
        default:
            break  // every other line: ignored for the outcome
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
        // THIS RUNG'S OWN FIELD, NOW (task
        // 2026-08-03-variant-postprocessing-concurrency). Core publishes
        // `fields.bin` after every rung, so the block for the variant we are about
        // to show exists. Without it a streamed variant arrived with mass 0 and an
        // empty von Mises field — which is exactly what the lattice page's AUTO
        // density grades from and what the results overlays draw. A four-rung
        // ladder therefore left rung 1 un-gradeable for hours, for no reason but
        // when the file was written.
        //
        // Matched BY VOLUME FRACTION, never by position: the container holds the
        // rungs accepted so far and this is the rung the event just named.
        // Best-effort — a fetch that fails leaves the variant exactly as it arrived
        // before this change, and the page's own gates report the field as absent.
        let container = fetchFields()
        if let c = container { streamedFieldsGrid = c }   // remember the geometry
        let block = container?.variants.first { $0.requestedVF == requestedVF }
        let enriched = block.map { b in
            OptimizeVariant(
                requestedVolumeFraction: requestedVF,
                achievedVolumeFraction: printedVF, printedFraction: printedVF,
                massGrams: b.massGrams, supportVolumeVoxels: b.supportVolumeVoxels,
                meshTriangleCount: mesh.1.count / 3, worstCaseMargin: margin,
                accepted: accepted, v3Passes: true,
                meshVertices: mesh.0, meshIndices: mesh.1,
                vonMisesField: b.vonMises, displacementField: b.displacement)
        } ?? v
        if block != nil {
            diag("streamed variant vf=\(requestedVF) carries its own field "
                 + "(\(block!.vonMises.count) voxels) — post-processable now")
        }
        // The GRID the field is indexed to must ride along, or the app holds a
        // field it cannot address. `appendStreamed` takes the grid from each
        // partial, so the LAST KNOWN container's geometry is passed every time — a
        // later fetch failure must not wipe the geometry an earlier one established.
        let g = streamedFieldsGrid
        onVariant(OptimizeOutcome(variants: [enriched], stoppedOnMargin: false,
                                  cancelled: false, acceptedCount: 1,
                                  voxelVolumeMM3: g?.voxelVolumeMM3 ?? 0,
                                  gridNx: g?.gridNx ?? 0, gridNy: g?.gridNy ?? 0,
                                  gridNz: g?.gridNz ?? 0,
                                  gridOrigin: g?.gridOrigin ?? .zero,
                                  spacing: g?.spacing ?? 0,
                                  computedRemotely: true))
        // THE RETENTION PAIR, AT EVERY RUNG (task
        // 2026-08-03-variant-postprocessing-fix, defect 1). A variant is on screen
        // and workable from THIS moment; its design must be too. Core now publishes
        // design.bin after every variant, so there is something to fetch here — and
        // fetching it here is what makes a run that never reaches its terminal event
        // keep the variants it DID produce, with the design that describes them.
        //
        // The maintainer's run is the case this exists for: three variants streamed,
        // the worker restarted on rung 4, no terminal event ever, no assembleFinal-
        // Outcome, no pair. The app kept his variants and correctly reported that it
        // had kept nothing to work on them with.
        //
        // Best-effort and idempotent: a failed fetch leaves the previous pair (which
        // then covers fewer variants than are on screen — the entry gate reads the
        // container's own index and disables the ones it does not cover).
        reportRetentionPair()
    }

    /// Fetch `design.bin` and report the retention pair, if both halves are there.
    /// Called after every streamed variant AND once more at final assembly, so the
    /// last thing reported is always the most complete container.
    private func reportRetentionPair() {
        guard let onArtifacts, let job = submittedJobJSON else { return }
        guard let design = fetchDesign() else { return }
        onArtifacts(RelatticeArtifacts(jobJSON: job, designBin: design))
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
        // *** THE 0.00x FAULT (handoff 2026-08-02-gate-diagnosis-recommendations). ***
        // report.json carries TWO arrays: `variants` (accepted) and
        // `rejected_variants` (evaluated-but-rejected, the honesty rider). This
        // reader only ever looked at the first, so a run where EVERY rung was
        // rejected produced an EMPTY variant list — and the failure sheet, taking a
        // max over it, told the user "the strongest variant's worst-case stress
        // margin was 0.00x". The real numbers were sitting in the array it never
        // opened (2.7814 raw / 0.5759 effective, fingerprint 9f6738726016).
        let rejectedReportVariants =
            report["rejected_variants"] as? [[String: Any]] ?? []

        // Per-voxel fields (best-effort; nil leaves the overlays gated).
        // BOTH the live-completion path and the RE-ATTACH path reach here — this is
        // the single assembly point, so a run whose client force-quit and re-attached
        // the next morning fetches exactly the same fields.bin, with the same presence
        // gate and the same graceful degradation (handoff 134, item 2).
        let fields = fetchFields()
        // The worker's own duration record (handoff 134, item 1) — never the client's
        // wall clock, which on a re-attach measures when someone looked, not the run.
        let timing = fetchTiming()
        // The lattice the run carried (handoff 2026-07-29-lattice-mode-ui); nil for a
        // non-lattice run, so the outcome below is unchanged for every current run.
        // The per-region breakdown, when the job asked for it (task
        // 2026-08-05-lattice-retention-app-control, S4). Read here rather than
        // inside fetchLatticeReport because it needs the accepted rungs to name the
        // receipt file, and those come off the stream.
        streamedLock.lock(); let acceptedForReceipt = streamed; streamedLock.unlock()
        let latticeReport = fetchLatticeReport(
            regionCellsJSON: fetchRegionCells(
                acceptedRequestedVFs: acceptedForReceipt.map { $0.requestedVF }))
        // The orientation ranking this run produced — a RECOMMENDATION shown beside
        // the results, never applied and never consulted for a verdict.
        let buildOrientation = fetchBuildOrientation()
        // THE RETENTION PAIR (task 2026-08-03-variant-entry-gating-and-retention),
        // one last time so the container reported is the COMPLETE one — this write
        // holds every evaluated rung, including any that were rejected and so never
        // streamed. Best-effort, exactly like fields.bin: a run whose design.bin
        // cannot be fetched is still a complete run, it simply cannot have its
        // variants re-latticed, and the entry control says so with the reason
        // instead of opening a page that refuses.
        //
        // It is no longer the ONLY report (task 2026-08-03-variant-postprocessing-
        // fix): the job document is retained at submit and the pair at every
        // streamed variant, because this line is reached only by a run that ran all
        // the way to its terminal event — which is precisely what the maintainer's
        // run did not do.
        reportRetentionPair()

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

        // THE LATTICED ALTERNATIVES (task 2026-08-07-lattice-variants-on-screen).
        // Receipts + sizes only — never the meshes. Read here, at the one assembly
        // point BOTH the live-completion and the re-attach paths reach, so a run
        // whose client force-quit and re-attached the next morning gets its
        // latticed variants from the replayed checkpoint lines exactly as a run
        // watched to the end does.
        let latticeAlternatives = fetchLatticeAlternatives(
            acceptedRequestedVFs: accepted.map { $0.requestedVF })

        if !accepted.isEmpty {
            let variants = accepted.map { s in
                makeVariant(streamed: s,
                            report: reportVariant(forAchieved: s.achievedVF),
                            fields: fields?.variant(forRequestedVF: s.requestedVF),
                            lattice: latticeAlternatives[s.requestedVF])
            }
            return remoteOutcome(variants: variants, acceptedCount: variants.count,
                                 fields: fields, timing: timing, latticeReport: latticeReport,
                                 buildOrientationJSON: buildOrientation)
        }

        // No accepted variant streamed: report-only rows. They carry no mesh, so they
        // are joined to the fields by the report's own requested VF when it has one —
        // a rejected rung has no overlay to light up, but the run's grid + duration
        // still ride along on the outcome below.
        // Ladder order: any evaluated-but-not-streamed rung from `variants`, then the
        // REJECTED rungs — so `variants.last` is the terminal rung the ladder stopped
        // on, which is what the failure sheet reads.
        let rejected = (reportVariants + rejectedReportVariants)
            .map { makeVariant(streamed: nil, report: $0, fields: nil) }
        return remoteOutcome(variants: rejected, acceptedCount: 0, fields: fields,
                             timing: timing, latticeReport: latticeReport,
                             buildOrientationJSON: buildOrientation)
    }

    /// Wrap remote variants in an OptimizeOutcome, carrying the run's grid metadata
    /// from fields.bin when present (0 otherwise). The overlays need the grid dims to
    /// index a variant's von Mises / displacement field, so without fields.bin they
    /// stay `isEmpty` (gated) even if — hypothetically — a variant carried arrays.
    private func remoteOutcome(variants: [OptimizeVariant], acceptedCount: Int,
                               fields: RemoteFieldsContainer?,
                               timing: RunTiming? = nil,
                               latticeReport: LatticeReport? = nil,
                               buildOrientationJSON: Data? = nil) -> OptimizeOutcome {
        OptimizeOutcome(variants: variants, stoppedOnMargin: false, cancelled: false,
                        acceptedCount: acceptedCount,
                        voxelVolumeMM3: fields?.voxelVolumeMM3 ?? 0,
                        gridNx: fields?.gridNx ?? 0, gridNy: fields?.gridNy ?? 0,
                        gridNz: fields?.gridNz ?? 0,
                        gridOrigin: fields?.gridOrigin ?? .zero,
                        spacing: fields?.spacing ?? 0,
                        computedRemotely: true,
                        timing: timing,
                        latticeReport: latticeReport,
                        buildOrientationJSON: buildOrientationJSON,
                        // WHICH LADDER RAN (task 2026-08-03-growth-ladder). A LAN
                        // run's report carries the mode in the ONE place that
                        // cannot lie about it: a variant only carries an
                        // `added_material` block when the core measured one, and
                        // the core measures one only on a growth ladder. Derived
                        // from the variants rather than parsed from a separate
                        // field so the mode and the numbers can never disagree.
                        growthLadder: variants.contains { $0.addedMaterial != nil })
    }

    private func makeVariant(streamed s: StreamedVariant?,
                             report rv: [String: Any]?,
                             fields f: RemoteFieldsContainer.Variant?,
                             lattice: LatticeVariantAlternative? = nil) -> OptimizeVariant {
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
            stressTensorField: f?.stressTensor ?? [],
            keyframeMeshes: [],
            // WHY this rung gated as it did (handoff 2026-08-02-gate-diagnosis-
            // recommendations). The SAME object the on-device bridge returns, from
            // the same core emitter, through the same decoder.
            diagnosis: (rv?["diagnosis"] as? [String: Any]).flatMap(GateDiagnosis.decode),
            // WHERE THIS RUNG'S PLASTIC IS (task 2026-08-03-growth-ladder) — the
            // core's own `added_material` block off report.json, the SAME document
            // and the same numbers the on-device bridge hands over. Absent on every
            // reduction run (core emits it only on a growth ladder) → nil, and the
            // results screen shows the savings headline exactly as before.
            addedMaterial: RemoteRun.decodeAddedMaterial(rv),
            // THE LATTICED OBJECT THIS RUNG ALSO PRODUCED (task 2026-08-07-
            // lattice-variants-on-screen). Its mass, margin and verdict, read from
            // its OWN receipt — never the solid's, and never derived from a mesh
            // that has not been transferred. nil on every non-lattice run, so a
            // run that asked for no lattice is byte-identical to before.
            latticeAlternative: lattice)
    }

    /// Decode one variant's `added_material` object from report.json. nil when the
    /// block is absent — a REDUCTION run, or any run predating the growth ladder.
    /// Defensive on every field: a malformed block degrades to nil rather than to a
    /// half-populated record that would render as confident wrong numbers.
    static func decodeAddedMaterial(_ rv: [String: Any]?) -> AddedMaterial? {
        guard let a = rv?["added_material"] as? [String: Any],
              let printed = a["printed_voxels"] as? Int,
              let inside = a["inside_part"] as? Int,
              let outside = a["outside_part"] as? Int else { return nil }
        return AddedMaterial(
            printedVoxels: printed, insidePart: inside, outsidePart: outside,
            partSolidVoxels: a["part_solid_voxels"] as? Int ?? 0,
            outsideFraction: a["outside_fraction"] as? Double ?? 0,
            outsideVolumeMM3: a["outside_volume_mm3"] as? Double ?? 0,
            netAddedVolumeMM3: a["net_added_volume_mm3"] as? Double ?? 0,
            outsideMassGrams: a["outside_mass_grams"] as? Double ?? 0,
            netAddedMassGrams: a["net_added_mass_grams"] as? Double ?? 0,
            targetSaturated: a["growth_target_saturated"] as? Bool ?? false)
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

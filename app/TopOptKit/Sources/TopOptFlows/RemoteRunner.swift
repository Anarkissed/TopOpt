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
// Honest limitations (see docs/handoffs/097 + 093-lan-offload.md STEP 3):
//   * The worker delivers each variant's MESH + the scalar report (volume
//     fraction, margins, orientation, stresses, settings). It does NOT deliver the
//     per-voxel vonMises / displacement / stressTensor fields, the playback
//     keyframes, or the mass. So remote variants render with their margins/settings,
//     but the stress overlay, flex animation, mass readout and playback are
//     UNAVAILABLE. The outcome is flagged `computedRemotely` so the results screen
//     shows those as "computed on Mac — n/a in this build".
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
public struct PersistedRemoteJob: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let fingerprint: String
    public let jobID: String
    public init(host: String, port: Int, fingerprint: String, jobID: String) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.jobID = jobID
    }
}

/// Single-slot store for the active remote job (UserDefaults). Single-slot because
/// only one remote run is in flight at a time; a new submit overwrites, a terminal
/// resolution clears. Deliberately NOT cleared on a client-side liveness failure
/// (watchdog/unreachable): the Mac keeps solving, so the record must survive for a
/// later re-attach — it is cleared only when the WORKER's job is known finished or
/// the user cancelled.
public enum RemoteJobStore {
    static let key = "topopt.activeRemoteJob.v1"

    public static func save(_ job: PersistedRemoteJob, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(job) { defaults.set(data, forKey: key) }
    }
    public static func load(defaults: UserDefaults = .standard) -> PersistedRemoteJob? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedRemoteJob.self, from: data)
    }
    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
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

    // MARK: delegate-queue-only state (URLSession serialises delegate callbacks)
    private var buffer = Data()
    /// Events delivered so far across ALL connections — the dedup high-water mark.
    /// Persists across reconnects (that is the point).
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
        let achievedVF: Double
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
        if let id = jobID {
            RemoteJobStore.save(PersistedRemoteJob(host: config.host, port: config.port,
                                                   fingerprint: config.expectedFingerprint,
                                                   jobID: id), defaults: defaults)
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
                RemoteJobStore.clear(defaults: defaults)
                return cancelledOutcome()
            }
            if let te = te {
                // A worker-reported error is a real terminal outcome (job done on
                // the worker) → clear the re-attach record. A CLIENT-side abort (a
                // mesh-fetch failure via failStream) leaves the Mac's work + the
                // record intact, so a later attempt can still re-attach.
                if fromWorker { RemoteJobStore.clear(defaults: defaults) }
                throw RemoteRunError(te)
            }
            if tc {
                RemoteJobStore.clear(defaults: defaults)
                return cancelledOutcome()
            }
            if tm {
                let outcome = try assembleFinalOutcome()
                RemoteJobStore.clear(defaults: defaults)
                return outcome
            }

            let stale = Date().timeIntervalSince(last) > config.inactivityGrace
            if ended || stale {
                if Date() < nextAttempt { continue }   // waiting out the backoff

                if probeStatus() != nil {
                    // The worker answered — it is alive (running or already finished).
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
        let margin = ev["margin"] as? Double ?? 0
        let accepted = (ev["accepted"] as? Bool) ?? true
        streamedLock.lock()
        streamed.append(StreamedVariant(requestedVF: requestedVF, achievedVF: achievedVF,
                                        margin: margin, accepted: accepted,
                                        meshName: meshName,
                                        vertices: mesh.0, indices: mesh.1))
        streamedLock.unlock()
        let v = OptimizeVariant(
            requestedVolumeFraction: requestedVF,
            achievedVolumeFraction: achievedVF,
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
    /// fetched during streaming. The scalar fields come from the report; the mesh
    /// geometry comes from the recorded streamed variants (never re-derive a
    /// filename). Flagged `computedRemotely` (the CLI does not serialise the
    /// per-voxel fields — see the header).
    private func assembleFinalOutcome() throws -> OptimizeOutcome {
        guard let id = jobID else { throw RemoteRunError("no job id") }
        let base = config.baseURL.appendingPathComponent("jobs")
            .appendingPathComponent(id).appendingPathComponent("files")
        let report = try getJSON(base.appendingPathComponent("report.json"))
        let reportVariants = report["variants"] as? [[String: Any]] ?? []

        streamedLock.lock(); let accepted = streamed; streamedLock.unlock()

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
            let variants = accepted.map { makeVariant(streamed: $0,
                                                      report: reportVariant(forAchieved: $0.achievedVF)) }
            return OptimizeOutcome(variants: variants, stoppedOnMargin: false,
                                   cancelled: false, acceptedCount: variants.count,
                                   computedRemotely: true)
        }

        let rejected = reportVariants.map { makeVariant(streamed: nil, report: $0) }
        return OptimizeOutcome(variants: rejected, stoppedOnMargin: false,
                               cancelled: false, acceptedCount: 0,
                               computedRemotely: true)
    }

    private func makeVariant(streamed s: StreamedVariant?,
                             report rv: [String: Any]?) -> OptimizeVariant {
        let margin = rv?["margin"] as? [String: Any]
        let orient = rv?["orientation"] as? [String: Any]
        let vf = s?.achievedVF ?? (rv?["volume_fraction"] as? Double ?? 0)
        let worst = (margin?["worst_case"] as? Double) ?? (s?.margin) ?? 0
        return OptimizeVariant(
            requestedVolumeFraction: s?.requestedVF ?? vf,
            achievedVolumeFraction: vf,
            massGrams: 0, supportVolumeVoxels: 0,        // not over the wire (header)
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
            meshVertices: s?.vertices ?? [], meshIndices: s?.indices ?? [])
    }

    /// Minimal binary-STL reader → (interleaved xyz floats, triangle-soup indices).
    /// The mesh is unindexed (STL has no shared vertices); fine for display.
    private func parseBinarySTL(_ data: Data) -> ([Float], [Int32]) {
        guard data.count > 84 else { return ([], []) }
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        var verts: [Float] = []; var idx: [Int32] = []
        verts.reserveCapacity(Int(count) * 9)
        var off = 84
        for _ in 0..<Int(count) {
            guard off + 50 <= data.count else { break }
            for v in 0..<3 {
                let base = off + 12 + v * 12
                for c in 0..<3 {
                    let f = data.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: base + c * 4, as: Float32.self)
                    }
                    verts.append(f)
                }
            }
            let n = Int32(idx.count)
            idx.append(contentsOf: [n, n + 1, n + 2])
            off += 50
        }
        return (verts, idx)
    }
}

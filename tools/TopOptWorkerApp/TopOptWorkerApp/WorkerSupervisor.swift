// WorkerSupervisor — owns the EXISTING Python worker (tools/topopt-worker) as a
// supervised subprocess (handoff 097). It does NOT reimplement the HTTP server —
// there is one server implementation, the Python one; this just launches it,
// keeps it alive, and holds a keep-awake assertion while a job runs so the Mac
// never sleeps mid-solve.
//
// Handoff 121 (the worker became human-facing): the app no longer INFERS one
// active job from the worker's stdout. It POLLS the worker's `GET /jobs` — the
// single source of truth for EVERY job (queued/running/done/error/cancelled) — so
// the menu can show a job LIST, offer per-job cancel/pause/reorder, and post a
// macOS completion notification when a job it was watching finishes. The worker's
// queue (default max-concurrency 1) means a second submitted job QUEUES rather
// than spawning a competing, memory-bandwidth-starved solve.
//
// Design: set-and-forget. Start on launch, restart on unexpected exit, surface a
// plain-English problem (missing/old topopt-cli) instead of a dead server.

import Foundation
import AppKit
import Combine
#if canImport(UserNotifications)
import UserNotifications
#endif

/// One job as reported by the worker's `GET /jobs` (handoff 121). Decoded straight
/// from the worker JSON; all progress/timestamp fields are optional because a
/// queued job has no progress yet and a running one has no finish time.
struct WorkerJob: Identifiable, Equatable, Decodable {
    let id: String
    let project: String?
    let state: String        // queued | running | done | error | cancelled
    let paused: Bool
    let rung: Int?
    let rungs: Int?
    let iter: Int?
    let position: Int?
    let createdAt: Double?
    let startedAt: Double?
    let finishedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, project, state, paused, rung, rungs, iter, position
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    var isActive: Bool { state == "queued" || state == "running" }
    var isTerminal: Bool { state == "done" || state == "error" || state == "cancelled" }
    var displayName: String { (project?.isEmpty == false ? project! : nil) ?? "Untitled" }

    /// Human state word for the menu row (a paused running job reads "Paused").
    var stateWord: String {
        switch state {
        case "queued":    return "Queued"
        case "running":   return paused ? "Paused" : "Solving"
        case "done":      return "Done"
        case "error":     return "Failed"
        case "cancelled": return "Cancelled"
        default:          return state.capitalized
        }
    }

    /// "rung 2/4 · iter 41" while solving, "position 2" while queued, else "".
    var progressWord: String {
        if state == "running", let n = rungs {
            let r = (rung ?? 0) + 1
            let i = iter.map { " · iter \($0)" } ?? ""
            return "rung \(r)/\(n)\(i)"
        }
        if state == "queued", let p = position { return "position \(p)" }
        return ""
    }

    /// A short "started 12 min ago" style phrase from the start (or submit) time.
    func startedWord(now: Date = Date()) -> String {
        guard let t = startedAt ?? createdAt else { return "" }
        let secs = max(0, now.timeIntervalSince1970 - t)
        return "started \(Self.age(secs))"
    }

    /// The completion-notification body: project + outcome summary.
    var completionSummary: String {
        switch state {
        case "done":  return "\(displayName): optimization finished"
        case "error": return "\(displayName): optimization failed"
        default:      return "\(displayName): \(stateWord.lowercased())"
        }
    }

    static func age(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        let m = Int(seconds / 60)
        if m < 60 { return "\(m) min ago" }
        let h = Int(seconds / 3600)
        if h < 24 { return "\(h) hour\(h == 1 ? "" : "s") ago" }
        let d = Int(seconds / 86_400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}

private struct JobsResponse: Decodable {
    let jobs: [WorkerJob]
    let maxConcurrency: Int?
    let running: Int?
    let queued: Int?
    enum CodingKeys: String, CodingKey {
        case jobs, running, queued
        case maxConcurrency = "max_concurrency"
    }
}

@MainActor
final class WorkerSupervisor: ObservableObject {

    enum State: Equatable { case stopped, starting, running, failed(String) }

    @Published private(set) var state: State = .stopped
    @Published private(set) var port: Int = 8757
    /// The core fingerprint from `topopt-cli --version`, shown so the user can see
    /// what the iPad will compare against; nil until resolved.
    @Published private(set) var fingerprint: String?
    @Published private(set) var cliVersion: String?
    /// Resolved topopt-cli path, and whether it ran `--version` cleanly.
    @Published private(set) var cliPath: String?
    @Published private(set) var cliOK = false

    /// Every job the worker knows about (handoff 121), polled from `GET /jobs`.
    /// The menu derives its active/queued list + recent completions from this.
    @Published private(set) var jobs: [WorkerJob] = []

    /// User setting: an explicit topopt-cli path when it isn't bundled.
    @Published var cliPathSetting: String {
        didSet { UserDefaults.standard.set(cliPathSetting, forKey: "cliPath") }
    }
    /// Optional completion webhook (handoff 121, requirement 4). Passed to the
    /// worker's `--webhook-url`; a change restarts the worker to take effect. The
    /// documented recipe is an ntfy.sh topic URL for a free phone push.
    @Published var webhookURL: String {
        didSet { UserDefaults.standard.set(webhookURL, forKey: "webhookURL") }
    }
    /// How many solves run at once. Default 1 — solves are memory-bandwidth-bound
    /// (handoff 113), so a second concurrent job runs BOTH slower. Raise only on
    /// hardware with more memory channels.
    @Published var maxConcurrency: Int {
        didSet { UserDefaults.standard.set(maxConcurrency, forKey: "maxConcurrency") }
    }
    /// Launch-at-login, backed by SMAppService (see LoginItem).
    @Published var launchAtLogin: Bool {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    private var process: Process?
    private var shouldRun = false
    private var restartWorkItem: DispatchWorkItem?
    /// The keep-awake assertion, held ONLY while ≥1 job is running.
    private var sleepAssertion: (any NSObjectProtocol)?
    /// Per-job last-seen state, so a transition INTO a terminal state fires exactly
    /// one notification — and only for jobs the app actually watched change (a
    /// pre-existing completed job at launch never fires; honest, no spam).
    private var lastStates: [String: String] = [:]
    private var pollTimer: Timer?

    /// The worker's scratch dir (passed explicitly as --workdir so each job's
    /// on-disk folder — <workDir>/<job-id> — is known for "Show in Finder").
    let workDir: URL =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".topopt-worker")

    let bonjour = BonjourAdvertiser()

    static let shared = WorkerSupervisor()

    init() {
        cliPathSetting = UserDefaults.standard.string(forKey: "cliPath") ?? ""
        webhookURL = UserDefaults.standard.string(forKey: "webhookURL") ?? ""
        let mc = UserDefaults.standard.integer(forKey: "maxConcurrency")
        maxConcurrency = mc > 0 ? mc : 1
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - UI helpers

    var isRunning: Bool { if case .running = state { return true }; return false }

    /// Active (queued/running) jobs, most-recent first — the top menu section.
    var activeJobs: [WorkerJob] {
        jobs.filter { $0.isActive }
            .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
    }
    /// Recent completions (done/error/cancelled), newest first, capped for the menu.
    var recentCompletions: [WorkerJob] {
        jobs.filter { $0.isTerminal }
            .sorted { ($0.finishedAt ?? 0) > ($1.finishedAt ?? 0) }
            .prefix(5).map { $0 }
    }
    var activeJobCount: Int { jobs.filter { $0.state == "running" }.count }
    private var hasRunningJob: Bool { jobs.contains { $0.state == "running" } }

    var menuBarSymbol: String {
        switch state {
        case .running:  return activeJobCount > 0 ? "cpu.fill" : "cpu"
        case .starting: return "cpu"
        case .stopped:  return "cpu"
        case .failed:   return "exclamationmark.triangle.fill"
        }
    }

    var statusText: String {
        switch state {
        case .running:
            let q = jobs.filter { $0.state == "queued" }.count
            let base = "Worker running · port \(port)"
            return q > 0 ? "\(base) · \(q) queued" : base
        case .starting: return "Starting worker…"
        case .stopped:  return "Worker stopped"
        case .failed(let m): return "Problem: \(m)"
        }
    }

    // MARK: - Lifecycle

    /// Start (or restart) the worker. Idempotent while running.
    func start() {
        shouldRun = true
        restartWorkItem?.cancel()
        guard process == nil else { return }
        state = .starting

        guard let python = Self.pythonPath else {
            state = .failed("Python 3 not found at /usr/bin/python3."); return
        }
        guard let script = Self.workerScriptPath else {
            state = .failed("Bundled worker script is missing from the app."); return
        }
        guard let cli = resolveCLI() else {
            state = .failed("topopt-cli not found. Set its path in Settings, or build "
                          + "it: cmake --build core/build --target topopt_cli")
            return
        }
        cliPath = cli
        // Probe the CLI up front so a missing/old binary is a clear message, not a
        // server that starts then rejects every job.
        probeCLI(cli)
        guard cliOK else {
            state = .failed("topopt-cli at \(cli) failed `--version`. Rebuild it: "
                          + "cmake --build core/build --target topopt_cli")
            return
        }

        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        var args = [script, "--cli", cli, "--host", "0.0.0.0", "--port", "\(port)",
                    "--workdir", workDir.path, "--max-concurrency", "\(maxConcurrency)"]
        let hook = webhookURL.trimmingCharacters(in: .whitespaces)
        if !hook.isEmpty { args += ["--webhook-url", hook] }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        // Drain stdout/stderr so the worker never blocks on a full pipe (it prints a
        // STATUS line per iteration). We no longer PARSE it for job state — that
        // comes from GET /jobs — but the pipe must still be read.
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.workerTerminated(proc.terminationStatus) }
        }

        do {
            try p.run()
            process = p
            state = .running
            bonjour.publish(port: port, fingerprint: fingerprint ?? "unknown")
            startPolling()
        } catch {
            state = .failed("Could not launch the worker: \(error.localizedDescription)")
        }
    }

    /// Stop the worker and stand down discovery + keep-awake. Stays stopped until
    /// the user starts it again.
    func stop() {
        shouldRun = false
        restartWorkItem?.cancel()
        stopPolling()
        bonjour.stop()
        process?.terminate()
        process = nil
        jobs = []
        lastStates = [:]
        updateKeepAwake()
        state = .stopped
    }

    func restart() { stop(); start() }

    private func workerTerminated(_ status: Int32) {
        process = nil
        stopPolling()
        bonjour.stop()
        jobs = []
        updateKeepAwake()
        guard shouldRun else { return }   // a deliberate stop
        // Unexpected exit — surface it, then auto-restart after a short backoff so a
        // transient crash self-heals without the user thinking about it.
        state = .failed("Worker exited (code \(status)) — restarting…")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun, self.process == nil else { return }
            self.start()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - job polling (GET /jobs, handoff 121)

    private func startPolling() {
        stopPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollJobs() }
        }
        pollTimer = timer
        Task { @MainActor in await self.pollJobs() }   // one immediate poll
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollJobs() async {
        guard isRunning, let url = URL(string: "http://127.0.0.1:\(port)/jobs") else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(JobsResponse.self, from: data)
            applyJobs(decoded.jobs)
        } catch {
            // Transient (worker still coming up, momentary refusal). The next tick
            // retries; we do not surface it as a failure.
        }
    }

    /// Fold a fresh /jobs snapshot in: detect completion transitions (→ notify),
    /// update the published list, and refresh keep-awake.
    private func applyJobs(_ incoming: [WorkerJob]) {
        for job in incoming {
            let prev = lastStates[job.id]
            // Fire ONLY on a genuine transition into a finished state we watched
            // change. A job first seen already-terminal (app launched after it
            // finished) never notifies — honest, no launch-time spam.
            if let prev, prev != job.state, (job.state == "done" || job.state == "error") {
                notifyCompletion(job)
            }
            lastStates[job.id] = job.state
        }
        jobs = incoming
        updateKeepAwake()
    }

    // MARK: - per-job actions (POST/DELETE to the worker)

    func cancel(_ job: WorkerJob) { jobAction(job.id, method: "DELETE", suffix: "") }
    func moveToFront(_ job: WorkerJob) { jobAction(job.id, method: "POST", suffix: "/front") }
    func pause(_ job: WorkerJob) { jobAction(job.id, method: "POST", suffix: "/pause") }
    func resume(_ job: WorkerJob) { jobAction(job.id, method: "POST", suffix: "/resume") }

    private func jobAction(_ id: String, method: String, suffix: String) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/jobs/\(id)\(suffix)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 5
        Task { @MainActor in
            _ = try? await URLSession.shared.data(for: req)
            await self.pollJobs()   // reflect the change immediately
        }
    }

    /// Reveal a job's on-disk workdir in Finder (the menu's "Show in Finder" and the
    /// notification click both land here). <workDir>/<job-id> holds worker.log +
    /// out/ (report, meshes).
    func revealWorkdir(forJob id: String) {
        let dir = workDir.appendingPathComponent(id)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: - completion notification (UserNotifications)

    private func notifyCompletion(_ job: WorkerJob) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = job.state == "done" ? "TopOpt — run finished" : "TopOpt — run failed"
        content.body = job.completionSummary
        content.sound = .default
        // Carry the workdir so a click reveals it (see the delegate in the app).
        content.userInfo = ["workdirJobID": job.id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "job-\(job.id)", content: content, trigger: nil))
        #endif
    }

    // MARK: - keep-awake (only while a job runs)

    private func updateKeepAwake() {
        if hasRunningJob, sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "TopOpt optimize running on this Mac")
        } else if !hasRunningJob, let token = sleepAssertion {
            ProcessInfo.processInfo.endActivity(token)
            sleepAssertion = nil
        }
    }

    // MARK: - CLI resolution + probe

    /// Bundled topopt-cli if present, else the user's settings path. (handoff 097)
    private func resolveCLI() -> String? {
        if let bundled = Bundle.main.path(forResource: "topopt-cli", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let s = cliPathSetting.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        return nil
    }

    private func probeCLI(_ cli: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["--version"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            var kv: [String: String] = [:]
            for tok in out.split(separator: " ") where tok.contains("=") {
                let parts = tok.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { kv[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            cliVersion = kv["version"]
            fingerprint = kv["fingerprint"]
            cliOK = (p.terminationStatus == 0) && (fingerprint != nil)
        } catch {
            cliOK = false
        }
    }

    /// The rebuild command the menu surfaces (for "Update core…" + CLI-missing).
    static let rebuildCommand =
        "git -C <repo> pull && cmake --build core/build --target topopt_cli"

    private static let pythonPath: String? = {
        for p in ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    private static let workerScriptPath: String? = {
        Bundle.main.path(forResource: "topopt_worker", ofType: "py")
    }()
}

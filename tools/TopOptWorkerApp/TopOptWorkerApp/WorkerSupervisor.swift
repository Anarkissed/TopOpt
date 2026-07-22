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

// `WorkerJob`, `JobsResponse`, `WorkerHealth`, `JobAction`, `JobControls`, and
// `WorkerClient` now live in WorkerClient.swift (the shared, Foundation-only action
// layer, handoff 124) so the menu, the window, and the SwiftPM tests all agree on
// one definition of a job, one per-state control list, and one set of requests.

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

    /// Whether the last poll reached the worker. While the process is up but the HTTP
    /// server is unreachable (starting, wedged), the window shows an HONEST unreachable
    /// state rather than a frozen-but-green UI (handoff 124, item 8).
    @Published private(set) var reachable = false

    /// When the current worker process started — the window header's uptime readout.
    @Published private(set) var workerStartedAt: Date?

    /// Consecutive failed polls; `reachable` flips false after a couple so a single
    /// dropped tick doesn't flicker the UI.
    private var pollFailures = 0

    /// The one request factory both faces + the supervisor use (handoff 124).
    var client: WorkerClient { WorkerClient(port: port) }

    /// A job the window should scroll to / highlight, set when a menu job row is
    /// clicked to open the window (handoff 124, item 5). Cleared once consumed.
    @Published var focusedJobID: String?

    var queuedCount: Int { jobs.filter { $0.state == "queued" }.count }

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
    /// The port the worker binds. Editable in Settings; takes effect on restart (the
    /// live `port` is updated in `start()`). Default 8757 (handoff 097).
    @Published var portSetting: Int {
        didSet { UserDefaults.standard.set(portSetting, forKey: "port") }
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
        let savedPort = UserDefaults.standard.integer(forKey: "port")
        portSetting = savedPort > 0 ? savedPort : 8757
        port = savedPort > 0 ? savedPort : 8757
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

    /// The window header's one-word liveness treatment. A running-but-paused job reads
    /// "Paused"; an up-but-unreachable server reads "Unreachable" (honest, item 8).
    enum Liveness { case solving, paused, idle, unreachable, stopped, starting }
    var liveness: Liveness {
        switch state {
        case .stopped, .failed: return .stopped
        case .starting:         return .starting
        case .running:
            if !reachable { return .unreachable }
            if jobs.contains(where: { $0.state == "running" && !$0.paused }) { return .solving }
            if jobs.contains(where: { $0.state == "running" && $0.paused }) { return .paused }
            return .idle
        }
    }

    /// Uptime of the current worker process, e.g. "up 12 min". Empty when stopped.
    func uptimeText(now: Date = Date()) -> String {
        guard let s = workerStartedAt, isRunning else { return "" }
        return "up " + WorkerJob.duration(max(0, now.timeIntervalSince(s)))
    }

    // MARK: - Lifecycle

    /// Start (or restart) the worker. Idempotent while running.
    func start() {
        shouldRun = true
        restartWorkItem?.cancel()
        guard process == nil else { return }
        port = portSetting          // apply any Settings change on (re)start
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
            workerStartedAt = Date()
            reachable = false          // until the first successful poll
            pollFailures = 0
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
        reachable = false
        workerStartedAt = nil
        updateKeepAwake()
        state = .stopped
    }

    func restart() { stop(); start() }

    private func workerTerminated(_ status: Int32) {
        process = nil
        stopPolling()
        bonjour.stop()
        jobs = []
        reachable = false
        workerStartedAt = nil
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
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollJobs() }
        }
        // `.common` so the poll keeps firing while a native menu is tracking — the
        // default run-loop mode is starved during menu tracking, which is exactly why
        // the rung/iter readout used to freeze the moment you opened the menu
        // (handoff 124, item 1: "keep it updating live while the menu is open").
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        Task { @MainActor in await self.pollJobs() }   // one immediate poll
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollJobs() async {
        guard isRunning else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: client.jobsRequest())
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(JobsResponse.self, from: data)
            pollFailures = 0
            reachable = true
            applyJobs(decoded.jobs)
        } catch {
            // Transient (worker still coming up, momentary refusal). A single miss is
            // ignored; two in a row flips `reachable` false so the window shows the
            // honest unreachable state (handoff 124, item 8). The next tick retries.
            pollFailures += 1
            if pollFailures >= 2 { reachable = false }
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

    // MARK: - per-job actions (POST/DELETE to the worker, handoff 124)
    //
    // ONE action path. The menu and the window both call `perform(_:on:)`, which routes
    // through the shared `WorkerClient` — so a control on either face fires the identical
    // request (proven in WorkerKitTests). The named wrappers are call-site sugar.

    func perform(_ action: JobAction, on job: WorkerJob) {
        let request = client.request(action, job: job.id)
        Task { @MainActor in
            _ = try? await URLSession.shared.data(for: request)
            await self.pollJobs()   // reflect the change immediately
        }
    }

    func cancel(_ job: WorkerJob) { perform(.cancel, on: job) }
    func moveToFront(_ job: WorkerJob) { perform(.moveToFront, on: job) }
    func pause(_ job: WorkerJob) { perform(.pause, on: job) }
    func resume(_ job: WorkerJob) { perform(.resume, on: job) }

    /// Reveal a job's on-disk workdir in Finder (the menu's "Show in Finder" and the
    /// notification click both land here). <workDir>/<job-id> holds worker.log +
    /// out/ (report, meshes).
    func revealWorkdir(forJob id: String) {
        let dir = workDir.appendingPathComponent(id)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// The id of the most interesting job for the log tail: a running one if any, else
    /// the most recently created. Nil when there are no jobs.
    var newestJobID: String? {
        jobs.first(where: { $0.state == "running" })?.id
            ?? jobs.sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }.first?.id
    }

    /// Last `lines` of a job's worker.log (handoff 124, item 7 — the collapsible log
    /// tail). Read on demand (no timer polls the file); the window offers a Refresh.
    /// Returns a friendly message rather than throwing when there is nothing to show.
    func tailWorkerLog(forJob id: String, lines: Int = 50) -> String {
        let path = workDir.appendingPathComponent(id).appendingPathComponent("worker.log")
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else {
            return "No worker.log yet for this job."
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
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

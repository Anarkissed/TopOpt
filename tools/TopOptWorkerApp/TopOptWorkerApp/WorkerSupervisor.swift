// WorkerSupervisor — owns the EXISTING Python worker (tools/topopt-worker) as a
// supervised subprocess (handoff 097). It does NOT reimplement the HTTP server —
// there is one server implementation, the Python one; this just launches it,
// keeps it alive, reads its stdout to show the active job, and holds a keep-awake
// assertion while a job runs so the Mac never sleeps mid-solve.
//
// Design: set-and-forget. Start on launch, restart on unexpected exit, surface a
// plain-English problem (missing/old topopt-cli) instead of a dead server.

import Foundation
import Combine

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
    /// The active job's live label ("rung 2/3 · iter 41"), or nil when idle.
    @Published private(set) var activeJobLabel: String?
    @Published private(set) var activeJobCount = 0

    /// User setting: an explicit topopt-cli path when it isn't bundled.
    @Published var cliPathSetting: String {
        didSet { UserDefaults.standard.set(cliPathSetting, forKey: "cliPath") }
    }
    /// Launch-at-login, backed by SMAppService (see LoginItem).
    @Published var launchAtLogin: Bool {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    private var process: Process?
    private var shouldRun = false
    private var restartWorkItem: DispatchWorkItem?
    /// Per-job state parsed from the worker's stdout STATUS lines.
    private var runningJobs = Set<String>()
    /// The keep-awake assertion, held ONLY while ≥1 job is running.
    private var sleepAssertion: (any NSObjectProtocol)?

    let bonjour = BonjourAdvertiser()

    static let shared = WorkerSupervisor()

    init() {
        cliPathSetting = UserDefaults.standard.string(forKey: "cliPath") ?? ""
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - UI helpers

    var isRunning: Bool { if case .running = state { return true }; return false }

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
        case .running:  return "Worker running · port \(port)"
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

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script, "--cli", cli, "--host", "0.0.0.0", "--port", "\(port)"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingestStdout(text) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.workerTerminated(proc.terminationStatus) }
        }

        do {
            try p.run()
            process = p
            state = .running
            bonjour.publish(port: port, fingerprint: fingerprint ?? "unknown")
        } catch {
            state = .failed("Could not launch the worker: \(error.localizedDescription)")
        }
    }

    /// Stop the worker and stand down discovery + keep-awake. Stays stopped until
    /// the user starts it again.
    func stop() {
        shouldRun = false
        restartWorkItem?.cancel()
        bonjour.stop()
        process?.terminate()
        process = nil
        runningJobs.removeAll()
        updateKeepAwake()
        activeJobLabel = nil
        activeJobCount = 0
        state = .stopped
    }

    func restart() { stop(); start() }

    private func workerTerminated(_ status: Int32) {
        process = nil
        bonjour.stop()
        runningJobs.removeAll()
        updateKeepAwake()
        activeJobLabel = nil; activeJobCount = 0
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

    // MARK: - stdout parsing

    private var stdoutBuffer = ""

    private func ingestStdout(_ text: String) {
        stdoutBuffer += text
        while let nl = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<nl])
            stdoutBuffer.removeSubrange(...nl)
            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        guard line.hasPrefix("STATUS ") else { return }   // banner + other logs: ignored
        var kv: [String: String] = [:]
        for tok in line.dropFirst(7).split(separator: " ") where tok.contains("=") {
            let parts = tok.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { kv[String(parts[0])] = String(parts[1]) }
        }
        guard let job = kv["job"], let jstate = kv["state"] else { return }
        switch jstate {
        case "running":
            runningJobs.insert(job)
            if let r = kv["rung"], let n = kv["rungs"], let i = kv["iter"] {
                activeJobLabel = "rung \(Int(r).map { $0 + 1 } ?? 1)/\(n) · iter \(i)"
            } else if let mesh = kv["variant"] {
                activeJobLabel = "variant \(mesh) ready"
            }
        default:   // done | error | cancelled
            runningJobs.remove(job)
            if runningJobs.isEmpty { activeJobLabel = nil }
        }
        activeJobCount = runningJobs.count
        updateKeepAwake()
    }

    // MARK: - keep-awake (only while a job runs)

    private func updateKeepAwake() {
        let jobRunning = !runningJobs.isEmpty
        if jobRunning, sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "TopOpt optimize running on this Mac")
        } else if !jobRunning, let token = sleepAssertion {
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

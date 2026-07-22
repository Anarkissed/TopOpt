// WorkerClient — the ONE action layer between the app and the Python worker
// (handoff 124). The app now has TWO faces: the compact MenuBarExtra and the full
// main Window. Both must drive the worker through IDENTICAL HTTP requests — a
// "Cancel" in the menu and a "Cancel" on a window card have to be the same DELETE,
// or the two surfaces silently diverge. So the request-building and the per-state
// control list live here, once, and both faces render from them.
//
// This file is deliberately Foundation-only (no SwiftUI/AppKit) so it compiles into
// the app target AND a standalone SwiftPM test target (WorkerKitTests) that proves
// the menu and the window build the same requests — see the test package alongside.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// The job model, decoded straight from the worker's `GET /jobs` rows. All progress
// / timestamp fields are optional: a queued job has no progress yet, a running one
// has no finish time. (Moved here from WorkerSupervisor in 124 so both faces + the
// tests share one definition.)

public struct WorkerJob: Identifiable, Equatable, Decodable, Sendable {
    public let id: String
    public let project: String?
    public let state: String        // queued | running | done | error | cancelled
    public let paused: Bool
    public let rung: Int?
    public let rungs: Int?
    public let iter: Int?
    /// Accepted variant meshes so far (handoff 124) — a real count for the History pane.
    public let variants: Int?
    public let position: Int?
    public let createdAt: Double?
    public let startedAt: Double?
    public let finishedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, project, state, paused, rung, rungs, iter, variants, position
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    public init(id: String, project: String? = nil, state: String, paused: Bool = false,
                rung: Int? = nil, rungs: Int? = nil, iter: Int? = nil, variants: Int? = nil,
                position: Int? = nil, createdAt: Double? = nil, startedAt: Double? = nil,
                finishedAt: Double? = nil) {
        self.id = id; self.project = project; self.state = state; self.paused = paused
        self.rung = rung; self.rungs = rungs; self.iter = iter; self.variants = variants
        self.position = position
        self.createdAt = createdAt; self.startedAt = startedAt; self.finishedAt = finishedAt
    }

    public var isActive: Bool { state == "queued" || state == "running" }
    public var isTerminal: Bool { state == "done" || state == "error" || state == "cancelled" }

    /// A stable short form of the job id — the fallback the menu + window show when a
    /// job carries no project name (handoff 124, item 2). The worker id is a 16-char
    /// hex; the first 8 are plenty to tell two jobs apart in a list.
    public var shortID: String { String(id.prefix(8)) }

    /// The row title. A real project name if the app sent one; otherwise the job's
    /// short id — NEVER the old "Untitled" placeholder (handoff 124, item 2).
    public var displayName: String {
        if let p = project, !p.trimmingCharacters(in: .whitespaces).isEmpty { return p }
        return "Job \(shortID)"
    }

    /// Human state word (a paused running job reads "Paused").
    public var stateWord: String {
        switch state {
        case "queued":    return "Queued"
        case "running":   return paused ? "Paused" : "Solving"
        case "done":      return "Done"
        case "error":     return "Failed"
        case "cancelled": return "Cancelled"
        default:          return state.capitalized
        }
    }

    /// The daily-driver telemetry (handoff 124, item 1): "rung 4/4 · iter 106" while
    /// solving, "position 2" while queued, else "". `rung` is 0-based on the wire.
    public var progressWord: String {
        if state == "running", let n = rungs {
            let r = (rung ?? 0) + 1
            let i = iter.map { " · iter \($0)" } ?? ""
            return "rung \(r)/\(n)\(i)"
        }
        if state == "queued", let p = position { return "position \(p)" }
        return ""
    }

    /// Fractional progress 0…1 for a bar, from rung + iter within the ladder. Nil when
    /// there is nothing real to show (queued / no ticks yet) — the bar stays honest and
    /// indeterminate rather than inventing a value (handoff 124, item 8).
    public func fractionComplete(itersPerRung: Int = 60) -> Double? {
        guard state == "running", let n = rungs, n > 0 else { return nil }
        let r = Double(rung ?? 0)
        let within = Swift.min(1.0, Double(iter ?? 0) / Double(max(1, itersPerRung)))
        return Swift.min(1.0, (r + within) / Double(n))
    }

    /// "started 12 min ago" from the start (or submit) time.
    public func startedWord(now: Date = Date()) -> String {
        guard let t = startedAt ?? createdAt else { return "" }
        return "started \(Self.age(max(0, now.timeIntervalSince1970 - t)))"
    }

    /// Elapsed wall time as a compact string, for the window's card + history.
    public func elapsedWord(now: Date = Date()) -> String {
        guard let s = startedAt else { return "" }
        let end = finishedAt ?? now.timeIntervalSince1970
        return Self.duration(max(0, end - s))
    }

    /// The History row's outcome summary: real accepted-variant count + duration for a
    /// finished run, the reason for a stopped one. Honest — no fabricated numbers.
    public func outcomeSummary(now: Date = Date()) -> String {
        let dur = elapsedWord(now: now)
        switch state {
        case "done":
            let n = variants ?? 0
            let v = "\(n) variant\(n == 1 ? "" : "s")"
            return dur.isEmpty ? v : "\(v) · \(dur)"
        case "error":     return dur.isEmpty ? "failed" : "failed · \(dur)"
        case "cancelled": return dur.isEmpty ? "cancelled" : "cancelled · \(dur)"
        default:          return dur
        }
    }

    /// A rough live ETA for a running job, from real elapsed time × remaining fraction.
    /// Nil until there is an honest fraction to extrapolate from (handoff 124, item 8 —
    /// approximate but a real computation, never a placeholder). Prefixed "~" by callers.
    public func etaWord(now: Date = Date(), itersPerRung: Int = 60) -> String? {
        guard state == "running", !paused, let f = fractionComplete(itersPerRung: itersPerRung),
              f > 0.02, f < 0.999, let s = startedAt else { return nil }
        let elapsed = max(0, now.timeIntervalSince1970 - s)
        let remaining = elapsed * (1 - f) / f
        return "~\(Self.duration(remaining)) left"
    }

    /// The completion-notification body: project + outcome summary.
    public var completionSummary: String {
        switch state {
        case "done":  return "\(displayName): optimization finished"
        case "error": return "\(displayName): optimization failed"
        default:      return "\(displayName): \(stateWord.lowercased())"
        }
    }

    public static func age(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        let m = Int(seconds / 60)
        if m < 60 { return "\(m) min ago" }
        let h = Int(seconds / 3600)
        if h < 24 { return "\(h) hour\(h == 1 ? "" : "s") ago" }
        let d = Int(seconds / 86_400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60, rem = s % 60
        if m < 60 { return rem == 0 ? "\(m)m" : "\(m)m \(rem)s" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h)h" : "\(h)h \(mm)m"
    }
}

/// The `GET /jobs` envelope: the rows plus the queue summary.
public struct JobsResponse: Decodable, Sendable {
    public let jobs: [WorkerJob]
    public let maxConcurrency: Int?
    public let running: Int?
    public let queued: Int?
    enum CodingKeys: String, CodingKey {
        case jobs, running, queued
        case maxConcurrency = "max_concurrency"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The worker's health/identity, decoded from `GET /health` — the honest chrome the
// window header shows (handoff 124, item 7/8). Every field is a real readout; a
// worker that can't run the CLI reports ok=false and the UI shows that, not a frozen
// green light.

public struct WorkerHealth: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let workerVersion: String?
    public let cli: String?
    public let cliVersion: String?
    public let fingerprint: String?
    public let activeJobs: Int?
    public let queuedJobs: Int?
    public let maxConcurrency: Int?
    enum CodingKeys: String, CodingKey {
        case ok, cli, fingerprint
        case workerVersion = "worker_version"
        case cliVersion = "cli_version"
        case activeJobs = "active_jobs"
        case queuedJobs = "queued_jobs"
        case maxConcurrency = "max_concurrency"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The HTTP action a job control performs. The pathSuffix + method here are the
// SINGLE definition both faces (and the worker's routing) agree on.

public enum JobAction: String, CaseIterable, Sendable {
    case moveToFront
    case pause
    case resume
    case cancel

    /// DELETE cancels; everything else is a POST (matches the worker's do_POST /
    /// do_DELETE routing).
    public var httpMethod: String { self == .cancel ? "DELETE" : "POST" }

    /// Appended after `/jobs/{id}`. Cancel targets the job itself (no suffix).
    public var pathSuffix: String {
        switch self {
        case .cancel:      return ""
        case .pause:       return "/pause"
        case .resume:      return "/resume"
        case .moveToFront: return "/front"
        }
    }

    public var systemImage: String {
        switch self {
        case .moveToFront: return "arrow.up.to.line"
        case .pause:       return "pause.fill"
        case .resume:      return "play.fill"
        case .cancel:      return "xmark"
        }
    }

    /// Default label. Cancel's wording is state-dependent, so callers use
    /// `JobControls.title(of:for:)` which special-cases it.
    public var defaultTitle: String {
        switch self {
        case .moveToFront: return "Move to front"
        case .pause:       return "Pause"
        case .resume:      return "Resume"
        case .cancel:      return "Cancel"
        }
    }

    public var isDestructive: Bool { self == .cancel }
}

/// The controls a job offers, derived from its state — the SAME list drives the menu
/// submenu and the window card so the two faces can never drift (handoff 124, the
/// unified action layer). Terminal jobs expose no HTTP control (Finder-only).
public enum JobControls {
    public static func actions(for job: WorkerJob) -> [JobAction] {
        switch job.state {
        case "running": return [job.paused ? .resume : .pause, .cancel]
        case "queued":  return [.moveToFront, .cancel]
        default:        return []
        }
    }

    /// The label a control shows for a given job. Only Cancel varies: a queued job is
    /// "Remove from queue"; a running one is "Cancel".
    public static func title(of action: JobAction, for job: WorkerJob) -> String {
        if action == .cancel { return job.state == "queued" ? "Remove from queue" : "Cancel" }
        return action.defaultTitle
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The request factory. Both faces obtain their URLRequests here; nothing else in the
// app constructs a worker URL.

public struct WorkerClient: Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String = "127.0.0.1", port: Int) {
        self.host = host
        self.port = port
    }

    public var baseURLString: String { "http://\(host):\(port)" }

    /// `GET /jobs` — the poll both faces read from.
    public func jobsRequest(timeout: TimeInterval = 4) -> URLRequest {
        get("/jobs", timeout: timeout)
    }

    /// `GET /health` — the identity/liveness probe the window header shows.
    public func healthRequest(timeout: TimeInterval = 4) -> URLRequest {
        get("/health", timeout: timeout)
    }

    /// The request for a per-job control. This is the method both the menu and the
    /// window call — identical bytes on the wire from either face.
    public func request(_ action: JobAction, job jobID: String,
                        timeout: TimeInterval = 5) -> URLRequest {
        var req = URLRequest(url: url("/jobs/\(jobID)\(action.pathSuffix)"))
        req.httpMethod = action.httpMethod
        req.timeoutInterval = timeout
        return req
    }

    // MARK: internals

    private func get(_ path: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        return req
    }

    private func url(_ path: String) -> URL {
        // The worker binds numeric host:port on the LAN, so a plain string URL is
        // exact and needs no percent-encoding (job ids are hex).
        guard let u = URL(string: baseURLString + path) else {
            preconditionFailure("worker URL could not be formed for \(path)")
        }
        return u
    }
}

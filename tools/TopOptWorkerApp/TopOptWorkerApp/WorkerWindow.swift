// WorkerWindow — the TopOpt Worker's main window (handoff 124, items 5–8). The
// MenuBarExtra stays the compact face; this is the large, beautiful surface that opens
// from the menu ("Open TopOpt Worker") or a job-row click, and closes back down to the
// menu item (LSUIElement lifecycle — closing the window never quits the app).
//
// It shows what the menu can't fit: the worker's identity header, the queue as glass
// cards with real progress, a history of finished runs, the settings pane (absorbing
// the old Settings sheet), and an optional live log tail. Every number is a real
// readout from /jobs or the CLI probe — a dead worker shows the honest unreachable
// state, not a frozen UI (item 8). All chrome is static (item 6): the only motion is a
// value changing when a poll delivers a new one.

import SwiftUI
import AppKit

struct WorkerWindow: View {
    @ObservedObject var supervisor: WorkerSupervisor

    enum Section: String, CaseIterable, Identifiable {
        case queue = "Queue", history = "History", settings = "Settings", log = "Log"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .queue: return "square.stack.3d.up"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "slider.horizontal.3"
            case .log: return "text.alignleft"
            }
        }
    }
    /// QA-only: the section to open on first render (defaults to Queue in normal use).
    var initialSection: Section = .queue
    @State private var section: Section = .queue

    var body: some View {
        VStack(spacing: 0) {
            WorkerHeader(supervisor: supervisor)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)

            sectionPicker
                .padding(.horizontal, 20).padding(.bottom, 8)

            Divider().overlay(Color.white.opacity(0.06))

            Group {
                switch section {
                case .queue:    QueuePane(supervisor: supervisor)
                case .history:  HistoryPane(supervisor: supervisor)
                case .settings: WorkerSettingsPane(supervisor: supervisor)
                case .log:      LogPane(supervisor: supervisor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 600)
        .workerStage()
        .foregroundStyle(WD.Palette.textPrimary)
        .onChange(of: supervisor.focusedJobID) { id in
            if id != nil { section = .queue }   // a menu row opened us → show the queue
        }
        .onAppear { section = initialSection }
    }

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(Section.allCases) { s in
                let selected = s == section
                Button {
                    section = s
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: s.symbol).font(.system(size: 11, weight: .semibold))
                        Text(s.rawValue).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundStyle(selected ? WD.Palette.accent : WD.Palette.textSecondary)
                    .workerGlassCapsule(selected ? .blue : .neutral, specular: selected ? 1 : 0.5)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Header — worker identity (item 7): status, port, core fingerprint + version, uptime,
// a live/paused treatment, and Start/Stop.

private struct WorkerHeader: View {
    @ObservedObject var supervisor: WorkerSupervisor

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            StatusDot(color: supervisor.liveness.color, diameter: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text("TopOpt Worker").font(.system(size: 17, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(WD.Palette.textSecondary)
            }
            Spacer()
            HStack(spacing: 6) {
                if let fp = supervisor.fingerprint {
                    GlassPill(text: "core \(fp)", systemImage: "cpu", tint: .blue)
                }
                if let v = supervisor.cliVersion {
                    GlassPill(text: v, systemImage: "number")
                }
                if supervisor.isRunning, case let up = supervisor.uptimeText(), !up.isEmpty {
                    GlassPill(text: up, systemImage: "clock")
                }
            }
            Button(supervisor.isRunning ? "Stop" : "Start") {
                supervisor.isRunning ? supervisor.stop() : supervisor.start()
            }
            .buttonStyle(GlassButtonStyle(tint: supervisor.isRunning ? .red : .blue))
        }
    }

    private var subtitle: String {
        var parts = [supervisor.liveness.label]
        if supervisor.isRunning {
            parts.append("port \(supervisor.port)")
            if supervisor.queuedCount > 0 { parts.append("\(supervisor.queuedCount) queued") }
        }
        return parts.joined(separator: " · ")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue — active/queued jobs as glass cards (item 7).

private struct QueuePane: View {
    @ObservedObject var supervisor: WorkerSupervisor

    var body: some View {
        ScrollViewReader { proxy in
            FlexScroll {
                VStack(spacing: 12) {
                    if !supervisor.isRunning {
                        EmptyStatePane(symbol: "cpu",
                                       title: supervisor.liveness == .unreachable
                                            ? "Worker unreachable" : "Worker stopped",
                                       message: supervisor.liveness == .unreachable
                                            ? "The process is up but not answering on port \(supervisor.port)."
                                            : "Start the worker to accept runs from the iPad.")
                    } else if supervisor.activeJobs.isEmpty {
                        EmptyStatePane(symbol: "tray", title: "No active jobs",
                                       message: "Ready for a run · max concurrency \(supervisor.maxConcurrency)")
                    } else {
                        ForEach(supervisor.activeJobs) { job in
                            JobCard(job: job, supervisor: supervisor)
                                .id(job.id)
                        }
                    }
                }
                .padding(20)
            }
            .onChange(of: supervisor.focusedJobID) { id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
                supervisor.focusedJobID = nil
            }
        }
    }
}

private struct JobCard: View {
    let job: WorkerJob
    @ObservedObject var supervisor: WorkerSupervisor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StatusDot(color: job.accentColor)
                Text(job.displayName).font(.system(size: 14, weight: .semibold))
                Spacer()
                GlassPill(text: job.stateWord,
                          tint: job.state == "running" && !job.paused ? .frost(job.accentColor, 0.5) : .neutral)
            }

            if job.state == "running" {
                HStack(spacing: 10) {
                    HonestBar(fraction: job.fractionComplete(), tint: job.accentColor)
                    Text(job.progressWord.isEmpty ? "starting…" : job.progressWord)
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(WD.Palette.textSecondary)
                        .fixedSize()
                }
            }

            HStack(spacing: 8) {
                Text(metaLine).font(.system(size: 11)).foregroundStyle(WD.Palette.textTertiary)
                Spacer()
                controls
            }
        }
        .padding(16)
        .workerGlass(.neutral)
    }

    private var metaLine: String {
        var parts: [String] = []
        let started = job.startedWord()
        if !started.isEmpty { parts.append(started) }
        if let eta = job.etaWord() { parts.append(eta) }
        else if job.state == "queued", let p = job.position { parts.append("position \(p)") }
        return parts.joined(separator: " · ")
    }

    private var controls: some View {
        HStack(spacing: 6) {
            ForEach(JobControls.actions(for: job), id: \.self) { action in
                Button {
                    supervisor.perform(action, on: job)
                } label: {
                    Image(systemName: action.systemImage).font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(GlassButtonStyle(tint: action.isDestructive ? .red : .neutral, compact: true))
                .help(JobControls.title(of: action, for: job))
            }
            Button {
                supervisor.revealWorkdir(forJob: job.id)
            } label: {
                Image(systemName: "folder").font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(GlassButtonStyle(tint: .neutral, compact: true))
            .help("Show in Finder")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// History — recent finished runs (item 7).

private struct HistoryPane: View {
    @ObservedObject var supervisor: WorkerSupervisor

    var body: some View {
        FlexScroll {
            VStack(spacing: 10) {
                let recent = supervisor.recentCompletions
                if recent.isEmpty {
                    EmptyStatePane(symbol: "clock", title: "No finished runs yet",
                                   message: "Completed, failed, and cancelled runs land here.")
                } else {
                    ForEach(recent) { job in
                        HStack(spacing: 10) {
                            StatusDot(color: job.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.displayName).font(.system(size: 13, weight: .semibold))
                                Text(job.outcomeSummary()).font(.system(size: 11))
                                    .foregroundStyle(WD.Palette.textSecondary)
                            }
                            Spacer()
                            if let f = job.finishedAt {
                                Text(WorkerJob.age(max(0, Date().timeIntervalSince1970 - f)))
                                    .font(.system(size: 11)).foregroundStyle(WD.Palette.textTertiary)
                            }
                            Button {
                                supervisor.revealWorkdir(forJob: job.id)
                            } label: {
                                Image(systemName: "folder").font(.system(size: 11, weight: .semibold))
                                    .frame(width: 26, height: 22)
                            }
                            .buttonStyle(GlassButtonStyle(tint: .neutral, compact: true))
                            .help("Show in Finder")
                        }
                        .padding(14)
                        .workerGlass(.neutral)
                    }
                }
            }
            .padding(20)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Log — a collapsible live tail of the newest job's worker.log (item 7, optional).
// Read on demand (a Refresh button, and once on appear) — no timer touches the file.

private struct LogPane: View {
    @ObservedObject var supervisor: WorkerSupervisor
    @State private var text = "…"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(header).font(.system(size: 12)).foregroundStyle(WD.Palette.textSecondary)
                Spacer()
                Button("Refresh") { reload() }
                    .buttonStyle(GlassButtonStyle(tint: .neutral, compact: true))
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(WD.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .workerGlass(.neutral)
        }
        .padding(20)
        .onAppear(perform: reload)
    }

    private var header: String {
        supervisor.newestJobID.map { "worker.log · job \($0.prefix(8)) · last 50 lines" }
            ?? "No job selected"
    }

    private func reload() {
        text = supervisor.newestJobID.map { supervisor.tailWorkerLog(forJob: $0) }
            ?? "No jobs yet — the log tail appears once a run starts."
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared bits.

private struct EmptyStatePane: View {
    let symbol: String, title: String, message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
                .foregroundStyle(WD.Palette.textTertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(WD.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// A glass button style in the family — translucent, tinted, hairline specular. Used by
/// the header Start/Stop and every per-card control so the whole app clicks the same.
struct GlassButtonStyle: ButtonStyle {
    var tint: WorkerGlassTint = .neutral
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 13, weight: .semibold))
            .foregroundStyle(tint.intensity > 0 ? tint.color : WD.Palette.textPrimary)
            .padding(.horizontal, compact ? 4 : 14)
            .padding(.vertical, compact ? 2 : 7)
            .workerGlassCapsule(tint, specular: configuration.isPressed ? 0.4 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

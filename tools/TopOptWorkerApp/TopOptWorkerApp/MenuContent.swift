// MenuContent — the compact menu-bar face (handoff 097 → 121 → 124). It stays the
// glanceable surface: the live job rows with the rung/iter telemetry the maintainer
// uses daily (item 1), the recent completions, and the worker controls. Handoff 124
// moves the MenuBarExtra to `.window` style so this is real SwiftUI that REFLOWS while
// open — the poll now updates the rung/iter in place instead of freezing the moment the
// menu opens — and it gets the Liquid Glass dark treatment, the same family as the main
// window. "Open TopOpt Worker" (and a click on any job row) opens that window; per-job
// controls route through the SAME action layer the window uses (JobControls).

import SwiftUI
import AppKit

struct MenuContent: View {
    @ObservedObject var supervisor: WorkerSupervisor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            jobsSection
            if !supervisor.recentCompletions.isEmpty { recentSection }
            Divider().overlay(Color.white.opacity(0.08))
            controls
        }
        .padding(14)
        .frame(width: 340)
        .workerStage()
        .foregroundStyle(WD.Palette.textPrimary)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(color: supervisor.liveness.color, diameter: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("TopOpt Worker").font(.system(size: 13, weight: .bold))
                Text(headerSubtitle).font(.system(size: 11))
                    .foregroundStyle(WD.Palette.textSecondary)
            }
            Spacer()
            Button {
                openMainWindow()
            } label: {
                Image(systemName: "macwindow").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(GlassButtonStyle(tint: .blue, compact: true))
            .help("Open TopOpt Worker")
        }
    }

    private var headerSubtitle: String {
        guard supervisor.isRunning else { return supervisor.liveness.label }
        var parts = [supervisor.liveness.label, "port \(supervisor.port)"]
        if supervisor.queuedCount > 0 { parts.append("\(supervisor.queuedCount) queued") }
        return parts.joined(separator: " · ")
    }

    // MARK: jobs

    @ViewBuilder private var jobsSection: some View {
        if supervisor.isRunning {
            let active = supervisor.activeJobs
            if active.isEmpty {
                Text("No active jobs — ready for a run")
                    .font(.system(size: 11)).foregroundStyle(WD.Palette.textTertiary)
                    .padding(.vertical, 2)
            } else {
                sectionLabel("Jobs")
                ForEach(active) { job in MenuJobRow(job: job, supervisor: supervisor) }
            }
        } else if case .failed(let msg) = supervisor.state {
            Text(msg).font(.system(size: 11)).foregroundStyle(WD.Palette.danger)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Recent")
            ForEach(supervisor.recentCompletions.prefix(3)) { job in
                Button {
                    supervisor.revealWorkdir(forJob: job.id)
                } label: {
                    HStack(spacing: 8) {
                        StatusDot(color: job.accentColor, diameter: 6)
                        Text(job.displayName).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(job.outcomeSummary()).font(.system(size: 10))
                            .foregroundStyle(WD.Palette.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openMainWindow()
            } label: {
                Label("Open TopOpt Worker", systemImage: "macwindow")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(GlassButtonStyle(tint: .blue))

            HStack(spacing: 8) {
                Button(supervisor.isRunning ? "Stop" : "Start") {
                    supervisor.isRunning ? supervisor.stop() : supervisor.start()
                }
                .buttonStyle(GlassButtonStyle(tint: supervisor.isRunning ? .red : .neutral, compact: true))
                Button("Restart") { supervisor.restart() }
                    .buttonStyle(GlassButtonStyle(tint: .neutral, compact: true))
                Spacer()
                Button {
                    supervisor.launchAtLogin.toggle()
                } label: {
                    Label("Login item",
                          systemImage: supervisor.launchAtLogin ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GlassButtonStyle(tint: supervisor.launchAtLogin ? .blue : .neutral, compact: true))
                .help("Launch at Login")
            }

            HStack(spacing: 8) {
                Button("Settings…") { openSettings() }
                    .buttonStyle(GlassButtonStyle(tint: .neutral, compact: true))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(GlassButtonStyle(tint: .neutral, compact: true))
            }
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9, weight: .bold))
            .foregroundStyle(WD.Palette.textTertiary).tracking(0.6)
    }

    // MARK: actions

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the standard macOS Settings scene (⌘,) from a menu-bar accessory app.
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

/// One live job row in the compact face: name + the rung/iter telemetry (item 1) that
/// updates in place while the menu is open, plus the shared per-job controls. Clicking
/// the row (outside a control) opens the main window focused on this job.
private struct MenuJobRow: View {
    let job: WorkerJob
    @ObservedObject var supervisor: WorkerSupervisor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(color: job.accentColor, diameter: 7)
                Text(job.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                controls
            }
            Text(detail)
                .font(.system(size: 10, design: .rounded).monospacedDigit())
                .foregroundStyle(WD.Palette.textSecondary)
                .lineLimit(1)
        }
        .padding(10)
        .workerGlass(.neutral, cornerRadius: 12, specular: 0.7)
        .contentShape(Rectangle())
        .onTapGesture {
            supervisor.focusedJobID = job.id
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// "Solving · rung 4/4 · iter 106 · started 12 min ago" — the restored daily readout.
    private var detail: String {
        [job.stateWord, job.progressWord, job.startedWord()]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var controls: some View {
        HStack(spacing: 4) {
            ForEach(JobControls.actions(for: job), id: \.self) { action in
                Button {
                    supervisor.perform(action, on: job)
                } label: {
                    Image(systemName: action.systemImage).font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(GlassButtonStyle(tint: action.isDestructive ? .red : .neutral, compact: true))
                .help(JobControls.title(of: action, for: job))
            }
        }
    }
}

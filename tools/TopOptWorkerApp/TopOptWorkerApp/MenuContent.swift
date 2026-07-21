// MenuContent — the menu-bar dropdown. Handoff 097 shipped a single status line;
// handoff 121 (the worker is now human-facing) turns it into a JOB LIST: one row
// per active/queued job with per-job cancel/pause/reorder, recent completions with
// "Show in Finder", plus the worker controls (Start/Stop, Launch at Login, Update
// core, Settings, Quit). The job data comes from the worker's GET /jobs poll, not
// from inferring one active job from stdout.

import SwiftUI
import AppKit

struct MenuContent: View {
    @ObservedObject var supervisor: WorkerSupervisor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status header (disabled items read as labels in a menu).
        Text(supervisor.statusText).font(.headline)

        if supervisor.cliOK, let fp = supervisor.fingerprint {
            Text("Core \(fp)\(supervisor.cliVersion.map { " · \($0)" } ?? "")")
        } else if case .failed(let msg) = supervisor.state {
            Text(msg)
        }

        // ── Active / queued jobs ────────────────────────────────────────────
        if supervisor.isRunning {
            Divider()
            let active = supervisor.activeJobs
            if active.isEmpty {
                Text("No active jobs — ready for a run")
            } else {
                Text("Jobs")
                ForEach(active) { job in
                    jobMenu(job)
                }
            }

            // ── Recent completions ──────────────────────────────────────────
            let recent = supervisor.recentCompletions
            if !recent.isEmpty {
                Divider()
                Text("Recent")
                ForEach(recent) { job in
                    Menu("\(job.displayName) · \(job.stateWord)") {
                        Button("Show in Finder") { supervisor.revealWorkdir(forJob: job.id) }
                    }
                }
            }
        }

        Divider()

        if supervisor.isRunning {
            Button("Stop worker") { supervisor.stop() }
        } else {
            Button("Start worker") { supervisor.start() }
        }
        Button("Restart worker") { supervisor.restart() }

        Toggle("Launch at Login", isOn: Binding(
            get: { supervisor.launchAtLogin },
            set: { supervisor.launchAtLogin = $0 }))

        Divider()

        // "Update core…" — instructions only; actual auto-update is out of scope
        // for handoff 097 (documented in the handoff). Copies the rebuild command.
        Menu("Update core…") {
            Text("The iPad app refuses a worker whose core is a different build.")
            Text("To update this Mac's core, in the repo run:")
            Text(WorkerSupervisor.rebuildCommand)
            Button("Copy rebuild command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(WorkerSupervisor.rebuildCommand, forType: .string)
            }
            Divider()
            Button("Re-check core version") { supervisor.restart() }
        }

        Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }

        Divider()
        Button("Quit TopOpt Worker") { NSApp.terminate(nil) }
    }

    /// One active/queued job as a submenu: a label row + its per-job actions.
    @ViewBuilder
    private func jobMenu(_ job: WorkerJob) -> some View {
        let detail = [job.stateWord, job.progressWord, job.startedWord()]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        Menu("\(job.displayName) — \(detail)") {
            if job.state == "running" {
                if job.paused {
                    Button("Resume") { supervisor.resume(job) }
                } else {
                    Button("Pause (frees the cores; keeps ~2 GB resident)") {
                        supervisor.pause(job)
                    }
                }
            }
            if job.state == "queued" {
                Button("Move to front") { supervisor.moveToFront(job) }
            }
            Button("Show in Finder") { supervisor.revealWorkdir(forJob: job.id) }
            Divider()
            Button(job.state == "queued" ? "Remove from queue" : "Cancel", role: .destructive) {
                supervisor.cancel(job)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var supervisor: WorkerSupervisor

    var body: some View {
        Form {
            Section("topopt-cli") {
                Text(supervisor.cliOK
                     ? "Using: \(supervisor.cliPath ?? "—")"
                     : "topopt-cli was not found or failed to run.")
                    .font(.callout)
                    .foregroundStyle(supervisor.cliOK ? Color.secondary : Color.red)
                HStack {
                    TextField("Path to topopt-cli", text: Binding(
                        get: { supervisor.cliPathSetting },
                        set: { supervisor.cliPathSetting = $0 }))
                    Button("Choose…") { chooseCLI() }
                }
                Text("Leave blank to use a topopt-cli bundled in the app. Otherwise "
                   + "build it once: cmake --build core/build --target topopt_cli")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Queue") {
                Stepper(value: Binding(get: { supervisor.maxConcurrency },
                                       set: { supervisor.maxConcurrency = max(1, $0) }),
                        in: 1...8) {
                    Text("Run \(supervisor.maxConcurrency) job\(supervisor.maxConcurrency == 1 ? "" : "s") at once")
                }
                Text("Solves are memory-bandwidth-bound on this hardware, so a second "
                   + "concurrent job makes BOTH slower — a queue is faster. Raise this "
                   + "only on a machine with more memory channels.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Completion webhook (optional)") {
                TextField("https://ntfy.sh/your-topic", text: Binding(
                    get: { supervisor.webhookURL },
                    set: { supervisor.webhookURL = $0 }))
                Text("When a job finishes, the worker POSTs a small JSON (job, state, "
                   + "summary) here. For a free phone notification, create a topic at "
                   + "ntfy.sh, install the ntfy app, and paste https://ntfy.sh/<topic>. "
                   + "We deliberately don't run our own push/email service.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Apply & Restart worker") { supervisor.restart() }
                Text("Queue size and the webhook URL take effect on restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460)
        .navigationTitle("TopOpt Worker")
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select topopt-cli"
        if panel.runModal() == .OK, let url = panel.url {
            supervisor.cliPathSetting = url.path
            supervisor.restart()
        }
    }
}

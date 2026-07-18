// MenuContent — the menu-bar dropdown (handoff 097). Plain words: is it running,
// on what port, what's the core fingerprint, is a job active, plus Start/Stop,
// Launch at Login, Update core, Settings, Quit.

import SwiftUI
import AppKit

struct MenuContent: View {
    @ObservedObject var supervisor: WorkerSupervisor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status header (disabled items read as labels in a menu).
        Text(supervisor.statusText).font(.headline)

        if let job = supervisor.activeJobLabel {
            Text("Optimizing · \(job)")
        } else if supervisor.isRunning {
            Text("Idle — ready for a run")
        }

        if supervisor.cliOK, let fp = supervisor.fingerprint {
            Text("Core \(fp)\(supervisor.cliVersion.map { " · \($0)" } ?? "")")
        } else if case .failed(let msg) = supervisor.state {
            Text(msg)
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
            Section {
                Button("Apply & Restart worker") { supervisor.restart() }
            }
        }
        .formStyle(.grouped)
        .padding()
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

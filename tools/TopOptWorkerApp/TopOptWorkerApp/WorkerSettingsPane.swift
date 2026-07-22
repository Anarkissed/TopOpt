// WorkerSettingsPane — the settings surface (handoff 124, item 7). It absorbs the old
// Settings sheet (which lived in MenuContent) into the main window AND backs the
// standard macOS Settings scene (⌘,), so there is ONE settings view, two entry points.
// Port, max concurrency, the webhook URL (with the ntfy recipe in a caption), and
// Launch at Login — plus the topopt-cli path. Styled in the glass family; still a plain
// Form under the hood for native keyboard/focus behaviour.

import SwiftUI
import AppKit

struct WorkerSettingsPane: View {
    @ObservedObject var supervisor: WorkerSupervisor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cliSection
                serverSection
                webhookSection
                loginSection
                applySection
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .tint(WD.Palette.accent)
    }

    // MARK: sections

    private var cliSection: some View {
        SettingsCard(title: "topopt-cli", symbol: "terminal") {
            Text(supervisor.cliOK ? "Using: \(supervisor.cliPath ?? "—")"
                                  : "topopt-cli was not found or failed to run.")
                .font(.system(size: 12))
                .foregroundStyle(supervisor.cliOK ? WD.Palette.textSecondary : WD.Palette.danger)
            HStack {
                TextField("Path to topopt-cli", text: Binding(
                    get: { supervisor.cliPathSetting },
                    set: { supervisor.cliPathSetting = $0 }))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseCLI() }
                    .buttonStyle(GlassButtonStyle(tint: .neutral, compact: true))
            }
            caption("Leave blank to use a topopt-cli bundled in the app. Otherwise build it "
                  + "once: cmake --build core/build --target topopt_cli")
        }
    }

    private var serverSection: some View {
        SettingsCard(title: "Server", symbol: "network") {
            Stepper(value: Binding(get: { supervisor.portSetting },
                                   set: { supervisor.portSetting = min(65535, max(1024, $0)) }),
                    in: 1024...65535) {
                Text("Port \(supervisor.portSetting)").monospacedDigit()
            }
            Stepper(value: Binding(get: { supervisor.maxConcurrency },
                                   set: { supervisor.maxConcurrency = max(1, $0) }),
                    in: 1...8) {
                Text("Run \(supervisor.maxConcurrency) job\(supervisor.maxConcurrency == 1 ? "" : "s") at once")
            }
            caption("Solves are memory-bandwidth-bound on this hardware, so a second "
                  + "concurrent job makes BOTH slower — a queue is faster. Raise concurrency "
                  + "only on a machine with more memory channels.")
        }
    }

    private var webhookSection: some View {
        SettingsCard(title: "Completion webhook", symbol: "bell.badge") {
            TextField("https://ntfy.sh/your-topic", text: Binding(
                get: { supervisor.webhookURL },
                set: { supervisor.webhookURL = $0 }))
                .textFieldStyle(.roundedBorder)
            caption("When a job finishes, the worker POSTs a small JSON (job, state, summary) "
                  + "here. For a free phone notification, create a topic at ntfy.sh, install "
                  + "the ntfy app, and paste https://ntfy.sh/<topic>. We deliberately don't "
                  + "run our own push/email service.")
        }
    }

    private var loginSection: some View {
        SettingsCard(title: "Startup", symbol: "power") {
            Toggle("Launch at Login", isOn: Binding(
                get: { supervisor.launchAtLogin },
                set: { supervisor.launchAtLogin = $0 }))
            caption("Keeps the worker on the LAN across reboots — set-and-forget.")
        }
    }

    private var applySection: some View {
        HStack(spacing: 10) {
            Button("Apply & Restart worker") { supervisor.restart() }
                .buttonStyle(GlassButtonStyle(tint: .blue))
            Text("Port, queue size, and the webhook take effect on restart.")
                .font(.system(size: 11)).foregroundStyle(WD.Palette.textTertiary)
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(WD.Palette.textTertiary)
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

/// A titled glass card wrapping a settings group.
private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WD.Palette.accent)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .workerGlass(.neutral)
    }
}

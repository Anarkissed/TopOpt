// TopOptWorkerApp — the set-and-forget macOS menu-bar app (handoff 097). It is a
// menu-bar-only accessory (LSUIElement) that supervises the Python worker, shows
// its status, advertises it on the LAN by Bonjour name, and survives reboots
// (Launch at Login). Download once, open once, done.

import SwiftUI

@main
struct TopOptWorkerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var supervisor = WorkerSupervisor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(supervisor: supervisor)
        } label: {
            Image(systemName: supervisor.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Window("TopOpt Worker Settings", id: "settings") {
            SettingsView(supervisor: supervisor)
                .frame(width: 460)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: no Dock icon, no main window (belt-and-suspenders with the
        // Info.plist LSUIElement flag).
        NSApp.setActivationPolicy(.accessory)
        // Set-and-forget: start the worker immediately.
        Task { @MainActor in WorkerSupervisor.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in WorkerSupervisor.shared.stop() }
    }
}

// TopOptWorkerApp — the set-and-forget macOS menu-bar app (handoff 097). It is a
// menu-bar-only accessory (LSUIElement) that supervises the Python worker, shows
// its status, advertises it on the LAN by Bonjour name, and survives reboots
// (Launch at Login). Download once, open once, done.
//
// Handoff 121: the worker is now human-facing (a job queue with multiple jobs), so
// the app requests notification permission and posts a macOS completion banner
// when a watched job finishes; clicking the banner reveals the job's workdir.

import SwiftUI
#if canImport(UserNotifications)
import UserNotifications
#endif

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

        #if canImport(UserNotifications)
        // Completion notifications (handoff 121). Ask once; a denial simply means no
        // banners — the menu job list still works. We are the delegate so a click on
        // a completion banner reveals that job's workdir.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif

        // Set-and-forget: start the worker immediately.
        Task { @MainActor in WorkerSupervisor.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in WorkerSupervisor.shared.stop() }
    }
}

#if canImport(UserNotifications)
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show completion banners even though we're a background accessory app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// A click on a completion banner reveals the finished job's workdir in Finder.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["workdirJobID"] as? String {
            Task { @MainActor in WorkerSupervisor.shared.revealWorkdir(forJob: id) }
        }
        completionHandler()
    }
}
#endif

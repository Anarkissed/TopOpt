// TopOptWorkerApp — the set-and-forget macOS menu-bar app (handoff 097). It is a
// menu-bar-only accessory (LSUIElement) that supervises the Python worker, shows
// its status, advertises it on the LAN by Bonjour name, and survives reboots
// (Launch at Login). Download once, open once, done.
//
// Handoff 121: the worker is now human-facing (a job queue with multiple jobs), so
// the app requests notification permission and posts a macOS completion banner
// when a watched job finishes; clicking the banner reveals the job's workdir.

import SwiftUI
import AppKit
#if canImport(UserNotifications)
import UserNotifications
#endif

@main
struct TopOptWorkerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var supervisor = WorkerSupervisor.shared

    var body: some Scene {
        // The compact face. `.window` style (handoff 124) renders real SwiftUI that
        // reflows while open — so the rung/iter telemetry updates live instead of
        // freezing (item 1) — and carries the Liquid Glass dark treatment.
        MenuBarExtra {
            MenuContent(supervisor: supervisor)
        } label: {
            Image(systemName: supervisor.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        // The large main window (item 5). Opens from the menu / a job row; closing it
        // returns the app to the menu bar (LSUIElement — the app does NOT quit).
        Window("TopOpt Worker", id: "main") {
            WorkerWindow(supervisor: supervisor)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 760, height: 600)

        // The standard macOS Settings scene (⌘, and the menu's "Settings…"). Same pane
        // the window's Settings tab shows — one settings view, two entry points (item 7).
        Settings {
            WorkerSettingsPane(supervisor: supervisor)
                .frame(width: 560, height: 540)
                .workerStage()
                .foregroundStyle(WD.Palette.textPrimary)
        }
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

        // QA-only (handoff 124 evidence). No effect in normal use.
        //   TOPOPT_WORKER_QA=1        → present the window + menu face as on-screen AppKit
        //                               windows (for screencapture on a machine that grants
        //                               Screen Recording).
        //   TOPOPT_WORKER_QA=render   → rasterize the SAME views (with the live supervisor's
        //                               real polled data) to PNGs via ImageRenderer and exit
        //                               — works headlessly, no Screen Recording permission.
        switch ProcessInfo.processInfo.environment["TOPOPT_WORKER_QA"] {
        case "1":      Task { @MainActor in self.presentQAWindows() }
        case "render": Task { @MainActor in await self.renderQAScreenshots() }
        default:       break
        }
    }

    @MainActor private func renderQAScreenshots() async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["TOPOPT_WORKER_QA_OUT"] ?? NSTemporaryDirectory()
        let sup = WorkerSupervisor.shared

        if env["TOPOPT_WORKER_QA_SECTION"] == "history" {
            // Wait for at least one finished run so the History pane shows real outcomes.
            for _ in 0..<160 {
                if !sup.recentCompletions.isEmpty { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            writePNG(WorkerWindow(supervisor: sup, initialSection: .history)
                        .environment(\.qaFlatten, true).frame(width: 760, height: 600),
                     to: "\(dir)/124_worker_history_dark.png")
            NSApp.terminate(nil)
            return
        }

        // Default: wait for a running job with real progress, then render queue + menu.
        for _ in 0..<120 {
            if sup.jobs.contains(where: { $0.state == "running" && ($0.iter ?? 0) >= 18 }) { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        writePNG(WorkerWindow(supervisor: sup).environment(\.qaFlatten, true)
                    .frame(width: 760, height: 600),
                 to: "\(dir)/124_worker_window_dark.png")
        writePNG(MenuContent(supervisor: sup).fixedSize(horizontal: false, vertical: true),
                 to: "\(dir)/124_worker_menu_dark.png")
        NSApp.terminate(nil)
    }

    @MainActor private func writePNG<V: View>(_ view: V, to path: String) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("QA render failed for \(path)"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        NSLog("QA wrote \(path)")
    }

    private var qaWindows: [NSWindow] = []

    @MainActor private func presentQAWindows() {
        NSApp.setActivationPolicy(.regular)   // so the QA windows take focus for capture
        func host<V: View>(_ view: V, title: String, size: NSSize) {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = title
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            w.center()
            w.makeKeyAndOrderFront(nil)
            qaWindows.append(w)
        }
        host(WorkerWindow(supervisor: .shared), title: "TopOpt Worker", size: NSSize(width: 760, height: 600))
        host(MenuContent(supervisor: .shared).fixedSize(horizontal: false, vertical: true),
             title: "TopOpt Worker — Menu", size: NSSize(width: 340, height: 520))
        NSApp.activate(ignoringOtherApps: true)
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

// TopOpt — the iPad app shell (ROADMAP M7.1). Deliberately thin: the app is a
// SwiftUI/Metal front end over the TopOptKit bridge (ARCHITECTURE §4 "App UI …
// Thin"). M7.1 only stands the target up and shows a bridge smoke result; the
// home/import/viewer/run/results flows are M7.2–M7.9.
import SwiftUI
import TopOptFlows

@main
struct TopOptApp: App {
    init() {
        // ★ his notes 2026-11-23 ("Tapping the notification should bring you RIGHT to the result screen"): the run
        // notifications' delegate, set as the app starts so a tap that launches the app reaches it too
        RunNotificationRouter.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

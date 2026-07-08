// TopOpt — the iPad app shell (ROADMAP M7.1). Deliberately thin: the app is a
// SwiftUI/Metal front end over the TopOptKit bridge (ARCHITECTURE §4 "App UI …
// Thin"). M7.1 only stands the target up and shows a bridge smoke result; the
// home/import/viewer/run/results flows are M7.2–M7.9.
import SwiftUI

@main
struct TopOptApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

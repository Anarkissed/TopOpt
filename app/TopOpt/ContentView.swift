// The app's root view (ROADMAP M7.3). It hosts the TopOptFlows RootView — the
// home + import flow — over a single shared AppModel. The M7.1 bridge-smoke
// screen this replaced proved the app linked the core; the flow now drives the
// real Home screen, import sheet (materials from the bundled materials.json via
// the bridge, STEP/STL picker, core diagnostics on failure) and Continue →
// workspace. The workspace itself (Metal viewer, tools) is M7.4+.
import SwiftUI
import TopOptFlows

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        RootView(model: model)
    }
}

#Preview {
    ContentView()
}

// The M7.1 bridge smoke screen. It proves the app is linked against TopOptKit /
// the core: it prints the core version and a "bridge smoke result" — the
// material count and the imported-mesh triangle count (ROADMAP M7.1). The real
// home screen and import flow arrive in M7.3; this view is intentionally
// throwaway UI, not the design-system screen (M7.2).
import SwiftUI
import TopOptKit

struct ContentView: View {
    @State private var status: String = "Running bridge smoke…"
    @State private var materialCount: Int?
    @State private var triangleCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TopOpt")
                .font(.largeTitle).bold()
            Text("core \(TopOptKit.coreVersion)")
                .font(.subheadline).foregroundStyle(.secondary)

            GroupBox("Bridge smoke") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Materials", value: materialCount.map(String.init) ?? "—")
                    LabeledContent("Imported triangles", value: triangleCount.map(String.init) ?? "—")
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding(24)
        .task { runSmoke() }
    }

    /// Loads a bundled materials.json + sample mesh and shows the two counts.
    /// Both resources are bundled with the app target (see the Xcode project);
    /// if either is missing the view degrades to just the core version.
    private func runSmoke() {
        guard let materials = Bundle.main.path(forResource: "materials", ofType: "json") else {
            status = "Bundle a materials.json to see the material count (M7.3 wires import)."
            return
        }
        let mesh = Bundle.main.path(forResource: "sample_cube", ofType: "stl")
        do {
            if let mesh {
                let result = try TopOptKit.smoke(materialsPath: materials, meshPath: mesh)
                materialCount = result.materialCount
                triangleCount = result.triangleCount
                status = result.watertight ? "Bridge OK — sample mesh watertight."
                                           : "Bridge OK — sample mesh not watertight."
            } else {
                materialCount = try TopOptKit.loadMaterials(path: materials).count
                status = "Bridge OK — bundle a sample mesh to see triangle count."
            }
        } catch {
            status = "Bridge error: \(error)"
        }
    }
}

#Preview {
    ContentView()
}

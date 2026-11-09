// LatticeSampleView — the Lattice page's SAMPLE (his iPad notes 11-08: "There is no 'One cell' or 'In the part' visuals
// whatsoever"; design note 30 / R3.2, plan B7: "Sample shows the ONE sample block … built by core through the LatticeTypes
// bridge with preview parity").
//
// The view switch [Sample │ In the part] stayed on the page after B8 (10-24) deleted the full-screen settings page and its
// sample stage, so Sample drew nothing. This is that view, rebuilt the way the design states it: core's COUPON
// (`topopt::lattice_sample_mesh`, shape "coupon" — LatticeTypes' generator, the block he prints: a solid end wall, a
// curved top, a thin tongue beside the thick body, the density graded along it, a cell-size step where the type allows
// one), drawn beside the panel in the model area. It is the engine's own triangles, so the picture is what the engine
// builds for the type — never an app-side stand-in. In the part is the stage's live preview, as before.
import SwiftUI
import simd
import TopOptDesign
import TopOptKit

struct LatticeSampleView: View {
    /// What the block is built from: the page's type, its cell (0 ⇒ core's 8 mm), and the printer's bead.
    struct Inputs: Equatable { let topology: String; let typeName: String; let cellMM: Double; let beadMM: Double }
    let inputs: Inputs

    @StateObject private var camera = OrbitCameraModel()
    @State private var mesh: ViewerMesh?
    @State private var caption = LatticeSampleView.building
    @State private var failed = false

    static let building = "Building the sample block\u{2026}"
    /// The switch's first view, in the design's word (note 30: [Sample │ In the part]).
    static let switchTitle = "Sample"

    var body: some View {
        ZStack(alignment: .bottom) {
            DS.Color.background.color
            if let mesh {
                MetalMeshView(mesh: mesh, camera: camera, settleRotation: Self.settleZUp)
            }
            Text(caption)
                .font(.system(size: 12.5)).foregroundStyle((failed ? DS.Color.warning : DS.Color.textSecondary).color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                .background(Capsule().fill(DS.Surface.panel.color))
                .padding(.bottom, DS.Space.l)
                .latticeID("lattice-sample-caption")
        }
        .task(id: inputs) { await build() }
    }

    /// Core's sample is Z-up (printed as it stands); the viewer is Y-up — the map the workspace applies to a part.
    static let settleZUp = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))

    private func build() async {
        caption = Self.building; failed = false
        let i = inputs
        let r = await Task.detached(priority: .userInitiated) { () -> Result<TopOptKit.LatticeSampleBlock, Error> in
            Result { try TopOptKit.latticeSampleBlock(topology: i.topology, cellMM: i.cellMM, beadMM: i.beadMM) }
        }.value
        guard !Task.isCancelled else { return }
        switch r {
        case .success(let block):
            let m = ViewerMesh(vertices: block.mesh.vertices, indices: block.mesh.indices,
                               faceIDs: [Int32](repeating: 1, count: block.mesh.indices.count / 3))
            mesh = m
            camera.reframe(m.bounds)
            caption = Self.caption(receiptJSON: block.receiptJSON, typeName: i.typeName)
        case .failure(let e):
            mesh = nil; failed = true
            caption = "The engine can't build this type's sample: \(e.localizedDescription)"
        }
    }

    /// "Sample block · 45 × 40 × 35 mm · Octet truss · built by the engine, as in your part" (R3.3's words).
    static func caption(receiptJSON: String, typeName: String) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(receiptJSON.utf8))) as? [String: Any]
        let dims = (obj?["dimensions_mm"] as? [Double])
            ?? ((obj?["coupon"] as? [String: Any])?["dimensions_mm"] as? [Double]) ?? []
        let size = dims.count == 3 ? dims.map { String(format: "%g", ($0 * 10).rounded() / 10) }.joined(separator: " × ") + " mm · " : ""
        return "Sample block · \(size)\(typeName) · built by the engine, as in your part"
    }
}

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

/// ★ his iPad notes 11-10 (img 3): "The background of the model is completely visible and cut off. It looks horrendous. This
/// should not be visible at all." The Lattice page says when Sample is up; the workspace then covers its part (under the
/// top-left block and the stage capsule, which stay), so only the sample block shows.
struct LatticeSampleShowingKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct LatticeSampleView: View {
    /// What the block is built from: the page's type, its cell (0 ⇒ core's 8 mm), the printer's bead, and (★ his iPad notes
    /// 11-10, img 6: "nothing changes the sample") the Grade's two ends (0 ⇒ core's band).
    struct Inputs: Equatable {
        let topology: String; let typeName: String; let cellMM: Double; let beadMM: Double
        var rhoLo: Double = 0; var rhoHi: Double = 0
    }
    let inputs: Inputs
    /// ★ his iPad notes 11-10 (img 6): the settings he has on that core's sample block can't show yet — said in one line.
    var notInSample: [String] = []

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
            VStack(spacing: DS.Space.s) {
                if let line = Self.notInSampleLine(notInSample) {
                    Text(line)
                        .font(.system(size: 12.5)).foregroundStyle(DS.Color.warning.color)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                        .background(Capsule().fill(DS.Surface.panel.color))
                        .latticeID("lattice-sample-not-shown")
                }
                Text(caption)
                    .font(.system(size: 12.5)).foregroundStyle((failed ? DS.Color.warning : DS.Color.textSecondary).color)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                    .background(Capsule().fill(DS.Surface.panel.color))
                    .latticeID("lattice-sample-caption")
            }
            .padding(.bottom, DS.Space.l)
        }
        .task(id: inputs) { await build() }
    }

    /// Core's sample is Z-up (printed as it stands); the viewer is Y-up — the map the workspace applies to a part.
    static let settleZUp = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))

    private func build() async {
        caption = Self.building; failed = false
        let i = inputs
        let r = await Task.detached(priority: .userInitiated) { () -> Result<TopOptKit.LatticeSampleBlock, Error> in
            Result { try TopOptKit.latticeSampleBlock(topology: i.topology, cellMM: i.cellMM, beadMM: i.beadMM,
                                                      rhoLo: i.rhoLo, rhoHi: i.rhoHi) }
        }.value
        guard !Task.isCancelled else { return }
        switch r {
        case .success(let block):
            let m = ViewerMesh(vertices: block.mesh.vertices, indices: block.mesh.indices,
                               faceIDs: [Int32](repeating: 1, count: block.mesh.indices.count / 3))
            mesh = m
            camera.reframe(m.bounds)
            caption = Self.caption(receiptJSON: block.receiptJSON, typeName: i.typeName, densityHeld: block.densityHeld)
        case .failure(let e):
            mesh = nil; failed = true
            caption = "The engine can't build this type's sample: \(e.localizedDescription)"
        }
    }

    /// "Sample block · 45 × 40 × 35 mm · Octet truss · density 20 → 35 % · built by the engine, as in your part" (R3.3's
    /// words; ★ his iPad notes 11-10: the grade it was built with, and "held to the type's band" when his ends were moved).
    static func caption(receiptJSON: String, typeName: String, densityHeld: Bool = false) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(receiptJSON.utf8))) as? [String: Any]
        let coupon = obj?["coupon"] as? [String: Any]
        let dims = (obj?["dimensions_mm"] as? [Double]) ?? (coupon?["dimensions_mm"] as? [Double]) ?? []
        let size = dims.count == 3 ? dims.map { String(format: "%g", ($0 * 10).rounded() / 10) }.joined(separator: " × ") + " mm · " : ""
        var grade = ""
        // core's receipt: "relative_density_graded": [lo, hi]
        if let g = (obj?["relative_density_graded"] ?? coupon?["relative_density_graded"]) as? [Double], g.count == 2,
           g[0] > 0, g[1] > 0 {
            let lo = Int((g[0] * 100).rounded()), hi = Int((g[1] * 100).rounded())
            grade = (lo == hi ? "density \(lo) %" : "density \(lo) → \(hi) %")
                + (densityHeld ? " (held to \(typeName)'s band)" : "") + " · "
        }
        return "Sample block · \(size)\(typeName) · \(grade)built by the engine, as in your part"
    }

    /// One plain line for the settings he has on that the engine's sample block doesn't build yet; nil when none.
    static func notInSampleLine(_ names: [String]) -> String? {
        names.isEmpty ? nil : "Not in the sample yet: " + names.joined(separator: ", ")
    }

    /// The page's settings the coupon can't show (core's sample takes the type, the cell and the grade only): Organic, the
    /// finish, the shape band, single-cell members — each named only while it is on.
    static func notInSample(organic: Bool, finish: LatticeBoundaryTreatment, shapeBand: Bool, singleCell: Bool) -> [String] {
        var out: [String] = []
        if organic { out.append("Organic") }
        switch finish {
        case .none: break
        case .rim: out.append("Rim")
        case .fullSkin: out.append("Skin")
        case .covered: out.append("Covered")
        }
        if shapeBand { out.append("the shape band") }
        if singleCell { out.append("single-cell members") }
        return out
    }
}

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
/// should not be visible at all." The Lattice page says when its sample is up; the workspace then covers its part (under the
/// top-left block and the stage capsule, which stay), so only the sample shows. ★ his 11-10 (later): "In a part … shouldn't
/// be the actual part the user has" — both views are samples now, so the page covers his part in either.
struct LatticeSampleShowingKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// ★ 362's 11-10 regression set found it: every change of the page's settings started a whole engine build of the sample
/// (~1.7 s), and a build already started runs to its end even after the page moved on — a Strength drag stacked dozens side
/// by side (the page-parity walk took 26 min a test; on his iPad, lag and heat). The builder runs ONE build at a time, and
/// only the newest sample asked for: one asked for before a newer one, or for a view that left, is skipped before it starts.
final class LatticeSampleBuilder: @unchecked Sendable {
    static let shared = LatticeSampleBuilder()
    private let queue = DispatchQueue(label: "lattice-sample", qos: .userInitiated)
    private let lock = NSLock()
    private var newest = 0
    private var started = 0

    /// A number for the sample just asked for; every earlier one is stale from now on.
    func ticket() -> Int { lock.lock(); defer { lock.unlock() }; newest += 1; return newest }
    /// The view that asked for `t` left or moved on: if its build hasn't started, it never will.
    func retire(_ t: Int) { lock.lock(); defer { lock.unlock() }; if newest == t { newest += 1 } }
    /// How many builds actually ran.
    var builds: Int { lock.lock(); defer { lock.unlock() }; return started }
    private func claim(_ t: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard t == newest else { return false }
        started += 1; return true
    }

    /// Runs `work` on the builder's one queue if `t` is still the newest when its turn comes; nil when it was skipped.
    func run<T>(_ t: Int, _ work: @escaping () throws -> T) async -> Result<T, Error>? {
        await withCheckedContinuation { (c: CheckedContinuation<Result<T, Error>?, Never>) in
            queue.async {
                guard self.claim(t) else { c.resume(returning: nil); return }
                c.resume(returning: Result { try work() })
            }
        }
    }
}

struct LatticeSampleView: View {
    /// ★ his 11-10 (later): "For the 'cell/in the part' I think it should go back to how it was, showing a chunk of a bunch of
    /// lattice cells together, and the 'in the part' should be named 'In A part' and should be a sample part that is shown
    /// with the settings implemented on there. It shouldn't be the actual part the user has."
    enum Shape: Equatable { case cells, part }
    /// What the sample is built from: which one, the page's type, its cell (0 ⇒ core's 8 mm), the printer's bead, and
    /// (★ his iPad notes 11-10, img 6: "nothing changes the sample") the Grade's two ends (0 ⇒ core's band; the chunk of
    /// cells takes `rhoHi`, one density).
    struct Inputs: Equatable {
        var shape: Shape = .part
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

    static let building = "Building the sample\u{2026}"

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
        .onAppear { if FlexibleSaid.recording { Self.recordedAppears += 1 }; Self.say(tag, "appear") }
        .onDisappear { Self.say(tag, "disappear") }
    }

    /// Diagnostics: SAMPLE_TRACE=1 prints each view's asks, skips, builds and appearances.
    static let tracing = ProcessInfo.processInfo.environment["SAMPLE_TRACE"] != nil
    static func say(_ tag: String, _ what: @autoclosure () -> String) {
        guard tracing else { return }
        let line = "[sample \(tag)] \(String(format: "%.3f", Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))) \(what())\n"
        FileHandle.standardError.write(Data(line.utf8))   // unbuffered: a stall's last lines are in the log
    }
    @State private var tag = String(UUID().uuidString.prefix(4))

    /// Test hooks, kept only while a test records (FlexibleSaid.recording): each sample asked for, each time a view came up.
    nonisolated(unsafe) static var recordedAsks: [Inputs] = []
    nonisolated(unsafe) static var recordedAppears = 0

    /// Core's sample is Z-up (printed as it stands); the viewer is Y-up — the map the workspace applies to a part.
    static let settleZUp = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))

    /// ★ A beat for a drag to move on before the engine builds (a slider's steps come ~16 ms apart): a change the next step
    /// replaces is cancelled here, before it costs a build.
    static let settleNanos: UInt64 = 120_000_000

    private func build() async {
        caption = Self.building; failed = false
        let i = inputs
        if FlexibleSaid.recording { Self.recordedAsks.append(i) }
        Self.say(tag, "ask \(i.shape) \(i.topology) cell \(i.cellMM) rho \(i.rhoLo)-\(i.rhoHi) bead \(i.beadMM)")
        try? await Task.sleep(nanoseconds: Self.settleNanos)
        guard !Task.isCancelled else { Self.say(tag, "cancelled in the beat"); return }
        let builder = LatticeSampleBuilder.shared
        let t = builder.ticket()
        // ★ the viewer's mesh is made on the builder's queue too: for the sample part's ~330 k triangles it held the main
        // thread for seconds (traced 11-10, debug build), a freeze on his iPad each time the sample changed
        let built = await withTaskCancellationHandler {
            await builder.run(t) { () -> (block: TopOptKit.LatticeSampleBlock, mesh: ViewerMesh) in
                let b = try TopOptKit.latticeSampleBlock(topology: i.topology, cellMM: i.cellMM, beadMM: i.beadMM,
                                                         rhoLo: i.rhoLo, rhoHi: i.rhoHi, cube: i.shape == .cells)
                return (b, ViewerMesh(vertices: b.mesh.vertices, indices: b.mesh.indices,
                                      faceIDs: [Int32](repeating: 1, count: b.mesh.indices.count / 3)))
            }
        } onCancel: { builder.retire(t) }
        Self.say(tag, "ticket \(t): \(built == nil ? "skipped" : "built")\(Task.isCancelled ? ", cancelled" : "")")
        guard let r = built, !Task.isCancelled else { return }
        switch r {
        case .success(let made):
            let block = made.block, m = made.mesh
            mesh = m
            Self.say(tag, "mesh up (\(block.mesh.indices.count / 3) triangles)")
            camera.reframe(m.bounds)
            caption = i.shape == .cells
                ? Self.cellsCaption(receiptJSON: block.receiptJSON, typeName: i.typeName, densityHeld: block.densityHeld)
                : Self.caption(receiptJSON: block.receiptJSON, typeName: i.typeName, densityHeld: block.densityHeld)
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
        return "Sample part · \(size)\(typeName) · \(grade)built by the engine"
    }

    /// The chunk of cells: "5 × 5 × 5 cells of 8 mm · Octet truss · density 30 % · built by the engine".
    static func cellsCaption(receiptJSON: String, typeName: String, densityHeld: Bool = false) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(receiptJSON.utf8))) as? [String: Any]
        var head = ""
        if let n = (obj?["cells_per_side"] as? NSNumber)?.intValue, let c = obj?["cell_mm"] as? Double, n > 0 {
            head = "\(n) × \(n) × \(n) cells of \(String(format: "%g", (c * 100).rounded() / 100)) mm · "
        }
        var dens = ""
        if let r = obj?["relative_density"] as? Double, r > 0 {
            dens = "density \(Int((r * 100).rounded())) %" + (densityHeld ? " (held to \(typeName)'s band)" : "") + " · "
        }
        return "\(head)\(typeName) · \(dens)built by the engine"
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

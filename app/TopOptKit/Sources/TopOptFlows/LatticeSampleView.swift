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
        /// ★ his 11-18: Organic's samples — "Cells" a cube of organic tendrils, "In a part" the sample part graded to shape,
        /// each with ONE stress focus — from these Organic settings (the open tab's) and the printer's layer. nil: not Organic.
        var organic: LatticeOrganicLook? = nil
        var layerMM: Double = 0.2
        /// The printer's wall ring (a Solid finish's cover); -1 none.
        var coverMM: Double = -1
        /// ★ his pick 11-20 ("Use my struts"): the group's own Auto struts as his part measured them (thin, thick, one);
        /// empty: the sample's. A typed (Manual) thickness is in `organic` already.
        var partStruts: [Double] = []
        /// ★ his 11-22 ("The sample model should always be consistent"): the part's own Auto numbers are being measured;
        /// the sample waits for them rather than build once with its own and again with his part's.
        var partStrutsPending = false
        /// Aesthetic (Extra spacing's default is on there).
        var aesthetic = false
    }
    let inputs: Inputs
    /// ★ his iPad notes 11-10 (img 6): the settings he has on that core's sample block can't show yet — said in one line.
    var notInSample: [String] = []

    @StateObject private var camera = OrbitCameraModel()
    @State private var mesh: ViewerMesh?
    @State private var caption = LatticeSampleView.building
    @State private var failed = false
    @State private var organicBars: LatticeLayoutBarsInputs?
    /// ★ his 11-22 notes (img 46: "Building the sample…" with no sense of how long): when this build began (the wait for his
    /// part's own numbers counts as the same build), and how long the sample on screen took.
    @State private var buildStarted: Date?
    @State private var heldForPart = false
    @State private var builtSeconds: Double?

    static let building = "Building the sample\u{2026}"

    /// ★ his 11-22: the time so far, once a second ("Building the sample · 12 s").
    static func buildingLine(elapsed s: Double) -> String {
        s < 1 ? building : "Building the sample \u{00B7} " + clock(s)
    }
    /// ★ his 11-22: how long the sample on screen took, a small quiet label on it (four words at most).
    static func builtLabel(seconds s: Double) -> String {
        "Built in " + (s < 10 ? String(format: "%.1f s", Swift.max(0, s)) : clock(s))
    }
    /// "12 s" under a minute, "1:05" from one.
    static func clock(_ s: Double) -> String {
        let n = Swift.max(0, Int(s.rounded(.down)))
        return n < 60 ? "\(n) s" : String(format: "%d:%02d", n / 60, n % 60)
    }
    /// Test hook (FlexibleSaid.recording): each "Built in" label shown.
    nonisolated(unsafe) static var recordedBuilt: [String] = []

    /// ★ his 11-22 (GenerationTimingLog): what the sample was built from.
    static func timingInputs(_ i: Inputs) -> GenerationTimingLog.Inputs {
        var t = GenerationTimingLog.Inputs()
        t.part = .init(file: i.shape == .cells ? "Sample: cells (40 mm cube)" : "Sample: part")
        if let o = i.organic { t.organic = ["Sample": o] }
        t.values = ["latticeType": .text(i.organic.map { "Organic " + $0.modeValue.title } ?? i.typeName),
                    "topology": .text(i.topology), "cellMM": .number(i.cellMM), "beadMM": .number(i.beadMM),
                    "rhoLo": .number(i.rhoLo), "rhoHi": .number(i.rhoHi), "layerMM": .number(i.layerMM),
                    "coverMM": .number(i.coverMM), "aesthetic": .flag(i.aesthetic),
                    "partStruts": .text(i.partStruts.map { String($0) }.joined(separator: ", "))]
        return t
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            DS.Color.background.color
            if let mesh {
                if let organicBars {   // ★ Organic: the engine's struts in the bare body, seen through it
                    MetalMeshView(mesh: mesh, camera: camera, settleRotation: Self.settleZUp,
                                  bodyAlpha: LatticeLayoutPreview.ghostAlpha, layoutBars: organicBars)
                } else {
                    MetalMeshView(mesh: mesh, camera: camera, settleRotation: Self.settleZUp)
                }
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
                captionLine
                    .font(.system(size: 12.5)).foregroundStyle((failed ? DS.Color.warning : DS.Color.textSecondary).color)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                    .background(Capsule().fill(DS.Surface.panel.color))
                    .latticeID("lattice-sample-caption")
            }
            .padding(.bottom, DS.Space.l)
        }
        .task(id: inputs) { await build() }
        .onChange(of: caption) { c in if FlexibleSaid.recording { Self.recordedCaptions.append(c) } }
        .onAppear { if FlexibleSaid.recording { Self.recordedAppears += 1 }; Self.say(tag, "appear") }
        .onDisappear { Self.say(tag, "disappear") }
    }

    /// ★ his 11-22 (img 46): the caption, with the time while it builds (once a second, this line only) and, once built, how
    /// long it took beside it, quieter — on the sample's own caption, never a line of the screen.
    @ViewBuilder private var captionLine: some View {
        if caption == Self.building, !failed, let start = buildStarted {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                Text(Self.buildingLine(elapsed: ctx.date.timeIntervalSince(start)))
            }
        } else if let s = builtSeconds, !failed {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(caption)
                Text(Self.builtLabel(seconds: s)).foregroundStyle(DS.Color.textTertiary.color).fixedSize()
                    .latticeID("lattice-sample-built")
            }
        } else {
            Text(caption)
        }
    }

    /// The build began (a new one; the wait for his part's numbers goes on as the same one).
    private func buildBegins() {
        builtSeconds = nil
        if !heldForPart || buildStarted == nil { buildStarted = Date() }
        heldForPart = inputs.organic != nil && inputs.partStrutsPending
    }
    /// The sample is on screen: how long it took stays on it.
    private func buildShown() {
        builtSeconds = buildStarted.map { Date().timeIntervalSince($0) }
        if FlexibleSaid.recording, let s = builtSeconds { Self.recordedBuilt.append(Self.builtLabel(seconds: s)) }
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
    nonisolated(unsafe) static var recordedCaptions: [String] = []

    /// Core's sample is Z-up (printed as it stands); the viewer is Y-up — the map the workspace applies to a part.
    static let settleZUp = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))

    /// ★ A beat for a drag to move on before the engine builds (a slider's steps come ~16 ms apart): a change the next step
    /// replaces is cancelled here, before it costs a build.
    static let settleNanos: UInt64 = 120_000_000

    private func build() async {
        caption = Self.building; failed = false
        buildBegins()   // ★ his 11-22: the time it takes, said
        let i = inputs
        if let look = i.organic { return await buildOrganic(look, i) }
        organicBars = nil
        if FlexibleSaid.recording { Self.recordedAsks.append(i) }
        Self.say(tag, "ask \(i.shape) \(i.topology) cell \(i.cellMM) rho \(i.rhoLo)-\(i.rhoHi) bead \(i.beadMM)")
        try? await Task.sleep(nanoseconds: Self.settleNanos)
        guard !Task.isCancelled else { Self.say(tag, "cancelled in the beat"); return }
        let builder = LatticeSampleBuilder.shared
        let log = GenerationTimingLog.shared, rec = log.begin(.sample, inputs: Self.timingInputs(i))   // ★ his 11-22
        defer { log.end(rec, .cancelled, reason: "the page moved on") }   // (a build that ended said so first)
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
        if built == nil { log.discard(rec) }   // skipped before it began: no line
        guard let r = built, !Task.isCancelled else { return }
        switch r {
        case .success(let made):
            let block = made.block, m = made.mesh
            log.end(rec, .done, stages: ["triangles": Double(block.mesh.indices.count / 3)])
            mesh = m
            Self.say(tag, "mesh up (\(block.mesh.indices.count / 3) triangles)")
            camera.reframe(m.bounds)
            buildShown()
            caption = i.shape == .cells
                ? Self.cellsCaption(receiptJSON: block.receiptJSON, typeName: i.typeName, densityHeld: block.densityHeld)
                : Self.caption(receiptJSON: block.receiptJSON, typeName: i.typeName, densityHeld: block.densityHeld)
        case .failure(let e):
            log.end(rec, .failed, reason: e.localizedDescription)
            mesh = nil; failed = true
            caption = "The engine can't build this type's sample: \(e.localizedDescription)"
        }
    }

    /// ★ Organic's sample (his 11-18; LatticeReview's C2, E5 and E8): the bare body (the cube, or the coupon) through a layout
    /// session — ONE woven region from a box zone round it, Auto's limits for it moved by Look, the made-up stress of ONE
    /// focus (no solve), the lay exact — drawn as the preview draws Organic.
    /// The sample's vines as the print file makes them (his 11-19 rule), cut flat at the body (11-20). Nonisolated: it runs off
    /// the main actor, as part of the caller's task.
    nonisolated static func sampleVines(runs: [LatticeLayoutSession.Run], vertices: [Float], indices: [Int32],
                                        heldFlat: [SIMD3<Float>] = []) async -> OrganicVineShape {
        var v = OrganicVineShape.tubes(runs: runs, heldFlat: heldFlat)
        v.cut(runs: runs, surface: OrganicVineShape.CutSurface(vertices: vertices, indices: indices))
        return v
    }

    private func buildOrganic(_ look: LatticeOrganicLook, _ i: Inputs) async {
        guard !i.partStrutsPending else { return }   // ★ his 11-22: "Building the sample…" until the part's numbers are in
        try? await Task.sleep(nanoseconds: Self.settleNanos)
        guard !Task.isCancelled else { return }
        // ★ his 11-22: the sample's line in the timing log, with each step's time (a build that ends says so first)
        let log = GenerationTimingLog.shared, rec = log.begin(.sample, inputs: Self.timingInputs(i))
        var stages: [String: Double] = [:]
        var t0 = Date()
        func step(_ name: String) { stages[name] = Date().timeIntervalSince(t0) * 1000; t0 = Date() }
        defer { log.end(rec, .cancelled, reason: "the page moved on", stages: stages) }
        do {
            let cube = i.shape == .cells
            let body = try TopOptKit.latticeSampleBody(cube: cube)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(cube ? "organic-sample-cube.stl" : "organic-sample-part.stl")
            try MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data()).write(to: url)
            let session = try await LatticeLayoutSession.open(path: url.path)
            defer { session.close() }
            step("openMS")
            var s = LatticeLayoutSession.Settings()
            s.beadMM = i.beadMM > 0 ? i.beadMM : 0.45
            s.minStrutLines = 2
            guard let b = LatticeLayoutPreview.box(body.vertices) else { throw TopOptError(message: "the sample body is empty") }
            var r = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            r.zone = .init(kind: .box, centre: SIMD3<Double>((b.lo + b.hi) / 2),
                           axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], half: SIMD3<Double>((b.hi - b.lo) / 2) + 1)
            r.weave = true
            // his 11-20 (img6: finish Skin, density 5): the group's own finish, as his part gets it
            if LatticeOrganicLook.finishWired { r.finish = LatticeLayoutPreview.organicFinish(look, LatticeSettings(), coverMM: i.coverMM) }
            s.regions = [r]
            var lim = try await session.sweepLimits(s, regions: [1], lineMM: s.beadMM).map(LatticeOrganicLook.Limits.init)
            step("limitsMS")
            if i.partStruts.count == 3, var l = lim {   // ★ his pick 11-20: the group's struts, as his part gets them
                l.strutLowerMM = i.partStruts[0]; l.strutUpperMM = i.partStruts[1]; l.strutAutoMM = i.partStruts[2]
                lim = l
            }
            let looked = lim.map { $0.looked(percent: look.lookPercentValue) }
            var ask = look.ask(limits: looked, layerMM: i.layerMM, aesthetic: i.aesthetic)
            ask.quality = .exact
            let groups = [LatticeLayoutSession.OrganicGroup(regions: [1], ask: ask)]
            let made = try await session.synthetic(s, groups: groups, walls: [(region: 1, foci: 1)], fromEmpty: true)
            step("syntheticMS")
            if !made.refused.isEmpty { throw LatticeRefused(refusals: made.refused) }
            let laid = try await session.layOrganic(s, groups: groups)
            step("layWallMS")
            stages["layMS"] = laid.ms; stages["traceMS"] = laid.msTrace; stages["strands"] = Double(laid.strands)
            if !laid.refused.isEmpty { throw LatticeRefused(refusals: laid.refused) }
            guard !Task.isCancelled else { return }
            let seg = LatticeLayoutPreview.segments(laid.runs)
            var l = LatticeLayoutColours.Laid()
            l.bars = seg.bars; l.barFlags = seg.skin; l.barCell = seg.cell; l.barRegion = seg.region; l.token = 1
            var bars = LatticeLayoutBarsInputs(token: Int.random(in: 1...Int.max), bars: seg.bars, flags: seg.flags,
                                               colours: LatticeLayoutColours.colours(l, type: nil, grade: false, oneColour: true), colourKey: 1)
            let runs = laid.runs
            let (bv, bi) = (body.vertices, body.indices)
            // off the main thread, but IN this task (never detached): leaving the page cancels it with the rest
            t0 = Date()
            bars.vines = await Self.sampleVines(runs: runs, vertices: bv, indices: bi, heldFlat: laid.flatEnds)
            step("vinesMS")
            guard !Task.isCancelled else { return }
            log.end(rec, .done, struts: seg.count, stages: stages)
            bars.lightFrom = LatticeLayoutPreview.organicLightFrom(grown: look.modeValue == .grown, netFrom: seg.lightFrom,
                                                                   count: seg.count)
            let m = ViewerMesh(vertices: body.vertices, indices: body.indices,
                               faceIDs: [Int32](repeating: 1, count: body.indices.count / 3))
            organicBars = bars
            mesh = m
            camera.reframe(m.bounds)
            buildShown()
            let size = cube ? "40 mm cube" : "Sample part · 45 × 40 × 35 mm"
            // his 11-20 (img6): the cells the sample was asked for, his Manual numbers when he set them, never Auto's
            let lo = ask.spacingMM > 0 ? ask.spacingMM : ask.spacingMinMM, hi = ask.spacingMM > 0 ? ask.spacingMM : ask.spacingMaxMM
            let cells = lo > 0 && hi > 0
                ? (lo == hi ? String(format: " · cells %@ mm", StrengthCheckDocs.number(lo))
                            : String(format: " · cells %@ to %@ mm", StrengthCheckDocs.number(lo), StrengthCheckDocs.number(hi)))
                : ""
            caption = "\(size) · Organic \(look.modeValue.title) · one stress focus\(cells) · built by the engine"
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }   // the page moved on: nothing to say
            log.end(rec, .failed, reason: (error as? TopOptError)?.message ?? "\(error)", stages: stages)
            mesh = nil; organicBars = nil; failed = true
            // his 11-20: a centred pop-up in plain English; ★ his 11-22: "An error should always tell what's wrong and how
            // to fix it. Always." — a refusal says which setting, what it allows and the way out
            caption = Self.organicFailedCaption
            let why = (error as? LatticeRefused).flatMap { LatticeRefusalWords.lines($0.refusals) } ?? Self.organicFailedText
            AppPopups.shared.show(Self.organicFailedTitle, why, log: (error as? TopOptError)?.message ?? "\(error)")
        }
    }
    static let organicFailedCaption = "The sample couldn’t be built with these settings"
    static let organicFailedTitle = "The sample couldn’t be built"
    static let organicFailedText = "Something went wrong building the sample. Try again; if it keeps happening, tell us."

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
    static func notInSample(organic: Bool, finish: LatticeBoundaryTreatment, shapeBand: Bool, singleCell: Bool,
                            organicBuilt: Bool) -> [String] {
        if organic && organicBuilt { return [] }   // ★ his 11-18: Organic's own samples show it
        return notInSample(organic: organic, finish: finish, shapeBand: shapeBand, singleCell: singleCell)
    }
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

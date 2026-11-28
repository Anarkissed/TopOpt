// FlexibleMainPicture — ★ notes30 FF1: the main Flexible page's picture, made OFF the main thread (the maintainer's yes of
// 11-26/27: "move that work off the main thread"; the plan: agent-scratch/organic1/notes30/flex-freeze/scope.md).
//
// ★ WHY. After a "This face" change the lattice rebuilds and each squeeze group's sim lands; each landing re-made the page's
// whole picture ON THE MAIN THREAD — the overlay's channels, every field's mesh, the Play-all colours, the composed tints,
// and the GPU textures of EVERY field — 2.5 to 9 s per landing in a Debug build (builder F1, 11-26), and a tap that fell
// inside it was lost.
// ★ THREE PHASES PER REFRESH (FlexibleMainStage.refresh):
//   A. GATHER (main, cheap): the side effects it always had (the sims scheduled, the build's note) and ONE value of every
//      input (`FlexiblePictureJob` — arrays and dictionaries are copy-on-write, so the copy is O(1));
//   B. COMPUTE (`FlexiblePictureEngine.compute`, a pure function of the job) on ONE worker thread with a 16 MB stack
//      (TopOptKit's TopOptWorkerThread, the lattice layout's): the overlay, the shown values (once), the channels, each field's
//      mesh, the heat, the Play-all colours, the walls' heat, the composed tints, each field version's stress and GPU bytes —
//      each cached per version, so a refine tick that changes nothing drawn costs nothing;
//   C. COMMIT (main, O(1)): every value assigned TOGETHER, the loop's rules (unchanged), `generation` bumped only when what is
//      drawn changed (today's rule) — the picture swaps in one frame, never an animation (his live-preview rule).
// ★ NEWEST WINS. The worker holds at most ONE waiting job (a newer one replaces it); a running job finishes and commits unless
// its picture can never be drawn — a new lattice generation, another project, a page over the stage — then a cancel is heard
// between its steps and a stale result is never committed.
// ★ RELEASE 21'S ONE-SOLVE RULE IS UNTOUCHED: the worker never calls core and never takes FlexibleCoreGate.
// ★ TESTS: `FlexiblePictureWorker.inline` (on in an XCTest process) runs the SAME job inside refresh() and commits before it
// returns — today's order, the same code; the new tests (FlexibleFreezeHostedTests, FlexiblePictureParityTests) turn it off.

import Foundation
import os
import QuartzCore
import simd
import TopOptKit

// MARK: - one field version's GPU bytes

/// ★ notes30 FF1: one field VERSION as the GPU reads it — made once per version on the picture worker, uploaded by the pass with
/// one copy (FlexibleLatticePass.uploadFE).
public struct FlexibleFEGPUField: @unchecked Sendable {
    /// The version it was made from (`key(_:)`).
    let key: String
    /// The field with every u rounded through a half (FlexibleLatticePass.halfRounded — the parity tests' reference).
    let halfRounded: FlexibleFEField
    /// rgba16Float per node: u's xyz, and the node's von Mises over its field's own top (0 without one).
    let packed: [UInt16]
    let nx: Int, ny: Int, nz: Int

    /// A version's identity: its serial and its calibrated scale (the page's fe token hashes the same two).
    static func key(_ f: FlexibleFEField) -> String { "\(f.serial)|\(f.scale)" }
}

/// ★ notes30 FF1: one lattice's volumes as the GPU reads them (FlexibleLatticePass.prepare — the CPU half of its upload): made
/// once per lattice GENERATION on the picture worker; the pass makes its textures from them with one copy each.
public struct FlexibleLatticeGPU: @unchecked Sendable {
    struct Volume<T> {
        let bytes: [T]
        let dims: (Int, Int, Int)
        /// rgba32Float (the press seam rides in z, w), else rg32Float.
        let four: Bool
    }
    let generation: Int
    /// The inputs the walls are compared with (the SDF and skin rounded through a half, the grids the volumes are on).
    let ref: FlexibleLatticeInputs
    let rm: Volume<Float>?
    let ds: Volume<UInt16>?
    let regionMin: SIMD3<Float>
    let regionMax: SIMD3<Float>
    let rhoSpan: SIMD2<Float>
}

#if canImport(MetalKit)
extension FlexibleFEGPUField {
    /// `stress`: the field's own von Mises per node and its scale's top (FlexibleFEStress.field / scaleTop); nil: none.
    /// (The packing moved here from FlexibleLatticePass.makeFieldTexture, unchanged.)
    static func make(_ f: FlexibleFEField, stress: (vonMises: [Float], top: Double)?) -> FlexibleFEGPUField? {
        let n = f.nx * f.ny * f.nz
        guard f.nx > 0, f.ny > 0, f.nz > 0, f.u.count == n else { return nil }
        let vm: [Float]? = stress.flatMap { s in s.top > 0 ? s.vonMises.map { $0 / Float(s.top) } : nil }
        var packed = [UInt16](repeating: 0, count: 4 * n)
        for i in 0..<n {
            packed[4 * i] = FlexibleLatticePass.halfBits(f.u[i].x); packed[4 * i + 1] = FlexibleLatticePass.halfBits(f.u[i].y)
            packed[4 * i + 2] = FlexibleLatticePass.halfBits(f.u[i].z)
            if let vm, i < vm.count { packed[4 * i + 3] = FlexibleLatticePass.halfBits(vm[i]) }
        }
        return FlexibleFEGPUField(key: key(f), halfRounded: FlexibleLatticePass.halfRounded(f), packed: packed, nx: f.nx, ny: f.ny, nz: f.nz)
    }

    /// The pass's own (a field the page did not prepare): its stress made here.
    static func make(_ f: FlexibleFEField) -> FlexibleFEGPUField? {
        make(f, stress: FlexibleFEStress.field(f).map { ($0.vonMises, FlexibleFEStress.scaleTop($0)) })
    }
}
#endif

// MARK: - the main-thread phases (measured)

/// ★ notes30 FF1: the Flexible page's main-thread phases — gather, commit, the H4' tints, `applyFlexibleLattice` (and, under the
/// red control or in a test's inline mode, the whole picture). Each is a signposted interval (Instruments' Points of Interest:
/// the Release meter) and, while a test records, timed in ms.
public enum FlexibleMainPhases {
    static let signposter = OSSignposter(logHandle: OSLog(subsystem: "app.topopt.flexible", category: .pointsOfInterest))
    private static let lock = NSLock()
    nonisolated(unsafe) private static var on = false
    nonisolated(unsafe) private static var entries: [(name: String, ms: Double)] = []

    /// Tests: start (clears the log) or stop recording.
    static var recording: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); on = newValue; entries = []; lock.unlock() }
    }
    /// Tests: what was recorded, in order.
    static var log: [(name: String, ms: Double)] { lock.lock(); defer { lock.unlock() }; return entries }

    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let t0 = CACurrentMediaTime()
        defer {
            signposter.endInterval(name, state)
            let ms = (CACurrentMediaTime() - t0) * 1000
            lock.lock()
            if on { entries.append(("\(name)", ms)) }
            lock.unlock()
        }
        return try body()
    }
}

// MARK: - the job (gathered on main) and the picture (made on the worker)

/// The stress of one field version (the Stress view, its legend's top, the walls' w channel): made once per version.
struct FlexibleFieldStress: @unchecked Sendable {
    let key: String
    let field: LatticeDemandField
    let peak: Double
    let scaleTop: Double
}

/// ★ notes30 FF1: every input of the page's picture, as values (FlexibleMainStage.gatherPicture). Nothing here is a live
/// main-actor object: the model and the project never enter a job.
struct FlexiblePictureJob: @unchecked Sendable {
    // identity
    var serial = 0
    var epoch = 0
    // the overlay: rebuilt (from `overlayJob`; nil = none) when what it is made from moved, else the committed one
    var oKey = ""
    var overlayCacheKey = ""
    var rebuildOverlay = false
    var overlayJob: FlexibleOverlayJob?
    var overlay: FlexibleOverlayMesh?
    var overlaySerial = 0
    // the lattice and the sims (the plan of FlexibleMainStage.feView — its meshes are made here)
    var drawn: FlexibleGeneratedLattice?
    var fallbackSim: String?
    var fe = FlexibleFEView()
    var feShownKey: String?
    var feShownIndex = 0
    var simKeys: [String: [FlexFaceKey]] = [:]
    var pinchedByRegion: [Int: [Bool]] = [:]
    var manualHeat = false
    var playLattice: FlexibleGeneratedLattice?
    var lattice: FlexibleGeneratedLattice?
    var wallLattice: FlexibleGeneratedLattice?
    var latticeBuilding = false
    var latticeIsStale = false
    var latticeAvailable = false
    // the channels' inputs (the model's values) and the edges groups' heat
    var channels: FlexiblePageChannels.Inputs?
    var pressHeat: [FlexiblePressHeat.Entry] = []
    var stacks: [FlexFaceKey: FlexStackInfo] = [:]
    var partMesh: ViewerMesh?
    var ghostColour = SIMD4<Float>(repeating: 0)
    // the views
    var heat = false
    var stress = false
    var xray = false
    var facePrismsSet = false
    var printedDrawn = false
    var wallsDrawnBase = false
    var attachView = false
    var hasModel = false
    // Stress (H4'): the groups' sims, or the solid part's field the body handed over
    var feStressRoute = false
    var solidStress: (field: LatticeDemandField, peak: Double)?
    var solidStressDrawable = false
    var stressKey = 0
    // the controls each of the moved steps reads (captured here — the worker never reads the stage's)
    var controlColumnHeat = false
    var controlPlayAllCombo = false
    var controlDentXrayOnFallback = false
    var controlDrawnCurveOnMain = false
    var controlHeatOnLid = false
    var controlPrintedRulesApart = false
    var controlStressScaleIsPeak = false
    var controlRound5Frames = false
    var controlRolesOnMain = false
    /// RED CONTROL `controlRound5Frames` only: round 5's group frames, painted by the model (the job then runs on main).
    var paintFrames: ((inout [Float]?, FlexibleOverlayMesh?) -> Void)?
}

/// ★ notes30 FF1: the page's picture, ONE value, committed together (FlexibleMainStage.commitPicture).
struct FlexiblePicture: @unchecked Sendable {
    var serial = 0
    var epoch = 0
    var oKey = ""
    var overlay: FlexibleOverlayMesh?
    var overlaySerial = 0
    var drawn: FlexibleGeneratedLattice?
    var fallbackSim: String?
    var fe = FlexibleFEView()
    var channels = FlexiblePageChannels.Channels(tints: nil, dents: nil, exaggeration: 0, animated: false, legendLine: "")
    /// What is drawn, as today's key (its hashes made on the worker, never on main).
    var key = ""
    var dentMaxMM = 0.0
    var heatValues: [Float]?
    var dentMapShown = false
    var dentOnColumnFallback = false
    var feBaseTints: [String: [Float]] = [:]
    var wallHeat: FlexibleWallHeat?
    // the caches the main thread's own readers share (a tap's reading, the Stress legend, the printed view)
    var feValues: [String: (key: String, values: [Float])] = [:]
    var feColumns: [String: (key: String, values: [FlexFaceKey: [Double?]])] = [:]
    var feStress: [String: FlexibleFieldStress] = [:]
    var open: (key: String, open: [Bool])?
    // H4': the ONE tint array, each Play-all version's, and what they were composed from
    var composed: [Float]?
    var composedPer: [String: [Float]] = [:]
    var composeKey = ""
    /// Each field's GPU bytes, aligned with `fe.fields`.
    var gpu: [FlexibleFEGPUField?] = []
    /// The lattice's volumes (its generation's).
    var latticeGPU: FlexibleLatticeGPU?
}

// MARK: - the compute (a pure function of the job; caches per version)

final class FlexiblePictureEngine: @unchecked Sendable {
    /// RED CONTROL (tests only — the parity test's): one step of the picture dropped; the parity must catch it.
    nonisolated(unsafe) static var controlDropStep: String?

    private let lock = NSLock()
    private var overlayCache: (key: String, overlay: FlexibleOverlayMesh?, serial: Int)?
    private var overlaySerials = 0
    private var meshCache: [String: (key: String, mesh: [Float])] = [:]
    private var valueCache: [String: (key: String, values: [Float])] = [:]
    private var columnCache: [String: (key: String, values: [FlexFaceKey: [Double?]])] = [:]
    private var stressCache: [String: FlexibleFieldStress?] = [:]
    private var stressKeys: [String: String] = [:]
    private var gpuCache: [String: FlexibleFEGPUField] = [:]
    private var openCache: (key: String, open: [Bool])?
    private var composeCache: (key: String, composed: [Float]?, per: [String: [Float]])?
    private var latticeCache: FlexibleLatticeGPU?
    /// Tests: how many times each step really ran (a cache hit does not count).
    private var made: [String: Int] = [:]

    /// Tests: the steps made so far.
    var madeCounts: [String: Int] { lock.lock(); defer { lock.unlock() }; return made }
    /// Tests: forget every cache (the next job makes everything again).
    func forget() {
        lock.lock()
        overlayCache = nil; meshCache = [:]; valueCache = [:]; columnCache = [:]; stressCache = [:]; stressKeys = [:]
        gpuCache = [:]; openCache = nil; composeCache = nil; latticeCache = nil
        lock.unlock()
    }

    /// The picture of `j`; nil when `cancelled` said so between two steps. One job at a time (the lock: the worker's, or a
    /// test's inline run on main).
    func compute(_ j: FlexiblePictureJob, cancelled: () -> Bool) -> FlexiblePicture? {
        lock.lock()
        defer { lock.unlock() }
        return run(j, cancelled)
    }

    private func count(_ step: String) { made[step, default: 0] += 1 }
    private static func dropped(_ step: String) -> Bool { controlDropStep == step }

    private func run(_ j: FlexiblePictureJob, _ cancelled: () -> Bool) -> FlexiblePicture? {
        var p = FlexiblePicture()
        p.serial = j.serial; p.epoch = j.epoch; p.oKey = j.oKey
        p.drawn = j.drawn; p.fallbackSim = j.fallbackSim

        // 1. the overlay (rebuilt only when what it is made from moved — today's key)
        let overlay: FlexibleOverlayMesh?
        let oSerial: Int
        if j.rebuildOverlay {
            if let c = overlayCache, c.key == j.overlayCacheKey {
                overlay = c.overlay; oSerial = c.serial
            } else {
                overlay = j.overlayJob.map { FlexiblePageChannels.overlay($0) }
                overlaySerials = Swift.max(overlaySerials, j.overlaySerial) &+ 1
                oSerial = overlaySerials
                overlayCache = (j.overlayCacheKey, overlay, oSerial)
                meshCache = [:]
                count("overlay")
            }
        } else {
            overlay = j.overlay; oSerial = j.overlaySerial
            overlaySerials = Swift.max(overlaySerials, oSerial)
            overlayCache = (j.overlayCacheKey, overlay, oSerial)
        }
        p.overlay = overlay; p.overlaySerial = oSerial
        if cancelled() { return nil }

        // 1b. the lattice's volumes (once per generation — the pass's upload makes its textures from them)
        p.latticeGPU = latticeGPU(j.lattice)
        if cancelled() { return nil }

        // 2. each field's mesh on this overlay (per version), and the token the pass uploads the fields by
        var fe = j.fe
        fe.mesh = fe.fields.map { feMesh($0, overlay, oSerial) }
        if let g = fe.tokenGeneration {
            var h = Hasher()
            h.combine(g)
            for f in fe.fields { h.combine(f.serial); h.combine(f.scale) }
            h.combine(oSerial)
            fe.token = h.finalize()
        }
        if cancelled() { return nil }

        // 3. the FE heat of the sequence on screen (every face by its own group's sim, one scale)
        let feNow = feHeat(fe, j, overlay, oSerial)
        if cancelled() { return nil }

        // 4. the values shown (ONCE — they were made twice per refresh) and the channels
        guard var inputs = j.channels else { return nil }
        inputs.shown = inputs.shown.resolvingStamps()
        let shown = FlexibleShownValues(inputs.shown, drawnLattice: j.drawn, frozenExaggeration: inputs.frozenExaggeration)
        let prisms = j.facePrismsSet
        let latticeHeat = prisms && (j.drawn != nil || feNow != nil || j.controlDrawnCurveOnMain)
        let pressHeat = j.heat && latticeHeat ? j.pressHeat : []
        var c = FlexiblePageChannels.channels(inputs, shown: shown, overlay: overlay, xray: false, drawnLattice: j.drawn,
                                              heat: j.heat && latticeHeat,
                                              depthScaleMM: pressHeat.isEmpty ? feNow?.scaleMM
                                                : feNow.map { Swift.max($0.scaleMM, FlexiblePressHeat.top(pressHeat)) },
                                              mapValues: feNow?.first, controlColumnColours: j.controlColumnHeat, pressHeat: pressHeat)
        if !latticeHeat { c.dents = nil; c.exaggeration = 0; c.mapValues = nil }
        if let paint = j.paintFrames { paint(&c.tints, overlay) }   // (the red control only)
        if Self.dropped("tints") { c.tints = nil }
        let dentMaxMM = latticeHeat ? (pressHeat.isEmpty ? (feNow?.scaleMM ?? shown.maxDepth) : c.heatScaleMM) : 0
        p.dentMaxMM = dentMaxMM
        p.heatValues = c.mapValues
        p.dentMapShown = overlay?.flatStart.isEmpty == false && dentMaxMM > 0
        p.dentOnColumnFallback = j.drawn != nil && !fe.active && !fe.pending && !j.controlDentXrayOnFallback
        if cancelled() { return nil }

        // 5. "Play all": each landed group's own colours
        p.feBaseTints = playAllBaseTints(fe, j, inputs, overlay, oSerial, scaleMM: dentMaxMM, nextScaleMM: feNow?.nextScaleMM)
        if cancelled() { return nil }

        // 6. the walls' heat
        p.wallHeat = wallHeat(fe, j, overlay, oSerial, shown: shown, dentMaxMM: dentMaxMM)
        if fe.active {
            c.exaggeration = FlexibleShownValues.cappedExaggeration(rule: shown.uncappedExaggeration, maxSafeScale: fe.safeScale)
            let i = Self.shownIndex(fe, key: j.feShownKey, index: j.feShownIndex)
            c.dents = i < fe.mesh.count ? fe.mesh[i] : nil
        }

        // 7. the views that need this overlay, and what is drawn as ONE key (today's — its hashes made here)
        let printedReady = j.printedDrawn && (j.controlPrintedRulesApart || overlay != nil) && !j.attachView
        let heatOnWalls = !j.controlHeatOnLid && j.heat && !j.stress && p.wallHeat != nil && j.facePrismsSet && dentMaxMM > 0
            && j.wallsDrawnBase && (j.xray || printedReady)
        p.key = [String(describing: c.tints.map { VertexTintKey($0).hash }),
                 String(describing: (fe.active ? nil : c.dents).map { VertexTintKey($0).hash }),   // (FE: the token below)
                 "\(c.exaggeration)", "\(j.drawn?.generation ?? -1)", "\(j.drawn?.facesToken ?? -1)", "\(j.latticeBuilding)",
                 "\(j.lattice?.generation ?? -1)", "\(j.latticeIsStale)", j.oKey, "\(j.latticeAvailable)",
                 "\(fe.token)", "\(fe.sequence)", "\(fe.shownSequence)", "\(fe.pending)", fe.failure ?? "", "\(j.xray)", "\(j.stress)",
                 "\(prisms)", "\(printedReady)"].joined(separator: "|")
            + "|\(p.wallHeat?.token ?? 0)|\(heatOnWalls)"
        p.channels = c
        p.fe = fe
        if cancelled() { return nil }

        // 8. each field version's stress (the Stress view, its legend's top, the walls' w) and its GPU bytes — once per version
        for f in fe.fields { if let s = stress(f) { p.feStress[f.versionKey] = s } }
        p.gpu = fe.fields.map { gpu($0) }
        for f in fe.fields {
            if let v = valueCache[f.versionKey] { p.feValues[f.versionKey] = v }
            if let v = columnCache[f.versionKey] { p.feColumns[f.versionKey] = v }
        }
        if cancelled() { return nil }

        // 9. H4': the printed view's open surface and the ONE tint array (+ each Play-all version's)
        let open = printedOpen(j, overlay, oSerial, printedReady: printedReady)
        p.open = open
        let bare = !j.controlHeatOnLid && j.heat && !j.stress && j.hasModel && (heatOnWalls || printedReady)
        let si = Self.shownIndex(fe, key: j.feShownKey, index: j.feShownIndex)
        let shownStress: FlexibleFieldStress? = fe.active && si < fe.fields.count ? stress(fe.fields[si]) : nil
        let shownTop = shownStress.map { j.controlStressScaleIsPeak ? $0.peak : $0.scaleTop } ?? 0
        let stressDrawable = j.feStressRoute ? (fe.active && shownTop > 0) : j.solidStressDrawable
        let showStress = j.stress && stressDrawable
        p.composeKey = "\(p.key)|" + FlexibleMainStage.composeKeyBody(
            rolesHash: FlexibleMainStage.rolesHash([:]), showStress: showStress, feRoute: j.feStressRoute, feToken: fe.token,
            stressKey: j.stressKey, xray: j.xray, heat: j.heat, hasOverlay: overlay != nil, bare: bare,
            baseKeys: Array(p.feBaseTints.keys), controlStressScaleIsPeak: j.controlStressScaleIsPeak,
            controlRound5Frames: j.controlRound5Frames, controlRolesOnMain: j.controlRolesOnMain, openKey: open?.key ?? "-")
        if let cc = composeCache, cc.key == p.composeKey {
            p.composed = cc.composed; p.composedPer = cc.per
        } else {
            let onePeak = showStress && j.controlStressScaleIsPeak
                ? (fe.sequence.compactMap { i in i < fe.fields.count ? stress(fe.fields[i])?.peak : nil }.max() ?? 0) : 0
            func stressOf(_ key: String?) -> (field: LatticeDemandField, peak: Double)? {
                guard showStress else { return nil }
                guard j.feStressRoute else { return j.solidStress }
                guard let f = fe.fields.first(where: { $0.versionKey == key }) ?? fe.sequence.first.map({ fe.fields[$0] }),
                      let s = stress(f) else { return nil }
                return (s.field, j.controlStressScaleIsPeak ? onePeak : s.scaleTop)
            }
            let ghost: SIMD4<Float>? = j.xray ? j.ghostColour : nil
            let first = (fe.shownSequence.first ?? fe.sequence.first).map { fe.fields[$0].versionKey }
            var composed = FlexibleMainTints.compose(base: c.tints, overlay: overlay, part: j.partMesh, heat: j.heat, roles: [:],
                                                     stress: stressOf(first), ghost: ghost, open: open?.open, lidWithoutHeat: bare)
            if let paint = j.paintFrames { paint(&composed, overlay) }
            var per: [String: [Float]] = [:]
            for (id, base) in p.feBaseTints {
                per[id] = FlexibleMainTints.compose(base: base, overlay: overlay, part: j.partMesh, heat: j.heat, roles: [:],
                                                    stress: stressOf(id), ghost: ghost, open: open?.open, lidWithoutHeat: bare)
            }
            if showStress, j.feStressRoute, per.isEmpty, fe.sequence.count > 1 || !fe.retained.isEmpty, let base = c.tints {
                for i in fe.sequence + fe.retained where i < fe.fields.count {
                    let id = fe.fields[i].versionKey
                    per[id] = FlexibleMainTints.compose(base: base, overlay: overlay, part: j.partMesh, heat: j.heat, roles: [:],
                                                        stress: stressOf(id), ghost: ghost, open: open?.open, lidWithoutHeat: bare)
                }
            }
            if let paint = j.paintFrames { for id in Array(per.keys) { paint(&per[id], overlay) } }
            p.composed = composed; p.composedPer = per
            composeCache = (p.composeKey, composed, per)
            count("compose")
        }
        count("picture")
        return p
    }

    // MARK: the steps (FlexibleMainStage+Squish's, over the job's values)

    /// The loop's field on screen: by its version, else by its index, else the sequence's first (FlexibleMainStage.feShownIndex).
    static func shownIndex(_ v: FlexibleFEView, key: String?, index: Int) -> Int {
        if let key, let i = v.fields.firstIndex(where: { $0.versionKey == key }) { return i }
        return v.sequence.contains(index) ? index : (v.sequence.first ?? 0)
    }

    private func feMesh(_ f: FlexibleFEField, _ overlay: FlexibleOverlayMesh?, _ oSerial: Int) -> [Float] {
        guard let o = overlay else { return [] }
        let key = "\(oSerial)|\(f.serial)|\(f.scale)"
        if let c = meshCache[f.versionKey], c.key == key { return c.mesh }
        let mesh = f.meshDisplacements(positions: o.mesh.flat.positions)
        meshCache[f.versionKey] = (key, mesh)
        count("mesh")
        return mesh
    }

    private func feColumnValues(_ f: FlexibleFEField, _ j: FlexiblePictureJob, _ overlay: FlexibleOverlayMesh?,
                                _ oSerial: Int) -> [FlexFaceKey: [Double?]]? {
        guard let o = overlay else { return nil }
        let key = "\(oSerial)|\(f.serial)|\(f.scale)|\(j.manualHeat)"
        if let c = columnCache[f.versionKey], c.key == key { return c.values }
        let keys = Set(j.simKeys[f.simID] ?? [])
        let ratio = 1 / Swift.max(1e-6, f.foldShare ?? 1)
        var perColumn: [FlexFaceKey: [Double?]] = [:]
        for k in o.flatStart.keys where keys.contains(k) {
            guard let st = j.stacks[k] else { continue }
            // ★ ROUND 7 · MANUAL follow-up: in Manual the Squish page's estimate, column for column
            if j.manualHeat {
                perColumn[k] = FlexibleStageModel.estimateColumnValues(f, st).map { Optional($0) }
                continue
            }
            let pinched = j.pinchedByRegion[k.region] ?? []
            perColumn[k] = st.columns.indices.map { c in
                Swift.max(0, f.columnCompression(stack: st, col: c, pinched: c < pinched.count && pinched[c]) * ratio)
            }
        }
        columnCache[f.versionKey] = (key, perColumn)
        count("columns")
        return perColumn
    }

    private func feMapValues(_ f: FlexibleFEField, _ j: FlexiblePictureJob, _ overlay: FlexibleOverlayMesh?, _ oSerial: Int) -> [Float]? {
        guard let o = overlay, let perColumn = feColumnValues(f, j, overlay, oSerial) else { return nil }
        let key = "\(oSerial)|\(f.serial)|\(f.scale)|\(j.manualHeat)"
        if let c = valueCache[f.versionKey], c.key == key { return c.values }
        let out = o.mapCornerValues(perColumn, stacks: j.stacks)
        valueCache[f.versionKey] = (key, out)
        count("values")
        return out
    }

    private func feHeat(_ fe: FlexibleFEView, _ j: FlexiblePictureJob, _ overlay: FlexibleOverlayMesh?,
                        _ oSerial: Int) -> (first: [Float], scaleMM: Double, nextScaleMM: Double)? {
        guard fe.active, !j.controlColumnHeat, !Self.dropped("heat") else { return nil }
        func heat(_ seq: [Int]) -> (union: [Float], top: Double)? {
            let all = seq.compactMap { i in i < fe.fields.count ? feMapValues(fe.fields[i], j, overlay, oSerial) : nil }
            guard var union = all.first else { return nil }
            for v in all.dropFirst() {
                for i in union.indices where i < v.count && !union[i].isFinite && v[i].isFinite { union[i] = v[i] }
            }
            let top = all.map { $0.reduce(Float(0)) { $1.isFinite ? Swift.max($0, $1) : $0 } }.max() ?? 0
            return top > 1e-6 ? (union, Double(top)) : nil
        }
        guard let now = heat(fe.shownSequence.isEmpty ? fe.sequence : fe.shownSequence) else { return nil }
        let next = fe.shownSequence == fe.sequence ? now.top : (heat(fe.sequence)?.top ?? now.top)
        return (now.union, now.top, next)
    }

    private func playAllBaseTints(_ fe: FlexibleFEView, _ j: FlexiblePictureJob, _ inputs: FlexiblePageChannels.Inputs,
                                  _ overlay: FlexibleOverlayMesh?, _ oSerial: Int, scaleMM: Double, nextScaleMM: Double?) -> [String: [Float]] {
        guard fe.active, fe.sequence.count > 1 || !fe.retained.isEmpty, let lat = j.playLattice, !j.controlPlayAllCombo,
              !Self.dropped("playAll") else { return [:] }
        var out: [String: [Float]] = [:]
        for i in fe.sequence + fe.retained where i < fe.fields.count {
            let id = fe.fields[i].simID
            let d = FlexibleLatticePreview.drawn(lat.showing(id), xray: true, building: j.latticeBuilding,
                                                 checkStampShown: nil, stale: j.latticeIsStale)
            let scale = fe.retained.contains(i) ? scaleMM : (nextScaleMM ?? scaleMM)
            out[fe.fields[i].versionKey] = FlexiblePageChannels.channels(inputs, overlay: overlay, xray: false, drawnLattice: d, heat: j.heat,
                                                                         depthScaleMM: scale,
                                                                         mapValues: feMapValues(fe.fields[i], j, overlay, oSerial)).tints
            count("playAll")
        }
        return out
    }

    private func wallHeat(_ fe: FlexibleFEView, _ j: FlexiblePictureJob, _ overlay: FlexibleOverlayMesh?, _ oSerial: Int,
                          shown: FlexibleShownValues, dentMaxMM: Double) -> FlexibleWallHeat? {
        guard dentMaxMM > 0, let g = j.wallLattice, g.keys.count == g.faces.count, !Self.dropped("walls") else { return nil }
        let squished = Set(g.squishedKeys)
        let slots = zip(g.keys, g.faces).filter { squished.contains($0.0) }
        guard !slots.isEmpty else { return nil }
        // the FE route: every face by its own group's field over the sequence on screen (FlexibleMainStage.feColumnHeat)
        var fromFE: [FlexFaceKey: [Double?]]?
        if fe.active, !j.controlColumnHeat {
            var out: [FlexFaceKey: [Double?]] = [:]
            for i in (fe.shownSequence.isEmpty ? fe.sequence : fe.shownSequence) where i < fe.fields.count {
                for (k, v) in feColumnValues(fe.fields[i], j, overlay, oSerial) ?? [:] where out[k] == nil { out[k] = v }
            }
            fromFE = out.isEmpty ? nil : out
        }
        let perColumn: [FlexFaceKey: [Double?]] = fromFE ?? shown.values.mapValues { v in
            v.map { if case .depth(let d) = $0 { return d } else { return nil } }
        }
        let cells = slots.map { k, face in
            j.stacks[k].map { FlexibleWallHeat.cells(stack: $0, face: face, perColumn: perColumn[k] ?? []) }
                ?? [Float](repeating: -1, count: face.nu * face.nv)
        }
        return FlexibleWallHeat(cells: cells, topMM: Float(dentMaxMM))
    }

    private func stress(_ f: FlexibleFEField) -> FlexibleFieldStress? {
        let key = FlexibleFEGPUField.key(f)
        if stressKeys[f.versionKey] == key, let c = stressCache[f.versionKey] { return c }
        let s = FlexibleFEStress.field(f).map { field in
            FlexibleFieldStress(key: key, field: field, peak: LatticeStressTint.peakMPa(field), scaleTop: FlexibleFEStress.scaleTop(field))
        }
        stressCache[f.versionKey] = s
        stressKeys[f.versionKey] = key
        count("stress")
        return s
    }

    private func gpu(_ f: FlexibleFEField) -> FlexibleFEGPUField? {
        #if canImport(MetalKit)
        let key = FlexibleFEGPUField.key(f)
        if let c = gpuCache[f.versionKey], c.key == key { return c }
        guard let g = FlexibleFEGPUField.make(f, stress: stress(f).map { ($0.field.vonMises, $0.scaleTop) }) else { return nil }
        gpuCache[f.versionKey] = g
        count("gpu")
        return g
        #else
        return nil
        #endif
    }

    private func latticeGPU(_ g: FlexibleGeneratedLattice?) -> FlexibleLatticeGPU? {
        #if canImport(MetalKit)
        guard let g else { return nil }
        if let c = latticeCache, c.generation == g.generation { return c }
        let prep = FlexibleLatticePass.prepare(g.inputs, generation: g.generation)
        latticeCache = prep
        count("lattice")
        return prep
        #else
        return nil
        #endif
    }

    private func printedOpen(_ j: FlexiblePictureJob, _ overlay: FlexibleOverlayMesh?, _ oSerial: Int,
                             printedReady: Bool) -> (key: String, open: [Bool])? {
        guard j.hasModel, printedReady, let o = overlay, let g = j.lattice else { return nil }
        let key = "\(oSerial)|\(g.generation)|\(o.mesh.flat.vertexCount)"
        if let c = openCache, c.key == key { return c }
        let open = FlexibleMainTints.overLattice(mesh: o.mesh, lattice: g.inputs)
        openCache = (key, open)
        count("open")
        return (key, open)
    }
}

// MARK: - the worker (one thread, newest wins)

/// ★ notes30 FF1: the page's picture worker — ONE thread with a 16 MB stack (TopOptKit's TopOptWorkerThread), at most one
/// waiting job (a newer one replaces it at the door), a running job cancelled only when its picture can never be drawn
/// (`cancel(to:)`: a new lattice generation, another project, a page over the stage).
final class FlexiblePictureWorker: @unchecked Sendable {
    /// Tests: the job runs synchronously inside refresh() and commits before it returns (today's order, the same code) — ON in
    /// an XCTest process (hundreds of tests read the page right after refresh()), OFF in the app; the new tests turn it off.
    /// `TOPOPT_PICTURE_WORKER=1` in the environment runs a whole test process in the app's mode (the check test, unchanged).
    nonisolated(unsafe) static var inline = NSClassFromString("XCTestCase") != nil
        && ProcessInfo.processInfo.environment["TOPOPT_PICTURE_WORKER"] != "1"
    /// RED CONTROL (tests only): today's path — the picture made on the main thread inside refresh(), and every field's GPU
    /// texture (its bytes too) made again on the main thread at each upload.
    nonisolated(unsafe) static var controlPictureOnMain = false
    /// The worker's stack: 16 MB (the lattice layout's; more than the iPad's main thread ever had).
    static let stackSize = 16 << 20

    let engine: FlexiblePictureEngine
    private let thread: TopOptWorkerThread
    private let lock = NSLock()
    private var waiting: (job: FlexiblePictureJob, done: (FlexiblePicture) -> Void)?
    private var running = false
    private var epoch = 0
    private var ranCount = 0, replacedCount = 0, cancelledCount = 0

    init(engine: FlexiblePictureEngine) {
        self.engine = engine
        thread = TopOptWorkerThread(stackSize: Self.stackSize, name: "TopOpt Flexible picture")
    }
    deinit { thread.stop() }

    /// Tests: jobs computed, jobs a newer one replaced at the door, jobs cancelled.
    var counts: (ran: Int, replaced: Int, cancelled: Int) { lock.lock(); defer { lock.unlock() }; return (ranCount, replacedCount, cancelledCount) }

    /// `done` runs on the worker thread (the stage hops to main to commit).
    func submit(_ job: FlexiblePictureJob, done: @escaping (FlexiblePicture) -> Void) {
        lock.lock()
        if waiting != nil { replacedCount += 1 }
        waiting = (job, done)
        epoch = Swift.max(epoch, job.epoch)
        let start = !running
        running = true
        lock.unlock()
        if start { thread.submit { [self] in drain() } }
    }

    /// Every job of an older epoch stops at its next step, and its picture is never handed over.
    func cancel(to e: Int) {
        lock.lock()
        epoch = Swift.max(epoch, e)
        lock.unlock()
    }

    private func current(_ e: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return e >= epoch
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = waiting else { running = false; lock.unlock(); return }
            waiting = nil
            lock.unlock()
            let p = current(next.job.epoch) ? engine.compute(next.job, cancelled: { !self.current(next.job.epoch) }) : nil
            lock.lock()
            if p == nil { cancelledCount += 1 } else { ranCount += 1 }
            lock.unlock()
            if let p { next.done(p) }
        }
    }
}

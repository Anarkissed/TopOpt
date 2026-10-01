// FlexibleStageModel — the Flexible stage's state and its recompute pipeline (task
// 2026-09-29-flexible-screens, A1).
//
// ★ WHO COMPUTES WHAT. Every number shown comes from core through FlexibleKit (M9). This
// model only decides WHEN to ask and caches the answers:
//   * the scene (part, grid, lattice mask, face regions) opens once per placement;
//   * a face's stack is built once per (face, frame rotation) and cached in core AND here;
//   * a dragged curve point re-runs ONLY the squish map (≈1 ms) at once, then the design
//     (≈0.1 s) off the main thread, coalesced so a fast drag never queues designs;
//   * Auto, the density field, conflicts and stamp checks follow the design.
//
// ★ SETTINGS LIVE IN THE PROJECT (`project.lattice.flexible`), so they are saved with it
// and undone by the same snapshot history as every other stage (S5).

import Combine
import Foundation
import simd
import TopOptKit

/// The bridge calls, serialised off the main thread. One scene at a time.
actor FlexibleWorker {
    private(set) var scene: FlexibleScene?
    private(set) var sceneKey: String?

    func open(jobJSON: String, jobDir: String, key: String) throws -> FlexibleScene.Info {
        if sceneKey != key || scene == nil {
            scene = nil
            scene = try FlexibleScene(jobJSON: jobJSON, jobDir: jobDir)
            sceneKey = key
        }
        return try scene!.info()
    }
    func withScene<T>(_ body: (FlexibleScene) throws -> T) throws -> T {
        guard let s = scene else { throw TopOptError(message: "The part is still opening.") }
        return try body(s)
    }
    /// ★ BATCH G: the scene itself, fetched in one quick hop — the squish sims run OFF this actor
    /// (it serialises the design calls and must never wait seconds on a solve).
    func sceneRef() -> FlexibleScene? { scene }
}

/// One control point of one face's X or Y curve (the × on the model, round 3 item 8).
public struct FlexCurvePoint: Equatable, Sendable {
    public let region: Int
    public let axis: String      // "x" | "y"
    public let index: Int
}

public struct FlexFaceKey: Hashable, Sendable {
    public let region: Int
    public let rotation: Int
}

/// Where a face's drawings go in 3D — every point from core's frame (from_uv / to_uv).
public struct FlexFaceGeometry {
    /// from_uv at every column centre, column order.
    public let centres: [SIMD3<Double>]
    /// The X edge (v = 0) and the Y edge (u = 0), on the face — both curves are drawn at
    /// once (round 3: "X and Y always combined"; the centre→edge line went with its mode).
    public let baselineX: FlexibleCurveBaseline
    public let baselineY: FlexibleCurveBaseline
    /// The frame's corner (u = 0, v = 0) on the face: where the X / Y arrows start.
    public let corner: SIMD3<Double>
    /// to_uv + t of every flat vertex of the part (the dent's ramp).
    public let partUVT: [Double]

    static func compute(scene: FlexibleScene, key k: FlexFaceKey, stack st: FlexStackInfo,
                        partFlat: [Float]) throws -> FlexFaceGeometry {
        let centres = try scene.fromUV(face: k.region, rotation: k.rotation,
                                       st.columns.map { SIMD2($0.uMM, $0.vMM) })
        // the entry along the load of the column nearest (u, v): the edge hugs the face
        func entry(_ u: Double, _ v: Double) -> Double {
            guard st.nu > 0, st.nv > 0, st.pitchMM > 0 else { return 0 }
            let iu = min(st.nu - 1, max(0, Int(u / st.pitchMM))), iv = min(st.nv - 1, max(0, Int(v / st.pitchMM)))
            var best: (Int, Int)? = nil
            for r in 0..<max(st.nu, st.nv) {
                for dv in -r...r { for du in -r...r where abs(du) == r || abs(dv) == r {
                    let c = st.column(iu + du, iv + dv)
                    if c >= 0, best == nil || du * du + dv * dv < best!.1 { best = (c, du * du + dv * dv) }
                } }
                if best != nil { break }
            }
            return best.map { st.columns[$0.0].entryT } ?? 0
        }
        let n = 30
        func line(_ uv: (Double) -> (Double, Double)) throws -> [SIMD3<Double>] {
            let pts = (0...n).map { uv(Double($0) / Double(n)) }
            let w = try scene.fromUV(face: k.region, rotation: k.rotation, pts.map { SIMD2($0.0, $0.1) })
            return zip(w, pts).map { $0 + st.load * entry($1.0, $1.1) }
        }
        let amp = max(5, min(40, 0.25 * max(st.uExtentMM, st.vExtentMM)))
        let up = -st.load
        let bx = FlexibleCurveBaseline(points: try line { (st.uExtentMM * $0, 0) }, up: up, amplitudeMM: amp)
        let by = FlexibleCurveBaseline(points: try line { (0, st.vExtentMM * $0) }, up: up, amplitudeMM: amp)
        let corner = try line { _ in (0, 0) }.first ?? .zero
        var xyz = [Double](); xyz.reserveCapacity(partFlat.count)
        for f in partFlat { xyz.append(Double(f)) }
        let uvt = try scene.toUVT(face: k.region, rotation: k.rotation, xyz)
        return FlexFaceGeometry(centres: centres, baselineX: bx, baselineY: by,
                                corner: corner, partUVT: uvt)
    }
}

extension FlexStackInfo {
    /// The column at (iu, iv), or −1 (Stack::column_at).
    public func column(_ iu: Int, _ iv: Int) -> Int {
        guard iu >= 0, iv >= 0, iu < nu, iv < nv else { return -1 }
        return cell[iv * nu + iu]
    }
}

@MainActor
public final class FlexibleStageModel: ObservableObject {

    /// ★ ROUND 3 (item 5): Face | Stamps | More (Filament / Squish / Auto / Physics folded in).
    /// ★ ROUND 4 (D1, his answer 3): Face | More — a face's ONE stamp is its Shape (Stamp), on
    /// the Face tab; the Stamps tab and its check stamps are gone.
    public enum Tab: String, CaseIterable, Identifiable {
        case face = "Face", more = "More"
        public var id: String { rawValue }
    }
    public enum SceneState: Equatable {
        case idle, opening, ready, failed(String)
    }

    // inputs
    public let project: ProjectModel
    public let materialsPath: String?
    public let library: FlexibleStampLibrary?
    private let persist: () -> Void
    private let worker = FlexibleWorker()
    /// The bridge worker, for tests that read core through the same open scene.
    var workerForTests: FlexibleWorker { worker }
    /// ★ BATCH G: the worker the squish sims fetch the scene from (one hop; they run off it).
    var squishWorker: FlexibleWorker { worker }

    // what the screens show
    @Published public private(set) var catalogue: [FlexMaterialInfo] = []
    @Published public private(set) var catalogueError: String?
    @Published public private(set) var bands: FlexErrorBandsInfo?
    @Published public private(set) var sceneState: SceneState = .idle
    @Published public private(set) var sceneInfo: FlexibleScene.Info?
    @Published public var tab: Tab = .face { didSet { if oldValue != tab { tabChanged() } } }
    @Published public var selectedRegion: Int? { didSet { if oldValue != selectedRegion { selectionChanged() } } }
    /// ★ ROUND 5 (S8): the folder tab open on the Settings modal's left rail (FlexibleSettingsRail).
    @Published public var rail: FlexibleRailTab = .group(FlexibleSqueezeGroups.first) { didSet { if oldValue != rail { railChanged() } } }
    /// ★ ROUND 5 (S9): the page's Exit left with nothing changed — the main page does nothing.
    var exitUnchanged = false
    /// ★ ROUND 5 (S9): a Save & Exit with the main page's Lattice view OFF only stored — the bake
    /// waits for the view (FlexibleMainStage).
    @Published public internal(set) var latticeBuildDeferred = false
    @Published public var showBuildable = false
    @Published public private(set) var stacks: [FlexFaceKey: FlexStackInfo] = [:]
    @Published public private(set) var geometry: [FlexFaceKey: FlexFaceGeometry] = [:]
    @Published public private(set) var liveS: [FlexFaceKey: [Double]] = [:]
    @Published public private(set) var designs: [FlexFaceKey: FlexFaceDesignInfo] = [:]
    @Published public private(set) var conflicts: [FlexConflictInfo] = []
    /// ★ ROUND 4 (D2): the TWO-SEGMENT designs of the faces a pinch presses (FlexiblePinch) —
    /// run with the designs; a face that is not pinched has none (core's own design stands).
    @Published public private(set) var segments: [FlexFaceKey: FlexiblePinch.Segments] = [:]
    /// ★ D2 REVIEW: a pinched face whose two-segment design threw (its words) — it keeps core's
    /// one profile and its card says so; the other faces keep their halves.
    @Published public private(set) var segmentErrors: [FlexFaceKey: String] = [:]
    /// ★ D2 REVIEW: the groups that will squish less than designed once the lattice carries every
    /// group (the firmer wins) — known with the designs, BEFORE Exit (FlexibleGroupEstimate).
    @Published public private(set) var groupMisses: [FlexibleGroupEstimate.Miss] = []
    @Published public private(set) var recommendation: FlexRecommendationInfo?
    @Published public private(set) var recommendationError: String?
    @Published public private(set) var checks: [UUID: FlexStampCheckInfo] = [:]
    @Published public private(set) var stampGrids: [UUID: FlexStamp] = [:]
    /// Check mode shows the stamp's dent instead of the design's (M14). ★ SINCE ROUND 4 (D1) NO
    /// UI SETS IT: the check stamps are gone from the page (his answer 3) and the migration
    /// empties the list — the plumbing (this, `checks`, the check branch of FlexibleShownValues
    /// and of the job) is KEPT for D2's load cases / G's case picker, which show a named press.
    @Published public var checkStampShown: UUID?
    /// The curve point showing its × (round 3, item 8); a tap anywhere on the part clears it.
    @Published public var curvePoint: FlexCurvePoint?
    /// ★ ROUND 3 (item 1.1): the page's exaggeration k, FROZEN while the depth chip is dragged
    /// — the dent, the prism and the chip hold one scale while the finger moves.
    @Published public var frozenExaggeration: Double?
    @Published public private(set) var lastError: String?
    /// The generated lattice (Generate button) and its build state.
    @Published public private(set) var lattice: FlexibleGeneratedLattice?
    @Published public private(set) var latticeBuilding = false
    @Published public private(set) var latticeError: String?
    /// ★ BATCH G: each squeeze group's squish sim for the CURRENT lattice (by sim id): pending,
    /// its calibrated FE field, or core's words. One publish per landed sim (FlexibleStageModel+Squish).
    @Published public internal(set) var squish: [String: FlexibleSquishState] = [:]
    /// The lattice generation `squish` belongs to.
    public internal(set) var squishGeneration: Int?
    /// What the sims need, built in the lattice's build task (released once the solver has it).
    var feRequest: FlexibleFERequest?
    /// The generation whose sims were handed to the solver.
    var squishScheduled: Int?
    /// One solve at a time, off the main thread (FlexibleSquishSolver).
    let squishSolver = FlexibleSquishSolver()
    /// Test only: keep the last FE request (the solver releases it after its last sim).
    var keepFERequest = false
    private(set) var lastFERequest: FlexibleFERequest?
    func keepLastFERequest(_ r: FlexibleFERequest?) { lastFERequest = r }
    /// Test control only: store a sim's result whatever its generation (the red control).
    var controlIgnoreSquishGeneration = false
    /// ★ ROUND 4 (D2): the density field the last lattice was built from (groups combined
    /// firmer-wins, pinches as two segments). ★ D2 REVIEW: kept ONLY when a test asks
    /// (`keepCombinedField`) — at 128³ it is ~24 MB (Float ρ + Int owner) nothing else reads.
    private(set) var lastCombinedField: FlexDensityField?
    /// Test control only: keep the combined field after a build.
    var keepCombinedField = false
    /// ★ ROUND 3 BATCH B (item 9): core's words per face, kept PER KEY — a face core could
    /// not stack (no blind retry: the next scene open clears it) or could not design (one
    /// face's throw no longer leaves every later face "still being designed").
    @Published public private(set) var stackErrors: [FlexFaceKey: String] = [:]
    @Published public private(set) var designErrors: [FlexFaceKey: String] = [:]
    /// ★ ROUND 4 (D2): what each face was designed FROM (its weight, map and stamp) — a refusal or
    /// a throw core gave for the face as it WAS is not said about the face as it IS while the
    /// run for the new one is in flight (typing a weight into the fix pop-up popped "weight must
    /// be > 0" until the new design landed).
    private(set) var designedInputs: [FlexFaceKey: String] = [:]
    nonisolated static func designInputKey(_ f: FlexibleFaceSettings) -> String {
        "\(f.weightKg)|\(f.map.hashValue)|\(f.activeStamp?.hashValue ?? 0)"
    }
    /// Bumped by every action of HIS that can create a problem (press, rest, a weight, the
    /// trash, a filament): the fix pop-up opens only on a NEW blocking issue an action caused.
    @Published public internal(set) var actionSerial = 0
    /// A one-line note for an automatic fix ("Nozzle temperature set to Auto — …"). ★ BATCH B
    /// REVIEW: it clears ITSELF after `toastSeconds` — an auto-fix can land while the main page
    /// shows (no Settings page up to clear it), and the page's own clear only heard a change,
    /// so a toast set before it opened stayed under the line for the whole visit.
    @Published public var toast: String? { didSet { scheduleToastClear() } }
    /// ★ BATCH B REVIEW: a design run (designs AND core's stack conflicts) is scheduled and has
    /// not landed — the pop-up waits for it before it pops a blocker that stands on opening
    /// (a calibrate-first map lands before the conflicts do).
    @Published public private(set) var designsInFlight = false
    var toastSeconds: Double = 3.5
    private var toastTask: Task<Void, Never>?
    private func scheduleToastClear() {
        toastTask?.cancel()
        guard let t = toast else { return }
        let ns = UInt64(max(0, toastSeconds) * 1e9)
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled, self.toast == t else { return }
            self.toast = nil
        }
    }
    /// The issue the page opens its pop-up on when it appears (the main page's pill).
    @Published public var pendingFix: FlexibleIssue?

    private var pendingStacks: Set<FlexFaceKey> = []
    /// Every bridge call in flight (scene, stacks, drawn maps, the lattice) — awaited by
    /// `waitForIdle` so nothing is still inside core when its owner goes away.
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    func track(_ t: Task<Void, Never>) {
        let id = UUID()
        inFlight[id] = t
        Task { @MainActor [weak self] in
            _ = await t.value
            self?.inFlight[id] = nil
        }
    }

    /// Wait until no bridge call is in flight and no design / Auto run is pending (tests; a
    /// page that must not tear down a scene mid-call).
    func waitForIdle() async {
        for _ in 0..<2000 {
            let tasks = Array(inFlight.values) + [designTask, autoTask].compactMap { $0 }
            for t in tasks { _ = await t.value }
            if inFlight.isEmpty { await squishSolver.waitForIdle(); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private var designGeneration = 0
    private var designTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?

    public init(project: ProjectModel, materialsPath: String?, stampsPath: String?,
                persist: @escaping () -> Void) {
        self.project = project
        self.materialsPath = materialsPath
        self.library = stampsPath.flatMap { try? FlexibleStampLibrary.load(path: $0) }
        self.persist = persist
        loadCatalogue()
    }

    // MARK: settings (in the project)

    /// ★ READ THROUGH THE ROUND-3 MIGRATION (FlexibleSettingsMigration): an old project
    /// shows and runs the new way (1 bead, both axes, no frame rotation, curves read "closer
    /// to the face = squishier") and its file changes only with the next edit.
    public var settings: FlexibleStageSettings {
        get { FlexibleSettingsMigration.migrated(project.lattice.flexible ?? FlexibleStageSettings()) }
        set { project.lattice.flexible = newValue }
    }

    public func edit(_ change: (inout FlexibleStageSettings) -> Void, recompute: Bool = true) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        syncRail()   // ★ ROUND 5 (S8): the folder tab follows the selected face's group
        if recompute { recomputeAll() }
        scheduleSave()
    }

    /// Every edit reaches the disk shortly after it is made, not only on Exit: a kill
    /// between edits must not lose the drawing (the lattice stage's own 2026-09-02 rule).
    private var saveTask: Task<Void, Never>?
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            self.save()
        }
    }

    public func save() {
        project.sealUndoStep()
        persist()
    }

    public var material: FlexMaterialInfo? {
        guard let id = settings.materialID else { return nil }
        return catalogue.first { $0.id == id }
    }

    // MARK: catalogue (S1)

    private func loadCatalogue() {
        guard let path = materialsPath else {
            catalogueError = "The Flexible filament list is not in this build."
            return
        }
        do {
            // the filaments core can predict for first, then the calibrate-first ones
            catalogue = try FlexibleCore.materials(path: path).sorted {
                ($0.noPrediction == nil) != ($1.noPrediction == nil) ? $0.noPrediction == nil
                    : $0.displayName < $1.displayName
            }
            bands = try FlexibleCore.errorBands(path: path)
        } catch {
            catalogueError = "\(error)"
        }
    }

    public func temperatureNote(_ tempC: Double) -> String {
        guard let path = materialsPath, let id = settings.materialID else { return "" }
        return (try? FlexibleCore.temperatureNote(path: path, materialID: id, tempC: tempC)) ?? ""
    }

    public func pickMaterial(_ id: String) {
        actionSerial += 1
        edit { s in
            s.materialID = id
            // a temperature from another filament is not one this one was tested at (R10)
            if let t = s.nozzleTempC, !(catalogue.first { $0.id == id }?.testedTempsC.contains(t) ?? false) {
                s.nozzleTempC = nil
            }
        }
    }

    // MARK: the scene

    struct SceneJob { let json: String; let dir: String }

    func sceneJob() throws -> SceneJob? {
        guard let file = project.importedFile else { return nil }
        let faceCount = max(file.faceCount, (project.viewerMesh?.faceIDs.max().map { Int($0) + 1 }) ?? 0)
        var inputs = FlexibleJob.Inputs(
            modelPath: file.path, resolution: project.quality.resolution,
            beadWidthMM: project.printParams.strutLineWidthMM, faceCount: faceCount,
            settings: settings, regions: project.latticeJobRegions().regions.map(\.wireDictionary))
        inputs.sectorRegions = regions.wire
        (inputs.buildDir, inputs.plateDir) = buildDirections
        let json = try FlexibleJob.sceneJobJSON(inputs, fallbackMaterial: catalogue.first?.id ?? "flexible")
        return SceneJob(json: json, dir: (file.path as NSString).deletingLastPathComponent)
    }

    /// The scene's key: everything that changes the part, grid, mask or regions —
    /// NOT the faces, curves or filament (those re-run designs, never the scene).
    /// ★ BATCH B REVIEW: the bead width too — the scene job sends it (min_extrudable_width_mm)
    /// and the shared model now keeps its scene for the whole session.
    private func sceneKey() -> String {
        guard let file = project.importedFile else { return "" }
        let regions = project.latticeJobRegions().regions.map(\.wireDictionary)
        let r = (try? JSONSerialization.data(withJSONObject: regions, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let (b, p) = buildDirections
        return "\(file.path)|\(project.quality.resolution)|\(r)|\(self.regions.key)|\(b)|\(p.map { "\($0)" } ?? "-")"
            + "|\(project.printParams.strutLineWidthMM)"
    }

    /// The scene key the project describes NOW (the main page compares it with the opened one).
    var currentSceneKey: String { sceneKey() }

    /// ★ ROUND 3 (item 1.2): the main run's build directions — `loads.build_dir` = −gravity
    /// (+Z when gravity is unset) and the plate normal only when he declared one.
    var buildDirections: (SIMD3<Double>, SIMD3<Double>?) {
        let lc = project.loadCase()
        return (lc.buildDirection, lc.plateDirection == SIMD3<Double>(0, 0, 0) ? nil : lc.plateDirection)
    }

    // MARK: regions (split sectors, FlexibleRegions.swift)

    /// The declared regions: every face, plus the Surface stage's split sectors.
    public var regions: FlexibleRegions { FlexibleRegions(model: project.faceRegions, mesh: project.viewerMesh) }
    public func name(_ region: Int) -> String { regions.name(region, mesh: project.viewerMesh) }
    /// Core's sentence with sector ids replaced by the app's names.
    public func text(_ s: String) -> String { regions.renamed(s, mesh: project.viewerMesh) }

    /// The region "no pressed face" offers to press (FlexibleReadiness.suggestedFace), cached
    /// per mesh, build direction and split — a split face offers the sector at its centroid.
    private var suggestedCache: (key: String, region: Int?)?
    func suggestedPressRegion() -> Int? {
        guard let mesh = project.viewerMesh else { return nil }
        let up = buildDirections.0
        let key = "\(mesh.triangleCount)|\(mesh.faceIDs.count)|\(up)|\(regions.key)"
        if let c = suggestedCache, c.key == key { return c.region }
        let region = FlexibleReadiness.suggestedFace(mesh: mesh, up: up).map {
            regions.region(at: $0.centroid, face: $0.face, mesh: mesh)
        }
        suggestedCache = (key, region)
        return region
    }

    /// The key the ready scene was opened with (the lattice is keyed by it too).
    private(set) var openedKey: String?
    /// The key the last open was ATTEMPTED with (a failed open is retried only on a new one).
    private(set) var openAttemptKey: String?

    public func openScene() {
        guard sceneState != .opening else { return }
        let key = sceneKey()
        // ★ THE SHARED MODEL (batch B): Settings re-opens over the main page's model — the same
        // part, the same scene: keep its stacks (and the overlay the main page draws) and only
        // re-read the main page's groups
        if sceneState == .ready, openedKey == key {
            adoptMainPageLoads(recompute: false)
            recomputeAll()
            return
        }
        openAttemptKey = key
        guard let job = try? sceneJob() else {
            sceneState = .failed("This project has no imported part to open.")
            return
        }
        sceneState = .opening
        let worker = self.worker
        track(Task.detached(priority: .userInitiated) {
            do {
                let info = try await worker.open(jobJSON: job.json, jobDir: job.dir, key: key)
                await MainActor.run {
                    self.sceneInfo = info
                    self.stacks = [:]
                    self.geometry = [:]
                    self.pendingStacks = []
                    self.stackErrors = [:]
                    self.designErrors = [:]
                    self.openedKey = key
                    self.sceneState = .ready
                    // ★ ROUND 3 (item 1.2): the main page's loads arrive as pressed / resting faces
                    self.adoptMainPageLoads(recompute: false)
                    self.recomputeAll()
                }
            } catch {
                await MainActor.run { self.sceneState = .failed("\(error)") }
            }
        })
    }

    // MARK: faces (S2)

    public var loadedKeys: [FlexFaceKey] {
        settings.loadedFaces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
    }

    /// Tap on the model: ★ ROUND 3 — it only SELECTS (img 8: tapping around pressed seven
    /// faces at 10 kg each, which made the conflicts and the '7 faces' refusal). Pressing is
    /// explicit: [Press it] / [It rests here] in the panel, or the main page's groups.
    public func tapFace(_ face: Int, point: SIMD3<Double>? = nil) {
        // a split face resolves to the sector holding the point (the Surface stage's rule)
        let region = regions.region(at: point, face: face, mesh: project.viewerMesh)
        NSLog("DIAG flexible tap face %d → region %d (known %d)", face, region, settings.face(region) != nil ? 1 : 0)
        curvePoint = nil
        // ★ S VERIFICATION: on the [+ New] tab ("Tap the face that starts it") a tap on a face that
        // can start a group STARTS it (with its hand) — it had only selected the face and left the tab
        if rail == .newGroup, newGroupCandidates.contains(region) {
            startGroup(with: region)
            ensureStack(region)
            return
        }
        selectedRegion = region
        if tab == .more { tab = .face }
        ensureStack(region)
    }

    /// ★ ROUND 4 (D1): a row of the Settings panel's face LIST was tapped — select that REGION
    /// (a split sector as itself: never resolved through the part's face, which would pick the
    /// whole face), so the rows below edit it and the part shows it selected.
    public func select(_ region: Int) {
        curvePoint = nil
        selectedRegion = region
        if tab == .more { tab = .face }
        ensureStack(region)
    }

    // MARK: the main page's loads (round 3, item 1.2 — FlexibleMainPageLoads)

    /// The main page's groups read as Flexible faces (cached per scene open and write-back).
    @Published public private(set) var mainPageLoads = FlexibleMainPageLoads()
    /// Faces whose OWN weight a group's replaced this session (region → the old kg): the
    /// panel says so in one line ("Was 7 kg · now Top's weight").
    @Published public internal(set) var relinkedWeights: [Int: Double] = [:]

    /// Read the main page's groups, then MATERIALISE them (`FlexibleMainPageLoads.adopt`): a
    /// face a Load group presses is pressed with its share and LINKED (weightFrom = the
    /// group) — one source of truth, also for a face pressed before round 3; an Anchor
    /// group's faces rest; [Rests] chosen on this page survives; a face whose group no longer
    /// holds it keeps its weight as his own. Sealed as one undo step. Called when the scene
    /// opens and after every write-back.
    public func adoptMainPageLoads(recompute: Bool = true) {
        guard let loads = deriveMainPageLoads() else { return }
        mainPageLoads = loads
        let before = settings
        var relinked: [Int: Double] = [:]
        edit({ s in relinked = Self.adopt(loads, into: &s) }, recompute: recompute)
        relinkedWeights.merge(relinked) { old, _ in old }
        if settings != before { project.sealUndoStep() }
        if selectedRegion == nil { selectedRegion = settings.loadedFaces.first?.faceRegionID }
    }

    func deriveMainPageLoads() -> FlexibleMainPageLoads? {
        guard let mesh = project.viewerMesh else { return nil }
        return FlexibleMainPageLoads.derive(
            groups: project.selection.groups, force: project.force, faceRegions: project.faceRegions,
            mesh: mesh, regions: regions, load: { [stacks] r in stacks[FlexFaceKey(region: r, rotation: 0)]?.load })
    }

    /// ★ D2 REVIEW: the main page's loads re-read into the cache ONLY — no edit, no undo step
    /// (the Settings page's undo / redo restored the project; the cache must follow it).
    public func refreshMainPageLoads() {
        if let loads = deriveMainPageLoads(), loads != mainPageLoads { mainPageLoads = loads }
    }

    /// ★ D2 REVIEW: the adopt, then the squeeze groups kept whole — a face the main page rests
    /// holds no group, a face it presses again joins a group that EXISTS (a stale id made a
    /// "Group 2" nobody made), and a main-page hand sits in one group.
    nonisolated static func adopt(_ loads: FlexibleMainPageLoads, into s: inout FlexibleStageSettings) -> [Int: Double] {
        // ★ ROUND 5 (S6): a face he DELETED stays deleted — the re-sync skips it (the main page's
        // group still holds it; that is his to change there)
        let removed = Set(s.removedRegions ?? [])
        let loads = removed.isEmpty ? loads : FlexibleMainPageLoads(entries: loads.entries.filter { !removed.contains($0.key) })
        let relinked = loads.adopt(into: &s)
        FlexibleSqueezeGroups.uniteHands(&s, loads: loads)
        return relinked
    }

    /// [Press it]: the main page's weight when the face is in a Load group; else `kg` (the
    /// number pad's answer); else — ★ ROUND 4 (D2) — group 1's ONE squeeze force (the face joins
    /// group 1, no pad). false ⇒ a weight must be asked first ("How much weight presses here?").
    @discardableResult
    public func press(_ region: Int, kg: Double? = nil) -> Bool {
        let inherited = mainPageLoads.entry(region).flatMap { $0.role == .pressed ? $0 : nil }
        let joinKg = inherited == nil && kg == nil ? firstGroupForce : nil
        guard inherited != nil || (kg ?? joinKg ?? 0) > 0 else { return false }
        actionSerial += 1
        edit { s in
            // ★ ROUND 5 (S6): pressing a deleted face brings it back — as a NEW face
            if s.isRemoved(region) { s.removedRegions?.removeAll { $0 == region }; if s.removedRegions?.isEmpty == true { s.removedRegions = nil } }
            var f = s.face(region) ?? FlexibleFaceSettings(faceRegionID: region)
            f.role = "loaded"
            f.squeezeGroup = nil   // a newly pressed face joins group 1
            if let e = inherited, kg == nil { f.weightKg = e.weightKg; f.weightFrom = e.groupID }
            else if let w = kg ?? joinKg { f.weightKg = w; f.weightFrom = nil }
            s.setFace(f)
            FlexibleSqueezeGroups.normalise(&s)
        }
        relinkedWeights[region] = nil
        selectedRegion = region
        ensureStack(region)
        return true
    }

    /// [It rests here] / [Rests]: HIS choice on this page, so it is unlinked (weightFrom nil)
    /// and no re-sync presses it again — not a write-back, not a re-open (`adopt(into:)`).
    public func rest(_ region: Int) {
        actionSerial += 1
        edit { s in
            if s.isRemoved(region) { s.removedRegions?.removeAll { $0 == region }; if s.removedRegions?.isEmpty == true { s.removedRegions = nil } }
            var f = s.face(region) ?? FlexibleFaceSettings(faceRegionID: region, role: "resting")
            f.role = "resting"
            f.weightFrom = nil
            s.setFace(f)
            FlexibleSqueezeGroups.normalise(&s)   // ★ D2: a resting face is in no squeeze group
        }
        relinkedWeights[region] = nil
        selectedRegion = region
    }

    /// A weight typed on the Flexible page. ★ ONE SOURCE OF TRUTH (maintainer): for a face
    /// whose weight comes from a main-page group, it WRITES BACK to the group — the group
    /// takes the weight that gives this face `kg` — and every face of the group re-syncs, so
    /// the area split stays consistent. A face in no group keeps it as its own.
    /// ★ ROUND 4 (D2, his answer 1: ONE force per squeeze group): a pressed face's weight IS its
    /// squeeze group's force — the hand that gives this face `kg` (its main-page group's weight,
    /// or `kg`) becomes the force of every hand in the group (`setGroupForce`).
    public func setWeight(_ region: Int, kg: Double) {
        guard kg > 0 else { return }
        if let g = squeezeGroup(of: region) {
            let f = settings.face(region)
            let hand = f?.weightFrom != nil ? mainPageLoads.groupKg(forRegion: region, kg: kg) : nil
            setGroupForce(g.id, kg: hand ?? kg)
            return
        }
        actionSerial += 1
        if let f = settings.face(region), let g = f.weightFrom,
           let total = mainPageLoads.groupKg(forRegion: region, kg: kg) {
            project.force.setWeight(g, kg: total)
            relinkedWeights[region] = nil
            adoptMainPageLoads()
            return
        }
        relinkedWeights[region] = nil
        edit { s in guard var f = s.face(region) else { return }; f.weightKg = kg; f.weightFrom = nil; s.setFace(f) }
    }

    /// The trash. ★ ROUND 5 (S6, his img 3: "For some reason, top A/B are not deletable. All faces
    /// should be deletable."): EVERY face — a split sector, a face a main-page Load or Anchor group
    /// holds — leaves the Flexible setup. The main page's group is NOT touched (it still presses the
    /// face in the main run — his to change there); a face a group holds is remembered as deleted
    /// (`removedRegions`) so the re-sync never brings it back.
    /// ★ ROUND 5 (S7: "When a face has been deleted, it comes back with the previous values. It
    /// should come back with reset values."): EVERYTHING the face held goes with it — its settings
    /// (curves, stamp, shape, squeeze group, deepest squish, weight and its link), its check
    /// stamps, and every per-face copy of core's answers the page keeps (the drawn map, the design,
    /// its words, the pinch halves, the relinked weight, a curve point's ×). Added again, it is a
    /// NEW face: defaults, and the main page's weight if a group presses it.
    @discardableResult
    public func removeFace(_ region: Int) -> Bool {
        actionSerial += 1
        let held = !mainPageLoads.canRemove(region)
        edit { s in
            s.removeFace(region)
            if held, !s.isRemoved(region) { s.removedRegions = (s.removedRegions ?? []) + [region] }
            FlexibleSqueezeGroups.normalise(&s)
        }
        purgeFaceCaches(region)
        if selectedRegion == region { selectedRegion = settings.loadedFaces.first?.faceRegionID ?? settings.faces.first?.faceRegionID }
        return true
    }

    /// ★ S7: every per-face copy the model keeps for `region` (any rotation) — never shown again for
    /// a face added back later.
    func purgeFaceCaches(_ region: Int) {
        func drop<V>(_ d: inout [FlexFaceKey: V]) {
            let ks = d.keys.filter { $0.region == region }
            for k in ks { d[k] = nil }
        }
        drop(&liveS); drop(&designs); drop(&designErrors); drop(&segments); drop(&segmentErrors)
        drop(&designedInputs)
        relinkedWeights[region] = nil
        if curvePoint?.region == region { curvePoint = nil }
        checks = checks.filter { id, _ in settings.checkStamps.contains { $0.stamp.id == id } }
    }

    public func key(_ region: Int) -> FlexFaceKey? {
        settings.face(region).map { FlexFaceKey(region: region, rotation: $0.rotationDeg) }
    }

    public func stack(_ region: Int) -> FlexStackInfo? { key(region).flatMap { stacks[$0] } }
    public func design(_ region: Int) -> FlexFaceDesignInfo? { key(region).flatMap { designs[$0] } }

    private func ensureStack(_ region: Int) {
        guard sceneState == .ready, let k = key(region), stacks[k] == nil, !pendingStacks.contains(k),
              stackErrors[k] == nil else { return }   // ★ no blind retry of a face core refused to stack
        pendingStacks.insert(k)
        let partFlat = project.viewerMesh?.flat.positions ?? []
        let worker = self.worker
        track(Task.detached(priority: .userInitiated) {
            do {
                let st = try await worker.withScene { try $0.stack(face: k.region, rotation: k.rotation) }
                let g = try await worker.withScene { try FlexFaceGeometry.compute(scene: $0, key: k, stack: st, partFlat: partFlat) }
                await MainActor.run {
                    self.stacks[k] = st; self.geometry[k] = g
                    self.seedStampIfNeeded(k.region)   // ★ Stamp chosen before the stack landed (D1 verification)
                    self.recomputeAll()
                }
            } catch {
                await MainActor.run {
                    self.lastError = "\(error)"
                    self.stackErrors[k] = "\(error)"
                    self.pendingStacks.remove(k)
                }
            }
        })
    }

    // MARK: the pipeline

    /// The temperature and family the designs are drawn for: the user's pick, else
    /// Auto's, else nothing (no guessed temperature, R10).
    public var designTempC: Double? {
        settings.nozzleTempC ?? recommendation.flatMap { $0.chosen ? $0.tempC : nil }
            ?? material?.testedTempsC.first
    }
    public var designTopology: String {
        settings.topology != "auto" ? settings.topology
            : (recommendation?.chosen == true ? recommendation!.topology : "gyroid")
    }
    public var build: FlexBuildParams {
        FlexBuildParams(topology: designTopology, beadsPerWall: settings.beadsPerWall,
                        beadWidthMM: project.printParams.strutLineWidthMM)
    }

    /// A curve point moved: the squish map now, the design when the drag rests.
    public func curveChanged(region: Int) {
        guard let k = key(region), let f = settings.face(region), stacks[k] != nil else { return }
        let map = f.map
        let worker = self.worker
        track(Task.detached(priority: .userInitiated) {
            if let s = try? await worker.withScene({ try $0.squishFraction(face: k.region, rotation: k.rotation, map: map) }) {
                await MainActor.run { self.liveS[k] = s }
            }
        })
        scheduleDesigns(delayNS: 120_000_000)
    }

    public func recomputeAll() {
        guard sceneState == .ready else { return }
        for k in loadedKeys where stacks[k] == nil { ensureStack(k.region) }
        refreshLiveS(loadedKeys)
        rasteriseStamps()
        scheduleDesigns(delayNS: 0)
        scheduleAuto()
    }

    /// ★ ROUND 3, ITEM 1: every pressed face's DRAWN map, from core's squish_fraction, as
    /// soon as its stack exists and after every recompute (undo, a new weight…). It needs no
    /// filament data, so a calibrate-first filament's map bends too (FlexibleShownValues).
    private func refreshLiveS(_ keys: [FlexFaceKey]) {
        let jobs = keys.compactMap { k -> (FlexFaceKey, FlexMap)? in
            guard stacks[k] != nil, let f = settings.face(k.region) else { return nil }
            return (k, f.map)
        }
        guard !jobs.isEmpty else { return }
        let worker = self.worker
        track(Task.detached(priority: .userInitiated) {
            var out: [FlexFaceKey: [Double]] = [:]
            for (k, map) in jobs {
                if let s = try? await worker.withScene({ try $0.squishFraction(face: k.region, rotation: k.rotation, map: map) }) {
                    out[k] = s
                }
            }
            let o = out
            await MainActor.run { for (k, v) in o { self.liveS[k] = v } }
        })
    }

    /// ★ ONE FACE'S THROW NO LONGER STOPS THE NEXT (round 3 batch B, item 9). The designs ran
    /// in ONE do/catch: a face core threw for (weight 0 — "weight must be > 0") left every
    /// LATER face undesigned, "still being designed" for ever. Each face now has its own
    /// catch, and its words are kept against its key.
    nonisolated static func designEach<K: Hashable, F, D>(_ faces: [F], key: (F) -> K,
                                                           cancelled: () -> Bool = { Task.isCancelled },
                                                           _ body: (F) async throws -> D) async
        -> (designs: [K: D], errors: [K: String], cancelled: Bool) {
        var out: [K: D] = [:], errs: [K: String] = [:]
        for f in faces {
            if cancelled() { return (out, errs, true) }
            do { out[key(f)] = try await body(f) }
            catch { errs[key(f)] = "\(error)" }
        }
        return (out, errs, false)
    }

    private func scheduleDesigns(delayNS: UInt64) {
        pipelineSettings = settings
        designGeneration += 1
        let gen = designGeneration
        designTask?.cancel()
        guard let path = materialsPath, let mat = settings.materialID else {
            designs = [:]
            designErrors = [:]
            segments = [:]
            segmentErrors = [:]
            groupMisses = []
            if designsInFlight { designsInFlight = false }
            return
        }
        if !designsInFlight { designsInFlight = true }
        let faces = settings.loadedFaces.filter { stacks[FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg)] != nil }
        let temp = designTempC, build = self.build, grids = stampGrids
        let checkStamps = settings.checkStamps
        let worker = self.worker
        // ★ ROUND 4 (D2): what the pinches' two-segment designs read (FlexiblePinch)
        let snapshot = settings, stackSnap = stacks
        let inputKeys = Dictionary(faces.map { (FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg), Self.designInputKey($0)) },
                                   uniquingKeysWith: { a, _ in a })
        let regions = self.regions
        let cuts = Dictionary(faces.map { ($0.faceRegionID, regions.cuts(of: $0.faceRegionID)) }, uniquingKeysWith: { a, _ in a })
        designTask = Task.detached(priority: .userInitiated) {
            if delayNS > 0 { try? await Task.sleep(nanoseconds: delayNS) }
            if Task.isCancelled { return }
            var out: [FlexFaceKey: FlexFaceDesignInfo] = [:]
            var faceErrors: [FlexFaceKey: String] = [:]
            var s: [FlexFaceKey: [Double]] = [:]
            var checks: [UUID: FlexStampCheckInfo] = [:]
            var conflicts: [FlexConflictInfo] = []
            var segs: [FlexFaceKey: FlexiblePinch.Segments] = [:]
            var segErrs: [FlexFaceKey: String] = [:]
            var misses: [FlexibleGroupEstimate.Miss] = []
            var err: String?
            let keys = faces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
            do {
                conflicts = try await worker.withScene {
                    try $0.conflicts(faces: keys.map(\.region), rotations: keys.map(\.rotation))
                }
            } catch {
                err = "\(error)"
            }
            if let temp {
                let r = await Self.designEach(faces, key: { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }) { f in
                    let k = FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)
                    let stamp = f.activeStamp.flatMap { grids[$0.id] }
                    return try await worker.withScene {
                        try $0.design(materialsPath: path, materialID: mat, tempC: temp, face: k.region,
                                      rotation: k.rotation, map: f.map, weightN: f.weightN,
                                      stamp: stamp, build: build)
                    }
                }
                if r.cancelled { return }
                out = r.designs
                faceErrors = r.errors
                for (k, d) in out { s[k] = d.columns.map(\.s) }
                if err == nil, let first = faceErrors.values.first { err = first }
                for c in checkStamps {
                    guard let f = faces.first(where: { $0.faceRegionID == c.faceRegionID }),
                          let g = grids[c.stamp.id], out[FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)]?.refusal == nil
                    else { continue }
                    do {
                        checks[c.stamp.id] = try await worker.withScene {
                            try $0.checkStamp(materialsPath: path, materialID: mat, tempC: temp,
                                              face: f.faceRegionID, rotation: f.rotationDeg, stamp: g, build: build)
                        }
                    } catch {
                        if err == nil { err = "\(error)" }
                    }
                }
                // ★ ROUND 4 (D2): a PINCH (two faces of one group on one stack) — each face's
                // pinched columns designed over their half, through core's own table
                // ★ D2 REVIEW: each face its own catch (one throw no longer drops every pinch)
                do {
                    let law = try FlexiblePinch.Law.core(materialsPath: path, materialID: mat, tempC: temp, build: build)
                    (segs, segErrs) = Self.pinchSegments(settings: snapshot, conflicts: conflicts, designs: out,
                                                         stacks: stackSnap, cuts: cuts, law: law)
                    // ★ D2 REVIEW: separate groups — which will squish less than designed once the
                    // lattice carries them all (the firmer wins), said BEFORE Exit
                    misses = try Self.groupEstimate(settings: snapshot, designs: out, segments: segs,
                                                    stacks: stackSnap, cuts: cuts, law: law)
                } catch {
                    if err == nil { err = "\(error)" }
                }
            }
            if Task.isCancelled { return }
            let (o, fe, ss, ch, co, er, sg) = (out, faceErrors, s, checks, conflicts, err, segs)
            let (se, mi) = (segErrs, misses)
            await MainActor.run {
                guard gen == self.designGeneration else { return }
                self.designsInFlight = false
                self.designs = o
                self.designErrors = fe
                for (k, v) in ss { self.liveS[k] = v }
                self.checks = ch
                self.conflicts = co
                self.segments = sg
                self.segmentErrors = se
                if self.groupMisses != mi { self.groupMisses = mi }
                self.designedInputs = inputKeys
                self.lastError = er
                self.applyAutoFixes()
            }
        }
    }

    /// ★ SILENT AUTO-FIXES (decisions): a refusal with an obvious fix is fixed, with a toast —
    /// temperature_not_tested → Auto; topology_no_data / honeycomb_side_stack → Gyroid.
    func applyAutoFixes() {
        let fixes = readiness.autoFixes
        guard !fixes.isEmpty else { return }
        edit { s in
            for f in fixes {
                switch f.what {
                case .temperatureAuto: s.nozzleTempC = nil
                case .topologyGyroid: s.topology = "gyroid"
                }
            }
        }
        toast = fixes.map(\.toast).joined(separator: " · ")
    }

    // MARK: Auto (S3)

    public func scheduleAuto() {
        autoTask?.cancel()
        guard let path = materialsPath, let mat = material, !mat.testedTempsC.isEmpty else {
            recommendation = nil
            return
        }
        let faces = settings.loadedFaces.compactMap { f -> FlexFaceRequest? in
            let k = FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)
            guard stacks[k] != nil else { return nil }
            return FlexFaceRequest(face: f.faceRegionID, rotation: f.rotationDeg, map: f.map,
                                   weightN: f.weightN, stamp: f.activeStamp.flatMap { stampGrids[$0.id] })
        }
        guard !faces.isEmpty else { recommendation = nil; return }
        // Auto weighs every tested temperature and both families; the user's overrides
        // are applied on top (R5), never fed back as if Auto chose them.
        let temps = mat.testedTempsC
        let feel = settings.feel, beads = settings.beadsPerWall
        let width = project.printParams.strutLineWidthMM
        let worker = self.worker
        autoTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            do {
                let r = try await worker.withScene {
                    try $0.recommend(materialsPath: path, materialID: mat.id, temps: temps,
                                     topologies: ["gyroid", "honeycomb"], feel: feel,
                                     beadsPerWall: beads, beadWidthMM: width, faces: faces)
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    let before = self.designTopology, beforeT = self.designTempC
                    self.recommendation = r
                    self.recommendationError = nil
                    if before != self.designTopology || beforeT != self.designTempC {
                        self.scheduleDesigns(delayNS: 0)
                    }
                }
            } catch {
                await MainActor.run { self.recommendationError = "\(error)" }
            }
        }
    }

    /// Is `topology` at `temp` a candidate core has data for, for these faces?
    public func candidate(topology: String, tempC: Double) -> FlexCandidate? {
        recommendation?.candidates.first { $0.topology == topology && $0.tempC == tempC }
    }

    // MARK: stamps (S4)

    /// Rasterise every placed stamp onto its face at half the column pitch.
    private func rasteriseStamps() {
        var grids: [UUID: FlexStamp] = [:]
        func lay(_ p: FlexibleStampPlacement, region: Int) {
            guard let st = stack(region) else { return }
            let onFace: (Double, Double) -> Bool = { u, v in
                let iu = Int((u / st.pitchMM).rounded(.down)), iv = Int((v / st.pitchMM).rounded(.down))
                guard iu >= 0, iv >= 0, iu < st.nu, iv < st.nv else { return false }
                return st.cell[iv * st.nu + iu] >= 0
            }
            if let g = FlexibleStamps.grid(p, library: library, uExtentMM: st.uExtentMM,
                                           vExtentMM: st.vExtentMM, pitchMM: st.pitchMM, onFace: onFace) {
                grids[p.id] = g
            }
        }
        // ★ ROUND 4 (D1): only a Stamp-shaped face's ONE stamp, at the face's weight (the
        // migration empties the check stamps; a stamp stored under Curves is not laid)
        for f in settings.faces { if let p = f.activeStamp { lay(p, region: f.faceRegionID) } }
        for c in settings.checkStamps { lay(c.stamp, region: c.faceRegionID) }
        stampGrids = grids
    }

    /// Core's own check that a grid conserves its force (≤ 0.5 %).
    public func stampError(_ id: UUID) -> String {
        guard let g = stampGrids[id] else { return "" }
        return FlexibleCore.stampError(g)
    }

    // MARK: the lattice (FlexibleLatticeGeneration.swift) — built on Save & Exit (batch B)

    /// ★ ROUND 3 BATCH B: FlexibleReadiness decides (the old gate's order was the bug); nil
    /// when nothing blocks.
    public var latticeRefusal: String? { readiness.refusal }
    /// The generated lattice no longer matches the settings (a face or the filament changed)
    /// — ★ BATCH B REVIEW: or the SCENE it was built on (a new grid, a new lattice region, a
    /// new bead on the main page; the shared model keeps its lattice across the session).
    public var latticeIsStale: Bool {
        lattice.map { $0.settingsKey != settings.designInputs.hashValue || ($0.sceneKey != nil && $0.sceneKey != openedKey) } ?? false
    }

    /// What a build is keyed by: the settings and the scene. ★ ROUND 5: the settings WITHOUT the
    /// display-only choices (a group's colour, the weight unit) — neither re-builds the lattice.
    private var latticeBuildKey: String { "\(settings.designInputs.hashValue)|\(openedKey ?? "")" }
    /// The key the last build FAILED on.
    private var latticeFailedKey: String?
    /// ★ BATCH B REVIEW: a failed build is LATCHED against what it was built from — the main
    /// page tried again on every change it caused itself (the failure published, the page
    /// rebuilt, it failed …), for ever, behind "Building the lattice…". Core's words while the
    /// settings and the scene are the ones that failed; nil once either changes.
    public var latticeFailure: String? {
        guard let e = latticeError, latticeFailedKey == latticeBuildKey else { return nil }
        return e
    }

    /// His explicit Save & Exit asks for the build again (once per Exit — never a loop).
    public func retryFailedBuild() { latticeFailedKey = nil }

    /// The settings the design pipeline last ran for (every design run is scheduled here).
    private(set) var pipelineSettings: FlexibleStageSettings?
    /// ★ BATCH B REVIEW: the settings moved without the pipeline — an undo / redo on the MAIN
    /// page (its two-finger tap restores `lattice.flexible` behind the model's back).
    var settingsOutranPipeline: Bool { sceneState == .ready && pipelineSettings?.designInputs != settings.designInputs }

    /// Bumped per build — the token the preview uploads once per.
    private var latticeGeneration = 0

    /// The squish faces in the order the pass takes them: the LARGEST first, so its four
    /// slots (`FlexibleSquishField.maxFaces`) squish the four largest (plan item 9: more than
    /// four pressed faces no longer blocks; the walls use every face).
    nonisolated static func squishOrder<K>(_ faces: [(key: K, areaMM2: Double)]) -> [K] {
        faces.enumerated().sorted { a, b in
            a.element.areaMM2 != b.element.areaMM2 ? a.element.areaMM2 > b.element.areaMM2 : a.offset < b.offset
        }.map(\.element.key)
    }

    /// Build the lattice: core's density field from the designs, or — for a calibrate-first
    /// filament — the SHAPE-ONLY field (FlexibleGeometryOnlyLattice) from core's mask and the
    /// drawn map. Refused only by a blocking readiness issue.
    /// ★ ROUND 4 (D2): one field PER SQUEEZE GROUP — core's own for a group core can assemble, the
    /// app's (FlexibleGroupField.assemble: core's rule without its refusal) for a group with a
    /// PINCH, whose pinched faces bring their two-segment designs — and, with two or more groups,
    /// the FIRMER density per voxel; each face then squishes by what its column holds in that
    /// combined field (≈ as built), and a group that misses its design says so.
    public func generateLattice() {
        let ready = readiness
        // blocked, or still designing (a face without its design would be left out silently)
        guard ready.isReady, !ready.designing, !latticeBuilding, let part = project.viewerMesh else { return }
        let faces = settings.loadedFaces
        let shapeOnly = material?.noPrediction != nil
        let allKeys = faces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
        // ★ ONE ARRAY PER FACE for the walls AND the dent: core's buildable depths (a pinched
        // face: its halves') — or, shape only, the drawing itself (S × deepest) — kept on the
        // lattice so the map drawn beside it is the one it squishes by
        var squish: [FlexFaceKey: FlexibleSquishFace] = [:], built: [FlexFaceKey] = []
        var depths: [FlexFaceKey: [Double?]] = [:], noLattice: [FlexFaceKey: [Bool]] = [:]
        var drawn: [FlexibleGeometryOnlyLattice.Face] = []
        var designed: [FlexFaceKey: FlexiblePinch.Segments] = [:], pressure: [FlexFaceKey: [Double]] = [:]
        var extent = 0.0, shallowest = Double.infinity
        for (f, k) in zip(faces, allKeys) {
            guard let st = stacks[k] else { continue }
            let dk: [Double?]
            if shapeOnly {
                guard let sv = liveS[k] else { continue }
                dk = st.columns.indices.map { i in
                    i < sv.count && st.columns[i].latticeMM > 0 ? sv[i] * f.deepestMM : nil
                }
                noLattice[k] = st.columns.map { $0.latticeMM <= 0 }
                drawn.append(.init(stack: st, s: sv))
                let lat = st.columns.map(\.latticeMM).filter { $0 > 0 }
                if !lat.isEmpty { shallowest = min(shallowest, lat.reduce(0, +) / Double(lat.count)) }
            } else {
                guard let d = designs[k] else { continue }
                let sg = segments[k] ?? FlexiblePinch.core(d, stack: st)
                designed[k] = sg
                pressure[k] = d.columns.map(\.pressureMPa)
                dk = sg.buildableDepthMM
                noLattice[k] = st.columns.indices.map { $0 < d.columns.count && d.columns[$0].status == "no_lattice" }
            }
            squish[k] = FlexibleSquishFace(stack: st, depthsMM: dk)
            built.append(k)
            depths[k] = dk
            extent = max(extent, st.uExtentMM, st.vExtentMM)
        }
        // ★ D2 REVIEW: the pass's four slots never split a pinch (face 5 stood still while face 3
        // squished with five pressed faces)
        let pinchedWith = pinchedKeys(built)
        let slots = FlexibleSqueezeGroups.squishSlots(Self.squishOrder(built.map { (key: $0, areaMM2: stacks[$0]?.areaMM2 ?? 0) }),
                                                      pinchedWith: pinchedWith)
        let order = slots.order, squishShown = slots.shown
        // ★ ROUND 4 (D2): the squeeze groups over the faces built, and whether each has a pinch
        let builtSet = Set(order)
        let partners = FlexibleSqueezeGroups.partners(pinches)
        let plans: [(number: Int, keys: [FlexFaceKey], pinched: Bool)] = squeezeGroups.compactMap { g in
            let keys = order.filter { g.regions.contains($0.region) }
            return keys.isEmpty ? nil : (g.number, keys, g.regions.contains { partners[$0] != nil })
        }
        let sims = self.sims.compactMap { sim -> FlexibleSim? in
            let keys = sim.keys.filter { builtSet.contains($0) }
            return keys.isEmpty ? nil : FlexibleSim(id: sim.id, kind: sim.kind, title: sim.title, short: sim.short, keys: keys)
        }
        let stackOf = stacks, regions = self.regions
        let cutsOf = Dictionary(order.map { ($0.region, regions.cuts(of: $0.region)) }, uniquingKeysWith: { a, _ in a })
        latticeGeneration += 1
        let generation = latticeGeneration
        let (builtKeys, faceNoLattice, extentMM, drawnFaces) = (order, noLattice, extent, drawn)
        let (designedSnap, pressureSnap, squishSnap, depthsSnap) = (designed, pressure, squish, depths)
        let depthForBand = shallowest.isFinite ? shallowest : 0
        let build = self.build, key = settings.designInputs.hashValue, temp = designTempC ?? 0
        let lawInputs: (path: String, material: String, temp: Double)? = {
            guard let p = materialsPath, let m = settings.materialID, let t = designTempC else { return nil }
            return (p, m, t)
        }()
        let builtOn = openedKey, buildKey = latticeBuildKey
        let label = shapeOnly ? FlexibleReadiness.shapeOnlyLabel(material?.displayName ?? "This filament") : nil
        // ★ ROUND 4 (D1): the WHOLE model's finish (None / Rim / Skin / Covered) — the per-face
        // "Solid skin" is gone
        let finish = settings.finishMode
        let buildDir = sceneInfo?.buildDir ?? SIMD3(0, 0, 1)
        latticeBuilding = true
        latticeError = nil
        let worker = self.worker
        let failWith = controlFailBuild
        let combine = controlCombine
        // ★ BATCH G: the squish sims' law, rests and (shape only) weights — every group a sim
        let feLaw: FlexSquishLawInfo? = materialsPath.map {
            FlexSquishLawInfo(materialsPath: $0, materialID: settings.materialID ?? "", topology: build.topology,
                              tempC: designTempC ?? 0, shapeOnly: shapeOnly)
        }
        let feResting = settings.faces.filter { $0.role == "resting" }.map(\.faceRegionID)
        let feWeights = Dictionary(zip(allKeys, faces.map(\.weightN)), uniquingKeysWith: { a, _ in a })
        track(Task.detached(priority: .userInitiated) {
            do {
                if let failWith { throw TopOptError(message: failWith) }
                var field: FlexDensityField
                var shared = 0
                var faceDepths = depthsSnap, squishFaces = squishSnap
                var notes: [String: String] = [:]
                if shapeOnly {
                    // ★ core's mask, the drawn map's density inside the printable band (a voxel
                    // under two faces — a pinch, two groups — takes the firmer)
                    let mask = try await worker.withScene { try $0.latticeMask(build: build) }
                    let band = try FlexibleGeometryOnlyLattice.band(topology: build.topology, beadsPerWall: build.beadsPerWall,
                                                                    beadWidthMM: build.beadWidthMM, latticeDepthMM: depthForBand)
                    field = FlexibleGeometryOnlyLattice.field(mask: mask, faces: drawnFaces, band: band)
                } else {
                    var fields: [FlexDensityField] = []
                    var mask: FlexDensityField?
                    for plan in plans {
                        if plan.pinched {
                            // ★ a PINCH: core refuses one stack pressed from both ends — the app
                            // assembles it by core's rule, over each face's halves
                            if mask == nil { mask = try await worker.withScene { try $0.latticeMask(build: build) } }
                            let fs = plan.keys.compactMap { k -> FlexibleGroupField.Face? in
                                guard let st = stackOf[k], let sg = designedSnap[k] else { return nil }
                                return FlexibleGroupField.Face(region: k.region, stack: st, cuts: cutsOf[k.region] ?? [],
                                                               density: sg.buildableDensity, cellMM: sg.cellMM)
                            }
                            fields.append(FlexibleGroupField.assemble(mask: mask!, faces: fs))
                        } else {
                            fields.append(try await worker.withScene {
                                try $0.densityField(faces: plan.keys.map(\.region), rotations: plan.keys.map(\.rotation), build: build)
                            })
                        }
                    }
                    guard !fields.isEmpty else { throw TopOptError(message: "No pressed face has a design yet.") }
                    if fields.count == 1 {
                        field = fields[0]
                    } else {
                        let c = combine(fields)
                        field = c.field
                        shared = c.shared
                        // ★ SEPARATE SQUEEZES: each face squishes by what its column holds in the
                        // COMBINED field (≈), and a group that misses its design says so
                        if let li = lawInputs {
                            let law = try FlexiblePinch.Law.core(materialsPath: li.path, materialID: li.material, tempC: li.temp, build: build)
                            for k in builtKeys {
                                guard let st = stackOf[k], let sg = designedSnap[k], let p = pressureSnap[k] else { continue }
                                let d = try FlexibleGroupField.asBuilt(field, stack: st, segments: sg, pressureMPa: p,
                                                                        strainUnder: law.strainUnder)
                                faceDepths[k] = d
                                squishFaces[k] = FlexibleSquishFace(stack: st, depthsMM: d)
                            }
                            for plan in plans {
                                let want = plan.keys.compactMap { designedSnap[$0]?.buildableDepthMM.compactMap { $0 }.max() }.max() ?? 0
                                let got = plan.keys.compactMap { faceDepths[$0]?.compactMap { $0 }.max() }.max() ?? 0
                                if FlexibleGroupEstimate.misses(designedMM: want, asBuiltMM: got) {
                                    notes[FlexibleSim.groupID(plan.number)] =
                                        FlexibleRowCopy.groupMisses(number: plan.number, asBuiltMM: got, designedMM: want)
                                }
                            }
                        }
                    }
                }
                let inputs = try FlexibleLatticeBuilder.inputs(
                    field: field, part: part, topology: build.topology, beadsPerWall: build.beadsPerWall,
                    beadWidthMM: build.beadWidthMM, buildDir: buildDir, skinOffFaces: [], finish: finish)
                // ★ BATCH G: what the squish sims need, made HERE — the combined field is not kept
                // (D-R4-19); the solver releases it after the last sim
                var fe: FlexibleFERequest?
                if let law = feLaw {
                    var fs: [FlexFaceKey: FlexibleFERequest.Face] = [:]
                    for k in builtKeys {
                        guard let st = stackOf[k] else { continue }
                        let sg = designedSnap[k]
                        let even = (feWeights[k] ?? 0) / Swift.max(st.footprintAreaMM2, 1e-9)
                        fs[k] = FlexibleFERequest.Face(key: k, stack: st, cuts: cutsOf[k.region] ?? [], depthsMM: faceDepths[k] ?? [],
                                                       heightsMM: sg?.heightMM ?? st.columns.map(\.latticeMM),
                                                       pinched: sg?.pinched ?? [],
                                                       pressureMPa: pressureSnap[k] ?? [Double](repeating: even, count: st.columns.count))
                    }
                    fe = FlexibleFERequest.build(field: field, inputs: inputs, sims: sims, faces: fs, resting: feResting,
                                                 law: law, generation: generation)
                }
                let feBuilt = fe
                let faceList = builtKeys.compactMap { squishFaces[$0] }
                let g = FlexibleGeneratedLattice(inputs: inputs, faces: faceList, keys: builtKeys, columnDepths: faceDepths,
                                                 columnNoLattice: faceNoLattice, extentMM: extentMM, generation: generation,
                                                 topology: build.topology, tempC: temp, settingsKey: key,
                                                 squishedKeys: Array(builtKeys.prefix(squishShown)),
                                                 shapeOnlyLabel: label, sceneKey: builtOn,
                                                 sims: sims, simNotes: notes, sharedVoxels: shared, pinchedWith: pinchedWith)
                let combined = field
                let keep = await MainActor.run { self.keepCombinedField }
                let kept = keep ? combined : nil
                await MainActor.run {
                    self.lattice = g; self.lastCombinedField = kept; self.latticeBuilding = false
                    self.latticeLanded(feBuilt)   // ★ BATCH G: a new lattice — its own squish sims
                }
            } catch {
                await MainActor.run {
                    self.latticeFailedKey = buildKey
                    self.latticeError = "\(error)"
                    self.latticeBuilding = false
                }
            }
        })
    }

    /// Test control only: how separate squeezes are combined (the rule: the firmer wins).
    var controlCombine: @Sendable ([FlexDensityField]) -> (field: FlexDensityField, shared: Int) = { FlexibleGroupField.firmer($0) }

    public func discardLattice() { lattice = nil; latticeLanded(nil) }

    /// Test control only: the next builds throw this (a builder or core refusal on the build).
    var controlFailBuild: String?

    // MARK: the run job (S5)

    /// The run job. ★ C2 VERIFICATION: `resting` — pressed faces that REST in this job only (the
    /// Export step's [Send with Face 5 resting] / [Send Group 1 only]: what core can run of a
    /// pinch or of several squeeze groups); his settings are untouched. A part with no file is
    /// its own error (C2 told him "press a face first").
    public func runJobJSON(resting: Set<Int> = []) throws -> String {
        guard let file = project.importedFile else { throw FlexibleJob.EncodeError.noPart }
        var s = settings
        if !resting.isEmpty {
            for r in resting {
                guard var f = s.face(r), f.isLoaded else { continue }
                f.role = "resting"
                s.setFace(f)
            }
            FlexibleSqueezeGroups.normalise(&s)
        }
        let pinches = FlexibleSqueezeGroups.pinches(conflicts, s)
        // ★ ROUND 4 (D2): what core cannot run yet (core brief) is said, never sent to be refused
        if FlexibleSqueezeGroups.groups(s).count > 1 { throw FlexibleJob.EncodeError.squeezeGroups }
        if !pinches.isEmpty { throw FlexibleJob.EncodeError.pinch }
        let faceCount = max(file.faceCount, (project.viewerMesh?.faceIDs.max().map { Int($0) + 1 }) ?? 0)
        var inputs = FlexibleJob.Inputs(
            modelPath: file.path, resolution: project.quality.resolution,
            beadWidthMM: project.printParams.strutLineWidthMM, faceCount: faceCount,
            settings: s, regions: project.latticeJobRegions().regions.map(\.wireDictionary),
            stampGrids: stampGrids)
        inputs.sectorRegions = regions.wire
        (inputs.buildDir, inputs.plateDir) = buildDirections
        inputs.pinches = pinches.map { [$0.a, $0.b] }
        return try FlexibleJob.runJobJSON(inputs)
    }
}

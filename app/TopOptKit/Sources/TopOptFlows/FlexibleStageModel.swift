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
    public enum Tab: String, CaseIterable, Identifiable {
        case face = "Face", stamps = "Stamps", more = "More"
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

    // what the screens show
    @Published public private(set) var catalogue: [FlexMaterialInfo] = []
    @Published public private(set) var catalogueError: String?
    @Published public private(set) var bands: FlexErrorBandsInfo?
    @Published public private(set) var sceneState: SceneState = .idle
    @Published public private(set) var sceneInfo: FlexibleScene.Info?
    @Published public var tab: Tab = .face
    @Published public var selectedRegion: Int?
    @Published public var showBuildable = false
    @Published public private(set) var stacks: [FlexFaceKey: FlexStackInfo] = [:]
    @Published public private(set) var geometry: [FlexFaceKey: FlexFaceGeometry] = [:]
    @Published public private(set) var liveS: [FlexFaceKey: [Double]] = [:]
    @Published public private(set) var designs: [FlexFaceKey: FlexFaceDesignInfo] = [:]
    @Published public private(set) var conflicts: [FlexConflictInfo] = []
    @Published public private(set) var recommendation: FlexRecommendationInfo?
    @Published public private(set) var recommendationError: String?
    @Published public private(set) var checks: [UUID: FlexStampCheckInfo] = [:]
    @Published public private(set) var stampGrids: [UUID: FlexStamp] = [:]
    /// Check mode shows the stamp's dent instead of the design's (M14).
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
    /// ★ ROUND 3 BATCH B (item 9): core's words per face, kept PER KEY — a face core could
    /// not stack (no blind retry: the next scene open clears it) or could not design (one
    /// face's throw no longer leaves every later face "still being designed").
    @Published public private(set) var stackErrors: [FlexFaceKey: String] = [:]
    @Published public private(set) var designErrors: [FlexFaceKey: String] = [:]
    /// Bumped by every action of HIS that can create a problem (press, rest, a weight, the
    /// trash, a filament): the fix pop-up opens only on a NEW blocking issue an action caused.
    @Published public private(set) var actionSerial = 0
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

    private func track(_ t: Task<Void, Never>) {
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
            if inFlight.isEmpty { return }
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
        selectedRegion = region
        if tab == .more { tab = .face }
        ensureStack(region)
    }

    // MARK: the main page's loads (round 3, item 1.2 — FlexibleMainPageLoads)

    /// The main page's groups read as Flexible faces (cached per scene open and write-back).
    @Published public private(set) var mainPageLoads = FlexibleMainPageLoads()
    /// Faces whose OWN weight a group's replaced this session (region → the old kg): the
    /// panel says so in one line ("Was 7 kg · now Top's weight").
    @Published public private(set) var relinkedWeights: [Int: Double] = [:]

    /// Read the main page's groups, then MATERIALISE them (`FlexibleMainPageLoads.adopt`): a
    /// face a Load group presses is pressed with its share and LINKED (weightFrom = the
    /// group) — one source of truth, also for a face pressed before round 3; an Anchor
    /// group's faces rest; [Rests] chosen on this page survives; a face whose group no longer
    /// holds it keeps its weight as his own. Sealed as one undo step. Called when the scene
    /// opens and after every write-back.
    public func adoptMainPageLoads(recompute: Bool = true) {
        guard let mesh = project.viewerMesh else { return }
        let loads = FlexibleMainPageLoads.derive(
            groups: project.selection.groups, force: project.force, faceRegions: project.faceRegions,
            mesh: mesh, regions: regions, load: { [stacks] r in stacks[FlexFaceKey(region: r, rotation: 0)]?.load })
        mainPageLoads = loads
        let before = settings
        var relinked: [Int: Double] = [:]
        edit({ s in relinked = loads.adopt(into: &s) }, recompute: recompute)
        relinkedWeights.merge(relinked) { old, _ in old }
        if settings != before { project.sealUndoStep() }
        if selectedRegion == nil { selectedRegion = settings.loadedFaces.first?.faceRegionID }
    }

    /// [Press it]: the main page's weight when the face is in a Load group; else `kg` (the
    /// number pad's answer). false ⇒ a weight must be asked first ("How much weight presses
    /// here?").
    @discardableResult
    public func press(_ region: Int, kg: Double? = nil) -> Bool {
        let inherited = mainPageLoads.entry(region).flatMap { $0.role == .pressed ? $0 : nil }
        guard inherited != nil || (kg ?? 0) > 0 else { return false }
        actionSerial += 1
        edit { s in
            var f = s.face(region) ?? FlexibleFaceSettings(faceRegionID: region)
            f.role = "loaded"
            if let e = inherited, kg == nil { f.weightKg = e.weightKg; f.weightFrom = e.groupID }
            else if let kg { f.weightKg = kg; f.weightFrom = nil }
            s.setFace(f)
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
            var f = s.face(region) ?? FlexibleFaceSettings(faceRegionID: region, role: "resting")
            f.role = "resting"
            f.weightFrom = nil
            s.setFace(f)
        }
        relinkedWeights[region] = nil
        selectedRegion = region
    }

    /// A weight typed on the Flexible page. ★ ONE SOURCE OF TRUTH (maintainer): for a face
    /// whose weight comes from a main-page group, it WRITES BACK to the group — the group
    /// takes the weight that gives this face `kg` — and every face of the group re-syncs, so
    /// the area split stays consistent. A face in no group keeps it as its own.
    public func setWeight(_ region: Int, kg: Double) {
        guard kg > 0 else { return }
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

    /// The trash. Refused (false) for a face a main-page group presses or anchors: the next
    /// re-sync would bring it straight back, so the panel offers [Rests] instead.
    @discardableResult
    public func removeFace(_ region: Int) -> Bool {
        guard mainPageLoads.canRemove(region) else { return false }
        actionSerial += 1
        edit { $0.removeFace(region) }
        relinkedWeights[region] = nil
        if selectedRegion == region { selectedRegion = settings.faces.first?.faceRegionID }
        return true
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
                await MainActor.run { self.stacks[k] = st; self.geometry[k] = g; self.recomputeAll() }
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
            if designsInFlight { designsInFlight = false }
            return
        }
        if !designsInFlight { designsInFlight = true }
        let faces = settings.loadedFaces.filter { stacks[FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg)] != nil }
        let temp = designTempC, build = self.build, grids = stampGrids
        let checkStamps = settings.checkStamps
        let worker = self.worker
        designTask = Task.detached(priority: .userInitiated) {
            if delayNS > 0 { try? await Task.sleep(nanoseconds: delayNS) }
            if Task.isCancelled { return }
            var out: [FlexFaceKey: FlexFaceDesignInfo] = [:]
            var faceErrors: [FlexFaceKey: String] = [:]
            var s: [FlexFaceKey: [Double]] = [:]
            var checks: [UUID: FlexStampCheckInfo] = [:]
            var conflicts: [FlexConflictInfo] = []
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
                    let stamp = f.designStamp.flatMap { grids[$0.id] }
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
            }
            if Task.isCancelled { return }
            let (o, fe, ss, ch, co, er) = (out, faceErrors, s, checks, conflicts, err)
            await MainActor.run {
                guard gen == self.designGeneration else { return }
                self.designsInFlight = false
                self.designs = o
                self.designErrors = fe
                for (k, v) in ss { self.liveS[k] = v }
                self.checks = ch
                self.conflicts = co
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
                                   weightN: f.weightN, stamp: f.designStamp.flatMap { stampGrids[$0.id] })
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
        for f in settings.faces { if let p = f.designStamp { lay(p, region: f.faceRegionID) } }
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
        lattice.map { $0.settingsKey != settings.hashValue || ($0.sceneKey != nil && $0.sceneKey != openedKey) } ?? false
    }

    /// What a build is keyed by: the settings and the scene.
    private var latticeBuildKey: String { "\(settings.hashValue)|\(openedKey ?? "")" }
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
    var settingsOutranPipeline: Bool { sceneState == .ready && pipelineSettings != settings }

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
    public func generateLattice() {
        let ready = readiness
        // blocked, or still designing (a face without its design would be left out silently)
        guard ready.isReady, !ready.designing, !latticeBuilding, let part = project.viewerMesh else { return }
        let faces = settings.loadedFaces
        let shapeOnly = material?.noPrediction != nil
        let allKeys = faces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
        // ★ ONE ARRAY PER FACE for the walls AND the dent: core's buildable depths — or, shape
        // only, the drawing itself (S × deepest) — kept on the lattice so the map drawn beside
        // it is the one it squishes by
        var squish: [FlexFaceKey: FlexibleSquishFace] = [:], built: [FlexFaceKey] = []
        var depths: [FlexFaceKey: [Double?]] = [:], noLattice: [FlexFaceKey: [Bool]] = [:]
        var drawn: [FlexibleGeometryOnlyLattice.Face] = []
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
                dk = FlexibleSquishFace.buildableDepths(stack: st, design: d)
                noLattice[k] = st.columns.indices.map { $0 < d.columns.count && d.columns[$0].status == "no_lattice" }
            }
            squish[k] = FlexibleSquishFace(stack: st, depthsMM: dk)
            built.append(k)
            depths[k] = dk
            extent = max(extent, st.uExtentMM, st.vExtentMM)
        }
        let order = Self.squishOrder(built.map { (key: $0, areaMM2: stacks[$0]?.areaMM2 ?? 0) })
        let squishFaces = order.compactMap { squish[$0] }
        let squished = Array(order.prefix(FlexibleSquishField.maxFaces))
        latticeGeneration += 1
        let generation = latticeGeneration
        let (builtKeys, faceDepths, faceNoLattice, extentMM, drawnFaces) = (order, depths, noLattice, extent, drawn)
        let depthForBand = shallowest.isFinite ? shallowest : 0
        let build = self.build, key = settings.hashValue, temp = designTempC ?? 0
        let builtOn = openedKey, buildKey = latticeBuildKey
        let label = shapeOnly ? FlexibleReadiness.shapeOnlyLabel(material?.displayName ?? "This filament") : nil
        let regions = self.regions
        let skinOff: [(face: Int, cuts: [RegionCut])] = faces.filter { !$0.skinOn }.flatMap { f in
            regions.faces(of: f.faceRegionID, mesh: part).map { (face: $0, cuts: regions.cuts(of: f.faceRegionID)) }
        }
        let buildDir = sceneInfo?.buildDir ?? SIMD3(0, 0, 1)
        latticeBuilding = true
        latticeError = nil
        let worker = self.worker
        let failWith = controlFailBuild
        track(Task.detached(priority: .userInitiated) {
            do {
                if let failWith { throw TopOptError(message: failWith) }
                let field: FlexDensityField
                if shapeOnly {
                    // ★ core's mask, the drawn map's density inside the printable band
                    let mask = try await worker.withScene { try $0.latticeMask(build: build) }
                    let band = try FlexibleGeometryOnlyLattice.band(topology: build.topology, beadsPerWall: build.beadsPerWall,
                                                                    beadWidthMM: build.beadWidthMM, latticeDepthMM: depthForBand)
                    field = FlexibleGeometryOnlyLattice.field(mask: mask, faces: drawnFaces, band: band)
                } else {
                    field = try await worker.withScene {
                        try $0.densityField(faces: builtKeys.map(\.region), rotations: builtKeys.map(\.rotation), build: build)
                    }
                }
                let inputs = try FlexibleLatticeBuilder.inputs(
                    field: field, part: part, topology: build.topology, beadsPerWall: build.beadsPerWall,
                    beadWidthMM: build.beadWidthMM, buildDir: buildDir, skinOffFaces: skinOff)
                let g = FlexibleGeneratedLattice(inputs: inputs, faces: squishFaces, keys: builtKeys, columnDepths: faceDepths,
                                                 columnNoLattice: faceNoLattice, extentMM: extentMM, generation: generation,
                                                 topology: build.topology, tempC: temp, settingsKey: key,
                                                 squishedKeys: squished, shapeOnlyLabel: label, sceneKey: builtOn)
                await MainActor.run { self.lattice = g; self.latticeBuilding = false }
            } catch {
                await MainActor.run {
                    self.latticeFailedKey = buildKey
                    self.latticeError = "\(error)"
                    self.latticeBuilding = false
                }
            }
        })
    }

    public func discardLattice() { lattice = nil }

    /// Test control only: the next builds throw this (a builder or core refusal on the build).
    var controlFailBuild: String?

    // MARK: the run job (S5)

    public func runJobJSON() throws -> String {
        guard let file = project.importedFile else { throw FlexibleJob.EncodeError.noLoadedFace }
        let faceCount = max(file.faceCount, (project.viewerMesh?.faceIDs.max().map { Int($0) + 1 }) ?? 0)
        var inputs = FlexibleJob.Inputs(
            modelPath: file.path, resolution: project.quality.resolution,
            beadWidthMM: project.printParams.strutLineWidthMM, faceCount: faceCount,
            settings: settings, regions: project.latticeJobRegions().regions.map(\.wireDictionary),
            stampGrids: stampGrids)
        inputs.sectorRegions = regions.wire
        (inputs.buildDir, inputs.plateDir) = buildDirections
        return try FlexibleJob.runJobJSON(inputs)
    }
}

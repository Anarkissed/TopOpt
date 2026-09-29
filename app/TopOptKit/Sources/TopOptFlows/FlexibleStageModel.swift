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

public struct FlexFaceKey: Hashable, Sendable {
    public let region: Int
    public let rotation: Int
}

/// Where a face's drawings go in 3D — every point from core's frame (from_uv / to_uv).
public struct FlexFaceGeometry {
    /// from_uv at every column centre, column order.
    public let centres: [SIMD3<Double>]
    /// The X edge (v = 0), the Y edge (u = 0) and the centre→edge line, on the face.
    public let baselineX: FlexibleCurveBaseline
    public let baselineY: FlexibleCurveBaseline
    public let baselineC: FlexibleCurveBaseline
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
        // centre→edge: from the face boundary (t = 0) to the most-inside column (t = 1)
        let ef = try scene.edgeFraction(face: k.region, rotation: k.rotation)
        let ci = ef.indices.max { ef[$0] < ef[$1] } ?? 0
        let (cu, cv, civ) = st.columns.isEmpty ? (0.0, 0.0, 0) : (st.columns[ci].uMM, st.columns[ci].vMM, st.columns[ci].iv)
        var u0 = cu
        while st.pitchMM > 0, st.column(Int(u0 / st.pitchMM) - 1, civ) >= 0 { u0 -= st.pitchMM }
        u0 -= st.pitchMM / 2
        let bc = FlexibleCurveBaseline(points: try line { (u0 + (cu - u0) * $0, cv) }, up: up, amplitudeMM: amp)
        let corner = try line { _ in (0, 0) }.first ?? .zero
        var xyz = [Double](); xyz.reserveCapacity(partFlat.count)
        for f in partFlat { xyz.append(Double(f)) }
        let uvt = try scene.toUVT(face: k.region, rotation: k.rotation, xyz)
        return FlexFaceGeometry(centres: centres, baselineX: bx, baselineY: by, baselineC: bc,
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

    public enum Tab: String, CaseIterable, Identifiable {
        case filament = "Filament", squish = "Squish", auto = "Auto", physics = "Physics", stamps = "Stamps"
        public var id: String { rawValue }
    }
    public enum Step: String, CaseIterable, Identifiable {
        case curveX = "X curve", curveY = "Y curve", view3D = "3D view"
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

    // what the screens show
    @Published public private(set) var catalogue: [FlexMaterialInfo] = []
    @Published public private(set) var catalogueError: String?
    @Published public private(set) var bands: FlexErrorBandsInfo?
    @Published public private(set) var sceneState: SceneState = .idle
    @Published public private(set) var sceneInfo: FlexibleScene.Info?
    @Published public var tab: Tab = .filament
    @Published public var step: Step = .curveX
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
    @Published public private(set) var slice: FlexFieldSliceInfo?
    @Published public var sliceAxis = 0
    @Published public var sliceFraction = 0.5
    /// Check mode shows the stamp's dent instead of the design's (M14).
    @Published public var checkStampShown: UUID?
    @Published public private(set) var lastError: String?
    /// The generated lattice (Generate button) and its build state.
    @Published public private(set) var lattice: FlexibleGeneratedLattice?
    @Published public private(set) var latticeBuilding = false
    @Published public private(set) var latticeError: String?

    private var pendingStacks: Set<FlexFaceKey> = []
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

    public var settings: FlexibleStageSettings {
        get { project.lattice.flexible ?? FlexibleStageSettings() }
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
        let json = try FlexibleJob.sceneJobJSON(inputs, fallbackMaterial: catalogue.first?.id ?? "flexible")
        return SceneJob(json: json, dir: (file.path as NSString).deletingLastPathComponent)
    }

    /// The scene's key: everything that changes the part, grid, mask or regions —
    /// NOT the faces, curves or filament (those re-run designs, never the scene).
    private func sceneKey() -> String {
        guard let file = project.importedFile else { return "" }
        let regions = project.latticeJobRegions().regions.map(\.wireDictionary)
        let r = (try? JSONSerialization.data(withJSONObject: regions, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(file.path)|\(project.quality.resolution)|\(r)|\(self.regions.key)"
    }

    // MARK: regions (split sectors, FlexibleRegions.swift)

    /// The declared regions: every face, plus the Surface stage's split sectors.
    public var regions: FlexibleRegions { FlexibleRegions(model: project.faceRegions, mesh: project.viewerMesh) }
    public func name(_ region: Int) -> String { regions.name(region, mesh: project.viewerMesh) }
    /// Core's sentence with sector ids replaced by the app's names.
    public func text(_ s: String) -> String { regions.renamed(s, mesh: project.viewerMesh) }

    public func openScene() {
        guard sceneState != .opening else { return }
        let key = sceneKey()
        guard let job = try? sceneJob() else {
            sceneState = .failed("This project has no imported part to open.")
            return
        }
        sceneState = .opening
        let worker = self.worker
        Task.detached(priority: .userInitiated) {
            do {
                let info = try await worker.open(jobJSON: job.json, jobDir: job.dir, key: key)
                await MainActor.run {
                    self.sceneInfo = info
                    self.stacks = [:]
                    self.geometry = [:]
                    self.pendingStacks = []
                    self.sceneState = .ready
                    self.recomputeAll()
                }
            } catch {
                await MainActor.run { self.sceneState = .failed("\(error)") }
            }
        }
    }

    // MARK: faces (S2)

    public var loadedKeys: [FlexFaceKey] {
        settings.loadedFaces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
    }

    /// Tap on the model: a new face becomes loaded; a known face is selected.
    public func tapFace(_ face: Int, point: SIMD3<Double>? = nil) {
        // a split face resolves to the sector holding the point (the Surface stage's rule)
        let region = regions.region(at: point, face: face, mesh: project.viewerMesh)
        NSLog("DIAG flexible tap face %d → region %d (known %d)", face, region, settings.face(region) != nil ? 1 : 0)
        if settings.face(region) == nil {
            edit { $0.setFace(FlexibleFaceSettings(faceRegionID: region)) }
        }
        selectedRegion = region
        if tab == .filament { tab = .squish }
        ensureStack(region)
    }

    public func removeFace(_ region: Int) {
        edit { $0.removeFace(region) }
        if selectedRegion == region { selectedRegion = settings.faces.first?.faceRegionID }
    }

    public func key(_ region: Int) -> FlexFaceKey? {
        settings.face(region).map { FlexFaceKey(region: region, rotation: $0.rotationDeg) }
    }

    public func stack(_ region: Int) -> FlexStackInfo? { key(region).flatMap { stacks[$0] } }
    public func design(_ region: Int) -> FlexFaceDesignInfo? { key(region).flatMap { designs[$0] } }

    private func ensureStack(_ region: Int) {
        guard sceneState == .ready, let k = key(region), stacks[k] == nil, !pendingStacks.contains(k) else { return }
        pendingStacks.insert(k)
        let partFlat = project.viewerMesh?.flat.positions ?? []
        let worker = self.worker
        Task.detached(priority: .userInitiated) {
            do {
                let st = try await worker.withScene { try $0.stack(face: k.region, rotation: k.rotation) }
                let g = try await worker.withScene { try FlexFaceGeometry.compute(scene: $0, key: k, stack: st, partFlat: partFlat) }
                await MainActor.run { self.stacks[k] = st; self.geometry[k] = g; self.recomputeAll() }
            } catch {
                await MainActor.run { self.lastError = "\(error)"; self.pendingStacks.remove(k) }
            }
        }
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
        Task.detached(priority: .userInitiated) {
            if let s = try? await worker.withScene({ try $0.squishFraction(face: k.region, rotation: k.rotation, map: map) }) {
                await MainActor.run { self.liveS[k] = s }
            }
        }
        scheduleDesigns(delayNS: 120_000_000)
    }

    public func recomputeAll() {
        guard sceneState == .ready else { return }
        for k in loadedKeys where stacks[k] == nil { ensureStack(k.region) }
        rasteriseStamps()
        scheduleDesigns(delayNS: 0)
        scheduleAuto()
    }

    private func scheduleDesigns(delayNS: UInt64) {
        designGeneration += 1
        let gen = designGeneration
        designTask?.cancel()
        guard let path = materialsPath, let mat = settings.materialID else {
            designs = [:]
            return
        }
        let faces = settings.loadedFaces.filter { stacks[FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg)] != nil }
        let temp = designTempC, build = self.build, grids = stampGrids
        let checkStamps = settings.checkStamps
        let sliceAxis = self.sliceAxis, sliceFraction = self.sliceFraction
        let info = sceneInfo
        let worker = self.worker
        designTask = Task.detached(priority: .userInitiated) {
            if delayNS > 0 { try? await Task.sleep(nanoseconds: delayNS) }
            if Task.isCancelled { return }
            var out: [FlexFaceKey: FlexFaceDesignInfo] = [:]
            var s: [FlexFaceKey: [Double]] = [:]
            var checks: [UUID: FlexStampCheckInfo] = [:]
            var conflicts: [FlexConflictInfo] = []
            var slice: FlexFieldSliceInfo?
            var err: String?
            do {
                let keys = faces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
                conflicts = try await worker.withScene {
                    try $0.conflicts(faces: keys.map(\.region), rotations: keys.map(\.rotation))
                }
                if let temp {
                    for f in faces {
                        if Task.isCancelled { return }
                        let k = FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)
                        let stamp = f.designStamp.flatMap { grids[$0.id] }
                        let d = try await worker.withScene {
                            try $0.design(materialsPath: path, materialID: mat, tempC: temp, face: k.region,
                                          rotation: k.rotation, map: f.map, weightN: f.weightN,
                                          stamp: stamp, build: build)
                        }
                        out[k] = d
                        s[k] = d.columns.map(\.s)
                    }
                    for c in checkStamps {
                        guard let f = faces.first(where: { $0.faceRegionID == c.faceRegionID }),
                              let g = grids[c.stamp.id], out[FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)]?.refusal == nil
                        else { continue }
                        checks[c.stamp.id] = try await worker.withScene {
                            try $0.checkStamp(materialsPath: path, materialID: mat, tempC: temp,
                                              face: f.faceRegionID, rotation: f.rotationDeg, stamp: g, build: build)
                        }
                    }
                    let designed = keys.filter { out[$0]?.refusal == nil && out[$0] != nil }
                    if conflicts.isEmpty, !designed.isEmpty, let info {
                        let n = [info.nx, info.ny, info.nz][sliceAxis]
                        let idx = max(0, min(n - 1, Int(Double(n) * sliceFraction)))
                        slice = try await worker.withScene {
                            try $0.densitySlice(faces: designed.map(\.region), rotations: designed.map(\.rotation),
                                                build: build, axis: sliceAxis, index: idx)
                        }
                    }
                }
            } catch {
                err = "\(error)"
            }
            if Task.isCancelled { return }
            let (o, ss, ch, co, sl, er) = (out, s, checks, conflicts, slice, err)
            await MainActor.run {
                guard gen == self.designGeneration else { return }
                self.designs = o
                for (k, v) in ss { self.liveS[k] = v }
                self.checks = ch
                self.conflicts = co
                self.slice = sl
                self.lastError = er
            }
        }
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

    // MARK: Generate lattice (FlexibleLatticeGeneration.swift)

    public var latticeRefusal: String? { FlexibleLatticeGate.refusal(self) }
    /// The generated lattice no longer matches the settings (a face or the filament changed).
    public var latticeIsStale: Bool { lattice.map { $0.settingsKey != settings.hashValue } ?? false }

    public func generateLattice() {
        guard latticeRefusal == nil, !latticeBuilding, let part = project.viewerMesh else { return }
        let faces = settings.loadedFaces
        let keys = faces.map { FlexFaceKey(region: $0.faceRegionID, rotation: $0.rotationDeg) }
        let squish = keys.compactMap { k -> FlexibleSquishFace? in
            guard let st = stacks[k], let d = designs[k] else { return nil }
            return FlexibleSquishFace(region: k.region, stack: st, design: d)
        }
        let build = self.build, key = settings.hashValue, temp = designTempC ?? 0
        let regions = self.regions
        let skinOff: [(face: Int, cuts: [RegionCut])] = faces.filter { !$0.skinOn }.flatMap { f in
            regions.faces(of: f.faceRegionID, mesh: part).map { (face: $0, cuts: regions.cuts(of: f.faceRegionID)) }
        }
        let buildDir = sceneInfo?.buildDir ?? SIMD3(0, 0, 1)
        latticeBuilding = true
        latticeError = nil
        let worker = self.worker
        Task.detached(priority: .userInitiated) {
            do {
                let field = try await worker.withScene {
                    try $0.densityField(faces: keys.map(\.region), rotations: keys.map(\.rotation), build: build)
                }
                let inputs = try FlexibleLatticeBuilder.inputs(
                    field: field, part: part, topology: build.topology, beadsPerWall: build.beadsPerWall,
                    beadWidthMM: build.beadWidthMM, buildDir: buildDir, skinOffFaces: skinOff)
                let g = FlexibleGeneratedLattice(inputs: inputs, faces: squish, topology: build.topology,
                                                 tempC: temp, settingsKey: key)
                await MainActor.run { self.lattice = g; self.latticeBuilding = false }
            } catch {
                await MainActor.run { self.latticeError = "\(error)"; self.latticeBuilding = false }
            }
        }
    }

    public func discardLattice() { lattice = nil }

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
        return try FlexibleJob.runJobJSON(inputs)
    }
}

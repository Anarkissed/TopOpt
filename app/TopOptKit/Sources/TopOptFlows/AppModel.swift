// AppModel.swift — the M7.3 home + import flow state machine.
//
// This is the testable core of the flow: navigation (home ⇄ import sheet ⇄
// workspace), the material dropdown sourced from materials.json via the bridge,
// file import through TopOptKit with the core diagnostic surfaced on failure, and
// the recent-projects list. The SwiftUI screens (HomeView / ImportSheet /
// RootView) are thin renderers over this; the logic lives here so it can be
// exercised headlessly by FlowFlowTests (the M7 /app/ verification standard).
//
// The bridge calls are injected (defaulting to the real TopOptKit) so the flow
// can be driven in tests against the committed core fixtures and its error paths
// forced deterministically.

import Foundation
import CoreGraphics
import Combine
import TopOptKit

@MainActor
public final class AppModel: ObservableObject {

    // MARK: Navigation

    /// The current top-level screen.
    @Published public private(set) var screen: Screen = .home
    /// Whether the import sheet is presented over Home.
    @Published public private(set) var importSheetPresented = false
    /// The name shown in the workspace chrome once a project is opened.
    @Published public private(set) var projectName = ""

    /// The workspace's current project state (mesh + selection groups + force/
    /// gravity + run), OWNED here so it survives navigation (M7.x-persist-a). Nil on
    /// Home before any project is opened.
    @Published public private(set) var project: ProjectModel?
    /// Live projects keyed by their `RecentProject.id`, so opening a recent within
    /// this launch restores the exact in-progress state rather than an empty one.
    private var projectsById: [UUID: ProjectModel] = [:]

    // MARK: Import draft (valid only while the sheet is open)

    /// The chosen print process; selects the material family offered.
    @Published public var process: ProcessKind = .fdm
    /// Import-draft "minimize plastic" toggle, carried into the new project. On →
    /// pursue material reduction; off → just handle the forces. Default on.
    @Published public var minimizePlastic = true
    /// Import-draft optimize resolution/quality, carried into the new project.
    @Published public var quality: RunQuality = .fast
    /// Selected material name per family (kept independently so switching the
    /// segment restores the family's own choice).
    @Published public private(set) var selectedFDMMaterial: String?
    @Published public private(set) var selectedResinMaterial: String?
    /// The successfully-imported (watertight) file, or nil until one is picked.
    @Published public private(set) var importedFile: ImportedFile?
    /// The imported part's geometry (flattened buffers + face ids), retained so
    /// the M7.4 workspace viewer has a mesh to render. Set together with
    /// `importedFile` on a watertight accept; cleared on reject / new import.
    @Published public private(set) var importedMesh: ImportedMesh?

    // MARK: Materials (loaded once from the bundle via the bridge)

    @Published public private(set) var fdmMaterials: [MaterialOption] = []
    @Published public private(set) var resinMaterials: [MaterialOption] = []
    /// Full material records by name, kept so a result screen can look up the chosen
    /// material's yield strength for the M7.viz.1 stress legend/scale.
    private var materialsByName: [String: Material] = [:]

    // MARK: Recents + toast

    @Published public private(set) var recentProjects: [RecentProject] = []
    /// Rendered Library thumbnails, keyed by project id. Generated from the imported
    /// mesh this launch (in-memory; on-disk-only recents show the frosted fallback).
    @Published public private(set) var thumbnails: [UUID: CGImage] = [:]
    /// Projects with a run in flight (incl. background runs) — drives the Library
    /// card's "Running" status so you can see at a glance which are optimizing.
    @Published public private(set) var runningIDs: Set<UUID> = []
    /// Phase subscriptions per live project, keeping `runningIDs`/`optimized` current.
    private var runCancellables: [UUID: AnyCancellable] = [:]
    /// Serial queue for the (potentially large) results encode/decode + file IO, so
    /// persisting/restoring variants never blocks the main thread (persist-c).
    private static let resultsQueue = DispatchQueue(label: "app.topopt.results", qos: .utility)
    /// Non-nil shows a transient toast (the design pill); the view clears it.
    @Published public var toast: String?

    // MARK: Dependencies (injected for tests; default to the real bridge)

    private let materialsPath: String?
    private let rulesPath: String?
    private let materialsLoader: (String) throws -> [Material]
    private let importer: (String) throws -> ImportedMesh
    /// Cross-launch persistence layer (M7.x-persist-b) and the clock used for
    /// `savedAt` (injected for deterministic tests).
    private let store: ProjectStore
    private let now: () -> Date

    /// - Parameters:
    ///   - materialsPath: path to materials.json (defaults to the app bundle's
    ///     copy; nil leaves the dropdowns empty until `loadMaterials` is given one).
    ///   - rulesPath: path to the settings rules.json (defaults to the bundle's
    ///     copy); needed to build a run request (ROADMAP M7.7).
    ///   - materialsLoader: injectable loader (defaults to `TopOptKit.loadMaterials`).
    ///   - importer: injectable mesh import (defaults to `TopOptKit.importMesh`).
    ///   - store: on-disk project store (defaults to Application Support).
    ///   - now: clock for save timestamps (defaults to `Date()`).
    public init(
        materialsPath: String? = Bundle.main.path(forResource: "materials", ofType: "json"),
        rulesPath: String? = Bundle.main.path(forResource: "rules", ofType: "json"),
        materialsLoader: @escaping (String) throws -> [Material] = { try TopOptKit.loadMaterials(path: $0) },
        importer: @escaping (String) throws -> ImportedMesh = { try TopOptKit.importMesh(path: $0) },
        store: ProjectStore = ProjectStore(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.materialsPath = materialsPath
        self.rulesPath = rulesPath
        self.materialsLoader = materialsLoader
        self.importer = importer
        self.store = store
        self.now = now
        // Seed the recents grid from disk (lazy: projects are re-imported only when
        // opened). persist-b.
        recentProjects = store.loadAllSnapshots().map {
            RecentProject(id: $0.id, name: $0.name, materialName: $0.material,
                          process: $0.process, optimized: $0.optimized ?? false)
        }
    }

    /// Assemble the inputs `minimize_plastic` needs for the M7.7 run, or nil if a
    /// file / material / config path is missing (Optimize is gated on these, so nil
    /// only happens if wiring is incomplete).
    public func makeRunRequest() -> RunRequest? {
        guard let project, let file = project.importedFile,
              let materialsPath, let rulesPath else { return nil }
        let lc = project.loadCase()
        return RunRequest(modelPath: file.path, material: project.material,
                          materialsPath: materialsPath, rulesPath: rulesPath,
                          resolution: project.quality.resolution,
                          projectName: project.name.isEmpty ? file.name : project.name,
                          anchorFaceIDs: lc.anchorFaceIDs, loadGroups: lc.loadGroups,
                          minimizePlastic: project.minimizePlastic,
                          buildDirection: lc.buildDirection)
    }

    // MARK: - Materials

    /// Load and split materials.json by family. Called on first appearance. On a
    /// load error the dropdowns stay empty and the diagnostic is toasted.
    public func loadMaterials() {
        guard let materialsPath else { return }
        do {
            let mats = try materialsLoader(materialsPath)
            materialsByName = Dictionary(mats.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            fdmMaterials = mats.filter { $0.family == ProcessKind.fdm.family }
                .map { MaterialOption($0.name) }
            resinMaterials = mats.filter { $0.family == ProcessKind.resin.family }
                .map { MaterialOption($0.name) }
            // Seed each family's default selection with its first material.
            if selectedFDMMaterial == nil { selectedFDMMaterial = fdmMaterials.first?.name }
            if selectedResinMaterial == nil { selectedResinMaterial = resinMaterials.first?.name }
        } catch {
            toast = "Couldn’t load materials: \(error)"
        }
    }

    /// The material options for the currently-selected process.
    public var currentMaterials: [MaterialOption] {
        process == .fdm ? fdmMaterials : resinMaterials
    }

    /// The selected material name for the current process, if any.
    public var selectedMaterial: String? {
        process == .fdm ? selectedFDMMaterial : selectedResinMaterial
    }

    /// Choose a material for the current process.
    public func selectMaterial(_ name: String) {
        switch process {
        case .fdm: selectedFDMMaterial = name
        case .resin: selectedResinMaterial = name
        }
    }

    /// Materials available for a given process (its category), for the in-workspace
    /// material picker (only same-category materials are offered).
    public func materials(for process: ProcessKind) -> [MaterialOption] {
        process == .fdm ? fdmMaterials : resinMaterials
    }

    /// The yield strength (MPa) of a material by name, for the M7.viz.1 stress legend
    /// / scale. 0 when the material isn't loaded (materials.json missing or a stale
    /// name), which the results screen treats as "no limit" → relative-scale fallback.
    public func yieldStrengthMPa(for materialName: String) -> Double {
        materialsByName[materialName]?.yieldStrengthMPa ?? 0
    }

    /// Rename the open project (tap the title). Updates the recents grid + persists.
    public func renameCurrentProject(to newName: String) {
        guard let project else { return }
        renameRecent(id: project.id, to: newName)
    }

    /// Rename any recent (from the open workspace title or the Library card menu).
    /// Updates the live project if loaded, the recents grid, and the on-disk snapshot.
    public func renameRecent(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateRecent(id: id) {
            RecentProject(id: $0.id, name: trimmed, materialName: $0.materialName,
                          process: $0.process, optimized: $0.optimized)
        }
        if let pm = projectsById[id] {
            pm.name = trimmed
            if project?.id == id { projectName = trimmed }
            persist(pm)
        } else if var snap = store.snapshot(id: id) {
            snap.name = trimmed
            try? store.save(snap)   // model already copied — snapshot-only rewrite
        }
    }

    /// Change the open project's material (within its category). Updates recents + persists.
    public func setCurrentProjectMaterial(_ material: String) {
        guard let project else { return }
        project.material = material
        updateRecent(id: project.id) {
            RecentProject(id: $0.id, name: $0.name, materialName: material,
                          process: $0.process, optimized: $0.optimized)
        }
        persistCurrentProject()
    }

    /// Flag a project as optimized (called when its run produces accepted variants):
    /// flips the Library status chip and persists the flag.
    public func markOptimized(_ id: UUID) {
        guard let idx = recentProjects.firstIndex(where: { $0.id == id }),
              !recentProjects[idx].optimized else { return }
        recentProjects[idx].optimized = true
        if let pm = projectsById[id] { persist(pm) }
    }

    /// Render + cache a Library thumbnail for a project from its imported mesh.
    /// No-op when there's no mesh or Metal is unavailable (frosted fallback shows).
    private func generateThumbnail(for id: UUID, mesh: ViewerMesh?) {
        guard let mesh, thumbnails[id] == nil,
              let image = MeshThumbnail.cgImage(for: mesh) else { return }
        thumbnails[id] = image
    }

    /// Track a live project's run phase so the Library reflects background runs:
    /// `runningIDs` gains/loses the id, and finishing with results marks it optimized.
    private func observeRun(_ pm: ProjectModel) {
        guard runCancellables[pm.id] == nil else { return }
        runCancellables[pm.id] = pm.run.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak pm] phase in
                guard let self, let pm else { return }
                if phase == .running {
                    self.runningIDs.insert(pm.id)
                } else {
                    self.runningIDs.remove(pm.id)
                    if pm.hasResults { self.markOptimized(pm.id) }
                }
            }
    }

    private func updateRecent(id: UUID, _ transform: (RecentProject) -> RecentProject) {
        if let idx = recentProjects.firstIndex(where: { $0.id == id }) {
            recentProjects[idx] = transform(recentProjects[idx])
        }
    }

    // MARK: - Import sheet lifecycle

    /// Open the import sheet for a new project. Clears any prior draft file but
    /// keeps the loaded materials and their default selections.
    public func newTopOpt() {
        importedFile = nil
        importedMesh = nil
        minimizePlastic = true   // reset the draft toggle to the default
        quality = .fast
        importSheetPresented = true
    }

    /// Dismiss the import sheet without starting a project.
    public func cancelImport() {
        importSheetPresented = false
    }

    /// Import a picked model file at `path`. On success (a watertight mesh) it
    /// becomes `importedFile`; a non-watertight or unreadable file is rejected and
    /// the core diagnostic is surfaced in a toast (ROADMAP M7.3).
    /// - Returns: true if the file was accepted.
    @discardableResult
    public func importFile(atPath path: String, displayName: String? = nil) -> Bool {
        let name = displayName ?? (path as NSString).lastPathComponent
        let mesh: ImportedMesh
        do {
            mesh = try importer(path)
        } catch {
            // Hard failure from the core (unreadable / unparseable / STEP without
            // OCCT): surface its diagnostic verbatim.
            importedFile = nil
            importedMesh = nil
            toast = "\(name): \(error)"
            return false
        }
        guard mesh.watertight else {
            // Parses but is open / non-manifold — the core cannot optimize it.
            importedFile = nil
            importedMesh = nil
            toast = "“\(name)” isn’t watertight (open or non-manifold surface). "
                  + "TopOpt needs a closed solid — repair the mesh and re-import."
            return false
        }
        importedFile = ImportedFile(name: name, path: path,
                                    triangleCount: mesh.triangleCount,
                                    faceCount: mesh.faceCount,
                                    watertight: mesh.watertight)
        importedMesh = mesh
        return true
    }

    /// Whether Continue is enabled: a watertight file is imported and a material
    /// for the current process is selected.
    public var canContinue: Bool {
        importedFile != nil && selectedMaterial != nil
    }

    /// Confirm the import sheet: record a recent project and enter the workspace.
    /// No-op (with a nudge toast) if `canContinue` is false.
    public func continueToWorkspace() {
        guard let file = importedFile, let material = selectedMaterial else {
            toast = "Import a model and choose a material to continue."
            return
        }
        let name = projectDisplayName(from: file.name)
        let recent = RecentProject(name: name, materialName: material, process: process)
        // Build the project's live working state and key it by the recent's id so
        // returning to it from Home restores the full setup (M7.x-persist-a).
        let pm = ProjectModel(id: recent.id, name: name, material: material,
                              process: process, importedFile: file, importedMesh: importedMesh)
        pm.minimizePlastic = minimizePlastic
        pm.quality = quality
        projectsById[recent.id] = pm
        project = pm
        recentProjects.insert(recent, at: 0)
        generateThumbnail(for: recent.id, mesh: pm.viewerMesh)
        observeRun(pm)
        projectName = name
        importSheetPresented = false
        screen = .workspace
        persist(pm)   // copy the model into the store + write the initial snapshot (persist-b)
    }

    // MARK: - Recents / navigation

    /// Open a recent project into the workspace. Its live state this launch is
    /// restored intact; otherwise it is rebuilt from disk (re-importing the copied
    /// model); a recent with neither opens an empty workspace for its material.
    public func open(_ recent: RecentProject) {
        projectName = recent.name
        process = recent.process
        selectMaterial(recent.materialName)
        if let pm = projectsById[recent.id] {
            project = pm
        } else if let restored = restoreFromDisk(recent) {
            projectsById[recent.id] = restored
            project = restored
        } else {
            project = ProjectModel(id: recent.id, name: recent.name,
                                   material: recent.materialName, process: recent.process,
                                   importedFile: nil, importedMesh: nil)
            projectsById[recent.id] = project
        }
        generateThumbnail(for: recent.id, mesh: project?.viewerMesh)
        if let pm = projectsById[recent.id] { observeRun(pm) }
        screen = .workspace
    }

    /// Return to Home from the workspace, saving the project's current state first.
    public func backHome() {
        persistCurrentProject()
        screen = .home
    }

    // MARK: - Persistence (M7.x-persist-b)

    /// Write the current project's latest state to disk. Called on leaving the
    /// workspace and from the app's scene-phase → background hook, so edits survive
    /// relaunch even without navigating Home. No-op if there is no persistable
    /// project (e.g. an empty/legacy one with no model).
    public func persistCurrentProject() {
        guard let project else { return }
        persist(project)
    }

    /// Save one project (copy its model into the store on first save, write the
    /// snapshot) and refresh its recents entry. Failures are surfaced as a toast but
    /// never crash the flow.
    private func persist(_ project: ProjectModel) {
        guard let snapshot = project.snapshot(savedAt: now()) else { return }
        do {
            try store.save(snapshot, modelSource: project.modelSourceURL)
        } catch {
            toast = "Couldn’t save “\(project.name)”: \(error.localizedDescription)"
        }
        // Once a project has results, reflect it in its Library card ("Optimized")
        // and persist the full outcome (variants + playback keyframes) so it
        // survives an app relaunch (persist-c). Encode + write off the main thread.
        if project.hasResults, let outcome = project.run.outcome {
            if let idx = recentProjects.firstIndex(where: { $0.id == project.id }),
               !recentProjects[idx].optimized {
                recentProjects[idx].optimized = true
            }
            let dto = OutcomeCodec.dto(from: outcome)
            let url = store.resultsURL(id: project.id)
            let dir = url.deletingLastPathComponent()
            Self.resultsQueue.async {
                guard let data = try? OutcomeCodec.encode(dto) else { return }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Rebuild a project from its on-disk snapshot, re-importing the copied model.
    /// Returns nil if there is no snapshot or the re-import fails (the caller falls
    /// back to an empty workspace).
    private func restoreFromDisk(_ recent: RecentProject) -> ProjectModel? {
        guard let snap = store.snapshot(id: recent.id) else { return nil }
        let path = store.modelPath(id: snap.id, fileName: snap.modelFileName)
        guard let mesh = try? importer(path) else { return nil }
        let file = ImportedFile(name: snap.originalFileName, path: path,
                                triangleCount: mesh.triangleCount, faceCount: mesh.faceCount,
                                watertight: mesh.watertight)
        let pm = ProjectModel(restoring: snap, importedFile: file, importedMesh: mesh)
        // persist-c: if this project had results, load them (variants + playback)
        // off-main and drop them into the idle run so results reopen instantly.
        if snap.optimized == true {
            let url = store.resultsURL(id: snap.id)
            Self.resultsQueue.async {
                guard let data = try? Data(contentsOf: url),
                      let outcome = try? OutcomeCodec.decode(data) else { return }
                DispatchQueue.main.async { pm.run.restoreOutcome(outcome) }
            }
        }
        return pm
    }

    // MARK: - internals

    /// Turn a file name into a project title: drop the extension and swap common
    /// separators for spaces (e.g. `Wall_Bracket_v4.step` → "Wall Bracket v4").
    private func projectDisplayName(from fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let spaced = base.replacingOccurrences(of: "_", with: " ")
                         .replacingOccurrences(of: "-", with: " ")
        let trimmed = spaced.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? base : trimmed
    }
}

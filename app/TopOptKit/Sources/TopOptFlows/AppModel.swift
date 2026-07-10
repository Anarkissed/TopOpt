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

    // MARK: Recents + toast

    @Published public private(set) var recentProjects: [RecentProject] = []
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
            RecentProject(id: $0.id, name: $0.name, materialName: $0.material, process: $0.process)
        }
    }

    /// Assemble the inputs `minimize_plastic` needs for the M7.7 run, or nil if a
    /// file / material / config path is missing (Optimize is gated on these, so nil
    /// only happens if wiring is incomplete).
    public func makeRunRequest(resolution: Int) -> RunRequest? {
        guard let project, let file = project.importedFile,
              let materialsPath, let rulesPath else { return nil }
        return RunRequest(modelPath: file.path, material: project.material,
                          materialsPath: materialsPath, rulesPath: rulesPath,
                          resolution: resolution,
                          projectName: project.name.isEmpty ? file.name : project.name)
    }

    // MARK: - Materials

    /// Load and split materials.json by family. Called on first appearance. On a
    /// load error the dropdowns stay empty and the diagnostic is toasted.
    public func loadMaterials() {
        guard let materialsPath else { return }
        do {
            let mats = try materialsLoader(materialsPath)
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

    // MARK: - Import sheet lifecycle

    /// Open the import sheet for a new project. Clears any prior draft file but
    /// keeps the loaded materials and their default selections.
    public func newTopOpt() {
        importedFile = nil
        importedMesh = nil
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
        projectsById[recent.id] = pm
        project = pm
        recentProjects.insert(recent, at: 0)
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
        return ProjectModel(restoring: snap, importedFile: file, importedMesh: mesh)
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

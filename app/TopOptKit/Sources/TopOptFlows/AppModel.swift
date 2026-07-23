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
    /// Whether the M7.params print-parameters sheet is presented over the workspace.
    @Published public private(set) var printParamsSheetPresented = false
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
    /// Handoff 134 — the pending unit question for a just-picked MESH file
    /// (STL/3MF carry no reliable unit). Non-nil presents the unit sheet; the
    /// file is not imported until it is answered.
    @Published public internal(set) var pendingUnitPrompt: ImportUnitPrompt?
    /// Handoff 134 — a refused import, presented as a plain-language sheet
    /// instead of a toast. Non-nil presents the refusal sheet.
    @Published public internal(set) var importRefusal: ImportRefusal?
    /// What the importer repaired on the accepted file (weld / re-orient /
    /// dropped empties), shown as a note on the import row. Nil when nothing
    /// was changed or the part came from STEP.
    @Published public private(set) var importRepairNote: String?
    /// The file waiting on `pendingUnitPrompt`'s answer. Not published — it is
    /// bookkeeping, not view state.
    private var pendingUnitPath: String?
    /// That file's inspection, carried forward so `importFile` neither re-parses
    /// the mesh nor — after a unit rescale — reports the repairs of the CLEAN
    /// rewritten copy instead of the user's original.
    private var pendingDiagnostics: PartDiagnostics?

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

    // MARK: Cold-launch remote re-attach (handoff 119)

    /// Remote jobs that were still outstanding when the app last died (read from the
    /// MULTI-SLOT `RemoteJobStore` at launch, handoff 121). Drives the Home re-attach
    /// UI: the 119 incident was a 7-hour run whose relaunched client had NO path back
    /// to the still-solving Mac; 121 generalises it to MORE THAN ONE outstanding job
    /// (a queued sibling, or two projects' runs) — the banner becomes a list when >1.
    /// A job is removed from the list when the user re-attaches or dismisses it.
    @Published public private(set) var pendingReattachJobs: [PersistedRemoteJob] = []

    /// Back-compat convenience: the first outstanding job (drives a single banner).
    public var pendingReattach: PersistedRemoteJob? { pendingReattachJobs.first }

    // MARK: Print-parameter presets (M7.params — app-wide named presets)

    /// The user's saved print-parameter presets (app-level, shared by every project).
    /// The built-in "Default" is NOT in here — `allPresets` synthesizes it as the
    /// first entry so it always exists. Loaded from `presetStore` on launch.
    @Published public private(set) var savedPresets: [PrintParamsPreset] = []

    /// Every preset offered in the sheet's picker: the built-in "Default" first, then
    /// the user's saved presets in save order.
    public var allPresets: [PrintParamsPreset] {
        [.builtInDefault] + savedPresets
    }

    // MARK: Dependencies (injected for tests; default to the real bridge)

    private let materialsPath: String?
    private let rulesPath: String?
    private let materialsLoader: (String) throws -> [Material]
    private let importer: (String) throws -> ImportedMesh
    /// Handoff 134 — structured mesh inspection (the refusal sheet's source of
    /// truth) and the unit rescaler. Injected together with `importer` so the
    /// whole import flow is drivable headlessly.
    private let inspector: (String) throws -> PartDiagnostics
    private let rescaler: (String, String, Double) throws -> Void
    /// Cross-launch persistence layer (M7.x-persist-b) and the clock used for
    /// `savedAt` (injected for deterministic tests).
    private let store: ProjectStore
    /// App-wide print-preset persistence (separate from per-project `store`).
    private let presetStore: PrintParamsPresetStore
    private let now: () -> Date
    /// Where the active-remote-job record lives (handoff 119). Injected so tests use a
    /// scratch suite; production reads/clears the real `UserDefaults.standard` that
    /// `RemoteRun` wrote at submit time.
    private let remoteJobDefaults: UserDefaults
    /// Builds the runner that re-attaches to an existing job. Injected so tests drive
    /// the flow with a stub (the real one streams the worker's `/events`); nil → the
    /// production `RunModel.remoteReattachRunner`.
    private let reattachRunnerFactory: ((RemoteRunnerConfig, String) -> RunModel.Runner)?

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
        inspector: @escaping (String) throws -> PartDiagnostics = { try TopOptKit.inspectPart(path: $0) },
        rescaler: @escaping (String, String, Double) throws -> Void = {
            try TopOptKit.rescalePart(from: $0, to: $1, scale: $2)
        },
        store: ProjectStore = ProjectStore(),
        presetStore: PrintParamsPresetStore = PrintParamsPresetStore(),
        now: @escaping () -> Date = { Date() },
        remoteJobDefaults: UserDefaults = .standard,
        reattachRunnerFactory: ((RemoteRunnerConfig, String) -> RunModel.Runner)? = nil
    ) {
        self.materialsPath = materialsPath
        self.rulesPath = rulesPath
        self.materialsLoader = materialsLoader
        self.importer = importer
        self.inspector = inspector
        self.rescaler = rescaler
        self.store = store
        self.presetStore = presetStore
        self.now = now
        self.remoteJobDefaults = remoteJobDefaults
        self.reattachRunnerFactory = reattachRunnerFactory
        // App-wide print presets survive relaunch (loaded once; Default is synthesized).
        savedPresets = presetStore.load()
        // Seed the recents grid from disk (lazy: projects are re-imported only when
        // opened). persist-b.
        recentProjects = store.loadAllSnapshots().map {
            RecentProject(id: $0.id, name: $0.name, materialName: $0.material,
                          process: $0.process, optimized: $0.optimized ?? false)
        }
        // Cold-launch re-attach (handoffs 119 + 121): surface EVERY remote job still
        // outstanding when the app last died. `RemoteRun` removes a job's record on its
        // terminal resolution or user cancel, so leftover records mean the app died
        // with those runs still in flight. `loadAll` also migrates a pre-121 single-slot
        // record on first read.
        pendingReattachJobs = RemoteJobStore.loadAll(defaults: remoteJobDefaults)
    }

    /// Assemble the inputs `minimize_plastic` needs for the M7.7 run, or nil if a
    /// file / material / config path is missing (Optimize is gated on these, so nil
    /// only happens if wiring is incomplete).
    public func makeRunRequest() -> RunRequest? {
        guard let project, let file = project.importedFile,
              let materialsPath, let rulesPath else { return nil }
        let lc = project.loadCase()
        let protections = project.faceProtectionSpecs()
        return RunRequest(modelPath: file.path, material: project.material,
                          materialsPath: materialsPath, rulesPath: rulesPath,
                          resolution: project.quality.resolution,
                          projectName: project.name.isEmpty ? file.name : project.name,
                          anchorFaceIDs: lc.anchorFaceIDs, loadGroups: lc.loadGroups,
                          minimizePlastic: project.minimizePlastic,
                          buildDirection: lc.buildDirection,
                          infillPercent: project.printParams.infillPercent,
                          designBox: project.designBox.bridgeBox,
                          keepOutBoxes: project.designBox.bridgeKeepOuts,
                          clearances: project.clearanceSpecs(),
                          faceProtections: protections.faceIDs,
                          faceProtectionDepthMM: protections.depthMM,
                          projectID: project.id)
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

    /// The density (g/cm³) of a material by name, for the results-screen STL export's
    /// honest mesh mass (handoff 105 / Open #6). 0 when the material isn't loaded — the
    /// export then falls back to resolving density from the bundled materials.json, and
    /// finally to a voxel-only mass. Provided so a future `ResultsScreen` call site can
    /// thread density in directly (`materialDensityGCm3:`), matching `yieldStrengthMPa`.
    public func densityGCm3(for materialName: String) -> Double {
        materialsByName[materialName]?.densityGCm3 ?? 0
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

    // MARK: - Print parameters sheet (M7.params)

    /// Present the print-parameters sheet over the workspace. No-op without an open
    /// project (there's nothing to edit). After project creation the sheet is
    /// READ-ONLY (`project.paramsLocked`): print parameters are set once, at import,
    /// and fixed for the life of the project — reopening it just shows the committed
    /// values so the user can review what this project was built at.
    public func openPrintParams() {
        guard project != nil else { return }
        printParamsSheetPresented = true
    }

    /// Dismiss the print-parameters sheet. During creation (the auto-presented sheet,
    /// `paramsLocked == false`) this COMMITS the chosen parameters: clamp to sane FDM
    /// bounds (the numeric fields let a user type anything), persist, and LOCK them for
    /// the life of the project — to use different parameters the user creates a new
    /// project. Reopening a locked project's sheet is read-only, so a Done there is a
    /// harmless no-op re-persist. Called on Done and on scrim-dismiss alike.
    public func closePrintParams() {
        if let project {
            project.printParams = project.printParams.clamped()
            project.paramsLocked = true
        }
        printParamsSheetPresented = false
        persistCurrentProject()
    }

    // MARK: - Print-parameter presets (M7.params — app-wide named presets)

    /// Save the given parameters as a new named preset, persisted app-wide so it is
    /// offered to every project. A blank name is ignored. The values are clamped to
    /// sane FDM bounds first (a preset is only ever as valid as a committed project).
    /// - Returns: the saved preset, or nil if the name was blank.
    @discardableResult
    public func savePreset(named name: String, params: PrintParams) -> PrintParamsPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let preset = PrintParamsPreset(name: trimmed, params: params.clamped())
        savedPresets.append(preset)
        do {
            try presetStore.save(savedPresets)
        } catch {
            toast = "Couldn’t save preset “\(trimmed)”: \(error.localizedDescription)"
        }
        return preset
    }

    /// Load a preset's values into the open project's (still-editable) print
    /// parameters. No-op once the project's parameters are locked (post-creation) —
    /// presets are a setup-time convenience, not a way around the lock.
    public func applyPreset(_ preset: PrintParamsPreset) {
        guard let project, !project.paramsLocked else { return }
        project.printParams = preset.params
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
        importRepairNote = nil
        pendingUnitPrompt = nil
        pendingUnitPath = nil
        pendingDiagnostics = nil
        importRefusal = nil
        minimizePlastic = true   // reset the draft toggle to the default
        quality = .fast
        importSheetPresented = true
    }

    /// Dismiss the import sheet without starting a project.
    public func cancelImport() {
        importSheetPresented = false
        pendingUnitPrompt = nil
        pendingUnitPath = nil
        pendingDiagnostics = nil
        importRefusal = nil
    }

    /// Handle a picked file (handoff 134). This is the entry point the picker
    /// calls; it decides whether to import straight away, ask the unit
    /// question first, or refuse.
    ///
    /// A STEP file carries its own unit and its own faces, so it imports
    /// directly — that path is unchanged. A MESH file (STL/3MF) is inspected
    /// first: a structural problem raises the refusal sheet, and a clean mesh
    /// raises the unit question, because neither format carries a unit the core
    /// can trust.
    public func pickedFile(atPath path: String, displayName: String? = nil) {
        let name = displayName ?? (path as NSString).lastPathComponent
        let lower = path.lowercased()
        let isSTEP = lower.hasSuffix(".step") || lower.hasSuffix(".stp")
        if isSTEP {
            importFile(atPath: path, displayName: name)
            return
        }
        do {
            let d = try inspector(path)
            guard d.acceptable else {
                importedFile = nil
                importedMesh = nil
                importRefusal = ImportRefusal(fileName: name, diagnostics: d,
                                              rawMessage: "")
                return
            }
            // Clean mesh: ask what its numbers mean before importing.
            pendingUnitPrompt = ImportUnitPrompt(fileName: name, diagnostics: d)
            pendingUnitPath = path
            pendingDiagnostics = d
        } catch {
            // Could not be read or parsed at all — no structured verdict exists.
            importedFile = nil
            importedMesh = nil
            importRefusal = ImportRefusal(fileName: name, diagnostics: nil,
                                          rawMessage: "\(error)")
        }
    }

    /// Answer the unit question and import (handoff 134).
    ///
    /// Millimetres imports the file as-is. Any other unit writes a RESCALED
    /// working copy and imports that, so every later stateless core call —
    /// tagging, masking, clearance, the optimizer, a remote run — re-reads a
    /// file that is already in millimetres. That is why no unit has to be
    /// threaded through the bridge, the job schema or persistence.
    @discardableResult
    public func resolveUnits(_ unit: PartUnit) -> Bool {
        guard let path = pendingUnitPath, let prompt = pendingUnitPrompt else { return false }
        pendingUnitPrompt = nil
        pendingUnitPath = nil
        // The ORIGINAL file's verdict: a rescale rewrites a clean, already-welded
        // STL, so inspecting the copy would report no repairs and understate what
        // was actually fixed in the user's file.
        let original = pendingDiagnostics
        pendingDiagnostics = nil

        var importPath = path
        if unit != .millimetres {
            let base = (prompt.fileName as NSString).deletingPathExtension
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(base)_mm.stl").path
            do {
                try rescaler(path, dst, unit.scaleToMM)
                importPath = dst
            } catch {
                importRefusal = ImportRefusal(fileName: prompt.fileName, diagnostics: nil,
                                              rawMessage: "\(error)")
                return false
            }
        }
        return importFile(atPath: importPath, displayName: prompt.fileName,
                          diagnostics: original)
    }

    /// Abandon the unit question without importing.
    public func cancelUnitPrompt() {
        pendingUnitPrompt = nil
        pendingUnitPath = nil
        pendingDiagnostics = nil
    }

    /// Dismiss the refusal sheet. The import sheet stays open so the user can
    /// pick a different file.
    public func dismissRefusal() {
        importRefusal = nil
    }

    /// Import a picked model file at `path`. On success (a watertight mesh) it
    /// becomes `importedFile`; a non-watertight or unreadable file is rejected and
    /// the core diagnostic is surfaced in a toast (ROADMAP M7.3).
    ///
    /// Handoff 134: still the direct path for STEP, and the tail of the mesh
    /// flow once units are settled. A mesh reaching here has already been
    /// inspected, so the watertight guard below is now a backstop rather than
    /// the primary gate.
    /// - Parameter diagnostics: the inspection already performed on this file by
    ///   `pickedFile`, so the mesh is not parsed a second time. Nil re-inspects
    ///   (the direct/STEP path).
    /// - Returns: true if the file was accepted.
    @discardableResult
    public func importFile(atPath path: String, displayName: String? = nil,
                           diagnostics: PartDiagnostics? = nil) -> Bool {
        let name = displayName ?? (path as NSString).lastPathComponent
        let mesh: ImportedMesh
        do {
            mesh = try importer(path)
        } catch {
            // Hard failure from the core (unreadable / unparseable / STEP without
            // OCCT): surface its diagnostic verbatim.
            importedFile = nil
            importedMesh = nil
            importRepairNote = nil
            toast = "\(name): \(error)"
            return false
        }
        guard mesh.watertight else {
            // Parses but is open / non-manifold — the core cannot optimize it.
            importedFile = nil
            importedMesh = nil
            importRepairNote = nil
            toast = "“\(name)” isn’t watertight (open or non-manifold surface). "
                  + "TopOpt needs a closed solid — repair the mesh and re-import."
            return false
        }
        importedFile = ImportedFile(name: name, path: path,
                                    triangleCount: mesh.triangleCount,
                                    faceCount: mesh.faceCount,
                                    watertight: mesh.watertight,
                                    pseudoFaces: mesh.pseudoFaces)
        importedMesh = mesh
        // Say what was repaired, if anything. Best-effort: a failure here must
        // not fail an otherwise-good import.
        importRepairNote = (diagnostics ?? (try? inspector(path)))
            .flatMap { ImportRepairNote.text(for: $0) }
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
        // Unlocked so the auto-presented creation sheet is editable once; it locks on
        // dismiss (closePrintParams), fixing the parameters for the project's life.
        let pm = ProjectModel(id: recent.id, name: name, material: material,
                              process: process, importedFile: file, importedMesh: importedMesh,
                              paramsLocked: false)
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
        // M7.params (b): a freshly imported model prompts for its print parameters as
        // it enters the workspace. The sheet auto-presents over the new workspace
        // (project is set, so `openPrintParams` presents); Done/scrim persist it.
        openPrintParams()
    }

    // MARK: - Deletion

    /// Delete a project from Home (Library card menu). Cancels any in-flight run,
    /// drops all in-memory state (the live model, its thumbnail, run observation and
    /// running flag), removes it from the recents grid, and erases its on-disk folder
    /// — the JSON snapshot, the copied model file, AND the persisted optimize results
    /// (`ProjectStore.delete` removes the whole project directory). If the project
    /// being deleted is the one currently open, returns to Home first. Safe for an id
    /// that was never loaded this launch (only the on-disk folder + recents entry).
    public func deleteProject(id: UUID) {
        if let pm = projectsById[id] { pm.run.cancel() }
        runCancellables[id]?.cancel()
        runCancellables[id] = nil
        runningIDs.remove(id)
        if project?.id == id {
            project = nil
            projectName = ""
            printParamsSheetPresented = false
            screen = .home
        }
        projectsById[id] = nil
        thumbnails[id] = nil
        recentProjects.removeAll { $0.id == id }
        store.delete(id: id)
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
    /// Also dismisses the print-parameters sheet if it was up (the workspace back
    /// affordance is behind the sheet's scrim in normal use, but keep the invariant
    /// that the sheet never outlives the workspace).
    public func backHome() {
        if printParamsSheetPresented { closePrintParams() }
        persistCurrentProject()
        screen = .home
    }

    // MARK: - Cold-launch remote re-attach (handoff 119)

    /// The banner copy for a pending re-attach: names the age and the worker (and the
    /// project, when known). Pure + static so it is unit-tested without a view or the
    /// wall clock. Example: "A run for Bracket, started about 7 hours ago, may still
    /// be running on 10.0.0.4. Re-attach to follow it and get the result."
    public static func reattachBannerText(for job: PersistedRemoteJob, now: Date = Date()) -> String {
        let subject = job.projectName.map { "A run for “\($0)”" } ?? "A remote run"
        let age = job.submittedAt.map { ", started \(relativeAge(now.timeIntervalSince($0)))," } ?? ""
        return "\(subject)\(age) may still be running on \(job.host). "
             + "Re-attach to follow it and get the result."
    }

    /// A coarse, locale-independent age phrase (so the banner copy is deterministic in
    /// tests). "just now" / "N min ago" / "about N hour(s) ago" / "about N day(s) ago".
    static func relativeAge(_ seconds: TimeInterval) -> String {
        let s = Swift.max(0, seconds)
        if s < 60 { return "just now" }
        let minutes = Int(s / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int(s / 3600)
        if hours < 24 { return "about \(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = Int(s / 86_400)
        return "about \(days) day\(days == 1 ? "" : "s") ago"
    }

    /// Re-attach to the pending remote job: reopen the project it belonged to and
    /// stream the worker's existing job (`remoteReattachRunner`) into that project's
    /// run. A still-running job resumes live; a job that COMPLETED while the app was
    /// gone has its full outcome replayed and lands on results; a dead/unknown job
    /// fails with the honest 101 worker-unreachable message. The persisted record is
    /// NOT cleared here — only a worker-terminal resolution (inside `RemoteRun`) or an
    /// explicit Dismiss clears it, so a failed re-attach can be retried next launch.
    public func reattach() {
        guard let job = pendingReattach else { return }
        reattach(job)
    }

    /// Re-attach to ONE specific outstanding job (handoff 121: the list may hold
    /// several). Spends just that job's banner entry, leaving any others.
    public func reattach(_ job: PersistedRemoteJob) {
        pendingReattachJobs.removeAll { $0.jobID == job.jobID }
        // Reopen the owning project so the stream lands in the normal workspace →
        // results flow. If it can't be resolved (no id, or it was deleted) there is
        // nowhere to host the result: say so honestly and leave the record for a
        // Dismiss (never silently drop it).
        guard let recent = job.projectID.flatMap({ id in recentProjects.first { $0.id == id } }) else {
            toast = "Couldn’t reopen the project for the run on \(job.host) — it may have been deleted."
            return
        }
        open(recent)
        guard let project else {
            toast = "Couldn’t reopen the project for the run on \(job.host)."
            return
        }
        let config = RemoteRunnerConfig(host: job.host, port: job.port,
                                        expectedFingerprint: job.fingerprint)
        project.run.runner = reattachRunnerFactory?(config, job.jobID)
            ?? RunModel.remoteReattachRunner(config, jobID: job.jobID, defaults: remoteJobDefaults)
        // A re-attach is a REMOTE run — RemoteRun owns its liveness, so it must not arm
        // the local setup-stall watchdog (handoff 129).
        project.run.start(reattachRequest(for: job, project: project), remote: true)
        // Anchor the elapsed clock to when the run BEGAN, not to this moment (handoff
        // 134): a re-attached run is not a new run, and a readout that restarts at
        // 0:00 understates a solve that has been going since last night exactly as
        // badly as a `now()`-derived summary overstates one.
        if let began = job.submittedAt { project.run.anchorElapsed(to: began) }
    }

    /// Dismiss the re-attach offer (back-compat single-banner path). Clears the
    /// persisted record(s) even after `reattach()` already spent the visible banner —
    /// the pre-121 contract was "Dismiss is the only user clear" and it always cleared.
    public func dismissReattach() {
        dismissAllReattach()
    }

    /// Dismiss ONE re-attach offer: the user's action removes just that job's
    /// persisted record (handoff 119 / the 101 rule that a client-side path never
    /// destroys the Mac's job — only the user does). Other outstanding jobs survive.
    public func dismissReattach(_ job: PersistedRemoteJob) {
        RemoteJobStore.remove(jobID: job.jobID, defaults: remoteJobDefaults)
        pendingReattachJobs.removeAll { $0.jobID == job.jobID }
    }

    /// Dismiss every outstanding re-attach offer at once (the list's "Dismiss all").
    public func dismissAllReattach() {
        RemoteJobStore.clear(defaults: remoteJobDefaults)
        pendingReattachJobs = []
    }

    /// Ask the worker to move a still-QUEUED job to the front of its queue (handoff
    /// 121, requirement 6): a quick Balanced check shouldn't wait behind an 8-hour
    /// Fine run. Best-effort and fire-and-forget — the worker no-ops if the job is
    /// already running (a running job is never preempted). A network failure is
    /// silent (the record stays; the user can retry).
    public func moveReattachJobToFront(_ job: PersistedRemoteJob) {
        guard let url = URL(string: "http://\(job.host):\(job.port)/jobs/\(job.jobID)/front")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            Task { @MainActor in self?.toast = "Asked the Mac to run “\(job.projectName ?? "this job")” next." }
        }.resume()
    }

    /// The request the re-attach run starts with. `remoteReattachRunner` skips submit,
    /// so the request's optimization inputs are unused for streaming — but it still
    /// carries the project id/name so a re-save keeps the record's routing metadata.
    /// Prefer the project's real request; fall back to a minimal carrier.
    private func reattachRequest(for job: PersistedRemoteJob, project: ProjectModel) -> RunRequest {
        if let real = makeRunRequest() { return real }
        return RunRequest(modelPath: project.importedFile?.path ?? "",
                          material: project.material,
                          materialsPath: materialsPath ?? "", rulesPath: rulesPath ?? "",
                          resolution: project.quality.resolution,
                          projectName: job.projectName ?? project.name,
                          projectID: job.projectID ?? project.id)
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
        // `pseudoFaces` is re-derived from the re-import rather than persisted:
        // it is a property of the FILE, so the reopened project must say the same
        // thing the original import said (handoff 134 — without this a reopened
        // STL project would claim its faces came from a B-rep).
        let file = ImportedFile(name: snap.originalFileName, path: path,
                                triangleCount: mesh.triangleCount, faceCount: mesh.faceCount,
                                watertight: mesh.watertight, pseudoFaces: mesh.pseudoFaces)
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

    // MARK: - test support (handoff 119)

    /// Preload a live project + its recents entry so a re-attach test can resolve the
    /// project WITHOUT disk IO and drive its run synchronously (the project's injected
    /// RunModel uses a synchronous scheduler). Internal; never used by production.
    func testSeedLiveProject(_ pm: ProjectModel, recent: RecentProject) {
        projectsById[pm.id] = pm
        if !recentProjects.contains(where: { $0.id == recent.id }) {
            recentProjects.insert(recent, at: 0)
        }
        observeRun(pm)
    }
}

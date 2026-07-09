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

    // MARK: Import draft (valid only while the sheet is open)

    /// The chosen print process; selects the material family offered.
    @Published public var process: ProcessKind = .fdm
    /// Selected material name per family (kept independently so switching the
    /// segment restores the family's own choice).
    @Published public private(set) var selectedFDMMaterial: String?
    @Published public private(set) var selectedResinMaterial: String?
    /// The successfully-imported (watertight) file, or nil until one is picked.
    @Published public private(set) var importedFile: ImportedFile?

    // MARK: Materials (loaded once from the bundle via the bridge)

    @Published public private(set) var fdmMaterials: [MaterialOption] = []
    @Published public private(set) var resinMaterials: [MaterialOption] = []

    // MARK: Recents + toast

    @Published public private(set) var recentProjects: [RecentProject] = []
    /// Non-nil shows a transient toast (the design pill); the view clears it.
    @Published public var toast: String?

    // MARK: Dependencies (injected for tests; default to the real bridge)

    private let materialsPath: String?
    private let materialsLoader: (String) throws -> [Material]
    private let importer: (String) throws -> ImportedMesh

    /// - Parameters:
    ///   - materialsPath: path to materials.json (defaults to the app bundle's
    ///     copy; nil leaves the dropdowns empty until `loadMaterials` is given one).
    ///   - materialsLoader: injectable loader (defaults to `TopOptKit.loadMaterials`).
    ///   - importer: injectable mesh import (defaults to `TopOptKit.importMesh`).
    public init(
        materialsPath: String? = Bundle.main.path(forResource: "materials", ofType: "json"),
        materialsLoader: @escaping (String) throws -> [Material] = { try TopOptKit.loadMaterials(path: $0) },
        importer: @escaping (String) throws -> ImportedMesh = { try TopOptKit.importMesh(path: $0) }
    ) {
        self.materialsPath = materialsPath
        self.materialsLoader = materialsLoader
        self.importer = importer
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
            toast = "\(name): \(error)"
            return false
        }
        guard mesh.watertight else {
            // Parses but is open / non-manifold — the core cannot optimize it.
            importedFile = nil
            toast = "“\(name)” isn’t watertight (open or non-manifold surface). "
                  + "TopOpt needs a closed solid — repair the mesh and re-import."
            return false
        }
        importedFile = ImportedFile(name: name, path: path,
                                    triangleCount: mesh.triangleCount,
                                    faceCount: mesh.faceCount,
                                    watertight: mesh.watertight)
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
        let project = RecentProject(name: name, materialName: material, process: process)
        recentProjects.insert(project, at: 0)
        projectName = name
        importSheetPresented = false
        screen = .workspace
    }

    // MARK: - Recents / navigation

    /// Open a recent project into the workspace.
    public func open(_ project: RecentProject) {
        projectName = project.name
        process = project.process
        selectMaterial(project.materialName)
        screen = .workspace
    }

    /// Return to Home from the workspace.
    public func backHome() {
        screen = .home
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

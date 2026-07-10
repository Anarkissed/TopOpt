// ProjectModel.swift — the per-project working state (M7.x-persist-a).
//
// Before this, the workspace's entire setup — the render mesh, the face-selection
// groups (SelectionModel), the force/gravity load case (ForceModel), and the run —
// lived as `@State`/`@StateObject` INSIDE `WorkspacePlaceholder`, so SwiftUI
// destroyed all of it whenever the view left the hierarchy (navigate Home, open a
// recent). That was silent data loss in a multi-screen flow.
//
// ProjectModel hoists that state into a reference type OWNED BY AppModel
// (`AppModel.project` + `projectsById`), so it survives navigation for the life of
// the launch: leaving the workspace and returning to the same project restores the
// gravity vector, groups, roles, directions, and weights exactly. The workspace
// binds to this instead of owning `@State` (its call sites are unchanged — it
// forwards `selection`/`force`/`viewerMesh`/`run` to here via computed properties).
//
// Cross-LAUNCH persistence (Codable to disk + real recents + copying the imported
// model into app storage) is the separate M7.x-persist-b follow-up; this task is
// in-memory-across-navigation only. Nothing here is `Codable` yet.

import Foundation
import TopOptKit

@MainActor
public final class ProjectModel: ObservableObject {
    /// Stable identity, shared with the project's `RecentProject.id` so
    /// `AppModel.open(_:)` can restore this exact instance from the recents grid.
    public let id: UUID
    public let name: String
    public let material: String
    public let process: ProcessKind
    /// The imported file (nil for a legacy recent with no in-memory model yet).
    public let importedFile: ImportedFile?
    public let importedMesh: ImportedMesh?

    /// The working state that used to live in WorkspacePlaceholder. `@Published`
    /// value types: the workspace mutates them in place (via computed forwarders),
    /// which republishes and re-renders exactly as the old `@State` did.
    @Published public var selection = SelectionModel()
    @Published public var force = ForceModel()
    @Published public var viewerMesh: ViewerMesh?

    /// The M7.7 run state machine. One per project so a run (and its background
    /// state) survives leaving and returning to the workspace.
    public let run: RunModel

    public init(id: UUID, name: String, material: String, process: ProcessKind,
                importedFile: ImportedFile?, importedMesh: ImportedMesh?,
                run: RunModel? = nil) {
        self.id = id
        self.name = name
        self.material = material
        self.process = process
        self.importedFile = importedFile
        self.importedMesh = importedMesh
        if let m = importedMesh {
            self.viewerMesh = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs)
        }
        self.run = run ?? ProjectModel.makeRun()
    }

    /// Rebuild a project from a persisted snapshot + its re-imported model
    /// (M7.x-persist-b). The mesh is re-imported by the caller (AppModel has the
    /// importer); the selection groups + force/gravity load case come straight off
    /// the snapshot.
    public convenience init(restoring snapshot: ProjectSnapshot,
                            importedFile: ImportedFile, importedMesh: ImportedMesh,
                            run: RunModel? = nil) {
        self.init(id: snapshot.id, name: snapshot.name, material: snapshot.material,
                  process: snapshot.process, importedFile: importedFile,
                  importedMesh: importedMesh, run: run)
        self.selection = snapshot.selection
        self.force = snapshot.force
    }

    /// A persistable snapshot of this project, or nil if there is no model to copy
    /// (an empty/legacy project can't be persisted). The model file is stored under
    /// a stable `model.<ext>` name so re-import dispatches by extension.
    public func snapshot(savedAt: Date) -> ProjectSnapshot? {
        guard let file = importedFile else { return nil }
        let ext = (file.name as NSString).pathExtension.lowercased()
        let modelFileName = ext.isEmpty ? "model" : "model.\(ext)"
        return ProjectSnapshot(id: id, name: name, material: material, process: process,
                               modelFileName: modelFileName, originalFileName: file.name,
                               savedAt: savedAt, selection: selection, force: force)
    }

    /// The URL of the imported model file to copy into the store on first save.
    public var modelSourceURL: URL? {
        guard let path = importedFile?.path else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The run's notifier is the on-device local-notification one where available;
    /// tests inject their own `run`.
    private static func makeRun() -> RunModel {
        #if canImport(UserNotifications)
        return RunModel(notifier: LocalRunNotifier())
        #else
        return RunModel()
        #endif
    }
}

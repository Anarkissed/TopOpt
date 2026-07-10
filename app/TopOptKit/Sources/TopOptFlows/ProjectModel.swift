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

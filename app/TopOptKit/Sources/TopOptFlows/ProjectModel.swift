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
import Combine
import simd
import TopOptKit

@MainActor
public final class ProjectModel: ObservableObject {
    /// Stable identity, shared with the project's `RecentProject.id` so
    /// `AppModel.open(_:)` can restore this exact instance from the recents grid.
    public let id: UUID
    /// Display name — editable (tap the title to rename). Identity is `id`.
    @Published public var name: String
    /// Chosen material — editable within the project's process/category.
    @Published public var material: String
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

    /// "Minimize plastic": pursue material reduction (the variant ladder). On with
    /// no forces → self-weight removal; on with forces → removal under the forces;
    /// off with forces → one conservative force-adequate variant. Default on.
    @Published public var minimizePlastic = true
    /// Optimize resolution / speed–quality tradeoff (Fast 64³ / Balanced 96³ /
    /// Fine 128³). Default Fast.
    @Published public var quality: RunQuality = .fast

    /// The M7.params print parameters (wall loops, top/bottom shell layers, infill %,
    /// pattern, layer height) — the user's override of the M5.1 recommended slicer
    /// settings. Seeded with FDM-sensible defaults; persisted on the project. The
    /// infill % is threaded through the bridge for the M7.infill-margin ladder
    /// knockdown (see `AppModel.makeRunRequest` → `RunRequest.infillPercent`).
    @Published public var printParams: PrintParams = .fdmDefault

    /// Whether the print parameters are LOCKED (M7.params lock-at-creation). Print
    /// parameters are chosen ONCE — on the sheet that auto-presents at import — and
    /// then fixed for the life of the project; to use different ones the user creates
    /// a new project. A freshly imported project starts UNLOCKED (the creation sheet
    /// is editable) and locks when that sheet is dismissed (`AppModel.closePrintParams`);
    /// a project restored from disk or reopened is already created, so it is locked.
    /// In-memory only — a restored project is always locked regardless of what was
    /// saved, so there is nothing to persist.
    @Published public var paramsLocked: Bool

    /// The M7.7 run state machine. One per project so a run (and its background
    /// state) survives leaving and returning to the workspace.
    public let run: RunModel

    /// Whether the project has usable optimize results (≥1 accepted variant) —
    /// drives the Library card's "Optimized" status and the persisted flag.
    public var hasResults: Bool {
        run.outcome?.variants.contains { $0.accepted } ?? false
    }

    /// Forwards the run's MEANINGFUL changes (outcome + phase, NOT the per-iteration
    /// progress ticks) up to this project's `objectWillChange`, so the workspace —
    /// which observes the project, not the nested run — reliably re-renders when
    /// results stream in, a run resolves, or persisted results are restored. Without
    /// this the results overlay only refreshed incidentally (on a camera tick).
    private var runForwarding: AnyCancellable?

    /// - Parameter paramsLocked: whether print parameters start locked. Defaults to
    ///   `true` (a restored/reopened project is already created); the import flow
    ///   passes `false` so the auto-presented creation sheet is editable once.
    public init(id: UUID, name: String, material: String, process: ProcessKind,
                importedFile: ImportedFile?, importedMesh: ImportedMesh?,
                run: RunModel? = nil, paramsLocked: Bool = true) {
        self.id = id
        self.name = name
        self.material = material
        self.process = process
        self.importedFile = importedFile
        self.importedMesh = importedMesh
        self.paramsLocked = paramsLocked
        if let m = importedMesh {
            self.viewerMesh = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs)
        }
        self.run = run ?? ProjectModel.makeRun()
        // The two initial value-replays fire here during init, before any view
        // observes this object, so they're harmless no-ops.
        self.runForwarding = Publishers.Merge(
            self.run.$outcome.map { _ in () },
            self.run.$phase.map { _ in () }
        )
        .sink { [weak self] in self?.objectWillChange.send() }
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
        self.minimizePlastic = snapshot.minimizePlastic ?? true
        self.quality = snapshot.quality ?? .fast
        self.printParams = snapshot.printParams ?? .fdmDefault
    }

    /// Assemble the run's load case from the current selection + force state, in the
    /// MODEL/grid frame the solver uses: anchor groups → their B-rep faces (clamped),
    /// load groups → their faces + model-frame force (kgf → N). The build direction
    /// (print up) is the negated gravity, or +Z if gravity is unset. Empty for an
    /// STL project (no face selection) — the run then falls back to self-weight.
    public func loadCase() -> (anchorFaceIDs: [Int], loadGroups: [TopOptKit.LoadGroupSpec],
                               buildDirection: SIMD3<Double>) {
        var anchors: [Int] = []
        var loads: [TopOptKit.LoadGroupSpec] = []
        for g in selection.groups {
            let kind = force.kind(for: g.id)
            if kind.isAnchor {
                anchors.append(contentsOf: g.faces.map { Int($0) })
            } else if kind.isLoad {
                let n = groupNormalModel(g) ?? SIMD3<Float>(0, 0, 1)
                if let f = force.loadForceVectorModel(g.id, groupNormal: n) {
                    loads.append(.init(faceIDs: g.faces.map { Int($0) },
                                       force: SIMD3<Double>(f)))
                }
            }
        }
        let up = force.gravity.map { -$0 } ?? SIMD3<Float>(0, 0, 1)
        return (anchors, loads, SIMD3<Double>(up))
    }

    /// A group's model-space outward normal (mean of its faces' normals), or nil.
    private func groupNormalModel(_ g: SelectionGroup) -> SIMD3<Float>? {
        guard let mesh = viewerMesh else { return nil }
        var acc = SIMD3<Float>.zero
        var found = false
        for f in g.faces { if let nrm = mesh.faceNormal(f) { acc += nrm; found = true } }
        guard found else { return nil }
        let len = simd_length(acc)
        return len > 1e-6 ? acc / len : nil
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
                               savedAt: savedAt, selection: selection, force: force,
                               minimizePlastic: minimizePlastic, quality: quality,
                               optimized: hasResults, printParams: printParams)
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

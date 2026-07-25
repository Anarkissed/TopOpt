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

    /// The M7.dom-app design-domain state: an optional design box (empty grow-room the
    /// optimizer may ADD material into, beyond the import) plus keep-out boxes. Default
    /// OFF (`box == nil`) → the run passes no box and behaves exactly as before.
    /// Persisted on the project; threaded to the core via `AppModel.makeRunRequest`.
    @Published public var designBox = DesignBoxModel()

    /// Round-6 item 4: the workspace undo/redo history over the edit slice (selection + force +
    /// design-box). Published so the header's Undo/Redo buttons enable/disable with `canUndo`/
    /// `canRedo`. Fed by a debounced auto-commit (`installUndoAutoCommit`) so a settled edit — a
    /// tap, a scrub, a handle drag, a painted stroke — folds into ONE step; driven by
    /// `performUndo`/`performRedo`. Depth 50 (see the handoff for the covered/uncovered scope).
    @Published public private(set) var undo = UndoHistory(depth: 50)
    /// The debounce that turns bursts of `objectWillChange` into one settled `commit`.
    private var undoAutoCommit: AnyCancellable?
    /// How long the edit slice must be quiet before it commits as an undo step. Long enough that a
    /// drag/scrub coalesces into one entry, short enough to feel immediate on a discrete tap.
    private static let undoSettleInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(400)

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
            self.viewerMesh = ViewerMesh(vertices: m.vertices, indices: m.indices,
                                         faceIDs: m.faceIDs, faceGeometry: m.faceGeometry,
                                         pseudoFaces: m.pseudoFaces)
        }
        self.run = run ?? ProjectModel.makeRun()
        // The two initial value-replays fire here during init, before any view
        // observes this object, so they're harmless no-ops.
        self.runForwarding = Publishers.Merge(
            self.run.$outcome.map { _ in () },
            self.run.$phase.map { _ in () }
        )
        .sink { [weak self] in self?.objectWillChange.send() }
        // Round-6 item 4: seed the undo baseline with the just-built state (so undo can never go
        // "before load") and start the debounced auto-commit. A `restoring` init re-seeds AFTER it
        // installs the persisted slice, so the restored state — not this empty one — is the floor.
        seedUndoBaseline()
        installUndoAutoCommit()
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
        self.designBox = snapshot.designBox ?? DesignBoxModel()
        // Re-seed AFTER restoring the slice: the persisted state is the undo floor, not the empty
        // state the designated init seeded. Runs synchronously before any debounce could fire.
        seedUndoBaseline()
    }

    // MARK: - Undo / redo (round-6 item 4)

    /// The current undoable slice — the value copy the history snapshots and restores.
    public var editSnapshot: EditSnapshot {
        EditSnapshot(selection: selection, force: force, designBox: designBox)
    }

    /// Whether an undo is available RIGHT NOW — a committed step, OR an in-flight edit the debounce
    /// hasn't folded in yet. The header button reads this (not `undo.canUndo`) so it enables the
    /// instant the user edits, matching the two-finger gesture, which commits-then-undoes. Reactive:
    /// it reads `@Published` state on this object, so the view re-evaluates it on every edit.
    public var canUndoNow: Bool { undo.canUndo || undo.baseline != editSnapshot }
    /// Whether a redo is available — only ever after an undo with no fresh edit since (which clears
    /// the redo stack), so there is no "pending" case to fold in here.
    public var canRedoNow: Bool { undo.canRedo }

    /// Seed the undo baseline with the current state, clearing history. Called after init and
    /// after a restore so undo can never reach a state that predates the loaded project.
    public func seedUndoBaseline() {
        undo.reset(to: editSnapshot)
    }

    /// Debounced auto-commit: after the edit slice has been quiet for `undoSettleInterval`, fold
    /// the settled state into history. `objectWillChange` fires on ANY published change, so the
    /// guard below (commit only when the slice truly differs) is what stops an unrelated republish
    /// — or the `undo` mutation this very method makes — from looping or manufacturing steps.
    private func installUndoAutoCommit() {
        undoAutoCommit = objectWillChange
            .debounce(for: Self.undoSettleInterval, scheduler: RunLoop.main)
            .sink { [weak self] in self?.commitUndoSnapshot() }
    }

    /// Fold the current settled slice into the history as one undo step, if it differs from the
    /// baseline. Idempotent and cheap on a no-op (it never touches the `@Published undo` unless a
    /// real step is recorded, so it can't re-arm its own debounce forever).
    private func commitUndoSnapshot() {
        let snap = editSnapshot
        guard undo.baseline != snap else { return }
        undo.commit(snap)
    }

    /// Undo one settled edit. Any in-flight (not-yet-debounced) edit is committed first, so undo
    /// always starts from the state actually on screen. No-op when nothing is undoable.
    public func performUndo() {
        commitUndoSnapshot()
        guard let restored = undo.undo() else { return }
        applyEditSnapshot(restored)
    }

    /// Redo one undone edit. No-op when the redo stack is empty (a fresh edit clears it).
    public func performRedo() {
        guard let restored = undo.redo() else { return }
        applyEditSnapshot(restored)
    }

    /// Restore a slice into the live model. The resulting republish re-arms the debounce, but the
    /// history's baseline already equals `s` (set by `undo()`/`redo()`), so the follow-up commit is
    /// a guarded no-op that leaves the redo stack intact.
    private func applyEditSnapshot(_ s: EditSnapshot) {
        selection = s.selection
        force = s.force
        designBox = s.designBox
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

    /// The run's "Keep clear" clearances (handoff 100), derived from the selection +
    /// roles: an AUTOMATIC bolt clearance for every anchored BORE face (an anchored
    /// hole is a fastener hole — design 095), and an EXPLICIT clearance for every
    /// group the user marked "Keep clear" (a bore → bolt, a planar face → bounded
    /// slab). Editable per-group distance overrides are threaded through; a nil
    /// override sends 0, which the core reads as "use the geometry-derived
    /// suggestion". Empty for an STL project (no B-rep faces) → no clearance.
    public func clearanceSpecs() -> [TopOptKit.ClearanceSpec] {
        guard let mesh = viewerMesh else { return [] }
        var specs: [TopOptKit.ClearanceSpec] = []
        for g in selection.groups {
            // Keep-clear v2: the attribute, not a role. A group clears if its keep-clear
            // is EFFECTIVELY on — either the anchored-bore auto rule, or an explicit
            // affix. Suppressing an auto bore (affix `.suppressed`) drops it here — that
            // is the auto-suppression override, "sent as such" by omission (the wire
            // format is unchanged; a clearance the run must skip is simply not listed).
            let auto = autoClearanceApplies(g, in: mesh)
            guard force.keepClearIsOn(g.id, autoDefault: auto) else { continue }
            // An EXPLICIT affix keeps every face of the group clear (bore → bolt,
            // plane → slab); the auto default affixes ONLY the bore faces (fastener
            // holes), never a plane, exactly as handoff 100 shipped.
            let explicit = force.keepClearAffix(for: g.id) == .on
            for f in g.faces {
                let bore = FaceTopology.isCurved(f, in: mesh)
                if !explicit && !bore { continue }
                // Per-bore when the group is unsynced, shared when synced (round 4, item 3).
                let ov = force.clearanceOverride(forGroup: g.id, face: f)
                if bore {
                    specs.append(.init(faceID: Int(f), kind: .bolt,
                                       concentricMarginMM: ov.concentricMarginMM ?? 0,
                                       axialClearanceMM: ov.axialClearanceMM ?? 0))
                } else {
                    specs.append(.init(faceID: Int(f), kind: .face,
                                       slabDepthMM: ov.slabDepthMM ?? 0))
                }
            }
        }
        return specs
    }

    /// The run's Face protections (handoff 124 — preserve-skin): every B-rep face of
    /// a group the user marked "Protect", plus the ONE global preserve-depth. The
    /// core freezes each face's OWN part-solid skin FrozenSolid to that depth. Empty
    /// for an STL project (no B-rep faces) or when nothing is protected → the run is
    /// byte-identical. Face ids are deduped (a face never appears twice).
    public func faceProtectionSpecs() -> (faceIDs: [Int], depthMM: Double) {
        guard viewerMesh != nil else { return ([], force.faceProtectDepthMM) }
        var ids: [Int] = []
        var seen = Set<FaceID>()
        for g in selection.groups where force.isProtected(g.id) {
            for f in g.faces where !seen.contains(f) {
                seen.insert(f)
                ids.append(Int(f))
            }
        }
        return (ids, force.faceProtectDepthMM)
    }

    /// Whether the anchored-bore AUTO clearance rule applies to a group (keep-clear
    /// v2): an anchor group with at least one bore (curved) face — a fastener hole
    /// (design 095). This is the default the keep-clear attribute deviates from.
    public func autoClearanceApplies(_ g: SelectionGroup, in mesh: ViewerMesh) -> Bool {
        guard force.kind(for: g.id).isAnchor else { return false }
        return g.faces.contains { FaceTopology.isCurved($0, in: mesh) }
    }

    /// Whether "Keep clear" is effectively on for a group given the current mesh —
    /// the single source the row control + the rendered volume both read.
    public func keepClearIsOn(_ g: SelectionGroup) -> Bool {
        guard let mesh = viewerMesh else { return false }
        return force.keepClearIsOn(g.id, autoDefault: autoClearanceApplies(g, in: mesh))
    }

    /// Whether the anchored-bore auto rule applies to a group (the default the affix
    /// toggle deviates from) — the mesh-aware convenience the UI passes to
    /// `ForceModel.setKeepClear(_:on:autoDefault:)`.
    public func keepClearAutoDefault(_ g: SelectionGroup) -> Bool {
        guard let mesh = viewerMesh else { return false }
        return autoClearanceApplies(g, in: mesh)
    }

    /// The TRUE 3D clearance volumes to render (keep-clear v2 Part 3), one per cleared
    /// face, tagged with the owning group so the viewport can brighten the selected
    /// one. Built from the EXACT bridge geometry + the SAME resolved distances the run
    /// freezes: an un-overridden distance resolves to the Auto suggestion (the real mm
    /// the core would derive), never 0, so the drawn cylinder/slab is the run's region.
    /// A bore whose B-rep face is not actually a cylinder yields a `.degenerate`
    /// volume (rendered hollow/dashed) — the same safe no-op the core produces.
    public func clearanceVolumes() -> [(groupID: UUID, volume: ClearanceVolume)] {
        resolvedClearances().map { ($0.groupID, $0.volume) }
    }

    /// A resolved clearance for ONE cleared face: the rendered volume plus the FIXED
    /// bore facts (radius, tessellation span) the Phase B drag handles need. Shared by
    /// `clearanceVolumes()` (the render) and `clearanceHandles()` (the drag anchors) so
    /// the picture and the handles can never derive from different numbers.
    private struct ResolvedClearance {
        let groupID: UUID
        let faceID: Int
        let volume: ClearanceVolume
        /// The bore's exact radius (mm); 0 for a slab.
        let boreRadiusMM: Float
        /// The bore's through-part tessellation span along its axis; nil for a slab.
        let axialSpan: (lo: Float, hi: Float)?
    }

    private func resolvedClearances() -> [ResolvedClearance] {
        guard let mesh = viewerMesh else { return [] }
        var out: [ResolvedClearance] = []
        for g in selection.groups {
            let auto = autoClearanceApplies(g, in: mesh)
            guard force.keepClearIsOn(g.id, autoDefault: auto) else { continue }
            let explicit = force.keepClearAffix(for: g.id) == .on
            for f in g.faces {
                let bore = FaceTopology.isCurved(f, in: mesh)
                if !explicit && !bore { continue }
                guard let geo = mesh.faceGeometry(f) else { continue }  // STL / no B-rep
                // Per-bore when the group is unsynced, shared when synced (round 4, item 3).
                let ov = force.clearanceOverride(forGroup: g.id, face: f)
                if bore {
                    let r = geo.cylinderRadiusMM
                    let margin = ov.concentricMarginMM ?? ClearanceSuggestion.boltMarginMM(boreRadiusMM: r)
                    let axial = ov.axialClearanceMM ?? ClearanceSuggestion.boltAxialMM(boreRadiusMM: r)
                    let span = mesh.faceAxialSpan(f, axisPoint: SIMD3<Float>(geo.axisPoint),
                                                  axisDir: SIMD3<Float>(geo.axisDir))
                    out.append(ResolvedClearance(
                        groupID: g.id, faceID: Int(f),
                        volume: .bolt(faceID: Int(f), geometry: geo, axialSpan: span,
                                      marginMM: margin, axialMM: axial),
                        boreRadiusMM: Float(r), axialSpan: span))
                } else {
                    let depth = ov.slabDepthMM ?? ClearanceSuggestion.faceSlabDepthMM
                    let outline = mesh.facePlaneOutline(f, planeNormal: SIMD3<Float>(geo.planeNormal),
                                                        planeOrigin: SIMD3<Float>(geo.planeOrigin))
                    out.append(ResolvedClearance(
                        groupID: g.id, faceID: Int(f),
                        volume: .slab(faceID: Int(f), geometry: geo, outline: outline, depthMM: depth),
                        boreRadiusMM: 0, axialSpan: nil))
                }
            }
        }
        return out
    }

    /// The Phase B drag-handle anchors for every rendered clearance volume, grouped by
    /// the owning selection group + face. Built from the SAME resolved geometry as
    /// `clearanceVolumes()`, so a handle sits on the exact wall / cap / face the run
    /// keeps clear. A degenerate volume contributes no handles (nothing to drag); such
    /// entries are dropped so the caller iterates only live handles.
    public func clearanceHandles() -> [(groupID: UUID, faceID: Int, handles: [ClearanceHandle])] {
        resolvedClearances().compactMap { rc in
            let hs = ClearanceHandles.handles(for: rc.volume,
                                              boreRadiusMM: rc.boreRadiusMM,
                                              axialSpan: rc.axialSpan)
            return hs.isEmpty ? nil : (rc.groupID, rc.faceID, hs)
        }
    }

    /// The representative bore radius (mm) of a group — the first cylindrical face's
    /// EXACT radius — for its "Auto · N mm" labels. Nil if the group has no bore
    /// geometry (STL, or a non-cylindrical selection).
    public func clearanceBoreRadius(for g: SelectionGroup) -> Double? {
        guard let mesh = viewerMesh else { return nil }
        for f in g.faces {
            if let geo = mesh.faceGeometry(f), geo.isCylinder { return geo.cylinderRadiusMM }
        }
        return nil
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
                               optimized: hasResults, printParams: printParams,
                               designBox: designBox)
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

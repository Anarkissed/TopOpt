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

    /// Task project-store-sidecars (Q2): set by the `restoring:` init when the
    /// re-imported model does not carry face ids the restored selection groups
    /// reference — the fingerprint of a project saved before the store copied the
    /// face-overrides sidecar. Names the affected groups and how to recover;
    /// `AppModel.open` surfaces it. Nil when every group resolves (every project
    /// saved by the fixed store).
    public private(set) var restoreWarning: String?

    /// The working state that used to live in WorkspacePlaceholder. `@Published`
    /// value types: the workspace mutates them in place (via computed forwarders),
    /// which republishes and re-renders exactly as the old `@State` did.
    @Published public var selection = SelectionModel()
    @Published public var force = ForceModel()
    @Published public var viewerMesh: ViewerMesh?

    /// ★ THE REGION LAYER (task 2026-08-14-face-regions §1) — the unions and the
    /// split cells over this part's faces. Default EMPTY: with no region edits the
    /// project emits exactly the job it emitted before this layer existed (bar R1).
    /// Persisted on the project as the DEFINITION (filter + add/remove + cut
    /// geometry), so a re-import re-evaluates it and reports what changed.
    @Published public var faceRegions = FaceRegionModel()

    /// The regions whose filter matches a different number of faces than it did
    /// when it was authored — computed on the import that follows a restore, and
    /// surfaced rather than absorbed (§3c). Empty when nothing drifted.
    @Published public private(set) var faceRegionDrift: [FaceRegionModel.Drift] = []

    /// Paint-mode overlay (handoff 2026-07-25): the triangle→painted-face map for the imported
    /// part, the escape when tap-selection over-selects. Nil for a project with no paintable mesh.
    /// `@Published` value type: a brush stroke mutates it in place (via `paintStroke`), which
    /// republishes AND arms the undo debounce — so a settled stroke folds into ONE round-6 undo
    /// step alongside the selection change it makes (see `EditSnapshot.paint`). A painted region
    /// becomes a pseudo-face with id ≥ `baseFaceCount`; downstream (highlight, picker, tagging,
    /// clearance, the run) sees it exactly as a segmenter-produced face — "painted == tapped".
    @Published public var paint: PaintModel?

    /// The M7.dom-app design-domain state: an optional design box (empty grow-room the
    /// optimizer may ADD material into, beyond the import) plus keep-out boxes. Default
    /// OFF (`box == nil`) → the run passes no box and behaves exactly as before.
    /// Persisted on the project; threaded to the core via `AppModel.makeRunRequest`.
    @Published public var designBox = DesignBoxModel()

    /// Lattice mode (handoff 2026-07-29-lattice-mode-ui): the mode toggle, topology, cell
    /// size, density range and region. Default OFF ⇒ no lattice block reaches the job, so
    /// the project produces exactly today's job (BAR U1). Persisted on the project and
    /// folded into the undo slice so every lattice edit is one undo step (BAR U4). Its
    /// controls are bounded at USE by the core-read `TopOptKit.LatticeLimits`, never here.
    @Published public var lattice = LatticeSettings()

    /// THE ARTIFACTS A RE-LATTICE NEEDS (task 2026-08-02-lattice-a-variant): the
    /// EXACT job document that produced this project's current results, and that
    /// run's `design.bin` (each variant's own density field).
    ///
    /// WHY THEY ARE RETAINED RATHER THAN REBUILT. "Lattice this variant" has to
    /// certify under the load case the variant was OPTIMIZED under. The project's
    /// live state is not that: the user may have moved an anchor, retagged a
    /// face, or changed the resolution since the run. Re-deriving the job from
    /// the current state would produce a load case that merely looks similar,
    /// and a selector resolved against changed geometry silently tags nothing
    /// (the PR-261 failure). So the submitted document is kept verbatim, beside
    /// the results it produced, and the re-lattice job is that document with its
    /// mode swapped.
    ///
    /// nil when the run kept neither — a solve on this device (the bridge writes
    /// no job document and no design container) or a result restored from a blob
    /// written before this existed. The lattice page then says so rather than
    /// offering an action that would quietly do something else.
    ///
    /// THE STORAGE LIVES ON THE RUN (task 2026-08-03-variant-entry-gating-and-
    /// retention). It used to be its own `@Published` here, and the two could then
    /// disagree: a failed run restores the previous variants (bar AJ1) while a pair
    /// cleared independently on the project left those variants claiming to have
    /// kept no design. The pair describes ONE run's results, so it moves with them
    /// or not at all. This stays as the property every reader already uses.
    public var relatticeArtifacts: RelatticeArtifacts? {
        get { run.retainedArtifacts }
        set { run.restoreArtifacts(newValue) }
    }

    /// THE SECOND QUESTION (handoff 2026-08-01-build-direction-separation): which
    /// way is UP ON THE PLATE, as its own project setting rather than an inference
    /// from the gravity widget's "which way is down in service". Default = nothing
    /// declared ⇒ the core's documented gravity fallback ⇒ exactly the job this
    /// project produced before this setting existed.
    @Published public var buildOrientation = BuildOrientation()

    /// Cache for `orientationRanking`, keyed on the receipt bytes it was decoded
    /// from, so the view body does not re-parse the JSON on every redraw.
    private var orientationRankingCache: (Data, OrientationRanking?)?

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

    /// ★ RESTORE THE SURFACES THAT CAME FROM THE CAD, on export (task
    /// 2026-08-06-arm-projection-and-void-check, S1c). DEFAULT ON, matching
    /// core's own `output.project_cad_faces` default — the app never invents a
    /// second answer to this question, it only lets the user override the one
    /// core states.
    ///
    /// ON  — every exported vertex that came from a face of the imported CAD is
    ///       put back on the plane or cylinder the B-rep states, exactly. Bolt
    ///       bores come out the radius they were drawn at.
    /// OFF — the voxelised approximation is exported instead. That is what the
    ///       app shipped before, and it is measurably ~8% oversize.
    ///
    /// This exists so the same job can be run BOTH WAYS while the maintainer
    /// evaluates the new default; it is not a preference the app has an opinion
    /// about beyond agreeing with core.
    @Published public var projectCADFaces = true

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

    /// The ranking the last run's build-orientation receipt carried, or nil.
    ///
    /// DERIVED from the run's own outcome — never stored independently — so it can
    /// never describe a different run from the results on screen. A RECOMMENDATION
    /// the UI displays; it is never applied, and `run.outcome`'s per-variant
    /// `accepted` remains the verdict of the orientation ACTUALLY certified.
    public var orientationRanking: OrientationRanking? {
        guard let data = run.outcome?.buildOrientationJSON else { return nil }
        if let c = orientationRankingCache, c.0 == data { return c.1 }
        let decoded = OrientationRanking.decode(data)
        orientationRankingCache = (data, decoded)
        return decoded
    }

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
            // Seed the paint overlay with the part's native face count so minted painted ids never
            // collide with a segmentation face. `faceCount` is the native (segmenter/STL-pseudo)
            // face count; fall back to the mesh's own max id + 1 if it is unset.
            let base = m.faceCount > 0 ? Int32(m.faceCount)
                : ((m.faceIDs.max()).map { $0 + 1 } ?? 0)
            self.paint = PaintModel(baseFaceCount: base)
        }
        self.run = run ?? ProjectModel.makeRun()
        // The two initial value-replays fire here during init, before any view
        // observes this object, so they're harmless no-ops.
        self.runForwarding = Publishers.Merge3(
            self.run.$outcome.map { _ in () },
            self.run.$phase.map { _ in () },
            // The retention pair now lives on the run too, and the entry controls
            // read it — so its changes must reach the workspace body as well.
            self.run.$retainedArtifacts.map { _ in () }
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
        // Task project-store-sidecars (Q2): a project saved BEFORE the store
        // carried the face-overrides sidecar re-imports without its painted
        // pseudo-faces, while the restored groups still reference their ids. Say
        // so plainly at open — naming the groups — instead of letting RUN SIM /
        // Optimize throw a raw out-of-range later.
        self.restoreWarning = Self.unresolvableGroupsWarning(
            selection: snapshot.selection, faceCount: importedMesh.faceCount)
        self.force = snapshot.force
        self.minimizePlastic = snapshot.minimizePlastic ?? true
        self.quality = snapshot.quality ?? .fast
        self.printParams = snapshot.printParams ?? .fdmDefault
        self.designBox = snapshot.designBox ?? DesignBoxModel()
        self.lattice = snapshot.lattice ?? LatticeSettings()
        // nil → TRUE. A project saved before this field existed reopens with CAD-face
        // projection ARMED, which is what the new core default means; decoding it to
        // false would quietly opt every existing project out of the change.
        self.projectCADFaces = snapshot.projectCADFaces ?? true
        self.faceRegions = snapshot.faceRegions ?? FaceRegionModel()
        // ★ RE-EVALUATE THE PERSISTED REGIONS AGAINST THIS IMPORT, and report what
        // moved (§3c / bar R6). A union is stored as a filter plus a hand
        // add/remove list precisely so it CAN be re-evaluated; the one thing that
        // must never happen is absorbing a change silently.
        refreshFaceRegionDrift()
        // Re-seed AFTER restoring the slice: the persisted state is the undo floor, not the empty
        // state the designated init seeded. Runs synchronously before any debounce could fire.
        seedUndoBaseline()
    }

    /// Re-evaluate every persisted region's filter against the CURRENT import and
    /// record which ones now match a different number of faces than they did when
    /// they were authored. Called on restore and after a re-import.
    ///
    /// ★ REPORTED, NEVER ABSORBED. A CAD edit renumbers B-rep faces; a union whose
    /// filter used to catch seven blend faces and now catches five is a fact the
    /// user has to see before they run. The core reports the same number on its own
    /// side (`[loadcase] region ... drift=`), so a remote run says it too.
    public func refreshFaceRegionDrift() {
        guard let mesh = viewerMesh, !faceRegions.isEmpty else {
            faceRegionDrift = []
            return
        }
        var now: [RegionID: Int] = [:]
        for r in faceRegions.regions where r.filter.any {
            now[r.id] = FaceRegionGeometry.match(r.filter, in: mesh).count
        }
        faceRegionDrift = faceRegions.drift(matchedNow: now)
    }

    /// The Q2 message: which restored groups reference face ids the re-imported
    /// model (with `faceCount` faces) does not carry, and what to do about it.
    /// Pure + static so it is unit-tested without disk IO. Nil when all resolve.
    static func unresolvableGroupsWarning(selection: SelectionModel,
                                          faceCount: Int) -> String? {
        let broken = selection.groups.compactMap { g -> String? in
            let missing = g.faces.filter { $0 >= FaceID(faceCount) }
            guard !missing.isEmpty else { return nil }
            return "“\(g.name)” (painted face \(missing.map(String.init).joined(separator: ", ")))"
        }
        guard !broken.isEmpty else { return nil }
        return "This project was saved before painted selections were stored with it, "
             + "so the reopened model doesn't carry the hand-painted faces that "
             + broken.joined(separator: " and ")
             + " selected. Those groups can't reach the solver. To recover: delete "
             + "them, re-paint the faces, and save the project again."
    }

    // MARK: - Undo / redo (round-6 item 4)

    /// The current undoable slice — the value copy the history snapshots and restores.
    public var editSnapshot: EditSnapshot {
        EditSnapshot(selection: selection, force: force, designBox: designBox, paint: paint,
                     lattice: lattice, faceRegions: faceRegions)
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
    /// ★ SEAL THE CURRENT STATE AS AN UNDO STEP, so the NEXT edit starts a new one.
    ///
    /// Surface actions are discrete — a cut, then a union, then a pattern — and each
    /// has to undo on its own. Left to the debounce they fold together: one undo
    /// after cut-then-union reversed BOTH, taking away a cut the user never asked to
    /// lose. Every surface commit seals first, so its predecessor is already a step.
    public func sealUndoStep() { commitUndoSnapshot() }

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
        lattice = s.lattice
        // ★ §6 — the region layer restores with everything else, so a cut, a union
        // or a pattern undoes through the SAME history as every other edit.
        faceRegions = s.faceRegions
        // Restore the paint overlay too, so undoing/redoing a brush stroke reverts the exact
        // painted triangles (not just the group membership). Only when the project actually has a
        // paint overlay — a nil snapshot on a paintable project would wrongly erase all paint.
        if let restored = s.paint { paint = restored }
        // The persisted sidecar must track the restored paint so a subsequent run / live tagging
        // reproduces what is now on screen. Best-effort: an undo that can't write the sidecar still
        // updates the in-memory overlay (the run rewrites it before it launches anyway).
        persistPaint()
        // Likewise, the restored `force` carries the manual primitives + deletions; keep the
        // clearance sidecar in step so undoing/redoing an add/move/delete round-trips to the file.
        persistClearances()
    }

    // MARK: - paint mode (handoff 2026-07-25)

    /// Apply a brush stroke to the active group's painted pseudo-face — the paint-mode escape from
    /// tap over-selection. Routes through `WorkspacePaint.stroke` (the tested pure router), which
    /// mints one painted face per group, paints/erases the triangles, and adds/removes the painted
    /// id on the active group. Mutating `paint` + `selection` republishes and arms the round-6 undo
    /// debounce, so a settled stroke becomes ONE undo step. No-op with no paint overlay (no mesh).
    /// The caller persists the sidecar on stroke-END via `persistPaint`.
    public func paintStroke(_ mode: PaintMode, triangles: [Int]) {
        guard var overlay = paint, !triangles.isEmpty else { return }
        // The round-6 UndoHistory is the SINGLE undo authority (see `EditSnapshot.paint`); the
        // router still records onto a `PaintHistory`, so hand it a throwaway we discard — we do not
        // fork a second undo stack.
        var ignoredHistory = PaintHistory()
        WorkspacePaint.stroke(mode, triangles: triangles, paint: &overlay,
                              selection: &selection, history: &ignoredHistory)
        paint = overlay
    }

    /// The per-triangle EFFECTIVE face ids (native ids with painted overrides applied) the viewer
    /// highlights/picks against, so a painted region behaves like any other face — the live paint
    /// highlight. Nil when there is no mesh or nothing is painted (the viewer uses native ids).
    public func effectivePaintFaceIDs() -> [Int32]? {
        guard let mesh = viewerMesh, let overlay = paint, !overlay.assignments.isEmpty else { return nil }
        return overlay.effectiveFaceIDs(base: mesh.faceIDs)
    }

    /// Persist the paint overlay to the core face-overrides sidecar next to the imported model, so
    /// the run and live tagging re-import EXACTLY what was painted ("painted == tapped" to the voxel
    /// grid). A cleared overlay deletes the sidecar. Best-effort — a write failure is swallowed (the
    /// run rewrites it before launch); no mesh / no file → nothing to persist.
    public func persistPaint() {
        guard let overlay = paint, let path = importedFile?.path else { return }
        try? TopOptKit.writeFaceOverrides(modelPath: path, dihedralDeg: 0, coneDeg: -1,
                                          paintFaces: overlay.paintFaceSets())
    }

    /// Persist the clearance edits — deleted auto faces + user-placed primitives — to
    /// the sidecar beside the working-copy model, so they survive a re-import of the
    /// same file (handoff group-editing, BAR B3). Best-effort; an empty state deletes
    /// the sidecar. Call after any add / delete / move of a manual primitive or a
    /// deletion of an auto one (the debounced undo auto-commit persists the project
    /// separately; this is the file-travelling copy).
    public func persistClearances() {
        guard let path = importedFile?.path else { return }
        let manual = force.allManualPrimitives.map {
            ClearanceSidecar.GroupPrimitives(group: $0.group, primitives: $0.primitives)
        }
        let sidecar = ClearanceSidecar(suppressedAutoFaces: force.suppressedClearanceFaceList,
                                       manual: manual)
        sidecar.write(forModelPath: path)
    }

    /// Auto-apply the clearance sidecar on import: re-suppress the deletions (the B3
    /// guarantee — a phantom bore stays deleted) and re-attach any manual primitives
    /// whose owning group still exists. Call once after a fresh import of a file that
    /// may carry a sidecar. No sidecar → no-op (byte-identical to a plain import).
    public func applyClearanceSidecar() {
        guard let path = importedFile?.path,
              let sidecar = ClearanceSidecar.read(forModelPath: path) else { return }
        force.loadSuppressedClearanceFaces(sidecar.suppressedAutoFaces)
        let live = Set(selection.groups.map { $0.id })
        for gp in sidecar.manual where live.contains(gp.group) {
            force.loadManualPrimitives(gp.primitives, for: gp.group)
        }
    }

    /// Translate a (possibly painted) selection face id to the id a resolved re-import assigns it:
    /// painted ids (`≥ baseFaceCount`) pack densely from `baseFaceCount` in the sidecar, native ids
    /// are unchanged. The run + tagging operate on the RE-IMPORTED model, so they must target this
    /// id, not the live overlay id. Identity when there is no paint (`resolvedFaceID` handles both).
    /// The face id the RUN will use for `id` — public since the face card must
    /// preview the same face the run freezes (task 2026-08-12 §0b).
    public func runFaceID(_ id: FaceID) -> FaceID { resolvedRunFaceID(id) }

    private func resolvedRunFaceID(_ id: FaceID) -> FaceID {
        paint?.resolvedFaceID(id) ?? id
    }

    /// Assemble the run's load case from the current selection + force state, in the
    /// MODEL/grid frame the solver uses: anchor groups → their B-rep faces (clamped),
    /// load groups → their faces + model-frame force (kgf → N). The build direction
    /// (print up) is the negated gravity, or +Z if gravity is unset. Empty for an
    /// STL project (no face selection) — the run then falls back to self-weight.
    public func loadCase() -> (anchorFaceIDs: [Int], loadGroups: [TopOptKit.LoadGroupSpec],
                               buildDirection: SIMD3<Double>,
                               plateDirection: SIMD3<Double>,
                               anchorRegionIDs: [RegionID]) {
        var anchors: [Int] = []
        var anchorRegions: [RegionID] = []
        var loads: [TopOptKit.LoadGroupSpec] = []
        for g in selection.groups {
            let kind = force.kind(for: g.id)
            if kind.isAnchor {
                // Painted faces carry a live overlay id; the run sees the dense re-import id.
                anchors.append(contentsOf: g.faces.map { Int(resolvedRunFaceID($0)) })
                // ★ A region rides ALONGSIDE the faces (task 2026-08-14-face-regions
                // §3e). Region ids are NOT face ids and are never remapped through
                // `resolvedRunFaceID` — a region is resolved core-side against the
                // run's own import, which is the whole reason it survives one.
                anchorRegions.append(contentsOf: g.regionIDs)
            } else if kind.isLoad {
                let n = groupNormalModel(g) ?? SIMD3<Float>(0, 0, 1)
                if let f = force.loadForceVectorModel(g.id, groupNormal: n) {
                    loads.append(.init(faceIDs: g.faces.map { Int(resolvedRunFaceID($0)) },
                                       force: SIMD3<Double>(f),
                                       regionIDs: g.regionIDs))
                }
            }
        }
        // `buildDirection` keeps its LEGACY job: the core derives the service
        // gravity as its unit negation, so this is the service side and must not
        // move (changing it would change every existing project's self-weight).
        let up = force.gravity.map { -$0 } ?? SIMD3<Float>(0, 0, 1)
        // `plateDirection` is the SEPARATED build-plate normal (handoff
        // 2026-08-01-build-direction-separation). ZERO when the user declared
        // none — the core then applies its documented gravity fallback and the
        // job is byte-identical to what this project produced before. Non-zero
        // only when the user actually answered the second question.
        let plate = buildOrientation.plateUp.map { simd_normalize($0) } ?? SIMD3<Float>(0, 0, 0)
        return (anchors, loads, SIMD3<Double>(up), SIMD3<Double>(plate), anchorRegions)
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
            // MANUAL (user-placed) primitives are EXPLICIT keep-out the finder missed:
            // emitted unconditionally (they are their own declaration, independent of
            // the group's auto/affix state). Their inline geometry crosses the bridge
            // as a manual `ClearanceSpec` (handoff group-editing).
            // Round-2: EXCEPT when the group carries a lattice role while lattice
            // mode is on — its primitives are then lattice REGIONS (material kept,
            // latticed or solid), the opposite of a keep-out (no material). They
            // ride `lattice.regions` via `latticeJobRegions()` instead, never both.
            // Only the PRIMITIVES re-purpose; the group's keep-clear FACES (an
            // independent attribute) keep clearing below.
            if !isLatticeRegionGroup(g.id) {
                for mp in force.manualPrimitives(for: g.id) { specs.append(mp.spec()) }
            }

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
                let bore = FaceTopology.isFastenerBore(f, in: mesh)
                if !explicit && !bore { continue }
                // The "−" on an auto primitive's row DELETES it: a suppressed face's
                // keep-out is dropped from the run (handoff group-editing, BAR B3). The
                // face stays in the group (it may still anchor); only its clearance goes.
                if force.isClearanceFaceSuppressed(f) { continue }
                // Per-bore when the group is unsynced, shared when synced (round 4, item 3).
                let ov = force.clearanceOverride(forGroup: g.id, face: f)
                if bore {
                    specs.append(.init(faceID: Int(resolvedRunFaceID(f)), kind: .bolt,
                                       concentricMarginMM: ov.concentricMarginMM ?? 0,
                                       axialClearanceMM: ov.axialClearanceMM ?? 0))
                } else {
                    specs.append(.init(faceID: Int(resolvedRunFaceID(f)), kind: .face,
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
    ///
    /// ★ THE DEPTH IS THE ONE THE USER DRAGGED (task 2026-08-12 §0a). `depthsMM`
    /// is parallel to `faceIDs`: for a group that also carries a lattice role it
    /// is that group's `LatticeSlabDepth` — the SAME number its lattice region
    /// carries — so the barrier is exactly as deep as the lattice it feeds. For a
    /// protect-only group it is the project's global depth, unchanged.
    public func faceProtectionSpecs()
        -> (faceIDs: [Int], depthMM: Double, depthsMM: [Double],
            regionIDs: [RegionID], regionDepthsMM: [Double]) {
        guard viewerMesh != nil else {
            return ([], force.faceProtectDepthMM, [], [], [])
        }
        var ids: [Int] = []
        var depths: [Double] = []
        var regionIDs: [RegionID] = []
        var regionDepths: [Double] = []
        var seen = Set<FaceID>()
        var seenRegions = Set<RegionID>()
        for g in selection.groups where force.isProtected(g.id) {
            // A protected group that is ALSO a lattice region is one slab; a
            // protect-only group keeps the project's global depth.
            let latticed = lattice.enabled && lattice.groupRoles[g.id] != nil
            for f in g.faces where !seen.contains(f) {
                seen.insert(f)
                // ★ PER FACE (task 2026-08-14 §3d). The depth plane is draggable
                // per face now, so the protection is resolved per face through the
                // SAME `LatticeSlabDepth` call the region emission makes — which is
                // what keeps R4 true when two faces of one group hold two depths.
                let d = latticed
                    ? LatticeSlabDepth.depthMM(
                        ref: .face(group: g.id, face: f), group: g.id,
                        perSelectable: lattice.selectableDepthMM,
                        perGroup: lattice.groupDepthMM,
                        fallbackMM: lattice.paintDepthMM)
                    : force.faceProtectDepthMM
                ids.append(Int(resolvedRunFaceID(f)))
                depths.append(d)
            }
            // ★ EACH REGION CARRIES ITS OWN DEPTH — which is what makes a grid
            // split a hand-authored grading mechanism (PR 331 §6): ten sectors
            // around a curved feature, each protected to a different depth, with
            // the optimiser deciding none of it.
            //
            // ★ AND IT IS THE SAME DEPTH THE 3D HANDLE DRAGS (task 2026-08-14
            // §3d, widened by the interrupt): resolved per REGION through the
            // same `LatticeSlabDepth` call a face goes through, so PR 331's
            // `face_protection_region_depths_mm` is FILLED from the one store
            // rather than from a parallel one.
            // ★ THE EFFECTIVE REGIONS, NOT THE TREE. A cut's parent and its
            // children both resolve to the same surface; emitting both describes it
            // twice with two roles and two depths, and the run keeps whichever was
            // written last. `surfaceEffectiveRegions` is the one definition.
            for r in surfaceEffectiveRegions(of: g) where !seenRegions.contains(r) {
                seenRegions.insert(r)
                let d = latticed
                    ? LatticeSlabDepth.depthMM(
                        ref: .region(group: g.id, region: r), group: g.id,
                        perSelectable: lattice.selectableDepthMM,
                        perGroup: lattice.groupDepthMM,
                        fallbackMM: lattice.paintDepthMM)
                    : force.faceProtectDepthMM
                regionIDs.append(r)
                regionDepths.append(d)
            }
        }
        return (ids, force.faceProtectDepthMM, depths, regionIDs, regionDepths)
    }

    /// The lattice region depth for `group`, in mm — the ONE number, read through
    /// `LatticeSlabDepth` so no call site can invent a second one.
    public func latticeSlabDepthMM(_ group: UUID) -> Double {
        LatticeSlabDepth.depthMM(group: group, perGroup: lattice.groupDepthMM,
                                 fallbackMM: lattice.paintDepthMM)
    }

    /// The depth for ONE selectable (task 2026-08-14 §3d) — its own dragged
    /// number, else its group's, else the project default. This is what the 3D
    /// depth plane drags and what the protection freezes: one call, both
    /// meanings, and for a REGION it is what fills PR 331's
    /// `face_protection_region_depths_mm`.
    public func latticeSlabDepthMM(_ ref: LatticeSelectableRef, in group: UUID) -> Double {
        LatticeSlabDepth.depthMM(ref: ref, group: group,
                                 perSelectable: lattice.selectableDepthMM,
                                 perGroup: lattice.groupDepthMM,
                                 fallbackMM: lattice.paintDepthMM)
    }

    /// ★ THE DENSITY IN FORCE FOR ONE SELECTABLE (maintainer, 2026-08-17: "There
    /// is no *actual* way to modify the density value when the lattice density
    /// setting is set to per-region").
    ///
    /// The same precedence shape the role and the depth use: the selectable's own
    /// stated number, else its group's, else the MODE's answer (Uniform states
    /// one; Auto and Per-region-with-nothing-stated state none and core derives).
    /// nil ⇒ AUTO ⇒ no `relative_density` key on the wire.
    public func latticeSelectableDensity(_ ref: LatticeSelectableRef,
                                         in group: UUID) -> Double? {
        if let d = lattice.selectableDensity[ref.key], d.isFinite, d > 0 { return d }
        return latticeDeclaredDensity(group)
    }

    /// Write one selectable's density. `nil` (or a non-positive value) CLEARS it
    /// back to the group's/mode's answer — "no number stated" must be spellable,
    /// because core's own sentinel for "derive it" is exactly the absence of a key.
    public func writeLatticeDensity(_ ref: LatticeSelectableRef, fraction: Double?) {
        guard let f = fraction, f.isFinite, f > 0 else {
            lattice.selectableDensity.removeValue(forKey: ref.key)
            return
        }
        let limits = TopOptKit.latticeLimits(topology: lattice.topologyID)
        // Clamped into core's certifiable band — there is no certificate outside
        // it, and a value core would refuse must not be storable from a keypad.
        lattice.selectableDensity[ref.key] =
            Swift.min(Swift.max(f, limits.rhoMin), limits.rhoMax)
    }

    /// ★ THE IN-PLANE EXPAND IN FORCE FOR ONE SELECTABLE (maintainer,
    /// 2026-08-17). 0 ⇒ the slab is exactly the face it came from.
    public func latticeExpandMM(_ ref: LatticeSelectableRef) -> Double {
        LatticeSlabExpand.clamp(lattice.selectableExpandMM[ref.key] ?? 0)
    }

    /// Write one selectable's in-plane expand, clamped. ZERO CLEARS it —
    /// "exactly the face" must be spellable, and it is the default every older
    /// project has.
    ///
    /// ★ AND IT MAY BE NEGATIVE (maintainer, 2026-08-17: "Can we make the
    /// expansion *also* take a negative value? I'd like to see us also be able
    /// to make it smaller in the x/y axis as well"). So the clear test is `== 0`
    /// and not `<= 0` — the old spelling would have silently discarded every
    /// shrink and left the drawer reading 0.0 mm after a leftward drag.
    ///
    /// ★ AND IT SNAPS TO ZERO (maintainer, 2026-08-17: "Please make a magnetic
    /// detent at 0 for the expansion so it is easier to 'feel' when it hits the
    /// floor"). The magnet lives HERE, on the one setter, rather than in each
    /// gesture — so the 3D knob, the drawer scrub and the keypad cannot develop
    /// three different feels, which is the defect the depth control already had
    /// once.
    public func writeLatticeExpandMM(_ ref: LatticeSelectableRef, mm: Double) {
        let v = LatticeSlabExpand.snapped(mm)
        if v == 0 { lattice.selectableExpandMM.removeValue(forKey: ref.key) }
        else { lattice.selectableExpandMM[ref.key] = v }
    }

    /// ★ WHAT THE FACE CARDS MUST BE DERIVED FROM (task
    /// 2026-08-17-lattice-stage-repair §2). One entry per thing the lattice panel
    /// shows a drawer for: the group itself, and every selectable inside it that
    /// carries a lattice role — each paired with the B-rep face its slab is built
    /// on and ★ THE DEPTH IN FORCE FOR IT, resolved through the same
    /// `latticeSlabDepthMM` the 3D handle and the protection spec go through.
    ///
    /// ★ THE DEFECT THIS FUNCTION EXISTS TO REMOVE. `refreshLatticeFaceCards`
    /// previously previewed ONE face per group at the GROUP's depth, and the
    /// drawer beneath a face or region row was then handed that group card while
    /// being labelled with the selectable's own number. So the card's cell,
    /// cells-across, strut and mass were all arithmetic at a depth the row was
    /// not showing — and dragging one face's handle moved the label and nothing
    /// else. Deriving from THIS list makes the two the same number by
    /// construction.
    ///
    /// A selectable with no B-rep face behind it (a hand-placed primitive, or a
    /// region whose members have gone) contributes nothing rather than a card
    /// about a face it does not own.
    public func latticeCardInputs()
        -> [(key: String, faceID: Int, depthMM: Double, declaredDensity: Double?)] {
        var out: [(key: String, faceID: Int, depthMM: Double,
                   declaredDensity: Double?)] = []
        for g in selection.groups where lattice.groupRoles[g.id] != nil {
            // ★ NO GROUP CARD (maintainer, 2026-08-17). There used to be one more
            // entry here, keyed by the group's UUID and built from
            // `g.faces.first` at the GROUP's depth — one arbitrary face standing
            // for the whole group. It fed a drawer of cell/density/strut/
            // cells-across numbers for a slab NO PRIMITIVE OWNS and no handle can
            // drag, which is why he could never bring it into regime. It is not
            // computed at all now: the group's badge and its grams total are
            // aggregated from the SELECTABLE cards below, so there is no
            // fabricated card left for anything to read.
            for ref in latticeSelectableRefs(g) {
                guard let f = latticeCardFace(ref, in: g) else { continue }
                // ★ EACH SELECTABLE'S OWN DENSITY, not the group's — the card
                // must be derived at the number that selectable's drawer shows
                // and its region emits (maintainer, 2026-08-17).
                out.append((ref.key, Int(runFaceID(f)),
                            latticeSlabDepthMM(ref, in: g.id),
                            latticeSelectableDensity(ref, in: g.id)))
            }
        }
        return out
    }

    /// ★ THE DENSITY THIS GROUP'S CARD MUST BE DERIVED AT, or nil for AUTO
    /// (task 2026-08-17-lattice-stage-repair §1d).
    ///
    /// ★ THE DEFECT THIS REMOVES. `refreshLatticeFaceCards` never passed
    /// `declaredDensity` at all — the parameter existed on
    /// `LatticeFaceCardDerivation.card` and no shipping call site used it. So a
    /// user who set Uniform and typed a number, or dialled ONE sector on the
    /// lattice page, still read the same figure Auto showed. That is what made
    /// "the density is stuck at 5%" true in EVERY mode and narrowed the break to
    /// the app: PR 336 had already proved the per-region override reaches core's
    /// grading law (0.25 and 0.60 on two sectors at one depth, measured).
    ///
    /// The precedence is the SAME one the emitted job uses: a per-group stated
    /// density wins (`LatticeRegionEmission.density(for:role:densities:)` puts it
    /// on the wire as `relative_density`); otherwise UNIFORM mode states the
    /// single density the run generates at, which is the range's dense end
    /// (`LatticeBounds.generateRelativeDensity`, the shipped generator's own
    /// rule); otherwise AUTO, where nil means "core derives it".
    public func latticeDeclaredDensity(_ group: UUID) -> Double? {
        // A stated per-group density wins in EVERY mode — it is the number the
        // job carries as `relative_density`.
        if let stated = lattice.groupDensities[group] { return stated }
        switch lattice.densityMode {
        case .uniform:
            // The single density the run generates at — the range's dense end,
            // the shipped generator's own rule.
            return LatticeBounds.compute(
                settings: lattice,
                limits: TopOptKit.latticeLimits(topology: lattice.topologyID),
                lineWidthMM: printParams.strutLineWidthMM).generateRelativeDensity
        case .sim:
            return nil                       // core derives
        case .perRegion:
            // ★ PER REGION WITH NOTHING STATED FOR THIS ONE IS STILL AUTO, and
            // that is the honest reading: the mode says "I will state it myself",
            // not "assume a number for me". A region the user has not dialled
            // shows what core WILL derive, exactly as the sector-density rows on
            // the lattice page do, and the emitted job carries no key for it.
            return nil
        }
    }

    /// The B-rep face one selectable's slab preview is built on, or nil.
    ///
    /// A REGION is a set of faces (PR 331), and the preview walks ONE face — the
    /// region's first member, which is the face its frame is built from. That
    /// over-states a sector's held material exactly as the group card did before
    /// this task, so the mass rows are no worse; the four numbers this task is
    /// about (depth, cell, density, cells across) do not read the voxel count at
    /// all, so they are exact.
    func latticeCardFace(_ ref: LatticeSelectableRef, in g: SelectionGroup) -> FaceID? {
        switch ref {
        case let .face(_, f): return f
        case .primitive: return nil            // no B-rep face to preview
        case let .region(_, rid):
            guard let mesh = viewerMesh, let region = faceRegions.region(rid) else {
                return nil
            }
            return FaceRegionGeometry.members(of: region, in: mesh).first
        }
    }

    /// The role in force for ONE selectable (§3c) — its own override, else its
    /// group's declaration. nil ⇒ not latticed at all.
    public func latticeSelectableRole(_ ref: LatticeSelectableRef,
                                     in group: UUID) -> LatticeGroupRole? {
        LatticeSelectableRoles.role(for: ref, groupRole: latticeEligibleRoles()[group],
                                   overrides: lattice.selectableRoles)
    }

    /// ★ EVERYTHING INSIDE A GROUP THAT CAN BE LATTICED ON ITS OWN: its REGIONS
    /// (PR 331), its B-rep faces, then its manual primitives — in the selection's
    /// own order.
    ///
    /// ONE listing rule, so the row the user taps and the thing the run resolves
    /// are the same set. A per-selectable control over a list the emission does
    /// not walk would be the "decorative primitive" defect again, one level down.
    ///
    /// ★ REGIONS COME FIRST, because a region is the SUMMARY of faces the user
    /// combined: PR 331's whole point is that a 24-face union is ONE row.
    ///
    /// ★ AND A GRID SPLIT'S CHILDREN ARE FOLDED BY PR 331'S OWN FLAG (bar R12).
    /// `FaceRegionModel.roots` hides a parent's children until it is expanded, so
    /// a 10×5 split is one row here as it is one row in the Regions sheet — there
    /// is no second collapse mechanism in this panel.
    /// ★ §1(a) — A FACE COVERED BY ONE OF THIS GROUP'S REGIONS IS **NOT** A ROW.
    ///
    /// ★ THE DEFECT THIS FIXES, MEASURED ON HIS OWN PART. This function used to
    /// return the regions AND every one of the group's raw faces, unconditionally.
    /// His load group carries **22 face ids**
    /// (`evidence/2026-08-07-lattice-variants-on-screen/run_his/job.json`), so
    /// combining them into ONE region gave him **1 region row + 22 face rows =
    /// 23 rows**, each with its own Lattice/Solid/Off chips, its own depth and its
    /// own out-of-regime readout. His words: *"That's completely untennable… This
    /// was all supposed to make things EASIER for the user!"*
    ///
    /// PR 331 measured the selection cost going 22 taps → 2. The LIST never
    /// followed. It does now: a face that a region of this group already covers
    /// is that region's CHILD (`latticeRegionMemberFaces`), shown only when the
    /// region is expanded and carrying no chips of its own (§1b) — the role, the
    /// lattice choice, the depth and the verdict are the REGION's.
    public func latticeSelectableRefs(_ g: SelectionGroup) -> [LatticeSelectableRef] {
        let covered = latticeRegionCoveredFaces(g)
        return latticeRegionRefs(g)
            + g.faces.filter { !covered.contains($0) }
                     .map { LatticeSelectableRef.face(group: g.id, face: $0) }
            + force.manualPrimitives(for: g.id).map { .primitive($0.id) }
    }

    /// Every face any region of `g` resolves to — the set `latticeSelectableRefs`
    /// subtracts. Reads EVERY region of the group, not just the unfolded rows: a
    /// collapsed grid split still owns its parent's faces, and a face must not
    /// pop back up as a top-level row merely because the row holding it is shut.
    public func latticeRegionCoveredFaces(_ g: SelectionGroup) -> Set<FaceID> {
        guard viewerMesh != nil, !g.regionIDs.isEmpty else { return [] }
        // ★ THROUGH THE ONE RESOLVER — a parent whose children superseded it must
        // not also claim its faces.
        var out: Set<FaceID> = []
        for r in surfaceEffectiveRegions(of: g) {
            out.formUnion(surfaceResolvedFaces(r))
        }
        return out
    }

    /// ★ §1(a)/§1(b) — THE FACES UNDERNEATH ONE REGION ROW, as collapsed children.
    /// Display only: they inherit the region's role, depth and verdict and are
    /// given no controls, which is what "role, lattice choice, depth and verdict
    /// are per REGION" means as a property rather than as a convention.
    public func latticeRegionMemberFaces(_ rid: RegionID) -> [FaceID] {
        guard let mesh = viewerMesh, let region = faceRegions.region(rid)
        else { return [] }
        return FaceRegionGeometry.members(of: region, in: mesh)
    }

    // MARK: - ★ §6(i)/(j) — COMMITTING A SURFACE CUT

    /// The region a cut through `face` should divide: the DEEPEST live region
    /// whose members contain it, so cutting a piece that was already cut divides
    /// the piece you pointed at and not its whole parent again.
    ///
    /// Nil when the face belongs to no region yet — the caller makes one.
    public func surfaceCutTarget(face: FaceID) -> RegionID? {
        guard let mesh = viewerMesh else { return nil }
        /// How many parents a region has above it — its depth in the split tree.
        func depth(_ r: FaceRegion) -> Int {
            var d = 0, cur = r
            while let p = faceRegions.region(cur.parentID) { d += 1; cur = p }
            return d
        }
        return faceRegions.regions
            .filter { FaceRegionGeometry.members(of: $0, in: mesh).contains(face) }
            .max { depth($0) < depth($1) }?
            .id
    }

    /// ★ §6(i)/(j) — CUT A FACE IN TWO, along a plane the user aimed on the model.
    ///
    /// The cut divides the face's REGION, because a region is what carries a role,
    /// a depth and a lattice choice — a bare face id carries none of those, and
    /// LAYER 1 is never re-partitioned (a cut face is still the same CAD face, so
    /// projection and the analytic-surface lookups are untouched).
    ///
    /// If the face has no region, an IDENTITY region is made for it first and
    /// joins whichever group already owns the face, so the two halves appear as
    /// rows in that group's Selections list rather than in no list at all.
    ///
    /// Returns the two children, or [] when nothing could be cut.
    @discardableResult
    public func commitSurfaceCut(_ cut: SurfaceCut) -> [RegionID] {
        sealUndoStep()          // each surface action is its own undo step
        guard let mesh = viewerMesh else { return [] }
        let target: RegionID
        if let existing = surfaceCutTarget(face: cut.faceID) {
            target = existing
        } else {
            let rid = faceRegions.union(faces: [cut.faceID],
                                        named: "Face \(cut.faceID)")
            // Join the group that already owns the face, if one does.
            if let g = selection.groups.first(where: { $0.faces.contains(cut.faceID) }) {
                selection.addRegions([rid], to: g.id)
            }
            target = rid
        }
        let kids = faceRegions.splitManual(target, point: cut.point, normal: cut.normal)
        // ★ AND A HALF THAT FELL INTO SEPARATE PATCHES BECOMES SEPARATE PIECES
        // (maintainer, 2026-08-16: "If a cut leaves a small piece alone, it should
        // be its own part … even if it's a tiny piece"). Cutting an L, a C or an
        // arc off-centre leaves one side of the plane holding the body of the face
        // AND a scrap round the far end, with nothing joining them; sharing a region
        // they would share a role, a depth and one row in Selections, and the scrap
        // could never be given its own.
        //
        // Returns the DEEPEST live pieces, so the caller selects and the lattice
        // receives what the user can actually see as separate.
        var leaves: [RegionID] = []
        for k in kids {
            let detached = faceRegions.splitDetached(k, in: mesh)
            leaves += detached.isEmpty ? [k] : detached
        }
        if !kids.isEmpty { objectWillChange.send() }
        return leaves
    }

    // MARK: - ★ §6/§7 — THE REST OF THE SURFACE TOOLSET
    //
    // ★ EVERY MECHANISM BELOW ALREADY EXISTED AND HAD NO CONTROL SURFACE. PR 331
    // built union, the filter, the grid split and the sliver guard, and reached
    // them only from the Regions sheet — so on the page the maintainer actually
    // works on, they did not exist ("Where are all the other tools? Union?
    // Pattern?"). These are the entry points the Surface panel calls; the work is
    // the wiring, not the geometry.

    /// ★ §6(c)/(d) — THE FACES LIKE THIS ONE. A filter DERIVED from a tapped face,
    /// never a stored id list: PR 331 measured that storing the matches turns a
    /// union into "a stale id list wearing a filter's clothes", and a simulated CAD
    /// edit grew a 24-face union to 32.
    ///
    /// Two rules, in order:
    ///   * a SMALL face flanked by larger ones is a blend — the signature §2(a)
    ///     measured, and the one that finds fillets and chamfers together.
    ///   * otherwise, the same analytic KIND (plane with plane, bore with bore).
    public func surfaceSimilarFilter(to face: FaceID) -> RegionFilter? {
        guard let mesh = viewerMesh else { return nil }
        let areas = FaceRegionGeometry.faceAreas(in: mesh)
        guard let a = areas[face], a > 0 else { return nil }
        let sorted = areas.values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let median = sorted[sorted.count / 2]

        // ── 1. A BORE: the same kind AND the same radius ────────────────────
        //
        // ★ "ALL THE M3 HOLES" IS THE QUESTION, not "every cylinder". Kind alone
        // caught all 12 cylinders on his part regardless of size, which lumps a
        // 1.5 mm bore in with a 40 mm fillet.
        //
        // ★ AND THIS COMES FIRST, BEFORE THE BLEND RULE. A small bore is still a
        // BORE: measured, a 9 mm² cylinder fell through the blend branch and
        // matched 19 faces — every small feature on the part — when what was
        // wanted was the other holes of its size.
        if let g = mesh.faceGeometry(face), g.kind == .cylinder,
           g.cylinderRadiusMM > 0 {
            var f = RegionFilter()
            f.kind = "cylinder"
            f.cylinderRadiusMM = g.cylinderRadiusMM
            // Loose enough for tessellation noise, tight enough to separate the
            // drill sizes a part actually uses.
            f.cylinderRadiusTolMM = max(0.05, g.cylinderRadiusMM * 0.05)
            return f
        }

        // ── 2. A BLEND: small, and flanked by larger faces ──────────────────
        //
        // The signature §2(a) measured. "Small FOR THIS PART" — the threshold is
        // read off the part rather than guessed in millimetres.
        if a < median * 0.5 {
            return RegionFilter.blend(maxAreaMM2: a * 1.5)
        }

        // ── 3. ANYTHING ELSE: the same kind AND a comparable size ───────────
        //
        // ★ KIND ALONE IS NOT SIMILARITY. Measured on his part: tapping the
        // largest plane matched 36 of 78 faces — 46% of the model — and the
        // largest `other` matched 30. "Every plane" is not what a person means by
        // "the ones like this"; a face of comparable SIZE is. The band is
        // generous (half to double) because a person means "about this big", not
        // a tolerance.
        var f = RegionFilter()
        switch mesh.faceGeometry(face)?.kind {
        case .plane:    f.kind = "plane"
        case .cylinder: f.kind = "cylinder"
        default:        f.kind = "other"
        }
        f.minAreaMM2 = a * 0.5
        f.maxAreaMM2 = a * 2.0
        return f
    }

    /// ★ §6(c) — ISOLATE THE MATCHES: make them their own face, disconnected from
    /// every other region that held them. See `FaceRegionModel.isolate`.
    @discardableResult
    public func commitSurfaceIsolate(_ filter: RegionFilter,
                                     named name: String) -> RegionID? {
        commitSurfaceIsolate(faces: viewerMesh.map { FaceRegionGeometry.match(filter, in: $0) } ?? [],
                             named: name).first
    }

    /// ★ ISOLATE A SET OF FACES — ONE PIECE PER *CONNECTED* GROUP OF THEM.
    ///
    /// Maintainer, 2026-08-16: "When cutting similar pieces, if they are *not*
    /// directly attached to one another, they should separate into isolated pieces.
    /// E.g. … 3 isolated faces that are considered similar; they should be cut into
    /// 3 separate faces, each individually selectable. However, if multi-select
    /// connects the pieces, then they are all made into a single face group."
    ///
    /// That rule is exactly connectivity, and it is the same rule a CUT already
    /// follows (`SurfaceComponents`): things that do not touch are not one thing.
    /// Faces that DO touch — including two different "kinds" brought together by a
    /// multi-select — stay one piece, because they are one piece.
    ///
    /// Returns the new regions, outermost first by size. Empty when nothing matched.
    @discardableResult
    public func commitSurfaceIsolate(faces: [FaceID],
                                     named name: String) -> [RegionID] {
        guard let mesh = viewerMesh, !faces.isEmpty else { return [] }
        sealUndoStep()

        // ★ CONNECTED GROUPS OF THE SELECTED FACES. Adjacency is face-level and
        // already derived for the loop walk; here it is restricted to the selection,
        // so "connected" means connected THROUGH THE SELECTION and not through the
        // rest of the part.
        let wanted = Set(faces)
        let adjacency = SurfaceComponents.faceAdjacency(in: mesh)
        var seen: Set<FaceID> = []
        var clusters: [[FaceID]] = []
        for f in faces.sorted() where !seen.contains(f) {
            var stack = [f], group: [FaceID] = []
            seen.insert(f)
            while let cur = stack.popLast() {
                group.append(cur)
                for n in adjacency[cur] ?? []
                where wanted.contains(n) && !seen.contains(n) {
                    seen.insert(n)
                    stack.append(n)
                }
            }
            clusters.append(group.sorted())
        }
        guard !clusters.isEmpty else { return [] }

        var out: [RegionID] = []
        for (k, cluster) in clusters.sorted(by: { $0.count > $1.count }).enumerated() {
            let label = clusters.count == 1 ? name : "\(name) \(k + 1)"
            if let rid = faceRegions.isolate(faces: cluster, named: label, in: mesh) {
                out.append(rid)
            }
        }
        // ★ AN ISOLATED PIECE JOINS NOTHING (maintainer, 2026-08-16: "The isolated
        // face was not selectable on its own and when I accidentally selected the
        // face next to it, it was part of the group of faces that were highlighted.
        // These must be selectable and cannot be part of a group").
        //
        // ★ AND THE OLD BEHAVIOUR WAS SELF-CONTRADICTORY. Isolating means
        // "disconnect this from everything it is currently connected with" — and
        // then it ADDED the new region to the very group those faces came from. So
        // the piece was disconnected at the REGION layer and still owned at the
        // GROUP layer: tapping its neighbour lit it, because they were groupmates.
        //
        // Disconnecting means both. The faces leave every group, the regions join
        // none, and each piece stands alone — selectable on the Topology page, ready
        // to be given to whichever group the user chooses.
        if !out.isEmpty {
            for g in selection.groups { selection.removeFaces(faces, from: g.id) }
        }
        force.sync(groups: selection.groups)
        objectWillChange.send()
        return out
    }

    /// ★ APPLY A CUT TO EVERY FACE IN A SELECTION (maintainer, 2026-08-16: "The
    /// select-similar should only be to add a tool's action to all the similar
    /// faces or to cut them out as a group/individual faces").
    ///
    /// Each face is cut through ITS OWN centre along ITS OWN frame, rotated by the
    /// same angle — so "cut all of these in half the same way" means the same thing
    /// on each of them rather than one plane swept across the part.
    @discardableResult
    public func commitSurfaceCut(faces: [FaceID], rotationDegrees: Double = 0,
                                 offsetMM: Double = 0) -> [RegionID] {
        guard let mesh = viewerMesh, !faces.isEmpty else { return [] }
        var out: [RegionID] = []
        for f in faces.sorted() {
            guard let base = SurfaceCut.centred(onFace: f, in: mesh) else { continue }
            out += commitSurfaceCut(base.rotated(by: SurfaceCut.snap(rotationDegrees))
                                        .moved(byMM: offsetMM))
        }
        return out
    }

    /// ★ AND A PATTERN TO EVERY FACE IN A SELECTION. Same grid on each face, in
    /// each face's own frame — a face the grid does not fit is skipped rather than
    /// failing the whole batch, and the count says how many took it.
    @discardableResult
    public func commitSurfacePattern(faces: [FaceID], columns: Int, rows: Int,
                                     rotationDegrees: Double = 0) -> [RegionID] {
        guard viewerMesh != nil, !faces.isEmpty else { return [] }
        var out: [RegionID] = []
        for f in faces.sorted() {
            out += commitSurfacePattern(face: f, columns: columns, rows: rows,
                                        rotationDegrees: rotationDegrees)
        }
        return out
    }

    /// ★ TAKE ONE PIECE OUT OF A GROUP THAT HOLDS ITS WHOLE.
    ///
    /// Maintainer, 2026-08-16: "I attempted to cut out one of the faces of the 3
    /// isolated/grouped faces above and it didn't disconnect it. Instead, it made it
    /// not be able to be de-selectable/re-selectable."
    ///
    /// ★ WHY IT FROZE. A group holds REGIONS, and a region that has been cut is
    /// represented by its CHILDREN (`surfaceEffectiveRegions`). So a group holding
    /// the PARENT contains every child implicitly. Removing one child from the group
    /// therefore changed nothing at all — the parent still spoke for it — and the
    /// piece stayed lit whatever was tapped. Adding it back did nothing either. From
    /// the outside: frozen.
    ///
    /// The fix is to make the implicit explicit exactly when it stops being true:
    /// replace the ancestor with the pieces it stands for, and then the one piece
    /// can leave on its own.
    public func surfaceDetachPiece(_ piece: RegionID, from group: UUID) {
        guard let g = selection.groups.first(where: { $0.id == group }) else { return }

        // Every ancestor of `piece` that the group holds, nearest first.
        var ancestors: [RegionID] = []
        var cur = faceRegions.region(piece)?.parentID ?? -1
        var guard_ = 0
        while let r = faceRegions.region(cur), guard_ < faceRegions.regions.count {
            guard_ += 1
            if g.regionIDs.contains(r.id) { ancestors.append(r.id) }
            cur = r.parentID
        }
        for ancestor in ancestors {
            // What the ancestor actually stands for, minus the piece leaving.
            let stands = surfaceEffectiveRegions(from: ancestor).filter { $0 != piece }
            selection.removeRegions([ancestor])
            if !stands.isEmpty { selection.addRegions(stands, to: group) }
        }
        selection.removeRegions([piece])
        force.sync(groups: selection.groups)
        objectWillChange.send()
    }

    /// How many faces a filter matches right now — shown BEFORE the union is made,
    /// so "select similar" is never a leap.
    public func surfaceMatchCount(_ filter: RegionFilter) -> Int {
        guard let mesh = viewerMesh else { return 0 }
        return FaceRegionGeometry.match(filter, in: mesh).count
    }

    /// ★ §6(c) — UNION THE FACES THE USER PICKED into ONE region.
    ///
    /// A HAND-PICKED union stores its members explicitly and carries no filter:
    /// PR 331's rule is that the filter IS the membership when one exists, and
    /// `add` holds only what was tapped in on top of it. With no filter, `add` is
    /// the whole membership, which is exactly what a multi-select means.
    /// The region a face belongs to, creating an identity one if it has none —
    /// so a tool that works on PIECES always has a piece to work with.
    @discardableResult
    public func surfaceEnsureRegion(for face: FaceID) -> RegionID? {
        guard viewerMesh != nil else { return nil }
        if let existing = surfaceCutTarget(face: face) { return existing }
        let rid = faceRegions.union(faces: [face], named: "Face \(face)")
        if let g = selection.groups.first(where: { $0.faces.contains(face) }) {
            selection.addRegions([rid], to: g.id)
        }
        objectWillChange.send()
        return rid
    }

    /// ★ UNION PIECES. The members are the union of the sources' member faces.
    ///
    /// ★ A LIMIT WORTH STATING: a region is `faces ∩ (intersection of half-spaces)`,
    /// so the union of two DISJOINT halves of one face is not expressible in this
    /// model — an intersection cannot describe "either side". Unioning two halves
    /// of the same face therefore yields that whole face back, which is coherent
    /// and explainable; unioning pieces of DIFFERENT faces does what it says.
    /// ★ NOT IMPLEMENTED, DELIBERATELY. See `SurfaceUnion`: the only union today's
    /// `FaceRegion` can express absorbs WHOLE FACES — pieces the user never picked —
    /// and that must never happen. The region shape needs a `parts` list first, plus
    /// expansion at the two emission sites. Returning nil keeps the confirm disabled
    /// rather than shipping the wrong behaviour quietly.
    @discardableResult
    public func commitSurfaceUnion(_ u: SurfaceUnion) -> RegionID? {
        sealUndoStep()          // each surface action is its own undo step
        guard viewerMesh != nil, u.hasEnoughToCombine else { return nil }
        guard let rid = faceRegions.unionOfParts(u.pieces,
                                                 named: "Union of \(u.count)")
        else { return nil }
        // The union joins the group any of its parts belonged to, so it appears in
        // the Selections list where a role and a depth can be given to it.
        if let g = selection.groups.first(where: { g in
            u.pieces.contains { g.regionIDs.contains($0) }
        }) {
            selection.addRegions([rid], to: g.id)
        }
        objectWillChange.send()
        return rid
    }

    /// Every face a region resolves to, following a union down to its parts.
    public func surfaceResolvedFaces(_ id: RegionID) -> [FaceID] {
        guard let mesh = viewerMesh else { return [] }
        var out: Set<FaceID> = []
        for leaf in faceRegions.resolvedLeaves(id) {
            guard let r = faceRegions.region(leaf) else { continue }
            out.formUnion(FaceRegionGeometry.members(of: r, in: mesh))
        }
        return out.sorted()
    }

    @discardableResult
    public func commitSurfaceUnion(faces: [FaceID]) -> RegionID? {
        guard viewerMesh != nil, !faces.isEmpty else { return nil }
        let rid = faceRegions.union(faces: faces,
                                    named: faces.count > 1
                                        ? "Union of \(faces.count)" : "Face \(faces[0])")
        if let g = selection.groups.first(where: { g in
            faces.contains { g.faces.contains($0) }
        }) {
            selection.addRegions([rid], to: g.id)
        }
        objectWillChange.send()
        return rid
    }

    /// ★ §6(c) — UNION the faces a filter matches into ONE region. The FILTER is
    /// stored, not its matches, and `filterMatchedAtAuthor` records the count so a
    /// later CAD edit is REPORTED as drift rather than absorbed silently.
    @discardableResult
    public func commitSurfaceUnion(_ filter: RegionFilter, named name: String) -> RegionID? {
        guard let mesh = viewerMesh else { return nil }
        let matched = FaceRegionGeometry.match(filter, in: mesh)
        guard !matched.isEmpty else { return nil }
        let rid = faceRegions.union(faces: [], named: name, filter: filter,
                                    matchedAtAuthor: matched.count)
        if let g = selection.groups.first(where: { g in
            matched.contains { g.faces.contains($0) }
        }) {
            selection.addRegions([rid], to: g.id)
        }
        objectWillChange.send()
        return rid
    }

    /// ★ §7 — THE PATTERN TOOL: split a face into an n x m grid in its OWN frame,
    /// refusing before it manufactures anything smaller than the smallest face the
    /// CAD itself produced (`kRegionSliverFloorVoxels` = 16 — the size of his own
    /// faces 41-47 at resolution 128).
    ///
    /// Returns the verdict WITHOUT splitting, so the panel can show the smallest
    /// piece and the refusal reason while the user is still choosing n and m.
    /// `piece` is the region the pattern divides — the one that was TAPPED. It is
    /// passed in rather than looked up: `surfaceCutTarget` returns the DEEPEST
    /// region holding the face, which after a cut is one particular half and not
    /// necessarily the half under the finger. Reading it here put the grid on the
    /// wrong piece — "the pattern doesn't go to the selected face".
    public func surfacePatternPreview(face: FaceID, columns: Int, rows: Int,
                                      rotationDegrees: Double = 0,
                                      piece: RegionID? = nil)
        -> (cells: [FaceRegionGeometry.GridCell], verdict: SliverVerdict)? {
        guard let mesh = viewerMesh else { return nil }
        // ★ §7 — THE GRID RUNS ALONG THE SHAPE. The frame's own axes come from the
        // member vertices' principal direction, which is pulled off by wherever the
        // tessellation is dense; the face's longest STRAIGHT EDGE is what a person
        // means by "in line with it". The user's own rotation is added on top, so
        // the automatic answer is a starting point and never a verdict.
        let frame = FaceRegionGeometry.frame(members: [face], in: mesh)
            .rotatedInPlane(byDegrees:
                SurfacePatternAxis.alignmentDegrees(face: face, in: mesh)
                    + rotationDegrees,
                members: [face], in: mesh)
        // ★ EQUAL AREA, not equal parameter — see `SurfacePatternAxis.areaCells`.
        // Even steps across the frame's extent leave the last column a sliver on
        // any face that is not a rectangle.
        // ★ CONFINED TO THE SELECTED PIECE. A pattern on one half of a cut face
        // divides THAT HALF; measuring over the whole face made the count disagree
        // with the drawing.
        let target = (piece ?? surfaceCutTarget(face: face))
            .flatMap { faceRegions.region($0) }
        // ★ AND SAY WHY WHEN IT REFUSES, IN ITS OWN WORDS. The grid used to answer
        // `[]` for every failure and the panel guessed one message — "Too many
        // pieces for this face" — which was wrong for the case that actually bites
        // on a curve ("170° per piece is too wide to cut with a plane"). The
        // geometry knows why; it now says so.
        let cells: [FaceRegionGeometry.GridCell]
        switch SurfacePatternAxis.grid(face: face, frame: frame,
                                       columns: columns, rows: rows, in: mesh,
                                       within: target?.cuts ?? []) {
        case .success(let c):
            cells = c
        case .failure(let refusal):
            return ([], SliverVerdict(ok: false, minCellVoxels: 0, emptyCells: 0,
                                      memberVoxels: 0,
                                      maxCellsBudget: columns * rows,
                                      floorVoxels: kRegionSliverFloorVoxels,
                                      reason: refusal.reason))
        }
        guard !cells.isEmpty else {
            return ([], SliverVerdict(ok: false, minCellVoxels: 0, emptyCells: 0,
                                      memberVoxels: 0,
                                      maxCellsBudget: columns * rows,
                                      floorVoxels: kRegionSliverFloorVoxels,
                                      reason: "Too many pieces for this face."))
        }
        // ★ PRICED AT THE RUN'S OWN SPACING, so the panel refuses with the number
        // the run would — the same path the Regions sheet prices against.
        let spacing = surfaceVoxelSpacingMM(mesh)
        let per = FaceRegionGeometry.cellVoxelCounts(members: [face], in: mesh,
                                                     cells: cells, spacingMM: spacing)
        let member = FaceRegionGeometry.memberVoxelEstimate(members: [face], in: mesh,
                                                            spacingMM: spacing)
        let verdict = FaceRegionModel.checkSliver(cellVoxels: per, memberVoxels: member)
        return (cells, verdict)
    }

    /// Commit the pattern. Refuses on a failing verdict — the guard is not advisory.
    @discardableResult
    public func commitSurfacePattern(face: FaceID, columns: Int, rows: Int,
                                     rotationDegrees: Double = 0,
                                     piece: RegionID? = nil) -> [RegionID] {
        sealUndoStep()          // each surface action is its own undo step
        guard let p = surfacePatternPreview(face: face, columns: columns, rows: rows,
                                            rotationDegrees: rotationDegrees,
                                            piece: piece),
              p.verdict.ok else { return [] }
        let splitTarget = piece ?? surfaceCutTarget(face: face) ?? {
            let rid = faceRegions.union(faces: [face], named: "Face \(face)")
            if let g = selection.groups.first(where: { $0.faces.contains(face) }) {
                selection.addRegions([rid], to: g.id)
            }
            return rid
        }()
        let kids = faceRegions.splitGrid(splitTarget, cells: p.cells)
        if !kids.isEmpty { objectWillChange.send() }
        return kids
    }

    /// One voxel, in mm, at the run's own resolution — the same derivation
    /// `FaceRegionSheetModel` uses, so the two surfaces price a split identically.
    private func surfaceVoxelSpacingMM(_ mesh: ViewerMesh) -> Double {
        let b = mesh.bounds
        let span = Double(max(b.max.x - b.min.x,
                              max(b.max.y - b.min.y, b.max.z - b.min.z)))
        let n = quality.resolution
        return n > 0 ? span / Double(n) : 0
    }

    /// ★ A FACE LOOP STOPS AT A PIECE THAT HAS BEEN MADE ITS OWN.
    ///
    /// Maintainer, 2026-08-16: "I select-similar'd the curved face … I couldn't
    /// select the face. I selected the face next to it, and it was automatically
    /// selected with it … it should be its own isolated face."
    ///
    /// ★ WHY IT CAME ALONG. `FaceTopology.loop` walks the run of connected CURVED
    /// faces — the "tap inside a bore and get the whole tube" rule — and it is pure
    /// geometry: it has never heard of regions. His isolated band is curved and
    /// touches other curved faces, so tapping ANY of them swept it up, whatever the
    /// region layer said. Isolating had worked perfectly and was then overruled one
    /// layer down.
    ///
    /// ★ AND THE FIX BELONGS HERE, NOT IN THE WALK. `FaceTopology` is geometry and
    /// should stay geometry; what a face BELONGS to is layer 2, and this is layer
    /// 2's veto over what the walk proposes.
    ///
    /// The rule is exact: a loop member is kept only if it is covered by the SAME
    /// regions as the face that was tapped. So an isolated set of several faces
    /// still selects together (they share their region), a face in no region still
    /// loops with other faces in no region, and a piece that has been made its own
    /// is never dragged in by a neighbour.
    public func surfaceLoopRespectingRegions(_ loop: [FaceID],
                                             from face: FaceID) -> [FaceID] {
        guard let mesh = viewerMesh, loop.count > 1, !faceRegions.isEmpty
        else { return loop }
        func owners(_ f: FaceID) -> Set<RegionID> {
            var out: Set<RegionID> = []
            for r in faceRegions.regions
            where FaceRegionGeometry.members(of: r, in: mesh).contains(f) {
                out.insert(r.id)
            }
            return out
        }
        let mine = owners(face)
        return loop.filter { $0 == face || owners($0) == mine }
    }

    /// ★ THE FACE SETS A UNION HAS WELDED INTO ONE — what the wireframe must stop
    /// drawing an edge between. See `SurfaceWireframe.edges(of:welded:)`.
    ///
    /// A region with two or more member faces and NO cuts is a union of whole
    /// faces, however it was made — tapped in by hand, combined from a similar
    /// filter, or built from parts. A region WITH cuts is a piece, and its edge to
    /// a neighbour is still a real boundary for the rest of the face it came from,
    /// so pieces contribute nothing here.
    public func surfaceWeldedFaces() -> [Set<FaceID>] {
        guard let mesh = viewerMesh else { return [] }
        var out: [Set<FaceID>] = []
        for r in faceRegions.regions {
            var faces: Set<FaceID> = []
            for leaf in faceRegions.resolvedLeaves(r.id) {
                guard let part = faceRegions.region(leaf), !part.isCut else { continue }
                faces.formUnion(FaceRegionGeometry.members(of: part, in: mesh))
            }
            if faces.count >= 2 { out.append(faces) }
        }
        return out
    }

    // MARK: - ★ THE SURFACE STAGE'S SCRATCHPAD (leave without saving = revert)

    /// Snapshot what a Surface session can throw away. See `SurfaceScratch`.
    public func surfaceCaptureScratch() -> SurfaceScratch {
        SurfaceScratch.capture(regions: faceRegions, groups: selection.groups)
    }

    /// Whether anything has been committed since that snapshot.
    public func surfaceHasEdits(since s: SurfaceScratch) -> Bool {
        s.differs(regions: faceRegions, groups: selection.groups)
    }

    /// ★ PUT IT ALL BACK. Regions AND group membership together — see
    /// `SurfaceScratch` for why restoring one without the other is worse than
    /// restoring neither.
    ///
    /// A group created ENTIRELY during the session had no entry in the snapshot;
    /// its regions are dropped rather than left pointing at regions that no longer
    /// exist. A group that existed keeps its faces untouched — no surface tool
    /// changes those, so they are not the session's to revert.
    public func surfaceRestore(_ s: SurfaceScratch) {
        faceRegions = s.regions
        for g in selection.groups {
            selection.setRegions(s.groupRegions[g.id] ?? [], for: g.id)
        }
        // Any region the snapshot does not contain cannot be referred to any more.
        let live = Set(s.regions.regions.map(\.id))
        for g in selection.groups {
            let stale = g.regionIDs.filter { !live.contains($0) }
            if !stale.isEmpty { selection.removeRegions(stale) }
        }
        force.sync(groups: selection.groups)
        objectWillChange.send()
    }

    // MARK: - ★ WHAT A GROUP ACTUALLY CONTAINS (the one resolver)

    /// ★ THE OUTERMOST REGION COVERING EACH FACE, AND NOTHING ELSE.
    ///
    /// ★ THE OVERLAP THIS EXISTS TO KILL. A region layer is a TREE: cut a face and
    /// its two halves live alongside their parent; union three pieces and the union
    /// lives alongside its parts. Ask "what does this group contain" by unioning
    /// `members(of:)` over every region in it and the same surface is described
    /// TWICE — once by the parent and once by each child. Downstream that is not a
    /// cosmetic problem: each description carries its own role and depth, and the
    /// run takes whichever the emission happened to write last.
    ///
    /// The maintainer put it plainly: "It can't have the original face and the other
    /// two cut faces from it. It needs to only bring in the cut faces. And same with
    /// a union; it can't pass along the 3 cut faces over, it needs to only pass
    /// along the singular union'ed face."
    ///
    /// So there is ONE definition, here, and every consumer goes through it: walk to
    /// the OUTERMOST region covering a face — up through unions, down past any
    /// parent whose children have superseded it — and emit that.
    public func surfaceEffectiveRegions(of g: SelectionGroup) -> [RegionID] {
        // ★ A PIECE EXPLICITLY GIVEN TO ANOTHER GROUP IS NOT THIS GROUP'S.
        //
        // A parent expands to its children — that is how a cut hands its pieces on.
        // But once a piece has been moved to a different group on the Topology page,
        // its parent must stop speaking for it, or the piece is claimed by both: the
        // group that holds the parent AND the group it was moved to. One surface,
        // two roles, and the run keeps whichever was written last.
        var claimedElsewhere: Set<RegionID> = []
        for other in selection.groups where other.id != g.id {
            claimedElsewhere.formUnion(other.regionIDs)
        }
        var out: [RegionID] = []
        var seen: Set<RegionID> = []
        for r in g.regionIDs {
            for id in surfaceEffectiveRegions(from: r)
            where !seen.contains(id) && !claimedElsewhere.contains(id) {
                seen.insert(id)
                out.append(id)
            }
        }
        return out
    }

    /// The effective descendants of one region: itself if nothing has superseded
    /// it, otherwise the pieces that have.
    public func surfaceEffectiveRegions(from id: RegionID) -> [RegionID] {
        // A region absorbed into a union is represented BY that union.
        let top = faceRegions.outermostUnion(containing: id)
        guard let r = faceRegions.region(top) else { return [] }

        // A union speaks for its parts.
        if r.isUnionOfParts { return [top] }

        // A cut or grid split is superseded by its children — they cover the same
        // surface between them, and they are what the user then works with.
        let kids = faceRegions.children(of: top).filter { !$0.isUnionOfParts }
        guard !kids.isEmpty else { return [top] }
        return kids.flatMap { surfaceEffectiveRegions(from: $0.id) }
    }

    /// The group's region rows, folded exactly as the Regions sheet folds them: a
    /// collapsed parent contributes itself and hides its children (R12).
    public func latticeRegionRefs(_ g: SelectionGroup) -> [LatticeSelectableRef] {
        var out: [LatticeSelectableRef] = []
        for r in g.regionIDs {
            guard let region = faceRegions.region(r) else { continue }
            // A child whose parent is also in this group is folded under it
            // unless that parent is expanded — PR 331's `collapsed`, read, never
            // duplicated.
            if let parent = faceRegions.region(region.parentID),
               g.regionIDs.contains(parent.id), parent.collapsed {
                continue
            }
            out.append(.region(group: g.id, region: r))
        }
        return out
    }

    /// ALL / SOME / NONE of a group's selectables are latticed — the summary the
    /// group row shows now that it does not own the decision (§3c).
    public func latticeCoverage(_ g: SelectionGroup) -> LatticeGroupCoverage {
        LatticeSelectableRoles.coverage(refs: latticeSelectableRefs(g),
                                       groupRole: latticeEligibleRoles()[g.id],
                                       overrides: lattice.selectableRoles)
    }

    /// Whether the anchored-bore AUTO clearance rule applies to a group (keep-clear
    /// v2): an anchor group with at least one fastener-bore face — a bolt through-hole
    /// (design 095). This is the default the keep-clear attribute deviates from.
    /// Gated on `isFastenerBore` (not the old 5° `isCurved`) so a group whose only
    /// curved faces are pocket corners / fillets / a boss no longer auto-clears
    /// (handoff 2026-07-29).
    public func autoClearanceApplies(_ g: SelectionGroup, in mesh: ViewerMesh) -> Bool {
        guard force.kind(for: g.id).isAnchor else { return false }
        return g.faces.contains { FaceTopology.isFastenerBore($0, in: mesh) }
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
            // MANUAL primitives render through the SAME volume path via a synthetic
            // StepFaceGeometry, so the picture is built from the identical numbers the
            // run freezes. They carry a NEGATIVE sentinel faceID so they never collide
            // with a real face (handoff group-editing).
            // Round-2: a lattice-role group's primitives render as REGIONS — the
            // primitive IS the region (PR 256 resolves them with zero margins), so
            // no clearance margin/axial inflation; the job emits the same numbers.
            let asRegion = isLatticeRegionGroup(g.id)
            for mp in force.manualPrimitives(for: g.id) {
                let key = Self.manualFaceKey(mp.id)
                let geo = mp.syntheticGeometry
                if mp.kind == .bolt {
                    let span: (lo: Float, hi: Float) = (Float(-mp.halfLengthMM), Float(mp.halfLengthMM))
                    // Render/run distances come from the SAME `clearanceMetric` the chips
                    // read (DEFECT 1) — so the picture, the run and both chips are one value.
                    let margin = asRegion ? 0
                        : clearanceMetric(groupID: g.id, faceID: key, role: .margin)?.resolved ?? mp.resolvedMarginMM
                    let axial = asRegion ? 0
                        : clearanceMetric(groupID: g.id, faceID: key, role: .axial)?.resolved ?? mp.resolvedAxialMM
                    out.append(ResolvedClearance(
                        groupID: g.id, faceID: key,
                        volume: .bolt(faceID: key, geometry: geo, axialSpan: span,
                                      marginMM: margin, axialMM: axial),
                        boreRadiusMM: Float(mp.radiusMM), axialSpan: span))
                } else {
                    let n = SIMD3<Float>(mp.axis)
                    let (u, v) = planeBasis(normal: n)
                    let outline = PlaneOutline(center: SIMD3<Float>(mp.center), uAxis: u, vAxis: v,
                                               halfU: Float(mp.halfUMM), halfV: Float(mp.halfWMM))
                    let depth = clearanceMetric(groupID: g.id, faceID: key, role: .slabDepth)?.resolved ?? mp.resolvedDepthMM
                    out.append(ResolvedClearance(
                        groupID: g.id, faceID: key,
                        volume: .slab(faceID: key, geometry: geo, outline: outline, depthMM: depth),
                        boreRadiusMM: 0, axialSpan: nil))
                }
            }

            let auto = autoClearanceApplies(g, in: mesh)
            guard force.keepClearIsOn(g.id, autoDefault: auto) else { continue }
            let explicit = force.keepClearAffix(for: g.id) == .on
            for f in g.faces {
                let bore = FaceTopology.isFastenerBore(f, in: mesh)
                if !explicit && !bore { continue }
                if force.isClearanceFaceSuppressed(f) { continue }  // deleted (BAR B3)
                guard let geo = mesh.faceGeometry(f) else { continue }  // STL / no B-rep
                // Per-bore when the group is unsynced, shared when synced (round 4, item 3).
                if bore {
                    let r = geo.cylinderRadiusMM
                    // Same single source as the chips (DEFECT 1): `clearanceMetric` reads the
                    // group's effective (synced/per-bore) override + the B-rep radius.
                    let margin = clearanceMetric(groupID: g.id, faceID: Int(f), role: .margin)?.resolved
                        ?? ClearanceSuggestion.boltMarginMM(boreRadiusMM: r)
                    let axial = clearanceMetric(groupID: g.id, faceID: Int(f), role: .axial)?.resolved
                        ?? ClearanceSuggestion.boltAxialMM(boreRadiusMM: r)
                    let span = mesh.faceAxialSpan(f, axisPoint: SIMD3<Float>(geo.axisPoint),
                                                  axisDir: SIMD3<Float>(geo.axisDir))
                    out.append(ResolvedClearance(
                        groupID: g.id, faceID: Int(f),
                        volume: .bolt(faceID: Int(f), geometry: geo, axialSpan: span,
                                      marginMM: margin, axialMM: axial),
                        boreRadiusMM: Float(r), axialSpan: span))
                } else {
                    let depth = clearanceMetric(groupID: g.id, faceID: Int(f), role: .slabDepth)?.resolved
                        ?? ClearanceSuggestion.faceSlabDepthMM
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

    // MARK: - ★ THE LATTICE DEPTH PLANES (task 2026-08-14-lattice-separation §3d)

    /// ★ A DRAGGABLE DEPTH PLANE PER FACE OR PRIMITIVE, expanding outward from the
    /// face, dragged to set how far in the lattice may go.
    ///
    /// PR 328 built the slab's geometry and its number and put the DRAG on the
    /// card's numeric field, and said so. This is the 3D handle it did not get to.
    /// It is not new drag math: the plane is a `ClearanceVolume.slab` and the grab
    /// is a `ClearanceHandle(role: .slabDepth)` — the same tested pair the
    /// keep-clear face slabs have used since keep-clear Phase B. What is new is
    /// where the dragged number LANDS: `LatticeSettings.selectableDepthMM`, which is
    /// also the protection depth (bar R4).
    ///
    /// ★ THE NORMAL IS FLIPPED, and that is the whole difference from a keep-out.
    /// A clearance slab reaches OUT of the part (it is space that must stay empty);
    /// a lattice slab reaches IN (it is material that must be held and lightened).
    /// `LatticeRegionEmission.spec(for:role:depthMM:faceID:)` flips it for the same
    /// reason, so the plane on screen is the region in the job.
    public struct LatticeDepthPlane: Identifiable {
        public let ref: LatticeSelectableRef
        public let groupID: UUID
        /// The render/handle key: the run face id, or the manual sentinel.
        public let faceKey: Int
        public let role: LatticeGroupRole
        public let depthMM: Double
        public let volume: ClearanceVolume
        public let handle: ClearanceHandle
        public var id: String { ref.key }
    }

    /// Every lattice depth plane to draw and grab, in the selection's order.
    /// Empty when lattice mode is off or nothing is declared — the TO page hides
    /// these, and a page that has none draws none.
    public func latticeDepthPlanes() -> [LatticeDepthPlane] {
        guard lattice.enabled, let mesh = viewerMesh else { return [] }
        let roles = latticeEligibleRoles()
        var out: [LatticeDepthPlane] = []
        for g in selection.groups {
            guard let groupRole = roles[g.id] else { continue }
            // ★ A REGION GETS A DEPTH PLANE TOO (the interrupt's §2c). A region is
            // a voxel SET, not a surface, so the plane is built from the region's
            // OWN frame — PR 331's `FaceRegionGeometry.frame`, the same PCA/shared-
            // axis frame its split cuts use — and it is REFUSED rather than
            // invented when the members do not face one way. See
            // `latticeRegionDepthPlane`.
            for r in latticeRegionRefs(g) {
                guard let role = LatticeSelectableRoles.role(
                        for: r, groupRole: groupRole,
                        overrides: lattice.selectableRoles),
                      let rid = r.regionID,
                      let plane = latticeRegionDepthPlane(rid, ref: r, group: g.id,
                                                          role: role, in: mesh)
                else { continue }
                out.append(plane)
            }
            // ★ §2(a) — A PRIMITIVE IS ALWAYS CREATED, FOR EVERY FACE KIND.
            //
            // This loop used to require `geo.isPlane` and a plane outline, and
            // `continue`d silently otherwise. On his own part that skipped 19 of
            // the 22 faces he declares (86.4%) and 42 of the part's 78 (53.8%) —
            // measured by `lattice_primitive_probe`. The shape is now the
            // distance-field offset of the face's OWN surface (§2b,
            // `FaceOffsetShell`), which is one rule for planes, cylinders and
            // everything else, so there is nothing left to skip on.
            for f in g.faces {
                let ref = LatticeSelectableRef.face(group: g.id, face: f)
                guard let role = LatticeSelectableRoles.role(
                        for: ref, groupRole: groupRole,
                        overrides: lattice.selectableRoles)
                else { continue }
                let depth = latticeSlabDepthMM(ref, in: g.id)
                let key = Int(resolvedRunFaceID(f))
                guard let plane = latticeFacePrimitive(faces: [f], ref: ref,
                                                       group: g.id, key: key,
                                                       role: role, depthMM: depth,
                                                       in: mesh)
                else { continue }
                out.append(plane)
            }
            // A hand-placed FACE primitive is already a slab in its own frame, so
            // its axis is the region direction and needs no flip. A BOLT primitive
            // is a cylinder region — there is no depth to drag, so it gets no plane.
            for mp in force.manualPrimitives(for: g.id) where mp.kind == .face {
                let ref = LatticeSelectableRef.primitive(mp.id)
                guard let role = LatticeSelectableRoles.role(
                    for: ref, groupRole: groupRole,
                    overrides: lattice.selectableRoles) else { continue }
                let n = SIMD3<Float>(mp.axis)
                let (u, v) = planeBasis(normal: n)
                let outline = PlaneOutline(center: SIMD3<Float>(mp.center),
                                           uAxis: u, vAxis: v,
                                           halfU: Float(mp.halfUMM),
                                           halfV: Float(mp.halfWMM))
                let key = Self.manualFaceKey(mp.id)
                let depth = lattice.selectableDepthMM[ref.key] ?? mp.resolvedDepthMM
                let volume = ClearanceVolume.slab(faceID: key,
                                                  geometry: mp.syntheticGeometry,
                                                  outline: outline, depthMM: depth)
                guard let h = ClearanceHandles.handles(for: volume, boreRadiusMM: 0,
                                                       axialSpan: nil).first
                else { continue }
                out.append(LatticeDepthPlane(ref: ref, groupID: g.id, faceKey: key,
                                             role: role, depthMM: depth,
                                             volume: volume, handle: h))
            }
        }
        return out
    }

    /// Write a dragged depth for one selectable — THE one number (§3d/R4).
    /// Clamped through `LatticeSlabDepth` so a viewport drag cannot reach a depth
    /// the card could not.
    public func writeLatticeDepthMM(_ ref: LatticeSelectableRef, mm: Double) {
        lattice.selectableDepthMM[ref.key] = LatticeSlabDepth.clamp(mm)
    }

    /// ★ WRITE THE GROUP'S DEPTH — AND MAKE IT STICK (maintainer, 2026-08-14):
    /// *"I need to be able to drag the primitive OR put a number in the 'Depth'
    /// field and see the primitive pulled to that depth. They need to be locked
    /// together."*
    ///
    /// ★ THE DEFECT THIS REMOVES. The group drawer's field used to assign
    /// `lattice.groupDepthMM[group]` directly. But `LatticeSlabDepth.depthMM`
    /// resolves a PER-SELECTABLE override FIRST — so the moment the user dragged a
    /// primitive's knob (which writes `selectableDepthMM`), the group's field went
    /// inert for that face: the number in the drawer changed and the primitive did
    /// not move. Dragging the handle is the OTHER HALF of the feature he is
    /// asking for, so reaching this state is not an unusual sequence; it is the
    /// normal one.
    ///
    /// Setting the group's depth is a statement about the whole group, so it
    /// CLEARS the per-selectable overrides inside it. A later drag on one face
    /// re-establishes that face's own number, which is what a per-face drag means.
    public func writeGroupDepthMM(_ group: UUID, mm: Double) {
        lattice.groupDepthMM[group] = LatticeSlabDepth.clamp(mm)
        guard let g = selection.groups.first(where: { $0.id == group }) else { return }
        for ref in latticeSelectableRefs(g) {
            lattice.selectableDepthMM.removeValue(forKey: ref.key)
        }
    }

    /// ★ ONE REGION'S DEPTH PLANE — or nil, honestly.
    ///
    /// A face has a plane; a region does not. What a region has is PR 331's
    /// `FaceRegionGeometry.frame` — the PCA (or shared-cylinder) frame its split
    /// cuts are already expressed in — plus its members' own outward normals.
    ///
    /// ★ THE PLANE IS REFUSED WHEN THE MEMBERS DO NOT FACE ONE WAY, and that
    /// refusal is the honest half. A union wrapping a bore, or a union of a top
    /// face and a side face, has no single direction "into the part": any plane
    /// drawn for it would be a number the user could drag that means nothing.
    /// `agreement` is the length of the area-weighted mean of the members'
    /// outward unit normals — 1 when they are parallel, ~0 when they oppose — and
    /// the threshold is 0.75, which a flat union clears and a wrap does not.
    /// A region with no plane still carries its DEPTH (the drawer's number, and
    /// PR 331's per-sector protection depth); what it does not get is a 3D grab.
    public static let regionPlaneNormalAgreement = 0.75

    /// ★ §2(a)/§2(b) — THE ONE PRIMITIVE BUILDER, for a face row AND a region row.
    ///
    /// A region's primitive is the offset of its MEMBERS' combined surface, which
    /// is §2(b)'s "the primitive's shape matches the unioned face's shape" taken
    /// literally: a union of 24 blend faces offsets those 24 faces, not a box
    /// around them.
    ///
    /// The handle rides the shell's own extremes, so dragging it and typing the
    /// number are the same value (§2d) whatever the surface is.
    func latticeFacePrimitive(faces: [FaceID], ref: LatticeSelectableRef,
                              group: UUID, key: Int, role: LatticeGroupRole,
                              depthMM: Double,
                              in mesh: ViewerMesh) -> LatticeDepthPlane? {
        // ★ THE PRIMITIVE IS DRAWN AT THE EXPANDED SIZE (maintainer, 2026-08-17:
        // "Please make the primitive expand and contract along with the handle").
        // The SAME number `LatticeRegionEmission` grows the emitted slab by, read
        // through the SAME accessor — so the shape on screen and the region in
        // the job cannot drift apart.
        guard let shell = FaceOffsetShell.build(faces: faces, in: mesh,
                                                depthMM: depthMM,
                                                expandMM: latticeExpandMM(ref))
        else { return nil }
        let volume = ClearanceVolume.shell(faceID: key, shell: shell)
        guard let h = ClearanceHandles.handles(for: volume, boreRadiusMM: 0,
                                               axialSpan: nil).first
        else { return nil }
        return LatticeDepthPlane(ref: ref, groupID: group, faceKey: key, role: role,
                                 depthMM: depthMM, volume: volume, handle: h)
    }

    /// ★ ONE REGION'S PRIMITIVE — and it no longer refuses.
    ///
    /// This function used to return nil FOUR ways: no members, no member that is
    /// a PLANE (`g.isPlane`), normals that disagree by more than 0.75, and an
    /// invalid PCA frame. Three of those four are properties of the region being
    /// CURVED, which is exactly the case §2 asks to support — his own question
    /// was about a curved face, and he guessed "a doughnut shape".
    ///
    /// The distance-field rule answers it without a special case: the primitive is
    /// the region's own surface pushed inward, so a union wrapping a bore gets the
    /// tube it should get instead of nothing at all. The only remaining nil is
    /// "this region resolves to no triangles", which is not a shape question.
    func latticeRegionDepthPlane(_ rid: RegionID, ref: LatticeSelectableRef,
                                 group: UUID, role: LatticeGroupRole,
                                 in mesh: ViewerMesh) -> LatticeDepthPlane? {
        guard let region = faceRegions.region(rid) else { return nil }
        let members = FaceRegionGeometry.members(of: region, in: mesh)
        guard !members.isEmpty else { return nil }
        // The render/handle key is the REGION id, kept distinct from a face key by
        // construction: face keys are non-negative run face ids and manual
        // primitives use a negative sentinel, so region ids (≥ 100) collide with
        // neither.
        return latticeFacePrimitive(faces: members, ref: ref, group: group,
                                    key: rid, role: role,
                                    depthMM: latticeSlabDepthMM(ref, in: group),
                                    in: mesh)
    }

    /// A stable NEGATIVE sentinel face key for a manual primitive, so it never
    /// collides with a real (non-negative) B-rep/pseudo face id in the render +
    /// handle maps. Session-stable (rebuilt per frame from the geometry anyway).
    static func manualFaceKey(_ id: UUID) -> Int { -(abs(id.hashValue) % 1_000_000_000) - 1 }

    // MARK: - lattice region (handoff 2026-07-29-lattice-mode-ui)

    /// Place the lattice region as a hand-placed primitive, REUSING the manual-primitive
    /// value type + gizmo (no second placement mechanism, task requirement 2). Centred on
    /// the model, sized off the model radius so it is visible; the user then drags its
    /// gizmo (`moveLatticeRegion` / `rotateLatticeRegion`). Republishing arms the undo
    /// debounce (BAR U4) and the setting persists (BAR U3). No-op without a mesh.
    public func placeLatticeRegion(_ kind: ManualPrimitive.Kind) {
        guard let mesh = viewerMesh else { return }
        let c = SIMD3<Double>(mesh.bounds.center)
        let r = max(1.0, Double(mesh.bounds.radius))
        lattice.region = kind == .bolt
            ? .defaultBolt(at: c, radiusMM: r * 0.4, halfLengthMM: r * 0.8)
            : .defaultFace(at: c, halfMM: r * 0.5)
    }

    /// Move the lattice region to `freeCenter` with the SAME magnetic detents the manual
    /// primitives use (snap to world/part axes), returning the snap labels. Reuses
    /// `ManualPrimitiveDetent`; writes back onto `lattice.region` (undo via republish).
    @discardableResult
    public func moveLatticeRegion(to freeCenter: SIMD3<Double>, snap: Bool = true) -> [String] {
        guard var p = lattice.region else { return [] }
        let targets = snap ? ManualPrimitiveDetent.worldAxisTargets() : []
        let result = ManualPrimitiveDetent.apply(freeCenter: freeCenter, axis: p.axis, targets: targets)
        p.center = result.center
        p.axis = result.axis
        lattice.region = p
        return result.labels
    }

    /// Rotate the lattice region's orientation to `newAxis` with axis detents (its
    /// centre is unchanged), returning the snap labels. Mirrors `rotateManualPrimitive`.
    @discardableResult
    public func rotateLatticeRegion(to newAxis: SIMD3<Double>,
                                    from startAxis: SIMD3<Double>? = nil,
                                    snap: Bool = true) -> [String] {
        guard var p = lattice.region else { return [] }
        let targets = snap ? ManualPrimitiveDetent.worldAxisTargets() : []
        let result = ManualPrimitiveDetent.apply(freeCenter: p.center, axis: newAxis,
                                                 targets: targets, leavingAxis: startAxis)
        p.center = result.center
        p.axis = result.axis
        lattice.region = p
        return result.labels
    }

    /// The faces of `g` whose keep-clear primitives EXIST right now — the ONE
    /// listing rule (round-2 T5): bore-or-explicit, NOT suppressed, with usable
    /// B-rep geometry. The Selections panel's primitive rows, the renderer and
    /// the run all apply this same filter; before the fix the panel skipped the
    /// suppression check, so converting an auto clearance to a manual primitive
    /// (which suppresses the auto face) listed BOTH — a second primitive where
    /// only one exists.
    public func listedClearanceFaces(_ g: SelectionGroup) -> [FaceID] {
        guard let mesh = viewerMesh, keepClearIsOn(g) else { return [] }
        let explicit = force.keepClearAffix(for: g.id) == .on
        return g.faces.filter { f in
            (FaceTopology.isFastenerBore(f, in: mesh) || explicit)
                && !force.isClearanceFaceSuppressed(f)
                && mesh.faceGeometry(f) != nil
        }
    }

    // MARK: - lattice regions on the job (round-2, M3)

    /// Whether `group` acts as a LATTICE REGION right now: it carries a lattice
    /// role AND lattice mode is on. Gated on `lattice.enabled` so a TO-only job is
    /// byte-identical whatever roles a project stores (bar U1/B8): with lattice
    /// off, role groups' primitives stay ordinary keep-outs.
    public func isLatticeRegionGroup(_ id: UUID) -> Bool {
        lattice.enabled && lattice.groupRoles[id] != nil
    }

    /// The `lattice.regions` entries for the current project state (round-2, the
    /// emission the stale page copy said was impossible — PR 256's schema). Role
    /// groups' manual primitives + faces, plus the legacy include primitives.
    /// Slab depths resolve through the SAME metric chain the chips/volumes read.
    /// The `lattice.regions` entries for a job that lattices a FINISHED VARIANT
    /// (task 2026-08-02-lattice-a-variant, bar Z11).
    ///
    /// ONLY explicit geometry predicates. A variant is a marching-cubes
    /// iso-surface with no segmentation, so a face selection carried over from
    /// the setup page describes the ORIGINAL part's surface — geometry this
    /// design no longer has. Synthesising a region from it would place a keep-out
    /// or an include the user has never seen against the geometry it will
    /// actually affect: PR 261's resolve-against-the-wrong-geometry failure. Such
    /// faces are COUNTED (`skippedFaces`) so the page can say so, never emitted.
    public func variantLatticeJobRegions() -> LatticeRegionEmission.Result {
        guard lattice.enabled else { return .init(regions: [], skippedFaces: 0) }
        return LatticeRegionEmission.variantRegions(
            groups: selection.groups,
            roles: lattice.groupRoles,
            primitives: resolvedLatticePrimitives,
            includePrimitives: lattice.includePrimitives.map {
                ($0, $0.resolvedDepthMM) },
            groupDensities: lattice.groupDensities)
    }

    /// A role group's manual primitives with their slab depths resolved through
    /// the SAME metric chain the chips and the rendered volumes read — so run,
    /// picture and chips agree. Shared by the whole-part and variant emissions.
    private var resolvedLatticePrimitives: (UUID) -> [(prim: ManualPrimitive, depthMM: Double)] {
        { gid in
            self.force.manualPrimitives(for: gid).map { mp in
                let key = Self.manualFaceKey(mp.id)
                let d = self.clearanceMetric(groupID: gid, faceID: key, role: .slabDepth)?.resolved
                    ?? mp.resolvedDepthMM
                return (mp, d)
            }
        }
    }

    /// ★ THE ROLE GATE, APPLIED WHERE THE RUN IS BUILT (task 2026-08-12 §1a/§1d).
    /// A stored role whose group has since lost its eligibility — the user cleared
    /// its Protect, or affixed Keep clear — must not reach the job. Filtering here
    /// rather than pruning at each of the six places a role can change means no
    /// call site can forget: this is the ONE function the emission goes through.
    public func latticeEligibleRoles() -> [UUID: LatticeGroupRole] {
        var byID: [UUID: SelectionGroup] = [:]
        for g in selection.groups { byID[g.id] = g }
        return LatticeFaceRoleGate.pruned(roles: lattice.groupRoles) { id in
            guard let g = byID[id] else { return false }
            return LatticeFaceRoleGate.allowed(
                kind: force.kind(for: id), protected: force.isProtected(id),
                // EXPLICIT only — see LatticeFaceRoleGate.block.
                keepClearOn: force.keepClearAffix(for: id) == .on)
        }
    }

    public func latticeJobRegions() -> LatticeRegionEmission.Result {
        guard lattice.enabled else { return .init(regions: [], skippedFaces: 0) }
        let resolvedPrims: (UUID) -> [(prim: ManualPrimitive, depthMM: Double)] = { gid in
            self.force.manualPrimitives(for: gid).map { mp in
                let key = Self.manualFaceKey(mp.id)
                let d = self.clearanceMetric(groupID: gid, faceID: key, role: .slabDepth)?.resolved
                    ?? mp.resolvedDepthMM
                return (mp, d)
            }
        }
        return LatticeRegionEmission.regions(
            groups: selection.groups,
            roles: latticeEligibleRoles(),
            primitives: resolvedPrims,
            includePrimitives: lattice.includePrimitives.map { ($0, $0.resolvedDepthMM) },
            faceDepthMM: lattice.paintDepthMM,
            groupDepthMM: { [weak self] gid in
                self?.latticeSlabDepthMM(gid) ?? .nan
            },
            runFaceID: { [weak self] f in Int(self?.resolvedRunFaceID(f) ?? f) },
            // ★ §3c/§3d — the per-primitive role and depth overrides. Empty on
            // every project that has not used them ⇒ the emission is unchanged.
            selectableRoles: lattice.selectableRoles,
            selectableDepthMM: lattice.selectableDepthMM,
            groupDensities: lattice.groupDensities,
            // ★ THE PER-REGION DENSITY AND THE IN-PLANE EXPAND REACH THE JOB
            // (maintainer, 2026-08-17). A control whose value no run consumes is
            // the decorative-primitive defect — these two lines are what stop it,
            // and `LatticeSlabExpandTests` caught this one missing.
            selectableDensity: lattice.selectableDensity,
            selectableExpandMM: lattice.selectableExpandMM,
            resolve: resolvedLatticeFace)
    }

    /// A face's exact B-rep geometry as the emission needs it; nil when the face
    /// has none (STL pseudo-face, cone, spline). Extracted so the whole-part
    /// emission and the per-group one used by the density control resolve faces
    /// through ONE closure — two copies could disagree about which faces exist.
    private var resolvedLatticeFace: (FaceID) -> LatticeRegionEmission.ResolvedFace? {
        { [weak self] f in
                guard let mesh = self?.viewerMesh, let geo = mesh.faceGeometry(f) else { return nil }
                if geo.isCylinder {
                    guard let span = mesh.faceAxialSpan(
                        f, axisPoint: SIMD3<Float>(geo.axisPoint),
                        axisDir: SIMD3<Float>(geo.axisDir)) else { return nil }
                    return .cylinder(axisPoint: geo.axisPoint, axisDir: geo.axisDir,
                                     radiusMM: geo.cylinderRadiusMM,
                                     spanLoMM: Double(span.lo), spanHiMM: Double(span.hi))
                }
                if geo.isPlane {
                    guard let o = mesh.facePlaneOutline(
                        f, planeNormal: SIMD3<Float>(geo.planeNormal),
                        planeOrigin: SIMD3<Float>(geo.planeOrigin)) else { return nil }
                    return .plane(center: SIMD3<Double>(o.center), normal: geo.planeNormal,
                                  halfUMM: Double(o.halfU), halfWMM: Double(o.halfV))
                }
                return nil
        }
    }

    /// ★ THE PER-REGION DENSITY CONTROL'S ROWS (task
    /// 2026-08-16-per-sector-density-override, §3). One row per INCLUDE role
    /// group, each carrying core's own derivation for that group's thinnest
    /// region — the valid range, the cell, the strut, the cells-per-member.
    ///
    /// The regions are produced by `latticeJobRegions()` filtered to ONE group at
    /// a time through the same emission the run uses, so a group whose faces have
    /// no usable B-rep geometry contributes no row rather than a row about a
    /// region that will never be emitted. Run == picture, the whole page's rule.
    public func latticeSectorDensityRows() -> [LatticeSectorDensity.Row] {
        let roles = latticeEligibleRoles()
        // The emission's order is the selection's own: include primitives first,
        // then each role group's primitives and faces in group order. Rebuilding
        // per group by re-running the emission with a single-group selection is
        // the only way to attribute a region to its group WITHOUT a second
        // ordering assumption, and it is the same function either way.
        return LatticeSectorDensity.rows(
            groups: selection.groups, roles: roles,
            densities: lattice.groupDensities,
            regionsFor: { [weak self] gid in
                guard let self, let g = self.selection.groups.first(where: { $0.id == gid })
                else { return [] }
                return LatticeRegionEmission.regions(
                    groups: [g], roles: roles,
                    primitives: self.resolvedLatticePrimitives,
                    includePrimitives: [],
                    faceDepthMM: self.lattice.paintDepthMM,
                    groupDepthMM: { [weak self] id in self?.latticeSlabDepthMM(id) ?? .nan },
                    runFaceID: { [weak self] f in Int(self?.resolvedRunFaceID(f) ?? f) },
                    groupDensities: self.lattice.groupDensities,
                    selectableDensity: self.lattice.selectableDensity,
                    selectableExpandMM: self.lattice.selectableExpandMM,
                    resolve: { [weak self] f in self?.resolvedLatticeFace(f) }).regions
            },
            topology: lattice.topologyID,
            minExtrudableWidthMM: printParams.strutLineWidthMM)
    }

    // MARK: - lattice page role helpers (handoff 2026-07-30-lattice-page)
    //
    // The page's three region roles map onto three EXISTING, distinct concepts —
    // never a new parallel one (bar B3). Since round-2 the include/exclude
    // carriers are the unified library's GROUP ROLES (`lattice.groupRoles` →
    // `lattice.regions` on the job); the helpers below are the legacy stores,
    // kept working for old snapshots and their pinned tests:
    //   clearance       → a keep-clear group + manual primitive (loads.clearances)
    //   lattice-include → LatticeSettings.includePrimitives (now emitted as
    //                     role=include regions too)
    //   lattice-exclude → a protect group (loads.face_protections, FrozenSolid)

    /// Append a lattice-INCLUDE primitive, centred + sized off the model like the
    /// legacy single region. Returns its id. Undo via republish (BAR U4).
    @discardableResult
    public func addLatticeIncludePrimitive(_ kind: ManualPrimitive.Kind) -> UUID? {
        guard let mesh = viewerMesh else { return nil }
        let c = SIMD3<Double>(mesh.bounds.center)
        let r = max(1.0, Double(mesh.bounds.radius))
        let p: ManualPrimitive = kind == .bolt
            ? .defaultBolt(at: c, radiusMM: r * 0.4, halfLengthMM: r * 0.8)
            : .defaultFace(at: c, halfMM: r * 0.5)
        lattice.includePrimitives.append(p)
        return p.id
    }

    /// Update / remove an include primitive by id.
    public func updateLatticeIncludePrimitive(_ p: ManualPrimitive) {
        guard let i = lattice.includePrimitives.firstIndex(where: { $0.id == p.id }) else { return }
        lattice.includePrimitives[i] = p
    }
    public func removeLatticeIncludePrimitive(id: UUID) {
        lattice.includePrimitives.removeAll { $0.id == id }
    }

    /// Add a CLEARANCE primitive from the lattice page: a dedicated keep-clear
    /// group holding one hand-placed primitive, riding the exact machinery the
    /// workspace's manual clearances use (`ForceModel.addManualPrimitive` →
    /// `clearanceSpecs` → `loads.clearances`). Returns (group, primitive) ids.
    @discardableResult
    public func addLatticeClearancePrimitive(_ kind: ManualPrimitive.Kind) -> (group: UUID, primitive: UUID)? {
        guard viewerMesh != nil else { return nil }
        let gid = selection.addGroup()
        selection.rename(gid, to: "Clearance")
        guard let pid = addManualPrimitive(kind, to: gid) else { return nil }
        return (gid, pid)
    }

    /// The dedicated lattice-EXCLUDE (protect) group, created on first use. Its
    /// faces ship as `loads.face_protections` (FrozenSolid — material KEPT SOLID),
    /// the opposite polarity of a clearance; one protect concept, no twin.
    public func latticeExcludeGroupID(createIfNeeded: Bool) -> UUID? {
        if let g = selection.groups.first(where: { $0.name == Self.latticeExcludeGroupName }) {
            return g.id
        }
        guard createIfNeeded else { return nil }
        let gid = selection.addGroup()
        selection.rename(gid, to: Self.latticeExcludeGroupName)
        force.setProtected(gid, true)
        return gid
    }
    public static let latticeExcludeGroupName = "Lattice-exclude"

    /// Toggle a painted face for the page's paint pane. Include faces live on
    /// `LatticeSettings.paintedIncludeFaces` (preview scope — no job carrier, the
    /// reported gap); exclude faces live on the protect group above (a real job
    /// field). Returns true if the face is now painted.
    @discardableResult
    public func toggleLatticePaintFace(_ face: FaceID, role: LatticeRegionRole) -> Bool {
        switch role {
        case .include:
            let f = Int(face)
            if let i = lattice.paintedIncludeFaces.firstIndex(of: f) {
                lattice.paintedIncludeFaces.remove(at: i)
                return false
            }
            lattice.paintedIncludeFaces.append(f)
            return true
        case .exclude:
            guard let gid = latticeExcludeGroupID(createIfNeeded: true) else { return false }
            if let g = selection.groups.first(where: { $0.id == gid }), g.faces.contains(face) {
                selection.removeFaces([face], from: gid)
                return false
            }
            selection.addFaces([face], to: gid)
            force.setProtected(gid, true)
            return true
        case .clearance:
            return false   // the paint pane offers include/exclude only (the prototype's rule)
        }
    }

    // MARK: - manual primitive editing (handoff group-editing)

    /// Add a hand-placed primitive to `group` (the group the user is locked into).
    /// It is placed at the model centre and sized off the model radius so it is
    /// visible without editing; the user then moves it (with detents) and tunes the
    /// distances. Placing a keep-out implies keep-clear ON for the group, so the
    /// picture + run include it. Returns the new primitive's id. Republishing arms
    /// the undo debounce (BAR B5); the sidecar is refreshed (BAR B3).
    @discardableResult
    public func addManualPrimitive(_ kind: ManualPrimitive.Kind, to group: UUID) -> UUID? {
        guard let mesh = viewerMesh,
              selection.groups.contains(where: { $0.id == group }) else { return nil }
        let c = SIMD3<Double>(mesh.bounds.center)
        let r = max(1.0, Double(mesh.bounds.radius))
        let p: ManualPrimitive = kind == .bolt
            ? .defaultBolt(at: c, radiusMM: r * 0.08, halfLengthMM: r * 0.25)
            : .defaultFace(at: c, halfMM: r * 0.2)
        let id = force.addManualPrimitive(p, to: group)
        // A manual primitive is its OWN explicit keep-out — `clearanceSpecs` emits it
        // unconditionally, so we do NOT flip the group's keep-clear affix (which would
        // also, wrongly, start clearing the group's other selected faces).
        persistClearances()
        return id
    }

    /// Move a manual primitive to `freeCenter` with MAGNETIC DETENTS, returning the
    /// snap labels ("world Z axis", "co-axial", …) the UI surfaces. Snaps the axis to
    /// the world principal axes and to nearby group primitives, and the centre onto
    /// bore-axis points / other primitives — so a hand-placed keep-out lands parallel
    /// to and concentric with the part's real holes instead of askew. Pure detent math
    /// in `ManualPrimitiveDetent`; this supplies the targets and writes the result.
    @discardableResult
    public func moveManualPrimitive(id: UUID, in group: UUID,
                                    to freeCenter: SIMD3<Double>, snap: Bool = true) -> [String] {
        guard var p = force.manualPrimitives(for: group).first(where: { $0.id == id }) else { return [] }
        // Detent OVERRIDE (the gizmo's "magnet" toggle): with snap off, no targets are
        // offered, so the primitive follows the finger exactly — the explicit way to place
        // a keep-out a snap would otherwise pull off-target. (Dragging past the 3 mm / 8°
        // tolerance also releases a snap, since `apply` only snaps WITHIN tolerance.)
        let targets = snap ? manualDetentTargets(excluding: id, in: group) : []
        let result = ManualPrimitiveDetent.apply(freeCenter: freeCenter, axis: p.axis, targets: targets)
        p.center = result.center
        p.axis = result.axis
        force.updateManualPrimitive(p, in: group)
        persistClearances()
        return result.labels
    }

    /// Rotate a manual primitive's ORIENTATION to `newAxis` (its bolt axis_dir / face
    /// normal) with magnetic AXIS detents (snap to the world principal axes + nearby
    /// primitive/bore axes), returning the snap labels. The CENTRE is unchanged — rotation
    /// is about the primitive's own origin. Rotation is expressed PURELY by the direction
    /// vector (see `PrimitiveGizmo`'s schema note), so it reaches the run through `spec()`'s
    /// `axisDir`/`normal` with no schema change. Arms undo + refreshes the sidecar (G3).
    /// `from` is the orientation the drag GRABBED (its start axis). Passing it lets the
    /// detent drop the world/primitive axis the primitive is already sitting on, so a small
    /// turn is not snapped straight back to where it started — the 8° dead-zone that made all
    /// three ribbons read as dead (2026-07-27 ribbon-rotation fix). The axis still snaps to a
    /// DIFFERENT principal/bore axis as the drag approaches one. `nil` keeps the old behaviour.
    @discardableResult
    public func rotateManualPrimitive(id: UUID, in group: UUID,
                                      to newAxis: SIMD3<Double>, from startAxis: SIMD3<Double>? = nil,
                                      snap: Bool = true) -> [String] {
        guard var p = force.manualPrimitives(for: group).first(where: { $0.id == id }) else { return [] }
        let targets = snap ? manualDetentTargets(excluding: id, in: group) : []
        let result = ManualPrimitiveDetent.apply(freeCenter: p.center, axis: newAxis,
                                                 targets: targets, leavingAxis: startAxis)
        p.axis = result.axis                    // keep p.center — rotation is in place
        force.updateManualPrimitive(p, in: group)
        persistClearances()
        // Only AXIS-kind snaps are meaningful here (the centre didn't move).
        return result.snapped.filter { $0.kind != .point }.map(\.label)
    }

    /// COPY a manual primitive: an INDEPENDENT duplicate (fresh id) in the same group,
    /// nudged clear of the original so it doesn't hide it. Because `ManualPrimitive` is a
    /// value type the copy shares NO storage — editing it never touches the original (G6).
    /// Arms undo + refreshes the sidecar. Returns the new id (nil if the source is gone).
    @discardableResult
    public func copyManualPrimitive(id: UUID, in group: UUID) -> UUID? {
        guard let src = force.manualPrimitives(for: group).first(where: { $0.id == id }) else { return nil }
        let copy = ManualPrimitive(id: UUID(), kind: src.kind, center: src.center + copyOffset(for: src),
                                   axis: src.axis, radiusMM: src.radiusMM, halfLengthMM: src.halfLengthMM,
                                   halfUMM: src.halfUMM, halfWMM: src.halfWMM, override: src.override)
        let newID = force.addManualPrimitive(copy, to: group)
        persistClearances()
        return newID
    }

    /// A small model-space nudge so a copy is visibly distinct from its original — twice the
    /// primitive's own size, along the world axis most perpendicular to its axis.
    private func copyOffset(for p: ManualPrimitive) -> SIMD3<Double> {
        let size = p.kind == .bolt ? max(p.radiusMM, 1) : max(p.halfUMM, 1)
        let a = simd_abs(p.axis)
        let dir: SIMD3<Double> = (a.x <= a.y && a.x <= a.z) ? SIMD3(1, 0, 0)
                               : (a.y <= a.z) ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
        return dir * (size * 2)
    }

    /// Convert an AUTO-found clearance on `face` into an explicit MANUAL primitive so a
    /// gizmo can move/rotate it (G2 decision). An auto primitive's geometry is DERIVED from
    /// the B-rep face and re-read core-side every run — there is nowhere to store a dragged
    /// centre/axis. So the instant the user grabs its gizmo we MATERIALISE the face's current
    /// resolved geometry as a `ManualPrimitive` (carrying the exact override over, so no value
    /// jumps) and SUPPRESS the auto face — an EXPLICIT conversion in the model, never implicit.
    /// The manual primitive resolves to the identical mask (B2). Returns the new id, or nil for
    /// a face with no usable B-rep geometry (STL / non-cyl-non-planar).
    @discardableResult
    public func convertAutoClearanceToManual(face f: FaceID, in group: UUID) -> UUID? {
        guard let mesh = viewerMesh, let geo = mesh.faceGeometry(f) else { return nil }
        let ov = force.clearanceOverride(forGroup: group, face: f)
        let mp: ManualPrimitive
        if geo.isCylinder {
            let span = mesh.faceAxialSpan(f, axisPoint: SIMD3<Float>(geo.axisPoint),
                                          axisDir: SIMD3<Float>(geo.axisDir))
            let halfLen = span.map { Double(($0.hi - $0.lo)) * 0.5 } ?? geo.cylinderRadiusMM
            let mid = span.map { Double(($0.lo + $0.hi)) * 0.5 } ?? 0
            let center = geo.axisPoint + ManualPrimitive.unit(geo.axisDir) * mid
            mp = ManualPrimitive(kind: .bolt, center: center, axis: geo.axisDir,
                                 radiusMM: geo.cylinderRadiusMM, halfLengthMM: halfLen, override: ov)
        } else if geo.isPlane {
            let outline = mesh.facePlaneOutline(f, planeNormal: SIMD3<Float>(geo.planeNormal),
                                                planeOrigin: SIMD3<Float>(geo.planeOrigin))
            let halfU = outline.map { Double($0.halfU) } ?? ClearanceSuggestion.faceSlabDepthMM
            let halfW = outline.map { Double($0.halfV) } ?? ClearanceSuggestion.faceSlabDepthMM
            let center = outline.map { SIMD3<Double>($0.center) } ?? geo.planeOrigin
            mp = ManualPrimitive(kind: .face, center: center, axis: geo.planeNormal,
                                 halfUMM: halfU, halfWMM: halfW, override: ov)
        } else {
            return nil
        }
        let id = force.addManualPrimitive(mp, to: group)
        force.suppressClearanceFace(f)          // the auto face no longer clears (no double-count)
        persistClearances()
        return id
    }

    /// The detent targets for moving a primitive: the world principal axes, plus each
    /// OTHER group primitive's axis (for co-axial / parallel snaps) and centre, plus
    /// the group's bore faces' axis points (snap onto a real hole the finder found).
    private func manualDetentTargets(excluding id: UUID, in group: UUID) -> [PrimitiveSnapTarget] {
        var targets = ManualPrimitiveDetent.worldAxisTargets()
        var i = 0
        for other in force.manualPrimitives(for: group) where other.id != id {
            i += 1
            targets.append(.init(kind: .primitiveAxis, point: other.center, direction: other.axis,
                                 label: "primitive \(i)"))
            targets.append(.init(kind: .point, point: other.center, label: "primitive \(i) centre"))
        }
        if let mesh = viewerMesh, let g = selection.groups.first(where: { $0.id == group }) {
            for f in g.faces where FaceTopology.isFastenerBore(f, in: mesh) {
                if let geo = mesh.faceGeometry(f) {   // isFastenerBore ⇒ a fitted cylinder
                    targets.append(.init(kind: .primitiveAxis, point: geo.axisPoint,
                                         direction: geo.axisDir, label: "bore axis"))
                    targets.append(.init(kind: .point, point: geo.axisPoint, label: "bore centre"))
                }
            }
        }
        return targets
    }

    /// Edit a manual primitive's distance override (margin / axial / depth). `mm ==
    /// nil` reverts that field to the Auto suggestion, matching the auto-primitive
    /// chips. Republishes (undo) + refreshes the sidecar.
    public func setManualMargin(id: UUID, in group: UUID, mm: Double?) {
        mutateManual(id: id, in: group) { $0.override.concentricMarginMM = mm }
    }
    public func setManualAxial(id: UUID, in group: UUID, mm: Double?) {
        mutateManual(id: id, in: group) { $0.override.axialClearanceMM = mm }
    }
    public func setManualSlab(id: UUID, in group: UUID, mm: Double?) {
        mutateManual(id: id, in: group) { $0.override.slabDepthMM = mm }
    }

    /// Edit a manual PLANE's in-plane extents — the Length + Width exposure. The UI
    /// works in FULL extents (what a user measures across the slab with calipers), so
    /// the ÷2 to the core rasterizer's CENTRED half-extents (`half_u_mm`/`half_w_mm`)
    /// happens HERE, at the one boundary, and nowhere else. `fullMM` is the full
    /// length/width; an emptied field (nil) is IGNORED — an extent is the primitive's
    /// own geometry, not a clearance distance, so it has no "Auto" to revert to. A
    /// non-positive entry is floored to one grid step of half-extent so the slab never
    /// collapses to zero area. Length ↔ the U axis (`halfUMM`), Width ↔ the W axis
    /// (`halfWMM`); the (u,w) basis is derived from the normal identically for auto +
    /// manual. Mutating `force` arms the EXISTING undo debounce (B5/P4) and refreshes
    /// the sidecar (B3), exactly as the Depth override does.
    public func setManualLength(id: UUID, in group: UUID, mm fullMM: Double?) {
        guard let full = fullMM else { return }
        mutateManual(id: id, in: group) { $0.halfUMM = Swift.max(ClearanceQuantize.stepMM, full * 0.5) }
    }
    public func setManualWidth(id: UUID, in group: UUID, mm fullMM: Double?) {
        guard let full = fullMM else { return }
        mutateManual(id: id, in: group) { $0.halfWMM = Swift.max(ClearanceQuantize.stepMM, full * 0.5) }
    }
    private func mutateManual(id: UUID, in group: UUID, _ body: (inout ManualPrimitive) -> Void) {
        guard var p = force.manualPrimitives(for: group).first(where: { $0.id == id }) else { return }
        body(&p)
        force.updateManualPrimitive(p, in: group)
        persistClearances()
    }

    /// A group's manual primitives (for the locked editor).
    public func manualPrimitives(in group: UUID) -> [ManualPrimitive] {
        force.manualPrimitives(for: group)
    }

    /// Delete ONE manual primitive from a group (the "−" on its row).
    public func removeManualPrimitive(id: UUID, from group: UUID) {
        force.removeManualPrimitive(id: id, from: group)
        persistClearances()
    }

    /// DELETE an auto-found clearance primitive (the "−" on an auto bore/plane row):
    /// suppress that face's keep-out. Works on auto-found primitives, which is the
    /// more frequently used half because the finder OVER-finds. Persisted to the
    /// sidecar so it stays deleted across re-detect / resolution / re-import (B3).
    public func deleteAutoClearance(face: FaceID) {
        force.suppressClearanceFace(face)
        persistClearances()
    }

    /// Restore a deleted auto clearance (undo affordance).
    public func restoreAutoClearance(face: FaceID) {
        force.unsuppressClearanceFace(face)
        persistClearances()
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

    /// ONE cylindrical face's EXACT radius (mm), or nil for a planar / STL / manual face.
    private func faceBoreRadiusMM(_ f: FaceID) -> Double? {
        guard let mesh = viewerMesh, let geo = mesh.faceGeometry(f), geo.isCylinder else { return nil }
        return geo.cylinderRadiusMM
    }

    // MARK: - the single clearance-value source (DEFECT 1 fix)

    /// The resolved clearance metric (override + Auto) for ONE role of ONE clearance
    /// primitive, keyed by the SAME `(groupID, faceID)` the viewport handle carries and
    /// the Selections-panel row identifies. This is THE single value every surface reads:
    ///
    ///   • a MANUAL primitive (negative sentinel `faceID`) reads its OWN stored geometry +
    ///     override — the panel used to do this while the viewport chip fell back to a
    ///     B-rep face lookup that returned nil (→ 0 mm), the whole of DEFECT 1;
    ///   • an AUTO primitive (real `faceID`) reads the B-rep face's exact radius + the
    ///     group's effective override (per-bore when unsynced, shared when synced).
    ///
    /// Nil only when the face/primitive no longer exists. Callers render `.resolved`; the
    /// pill also gets `.override` (nil ⇒ show "Auto") and `.auto` (the suggestion).
    public func clearanceMetric(groupID: UUID, faceID: Int,
                                role: ClearanceMetric.Role) -> ClearanceMetric? {
        if faceID < 0 {
            guard let mp = force.manualPrimitives(for: groupID)
                .first(where: { Self.manualFaceKey($0.id) == faceID }) else { return nil }
            return mp.metric(role)   // the primitive's OWN single source
        }
        let f = FaceID(faceID)
        let ov = force.clearanceOverride(forGroup: groupID, face: f)
        switch role {
        case .margin:
            guard let r = faceBoreRadiusMM(f) else { return nil }
            return ClearanceMetric(override: ov.concentricMarginMM,
                                   auto: ClearanceSuggestion.boltMarginMM(boreRadiusMM: r))
        case .axial:
            guard let r = faceBoreRadiusMM(f) else { return nil }
            return ClearanceMetric(override: ov.axialClearanceMM,
                                   auto: ClearanceSuggestion.boltAxialMM(boreRadiusMM: r))
        case .slabDepth:
            return ClearanceMetric(override: ov.slabDepthMM, auto: ClearanceSuggestion.faceSlabDepthMM)
        }
    }

    /// WRITE one clearance role's value (mm; nil ⇒ revert to Auto), keyed by the SAME
    /// `(groupID, faceID)` as `clearanceMetric`. Routes a MANUAL primitive to its own
    /// override (arming undo + refreshing the sidecar) and an AUTO primitive to the
    /// group/bore override — so a viewport handle drag lands in the right place for
    /// both origins, not just the panel-only manual path it used to.
    public func writeClearanceMetric(groupID: UUID, faceID: Int,
                                     role: ClearanceMetric.Role, mm: Double?) {
        if faceID < 0 {
            guard let mp = force.manualPrimitives(for: groupID)
                .first(where: { Self.manualFaceKey($0.id) == faceID }) else { return }
            switch role {
            case .margin:    setManualMargin(id: mp.id, in: groupID, mm: mm)
            case .axial:     setManualAxial(id: mp.id, in: groupID, mm: mm)
            case .slabDepth: setManualSlab(id: mp.id, in: groupID, mm: mm)
            }
            return
        }
        let f = FaceID(faceID)
        switch role {
        case .margin:    force.setClearanceMargin(group: groupID, face: f, mm: mm)
        case .axial:     force.setClearanceAxial(group: groupID, face: f, mm: mm)
        case .slabDepth: force.setClearanceSlab(group: groupID, face: f, mm: mm)
        }
    }

    /// A group's model-space outward normal (mean of its faces' normals), or nil.
    private func groupNormalModel(_ g: SelectionGroup) -> SIMD3<Float>? {
        guard let mesh = viewerMesh else { return nil }
        var acc = SIMD3<Float>.zero
        var found = false
        for f in g.faces { if let nrm = mesh.faceNormal(f) { acc += nrm; found = true } }
        // ★ A REGION CONTRIBUTES ITS MEMBERS' NORMALS (task 2026-08-14-face-regions).
        // Without this a group holding ONLY a region would fall back to the +Z
        // default and a "normal to the face" load would point the wrong way —
        // silently, since nothing downstream can tell a defaulted normal from a
        // measured one.
        for r in g.regionIDs {
            guard let region = faceRegions.region(r) else { continue }
            for f in FaceRegionGeometry.members(of: region, in: mesh) {
                if let nrm = mesh.faceNormal(f) { acc += nrm; found = true }
            }
        }
        guard found else { return nil }
        let len = simd_length(acc)
        return len > 1e-6 ? acc / len : nil
    }

    /// A persistable snapshot of this project, or nil if there is no model to copy
    /// (an empty/legacy project can't be persisted). The model file is stored under
    /// a stable `model.<ext>` name so re-import dispatches by extension.
    public func snapshot(savedAt: Date) -> ProjectSnapshot? {
        guard let file = importedFile else { return nil }
        // The stored model's extension MUST match the working file's CONTENT (its
        // `path`), not the display `name`: a 3MF import is normalised to an STL
        // working copy (handoff 2026-07-26-3mf-optimize-path), so `path` is ".stl"
        // while `name` stays ".3mf". Naming the stored file model.3mf would make the
        // reopen re-import dispatch a 3MF reader over STL bytes and fail. The true
        // source name is preserved separately as `originalFileName`.
        let ext = (file.path as NSString).pathExtension.lowercased()
        let modelFileName = ext.isEmpty ? "model" : "model.\(ext)"
        return ProjectSnapshot(id: id, name: name, material: material, process: process,
                               modelFileName: modelFileName, originalFileName: file.name,
                               savedAt: savedAt, selection: selection, force: force,
                               minimizePlastic: minimizePlastic, quality: quality,
                               optimized: hasResults, printParams: printParams,
                               designBox: designBox,
                               lattice: lattice.enabled ? lattice : nil,
                               // Written ALWAYS, including when it is at the
                               // default — this is a setting the user can turn
                               // off, and "absent" already means ON, so an
                               // omitted-when-default rule would make the OFF
                               // state the only one that survives a reopen only
                               // by accident of which value it happened to be.
                               projectCADFaces: projectCADFaces,
                               faceRegions: faceRegions.isEmpty ? nil : faceRegions)
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

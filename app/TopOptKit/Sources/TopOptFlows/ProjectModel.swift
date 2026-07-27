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
        EditSnapshot(selection: selection, force: force, designBox: designBox, paint: paint)
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
    private func resolvedRunFaceID(_ id: FaceID) -> FaceID {
        paint?.resolvedFaceID(id) ?? id
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
                // Painted faces carry a live overlay id; the run sees the dense re-import id.
                anchors.append(contentsOf: g.faces.map { Int(resolvedRunFaceID($0)) })
            } else if kind.isLoad {
                let n = groupNormalModel(g) ?? SIMD3<Float>(0, 0, 1)
                if let f = force.loadForceVectorModel(g.id, groupNormal: n) {
                    loads.append(.init(faceIDs: g.faces.map { Int(resolvedRunFaceID($0)) },
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
            // MANUAL (user-placed) primitives are EXPLICIT keep-out the finder missed:
            // emitted unconditionally (they are their own declaration, independent of
            // the group's auto/affix state). Their inline geometry crosses the bridge
            // as a manual `ClearanceSpec` (handoff group-editing).
            for mp in force.manualPrimitives(for: g.id) { specs.append(mp.spec()) }

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
    public func faceProtectionSpecs() -> (faceIDs: [Int], depthMM: Double) {
        guard viewerMesh != nil else { return ([], force.faceProtectDepthMM) }
        var ids: [Int] = []
        var seen = Set<FaceID>()
        for g in selection.groups where force.isProtected(g.id) {
            for f in g.faces where !seen.contains(f) {
                seen.insert(f)
                ids.append(Int(resolvedRunFaceID(f)))
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
            // MANUAL primitives render through the SAME volume path via a synthetic
            // StepFaceGeometry, so the picture is built from the identical numbers the
            // run freezes. They carry a NEGATIVE sentinel faceID so they never collide
            // with a real face (handoff group-editing).
            for mp in force.manualPrimitives(for: g.id) {
                let key = Self.manualFaceKey(mp.id)
                let geo = mp.syntheticGeometry
                if mp.kind == .bolt {
                    let span: (lo: Float, hi: Float) = (Float(-mp.halfLengthMM), Float(mp.halfLengthMM))
                    // Render/run distances come from the SAME `clearanceMetric` the chips
                    // read (DEFECT 1) — so the picture, the run and both chips are one value.
                    let margin = clearanceMetric(groupID: g.id, faceID: key, role: .margin)?.resolved ?? mp.resolvedMarginMM
                    let axial = clearanceMetric(groupID: g.id, faceID: key, role: .axial)?.resolved ?? mp.resolvedAxialMM
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
                let bore = FaceTopology.isCurved(f, in: mesh)
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

    /// A stable NEGATIVE sentinel face key for a manual primitive, so it never
    /// collides with a real (non-negative) B-rep/pseudo face id in the render +
    /// handle maps. Session-stable (rebuilt per frame from the geometry anyway).
    static func manualFaceKey(_ id: UUID) -> Int { -(abs(id.hashValue) % 1_000_000_000) - 1 }

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
    @discardableResult
    public func rotateManualPrimitive(id: UUID, in group: UUID,
                                      to newAxis: SIMD3<Double>, snap: Bool = true) -> [String] {
        guard var p = force.manualPrimitives(for: group).first(where: { $0.id == id }) else { return [] }
        let targets = snap ? manualDetentTargets(excluding: id, in: group) : []
        let result = ManualPrimitiveDetent.apply(freeCenter: p.center, axis: newAxis, targets: targets)
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
            for f in g.faces where FaceTopology.isCurved(f, in: mesh) {
                if let geo = mesh.faceGeometry(f), geo.isCylinder {
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

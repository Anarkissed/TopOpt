// FlexibleMainStage — the MAIN Flexible page's side of the Flexible stage (task
// 2026-09-29-flexible-screens, round 3 batch B, item 7.1; maintainer: "no Generate/Lattice
// button — Save & Exit builds it and it shows on the MAIN Flexible page").
//
// ★ THE LATTICE OUTLIVES THE PAGE. The Settings page's FlexibleStageModel was a @StateObject
// of the page, so Exit threw the lattice away with it. The ONE model per project now lives
// here, owned by WorkspacePlaceholder (`@StateObject flexibleMain`, hook H1), and the page
// observes it (H2). Exit → `didExitSettings()` → the lattice builds (waiting for designs
// still in flight) and the main page draws it, squishing inside the X-ray part.
//
// ★ COARSE STATE ONLY. WorkspacePlaceholder's body is 11.7k lines: this object publishes
// only what changes the picture (`generation`, the three views, the model's arrival) — never
// the squish (the renderer steps FlexibleSquishLoop itself), never a drag. Nothing here
// recomputes or builds while a full-screen page is up (frozen).
//
// ★ ITS HOOKS (each one line in #354's WorkspacePlaceholder; the exact list is in the
// handoff): `model(for:…)` (H2), `layer(_:stage:pageUp:)` (H3), `mesh` / `tints` / `dents` /
// `dentScale` / `bodyAlpha` / `owns` (H4), FlexibleMainViewToggles (H5),
// FlexibleMainStatusPill (H10) and FlexibleMainPlayerSlot (the squish player).

import Combine
import Foundation
import simd
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
public final class FlexibleMainStage: ObservableObject {

    // MARK: coarse published state

    /// Bumped when what the main page DRAWS changed (overlay, tints, dents, the lattice).
    @Published public private(set) var generation = 0
    /// Bumped when the shared model arrives (a new project, or the first visit).
    @Published public private(set) var attached = 0
    /// The views (batch B's minimum — batch C adds Stress and the legends).
    @Published public var heat = true { didSet { if oldValue != heat { refresh() } } }
    /// ★ ROUND 4 (C2 — his img 5: "the xray and lattice view … both seem to require one another
    /// … remove the xray view selector if the lattice view is going to use the rendering
    /// anyways"): the Lattice VIEW is his one choice. Shown, the part is the X-ray ghost with the
    /// walls inside; hidden, it is the solid part (Dent heat / Stress read on it). On by default.
    @Published public var latticeOn = true { didSet { if oldValue != latticeOn { refresh() } } }
    /// What the Lattice button shows as on, and what is drawn: his choice AND a lattice to show
    /// (one drawn, or one on its way without Settings — `latticeAvailable`).
    public var latticeShown: Bool { latticeOn && latticeAvailable }
    /// ★ C2: X-ray is no longer a button — it is the Lattice view's rendering (the walls are only
    /// ever seen through the ghost), so the two are on together and off together.
    /// ★ BATCH M (M6, his round-5 img 6: "When the dent view is selected, the xray view should also
    /// initiate (that's why there is no point to include the actual button), showing the lattice (if
    /// selected) as a ghost and the dents bending through the ghosts … make it solid"): the DENT view
    /// turns X-ray on too — the body a ghost, the dent planes solid; with the lattice shown its walls
    /// are a ghost as well (`ghostWalls`, the layer's).
    public var xray: Bool { latticeShown || dentXray }
    /// The dent view is on and has a map to show (kept by `refresh` — read on every body pass).
    public var dentXray: Bool { heat && dentMapShown }
    var dentMapShown = false
    /// The walls are drawn as a ghost under the solid dent planes (the dent view and the lattice on).
    public var ghostWalls: Bool { dentXray && latticeShown }
    public func toggleLattice() {
        latticeOn = !latticeShown
    }
    /// ★ C2: a lattice to show — drawn, or coming without Settings (the scene opening, a build or
    /// its designs in flight, nothing blocking, no failed build). Kept here (read on every
    /// workspace body pass by `bodyAlpha`), recomputed in `refresh` — never per body pass.
    public internal(set) var latticeAvailable = true
    /// ★ C2 (his answer 2): Settings was opened by the Lattice VIEW button (nothing to show) —
    /// its Save & Exit turns the view on.
    var showLatticeOnExit = false
    /// ★ C2: a build this stage started has not landed yet — when it does, the note says so once.
    var awaitingReady = false
    /// ★ C2 (his answer 2: "a notification should show up when it is ready"): the one-line note
    /// under the view row. Its own object — a note coming and going never re-runs the workspace.
    public let note = FlexibleMainNote()
    /// ★ C2 (his answer 2: "when Lattice Ready shows, tapping it should send to Core and the
    /// export path"): core's Flexible runner and the Export step (its own object, observed only
    /// by the pill and the Export mount).
    public let coreRun = FlexibleCoreRun()
    /// ★ C2 VERIFICATION: how the pill takes him to the Lattice stage (H10 hands it over with each
    /// tap) — builds start only there.
    var goToLattice: (() -> Void)?

    // MARK: batch C — Stress, the legends, tap-to-read (FlexibleMainStage+Views.swift)

    /// ★ STRESS (item T): the solid part's FEA from the main page's loads, coloured over the
    /// part. Off by default. ★ BATCH C VERIFICATION: on, it takes the pressed map from Heat (one
    /// colouring of the map at a time — toggleStress); X-ray and the lattice are left alone.
    @Published public var stress = false
    /// The reading a tap pinned while a legend is drilled in (one publish per tap).
    @Published public internal(set) var reading: FlexibleReading?
    /// Legends he minimised (the caret), and the one placed first (a pill he tapped open).
    @Published public var minimized: Set<FlexibleReadKind> = []
    @Published public var legendPriority: FlexibleReadKind?
    /// ★ BATCH M (M4): the ONE legend card folded to its column of bars (the caret; a tap opens it).
    @Published public var legendMinimized = false
    /// The workspace's solve (H5' and H2 hand over a FlexibleStressSolver — `attach`): run only
    /// when there is no field for these inputs, never twice (FlexibleStressTrigger).
    var stressSolver: (() -> Void)?
    /// ★ BATCH C VERIFICATION: what the solve is doing — the sim's own phase, or why it could not
    /// start — ONE published value (it failed silently on his project: "No stress yet" for ever).
    @Published public internal(set) var stressState: FlexibleStressState = .idle
    /// ★ BATCH M: on the FE route only while Stress is ON (the sims run with every lattice — the Stress
    /// button must not read "Simulating…" when he never asked for Stress).
    var stressRunning: Bool { feStressRoute ? (stress && stressView.isRunning) : stressState.isRunning }
    /// The sim whose phase is observed, and that observation.
    weak var stressSim: LatticeSimModel?
    var stressPhaseObservation: AnyCancellable?
    /// The field the page shows (stashed from H4's call), its identity and its peak.
    var stressField: LatticeDemandField?
    var stressKey = 0
    var stressPeak = 0.0
    /// The lattice legend's two ends and span, per lattice generation (a full scan of the mask —
    /// never per body pass), and how many scans were made (tests).
    var latticeEndsCache: (generation: Int, span: ClosedRange<Double>, lo: String, hi: String)?
    var latticeSpanScans = 0
    /// The view the tap came through (H6 hands the projection and the settle each render).
    var viewFrame: LatticeBandChipFrame?
    /// Tests only: the view's direction, pinned.
    var controlViewDirection: SIMD3<Float>?
    /// The composed ONE tint array, and what it was composed from.
    var composedKey: String?
    var composed: [Float]?
    /// The lattice whose depths the map shows (refresh), and the map's deepest value (mm).
    private(set) var drawn: FlexibleGeneratedLattice?
    private(set) var dentMaxMM = 0.0

    /// The squish, one number, stepped by the renderer (FlexibleSquishLoop).
    public let loop = FlexibleSquishLoop()
    /// ★ ROUND 4 (D2): the squeeze the player shows (a group, or all at once) — nil ⇒ the
    /// lattice's default (its first group). One publish per pick.
    @Published public private(set) var shownSim: String?
    /// What the player can pick: the lattice's sims (each group, then all at once).
    public var sims: [FlexibleSim] { model?.lattice?.sims ?? [] }
    /// The player's picker: that squeeze's faces squish (the dent and the walls); the walls'
    /// field is the same lattice (a faces-only upload — FlexibleLatticeLayerInputs.facesToken).
    public func pick(_ id: String) {
        guard shownSim != id else { return }
        shownSim = id
        model?.squishSolver.promote(id)   // ★ BATCH G: a pick of a sim still solving runs next
        refresh()
        // ★ BATCH G: a pick while playing starts that squeeze from rest (the swap never pops)
        if fe.active, loop.playing { loop.restartFromRest(reduceMotion: reduceMotion()) }
    }
    /// The lattice as the player shows it: only the picked squeeze's faces squish.
    public var shownLattice: FlexibleGeneratedLattice? { model?.lattice?.showing(playingSim) }
    /// ★ BATCH G VERIFICATION: the squeeze on screen — the pick, or, when EVERY sim of "Play all"
    /// failed, the first group (its column squish plays; never every group's faces at once).
    var playingSim: String? { fallbackSim ?? shownSim }
    /// The sim on screen (nil: one group — nothing to pick).
    public var shownSimInfo: FlexibleSim? { sims.count > 1 ? shownLattice?.shownSim : nil }
    /// ★ ONE LINE when the shown group squishes less than it was designed for (another group's
    /// firmer material wins where they share): "Group 2 squishes 1.2 of 3.0 mm · firmer wins".
    public var simNote: String? {
        // ★ BATCH G: the sims' own line wins while it lasts ("Simulating the squish…")
        if let n = feNote { return n }
        // ★ BATCH G: "Play all" (the default with two groups) is the whole lattice — its note is the
        // first group's miss (FlexibleGeneratedLattice.simNote(for: "all"))
        guard let g = shownLattice, let id = g.shownSimID ?? g.shownSim?.id else { return nil }
        return g.simNote(for: id)
    }
    public private(set) var model: FlexibleStageModel?
    private var projectID: UUID?
    private var observation: AnyCancellable?
    /// ★ BATCH B REVIEW: the PROJECT, observed too — the main page's own edits (a new grid, a
    /// lattice region, a group's weight, an undo) reach the lattice without Settings opening.
    private var projectObservation: AnyCancellable?
    /// The main page's loads as last acted on (the groups and their forces).
    private var seenLoads: (groups: [SelectionGroup], force: ForceModel)?
    /// A full-screen page (Settings) is up: nothing recomputes or builds under it.
    public private(set) var frozen = false
    /// The main page is showing the Flexible lattice stage.
    public private(set) var visible = false
    /// How the page saves the project (handed over by H2's call).
    private var persistHook: () -> Void = {}
    /// What the page last told `layer` (so a change is acted on once, off the view update).
    private var seen: (owned: Bool, pageUp: Bool, project: UUID?)?

    // the picture, cached (rebuilt on a model change, never per body evaluation)
    private(set) var overlay: FlexibleOverlayMesh?
    private var overlayKey: String?
    private(set) var channels: FlexiblePageChannels.Channels?
    private var channelsKey: String?
    /// The lattice generation the loop last auto-played for.
    private var playedGeneration: Int?
    // ★ BATCH G: the squish sims (FlexibleMainStage+Squish)
    /// The FE view of the lattice on screen (refreshed with the picture, never per frame).
    var fe = FlexibleFEView()
    /// Each field's mesh displacements on the overlay, keyed by (overlay, field).
    var feMeshCache: [String: (key: String, mesh: [Float])] = [:]
    /// ★ BATCH M (M5): each field's dent heat at every map vertex (FlexibleMainStage+Squish.feMapValues).
    var feValueCache: [String: (key: String, values: [Float])] = [:]
    /// ★ BATCH M (M3): each field's stress (FlexibleMainStage+Stress.feStress).
    var feStressCache: [String: (key: String, field: LatticeDemandField, peak: Double)] = [:]
    /// The heat's values the map is coloured by NOW (FE: the field shown first; else the corner means)
    /// — a tap reads them (H7), so the number is the colour under it.
    var heatValues: [Float]?
    /// Test control only: one colour per column (the blocks of his img 5 — the red control of M5).
    var controlColumnHeat = false
    /// Bumped per overlay rebuild (the mesh cache and the pass's FE token follow it).
    var overlaySerial = 0
    /// The lattice generation the loop started its FE sequence for (from rest).
    var fePlayedGeneration: Int?
    // ★ BATCH G VERIFICATION: the loop starts by (generation, the sequence ASKED FOR) — not by the
    // generation alone, which left a failed only sim at rest and a pick that landed late unplayed
    /// The FE sequence the loop last started (or saw playing): "generation|sim,sim".
    var feStartedKey: String?
    /// The column fallback the loop last auto-played: "generation|sim,sim".
    var fallbackKey: String?
    /// The loop was held at rest while the shown sims ran ("Simulating the squish…") — what lands
    /// next (a field, or the fallback) plays from rest.
    var heldForSims = false
    /// Every sim of "Play all" failed: the group whose column squish plays instead.
    var fallbackSim: String?
    /// "Play all": each landed group's own tints before composition (refresh), and the composed
    /// ones the renderer swaps in with the group's field.
    var feBaseTints: [String: [Float]] = [:]
    let feTintBox = FlexibleFETints()
    /// Test controls only: batch G's loop rules (one start per generation) — the red control of the
    /// keys above; the sims read BEFORE they are started (the Save & Exit flash); "Play all" as the
    /// combo (every group's colours for every turn, every failed group's faces at once).
    var controlLoopByGeneration = false
    var controlReadSimsBeforeStart = false
    var controlPlayAllCombo = false
    /// ★ the gate: another core solve runs (the Stress view's sim, a topology run) — FlexibleStressSolver.busy
    var squishBusy: (() -> Bool)?
    /// The Stress solve waited for a sim (it starts when the sims go idle).
    var stressWaiting = false
    var squishIdleObservation: AnyCancellable?
    /// Test control only: draw today's COLUMN squish even with the sims landed (the BEFORE renders).
    var controlColumnSquish = false
    /// Test control only: a failed sim holds the loop at rest (no column fallback — the red control).
    var controlNoFallback = false
    /// Tests: the next refresh rebuilds the overlay (a mesh rebuild mid Play all).
    func forceOverlayRebuildForTests() { overlayKey = nil }
    /// Reduced motion (tests pin it).
    var reduceMotion: () -> Bool = {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        false
        #endif
    }

    public init() {
        // ★ C2 VERIFICATION: the Export step's buttons act through the stage (the model, the note,
        // the way to the Lattice stage are its)
        coreRun.onFix = { [weak self] f in self?.coreFix(f) }
        // ★ BATCH G: a Stress solve that waited for a squish sim starts when the last one leaves core
        squishIdleObservation = NotificationCenter.default.publisher(for: FlexibleSquishSolver.idleNotification)
            .sink { [weak self] _ in self?.squishIdle() }
    }

    // MARK: the one model per project (H2)

    /// The ONE model for `project`, made once and kept across Settings open / Exit (the page
    /// observes it). Called from the page's init: it neither publishes nor starts work.
    public func model(for project: ProjectModel, materialsPath: String?, stampsPath: String?,
                      persist: @escaping () -> Void) -> FlexibleStageModel {
        persistHook = persist
        return ensure(project, materialsPath: materialsPath, stampsPath: stampsPath)
    }

    @discardableResult
    private func ensure(_ project: ProjectModel, materialsPath: String? = FlexibleResources.materialsPath,
                        stampsPath: String? = FlexibleResources.stampsPath) -> FlexibleStageModel {
        if let m = model, projectID == project.id { return m }
        let m = FlexibleStageModel(project: project, materialsPath: materialsPath, stampsPath: stampsPath,
                                   persist: { [weak self] in self?.persistHook() })
        model = m
        projectID = project.id
        overlay = nil; overlayKey = nil; channels = nil; channelsKey = nil; playedGeneration = nil
        // (called from a view's init: publish nothing unless a previous project left it playing)
        if loop.playing || loop.held != 1 { DispatchQueue.main.async { [loop] in loop.hold(1) } }
        // ★ D2: another project's squeeze pick does not carry over (async: never inside an update)
        if shownSim != nil { DispatchQueue.main.async { [weak self] in self?.shownSim = nil } }
        observation = m.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.modelChanged() }
        // ★ BATCH G: no sim starts beside another core solve; a Stress solve it held back starts after
        m.squishSolver.busy = { [weak self] in self?.squishBusy?() ?? false }
        m.squishSolver.onIdle = { [weak self] in self?.squishIdle() }
        fe = FlexibleFEView(); feMeshCache = [:]; feValueCache = [:]; feStressCache = [:]; fePlayedGeneration = nil
        feStartedKey = nil; fallbackKey = nil; heldForSims = false; fallbackSim = nil; feBaseTints = [:]; feTintBox.set([:])
        seenLoads = nil
        projectObservation = project.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.projectChanged() }
        return m
    }

    /// RED CONTROL: batch G's loop rules as they were (one FE start per generation; the column path
    /// auto-plays once per generation, the pre-pending refresh included).
    private func controlBatchGLoop(_ g: FlexibleGeneratedLattice) {
        if fe.active {
            loop.sequenceCount = fe.sequence.count
            if fePlayedGeneration != g.generation {
                fePlayedGeneration = g.generation
                playedGeneration = g.generation
                loop.restartFromRest(reduceMotion: reduceMotion())
            }
        } else if fe.pending || (controlNoFallback && fe.failure != nil) {
            loop.sequenceCount = 1
            if loop.playing || loop.held != 0 { loop.hold(0) }
        } else if playedGeneration != g.generation {
            loop.sequenceCount = 1
            playedGeneration = g.generation
            loop.autoPlay(reduceMotion: reduceMotion())
        }
    }

    /// Settings' Save & Exit (H2's onExit): back on the main page, build the lattice — now if
    /// the designs are in, else as soon as they land (`modelChanged`).
    /// ★ BATCH C VERIFICATION: H2 hands the solver over HERE too — it used to arrive only from
    /// the toggles' body, which had not rendered yet when Settings opened in the same action
    /// that made the stage Flexible, so the first Exit started nothing.
    public func didExitSettings(solver: FlexibleStressSolver? = nil) {
        if let solver { attach(solver) }
        frozen = false
        visible = true
        model?.checkStampShown = nil
        model?.pendingFix = nil
        model?.retryFailedBuild()   // his Save & Exit asks for the build: a failed one is tried once more
        // ★ C2: Settings opened by the Lattice view button (nothing to show) — Exit shows the view
        if showLatticeOnExit { showLatticeOnExit = false; latticeOn = true }
        noteLoads()        // what Settings did to the groups (a weight written back) is in hand
        refresh()
        buildIfReady()
        // ★ BATCH C (item T) — re-solved on Exit only while Stress SHOWS: nothing on screen reads
        // a field otherwise, and an unasked solve competes with the lattice build Exit starts
        if stress { requestStressIfNeeded() }
    }

    /// The pill's tap: the page opens on the one thing to fix.
    public func openFix() {
        guard let m = model else { return }
        m.pendingFix = m.readiness.blocking.first
    }

    // MARK: what the main page reads (pure reads — safe inside the body)

    /// The stage is the Flexible lattice stage.
    public func owns(_ project: ProjectModel, _ stage: WorkspaceStage) -> Bool {
        stage == .lattice && project.lattice.flexible != nil
    }

    func current(_ project: ProjectModel, _ stage: WorkspaceStage) -> FlexibleStageModel? {
        guard owns(project, stage), let m = model, projectID == project.id else { return nil }
        return m
    }

    /// H3: the lattice for the main MetalMeshView — hidden under a full-screen page, looping in
    /// the renderer when shown. Also where the page's visibility is noted (acted on async).
    public func layer(_ project: ProjectModel, stage: WorkspaceStage, pageUp: Bool) -> FlexibleLatticeLayerInputs? {
        note(project, owned: owns(project, stage), pageUp: pageUp)
        guard let m = current(project, stage) else { return nil }
        let fresh = m.lattice != nil && !m.latticeIsStale
        // ★ ROUND 4 (D2): the picked squeeze's faces squish
        var inputs = FlexibleLatticePreview.inputs(xray: xray, lattice: m.lattice?.showing(playingSim), building: m.latticeBuilding,
                                                   latticeShows: latticeOn && fresh && !pageUp,
                                                   loop: fresh && !pageUp ? loop : nil)
        // ★ BATCH G: the squeeze groups' fields, their meshes and the sequence the loop plays
        if fe.active, fresh, !pageUp {
            inputs?.fe = fe.fields; inputs?.feMesh = fe.mesh; inputs?.feSequence = fe.sequence; inputs?.feToken = fe.token
            inputs?.feTints = feTintBox   // ★ "Play all": each group's own colours, swapped in with its field
            // ★ BATCH M (M3): Stress on — the walls take each group's own stress (the sequence's one scale)
            if stress, feStressRoute, stressDrawable, feStressPeak > 0 { inputs?.stressInvMPa = Float(1 / feStressPeak) }
        }
        inputs?.ghostWalls = ghostWalls   // ★ BATCH M (M6): the dent view ghosts the walls under the solid planes
        return inputs
    }

    /// H4: the overlay mesh (the part with every pressed face's map quads), nil ⇒ the stage's.
    public func mesh(_ project: ProjectModel, on stage: WorkspaceStage) -> ViewerMesh? {
        current(project, stage) != nil ? overlay?.mesh : nil
    }
    public func dents(_ project: ProjectModel, on stage: WorkspaceStage) -> [Float]? {
        // ★ BATCH G: in FE mode the mesh of the sim the RENDERER shows (a rebuild re-uploads it)
        current(project, stage) != nil && overlay != nil ? shownDents : nil
    }
    /// The static scale (k × the held amount); the renderer's loop overrides it while it drives.
    public func dentScale(_ project: ProjectModel, on stage: WorkspaceStage) -> Float {
        guard dents(project, on: stage) != nil, let k = channels?.exaggeration else { return 0 }
        return Float(k * loop.held)
    }
    public func bodyAlpha(_ project: ProjectModel, on stage: WorkspaceStage) -> Float? {
        owns(project, stage) ? (xray ? FlexibleStagePage.xrayBodyAlpha : 1) : nil
    }

    /// The squish player shows only when there is something to squish: a lattice that still
    /// matches the settings, on the visible main page.
    public var playerShown: Bool {
        guard visible, !frozen, let m = model, m.lattice != nil, !m.latticeIsStale, channels?.dents != nil else { return false }
        return true
    }
    /// The player's full end ("10 kg").
    public var fullLabel: String {
        guard let m = model else { return "Full load" }
        let shown = Set(shownLattice?.squishedKeys.map(\.region) ?? [])
        return FlexibleSquishLoop.fullLabel(weightsKg: m.settings.loadedFaces.filter { shown.contains($0.faceRegionID) }.map(\.weightKg),
                                            shapeOnly: m.lattice?.shapeOnly == true)
    }

    /// The bottom pill (H10).
    public var status: FlexibleMainStatus {
        FlexibleMainStatus.of(model: model)
    }

    // MARK: ★ C2 VERIFICATION — Ready sends what he set NOW (edits on another stage included)

    /// The main page moved since the stage last read it: a new scene (grid, region, bead), the
    /// groups or their forces (a weight typed on Topology), or the settings behind the pipeline
    /// (an undo). The stage re-reads the main page only while it shows (`projectChanged`).
    func mainPageMoved(_ m: FlexibleStageModel) -> Bool {
        let p = m.project
        let key = m.currentSceneKey
        let failed: Bool = { if case .failed = m.sceneState { return true } else { return false } }()
        let sceneMoved = (m.sceneState == .ready && key != m.openedKey) || (failed && key != m.openAttemptKey)
        let loadsMoved = seenLoads.map { $0.groups != p.selection.groups || $0.force != p.force } ?? true
        return sceneMoved || loadsMoved || m.settingsOutranPipeline
    }

    /// The big button's Ready: send the job Settings describes to core's Flexible runner and open
    /// the Export step. ★ C2 VERIFICATION (the verifier's V4): tapped on another stage after a
    /// main-page edit there, C2 sent the job from BEFORE the edit (the group is the one source of
    /// truth — his weight never reached core). The model catches up first; if the lattice no
    /// longer matches, nothing is sent: it rebuilds (on the Lattice stage) and Ready comes back.
    public func sendToCore() {
        guard let m = model else { return }
        if mainPageMoved(m) {
            let before = m.settings
            noteLoads()
            m.openScene()   // (the same scene: re-reads the groups at once; a new one re-opens)
            refresh()
            if m.settings != before || m.sceneState != .ready || m.lattice == nil || m.latticeIsStale {
                rebuildFirst()
                return
            }
        }
        coreRun.send(m)
    }

    /// The lattice must be rebuilt before anything is sent: on the Lattice stage it builds (now,
    /// or when the designs land); elsewhere the pill takes him there, where builds start.
    func rebuildFirst() {
        if visible { buildIfReady() } else { goToLattice?() }
        note.post(.building)
    }

    /// A button of the Export step: send what core can run, or use the filament with data (the
    /// step closes; the lattice rebuilds and "Lattice ready" says when).
    func coreFix(_ f: FlexibleCoreFix) {
        guard let m = model else { return }
        switch f {
        case .send:
            coreRun.send(m, fix: f)
        case .useFilament(let id, _):
            m.pickMaterial(id)
            coreRun.close()
            rebuildFirst()
        }
    }

    // MARK: reacting (never inside a view update)

    private func note(_ project: ProjectModel, owned: Bool, pageUp: Bool) {
        let now = (owned: owned, pageUp: pageUp, project: owned ? project.id : nil)
        if let s = seen, s.owned == now.owned, s.pageUp == now.pageUp, s.project == now.project { return }
        seen = now
        DispatchQueue.main.async { [weak self, weak project] in
            guard let self, let project else { return }
            self.apply(project, owned: owned, pageUp: pageUp)
        }
    }

    func apply(_ project: ProjectModel, owned: Bool, pageUp: Bool) {
        frozen = pageUp
        visible = owned && !pageUp
        guard owned else { return }
        let isNew = model == nil || projectID != project.id
        let m = ensure(project)
        if isNew { attached &+= 1 }
        guard visible else { return }
        noteLoads()
        m.openScene()
        refresh()
        buildIfReady()
    }

    /// ★ BATCH G: the sims went idle — a Stress solve that waited for them starts now.
    func squishIdle() {
        guard stressWaiting, !FlexibleSquishSolver.solving else { return }
        stressWaiting = false
        stressSolver?()
    }

    private func modelChanged() {
        guard !frozen, visible else { return }
        refresh()
        buildIfReady()
    }

    func noteLoads() {
        guard let p = model?.project else { return }
        seenLoads = (p.selection.groups, p.force)
    }

    /// ★ THE MAIN PAGE'S OWN EDITS (batch B review). The stage heard only the model, so a new
    /// grid (quality), a new lattice region (a group's role), a new bead, a group's weight —
    /// and the two-finger UNDO, which restores `lattice.flexible` behind the model's back —
    /// left the old lattice "ready", or a stale one hidden behind "Building…" with no build.
    /// Now: the scene the project describes differs from the one opened, the groups moved,
    /// or the settings moved without the pipeline ⇒ `openScene()` (a new key re-opens; the same
    /// key re-reads the groups and re-runs the designs), and the lattice rebuilds when they
    /// land. Debounced, only while the stage shows, never under Settings.
    func projectChanged() {
        guard !frozen, visible, let m = model, m.sceneState != .opening else { return }
        if mainPageMoved(m) {
            noteLoads()
            m.openScene()
            refresh()
        }
        buildIfReady()
        // ★ BATCH C: a main-page edit (a load, an anchor) leaves the stress field stale — while
        // Stress shows, the solver re-runs it (it checks the fingerprint; nothing runs twice)
        if stress { requestStressIfNeeded() }
    }

    /// Build when nothing blocks and the designs are in: the first time the stage shows, after
    /// Exit, and whenever a later edit left the lattice stale — never per drag (the model's
    /// changes reach here debounced, and nothing builds while Settings is up).
    func buildIfReady() {
        guard let m = model, !frozen, m.sceneState == .ready, !m.latticeBuilding,
              m.lattice == nil || m.latticeIsStale,
              // ★ a build that failed on these settings and this scene is not retried (it
              // looped: the failure published, the page rebuilt, it failed …); an edit or a new
              // scene clears it
              m.latticeFailure == nil else { return }
        let r = m.readiness
        guard r.isReady, !r.designing else { return }
        m.generateLattice()
        awaitingReady = true   // ★ C2: the note says "Lattice ready" when this build lands
    }

    /// The picture from the model: the overlay (rebuilt only when the pressed faces' stacks
    /// change — a new mesh reframes the camera), then its tints and dents.
    func refresh() {
        guard let m = model else { return }
        // ★ C2: what the Lattice button and the X-ray read (once per refresh, never per body pass)
        latticeAvailable = FlexibleLatticeView.available(model: m)
        noteBuildLanded(m)
        let keys = m.loadedKeys.filter { m.stacks[$0] != nil && m.geometry[$0] != nil }
        let oKey = keys.map { "\($0.region)/\($0.rotation)" }.joined(separator: ",") + "|" + m.regions.key
        if overlayKey != oKey {
            // ★ BATCH C VERIFICATION: the part's triangles cut fine enough for the Stress colours
            // (his pad is 12 triangles); the dent's geometry is unchanged
            // ★ BATCH G: … and no coarser than the squish sim's grid, so a big flat triangle bends
            // with the lattice skin inside it (known from the scene before the first overlay)
            let stressEdge = m.project.viewerMesh.map(FlexibleOverlayMesh.stressEdgeMM)
            let feEdge = m.sceneInfo.map { FlexibleFE.spacing(sceneNX: $0.nx, ny: $0.ny, nz: $0.nz, spacing: $0.spacing) }
            overlay = FlexiblePageChannels.overlay(model: m, maxEdgeMM: [stressEdge, feEdge].compactMap { $0 }.min())
            overlayKey = oKey
            overlaySerial &+= 1
            feMeshCache = [:]
        }
        // the map is the lattice's while one is shown (X-ray only gates the walls here)
        var drawn = FlexibleLatticePreview.drawn(m.lattice?.showing(shownSim), xray: true, building: m.latticeBuilding,
                                                 checkStampShown: nil, stale: m.latticeIsStale)
        // ★ BATCH G: the squeeze groups' 3D sims (started here — the shown sim first)
        fe = feView(m, drawn: drawn)
        // ★ BATCH G VERIFICATION: every sim of "Play all" failed — the FIRST group's column squish
        // plays, the picker showing it (the column path has one squeeze at a time; "Play all" there
        // squished every group's faces at once — the combo his round-5 (a) rejects)
        fallbackSim = nil
        if fe.failure != nil, fe.requested.count > 1, !controlPlayAllCombo, let first = fe.requested.first {
            fallbackSim = first
            drawn = FlexibleLatticePreview.drawn(m.lattice?.showing(first), xray: true, building: m.latticeBuilding,
                                                 checkStampShown: nil, stale: m.latticeIsStale)
            fe = feView(m, drawn: drawn)
        }
        self.drawn = drawn
        // ★ BATCH C: the channels WITHOUT the ghost — Stress and the group colours are composed
        // in first (FlexibleMainTints), then X-ray ghosts what is not opaque
        // ★ BATCH M (M5, M2b): in FE mode the heat IS the sim's dent — at every vertex of the shown
        // group's faces, on ONE scale over the groups of the sequence (Play all's turns compare)
        let feNow = feHeat(m)
        var c = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: false, drawnLattice: drawn, heat: heat,
                                              depthScaleMM: feNow?.scaleMM, mapValues: feNow?.first,
                                              controlColumnColours: controlColumnHeat)
        let shown = FlexibleShownValues(model: m, drawnLattice: drawn)
        dentMaxMM = feNow?.scaleMM ?? shown.maxDepth
        heatValues = c.mapValues
        dentMapShown = overlay?.flatStart.isEmpty == false && dentMaxMM > 0   // ★ BATCH M (M6): the dent view's X-ray
        // ★ BATCH G: the field moves the ghost, the heat plane and the walls; ×k capped so the map
        // stays injective (the planes never cross)
        feBaseTints = playAllBaseTints(m, scaleMM: dentMaxMM)
        if fe.active {
            c.exaggeration = FlexibleShownValues.cappedExaggeration(rule: shown.uncappedExaggeration, maxSafeScale: fe.safeScale)
            c.dents = feShownMesh
        }
        loop.exaggeration = c.exaggeration
        if let g = drawn {
            let asked = "\(g.generation)|" + fe.requested.joined(separator: ",")
            if controlLoopByGeneration {
                controlBatchGLoop(g)
            } else if fe.active {
                loop.sequenceCount = fe.sequence.count
                if feStartedKey != asked {
                    feStartedKey = asked
                    // the FIRST field of a new lattice, or the shown sequence coming out of "Simulating
                    // the squish…" (a pick of a sim still solving): from REST (sim 0). A pick of a sim
                    // already landed keeps his play / pause (pick() restarts a playing loop).
                    if fePlayedGeneration != g.generation || heldForSims {
                        fePlayedGeneration = g.generation
                        playedGeneration = g.generation
                        heldForSims = false
                        loop.restartFromRest(reduceMotion: reduceMotion())
                    }
                }
            } else if fe.pending || (controlNoFallback && fe.failure != nil) {
                // the sims run: the lattice is shown, held at rest ("Simulating the squish…")
                loop.sequenceCount = 1
                heldForSims = true
                feStartedKey = nil
                if loop.playing || loop.held != 0 { loop.hold(0) }
            } else if fe.failure != nil {
                // ★ the FALLBACK plays: the column squish, once per lattice and sequence — whenever the
                // sims had held it at rest, or on a new lattice
                loop.sequenceCount = 1
                feStartedKey = nil
                if fallbackKey != asked {
                    fallbackKey = asked
                    if heldForSims || playedGeneration != g.generation {
                        heldForSims = false
                        playedGeneration = g.generation
                        loop.autoPlay(reduceMotion: reduceMotion())
                    }
                }
            } else if playedGeneration != g.generation {
                loop.sequenceCount = 1
                playedGeneration = g.generation
                loop.autoPlay(reduceMotion: reduceMotion())   // (held still while a legend reads)
            }
        } else if loop.playing || loop.held != 1 {
            loop.hold(1)   // his live drawing (no lattice) holds at the full squish
        }
        let key = [String(describing: c.tints.map { VertexTintKey($0).hash }),
                   String(describing: (fe.active ? nil : c.dents).map { VertexTintKey($0).hash }),   // (FE: the token below)
                   "\(c.exaggeration)", "\(drawn?.generation ?? -1)", "\(drawn?.facesToken ?? -1)", "\(m.latticeBuilding)",
                   "\(m.lattice?.generation ?? -1)", "\(m.latticeIsStale)", oKey, "\(latticeAvailable)",
                   "\(fe.token)", "\(fe.sequence)", "\(fe.pending)", fe.failure ?? "", "\(xray)", "\(stress)"].joined(separator: "|")
        channels = c
        if channelsKey != key {
            channelsKey = key
            generation &+= 1
        }
    }
}

/// What the bottom pill says (H10), as a value.
public struct FlexibleMainStatus: Equatable, Sendable {
    /// ★ C2 VERIFICATION: `preview` — the lattice preview is built, but core can't take the job
    /// as it stands (a pinch, several squeeze groups, a calibrate-first filament —
    /// FlexibleCoreHold): never the Ready green; its tap opens the Export step on why.
    public enum Tone: Equatable, Sendable { case ready, building, fix, idle, preview }
    public let line: String
    public let tone: Tone
    /// The issue a tap opens Settings on.
    public let fix: FlexibleIssue?

    /// ★ BATCH B REVIEW: the pill reads "Lattice" over this line, so the line never says
    /// "Lattice" again ("Lattice / Lattice ready").
    public static let opening = "Opening the part…"
    /// Before the stage opened this project this session (another stage's bar): a tap goes to
    /// the Lattice stage and opens Settings.
    public static let notOpened = "Tap to open"
    public static let building = "Building…"
    public static let ready = "Ready"

    /// The rule: the one thing to fix (readiness.oneLine) → a failed build (core's words; ★
    /// batch B review: it was "Building…" for ever) → building (opening, designing, no
    /// lattice yet, stale) → ★ C2 VERIFICATION: a PREVIEW when core can't take the job as it
    /// stands (`hold`: a pinch, several squeeze groups; the shape-only label for a
    /// calibrate-first filament) → ready.
    public static func of(readiness: FlexibleReadiness?, sceneReady: Bool, isBuilding: Bool,
                          lattice: FlexibleGeneratedLattice?, stale: Bool, failure: String? = nil,
                          hold: String? = nil) -> FlexibleMainStatus {
        guard let r = readiness, sceneReady else { return .init(line: opening, tone: .building, fix: nil) }
        // ★ the SHORT form (it truncated mid-sentence at 11" portrait); the pop-up says it whole
        if let first = r.blocking.first { return .init(line: first.pill, tone: .fix, fix: first) }
        if let failure, !isBuilding { return .init(line: FlexibleReadiness.buildFailedLine(failure), tone: .fix, fix: nil) }
        if isBuilding || r.designing || lattice == nil || stale { return .init(line: building, tone: .building, fix: nil) }
        // ★ C2 VERIFICATION: what core can't take as it stands is a preview, never the Ready green
        // (the hold is the one source: a calibrate-first filament's hold carries his shape-only label)
        if let hold { return .init(line: hold, tone: .preview, fix: nil) }
        return .init(line: lattice?.shapeOnlyLabel ?? ready, tone: .ready, fix: nil)
    }

    @MainActor
    public static func of(model m: FlexibleStageModel?) -> FlexibleMainStatus {
        guard let m else { return .init(line: notOpened, tone: .idle, fix: nil) }
        if case .failed = m.sceneState { return .init(line: "The part could not be opened", tone: .fix, fix: nil) }
        return of(readiness: m.sceneState == .ready ? m.readiness : nil, sceneReady: m.sceneState == .ready,
                  isBuilding: m.latticeBuilding, lattice: m.lattice, stale: m.latticeIsStale, failure: m.latticeFailure,
                  hold: m.coreHoldKind.map { FlexibleCoreHold.pill($0, shapeOnlyLabel: m.lattice?.shapeOnlyLabel) })
    }
}

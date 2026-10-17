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
    /// ★ ROUND 7 (F, his answer 13): every group's heat (his 3 s hold on the heat icon).
    @Published public internal(set) var heatAll = false
    /// ★ ROUND 7 (F): the region of the face he last tapped on the main page (its squeeze group is the "selected" one).
    var tappedRegion: Int?
    /// ★ ROUND 4 (C2 — his img 5): the Lattice VIEW, on by default. ★ ROUND 7, X1: a plain show / hide — shown, the lattice
    /// is drawn (in the printed view with X-ray off, inside the ghost with X-ray on); hidden, the solid part. It never turns
    /// X-ray on (C2's "the Lattice view IS the X-ray" was reversed by R7-V, its last coupling by X1).
    @Published public var latticeOn = true { didSet { if oldValue != latticeOn { refresh(); if latticeOn { bakeDeferred() } } } }   // ★ S9: a bake a Save & Exit left for the view
    /// What the Lattice button shows as on, and what is drawn: his choice AND a lattice to show
    /// (one drawn, or one on its way without Settings — `latticeAvailable`).
    public var latticeShown: Bool { latticeOn && latticeAvailable }
    /// ★ ROUND 7, R7-V (his img5, 2026-10-14: "Please re-add the x-ray view icon. In the default view, we should be able to
    /// see the model +the finish in the latticed area"): X-RAY IS ITS OWN ICON AGAIN — heat and the lattice no longer force
    /// it (REVERSES C2, his round-4 img 5, and M6's "the dent view turns X-ray on", his round-5 img 6). ★ R7-V REVIEW: his
    /// choice is kept per project for the session (`xrayChoice`). ★ ROUND 7, X1: OFF by default for every finish (R7-V's
    /// stopgap — on for None / Rim / Skin — is retired; the printed view shows the lattice with X-ray off): `xrayDefault`.
    @Published var xrayChoice: [UUID: Bool] = [:]
    public var xrayOn: Bool {
        get { xrayChoice[projectID ?? Self.noProject] ?? xrayDefault }
        set {
            guard newValue != xrayOn else { return }
            xrayChoice[projectID ?? Self.noProject] = newValue
            refresh()
        }
    }
    /// ★ ROUND 7, X1 (his answer on the R7-V handoff's Q9, 2026-10-14: "X-ray mode should show the inside of the SOLID showing
    /// the extent of the face prism/bend amount/heat map etc. The lattice should be visible without x-ray on as long as finish
    /// is set to something that isn't 'covered'. These two things are not mutually exclusive."): X-RAY IS OFF BY DEFAULT,
    /// WHATEVER THE FINISH. R7-V's stopgap — the default followed the finish (ON for None / Rim / Skin, so his None pad's
    /// lattice was not hidden behind an opaque body) — is RETIRED: the PRINTED VIEW (`printedView`) now shows the lattice
    /// with X-ray off. His tap is still kept per project for the session (`xrayChoice`).
    /// RED CONTROL `controlXrayByFinish`: R7-V's stopgap (with M1's rule inside it: no face-prism, no X-ray).
    var xrayDefault: Bool {
        guard controlXrayByFinish else { return false }
        return (model?.settings.finishMode ?? .covered) != .covered
            && (model.map { $0.sceneState != .ready || $0.facePrismsSet } ?? true)
    }
    static let noProject = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    /// ★ X1, test controls only (each the rule it reverses): R7-V's X-ray stopgap (on by the finish); R7-V's "a view that
    /// needs another turns it on itself" for the Lattice icon and [Prisms] (both turned X-ray on); R7-V's walls only in X-ray
    /// (no printed view — out of X-ray an opaque body hid every wall).
    var controlXrayByFinish = false
    var controlViewsForceXray = false
    var controlNoPrintedView = false
    /// The body is the ghost (his X-ray icon). RED CONTROL `controlXrayIsLatticeView`: C2 + M6's derived rule.
    public var xray: Bool { controlXrayIsLatticeView ? (latticeShown || dentXray) : xrayOn }
    /// ★ ROUND 7, X1 — THE PRINTED VIEW (his Q9 answer: "If lattice is on without x-ray view, we see the lattice plus the
    /// solid"): X-ray off, the Lattice view on (a lattice to show) and a finish that leaves the lattice open — None (the walls
    /// run to the surface), Rim (bands at the edges), Skin (a perforated sheet). The page then shows the SOLID part (opaque,
    /// correctly sorted) with the lattice where the finish leaves it open; Covered is the plain model (the print). The walls
    /// are marched with the printed solid (FlexibleLatticeField.printedSolid — the skin, the pocket's own wall and floor),
    /// the body is see-through with its closed surface flagged solid and written into the G-buffer by the pass
    /// (FlexibleLatticePass.encodeBody). RED CONTROL `controlNoPrintedView`.
    public var printedView: Bool { !controlNoPrintedView && !xray && latticeShown && finishLeavesLatticeOpen }
    /// The finish is not Covered (core still gets only Covered as a solid skin — FlexibleFinish.jobSkinOn).
    var finishLeavesLatticeOpen: Bool { (model?.settings.finishMode ?? .covered) != .covered }
    /// …and DRAWN now: a fresh lattice, not building, no full-screen page up. The layer's `printed`, the body's alpha (0:
    /// only its closed surface draws) and the tints' solid flags all read THIS one rule — a see-through body with no pass to
    /// draw its closed surface would vanish.
    func printedDrawn(_ m: FlexibleStageModel) -> Bool {
        printedView && m.lattice != nil && !m.latticeIsStale && !m.latticeBuilding && !frozen
    }
    /// ★ ROUND 7, X1 VERIFY (the verify: the layer read `printedDrawn && !pageUp`, the body alpha `printedDrawn` alone, the
    /// open flags needed an overlay — with no overlay the body went see-through with nothing flagged solid, and the part
    /// would vanish): ONE rule for the layer's `printed`, the body alpha 0 and the tints' open surface — the printed view
    /// drawn AND its open surface known (an overlay). The layer adds `!pageUp` (its walls hide under a page at once); the
    /// body alpha and the tints follow the page a turn later (`frozen`) — that frame is under the full-screen page, and its
    /// closed surface still draws (flagged solid), so nothing vanishes. RED CONTROL `controlPrintedRulesApart` (X1's rules).
    func printedReady(_ m: FlexibleStageModel) -> Bool {
        printedDrawn(m) && (controlPrintedRulesApart || overlay != nil)
    }
    var controlPrintedRulesApart = false
    /// Tests only: the overlay dropped (the state the one rule guards — no open surface to flag).
    func dropOverlayForTests() { overlay = nil; overlayKey = nil }

    /// ★ ROUND 7, X1 VERIFY — THE HEAT ON THE WALLS (FlexibleWallHeat). His Q9 answer (2026-10-14): "X-ray mode should show the
    /// inside of the SOLID showing the extent of the face prism/bend amount/heat map etc. … If the user adds x-ray, we see
    /// through the solid." The verify: with Heat on, X-ray kept the pressed face's heat as an OPAQUE lid — from his img5 top
    /// camera one heat-coloured square, none of the lattice (its blocker); in the printed view the heat lay only on the solid
    /// part, a flat 0 mm blue (his img3: "The view of the heatmap doesn't actually change anything"). Now, with Heat on and the
    /// walls DRAWN (X-ray, or the printed view), the walls carry the squish of their column on the legend's scale, and the lid
    /// stops hiding them (X-ray: a faint heat skin; the printed view: the solid part is the plain part). REVERSES batch M's
    /// M6 ghost walls under the solid dent planes (his round-5 img 6) in that state, by his Q9 words. RED CONTROL
    /// `controlHeatOnLid` (X1's first build).
    public var heatOnWalls: Bool {
        guard !controlHeatOnLid, heat, !stress, wallHeatTable != nil, let m = model, m.facePrismsSet, dentMaxMM > 0 else { return false }
        return wallsDrawn(m)
    }
    /// The walls are DRAWN now (what `layer` hands the pass, a page aside): a fresh lattice, not building, his Lattice view on —
    /// in X-ray, or in the printed view.
    func wallsDrawn(_ m: FlexibleStageModel) -> Bool {
        latticeOn && m.lattice != nil && !m.latticeIsStale && !m.latticeBuilding && !frozen && (xray || printedReady(m))
    }
    /// The walls' heat for the lattice on screen (made in `refresh` — never per body pass).
    var wallHeatTable: FlexibleWallHeat?
    /// The lid (the pressed faces' map) carries no heat: the walls do (X-ray), or the printed view opens it over the lattice
    /// and its solid part is the plain part (it does not squish — no flat 0 mm lid).
    var lidWithoutHeat: Bool {
        guard !controlHeatOnLid, heat, !stress, let m = model else { return false }
        return heatOnWalls || printedReady(m)
    }
    /// The heat IS drawn somewhere — the walls, or the lid (the 19:45 ruling: the legend, TAP TO READ and the reading's
    /// reset need heat actually drawn). Under the red control: X1's rule (no such check).
    var heatDrawn: Bool { controlHeatOnLid || heatOnWalls || !lidWithoutHeat }
    /// Test control only (X1 verify): X1's first build — the heat only on the lid (opaque in X-ray, M6's ghost walls under it;
    /// the closed part's flat 0 mm in the printed view), the walls by density, the legend's rows regardless.
    var controlHeatOnLid = false
    /// Test control only (X1 verify): the Lattice icon under Covered says nothing (X1's first build).
    var controlNoCoveredNote = false
    /// The walls are SEEN: in X-ray, or (★ X1) in the printed view — the lattice legend shows then.
    public var wallsShown: Bool { latticeShown && (xray || (finishLeavesLatticeOpen && !controlNoPrintedView)) }
    /// ★ X1: the Lattice icon is a plain show / hide — lit by his view (and a lattice to show), never by X-ray (R7-V's handoff
    /// Q10, answered by his Q9 words). Under Covered with X-ray off the view stays his: its walls are seen in X-ray.
    public var latticeIconLit: Bool { controlViewsForceXray ? wallsShown : latticeShown }
    /// The dent view is on and has a map to show (kept by `refresh` — read on every body pass).
    /// (★ R7-V: no longer turns X-ray on — it decides only whether the walls are a ghost under its solid planes.)
    public var dentXray: Bool { heat && dentMapShown && !dentOnColumnFallback }
    var dentMapShown = false
    /// ★ BATCH M VERIFICATION: the map is the column squish of a drawn lattice (the FE field is not driving
    /// it) — kept by `refresh`.
    var dentOnColumnFallback = false
    /// The walls are drawn as a ghost under the solid dent planes (the dent view and the lattice on, in X-ray).
    /// ★ X1 VERIFY: never while the walls carry the heat (they are solid then, the lid a faint skin — `heatOnWalls`).
    public var ghostWalls: Bool { dentXray && latticeShown && xray && !heatOnWalls }
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
    /// ★ ROUND 7, R7-D1 (the redesign's step 0): ONE card at a time on the main page — the Setup tray, the Lattice card, the
    /// blocker callout (D1), D2's face chip and a keypad (FlexibleChromeState).
    public let chrome = FlexibleChromeState()
    /// ★ R7-D1: the main page's viewport (the views row measures it; the corner pair, inside #354's bar, cannot).
    public let chromeGeometry = FlexibleChromeGeometry()
    /// ★ R7-D1: which blockers already popped above the pair this session (each new one pops once).
    var calloutRule = FlexibleCalloutRule()
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
    var playingSim: String? { fallbackSim ?? selectedSim }   // ★ ROUND 7 (F): the selected group (first by default)
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
    var playedGeneration: Int?
    // ★ BATCH G: the squish sims (FlexibleMainStage+Squish)
    /// The FE view of the lattice on screen (refreshed with the picture, never per frame).
    var fe = FlexibleFEView()
    /// Each field's mesh displacements on the overlay, keyed by (overlay, field).
    var feMeshCache: [String: (key: String, mesh: [Float])] = [:]
    /// ★ BATCH M (M5): each field's dent heat at every map vertex (FlexibleMainStage+Squish.feMapValues).
    var feValueCache: [String: (key: String, values: [Float])] = [:]
    /// ★ X1 VERIFY: each field's compression per column of its group's faces (the walls' heat — `feColumnValues`).
    var feColumnCache: [String: (key: String, values: [FlexFaceKey: [Double?]])] = [:]
    /// ★ BATCH M (M3): each field's stress (FlexibleMainStage+Stress.feStress) — its peak and its scale's top.
    var feStressCache: [String: (key: String, field: LatticeDemandField, peak: Double, top: Double)] = [:]
    /// Test controls only (★ BATCH M VERIFICATION's red controls): batch M's Stress route (only a FRESH
    /// lattice — a stale one fell to the solid part's solve); one scale at the sequence's PEAK; the
    /// legend's words from the sims landed only; the dent view's X-ray on the column fallback too.
    var controlStressRouteNeedsFreshLattice = false
    var controlStressScaleIsPeak = false
    var controlStressWordsByActiveOnly = false
    var controlDentXrayOnFallback = false
    /// Test control only: the dent row's "×k" without the fold cut (batch M's label — "×1" over a ¼ motion).
    var controlDentLabelIgnoresFold = false
    /// The heat's values the map is coloured by NOW (FE: the field shown first; else the corner means)
    /// — a tap reads them (H7), so the number is the colour under it.
    var heatValues: [Float]?
    /// Test control only: one colour per column (the blocks of his img 5 — the red control of M5).
    var controlColumnHeat = false
    /// Bumped per overlay rebuild (the mesh cache and the pass's FE token follow it).
    var overlaySerial = 0
    /// ★ ROUND 6: the main page's prisms, and the state they were built for (`volumes`).
    var volumesCache: (key: String, items: [ClearanceRenderItem])?
    /// ★ ROUND 7, X1: the printed view's open surface, and the overlay / lattice it was found for (`printedOpen`).
    var openCache: (key: String, open: [Bool])?
    /// ★ ROUND 7, M1: the picked group's face-prisms, and what they were built from (`volumes`).
    var facePrismCache: (inputs: FacePrismInputs, items: [ClearanceRenderItem])?
    /// ★ S1b: the model's views, observed (`ensure`).
    private var viewsObservation: AnyCancellable?
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
    /// Test control only (round 6, item 1 — it retires the S + M merge's `controlTurnsWithoutFrames`): round 5's
    /// group frames painted on the main page's model, in every view and every Play-all turn.
    var controlRound5Frames = false
    /// ★ "A group's prism only after a pick" (his answer of 2026-10-09; batch V's view setting, fixed ON by R7-V —
    /// FlexibleMainPickSession): he picked a group in this session — the selection as last seen, and its observation (from
    /// the stage's first look at the project on).
    public internal(set) var sessionPicked = false
    var lastSelection: SelectionModel?
    var selectionObservation: AnyCancellable?
    /// ★ BATCH V REVIEW ("Prism after a pick"): an Undo or a Redo re-writes the selection (ProjectModel.applyEditSnapshot) —
    /// never his pick. The history as last seen, its observation, and "the next selection write is a restore's".
    var lastUndo: UndoHistory?
    var undoObservation: AnyCancellable?
    var restoreWritePending = false
    /// Test control only (batch V review): an Undo / Redo's selection write counted as a pick (as batch V built it).
    var controlUndoIsAPick = false
    /// ★ R7-V, test controls only (each the rule it reverses): #354's roles and Flexible's role marks on the main page's
    /// model (batch V's toggles unticked); the active group's prism on open (S1b's rule); the play bar with no Play view in
    /// its gate (rounds 3–6); X-ray as the Lattice view's rendering and the dent view's (C2 + M6).
    var controlRolesOnMain = false
    var controlPrismOnOpen = false
    var controlPlayerIgnoresPlayView = false
    var controlXrayIsLatticeView = false
    /// ★ R7-V REVIEW, test control only: the squish number on the main page (S1b's mm tags — after a pick, under [Prisms]),
    /// which his 2026-10-14 answer moved to the Squish page only.
    var controlSquishTagsOnMain = false
    /// ★ ROUND 7, M1 (H15'), test control only: round 6's SQUISH prisms on the main page (S1b — the active group's pressed
    /// faces at their Settings squish depth, every pressed face under [Prisms]), which his img1 / img2 words replaced by the
    /// picked group's LATTICE face-prisms.
    var controlSquishPrismsOnMain = false
    /// ★ R7-V: Play turned on while a page was up (the loop starts when the main page shows again).
    var playStartPending = false
    /// ★ the gate: another core solve runs (the Stress view's sim, a topology run) — FlexibleStressSolver.busy
    var squishBusy: (() -> Bool)?
    /// The Stress solve waited for a sim (it starts when the sims go idle).
    var stressWaiting = false
    var squishIdleObservation: AnyCancellable?
    /// Test control only: draw today's COLUMN squish even with the sims landed (the BEFORE renders).
    var controlColumnSquish = false
    /// Test control only: a failed sim holds the loop at rest (no column fallback — the red control).
    var controlNoFallback = false
    /// ★ BATCH N, test control only: the page ignores the refined fields (batch G / M — the quick field
    /// and its fold cut for ever; the red control of the swap and the line).
    var controlNoRefineView = false
    /// ★ BATCH N VERIFICATION, test controls only: the legend's top, the dent row's field and the (i) read
    /// the NEWEST version (batch N — a refine landing mid-squeeze moved them while the quick field
    /// played); the page does not refresh when the renderer swaps a refined version in at rest.
    var controlLegendByNewestVersion = false
    var controlNoSwapRefresh = false
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
        Self.lastMade = self   // ★ M1 VERIFY: the hosted evidence probe reads the workspace's own stage (weak; tests only)
        // ★ C2 VERIFICATION: the Export step's buttons act through the stage (the model, the note,
        // the way to the Lattice stage are its)
        coreRun.onFix = { [weak self] f in self?.coreFix(f) }
        // ★ BATCH G: a Stress solve that waited for a squish sim starts when the last one leaves core
        squishIdleObservation = NotificationCenter.default.publisher(for: FlexibleSquishSolver.idleNotification)
            .sink { [weak self] _ in self?.squishIdle() }
        // ★ BATCH N VERIFICATION: the renderer swapped a refined version in at rest — the legend's top, the
        // dent row and the (i) follow it now (the next runloop turn: never inside the renderer's frame)
        loop.onVersionSwap = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.controlNoSwapRefresh else { return }
                self.refresh()
            }
        }
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
        // ★ R7-V: the Play view as the model has it (OFF on open: at rest — every hold is), no pause of his carried over
        DispatchQueue.main.async { [loop, weak m] in
            loop.playView = m?.views.contains(.play) ?? false
            loop.forgetHisPause()
            if loop.playing || loop.held != (loop.playView ? 1 : 0) { loop.hold(1) }
        }
        // ★ D2: another project's squeeze pick does not carry over (async: never inside an update)
        if shownSim != nil { DispatchQueue.main.async { [weak self] in self?.shownSim = nil } }
        tappedRegion = nil   // ★ ROUND 7 (F): nor the face he last tapped there, nor his 3 s hold
        if heatAll { DispatchQueue.main.async { [weak self] in self?.heatAll = false } }
        // ★ ROUND 7 (M2, the reviewer's ruling 3): a project I2 saved has its edge strips moved off the Surface stage once,
        // as the loaded state when nothing is undoable (FlexibleSectorMigration) — never inside a view's init
        DispatchQueue.main.async { [weak m] in m?.migrateSectorsAtOpen() }
        observation = m.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.modelChanged() }
        // ★ BATCH G: no sim starts beside another core solve; a Stress solve it held back starts after
        m.squishSolver.busy = { [weak self] in self?.squishBusy?() ?? false }
        m.squishSolver.onIdle = { [weak self] in self?.squishIdle() }
        fe = FlexibleFEView(); feMeshCache = [:]; feValueCache = [:]; feColumnCache = [:]; feStressCache = [:]; fePlayedGeneration = nil
        feStartedKey = nil; fallbackKey = nil; heldForSims = false; fallbackSim = nil; feBaseTints = [:]; feTintBox.set([:])
        seenLoads = nil
        // a fresh session of picks (FlexibleMainPickSession); ★ R7-V: batch V's two view settings are gone — his kept keys too
        openPickSession(project)
        UserDefaults.standard.removeObject(forKey: Self.batchVSettingsKey(project.id))
        projectObservation = project.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.projectChanged() }
        // ★ S1b: the views ([Prisms] here, either view on Settings) redraw what the main page draws from them — H15's
        // list, the legend card's Prisms row, the button — at once (never the first value: this runs in a view's init)
        viewsObservation = m.$views.dropFirst().removeDuplicates()
            .sink { [weak self] v in self?.viewsChanged(v) }   // ★ R7-V: and Play, on either page
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
        if playStartPending { playStartPending = false; refresh() }   // ★ R7-V: Play turned on while Settings was up
        model?.checkStampShown = nil
        model?.pendingFix = nil
        // ★ ROUND 5 (S9): "Exit" — nothing changed on Settings: the main page stays EXACTLY as it was
        if model?.takeExitUnchanged() == true { showLatticeOnExit = false; return }
        model?.retryFailedBuild()   // his Save & Exit asks for the build: a failed one is tried once more
        // ★ C2: Settings opened by the Lattice view button (nothing to show) — Exit shows the view (★ X1: the view only; X-ray
        // stays as he set it)
        if showLatticeOnExit { showLatticeOnExit = false; showLatticeView() }
        // ★ ROUND 5 (S9): with the Lattice view OFF, Save & Exit only STORES — the bake waits for the view
        model?.latticeBuildDeferred = !latticeOn
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
        m.pendingFix = m.readiness.blocking.first ?? FlexibleLatticeUnder.first(m.readiness)   // ★ batch E
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
                                                   loop: fresh && !pageUp ? loop : nil,
                                                   printed: printedReady(m) && !pageUp)   // ★ X1: the printed view (★ verify: its one rule)
        // ★ BATCH G: the squeeze groups' fields, their meshes and the sequence the loop plays
        if fe.active, fresh, !pageUp {
            inputs?.fe = fe.fields; inputs?.feMesh = fe.mesh; inputs?.feSequence = fe.sequence; inputs?.feToken = fe.token
            inputs?.feTints = feTintBox   // ★ "Play all": each group's own colours, swapped in with its field
            // ★ BATCH M (M3): Stress on — the walls take each group's own stress (★ verification: each
            // field on its own scale — the pass's texture carries the fraction of its top)
            if stress, feStressRoute, stressDrawable { inputs?.stressWalls = true }
        }
        inputs?.ghostWalls = ghostWalls   // ★ BATCH M (M6): the dent view ghosts the walls under the solid planes
        if heatOnWalls, !pageUp { inputs?.heatWalls = wallHeatTable }   // ★ X1 VERIFY: Heat on — the walls carry it
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
        guard owns(project, stage) else { return nil }
        if xray { return FlexibleStagePage.xrayBodyAlpha }
        // ★ X1, THE PRINTED VIEW: the body see-through — only its CLOSED surface (the tints' solid flag) draws, opaque, and the
        // pass writes it into the G-buffer with the walls (FlexibleLatticePass.encodeBody), so it is sorted
        if let m = current(project, stage), printedReady(m) { return 0 }   // ★ X1 VERIFY: the one rule
        return 1
    }
    /// ★ ROUND 7, M1 (hook H15' — WorkspacePlaceholder hands ONLY this to the viewer on the Flexible stage): the main page's
    /// prisms ARE the picked group's LATTICE face-prisms — #354's own `LatticeDepthPlane`s (the Selections modal's Lattice
    /// rows), each at its list depth (`latticeSlabDepthMM`, one store, so the prism and the list are always equal — his img1:
    /// "they should *always* be equal"), in the face-prism violet, #354's look for the active group. Only after he picks a
    /// group in this session (his fixed rule); a group with no face-prism draws nothing — the Top, Off in Selections, no longer
    /// draws its SQUISH prism (his img2: "What is this 12mm? … please remove whatever it is"; the squish depth and its number
    /// are the Squish page's). [Prisms] = every face-prism of the picked group (its legend row, and X-ray). [] off the Flexible
    /// stage, under a page, or while a legend reads. Cached on its inputs (the workspace's body asks on every pass).
    /// RED CONTROL `controlSquishPrismsOnMain`: round 6's squish prisms (S1b).
    public func volumes(_ project: ProjectModel, on stage: WorkspaceStage, drilledIn: Bool) -> [ClearanceRenderItem] {
        guard !drilledIn, !frozen, let m = current(project, stage) else { return [] }
        if controlSquishPrismsOnMain { return squishVolumes(project, m) }
        // ★ M1 VERIFY (the verify: "[Prisms] does nothing visible on the model" — before a pick it drew nothing, after one
        // exactly what the pick drew): [Prisms] = EVERY group's lattice face-prisms (his round-6 words for the view: "a view
        // that turns on/off ALL … prisms"), the picked group's brighter; without [Prisms], the picked group's only (his fixed
        // rule: a group's prism only after a pick). RED CONTROL `controlPrismsPickedOnly`: the picked group's only.
        let picked = pickedGroup(project)
        let all = prismsOn && !Self.controlPrismsPickedOnly
        guard all || picked != nil else { return [] }
        return facePrismItems(project, picked: picked?.id, all: all)
    }

    /// ★ M1 (VERIFY): the lattice face-prisms drawn — #354's own include `LatticeDepthPlane`s at their list depth, of the picked
    /// group (`all` false) or of every group (`all`: [Prisms]), in #354's active look (`selected`) — under [Prisms] with a pick,
    /// only the picked group's (the others fainter, #354's look for the rest); a hidden group's never. (Looking at the first
    /// picture: with nothing picked every face-prism drawn faint hid under the heat — nothing picked, all in the active look.)
    /// Cached on its inputs (the workspace's body asks on every pass).
    func facePrismItems(_ project: ProjectModel, picked: UUID?, all: Bool) -> [ClearanceRenderItem] {
        let inputs = FacePrismInputs(group: picked, all: all, lattice: project.lattice, selection: project.selection,
                                     force: project.force, regions: project.faceRegions, groupView: project.groupView,
                                     mesh: project.viewerMesh?.triangleCount ?? 0)
        if let c = facePrismCache, c.inputs == inputs { return c.items }
        let items = project.latticeDepthPlanes()
            .filter { $0.role == .include && !project.groupView.isHidden($0.groupID) && (all || $0.groupID == picked) }
            .map { ClearanceRenderItem(volume: $0.volume, selected: picked == nil || $0.groupID == picked, tint: FlexibleStageStyle.facePrismTint) }
        facePrismCache = (inputs, items)
        return items
    }

    /// ★ M1: what the face-prisms are built from (every input of `ProjectModel.latticeDepthPlanes`, the picked group, and
    /// whether [Prisms] asks for every group's).
    struct FacePrismInputs: Equatable {
        let group: UUID?
        let all: Bool
        let lattice: LatticeSettings
        let selection: SelectionModel
        let force: ForceModel
        let regions: FaceRegionModel
        let groupView: GroupViewState
        let mesh: Int
    }

    /// The RED CONTROL's prisms: round 6 (item 3, hook H15) — the main page's SQUISH prisms, faint (FlexibleDepthPrism's,
    /// at the page's k) — the ACTIVE Selections group's pressed faces, or every pressed face while the Prisms view is on.
    func squishVolumes(_ project: ProjectModel, _ m: FlexibleStageModel) -> [ClearanceRenderItem] {
        let k = prismK   // ★ S1b: the page's ONE k (the tags and the legend's ×k read it too)
        // ★ "Prism after a pick" (★ R7-V: fixed, no longer a setting): the active group only once he has picked in this
        // session, and never a Pending group's (FlexibleMainPickSession.prismGroup)
        let active = prismGroup(project)
        let key = "\(k)|\(m.views.rawValue)|\(active.map { "\($0.id)\($0.faces)\($0.regionIDs)" } ?? "-")|\(m.settings.hashValue)|"
            + "\(m.stacks.count)|\(m.geometry.count)|\(m.stampGrids.count)"
        if let c = volumesCache, c.key == key { return c.items }
        let loaded = m.settings.loadedFaces.map(\.faceRegionID)
        // the active group's pressed faces: its faces (a region's members too) and its cut sectors; a face it LOADS is
        // linked to it
        var picked = Set<Int>()
        if let g = active {
            let part = project.viewerMesh, all = m.regions
            var faces = Set(g.faces.map { Int($0) }), sectors = Set<Int>()
            for id in g.regionIDs {
                guard let reg = project.faceRegions.region(id) else { continue }
                if all.sectors.contains(where: { $0.id == id }) { sectors.insert(FlexibleRegions.wireID(reg)) }
                else if let part { faces.formUnion(FaceRegionGeometry.members(of: reg, in: part).map { Int($0) }) }
            }
            picked = Set(loaded.filter { r in
                m.settings.face(r)?.weightFrom == g.id || sectors.contains(r)
                    || (!FlexibleRegions.isSector(r) && !faces.isDisjoint(with: all.faces(of: r, mesh: part)))
            })
        }
        // ★ S1b VERIFICATION (spec §2, the Prisms view: "every pressed face's prism, faint; the selected one brighter"):
        // under [Prisms] every pressed face, the active group's brighter (Settings' own view-selected alphas); else the
        // active group's own, faint
        let prisms = m.views.contains(.prisms)
        let regions = prisms ? loaded : loaded.filter { picked.contains($0) }
        let items: [ClearanceRenderItem] = regions.compactMap { r in
            guard let f = m.settings.face(r), let key = m.key(r), let st = m.stacks[key], let g = m.geometry[key],
                  let v = FlexibleDepthPrism.volume(region: r, stack: st, centres: g.centres, depthMM: f.deepestMM, k: k,
                                                    footprint: m.prismFootprint(r)) else { return nil }
            let bright = prisms && picked.contains(r)
            return ClearanceRenderItem(volume: v, selected: bright, tint: FlexibleStageStyle.facePrismTint,
                                       faceAlpha: bright ? FlexibleDepthPrism.viewSelectedFaceAlpha : FlexibleDepthPrism.restFaceAlpha,
                                       edgeAlpha: bright ? FlexibleDepthPrism.viewSelectedEdgeAlpha : FlexibleDepthPrism.restEdgeAlpha)
        }
        volumesCache = (key, items)
        return items
    }
    /// ★ S1b (round 6 item 3, the main page): the ONE k the main page's prisms, their mm tags and the legend's Prisms
    /// row use — the dent's exaggeration, or 1 while nothing is dented (the prism at its true depth).
    public var prismK: Double { channels.map { FlexibleStageVolumes.prismK($0.exaggeration) } ?? 1 }
    /// The Prisms row's "×k".
    public var prismLegendK: Int { Int(prismK.rounded()) }
    /// ★ S1b: the Prisms view is on (the main page's [Prisms]; the model's own `views`, which Settings shares).
    public var prismsOn: Bool { model?.views.contains(.prisms) == true }
    /// ★ S1b: the main page's ONE legend card carries the Prisms row while [Prisms] is on. ★ M1 VERIFY (the verify: the row
    /// described violet that was not on screen): only while [Prisms] DRAWS a face-prism (the 19:45 ruling's rule: "a legend
    /// row only where its thing is actually drawn"). RED CONTROL `controlPrismsPickedOnly`: whenever [Prisms] is on.
    public var legendPrismsRow: Bool {
        guard prismsOn else { return false }
        if Self.controlPrismsPickedOnly { return true }
        guard let p = model?.project else { return false }
        return !facePrismItems(p, picked: pickedGroup(p)?.id, all: true).isEmpty
    }
    /// ★ S1b (round 6 item 3 — his img3: "When a face … is highlighted, we should automatically be able to see the
    /// amount of squish it has been set to"): the main page's READ-ONLY "%.1f mm" tags, one per prism H15 draws (the
    /// active Selections group's pressed faces, or every one in the Prisms view), at the prism's FLOOR — where the
    /// number belongs, as on Settings — greedy against overlaps (the larger face first), none under a keep-out or off
    /// screen; [] wherever `volumes` is (off the Flexible stage, under a page, while a legend reads). Never a tap: the
    /// main page has no chip — the mm is changed in Settings.
    /// ★ S1b VERIFICATION (the verifier, on his pad: in his Lattice view the faint prism cannot be seen, so a side face's
    /// "24.5 mm" floated over the top face; on his 13" portrait [Prisms] showed 3 of 5 numbers, 1 of 4 on r5): each tag
    /// carries its FACE and a LEADER to it (FlexibleMainTagLeader), and a floor hidden under a keep-out slides along its
    /// prism's axis (then beside its face, if the leader reaches it) — FlexibleStageViewTags.placeMain; the active group's
    /// tags first under [Prisms]. `viewDirection` marks a face that turns away (its leader dashed).
    func prismTags(_ project: ProjectModel, on stage: WorkspaceStage, drilledIn: Bool, viewport: CGSize, keepOut: [CGRect],
                   projector: (SIMD3<Float>) -> CGPoint?,
                   viewDirection: ((SIMD3<Float>) -> SIMD3<Float>?)? = nil) -> [FlexibleStageViewTags.Tag] {
        // ★ R7-V REVIEW — his img2 (2026-10-14): "What is this 12mm? … this screen should only show the lattice selection and
        // so this 12mm is completely worthless and makes no sense … please remove whatever it is", and his answer: "The
        // squish number: only on the Squish page" (the main page shows only the face-prism's own depth — R7-M's chips). The
        // squish number is never drawn here — after a pick or under [Prisms]; the prisms stay, faint. This REVERSES S1b's
        // tags (round 6 item 3, his img3: "we should automatically be able to see the amount of squish"). The placement
        // below is kept for R7-M's face-prism chips. RED CONTROL `controlSquishTagsOnMain`.
        guard controlSquishTagsOnMain else { return [] }
        guard let m = current(project, stage) else { return [] }
        guard !drilledIn, !frozen else { return [] }
        // (the control's tags sit on the control's squish prisms — M1's face-prisms carry no number on this page yet)
        let cands: [FlexibleStageViewTags.MainCandidate] = squishVolumes(project, m).compactMap { item in
            let r = item.volume.faceID
            guard let f = m.settings.face(r), let h = FlexibleDepthPrism.handle(item.volume) else { return nil }
            // ★ S1b VERIFICATION: the prism's axis — its floor (the handle's anchor) to its face (the base centre)
            let axis = h.planeOrigin - h.anchor
            var along = Self.tagSteps.compactMap { projector(h.anchor + axis * Float($0)) }
            let axisCount = along.count
            // a floor hidden all along its axis (under the Selections panel, say): beside its face, while the face shows —
            // the leader is then a short spoke to the face's dot
            let face = projector(h.planeOrigin)
            if let f = face { along += Self.besideFace.map { CGPoint(x: f.x + $0.x, y: f.y + $0.y) } }
            guard !along.isEmpty else { return nil }
            let columns = m.key(r).flatMap { m.stacks[$0]?.columns.count } ?? 0
            // the face turns away when the view ray meets its OUTWARD normal (the handle's normal points in)
            let away = viewDirection.flatMap { $0(h.planeOrigin) }.map { simd_dot($0, -h.planeNormal) > FlexibleStageViewTags.awayDot } ?? false
            return FlexibleStageViewTags.MainCandidate(region: r, columns: columns, bright: item.selected,
                                                       text: String(format: "%.1f mm", f.deepestMM), along: along,
                                                       axisCount: axisCount, face: face, away: away)
        }
        return FlexibleStageViewTags.placeMain(cands, keepOut: keepOut, viewport: viewport)
    }
    /// ★ S1b VERIFICATION: where along its prism's axis a tag may sit, in order — the floor (0), toward the face (1), on
    /// out past it (to 2), then on in past the floor (to −3: a face under the Selections panel keeps its number, on its
    /// axis, its leader running back to the panel's edge), every eighth.
    static let tagSteps: [Double] = (0...16).map { Double($0) / 8 } + (1...24).map { -Double($0) / 8 }
    /// …and, last, beside its face (pt from the face's point): right, left, below, above, then the diagonals, nearest first.
    static let besideFace: [CGPoint] = [52.0, 80, 112].flatMap { r -> [CGPoint] in
        let d = r * 0.7071
        return [CGPoint(x: r, y: 0), CGPoint(x: -r, y: 0), CGPoint(x: 0, y: r * 0.6), CGPoint(x: 0, y: -r * 0.6),
                CGPoint(x: d, y: d * 0.6), CGPoint(x: -d, y: d * 0.6), CGPoint(x: d, y: -d * 0.6), CGPoint(x: -d, y: -d * 0.6)]
    }

    /// ★ ROUND 6 (item 3): the main page's [Prisms] — the Prisms view, and X-ray with it (a view that needs another turns
    /// it on itself). ★ R7-V: X-ray, not the Lattice view — a prism sits under its face, inside the part.
    /// ★ ROUND 7, X1 (his Q9 answer: X-ray is HIS view — "If the user adds x-ray, we see through the solid"): [Prisms] no longer
    /// turns X-ray on (R7-V's rule, reversed). RED CONTROL `controlViewsForceXray`.
    public func togglePrisms() {
        guard let m = model else { return }
        m.toggleView(.prisms)
        if controlViewsForceXray, m.views.contains(.prisms), !xrayOn { xrayOn = true }
    }

    /// ★ X1 VERIFY: the walls' heat table for the lattice on screen — per squish face (the pass's slots, in
    /// `squishFaces` order), per cell, the column's squish: the 3D sim's compression on the FE route (each face by its own
    /// group's field — `feColumnHeat`), else core's buildable depth (what the column map is coloured by); the legend's top.
    /// nil with no squish to show.
    func makeWallHeat(_ m: FlexibleStageModel, shown: FlexibleShownValues) -> FlexibleWallHeat? {
        guard dentMaxMM > 0, let g = m.lattice?.showing(playingSim), g.keys.count == g.faces.count else { return nil }
        let squished = Set(g.squishedKeys)
        let slots = zip(g.keys, g.faces).filter { squished.contains($0.0) }
        guard !slots.isEmpty else { return nil }
        let perColumn: [FlexFaceKey: [Double?]] = feColumnHeat(m) ?? shown.values.mapValues { v in
            v.map { if case .depth(let d) = $0 { return d } else { return nil } }
        }
        let cells = slots.map { k, face in
            m.stacks[k].map { FlexibleWallHeat.cells(stack: $0, face: face, perColumn: perColumn[k] ?? []) }
                ?? [Float](repeating: -1, count: face.nu * face.nv)
        }
        return FlexibleWallHeat(cells: cells, topMM: Float(dentMaxMM))
    }

    /// The squish player shows only when there is something to squish: a lattice that still
    /// matches the settings, on the visible main page — ★ R7-V: and his Play view on (his img1: "When it is on the
    /// simulation plays - otherwise, remove the play-bar from the bottom of the screen entirely").
    public var playerShown: Bool {
        guard visible, !frozen, let m = model, m.lattice != nil, !m.latticeIsStale, channels?.dents != nil else { return false }
        return m.views.contains(.play) || controlPlayerIgnoresPlayView
    }
    /// The player's full end ("10 kg").
    public var fullLabel: String {
        guard let m = model else { return "Full load" }
        let shown = Set(shownLattice?.squishedKeys.map(\.region) ?? [])
        // ★ ROUND 7 REVIEW (R): each HAND's force — a face's lattice parts together (each part is an equal share of it)
        let own = m.squeezeGroups.flatMap { m.groupHands($0) }.filter { $0.mainGroup == nil && $0.regions.count > 1 }
        let parts = Set(own.flatMap(\.regions))
        let weights = m.settings.loadedFaces.filter { shown.contains($0.faceRegionID) && !parts.contains($0.faceRegionID) }.map(\.weightKg)
            + own.filter { $0.regions.contains(where: shown.contains) }.map(\.kg)
        return FlexibleSquishLoop.fullLabel(weightsKg: weights, shapeOnly: m.lattice?.shapeOnly == true, unit: m.weightUnit)   // ★ S4
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
        if visible { coreRun.close() }   // ★ R7-D1 (H31): on the Flexible stage the card shows the answer, never the full-screen step
    }

    // MARK: ★ ROUND 7, R7-D1 — the corner pair (FlexibleCornerPair)

    /// The corner pair's status (the old pill's, on the Flexible stage).
    func cornerStatus(_ m: FlexibleStageModel) -> FlexibleMainStatus { FlexibleMainStatus.of(model: m) }

    /// Core's last answer is for the lattice on screen.
    func answerIsCurrent(_ m: FlexibleStageModel) -> Bool {
        guard let g = m.lattice, !m.latticeIsStale else { return false }
        return coreRun.sentFor == g.generation
    }

    /// The card's [Send to core] and Ready's tap: send (an unchanged job never re-sends) — the answer shows in the card,
    /// never the full-screen step.
    public func sendFromCard() {
        sendToCore()
        coreRun.close()
    }

    /// Stub (tests first).
    public func resendFromCard() { sendFromCard() }

    /// What the split button's zones act through.
    func cornerHooks(openSquish: @escaping () -> Void) -> FlexibleLatticeButton.Hooks {
        FlexibleLatticeButton.Hooks(send: { [weak self] in self?.sendFromCard() },
                                    showCard: { [weak self] in if let s = self, let m = s.model { s.coreRun.showHold(m.coreHold) } },
                                    showLattice: { [weak self] in self?.showLatticeView() },
                                    note: { [weak self] k in self?.note.post(k) },
                                    openSquish: openSquish,
                                    callout: {})
    }

    /// A blocker the status names pops above the pair — once per issue (the card, when open, shows it instead). Asked only
    /// by the pair, which shows only on the Flexible stage with no page up (H30, inside #354's `!fullScreenPageUp` scope).
    func noteCallout(_ s: FlexibleMainStatus) {
        guard calloutRule.next(s) != nil else { return }
        if chrome.open != .latticeCard { chrome.show(.callout) }
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
        if !owned || pageUp { chrome.foldAll() }   // ★ R7-D1: a stage change or the Squish page folds every card
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
        // ★ BATCH M VERIFICATION: re-checked — a solid solve held back behind a sim is never started once
        // the page's Stress is the groups' own sims (its answer would never be drawn)
        guard !feStressRoute || controlStressRouteNeedsFreshLattice else { return }
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
              !m.latticeBuildDeferred || latticeOn,   // ★ S9: a Save & Exit with the view off only stored
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
        var drawn = FlexibleLatticePreview.drawn(m.lattice?.showing(selectedSim), xray: true, building: m.latticeBuilding,   // ★ ROUND 7 (F)
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
        // ★ ROUND 6 (his img1): no group colour on the main page — no frame, no digit, no tinted map-less face
        // ★ ROUND 7, M1 (1a): no face-prism — the PLAIN model (no dent heat, no dent: nothing can squish)
        let prisms = m.facePrismsSet
        // ★ M1 VERIFY (the verify: after a depth edit the legend read "What you drew · 0 mm … 24.5 mm" — Face 3's SQUISH
        // depth, beside the list's 17.3 / 25.0; his answer: "the squish number: only on the Squish page"): the drawn curve is
        // the Squish page's — the main page wears heat and a dent only from a lattice DRAWN (or core's 3D heat). While none is
        // drawn (building, stale, deferred) it is the plain model. RED CONTROL `controlDrawnCurveOnMain`: the drawn curve's.
        let latticeHeat = prisms && (drawn != nil || feNow != nil || Self.controlDrawnCurveOnMain)
        var c = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: false, drawnLattice: drawn, heat: heat && latticeHeat,
                                              depthScaleMM: feNow?.scaleMM, mapValues: feNow?.first,
                                              controlColumnColours: controlColumnHeat, groupColours: false,
                                              roleMarks: controlRolesOnMain)   // ★ R7-V: no role mark on the main page's model
        if !latticeHeat { c.dents = nil; c.exaggeration = 0; c.mapValues = nil }
        if controlRound5Frames { FlexibleGroupFrames.paint(&c.tints, overlay: overlay, model: m) }   // (the red control only)
        let shown = FlexibleShownValues(model: m, drawnLattice: drawn)
        dentMaxMM = latticeHeat ? (feNow?.scaleMM ?? shown.maxDepth) : 0   // ★ BATCH N VERIFICATION: the sequence AS ON SCREEN (★ M1: none without a face-prism; ★ M1 VERIFY: none without a lattice drawn)
        heatValues = c.mapValues
        dentMapShown = overlay?.flatStart.isEmpty == false && dentMaxMM > 0   // ★ BATCH M (M6): the dent view's X-ray
        // ★ BATCH M VERIFICATION: …but not on the column FALLBACK (a lattice drawn, its sims failed — or none,
        // a shape-only filament): its planes are core's per-column steps — 'no number' columns stand still
        // among sunk ones and one face's plane crosses another's — which the solid body hid; there the
        // dent view keeps the body solid (and the walls opaque), as before batch M
        dentOnColumnFallback = drawn != nil && !fe.active && !fe.pending && !controlDentXrayOnFallback
        // ★ BATCH G: the field moves the ghost, the heat plane and the walls; ×k capped so the map
        // stays injective (the planes never cross)
        feBaseTints = playAllBaseTints(m, scaleMM: dentMaxMM, nextScaleMM: feNow?.nextScaleMM)
        // ★ X1 VERIFY: the walls' heat — the same numbers the map is coloured by, per column, on the legend's scale
        wallHeatTable = makeWallHeat(m, shown: shown)
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
                   "\(fe.token)", "\(fe.sequence)", "\(fe.shownSequence)", "\(fe.pending)", fe.failure ?? "", "\(xray)", "\(stress)",
                   "\(prisms)", "\(printedReady(m))"].joined(separator: "|")   // ★ M1 VERIFY: the views' availability redraws the row; ★ X1: the printed view
            + "|\(wallHeatTable?.token ?? 0)|\(heatOnWalls)"   // ★ X1 VERIFY: the walls' heat
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
    /// ★ M1 VERIFY: `blocked` — nothing can be made or sent until he does what the line says on the main page (no face-prism):
    /// the button is disabled there with its reason (ruling 4), a tap target only from another stage (to the Lattice stage).
    public enum Tone: Equatable, Sendable { case ready, building, fix, idle, preview, blocked }
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
    /// ★ ROUND 5 (S9): Save & Exit with the Lattice view off stored the settings; the bake waits.
    public static let deferred = "View off · tap to build"

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
        // ★ BATCH E (+ review): a pressed face with no lattice under it is said here too — never a
        // fix tone: the big button still SENDS (FlexibleLatticeUnder.mainStatus); his shape-only label first
        if let s = FlexibleLatticeUnder.mainStatus(r, hold: hold) { return s }
        if let hold { return .init(line: hold, tone: .preview, fix: nil) }
        return .init(line: lattice?.shapeOnlyLabel ?? ready, tone: .ready, fix: nil)
    }

    @MainActor
    public static func of(model m: FlexibleStageModel?) -> FlexibleMainStatus {
        guard let m else { return .init(line: notOpened, tone: .idle, fix: nil) }
        if case .failed = m.sceneState { return .init(line: "The part could not be opened", tone: .fix, fix: nil) }
        // ★ ROUND 7, M1 (1a, ruling 4): no face-prism — no lattice and nothing to send: the one line, after the readiness's own
        // blockers (a filament, a pressed face). ★ M1 VERIFY (the verify: the words pointed to Selections, the tap opened the
        // Squish page's [Lattice under all N] — three new groups, the whole pad latticed again): `.blocked` — "Export disabled
        // with a stated reason" (ruling 4): disabled on the main page, Selections beside it; on another stage its tap goes to
        // the Lattice stage. RED CONTROL `FlexibleMainStage.controlNoPrismOpensSquishFix`: the M1 build's .fix + the fix.
        if m.sceneState == .ready, !m.facePrismsSet, m.readiness.blocking.isEmpty {
            if FlexibleMainStage.controlNoPrismOpensSquishFix {
                return .init(line: FlexibleRowCopy.noFacePrism, tone: .fix, fix: FlexibleLatticeUnder.first(m.readiness))
            }
            return .init(line: FlexibleRowCopy.noFacePrism, tone: .blocked, fix: nil)
        }
        // ★ ROUND 7 REVIEW (R, his answer of 2026-10-15: "After Reset all, the main page's status line also says 'Nothing to
        // squish yet'"; his answer 3: "Allow an *empty* setup after reset all"): nothing set to squish is no fault — the line
        // says so, neutral, no Fix (the readiness's "press the face that carries weight" was F's leftover here)
        if let empty = FlexibleMainStatus.emptySetup(m) { return empty }
        // ★ ROUND 5 (S9): saved with the Lattice view off — nothing bakes until the view is on (a tap turns it on)
        if m.latticeBuildDeferred, m.lattice == nil || m.latticeIsStale, m.sceneState == .ready,
           m.readiness.blocking.isEmpty, !m.latticeBuilding { return .init(line: deferred, tone: .idle, fix: nil) }
        return of(readiness: m.sceneState == .ready ? m.readiness : nil, sceneReady: m.sceneState == .ready,
                  isBuilding: m.latticeBuilding, lattice: m.lattice, stale: m.latticeIsStale, failure: m.latticeFailure,
                  hold: m.coreHoldKind.map { FlexibleCoreHold.pill($0, shapeOnlyLabel: m.lattice?.shapeOnlyLabel) })
    }
}

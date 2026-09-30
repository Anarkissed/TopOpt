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
    /// The views (batch B's minimum — batch C adds Stress and the legends). X-ray on.
    @Published public var xray = true { didSet { if oldValue != xray { refresh() } } }
    @Published public var heat = true { didSet { if oldValue != heat { refresh() } } }
    @Published public var latticeOn = true { didSet { if oldValue != latticeOn { refresh() } } }
    /// ★ BATCH B REVIEW: the walls are drawn only in X-ray (the body is opaque otherwise), so
    /// X-ray off made the Lattice button look broken. The button shows what is DRAWN, and
    /// turning it on turns X-ray on.
    public var latticeShown: Bool { latticeOn && xray }
    public func toggleLattice() {
        if latticeShown { latticeOn = false } else { xray = true; latticeOn = true }
    }

    // MARK: batch C — Stress, the legends, tap-to-read (FlexibleMainStage+Views.swift)

    /// ★ STRESS (item T): the solid part's FEA from the main page's loads, coloured over the
    /// part. Off by default; on, it turns X-ray off so its colours read (toggleStress).
    @Published public var stress = false
    /// The reading a tap pinned while a legend is drilled in (one publish per tap).
    @Published public internal(set) var reading: FlexibleReading?
    /// Legends he minimised (the caret), and the one placed first (a pill he tapped open).
    @Published public var minimized: Set<FlexibleReadKind> = []
    @Published public var legendPriority: FlexibleReadKind?
    /// The workspace's solve (H5' hands it over each render): run only when there is no field
    /// or it is stale, and never twice (FlexibleStressTrigger).
    var stressSolver: (() -> Void)?
    var stressReady = false
    var stressRunning = false
    /// The field the page shows (stashed from H4's call), its identity and its peak.
    var stressField: LatticeDemandField?
    var stressKey = 0
    var stressPeak = 0.0
    /// The view the tap came through (H6 hands the projection and the settle each render).
    var viewFrame: LatticeBandChipFrame?
    /// The composed ONE tint array, and what it was composed from.
    var composedKey: String?
    var composed: [Float]?
    /// The lattice whose depths the map shows (refresh), and the map's deepest value (mm).
    private(set) var drawn: FlexibleGeneratedLattice?
    private(set) var dentMaxMM = 0.0

    /// The squish, one number, stepped by the renderer (FlexibleSquishLoop).
    public let loop = FlexibleSquishLoop()
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

    public init() {}

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
        observation = m.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.modelChanged() }
        seenLoads = nil
        projectObservation = project.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.projectChanged() }
        return m
    }

    /// Settings' Save & Exit (H2's onExit): back on the main page, build the lattice — now if
    /// the designs are in, else as soon as they land (`modelChanged`).
    public func didExitSettings() {
        frozen = false
        visible = true
        model?.checkStampShown = nil
        model?.pendingFix = nil
        model?.retryFailedBuild()   // his Save & Exit asks for the build: a failed one is tried once more
        noteLoads()        // what Settings did to the groups (a weight written back) is in hand
        refresh()
        buildIfReady()
        requestStressIfNeeded()   // ★ BATCH C (item T): the solid part's FEA starts on Save & Exit
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
        return FlexibleLatticePreview.inputs(xray: xray, lattice: m.lattice, building: m.latticeBuilding,
                                             latticeShows: latticeOn && fresh && !pageUp,
                                             loop: fresh && !pageUp ? loop : nil)
    }

    /// H4: the overlay mesh (the part with every pressed face's map quads), nil ⇒ the stage's.
    public func mesh(_ project: ProjectModel, on stage: WorkspaceStage) -> ViewerMesh? {
        current(project, stage) != nil ? overlay?.mesh : nil
    }
    public func dents(_ project: ProjectModel, on stage: WorkspaceStage) -> [Float]? {
        current(project, stage) != nil && overlay != nil ? channels?.dents : nil
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
        let shown = Set(m.lattice?.squishedKeys.map(\.region) ?? [])
        return FlexibleSquishLoop.fullLabel(weightsKg: m.settings.loadedFaces.filter { shown.contains($0.faceRegionID) }.map(\.weightKg),
                                            shapeOnly: m.lattice?.shapeOnly == true)
    }

    /// The bottom pill (H10).
    public var status: FlexibleMainStatus {
        FlexibleMainStatus.of(model: model)
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

    private func modelChanged() {
        guard !frozen, visible else { return }
        refresh()
        buildIfReady()
    }

    private func noteLoads() {
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
        let p = m.project
        let key = m.currentSceneKey
        let failed: Bool = { if case .failed = m.sceneState { return true } else { return false } }()
        let sceneMoved = (m.sceneState == .ready && key != m.openedKey) || (failed && key != m.openAttemptKey)
        let loadsMoved = seenLoads.map { $0.groups != p.selection.groups || $0.force != p.force } ?? true
        if sceneMoved || loadsMoved || m.settingsOutranPipeline {
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
    }

    /// The picture from the model: the overlay (rebuilt only when the pressed faces' stacks
    /// change — a new mesh reframes the camera), then its tints and dents.
    func refresh() {
        guard let m = model else { return }
        let keys = m.loadedKeys.filter { m.stacks[$0] != nil && m.geometry[$0] != nil }
        let oKey = keys.map { "\($0.region)/\($0.rotation)" }.joined(separator: ",") + "|" + m.regions.key
        if overlayKey != oKey {
            overlay = FlexiblePageChannels.overlay(model: m)
            overlayKey = oKey
        }
        // the map is the lattice's while one is shown (X-ray only gates the walls here)
        let drawn = FlexibleLatticePreview.drawn(m.lattice, xray: true, building: m.latticeBuilding,
                                                 checkStampShown: nil, stale: m.latticeIsStale)
        self.drawn = drawn
        // ★ BATCH C: the channels WITHOUT the ghost — Stress and the group colours are composed
        // in first (FlexibleMainTints), then X-ray ghosts what is not opaque
        let c = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: false, drawnLattice: drawn, heat: heat)
        dentMaxMM = FlexibleShownValues(model: m, drawnLattice: drawn).maxDepth
        loop.exaggeration = c.exaggeration
        if let g = drawn {
            if playedGeneration != g.generation {
                playedGeneration = g.generation
                loop.autoPlay(reduceMotion: reduceMotion())
            }
        } else if loop.playing || loop.held != 1 {
            loop.hold(1)   // his live drawing (no lattice) holds at the full squish
        }
        let key = [String(describing: c.tints.map { VertexTintKey($0).hash }),
                   String(describing: c.dents.map { VertexTintKey($0).hash }),
                   "\(c.exaggeration)", "\(drawn?.generation ?? -1)", "\(m.latticeBuilding)",
                   "\(m.lattice?.generation ?? -1)", "\(m.latticeIsStale)", oKey].joined(separator: "|")
        channels = c
        if channelsKey != key {
            channelsKey = key
            generation &+= 1
        }
    }
}

/// What the bottom pill says (H10), as a value.
public struct FlexibleMainStatus: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case ready, building, fix, idle }
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
    /// lattice yet, stale) → ready (the shape-only label for a calibrate-first filament).
    public static func of(readiness: FlexibleReadiness?, sceneReady: Bool, isBuilding: Bool,
                          lattice: FlexibleGeneratedLattice?, stale: Bool, failure: String? = nil) -> FlexibleMainStatus {
        guard let r = readiness, sceneReady else { return .init(line: opening, tone: .building, fix: nil) }
        // ★ the SHORT form (it truncated mid-sentence at 11" portrait); the pop-up says it whole
        if let first = r.blocking.first { return .init(line: first.pill, tone: .fix, fix: first) }
        if let failure, !isBuilding { return .init(line: FlexibleReadiness.buildFailedLine(failure), tone: .fix, fix: nil) }
        if isBuilding || r.designing || lattice == nil || stale { return .init(line: building, tone: .building, fix: nil) }
        return .init(line: lattice?.shapeOnlyLabel ?? ready, tone: .ready, fix: nil)
    }

    @MainActor
    public static func of(model m: FlexibleStageModel?) -> FlexibleMainStatus {
        guard let m else { return .init(line: notOpened, tone: .idle, fix: nil) }
        if case .failed = m.sceneState { return .init(line: "The part could not be opened", tone: .fix, fix: nil) }
        return of(readiness: m.sceneState == .ready ? m.readiness : nil, sceneReady: m.sceneState == .ready,
                  isBuilding: m.latticeBuilding, lattice: m.lattice, stale: m.latticeIsStale, failure: m.latticeFailure)
    }
}

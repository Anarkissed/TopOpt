// FlexibleStagePage — the Flexible stage's page (task 2026-09-29-flexible-screens, A1).
//
// Layout follows the lattice Settings page (LatticeSetupWizard): the part fills the
// screen, "Exit" top-left in the accent capsule, a one-line notice top-centre, and ONE
// panel bottom-left (PageChrome.edge inset, DS.Surface.panel, DS.Radius.panel). ★ ROUND 3:
// every row one line (FlexibleFacePanel); the page is always in X-ray; the legend sits on
// the trailing edge, centred. ★ ROUND 4 (batch D1): the panel (FlexibleSettingsPanel) is as
// tall as its rows, Face | More, and folds to its header; the legend folds to a bar; and NO
// LATTICE is drawn here (his img 6: "the lattice should not be visible in the settings screen
// - only in the main Flexibles page. Simply have the model in xray view in the settings") —
// the X-ray part and the bent map only; the lattice lives on the main page.
//
// ★ ROUND 3 BATCH B: there is no Generate button — Save & Exit builds the lattice and the MAIN
// Flexible page shows it (FlexibleMainStage owns the ONE model, so the lattice outlives this
// page). The top line is a live readiness line (FlexibleReadiness); a blocker opens a pop-up
// that selects the face and offers 1–3 one-tap fixes (FlexibleFixPopup); Exit is blocked
// only by a blocking issue and then reads "Fix 1 thing". The squish player (play / drag)
// sits bottom-centre, its frame computed against the panel, the legend and the top row.
//
// ★ NOTHING ON THIS PAGE COMPUTES A SQUISH NUMBER. It draws FlexibleStageModel's copies of
// core's results (M9). Numbers carry their tier and ± band (R7); a column core could not
// give a number for is drawn as "no number", never a guess.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

/// The live camera projection, kept OUTSIDE the page's own state so a camera move
/// redraws only the overlays that follow it — not the mesh view or the panel.
@MainActor
final class FlexibleProjectionBox: ObservableObject {
    @Published var projection: CameraProjection?
}

public struct FlexibleStagePage: View {
    @ObservedObject var project: ProjectModel
    /// ★ BATCH B: the SHARED model (FlexibleMainStage.model(for:)), observed — not owned. A
    /// page-owned @StateObject died with the page, and the lattice with it (item 7.1).
    @ObservedObject var model: FlexibleStageModel
    @StateObject private var camera = OrbitCameraModel()
    @StateObject private var proj = FlexibleProjectionBox()
    let onExit: () -> Void

    // the overlay mesh and its per-vertex channels, rebuilt only when their inputs change
    @State private var overlay: FlexibleOverlayMesh?
    @State private var tints: [Float]?
    @State private var dents: [Float]?
    @State private var dentScale: Float = 0
    /// The shown dent's exaggeration, kept so the loop only rescales (FlexibleShownValues).
    @State private var dentExaggeration: Double = 0
    /// The dent loops only while a lattice is drawn; while he edits it holds still (round 3).
    @State private var dentAnimated = false
    @State private var padTarget: String?
    /// ★ THE SQUISH PLAYER (maintainer: "a play button and/or timeline to drag that moves the
    /// squish in and out"): one amount 0…1 for the dent AND the walls (FlexibleSquishLoop).
    @StateObject private var loop = FlexibleSquishLoop()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The fix pop-up (item 9): which issue, and the rule that opens it on a NEW one.
    @State private var fixShown: FlexibleIssue?
    @State private var prompt = FlexibleFixPrompt()
    /// The face the pop-up pulses on the part.
    @State private var pulse: DetentPulse?
    @State private var pulseToken = 0
    /// ★ X-RAY VISION (maintainer, 2026-09-29): the body as a ghost, the dented map opaque,
    /// the lattice seen inside. ★ ROUND 3 (item 1.4): ALWAYS on on this page — the bend reads
    /// from any angle, even edge-on (img 1); the X-ray button under the gizmo is gone.
    private let xray = true
    /// ★ BATCH C (item 1.4): the legend reads too — tap it ("TAP THE PART TO READ"), then the
    /// part: the dent's true mm at that spot, pinned as a callout; a tap never selects a face
    /// while it reads; a double tap anywhere (or the legend again) comes back out.
    @State private var legendDrilled = false
    @State private var reading: FlexibleReading?
    /// The panel's, the legend's, the top row's and the player's frames (global), and the
    /// stage's — for the chips' keep-out and the player's place.
    @State private var frames: [String: CGRect] = [:]
    /// ★ ROUND 4 (img 1): the panel and the legend fold away.
    @State private var panelMinimized = false
    @State private var legendMinimized = false
    /// ★ ROUND 5 (S9): the settings as they were when the page opened (once the part is open and the
    /// main page's loads are read in) — "Exit" until something differs, "Save & Exit" after.
    /// ★ S VERIFICATION: taken as the page APPEARS (an edit while the part is still opening counts);
    /// once it is open, the open's own read of the main page's loads is applied to it
    /// (FlexibleStageModel.openedSnapshot) — never re-taken from the settings he may have edited.
    @State private var opened: FlexibleStageSettings?
    @State private var openedSettled = false
    /// ★ ROUND 5 (S2): the overlay's edge (the 3D sim's grid while its field moves the part), the
    /// field's mesh displacements (cached per overlay and field), and the group that plays.
    @State private var overlayEdge: Double?
    @State private var feDents: (key: String, dents: [Float])?
    @State private var playingNumber: Int?
    @State private var playingFE = false
    private var keepOut: [CGRect] { Self.stageKeepOut(frames) }
    /// The chips', the stamp handle's and the curve editors' keep-outs, in the stage's frame.
    /// ★ S VERIFICATION: the player as its two DRAWN parts — the capsule and its top row's picker
    /// and note (the "Group 2 ▾" row made the whole player's width above the capsule a keep-out,
    /// and a curve's end point hid under its empty right side at 11" landscape).
    static func stageKeepOut(_ frames: [String: CGRect]) -> [CGRect] {
        guard let st = frames["stage"] else { return [] }
        let player = frames["playerCapsule"] != nil ? ["playerTopRow", "playerCapsule"] : ["player"]
        return (["panel", "legend"] + player).compactMap { frames[$0]?.offsetBy(dx: -st.minX, dy: -st.minY) }
    }
    private let ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    static let squishPeriodS = 2.4

    /// ★ BATCH B: over the main page's shared model (FlexibleMainStage.model(for:)).
    public init(project: ProjectModel, model: FlexibleStageModel, onExit: @escaping () -> Void) {
        self.project = project
        self.model = model
        self.onExit = onExit
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                DS.Color.background.color.ignoresSafeArea()
                stage
                exitButton
                notice(in: geo.size)
                FlexibleSettingsPanel(model: model, padTarget: $padTarget, minimized: $panelMinimized)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["panel": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .frame(maxHeight: panelMaxHeight(geo.size), alignment: .bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, PageChrome.edge)
                    .padding(.bottom, PageChrome.edge)
                FlexibleViewColumn(camera: camera)
                player(in: geo.size)
                // ★ THE LEGEND SITS ON THE TRAILING EDGE, VERTICALLY CENTRED (round 3, item 7:
                // "legends never cover buttons" — it covered Generate in the bottom corner),
                // placed by FlexibleLegendPlacement.legend against the gizmo and the top line
                // (batch B review: the placement the tests measure is the one the page calls)
                if dents != nil {
                    legend(in: geo.size)
                }
                // ★ THE POP-UP SHOWS THE ISSUE AS IT IS NOW (batch B review) — placed under the
                // top line, clear of the gizmo (it covered its left 36 pt at 11" portrait)
                if let shown = fixShown, let issue = FlexibleFixPrompt.live(shown, in: model.readiness) {
                    let pop = FlexibleLegendPlacement.popUp(viewport: geo.size, notice: noticeBand(geo.size),
                                                            below: model.toast == nil ? 0 : Self.toastRowHeight)
                    FlexibleFixPopup(model: model, issue: issue, padTarget: $padTarget) { fixShown = nil }
                        .frame(width: pop.width)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["popup": g.frame(in: .global)])
                        }.allowsHitTesting(false))
                        .padding(.leading, pop.minX)
                        .padding(.top, pop.minY)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                        .zIndex(30)
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["page": g.frame(in: .global)])
            }.allowsHitTesting(false))
        }
        .onAppear {
            if let b = project.viewerMesh?.bounds { camera.reframe(b) }
            // his earlier actions are not new — but a blocker that already stands pops ONCE,
            // when the scene and designs settle (batch B review: "blockers surface at once");
            // the main page's pill opens its own fix instead
            prompt = FlexibleFixPrompt(actionSerial: model.actionSerial, popExisting: model.pendingFix == nil)
            let appeared = model.settings
            model.openScene()
            // ★ ROUND 5 (S9): what "nothing changed" means — the settings once the part is open
            // (★ S VERIFICATION: as the page appeared while it is still opening)
            openedSettled = model.sceneState == .ready
            opened = openedSettled ? model.settings : appeared
            rebuildOverlay()
            // the main page's pill opened Settings on a fix
            if let f = model.pendingFix { model.pendingFix = nil; present(f) }
        }
        .onChange(of: model.geometry.count) { _ in rebuildOverlay() }
        // ★ ROUND 5 (S9): a part still opening as the page appeared — "unchanged" is what it opens with:
        // ★ S VERIFICATION: the page's snapshot WITH the open's read of the main page's loads (an edit
        // he made while it opened stays a change)
        .onChange(of: model.sceneState == .ready) { ready in
            if ready, !openedSettled, let o = opened { opened = model.openedSnapshot(appeared: o); openedSettled = true }
        }
        .onReceive(ticker) { _ in
            // ★ THE SQUISH (the player's loop): only the scale moves — the displacements and
            // colours are rebuilt when the design changes, never per frame. ★ ROUND 4: no lattice
            // is drawn on this page, so this ticker steps his drawing (the renderer's loop is the
            // main page's)
            guard loop.playing, dents != nil else { return }
            dentScale = Float(dentExaggeration * loop.amount)
        }
        // a drag on the timeline, a pause: the one scale follows at once
        .onReceive(loop.$held) { a in
            if !loop.playing, dents != nil { dentScale = Float(dentExaggeration * a) }
        }
        // A fresh lattice (a Save & Exit build that lands while this page is up) refreshes the
        // channels. ★ VERIFICATION OF D1: it no longer flips the map to "What can be built" or
        // the tab to Face — no lattice is drawn on this page (D-R4-6), the map stays HIS drawing,
        // and nothing ever set the flag back
        .onChange(of: FlexibleLatticePreview.freshKey(model.lattice)) { gen in
            refreshChannels()
            if gen != nil, dentAnimated { loop.autoPlay(reduceMotion: reduceMotion) }
        }
        .onChange(of: model.stacks.count) { _ in rebuildOverlay() }
        // the legend went (no dent to show): it cannot stay drilled in
        .onChange(of: dents == nil) { gone in if gone { legendDrilled = false; reading = nil } }
        // ★ while the legend reads, the squish holds still (the reading stays on its surface)
        .onChange(of: legendDrilled) { loop.holdWhileReading($0) }
        .onChange(of: model.latticeBuilding) { _ in refreshChannels() }
        .onReceive(model.objectWillChange.debounce(for: .milliseconds(16), scheduler: RunLoop.main)) { _ in
            refreshChannels()
        }
        .onPreferenceChange(FlexibleKeepOutKey.self) { frames = $0 }
        .accessibilityIdentifier("flexible-stage-page")
    }

    // MARK: the stage

    /// The part's opacity while a dent is shown; the dented map itself stays opaque.
    static let dentBodyAlpha: Float = 0.3
    /// X-ray: the ghost's face-on opacity. The shader adds up to +0.5 toward the silhouette
    /// (MetalMeshView, tint flags.z), so the outline reads and the inside shows.
    static let xrayBodyAlpha: Float = 0.04

    // ★ ROUND 4 (D1, img 6): NO LATTICE ON THIS PAGE. The generated lattice lives on the MAIN
    // Flexible page; here the part is X-ray and the map is his drawing (FlexibleShownValues with
    // no drawn lattice: "What you drew"), stepped by this page's own ticker.


    /// The same settle the workspace draws with (gravity → down), so the part sits as it
    /// does on every other stage.
    private var settle: simd_quatf {
        project.force.settleRotation
            ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
    }

    private var stage: some View {
        ZStack {
            MetalMeshView(
                mesh: overlay?.mesh ?? project.viewerMesh, camera: camera,
                vertexTints: tints,
                settleRotation: settle, settleAnimated: false,
                faceToolActive: true,
                onPickFace: { fid in model.tapFace(Int(fid)) },
                // a split face: the tap's point picks the sector (FlexibleRegions)
                onPickPoint: { fid, pt in
                    if legendDrilled { readDent(at: pt); return true }   // reading, never selecting
                    model.tapFace(Int(fid), point: pt.map { SIMD3<Double>($0) })
                    return true
                },
                // ★ a double tap anywhere leaves the reading (#354's exit, mounted only while drilled in)
                onLatticeProbeExit: legendDrilled ? { legendDrilled = false; reading = nil } : nil,
                onProjection: { p in
                    // the renderer publishes world→clip; the part is drawn settled (rotated
                    // about its centre), so the overlays project MODEL points through both
                    let c = (overlay?.mesh ?? project.viewerMesh)?.bounds.center ?? .zero
                    let m = ViewerModelFrame.matrix(centre: c, rotation: settle)
                    let q = CameraProjection(viewProjection: p.viewProjection * m, viewportSize: p.viewportSize)
                    if proj.projection != q { proj.projection = q }
                },
                flexDisplacements: dents, flexScale: dentScale,
                // ★ ROUND 3 (item 1.1): the selected face's deepest squish as a prism × k
                clearanceVolumes: FlexibleDepthPrism.renderItems(model: model, k: dentExaggeration),
                // ★ THE DENT READS THROUGH THE PART (maintainer, 2026-09-29): while a dent is
                // shown the body drops to 30 % and the dented map stays at 100 %.
                bodyAlpha: xray ? Self.xrayBodyAlpha : (dents != nil ? Self.dentBodyAlpha : 1),
                // ★ BATCH B: the face the fix pop-up names, pulsed
                detentPulse: pulse,
                // ★ ROUND 4 (D1, img 6): no lattice here — it lives on the main Flexible page
                flexibleLattice: nil)
            FlexibleStageOverlays(model: model, proj: proj, exaggeration: dentExaggeration, keepOut: keepOut)
            FlexibleReadingCallout(proj: proj, reading: legendDrilled ? reading : nil)
        }
        .coordinateSpace(name: FlexibleStageSpace.name)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["stage": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .ignoresSafeArea()
    }

    private func rebuildOverlay() {
        // ★ ROUND 5 (S2): cut to the 3D sim's grid while its field moves the part (a big flat
        // triangle bends with it), as the main page's overlay is
        overlayEdge = FlexibleSettingsSquish.overlayEdge(model: model)
        overlay = overlayEdge.map { FlexiblePageChannels.overlay(model: model, maxEdgeMM: $0) } ?? FlexiblePageChannels.overlay(model: model)
        feDents = nil
        refreshChannels()
    }

    /// The dent he tapped (the drawn map, at the squish on screen now), read at its column —
    /// FlexibleProbe, the main page's one dent probe.
    private func readDent(at pt: SIMD3<Float>?) {
        guard let p = pt, let q = proj.projection, let sp = q.project(p), let ray = q.ray(throughViewPoint: sp) else { return }
        reading = FlexibleProbe.dentReading(model: model, overlay: overlay, dents: dents, scale: dentScale,
                                            drawnLattice: nil, point: p, dir: ray.dir)
            ?? FlexibleReading(kind: .dent, value: "—", unit: FlexibleReadKind.dent.nothingHere, fraction: nil, anchor: p)
    }

    /// Per-column colours + the dent (FlexiblePageChannels — the page's one source), then the
    /// player's state and the fix pop-up's rule.
    private func refreshChannels() {
        var c = FlexiblePageChannels.channels(model: model, overlay: overlay, xray: xray, drawnLattice: nil)
        // ★ ROUND 5 (S1): each pressed face framed in its squeeze group's colour (FlexibleGroupFrames)
        FlexibleGroupFrames.paint(&c.tints, overlay: overlay, model: model)
        // ★ ROUND 5 (S2): only the SELECTED face's group squishes — its 3D field when current, else
        // its faces' columns (FlexibleSettingsSquish)
        if FlexibleSettingsSquish.overlayEdge(model: model) != overlayEdge { rebuildOverlay(); return }
        let group = model.playingGroup
        FlexibleSettingsSquish.startSims(model: model, group: group)
        let sq = FlexibleSettingsSquish.shown(model: model, overlay: overlay, channels: c, feCache: &feDents)
        c.dents = sq.dents
        c.exaggeration = sq.exaggeration
        if playingNumber != sq.groupNumber || playingFE != sq.fe {
            let restart = playingNumber != nil
            playingNumber = sq.groupNumber
            playingFE = sq.fe
            if restart, loop.playing { loop.restartFromRest(reduceMotion: reduceMotion) }
        }
        tints = c.tints
        dents = c.dents
        dentExaggeration = c.exaggeration
        loop.exaggeration = c.exaggeration   // the renderer's scale is k × amount
        // ★ a lattice appears → the squish plays (not under reduced motion); his live drawing
        // (no lattice, or a stale one) holds still at the full squish — he can still play it
        if c.animated != dentAnimated {
            if c.animated { loop.autoPlay(reduceMotion: reduceMotion) } else { loop.hold(1) }
        }
        dentAnimated = c.animated
        dentScale = c.dents == nil ? 0 : Float(c.exaggeration * loop.amount)
        // ★ ITEM 9: a NEW blocking issue HIS last action caused opens the pop-up at once
        let r = model.readiness
        if let i = prompt.next(r, actionSerial: model.actionSerial,
                               settled: !r.designing && model.sceneState == .ready && !model.designsInFlight),
           fixShown == nil {
            present(i)
        }
        if let f = fixShown, !r.popping.contains(where: { $0.id == f.id }) { fixShown = nil }
    }

    /// Open the pop-up on `issue`: select its face, pulse every face it names (a shared stack:
    /// both ends, one after the other), turn the camera to see them (two: an oblique view).
    private func present(_ issue: FlexibleIssue) {
        fixShown = issue
        guard let r = issue.region else { return }
        model.selectedRegion = r
        model.tab = .face
        let named = issue.named
        for (i, region) in named.enumerated() {
            guard let f = regionsFaces(region).first else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(i)) {
                pulseToken += 1
                pulse = DetentPulse(faceID: FaceID(f), token: pulseToken)
            }
        }
        let loads = named.compactMap { region in
            (model.stack(region) ?? model.stacks.first(where: { $0.key.region == region })?.value)?.load
        }
        let g = loads.count >= 2 ? FlexibleFixPopup.cameraRegion(load: loads[0], other: loads[1], settle: settle)
            : loads.first.flatMap { FlexibleFixPopup.cameraRegion(load: $0, settle: settle) }
        if let g { camera.snap(to: g, animated: !reduceMotion) }
    }

    private func regionsFaces(_ r: Int) -> [Int] { model.regions.faces(of: r, mesh: project.viewerMesh) }

    // MARK: the squish player (bottom-centre, its frame computed against the page's keep-outs)

    @ViewBuilder private func player(in size: CGSize) -> some View {
        if dents != nil, let r = playerFrame(size) {
            // ★ ROUND 5 (S2): which group plays, in its colour ("● Group 2 ▾"); a pick selects that
            // group's first face (the page plays the selected face's group)
            let sims = FlexibleSettingsSquish.playerSims(model: model)
            FlexibleSquishPlayer(loop: loop, fullLabel: fullLabel, width: r.width,
                                 sims: sims, shown: sims.first { $0.id == playingNumber.map(FlexibleSim.groupID) },
                                 onPick: { id in FlexibleSettingsSquish.pick(id, model: model) },
                                 note: FlexibleSettingsSquish.note(model: model, fe: playingFE),
                                 colour: { model.groupColour(number: $0) })
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["player": g.frame(in: .global)])
                }.allowsHitTesting(false))
                .position(x: r.midX, y: r.midY)
        }
    }

    /// The page's keep-outs in its own frame: the panel, the legend, the top row (Exit, undo,
    /// redo), the readiness line — so the player never covers a button or a legend.
    static func playerKeepOut(_ frames: [String: CGRect]) -> [CGRect] {
        guard let page = frames["page"] else { return [] }
        return ["panel", "legend", "exitRow", "notice"].compactMap { frames[$0]?.offsetBy(dx: -page.minX, dy: -page.minY) }
    }

    private func playerFrame(_ size: CGSize) -> CGRect? {
        FlexibleLegendPlacement.player(viewport: size, bottomClearance: PageChrome.edge,
                                       keepOut: Self.playerKeepOut(frames))
    }

    private var fullLabel: String {
        // ★ ROUND 5 (S2 / S4): the playing group's, in the page's unit (FlexibleSettingsSquish)
        FlexibleSettingsSquish.fullLabel(model: model)
    }

    // MARK: chrome

    private var exitButton: some View {
        VStack {
            HStack {
                HStack {
                    // ★ BATCH B (item 9.3): Exit consults the readiness — blocked ONLY by what truly
                    // stops a lattice, and then it opens the fix instead of leaving
                    let r = model.readiness
                    // ★ ROUND 5 (S9): "Exit" until something differs from how the page opened (a value —
                    // undoing back reads "Exit" again); "Save & Exit" after; "Fix 1 thing" while blocked
                    let modified = FlexibleSettingsExit.modified(model.settings, since: opened)
                    Button {
                        switch FlexibleSettingsExit.decide(model.readiness, modified: modified) {
                        case .exit:
                            if modified {
                                model.save()                  // Save & Exit: the main page bakes (Lattice view on)
                            } else {
                                model.exitUnchanged = true    // Exit: nothing moves on the main page
                            }
                            onExit()
                        case .fix(let issue):
                            present(issue)
                        }
                    } label: {
                        Text(FlexibleSettingsExit.title(r, modified: modified))
                            .dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .padding(.vertical, 12).padding(.horizontal, DS.Space.xl5)
                            .background(Capsule().fill((r.isReady || !modified ? DS.Color.accent : DS.Color.warning).color))
                    }
                    .buttonStyle(.plain)
                    .background(GeometryReader { g in
                        // (and what it says, for the hosted test: "exitTitle:Save & Exit")
                        Color.clear.preference(key: FlexibleKeepOutKey.self,
                                               value: ["exitButton": g.frame(in: .global),
                                                       "exitTitle:" + FlexibleSettingsExit.title(r, modified: modified): .zero])
                    }.allowsHitTesting(false))
                    .accessibilityIdentifier("flexible-exit")
                    // the project's own snapshot history: every Flexible setting is undoable (S5)
                    ForEach([(true, "arrow.uturn.backward"), (false, "arrow.uturn.forward")], id: \.1) { undo, icon in
                        Button {
                            Self.history(undo: undo, project: project, model: model)
                        } label: {
                            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DS.Color.textPrimary.color)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(DS.Color.chipSolid.color))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(undo ? "flexible-undo" : "flexible-redo")
                    }
                }
                // ★ the WHOLE row (Exit, undo, redo) — the top line's band starts right of it
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["exitRow": g.frame(in: .global)])
                }.allowsHitTesting(false))
                Spacer()
            }
            Spacer()
        }
        .padding(PageChrome.edge)
    }

    /// ★ THE PAGE'S UNDO / REDO: the project's own snapshot history, then — ★ D2 REVIEW — the
    /// main page's loads re-read (no edit, no undo step: the redo stack survives) before the
    /// designs re-run. The cached loads had kept the undone weight: a group line read
    /// "Squeeze 10–12 kg", the pencil seeded 12 and the next press asked for the pad.
    @MainActor
    static func history(undo: Bool, project: ProjectModel, model: FlexibleStageModel) {
        if undo { project.performUndo() } else { project.performRedo() }
        model.refreshMainPageLoads()
        model.recomputeAll()
    }

    /// The toast line's height under the top line (the pop-up goes below it).
    static let toastRowHeight: CGFloat = 30

    /// ★ THE PANEL MAY GROW UP TO THE TOP CHROME (verification of D1; FlexibleSettingsPanel.maxHeight):
    /// the Exit row, the top line and its toast, the fix pop-up while it is up.
    private func panelMaxHeight(_ size: CGSize) -> CGFloat {
        var band = noticeBand(size)
        if model.toast != nil { band.size.height += Self.toastRowHeight }
        var top = [exitRowLocal(), band]
        if fixShown != nil, let p = frames["popup"], let page = frames["page"] {
            top.append(p.offsetBy(dx: -page.minX, dy: -page.minY))
        }
        return FlexibleSettingsPanel.maxHeight(viewport: size, topChrome: top)
    }

    /// The Exit row in the page's frame (measured; a nominal row before the first layout).
    private func exitRowLocal() -> CGRect {
        guard let row = frames["exitRow"] else {
            return CGRect(x: PageChrome.edge, y: PageChrome.edge, width: 226, height: 44)
        }
        guard let page = frames["page"] else { return row }
        return row.offsetBy(dx: -page.minX, dy: -page.minY)
    }

    /// ★ THE TOP LINE'S BAND (batch B review): right of the Exit row, left of the gizmo —
    /// or its own row under Exit when that is too narrow (11" portrait).
    private func noticeBand(_ size: CGSize) -> CGRect {
        FlexibleLegendPlacement.noticeBand(viewport: size, exitRow: exitRowLocal())
    }

    /// The legend, placed by FlexibleLegendPlacement.legend against the gizmo and the top line
    /// (its own size measured; trailing-centred until the first measurement).
    @ViewBuilder private func legend(in size: CGSize) -> some View {
        // ★ BATCH C VERIFICATION: the legend's BODY lets every touch through (a curve point or
        // the curve line under it stays live — "tap the line adds a point"); only its tab row
        // ("TAP TO READ") takes the tap that drills in and out
        // ★ ROUND 4 (img 1): the legend folds to the lattice legend's bar (the scale alone) — a
        // tap on the bar brings it back; its chevron (top right) folds it
        let view = Group {
            if legendMinimized {
                // ★ A BUTTON (verification of D1): the tap gesture that brought it back was untested
                Button { legendMinimized = false } label: {
                    FlexibleLegendBar(fraction: legendDrilled ? reading?.fraction : nil)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show the key")
                .accessibilityIdentifier("flexible-legend-expand")
            } else {
                FlexibleLegend(model: model, drawnLattice: nil, drilled: legendDrilled,
                               reading: legendDrilled ? reading : nil)
                    .overlay(alignment: .top) {
                        HStack(spacing: 0) {
                            Color.clear
                                .frame(maxWidth: .infinity).frame(height: FlexibleLegend.tabHeight)
                                .contentShape(Rectangle())
                                .onTapGesture { legendDrilled.toggle(); reading = nil }
                                .accessibilityElement()
                                .accessibilityLabel(legendDrilled ? "Stop reading" : "Tap to read")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier("flexible-settings-legend-tab")
                            Button { legendMinimized = true } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(DS.Color.accent.color)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Minimise the key")
                            .accessibilityIdentifier("flexible-legend-minimize")
                        }
                    }
            }
        }
            .accessibilityIdentifier("flexible-settings-legend")
            .background(GeometryReader { g in
                Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["legend": g.frame(in: .global)])
            }.allowsHitTesting(false))
        if let measured = frames["legend"]?.size, measured.width > 0, measured.height > 0,
           let r = FlexibleLegendPlacement.legend(size: measured, viewport: size,
                                                  keepOut: [FlexibleLegendPlacement.gizmoFrame(viewport: size), noticeBand(size)]) {
            view.position(x: r.midX, y: r.midY)
        } else {
            view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, PageChrome.edge)
        }
    }

    /// ★ THE TOP LINE (batch B, item 9): opening / a failure, else the live READINESS line —
    /// "Ready: Exit builds the lattice" (green) or "1 thing to fix: … [Fix]" (the pop-up) —
    /// and, under it for a moment, what an automatic fix did. In its band (noticeBand).
    @ViewBuilder private func notice(in size: CGSize) -> some View {
        let band = noticeBand(size)
        VStack(spacing: DS.Space.xs) {
            if let text = noticeText {
                noticePill(text, icon: "info.circle.fill", colour: DS.Color.textSecondary.color, fix: nil)
            } else if model.sceneState == .ready {
                let r = model.readiness
                // a failed build, and ★ (D2 review) separate groups that compete, in warning colour
                let good = r.isReady && !r.buildFailed && r.advisory == nil   // ★ batch E: competing, or no lattice under a face
                // ★ ROUND 5 (S9): it names the button — "Save & Exit builds…" only once something changed
                noticePill(FlexibleSettingsExit.readyLine(r.oneLine, modified: FlexibleSettingsExit.modified(model.settings, since: opened)),
                           icon: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                           colour: (good ? FlexibleStageStyle.accentToken : DS.Color.warning).color,
                           fix: r.blocking.first ?? r.advisory)
            }
            if let t = model.toast {
                Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
                    .background(Capsule().fill(DS.Color.chipSolid.color))
                    .accessibilityIdentifier("flexible-toast")
            }
        }
        .frame(width: band.width)
        .padding(.leading, band.minX)
        .padding(.top, band.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func noticePill(_ text: String, icon: String, colour: Color, fix: FlexibleIssue?) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(colour)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("flexible-readiness-line")
            if let fix {
                Button { present(fix) } label: {
                    Text("Fix").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Capsule().fill(DS.Color.warning.color.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-readiness-fix")
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
        .background(Capsule().fill(DS.Color.chipSolid.color))
        .overlay(Capsule().stroke(DS.Color.strokeSubtle.color, lineWidth: 1))
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["notice": g.frame(in: .global)])
        }.allowsHitTesting(false))
    }

    private var noticeText: String? {
        switch model.sceneState {
        case .opening: return "Opening the part — its faces, stacks and lattice region."
        case .failed(let why): return "The part could not be opened: \(why)"
        default: return nil
        }
    }

    // (the panel: FlexibleSettingsPanel — round 4)
}

/// The frames the depth chips keep out of (the panel, the legend) and the stage's own.
struct FlexibleKeepOutKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - overlays that follow the camera

struct FlexibleStageOverlays: View {
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var proj: FlexibleProjectionBox
    /// The page's exaggeration (the dent's and the prism's k).
    var exaggeration: Double = 1
    /// Where a chip cannot be reached (the panel, the legend), in stage points.
    var keepOut: [CGRect] = []

    var body: some View {
        ZStack {
            // ★ ROUND 3: BOTH curves on the selected pressed face, on its own two edges, at once
            // ("X and Y always combined"); the frame arrows went with the frame rotation.
            if model.tab == .face, let r = model.selectedRegion, let k = model.key(r),
               let g = model.geometry[k], let f = model.settings.face(r), f.isLoaded {
                // ★ ROUND 4: Curves or Stamp — never both; the Stamp face's handle is below
                ForEach(Self.curveAxes(f), id: \.self) { axis in
                    FlexibleCurveEditor(projection: proj.projection,
                                        baseline: axis == "x" ? g.baselineX : g.baselineY,
                                        curve: axis == "x" ? f.curveX : f.curveY,
                                        label: axis.uppercased(), tint: FlexibleStageStyle.onPart,
                                        selected: selection(r, axis),
                                        onChange: { c in setCurve(r, axis, c) },
                                        onCommit: { model.save() },
                                        // ★ VERIFICATION OF D1: never drawn or touched under the panel,
                                        // the legend or the player (img 6's class, for the curves)
                                        keepOut: keepOut)
                }
                // ★ ROUND 3 (item 1.1): the deepest squish, dragged out as a prism
                FlexibleDepthChips(model: model, projection: proj.projection, k: exaggeration, keepOut: keepOut)
                // ★ ROUND 4 (D1): a Stamp face's ONE stamp — never under the panel or the legend,
                // and never on the depth chip (it keeps clear of the chip's place: `k`)
                FlexibleFaceStampHandle(model: model, projection: proj.projection, keepOut: keepOut, k: exaggeration)
            }
        }
    }

    /// The curves drawn on a face: both (X and Y, combined) under Curves, none under Stamp —
    /// the curves vanish the moment Stamp is chosen (his img 1).
    static func curveAxes(_ f: FlexibleFaceSettings) -> [String] { f.isStampShape ? [] : ["x", "y"] }

    /// The × of one curve, held by the model (a tap on the part clears it).
    private func selection(_ r: Int, _ axis: String) -> Binding<Int?> {
        Binding(get: { model.curvePoint.flatMap { $0.region == r && $0.axis == axis ? $0.index : nil } },
                set: { model.curvePoint = $0.map { FlexCurvePoint(region: r, axis: axis, index: $0) } })
    }

    private func setCurve(_ r: Int, _ axis: String, _ c: FlexCurve) {
        model.edit({ s in
            guard var f = s.face(r) else { return }
            if axis == "y" { f.curveY = c } else { f.curveX = c }
            s.setFace(f)
        }, recompute: false)
        model.curveChanged(region: r)
    }
}

// MARK: - small shared controls (the wizard's chip row, in this page's own file)

struct FlexChips: View {
    let options: [(id: String, label: String)]
    let selection: String
    var id: String = "flexible-chip"
    var disabled: Set<String> = []
    /// false: each chip its own width (the panel's rows — "Honeycomb" read "Honeyco…" in an
    /// equal third of a fixed frame).
    var equalWidths = true
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.id) { o in
                let on = o.id == selection
                Button { onPick(o.id) } label: {
                    Text(o.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(on ? DS.Color.textPrimary.color
                                         : (disabled.contains(o.id) ? DS.Color.textDisabled.color
                                            : DS.Color.textTertiary.color))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: equalWidths ? .infinity : nil)
                        .background(Capsule().fill(on ? DS.Color.fillSelected.color : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(id)-\(o.id)")
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.Color.background.opacity(0.35).color)
            .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
    }
}

struct FlexSectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.Color.textTertiary.color)
            .textCase(.uppercase)
    }
}

struct FlexCaption: View {
    let text: String
    var colour: Color = DS.Color.textTertiary.color
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A number the user types: a chip that opens the shared number pad (standing rule:
/// every numeric input opens a numeric keypad).
struct FlexNumberChip: View {
    let key: String
    let title: String
    let unit: String
    let value: Double
    var decimals = 1
    @Binding var padTarget: String?
    let onValue: (Double) -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
            Spacer()
            Button { padTarget = key } label: {
                Text("\(String(format: "%.\(decimals)f", value)) \(unit)")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(DS.Surface.valuePill.color))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flexible-number-\(key)")
            .numberPad(Binding(get: { padTarget == key }, set: { if !$0 { padTarget = nil } }),
                       config: .init(title: title, unit: unit, allowsDecimal: true), seed: value) { v in
                if let v, v > 0 { onValue(v) }
            }
        }
    }
}

/// The badge every squish number wears (R7): tier + ± band, from core.
struct FlexTierBadge: View {
    let tier: FlexTier
    var body: some View {
        HStack(spacing: 4) {
            Text(tier.tier).font(.system(size: 11, weight: .bold))
            Text("± \(Int((tier.band * 100).rounded())) %").font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tier.tier == "estimated" ? DS.Color.warning.color : DS.Color.textSecondary.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(DS.Color.fillSubtle.color))
    }
}

/// The per-face numbers: range with tier and band, and the clamped columns in plain words.
struct FlexibleFaceResult: View {
    let design: FlexFaceDesignInfo
    @ObservedObject var model: FlexibleStageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FlexSectionTitle(text: model.showBuildable ? "Can be built" : "You drew")
                Spacer()
                FlexTierBadge(tier: design.tier)
            }
            if let r = model.showBuildable ? design.buildableDepthRange : design.targetDepthRange {
                let b = design.tier.band
                Text(String(format: "%.1f – %.1f mm squish", r.lowerBound, r.upperBound))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                if model.showBuildable {
                    FlexCaption(text: String(format: "± %.0f %%: %.1f – %.1f mm", b * 100,
                                             r.lowerBound * (1 - b), r.upperBound * (1 + b)))
                }
            }
            FlexCaption(text: design.tier.why)
            let t = model.designTempC.map { "\(Int($0)) °C" } ?? "—"
            FlexCaption(text: "\(model.designTopology.capitalized) at \(t)" + (model.settings.topology == "auto" ? " (Auto)" : ""))
            let lines = clampLines
            if !lines.isEmpty {
                ForEach(lines, id: \.self) { FlexCaption(text: $0, colour: DS.Color.warning.color) }
            }
            if design.targetExtrapolated > 0 {
                FlexCaption(text: "\(design.targetExtrapolated) columns squish past the tested 20 % — extrapolated.")
            }
            if design.designStampRigidAveraged {
                FlexCaption(text: "A rigid design stamp is read as its stated weight spread over the area it covers — its real pressure depends on the lattice being designed.")
            }
            if design.designStampOffFace {
                FlexCaption(text: String(format: "%.1f N of the design stamp lands off this face.", design.designStampOffFaceN),
                            colour: DS.Color.warning.color)
            }
        }
    }

    private var clampLines: [String] {
        var l: [String] = []
        if design.tooFirm > 0 { l.append("\(design.tooFirm) columns: even the softest lattice will not squish that far here.") }
        if design.tooSoft > 0 { l.append("\(design.tooSoft) columns: even the firmest lattice squishes further than drawn.") }
        if design.beyondData > 0 { l.append("\(design.beyondData) columns: that squish is beyond the tested data.") }
        if design.solidUnderMap > 0 { l.append("\(design.solidUnderMap) columns are solid under the drawing (no lattice there).") }
        if model.showBuildable, design.buildableBeyondData > 0 {
            l.append("\(design.buildableBeyondData) columns leave the data once smoothed — no number there.")
        }
        return l
    }
}

/// The map's legend: ONE line saying what it shows and how much it is exaggerated ("What
/// you drew · shown ×7"), the ramp, 0 … deepest, and the tier where core gave one. ★ ROUND 3:
/// the long captions moved behind the (i) (FlexibleRowCopy); on the trailing edge, centred.
/// ★ BATCH C: it takes a tap — "TAP TO READ" → "TAP THE PART TO READ" — and marks the reading
/// on its ramp.
struct FlexibleLegend: View {
    @ObservedObject var model: FlexibleStageModel
    /// The generated lattice while it is drawn (X-ray): the map is then the one it was built from.
    var drawnLattice: FlexibleGeneratedLattice? = nil
    var drilled = false
    var reading: FlexibleReading? = nil
    /// The tab row's height — the only part of the legend that takes a tap (the padding above
    /// the "TAP TO READ" line, the line, and half the gap under it).
    static let tabHeight: CGFloat = DS.Space.ml + 16

    var body: some View {
        let shown = FlexibleShownValues(model: model, drawnLattice: drawnLattice)
        let tier = model.checkStampShown.flatMap { model.checks[$0]?.tier }
            ?? model.selectedRegion.flatMap { model.design($0)?.tier }
        let noNumber = shown.values.values.contains { $0.contains { if case .noNumber = $0 { return true } else { return false } } }
        VStack(alignment: .leading, spacing: 6) {
            Text(drilled ? "TAP THE PART TO READ" : "TAP TO READ")
                .font(.system(size: 10, weight: .bold)).tracking(0.7)
                .foregroundStyle(DS.Color.accent.color)
                .accessibilityIdentifier("flexible-legend-tab")
            Text(shown.legendLine).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityIdentifier("flexible-legend-line")
            HStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { i in
                    FlexibleColours.depthColour(fraction: Double(i) / 23).color.frame(width: 9, height: 10)
                }
            }
            .overlay(alignment: .topLeading) {
                if let f = reading?.fraction {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.Color.accent.color)
                        .offset(x: CGFloat(min(1, max(0, f))) * 216 - 4, y: 10)
                }
            }
            HStack {
                Text("0 mm"); Spacer(); Text(String(format: "%.1f mm", shown.maxDepth))
            }
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(DS.Color.textSecondary.color)
            if noNumber {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(DS.Color.textQuaternary.color).frame(width: 12, height: 10)
                    Text("grey · no number").font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            if let tier { FlexTierBadge(tier: tier) }
        }
        .frame(width: 236)
        .padding(DS.Space.ml)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder((drilled ? DS.Color.accent : DS.Color.strokePanel).color, lineWidth: drilled ? 1.5 : 1)))
        // ★ PASS-THROUGH (batch C verification): the page lays the tab's tap target over it
        .allowsHitTesting(false)
    }
}

/// The reading a tap pinned on the Settings page's part, re-projected on every camera move
/// (it observes the page's projection box, so the page itself does not re-render).
struct FlexibleReadingCallout: View {
    @ObservedObject var proj: FlexibleProjectionBox
    let reading: FlexibleReading?

    var body: some View {
        if let r = reading, let s = proj.projection?.project(r.anchor) {
            // ★ the value in the accent blue, in its own squircle (FlexibleReadingTag)
            FlexibleReadingTag(reading: r)
                .offset(x: s.x + 2, y: s.y - FlexibleReadingTag.halfHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityIdentifier("flexible-reading-callout")
        }
    }
}

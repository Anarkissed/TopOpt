// FlexibleMainStatusPill — the main page's bottom-bar pill under Flexible (task
// 2026-09-29-flexible-screens, round 3 batch B, item 7.1; hook H10).
//
// ★ NO OCTET "LATTICE" RUN UNDER FLEXIBLE. The bottom bar's `latticeThisButton` ("Lattice ·
// nothing set to lattice") is replaced, only when the project is Flexible, by this pill in
// the same slot and stature: "Lattice" over one line — "Ready", "Building…", the shape-only
// label, a failed build's words, or the ONE thing to fix in its short pill form
// (FlexibleIssue.pill — the whole sentence is on the pop-up it opens).
// ★ ROUND 4 (C2 — his img 6 and answer 2: "the large bottom buttons are for exports and
// starting the actual core process. So when Lattice Ready shows, tapping it should send to Core
// and the export path"): Ready → core's Flexible runner and the Export step
// (FlexibleMainStage.pillTapped → FlexibleCoreRun); the one thing to fix → Settings on its
// pop-up; building → nothing opens. It used to open Settings on EVERY tap, a ready lattice
// included — his img 6.
// ★ C2 VERIFICATION: a PREVIEW tone — the lattice preview is built, but core can't take the job
// as it stands (his pinch, two squeeze groups, a calibrate-first filament): never the Ready
// green; its tap opens the Export step on why and what core CAN run. `goToLattice` (H10): on
// another stage "Building…" (and a Ready his edits there made stale) takes him to the Lattice
// stage, where builds start.
//
// Also here: the Flexible view toggles (H5 — Dent heat, Stress, Lattice; C2: no X-ray button; ★ S1b: [Prisms])
// and the main page's squish player slot.

import SwiftUI
import TopOptDesign

public struct FlexibleMainStatusPill: View {
    @ObservedObject var main: FlexibleMainStage
    let open: () -> Void
    let goToLattice: () -> Void

    public init(main: FlexibleMainStage, open: @escaping () -> Void, goToLattice: @escaping () -> Void = {}) {
        self.main = main
        self.open = open
        self.goToLattice = goToLattice
    }

    public var body: some View {
        // the model's own changes (designs landing, the build) redraw ONLY this pill
        if let m = main.model {
            FlexibleMainStatusPillBody(model: m, main: main, open: open, goToLattice: goToLattice)
        } else {
            Self.pill(FlexibleMainStatus.of(model: nil), action: open)
        }
    }

    /// The pill's fill: the Ready green only when core can take the job (★ C2 VERIFICATION).
    static func fill(_ t: FlexibleMainStatus.Tone) -> RGBA {
        t == .ready ? FlexibleStageStyle.accentToken : DS.Color.fillDisabled
    }
    /// Its outline: warning for a fix, the green for a preview (the preview is good; core can't
    /// take it yet), the panel's otherwise.
    static func stroke(_ t: FlexibleMainStatus.Tone) -> RGBA {
        switch t {
        case .fix: return DS.Color.warning
        case .preview: return FlexibleStageStyle.accentToken
        default: return DS.Color.strokePanel
        }
    }

    static func pill(_ s: FlexibleMainStatus, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    if s.tone == .building { ProgressView().controlSize(.mini).tint(DS.Color.textPrimary.color) }
                    if s.tone == .fix { Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12, weight: .bold)) }
                    Text("Lattice").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                }
                Text(s.line)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 300)
                    .opacity(0.85)
                    .accessibilityIdentifier("flexible-status-line")
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, 11).padding(.horizontal, DS.Space.xl3)
            .background(Capsule().fill(fill(s.tone).color)
                .overlay(Capsule().strokeBorder(stroke(s.tone).color, lineWidth: s.tone == .ready ? 0 : 1)))
            .dsShadow(s.tone == .ready ? DS.Shadow.accentGlow : DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("flexible-status-pill")
    }
}

private struct FlexibleMainStatusPillBody: View {
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var run: FlexibleCoreRun
    let open: () -> Void
    let goToLattice: () -> Void

    init(model: FlexibleStageModel, main: FlexibleMainStage, open: @escaping () -> Void, goToLattice: @escaping () -> Void) {
        self.model = model; self.main = main; self._run = ObservedObject(wrappedValue: main.coreRun)
        self.open = open; self.goToLattice = goToLattice
    }

    var body: some View {
        // ★ C2: while core runs the job, the pill says so (a tap shows the run)
        let s = FlexibleMainStatus.of(model: model).whileSending(run.isSending)
        FlexibleMainStatusPill.pill(s) {
            main.pillTapped(s, open: open, goToLattice: goToLattice)
        }
    }
}

/// H5 / H5': the main Flexible page's views, where `viewModeToggles` sits (below the gizmo, on
/// `edge`) — the same 40 pt buttons. ★ ROUND 4 (C2, his img 5): Dent heat, Stress, Lattice — no
/// X-ray button: the Lattice view IS the X-ray rendering (FlexibleMainStage.xray). Heat and
/// Lattice on by default. The Lattice button shows / hides the lattice, or — with nothing to
/// show — opens Settings, whose Exit turns the view on (`openSettings`, H5's closure). The
/// "Lattice ready" note sits on the row's line, left of the buttons (FlexibleMainNoteView — ★ C2
/// verification: it was under the row);
/// ★ BATCH C VERIFICATION: Stress and Dent heat are the two colourings of the pressed map — one
/// at a time (FlexibleMainStage.toggleStress); Stress leaves X-ray and the lattice alone.
/// ★ STRESS IS SOLVED DIRECTLY (item T): `solver` is the workspace's own FlexibleStressSolver
/// (latticeSim + the regions the load case reaches), never `startStressSolveIfNeeded` (gated on
/// `lattice.enabled && needsStressSolve`, which a fresh Flexible part never passes). While it
/// solves the button spins; the Stress legend says "Simulating…" — once (the #354 banner and a
/// caption under this row said it too: four times).
public struct FlexibleMainViewToggles: View {
    @ObservedObject var main: FlexibleMainStage
    let solver: FlexibleStressSolver?
    /// ★ C2: H5 hands the workspace's "open Settings" over (the Lattice button with nothing to show).
    let openSettings: () -> Void

    public init(main: FlexibleMainStage, solver: FlexibleStressSolver? = nil, openSettings: @escaping () -> Void = {}) {
        self.main = main
        self.solver = solver
        self.openSettings = openSettings
    }

    static let heatIcon = "thermometer.medium"
    static let stressIcon = "waveform.path.ecg"
    /// ★ S1b (round 6 item 3): Dent heat, Stress, Lattice and [Prisms] (the Settings page's own button and glyph).
    static let buttons = 4

    // ★ a thermometer reads "heat" (the stacked-layers glyph did not — batch B review)
    private var heatButton: some View {
        FlexibleViewButton(icon: FlexibleMainViewToggles.heatIcon, label: "Dent heat", on: main.heat) { main.toggleHeat() }
            .accessibilityIdentifier("flexible-main-view-heat")
    }
    private var stressButton: some View {
        FlexibleViewButton(icon: FlexibleMainViewToggles.stressIcon, label: main.stressRunning ? "Simulating…" : "Stress",
                           on: main.stress) { main.toggleStress() }
            .overlay {
                if main.stressRunning, main.stress {
                    ProgressView().controlSize(.small).tint(DS.Color.textPrimary.color).allowsHitTesting(false)
                }
            }
            .accessibilityIdentifier("flexible-main-view-stress")
    }
    // ★ C2: shows / hides the lattice — or, with nothing to show, opens Settings
    private var latticeButton: some View {
        FlexibleViewButton(icon: "cube.transparent", label: "Lattice", on: main.latticeShown) {
            main.latticeButtonTapped(openSettings: openSettings)
        }
            .accessibilityIdentifier("flexible-main-view-lattice")
    }
    // ★ S1b (round 6 item 3 — his img3: "a view that turns on/off ALL squish prisms"): every pressed face's prism,
    // faint, with its mm; it turns the Lattice view (the X-ray) on itself
    private var prismsButton: some View {
        FlexibleViewButton(icon: FlexibleStageViews.prismsIcon, label: "Prisms", on: main.prismsOn,
                           action: { main.togglePrisms() }, glyph: FlexibleStageViews.prismsGlyph(on: main.prismsOn))
            .accessibilityIdentifier("flexible-main-view-prisms")
    }

    public var body: some View {
        // the workspace's solver (no publish: its sim's phase arrives on the next run-loop turn)
        let _ = solver.map { main.attach($0) }
        GeometryReader { g in
            HStack(spacing: DS.Space.s) {
                // ★ C2: "Lattice ready" — ★ C2 VERIFICATION: beside the row, in the band `frame` holds
                FlexibleMainNoteView(note: main.note, main: main, maxWidth: Self.noteFrame(viewport: g.size).width)
                // ★ S1b: one line of four — or, on a pad too narrow for the note beside four (the iPad mini), two over two
                Group {
                    if Self.columns(viewport: g.size) >= Self.buttons {
                        HStack(spacing: DS.Space.s) { heatButton; stressButton; latticeButton; prismsButton }
                    } else {
                        VStack(alignment: .trailing, spacing: DS.Space.s) {
                            HStack(spacing: DS.Space.s) { heatButton; stressButton }
                            HStack(spacing: DS.Space.s) { latticeButton; prismsButton }
                        }
                    }
                }
                .latticeBandChipKeepOut()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, PageChrome.belowGizmo)
            .padding(.trailing, PageChrome.edge)
        }
    }

    /// Where the toggles sit, for the player's and the legends' keep-outs: the row (★ S1b: four 40 pt
    /// buttons, `s` apart — two over two on a narrow pad) AND the note's band beside it (★ C2: reserved, so a note coming and
    /// going never moves a legend; ★ C2 VERIFICATION: on the row's line, so it ends where the row
    /// ends and costs the legends nothing).
    static func frame(viewport: CGSize) -> CGRect {
        rowFrame(viewport: viewport).union(noteFrame(viewport: viewport))
    }
    /// The buttons alone (★ S1b: one line of four, or two over two — `columns`).
    static func rowFrame(viewport: CGSize) -> CGRect {
        let c = columns(viewport: viewport), r = (buttons + c - 1) / c
        let w = CGFloat(c) * 40 + CGFloat(c - 1) * DS.Space.s
        let h = CGFloat(r) * 40 + CGFloat(r - 1) * DS.Space.s
        return CGRect(x: viewport.width - PageChrome.edge - w, y: PageChrome.belowGizmo, width: w, height: h)
    }
    /// ★ S1b: the buttons per line — four, unless four in a line would leave the "Lattice ready · Show" note less than
    /// its `minWidth` beside them, clear of the left panel (the iPad mini portrait: 148 pt); then two over two.
    static func columns(viewport: CGSize) -> Int {
        let line = CGFloat(buttons) * 40 + CGFloat(buttons - 1) * DS.Space.s
        let room = viewport.width - PageChrome.edge - line - DS.Space.s
            - (FlexibleMainLegendLayout.leftStrip(viewport: viewport).maxX + DS.Space.s)
        return room >= FlexibleMainNote.minWidth ? buttons : (buttons + 1) / 2
    }
}

/// The main page's squish player: bottom-centre, above the bottom bar, clear of the view
/// toggles and of the legends (batch C: their real frames, FlexibleMainLegendLayout). Only
/// when there is something to squish.
public struct FlexibleMainPlayerSlot: View {
    @ObservedObject var main: FlexibleMainStage
    let bottomClearance: CGFloat
    /// ★ BATCH B REVIEW: the width of the bottom-right settings-chip column (Gravity, …) — it
    /// sits in the player's row (0 when the column is not shown). Its widest chip is the
    /// bottom one (BottomChipOrder), the one beside the player.
    let chipColumnWidth: CGFloat

    public init(main: FlexibleMainStage, bottomClearance: CGFloat, chipColumnWidth: CGFloat = 0) {
        self.main = main
        self.bottomClearance = bottomClearance
        self.chipColumnWidth = chipColumnWidth
    }

    /// The trailing legend slot the main page's legends take (batch C) — kept clear now.
    public static let legendSize = CGSize(width: 268, height: 168)
    /// How tall the chip column is kept clear above the bar (four chip rows).
    static let chipColumnHeight: CGFloat = 4 * (PageChrome.compactButton + DS.Space.s)

    public static func keepOut(viewport: CGSize, bottomClearance: CGFloat = 0, chipColumnWidth: CGFloat = 0,
                               legends: [CGRect]? = nil) -> [CGRect] {
        var k = [FlexibleMainViewToggles.frame(viewport: viewport),
                 // ★ BATCH C VERIFICATION: the left panel strip (Selections, the stage buttons) —
                 // at 11" portrait the player sat inside the Selections column
                 FlexibleMainLegendLayout.leftStrip(viewport: viewport)]
        // ★ BATCH C: the legends' real frames (FlexibleMainLegendLayout); the reserved slot
        // only when none are handed over
        if let legends { k += legends } else if let l = FlexibleLegendPlacement.legend(size: legendSize, viewport: viewport) { k.append(l) }
        if chipColumnWidth > 0 {
            // bottomRightControls: trailing on `edge`, its bottom `bottomClearance + m` up
            let bottom = viewport.height - bottomClearance - DS.Space.m
            k.append(CGRect(x: viewport.width - PageChrome.edge - chipColumnWidth, y: bottom - chipColumnHeight,
                            width: chipColumnWidth, height: chipColumnHeight))
        }
        return k
    }

    /// Where a player of `size` goes: clear of the buttons, the left panel, the chip column and the ONE legend card
    /// (★ S1b: the card itself — it now comes for [Prisms]' row with no scale, where no kind names it).
    static func place(main: FlexibleMainStage, viewport v: CGSize, bottomClearance: CGFloat, chipColumnWidth: CGFloat,
                      size: CGSize) -> CGRect? {
        FlexibleLegendPlacement.player(viewport: v, bottomClearance: bottomClearance,
                                       keepOut: keepOut(viewport: v, bottomClearance: bottomClearance, chipColumnWidth: chipColumnWidth,
                                                        legends: main.legendCard(viewport: v, bottomClearance: bottomClearance,
                                                                                 chipColumnWidth: chipColumnWidth).map { [$0.frame] } ?? []),
                                       size: size)
    }
    /// ★ S1b: where the player is now (nil while it does not show) — the main page's mm tags keep clear of it.
    static func frame(main: FlexibleMainStage, viewport v: CGSize, bottomClearance: CGFloat, chipColumnWidth: CGFloat) -> CGRect? {
        guard main.playerShown else { return nil }
        return place(main: main, viewport: v, bottomClearance: bottomClearance, chipColumnWidth: chipColumnWidth,
                     size: FlexibleSquishPlayer.size(picker: main.sims.count > 1, note: main.simNote != nil))
    }

    public var body: some View {
        GeometryReader { g in
            // ★ ROUND 4 (D2): the group picker widens it, a group's miss line heightens it — the
            // placement keeps the whole of it clear of every button and legend
            let sims = main.sims, note = main.simNote
            let size = FlexibleSquishPlayer.size(picker: sims.count > 1, note: note != nil)
            if main.playerShown,
               let r = Self.place(main: main, viewport: g.size, bottomClearance: bottomClearance, chipColumnWidth: chipColumnWidth,
                                  size: size) {
                FlexibleSquishPlayer(loop: main.loop, fullLabel: main.fullLabel, width: r.width,
                                     playAllLive: main.playAllLive, noteFor: { main.simNote(playing: $0) },   // ★ G verification: the playing group
                                     sims: sims, shown: main.shownSimInfo, onPick: { main.pick($0) }, note: note,
                                     colour: { n in main.model?.groupColour(number: n) ?? FlexibleSqueezeGroups.colour(number: n) })   // ★ S1: his chosen colour
                    .latticeBandChipKeepOut()
                    .position(x: r.midX, y: r.midY)
            }
        }
    }
}

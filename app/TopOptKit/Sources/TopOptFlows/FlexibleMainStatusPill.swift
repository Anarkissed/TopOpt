// FlexibleMainStatusPill — the main page's bottom-bar pill under Flexible (task
// 2026-09-29-flexible-screens, round 3 batch B, item 7.1; hook H10).
//
// ★ NO OCTET "LATTICE" RUN UNDER FLEXIBLE. The bottom bar's `latticeThisButton` ("Lattice ·
// nothing set to lattice") is replaced, only when the project is Flexible, by this pill in
// the same slot and stature: "Lattice" over one line — "Ready", "Building…", the shape-only
// label, a failed build's words, or the ONE thing to fix in its short pill form
// (FlexibleIssue.pill — the whole sentence is on the pop-up it opens).
// A tap opens Settings; with something to fix, the page opens on that fix's pop-up.
//
// Also here: the Flexible view toggles (H5 — X-ray, Dent heat, Stress, Lattice) and the main
// page's squish player slot.

import SwiftUI
import TopOptDesign

public struct FlexibleMainStatusPill: View {
    @ObservedObject var main: FlexibleMainStage
    let open: () -> Void

    public init(main: FlexibleMainStage, open: @escaping () -> Void) {
        self.main = main
        self.open = open
    }

    public var body: some View {
        // the model's own changes (designs landing, the build) redraw ONLY this pill
        if let m = main.model {
            FlexibleMainStatusPillBody(model: m, main: main, open: open)
        } else {
            Self.pill(FlexibleMainStatus.of(model: nil), action: open)
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
            .background(Capsule().fill((s.tone == .ready ? FlexibleStageStyle.accentToken : DS.Color.fillDisabled).color)
                .overlay(Capsule().strokeBorder((s.tone == .fix ? DS.Color.warning : DS.Color.strokePanel).color,
                                                lineWidth: s.tone == .ready ? 0 : 1)))
            .dsShadow(s.tone == .ready ? DS.Shadow.accentGlow : DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("flexible-status-pill")
    }
}

private struct FlexibleMainStatusPillBody: View {
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var main: FlexibleMainStage
    let open: () -> Void

    var body: some View {
        let s = FlexibleMainStatus.of(model: model)
        FlexibleMainStatusPill.pill(s) {
            if s.fix != nil { main.openFix() }
            open()
        }
    }
}

/// H5 / H5': the main Flexible page's views, where `viewModeToggles` sits (below the gizmo, on
/// `edge`) — the same 40 pt buttons. X-ray, Dent heat, Stress, Lattice (batch C: Stress). X-ray,
/// Heat and Lattice on by default. Lattice turns X-ray on (the walls are drawn in X-ray);
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

    public init(main: FlexibleMainStage, solver: FlexibleStressSolver? = nil) {
        self.main = main
        self.solver = solver
    }

    static let heatIcon = "thermometer.medium"
    static let stressIcon = "waveform.path.ecg"
    static let buttons = 4

    public var body: some View {
        // the workspace's solver (no publish: its sim's phase arrives on the next run-loop turn)
        let _ = solver.map { main.attach($0) }
        HStack(spacing: DS.Space.s) {
            FlexibleViewButton(icon: "square.stack.3d.up", label: "X-ray", on: main.xray) { main.xray.toggle() }
                .accessibilityIdentifier("flexible-main-view-xray")
            // ★ a thermometer reads "heat" (the stacked-layers glyph did not — batch B review)
            FlexibleViewButton(icon: FlexibleMainViewToggles.heatIcon, label: "Dent heat", on: main.heat) { main.toggleHeat() }
                .accessibilityIdentifier("flexible-main-view-heat")
            FlexibleViewButton(icon: FlexibleMainViewToggles.stressIcon, label: main.stressRunning ? "Simulating…" : "Stress",
                               on: main.stress) { main.toggleStress() }
                .overlay {
                    if main.stressRunning, main.stress {
                        ProgressView().controlSize(.small).tint(DS.Color.textPrimary.color).allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("flexible-main-view-stress")
            FlexibleViewButton(icon: "cube.transparent", label: "Lattice", on: main.latticeShown) { main.toggleLattice() }
                .accessibilityIdentifier("flexible-main-view-lattice")
        }
        .latticeBandChipKeepOut()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, PageChrome.belowGizmo)
        .padding(.trailing, PageChrome.edge)
    }

    /// Where the toggles sit, for the player's and the legends' keep-outs (four 40 pt buttons,
    /// `s` apart).
    static func frame(viewport: CGSize) -> CGRect {
        let w = CGFloat(buttons) * 40 + CGFloat(buttons - 1) * DS.Space.s
        return CGRect(x: viewport.width - PageChrome.edge - w, y: PageChrome.belowGizmo, width: w, height: 40)
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

    public var body: some View {
        GeometryReader { g in
            // ★ ROUND 4 (D2): the group picker widens it, a group's miss line heightens it — the
            // placement keeps the whole of it clear of every button and legend
            let sims = main.sims, note = main.simNote
            let size = FlexibleSquishPlayer.size(picker: sims.count > 1, note: note != nil)
            if main.playerShown,
               let r = FlexibleLegendPlacement.player(viewport: g.size, bottomClearance: bottomClearance,
                                                      keepOut: Self.keepOut(viewport: g.size, bottomClearance: bottomClearance,
                                                                            chipColumnWidth: chipColumnWidth,
                                                                            legends: main.legendFrames(viewport: g.size, bottomClearance: bottomClearance,
                                                                                                       chipColumnWidth: chipColumnWidth).values.map(\.frame)),
                                                      size: size) {
                FlexibleSquishPlayer(loop: main.loop, fullLabel: main.fullLabel, width: r.width,
                                     sims: sims, shown: main.shownSimInfo, onPick: { main.pick($0) }, note: note)
                    .latticeBandChipKeepOut()
                    .position(x: r.midX, y: r.midY)
            }
        }
    }
}

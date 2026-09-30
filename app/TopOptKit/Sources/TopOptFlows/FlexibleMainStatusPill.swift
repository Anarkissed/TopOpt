// FlexibleMainStatusPill — the main page's bottom-bar pill under Flexible (task
// 2026-09-29-flexible-screens, round 3 batch B, item 7.1; hook H10).
//
// ★ NO OCTET "LATTICE" RUN UNDER FLEXIBLE. The bottom bar's `latticeThisButton` ("Lattice ·
// nothing set to lattice") is replaced, only when the project is Flexible, by this pill in
// the same slot and stature: "Lattice" over one line — "Lattice ready", "Building the
// lattice…", the shape-only label, or the ONE thing to fix (FlexibleReadiness.oneLine).
// A tap opens Settings; with something to fix, the page opens on that fix's pop-up.
//
// Also here: the minimal Flexible view toggles (H5 — X-ray, Heat, Lattice; batch C adds
// Stress and the legends) and the main page's squish player slot.

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

/// H5: the main Flexible page's views, where `viewModeToggles` sits (below the gizmo, on
/// `edge`) — the same 40 pt buttons. X-ray, Heat and Lattice, all on by default.
public struct FlexibleMainViewToggles: View {
    @ObservedObject var main: FlexibleMainStage

    public init(main: FlexibleMainStage) { self.main = main }

    public var body: some View {
        HStack(spacing: DS.Space.s) {
            FlexibleViewButton(icon: "square.stack.3d.up", label: "X-ray", on: main.xray) { main.xray.toggle() }
                .accessibilityIdentifier("flexible-main-view-xray")
            FlexibleViewButton(icon: "square.3.layers.3d.down.right", label: "Dent heat", on: main.heat) { main.heat.toggle() }
                .accessibilityIdentifier("flexible-main-view-heat")
            FlexibleViewButton(icon: "cube.transparent", label: "Lattice", on: main.latticeOn) { main.latticeOn.toggle() }
                .accessibilityIdentifier("flexible-main-view-lattice")
        }
        .latticeBandChipKeepOut()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, PageChrome.belowGizmo)
        .padding(.trailing, PageChrome.edge)
    }

    /// Where the toggles sit, for the player's keep-out (three 40 pt buttons, `s` apart).
    static func frame(viewport: CGSize) -> CGRect {
        let w = 3 * 40 + 2 * DS.Space.s
        return CGRect(x: viewport.width - PageChrome.edge - w, y: PageChrome.belowGizmo, width: w, height: 40)
    }
}

/// The main page's squish player: bottom-centre, above the bottom bar, clear of the view
/// toggles and of the trailing legend slot (FlexibleLegendPlacement). Only when there is
/// something to squish.
public struct FlexibleMainPlayerSlot: View {
    @ObservedObject var main: FlexibleMainStage
    let bottomClearance: CGFloat

    public init(main: FlexibleMainStage, bottomClearance: CGFloat) {
        self.main = main
        self.bottomClearance = bottomClearance
    }

    /// The trailing legend slot the main page's legends take (batch C) — kept clear now.
    public static let legendSize = CGSize(width: 268, height: 168)

    public static func keepOut(viewport: CGSize) -> [CGRect] {
        var k = [FlexibleMainViewToggles.frame(viewport: viewport)]
        if let l = FlexibleLegendPlacement.legend(size: legendSize, viewport: viewport) { k.append(l) }
        return k
    }

    public var body: some View {
        GeometryReader { g in
            if main.playerShown,
               let r = FlexibleLegendPlacement.player(viewport: g.size, bottomClearance: bottomClearance,
                                                      keepOut: Self.keepOut(viewport: g.size)) {
                FlexibleSquishPlayer(loop: main.loop, fullLabel: main.fullLabel, width: r.width)
                    .latticeBandChipKeepOut()
                    .position(x: r.midX, y: r.midY)
            }
        }
    }
}

// FlexibleSettingsPanel — the Flexible Settings page's one panel, bottom-left (task
// 2026-09-29-flexible-screens, round 4 batch D1; his img 1).
//
// ★ AS TALL AS IT NEEDS TO BE ("The size of the modal should be as tall as it needs to be,
// there is too much empty space there"). Round 3's panel was a ScrollView in a max-height
// frame, and a ScrollView takes every point it is offered — 62 % of the screen for four rows.
// `FlexibleHugHeight` offers the scroll its content's own height and never more than the page
// offers: short content hugs, long content scrolls.
// ★ MINIMIZE ("Add the ability to minimize the Setting and Legend modals"): a chevron in the
// header folds the panel down to its header line (the selected face named in it); the same
// chevron opens it again. The legend's own minimize (the lattice legend's idiom: a narrow bar
// that keeps the scale) is `FlexibleLegendBar`.
// ★ TABS: Face | More (the Stamps tab went — a face's one stamp is its Shape).
// ★ ROUND 5 (S8, his img 3: "The groups should be separate folders … The folder tabs should be on
// the *left* side of the modal so enough groups can fit"): the Face | More chips became a RAIL of
// folder tabs down the panel's left side (FlexibleSettingsRail) — [Model], one per squeeze group,
// [Rests], [+] — with the open tab beside it. The panel is 480 pt wide: the rail takes 72 + 8, the
// tab keeps round 4's 372 pt (`contentWidth`), so every row measured at 372 still fits. ★ S5: [Reset all] in the header, with a one-line confirm.

import SwiftUI
import TopOptDesign
import TopOptKit

struct FlexibleSettingsPanel: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    @Binding var minimized: Bool

    static let width: CGFloat = 480
    /// The open tab's width beside the rail — round 4's 372 pt, so every one-line row still fits.
    static let contentWidth: CGFloat = width - 2 * DS.Space.ml - FlexibleSettingsRailView.width - DS.Space.s
    /// ★ S5: the header's Reset all asks once, in one line, before it resets.
    @State private var confirmingReset = false
    /// The selected card's height and the scroll's own, as laid out: when either changes (the
    /// stamp's rows, a design's warning line; the fix pop-up taking the top of the page) the card
    /// is brought back into view — a reveal made before them left it cut off.
    @State private var cardHeight: CGFloat = 0
    @State private var scrollHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if confirmingReset { resetConfirm } else { header }
            if !minimized {
                // ★ ROUND 5 (S8): the folder rail on the left, the open tab beside it
                ScrollViewReader { proxy in
                    FlexibleHugHeight {
                        HStack(alignment: .top, spacing: DS.Space.s) {
                        FlexibleSettingsRailView(model: model)
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: DS.Space.m) {
                                FlexibleRailContent(model: model, padTarget: $padTarget)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { scrollHeight = g.size.height }
                                .onChange(of: g.size.height) { scrollHeight = $0 }
                                // what the scroll SHOWS (the hosted test checks the card lies in it)
                                .preference(key: FlexibleKeepOutKey.self, value: ["panelScroll": g.frame(in: .global)])
                        }.allowsHitTesting(false))
                        .onPreferenceChange(FlexibleKeepOutKey.self) { v in cardHeight = v["faceCard"]?.height ?? 0 }
                        }
                    }
                    // ★ THE SELECTED FACE'S CARD SCROLLS INTO VIEW (verification of D1): on a list
                    // tap, a tap on the part, the fix pop-up's select, a switch back to Face, the
                    // card growing (Stamp's rows, a warning line), the panel shrinking under the
                    // pop-up — and as the page opens
                    .onChange(of: revealKey) { _ in reveal(proxy) }
                    .onAppear { reveal(proxy) }
                }
            }
        }
        .padding(DS.Space.ml)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    /// What moves or resizes the selected face's card.
    private var revealKey: String {
        let r = model.selectedRegion
        let f = r.flatMap { model.settings.face($0) }
        // ★ D2 REVIEW: a move to another squeeze group moves the card under that group's header
        let group = r.flatMap { model.squeezeGroup(of: $0)?.id } ?? 0
        return "\(r ?? -1)|\(model.tab.rawValue)|\(model.rail)|\(f?.role ?? "-")|\(f?.isStampShape ?? false)|\(minimized)|g\(group)"
            + "|\(Int(cardHeight / 4))|\(Int(scrollHeight / 4))"
    }

    /// Scroll the card fully into view: `.bottom` moves the list only as far as the card's last
    /// row needs (a card already on the panel stays put; the rows above it stay in sight).
    /// Asked IN the change (SwiftUI applies it on the layout that follows), and again whenever the
    /// card or the scroll changes height (`revealKey`: the stamp's rows, a design's warning, the
    /// fix pop-up taking the top of the page). ★ Not deferred: a scroll dispatched for later ran
    /// seconds late in the hosted test — after the next tap — and left the card below the fold.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard !minimized, model.tab == .face, let r = model.selectedRegion else { return }
        proxy.scrollTo(FlexibleFaceList.cardID(r), anchor: Self.revealAnchor)
    }
    static let revealAnchor = UnitPoint.bottom

    /// ★ HOW TALL THE PANEL MAY GROW (verification of D1): up to the page's top chrome over its
    /// column — the Exit row, the top line (and its toast), the fix pop-up while it is up — never
    /// less than round 3's 62 % of the page. At 62 % the selected face's card (446 pt with a stamp)
    /// did not fit the scroll on 11" landscape (517 pt for the whole panel). It still hugs its rows.
    static func maxHeight(viewport: CGSize, topChrome: [CGRect], edge: CGFloat = PageChrome.edge) -> CGFloat {
        let column = CGRect(x: edge, y: 0, width: width, height: viewport.height)
        let top = topChrome.filter { $0.minX < column.maxX && $0.maxX > column.minX }.map(\.maxY).max() ?? edge
        return max(viewport.height * 0.62, viewport.height - edge - top - DS.Space.m)
    }

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            Circle().fill(FlexibleStageStyle.accent).frame(width: 8, height: 8)
            Text("Flexible").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
            // folded: which face the page is on, so the header still says it
            if minimized, let r = model.selectedRegion {
                Text("· \(model.faceName(r))").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1)
            }
            Spacer()
            // ★ ROUND 5 (S5): "Reset all" — every input back to a brand-new setup (asked once; undoable)
            if !minimized {
                Button { confirmingReset = true } label: {
                    Text(FlexibleSettingsExit.resetButton)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(Capsule().fill(DS.Color.fillSubtle.color)
                            .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["resetAll": g.frame(in: .global)])
                }.allowsHitTesting(false))
                .accessibilityIdentifier("flexible-reset-all")
            }
            Button { withAnimation(.easeInOut(duration: 0.2)) { minimized.toggle() } } label: {
                Image(systemName: minimized ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.accent.color)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DS.Color.fillSubtle.color))
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(minimized ? "Show the settings" : "Minimise the settings")
            .accessibilityIdentifier("flexible-panel-minimize")
        }
    }
}

extension FlexibleSettingsPanel {
    /// ★ S5: the one-line confirm, in the header's place: "Reset every setting here? [Reset] [Cancel]".
    var resetConfirm: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.Color.warning.color)
            Text(FlexibleSettingsExit.resetAsk).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.85)
                .accessibilityIdentifier("flexible-reset-ask")
            Spacer(minLength: DS.Space.xs)
            Button { confirmingReset = false; model.resetAll() } label: {
                Text(FlexibleSettingsExit.resetConfirm).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(DS.Color.danger.color.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .background(GeometryReader { g in
                Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["resetConfirm": g.frame(in: .global)])
            }.allowsHitTesting(false))
            .accessibilityIdentifier("flexible-reset-confirm")
            Button { confirmingReset = false } label: {
                Text(FlexibleSettingsExit.resetCancel).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(DS.Color.fillSubtle.color))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flexible-reset-cancel")
        }
        .frame(minHeight: 36)
    }
}

/// ★ HUG, THEN SCROLL: offers its one child the content's own height (the child is asked with
/// no height, so a ScrollView answers with its content's), capped at what the parent offers.
/// Pure layout — FlexibleSettingsRound4Tests measures it against round 3's greedy scroll.
struct FlexibleHugHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let ideal = v.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The Settings legend MINIMIZED — the lattice legend's own idiom (LatticeLegendPanel's
/// `minimizedColumn`): the scale alone, a narrow bar, deepest at the top, with the reading's
/// arrow when there is one; a tap on it (the page's) brings the whole legend back.
struct FlexibleLegendBar: View {
    let fraction: Double?
    /// ★ VERIFICATION OF D1: 150 pt made the folded legend (≈ 180 pt with its caret) TALLER than
    /// the open one (98–124 pt) — minimising must make it smaller.
    static let barHeight: CGFloat = 64

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                ForEach((0..<24).reversed(), id: \.self) { i in
                    FlexibleColours.depthColour(fraction: Double(i) / 23).color.frame(width: 18)
                }
            }
            .frame(height: Self.barHeight)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if let f = fraction {
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.Color.accent.color)
                        .offset(x: 18, y: (1 - CGFloat(min(1, max(0, f)))) * Self.barHeight - 5)
                }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DS.Color.accent.color)
        }
        .padding(DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous)
            .fill(DS.Surface.panel.color.opacity(0.9))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
    }
}

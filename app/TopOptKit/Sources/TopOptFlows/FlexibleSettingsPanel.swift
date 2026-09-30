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

import SwiftUI
import TopOptDesign
import TopOptKit

struct FlexibleSettingsPanel: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    @Binding var minimized: Bool

    static let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            if !minimized {
                // ★ Face | More — one-line rows, details behind (i) or a caret
                FlexChips(options: FlexibleStageModel.Tab.allCases.map { ($0.rawValue, $0.rawValue) },
                          selection: model.tab.rawValue, id: "flexible-tab") {
                    model.tab = FlexibleStageModel.Tab(rawValue: $0) ?? .face
                }
                FlexibleHugHeight {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            switch model.tab {
                            case .face: FlexibleFacePanel(model: model, padTarget: $padTarget)
                            case .more: FlexibleMorePanel(model: model)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
    static let barHeight: CGFloat = 150

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

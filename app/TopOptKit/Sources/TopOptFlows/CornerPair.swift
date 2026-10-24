// CornerPair — A1's CORNER PAIR: a chip and a split button side by side in the bottom bar, and the ONE panel above them.
//
// Lifted from #362 (claude/flexible-screens) at b472880b, app/TopOptKit/Sources/TopOptFlows/FlexibleCornerPair.swift, as a
// neutral shared component (reviewer ruling 2026-10-24 07:30). #362 swaps its Flexible* copy for this one on its next sync of
// #354.
//
// Copied, not redesigned. What changed from the source, and only that:
//   * FlexibleCornerPair → CornerPair, FlexibleChromeGeometry → ChromeGeometry, FlexibleCornerPairStyle → CornerPairStyle,
//     FlexibleKeepOutKey → ChromeKeepOutKey (the same merge rule);
//   * the pair's three parts are parameters — `chip`, `split`, `panel` (the source built them from FlexibleMainStage: the
//     Setup chip + tray, the Lattice split button, the Lattice card and the blocker callout); the caller sizes its panel with
//     CornerPairStyle.panel(width:maxHeight:) (the source read FlexibleChromeLayout.panelWidth / panelMaxHeight and the main
//     stage's legend);
//   * ChromeGeometry.panelCard is the open panel's name (String) — the source's FlexibleChromeState.Card;
//   * the test control `controlPanelInLayout` lives on CornerPairStyle (a generic view cannot hold a static);
//   * not lifted (Flexible-only): FlexibleLatticeSplit, FlexibleLatticeCardMount, FlexibleCalloutMount, `gravityAction`
//     (FlexibleMainStage.gravitySetupStarts), `controlCapturedStatus` (the callout rule's red control), and the
//     `.said` / `.saidWhole` fit recorders (FlexibleSaid.swift) on the style's buttons;
//   * CornerPairStyle.big's filled colours are parameters (the source: FlexibleStageStyle.accent / .onAccent).
//
// The rules the source kept: the pair sits INSIDE the page's bottom bar, so the bar's own measure is the pair's; its panel is an
// OVERLAY of the pair, PageChrome.gap above it and right-aligned, never in layout — the bar's measured height never changes;
// one panel at a time is the caller's state.

import SwiftUI
import TopOptDesign

/// The frames a view publishes (global), for the keep-outs and the hosted tests. (Copied from FlexibleKeepOutKey.)
struct ChromeKeepOutKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The page's viewport, as its views row measures it (the pair sits inside the bar and cannot measure it).
@MainActor
public final class ChromeGeometry: ObservableObject {
    @Published public internal(set) var viewport: CGSize = .zero
    /// The open panel's drawn height and which panel it is (a player keeps clear of the panel's REAL frame).
    @Published public internal(set) var panelHeight: CGFloat = 0
    @Published public internal(set) var panelCard: String?
    public init() {}
    func note(_ v: CGSize) { if v != viewport, v.width > 0, v.height > 0 { viewport = v } }
    func notePanel(_ h: CGFloat, for card: String? = nil) {
        if abs(h - panelHeight) > 0.5 { panelHeight = h }
        if card != panelCard { panelCard = card }
    }
    /// The Selections list's frame (global) — a face chip keeps clear of it.
    @Published public internal(set) var selectionsFrame: CGRect?
    func noteSelections(_ r: CGRect?) {
        guard r != selectionsFrame else { return }
        DispatchQueue.main.async { [weak self] in if self?.selectionsFrame != r { self?.selectionsFrame = r } }
    }
}

public struct CornerPair<Chip: View, Split: View, Panel: View>: View {
    @ObservedObject private var geometry: ChromeGeometry
    /// The open panel's name (nil: none) — the measure is re-made for each panel.
    let open: String?
    let chip: Chip
    let split: Split
    let panel: Panel

    public init(geometry: ChromeGeometry, open: String?, @ViewBuilder chip: () -> Chip, @ViewBuilder split: () -> Split,
                @ViewBuilder panel: () -> Panel) {
        self._geometry = ObservedObject(wrappedValue: geometry)
        self.open = open; self.chip = chip(); self.split = split(); self.panel = panel()
    }

    public var body: some View {
        let pair = HStack(alignment: .bottom, spacing: CornerPairStyle.pairGap) {
            chip    // (the caller publishes its frame — the source's "setupChip")
            split   // (… and the source's "latticeSplit")
        }
        if CornerPairStyle.controlPanelInLayout {
            VStack(alignment: .trailing, spacing: CornerPairStyle.panelGap) { measuredPanel; pair }
        } else {
            pair.overlay(alignment: .bottomTrailing) {
                measuredPanel.offset(y: -(PageChrome.actionButton + CornerPairStyle.panelGap))
            }
        }
    }

    /// The panel measured (its drawn height, for a player's keep-out). (Which panel is read when the measure lands, and the
    /// reader is re-made for each panel, so a new panel measures at once.)
    @ViewBuilder private var measuredPanel: some View {
        let geometry = self.geometry, open = self.open
        panel.background(GeometryReader { g in
            Color.clear
                .onAppear { geometry.notePanel(g.size.height, for: open) }
                .onChange(of: g.size.height) { geometry.notePanel($0, for: open) }
        }.id(open).allowsHitTesting(false))
    }
}

/// The pair's shared looks (DS tokens only).
enum CornerPairStyle {
    /// Test control only: the panels placed IN layout (the bar would measure them — the defect the overlay avoids).
    @MainActor static var controlPanelInLayout = false
    static let pairGap: CGFloat = PageChrome.gap
    static let panelGap: CGFloat = PageChrome.gap

    /// A panel's glass: Surface.panel, radius 22, the panel hairline; its body scrolls past `maxHeight`.
    static func panel<C: View>(width: CGFloat, maxHeight: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: max(0, maxHeight - 2 * DS.Space.m))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DS.Space.ml).padding(.vertical, DS.Space.m)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .dsShadow(DS.Shadow.panel)
    }

    /// A 44 × 44 icon button (fold, back, dismiss).
    static func x44(_ icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary.color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// A small bordered button ("Change", "Show the fix"), 44 tall to the finger.
    static func small(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.m)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.fillSubtle.color)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// A fix button (the first one filled).
    static func big(_ title: String, primary: Bool, id: String, accent: Color = DS.Color.accent.color, onAccent: Color = .white,
                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primary ? onAccent : DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, DS.Space.l)
                .frame(minWidth: 44, minHeight: 44)
                .background(Capsule().fill(primary ? accent : DS.Color.chipSolid.color))
                .overlay(CornerPairStyle.secondaryEdge(primary))   // a secondary fix reads as a button
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// A secondary button wears the strong hairline (small's, the mockup's outlined buttons); the first, filled one needs none.
    static let secondaryEdgeWidth: CGFloat = 1
    @ViewBuilder static func secondaryEdge(_ primary: Bool) -> some View {
        if !primary { Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: secondaryEdgeWidth) }
    }

    /// The frame a view publishes for the hosted tests and the keep-outs (ChromeKeepOutKey, global).
    static func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: ChromeKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

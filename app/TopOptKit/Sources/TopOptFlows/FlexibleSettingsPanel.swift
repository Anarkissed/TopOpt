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
// tab keeps round 4's 372 pt (`contentWidth`), so every row measured at 372 still fits. ★ S5: [Reset all] in the header, with a one-line confirm
// (★ U21: in place — [Cancel] where [Reset all] was, [Reset] to its left).

import SwiftUI
import TopOptDesign
import TopOptKit

struct FlexibleSettingsPanel: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    @Binding var minimized: Bool
    /// ★ B9 (R6: "Foot: Cancel │ Save … Save matches the Lattice page"): the pinned foot's two ways off the page — the page's
    /// leave check (Save) and its revert (Cancel). nil (a panel hosted alone in a test): no foot.
    var foot: FlexibleSquishFoot.Actions? = nil

    /// ★ B9 (U14, design-system §6: "the wide panel (Lattice settings, Squish, Print plan) is 440 pt"): round 5's 480 pt panel
    /// is the shared wide panel now.
    static let width: CGFloat = PageChrome.widePanelWidth
    /// The open tab's inset from the tabs and the panel's edge (DSPanel's 14).
    static let inset: CGFloat = 14
    /// The open tab's width beside the rail.
    static let contentWidth: CGFloat = width - FlexibleSettingsRailView.width - 2 * inset

    /// ★ B9 LOOK (his "look per screen"; design-system §4.3, DSPanel's measures): the 48 pt header, a hairline, the folder tabs
    /// flush on the left beside the open tab (the tabs stay put, the tab scrolls — FlexibleRevealScroll keeps the selected face's
    /// card in view, which DSPanel's own scroll cannot), a hairline, the pinned foot. Folded, the panel is the header's pill.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !minimized {
                // ★ ROUND 5 (S8): the folder rail on the left, the open tab beside it
                FlexibleHugHeight {
                    HStack(alignment: .top, spacing: 0) {
                        FlexibleSettingsRailView(model: model)
                            .frame(maxHeight: .infinity, alignment: .top)
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            // ★ THE SELECTED FACE'S CARD SCROLLS INTO VIEW (verification of D1): on a list
                            // tap, a tap on the part, the fix pop-up's select, a switch back to Face, the
                            // card growing (Stamp's rows, a warning line), the panel shrinking under the
                            // pop-up — and as the page opens. ★ ROUND 7 · T3 RECODE: an explicit scroll
                            // position settled against the scroll's measured height (FlexibleRevealScroll);
                            // the ScrollViewReader ask never moved on 11" landscape "as opened".
                            FlexibleRevealScroll(revealKey: revealKey, enabled: revealEnabled,
                                                 legacyID: model.selectedRegion.map { AnyHashable(FlexibleFaceList.cardID($0)) }) {
                                VStack(alignment: .leading, spacing: DS.Space.m) {
                                    // ★ B9 (the mockup's #flex-squish): Auto │ Manual and Reset all at the top of the open tab, on
                                    // every tab — inside its scroll, as the mockup's (the pinned foot took room the selected
                                    // face's Stamp card needs at 11" landscape)
                                    topRow
                                    FlexibleRailContent(model: model, padTarget: $padTarget)
                                }
                                .padding(.horizontal, Self.inset).padding(.top, 10).padding(.bottom, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .background(GeometryReader { g in
                                // what the scroll SHOWS (the hosted test checks the card lies in it)
                                Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["panelScroll": g.frame(in: .global)])
                            }.allowsHitTesting(false))
                        }
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
                // ★ B9: the foot is pinned (U10: it never scrolls away)
                if let foot {
                    FlexibleSquishFoot(actions: foot)
                        .padding(.horizontal, Self.inset).padding(.top, 8).padding(.bottom, 12)
                        .overlay(alignment: .top) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
                }
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .background(Self.shape(minimized).fill(DS.Surface.panel.color))
        .overlay(Self.shape(minimized).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .clipShape(Self.shape(minimized))
        .dsShadow(DS.Shadow.panel)
    }

    /// DSPanel's outline: radius 22 open, the header's pill folded.
    static func shape(_ folded: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: folded ? DSParts.headerHeight / 2 : DSParts.panelRadius, style: .continuous)
    }

    /// What moves the selected face's card (its height and the scroll's own are watched by
    /// FlexibleRevealScroll itself).
    private var revealKey: String {
        let r = model.selectedRegion
        let f = r.flatMap { model.settings.face($0) }
        // ★ D2 REVIEW: a move to another squeeze group moves the card under that group's header
        let group = r.flatMap { model.squeezeGroup(of: $0)?.id } ?? 0
        return "\(r ?? -1)|\(model.tab.rawValue)|\(model.rail)|\(f?.role ?? "-")|\(f?.isStampShape ?? false)|\(minimized)|g\(group)"
    }

    /// The card is revealed on the Face tab with a face selected (`.bottom`-first: the list moves
    /// only as far as the card's last row needs; a card already on the panel stays put; a card
    /// taller than the scroll shows its top).
    private var revealEnabled: Bool { !minimized && model.tab == .face && model.selectedRegion != nil }

    /// ★ HOW TALL THE PANEL MAY GROW (verification of D1): up to the page's top chrome over its
    /// column — the Exit row, the top line (and its toast), the fix pop-up while it is up — never
    /// less than round 3's 62 % of the page. At 62 % the selected face's card (446 pt with a stamp)
    /// did not fit the scroll on 11" landscape (517 pt for the whole panel). It still hugs its rows.
    static func maxHeight(viewport: CGSize, topChrome: [CGRect], edge: CGFloat = PageChrome.edge) -> CGFloat {
        let column = CGRect(x: edge, y: 0, width: width, height: viewport.height)
        let top = topChrome.filter { $0.minX < column.maxX && $0.maxX > column.minX }.map(\.maxY).max() ?? edge
        return max(viewport.height * 0.62, viewport.height - edge - top - DS.Space.m)
    }

    /// ★ B9 (U2, design-system §4.3: "Header: chevron + name + count, nothing else"): the page's name alone — the stage row
    /// above it already says Flexible.
    static let title = "Squish"

    /// The header's count: "2 groups", "1 group".
    static func count(groups n: Int) -> String { n == 1 ? "1 group" : "\(n) groups" }

    /// ★ B9 (U2): chevron + "Squish" + its count, nothing else. A tap anywhere on it folds the panel to this one line (round
    /// 4's minimise) and opens it again. Auto │ Manual and Reset all moved to the top of the open tab (`topRow`).
    private var header: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { minimized.toggle() } } label: {
            // ★ B9 LOOK: DSPanel's header — chevron (turned while folded), the name, the count; 48 pt
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .rotationEffect(.degrees(minimized ? -90 : 0))
                    .frame(width: 18)
                Text(Self.title).font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer(minLength: 8)
                Text(Self.count(groups: model.squeezeGroups.count))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .padding(.horizontal, Self.inset)
            .frame(height: DSParts.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["panelHeader": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityLabel(minimized ? "Show the settings" : "Minimise the settings")
        .accessibilityIdentifier("flexible-panel-minimize")
        .flexibleProbe("flexible-panel-minimize")
    }

    /// ★ B9: the open tab's top line — ★ MANUAL (M1, his words of 2026-10-22: "at the very top of the Squish modal, it should
    /// have a toggle that says manual or auto") and ★ ROUND 5 (S5) "Reset all": every input back to a brand-new setup (asked
    /// once, in place; undoable). Reset all sits at the trailing end, so its ask (the question and [Reset] to the left of
    /// [Cancel]) lies over the hidden switch.
    private var topRow: some View {
        HStack(spacing: DS.Space.s) {
            FlexibleManualToggle(model: model)
                .opacity(model.resetAsk ? 0 : 1).allowsHitTesting(!model.resetAsk)
            Spacer(minLength: 0)
            Button { model.askResetAll() } label: {
                Text(FlexibleSettingsExit.resetButton)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                    .padding(.horizontal, 6).frame(height: 30)
                    .frame(minWidth: FlexibleTargets.least, minHeight: FlexibleTargets.least)   // ★ R: a 44 pt target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(FlexibleConfirmInPlace(asking: model.resetAsk, question: FlexibleSettingsExit.resetAsk,
                                             destructive: FlexibleSettingsExit.resetConfirm, keep: FlexibleSettingsExit.resetCancel,
                                             confirmKey: "resetConfirm", keepKey: "resetCancel", questionID: "flexible-reset-ask",
                                             confirm: { model.confirmResetAll() }, cancel: { model.keepAll() }))
            .background(GeometryReader { g in
                Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["resetAll": g.frame(in: .global)])
            }.allowsHitTesting(false))
            .accessibilityIdentifier("flexible-reset-all")
            .flexibleProbe("flexible-reset-all")
        }
    }
}

/// ★ B9 (R6: "Foot: Cancel │ Save. Today it is Exit │ Save & Exit; Save matches the Lattice page (R3.4), and Save rebuilds the
/// lattice"): the Squish panel's pinned foot. Save is the page's one leave check (today's Exit / Save & Exit: it saves what
/// changed and rebuilds, leaves as it was when nothing did, and opens the fix instead while a change is blocked — then the
/// fix chip beside it says so, U6). Cancel puts back what changed on this page and leaves; Redo brings it back.
struct FlexibleSquishFoot: View {
    struct Actions {
        let save: () -> Void
        let cancel: () -> Void
        /// "Fix 1 thing" while a change is blocked (Save opens the fix); nil when Save can leave.
        let fix: String?
    }
    let actions: Actions

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if let fix = actions.fix {
                Button(action: actions.save) {
                    Text(fix).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, DS.Space.sm).frame(height: 30)
                        .background(Capsule().fill(DS.Color.warning.opacity(0.14).color))
                        .frame(minHeight: FlexibleTargets.least).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-squish-fix")
                .flexibleProbe("flexible-squish-fix")
            }
            Spacer(minLength: 0)
            button(FlexibleSettingsExit.cancel, primary: false, key: "squishCancel", id: "flexible-squish-cancel", action: actions.cancel)
            button(FlexibleSettingsExit.save, primary: true, key: "squishSave", id: "flexible-exit", action: actions.save)
        }
        .padding(.top, DS.Space.xs)
    }

    /// One foot button (44 pt tall): Save in the accent (greyed while a change is blocked), Cancel quiet. Save keeps the old
    /// Exit button's id ("flexible-exit"): it is the same one way off the page.
    private func button(_ title: String, primary: Bool, key: String, id: String, action: @escaping () -> Void) -> some View {
        let blocked = primary && actions.fix != nil
        return Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.opacity(blocked ? 0.5 : 1).color)
                .padding(.horizontal, DS.Space.l).frame(minWidth: 84, minHeight: FlexibleTargets.least)
                .background(Capsule().fill(primary ? (blocked ? DS.Color.fillSubtle : DS.Color.accent).color
                                                   : DS.Color.fillSubtle.color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityIdentifier(id)
        .flexibleProbe(id)
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
            // ★ BATCH M2 (V12): the main page's ONE smooth ramp, deepest at the top — never 24 flat blocks
            FlexibleMainLegendRow.ramp(.dent, vertical: true)
            .frame(width: 18, height: Self.barHeight)
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

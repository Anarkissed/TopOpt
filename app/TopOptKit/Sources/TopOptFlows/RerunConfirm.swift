// RerunConfirm — B3 (design-system §1 U7: "every confirm is a ConfirmInPlace inside its panel's bounds"; OneWayToSayNoTests).
//
// Optimize over finished results asks first (BAR 4: a new run retires them). It asked with a system alert in the middle of the
// screen; now it asks in place, in a card over the run button's corner: the question, what goes, then its choices — Re-run
// here (danger), Save as new project (an Optimize re-run only), Cancel — each a 44 pt row. The choices are the caller's own
// Buttons (#362's H50b lines, unchanged); this view only lays them out.
// ★ #362's conditions (20:30Z — an alert blocked everything for free; a card does not): leaving the card without choosing is
// Cancel — a tap anywhere outside it, a change of stage, an Undo or any edit (`leaveToken` moves) — and while it is up the
// caller starts nothing else (WorkspacePlaceholder.requestRun / requestLatticeRun return at once).

import SwiftUI
import TopOptDesign

struct RerunConfirm<Token: Equatable, Choices: View>: View {
    let shown: Bool
    let message: String
    /// What leaving means: when it moves while the card is up, `onLeave` (Cancel) runs.
    let leaveToken: Token
    let onLeave: () -> Void
    /// How far above the page's bottom edge the card sits (the bottom bar's height and its margin).
    let bottom: CGFloat
    @ViewBuilder let choices: () -> Choices

    static var width: CGFloat { 400 }

    var body: some View {
        if shown {
            ZStack(alignment: .bottomTrailing) {
                // a tap anywhere outside the card is Cancel (it dims nothing). A plain Button, not a tap gesture: the button
                // takes every click, as the card's own choices do.
                Button(action: onLeave) { Color.black.opacity(0.001).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .ignoresSafeArea()
                    .background(CornerPairStyle.publish("rerunOutside"))
                    .accessibilityLabel("Cancel")
                card
            }
            .onChange(of: leaveToken) { _ in onLeave() }
        }
    }

    private var card: some View {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(RerunCard.title).dsStyle(DS.TypeScale.headline).foregroundStyle(DS.Color.textPrimary.color)
                Text(message).dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: DS.Space.xs) { choices() }
                    .buttonStyle(RerunChoiceStyle())
                    .padding(.top, DS.Space.xs)
            }
            .padding(DS.Space.l)
            .frame(width: Self.width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Surface.dialog.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.panel)
            .background(CornerPairStyle.publish("rerunConfirm"))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rerun-confirm")
            .padding(.trailing, PageChrome.edge)
            .padding(.bottom, bottom)
            .transition(.opacity)
    }
}

/// A choice row: the dangerous one in danger red (`danger`: the caller says so — a `.destructive` role does not take a click
/// on the Mac outside a system dialog), Cancel quiet, the rest plain — 44 pt each, full width.
struct RerunChoiceStyle: ButtonStyle {
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        let danger = danger || configuration.role == .destructive, cancel = configuration.role == .cancel
        configuration.label
            .font(.system(size: 15, weight: danger ? .bold : .semibold))
            .foregroundStyle((danger ? DS.Color.danger : cancel ? DS.Color.textSecondary : DS.Color.textPrimary).color)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, DS.Space.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill((danger ? DS.Color.danger.opacity(0.14) : DS.Color.fillSubtle).color))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .background(CornerPairStyle.publish("rerunChoice-\(danger ? "rerun" : cancel ? "cancel" : "copy")"))
    }
}

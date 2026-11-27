// ClearAllConfirm.swift — B2 (U13, design-system §4.29; his round 2 note J-5: "Include a 'Reset' button with a confirmation
// (where 'yes' is in a different place than 'Reset' is so the user has to move to select it)").
//
// For a clear-everything action only (Print plan › Reset); single deletes keep the inline confirm (§4.13). The button sits
// at one edge (bottom-left); its confirm opens at the TOP MIDDLE over a dim: the question, one line on what goes, then
// **Keep them** (left) and **Clear all** (right, danger). The finger has to travel to say yes. A tap on the dim keeps them.

import SwiftUI
import TopOptDesign

struct ClearAllConfirm: View {
    /// "Clear every print plan?"
    let question: String
    /// One line on what goes ("Its cuts, joints, add-ons and places go.").
    let detail: String
    var keepLabel = "Keep them"
    var clearLabel = "Clear all"
    let keep: () -> Void
    let clear: () -> Void

    static let width: CGFloat = 380

    var body: some View {
        ZStack(alignment: .top) {
            DS.Color.scrim.color.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: keep)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(question).dsStyle(DS.TypeScale.headline).foregroundStyle(DS.Color.textPrimary.color)
                Text(detail).dsStyle(DS.TypeScale.subhead).foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(action: keep) {
                        Text(keepLabel).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .padding(.horizontal, DS.Space.l).frame(minWidth: 44, minHeight: 44)
                            .background(Capsule().fill(DS.Color.fillSubtle.color))
                    }
                    .buttonStyle(.plain)
                    .background(CornerPairStyle.publish("clearAllKeep"))
                    .accessibilityIdentifier("clear-all-keep")
                    Spacer()
                    Button(action: clear) {
                        Text(clearLabel).font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DS.Color.danger.color)
                            .padding(.horizontal, DS.Space.l).frame(minWidth: 44, minHeight: 44)
                            .background(Capsule().fill(DS.Color.danger.opacity(0.14).color))
                    }
                    .buttonStyle(.plain)
                    .background(CornerPairStyle.publish("clearAllYes"))
                    .accessibilityIdentifier("clear-all-yes")
                }
                .padding(.top, DS.Space.xs)
            }
            .padding(DS.Space.l)
            .frame(width: Self.width)
            .background(RoundedRectangle(cornerRadius: DS.Radius.dialog, style: .continuous).fill(DS.Surface.dialog.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.dialog, style: .continuous)
                    .strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.sheet)
            .background(CornerPairStyle.publish("clearAllCard"))
            .padding(.top, PageChrome.panelTop)
        }
    }
}

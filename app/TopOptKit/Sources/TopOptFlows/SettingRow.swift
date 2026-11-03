// SettingRow.swift — B2 (round 1, R2.2; design-system §4.21 and §4.14, U8).
//
// The setting row: a bold 3–5 word label · its value in accent with ⌄ (a tap opens its menu) · its (i). "Safety margin  Light
// use · 150 % ⌄ (i)", "Start from  Solid · + Lattice faces ⌄ (i)". 44 pt tall (U3).
// The (i) (`InfoTip`): a 22 pt circle with a 13 pt "i" in textTertiary, a 44 pt target; its popover holds 1–3 sentences,
// 300 pt wide at most, the dialog surface, anchored to it, closed by a tap anywhere.

import SwiftUI
import TopOptDesign

/// The one (i).
struct InfoTip: View {
    /// Its published frame ("info-<key>") and accessibility id.
    let key: String
    let text: String
    var label = "About this"
    @State private var open = false

    static let circle: CGFloat = 22

    var body: some View {
        Button { open.toggle() } label: {
            Text("i")
                .font(.system(size: 13, weight: .bold, design: .serif))
                .foregroundStyle(DS.Color.textTertiary.color)
                .frame(width: Self.circle, height: Self.circle)
                .overlay(Circle().strokeBorder(DS.Color.textTertiary.color, lineWidth: 1.2))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DS.Color.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300 - 2 * DS.Space.l, alignment: .leading)
                .padding(DS.Space.l)
                .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous).fill(DS.Surface.dialog.color))
                .accessibilityIdentifier("info-\(key)-text")
        }
        .background(NumberPad.published("info-\(key)"))
        .accessibilityLabel(label)
        .accessibilityIdentifier("info-\(key)")
    }
}

/// One setting: label · value ⌄ (its menu) · (i).
struct SettingRow<MenuItems: View>: View {
    /// The value's published frame (`key`) and accessibility id (`id`).
    let key: String
    let id: String
    let label: String
    let value: String
    var info: String? = nil
    var infoLabel = "About this"
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(label).dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                .foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1)
            Menu { menu() } label: {
                HStack(spacing: 4) {
                    Text(value).dsStyle(DS.TypeScale.caption).fontWeight(.semibold).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(DS.Color.accent.color)
                .frame(minHeight: 44)   // the touch rule: a 44 pt target
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .background(NumberPad.published(key))
            .accessibilityIdentifier(id)
            if let info { InfoTip(key: key, text: info, label: infoLabel) }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }
}

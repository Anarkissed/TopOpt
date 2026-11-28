// SettingRow.swift — B2 (round 1, R2.2; design-system §4.21 and §4.14, U8).
//
// The setting row: a bold 3–5 word label · its value in accent with ⌄ (a tap opens its menu) · its (i). "Safety margin  Light
// use · 150 % ⌄ (i)", "Start from  Solid · + Lattice faces ⌄ (i)". 44 pt tall (U3).
// The (i) (`InfoTip`): ★ notes29 (his 11-25) the one (i), `AppInfoButton` — its glyph in a 44 pt target, its words in the
// centred notification (AppPopups.help: "Tap anywhere to continue"). It was a 22 pt circle opening a popover beside it.

import SwiftUI
import TopOptDesign

/// The (i) of a setting row and of the pages that use it: the one (i) (AppInfoButton), its frame published as "info-<key>".
struct InfoTip: View {
    /// Its published frame ("info-<key>") and accessibility id.
    let key: String
    let text: String
    var label = "About this"
    /// The notification's title (default: `label`).
    var title: String? = nil

    var body: some View {
        AppInfoButton(title: title ?? label, text: text, label: label, id: "info-\(key)")
            .background(NumberPad.published("info-\(key)"))
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
            .menuStyle(.button).buttonStyle(.plain)   // no platform chrome round the label: the row stays 44 (U3)
            .fixedSize()
            .background(NumberPad.published(key))
            .accessibilityIdentifier(id)
            if let info { InfoTip(key: key, text: info, label: infoLabel) }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .background(NumberPad.published("settingRow-\(key)"))
    }
}

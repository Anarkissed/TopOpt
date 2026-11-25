// DSNumberPad.swift — ★ HIS iPad NOTES 2026-11-22 (img 5, the Lattice settings panel with Apple's full keyboard over the lower
// half of the screen): "When I tap on a field to enter a number it covers the field/area I want to actually fill in. Why is
// the full alpha-numeric keyboard being used? It should just be the numeric."
//
// Apple has no small number pad on the iPad (its "number" keyboard is the full keyboard on its numbers page), so a number is
// typed on the APP's pad (NumberPad, design-system §4.33: 0-9, the point, ± only where the number can be negative, delete,
// Done; keys 50 pt), which opens BESIDE the number on the side with room (NumberPadField's popover, his 11-09 rule) and never
// over it. With a keyboard connected no pad opens: the number takes typing in place, Return keeps it (NumberPadField).
//
// `PadNumberBox` is the number box for the fields that still opened the system keyboard (a TextField: the Organic settings on
// the Lattice page, Skin thickness, the strength check's values). It looks like the box it replaces; a tap opens the pad;
// what is typed is a draft (shown in the box as it is typed); Done, or a tap anywhere else, hands the typed TEXT to the
// field's own commit — the code its Return ran — so a refusal, a snap, an empty entry and a bad one do what they did. Nothing
// typed (or the text it opened with) commits nothing.
import SwiftUI
import TopOptDesign

struct PadNumberBox: View {
    /// The accessibility id (the field's own, as before) and the published frame ("numberPadBox-<key>": a "numberPad" key,
    /// which the notification lane leaves out, as it did the text field).
    let key: String
    /// The setting's name: the pad's header.
    var title: String = ""
    /// What the box shows (nil or empty: `placeholder`, greyed).
    let shown: String?
    var placeholder: String = ""
    /// The text the pad opens with (nil: `shown`).
    var seedText: String? = nil
    /// The unit the pad shows after the number (nil: none).
    var unit: String? = nil
    var width: CGFloat = 64
    /// An Auto mode: the box shows Auto's number and takes no typing.
    var locked = false
    var allowsDecimal = true
    /// ± on the pad: only where the number can be negative.
    var allowsNegative = false
    var maxLength = NumberPadEntry.maxLength
    /// The field's own commit (its Return's code), with the typed text: once, as the pad closes, when the text changed.
    let commit: (String) -> Void

    @State private var open = false
    /// What has been typed since the pad opened (nil: nothing).
    @State private var draft: String?

    /// The strength check's values are typed as plain decimals (no exponent key): 0.00000000001 is 13 characters.
    static let longLimit = 16
    /// The box's height (the text field's), inside its 44 pt target.
    static let height: CGFloat = 32

    var body: some View {
        Button { draft = nil; open = true } label: {
            face
                .frame(width: width)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .numberPad(padBinding, config: config, seed: nil, onText: { draft = $0 })
        .background(NumberPad.published("numberPadBox-\(key)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(boxText.isEmpty ? placeholder : boxText)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(key)
    }

    /// The text the pad opens with.
    private var seed: String { seedText ?? shown ?? "" }

    private var config: NumberPad.Config {
        .init(title: title, unit: unit, allowsDecimal: allowsDecimal, allowsNegative: allowsNegative, clampsOnClose: false,
              seedText: seed, placeholder: placeholder.isEmpty ? nil : placeholder, maxLength: maxLength)
    }

    /// Closing the pad (Done, a tap elsewhere, Return on a keyboard) commits the draft BEFORE the page hears it closed.
    private var padBinding: Binding<Bool> {
        Binding(get: { open }, set: { v in
            if !v, open { close() }
            if v != open { open = v }
        })
    }

    private func close() {
        let typed = draft
        draft = nil
        if let text = Self.toCommit(typed: typed, seed: seed) { commit(text) }
    }

    /// What a close hands the field's commit: the typed text, or nil (nothing typed, or the text it opened with).
    static func toCommit(typed: String?, seed: String) -> String? {
        guard let typed, typed != seed else { return nil }
        return typed
    }

    /// The box's text: the draft while it is typed, else the value.
    private var boxText: String { (open ? draft : nil) ?? shown ?? "" }

    private var face: some View {
        let t = boxText
        return Text(t.isEmpty ? placeholder : t)
            .font(.system(size: 14, weight: .semibold)).monospacedDigit()
            .foregroundStyle((t.isEmpty ? DS.Color.textTertiary : DS.Color.textPrimary).color)
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Color.fillSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                    .strokeBorder((open ? DS.Color.accent : DS.Color.strokeStrong).color, lineWidth: open ? 1.5 : 1)))
            .opacity(locked ? 0.55 : 1)
    }

    /// A number as plain decimals, every digit kept (1e-9 is "0.000000001"): what the pad opens with where the box shows
    /// "10⁻⁹" (the strength check's values).
    static func plain(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumIntegerDigits = 1
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 15
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

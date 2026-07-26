// NumberPad.swift — the app-wide COMPACT numeric-entry pad (numeric-input handoff).
//
// The problem it fixes: EVERY numeric field in the app used to open the full system
// keyboard — a triple-tap to raise it, a caret stranded at the right of the field,
// and digits appended to whatever was already there. This replaces all of that with
// ONE shared control:
//   • a SINGLE tap on any numeric chip pops a small on-screen number pad anchored
//     beside that chip (a `.popover` — never the system keyboard, never a modal sheet);
//   • the FIRST keystroke REPLACES the whole value, so the user never positions a caret.
//
// It is split in two so the behaviour is verifiable HEADLESSLY (the /app/ rule): the
// keystroke state machine is `NumberPadEntry`, a pure value type (replace-on-first-key,
// decimal rules, backspace, parse) that the unit tests drive; `NumberPad` is the thin
// SwiftUI shell that renders the keys and is maintainer device QA. Callers attach it via
// the `.numberPad(...)` modifier and receive the live parsed value on every keystroke,
// so a value entered here flows through the SAME setter (and therefore the same
// `UndoHistory`) as a scrub — no parallel entry path.

import SwiftUI
import TopOptDesign

/// The pure keystroke state machine behind `NumberPad`. Seeded with the value the chip
/// currently shows; the first digit/decimal press REPLACES that seed (the caret-free
/// "typing replaces the whole value" contract), while backspace edits in place. No
/// SwiftUI, no clamping — the caller's existing setter owns range/units — so this is
/// unit-tested directly.
public struct NumberPadEntry: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case digit(Int)
        case dot
        case delete
    }

    /// Whether a decimal point is allowed (mm / weight) or not (counts, %, port).
    public let allowsDecimal: Bool
    /// The current text being built (may be empty, or a bare "0." mid-entry).
    public private(set) var text: String
    /// True once ANY key has been pressed since the pad opened. Gates the one-shot
    /// "first keystroke clears the seed" behaviour.
    public private(set) var touched: Bool

    /// Longest run of characters accepted, a sanity cap so a stuck finger can't build a
    /// pathological string (nine digits covers every field in the app).
    public static let maxLength = 9

    public init(seed: String, allowsDecimal: Bool) {
        self.allowsDecimal = allowsDecimal
        self.text = seed
        self.touched = false
    }

    /// Seed from the value the chip shows, formatted the way the chip formats it (so the
    /// pad opens showing exactly the same number).
    public init(seedValue: Double?, allowsDecimal: Bool) {
        self.init(seed: NumberPadEntry.seedString(seedValue, allowsDecimal: allowsDecimal),
                  allowsDecimal: allowsDecimal)
    }

    public mutating func press(_ key: Key) {
        switch key {
        case .digit(let d):
            if !touched { text = ""; touched = true }   // first keystroke clears the seed
            if text == "0" { text = "" }                // no leading zeros ("0"+"5" -> "5")
            guard text.count < Self.maxLength else { return }
            text += String(d)
        case .dot:
            guard allowsDecimal else { return }
            if !touched { text = ""; touched = true }
            if text.isEmpty { text = "0" }              // ".5" reads as "0.5"
            guard !text.contains(".") else { return }   // only one point
            guard text.count < Self.maxLength else { return }
            text += "."
        case .delete:
            touched = true
            if !text.isEmpty { text.removeLast() }
        }
    }

    /// The parsed value, or nil when the field is empty / not yet a number. A trailing
    /// "." ("2.") reads as the integer part so a mid-entry value never flickers to nil.
    public var value: Double? {
        if text.isEmpty || text == "." { return nil }
        let t = text.hasSuffix(".") ? String(text.dropLast()) : text
        return Double(t)
    }

    /// Format a seed value the way the chips do: `%g` (drops trailing zeros) rounded to
    /// 2 dp for decimal fields, a plain integer otherwise. nil / non-finite → empty.
    public static func seedString(_ v: Double?, allowsDecimal: Bool) -> String {
        guard let v, v.isFinite else { return "" }
        if allowsDecimal {
            return String(format: "%g", (v * 100).rounded() / 100)
        }
        return String(Int(v.rounded()))
    }
}

/// The compact on-screen number pad. Rendered inside a `.popover` anchored to the chip
/// that opened it (see `View.numberPad`). Emits the live parsed value on every keystroke
/// through `onValue`; the caller writes it through its normal setter, so the entry is
/// undoable and unit-safe by construction.
struct NumberPad: View {
    struct Config: Equatable {
        /// Short caption shown above the keys ("Margin", "Layer height", "Weight").
        var title: String = ""
        /// Trailing unit shown next to the live number ("mm", "%", "lbs"); nil = none.
        var unit: String? = nil
        /// Whether the decimal key is offered.
        var allowsDecimal: Bool = true
    }

    let config: Config
    /// The value shown when the pad opens (the chip's current value).
    let seed: Double?
    /// Live parsed value on every keystroke — nil when the field is momentarily empty.
    let onValue: (Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entry: NumberPadEntry
    @ScaledMetric(relativeTo: .title2) private var numberSize: CGFloat = 24

    init(config: Config, seed: Double?, onValue: @escaping (Double?) -> Void) {
        self.config = config
        self.seed = seed
        self.onValue = onValue
        _entry = State(initialValue: NumberPadEntry(seedValue: seed,
                                                    allowsDecimal: config.allowsDecimal))
    }

    var body: some View {
        VStack(spacing: DS.Space.m) {
            display
            keys
        }
        .padding(DS.Space.ml)
        .frame(width: 244)
        .foregroundStyle(DS.Color.textPrimary.color)
        .background(DS.Surface.dialog.color)
    }

    // MARK: live readout

    private var display: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            if !config.title.isEmpty {
                Text(config.title.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            Spacer(minLength: DS.Space.s)
            Text(entry.text.isEmpty ? "0" : entry.text)
                .font(.system(size: numberSize, weight: .heavy)).monospacedDigit()
                .tracking(-0.5)
                .foregroundStyle(entry.text.isEmpty ? DS.Color.textTertiary.color
                                                    : DS.Color.textPrimary.color)
            if let unit = config.unit {
                Text(unit).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
        }
        .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
            .fill(DS.Color.fillSubtle.color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(config.title)
        .accessibilityValue(entry.text.isEmpty ? "empty" : entry.text)
    }

    // MARK: keys

    private var keys: some View {
        VStack(spacing: DS.Space.s) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: DS.Space.s) {
                    ForEach(row, id: \.self) { key in keyButton(key) }
                }
            }
            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Capsule().fill(DS.Color.accent.color))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
        }
    }

    /// The 4×3 layout; the bottom-left slot is the decimal key (decimal fields) or a
    /// blank spacer (integer fields), so integer pads never offer a "." that can't parse.
    private static let rows: [[Cell]] = [
        [.digit(1), .digit(2), .digit(3)],
        [.digit(4), .digit(5), .digit(6)],
        [.digit(7), .digit(8), .digit(9)],
        [.dot, .digit(0), .delete],
    ]

    enum Cell: Hashable {
        case digit(Int)
        case dot
        case delete
    }

    @ViewBuilder private func keyButton(_ cell: Cell) -> some View {
        switch cell {
        case .digit(let d):
            padButton(String(d), a11y: String(d)) { press(.digit(d)) }
        case .dot:
            if config.allowsDecimal {
                padButton(".", a11y: "decimal point") { press(.dot) }
            } else {
                Color.clear.frame(maxWidth: .infinity).frame(height: 46)
            }
        case .delete:
            padButton(nil, glyph: "delete.left", a11y: "delete") { press(.delete) }
        }
    }

    private func padButton(_ text: String?, glyph: String? = nil, a11y: String,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let text {
                    Text(text).font(.system(size: 21, weight: .semibold)).monospacedDigit()
                } else if let glyph {
                    Image(systemName: glyph).font(.system(size: 18, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity).frame(height: 46)
            .foregroundStyle(DS.Color.textPrimary.color)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                .fill(DS.Color.fillSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                    .strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
    }

    private func press(_ key: NumberPadEntry.Key) {
        entry.press(key)
        onValue(entry.value)
    }
}

extension View {
    /// Attach the shared number pad, shown as a compact popover anchored to this view
    /// (the chip). Toggle `presented` from the chip's tap; the pad emits the live parsed
    /// value through `onValue` so the caller writes it via its normal setter.
    ///
    /// On iPad (regular width) `.popover` is already an anchored floating panel; the
    /// `presentationCompactAdaptation(.popover)` keeps it a popover on a compact width
    /// too, so it is NEVER a system keyboard or a full-height sheet.
    @ViewBuilder
    func numberPad(_ presented: Binding<Bool>, config: NumberPad.Config, seed: Double?,
                   onValue: @escaping (Double?) -> Void) -> some View {
        self.popover(isPresented: presented) {
            numberPadContent(config: config, seed: seed, onValue: onValue)
        }
    }

    @ViewBuilder
    private func numberPadContent(config: NumberPad.Config, seed: Double?,
                                  onValue: @escaping (Double?) -> Void) -> some View {
        let pad = NumberPad(config: config, seed: seed, onValue: onValue)
        if #available(iOS 16.4, macOS 13.3, *) {
            pad.presentationCompactAdaptation(.popover)
        } else {
            pad
        }
    }
}

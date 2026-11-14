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
        /// ★ FLIP THE SIGN (maintainer, 2026-08-18: "There is no 'negative' option in
        /// the numeric value selector for the expansion. Please add a button for
        /// that"). A TOGGLE, not a "minus" key: a leading "−" typed as a character
        /// would have to be parsed, rejected mid-entry and re-rejected on paste,
        /// whereas flipping a sign is the same operation whenever it is pressed —
        /// before the digits, after them, or twice.
        case negate
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

    /// ★ Whether the sign key is offered. Default FALSE, so every existing field —
    /// a depth, a weight, a port — is byte-identical and cannot be made negative by
    /// a control it never had.
    public var allowsNegative: Bool = false

    public init(seed: String, allowsDecimal: Bool, allowsNegative: Bool = false) {
        self.allowsDecimal = allowsDecimal
        self.allowsNegative = allowsNegative
        self.text = seed
        self.touched = false
    }

    /// Seed from the value the chip shows, formatted the way the chip formats it (so the
    /// pad opens showing exactly the same number).
    public init(seedValue: Double?, allowsDecimal: Bool, allowsNegative: Bool = false) {
        self.init(seed: NumberPadEntry.seedString(seedValue, allowsDecimal: allowsDecimal),
                  allowsDecimal: allowsDecimal, allowsNegative: allowsNegative)
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
        case .negate:
            guard allowsNegative else { return }
            touched = true
            // ★ AN EMPTY FIELD BECOMES "-", so the sign can be chosen BEFORE the
            // digits — which is how people type a negative number.
            if text.hasPrefix("-") { text.removeFirst() } else { text = "-" + text }
        }
    }

    /// The parsed value, or nil when the field is empty / not yet a number. A trailing
    /// "." ("2.") reads as the integer part so a mid-entry value never flickers to nil.
    public var value: Double? {
        if text.isEmpty || text == "." || text == "-" || text == "-." { return nil }
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

/// ★ B2 (U15, design-system §4.33): the range a number may take, as the pad's header says it ("1 to 40 mm", "150 % and up")
/// and as the toast says what was kept ("Kept 40 (1 to 40 mm)"). `upper` nil = no top ("Custom… (150 % and up)", app-map §7).
public struct NumberRange: Equatable, Sendable {
    public var lower: Double
    public var upper: Double?
    public init(_ lower: Double, _ upper: Double?) { self.lower = lower; self.upper = upper }
    public init(_ r: ClosedRange<Double>) { self.init(r.lowerBound, r.upperBound) }

    public func contains(_ v: Double) -> Bool { v >= lower - 1e-9 && (upper.map { v <= $0 + 1e-9 } ?? true) }
    /// The nearest allowed value.
    public func clamp(_ v: Double) -> Double { Swift.max(lower, upper.map { Swift.min($0, v) } ?? v) }

    /// "1 to 40 mm", "150 % and up" (the unit once, at the end).
    public func text(unit: String?) -> String {
        let u = unit.map { " \($0)" } ?? ""
        guard let upper else { return "\(Self.number(lower))\(u) and up" }
        return "\(Self.number(lower)) to \(Self.number(upper))\(u)"
    }
    /// The toast after an out-of-range number: the number kept, then the range — "Kept 40 (1 to 40 mm)", "Kept 150 % (150 %
    /// and up)" (the reviewer's wording, 11-03: a percent is said with its sign).
    public func keptNote(_ kept: Double, unit: String?) -> String {
        "Kept \(Self.number(kept))\(unit == "%" ? " %" : "") (\(text(unit: unit)))"
    }

    static func number(_ v: Double) -> String { String(format: "%g", (v * 100).rounded() / 100) }
}

/// The app's number pad (design-system §4.33): beside the number you tapped, 276 pt wide, radius 22, the dialog surface. Its
/// header names the setting and its range; keys 50 pt tall, 7 8 9 ⌫ · 4 5 6 ± · 1 2 3 . · 0 Done. ± only where the number
/// can be negative (dimmed elsewhere), the point only where it has decimals. The value shows selected, so the first key
/// replaces it; a caret blinks once you type. Emits the live parsed value on every keystroke through `onValue`; the caller
/// writes it through its normal setter, so the entry is undoable and unit-safe by construction. Done (or a tap anywhere
/// else) keeps it; out of its range the nearest allowed value is kept and the page says so (`NumberPadField`).
struct NumberPad: View {
    struct Config: Equatable {
        /// The setting's name, shown in the header ("Depth", "Safety margin", "Weight").
        var title: String = ""
        /// Trailing unit shown next to the live number ("mm", "%", "lbs"); nil = none.
        var unit: String? = nil
        /// Whether the decimal key is offered.
        var allowsDecimal: Bool = true
        /// ★ Whether the SIGN key is offered. Default false — only a field whose
        /// value is genuinely signed asks for it (today: the in-plane expand, which
        /// shrinks below zero).
        var allowsNegative: Bool = false
        /// ★ APP LIST 2 (B4): an SF Symbol drawn BEFORE the title — the Expand keypad's "+", matching its box and its
        /// handle. nil = the title alone (every keypad before B4).
        var titleSymbol: String? = nil
        /// ★ B2 (U15): the range, for the header and for what a close keeps. nil = the caller's own clamp (no header range).
        var range: NumberRange? = nil
        /// The pad keeps the nearest allowed value on close (and says so). False: the number does it itself (NumberField,
        /// which commits once, on close).
        var clampsOnClose = true

        /// "Depth · 1 to 40 mm" (the name alone without a range, the range alone without a name).
        var header: String {
            let r = range?.text(unit: unit)
            switch (title.isEmpty, r) {
            case (false, let r?): return "\(title) · \(r)"
            case (true, let r?): return r
            default: return title
            }
        }
    }

    let config: Config
    /// The value shown when the pad opens (the chip's current value).
    let seed: Double?
    /// Live parsed value on every keystroke — nil when the field is momentarily empty.
    let onValue: (Double?) -> Void
    /// Done. nil = dismiss the presentation it sits in (the popover a field without a host falls back to).
    var onDone: (() -> Void)? = nil

    /// §4.33's measures.
    static let width: CGFloat = 276
    static let keyHeight: CGFloat = 50
    static let gap: CGFloat = DS.Space.s
    static let inset: CGFloat = DS.Space.m
    static let headerHeight: CGFloat = 16
    static let displayHeight: CGFloat = 44
    static var height: CGFloat { inset * 2 + headerHeight + gap + displayHeight + gap + keyHeight * 4 + gap * 3 }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entry: NumberPadEntry
    @State private var caretOn = true
    @ScaledMetric(relativeTo: .title2) private var numberSize: CGFloat = 24

    init(config: Config, seed: Double?, onValue: @escaping (Double?) -> Void, onDone: (() -> Void)? = nil) {
        self.config = config
        self.seed = seed
        self.onValue = onValue
        self.onDone = onDone
        _entry = State(initialValue: NumberPadEntry(seedValue: seed,
                                                    allowsDecimal: config.allowsDecimal,
                                                    allowsNegative: config.allowsNegative))
    }

    var body: some View {
        VStack(spacing: Self.gap) {
            header
            display
            keys
        }
        .padding(Self.inset)
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(DS.Color.textPrimary.color)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Surface.dialog.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1)))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .background(Self.probed("numberPad"))
        .onDisappear { NumberPadProbe.frames = [:] }
        .accessibilityIdentifier("numberPad")
    }

    // MARK: header + live readout

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            if let sym = config.titleSymbol {
                Image(systemName: sym).font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .accessibilityHidden(true)
            }
            Text(config.header)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityIdentifier("numberPad-header")
            Spacer(minLength: 0)
        }
        .frame(height: Self.headerHeight)
    }

    private var display: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Spacer(minLength: DS.Space.s)
            HStack(spacing: 1) {
                Text(entry.text.isEmpty ? "0" : entry.text)
                    .font(.system(size: numberSize, weight: .heavy)).monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(entry.text.isEmpty ? DS.Color.textTertiary.color : DS.Color.textPrimary.color)
                    .padding(.horizontal, entry.touched ? 0 : 3)
                    // ★ §4.33: the value shows SELECTED until the first key (which replaces it)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(entry.touched ? Color.clear : DS.Color.accent.opacity(0.45).color))
                if entry.touched {
                    // … then a caret (steady with reduced motion)
                    Rectangle().fill(DS.Color.accent.color).frame(width: 2, height: numberSize)
                        .opacity(reduceMotion || caretOn ? 1 : 0)
                }
            }
            if let unit = config.unit {
                Text(unit).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(maxWidth: .infinity, minHeight: Self.displayHeight, maxHeight: Self.displayHeight, alignment: .trailing)
        .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
            .fill(DS.Color.fillSubtle.color))
        .task(id: entry.touched) {
            guard entry.touched, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 530_000_000)
                caretOn.toggle()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(config.title)
        .accessibilityValue(entry.text.isEmpty ? "empty" : entry.text)
        .accessibilityIdentifier("numberPad-value")
    }

    // MARK: keys

    /// §4.33's grid: 7 8 9 ⌫ · 4 5 6 ± · 1 2 3 . · 0 (wide) Done (wide, accent).
    private var keys: some View {
        VStack(spacing: Self.gap) {
            HStack(spacing: Self.gap) { key(.digit(7)); key(.digit(8)); key(.digit(9)); key(.delete) }
            HStack(spacing: Self.gap) { key(.digit(4)); key(.digit(5)); key(.digit(6)); key(.negate) }
            HStack(spacing: Self.gap) { key(.digit(1)); key(.digit(2)); key(.digit(3)); key(.dot) }
            HStack(spacing: Self.gap) {
                key(.digit(0))
                Button { (onDone ?? { dismiss() })() } label: {
                    Text("Done")
                        .font(.system(size: 17, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: Self.keyHeight)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(DS.Color.accent.color))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Self.probed("numberPad-done"))
                .accessibilityLabel("Done")
                .accessibilityIdentifier("numberPad-done")
            }
        }
    }

    /// One key; a key the number can't use (± on a positive number, the point on a count) is dimmed and does nothing.
    private func key(_ k: NumberPadEntry.Key) -> some View {
        let (label, glyph, a11y, id, enabled): (String?, String?, String, String, Bool) = {
            switch k {
            case .digit(let d): return (String(d), nil, String(d), "\(d)", true)
            case .dot: return (".", nil, "decimal point", "dot", config.allowsDecimal)
            case .delete: return (nil, "delete.left", "delete", "delete", true)
            case .negate: return (nil, "plus.forwardslash.minus", "positive or negative", "sign", config.allowsNegative)
            }
        }()
        return Button { press(k) } label: {
            Group {
                if let label {
                    Text(label).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                } else if let glyph {
                    Image(systemName: glyph).font(.system(size: 19, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity).frame(height: Self.keyHeight)
            .foregroundStyle((enabled ? DS.Color.textPrimary : DS.Color.textDisabled).color)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill((enabled ? DS.Color.fillSubtle : DS.Color.fillDisabled).color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .background(Self.probed("numberPad-key-\(id)"))
        .accessibilityLabel(a11y)
        .accessibilityIdentifier("numberPad-key-\(id)")
    }

    private func press(_ key: NumberPadEntry.Key) {
        entry.press(key)
        caretOn = true
        onValue(entry.value)
    }

    /// A key's frame in the pad's own window (the popover's), for the hosted tests to click.
    static func probed(_ name: String) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { NumberPadProbe.frames[name] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { NumberPadProbe.frames[name] = $0 }
        }.allowsHitTesting(false)
    }

    /// A frame reaches the page (the hosted tests click it).
    static func published(_ name: String) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: ChromeKeepOutKey.self, value: [name: g.frame(in: .global)])
        }.allowsHitTesting(false)
    }
}

extension View {
    /// Attach the shared number pad to this view (the number). Toggle `presented` from the number's tap; the pad emits the
    /// live parsed value through `onValue` so the caller writes it via its normal setter.
    ///
    /// ★ B2 (U15): the pad opens in a popover beside the number (below it, above when there is no room; never the system
    /// keyboard, never a full-height sheet); out of range a close keeps the nearest allowed value and says so; with a
    /// hardware keyboard connected no pad opens and the number takes typing in place (`NumberPadField`).
    func numberPad(_ presented: Binding<Bool>, config: NumberPad.Config, seed: Double?,
                   onValue: @escaping (Double?) -> Void) -> some View {
        modifier(NumberPadField(presented: presented, config: config, seed: seed, onValue: onValue))
    }
}

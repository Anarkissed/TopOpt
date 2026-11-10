// PatternBar.swift — B8 (row 37; N1, P5; mockup #cut-pattern, #cut-pattern-type, #cut-pattern-zero, #cut-pattern-none): the
// Pattern tool's bar, beside the face on the part.
//
//   On a hole:      ✕ │ − n around + │ − n down the hole + │ ✓                     (mockup .tbar)
//   On any other:   ✕ │ − n along + │ − n across + │ Rotate ↺ n° ↻ │ ✓              (the reviewer's 11-09 18:31Z ruling (b):
//                   a flat face's grid starts square to its longest straight edge and turns in 15° steps, typed, as the
//                   flat Cut does; anything else keeps his 08-16 arc grid with this same bar, and no plane question)
//   • Each count is the app's NumberField (tap to type, drag to step, §4.28) with its − and + (N1: every + has a −).
//   • Every count is CUT LINES, as on a hole (P5): either goes down to 0 (no cuts that way). With nothing to cut the bar says
//     so and ✓ waits.
//   • A pattern the run cannot hold (a piece under the sliver floor) says how many pieces fit, and ✓ waits.

import SwiftUI
import TopOptDesign

public enum PatternBarCopy {
    public static let around = "around"
    public static let downTheHole = "down the hole"
    /// ★ 11-09 ruling (b): a flat face's (and any other's) counts — cut lines along its longest edge, and across it.
    public static let along = "along"
    public static let across = "across"
    public static let rotate = CutBarCopy.rotate
    /// The refused line (≤ 5 words, design-system §4.10): how many pieces the face can hold at the run's own size.
    public static func fits(_ n: Int) -> String { n >= 2 ? "Fits \(n) pieces at most" : "Too small to split" }
}

/// ★ 11-09 ruling (b): the grid's bar counts CUT LINES (as a hole's does); the grid itself is built from pieces.
public enum PatternGrid {
    /// Up to 12 pieces each way (today's stepper's limit): 0–11 lines.
    public static let linesRange = 0...11
    /// Today's first grid (3 columns × 1 row): 2 lines along, none across.
    public static let defaultAlong = 2
    public static let defaultAcross = 0
    /// n lines make n + 1 pieces that way.
    public static func pieces(lines: Int) -> Int { Swift.max(0, lines) + 1 }
    public static func lines(pieces: Int) -> Int { Swift.max(0, pieces - 1) }
    /// Rotate's number, 0..<360 (the Cut bar's own wrap): ↺ from 0 is 345°.
    public static func rotation(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        let a = r < 0 ? r + 360 : r
        return a >= 360 || a == 0 ? 0 : a
    }
}

/// ✕ │ − n {around|along} + │ − n {down the hole|across} + │ [Rotate ↺ n° ↻ │] [its line] │ ✓
struct PatternBar: View {
    struct Count {
        let word: String
        let key: String
        let value: Int
        let range: ClosedRange<Int>
        let set: (Int) -> Void
    }

    let counts: [Count]
    /// The grid's turn (nil on a hole: its lines hang on its own axis).
    let rotate: (value: Double, set: (Double) -> Void)?
    /// nil: ✓ splits it. Otherwise the line the bar shows, and ✓ waits.
    let refusal: String?
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            round("xmark", "Cancel", key: "patternBarCancel", accent: false, action: cancel)
            ForEach(Array(counts.enumerated()), id: \.offset) { k, c in
                if k > 0 { divider }
                count(c)
            }
            if let rotate {
                divider
                stepper(PatternBarCopy.rotate, key: "patternRotate", value: rotate.value, set: rotate.set)
            }
            if let refusal {
                Text(refusal).font(.system(size: 12)).foregroundStyle(DS.Color.warning.color)
                    .padding(.horizontal, 6).fixedSize()
                    .background(DSParts.publish("patternBarLine"))
            }
            round("checkmark", "Split", key: refusal == nil ? "patternBarOK" : "patternBarOK-off", accent: refusal == nil,
                  action: confirm)
                .disabled(refusal != nil)
        }
        .padding(5)
        .background(Capsule().fill(DS.Color.chipSolid.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .fixedSize()
        .background(DSParts.publish("patternBar"))
    }

    private var divider: some View { Rectangle().fill(DS.Color.strokeStrong.color).frame(width: 1, height: 24) }

    /// − · its number (tap to type) · its word · + (mockup: "− 6 around +").
    private func count(_ c: Count) -> some View {
        let clamp: (Double) -> Void = { c.set(Swift.min(c.range.upperBound, Swift.max(c.range.lowerBound, Int($0.rounded())))) }
        return HStack(spacing: 4) {
            round("minus", "Fewer \(c.word)", key: "\(c.key)Minus", accent: false) { clamp(Double(c.value - 1)) }
            NumberField(key: c.key, title: c.word,
                        spec: FlexNumberSpec(value: Double(c.value), unit: "", step: 1,
                                             range: Double(c.range.lowerBound)...Double(c.range.upperBound), decimals: 0),
                        size: .bare, onCommit: clamp)
            Text(c.word).font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color).padding(.trailing, 2).fixedSize()
            round("plus", "More \(c.word)", key: "\(c.key)Plus", accent: false) { clamp(Double(c.value + 1)) }
        }
    }

    /// Rotate: its word, ↺ 15° · its number (tap to type) · ↻ 15° — the Cut bar's own (CutBar.stepper).
    private func stepper(_ t: String, key: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(t).font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color).padding(.horizontal, 6).fixedSize()
            round("arrow.counterclockwise", "\(t) \u{2212}15\u{00B0}", key: "\(key)Minus", accent: false) { set(value - 15) }
            NumberField(key: key, title: t,
                        spec: FlexNumberSpec(value: value, unit: "\u{00B0}", step: 1, range: 0...360, decimals: 0, wraps: true),
                        size: .bare, onCommit: set)
            round("arrow.clockwise", "\(t) +15\u{00B0}", key: "\(key)Plus", accent: false) { set(value + 15) }
        }
    }

    /// A 42 pt round button (mockup .tbar .c; ✓ is the accent, and greys while it waits).
    private func round(_ icon: String, _ label: String, key: String, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold))
                .foregroundStyle(accent ? Color.white : DS.Color.textPrimary.color)
                .frame(width: 42, height: 42)
                .background(Circle().fill((accent ? DS.Color.accent : DS.Color.fillSubtle).color))
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(key))
        .accessibilityLabel(label)
    }
}

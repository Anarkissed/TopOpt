// PatternBar.swift — B8 (row 37; N1, P5; mockup #cut-pattern, #cut-pattern-type, #cut-pattern-zero, #cut-pattern-none): the
// Pattern tool's bar on a hole, beside the hole on the part.
//
//   ✕ │ − n around + │ − n down the hole + │ ✓   (mockup .tbar)
//   • Each count is the app's NumberField (tap to type, drag to step, §4.28) with its − and + (N1: every + has a −).
//   • Either count goes down to 0 (P5: no cuts that way). With nothing to cut the bar says so and ✓ waits.
//   • A pattern the run cannot hold (a piece under the sliver floor) says how many pieces fit, and ✓ waits.

import SwiftUI
import TopOptDesign

public enum PatternBarCopy {
    public static let around = "around"
    public static let downTheHole = "down the hole"
    /// The refused line (≤ 5 words, design-system §4.10): how many pieces the hole can hold at the run's own size.
    public static func fits(_ n: Int) -> String { n >= 2 ? "Fits \(n) pieces at most" : "Too small to split" }
}

/// ✕ │ − n around + │ − n down the hole + │ [its line] │ ✓
struct PatternHoleBar: View {
    let around: Int
    let down: Int
    /// nil: ✓ splits it. Otherwise the line the bar shows, and ✓ waits.
    let refusal: String?
    let set: (_ around: Int, _ down: Int) -> Void
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            round("xmark", "Cancel", key: "patternBarCancel", accent: false, action: cancel)
            count(PatternBarCopy.around, key: "patternAround", value: around, range: PatternHole.aroundRange) { set($0, down) }
            divider
            count(PatternBarCopy.downTheHole, key: "patternDown", value: down, range: PatternHole.downRange) { set(around, $0) }
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
    private func count(_ word: String, key: String, value: Int, range: ClosedRange<Int>,
                       set: @escaping (Int) -> Void) -> some View {
        let clamp: (Double) -> Void = { set(Swift.min(range.upperBound, Swift.max(range.lowerBound, Int($0.rounded())))) }
        return HStack(spacing: 4) {
            round("minus", "Fewer \(word)", key: "\(key)Minus", accent: false) { clamp(Double(value - 1)) }
            NumberField(key: key, title: word,
                        spec: FlexNumberSpec(value: Double(value), unit: "", step: 1,
                                             range: Double(range.lowerBound)...Double(range.upperBound), decimals: 0),
                        size: .bare, onCommit: clamp)
            Text(word).font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color).padding(.trailing, 2).fixedSize()
            round("plus", "More \(word)", key: "\(key)Plus", accent: false) { clamp(Double(value + 1)) }
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

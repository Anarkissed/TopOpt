// FlexibleNumberBox — the ONE number input of the Flexible Settings page (task
// 2026-09-29-flexible-screens, round 5 batch S3; his img 2: "All number inputs should show a
// textbox with a number to show it is editable; and always with a numerical input OR draggable
// up/down for ease of use.").
//
// ★ WHAT HE SEES. A small field — the number and its unit in a rounded box with a hairline, the
// look of a text field — never a bare pencil. Its two ways in:
//   * a TAP opens the app's numeric keypad (NumberPad, the `.numberPad` popover — the project rule:
//     every numeric input opens a numeric keypad). The value is committed ONCE, as the pad closes
//     (a live commit wrote "12" as 1 then 12 — FlexPadBuffer's lesson);
//   * a VERTICAL DRAG scrubs it: up = more, down = less, slow = fine, fast = coarse (the scrub
//     pill's idea — GlassValuePill / ClearanceScrub — turned upright), snapped to the field's step,
//     clamped to its range. The box shows the value as it moves; it is committed ONCE, on release
//     (one undo step, and a weight written back to the main page once, not per point).
// A weight box also switches its unit (kg / lb / N / kN — FlexibleWeightUnit) from a menu on the
// unit itself; the number never moves when the unit does (storage is kgf).
// ★ PURE PARTS (FlexibleNumberBoxTests): the spec's clamp / wrap / snap / format, the scrub, the
// keypad's commit. The SwiftUI shell only accumulates drags and shows the text.

import SwiftUI
import TopOptDesign

/// One number field's rules, in the unit it SHOWS.
public struct FlexNumberSpec: Equatable, Sendable {
    public var value: Double
    public var unit: String
    /// One scrub step (and the grid a scrubbed value snaps to).
    public var step: Double
    public var range: ClosedRange<Double>
    /// Decimals shown (trailing zeros dropped).
    public var decimals: Int
    /// An angle: values wrap round the range instead of stopping at its ends.
    public var wraps = false

    public init(value: Double, unit: String, step: Double, range: ClosedRange<Double>, decimals: Int, wraps: Bool = false) {
        self.value = value; self.unit = unit; self.step = step; self.range = range; self.decimals = decimals; self.wraps = wraps
    }

    /// Inside the range: clamped, or — an angle — wrapped (0 … 360 ⇒ 350 + 20 = 10).
    public func clamped(_ v: Double) -> Double {
        guard v.isFinite else { return value }
        if wraps {
            let span = range.upperBound - range.lowerBound
            guard span > 0 else { return range.lowerBound }
            var x = (v - range.lowerBound).truncatingRemainder(dividingBy: span)
            if x < 0 { x += span }
            return range.lowerBound + x
        }
        return min(range.upperBound, max(range.lowerBound, v))
    }

    /// On the step grid (whole multiples of the step: 0.5 mm, 15°, 1 lb), then inside the range.
    public func snapped(_ v: Double) -> Double {
        guard step > 0 else { return clamped(v) }
        return clamped((v / step).rounded() * step)
    }

    /// The number as the box shows it ("3", "2.5", "0.098").
    public var text: String { Self.format(value, decimals: decimals) }
    public static func format(_ v: Double, decimals: Int) -> String { FlexibleWeightUnit.number(v, decimals: decimals) }

    /// What a value typed on the keypad commits: nil below the range's start (a "0 kg" means
    /// nothing — the old value stays), else clamped (a 50 mm deepest squish stops at the lattice).
    public func typed(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        if !wraps, v < range.lowerBound - 1e-12 { return nil }
        return clamped(v)
    }
}

/// ★ THE UPRIGHT SCRUB: how far one drag update moves the value.
public enum FlexNumberScrub {
    /// Points of finger travel per step when the finger is slow (fine) …
    public static let slowPointsPerStep = 10.0
    /// … and when it is fast (coarse).
    public static let fastPointsPerStep = 2.0
    /// |dy| per update at which the gain is fully coarse.
    public static let fastSpeedPoints = 14.0

    /// The value change for one update of `deltaY` points (screen y grows DOWN, so an upward
    /// finger — a negative dy — adds).
    public static func increment(deltaY dy: Double, step: Double) -> Double {
        let t = min(1, abs(dy) / fastSpeedPoints)
        let pointsPerStep = slowPointsPerStep + (fastPointsPerStep - slowPointsPerStep) * t
        return -dy / pointsPerStep * step
    }

    /// One update: the raw (unsnapped) value accumulates, clamped so a reversal answers at once;
    /// what the box shows is it snapped to the step.
    public static func scrub(raw: Double, deltaY: Double, spec: FlexNumberSpec) -> (raw: Double, shown: Double) {
        let next = spec.wraps ? raw + increment(deltaY: deltaY, step: spec.step)
                              : spec.clamped(raw + increment(deltaY: deltaY, step: spec.step))
        return (next, spec.snapped(next))
    }
}

/// What the keypad typed, held until it CLOSES (then the spec decides what commits).
public struct FlexNumberPadBuffer: Equatable, Sendable {
    public private(set) var pending: Double?
    public init() {}
    public mutating func typed(_ v: Double?) { pending = v }
    public mutating func closed(_ spec: FlexNumberSpec) -> Double? {
        defer { pending = nil }
        return spec.typed(pending)
    }
}

/// The box. `padTarget` is the page's one keypad slot (one pad open at a time).
struct FlexNumberBox: View {
    /// The keypad slot and the accessibility id ("flexible-number-<key>").
    let key: String
    /// The keypad's caption.
    let title: String
    let spec: FlexNumberSpec
    @Binding var padTarget: String?
    /// A weight box: the units it can switch to, and the switch.
    var units: [FlexibleWeightUnit] = []
    var onUnit: (FlexibleWeightUnit) -> Void = { _ in }
    /// Commit (the unit it shows): once per keypad close, once per drag release.
    let onCommit: (Double) -> Void

    @State private var scrub: (raw: Double, shown: Double)?
    @State private var lastY: CGFloat = 0
    @State private var buffer = FlexNumberPadBuffer()
    /// A drag must travel this far before it scrubs (below it the touch is a tap).
    static let tapSlop: CGFloat = 3
    static let height: CGFloat = 32

    var body: some View {
        let shown = scrub.map { FlexNumberSpec.format($0.shown, decimals: spec.decimals) } ?? spec.text
        HStack(spacing: 4) {
            // the number (and the up / down hint): a TAP opens the keypad, a vertical DRAG scrubs
            Button { padTarget = key } label: {
                HStack(spacing: 4) {
                    Text(shown)
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1).fixedSize()
                        .frame(minWidth: 26, alignment: .trailing)
                        .accessibilityIdentifier("flexible-number-\(key)-value")
                    if units.count <= 1 { unitView }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .frame(height: Self.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // the drag wins over the tap once the finger travels (a scrub never opens the keypad)
            .highPriorityGesture(drag)
            // a weight: its unit is its own menu (kg / lb / N / kN), apart from the number
            if units.count > 1 {
                Rectangle().fill(DS.Color.strokeStrong.color).frame(width: 1, height: 18)
                unitView
            }
        }
        .padding(.horizontal, 9)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Color.fillSubtle.color)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder((padTarget == key || scrub != nil ? DS.Color.accent : DS.Color.strokeStrong).color,
                              lineWidth: padTarget == key || scrub != nil ? 1.5 : 1)))
        .fixedSize()
        // its frame reaches the page (the hosted tests click it)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self,
                                   value: ["numberBox-\(key)": g.frame(in: .global)]
                                       .merging(padTarget == key ? ["numberBoxKeypad-\(key)": g.frame(in: .global)] : [:]) { $1 })
        }.allowsHitTesting(false))
        .numberPad(Binding(get: { padTarget == key }, set: { if !$0, padTarget == key { padTarget = nil } }),
                   config: .init(title: title, unit: spec.unit, allowsDecimal: true), seed: spec.value) { buffer.typed($0) }
        .onChange(of: padTarget == key) { open in
            if !open, let v = buffer.closed(spec), abs(v - spec.value) > 1e-12 { onCommit(v) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue("\(shown) \(spec.unit)")
        .accessibilityAdjustableAction { dir in
            let v = spec.snapped(spec.value + (dir == .increment ? spec.step : -spec.step))
            if v != spec.value { onCommit(v) }
        }
        .accessibilityIdentifier("flexible-number-\(key)")
    }

    @ViewBuilder private var unitView: some View {
        if units.count > 1 {
            Menu {
                ForEach(units) { u in
                    Button { onUnit(u) } label: {
                        if u.label == spec.unit { Label(u.label, systemImage: "checkmark") } else { Text(u.label) }
                    }
                    .accessibilityIdentifier("flexible-unit-\(u.rawValue)")
                }
            } label: {
                HStack(spacing: 2) {
                    Text(spec.unit).font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(DS.Color.accent.color)
                .frame(minHeight: Self.height)
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Unit \(spec.unit)")
            .accessibilityIdentifier("flexible-number-\(key)-unit")
        } else {
            Text(spec.unit).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Color.textTertiary.color)
                .lineLimit(1).fixedSize()
        }
    }

    /// Up / down scrubs, once the finger has travelled `tapSlop` (below it the Button's tap opens
    /// the keypad); committed once, on release.
    private var drag: some Gesture {
        DragGesture(minimumDistance: Self.tapSlop)
            .onChanged { g in
                if scrub == nil { scrub = (spec.value, spec.value); lastY = 0 }
                let dy = Double(g.translation.height - lastY)
                lastY = g.translation.height
                guard dy != 0, let s = scrub else { return }
                scrub = FlexNumberScrub.scrub(raw: s.raw, deltaY: dy, spec: spec)
            }
            .onEnded { _ in
                let done = scrub
                scrub = nil
                lastY = 0
                if let done, abs(done.shown - spec.value) > 1e-12 { onCommit(done.shown) }
            }
    }
}

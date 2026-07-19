// GlassValuePill.swift — the keep-clear distance control (keep-clear Phase B, Part B).
//
// "Shapr3D meets Apple dark-mode liquid glass": a floating dark ultra-thin-material
// glass pill with a soft inner sheen and a rounded-squircle, carrying a big legible
// number + unit that is
//   • SCRUBBABLE horizontally — Shapr3D-style precision drag where a slow finger takes
//     fine steps and a fast flick takes coarse ones (`ClearanceScrub`);
//   • TAP-to-type — a tap (no scrub) opens a numeric field;
//   • Auto-aware — an "Auto" chip shows the real geometry-derived mm when the value is
//     auto-derived, and a ↺ reset restores it once the user has set an explicit number.
// It respects Dynamic Type (the number size is a `@ScaledMetric`) and reads its chrome
// from the TopOptDesign tokens (`Surface.valuePill`, `Radius.valuePill`, `Color.clearance`).
//
// The scrub curve is pure + headless-tested (`ClearanceScrub`); this SwiftUI shell that
// accumulates drag deltas and renders the glass is maintainer device QA (the /app/ rule).

import SwiftUI
import TopOptDesign

struct GlassValuePill: View {
    /// Short label ("Margin", "Axial", "Depth").
    let title: String
    /// The user's explicit value (mm), or nil when it is auto-derived.
    let valueMM: Double?
    /// The geometry-derived Auto suggestion (mm), or nil when unknown (no bore geo).
    let autoMM: Double?
    /// The pill's accent. Design-overhaul 109: the value chips are BLUE liquid glass (the app's
    /// signature material) — distinct from the RED 3D clearance HANDLES, which keep the
    /// forbidden-space colour. Blue by default; callers may override.
    var tint: Color = DS.Color.accent.color
    /// Highlight the pill (e.g. while its 3D handle is being dragged — the live readout).
    var active: Bool = false
    /// Compact row variant (Selections panel) vs the larger floating variant.
    var compact: Bool = false
    /// Set an explicit value (mm), or nil to reset to the Auto suggestion.
    let onSet: (Double?) -> Void

    @State private var typing = false
    @State private var draft = ""
    /// Running mm value during a scrub (nil = not scrubbing), and the last cumulative
    /// drag x, so each `onChanged` applies only the incremental delta.
    @State private var scrubValue: Float?
    @State private var scrubLastX: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    /// The number size scales with Dynamic Type. Design-overhaul 109: tightened from 22/15 to
    /// 17/13 — the old pills were far too large.
    @ScaledMetric(relativeTo: .title3) private var numberSizeFloating: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var numberSizeCompact: CGFloat = 13

    private var isAuto: Bool { valueMM == nil }
    private var displayedMM: Double? { valueMM ?? autoMM }
    private var numberSize: CGFloat { compact ? numberSizeCompact : numberSizeFloating }

    var body: some View {
        HStack(spacing: compact ? DS.Space.xs : DS.Space.s) {
            VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(title.uppercased())
                        .font(.system(size: compact ? 9 : 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(DS.Color.textTertiary.color)
                    if isAuto { autoChip }
                }
                numberRow
            }
            if !isAuto { resetButton }
        }
        .padding(.vertical, compact ? 4 : 6)
        .padding(.horizontal, compact ? DS.Space.s : DS.Space.sm)
        .liquidGlass(LiquidGlass.Tint.frost(DS.Color.accent, intensity: active ? 0.75 : 0.5),
                     cornerRadius: Self.radius, specular: active ? 1.3 : 1)
        .overlay(activeBorder)
        .compositingGroup()
        .dsShadow(.panel)
        .animation(DS.Motion.emphasized, value: active)
        // Commit on focus loss too: the iOS decimal pad has no return key, so `.onSubmit`
        // alone would strand a typed value when the user dismisses the keyboard.
        .onChange(of: fieldFocused) { focused in if !focused { commitTyped() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) clearance")
        .accessibilityValue(isAuto ? "Auto \(Self.mm(displayedMM))" : Self.mm(valueMM))
    }

    // MARK: number + unit (scrub / type)

    @ViewBuilder private var numberRow: some View {
        if typing {
            HStack(spacing: 3) {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .frame(width: compact ? 44 : 64)
                    .multilineTextAlignment(.leading)
                    .font(.system(size: numberSize, weight: .heavy))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .focused($fieldFocused)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .onSubmit(commitTyped)
                Text("mm").font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .onAppear { fieldFocused = true }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Self.number(displayedMM))
                    .font(.system(size: numberSize, weight: .heavy))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .foregroundStyle((isAuto ? tint : DS.Color.textPrimary.color))
                Text("mm").font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture)
        }
    }

    /// How far the finger must travel before a scrub BEGINS. Below this a touch is a
    /// tap (→ type), so a pure tap on an Auto pill never writes `autoMM` as an explicit
    /// override just to open the field.
    private static let scrubThreshold: CGFloat = 2

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if scrubValue == nil {
                    // Don't begin (or write anything) until the finger actually moves —
                    // otherwise the zero-delta tap flips Auto → explicit before `onEnded`
                    // can classify it as a tap-to-type.
                    guard abs(v.translation.width) > Self.scrubThreshold else { return }
                    scrubValue = Float(displayedMM ?? 0)
                    scrubLastX = 0                // measure the first delta from the start
                }
                let dx = v.translation.width - scrubLastX
                scrubLastX = v.translation.width
                guard dx != 0 else { return }
                let nv = ClearanceScrub.scrub(value: scrubValue ?? 0, deltaPoints: Float(dx))
                scrubValue = nv                                          // accumulate the raw value
                onSet(ClearanceQuantize.snap(Double(nv)))                // emit on the 0.25 mm grid (item 12)
            }
            .onEnded { _ in
                let didScrub = scrubValue != nil     // a scrub actually began → not a tap
                scrubValue = nil
                scrubLastX = 0
                if !didScrub {                       // a tap → type
                    draft = Self.number(displayedMM)
                    typing = true
                }
            }
    }

    private func commitTyped() {
        guard typing else { return }              // idempotent (onSubmit + focus-loss)
        let t = draft.trimmingCharacters(in: .whitespaces)
        // Typed values round to the nearest 0.25 mm step on commit (item 12); empty reverts to Auto.
        if let v = Double(t), v > 0 { onSet(ClearanceQuantize.snap(v)) } else if t.isEmpty { onSet(nil) }
        typing = false
    }

    // MARK: chrome

    private var autoChip: some View {
        Text("Auto")
            .font(.system(size: compact ? 8.5 : 9.5, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(tint)
            .padding(.vertical, 1.5).padding(.horizontal, 5)
            .background(Capsule().fill(tint.opacity(0.16)))
    }

    private var resetButton: some View {
        Button { onSet(nil) } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: compact ? 10 : 12, weight: .bold))
                .foregroundStyle(DS.Color.textTertiary.color)
                .padding(compact ? 3 : 5)
                .background(Circle().fill(DS.Color.fillSubtle.color))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset \(title) to Auto")
    }

    /// The chip's corner radius — tightened for the 2026-small redesign (was `DS.Radius.valuePill`).
    private static let radius: CGFloat = 12

    /// A brighter blue rim while the chip owns a live drag (the glass supplies the resting edge).
    @ViewBuilder private var activeBorder: some View {
        if active {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(tint.opacity(0.8), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }

    // MARK: formatting

    /// The number alone ("2.5"), rounded to 2 dp; "—" when unknown.
    static func number(_ v: Double?) -> String {
        guard let v = v else { return "—" }
        return String(format: "%g", (v * 100).rounded() / 100)
    }
    /// Number + unit for accessibility ("2.5 mm").
    static func mm(_ v: Double?) -> String {
        guard v != nil else { return "—" }
        return "\(number(v)) mm"
    }
}

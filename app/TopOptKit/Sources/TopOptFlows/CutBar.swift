// CutBar.swift — B8 (R1, P6, N1, rows 36; mockup #cut-line, #cut-hole, #cut-hole-across, #cut-hole-along, #cut-plane-ask,
// #cut-ring): the Cut tool's bar and its first question, beside the cut on the part.
//
//   • The bar (mockup .tbar): ✕ │ Tilt ↺ n° ↻ │ Rotate ↺ n° ↻ │ n mm drag ↕ │ ✓. A flat face has no Tilt (its line only turns,
//     and that turn is Rotate); an along line has no mm (its ⟲ handle carries it round: "drag ⟲"). Every number is the app's
//     NumberField (tap to type, drag to step, §4.28); ↺ / ↻ step 15°.
//   • The question (mockup .ask): "Cut this hole…" [Along the hole │ Across the hole], or "Which plane?" [Around it │ Down it │
//     At an angle], each a picture over its words.

import SwiftUI
import TopOptDesign

public enum CutBarCopy {
    public static let tilt = "Tilt"
    public static let rotate = "Rotate"
    public static let dragMove = "drag \u{2195}"
    public static let dragAround = "drag \u{27F2}"
    public static let askHole = "Cut this hole\u{2026}"
    public static let alongHole = "Along the hole"
    public static let acrossHole = "Across the hole"
    public static let askPlane = "Which plane?"
    public static let aroundIt = "Around it"
    public static let downIt = "Down it"
    public static let atAnAngle = "At an angle"
}

/// ✕ │ [Tilt ↺ n° ↻ │] Rotate ↺ n° ↻ │ [n mm drag ↕ | drag ⟲] │ ✓
struct CutBar: View {
    let aim: CutAim
    let set: (CutAim) -> Void
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            round("xmark", "Cancel", key: "cutBarCancel", accent: false, action: cancel)
            if aim.showsTilt {
                stepper(CutBarCopy.tilt, key: "cutBarTilt", value: aim.tiltDeg, range: -CutAim.tiltLimit...CutAim.tiltLimit,
                        wraps: false) { v in var a = aim; a.setTilt(v); set(a) }
                divider
            }
            stepper(CutBarCopy.rotate, key: "cutBarRotate", value: aim.rotateDeg, range: 0...360, wraps: true) { v in
                var a = aim; a.setRotate(v); set(a)
            }
            if aim.moves {
                divider
                NumberField(key: "cutBarMove", title: "Move",
                            spec: FlexNumberSpec(value: aim.offsetMM, unit: "mm", step: 0.5, range: aim.reach, decimals: 1),
                            size: .bare, allowsNegative: aim.reach.lowerBound < 0) { v in var a = aim; a.setOffset(v); set(a) }
                label(CutBarCopy.dragMove)
            } else {
                label(CutBarCopy.dragAround)
            }
            round("checkmark", "Cut", key: "cutBarOK", accent: true, action: confirm)
        }
        .padding(5)
        .background(Capsule().fill(DS.Color.chipSolid.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .fixedSize()
        .background(DSParts.publish("cutBar"))
    }

    private var divider: some View { Rectangle().fill(DS.Color.strokeStrong.color).frame(width: 1, height: 24) }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color).padding(.horizontal, 6).fixedSize()
    }

    /// Tilt or Rotate: its word, ↺ 15° · its number · ↻ 15°.
    private func stepper(_ t: String, key: String, value: Double, range: ClosedRange<Double>, wraps: Bool,
                         set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            label(t)
            round("arrow.counterclockwise", "\(t) \u{2212}15\u{00B0}", key: "\(key)Minus", accent: false) { set(value - 15) }
            NumberField(key: key, title: t,
                        spec: FlexNumberSpec(value: value, unit: "\u{00B0}", step: 1, range: range, decimals: 0, wraps: wraps),
                        size: .bare, allowsNegative: range.lowerBound < 0, onCommit: set)
            round("arrow.clockwise", "\(t) +15\u{00B0}", key: "\(key)Plus", accent: false) { set(value + 15) }
        }
    }

    /// A 42 pt round button (mockup .tbar .c; ✓ is the accent).
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

/// "Cut this hole…" or "Which plane?" — picture buttons (mockup .ask: 96 pt options, a 44 × 30 picture over the words).
struct CutAsk: View {
    let ask: CutAim.Ask
    let answer: (CutAim.Way, _ atAnAngle: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ask == .hole ? CutBarCopy.askHole : CutBarCopy.askPlane)
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
            HStack(spacing: 6) {
                if ask == .hole {
                    option(CutBarCopy.alongHole, key: "cutAskAlong", picture: .alongHole) { answer(.along, false) }
                    option(CutBarCopy.acrossHole, key: "cutAskAcross", picture: .acrossHole) { answer(.across, false) }
                } else {
                    option(CutBarCopy.aroundIt, key: "cutAskAround", picture: .around) { answer(.across, false) }
                    option(CutBarCopy.downIt, key: "cutAskDown", picture: .down) { answer(.along, false) }
                    option(CutBarCopy.atAnAngle, key: "cutAskAngle", picture: .angle) { answer(.across, true) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Surface.dialog.color)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .fixedSize()
        .background(DSParts.publish("cutAsk"))
    }

    private func option(_ words: String, key: String, picture: CutAskPicture.Kind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                CutAskPicture(kind: picture).frame(width: 44, height: 30)
                Text(words).font(.system(size: 12)).foregroundStyle(DS.Color.textPrimary.color)
                    .multilineTextAlignment(.center).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
            .frame(width: 96)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Color.fillSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(key))
        .accessibilityLabel(words)
    }
}

/// The ask's pictures, the mockup's 44 × 30 drawings: a bore (its rim and walls) or a block, and the cut in the accent.
struct CutAskPicture: View {
    enum Kind { case alongHole, acrossHole, around, down, angle }
    let kind: Kind

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 44, sy = size.height / 30
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            let grey = GraphicsContext.Shading.color(Color(red: 0.6, green: 0.67, blue: 0.67))
            let accent = GraphicsContext.Shading.color(Color(red: 0.39, green: 0.82, blue: 1.0))
            switch kind {
            case .alongHole, .acrossHole:
                ctx.stroke(Path(ellipseIn: CGRect(x: 12 * sx, y: 2 * sy, width: 20 * sx, height: 8 * sy)), with: grey, lineWidth: 1)
                var walls = Path(); walls.move(to: p(12, 6)); walls.addLine(to: p(12, 24)); walls.move(to: p(32, 6)); walls.addLine(to: p(32, 24))
                ctx.stroke(walls, with: grey, lineWidth: 1)
                if kind == .alongHole {
                    var l = Path(); l.move(to: p(22, 2)); l.addLine(to: p(22, 28))
                    ctx.stroke(l, with: accent, lineWidth: 2.5)
                } else {
                    ctx.stroke(Path(ellipseIn: CGRect(x: 11 * sx, y: 12 * sy, width: 22 * sx, height: 8 * sy)), with: accent, lineWidth: 2.5)
                }
            case .around, .down, .angle:
                ctx.stroke(Path(roundedRect: CGRect(x: 10 * sx, y: 4 * sy, width: 24 * sx, height: 22 * sy), cornerRadius: 4 * sx),
                           with: grey, lineWidth: 1)
                var l = Path()
                switch kind {
                case .around: l.move(to: p(8, 15)); l.addLine(to: p(36, 15))
                case .down: l.move(to: p(22, 2)); l.addLine(to: p(22, 28))
                default: l.move(to: p(8, 26)); l.addLine(to: p(36, 4))
                }
                ctx.stroke(l, with: accent, lineWidth: 2.5)
            }
        }
        .accessibilityHidden(true)
    }
}

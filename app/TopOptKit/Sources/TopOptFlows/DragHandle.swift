// DragHandle.swift — B2 (design-system §4.24; his R1, and round 2: "one handle for every drag").
//
// A 44 pt round handle with ↕ (or ⟲ around a bore or drum), turned to its drag direction on screen. It is dragged along its
// axis only (the across-axis part of a finger's move is ignored), and the number it changes rides beside it in a value pill.
// The cut (Cut and Print plan: drag moves the cut, Tilt / Rotate only angle it), a face prism's end (its depth) and a
// zone's sides use it.

import SwiftUI
import TopOptDesign

struct DragHandle: View {
    enum Glyph { case along, around }

    /// The published frame ("handle-<key>") and accessibility id.
    let key: String
    /// The drag direction on screen (any length; up = (0, -1)).
    let axis: CGVector
    var glyph: Glyph = .along
    /// The number it changes, shown beside it ("31.0 mm").
    let value: String
    /// Points moved along `axis` since the drag began (+ = along it); `ended` once, on release.
    let onDrag: (_ along: CGFloat, _ ended: Bool) -> Void

    static let size: CGFloat = 44

    /// The part of a move that lies along the axis.
    static func along(_ t: CGSize, axis: CGVector) -> CGFloat {
        let l = (axis.dx * axis.dx + axis.dy * axis.dy).squareRoot()
        guard l > 0 else { return 0 }
        return (t.width * axis.dx + t.height * axis.dy) / l
    }

    /// The glyph's turn: ↕ points up at 0°.
    var angle: Angle { .radians(atan2(Double(axis.dx), Double(-axis.dy))) }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: glyph == .along ? "arrow.up.and.down" : "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .rotationEffect(glyph == .along ? angle : .zero)
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(DS.Color.accent.color)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 2)))
                .dsShadow(DS.Shadow.panel)
                .contentShape(Circle())
                .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { onDrag(Self.along($0.translation, axis: axis), false) }
                    .onEnded { onDrag(Self.along($0.translation, axis: axis), true) })
                .background(CornerPairStyle.publish("handle-\(key)"))
                .accessibilityLabel("Drag to change")
                .accessibilityValue(value)
                .accessibilityIdentifier("handle-\(key)")
            Text(value)
                .font(.system(size: 14, weight: .heavy)).monospacedDigit()
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.vertical, 6).padding(.horizontal, DS.Space.m)
                .background(Capsule().fill(DS.Surface.valuePill.color)
                    .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
                .background(CornerPairStyle.publish("handleValue-\(key)"))
        }
    }
}

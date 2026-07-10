// RotationRingGizmo.swift — the SwiftUI surface for the M7.6-ring constrained
// single-DOF rotation ring (MOD-F1 D4 v2). It draws the ring(s) at the load
// arrow's base, maps a drag to the ONE angle the ring constrains (never a
// freehand vector), fires a haptic tick as the drag crosses each 15° detent, and
// exposes Set (commit this ring / reveal the next) and Cancel.
//
// All the aiming math lives in the headlessly-tested RotationRing / RingAiming;
// this view is pure presentation + gesture and is maintainer device QA (the M7
// /app/ standard). Haptics compile only where UIKit exists (iOS); macOS builds
// the same view without the tick generator.

import SwiftUI
import simd
import TopOptDesign
#if canImport(UIKit)
import UIKit
#endif

/// The ring overlay for the active load's custom aim. `center` is the arrow base
/// in stage coordinates; `aiming` says whether ring 1 or the orthogonal ring 2 is
/// live (so ring 2 is drawn only after the first commits).
struct RotationRingGizmo: View {
    let center: CGPoint
    let aiming: RingAiming
    let tint: Color
    /// Live drag angle (radians about `center`) — drives RingAiming.rotateActive.
    let onRotate: (Float) -> Void
    /// Commit the current ring (ring 1 → reveal ring 2; ring 2 → finalize).
    let onSet: () -> Void
    /// Abandon the aim and restore the previous direction.
    let onCancel: () -> Void

    /// The last raw drag angle, for per-detent haptic edge detection.
    @State private var lastAngle: Float?

    private static let radius: CGFloat = 92

    var body: some View {
        ZStack {
            ringShape
            detentTicks
            controls
        }
        .frame(width: Self.radius * 2 + 120, height: Self.radius * 2 + 120)
        .position(center)
    }

    // The ring itself: the active ring is solid; a committed first ring is dimmed
    // so the two-stage sequence reads (ring 2 is drawn perpendicular-ish, flattened).
    private var ringShape: some View {
        ZStack {
            if aiming.isOnSecondRing {
                Ellipse()
                    .stroke(tint.opacity(0.35), lineWidth: 2)
                    .frame(width: Self.radius * 2, height: Self.radius * 0.7)
            }
            Circle()
                .stroke(tint, style: StrokeStyle(lineWidth: 3))
                .frame(width: Self.radius * 2, height: Self.radius * 2)
                .shadow(color: tint.opacity(0.5), radius: 8)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    // The drag is constrained to a single angle about the ring centre
                    // — its distance from centre is ignored (never a 2-DOF vector).
                    let local = CGPoint(x: v.location.x - Self.radius - 60,
                                        y: v.location.y - Self.radius - 60)
                    let a = RotationRing.angleForDrag(center: .zero, location: local)
                    if let last = lastAngle, RotationRing.didCrossDetent(fromRadians: last, toRadians: a) {
                        fireTick()
                    }
                    lastAngle = a
                    onRotate(a)
                }
                .onEnded { _ in lastAngle = nil }
        )
    }

    // 24 tick marks around the ring (one per 15° detent).
    private var detentTicks: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 0..<RotationRing.detentCount {
                let a = CGFloat(i) / CGFloat(RotationRing.detentCount) * 2 * .pi
                let outer = Self.radius, inner = Self.radius - 8
                let p0 = CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner)
                let p1 = CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer)
                var path = Path(); path.move(to: p0); path.addLine(to: p1)
                ctx.stroke(path, with: .color(tint.opacity(0.45)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: DS.Space.s) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .frame(width: 40, height: 34)
                        .background(Capsule().fill(DS.Surface.bar.color)
                            .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
                }
                .buttonStyle(.plain)
                Button(action: onSet) {
                    Text(aiming.isOnSecondRing ? "Done" : "Set")
                        .dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
                        .background(Capsule().fill(DS.Color.accent.color))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fireTick() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

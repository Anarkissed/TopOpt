// PlayTimeline.swift — B2 (design-system §4.35; his Phase 3 note P3: "All actions go to the Play view button. When clicked it
// automatically starts at the separation of the parts and the play button at the centre-bottom of the screen is usable and
// will play the movement of the parts").
//
// Bottom centre, just above the corner: a 64 pt glass capsule — ▶ / ❚❚ (accent) · above the track, what plays and where it
// is · the track with its two ends in words (Apart ⟷ Together on the Print plan; At rest ⟷ Full squish on Setup and Squish).
// ▶ plays to the far end and back, again and again, pausing ½ s at each end; a drag anywhere along the track stops it there.
// When nothing can come apart it says so and ▶ is dimmed. With reduced motion ▶ steps between the two ends.
// The timing is pure (`PlayTimelineClock`); the view draws it.

import SwiftUI
import TopOptDesign

/// Where the timeline is (0 = the left end, 1 = the right end) at a time since ▶, playing there and back with a pause at
/// each end.
struct PlayTimelineClock: Equatable {
    /// Seconds from one end to the other.
    var travel: Double = 2
    /// The pause at each end.
    var pause: Double = 0.5

    /// One cycle: left → pause → right → pause → back.
    var period: Double { 2 * (travel + pause) }

    /// The position at `t` seconds after ▶ from `start` (moving right from 0, left from 1).
    func position(at t: Double, from start: Double = 0) -> Double {
        // run from the start's own place in the cycle
        let startPhase = start >= 1 ? travel + pause : start * travel
        var x = (t + startPhase).truncatingRemainder(dividingBy: period)
        if x < 0 { x += period }
        if x < travel { return x / travel }                       // going right
        if x < travel + pause { return 1 }                         // pause at the right end
        if x < 2 * travel + pause { return 1 - (x - travel - pause) / travel }   // going left
        return 0                                                   // pause at the left end
    }

    /// Reduced motion: ▶ steps to the other end.
    static func step(from p: Double) -> Double { p < 0.5 ? 1 : 0 }
}

struct PlayTimeline: View {
    /// What plays and where it is ("2 pieces + 3 add-ons · apart, as they print").
    let caption: String
    let leftEnd: String
    let rightEnd: String
    /// 0…1 (the caller's state: the pieces' separation, the squish).
    @Binding var position: Double
    /// Nothing can come apart: it says so (`caption`) and ▶ is dimmed.
    var enabled = true
    var clock = PlayTimelineClock()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playing = false
    @State private var trackWidth: CGFloat = 1

    static let height: CGFloat = 64
    static let width: CGFloat = 420

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Button { toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(DS.Color.accent.color))
                    .opacity(enabled ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .background(CornerPairStyle.publish("timelinePlay"))
            .accessibilityLabel(playing ? "Pause" : "Play")
            .accessibilityIdentifier("timeline-play")
            VStack(alignment: .leading, spacing: 4) {
                Text(caption).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                HStack(spacing: DS.Space.s) {
                    Text(leftEnd).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textTertiary.color)
                    track
                    Text(rightEnd).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textTertiary.color)
                }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(width: Self.width, height: Self.height)
        .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(DS.Surface.bar.color)))
        .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .clipShape(Capsule())
        .dsShadow(DS.Shadow.panel)
        .background(CornerPairStyle.publish("timeline"))
        .task(id: playing) {
            guard playing else { return }
            let start = position, began = Date()
            while !Task.isCancelled, playing {
                position = clock.position(at: Date().timeIntervalSince(began), from: start)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private var track: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.fillSelected.color).frame(height: 4)
                Circle().fill(Color.white).frame(width: 16, height: 16)
                    .offset(x: CGFloat(position) * (g.size.width - 16))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { v in
                playing = false
                position = Self.position(atX: v.location.x, trackWidth: g.size.width)
            })
            .background(CornerPairStyle.publish("timelineTrack"))
        }
        .frame(height: 44)
    }

    /// Where a finger at `x` along the track puts the timeline (the thumb's centre follows it, inside the ends).
    static func position(atX x: CGFloat, trackWidth w: CGFloat) -> Double {
        Double(min(1, max(0, (x - 8) / max(1, w - 16))))
    }

    private func toggle() {
        if reduceMotion {
            position = PlayTimelineClock.step(from: position)
        } else {
            playing.toggle()
        }
    }
}

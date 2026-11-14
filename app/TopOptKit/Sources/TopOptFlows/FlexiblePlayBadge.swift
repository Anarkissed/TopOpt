// FlexiblePlayBadge — what the Play icon says while the bar is hidden, and the Heat icon's "every group" mark (task
// 2026-09-29-flexible-screens, round 7 batch R7-V's review). His rule (binding): visual over text, view buttons icons only.
// ★ THE VERIFY (2026-10-14): with Play off — the default — the bar and its lines are hidden, and all that was left of the
// sims' status was a faint grey mini spinner in the Play icon's corner (it read as a speck at 11" landscape); a failed sim
// said nothing at all ("Squish sim failed", "Group 2's sim failed", "Refine didn't settle", "Refine took too long" live
// in the hidden bar), and the Settings page's Play icon had no status of its own. Now both Play icons carry:
//   * a turning ACCENT ARC on the icon's rim while the sims run or refine;
//   * an ORANGE DOT at its corner when a sim failed or its refine did not land (the bar says why when he turns Play on).
// The Settings [Heat] icon under his 3 s hold (every group's heat) carries three small dots in his groups' colours, so
// "this group" and "every group" differ at a glance (thermometer.medium vs .high alone could not be told apart).

import SwiftUI
import TopOptDesign

/// The sims' status as the Play icon shows it.
public enum FlexiblePlayStatus: Equatable, Sendable {
    case idle, working, failed

    /// The Settings page's: from the line its (hidden) bar would carry (FlexibleSettingsSquish.note).
    static func settings(note: String?) -> FlexiblePlayStatus {
        switch note {
        case FlexibleRowCopy.settingsColumnRunning?: return .working
        case FlexibleRowCopy.settingsColumnFailed?: return .failed
        default: return .idle
        }
    }
}

extension FlexibleMainStage {
    /// The main page's: from the sims on screen (the bar's note — FlexibleMainStage.feNote).
    var playStatus: FlexiblePlayStatus {
        if simsWorking { return .working }
        if fe.failure != nil || !fe.skipped.isEmpty || fe.refineKept != nil { return .failed }
        return .idle
    }
}

/// The Play icon's status, drawn over the 40 pt round view button (icon only — the state is the accessibility value).
struct FlexiblePlayBadge: View {
    let status: FlexiblePlayStatus

    static let ringWidth: CGFloat = 3
    static let dot: CGFloat = 11

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if status == .working {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { t in
                    Circle()
                        .inset(by: Self.ringWidth / 2)
                        .trim(from: 0, to: 0.3)
                        .stroke(DS.Color.accent.color, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                }
                .frame(width: 40, height: 40)
                .accessibilityIdentifier("flexible-play-working")
            }
            if status == .failed {
                Circle().fill(DS.Color.warning.color)
                    .overlay(Circle().strokeBorder(DS.Color.background.color, lineWidth: 1.5))
                    .frame(width: Self.dot, height: Self.dot)
                    .offset(x: 2, y: -2)
                    .accessibilityIdentifier("flexible-play-failed")
            }
        }
        .frame(width: 40, height: 40, alignment: .topTrailing)
        .allowsHitTesting(false)
    }
}

/// The Settings [Heat] icon's "every group" mark: three small dots in his groups' colours (the [Groups] glyph's).
struct FlexibleHeatAllBadge: View {
    let colours: [RGBA]

    var body: some View {
        ZStack {
            ForEach(Array(colours.prefix(3).enumerated()), id: \.offset) { i, c in
                Circle().fill(c.color)
                    .overlay(Circle().strokeBorder(DS.Color.background.color, lineWidth: 1))
                    .frame(width: 7, height: 7)
                    .offset(x: [-3.5, 3.5, 0][i % 3], y: [2.5, 2.5, -3.5][i % 3])
            }
        }
        .frame(width: 16, height: 16)
        .offset(x: 3, y: -3)
        .allowsHitTesting(false)
        .accessibilityIdentifier("flexible-settings-heat-all")
    }
}

// ResultsGiveWayKey.swift — ★ notes25 (C2, C3): Results' colour key says in plain words what its top colour means — "Yields" for a
// solid result (its stress against the material's knocked-down yield), "Gives way" for a print file (how close each place is to
// giving way: red = it gives way at the shown load). The tap-to-explore key's look and behaviour (ResultsStressExplore, which
// Compare keeps), with that one word at the top of the bar; a print file's scale is the share of each place's limit.

import SwiftUI
import TopOptDesign

struct ResultsGiveWayKey: View {
    enum Scale: Equatable {
        /// A solid result: MPa, the top = the material's (knocked-down) yield.
        case stress(topMPa: Double)
        /// A print file: each place's share of its limit at the shown load, the top = 100 % (it gives way).
        case share
    }
    let scale: Scale
    /// What the scale is keyed to ("PA12 · scaled to 21 MPa yield at 50% gyroid"), or the share's own line.
    let caption: String
    /// What the colours show right now while the part moves.
    var note: String? = nil
    /// The value where he tapped (MPa, or a share where 1 = gives way), nil before a tap.
    let reading: Double?
    @Binding var minimized: Bool

    /// ★ C2/C3: the top colour in plain words (at most five).
    static func topWords(_ s: Scale) -> String {
        switch s {
        case .stress: return "Yields"
        case .share: return "Gives way"
        }
    }

    private var readingText: String? {
        guard let r = reading else { return nil }
        switch scale {
        case .stress: return String(format: "%.2f MPa", r)
        case .share: return String(format: "%.0f%%", r * 100)
        }
    }

    var body: some View {
        Group {
            if minimized {
                Button { minimized = false } label: {
                    HStack(spacing: DS.Space.s) {
                        LinearGradient(colors: ResultsStressExplore.ramp, startPoint: .leading, endPoint: .trailing)
                            .frame(width: 44, height: 6).clipShape(Capsule())
                        Text(readingText ?? (scale == .share ? "Colour key" : "Stress key"))
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .foregroundStyle((reading == nil ? DS.Color.textSecondary : DS.Color.accent).color)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DS.Color.accent.color)
                    }
                    .padding(.horizontal, DS.Space.l).frame(height: 40)
                    .background(Capsule().fill(ResultsChrome.fill.color).overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open the colour key")
            } else {
                LatticeLegendChrome(width: reading == nil ? ResultsStressExplore.width : ResultsStressExplore.widthWithReading,
                                    minimized: $minimized,
                                    info: "Tap any spot on the part to read it there. Double-tap anywhere to come back.") {
                    HStack(alignment: .center, spacing: DS.Space.s) {
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(Array(ticks.enumerated()), id: \.offset) { i, t in
                                Text(t).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(DS.Color.textSecondary.color)
                                if i < ticks.count - 1 { Spacer(minLength: 0) }
                            }
                        }
                        .frame(width: 40, height: ResultsStressExplore.barH + 14)
                        LinearGradient(colors: ResultsStressExplore.ramp.reversed(), startPoint: .top, endPoint: .bottom)
                            .frame(width: 22, height: ResultsStressExplore.barH)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(alignment: .top) { arrow }
                        VStack(alignment: .leading, spacing: 2) {
                            // ★ C2/C3: what the top colour means, beside it
                            Text(Self.topWords(scale)).font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ResultsModel.stressColor(fraction: 1).color)
                                .fixedSize()
                                .background(ResultsChrome.publish("resultsStressKeyTop"))
                                .accessibilityIdentifier("results-stress-key-top")
                            Spacer(minLength: 0)
                            Text(scale == .share ? "of its" : "MPa").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.Color.textSecondary.color)
                            Text(scale == .share ? "limit" : "von Mises").font(.system(size: 10))
                                .foregroundStyle(DS.Color.textTertiary.color)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 66, height: ResultsStressExplore.barH + 14, alignment: .leading)
                        if let r = readingText {
                            LatticeLegendReading(value: String(r.split(separator: " ").first ?? Substring(r))
                                                    .replacingOccurrences(of: "%", with: ""),
                                                 unit: scale == .share ? "%" : "MPa", caption: "where you tapped")
                                .frame(width: 80)
                        }
                    }
                    if let note {
                        Text(note).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, DS.Space.s)
                            .accessibilityIdentifier("results-stress-key-note")
                    }
                    Text(caption).font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, DS.Space.s)
                }
            }
        }
        .background(ResultsChrome.publish("resultsStressKey"))
        .accessibilityIdentifier("results-stress-key")
    }

    private var ticks: [String] {
        switch scale {
        case .stress(let top):
            return (0..<5).map { String(format: top >= 10 ? "%.0f" : "%.1f", top * (1 - Double($0) / 4)) }
        case .share:
            return ["100%", "75%", "50%", "25%", "0"]
        }
    }

    /// The tapped value's place on the bar (hot end up).
    @ViewBuilder private var arrow: some View {
        if let r = reading {
            let top: Double = { if case .stress(let t) = scale { return t }; return 1 }()
            if top > 0 {
                let t = 1 - min(1, max(0, r / top))
                HStack(spacing: 0) {
                    Rectangle().fill(DS.Color.accent.color).frame(width: 22, height: 2)
                    Image(systemName: "arrowtriangle.left.fill").font(.system(size: 16)).foregroundStyle(DS.Color.accent.color)
                        .shadow(color: .black.opacity(0.8), radius: 1)
                }
                .offset(x: 11, y: CGFloat(t) * ResultsStressExplore.barH - 8)
            }
        }
    }
}

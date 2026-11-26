// LatticeRefreshingCard — ★ his notes on release 20 (2026-11-25): "Add a setting in the main menu settings to 'Skip all
// animations' which will turn off ALL animations and allow for a blank screen with a 'Refreshing Lattice' notification and
// progress bar. Let it run at the real speed of the refresh."
//
// With Skip all animations on, while a lay runs the lattice area stays blank (LatticeBuildShow hides the last lattice; nothing
// grows) and this card sits in the middle of the 3D view: "Refreshing Lattice", a progress bar, and what the engine is doing in
// a few words. The bar is the refresh's REAL progress: it moves on as each of the refresh's steps really ends (opening the part,
// laying the struts, cutting the part open), and within a step by the time that step took the last time on this part — never
// past 90 % of the step until it really ends (no fake progress: a slow step holds the bar, it never runs ahead of the work). An
// Organic lay's steps are the engine's own phases (growing, pruning, re-seeding, reaching the walls, finishing). Off: no card
// (the timelapse, or Organic's growth, is the refresh's picture).
import SwiftUI
import Combine
import TopOptDesign

/// The refresh under way: its steps, the one it is on and when that began. Main thread only.
@MainActor
public final class LatticeRefreshProgress: ObservableObject {
    /// One of the refresh's steps: its words (five at most) and how long it took the last time (s).
    struct Stage: Equatable { var words: String; var expectedS: Double }
    /// A refresh is under way.
    @Published public private(set) var on = false
    /// The step it is on (an index into `stages`).
    @Published private(set) var index = 0
    private(set) var stages: [Stage] = []
    private(set) var stageStarted = Date()
    /// Refreshes shown (tests).
    private(set) var shown = 0

    public init() {}

    /// A refresh began with these steps (in order).
    func begin(_ stages: [Stage], now: Date = Date()) {
        self.stages = stages.isEmpty ? [Stage(words: "Laying the struts", expectedS: 1)] : stages
        index = 0
        stageStarted = now
        if !on { shown += 1 }
        on = true
    }

    /// The step whose words are `words` is under way now (those before it are done). Unknown words: nothing moves.
    func reached(_ words: String, now: Date = Date()) {
        guard on, let i = stages.firstIndex(where: { $0.words == words }), i > index else { return }
        index = i
        stageStarted = now
    }

    /// The refresh ended (landed, failed or stopped).
    func end() {
        guard on else { return }
        on = false
        index = 0
        stages = []
    }

    /// The words of the step under way.
    var words: String { stages.indices.contains(index) ? stages[index].words : "" }

    /// How far the refresh is at `date` (0 → 1): the steps done (by how long each took the last time), and the share of the
    /// one under way by its time so far against its last time, never past 90 % of it until it ends.
    func fraction(at date: Date) -> Double {
        guard on, !stages.isEmpty else { return 0 }
        let w = stages.map { Swift.max($0.expectedS, 0.05) }
        let total = w.reduce(0, +)
        let done = w.prefix(index).reduce(0, +)
        let into = Swift.min(Self.stepCap, Swift.max(0, date.timeIntervalSince(stageStarted)) / w[index])
        return Swift.min(1, (done + into * w[index]) / total)
    }
    /// The share of a step the bar may reach before the step really ends.
    static let stepCap = 0.9
}

/// The centred card: "Refreshing Lattice", the bar, the step's words. Shown only with Skip all animations on and a refresh under
/// way; never takes a touch (the page stays usable round it).
struct LatticeRefreshingCard: View {
    @ObservedObject var progress: LatticeRefreshProgress
    @ObservedObject var settings: AppSettings = .shared
    var title = LatticeRefreshingCard.title

    static let title = "Refreshing Lattice"
    static let width: CGFloat = 300
    /// Test hook (FlexibleSaid.recording): each time the card was drawn with its words.
    nonisolated(unsafe) static var recorded: [String] = []

    var body: some View {
        if settings.skipAnimations, progress.on {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                card(progress.fraction(at: ctx.date))
            }
            .allowsHitTesting(false)
            .onAppear { if FlexibleSaid.recording { Self.recorded.append(title) } }
        }
    }

    private func card(_ f: Double) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title).dsStyle(DS.TypeScale.headline).foregroundStyle(DS.Color.textPrimary.color)
                .said(title)
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.textTertiary.color.opacity(0.35))
                Capsule().fill(DS.Color.accent.color).frame(width: Swift.max(6, (Self.width - 2 * DS.Space.l) * f))
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Refreshing the lattice")
            .accessibilityValue("\(Int((f * 100).rounded())) percent")
            Text(progress.words).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
        }
        .padding(DS.Space.l)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous).fill(DS.Surface.dialog.color))
        .accessibilityIdentifier("lattice-refreshing-card")
    }
}

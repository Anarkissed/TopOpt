// RunProgressReadout.swift — the honest in-flight progress readout (run-progress-
// visibility task). The maintainer runs design-box 64³ ladders that take ~80
// minutes (≈20 min/rung × 4 rungs); before this the only signal was a static,
// inert "Optimizing more variants…" pill, so a live run was indistinguishable
// from a dead one for over an hour.
//
// This view surfaces what the bridge progress callback ACTUALLY carries — variant
// (rung) N of M and the current SIMP iteration — alongside a live elapsed clock,
// and a clearly-LABELLED remaining-time estimate once one variant has completed.
// It is deliberately honest per the maintainer's constraint (handoff 086 made rung
// termination ADAPTIVE — iter 100–145, safety cap 200 — so the iteration count is
// NOT known in advance): no fabricated bar fills toward a fake 100%. The bar it
// does show is DISCRETE (completed variants / total) and sits flat while a rung
// runs; the ticking elapsed clock + climbing iteration are the "it's alive" signal.
//
// Shared by the RunScreen running card and the tappable ResultsScreen pill drawer
// so both read the same numbers the same way. Every value is a READ off RunModel
// (`progress`, `startedAt`); it mutates nothing but the (view-local) rung anchor.

import SwiftUI
import TopOptDesign

public struct RunProgressReadout: View {
    @ObservedObject var model: RunModel
    /// Voxel resolution + material for the "SIMP · NN³ · MATERIAL" footer.
    let resolution: Int
    let materialName: String
    /// One-line collapsed form (the pill) vs. the full card/drawer block.
    var compact: Bool

    public init(model: RunModel, resolution: Int, materialName: String, compact: Bool = false) {
        self.model = model
        self.resolution = resolution
        self.materialName = materialName
        self.compact = compact
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if compact { compactLine(now: context.date) }
                else { fullBlock(now: context.date) }
            }
        }
    }

    // MARK: derived values

    /// Read STRAIGHT off the model — never latched into view-local @State. A latch
    /// only updates when SwiftUI happens to observe the change, so it silently drops
    /// snapshots that are superseded within one runloop turn (handoff 089); the model
    /// holds the last snapshot for the life of the run, so reading it cannot go stale.
    private var snapshot: RunProgress {
        model.progress ?? RunProgress(rung: 0, rungCount: 1, iteration: 0)
    }

    private func elapsed(_ now: Date) -> TimeInterval {
        guard let start = model.startedAt else { return 0 }
        return Swift.max(0, now.timeIntervalSince(start))
    }

    /// The live ETA for the given instant: the estimator's last value ticked DOWN by
    /// the time since that event (a smooth countdown between ticks), plus whether it
    /// should be DIMMED — the stream has gone quiet for longer than a few iterations'
    /// worth of time, so the number is no longer trustworthy (handoff 111). nil before
    /// warm-up (the caller shows "estimating…").
    private func etaDisplay(_ now: Date) -> (text: String, dim: Bool)? {
        guard let eta = model.eta else { return nil }
        let sinceEvent = Swift.max(0, now.timeIntervalSinceReferenceDate - eta.asOf)
        let remaining = Swift.max(0, eta.secondsRemaining - sinceEvent)
        // Stale after a few iterations of silence, adaptive to the observed rate but
        // floored so a fast rung doesn't dim on one slow tick.
        let staleAfter = Swift.max(20, 3 * eta.secondsPerIteration)
        return (etaLabel(remaining, bound: eta.bound), sinceEvent > staleAfter)
    }

    /// ★ T5 (U4: "result", never "variant"): which of the results is being made.
    private var variantLine: String {
        let p = snapshot
        return p.rungCount > 1 ? "Result \(p.rung + 1) of \(p.rungCount)" : "Optimizing"
    }

    /// ★ T5: the run card's Step row — the result and its iteration (the mockup's "Scenario 2 of 3 · iteration 34").
    private var stepLine: String {
        let p = snapshot
        return p.rungCount > 1 ? "Result \(p.rung + 1) of \(p.rungCount) \u{00B7} iteration \(p.iteration)" : "Iteration \(p.iteration)"
    }

    /// ★ T5 (mockup #topo-corner "running": "3:10 left · tap to view"): the corner button's line while a run goes — the hedged
    /// time left once there is one.
    @MainActor public static func buttonLine(_ model: RunModel, now: Date = Date()) -> String {
        guard let eta = model.eta else { return "Tap to view" }
        let remaining = Swift.max(0, eta.secondsRemaining - Swift.max(0, now.timeIntervalSinceReferenceDate - eta.asOf))
        return timeLeft(remaining, bound: eta.bound) + " left \u{00B7} tap to view"
    }

    /// The time left in words, always hedged (handoff 111): "up to 42 min" while it is an upper bound, "about 42 min" once
    /// it is built on finished results.
    static func timeLeft(_ secs: TimeInterval, bound: RunETA.Bound) -> String {
        let mag = coarse(secs)
        switch bound {
        case .upper: return secs < 60 ? "under a minute" : "up to \(mag)"
        case .approximate: return secs < 60 ? "under a minute" : "about \(mag)"
        }
    }

    // MARK: full block (running card + drawer)

    /// ★ LOOK PER SCREEN (T5, mockup .running): "Optimizing" with its ring, then Step · Elapsed · Time left (13 pt, the label
    /// secondary, the value at the right), then the bar.
    @ViewBuilder private func fullBlock(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(DS.Color.accent.color)
                Text("Optimizing").font(.system(size: 20, weight: .bold)).foregroundStyle(DS.Color.textPrimary.color)
            }
            let eta = etaDisplay(now)
            statRow(label: "Step", value: stepLine)
            statRow(label: "Elapsed", value: clock(elapsed(now)))
            statRow(label: "Time left", value: eta?.text ?? "estimating\u{2026}", dim: eta?.dim ?? false)
            // DISCRETE, honest bar: completed results / total. Flat within a rung (handoff 086).
            if snapshot.rungCount > 1 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(DS.Color.accent.color).frame(width: g.size.width * snapshot.rungFractionComplete)
                    }
                }
                .frame(height: 6)
            }
        }
    }

    private func statRow(label: String, value: String, dim: Bool = false) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(label).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
            Spacer(minLength: DS.Space.l)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .monospacedDigit()
                // The time left fades when the stream stalls past the freshness threshold —
                // it dims WITH the staleness rather than lying with a crisp number.
                .opacity(dim ? 0.4 : 1)
        }
    }

    // MARK: compact line (the pill)

    @ViewBuilder private func compactLine(now: Date) -> some View {
        HStack(spacing: DS.Space.s) {
            ProgressView().controlSize(.small).tint(DS.Color.accent.color)
            Text(variantLine)
                .dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                .foregroundStyle(DS.Color.textPrimary.color)
            Text("·").foregroundStyle(DS.Color.textTertiary.color)
            Text(clock(elapsed(now)))
                .dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                .foregroundStyle(DS.Color.textSecondary.color)
                .monospacedDigit()
        }
    }

    // MARK: formatting

    /// The ETA label — ALWAYS hedged (handoff 111): "≤ …" while it's an upper bound
    /// (no rung has finished, built on the iteration cap), "~ …" once it's a live
    /// approximation (built on observed iterations-per-rung). Never a bare precise time.
    private func etaLabel(_ secs: TimeInterval, bound: RunETA.Bound) -> String {
        Self.timeLeft(secs, bound: bound)   // ★ T5: the row says "Time left"; the hedge is in words ("up to" / "about")
    }

    /// Elapsed as `M:SS` (or `H:MM:SS` past an hour) — exact, monospaced.
    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    /// The ETA magnitude, rounded to friendly units — never spuriously precise.
    private static func coarse(_ t: TimeInterval) -> String {
        if t < 60 { return "under a minute" }
        let totalMin = Int((t / 60).rounded())
        if totalMin < 60 { return "\(totalMin) min" }
        let h = totalMin / 60, rem = totalMin % 60
        return rem == 0 ? "\(h) hr" : "\(h) hr \(rem) min"
    }
}

#Preview("Run progress readout") {
    let m = RunModel(scheduler: SynchronousRunScheduler())
    return ZStack {
        DS.Color.background.color.ignoresSafeArea()
        RunProgressReadout(model: m, resolution: 64, materialName: "PLA")
            .padding(DS.Space.xl2)
    }
    .preferredColorScheme(.dark)
}

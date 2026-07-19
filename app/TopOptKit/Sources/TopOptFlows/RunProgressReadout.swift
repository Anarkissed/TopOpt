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

    private var variantLine: String {
        let p = snapshot
        return p.rungCount > 1 ? "Variant \(p.rung + 1) of \(p.rungCount)" : "Optimizing"
    }

    // MARK: full block (running card + drawer)

    @ViewBuilder private func fullBlock(now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small).tint(DS.Color.accent.color)
                Text(variantLine)
                    .dsStyle(DS.TypeScale.title)
                    .foregroundStyle(DS.Color.textPrimary.color)
            }

            Text("SIMP iteration \(snapshot.iteration)")
                .dsStyle(DS.TypeScale.body)
                .foregroundStyle(DS.Color.textSecondary.color)
                .monospacedDigit()

            // DISCRETE, honest bar: completed variants / total. Flat within a rung.
            if snapshot.rungCount > 1 {
                ProgressBar(value: snapshot.rungFractionComplete)
                    .frame(maxWidth: 320)
            }

            let eta = etaDisplay(now)
            statRow(label: "Elapsed", value: clock(elapsed(now)))
            statRow(label: "Est. remaining", value: eta?.text ?? "estimating…",
                    estimate: true, dim: eta?.dim ?? false)

            Text("SIMP · \(resolution)³ voxel grid · \(materialName)")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
        }
    }

    private func statRow(label: String, value: String, estimate: Bool = false,
                         dim: Bool = false) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(label)
                .dsStyle(DS.TypeScale.footnote)
                .foregroundStyle(DS.Color.textTertiary.color)
            Spacer(minLength: DS.Space.l)
            Text(value)
                .dsStyle(DS.TypeScale.bodyStrong)
                .foregroundStyle((estimate ? DS.Color.textSecondary : DS.Color.textPrimary).color)
                .monospacedDigit()
                // The ETA fades when the stream stalls past the freshness threshold —
                // it dims WITH the staleness rather than lying with a crisp number.
                .opacity(dim ? 0.4 : 1)
        }
        .frame(maxWidth: 320)
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
        let mag = coarse(secs)                       // "42 min" / "under a minute"
        let underMinute = secs < 60
        switch bound {
        case .upper:
            return underMinute ? "≤ under a minute" : "≤ about \(mag) left"
        case .approximate:
            return underMinute ? "~ under a minute" : "~\(mag) left"
        }
    }

    /// Elapsed as `M:SS` (or `H:MM:SS` past an hour) — exact, monospaced.
    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    /// The ETA magnitude, rounded to friendly units — never spuriously precise.
    private func coarse(_ t: TimeInterval) -> String {
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

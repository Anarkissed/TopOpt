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

    /// When the CURRENT rung began — anchored on each rung transition so the ETA
    /// counts DOWN within a rung. View-local and never persisted: on a freshly
    /// created readout (e.g. reopening the drawer mid-rung) it re-anchors to now,
    /// which briefly OVER-estimates (never under) and then self-corrects. The ETA
    /// math itself lives in `RunProgress.remainingEstimate` (unit-tested).
    @State private var rungStartedAt: Date?
    @State private var lastRung: Int?

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
        .onAppear {
            if rungStartedAt == nil { rungStartedAt = model.startedAt ?? Date() }
            lastRung = model.progress?.rung ?? lastRung
        }
        .onChange(of: model.progress?.rung) { newRung in
            guard let rung = newRung, lastRung != rung else { return }
            lastRung = rung                          // a new variant started
            rungStartedAt = Date()
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

    private func rungElapsed(_ now: Date) -> TimeInterval {
        guard let anchor = rungStartedAt else { return elapsed(now) }
        return Swift.max(0, now.timeIntervalSince(anchor))
    }

    /// The ETA seconds (nil until a rung has completed) for the given instant.
    private func eta(_ now: Date) -> TimeInterval? {
        snapshot.remainingEstimate(elapsed: elapsed(now), currentRungElapsed: rungElapsed(now))
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

            statRow(label: "Elapsed", value: clock(elapsed(now)))
            statRow(label: "Est. remaining", value: etaText(now), estimate: true)

            Text("SIMP · \(resolution)³ voxel grid · \(materialName)")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
        }
    }

    private func statRow(label: String, value: String, estimate: Bool = false) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(label)
                .dsStyle(DS.TypeScale.footnote)
                .foregroundStyle(DS.Color.textTertiary.color)
            Spacer(minLength: DS.Space.l)
            Text(value)
                .dsStyle(DS.TypeScale.bodyStrong)
                .foregroundStyle((estimate ? DS.Color.textSecondary : DS.Color.textPrimary).color)
                .monospacedDigit()
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

    /// The estimate text — either the countdown ("~about 42 min left") or an honest
    /// "estimating" state before the first variant lands (no rung rate yet).
    private func etaText(_ now: Date) -> String {
        guard let secs = eta(now) else { return "estimating…" }
        return "~\(coarse(secs)) left"
    }

    /// Elapsed as `M:SS` (or `H:MM:SS` past an hour) — exact, monospaced.
    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    /// ETA rounded to friendly units — never spuriously precise (it's an estimate).
    private func coarse(_ t: TimeInterval) -> String {
        if t < 60 { return "under a minute" }
        let totalMin = Int((t / 60).rounded())
        if totalMin < 60 { return "about \(totalMin) min" }
        let h = totalMin / 60, rem = totalMin % 60
        return rem == 0 ? "about \(h) hr" : "about \(h) hr \(rem) min"
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

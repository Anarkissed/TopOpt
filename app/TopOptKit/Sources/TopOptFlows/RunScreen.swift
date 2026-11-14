// RunScreen.swift — the M7.7 run overlay: the design's "Optimizing NN%" glass
// card while a run is in flight, and design-consistent failure sheets (never
// alerts) when it can't finish.
//
// This is a thin SwiftUI renderer over RunModel — all of the run logic (the bar
// math, the failure classification, cancel, background) is in the headlessly-
// tested RunModel. Pixels + haptics here are maintainer device QA (the M7 /app/
// standard). Matches the RUNNING card in docs/design/TopOpt.dc.html.

import SwiftUI
import TopOptDesign

public struct RunScreen: View {
    @ObservedObject var model: RunModel
    /// Chosen material name, for the "SIMP · NN³ · MATERIAL" sub-line.
    let materialName: String
    /// Voxel resolution the run uses, shown as "NN³".
    let resolution: Int
    /// Re-run the same job from a failure sheet.
    var onRetry: () -> Void
    /// ★ T5: the version this run makes ("v8"), for the card's overline "OPTIMIZING V8"; nil off the Library.
    var version: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(model: RunModel, materialName: String, resolution: Int,
                onRetry: @escaping () -> Void = {}, version: String? = nil) {
        self.model = model
        self.materialName = materialName
        self.resolution = resolution
        self.onRetry = onRetry
        self.version = version
    }

    public var body: some View {
        ZStack {
            switch model.phase {
            case .running:
                // Once the first variant streams in, the results screen takes over
                // (progressive results); the progress card yields to it.
                if !(model.outcome?.variants.isEmpty ?? true) {
                    EmptyView()
                } else if model.isMinimized {
                    minimizedChip
                } else {
                    runningCard
                }
            case .failed:
                failureSheet
            default:
                EmptyView()
            }
        }
        .animation(DS.Motion.sheetIn, value: model.phase)
        .animation(DS.Motion.sheetIn, value: model.isMinimized)
    }

    // MARK: - Minimized chip ("Run in Background")

    /// A top-center pill shown while the run continues in the background; the
    /// workspace behind it is fully interactive. Tap to re-open the full card. Sits
    /// at the top (aligned with the nav row) so it never covers the bottom hint bar.
    private var minimizedChip: some View {
        // ★ B2 (U16, §4.34): the status pill in the top lane — centred, as wide as the row's controls allow, two lines:
        // the run, then "Tap to view"
        LaneSlot(key: "run-status") { _ in
            Button { model.restore() } label: {
                VStack(spacing: 1) {
                    RunProgressReadout(model: model, resolution: resolution,
                                       materialName: materialName, compact: true)
                        .lineLimit(1)
                    Text("Tap to view")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .padding(.vertical, DS.Space.s)
                .padding(.horizontal, DS.Space.l)
                .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Surface.sheet.color))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1))
                .dsShadow(.panel)
            }
            .buttonStyle(.plain)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Running card (design RUNNING)

    /// ★ LOOK PER SCREEN (T5, mockup .running): 480 pt, radius 24, the dialog surface; the overline names the version; the
    /// buttons sit at its right. No dimming: the part stays as it is behind it.
    private var runningCard: some View {
        ZStack {
            // centred on the page; behind it the page takes no taps while the card is up (as before), but is not dimmed
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
            runningCardBody
        }
    }

    private var runningCardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optimizing" + (version.map { " \($0)" } ?? ""))
                .font(.system(size: 11, weight: .bold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(DS.Color.accent.color)
                .opacity(pulse ? 1 : 0.65)

            // The honest, live readout: the result being made, its iteration, the elapsed clock, and a hedged time left
            // (once one result has finished). No fabricated percentage — handoff 086 made rung termination adaptive, so an
            // in-advance progress bar would lie.
            RunProgressReadout(model: model, resolution: resolution, materialName: materialName)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                PillButton("Cancel", style: .secondary) { model.cancel() }
                PillButton(model.runningInBackground ? "In background" : "Run in background",   // ★ B3 (app-map §3.4): plain words
                           style: .secondary,
                           isEnabled: model.canSendToBackground) { model.runInBackground() }
                    .background(CornerPairStyle.publish("runCardBackground"))
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(DS.Surface.dialog.color))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
        .dsShadow(DS.Shadow.sheet)
        .background(CornerPairStyle.publish("runCard"))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    // MARK: - Failure sheet (design-consistent, not an alert)

    @ViewBuilder private var failureSheet: some View {
        if let failure = model.failure, !model.failureShowsOnButton {   // ★ B1 (O1): engine text is a line on the button, not this card
            ZStack {
                Rectangle().fill(.ultraThinMaterial).overlay(DS.Color.scrim.color)
                    .ignoresSafeArea()
                    .onTapGesture { model.dismissFailure() }

                GlassSheet {
                    VStack(spacing: DS.Space.m) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(DS.Color.danger.color)
                            .padding(.bottom, DS.Space.xs)

                        Text(failure.title)
                            .dsStyle(DS.TypeScale.title)
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .multilineTextAlignment(.center)

                        let blocks = model.outcome?.reportJSON.flatMap(RunReportBlocks.decode(reportJSON:))   // Flexible (PR #362) H56h: redesign to strengthen (overnight plan 2026-10-25)
                        if blocks?.strengthen == nil {   // Flexible (PR #362) H56h: redesign to strengthen (overnight plan 2026-10-25) — a strengthen run's cards say what failed (the margin line would read 0.00×)
                        Text(failure.message)
                            .dsStyle(DS.TypeScale.body)
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        }   // Flexible (PR #362) H56h: redesign to strengthen (overnight plan 2026-10-25) — (the margin line)
                        if let blocks { RunReportCardsView(blocks: blocks) }   // Flexible (PR #362) H56h: redesign to strengthen (overnight plan 2026-10-25) — the versions' cards + item 47's line

                        HStack(spacing: DS.Space.m) {
                            PillButton("Close", style: .secondary) { model.dismissFailure() }
                            // A stall didn't cancel the background solve — offer to let
                            // it keep running (an honest guard admits its own timeout).
                            if model.canKeepWaiting {
                                PillButton("Keep waiting", style: .secondary) { model.keepWaiting() }
                            }
                            PillButton("Try Again") { model.dismissFailure(); onRetry() }
                        }
                        .padding(.top, DS.Space.s)
                    }
                    .padding(DS.Space.xl2)
                    .frame(width: 440)
                }
                .background(CornerPairStyle.publish("runFailureSheet"))   // B1: hosted tests see whether a card is up
                .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
    }
}

#Preview("Run — running") {
    let m = RunModel(scheduler: SynchronousRunScheduler())
    return ZStack {
        DS.Color.background.color.ignoresSafeArea()
        RunScreen(model: m, materialName: "PLA", resolution: 64)
    }
    .preferredColorScheme(.dark)
}

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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(model: RunModel, materialName: String, resolution: Int,
                onRetry: @escaping () -> Void = {}) {
        self.model = model
        self.materialName = materialName
        self.resolution = resolution
        self.onRetry = onRetry
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
        VStack {
            Button { model.restore() } label: {
                HStack(spacing: DS.Space.sm) {
                    RunProgressReadout(model: model, resolution: resolution,
                                       materialName: materialName, compact: true)
                    Text("Tap to view")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .padding(.vertical, DS.Space.sm)
                .padding(.horizontal, DS.Space.l)
                .background(Capsule().fill(DS.Surface.sheet.color))
                .overlay(Capsule().strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1))
                .dsShadow(.panel)
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Space.xl3)   // align with the top chrome (nav) row
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Running card (design RUNNING)

    private var runningCard: some View {
        ZStack {
            // A light dimming so the card reads over the 3D stage without hiding it.
            Rectangle().fill(.ultraThinMaterial).opacity(0.15).ignoresSafeArea()

            GlassSheet {
             VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Optimizing")
                    .dsStyle(DS.TypeScale.overline)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Color.accent.color)
                    .opacity(pulse ? 1 : 0.65)

                // The honest, live readout: variant N of M, current SIMP iteration,
                // elapsed clock, and a LABELLED est.-remaining (once one variant has
                // completed). No fabricated percentage — handoff 086 made rung
                // termination adaptive, so an in-advance progress bar would lie.
                RunProgressReadout(model: model, resolution: resolution, materialName: materialName)

                HStack(spacing: DS.Space.m) {
                    PillButton("Cancel", style: .secondary) { model.cancel() }
                    PillButton(model.runningInBackground ? "In Background" : "Run in Background",
                               style: .secondary,
                               isEnabled: !model.runningInBackground) { model.runInBackground() }
                }
                .padding(.top, DS.Space.s)
                .frame(maxWidth: .infinity)
             }
             .padding(.horizontal, DS.Space.xl3)
             .padding(.vertical, DS.Space.xl2)
             .frame(width: 430)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    // MARK: - Failure sheet (design-consistent, not an alert)

    @ViewBuilder private var failureSheet: some View {
        if let failure = model.failure {
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

                        Text(failure.message)
                            .dsStyle(DS.TypeScale.body)
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: DS.Space.m) {
                            PillButton("Close", style: .secondary) { model.dismissFailure() }
                            PillButton("Try Again") { model.dismissFailure(); onRetry() }
                        }
                        .padding(.top, DS.Space.s)
                    }
                    .padding(DS.Space.xl2)
                    .frame(width: 440)
                }
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

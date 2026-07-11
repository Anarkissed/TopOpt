// ResultsScreen.swift — the M7.8 results overlay: the design's RESULTS chrome
// (savings tabs, stress toggle, recommended-orientation sheet, morph scrub) drawn
// over the 3D stage. Matches the RESULTS section of docs/design/TopOpt.dc.html,
// except print time is omitted (DECISIONS.md 2026-07-11 chose (b)).
//
// Thin SwiftUI over the headlessly-tested ResultsModel — all savings/orientation/
// shear/stress logic lives there. Pixels are maintainer device QA (the M7 /app/
// standard). The stress vertex-coloring + threshold-morph *rendering* in the Metal
// viewer, and swapping the stage to the variant mesh, are a separate follow-up;
// here the scrub + stress toggle drive ResultsModel state and the chrome.

import SwiftUI
import TopOptDesign
import TopOptKit

public struct ResultsScreen: View {
    @StateObject private var model: ResultsModel
    /// The current (growing) outcome — new variants stream in during the run; when
    /// its variant count changes, the model merges it (progressive results).
    let liveOutcome: OptimizeOutcome
    /// Whether the optimize is still running behind the results (more variants may
    /// arrive) — drives an "optimizing more…" indicator.
    let streaming: Bool
    /// Back to Home (KEEPS the variants on the project so reopening shows them).
    var onClose: () -> Void
    /// Export (.3mf) — M7.9. Passed in so the button exists per the design now;
    /// the workspace wires the real export sheet in M7.9.
    var onExport: () -> Void
    /// "See Original Model" — reveal the editable workspace (the variants stay
    /// saved; re-optimizing there starts over).
    var onSeeOriginal: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orientOpen = false
    /// Drives the Play animation: a ~30 fps tick that advances the morph scrub while
    /// `model.playing`, so Play actually plays (previously it required a manual drag).
    @State private var ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    private static let morphDuration: Double = 6   // design `dur = 6`s

    public init(projectName: String, outcome: OptimizeOutcome, streaming: Bool = false,
                onClose: @escaping () -> Void = {}, onExport: @escaping () -> Void = {},
                onSeeOriginal: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: ResultsModel(projectName: projectName, outcome: outcome))
        self.liveOutcome = outcome
        self.streaming = streaming
        self.onClose = onClose
        self.onExport = onExport
        self.onSeeOriginal = onSeeOriginal
    }

    public var body: some View {
        ZStack {
            // The variant stage: its own viewer (opaque over the workspace) showing
            // the selected variant's isosurface, optionally stress-colored, morphing
            // with the scrub. Pixels are device QA (the M7 /app/ standard).
            DS.Color.background.color.ignoresSafeArea()
            MetalMeshView(mesh: viewerMesh,
                          stressTints: stressTints,
                          reveal: viewerReveal)
                .ignoresSafeArea()

            topLeft
            topRight
            savingsTabs
            mediaPlayer
            orientationCorner
            streamingChip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .animation(DS.Motion.sheetIn, value: orientOpen)
        .onReceive(ticker) { _ in
            guard model.playing else { return }
            model.advance((1.0 / 30.0) / Self.morphDuration)
        }
        .onChange(of: liveOutcome.variants.count) { _ in
            // A variant streamed in (or the final outcome landed) — merge it.
            model.update(from: liveOutcome)
        }
    }

    /// A top-center "optimizing more…" pill while later variants are still running.
    @ViewBuilder private var streamingChip: some View {
        if streaming {
            VStack {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small).tint(DS.Color.accent.color)
                    Text("Optimizing more variants…").dsStyle(DS.TypeScale.caption)
                        .fontWeight(.semibold).foregroundStyle(DS.Color.textSecondary.color)
                }
                .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.l)
                .background(Capsule().fill(DS.Surface.bar.color)
                    .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
                .padding(.top, DS.Space.xl3)
                Spacer()
            }
        }
    }

    /// Per-flat-vertex stress colors for the selected variant, or nil when the
    /// overlay is off / the variant has no field. NOTE (device-QA perf follow-up):
    /// recomputed on each body eval while the overlay is on; memoize on
    /// `selectedIndex` if a scrub-with-stress hitch shows up on device.
    private var stressTints: [SIMD4<Float>]? {
        guard model.stressOn, let mesh = model.selectedMesh,
              let field = model.selectedStressField, !field.isEmpty else { return nil }
        return model.stressTints(for: mesh, field: field)
    }

    /// The mesh the viewer shows. When the variant has an optimization history and
    /// stress is off, Play scrubs THROUGH the history keyframes (the real "watch it
    /// carve out"); otherwise it's the final mesh (stress overlay, or the
    /// reveal-scrub fallback for meshes without history).
    private var showHistory: Bool { !model.stressOn && model.hasHistory }
    private var viewerMesh: ViewerMesh? { showHistory ? model.playbackMesh : model.selectedMesh }
    private var viewerReveal: Float { showHistory ? 1 : Float(model.playT) }

    // MARK: - Top-left: back + project / Optimized ✓

    private var topLeft: some View {
        VStack {
            HStack(spacing: DS.Space.m) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(DS.Surface.bar.color)
                            .overlay(Circle().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
                }
                .buttonStyle(.plain)

                HStack(spacing: DS.Space.sm) {
                    Text(model.projectName).dsStyle(DS.TypeScale.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary.color)
                    Rectangle().fill(DS.Color.textPrimary.opacity(0.15).color).frame(width: 1, height: 14)
                    Text("Optimized ✓").dsStyle(DS.TypeScale.callout)
                        .foregroundStyle(DS.Color.okGreen.color)
                }
                .padding(.vertical, DS.Space.sm)
                .padding(.horizontal, DS.Space.l)
                .background(Capsule().fill(DS.Surface.bar.color)
                    .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))

                Button(action: onSeeOriginal) {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "cube.transparent").font(.system(size: 12, weight: .semibold))
                        Text("See Original").dsStyle(DS.TypeScale.callout)
                    }
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.l)
                    .background(Capsule().fill(DS.Surface.bar.color)
                        .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Spacer()
        }
        .padding(DS.Space.xl3)
    }

    // MARK: - Top-right: Stress toggle + Export

    private var topRight: some View {
        VStack {
            HStack(spacing: DS.Space.sm) {
                Spacer()
                Button { model.toggleStress() } label: {
                    HStack(spacing: DS.Space.s) {
                        Circle()
                            .fill(AngularGradient(colors: [
                                RGBA(28, 60, 170).color, RGBA(0, 170, 220).color, RGBA(60, 190, 110).color,
                                RGBA(250, 220, 60).color, RGBA(255, 70, 50).color, RGBA(28, 60, 170).color,
                            ], center: .center))
                            .frame(width: 12, height: 12)
                        Text("Stress").dsStyle(DS.TypeScale.callout)
                            .foregroundStyle(DS.Color.textPrimary.color)
                    }
                    .padding(.vertical, DS.Space.sm)
                    .padding(.horizontal, DS.Space.l)
                    .background(Capsule().fill(model.stressOn ? DS.Color.accent.opacity(0.22).color : DS.Surface.bar.color)
                        .overlay(Capsule().strokeBorder(model.stressOn ? DS.Color.accent.opacity(0.6).color : DS.Color.strokePanel.color, lineWidth: 1)))
                }
                .buttonStyle(.plain)

                Button(action: onExport) {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .semibold))
                        Text("Export .3mf").dsStyle(DS.TypeScale.bodyStrong)
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, DS.Space.m)
                    .padding(.horizontal, DS.Space.xl4)
                    .background(Capsule().fill(DS.Color.accent.color))
                    .dsShadow(.accentGlow)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(DS.Space.xl3)
    }

    // MARK: - Bottom-left: savings tabs

    private var savingsTabs: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: DS.Space.s) {
                ForEach(model.tabs, id: \.index) { tab in
                    let active = tab.index == model.selectedIndex
                    Button { model.select(tab.index) } label: {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            if tab.isRecommended {
                                Text("RECOMMENDED")
                                    .font(.system(size: 9, weight: .bold)).tracking(0.6)
                                    .foregroundStyle(DS.Color.okGreen.color)
                            }
                            Text(tab.savingsLabel)
                                .font(.system(size: active ? 20 : 16, weight: .heavy))
                                .foregroundStyle(active ? DS.Color.accent.color : DS.Color.textPrimary.opacity(0.85).color)
                            Text(tab.subLabel(active: active))
                                .dsStyle(DS.TypeScale.footnote)
                                .foregroundStyle(DS.Color.textSecondary.color)
                        }
                        .padding(.vertical, active ? DS.Space.ml : DS.Space.m)
                        .padding(.horizontal, active ? DS.Space.xl3 : DS.Space.xl)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                            .fill(active ? RGBA(24, 28, 40, 0.75).color : RGBA(24, 24, 30, 0.55).color)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                                .strokeBorder(active ? DS.Color.accent.opacity(0.53).color : DS.Color.strokePanel.color, lineWidth: 1)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(DS.Space.xl4)
    }

    // MARK: - Bottom-center: morph media player

    private var mediaPlayer: some View {
        VStack {
            Spacer()
            HStack(spacing: DS.Space.sm) {
                Button {
                    if reduceMotion { model.scrub(to: 1) }   // snap to the formed shape
                    else { model.togglePlay() }
                } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Color.background.color)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.white))
                }
                .buttonStyle(.plain)

                Slider(value: Binding(get: { model.playT }, set: { model.scrub(to: $0) }), in: 0...1)
                    .frame(width: 150)
                    .tint(DS.Color.accent.color)

                Text(String(format: "0:0%d", min(9, Int((model.playT * 6).rounded(.down)))))
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .monospacedDigit()
                    .frame(width: 34)
            }
            .padding(.vertical, DS.Space.xs)
            .padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(.panel)
            .padding(.bottom, DS.Space.xl6)
        }
    }

    // MARK: - Bottom-right: orientation cube + sheet

    private var orientationCorner: some View {
        VStack(alignment: .trailing) {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: DS.Space.m) {
                    if orientOpen, let v = model.selected { orientationSheet(v) }
                    Button { orientOpen.toggle() } label: {
                        Image(systemName: "cube")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .frame(width: 50, height: 50)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                                .fill(orientOpen ? DS.Color.accent.opacity(0.22).color : DS.Surface.bar.color)
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                                    .strokeBorder(orientOpen ? DS.Color.accent.opacity(0.6).color : DS.Color.strokePanel.color, lineWidth: 1)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(DS.Space.xl4)
    }

    private func orientationSheet(_ v: ResultVariantVM) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recommended orientation").dsStyle(DS.TypeScale.headline)
                .foregroundStyle(DS.Color.textPrimary.color)
            Text(v.orientationSummary)
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.xs)

            Divider().overlay(DS.Color.strokeSubtle.color).padding(.vertical, DS.Space.m)

            // Layer shear only — print time omitted (DECISIONS 2026-07-11 (b)).
            VStack(alignment: .leading, spacing: 1) {
                Text("Layer shear").dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                Text(v.layerShear.isLow ? "\(v.layerShear.label) ✓" : v.layerShear.label)
                    .dsStyle(DS.TypeScale.callout)
                    .foregroundStyle(v.layerShear.isLow ? DS.Color.okGreen.color : DS.Color.textPrimary.color)
            }

            // M5.2b advisory (handoff 044): surface the min-feature warning if any.
            if v.minFeatureViolations > 0 {
                Text(v.minFeatureWarning)
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Space.m)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(.panel)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

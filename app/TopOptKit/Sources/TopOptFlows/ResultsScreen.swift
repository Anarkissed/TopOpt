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
#if canImport(UIKit)
import UIKit
#endif

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
    /// The latest camera→screen projection the viewer publishes, so the hot-spot
    /// marker (M7.viz.2) tracks the worst point as the camera orbits/zooms.
    @State private var projection: CameraProjection?
    /// Whether the hot-spot marker's value/margin callout is expanded (tap to toggle).
    @State private var hotSpotExpanded = false
    @StateObject private var videoExport = VideoExportModel()
    /// Drives the Play animation: a ~30 fps tick that advances the morph scrub while
    /// `model.playing`, so Play actually plays (previously it required a manual drag).
    @State private var ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    private static let morphDuration: Double = 6   // design `dur = 6`s
    private static let flexDuration: Double = 2.5  // one rest→full→rest wobble (s)

    public init(projectName: String, outcome: OptimizeOutcome,
                materialName: String = "", yieldStrengthMPa: Double = 0,
                appliedLoadKg: Double = 0, loadUnit: WeightUnit = .kg,
                infillPercent: Int = 100, infillPattern: String = "gyroid",
                loadLocations: [SIMD3<Float>] = [],
                loadDirections: [SIMD3<Float>] = [], anchorPoints: [SIMD3<Float>] = [],
                streaming: Bool = false,
                onClose: @escaping () -> Void = {}, onExport: @escaping () -> Void = {},
                onSeeOriginal: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: ResultsModel(
            projectName: projectName, outcome: outcome,
            materialName: materialName, yieldStrengthMPa: yieldStrengthMPa,
            appliedLoadKg: appliedLoadKg, loadUnit: loadUnit,
            infillPercent: infillPercent, infillPattern: infillPattern,
            loadLocations: loadLocations,
            loadDirections: loadDirections, anchorPoints: anchorPoints))
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
                          onProjection: { projection = $0 },
                          stressTints: stressTints,
                          stressMultiplier: Float(stressMultiplier),
                          reveal: viewerReveal,
                          flexDisplacements: flexDisplacements,
                          flexScale: flexScale,
                          loadFlowVertices: loadFlowVertices,
                          loadFlowKey: loadFlowKey,
                          loadFlowGuides: loadFlowGuides,
                          bodyAlpha: bodyAlpha)
                .ignoresSafeArea()

            topBar
            // The viz toggles (Stress / Flex / Load path / Failure) and their
            // now-compact controls cluster at the BOTTOM-RIGHT; each chip slides its own
            // drawer open to the LEFT rather than dropping a big panel over the model.
            // The cluster sits just above the orientation cube (see `cubeClearance`).
            vizRail
            hotSpotMarker.ignoresSafeArea()           // M7.viz.2: worst-point callout
            failureMarker.ignoresSafeArea()           // M7.viz.6: failure-point marker
            savingsTabs
            mediaPlayer
            orientationCorner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .animation(DS.Motion.sheetIn, value: orientOpen)
        .onReceive(ticker) { _ in
            if model.playing { model.advance((1.0 / 30.0) / Self.morphDuration) }
            // M7.viz.3: loop the flex while it's on — UNLESS reduced-motion, which
            // holds the static full-deflection frame (no advance → phase stays put,
            // and flexScale uses amplitude 1).
            if model.flexOn && !reduceMotion {
                model.advanceFlex((1.0 / 30.0) / Self.flexDuration)
            }
            // Handoff 070 flow: advance the comet clock while the overlay is on — UNLESS
            // reduced-motion (system OR the drawer toggle), which freezes the arrows
            // mid-path with clean heads (no advance → the static presentation).
            if model.loadPathOn && !model.flowReduced(reduceMotion: reduceMotion) {
                model.advanceFlowClock(1.0 / 30.0)
            }
        }
        .onChange(of: liveOutcome.variants.count) { _ in
            // A variant streamed in (or the final outcome landed) — merge it.
            model.update(from: liveOutcome)
        }
        .sheet(isPresented: Binding(
            get: { if case .ready = videoExport.state { return true } else { return false } },
            set: { if !$0 { videoExport.reset() } })) {
            if case let .ready(url) = videoExport.state { ShareSheet(items: [url]) }
        }
        .alert("Couldn’t save video", isPresented: Binding(
            get: { if case .failed = videoExport.state { return true } else { return false } },
            set: { if !$0 { videoExport.reset() } })) {
            Button("OK") { videoExport.reset() }
        } message: {
            if case let .failed(msg) = videoExport.state { Text(msg) }
        }
    }

    /// An "optimizing more…" pill shown just above the savings tabs (bottom-left),
    /// so a newly-arriving variant appears right next to it.
    @ViewBuilder private var streamingChip: some View {
        if streaming {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small).tint(DS.Color.accent.color)
                Text("Optimizing more variants…").dsStyle(DS.TypeScale.footnote)
                    .fontWeight(.semibold).foregroundStyle(DS.Color.textSecondary.color)
            }
            .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
    }

    /// Per-flat-vertex stress colors for the selected variant, or nil when the
    /// overlay is off / the variant has no field. NOTE (device-QA perf follow-up):
    /// recomputed on each body eval while the overlay is on; memoize on
    /// `selectedIndex` if a scrub-with-stress hitch shows up on device.
    private var stressTints: [SIMD4<Float>]? {
        // In load-path FLOW mode the flow's Body segment owns the body appearance: the
        // "Stress" body paints the static field with the MOVING epicenters blended in
        // (a bloom following each arrow); x-ray / solid paint plain clay (nil tints).
        if loadPathActive {
            guard model.flowBodyMode == .stress, let mesh = viewerMesh,
                  let field = model.selectedStressField, !field.isEmpty else { return nil }
            let heads = model.flowHeadPositions(reduceMotion: reduceMotion)
            return model.flowStressTints(for: mesh, field: field, heads: heads)
        }
        guard showStressColors, let mesh = viewerMesh,
              let field = model.selectedStressField, !field.isEmpty else { return nil }
        return model.stressTints(for: mesh, field: field, multiplier: stressMultiplier)
    }

    /// Whether the body is stress-colored right now: when the Stress chip is on, OR
    /// when a deflection is animating (flex loop / failure push) so the part visibly
    /// flushes blue→red as it moves (M7.viz coupling). Sampled against `viewerMesh`,
    /// so during the history morph it colors whichever keyframe is on screen.
    private var showStressColors: Bool { model.stressOn || deflectionActive }

    /// The load multiple the stress field is colored at this frame (1× at rest, the
    /// flex amplitude while wobbling, the push scrub while driving to failure). Passed
    /// to the viewer so it re-uploads the recolored tints as the multiplier moves.
    private var stressMultiplier: Double { model.stressColorMultiplier(reduceMotion: reduceMotion) }

    /// The mesh the viewer shows. When the variant has an optimization history and
    /// stress is off, Play scrubs THROUGH the history keyframes (the real "watch it
    /// carve out"); otherwise it's the final mesh (stress overlay, or the
    /// reveal-scrub fallback for meshes without history).
    /// M7.viz.3 flex is live only when toggled on AND the variant has a displacement
    /// field. While flexing, the stage shows the final variant mesh (not the history
    /// morph) fully formed, wobbling by the displacement.
    private var flexActive: Bool { model.flexOn && model.hasFlex }
    /// M7.viz.4 load-path is live only when toggled on AND the variant has a
    /// displacement field to derive principal directions from. Like flex, it shows
    /// the final mesh fully formed (not the history morph).
    private var loadPathActive: Bool { model.loadPathOn && model.hasLoadPath }
    /// M7.viz.6 "push" scrub: drives the flex deflection at a load-proportional scale.
    /// Only live when the failure surface is on AND the variant has a displacement
    /// field (else the feature degrades to just the number + marker — no scrub).
    private var pushActive: Bool { model.pushActive }
    /// Either flex mechanism displaces the mesh via the same render path (per-vertex
    /// displacement × scale): the viz.3 wobble or the viz.6 push scrub.
    private var deflectionActive: Bool { flexActive || pushActive }
    /// Whether Play morphs THROUGH the optimization history (the "watch it carve out")
    /// rather than the reveal-slice fallback. `stressOn` is deliberately NOT a factor
    /// (see `ResultsModel.showsHistoryMorph`): the Stress chip used to fall through to
    /// the slice viewer here, so Play with Stress on sliced instead of morphing. The
    /// morph and the stress overlay now coexist — the tints sample the live keyframe.
    private var showHistory: Bool {
        ResultsModel.showsHistoryMorph(hasHistory: model.hasHistory,
                                       deflectionActive: deflectionActive,
                                       loadPathActive: loadPathActive)
    }
    private var viewerMesh: ViewerMesh? { showHistory ? model.playbackMesh : model.selectedMesh }
    private var viewerReveal: Float { (showHistory || deflectionActive || loadPathActive) ? 1 : Float(model.playT) }

    // MARK: - Load-path FLOW geometry (handoff 070 → Metal)

    /// The comet-arrow tube geometry for THIS frame — the model's comet frames (one per
    /// visible path, animated at the flow clock) extruded to GPU vertices. nil when the
    /// overlay is off / the variant has no curves. Recomputed each tick (that is the
    /// animation); the coordinator re-uploads it every frame.
    private var loadFlowVertices: [Float]? {
        guard loadPathActive else { return nil }
        let frames = model.flowCometFrames(reduceMotion: reduceMotion)
        guard !frames.isEmpty else { return nil }
        var out: [Float] = []
        for f in frames { out.append(contentsOf: CometMesh.build(f)) }
        return out.isEmpty ? nil : out
    }

    /// A per-frame key so the coordinator knows the comet geometry changed (the flow
    /// clock, plus a discriminator for paused param changes).
    private var loadFlowKey: Double { model.flowClock }

    /// The faint full-path guide routes (pos+rgba line list, stride 7), so a path reads
    /// even when its arrow is elsewhere on it. The isolated path is brighter; when all
    /// paths show, every guide is equally faint. nil when the overlay is off.
    private var loadFlowGuides: [Float]? {
        guard loadPathActive else { return nil }
        let polys = model.flowGuidePolylines()
        guard !polys.isEmpty else { return nil }
        let isolate = model.flowIsolate
        let c = ResultsModel.flowColor
        var out: [Float] = []
        for (i, poly) in polys.enumerated() where poly.count >= 2 {
            let a: Float = isolate == nil ? 0.16 : (isolate == i ? 0.55 : 0.05)
            for k in 0..<(poly.count - 1) {
                appendGuideVertex(&out, poly[k], c, a)
                appendGuideVertex(&out, poly[k + 1], c, a)
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Append one guide-line vertex: position + PREMULTIPLIED rgba (the comet pipeline
    /// blends additive, so the emissive contribution is `rgb·a`).
    private func appendGuideVertex(_ out: inout [Float], _ p: SIMD3<Float>,
                                   _ c: SIMD3<Float>, _ a: Float) {
        out.append(p.x); out.append(p.y); out.append(p.z)
        out.append(c.x * a); out.append(c.y * a); out.append(c.z * a); out.append(a)
    }

    /// The body opacity for the current flow body mode (x-ray/stress translucent,
    /// solid opaque); 1 when the overlay is off (the normal opaque draw).
    private var bodyAlpha: Float { loadPathActive ? model.flowBodyMode.bodyAlpha : 1 }

    /// Per-flat-vertex flex displacement for the selected variant (nil when flex is
    /// off / the variant has no field). Cached in the model, so this is cheap.
    private var flexDisplacements: [Float]? {
        guard deflectionActive, let mesh = model.selectedMesh,
              let field = model.selectedDisplacementField, !field.isEmpty else { return nil }
        return model.flexDisplacements(for: mesh, field: field)
    }
    /// The per-frame displacement scale. For the viz.3 wobble it is exaggeration·
    /// amplitude (reduced-motion pins amplitude at 1); for the viz.6 push scrub it is
    /// the load-proportional push exaggeration (a static scrub — no loop).
    private var flexScale: Float {
        if pushActive { return model.pushFlexScale() }
        return flexActive ? model.flexScale(reduceMotion: reduceMotion) : 0
    }

    // MARK: - Stress legend (M7.viz.1 — scaled to material yield)

    /// The Stress chip's drawer: the heatmap legend — names the material and the
    /// yield the scale is keyed to, with the color ramp bar. Green (comfortably below
    /// yield) → red (at/above yield). Slides open beside the Stress chip on the right
    /// rail. Pixels are device QA (the M7 /app/ standard); the copy is headlessly
    /// tested on the model.
    @ViewBuilder private var stressDrawer: some View {
        let legend = model.stressLegend
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(legend.caption)
                .dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                .foregroundStyle(DS.Color.textPrimary.color)
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: Self.rampColors, startPoint: .leading, endPoint: .trailing))
                .frame(width: Self.drawerWidth, height: 7)
            HStack {
                Text(legend.minLabel).dsStyle(DS.TypeScale.caption)
                Spacer()
                Text(legend.maxLabel).dsStyle(DS.TypeScale.caption)
            }
            .foregroundStyle(DS.Color.textSecondary.color)
            .frame(width: Self.drawerWidth)
        }
        .resultsDrawerChrome(width: Self.drawerWidth)
    }

    /// The stress ramp's five design stops as SwiftUI colors — the same
    /// blue→cyan→green→yellow→red gradient ResultsModel.stressColor interpolates.
    private static let rampColors: [Color] = [
        RGBA(28, 60, 170).color, RGBA(0, 170, 220).color, RGBA(60, 190, 110).color,
        RGBA(250, 220, 60).color, RGBA(255, 70, 50).color,
    ]

    // MARK: - Flex control (M7.viz.3 — deflection animation)

    /// The Flex chip's drawer: the exaggeration slider for the flex animation
    /// (50–100×). Under reduced-motion the copy says a static full-deflection frame is
    /// shown, not a loop. Slides open beside the Flex chip on the right rail. Pixels
    /// are device QA (the M7 /app/ standard); the exaggeration math + reduced-motion
    /// path are tested on the model.
    @ViewBuilder private var flexDrawer: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.m) {
                Text("Deflection").dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                Text("\(Int(model.flexExaggeration))×").dsStyle(DS.TypeScale.footnote)
                    .fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(DS.Color.accent.color)
            }
            Slider(value: Binding(get: { model.flexExaggeration },
                                  set: { model.setFlexExaggeration($0) }),
                   in: FlexAnimation.minExaggeration...FlexAnimation.maxExaggeration)
                .frame(width: Self.drawerWidth)
                .tint(DS.Color.accent.color)
            Text(reduceMotion
                 ? "Reduced motion — full deflection"
                 : "Exaggerated \(Int(model.flexExaggeration))× — not to scale")
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textSecondary.color)
                .frame(width: Self.drawerWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .resultsDrawerChrome(width: Self.drawerWidth)
    }

    // MARK: - Load-path legend (M7.viz.4 — principal-stress-direction key)

    /// The compact-drawer content width for the load-path FLOW controls — a touch wider
    /// than the other drawers so the segmented controls read, still slim.
    private static let flowDrawerWidth: CGFloat = 188

    /// The Load-path chip's drawer (handoff 070 redesign): the "alive" flow's compact
    /// controls — motion style, isolate-a-path, body mode, flow speed, wiggle, and a
    /// reduced-motion (static) toggle. Matches the prototype's Tune panel control set,
    /// squeezed into the existing right-rail chip drawer (not a big floating panel).
    /// Placement/pixels are device QA; the underlying state + curve math are headless.
    @ViewBuilder private var loadPathDrawer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Load-path flow").dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                .foregroundStyle(DS.Color.textPrimary.color)

            // Mode selector (M7.viz.5): swap which family of curves the SAME comet
            // animation rides — LOAD → hot-spot (the stress field) vs LOAD → anchor (the
            // route to ground). Shown only when the anchor route is available (a tensor
            // field + tagged loads + tagged anchors); otherwise the flow stays the
            // stress-point mode with no toggle.
            if model.hasAnchorFlow {
                drawerLabel("Mode")
                SegmentedGlass(FlowPathMode.allCases.map { .init($0, $0.title) },
                               selection: Binding(get: { model.flowMode },
                                                  set: { model.setFlowMode($0) }))
            }
            // The caption is honest per mode: it depicts a PATH, not a claim force moves
            // in time — the literal Stress chip stays the truthful static readout.
            Text(model.flowMode.caption)
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)

            drawerLabel("Motion")
            SegmentedGlass(FlowMotionStyle.allCases.map { .init($0, $0.title) },
                           selection: $model.flowStyle)

            if model.flowCurveCount > 1 {
                drawerLabel("Isolate a path")
                isolatePicker
            }

            drawerLabel("Body")
            SegmentedGlass(FlowBodyMode.allCases.map { .init($0, $0.title) },
                           selection: $model.flowBodyMode)

            drawerLabel("Flow speed")
            HStack(spacing: DS.Space.s) {
                Slider(value: Binding(get: { model.flowSpeed }, set: { model.setFlowSpeed($0) }),
                       in: 0.2...2.5).tint(RGBA(255, 90, 72).color)
                Text(String(format: "%.1f×", model.flowSpeed)).dsStyle(DS.TypeScale.caption)
                    .monospacedDigit().foregroundStyle(DS.Color.textSecondary.color)
                    .frame(width: 30, alignment: .trailing)
            }

            drawerLabel("Wiggle")
            HStack(spacing: DS.Space.s) {
                Slider(value: Binding(get: { model.flowWiggle }, set: { model.setFlowWiggle($0) }),
                       in: 0...2).tint(RGBA(255, 90, 72).color)
                Text(String(format: "%.1f×", model.flowWiggle)).dsStyle(DS.TypeScale.caption)
                    .monospacedDigit().foregroundStyle(DS.Color.textSecondary.color)
                    .frame(width: 30, alignment: .trailing)
            }

            Toggle(isOn: $model.flowReducedStatic) {
                Text("Reduced motion (static)").dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
            }
            .toggleStyle(SwitchToggleStyle(tint: RGBA(255, 90, 72).color))
            .padding(.top, DS.Space.xxs)
        }
        .resultsDrawerChrome(width: Self.flowDrawerWidth)
    }

    /// A small uppercase section label inside the flow drawer (prototype `label.h`).
    private func drawerLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold)).tracking(0.6)
            .foregroundStyle(DS.Color.textTertiary.color)
            .padding(.top, DS.Space.xxs)
    }

    /// The isolate-a-path menu: "All paths" or a single path (index into the curves).
    private var isolatePicker: some View {
        Menu {
            Button("All paths") { model.flowIsolate = nil }
            ForEach(0..<model.flowCurveCount, id: \.self) { i in
                Button("Path \(i + 1)") { model.flowIsolate = i }
            }
        } label: {
            HStack {
                Text(model.flowIsolate.map { "Path \($0 + 1)" } ?? "All paths")
                    .dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                .fill(.black.opacity(0.30))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Hot-spot callout (M7.viz.2 — the single worst-stress point)

    /// A tappable marker framing the highest-stress point on the displayed variant,
    /// with its value + margin (value ÷ yield) so the user is not left hunting the
    /// red zone. Shown only while the stress overlay is on and the point projects in
    /// front of the camera. The located point + value/margin are headlessly tested on
    /// ResultsModel; the marker's placement/look is device QA (the M7 /app/ standard).
    @ViewBuilder private var hotSpotMarker: some View {
        // When the failure surface is on, its marker sits at this same point (the
        // failure location IS the hot spot), so defer to it to avoid a double marker.
        if model.stressOn, !model.failureOn, let hs = model.hotSpot, let p = projection?.project(hs.position) {
            let overYield = hs.yieldStrengthMPa > 0 && hs.margin >= 1
            let tint = overYield ? RGBA(255, 70, 50).color : DS.Color.textPrimary.color
            ZStack {
                Button { hotSpotExpanded.toggle() } label: {
                    Circle()
                        .strokeBorder(tint, lineWidth: 2)
                        .background(Circle().fill(tint.opacity(0.18)))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)

                if hotSpotExpanded {
                    hotSpotCallout(hs, tint: tint)
                        .fixedSize()
                        .offset(y: -48)   // float the readout above the marker
                }
            }
            .position(p)
        }
    }

    /// The hot spot's readout: "Hot spot" · peak value · margin (value ÷ yield).
    private func hotSpotCallout(_ hs: HotSpot, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("HOT SPOT").font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundStyle(DS.Color.textSecondary.color)
            Text(hs.valueLabel).dsStyle(DS.TypeScale.bodyStrong)
                .foregroundStyle(DS.Color.textPrimary.color)
            Text(hs.marginLabel).dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                .foregroundStyle(tint)
        }
        .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(.panel)
    }

    // MARK: - Failure-load prediction (M7.viz.6 — "push it till it breaks")

    private static let failureRed = RGBA(255, 70, 50).color

    /// The Failure chip's drawer: the ONE honest failure load for this project's fixed
    /// infill (M7.params infill-aware) in the user's units, the honesty caption, and —
    /// when the variant has a displacement field — the "push" scrub (1× → the failure
    /// multiple) that drives the deflection toward failure. Slides open beside the
    /// Failure chip on the right rail. All values are headlessly tested on ResultsModel;
    /// layout is device QA.
    @ViewBuilder private var failureDrawer: some View {
        if let fp = model.failurePrediction {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("FAILURE LOAD").font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(DS.Color.textSecondary.color)
                Text(fp.headline).dsStyle(DS.TypeScale.bodyStrong)
                    .foregroundStyle(model.atFailure ? Self.failureRed : DS.Color.textPrimary.color)
                    .frame(width: Self.drawerWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(fp.subtitle)
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .frame(width: Self.drawerWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if model.hasFlex { pushControl(fp) }
            }
            .resultsDrawerChrome(width: Self.drawerWidth)
        }
    }

    /// The push scrub: drag 1× (current load) → the failure multiple to drive the part
    /// visibly toward failure. At/above the multiple the copy flips to "Yields here".
    private func pushControl(_ fp: FailurePrediction) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                Text("Push").dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                Text(String(format: "%.1f×", model.pushFactor)).dsStyle(DS.TypeScale.footnote)
                    .fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(model.atFailure ? Self.failureRed : DS.Color.accent.color)
            }
            Slider(value: Binding(get: { model.pushFactor }, set: { model.setPush(factor: $0) }),
                   in: 1...max(1.0001, fp.multiplier))
                .frame(width: Self.drawerWidth)
                .tint(model.atFailure ? Self.failureRed : DS.Color.accent.color)
            // Reads naturally as the user drags: the live load in their units + the
            // current multiple, ramping "1180 lb · 1.4× load" → "1915 lb · 3.0× · YIELDS".
            Text(model.pushReadout(prediction: fp))
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(model.atFailure ? Self.failureRed : DS.Color.textSecondary.color)
                .frame(width: Self.drawerWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DS.Space.s)
    }

    /// The failure-point marker: reuses the M7.viz.2 hot-spot marker styling at the
    /// same worst point (the failure location IS the peak-stress point). Turns red with
    /// a "Yields here" callout once the push scrub reaches the failure multiple.
    @ViewBuilder private var failureMarker: some View {
        if model.failureOn, let fp = model.failurePrediction, let p = projection?.project(fp.position) {
            let tint = model.atFailure ? Self.failureRed : DS.Color.accent.color
            ZStack {
                Circle()
                    .strokeBorder(tint, lineWidth: 2)
                    .background(Circle().fill(tint.opacity(model.atFailure ? 0.30 : 0.18)))
                    .frame(width: 26, height: 26)
                failureCallout(fp, tint: tint)
                    .fixedSize()
                    .offset(y: -48)   // float the readout above the marker
            }
            .position(p)
        }
    }

    /// The failure marker's readout: "YIELDS HERE" + the load at which it yields, or —
    /// before failure — the current push load against the failure load.
    private func failureCallout(_ fp: FailurePrediction, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.atFailure ? "YIELDS HERE" : "FAILS AT")
                .font(.system(size: 9, weight: .bold)).tracking(0.6)
                .foregroundStyle(DS.Color.textSecondary.color)
            Text(fp.valueLabel).dsStyle(DS.TypeScale.bodyStrong)
                .foregroundStyle(model.atFailure ? tint : DS.Color.textPrimary.color)
            Text(String(format: "%.1f× the load", fp.multiplier))
                .dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                .foregroundStyle(tint)
        }
        .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(.panel)
    }

    // MARK: - Top bar: back · project / Optimized ✓ · See Original · Export

    /// One flex row across the top: navigation + project on the left, Export on the
    /// right. Keeping every top control in a single HStack (rather than two
    /// independent left/right overlays) means a narrow device compresses the row
    /// instead of letting "See Original" and Export overlap. The secondary viz chips
    /// were pulled OUT of here onto the right rail (`vizRail`), which is what freed the
    /// space. Pixels are device QA (the M7 /app/ standard).
    private var topBar: some View {
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
                        .lineLimit(1)
                    Rectangle().fill(DS.Color.textPrimary.opacity(0.15).color).frame(width: 1, height: 14)
                    Text("Optimized ✓").dsStyle(DS.TypeScale.callout)
                        .foregroundStyle(DS.Color.okGreen.color)
                        .fixedSize()
                }
                .padding(.vertical, DS.Space.sm)
                .padding(.horizontal, DS.Space.l)
                .background(Capsule().fill(DS.Surface.bar.color)
                    .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
                // The project capsule is the one flexible element — under width
                // pressure its name truncates (lineLimit 1) while the fixed-size
                // buttons keep their full width, so nothing overlaps.

                Button(action: onSeeOriginal) {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "cube.transparent").font(.system(size: 12, weight: .semibold))
                        Text("See Original").dsStyle(DS.TypeScale.callout)
                    }
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .fixedSize()
                    .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.l)
                    .background(Capsule().fill(DS.Surface.bar.color)
                        .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
                }
                .buttonStyle(.plain)

                Spacer(minLength: DS.Space.m)

                exportButton
            }
            Spacer()
        }
        .padding(DS.Space.xl3)
    }

    // MARK: - Bottom-right rail: slide-open visualization chips

    /// The compact drawer content width (sliders, ramp, key copy) — the drawers are
    /// deliberately slim so the model viewport stays maximally unobstructed.
    private static let drawerWidth: CGFloat = 150
    /// Bottom inset that lifts the chip cluster clear of the orientation cube, which
    /// occupies the very bottom-right corner (`orientationCorner`): its `xl4` gutter +
    /// the 50pt cube + a gap. Keeps the two right-corner clusters from overlapping.
    private static let cubeClearance: CGFloat = DS.Space.xl4 + 50 + DS.Space.m

    /// A vertical cluster pinned to the BOTTOM-RIGHT, holding the secondary
    /// visualization toggles. Each chip toggles its mode and slides its own compact
    /// drawer open to the LEFT; flex/load-path/failure are mutually exclusive in the
    /// model, so opening one collapses the others (stress can accompany them, as
    /// before — a stress-coloured flex is a real combination). A leading `Spacer` sinks
    /// the chips to the bottom; the bottom inset clears the orientation cube so the two
    /// right-corner clusters never collide. Pixels are device QA.
    private var vizRail: some View {
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            Spacer()
            // Stress — the ramp legend drawer.
            vizRow(open: model.stressOn, drawer: { stressDrawer }, chip: { stressChip })
            // M7.viz.3 Flex — only when the variant carries a displacement field.
            if model.hasFlex {
                vizRow(open: flexActive, drawer: { flexDrawer }, chip: { flexChip })
            }
            // M7.viz.4 Load path — same displacement-field gate as Flex.
            if model.hasLoadPath {
                vizRow(open: loadPathActive, drawer: { loadPathDrawer }, chip: { loadPathChip })
            }
            // M7.viz.6 Failure — only when the variant has an applied load + peak + yield.
            if model.hasFailurePrediction {
                vizRow(open: model.failureOn, drawer: { failureDrawer }, chip: { failureChip })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.horizontal, DS.Space.xl4)   // align the chips' right edge with the cube
        .padding(.bottom, Self.cubeClearance)
        .animation(DS.Motion.sheetIn, value: model.stressOn)
        .animation(DS.Motion.sheetIn, value: model.flexOn)
        .animation(DS.Motion.sheetIn, value: model.loadPathOn)
        .animation(DS.Motion.sheetIn, value: model.failureOn)
    }

    /// One rail row: the chip pinned to the right edge, its drawer sliding out to the
    /// left when `open`. The leading spacer keeps the chip flush-right and lets the
    /// drawer float over the model rather than pushing the chip around.
    private func vizRow<Drawer: View, Chip: View>(
        open: Bool, @ViewBuilder drawer: () -> Drawer, @ViewBuilder chip: () -> Chip) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Spacer(minLength: 0)
            if open {
                drawer()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            chip()
        }
    }

    /// A rail toggle chip — icon + label capsule, accent-tinted when its mode is on.
    /// Matches the app's existing chip language exactly (padding, capsule, accent).
    private func vizChip<Icon: View>(
        label: String, isOn: Bool, action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                icon()
                Text(label).dsStyle(DS.TypeScale.bodyStrong)
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, DS.Space.m)
            .padding(.horizontal, DS.Space.xl4)
            .background(Capsule().fill(isOn ? DS.Color.accent.opacity(0.28).color : DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(isOn ? DS.Color.accent.opacity(0.7).color : DS.Color.strokeStrong.color, lineWidth: 1.5)))
        }
        .buttonStyle(.plain)
    }

    private var stressChip: some View {
        vizChip(label: "Stress", isOn: model.stressOn, action: { model.toggleStress() }) {
            Circle()
                .fill(AngularGradient(colors: [
                    RGBA(28, 60, 170).color, RGBA(0, 170, 220).color, RGBA(60, 190, 110).color,
                    RGBA(250, 220, 60).color, RGBA(255, 70, 50).color, RGBA(28, 60, 170).color,
                ], center: .center))
                .frame(width: 15, height: 15)
        }
    }

    private var flexChip: some View {
        vizChip(label: "Flex", isOn: model.flexOn, action: { model.toggleFlex() }) {
            Image(systemName: "waveform.path").font(.system(size: 13, weight: .semibold))
        }
    }

    private var loadPathChip: some View {
        vizChip(label: "Load path", isOn: model.loadPathOn, action: { model.toggleLoadPath() }) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private var failureChip: some View {
        vizChip(label: "Failure", isOn: model.failureOn, action: { model.toggleFailure() }) {
            Image(systemName: "burst").font(.system(size: 13, weight: .semibold))
        }
    }

    private var exportButton: some View {
        Button(action: onExport) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .semibold))
                Text("Export .3mf").dsStyle(DS.TypeScale.bodyStrong)
            }
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.vertical, DS.Space.m)
            .padding(.horizontal, DS.Space.xl4)
            .background(Capsule().fill(DS.Color.accent.color))
            .dsShadow(.accentGlow)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom-left: savings tabs

    private var savingsTabs: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Spacer()
            streamingChip   // "optimizing more…" sits right above the variant tabs
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
        // Lifted clear of the bottom-center playbar so the variant cards and the play
        // controls never overlap (they used to share the bottom band). The playbar
        // occupies ~76pt up from the bottom; this keeps the cards above it.
        .padding(.horizontal, DS.Space.xl4)
        .padding(.top, DS.Space.xl4)
        .padding(.bottom, 92)
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

                downloadButton   // far-right: save the optimization as a video
            }
            .padding(.vertical, DS.Space.xs)
            .padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(.panel)
            .padding(.bottom, DS.Space.xl6)
        }
    }

    /// Far-right timeline control: export the optimization playback as a video. A
    /// spinner while encoding; enabled only when the variant has a history.
    @ViewBuilder private var downloadButton: some View {
        if videoExport.isExporting {
            ProgressView().controlSize(.small).tint(DS.Color.accent.color)
                .frame(width: 32, height: 32)
        } else {
            Button {
                videoExport.export(keyframes: model.keyframes(), name: model.projectName)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasHistory)
            .opacity(model.hasHistory ? 1 : 0.35)
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

/// The shared chrome for the right-rail drawers: a compact glass panel (tighter
/// padding than the old floating cards) with the standard panel surface, stroke, and
/// shadow. Keeping it in one place makes every drawer read as the same treatment.
private extension View {
    /// `width` is the drawer's CONTENT width (the sliders/ramp/key all share it). The
    /// content is pinned to exactly that width BEFORE the chrome padding, so a drawer is
    /// only ever as wide as its contents + padding — no full-width stretch. This is the
    /// fix for the "drawers stretch nearly the full screen" bug: the Deflection/Failure
    /// drawers contain `HStack { label; Spacer(); value }` rows whose greedy `Spacer`
    /// would otherwise expand the drawer to fill whatever width the rail offered.
    func resultsDrawerChrome(width: CGFloat) -> some View {
        self
            .frame(width: width, alignment: .leading)
            .padding(.vertical, DS.Space.m)
            .padding(.horizontal, DS.Space.l)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(.panel)
            .fixedSize()   // never let an ancestor stretch the finished card
    }
}

/// A share sheet for the exported video (UIActivityViewController on iOS; a simple
/// confirmation on macOS, where there is no activity view controller).
#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheet: View {
    let items: [Any]
    var body: some View {
        VStack(spacing: DS.Space.m) {
            Text("Video saved").dsStyle(DS.TypeScale.title)
            if let url = items.first as? URL {
                Text(url.lastPathComponent).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
            }
        }
        .padding(DS.Space.xl3)
    }
}
#endif

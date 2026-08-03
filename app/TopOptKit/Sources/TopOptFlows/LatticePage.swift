// LatticePage.swift — the full-screen lattice page (handoff 2026-07-30-lattice-page,
// reworked in round-2 2026-07-31: maintainer device-round feedback + ONE selection
// system).
//
// The page is CHROME ONLY: it renders over the workspace's live stage (mesh view +
// raymarched strut preview), which stays mounted underneath — the workspace hides
// its own chrome while the page is open (one stage, never two).
//
// ROUND-2 STRUCTURE (the maintainer's items):
//  L18/L22/L23  Regions & faces open the SAME Selections library the TO page uses —
//      the workspace mounts its own `selectionsPanel` over this page when
//      `page.libraryOpen` (ONE view, ONE model — never a second selection UX).
//      Taps route through the non-destructive `LatticeLibraryTap` (M2).
//  L1   ONE spacing token between every chrome element (`LatticeChromeLayout`).
//  L9   Cell size + density are ONE ladder row (they open the same pane).
//  L13  Notes are TRANSIENT: top-centre, tap / replace / 60 s (`LatticeTransientNote`).
//  L14  Topology names on one line; non-generatable rows greyed with an orange
//      asterisk and a SINGLE footnote — never a per-row badge sentence.
//  L15  Boundary is the inline three-way on the ladder (sub-page removed).
//  L16  Review is a bottom-right drawer (ladder row removed).
//  L17  Preview is the bottom-right toggle + Refresh — the ONLY preview control.
//
// DATA RULES (the original bars, unchanged):
//  B0  the topology picker is computed from CORE's certifiable ∪ generatable sets.
//  B0b the density band shown is core's for the SELECTED topology.
//  B1  the entry gate covers the page until ≥1 anchor AND ≥1 load, and STATES
//      what is missing.
//  B5  RUN SIM gates with a one-line reason.
//  B6  Auto density is OFFERED only with a real field (provenance + age shown).
//  B7  boundary treatment is the three-way enum — skin-without-rim unrepresentable.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

public struct LatticePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var project: ProjectModel
    @ObservedObject var run: RunModel
    @ObservedObject var sim: LatticeSimModel
    @ObservedObject var page: LatticePageModel

    /// The variants-entry demand field (that run's own von Mises), nil from the
    /// workspace entry. When set, Auto density is available with no sim (B6).
    let variantField: LatticeDemandField?
    /// WHICH FINISHED VARIANT this page is working on (task
    /// 2026-08-02-lattice-a-variant). Non-nil ⇒ the page names it, the stage
    /// under the page is showing THAT variant's geometry, face tapping is off
    /// (it has no selectable faces), and the action row offers two clearly
    /// different jobs instead of one that would silently do the surprising one.
    let variantContext: LatticeVariantContext?
    /// The strut-preview toggle, owned by the workspace (the stage layer is its).
    @Binding var previewOn: Bool
    /// Base Optimize enablement + summary from the workspace (same rules as page one).
    let baseCanOptimize: Bool
    let baseSummary: String
    let onOptimize: () -> Void
    /// LATTICE THIS VARIANT — the `lattice_variant` job. Distinct from
    /// `onOptimize`, which re-runs the whole ladder.
    let onRelattice: () -> Void
    let onClose: () -> Void
    /// Back to Setup (closes the page; the workspace is the setup surface).
    let onBackToSetup: () -> Void
    /// L17: re-run the preview with the CURRENT settings (rebake the strut scene).
    let onRefreshPreview: () -> Void
    /// TEST SEAM for the offscreen evidence captures: ImageRenderer does not
    /// render platform-backed containers (ScrollView), so the evidence generator
    /// renders the panel as a plain stack. Production always scrolls.
    let staticRender: Bool

    // MARK: the pre-flight forecast (bar F3)

    /// Holds the forecast and its staleness. Owned by the workspace so it survives
    /// the page being closed and reopened.
    @ObservedObject var forecast: LatticeForecastModel
    /// The EXACT `lattice_variant` job "Lattice this variant" would submit — the
    /// forecast's input AND its identity. nil when there is nothing to forecast (no
    /// variant, no retained design, no worker). Rebuilt whenever the settings move,
    /// so a changed configuration is a changed document is a new forecast.
    let forecastJob: Data?
    /// Runs the forecast. Injected because it is a worker round trip; nil in the
    /// previews and offscreen captures, where the page renders without one.
    let driveForecast: (@Sendable (Data) async throws -> LatticeForecast)?

    public init(model: AppModel, project: ProjectModel, run: RunModel,
                sim: LatticeSimModel, page: LatticePageModel,
                variantField: LatticeDemandField? = nil,
                variantContext: LatticeVariantContext? = nil,
                previewOn: Binding<Bool>,
                baseCanOptimize: Bool, baseSummary: String,
                onOptimize: @escaping () -> Void,
                onRelattice: @escaping () -> Void = {},
                onClose: @escaping () -> Void,
                onBackToSetup: @escaping () -> Void,
                onRefreshPreview: @escaping () -> Void = {},
                forecast: LatticeForecastModel = LatticeForecastModel(),
                forecastJob: Data? = nil,
                driveForecast: (@Sendable (Data) async throws -> LatticeForecast)? = nil,
                staticRender: Bool = false) {
        self.model = model
        self.project = project
        self.run = run
        self.sim = sim
        self.page = page
        self.variantField = variantField
        self.variantContext = variantContext
        self._previewOn = previewOn
        self.baseCanOptimize = baseCanOptimize
        self.baseSummary = baseSummary
        self.onOptimize = onOptimize
        self.onRelattice = onRelattice
        self.onClose = onClose
        self.onBackToSetup = onBackToSetup
        self.onRefreshPreview = onRefreshPreview
        self.forecast = forecast
        self.forecastJob = forecastJob
        self.driveForecast = driveForecast
        self.staticRender = staticRender
    }

    // MARK: derived truth (all live, nothing hardcoded)

    private var force: ForceModel { project.force }
    private var groups: [SelectionGroup] { project.selection.groups }
    private var anchors: Int { force.anchorCount(in: groups) }
    private var loads: Int { force.loadCount(in: groups) }
    private var gate: LatticePageGate { LatticePageGate.compute(anchors: anchors, loads: loads) }

    private var limits: TopOptKit.LatticeLimits {
        TopOptKit.latticeLimits(topology: project.lattice.topologyID)
    }
    private var generatable: Bool {
        TopOptKit.latticeGeneratableTopologies.contains(project.lattice.topologyID)
    }
    private var bounds: LatticeBounds {
        LatticeBounds.compute(settings: project.lattice, limits: limits,
                              generatable: generatable,
                              memberMM: project.lattice.regionMemberMM ?? 0,
                              lineWidthMM: project.printParams.wallLineWidthOuterMM)
    }
    private var topologyRows: [LatticeTopologyRow] { LatticeTopologyPicker.rowsFromCore() }
    private var topologyDisplayName: String {
        LatticeType.displayName(forID: project.lattice.topologyID)
    }

    private var optimizing: Bool { run.phase == .running }
    private var runFailureText: String? {
        guard case .failed = run.phase else { return nil }
        return run.failure?.message ?? "The run failed."
    }
    private var simStale: Bool {
        guard let ctx = model.makeLatticeSimContext() else { return false }
        return sim.isStale(against: ctx.fingerprint)
    }
    /// The demand field: the variants entry's own field wins; else the sim's.
    private var demandField: LatticeDemandField? { variantField ?? sim.field }
    private var autoGate: LatticeAutoDensityGate {
        // The variants-entry field is never stale (it IS that run's result).
        LatticeAutoDensityGate.compute(field: demandField,
                                       stale: variantField == nil && simStale)
    }
    private var banner: LatticePageBanner? {
        LatticePageBanner.derive(simPhase: sim.phase, simStale: simStale,
                                 optimizing: optimizing, runFailure: runFailureText)
    }
    private var simGate: LatticeSimGate {
        LatticeSimGate.compute(latticeOn: project.lattice.enabled,
                               optimizing: optimizing, simRunning: sim.phase == .running)
    }
    private var optimizeSurface: LatticeOptimizeSurface {
        LatticeOptimizeSurface.compute(
            baseCanOptimize: baseCanOptimize, baseSummary: baseSummary,
            latticeEnabled: project.lattice.enabled,
            densityMode: project.lattice.densityMode,
            topologyDisplayName: topologyDisplayName,
            cellMM: project.lattice.cellMM,
            bounds: project.lattice.enabled ? bounds : nil,
            running: optimizing,
            lineWidthMM: project.printParams.wallLineWidthOuterMM,
            cellSummary: cellSummaryText,
            designBoxActive: project.designBox.isActive)
    }

    private var clearanceCount: Int { project.clearanceSpecs().count }
    /// Groups carrying a lattice role (the unified library's include/exclude).
    private var roleGroupCount: Int {
        groups.filter { project.lattice.groupRoles[$0.id] != nil }.count
    }
    private var regionCount: Int {
        project.latticeJobRegions().regions.count
    }

    // MARK: body

    public var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            ZStack(alignment: .topLeading) {
                topLeftColumn
                topRightColumn
                topCentreColumn
                if portrait {
                    panelView(maxHeight: geo.size.height * 0.46)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, DS.Space.l)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, LatticeChromeLayout.panelBottomClearance)
                } else {
                    // L4: the panel is only as tall as its content and sits CENTRED
                    // on the left edge (no stretched frame, no empty bottom).
                    panelView(maxHeight: geo.size.height - 200)
                        .frame(width: 348)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, DS.Space.xl4)
                }
                bottomRightCluster
                if !gate.satisfied { gateOverlay }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // *** THE FORECAST'S CALL SITE (bar F3). *** Every layer below this
            // line existed before it did — core computes the forecast, the worker
            // serves it, RelatticeRun drives it, LatticeForecast parses it and the
            // button and drawer render it — and the user saw nothing, because
            // nothing invoked it. `id:` is the job document itself, so changing any
            // setting that changes the job re-asks, and changing one that does not
            // costs nothing.
            .task(id: forecastJob) {
                guard let drive = driveForecast else { return }
                forecast.request(forecastJob, drive: drive)
            }
        }
    }

    // MARK: top-left: back · title · undo/redo · From Setup (ONE gap between rows)

    private var topLeftColumn: some View {
        VStack(alignment: .leading, spacing: LatticeChromeLayout.titleToFromSetup) {
            HStack(spacing: LatticeChromeLayout.topLeftRowSpacing) {
                circleButton(system: "chevron.left", label: "Close lattice") { onClose() }
                HStack(spacing: DS.Space.m) {
                    Text(project.name.isEmpty ? "Untitled" : project.name)
                        .dsStyle(DS.TypeScale.headline)
                    Rectangle().fill(DS.Color.textPrimary.opacity(0.16).color)
                        .frame(width: 1, height: 20)
                    Text(project.material).dsStyle(DS.TypeScale.body)
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .padding(.horizontal, DS.Space.xl2).frame(height: 52)
                .background(Capsule().fill(DS.Surface.bar.color)
                    .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
                circleButton(system: "arrow.uturn.backward", label: "Undo") { project.performUndo() }
                circleButton(system: "arrow.uturn.forward", label: "Redo") { project.performRedo() }
            }
            workingOnBar
            fromSetupBar
        }
        .padding(.leading, DS.Space.xl4).padding(.top, DS.Space.xl3)
    }

    private func circleButton(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 52, height: 52)
                .background(Circle().fill(DS.Surface.bar.color)
                    .overlay(Circle().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: which VARIANT this page is working on (bar Z7/Z9)

    /// The identity bar. When the page was entered from a finished variant it
    /// says WHICH ONE, and it sits directly above the "From Setup" row so the
    /// subject of every control below it is stated before the controls are.
    /// Absent from the workspace entry, where the subject is the whole part.
    @ViewBuilder private var workingOnBar: some View {
        if let v = variantContext {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Color.accent.color)
                Text("Working on").dsStyle(DS.TypeScale.caption2).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                Text(v.title).dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                    .foregroundStyle(DS.Color.textPrimary.color)
                divider
                Text(v.subtitle).dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textTertiary.color)
                if !LatticeVariantAuthoring.compute(variant: v).faceTapEnabled {
                    divider
                    Text("no selectable faces — place regions instead")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.42).color)
                }
            }
            .padding(.horizontal, DS.Space.ml).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Surface.bar.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.accent.opacity(0.45).color, lineWidth: 1)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Working on \(v.title), \(v.subtitle)")
        }
    }

    // MARK: "From Setup" read-only inherited bar

    private var fromSetupBar: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.textQuaternary.color)
            Text("From Setup").dsStyle(DS.TypeScale.caption2).fontWeight(.semibold)
                .foregroundStyle(DS.Color.textQuaternary.color)
            divider
            setupCount("\(anchors) anchor\(anchors == 1 ? "" : "s")",
                       ok: anchors >= 1, tint: DS.Color.okGreen)
            setupCount(loads >= 1 ? loadLabel : "0 loads",
                       ok: loads >= 1, tint: DS.Color.accent)
            Text("\(clearanceCount) keep-clear").dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
            divider
            Text(project.material).dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
            Text("\(project.quality.title) · \(project.quality.resolution)³")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
            if let mesh = project.viewerMesh {
                let e = mesh.bounds.max - mesh.bounds.min
                Text(String(format: "%.0f × %.0f × %.0f mm", e.x, e.y, e.z))
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.32).color)
            }
        }
        .padding(.horizontal, DS.Space.ml).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control)
            .fill(DS.Surface.bar.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
    }

    /// The load readout in the user's own display unit (round-2 T4: no hardcoded kg).
    private var loadLabel: String {
        let kg = force.totalLoadKg(in: groups)
        return kg > 0 ? "\(force.formattedWeight(kg: kg)) load"
                      : "\(loads) load\(loads == 1 ? "" : "s")"
    }

    private func setupCount(_ text: String, ok: Bool, tint: RGBA) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill((ok ? tint : DS.Color.warning).color).frame(width: 8, height: 8)
            Text(text).dsStyle(DS.TypeScale.caption2).fontWeight(.semibold)
                .foregroundStyle((ok ? DS.Color.textPrimary.opacity(0.8) : DS.Color.warning).color)
        }
    }

    private var divider: some View {
        Rectangle().fill(DS.Color.textPrimary.opacity(0.12).color).frame(width: 1, height: 15)
    }

    // MARK: top-right: RUN SIM (the workspace gizmo is hidden under the page — L6)

    /// ROUND-2 BARS L2 + L3. The top-right corner belongs to the POSITION GIZMO,
    /// on every page — so RUN SIM moved down to the bottom-right cluster with the
    /// page's other actions, where "the simulation button" lives on the smoothing
    /// page too (`Re-certify`) and on the TO page (`Optimize`).
    ///
    /// Round 1 answered the same collision by HIDING the gizmo here (its
    /// Metal-backed glass composited over this page's pure-SwiftUI chrome, so
    /// RUN SIM rendered behind it). That traded one invariant for another. Moving
    /// the button and mounting the gizmo above every page keeps both.
    ///
    /// What is left in this corner is the gate's REASON, which is a caption, not a
    /// control — and it is inset by `PageChrome.gizmoClearance` so it cannot land
    /// under the gizmo either (bar L5).
    @ViewBuilder private var topRightColumn: some View {
        if let reason = simGate.reason {
            VStack(alignment: .trailing, spacing: LatticeChromeLayout.runSimColumnSpacing) {
                Text(reason)
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 236, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, LatticeChromeLayout.edge + PageChrome.gizmoClearance)
            .padding(.top, DS.Space.xl3)
        }
    }

    private var runSimButton: some View {
        Button {
            guard !simGate.blocked, let ctx = model.makeLatticeSimContext() else { return }
            sim.run(ctx)
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                Text("RUN SIM").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
            }
            .foregroundStyle((simGate.blocked ? DS.Color.textDisabled : DS.Color.textPrimary).color)
            .padding(.horizontal, DS.Space.xl).frame(height: PageChrome.actionButton)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill((simGate.blocked ? DS.Color.fillDisabled : DS.Surface.panel).color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder((simGate.blocked ? DS.Color.strokeSubtle : DS.Color.strokeStrong).color,
                                  lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .disabled(simGate.blocked)
        .accessibilityLabel("Run sim")
    }

    // MARK: top-centre: transient note (L13) + status banner

    private var topCentreColumn: some View {
        VStack(spacing: LatticeChromeLayout.noteToBanner) {
            if let n = page.note { noteView(n) }
            if let b = banner { bannerView(b) }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, DS.Space.xl3)
    }

    /// The transient note (L13): top-centre, dismissed by tap, by a different
    /// note, or by the 60 s tick.
    private func noteView(_ n: LatticeTransientNote) -> some View {
        Text(n.text)
            .dsStyle(DS.TypeScale.caption)
            .foregroundStyle(DS.Color.textPrimary.opacity(0.8).color)
            .padding(.vertical, 8).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
            .frame(maxWidth: 560)
            .contentShape(Capsule())
            .onTapGesture { page.dismissNote() }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
                page.tick(now: now)
            }
            .accessibilityLabel("Note: \(n.text). Tap to dismiss.")
    }

    private func bannerView(_ b: LatticePageBanner) -> some View {
        HStack(spacing: DS.Space.m) {
            ZStack {
                Circle().fill(bannerTint(b.kind).color).frame(width: 26, height: 26)
                Image(systemName: bannerGlyph(b.kind))
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(DS.Color.background.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title).dsStyle(DS.TypeScale.bodyStrong)
                Text(b.body).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(2)
                if b.showsProgress {
                    ProgressView().progressViewStyle(.linear).tint(DS.Color.accent.color)
                        .frame(maxWidth: 220)
                }
            }
            if let label = b.actionLabel {
                Button { bannerAction(b) } label: {
                    Text(label).dsStyle(DS.TypeScale.callout).fontWeight(.semibold)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.horizontal, DS.Space.ml).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                            .fill(DS.Color.fillSelected.color))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
            .fill(DS.Surface.sheet.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .strokeBorder(bannerTint(b.kind).opacity(0.44).color, lineWidth: 1)))
        .frame(maxWidth: 560)
        .dsShadow(DS.Shadow.panel)
    }

    private func bannerTint(_ k: LatticePageBanner.Kind) -> RGBA {
        switch k {
        case .simRunning: return DS.Color.accent
        case .simComplete: return DS.Color.okGreen
        case .simStale, .smoothingStale: return DS.Color.warning
        case .optimizing: return RGBA(hex: 0x5E5CE6)
        case .failed: return DS.Color.danger
        }
    }
    private func bannerGlyph(_ k: LatticePageBanner.Kind) -> String {
        switch k {
        case .simRunning, .optimizing: return "circle.fill"
        case .simComplete: return "checkmark"
        case .simStale, .smoothingStale: return "exclamationmark"
        case .failed: return "xmark"
        }
    }
    private func bannerAction(_ b: LatticePageBanner) {
        switch b.kind {
        case .simRunning: sim.cancel()
        case .simStale:
            if let ctx = model.makeLatticeSimContext() { sim.run(ctx) }
        case .optimizing: run.cancel()
        case .failed: page.go(nil)
        // The smoothing-stale banner is not a LATTICE-page state; it is derived
        // and shown by the smoothing page. Listed for exhaustiveness so a future
        // kind cannot be added without a decision here.
        case .simComplete, .smoothingStale: break
        }
    }

    // MARK: the panel (L3: no "Part"; L4: content-height)

    @State private var paneContentHeight: CGFloat = 0

    private func panelView(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if page.panelMinimized {
                minimizedHeader
            } else {
                panelHeader
                if staticRender {
                    VStack(spacing: DS.Space.s) { paneContent }
                        .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.m)
                } else {
                    // L4: the scroll region is exactly as tall as its content, up
                    // to the cap — the panel never stretches past its content.
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: DS.Space.s) { paneContent }
                            .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.m)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: PaneHeightKey.self,
                                                       value: g.size.height)
                            })
                    }
                    .frame(height: min(max(paneContentHeight, 1), max(maxHeight, 1)))
                    .onPreferenceChange(PaneHeightKey.self) { paneContentHeight = $0 }
                }
            }
        }
        .frame(maxWidth: page.panelMinimized ? 236 : .infinity)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .animation(DS.Motion.emphasized, value: page.panelMinimized)
    }

    private struct PaneHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Pane titles. L3: the modal never says "part" — the root pane is just
    /// "Lattice" with no kicker.
    private var paneTitle: (kicker: String, title: String) {
        switch page.pane {
        case nil: return ("", "Lattice")
        case .topology: return ("Lattice", "Topology")
        case .cellDensity: return ("Lattice", "Cell & density")
        }
    }

    private var panelHeader: some View {
        HStack(spacing: DS.Space.sm) {
            if page.pane != nil {
                Button { page.back() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                            .fill(DS.Color.fillSubtle.color))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 1) {
                if !paneTitle.kicker.isEmpty {
                    Text(paneTitle.kicker.uppercased())
                        .font(.system(size: 11, weight: .semibold)).tracking(0.7)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                }
                Text(paneTitle.title).dsStyle(DS.TypeScale.headline).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            if page.pane == nil || page.pane == .topology { topologyBadge }
            Button { page.panelMinimized = true } label: {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                        .fill(DS.Color.fillSubtle.color))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize panel")
        }
        .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.ml).padding(.bottom, DS.Space.sm)
    }

    private var minimizedHeader: some View {
        HStack(spacing: DS.Space.sm) {
            Text("\(paneTitle.title) · \(selectedRow?.badge.capitalized ?? "")")
                .dsStyle(DS.TypeScale.bodyStrong).lineLimit(1)
            Spacer()
            Button { page.panelMinimized = false } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                        .fill(DS.Color.fillSubtle.color))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Maximize panel")
        }
        .padding(.horizontal, DS.Space.l).frame(height: 56)
    }

    private var selectedRow: LatticeTopologyRow? {
        topologyRows.first { $0.id == project.lattice.topologyID }
    }

    private var topologyBadge: some View {
        let row = selectedRow
        let certifiableAndRuns = (row?.certifiable ?? false) && (row?.generatable ?? false)
        let text = row?.badge ?? "UNKNOWN"
        let tint = certifiableAndRuns ? DS.Color.okGreen : DS.Color.warning
        return Text(text)
            .font(.system(size: 10.5, weight: .bold)).tracking(0.3)
            .foregroundStyle(tint.color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(certifiableAndRuns ? DS.Color.okGreen.opacity(0.14).color : .clear)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tint.opacity(0.7).color,
                                  style: StrokeStyle(lineWidth: 1,
                                                     dash: certifiableAndRuns ? [] : [3, 3]))))
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private var paneContent: some View {
        switch page.pane {
        case nil: ladderList
        case .topology: topologyPane
        case .cellDensity: cellDensityPane
        }
    }

    // MARK: the ladder (single flat list)

    private var ladderList: some View {
        VStack(spacing: DS.Space.s) {
            // 1 · Lattice infill toggle
            ladderRow(key: "Lattice infill",
                      value: project.lattice.enabled ? "On" : "Off",
                      flag: nil, flagTint: nil) {
                Toggle("", isOn: Binding(get: { project.lattice.enabled },
                                         set: { project.lattice.enabled = $0 }))
                    .labelsHidden().toggleStyle(.switch).tint(DS.Color.okGreen.color)
            } action: {
                project.lattice.enabled.toggle()
            }
            // 2 · Topology
            ladderRow(key: "Topology", value: topologyDisplayName,
                      flag: ladderTopologyFlag.text, flagTint: ladderTopologyFlag.tint,
                      chevron: true) { EmptyView() } action: { page.go(.topology) }
            // 3 · Cell & density — ONE row (L9: both open the same pane)
            ladderRow(key: "Cell & density",
                      value: "\(cellSummaryText) · \(densityRangeText)",
                      flag: nil, flagTint: nil, chevron: true) {
                if limits.certifiable { miniBand }
            } action: { page.go(.cellDensity) }
            // 4 · Regions & faces — opens THE Selections library, the exact panel
            // the TO page uses (L18). No second selection UX exists here.
            ladderRow(key: "Regions & faces",
                      value: "\(roleGroupCount) group role\(roleGroupCount == 1 ? "" : "s") · \(regionCount) region\(regionCount == 1 ? "" : "s")",
                      flag: nil, flagTint: nil, chevron: true) { EmptyView() } action: {
                page.libraryOpen.toggle()
                if page.libraryOpen {
                    page.panelMinimized = true
                    page.post(note: "Same Selections library as Setup — tap a group to give it a lattice role; faces of Setup groups can only be removed back on Setup.")
                }
            }
            // 5 · Boundary — the single three-way question, INLINE (L15).
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Boundary").font(.system(size: 11.5))
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.42).color)
                    .padding(.horizontal, DS.Space.ml).padding(.top, DS.Space.s)
                treatmentSegment
                    .padding(.horizontal, DS.Space.s).padding(.bottom, DS.Space.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .fill(DS.Color.fillSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                    .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
    }

    private var ladderTopologyFlag: (text: String, tint: RGBA) {
        guard let r = selectedRow else { return ("unknown", DS.Color.warning) }
        if r.certifiable && r.generatable { return ("certifiable", DS.Color.okGreen) }
        if r.certifiable { return ("no geometry yet", DS.Color.warning) }
        return ("preview only", DS.Color.warning)
    }

    private var densityRangeText: String {
        "\(Int((bounds.densityLo * 100).rounded()))–\(Int((bounds.densityHi * 100).rounded())) %"
    }

    /// The core band (green) with the user's clamped window (white) over 0–100%.
    private var miniBand: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Color.fillSubtle.color)
                    Capsule().fill(DS.Color.okGreen.opacity(0.35).color)
                        .frame(width: w * (bounds.bandHi - bounds.bandLo))
                        .offset(x: w * bounds.bandLo)
                    Capsule().fill(DS.Color.textPrimary.color)
                        .frame(width: max(3, w * (bounds.densityHi - bounds.densityLo)))
                        .offset(x: w * bounds.densityLo)
                }
            }
            .frame(width: 64, height: 8)
            // The DISPLAYED range is always the clamped one (inside the band), so
            // the caption distinguishes "the user's pick was inside" from "we
            // pulled it onto the band" — never a false "out of band".
            Text(inBand ? "in band" : "clamped to band")
                .font(.system(size: 9.5))
                .foregroundStyle(DS.Color.textPrimary.opacity(0.34).color)
        }
    }

    private var inBand: Bool {
        bounds.densityLoReason == nil && bounds.densityHiReason == nil
    }

    private func ladderRow<Accessory: View>(
        key: String, value: String, flag: String?, flagTint: RGBA?,
        chevron: Bool = false,
        @ViewBuilder accessory: () -> Accessory,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(key).font(.system(size: 11.5))
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.42).color)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(value).dsStyle(DS.TypeScale.bodyStrong).lineLimit(1)
                        if let f = flag, let t = flagTint {
                            Text(f).font(.system(size: 11, weight: .bold))
                                .foregroundStyle(t.color).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: DS.Space.s)
                accessory()
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.38).color)
                }
            }
            .padding(.horizontal, DS.Space.ml)
            .frame(minHeight: 62)
            .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .fill(DS.Color.fillSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                    .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: topology pane (B0 — core truth only; L14 — one line, one footnote)

    private var topologyPane: some View {
        VStack(spacing: 7) {
            ForEach(topologyRows) { row in
                topologyRowButton(row)
            }
            // L14: ONE footnote for every asterisked row — never a per-row
            // "certifies · no geometry yet" sentence. The split still comes from
            // core's two sets (B0); this is presentation only.
            if topologyRows.contains(where: { !$0.generatable }) {
                Text("* the geometry does not exist yet")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.warning.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DS.Space.xs)
            }
        }
    }

    private func topologyRowButton(_ row: LatticeTopologyRow) -> some View {
        let selected = project.lattice.topologyID == row.id
        return Button { project.lattice.topologyID = row.id } label: {
            HStack(spacing: DS.Space.sm) {
                // L14: the name on ONE line; a non-generatable topology is GREYED
                // with an orange asterisk pointing at the single footnote.
                HStack(alignment: .top, spacing: 2) {
                    Text(row.displayName)
                        .dsStyle(DS.TypeScale.bodyStrong)
                        .foregroundStyle((row.generatable ? DS.Color.textPrimary
                                                          : DS.Color.textTertiary).color)
                        .lineLimit(1)
                    if !row.generatable {
                        Text("*").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(DS.Color.warning.color)
                    }
                }
                Spacer(minLength: DS.Space.s)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.Color.accent.color)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, DS.Space.ml).frame(minHeight: 54)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(selected ? DS.Color.accent.opacity(0.16).color : DS.Color.fillSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(selected ? DS.Color.accent.opacity(0.45).color
                                           : DS.Color.strokePanel.color,
                                  lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: cell + density pane (B0b — the band is core's; L8 — tappable numbers)

    @State private var numberPadTarget: String? = nil

    private var cellDensityPane: some View {
        VStack(spacing: DS.Space.sm) {
            // Cell size card — Auto / Fixed / Swept (bar R6). Fixed is today's single
            // value + slider, unchanged; the slider's LOWER bound is now core's own
            // printability floor (bounds.cellFloorMM) instead of the old app hardcode.
            card {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cell size").dsStyle(DS.TypeScale.body)
                    Spacer()
                }
                segment(["Auto", "Fixed", "Swept"],
                        selected: cellModeIndex, enabled: cellModeEnabled) { i in
                    project.lattice.cellSizeMode = LatticePage.cellModes[i]
                }
                cellModeBody
                if let note = cellModeGateNote {
                    Text(note).dsStyle(DS.TypeScale.caption)
                        .foregroundStyle((project.lattice.cellSizeMode == .fixed
                                          ? DS.Color.textQuaternary.color
                                          : RGBA(hex: 0xFFCF7A).color))
                }
                if let reason = bounds.cellReason {
                    Text(reason).dsStyle(DS.TypeScale.caption)
                        .foregroundStyle((bounds.cellOverCeiling ? DS.Color.warning : DS.Color.textSecondary).color)
                } else if let c = bounds.cellCeilingMM {
                    Text(String(format: "Certifiable up to %.1f mm on this member (core's ≥ %g cells rule).",
                                c, limits.minCellsPerMember))
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.okGreen.color)
                }
            }
            // Density range card — the BAND IS CORE'S for the selected topology.
            card {
                HStack(alignment: .firstTextBaseline) {
                    Text("Density range").dsStyle(DS.TypeScale.body)
                    Spacer()
                    tappableNumber(key: "densityLo",
                                   text: "\(Int((bounds.densityLo * 100).rounded())) %",
                                   title: "Min density", unit: "%",
                                   seed: (project.lattice.minRelativeDensity * 100).rounded()) { v in
                        project.lattice.minRelativeDensity =
                            Swift.min(Swift.max(v / 100, 0), project.lattice.maxRelativeDensity - 0.02)
                    }
                    Text("–").dsStyle(DS.TypeScale.headline)
                        .foregroundStyle(DS.Color.textTertiary.color)
                    tappableNumber(key: "densityHi",
                                   text: "\(Int((bounds.densityHi * 100).rounded())) %",
                                   title: "Max density", unit: "%",
                                   seed: (project.lattice.maxRelativeDensity * 100).rounded()) { v in
                        project.lattice.maxRelativeDensity =
                            Swift.max(Swift.min(v / 100, 1), project.lattice.minRelativeDensity + 0.02)
                    }
                }
                densitySlider(label: "min",
                              value: Binding(get: { project.lattice.minRelativeDensity },
                                             set: { project.lattice.minRelativeDensity = min($0, project.lattice.maxRelativeDensity - 0.02) }))
                densitySlider(label: "max",
                              value: Binding(get: { project.lattice.maxRelativeDensity },
                                             set: { project.lattice.maxRelativeDensity = max($0, project.lattice.minRelativeDensity + 0.02) }))
                if limits.certifiable {
                    Text(bandNote).dsStyle(DS.TypeScale.caption)
                        .foregroundStyle((inBand ? DS.Color.okGreen : DS.Color.warning).color)
                } else {
                    Text("No certifiable band — core carries no tensor for \(topologyDisplayName).")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.warning.color)
                }
            }
            // Region depth: how deep a face-role region reaches into the part —
            // the depth the emitted `lattice.regions` face entries carry (L8).
            card {
                HStack(alignment: .firstTextBaseline) {
                    Text("Region depth").dsStyle(DS.TypeScale.body)
                    Spacer()
                    tappableNumber(key: "depth",
                                   text: String(format: "%.1f mm", project.lattice.paintDepthMM),
                                   title: "Region depth", unit: "mm",
                                   seed: project.lattice.paintDepthMM) { v in
                        project.lattice.paintDepthMM = Swift.min(50, Swift.max(0.5, v))
                    }
                }
                Text("How far a face marked in the Selections library reaches into the part as a lattice region.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
            // Density MODE — uniform vs auto (B6).
            card {
                HStack {
                    Text("Density mode").dsStyle(DS.TypeScale.body)
                    Spacer()
                    segment(["Uniform", "Auto"],
                            selected: project.lattice.densityMode == .auto ? 1 : 0,
                            enabled: [true, autoGate.offered]) { i in
                        project.lattice.densityMode = i == 1 ? .auto : .uniform
                    }
                }
                if let reason = autoGate.unavailableReason {
                    Text(reason).dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(RGBA(hex: 0xFFCF7A).color)
                } else if let prov = autoGate.provenanceLabel {
                    HStack(spacing: DS.Space.s) {
                        Text(project.lattice.densityMode == .auto
                            ? "Auto grades from: \(prov)"
                            : "Field available: \(prov)")
                            .dsStyle(DS.TypeScale.caption)
                            .foregroundStyle((autoGate.stale ? DS.Color.warning : DS.Color.textSecondary).color)
                        if autoGate.stale { Text("stale").dsStyle(DS.TypeScale.caption)
                            .foregroundStyle(DS.Color.warning.color) }
                    }
                }
            }
        }
    }

    // MARK: cell-size mode — Auto / Fixed / Swept, bounded BY CORE (bar R6)

    /// Segment order: ONE source of truth for index ↔ mode, so the control and the
    /// stored setting can never drift.
    private static let cellModes: [LatticeCellSizeMode] = [.auto, .fixed, .swept]

    /// The one-line cell summary the ladder row and the Review drawer both show, so
    /// the mode is legible without opening the pane ("Auto 2.6 mm" / "8.0 mm" /
    /// "Swept 4.0–8.0 mm"). Fixed reads exactly as it did before the mode existed.
    private var cellSummaryText: String {
        // A uniform run always uses the fixed cell whatever the stored mode says
        // (runSpec resolves it) — the summary must not claim otherwise.
        guard cellModeGraded else { return String(format: "%.1f mm", project.lattice.cellMM) }
        switch project.lattice.cellSizeMode {
        case .fixed:
            return String(format: "%.1f mm", project.lattice.cellMM)
        case .auto:
            return bounds.cellFloorMM.map { String(format: "Auto %.1f mm", $0) } ?? "Auto (core)"
        case .swept:
            let lo = Swift.max(project.lattice.cellMinMM, bounds.cellFloorMM ?? 0)
            let hi = Swift.max(project.lattice.cellMaxMM, lo)
            return String(format: "Swept %.1f–%.1f mm", lo, hi)
        }
    }
    /// The slider's top end (mm) — a UI convenience, unchanged from the shipped
    /// control. The BOTTOM end is core's (`bounds.cellFloorMM`), never this file's.
    private static let cellSliderMaxMM: Double = 20
    /// Shown only when NO core floor exists (no line width set, or core carries no
    /// tensor for the topology): the control's own start of range, explicitly not a
    /// certifiable limit — the caption says so.
    private static let cellFallbackFloorMM: Double = 2

    private var cellModeIndex: Int {
        LatticePage.cellModes.firstIndex(of: project.lattice.cellSizeMode) ?? 1
    }

    /// Auto and Swept hand the cell choice to CORE, which happens inside the GRADED
    /// pass — so they are offered only when Density mode is Auto. Greyed with the
    /// reason below rather than silently ignored.
    private var cellModeGraded: Bool { project.lattice.densityMode == .auto }
    private var cellModeEnabled: [Bool] { [cellModeGraded, true, cellModeGraded] }

    private var cellModeGateNote: String? {
        guard !cellModeGraded else { return nil }
        if project.lattice.cellSizeMode != .fixed {
            return "This run is uniform, so it will use the fixed cell — set Density mode to Auto for core to choose or sweep the cell."
        }
        return "Auto and Swept need Density mode = Auto: core picks the cell inside the graded pass."
    }

    /// Core's floor for the current topology at the user's own line width, or the
    /// control's fallback start when core has no number to give.
    private var cellFloorMM: Double { bounds.cellFloorMM ?? LatticePage.cellFallbackFloorMM }

    private var cellSliderRange: ClosedRange<Double> {
        let top = LatticePage.cellSliderMaxMM
        let lo = Swift.max(0.5, Swift.min(cellFloorMM, top - 0.5))
        return lo...top
    }

    private func clampCell(_ v: Double) -> Double {
        let r = cellSliderRange
        return Swift.min(r.upperBound, Swift.max(r.lowerBound, (v * 2).rounded() / 2))
    }

    @ViewBuilder private var cellModeBody: some View {
        switch project.lattice.cellSizeMode {
        case .auto:
            HStack(alignment: .firstTextBaseline) {
                Text("Core's cell").dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
                Spacer()
                Text(bounds.cellFloorMM.map { String(format: "%.1f mm", $0) } ?? "—")
                    .dsStyle(DS.TypeScale.headline)
                    .foregroundStyle((bounds.cellFloorMM == nil ? DS.Color.textTertiary
                                                                : DS.Color.textPrimary).color)
            }
            Text(bounds.cellFloorMM == nil
                 ? "Core has no cell for this topology at your print settings yet — set an outer line width to read it."
                 : "Core picks the smallest cell whose struts still print at your line width; no cell is entered here.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textQuaternary.color)
        case .fixed:
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                tappableNumber(key: "cell",
                               text: String(format: "%.1f mm", project.lattice.cellMM),
                               title: "Cell size", unit: "mm",
                               seed: project.lattice.cellMM) { v in
                    project.lattice.cellMM = clampCell(v)
                }
            }
            Slider(value: Binding(get: { Swift.min(cellSliderRange.upperBound,
                                                   Swift.max(cellSliderRange.lowerBound,
                                                             project.lattice.cellMM)) },
                                  set: { project.lattice.cellMM = clampCell($0) }),
                   in: cellSliderRange)
                .tint(DS.Color.accent.color)
        case .swept:
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                tappableNumber(key: "cellMin",
                               text: String(format: "%.1f mm", project.lattice.cellMinMM),
                               title: "Smallest cell", unit: "mm",
                               seed: project.lattice.cellMinMM) { v in
                    let lo = clampCell(v)
                    project.lattice.cellMinMM = lo
                    if project.lattice.cellMaxMM < lo { project.lattice.cellMaxMM = lo }
                }
                Text("–").dsStyle(DS.TypeScale.headline)
                    .foregroundStyle(DS.Color.textTertiary.color)
                tappableNumber(key: "cellMax",
                               text: String(format: "%.1f mm", project.lattice.cellMaxMM),
                               title: "Largest cell", unit: "mm",
                               seed: project.lattice.cellMaxMM) { v in
                    project.lattice.cellMaxMM = Swift.max(clampCell(v), project.lattice.cellMinMM)
                }
            }
            Text(bounds.cellFloorMM == nil
                 ? "Core grades the cell across this window — fine where the stress is high, coarse where it is low."
                 : String(format: "Core grades the cell across this window — fine where the stress is high, coarse where it is low. Neither end goes below core's %.1f mm floor.",
                          cellFloorMM))
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textQuaternary.color)
        }
    }

    /// A tappable number (L8): the value is a button; tapping opens the small
    /// numeric keypad seeded with the current value.
    private func tappableNumber(key: String, text: String, title: String, unit: String,
                                seed: Double, write: @escaping (Double) -> Void) -> some View {
        Button { numberPadTarget = key } label: {
            Text(text).dsStyle(DS.TypeScale.headline)
                .padding(.horizontal, DS.Space.s).frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                    .fill(DS.Color.textPrimary.opacity(0.07).color)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.field)
                        .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .numberPad(Binding(get: { numberPadTarget == key },
                           set: { if !$0 { numberPadTarget = nil } }),
                   config: .init(title: title, unit: unit, allowsDecimal: true),
                   seed: seed) { v in
            if let v, v > 0 { write(v) }
        }
        .accessibilityLabel("\(title): \(text). Tap to type.")
    }

    private var bandNote: String {
        let lo = Int((bounds.bandLo * 100).rounded()), hi = Int((bounds.bandHi * 100).rounded())
        if inBand { return "Inside the certifiable band, \(lo)–\(hi) % (from core, \(topologyDisplayName))." }
        if bounds.densityLoReason != nil { return "Clamped up to \(lo) % — below it \(topologyDisplayName) builds but is not certifiable." }
        return "Clamped down to \(hi) % — above it exceeds the certified data."
    }

    private func densitySlider(label: String, value: Binding<Double>) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text(label).font(.system(size: 11))
                .foregroundStyle(DS.Color.textQuaternary.color).frame(width: 26, alignment: .leading)
            Slider(value: value, in: 0.02...0.9).tint(DS.Color.accent.color)
        }
    }

    // MARK: boundary segment (B7 — three-way, inline per L15)

    private var treatmentSegment: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: 5) {
                treatmentButton(.none, "None", "lattice to the edge")
                treatmentButton(.rim, "Rim only", "flat-face edges")
                treatmentButton(.fullSkin, "Full skin", "rim + faces")
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .fill(RGBA(0, 0, 0, 0.34).color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
            // DEFECT 4 (task 2026-08-03-variant-postprocessing-fix). "Rim only"
            // dresses ANALYTIC plane pairs, and an optimized part has none, so it is
            // identically zero geometry. Said HERE, at the control, before the run —
            // not as `rim_elements: 0` in a receipt afterwards.
            if let why = boundaryEmitsNothingWarning {
                Text(why)
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// nil ⇒ the chosen boundary treatment can produce geometry on this part.
    var boundaryEmitsNothingWarning: String? {
        LatticeCoreCapability.boundaryProducesNothing(
            skinJobValue: project.lattice.boundary.jobSkinValue,
            // Every lattice run this page can start is over a VOXEL design: either
            // the optimizer's output (the variants entry) or a fresh ladder's. There
            // is no analytic-face path here to be wrong about.
            voxelDerived: true)
    }

    private func treatmentButton(_ t: LatticeBoundaryTreatment, _ name: String, _ hint: String) -> some View {
        let on = project.lattice.boundary == t
        return Button { project.lattice.boundary = t } label: {
            VStack(spacing: 2) {
                Text(name).dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                // 0.6, nudged off the prototype's value — the band-literal grep test
                // scans this file and the exact prototype opacity collides with a
                // forbidden band number.
                Text(hint).font(.system(size: 10)).opacity(0.6)
            }
            .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textSecondary).color)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                .fill(on ? DS.Color.accent.color : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: bottom-right cluster (L16/L17): Preview · Refresh · Review · Optimize

    private var bottomRightCluster: some View {
        VStack(alignment: .trailing, spacing: LatticeChromeLayout.reviewDrawerToCluster) {
            if page.reviewOpen { reviewDrawer }
            HStack(spacing: LatticeChromeLayout.bottomClusterSpacing) {
                previewToggleButton
                if previewOn { previewRefreshButton }
                reviewButton
                // L3: the simulation button is BOTTOM RIGHT, not top, not floating.
                runSimButton
                optimizeButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, LatticeChromeLayout.edge).padding(.bottom, LatticeChromeLayout.edge)
    }

    /// L17: the ONLY preview control — a plain on/off toggle.
    private var previewToggleButton: some View {
        Button {
            previewOn.toggle()
            if previewOn {
                page.post(note: "Preview is indicative — the built lattice is generated at optimize time.")
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: previewOn ? "cube.transparent.fill" : "cube.transparent")
                    .font(.system(size: 15, weight: .bold))
                Text(previewOn ? "Preview on" : "Preview")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle((previewOn ? DS.Color.warning : DS.Color.textSecondary).color)
            .padding(.horizontal, DS.Space.l).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(previewOn ? DS.Color.warning.opacity(0.12).color : DS.Surface.bar.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                    .strokeBorder(previewOn ? DS.Color.warning.opacity(0.4).color
                                            : DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(previewOn ? "Turn preview off" : "Turn preview on")
    }

    /// L17: the separate Refresh — re-runs the preview with the current settings.
    private var previewRefreshButton: some View {
        Button { onRefreshPreview() } label: {
            VStack(spacing: 2) {
                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .bold))
                Text("Refresh").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.horizontal, DS.Space.l).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(DS.Surface.bar.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                    .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh preview")
    }

    /// L16: Review — a drawer with the full settings summary, not a ladder pane.
    private var reviewButton: some View {
        Button { page.reviewOpen.toggle() } label: {
            VStack(spacing: 2) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 15, weight: .bold))
                Text("Review").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.horizontal, DS.Space.l).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(page.reviewOpen ? DS.Color.fillSelected.color : DS.Surface.bar.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                    .strokeBorder(page.reviewOpen ? DS.Color.strokeStrong.color
                                                  : DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Review settings")
    }

    private var reviewDrawer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("REVIEW").font(.system(size: 11, weight: .semibold)).tracking(0.7)
                .foregroundStyle(DS.Color.textQuaternary.color)
            summaryRow("Topology", topologyDisplayName
                + (selectedRow.map { $0.certifiable && $0.generatable } == true ? "" : " (can't run)"),
                warn: selectedRow.map { !($0.certifiable && $0.generatable) } ?? true)
            summaryRow("Cell / density",
                       "\(cellSummaryText) · \(densityRangeText)",
                       warn: bounds.cellOverCeiling)
            summaryRow("Density mode",
                       project.lattice.densityMode == .auto ? "Auto (graded from this run's field)" : "Uniform",
                       warn: false)
            summaryRow("Regions",
                       "\(roleGroupCount) group role\(roleGroupCount == 1 ? "" : "s") · \(regionCount) region\(regionCount == 1 ? "" : "s") · \(clearanceCount) keep-clear",
                       warn: false)
            summaryRow("Boundary", boundaryTitle, warn: false)
            summaryRow("Job", project.lattice.enabled ? "Topology + lattice" : "Topology only", warn: false)
            if variantContext != nil { forecastSection }
        }
        .padding(DS.Space.l)
        .frame(width: 348, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .fill(DS.Surface.sheet.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    private var boundaryTitle: String {
        switch project.lattice.boundary {
        case .none: return "None"
        case .rim: return "Rim only"
        case .fullSkin: return "Full skin · diagrid"
        }
    }

    /// The pre-flight forecast, in full: the headline, every reason with its own
    /// count, and the remedies core MEASURED by re-running the grading law. This is
    /// the surface the maintainer needed and did not have — the numbers were all
    /// computable in under a second, and he got them from a receipt an hour later.
    @ViewBuilder private var forecastSection: some View {
        let p = forecastPanel
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Rectangle().fill(DS.Color.strokePanel.color).frame(height: 1)
                .padding(.vertical, DS.Space.xs)
            Text(p.title.uppercased()).font(.system(size: 11, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle((p.warn ? DS.Color.warning : DS.Color.textQuaternary).color)
            if let placeholder = p.placeholder {
                Text(placeholder).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let headline = p.headline {
                Text(headline).dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                    .foregroundStyle((p.warn ? DS.Color.warning : DS.Color.textPrimary).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(p.reasons.enumerated()), id: \.offset) { _, line in
                Text("• " + line).dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(p.advice.enumerated()), id: \.offset) { _, line in
                Text("→ " + line).dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            ([p.title, p.placeholder, p.headline] + p.reasons + p.advice)
                .compactMap { $0 }.joined(separator: ". "))
    }

    private func summaryRow(_ k: String, _ v: String, warn: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text(k).dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textPrimary.opacity(0.48).color)
            Spacer()
            Text(v).dsStyle(DS.TypeScale.callout).fontWeight(.semibold)
                .foregroundStyle((warn ? DS.Color.warning : DS.Color.textPrimary).color)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 34)
    }

    /// The action row. BAR Z7: entered from a variant there are TWO genuinely
    /// different jobs here — lattice THIS variant (minutes, no ladder) and re-run
    /// the whole ladder from the original part (hours) — and they get two
    /// buttons that each say which one they are. Entered from the workspace
    /// there is only Optimize, exactly as before.
    private var actions: LatticePageActions {
        LatticePageActions.compute(variant: variantContext,
                                   optimizeSurface: optimizeSurface,
                                   running: optimizing,
                                   forecast: forecast.forecast(for: forecastJob))
    }

    /// THE FORECAST, IN THE REVIEW DRAWER (bar F3). The button carries the refusal
    /// in one line; this carries the whole answer — every reason with its count and
    /// every remedy core actually measured — on the surface whose entire job is
    /// "read this before you spend a run".
    private var forecastPanel: LatticeForecastPanel {
        LatticeForecastPanel.compute(
            state: forecast.state,
            describesCurrentJob: forecastJob != nil && forecast.describes == forecastJob)
    }

    private var optimizeButton: some View {
        let a = actions
        return HStack(spacing: DS.Space.m) {
            if let re = a.relattice {
                actionButton(re, action: onRelattice)
            }
            actionButton(a.optimize, action: onOptimize)
        }
    }

    private func actionButton(_ a: LatticePageActions.Action,
                              action: @escaping () -> Void) -> some View {
        // The PRIMARY action wears the accent; a secondary one is a bordered
        // panel. Two visibly different weights, so the destructive-of-time
        // choice (re-running the whole ladder) is never the one a thumb lands on
        // by default.
        let tint: RGBA = a.primary ? DS.Color.accent : DS.Surface.panel
        return Button {
            guard a.enabled else { return }
            action()
        } label: {
            VStack(spacing: 2) {
                Text(a.label).dsStyle(DS.TypeScale.headline)
                Text(a.sub).font(.system(size: 11.5, weight: .semibold)).opacity(0.72)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle((a.enabled ? DS.Color.textPrimary : DS.Color.textDisabled).color)
            .padding(.horizontal, DS.Space.xl4).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(a.enabled ? tint.color : DS.Color.fillDisabled.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                    .strokeBorder(DS.Color.strokeSubtle.color,
                                  lineWidth: a.primary ? 0 : 1)))
            .dsShadow(a.enabled && a.primary ? DS.Shadow.accentGlow : DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .disabled(!a.enabled)
        .accessibilityLabel(a.label)
        .accessibilityHint(a.sub)
    }

    // MARK: entry gate (B1)

    private var gateOverlay: some View {
        ZStack {
            DS.Color.scrim.color.ignoresSafeArea()
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                HStack(spacing: DS.Space.ml) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13)
                            .fill(DS.Color.warning.opacity(0.16).color)
                            .frame(width: 42, height: 42)
                        Text("!").font(.system(size: 21, weight: .bold))
                            .foregroundStyle(DS.Color.warning.color)
                    }
                    Text(gate.title).dsStyle(DS.TypeScale.title)
                }
                VStack(spacing: DS.Space.s) {
                    ForEach(gate.items, id: \.name) { item in
                        HStack(spacing: DS.Space.m) {
                            Image(systemName: item.satisfied ? "checkmark" : "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle((item.satisfied ? DS.Color.okGreen : DS.Color.warning).color)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).dsStyle(DS.TypeScale.bodyStrong)
                                Text(item.detail).dsStyle(DS.TypeScale.caption2)
                                    .foregroundStyle(DS.Color.textPrimary.opacity(0.5).color)
                            }
                            Spacer()
                            if let fix = item.fixLabel {
                                Button { onBackToSetup() } label: {
                                    Text(fix).dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                                        .foregroundStyle(DS.Color.textPrimary.color)
                                        .padding(.horizontal, DS.Space.ml).frame(height: 44)
                                        .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                                            .fill(DS.Color.fillDisabled.color)
                                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field)
                                                .strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, DS.Space.ml).frame(minHeight: 58)
                        .background(RoundedRectangle(cornerRadius: 15)
                            .fill((item.satisfied ? DS.Color.okGreen : DS.Color.warning).opacity(0.10).color)
                            .overlay(RoundedRectangle(cornerRadius: 15)
                                .strokeBorder((item.satisfied ? DS.Color.okGreen : DS.Color.warning)
                                    .opacity(0.29).color, lineWidth: 1)))
                    }
                }
                Button { onBackToSetup() } label: {
                    Text(gate.ctaLabel).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                            .fill(DS.Color.accent.color))
                }
                .buttonStyle(.plain)
            }
            .padding(DS.Space.xl5)
            .frame(maxWidth: 540)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet)
                .fill(DS.Surface.dialog.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet)
                    .strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.sheet)
            .padding(DS.Space.xl4)
        }
    }

    // MARK: shared bits

    @ViewBuilder
    private func card<Content: View>(warning: Bool = false,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.ml)
            .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .fill(warning ? DS.Color.warning.opacity(0.10).color : DS.Color.fillSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                    .strokeBorder(warning ? DS.Color.warning.opacity(0.45).color
                                          : DS.Color.strokePanel.color, lineWidth: 1)))
    }

    private func segment(_ names: [String], selected: Int, enabled: [Bool],
                         pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                Button { if enabled[i] { pick(i) } } label: {
                    Text(n).dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                        .foregroundStyle((i == selected ? DS.Color.textPrimary
                                          : enabled[i] ? DS.Color.textSecondary
                                          : DS.Color.textDisabled).color)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                            .fill(i == selected ? DS.Color.accent.color : .clear))
                }
                .buttonStyle(.plain)
                .disabled(!enabled[i])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control)
            .fill(RGBA(0, 0, 0, 0.34).color))
    }
}

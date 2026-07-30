// LatticePage.swift — the full-screen lattice page (handoff 2026-07-30-lattice-page),
// implementing the approved design docs/design/lattice-page/latticePage.html
// (direction A "Ladder": one panel, a SINGLE flat list, sub-panes pushed in place).
//
// The page is CHROME ONLY: it renders over the workspace's live stage (mesh view +
// raymarched strut preview), which stays mounted underneath — the workspace hides
// its own chrome while the page is open (one stage, never two).
//
// DATA RULES (the bars):
//  B0  the topology picker is computed from CORE's certifiable ∪ generatable sets —
//      nothing here authors a topology name.
//  B0b the density band shown is core's for the SELECTED topology.
//  B1  the entry gate covers the page until ≥1 anchor AND ≥1 load, and STATES
//      what is missing.
//  B4  the one-voxel minimum is LIVE (longest extent / resolution), never a constant.
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
    /// The strut-preview toggle, owned by the workspace (the stage layer is its).
    @Binding var previewOn: Bool
    /// Base Optimize enablement + summary from the workspace (same rules as page one).
    let baseCanOptimize: Bool
    let baseSummary: String
    let onOptimize: () -> Void
    let onClose: () -> Void
    /// Back to Setup (closes the page; the workspace is the setup surface).
    let onBackToSetup: () -> Void
    /// TEST SEAM for the offscreen evidence captures: ImageRenderer does not
    /// render platform-backed containers (ScrollView), so the evidence generator
    /// renders the panel as a plain stack. Production always scrolls.
    let staticRender: Bool

    public init(model: AppModel, project: ProjectModel, run: RunModel,
                sim: LatticeSimModel, page: LatticePageModel,
                variantField: LatticeDemandField? = nil,
                previewOn: Binding<Bool>,
                baseCanOptimize: Bool, baseSummary: String,
                onOptimize: @escaping () -> Void,
                onClose: @escaping () -> Void,
                onBackToSetup: @escaping () -> Void,
                staticRender: Bool = false) {
        self.model = model
        self.project = project
        self.run = run
        self.sim = sim
        self.page = page
        self.variantField = variantField
        self._previewOn = previewOn
        self.baseCanOptimize = baseCanOptimize
        self.baseSummary = baseSummary
        self.onOptimize = onOptimize
        self.onClose = onClose
        self.onBackToSetup = onBackToSetup
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

    /// LIVE one-voxel minimum: longest bbox extent / resolution (B4).
    private var voxelMM: Double? {
        guard let mesh = project.viewerMesh else { return nil }
        return VoxelFit.spacing(forBounds: mesh.bounds, resolution: project.quality.resolution)
    }
    private var longestExtentMM: Double {
        guard let mesh = project.viewerMesh else { return 0 }
        let e = mesh.bounds.max - mesh.bounds.min
        return Double(max(e.x, max(e.y, e.z)))
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
            running: optimizing)
    }

    private var clearanceCount: Int { project.clearanceSpecs().count }
    private var includeCount: Int { project.lattice.includePrimitives.count }
    private var excludeFaceCount: Int {
        guard let gid = project.latticeExcludeGroupID(createIfNeeded: false),
              let g = groups.first(where: { $0.id == gid }) else { return 0 }
        return g.faces.count
    }
    private var paintedFaceCount: Int {
        project.lattice.paintedIncludeFaces.count + excludeFaceCount
    }

    // MARK: body

    public var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            ZStack(alignment: .topLeading) {
                topLeftRow
                fromSetupBar.padding(.top, 74)
                topRightColumn
                if let b = banner { bannerView(b) }
                if portrait {
                    panelView
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, DS.Space.l)
                        .frame(maxHeight: geo.size.height * 0.46)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 104)
                    chipColumn
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 128).padding(.trailing, DS.Space.l)
                } else {
                    panelView
                        .frame(width: 348)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 136).padding(.bottom, 104)
                        .padding(.leading, DS.Space.xl4)
                    chipColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, DS.Space.xl4).padding(.bottom, 104)
                }
                bottomRow
                if !gate.satisfied { gateOverlay }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: top-left: back · title · undo/redo

    private var topLeftRow: some View {
        HStack(spacing: DS.Space.m) {
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
        .padding(.leading, DS.Space.xl4)
    }

    private var loadLabel: String {
        let kg = force.totalLoadKg(in: groups)
        return kg > 0 ? String(format: "%.0f kg load", kg) : "\(loads) load\(loads == 1 ? "" : "s")"
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

    // MARK: top-right: RUN SIM

    private var topRightColumn: some View {
        VStack(alignment: .trailing, spacing: DS.Space.xs) {
            Button {
                guard !simGate.blocked, let ctx = model.makeLatticeSimContext() else { return }
                sim.run(ctx)
            } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                    Text("RUN SIM").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                }
                .foregroundStyle((simGate.blocked ? DS.Color.textDisabled : DS.Color.textPrimary).color)
                .padding(.horizontal, DS.Space.xl).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill((simGate.blocked ? DS.Color.fillDisabled : DS.Surface.panel).color)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                        .strokeBorder((simGate.blocked ? DS.Color.strokeSubtle : DS.Color.strokeStrong).color,
                                      lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .disabled(simGate.blocked)
            .accessibilityLabel("Run sim")
            if let reason = simGate.reason {
                Text(reason)
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 236, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Clear the workspace's always-on orientation gizmo in the absolute corner.
        .padding(.trailing, 130 + DS.Space.xl4).padding(.top, DS.Space.xl3)
    }

    // MARK: status banner

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
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, DS.Space.xl3)
        .dsShadow(DS.Shadow.panel)
    }

    private func bannerTint(_ k: LatticePageBanner.Kind) -> RGBA {
        switch k {
        case .simRunning: return DS.Color.accent
        case .simComplete: return DS.Color.okGreen
        case .simStale: return DS.Color.warning
        case .optimizing: return RGBA(hex: 0x5E5CE6)
        case .failed: return DS.Color.danger
        }
    }
    private func bannerGlyph(_ k: LatticePageBanner.Kind) -> String {
        switch k {
        case .simRunning, .optimizing: return "circle.fill"
        case .simComplete: return "checkmark"
        case .simStale: return "exclamationmark"
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
        case .simComplete: break
        }
    }

    // MARK: the panel

    private var panelView: some View {
        VStack(spacing: 0) {
            if page.panelMinimized {
                minimizedHeader
            } else {
                panelHeader
                if staticRender {
                    VStack(spacing: DS.Space.s) { paneContent }
                        .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.m)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: DS.Space.s) { paneContent }
                            .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.m)
                    }
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

    private var paneTitle: (kicker: String, title: String) {
        switch page.pane {
        case nil: return ("Part", "Lattice")
        case .topology: return ("Lattice", "Topology")
        case .cellDensity: return ("Lattice", "Cell & density")
        case .regions: return ("Lattice", "Regions")
        case .primitive: return ("Primitive", primitiveName ?? "")
        case .paint: return ("Face set", "Painted faces")
        case .boundary: return ("Lattice", "Boundary & finish")
        case .review: return ("Lattice", "Review & run")
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
                Text(paneTitle.kicker.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(DS.Color.textQuaternary.color)
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
        case .regions: regionsPane
        case .primitive(let id): primitivePane(id)
        case .paint: paintPane
        case .boundary: boundaryPane
        case .review: reviewPane
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
            // 3 · Cell size (band bar is advisory: core's cells-per-member floor)
            ladderRow(key: "Cell size",
                      value: String(format: "%.1f mm", project.lattice.cellMM),
                      flag: nil, flagTint: nil, chevron: true) {
                if let c = bounds.cellCeilingMM {
                    bandCaption(ok: !bounds.cellOverCeiling,
                                text: bounds.cellOverCeiling ? "over ceiling" : "≤ \(String(format: "%.1f", c)) mm")
                }
            } action: { page.go(.cellDensity) }
            // 4 · Density range (the band IS core's, per topology — B0b)
            ladderRow(key: "Density range", value: densityRangeText,
                      flag: nil, flagTint: nil, chevron: true) {
                if limits.certifiable { miniBand }
            } action: { page.go(.cellDensity) }
            // 5 · Regions & faces
            ladderRow(key: "Regions & faces",
                      value: "\(clearanceCount + includeCount) primitives · \(paintedFaceCount) faces",
                      flag: nil, flagTint: nil, chevron: true) { EmptyView() } action: { page.go(.regions) }
            // 6 · Boundary & finish
            ladderRow(key: "Boundary & finish", value: boundarySummary,
                      flag: nil, flagTint: nil, chevron: true) { EmptyView() } action: { page.go(.boundary) }
            // 7 · Review & run (deviation from the prototype's dir-A ladder, which
            // defined the pane but wired no row to it — every pane must be reachable).
            ladderRow(key: "Review & run", value: project.lattice.enabled ? "Topology + lattice" : "Topology only",
                      flag: nil, flagTint: nil, chevron: true) { EmptyView() } action: { page.go(.review) }
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

    private var boundarySummary: String {
        let t: String
        switch project.lattice.boundary {
        case .none: t = "None"
        case .rim: t = "Rim only"
        case .fullSkin: t = "Full skin"
        }
        return "\(t) · \(project.lattice.densityMode == .auto ? "auto density" : "uniform")"
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

    private func bandCaption(ok: Bool, text: String) -> some View {
        Text(text).font(.system(size: 9.5))
            .foregroundStyle((ok ? DS.Color.textPrimary.opacity(0.34) : DS.Color.warning).color)
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

    // MARK: topology pane (B0 — core truth only)

    private var topologyPane: some View {
        VStack(spacing: 7) {
            ForEach(topologyRows) { row in
                Button { project.lattice.topologyID = row.id } label: {
                    HStack(spacing: DS.Space.sm) {
                        Text(row.displayName).dsStyle(DS.TypeScale.bodyStrong)
                        Spacer(minLength: DS.Space.s)
                        topoRowBadge(row)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(DS.Color.accent.color)
                            .opacity(project.lattice.topologyID == row.id ? 1 : 0)
                    }
                    .padding(.horizontal, DS.Space.ml).frame(minHeight: 54)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(project.lattice.topologyID == row.id
                            ? DS.Color.accent.opacity(0.16).color : DS.Color.fillSubtle.color)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                            .strokeBorder(project.lattice.topologyID == row.id
                                ? DS.Color.accent.opacity(0.45).color : DS.Color.strokePanel.color,
                                lineWidth: 1)))
                }
                .buttonStyle(.plain)
            }
            if let reason = bounds.generatableReason {
                Text(reason).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.warning.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DS.Space.xs)
            }
        }
    }

    private func topoRowBadge(_ row: LatticeTopologyRow) -> some View {
        let runs = row.certifiable && row.generatable
        let tint = runs ? DS.Color.okGreen : DS.Color.warning
        return Text(row.badge)
            .font(.system(size: 10.5, weight: .bold)).tracking(0.3)
            .foregroundStyle(tint.color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(runs ? DS.Color.okGreen.opacity(0.14).color : .clear)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tint.opacity(0.7).color,
                                  style: StrokeStyle(lineWidth: 1, dash: runs ? [] : [3, 3]))))
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: cell + density pane (B0b — the band is core's, per topology)

    private var cellDensityPane: some View {
        VStack(spacing: DS.Space.sm) {
            // Cell size card
            card {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cell size").dsStyle(DS.TypeScale.body)
                    Spacer()
                    Text(String(format: "%.1f mm", project.lattice.cellMM))
                        .dsStyle(DS.TypeScale.headline)
                }
                Slider(value: Binding(get: { project.lattice.cellMM },
                                      set: { project.lattice.cellMM = ($0 * 2).rounded() / 2 }),
                       in: 2...20)
                    .tint(DS.Color.accent.color)
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
                    Text(densityRangeText).dsStyle(DS.TypeScale.headline)
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
            // Density MODE — uniform vs auto (B6). The prototype placed this on the
            // skin; core's skin has no density knob, so the mode governs the LATTICE
            // density (deviation justified in the handoff).
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
                            ? "Auto grades the preview from: \(prov)"
                            : "Field available: \(prov)")
                            .dsStyle(DS.TypeScale.caption)
                            .foregroundStyle((autoGate.stale ? DS.Color.warning : DS.Color.textSecondary).color)
                        if autoGate.stale { Text("stale").dsStyle(DS.TypeScale.caption)
                            .foregroundStyle(DS.Color.warning.color) }
                    }
                }
                if project.lattice.densityMode == .auto {
                    Text("Auto can't ride an optimize job yet — it grades the preview; switch to Uniform to run.")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.warning.color)
                }
            }
        }
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

    // MARK: regions pane (B3 — three roles, three real concepts)

    private var regionsPane: some View {
        VStack(spacing: DS.Space.s) {
            roleCard(.clearance, count: clearanceCount,
                     items: clearanceItems, addEnabled: true,
                     addAction: {
                         if let (_, pid) = project.addLatticeClearancePrimitive(.bolt) {
                             page.go(.primitive(pid))
                         }
                     })
            roleCard(.include, count: includeCount,
                     items: includeItems, addEnabled: true,
                     addAction: {
                         if let id = project.addLatticeIncludePrimitive(.bolt) {
                             page.go(.primitive(id))
                         }
                     })
            roleCard(.exclude, count: excludeFaceCount,
                     items: [], addEnabled: false,
                     addAction: {})
            Text("Include regions scope the preview and the report — the job lattices the whole solid interior (core's schema carries no region yet). Exclude works by PAINTING faces solid (a real job field); exclude PRIMITIVES have no job field yet, so none can be placed.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textQuaternary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct RegionItem: Identifiable {
        let id: UUID
        let name: String
        let size: String
        let belowVoxel: Bool
    }

    private var clearanceItems: [RegionItem] {
        var out: [RegionItem] = []
        for (group, prims) in force.allManualPrimitives {
            _ = group
            for p in prims {
                out.append(RegionItem(id: p.id, name: "Keep-clear \(p.kind == .bolt ? "bore" : "slab")",
                                      size: sizeText(p), belowVoxel: minDimMM(p) < (voxelMM ?? 0)))
            }
        }
        return out
    }
    private var includeItems: [RegionItem] {
        project.lattice.includePrimitives.map {
            RegionItem(id: $0.id, name: $0.kind == .bolt ? "Lattice cylinder" : "Lattice slab",
                       size: sizeText($0), belowVoxel: minDimMM($0) < (voxelMM ?? 0))
        }
    }

    private func sizeText(_ p: ManualPrimitive) -> String {
        switch p.kind {
        case .bolt: return String(format: "ø%.1f × %.1f", 2 * p.radiusMM, 2 * p.halfLengthMM)
        case .face: return String(format: "%.1f × %.1f", 2 * p.halfUMM, 2 * p.halfWMM)
        }
    }
    private func minDimMM(_ p: ManualPrimitive) -> Double {
        switch p.kind {
        case .bolt: return Swift.min(2 * p.radiusMM, 2 * p.halfLengthMM)
        case .face: return Swift.min(2 * p.halfUMM, 2 * p.halfWMM)
        }
    }

    private func roleTint(_ role: LatticeRegionRole) -> RGBA {
        switch role {
        case .clearance: return DS.Color.danger
        case .include: return DS.Color.accent
        case .exclude: return DS.Color.accentPurple
        }
    }

    private func roleCard(_ role: LatticeRegionRole, count: Int, items: [RegionItem],
                          addEnabled: Bool, addAction: @escaping () -> Void) -> some View {
        let open = page.openRole == role
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { page.openRole = role } label: {
                    HStack(spacing: DS.Space.sm) {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(roleTint(role).color,
                                          style: StrokeStyle(lineWidth: 1.7,
                                                             dash: role == .clearance ? [3, 3] : []))
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(role == .clearance ? .clear : roleTint(role).opacity(0.3).color))
                            .frame(width: 25, height: 25)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(role.displayName).dsStyle(DS.TypeScale.bodyStrong)
                            Text(role.subtitle).font(.system(size: 11))
                                .foregroundStyle(DS.Color.textPrimary.opacity(0.44).color)
                        }
                        Spacer()
                        Text("\(count)").dsStyle(DS.TypeScale.callout).fontWeight(.bold)
                            .foregroundStyle(roleTint(role).color)
                    }
                    .padding(.horizontal, DS.Space.ml).frame(minHeight: 60)
                }
                .buttonStyle(.plain)
                Button(action: addAction) {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle((addEnabled ? roleTint(role) : DS.Color.textDisabled).color)
                        .frame(width: 52, height: 60)
                        .background(DS.Color.fillSubtle.color)
                }
                .buttonStyle(.plain)
                .disabled(!addEnabled)
                .accessibilityLabel("Add \(role.displayName) region")
            }
            if open {
                VStack(spacing: DS.Space.xs) {
                    ForEach(items) { it in
                        Button { page.go(.primitive(it.id)) } label: {
                            HStack(spacing: DS.Space.s) {
                                Text(it.name).dsStyle(DS.TypeScale.callout)
                                Spacer()
                                Text(it.size).dsStyle(DS.TypeScale.caption2)
                                    .foregroundStyle(DS.Color.textQuaternary.color)
                                if it.belowVoxel {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DS.Color.warning.color)
                                }
                            }
                            .padding(.horizontal, DS.Space.m).frame(minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                                .fill(DS.Color.fillSubtle.color))
                        }
                        .buttonStyle(.plain)
                    }
                    if role != .clearance {
                        Button { page.paintRole = role; page.go(.paint) } label: {
                            Text("Paint faces — \(role.displayName)")
                                .dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                                .foregroundStyle(DS.Color.textPrimary.opacity(0.7).color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, DS.Space.m).frame(minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                                    .strokeBorder(DS.Color.textPrimary.opacity(0.18).color,
                                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.Space.s).padding(.bottom, DS.Space.s)
            }
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
            .fill(open ? DS.Color.textPrimary.opacity(0.07).color : DS.Color.fillSubtle.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .strokeBorder(open ? DS.Color.strokeStrong.color : DS.Color.strokePanel.color, lineWidth: 1)))
    }

    // MARK: primitive pane (B4 — live voxel minimum + who-honours lanes)

    private enum PrimRef {
        case include(ManualPrimitive)
        case clearance(group: UUID, prim: ManualPrimitive)
    }

    private func findPrimitive(_ id: UUID) -> PrimRef? {
        if let p = project.lattice.includePrimitives.first(where: { $0.id == id }) {
            return .include(p)
        }
        for (group, prims) in force.allManualPrimitives {
            if let p = prims.first(where: { $0.id == id }) {
                return .clearance(group: group, prim: p)
            }
        }
        return nil
    }

    private var primitiveName: String? {
        guard case .primitive(let id) = page.pane, let ref = findPrimitive(id) else { return nil }
        switch ref {
        case .include(let p): return p.kind == .bolt ? "Lattice cylinder" : "Lattice slab"
        case .clearance(let p): return p.prim.kind == .bolt ? "Keep-clear bore" : "Keep-clear slab"
        }
    }

    @ViewBuilder private func primitivePane(_ id: UUID) -> some View {
        if let ref = findPrimitive(id) {
            let prim: ManualPrimitive = { switch ref { case .include(let p): return p
                                                       case .clearance(_, let p): return p } }()
            let role: LatticeRegionRole = { switch ref { case .include: return .include
                                                         case .clearance: return .clearance } }()
            VStack(spacing: DS.Space.s) {
                Text("Drag the primitive on the model to place it — values are absolute mm")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Shape (Cylinder / Slab — the two shapes the clearance schema carries;
                // the prototype's Sphere has no job carrier, deviation in the handoff).
                segment(["Cylinder", "Slab"], selected: prim.kind == .bolt ? 0 : 1,
                        enabled: [true, true]) { i in
                    var p = prim
                    p.kind = i == 0 ? .bolt : .face
                    writePrimitive(ref, p)
                }
                dimsFields(ref, prim)
                // Role (Clear / Lattice; Solid has no primitive carrier — disabled).
                segment([LatticeRegionRole.clearance.shortName,
                         LatticeRegionRole.include.shortName,
                         LatticeRegionRole.exclude.shortName],
                        selected: role == .clearance ? 0 : 1,
                        enabled: [true, true, false]) { i in
                    guard (i == 0 ? LatticeRegionRole.clearance : .include) != role else { return }
                    switchRole(ref, prim)
                }
                Text("“Solid” (lattice-exclude) has no primitive job field yet — paint faces instead.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                honoursCard(sizeMM: minDimMM(prim)) {
                    var p = prim
                    if let v = voxelMM {
                        switch p.kind {
                        case .bolt:
                            p.radiusMM = Swift.max(p.radiusMM, v / 2)
                            p.halfLengthMM = Swift.max(p.halfLengthMM, v / 2)
                        case .face:
                            p.halfUMM = Swift.max(p.halfUMM, v / 2)
                            p.halfWMM = Swift.max(p.halfWMM, v / 2)
                        }
                        writePrimitive(ref, p)
                    }
                }
                Button {
                    deletePrimitive(ref)
                    page.go(.regions)
                } label: {
                    Text("Delete").dsStyle(DS.TypeScale.callout).fontWeight(.semibold)
                        .foregroundStyle(RGBA(hex: 0xFF6961).color)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                            .fill(DS.Color.danger.opacity(0.12).color)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                                .strokeBorder(DS.Color.danger.opacity(0.35).color, lineWidth: 1)))
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("This primitive no longer exists.").dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textSecondary.color)
        }
    }

    private func writePrimitive(_ ref: PrimRef, _ p: ManualPrimitive) {
        switch ref {
        case .include: project.updateLatticeIncludePrimitive(p)
        case .clearance(let group, _): project.force.updateManualPrimitive(p, in: group)
        }
    }
    private func deletePrimitive(_ ref: PrimRef) {
        switch ref {
        case .include(let p): project.removeLatticeIncludePrimitive(id: p.id)
        case .clearance(let group, let p): project.force.removeManualPrimitive(id: p.id, from: group)
        }
    }
    /// Move a primitive between the clearance and include stores (same geometry,
    /// different concept — the stores never share a record).
    private func switchRole(_ ref: PrimRef, _ p: ManualPrimitive) {
        deletePrimitive(ref)
        switch ref {
        case .include:
            if let (gid, _) = project.addLatticeClearancePrimitive(p.kind) {
                var moved = p
                for mp in project.force.manualPrimitives(for: gid) {
                    moved = ManualPrimitive(id: mp.id, kind: p.kind, center: p.center,
                                            axis: p.axis, radiusMM: p.radiusMM,
                                            halfLengthMM: p.halfLengthMM,
                                            halfUMM: p.halfUMM, halfWMM: p.halfWMM,
                                            override: p.override)
                    project.force.updateManualPrimitive(moved, in: gid)
                    page.go(.primitive(mp.id))
                }
            }
        case .clearance:
            project.lattice.includePrimitives.append(p)
            page.go(.primitive(p.id))
        }
    }

    @ViewBuilder private func dimsFields(_ ref: PrimRef, _ prim: ManualPrimitive) -> some View {
        HStack(spacing: 7) {
            switch prim.kind {
            case .bolt:
                dimField(ref, prim, label: "Diameter", value: 2 * prim.radiusMM) { p, v in
                    var q = p; q.radiusMM = v / 2; return q
                }
                dimField(ref, prim, label: "Height", value: 2 * prim.halfLengthMM) { p, v in
                    var q = p; q.halfLengthMM = v / 2; return q
                }
            case .face:
                dimField(ref, prim, label: "U span", value: 2 * prim.halfUMM) { p, v in
                    var q = p; q.halfUMM = v / 2; return q
                }
                dimField(ref, prim, label: "W span", value: 2 * prim.halfWMM) { p, v in
                    var q = p; q.halfWMM = v / 2; return q
                }
            }
        }
    }

    @State private var dimPadTarget: String? = nil

    private func dimField(_ ref: PrimRef, _ prim: ManualPrimitive, label: String,
                          value: Double,
                          apply: @escaping (ManualPrimitive, Double) -> ManualPrimitive) -> some View {
        let below = value < (voxelMM ?? 0)
        let key = "\(prim.id)-\(label)"
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(label) (mm)").font(.system(size: 11))
                .foregroundStyle(DS.Color.textQuaternary.color)
            Button { dimPadTarget = key } label: {
                Text(String(format: "%.1f", value))
                    .dsStyle(DS.TypeScale.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.sm).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                        .fill(DS.Color.textPrimary.opacity(0.07).color)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.field)
                            .strokeBorder(below ? DS.Color.warning.opacity(0.55).color
                                                : DS.Color.strokePanel.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .numberPad(Binding(get: { dimPadTarget == key },
                               set: { if !$0 { dimPadTarget = nil } }),
                       config: .init(title: label, unit: "mm", allowsDecimal: true),
                       seed: value) { v in
                if let v, v > 0 { writePrimitive(ref, apply(prim, v)) }
            }
        }
    }

    private func honoursCard(sizeMM: Double, snap: @escaping () -> Void) -> some View {
        let lanes = LatticeSizingLanes.compute(
            sizeMM: sizeMM, voxelMM: voxelMM ?? 0,
            resolution: project.quality.resolution, longestExtentMM: longestExtentMM)
        return card(warning: !lanes.honoured) {
            Text("WHO HONOURS \(String(format: "%.2f", sizeMM)) MM")
                .font(.system(size: 11, weight: .bold)).tracking(0.5)
                .foregroundStyle(DS.Color.textQuaternary.color)
            ForEach(lanes.lanes, id: \.name) { lane in
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: lane.honoured ? "checkmark" : "approximatelyequal")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle((lane.honoured ? DS.Color.okGreen : DS.Color.warning).color)
                        .frame(width: 18)
                    Text(lane.name).dsStyle(DS.TypeScale.caption)
                    Spacer()
                    Text(lane.verdict).dsStyle(DS.TypeScale.caption2).fontWeight(.semibold)
                        .foregroundStyle((lane.honoured ? DS.Color.okGreen : DS.Color.warning).color)
                }
                .frame(minHeight: 26)
            }
            Divider().overlay(DS.Color.strokeSubtle.color)
            HStack(spacing: DS.Space.sm) {
                Text(lanes.voxelLine).dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.48).color)
                Spacer()
                if !lanes.honoured {
                    Button(action: snap) {
                        Text("Snap to 1 voxel").dsStyle(DS.TypeScale.caption2).fontWeight(.semibold)
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
        }
    }

    // MARK: paint pane

    private var paintPane: some View {
        VStack(spacing: DS.Space.s) {
            segment([LatticeRegionRole.include.displayName, LatticeRegionRole.exclude.displayName],
                    selected: page.paintRole == .exclude ? 1 : 0, enabled: [true, true]) { i in
                page.paintRole = i == 1 ? .exclude : .include
            }
            card {
                if page.paintRole == .include {
                    HStack {
                        Text("Depth into part").dsStyle(DS.TypeScale.callout)
                        Spacer()
                        Text(String(format: "%.1f mm", project.lattice.paintDepthMM))
                            .dsStyle(DS.TypeScale.bodyStrong)
                    }
                    Slider(value: Binding(get: { project.lattice.paintDepthMM },
                                          set: { project.lattice.paintDepthMM = ($0 * 2).rounded() / 2 }),
                           in: 0.5...20)
                        .tint(DS.Color.accent.color)
                    Text("\(project.lattice.paintedIncludeFaces.count) faces painted · tap a face on the model to add or remove")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.48).color)
                } else {
                    Text("\(excludeFaceCount) faces painted · tap a face on the model to add or remove")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.48).color)
                    Text("Painted faces ship as face protections — the optimizer keeps their material SOLID (the same Protect the workspace has; depth uses the protect default).")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                }
            }
            if page.paintRole == .include {
                Text("Include-painted faces scope the PREVIEW only — no job field carries them yet (reported gap).")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: boundary pane (B7 — three-way, unrepresentable otherwise)

    private var boundaryPane: some View {
        VStack(spacing: DS.Space.sm) {
            treatmentSegment
            if project.lattice.boundary == .fullSkin {
                card {
                    HStack {
                        Text("Skin pattern").dsStyle(DS.TypeScale.callout)
                        Spacer()
                        Text("Diagrid").dsStyle(DS.TypeScale.bodyStrong)
                    }
                    Text("The anchored diagrid is core's one skin — its knots sit exactly where cut struts meet the surface, and its thickness follows core's own printability rule from your line width.")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                }
            }
            if project.lattice.boundary != .none {
                card {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "checkmark.shield.fill").font(.system(size: 13))
                            .foregroundStyle(DS.Color.okGreen.color)
                        Text("Clearance regions are always protected").dsStyle(DS.TypeScale.callout)
                    }
                    Text("Struts are cut back to every keep-clear wall exactly, and bores get a collar ring at the declared radius — core does this unconditionally; there is nothing to switch off.")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                }
            }
        }
    }

    private var treatmentSegment: some View {
        HStack(spacing: 5) {
            treatmentButton(.none, "None", "lattice to the edge")
            treatmentButton(.rim, "Rim only", "closed border")
            treatmentButton(.fullSkin, "Full skin", "rim + faces")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
            .fill(RGBAColorBlack.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
    }

    private var RGBAColorBlack: RGBA { RGBA(0, 0, 0, 0.34) }

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

    // MARK: review pane

    private var reviewPane: some View {
        VStack(spacing: DS.Space.s) {
            card {
                summaryRow("Topology", topologyDisplayName
                    + (selectedRow.map { $0.certifiable && $0.generatable } == true ? "" : " (can't run)"),
                    warn: selectedRow.map { !($0.certifiable && $0.generatable) } ?? true)
                summaryRow("Cell / density",
                           String(format: "%.1f mm · %@", project.lattice.cellMM, densityRangeText),
                           warn: bounds.cellOverCeiling)
                summaryRow("Density mode",
                           project.lattice.densityMode == .auto ? "Auto (preview only)" : "Uniform",
                           warn: project.lattice.densityMode == .auto)
                summaryRow("Regions", "\(clearanceCount + includeCount) primitives · \(paintedFaceCount) faces",
                           warn: false)
                summaryRow("Boundary", boundaryTitle, warn: false)
                summaryRow("Job", project.lattice.enabled ? "Topology + lattice" : "Topology only", warn: false)
            }
            Button { previewOn.toggle() } label: {
                HStack(spacing: DS.Space.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lattice preview").dsStyle(DS.TypeScale.bodyStrong)
                        Text("Indicative cells — not the built lattice").font(.system(size: 11))
                            .foregroundStyle(DS.Color.textPrimary.opacity(0.44).color)
                    }
                    Spacer()
                    Toggle("", isOn: $previewOn).labelsHidden().toggleStyle(.switch)
                        .tint(DS.Color.warning.color)
                }
                .padding(.horizontal, DS.Space.ml).frame(minHeight: 56)
                .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                    .fill(previewOn ? DS.Color.warning.opacity(0.12).color : DS.Color.fillSubtle.color)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                        .strokeBorder(previewOn ? DS.Color.warning.opacity(0.4).color
                                                : DS.Color.strokePanel.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
        }
    }

    private var boundaryTitle: String {
        switch project.lattice.boundary {
        case .none: return "None"
        case .rim: return "Rim only"
        case .fullSkin: return "Full skin · diagrid"
        }
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

    // MARK: chips

    private var chipColumn: some View {
        VStack(alignment: .trailing, spacing: 9) {
            chip(.paint, label: "Paint", value: "\(paintedFaceCount) faces",
                 tint: DS.Color.accentPurple,
                 hint: "\(paintedFaceCount) faces painted across include and exclude.",
                 actionLabel: "Edit paint") { page.go(.paint) }
            chip(.regions, label: "Regions", value: "\(clearanceCount + includeCount)",
                 tint: DS.Color.accent,
                 hint: "\(clearanceCount + includeCount) primitives across clearance and lattice-include.",
                 actionLabel: "Edit regions") { page.go(.regions) }
            chip(.preview, label: "Preview", value: previewOn ? "on" : "off",
                 tint: DS.Color.warning,
                 hint: "Indicative cell preview — not the built lattice.",
                 actionLabel: previewOn ? "Turn off" : "Turn on") { previewOn.toggle() }
        }
    }

    private func chip(_ id: LatticePageModel.Chip, label: String, value: String,
                      tint: RGBA, hint: String, actionLabel: String,
                      action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 9) {
            if page.openChip == id {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(label.uppercased()).font(.system(size: 12, weight: .bold)).tracking(0.5)
                        .foregroundStyle(DS.Color.textSecondary.color)
                    Text(hint).dsStyle(DS.TypeScale.callout)
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.75).color)
                    Button { page.openChip = nil; action() } label: {
                        Text(actionLabel).dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                                .fill(DS.Color.fillDisabled.color)
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field)
                                    .strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(DS.Space.ml).frame(minWidth: 220, maxWidth: 280)
                .background(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                    .fill(DS.Surface.sheet.color)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.valuePill)
                        .strokeBorder(tint.opacity(0.4).color, lineWidth: 1)))
                .dsShadow(DS.Shadow.panel)
            }
            Button { page.openChip = page.openChip == id ? nil : id } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(tint.color,
                                      style: StrokeStyle(lineWidth: 1.6,
                                                         dash: id == .preview && !previewOn ? [3, 3] : []))
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(id == .preview && !previewOn ? .clear : tint.opacity(0.32).color))
                        .frame(width: 16, height: 16)
                    Text(label).dsStyle(DS.TypeScale.body).fontWeight(.semibold)
                    Text(value).dsStyle(DS.TypeScale.caption2).fontWeight(.semibold)
                        .foregroundStyle(DS.Color.textSecondary.color)
                }
                .padding(.horizontal, DS.Space.ml).frame(minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 15)
                    .fill(page.openChip == id ? DS.Color.fillSelected.color : DS.Surface.bar.color)
                    .overlay(RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(page.openChip == id ? DS.Color.strokeStrong.color
                                                          : DS.Color.strokePanel.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: bottom row

    private var bottomRow: some View {
        HStack(alignment: .bottom) {
            Text(page.hint(gated: !gate.satisfied, previewOn: previewOn))
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textPrimary.opacity(0.5).color)
                .lineLimit(2)
                .padding(.vertical, 8).padding(.horizontal, DS.Space.l)
                .background(RoundedRectangle(cornerRadius: 15).fill(DS.Surface.bar.color)
                    .overlay(RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
                .frame(maxWidth: 430, alignment: .leading)
            Spacer()
            optimizeButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, DS.Space.xl4).padding(.bottom, DS.Space.xl4)
    }

    private var optimizeButton: some View {
        let s = optimizeSurface
        return Button {
            guard s.enabled else { return }
            onOptimize()
        } label: {
            VStack(spacing: 2) {
                Text(s.label).dsStyle(DS.TypeScale.headline)
                Text(s.sub).font(.system(size: 11.5, weight: .semibold)).opacity(0.72)
                    .lineLimit(1)
            }
            .foregroundStyle((s.enabled ? DS.Color.textPrimary : DS.Color.textDisabled).color)
            .padding(.horizontal, DS.Space.xl5).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(s.enabled ? DS.Color.accent.color : DS.Color.fillDisabled.color))
            .dsShadow(s.enabled ? DS.Shadow.accentGlow : DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .disabled(!s.enabled)
        .accessibilityLabel("Optimize")
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

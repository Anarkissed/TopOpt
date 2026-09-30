// FlexibleStagePage — the Flexible stage's page (task 2026-09-29-flexible-screens, A1).
//
// Layout follows the lattice Settings page (LatticeSetupWizard): the part fills the
// screen, "Exit" top-left in the accent capsule, a one-line notice top-centre, and ONE
// panel bottom-left (PageChrome.edge inset, DS.Surface.panel, DS.Radius.panel). ★ ROUND 3:
// its tabs are Face | Stamps | More, every row one line (FlexibleFacePanel); the page is
// always in X-ray; the legend sits on the trailing edge, centred.
//
// ★ NOTHING ON THIS PAGE COMPUTES A SQUISH NUMBER. It draws FlexibleStageModel's copies of
// core's results (M9). Numbers carry their tier and ± band (R7); a column core could not
// give a number for is drawn as "no number", never a guess.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

/// The live camera projection, kept OUTSIDE the page's own state so a camera move
/// redraws only the overlays that follow it — not the mesh view or the panel.
@MainActor
final class FlexibleProjectionBox: ObservableObject {
    @Published var projection: CameraProjection?
}

public struct FlexibleStagePage: View {
    @ObservedObject var project: ProjectModel
    @StateObject private var model: FlexibleStageModel
    @StateObject private var camera = OrbitCameraModel()
    @StateObject private var proj = FlexibleProjectionBox()
    let onExit: () -> Void

    // the overlay mesh and its per-vertex channels, rebuilt only when their inputs change
    @State private var overlay: FlexibleOverlayMesh?
    @State private var tints: [Float]?
    @State private var dents: [Float]?
    @State private var dentScale: Float = 0
    /// The shown dent's exaggeration, kept so the loop only rescales (FlexibleShownValues).
    @State private var dentExaggeration: Double = 0
    /// The dent loops only while a lattice is drawn; while he edits it holds still (round 3).
    @State private var dentAnimated = false
    @State private var padTarget: String?
    // the generated lattice: squish loop phase (0…1, 30 fps, the Results flex pattern)
    @State private var squishPhase: Double = 0
    /// ★ X-RAY VISION (maintainer, 2026-09-29): the body as a ghost, the dented map opaque,
    /// the lattice seen inside. ★ ROUND 3 (item 1.4): ALWAYS on on this page — the bend reads
    /// from any angle, even edge-on (img 1); the X-ray button under the gizmo is gone.
    private let xray = true
    @State private var showExport = false
    /// The panel's and the legend's frames (global), and the stage's — for the chips' keep-out.
    @State private var frames: [String: CGRect] = [:]
    private var keepOut: [CGRect] {
        guard let st = frames["stage"] else { return [] }
        return ["panel", "legend"].compactMap { frames[$0]?.offsetBy(dx: -st.minX, dy: -st.minY) }
    }
    private let ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    static let squishPeriodS = 2.4

    public init(project: ProjectModel, materialsPath: String?, stampsPath: String?,
                persist: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.project = project
        _model = StateObject(wrappedValue: FlexibleStageModel(
            project: project, materialsPath: materialsPath, stampsPath: stampsPath, persist: persist))
        self.onExit = onExit
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                DS.Color.background.color.ignoresSafeArea()
                stage
                exitButton
                notice
                panel
                    .frame(maxHeight: geo.size.height * 0.62, alignment: .bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, PageChrome.edge)
                    .padding(.bottom, PageChrome.edge)
                latticeControls
                FlexibleViewColumn(camera: camera)
                if showExport, let g = model.lattice { exportSheet(g) }
                // ★ THE LEGEND SITS ON THE TRAILING EDGE, VERTICALLY CENTRED (round 3, item 7:
                // "legends never cover buttons" — it covered Generate in the bottom corner)
                if dents != nil || model.checkStampShown != nil {
                    FlexibleLegend(model: model, drawnLattice: drawnLattice)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["legend": g.frame(in: .global)])
                        }.allowsHitTesting(false))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, PageChrome.edge)
                }
            }
        }
        .onAppear {
            if let b = project.viewerMesh?.bounds { camera.reframe(b) }
            model.openScene()
            rebuildOverlay()
        }
        .onChange(of: model.geometry.count) { _ in rebuildOverlay() }
        .onReceive(ticker) { _ in
            // ★ THE SQUISH, ON REPEAT (maintainer, 2026-09-29): only while a lattice is drawn;
            // the drawn map holds still while he edits (round 3)
            guard dentAnimated else { return }
            squishPhase = (squishPhase + (1.0 / 30.0) / Self.squishPeriodS).truncatingRemainder(dividingBy: 1)
            // ★ only the scale moves: the displacements and colours are rebuilt when the
            // design changes, never per frame (a whole-mesh rebuild at 30 fps on the M2 stand)
            if dents != nil { dentScale = Float(dentExaggeration * squishAmplitude) }
        }
        // ★ A FRESH LATTICE — Generate AND Generate again (keyed on the generation, not on
        // `lattice != nil`, which stayed true across a rebuild) — is shown squishing what can
        // be built, the densities it was made from, in X-ray: the 3D view, no stamp.
        .onChange(of: FlexibleLatticePreview.freshKey(model.lattice)) { gen in
            if gen != nil {
                model.showBuildable = true; model.tab = .face
                model.checkStampShown = nil
            }
            refreshChannels()
        }
        .onChange(of: model.stacks.count) { _ in rebuildOverlay() }
        .onChange(of: model.latticeBuilding) { _ in refreshChannels() }
        .onReceive(model.objectWillChange.debounce(for: .milliseconds(16), scheduler: RunLoop.main)) { _ in
            refreshChannels()
        }
        .onPreferenceChange(FlexibleKeepOutKey.self) { frames = $0 }
        .accessibilityIdentifier("flexible-stage-page")
    }

    // MARK: the stage

    /// The part's opacity while a dent is shown; the dented map itself stays opaque.
    static let dentBodyAlpha: Float = 0.3
    /// X-ray: the ghost's face-on opacity. The shader adds up to +0.5 toward the silhouette
    /// (MetalMeshView, tint flags.z), so the outline reads and the inside shows.
    static let xrayBodyAlpha: Float = 0.04

    /// The generated lattice while it is DRAWN: X-ray on, not being rebuilt, and still what the
    /// settings describe. The map and the dent then come from its own depths (FlexibleShownValues).
    private var drawnLattice: FlexibleGeneratedLattice? {
        FlexibleLatticePreview.drawn(model.lattice, xray: xray, building: model.latticeBuilding,
                                     checkStampShown: model.checkStampShown, stale: model.latticeIsStale)
    }

    /// The lattice owns the map (no stamp shown, not stale) — FlexibleLatticePreview.latticeShows.
    private var latticeShows: Bool {
        FlexibleLatticePreview.latticeShows(checkStampShown: model.checkStampShown, stale: model.latticeIsStale)
    }

    /// 0 → 1 → 0 over one period (FlexAnimation's cosine ease, Results screen) while the
    /// lattice is drawn; 1 (the full drawing, held still) otherwise.
    private var squishAmplitude: Double {
        dentAnimated ? 0.5 - 0.5 * cos(2 * .pi * squishPhase) : 1
    }

    /// The same settle the workspace draws with (gravity → down), so the part sits as it
    /// does on every other stage.
    private var settle: simd_quatf {
        project.force.settleRotation
            ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
    }

    private var stage: some View {
        ZStack {
            MetalMeshView(
                mesh: overlay?.mesh ?? project.viewerMesh, camera: camera,
                vertexTints: tints,
                settleRotation: settle, settleAnimated: false,
                faceToolActive: true,
                onPickFace: { fid in model.tapFace(Int(fid)) },
                // a split face: the tap's point picks the sector (FlexibleRegions)
                onPickPoint: { fid, pt in
                    model.tapFace(Int(fid), point: pt.map { SIMD3<Double>($0) })
                    return true
                },
                onProjection: { p in
                    // the renderer publishes world→clip; the part is drawn settled (rotated
                    // about its centre), so the overlays project MODEL points through both
                    let c = (overlay?.mesh ?? project.viewerMesh)?.bounds.center ?? .zero
                    let m = ViewerModelFrame.matrix(centre: c, rotation: settle)
                    let q = CameraProjection(viewProjection: p.viewProjection * m, viewportSize: p.viewportSize)
                    if proj.projection != q { proj.projection = q }
                },
                flexDisplacements: dents, flexScale: dentScale,
                // ★ ROUND 3 (item 1.1): the selected face's deepest squish as a prism × k
                clearanceVolumes: FlexibleDepthPrism.renderItems(model: model, k: dentExaggeration),
                // ★ THE DENT READS THROUGH THE PART (maintainer, 2026-09-29): while a dent is
                // shown the body drops to 30 % and the dented map stays at 100 %.
                bodyAlpha: xray ? Self.xrayBodyAlpha : (dents != nil ? Self.dentBodyAlpha : 1),
                // ★ THE LATTICE IS DRAWN IN THE MESH VIEW'S OWN PASSES (FlexibleLatticePass,
                // a third G-buffer writer — the way Structural and Aesthetic draw theirs), only
                // in X-ray, squished by the SAME flexScale as the dent (hidden, not torn down,
                // while a stamp owns the map).
                flexibleLattice: FlexibleLatticePreview.inputs(xray: xray, lattice: model.lattice,
                                                               building: model.latticeBuilding,
                                                               latticeShows: latticeShows))
            FlexibleStageOverlays(model: model, proj: proj, exaggeration: dentExaggeration, keepOut: keepOut)
        }
        .coordinateSpace(name: FlexibleStageSpace.name)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["stage": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .ignoresSafeArea()
    }

    private func rebuildOverlay() {
        overlay = FlexiblePageChannels.overlay(model: model)
        refreshChannels()
    }

    /// Per-column colours + the dent (FlexiblePageChannels — the page's one source).
    private func refreshChannels() {
        let c = FlexiblePageChannels.channels(model: model, overlay: overlay, xray: xray, drawnLattice: drawnLattice)
        tints = c.tints
        dents = c.dents
        dentExaggeration = c.exaggeration
        dentAnimated = c.animated
        dentScale = c.dents == nil ? 0 : Float(c.exaggeration * squishAmplitude)
    }

    // MARK: generate + export (FlexibleLatticeGeneration.swift, FlexibleExportSheet.swift — disabled until core)

    /// Bottom right, where the Settings wizard keeps "Refresh sample": Generate lattice,
    /// then Export and a show/hide for the lattice once it exists.
    private var latticeControls: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                Spacer()
                VStack(alignment: .trailing, spacing: DS.Space.s) {
                    if let why = model.latticeRefusal, model.lattice == nil {
                        Text(why).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 300, alignment: .trailing)
                            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                            .background(Capsule().fill(DS.Color.chipSolid.color))
                    }
                    if model.latticeIsStale {
                        Text("Settings changed since this lattice was made — generate again.")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.warning.color)
                            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                            .background(Capsule().fill(DS.Color.chipSolid.color))
                    }
                    if let e = model.latticeError {
                        Text(e).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.danger.color)
                            .frame(maxWidth: 320, alignment: .trailing)
                    }
                    HStack(spacing: DS.Space.s) {
                        if model.lattice != nil {
                            pill("Export", icon: "square.and.arrow.up", fill: DS.Color.accent, id: "flexible-export") {
                                showExport = true
                            }
                        }
                        pill(model.latticeBuilding ? "Generating…" : (model.lattice == nil ? "Generate lattice" : "Generate again"),
                             icon: "cube.transparent",
                             fill: model.latticeRefusal == nil && !model.latticeBuilding ? FlexibleStageStyle.accentToken : DS.Color.textTertiary,
                             id: "flexible-generate") {
                            model.generateLattice()
                        }
                        .disabled(model.latticeRefusal != nil || model.latticeBuilding)
                    }
                }
            }
            .padding(PageChrome.edge)
        }
    }

    private func pill(_ title: String, icon: String, fill: RGBA, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: icon).font(.system(size: 15, weight: .bold))
                Text(title).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, 12).padding(.horizontal, DS.Space.xl2)
            .background(Capsule().fill(fill.color))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func exportSheet(_ g: FlexibleGeneratedLattice) -> some View {
        // ★ EXPORTS WAIT ON CORE (maintainer, 2026-09-29): the modal says so, both cards disabled
        FlexibleExportSheet(summary: "\(g.topology.capitalized) · \(Int(g.tempC)) °C · \(model.material?.displayName ?? "")",
                            onClose: { showExport = false })
            .transition(.opacity)
            .zIndex(20)
    }

    // MARK: chrome

    private var exitButton: some View {
        VStack {
            HStack {
                Button {
                    model.save()
                    onExit()
                } label: {
                    Text("Exit")
                        .dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.vertical, 12).padding(.horizontal, DS.Space.xl5)
                        .background(Capsule().fill(DS.Color.accent.color))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-exit")
                // the project's own snapshot history: every Flexible setting is undoable (S5)
                ForEach([(true, "arrow.uturn.backward"), (false, "arrow.uturn.forward")], id: \.1) { undo, icon in
                    Button {
                        if undo { project.performUndo() } else { project.performRedo() }
                        model.recomputeAll()
                    } label: {
                        Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(DS.Color.chipSolid.color))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(undo ? "flexible-undo" : "flexible-redo")
                }
                Spacer()
            }
            Spacer()
        }
        .padding(PageChrome.edge)
    }

    /// ★ ONLY WHEN THERE IS SOMETHING TO SAY (verification of round 3: "only what is
    /// necessary"): opening, a failure, or "Tap a face on the part." — the permanent
    /// "no strength certificate" line is gone (it lives in the Physics (i) and the modal).
    @ViewBuilder private var notice: some View {
        if let text = noticeText {
            noticePill(text)
        }
    }

    private func noticePill(_ text: String) -> some View {
        VStack {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "info.circle.fill").font(.system(size: 13))
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
            }
            .foregroundStyle(DS.Color.textSecondary.color)
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
            .background(Capsule().fill(DS.Color.chipSolid.color))
            .overlay(Capsule().stroke(DS.Color.strokeSubtle.color, lineWidth: 1))
            .padding(.top, PageChrome.edge + 6)
            .padding(.horizontal, 180)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var noticeText: String? {
        switch model.sceneState {
        case .opening: return "Opening the part — its faces, stacks and lattice region."
        case .failed(let why): return "The part could not be opened: \(why)"
        default: break
        }
        if model.settings.faces.isEmpty, model.tab == .face {
            return "Tap a face on the part."
        }
        return nil
    }

    // MARK: the panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(FlexibleStageStyle.accent).frame(width: 8, height: 8)
                Text("Flexible").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                // (the filament is the Face tab's first row — not said twice)
            }
            // ★ ROUND 3 (item 5): Face | Stamps | More — one-line rows, details behind (i)
            FlexChips(options: FlexibleStageModel.Tab.allCases.map { ($0.rawValue, $0.rawValue) },
                      selection: model.tab.rawValue, id: "flexible-tab") {
                model.tab = FlexibleStageModel.Tab(rawValue: $0) ?? .face
            }
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    switch model.tab {
                    case .face: FlexibleFacePanel(model: model, padTarget: $padTarget)
                    case .stamps: FlexibleStampsPane(model: model, padTarget: $padTarget)
                    case .more: FlexibleMorePanel(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.ml)
        .frame(width: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["panel": g.frame(in: .global)])
        }.allowsHitTesting(false))
    }
}

/// The frames the depth chips keep out of (the panel, the legend) and the stage's own.
struct FlexibleKeepOutKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - overlays that follow the camera

struct FlexibleStageOverlays: View {
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var proj: FlexibleProjectionBox
    /// The page's exaggeration (the dent's and the prism's k).
    var exaggeration: Double = 1
    /// Where a chip cannot be reached (the panel, the legend), in stage points.
    var keepOut: [CGRect] = []

    var body: some View {
        ZStack {
            // ★ ROUND 3: BOTH curves on the selected pressed face, on its own two edges, at once
            // ("X and Y always combined"); the frame arrows went with the frame rotation.
            if model.tab == .face, let r = model.selectedRegion, let k = model.key(r),
               let g = model.geometry[k], let f = model.settings.face(r), f.isLoaded {
                // the Curves shape (batch D's Stamp shape draws its stamp here instead)
                ForEach((f.shape ?? "curves") == "curves" ? ["x", "y"] : [], id: \.self) { axis in
                    FlexibleCurveEditor(projection: proj.projection,
                                        baseline: axis == "x" ? g.baselineX : g.baselineY,
                                        curve: axis == "x" ? f.curveX : f.curveY,
                                        label: axis.uppercased(), tint: FlexibleStageStyle.onPart,
                                        selected: selection(r, axis),
                                        onChange: { c in setCurve(r, axis, c) },
                                        onCommit: { model.save() })
                }
                // ★ ROUND 3 (item 1.1): the deepest squish, dragged out as a prism
                FlexibleDepthChips(model: model, projection: proj.projection, k: exaggeration, keepOut: keepOut)
            }
            if model.tab == .stamps {
                FlexibleStampHandles(model: model, projection: proj.projection)
            }
        }
    }

    /// The × of one curve, held by the model (a tap on the part clears it).
    private func selection(_ r: Int, _ axis: String) -> Binding<Int?> {
        Binding(get: { model.curvePoint.flatMap { $0.region == r && $0.axis == axis ? $0.index : nil } },
                set: { model.curvePoint = $0.map { FlexCurvePoint(region: r, axis: axis, index: $0) } })
    }

    private func setCurve(_ r: Int, _ axis: String, _ c: FlexCurve) {
        model.edit({ s in
            guard var f = s.face(r) else { return }
            if axis == "y" { f.curveY = c } else { f.curveX = c }
            s.setFace(f)
        }, recompute: false)
        model.curveChanged(region: r)
    }
}

// MARK: - small shared controls (the wizard's chip row, in this page's own file)

struct FlexChips: View {
    let options: [(id: String, label: String)]
    let selection: String
    var id: String = "flexible-chip"
    var disabled: Set<String> = []
    /// false: each chip its own width (the panel's rows — "Honeycomb" read "Honeyco…" in an
    /// equal third of a fixed frame).
    var equalWidths = true
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.id) { o in
                let on = o.id == selection
                Button { onPick(o.id) } label: {
                    Text(o.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(on ? DS.Color.textPrimary.color
                                         : (disabled.contains(o.id) ? DS.Color.textDisabled.color
                                            : DS.Color.textTertiary.color))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: equalWidths ? .infinity : nil)
                        .background(Capsule().fill(on ? DS.Color.fillSelected.color : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(id)-\(o.id)")
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.Color.background.opacity(0.35).color)
            .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
    }
}

struct FlexSectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.Color.textTertiary.color)
            .textCase(.uppercase)
    }
}

struct FlexCaption: View {
    let text: String
    var colour: Color = DS.Color.textTertiary.color
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A number the user types: a chip that opens the shared number pad (standing rule:
/// every numeric input opens a numeric keypad).
struct FlexNumberChip: View {
    let key: String
    let title: String
    let unit: String
    let value: Double
    var decimals = 1
    @Binding var padTarget: String?
    let onValue: (Double) -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
            Spacer()
            Button { padTarget = key } label: {
                Text("\(String(format: "%.\(decimals)f", value)) \(unit)")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(DS.Surface.valuePill.color))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flexible-number-\(key)")
            .numberPad(Binding(get: { padTarget == key }, set: { if !$0 { padTarget = nil } }),
                       config: .init(title: title, unit: unit, allowsDecimal: true), seed: value) { v in
                if let v, v > 0 { onValue(v) }
            }
        }
    }
}

/// The badge every squish number wears (R7): tier + ± band, from core.
struct FlexTierBadge: View {
    let tier: FlexTier
    var body: some View {
        HStack(spacing: 4) {
            Text(tier.tier).font(.system(size: 11, weight: .bold))
            Text("± \(Int((tier.band * 100).rounded())) %").font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tier.tier == "estimated" ? DS.Color.warning.color : DS.Color.textSecondary.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(DS.Color.fillSubtle.color))
    }
}

/// The per-face numbers: range with tier and band, and the clamped columns in plain words.
struct FlexibleFaceResult: View {
    let design: FlexFaceDesignInfo
    @ObservedObject var model: FlexibleStageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FlexSectionTitle(text: model.showBuildable ? "Can be built" : "You drew")
                Spacer()
                FlexTierBadge(tier: design.tier)
            }
            if let r = model.showBuildable ? design.buildableDepthRange : design.targetDepthRange {
                let b = design.tier.band
                Text(String(format: "%.1f – %.1f mm squish", r.lowerBound, r.upperBound))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                if model.showBuildable {
                    FlexCaption(text: String(format: "± %.0f %%: %.1f – %.1f mm", b * 100,
                                             r.lowerBound * (1 - b), r.upperBound * (1 + b)))
                }
            }
            FlexCaption(text: design.tier.why)
            let t = model.designTempC.map { "\(Int($0)) °C" } ?? "—"
            FlexCaption(text: "\(model.designTopology.capitalized) at \(t)" + (model.settings.topology == "auto" ? " (Auto)" : ""))
            let lines = clampLines
            if !lines.isEmpty {
                ForEach(lines, id: \.self) { FlexCaption(text: $0, colour: DS.Color.warning.color) }
            }
            if design.targetExtrapolated > 0 {
                FlexCaption(text: "\(design.targetExtrapolated) columns squish past the tested 20 % — extrapolated.")
            }
            if design.designStampRigidAveraged {
                FlexCaption(text: "A rigid design stamp is read as its stated weight spread over the area it covers — its real pressure depends on the lattice being designed.")
            }
            if design.designStampOffFace {
                FlexCaption(text: String(format: "%.1f N of the design stamp lands off this face.", design.designStampOffFaceN),
                            colour: DS.Color.warning.color)
            }
        }
    }

    private var clampLines: [String] {
        var l: [String] = []
        if design.tooFirm > 0 { l.append("\(design.tooFirm) columns: even the softest lattice will not squish that far here.") }
        if design.tooSoft > 0 { l.append("\(design.tooSoft) columns: even the firmest lattice squishes further than drawn.") }
        if design.beyondData > 0 { l.append("\(design.beyondData) columns: that squish is beyond the tested data.") }
        if design.solidUnderMap > 0 { l.append("\(design.solidUnderMap) columns are solid under the drawing (no lattice there).") }
        if model.showBuildable, design.buildableBeyondData > 0 {
            l.append("\(design.buildableBeyondData) columns leave the data once smoothed — no number there.")
        }
        return l
    }
}

/// The map's legend: ONE line saying what it shows and how much it is exaggerated ("What
/// you drew · shown ×7"), the ramp, 0 … deepest, and the tier where core gave one. ★ ROUND 3:
/// the long captions moved behind the (i) (FlexibleRowCopy); on the trailing edge, centred.
struct FlexibleLegend: View {
    @ObservedObject var model: FlexibleStageModel
    /// The generated lattice while it is drawn (X-ray): the map is then the one it was built from.
    var drawnLattice: FlexibleGeneratedLattice? = nil

    var body: some View {
        let shown = FlexibleShownValues(model: model, drawnLattice: drawnLattice)
        let tier = model.checkStampShown.flatMap { model.checks[$0]?.tier }
            ?? model.selectedRegion.flatMap { model.design($0)?.tier }
        let noNumber = shown.values.values.contains { $0.contains { if case .noNumber = $0 { return true } else { return false } } }
        VStack(alignment: .leading, spacing: 6) {
            Text(shown.legendLine).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityIdentifier("flexible-legend-line")
            HStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { i in
                    FlexibleColours.depthColour(fraction: Double(i) / 23).color.frame(width: 9, height: 10)
                }
            }
            HStack {
                Text("0 mm"); Spacer(); Text(String(format: "%.1f mm", shown.maxDepth))
            }
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(DS.Color.textSecondary.color)
            if noNumber {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(DS.Color.textQuaternary.color).frame(width: 12, height: 10)
                    Text("grey · no number").font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            if let tier { FlexTierBadge(tier: tier) }
        }
        .frame(width: 236)
        .padding(DS.Space.ml)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .allowsHitTesting(false)
    }
}

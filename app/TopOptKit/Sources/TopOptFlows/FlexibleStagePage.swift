// FlexibleStagePage — the Flexible stage's page (task 2026-09-29-flexible-screens, A1).
//
// Layout follows the lattice Settings page (LatticeSetupWizard): the part fills the
// screen, "Exit" top-left in the accent capsule, a one-line notice top-centre, and ONE
// panel bottom-left (PageChrome.edge inset, DS.Surface.panel, DS.Radius.panel) whose tabs
// walk the spec's flow: Filament → Squish → Auto → Physics → Stamps.
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
    @State private var padTarget: String?

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
                if model.tab == .squish, model.step == .view3D || model.checkStampShown != nil {
                    FlexibleLegend(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(PageChrome.edge)
                }
            }
        }
        .onAppear {
            if let b = project.viewerMesh?.bounds { camera.reframe(b) }
            model.openScene()
        }
        .onChange(of: model.geometry.count) { _ in rebuildOverlay() }
        .onChange(of: model.stacks.count) { _ in rebuildOverlay() }
        .onReceive(model.objectWillChange.debounce(for: .milliseconds(16), scheduler: RunLoop.main)) { _ in
            refreshChannels()
        }
        .accessibilityIdentifier("flexible-stage-page")
    }

    // MARK: the stage

    /// The part's opacity while a dent is shown; the dented map itself stays opaque.
    static let dentBodyAlpha: Float = 0.3

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
                // ★ THE DENT READS THROUGH THE PART (maintainer, 2026-09-29): while a dent is
                // shown the body drops to 30 % and the dented map stays at 100 %.
                bodyAlpha: dents != nil ? Self.dentBodyAlpha : 1)
            FlexibleStageOverlays(model: model, proj: proj)
        }
        .coordinateSpace(name: FlexibleStageSpace.name)
        .ignoresSafeArea()
    }

    private func rebuildOverlay() {
        guard let part = project.viewerMesh else { return }
        let faces: [FlexibleOverlayFace] = model.loadedKeys.compactMap { k in
            guard let st = model.stacks[k], let g = model.geometry[k] else { return nil }
            let regions = model.regions
            return FlexibleOverlayFace(key: k, faces: Set(regions.faces(of: k.region, mesh: part)),
                                       cuts: regions.cuts(of: k.region), stack: st, centres: g.centres)
        }
        overlay = faces.isEmpty ? nil : FlexibleOverlayMesh.build(part: part, faces: faces)
        refreshChannels()
    }

    /// Per-column colours + the dent, from the model's current copies of core's results.
    private func refreshChannels() {
        // part regions: loaded / resting / selected / linked other end / conflict — by REGION,
        // so a split sector is tinted on its own side of its cuts (FlexibleRegions)
        let regions = model.regions
        let conflictRegions = Set(model.conflicts.flatMap { [$0.faceA, $0.faceB] })
        var regionTint: [(id: Int, tint: SIMD4<Float>)] = []   // later entries win
        for f in model.settings.faces {
            var c = f.isLoaded ? FlexibleColours.loadedFace : FlexibleColours.restingFace
            if conflictRegions.contains(f.faceRegionID) { c = FlexibleColours.conflict }
            regionTint.append((f.faceRegionID, c))
        }
        if let r = model.selectedRegion, let st = model.stack(r) {
            for l in st.exitRegions { regionTint.append((l.id, FlexibleColours.linkedEnd)) }
            if !conflictRegions.contains(r) { regionTint.append((r, FlexibleColours.selectedFace)) }
        }
        let partMesh = project.viewerMesh
        let tintOf: (Int, SIMD3<Double>) -> SIMD4<Float>? = { face, centroid in
            var out: SIMD4<Float>?
            for e in regionTint where regions.contains(e.id, face: face, centroid: centroid, mesh: partMesh) {
                out = e.tint
            }
            return out
        }
        guard let overlay else {
            // no stacks yet: tint the part itself, per triangle
            guard let mesh = project.viewerMesh else { tints = nil; dents = nil; dentScale = 0; return }
            let n = mesh.flat.vertexCount
            var out = [Float](repeating: 0, count: n * 8)
            let ids = mesh.faceIDs
            func vtx(_ i: UInt32) -> SIMD3<Double> {
                let b = Int(i) * 3
                return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
            }
            for t in 0..<min(mesh.triangleCount, n / 3) where !regionTint.isEmpty {
                let fid = t < ids.count ? Int(ids[t]) : -1
                let c = (vtx(mesh.indices[3 * t]) + vtx(mesh.indices[3 * t + 1]) + vtx(mesh.indices[3 * t + 2])) / 3
                guard let col = tintOf(fid, c) else { continue }
                for j in 0..<3 {
                    let v = 3 * t + j
                    out[v * 8] = col.x; out[v * 8 + 1] = col.y; out[v * 8 + 2] = col.z; out[v * 8 + 3] = col.w
                }
            }
            tints = n > 0 ? out : nil
            dents = nil
            dentScale = 0
            return
        }
        let shown = FlexibleShownValues(model: model)
        var colours: [FlexFaceKey: [SIMD4<Float>]] = [:]
        for k in model.loadedKeys {
            guard let vals = shown.values[k] else { continue }
            colours[k] = vals.map { v in
                switch v {
                case .depth(let mm): return FlexibleColours.depth(mm, max: shown.maxDepth)
                case .noNumber: return FlexibleColours.noNumber
                case .solid: return SIMD4(0, 0, 0, 0)
                }
            }
        }
        tints = overlay.tints(partTint: tintOf, columnColours: colours)
        if shown.showsDent {
            var depths: [FlexFaceKey: [Double?]] = [:]
            for (k, vals) in shown.values {
                depths[k] = vals.map { if case .depth(let d) = $0 { return d } else { return nil } }
            }
            dents = overlay.displacements(depths: depths, stacks: model.stacks,
                                          partUVT: model.geometry.mapValues(\.partUVT))
            dentScale = Float(shown.exaggeration)
        } else {
            dents = nil
            dentScale = 0
        }
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

    private var notice: some View {
        VStack {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "info.circle.fill").font(.system(size: 13))
                Text(noticeText)
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

    private var noticeText: String {
        switch model.sceneState {
        case .opening: return "Opening the part — its faces, stacks and lattice region."
        case .failed(let why): return "The part could not be opened: \(why)"
        default: break
        }
        if model.settings.faces.isEmpty, model.tab == .squish {
            return "Tap a face on the part to mark where the weight goes."
        }
        return "Flexible · no strength certificate · every number shows its tier and ± band."
    }

    // MARK: the panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(FlexibleStageStyle.accent).frame(width: 8, height: 8)
                Text("Flexible").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                if let m = model.material {
                    Text(m.displayName).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
                }
            }
            FlexChips(options: FlexibleStageModel.Tab.allCases.map { ($0.rawValue, $0.rawValue) },
                      selection: model.tab.rawValue, id: "flexible-tab") {
                model.tab = FlexibleStageModel.Tab(rawValue: $0) ?? .filament
            }
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    switch model.tab {
                    case .filament: FlexibleFilamentPane(model: model)
                    case .squish: FlexibleSquishPane(model: model, padTarget: $padTarget)
                    case .auto: FlexibleAutoPane(model: model)
                    case .physics: FlexiblePhysicsPane(model: model)
                    case .stamps: FlexibleStampsPane(model: model, padTarget: $padTarget)
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
    }
}

// MARK: - what the overlay shows

/// One column's value on the overlay.
enum FlexShownValue { case depth(Double), noNumber, solid }

/// Which numbers the overlay shows right now — the drawn map while a curve is being
/// drawn, the drawn or buildable depth in the 3D view, a stamp's dent in check mode.
@MainActor
struct FlexibleShownValues {
    var values: [FlexFaceKey: [FlexShownValue]] = [:]
    var maxDepth = 0.0
    var showsDent = false
    var exaggeration = 1.0
    var label = ""

    init(model m: FlexibleStageModel) {
        let checkID = m.checkStampShown
        for f in m.settings.loadedFaces {
            let k = FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)
            guard let st = m.stacks[k] else { continue }
            if let id = checkID, let c = m.checks[id],
               m.settings.checkStamps.contains(where: { $0.stamp.id == id && $0.faceRegionID == f.faceRegionID }) {
                values[k] = st.columns.indices.map { i in
                    if let d = c.depthMM[i] { return .depth(d) }
                    return c.status[i] == "beyond_data" ? .noNumber : .depth(0)
                }
                label = "Dent under the stamp"
                showsDent = true
                continue
            }
            let design = m.designs[k]
            if m.step == .view3D, let d = design, d.refusal == nil {
                values[k] = d.columns.map { c in
                    if c.status == "no_lattice" { return .solid }
                    if m.showBuildable { return c.buildableOK ? .depth(c.buildableDepthMM) : .noNumber }
                    return .depth(c.targetDepthMM)
                }
                label = m.showBuildable ? "What can be built (estimate)" : "What you drew"
                showsDent = true
            } else if let s = m.liveS[k] {
                // while drawing: the drawn map, S × deepest (a drawing, not a prediction)
                values[k] = s.map { .depth($0 * f.deepestMM) }
                label = "What you drew"
            }
        }
        for v in values.values { for x in v { if case .depth(let d) = x { maxDepth = max(maxDepth, d) } } }
        // ★ ONE SCALE FOR BOTH SIDES OF THE TOGGLE: drawn and buildable are coloured against
        // the same maximum, so flipping between them compares like with like.
        if m.step == .view3D, checkID == nil {
            for d in m.designs.values where d.refusal == nil {
                maxDepth = max(maxDepth, d.targetDepthRange?.upperBound ?? 0,
                               d.buildableDepthRange?.upperBound ?? 0)
            }
        }
        // the dent is exaggerated so a few mm reads on a 100 mm part; the legend says by how much
        let ext = m.stacks.values.map { max($0.uExtentMM, $0.vExtentMM) }.max() ?? 0
        if maxDepth > 0, ext > 0 { exaggeration = max(1, min(4, (0.10 * ext / maxDepth).rounded())) }
    }
}

// MARK: - overlays that follow the camera

struct FlexibleStageOverlays: View {
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var proj: FlexibleProjectionBox

    var body: some View {
        ZStack {
            if model.tab == .squish, let r = model.selectedRegion, let k = model.key(r),
               let g = model.geometry[k], let st = model.stacks[k], let f = model.settings.face(r), f.isLoaded {
                FlexibleFrameArrows(projection: proj.projection, origin: g.corner, xAxis: st.xAxis,
                                    yAxis: st.yAxis, load: st.load,
                                    lengthMM: max(4, 0.15 * max(st.uExtentMM, st.vExtentMM)))
                if model.step != .view3D {
                    let (base, curve, label) = editorInputs(f, g)
                    FlexibleCurveEditor(projection: proj.projection, baseline: base, curve: curve,
                                        label: label, tint: FlexibleStageStyle.accent,
                                        onChange: { c in setCurve(r, c) },
                                        onCommit: { model.save() })
                }
            }
            if model.tab == .stamps {
                FlexibleStampHandles(model: model, projection: proj.projection)
            }
        }
    }

    private func editorInputs(_ f: FlexibleFaceSettings, _ g: FlexFaceGeometry) -> (FlexibleCurveBaseline, FlexCurve, String) {
        if f.mode == "centre_edge" { return (g.baselineC, f.curveCentreEdge, "edge → centre") }
        return model.step == .curveY ? (g.baselineY, f.curveY, "Y") : (g.baselineX, f.curveX, "X")
    }

    private func setCurve(_ r: Int, _ c: FlexCurve) {
        model.edit({ s in
            guard var f = s.face(r) else { return }
            if f.mode == "centre_edge" { f.curveCentreEdge = c }
            else if model.step == .curveY { f.curveY = c } else { f.curveX = c }
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
                        .frame(maxWidth: .infinity)
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

// MARK: - Filament (S1)

struct FlexibleFilamentPane: View {
    @ObservedObject var model: FlexibleStageModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if let e = model.catalogueError { FlexCaption(text: e, colour: DS.Color.danger.color) }
            if let m = model.material { temperature(m) }
            FlexSectionTitle(text: "Filament")
            ForEach(model.catalogue) { m in row(m) }
            FlexSectionTitle(text: "Walls")
            FlexChips(options: [("1", "1 bead"), ("2", "2 beads")],
                      selection: String(model.settings.beadsPerWall), id: "flexible-beads") { v in
                model.edit { $0.beadsPerWall = Int(v) ?? 1 }
            }
            FlexCaption(text: model.settings.beadsPerWall == 2
                        ? "2-bead walls are unverified: numbers carry the estimated band until they are tested."
                        : "Walls one bead wide — how the published tests were printed.")
            FlexCaption(text: String(format: "Bead %.2f mm, from Print Parameters — the same bead the other stages send.",
                                     model.project.printParams.strutLineWidthMM))
        }
    }

    private func tierLabel(_ m: FlexMaterialInfo) -> String {
        switch m.tier {
        case "literature": return "published data"
        case "calibrate_first": return "calibrate first"
        case "proxy_candidate": return "calibrate first"
        default: return m.tier
        }
    }

    @ViewBuilder private func row(_ m: FlexMaterialInfo) -> some View {
        let on = model.settings.materialID == m.id
        Button { model.pickMaterial(m.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(m.displayName).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                    Spacer()
                    Text(tierLabel(m)).font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(m.noPrediction == nil ? DS.Color.okGreen.color : DS.Color.warning.color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(DS.Color.fillSubtle.color))
                }
                HStack(spacing: 6) {
                    if let s = m.shoreA { Text("Shore \(Int(s))A") }
                    if m.foaming { Text("· foaming") }
                    if !m.testedTempsC.isEmpty {
                        Text("· tested at " + m.testedTempsC.map { "\(Int($0)) °C" }.joined(separator: ", "))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary.color)
                if m.noPrediction != nil {
                    Text("Calibrate first — geometry only")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(on ? DS.Color.fillSelected.color : DS.Color.fillSubtle.color))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(on ? FlexibleStageStyle.accent.opacity(0.6) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("flexible-filament-\(m.id)")
    }

    @ViewBuilder private func temperature(_ m: FlexMaterialInfo) -> some View {
        FlexSectionTitle(text: "Nozzle temperature")
        if let np = m.noPrediction {
            // R7: empty fields with the reason, never a greyed guess
            VStack(alignment: .leading, spacing: 4) {
                Text("Calibrate first — geometry only").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.warning.color)
                FlexCaption(text: np.reason)
                FlexCaption(text: "Squish, density and depth stay empty for this filament. The lattice can still be placed and drawn.")
            }
        } else {
            let opts = [("auto", "Auto")] + m.testedTempsC.map { (String(Int($0)), "\(Int($0)) °C") }
            FlexChips(options: opts, selection: model.settings.nozzleTempC.map { String(Int($0)) } ?? "auto",
                      id: "flexible-temp") { v in
                model.edit { $0.nozzleTempC = v == "auto" ? nil : Double(v) }
            }
            FlexCaption(text: "Only the temperatures this filament was tested at are offered; foaming filaments change softness with temperature, and the app never guesses between them.")
            if let t = model.settings.nozzleTempC {
                let note = model.temperatureNote(t)
                if !note.isEmpty { FlexCaption(text: "\(Int(t)) °C: \(note)", colour: DS.Color.warning.color) }
            }
        }
    }
}

// MARK: - Squish (S2)

struct FlexibleSquishPane: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?

    private var faces: [FlexibleFaceSettings] { model.settings.faces }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if faces.isEmpty {
                FlexCaption(text: "Tap a face on the part to mark where the weight goes. Its other end lights up.")
            } else if let r = model.selectedRegion ?? faces.first?.faceRegionID, let f = model.settings.face(r) {
                stepper(r)
                conflictNote(r)
                faceSettings(f)
                if f.isLoaded { curveControls(f); results(f) }
                FlexibleSliceView(model: model)
            }
            if let np = model.material?.noPrediction {
                // R7: empty fields with the reason — core's own sentence
                Text("Calibrate first — geometry only").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.warning.color)
                FlexCaption(text: np.reason)
                FlexCaption(text: "The curves can be drawn; no squish, density or depth is predicted.")
            }
        }
        .onAppear { if model.selectedRegion == nil { model.selectedRegion = faces.first?.faceRegionID } }
    }

    private func faceName(_ region: Int) -> String { model.name(region) }

    @ViewBuilder private func stepper(_ r: Int) -> some View {
        let i = faces.firstIndex { $0.faceRegionID == r } ?? 0
        HStack {
            Button { model.selectedRegion = faces[(i + faces.count - 1) % faces.count].faceRegionID } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
            }.buttonStyle(.plain).accessibilityIdentifier("flexible-face-prev")
            Spacer()
            VStack(spacing: 1) {
                Text("Face \(i + 1) of \(faces.count)").font(.system(size: 14, weight: .semibold))
                Text(faceName(r)).font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary.color)
            }
            Spacer()
            Button { model.selectedRegion = faces[(i + 1) % faces.count].faceRegionID } label: {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
            }.buttonStyle(.plain).accessibilityIdentifier("flexible-face-next")
        }
        .foregroundStyle(DS.Color.textPrimary.color)
    }

    @ViewBuilder private func conflictNote(_ r: Int) -> some View {
        if let c = model.conflicts.first(where: { $0.faceA == r || $0.faceB == r }) {
            // M13: core's two face names
            FlexCaption(text: "\(faceName(c.faceA).capitalized) and \(faceName(c.faceB)) both push the same material along the same line (\(Int(c.overlapMM3.rounded())) mm³ shared). One squish profile per stack: mark one of them as where it rests.",
                        colour: DS.Color.warning.color)
        }
    }

    @ViewBuilder private func faceSettings(_ f: FlexibleFaceSettings) -> some View {
        let r = f.faceRegionID
        FlexChips(options: [("loaded", "Carries weight"), ("resting", "Rests here")], selection: f.role,
                  id: "flexible-role") { v in model.edit { s in var g = f; g.role = v; s.setFace(g) } }
        if let st = model.stack(r) {
            let links = st.exitRegions.map { "\(faceName($0.id)) \(Int(($0.fraction * 100).rounded())) %" }
            FlexCaption(text: "Other end: " + (links.isEmpty ? "not found" : links.joined(separator: ", ")),
                        colour: DS.Color.accentCyan.color)
            if st.side { FlexCaption(text: "Side face · gyroid only · estimated", colour: DS.Color.warning.color) }
            if st.normalSpreadFlag {
                FlexCaption(text: String(format: "This face bends %.0f° — the map is projected along one direction.", st.normalSpreadDeg),
                            colour: DS.Color.warning.color)
            }
            FlexCaption(text: String(format: "%.0f × %.0f mm · %d columns, %.1f mm apart · lattice %.1f–%.1f mm deep",
                                     st.uExtentMM, st.vExtentMM, st.columns.count, st.pitchMM, st.latticeMMMin, st.latticeMMMax))
        } else if model.sceneState == .ready {
            FlexCaption(text: "Finding this face's stack…")
        }
        if f.isLoaded {
            FlexNumberChip(key: "weight-\(r)", title: "Weight", unit: "kg", value: f.weightKg, padTarget: $padTarget) { v in
                model.edit { s in var g = f; g.weightKg = v; s.setFace(g) }
            }
            FlexCaption(text: String(format: "%.1f N at 9.80665 m/s²", f.weightN))
            FlexNumberChip(key: "deepest-\(r)", title: "Deepest squish", unit: "mm", value: f.deepestMM, padTarget: $padTarget) { v in
                model.edit { s in var g = f; g.deepestMM = v; s.setFace(g) }
            }
            HStack {
                Text("Frame").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                Button { rotate(f, -90) } label: { Image(systemName: "rotate.left") }
                    .buttonStyle(.plain).accessibilityIdentifier("flexible-rotate-left")
                Text("\(f.rotationDeg)°").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Button { rotate(f, 90) } label: { Image(systemName: "rotate.right") }
                    .buttonStyle(.plain).accessibilityIdentifier("flexible-rotate-right")
            }
            .foregroundStyle(DS.Color.textPrimary.color)
        }
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Skin").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                FlexCaption(text: f.skinOn ? "A solid skin covers this face." : "No skin: edges and side walls squish too.")
            }
            Spacer()
            GlassToggle(isOn: f.skinOn) { model.edit { s in var g = f; g.skinOn.toggle(); s.setFace(g) } }
                .accessibilityIdentifier("flexible-skin")
        }
        Button { model.removeFace(r) } label: {
            Label("Remove this face", systemImage: "trash").font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Color.danger.color)
        }.buttonStyle(.plain)
    }

    private func rotate(_ f: FlexibleFaceSettings, _ by: Int) {
        model.edit { s in var g = f; g.rotationDeg = ((g.rotationDeg + by) % 360 + 360) % 360; s.setFace(g) }
        model.selectedRegion = f.faceRegionID
    }

    @ViewBuilder private func curveControls(_ f: FlexibleFaceSettings) -> some View {
        FlexSectionTitle(text: "How the squish varies")
        FlexChips(options: [("both", "Both axes"), ("either", "Either axis"), ("centre_edge", "Centre → edge")],
                  selection: f.mode, id: "flexible-mode") { v in
            model.edit { s in var g = f; g.mode = v; s.setFace(g) }
        }
        FlexCaption(text: f.mode == "both" ? "Soft only where both curves are high."
                    : f.mode == "either" ? "Soft where either curve is high."
                    : "One curve from the face's edge to its middle.")
        let steps: [(String, String)] = f.mode == "centre_edge"
            ? [("X curve", "1 · Curve"), ("3D view", "2 · 3D view")]
            : [("X curve", "1 · X curve"), ("Y curve", "2 · Y curve"), ("3D view", "3 · 3D view")]
        FlexChips(options: steps, selection: model.step.rawValue, id: "flexible-step") { v in
            model.step = FlexibleStageModel.Step(rawValue: v) ?? .curveX
        }
        if model.step != .view3D {
            HStack {
                FlexCaption(text: "Drag the points on the part. Up = softer (0 → 1 × deepest squish). Double-tap a point to delete it.")
                Button {
                    model.edit({ s in
                        var g = f
                        if g.mode == "centre_edge" { g.curveCentreEdge = FlexibleCurveEditor.addingPoint(to: g.curveCentreEdge) }
                        else if model.step == .curveY { g.curveY = FlexibleCurveEditor.addingPoint(to: g.curveY) }
                        else { g.curveX = FlexibleCurveEditor.addingPoint(to: g.curveX) }
                        s.setFace(g)
                    }, recompute: false)
                    model.curveChanged(region: f.faceRegionID)
                } label: {
                    Text("+ point").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(DS.Color.fillSelected.color))
                        .foregroundStyle(DS.Color.textPrimary.color)
                }.buttonStyle(.plain).accessibilityIdentifier("flexible-add-point")
            }
        } else {
            FlexChips(options: [("drew", "What you drew"), ("built", "What can be built")],
                      selection: model.showBuildable ? "built" : "drew", id: "flexible-drew-built") { v in
                model.showBuildable = v == "built"
            }
            if model.showBuildable {
                FlexCaption(text: "An estimate: the drawn map clamped to the tested data and smoothed to about one cell, until the lattice recipe exists.")
            }
        }
    }

    @ViewBuilder private func results(_ f: FlexibleFaceSettings) -> some View {
        if let d = model.design(f.faceRegionID) {
            if let r = d.refusal {
                FlexCaption(text: r.reason, colour: DS.Color.warning.color)
            } else {
                FlexibleFaceResult(design: d, model: model)
            }
        } else if model.settings.materialID == nil {
            FlexCaption(text: "Pick a filament to see what the lattice can do here.")
        }
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

/// The 3D view's legend: numbers, the tier and band, the exaggeration.
struct FlexibleLegend: View {
    @ObservedObject var model: FlexibleStageModel

    var body: some View {
        let shown = FlexibleShownValues(model: model)
        let tier = model.checkStampShown.flatMap { model.checks[$0]?.tier }
            ?? model.selectedRegion.flatMap { model.design($0)?.tier }
        VStack(alignment: .leading, spacing: 6) {
            Text(shown.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
            HStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { i in
                    ResultsModel.stressColor(fraction: Double(i) / 23).color.frame(width: 9, height: 10)
                }
            }
            HStack {
                Text("0 mm"); Spacer(); Text(String(format: "%.1f mm", shown.maxDepth))
            }
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(DS.Color.textSecondary.color)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(DS.Color.textQuaternary.color).frame(width: 12, height: 10)
                Text("no number (outside the data)").font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary.color)
            }
            if let tier { FlexTierBadge(tier: tier) }
            if shown.showsDent {
                FlexCaption(text: "Dent drawn × \(Int(shown.exaggeration)) deeper than it is.")
            }
            FlexCaption(text: "Dents have sharper edges than real life, and a small press on a big pad sinks less than shown.")
        }
        .frame(width: 236)
        .padding(DS.Space.ml)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .allowsHitTesting(false)
    }
}

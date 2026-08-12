// LatticeSetupWizard.swift — ★ PAGE 2: LATTICE SETTINGS, A WIZARD THAT SHOWS AND
// NEVER TELLS (task 2026-08-12-lattice-page-redesign §2).
//
// ★ THE LAW: "NO MORE EXHAUSTING MASSIVE PIECES OF TEXT. SHOW THE CHANGES BEING
// MADE ON SCREEN." There is no explanatory prose on this page. The longest string
// it can render is the disclaimer — nine words — and every setting explains
// itself by MOVING the object in the centre.
//
// THE LAYOUT.
//
//   centre      the object. One cell in Stage A; the tiled sample in Stage B.
//               Rotatable throughout (the orbit camera, the same one every other
//               page uses).
//   left        the PERSISTENT MODAL: every selection, always live, always
//               changeable — the wizard is the order, not a gate.
//   top-centre  the disclaimer: one line, an X (§3b).
//   bottom-right Save & Exit → back to page 1, where Optimize is pressed.
//
// THE CINEMATICS ARE `LatticeWizardCinematic` VALUES, played here:
//   .morph              the struts rebuild into the new family, cross-faded
//   .tile               the one cell flies into the part and expands outward
//   .stressWipeAndDive  the field wipes down the part, then the camera dives
//                       into the densest lattice
//   .jumpToSample       Auto cell size cuts straight to the sample
//   .boundarySwap       the four finishes, on the part, switchable

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

public struct LatticeSetupWizard: View {

    @ObservedObject var project: ProjectModel
    let onExit: () -> Void

    @State private var model: LatticeWizardModel
    @State private var camera = OrbitCameraModel()
    /// The tile expansion, 0…1 — animated by `.tile`, and what `stageMesh` reads.
    @State private var tileProgress: Double = 1
    /// The stress wipe, 0…1 — the renderer's own `reveal`.
    @State private var wipe: Double = 0
    /// Last measured build+upload time for the centre object, in ms (R4).
    @State private var lastLatencyMS: Double = 0
    @State private var mesh: ViewerMesh?

    public init(project: ProjectModel, onExit: @escaping () -> Void) {
        self.project = project
        self.onExit = onExit
        _model = State(initialValue: LatticeWizardModel(settings: project.lattice))
    }

    public var body: some View {
        ZStack {
            DS.Color.background.color.ignoresSafeArea()
            stageView
            HStack(spacing: 0) {
                selectionsModal
                Spacer(minLength: 0)
            }
            disclaimer
            saveAndExit
        }
        .onAppear { rebuild() }
        .onChange(of: model.playToken) { _ in playCurrent() }
    }

    // MARK: the centre — the object, and nothing else

    private var stageView: some View {
        ZStack {
            MetalMeshView(mesh: mesh, camera: camera,
                          stressTints: model.stage == .lattice && model.densityMode == .auto
                              ? sampleTints : nil,
                          reveal: Float(model.densityMode == .auto ? wipe : 1))
                .ignoresSafeArea()
        }
    }

    /// The BAKED field (§3a) mapped onto the tiled block's vertices by height —
    /// the sample's own field, never a solve.
    private var sampleTints: [SIMD4<Float>] {
        guard let m = mesh else { return [] }
        let p = m.positions
        let n = p.count / 3
        guard n > 0 else { return [] }
        let half = Float(LatticeWizardSample.heightMM) / 2
        var out = [SIMD4<Float>](); out.reserveCapacity(n)
        for i in 0..<n {
            let z = p[i * 3 + 2], x = p[i * 3]
            let moment = max(0, (Float(LatticeWizardSample.lengthMM) / 2 - x))
                / Float(LatticeWizardSample.lengthMM)
            let fraction = Double(min(1, moment * abs(z) / max(1e-6, half) * 2))
            let c = LatticeDensityProxy.densityColor(fraction: fraction)
            out.append(SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1))
        }
        return out
    }

    // MARK: the persistent left modal (§2) — every selection, always live

    private var selectionsModal: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            stagePicker
            group("Type") { typeRow }
            group("Size") {
                scrubRow(value: model.cellMM, unit: "mm", step: 0.05,
                         range: 1...20) { model.cellMM = $0; rebuild() }
            }
            group("Thickness") {
                scrubRow(value: model.relativeDensity * 100, unit: "%", step: 0.4,
                         range: 5...90) {
                    model.relativeDensity = $0 / 100; rebuild()
                }
            }
            Divider().overlay(DS.Color.strokeSubtle.color)
            group("Density") {
                segmentRow(["Auto", "Uniform"],
                           selected: model.densityMode == .auto ? 0 : 1) { i in
                    model.setDensityMode(i == 0 ? .auto : .uniform)
                }
            }
            group("Cell size") {
                segmentRow(["Auto", "Fixed", "Swept"],
                           selected: cellModeIndex) { i in
                    model.setCellSizeMode([.auto, .fixed, .swept][i])
                }
            }
            group("Finish") {
                segmentRow(["None", "Rim", "Skin"],
                           selected: boundaryIndex) { i in
                    model.setBoundary([.none, .rim, .fullSkin][i])
                }
            }
            Spacer(minLength: 0)
            latencyReadout
        }
        .padding(DS.Space.ml)
        .frame(width: PageChrome.panelWidth, alignment: .leading)
        .background(DS.Surface.panel.color)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Color.strokeSubtle.color).frame(width: 1)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var stagePicker: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(LatticeWizardStage.allCases, id: \.rawValue) { s in
                stageChip(s)
            }
            Spacer(minLength: 0)
            if model.stage == .cell {
                Button { model.enterLattice() } label: {
                    Label("Tile it", systemImage: "square.grid.3x3.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.vertical, 6).padding(.horizontal, DS.Space.sm)
                        .background(Capsule().fill(
                            LatticeDensityProxy.densityColor(fraction: 0.7).opacity(0.7).color))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wizard-tile")
            }
        }
    }

    private func stageChip(_ s: LatticeWizardStage) -> some View {
        let on: Bool = (model.stage == s)
        let ink: Color = (on ? DS.Color.textPrimary : DS.Color.textTertiary).color
        let fill: Color = on ? DS.Color.fillSelected.color : Color.clear
        return Button { model.jump(to: s); rebuild() } label: {
            Text(s.title)
                .dsStyle(DS.TypeScale.footnote).fontWeight(.bold)
                .foregroundStyle(ink)
                .padding(.vertical, 6)
                .padding(.horizontal, DS.Space.sm)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wizard-stage-\(s.rawValue)")
    }

    private var typeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs) {
                ForEach(LatticeType.family, id: \.id) { t in
                    typeChip(t)
                }
            }
        }
    }

    private func typeChip(_ t: LatticeType) -> some View {
        let on: Bool = (model.topologyID == t.id)
        let ink: Color = (on ? DS.Color.textPrimary : DS.Color.textTertiary).color
        let fill: Color = on ? DS.Color.fillSelected.color : Color.clear
        return Button { model.setTopology(t.id) } label: {
            Text(t.displayName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ink)
                .padding(.vertical, 6)
                .padding(.horizontal, DS.Space.sm)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wizard-type-\(t.id)")
    }

    private var cellModeIndex: Int {
        switch model.cellSizeMode {
        case .auto: return 0
        case .fixed: return 1
        default: return 2
        }
    }
    private var boundaryIndex: Int {
        switch model.boundary {
        case .none: return 0
        case .rim: return 1
        case .fullSkin: return 2
        }
    }

    /// R4 — the measured build+upload time for the object on screen, always
    /// visible. A number, not a claim.
    private var latencyReadout: some View {
        HStack(spacing: DS.Space.xs) {
            Text(String(format: "%.0f ms", lastLatencyMS))
                .font(.system(size: 11, weight: .bold)).monospacedDigit()
            Text("\(model.stageTriangleCount) tris")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(DS.Color.textQuaternary.color)
        }
        .foregroundStyle(DS.Color.textTertiary.color)
    }

    // MARK: chrome

    /// ★ §3b — a SMALL TOP-CENTRE MODAL WITH AN X. One line. Dismissible.
    @ViewBuilder private var disclaimer: some View {
        if model.showDisclaimer {
            VStack {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "info.circle.fill").font(.system(size: 11))
                    Text(LatticeWizardSample.provenanceNote)
                        .dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                    Button { model.showDisclaimer = false } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wizard-disclaimer-dismiss")
                }
                .foregroundStyle(DS.Color.textSecondary.color)
                .padding(.vertical, 7).padding(.horizontal, DS.Space.m)
                .background(Capsule().fill(DS.Surface.bar.color))
                .padding(.top, PageChrome.topInset)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var saveAndExit: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    project.lattice = model.applied(to: project.lattice)
                    onExit()
                } label: {
                    Text("Save & Exit")
                        .dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.vertical, 12).padding(.horizontal, DS.Space.xl5)
                        .background(Capsule().fill(DS.Color.accent.color))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wizard-save-exit")
            }
            .padding(PageChrome.edge)
        }
    }

    // MARK: the moves

    /// Rebuild the centre object and MEASURE it (R4). Everything the page draws
    /// goes through here, so the number on screen is the number for every change.
    private func rebuild() {
        let t0 = CFAbsoluteTimeGetCurrent()
        mesh = model.stageMesh(progress: tileProgress)
        lastLatencyMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    private func playCurrent() {
        guard let c = model.playing else { return }
        switch c {
        case .morph:
            // The struts rebuild into the new family. A cross-fade over the
            // rebuild reads as a morph and costs one mesh build.
            withAnimation(.easeInOut(duration: c.duration)) { rebuild() }
        case .tile, .jumpToSample:
            // ★ The single cell EXPANDS OUTWARD to tile the part — animated, not
            // cut to. `tileProgress` drives the cell count, so the block really
            // grows a ring at a time.
            tileProgress = 0
            rebuild()
            animateTile(over: c.duration)
        case .stressWipeAndDive:
            // ★ The field wipes DOWN the object, then the camera DIVES into the
            // densest part of the lattice.
            tileProgress = 1
            rebuild()
            wipe = 0
            withAnimation(.easeInOut(duration: c.duration * 0.5)) { wipe = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + c.duration * 0.55) {
                dive()
            }
        case .boundarySwap:
            withAnimation(.easeInOut(duration: c.duration)) { rebuild() }
        }
        model.finishedPlaying()
    }

    /// ★ THE DIVE (§2 Stage C): after the field has wiped down the part, the
    /// camera closes on the DENSEST point of the baked field — the user sees the
    /// lattice get denser where the stress is, from the inside.
    private func dive() {
        let target: SIMD3<Float> =
            LatticeWizardSample.densestPoint(for: mesh ?? model.stageMesh())
        camera.pan(dx: -target.x, dy: -target.z, viewportHeight: 800)
        withAnimation(.easeInOut(duration: 0.9)) { camera.zoom(0.45) }
    }

    /// Step the tile expansion so the block grows ring by ring rather than
    /// appearing whole. One rebuild per ring — that is what makes it a MOVE.
    private func animateTile(over seconds: Double) {
        let rings = max(1, model.cellsAcross)
        let step = seconds / Double(rings)
        for r in 1...rings {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(r)) {
                tileProgress = Double(r) / Double(rings)
                withAnimation(.easeOut(duration: step)) { rebuild() }
            }
        }
    }

    // MARK: small shared bits (no prose anywhere)

    @ViewBuilder private func group<C: View>(_ title: String,
                                             @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .heavy)).tracking(0.6)
                .foregroundStyle(DS.Color.textQuaternary.color)
            content()
        }
    }

    private func scrubRow(value: Double, unit: String, step: Double,
                          range: ClosedRange<Double>,
                          set: @escaping (Double) -> Void) -> some View {
        Text(String(format: "%.2f %@", value, unit))
            .dsStyle(DS.TypeScale.bodyStrong).monospacedDigit()
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, 7).padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.pill)
                .fill(DS.Color.fillSelected.color))
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                let next = value + Double(v.translation.width) * step
                set(Swift.min(range.upperBound, Swift.max(range.lowerBound, next)))
            })
    }

    private func segmentRow(_ names: [String], selected: Int,
                            tap: @escaping (Int) -> Void) -> some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                segmentButton(n, on: selected == i) { tap(i) }
            }
        }
    }

    private func segmentButton(_ name: String, on: Bool,
                               tap: @escaping () -> Void) -> some View {
        let ink: Color = (on ? DS.Color.textPrimary : DS.Color.textTertiary).color
        let fill: Color = on ? DS.Color.fillSelected.color : Color.clear
        return Button(action: tap) {
            Text(name)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: DS.Radius.pill).fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wizard-seg-\(name.lowercased())")
    }
}

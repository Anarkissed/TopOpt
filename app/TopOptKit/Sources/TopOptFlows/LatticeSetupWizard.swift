// LatticeSetupWizard.swift — ★ PAGE 3: THE LATTICE SETTINGS WIZARD
// (task 2026-08-12-lattice-page-redesign §2, rearranged by
//  task 2026-08-14-lattice-separation §5, §6 and §7).
//
// ★ THE LAW: "NO MORE EXHAUSTING MASSIVE PIECES OF TEXT. SHOW THE CHANGES BEING
// MADE ON SCREEN." There is no explanatory prose on this page. Every setting
// explains itself by MOVING the object.
//
// ★ WHAT PR 328 GOT WRONG, IN HIS WORDS: "This was meant to act as a wizard — but
// all I see are the selections on the left-hand side? There should be a wizard
// that takes you through each selection IN THE CENTER OF THE SCREEN, one at a
// time." It had the cinematics, the stages and the sample; what it did not have
// was a wizard. Every control lived in the left modal, so the page was a settings
// panel that happened to animate.
//
// THE LAYOUT NOW.
//
//   centre        the object, AND the wizard card directly beneath it: this
//                 stage's decision, alone, with NEXT (§5a).
//   centre-left   the persistent modal — every selection, always live, grouped
//                 under SUB-TITLES THAT ARE THE WIZARD'S STAGES (§5c). Centred
//                 vertically, clear of the top and bottom edges (§6).
//   top-centre    the disclaimer: one line, an X.
//   bottom-right  Save & Exit → back to the lattice page.
//
// ★ AND THEY ARE ONE STATE MACHINE, NOT TWO UIs (§5c / bar R5). Changing a
// setting in the modal calls `model.touched(_:)`, which moves the wizard to that
// setting's stage so the change is SEEN; Next calls `model.advance()`, which moves
// the modal's highlighted sub-title. The mapping is `LatticeWizardSetting.stage` —
// one table, read by both.
//
// ★ §7 — THE SAMPLE IS VISIBLE. See `LatticeWizardReveal` for the defect this
// page shipped with and why the fix is a type rather than a condition.

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
    /// ★ §7 — the stress wipe. A CINEMATIC that runs and finishes, never a
    /// property of a setting: `reveal.value` is 1 unless a wipe is running.
    @State private var reveal = LatticeWizardReveal()
    /// Last measured build+upload time for the centre object, in ms (R4 of the
    /// previous task — kept, because it is the page's own honesty about latency).
    @State private var lastLatencyMS: Double = 0
    @State private var mesh: ViewerMesh?

    public init(project: ProjectModel, onExit: @escaping () -> Void) {
        self.project = project
        self.onExit = onExit
        _model = State(initialValue: LatticeWizardModel(settings: project.lattice))
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                DS.Color.background.color.ignoresSafeArea()
                stageView
                wizardCard
                HStack(spacing: 0) {
                    selectionsModal
                        // ★ §6 — centre-left, vertically centred, clear of both edges.
                        .pageLeftModal(canvasHeight: geo.size.height)
                    Spacer(minLength: 0)
                }
                disclaimer
                saveAndExit
            }
        }
        // ★ §7b — FRAME THE SAMPLE ON ENTRY, at a sensible size, whatever the
        // camera was doing before.
        .onAppear { rebuild(); frameSample() }
        .onChange(of: model.playToken) { _ in playCurrent() }
        // ★ §7b — …AND ON EVERY STAGE TRANSITION. A stage change swaps one cell
        // for a tiled block (or back), which is a different object at a different
        // scale, and the previous stage may have left the camera mid-dive.
        .onChange(of: model.stage) { _ in rebuild(); frameSample() }
    }

    // MARK: the centre — the object

    private var stageView: some View {
        MetalMeshView(mesh: mesh, camera: camera,
                      stressTints: model.stage != .cell && model.densityMode == .auto
                          ? sampleTints : nil,
                      // ★ §7 — ONE input, and it is the cinematic's own progress.
                      // It was `densityMode == .auto ? wipe : 1`, with `wipe`
                      // starting at 0 and `.auto` the default: the page opened
                      // with every fragment discarded.
                      reveal: Float(reveal.value))
            .ignoresSafeArea()
    }

    /// Re-fit the camera to whatever is on the stage now. `reframe` re-anchors the
    /// look-at target on the object's own centre and refits the distance, so it
    /// also clears the pan the Stage-C dive left behind.
    private func frameSample() {
        guard let m = mesh, !m.isEmpty else { return }
        camera.reframe(m.bounds)
    }

    /// The BAKED field mapped onto the tiled block's vertices by height — the
    /// sample's own field, never a solve.
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

    // MARK: ★ §5a — THE WIZARD, CENTRE STAGE

    /// One decision at a time, in the middle of the screen, with the sample
    /// responding live. The card holds THIS stage's settings and nothing else; the
    /// modal on the left holds all of them, always.
    private var wizardCard: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    ForEach(LatticeWizardStage.allCases, id: \.rawValue) { s in
                        Capsule()
                            .fill((s == model.stage ? DS.Color.accent
                                                    : DS.Color.strokeSubtle).color)
                            .frame(width: s == model.stage ? 22 : 10, height: 4)
                    }
                    Text(model.stage.title)
                        .dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                        .foregroundStyle(DS.Color.textPrimary.color)
                    Spacer(minLength: 0)
                }
                ForEach(model.stage.settings, id: \.rawValue) { s in
                    settingControl(s, titled: true)
                }
                nextButton
            }
            .padding(DS.Space.ml)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .fill(DS.Surface.panel.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                    .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.panel)
            .padding(.bottom, PageChrome.edge + PageChrome.actionButton)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Centred in the STAGE — the space the object occupies — not in the raw
        // canvas, so the card can never land on top of the left modal. On a
        // portrait iPad a full-width centring puts a 380 pt card 50 pt into a
        // 348 pt panel, and overlapping chrome is the complaint this page is
        // being rebuilt to answer.
        .padding(.leading, PageChrome.panelWidth + PageChrome.edge * 2)
        .accessibilityIdentifier("wizard-card")
    }

    /// ★ NEXT advances the wizard (§5a). On the last stage there is nothing to
    /// advance to, so the card offers the same Save & Exit the corner does rather
    /// than a button that does nothing.
    private var nextButton: some View {
        Button {
            if model.hasNext { model.advance() } else { saveAndClose() }
        } label: {
            HStack(spacing: DS.Space.s) {
                Text(model.hasNext ? "Next" : "Save & Exit")
                    .dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                if model.hasNext {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(DS.Color.accent.color))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wizard-next")
    }

    // MARK: the persistent left modal (§5b/§5c) — every selection, always live

    /// ★ §5c — THE SUB-TITLES ARE THE WIZARD'S STAGES. The modal is grouped by
    /// `LatticeWizardStage`, each group holding exactly `stage.settings`, and the
    /// group the wizard is on is lit. Tapping a sub-title jumps the wizard there;
    /// changing a control inside it moves the wizard there too.
    private var selectionsModal: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(LatticeWizardStage.allCases, id: \.rawValue) { stage in
                VStack(alignment: .leading, spacing: 7) {
                    stageSubTitle(stage)
                    ForEach(stage.settings, id: \.rawValue) { s in
                        settingControl(s, titled: true)
                    }
                }
            }
            latencyReadout
        }
        .padding(DS.Space.ml)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    private func stageSubTitle(_ s: LatticeWizardStage) -> some View {
        let on: Bool = (model.stage == s)
        return Button { model.jump(to: s) } label: {
            HStack(spacing: DS.Space.xs) {
                Circle().fill((on ? DS.Color.accent : DS.Color.strokeSubtle).color)
                    .frame(width: 6, height: 6)
                Text(s.title.uppercased())
                    .font(.system(size: 9.5, weight: .heavy)).tracking(0.6)
                    .foregroundStyle((on ? DS.Color.textSecondary
                                         : DS.Color.textQuaternary).color)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wizard-stage-\(s.rawValue)")
    }

    // MARK: ONE control per setting, rendered by the card AND the modal

    /// The SAME control in both places — the card and the modal are two views of
    /// one state, so they cannot offer two different editors for one number.
    @ViewBuilder private func settingControl(_ s: LatticeWizardSetting,
                                             titled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if titled {
                Text(s.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            switch s {
            case .type: typeRow
            case .size:
                scrubRow(value: model.cellMM, unit: "mm", step: 0.05, range: 1...20) {
                    model.cellMM = $0
                    model.touched(.size)
                    rebuild()
                }
            case .thickness:
                scrubRow(value: model.relativeDensity * 100, unit: "%", step: 0.4,
                         range: 5...90) {
                    model.relativeDensity = $0 / 100
                    model.touched(.thickness)
                    rebuild()
                }
            case .cellSize:
                segmentRow(["Auto", "Fixed", "Swept"], selected: cellModeIndex) { i in
                    model.setCellSizeMode([.auto, .fixed, .swept][i])
                }
            case .density:
                segmentRow(["Auto", "Uniform"],
                           selected: model.densityMode == .auto ? 0 : 1) { i in
                    model.setDensityMode(i == 0 ? .auto : .uniform)
                }
            case .finish:
                segmentRow(["None", "Rim", "Skin"], selected: boundaryIndex) { i in
                    model.setBoundary([.none, .rim, .fullSkin][i])
                }
            }
        }
    }

    private var typeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs) {
                ForEach(LatticeType.family, id: \.id) { t in typeChip(t) }
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

    /// The measured build+upload time for the object on screen, always visible.
    /// A number, not a claim.
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

    /// A SMALL TOP-CENTRE MODAL WITH AN X. One line. Dismissible.
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
                Button { saveAndClose() } label: {
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

    private func saveAndClose() {
        project.lattice = model.applied(to: project.lattice)
        onExit()
    }

    // MARK: the moves

    /// Rebuild the centre object and MEASURE it. Everything the page draws goes
    /// through here, so the number on screen is the number for every change.
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
            // The single cell EXPANDS OUTWARD to tile the part — animated, not cut
            // to. `tileProgress` drives the cell count, so the block really grows a
            // ring at a time.
            tileProgress = 0
            rebuild()
            animateTile(over: c.duration)
        case .stressWipeAndDive:
            // The field wipes DOWN the object, then the camera DIVES into the
            // densest part of the lattice.
            tileProgress = 1
            rebuild()
            animateWipe(over: c.duration * 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + c.duration * 0.55) {
                dive()
            }
        case .boundarySwap:
            withAnimation(.easeInOut(duration: c.duration)) { rebuild() }
        }
        model.finishedPlaying()
    }

    /// ★ THE DIVE (Stage C): after the field has wiped down the part, the camera
    /// closes on the DENSEST point of the baked field — the user sees the lattice
    /// get denser where the stress is, from the inside.
    private func dive() {
        let target: SIMD3<Float> =
            LatticeWizardSample.densestPoint(for: mesh ?? model.stageMesh())
        camera.pan(dx: -target.x, dy: -target.z, viewportHeight: 800)
        withAnimation(.easeInOut(duration: 0.9)) { camera.zoom(0.45) }
    }

    /// ★ §7 — STEP the wipe, so it really wipes, and END it whether it lands or is
    /// pre-empted. A value handed straight to a Metal view is not interpolated by
    /// `withAnimation`, so the previous single assignment was a jump; stepping it
    /// on the same clock the tile expansion uses is what makes it a MOVE.
    private func animateWipe(over seconds: Double) {
        let steps = 18
        reveal.begin()
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds * Double(i) / Double(steps)) {
                if i == steps { reveal.end() } else { reveal.step(to: Double(i) / Double(steps)) }
            }
        }
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

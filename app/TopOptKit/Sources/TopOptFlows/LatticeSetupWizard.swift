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
    /// ★ §5 — which numeric field has the keypad open. One at a time, keyed by the
    /// field's id, so every number on this page types as well as drags.
    @State private var numberPadField: String?

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
                // ★ ONE MODAL (maintainer, 2026-08-14): *"Combine the two modals
                // together. Place the one on the right at the very bottom of the
                // one on the left."* The floating wizard card is gone; its view
                // switch is the last row inside this panel.
                selectionsModal
                    .modifier(WizardModalPlacement(canvasHeight: geo.size.height))
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

    /// ★ §11(a) — THE CARD IS THE WIZARD'S PROGRESS, NOT A SECOND COPY OF THE
    /// CONTROLS.
    ///
    /// ★ THE DEFECT, IN HIS SCREENSHOT: "A DUPLICATE 'FINISH' PANEL FLOATS IN THE
    /// MIDDLE-BOTTOM OF THE SCREEN, overlapping the model, carrying its own
    /// Density and Finish rows AND ITS OWN 'SAVE & EXIT' — while a second
    /// 'Save & Exit' sits bottom-right."
    ///
    /// ★ ROOT CAUSE. This card rendered `model.stage.settings` through
    /// `settingControl`, and `selectionsModal` rendered EVERY stage's settings
    /// through the same function — so on the Finish stage the Density and Finish
    /// editors existed TWICE on one screen, once in the left modal and once in a
    /// 380 pt panel floating over the model. It was duplication by construction,
    /// not a layout accident.
    ///
    /// ★ THE FIX. Each control exists ONCE, in the left modal — the panel §11(c)
    /// requires every page to have. The card keeps what only it can carry: which
    /// stage you are on, and the way forward. It is now a short bar rather than a
    /// stack of editors, so it stops covering the object the page exists to show.
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

    /// ★ NEXT advances the wizard (§5a).
    ///
    /// ★ §11(a)/R13 — AND ON THE LAST STAGE IT IS NOT A SECOND "SAVE & EXIT".
    /// It used to relabel itself, which put TWO buttons carrying that exact text
    /// on one screen: this one, mid-card, and the page's own bottom-right action.
    /// There is now ONE Save & Exit on the page and it is the corner's, which is
    /// where every other page in the app puts its primary action (§0 rule S17).
    @ViewBuilder private var nextButton: some View {
        if model.hasNext {
            Button { model.advance() } label: {
                HStack(spacing: DS.Space.s) {
                    Text("Next")
                        .dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Capsule().fill(DS.Color.accent.color))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wizard-next")
        }
    }

    // MARK: the persistent left modal (§5b/§5c) — every selection, always live

    /// ★ §5c — THE SUB-TITLES ARE THE WIZARD'S STAGES. The modal is grouped by
    /// `LatticeWizardStage`, each group holding exactly `stage.settings`, and the
    /// group the wizard is on is lit. Tapping a sub-title jumps the wizard there;
    /// changing a control inside it moves the wizard there too.
    ///
    /// ★ IT SHOWS ONE VIEW AT A TIME, AND IT HUGS ITS CONTENT.
    ///
    /// ★ HIS TWO INSTRUCTIONS THAT SHAPE THIS: *"Why is the modal so big and so up
    /// high in the way? Cut it as small as possible and drop it as low as possible
    /// without making anything hidden or making anything requiring scrolling"* and
    /// *"These are now 'views'."*
    ///
    /// ★ THE SIZE DEFECT WAS A `ScrollView`, AND IT WAS MINE. I wrapped this body
    /// in one so it could scroll if it outgrew its band — but a `ScrollView` takes
    /// ALL the height it is offered, so the panel stopped hugging its content and
    /// ran nearly the full screen with empty glass below the last control. It is
    /// gone: showing one view at a time is what makes scrolling unnecessary, which
    /// is the fix he actually asked for.
    private var selectionsModal: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(model.stage.settings.filter { !$0.isRenderedByCellSize },
                    id: \.rawValue) { s in
                settingControl(s, titled: true)
            }
            latencyReadout
            // ★ THE CARD, MOVED HERE: "place the one on the right at the very
            // bottom of the one on the left."
            viewSwitcher
        }
        .padding(DS.Space.ml)
        .frame(width: PageChrome.panelWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .animation(DS.Motion.emphasized, value: model.stage)
    }

    /// ★ THE VIEW SWITCH — the whole of what the floating card is now. Two views,
    /// switchable in EITHER direction ("make it so you can go back and forth"),
    /// and no third tab for Finish.
    private var viewSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(LatticeWizardStage.allCases, id: \.rawValue) { s in
                let on: Bool = (model.stage == s)
                Button { model.jump(to: s); rebuild(); frameSample() } label: {
                    Text(s.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle((on ? DS.Color.textPrimary
                                             : DS.Color.textTertiary).color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        // ★ "make the view buttons the same blue as they used to
                        // be" — the wizard's own accent, which is what its Next
                        // button and its lit stage pip wore before the card was
                        // folded into this panel.
                        .background(Capsule().fill(on ? DS.Color.accent.color
                                                      : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wizard-stage-\(s.rawValue)")
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.Color.background.opacity(0.35).color)
            .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
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
                // ★ NEVER RENDERED HERE. `isRenderedByCellSize` filters it out of
                // the list; the cell dimension is drawn by `.cellSize` below, as
                // whatever that mode needs. Asking for it twice is the duplication
                // the maintainer removed.
                EmptyView()
            case .thickness:
                scrubRow("thickness", value: model.relativeDensity * 100, unit: "%",
                         step: 0.4, range: 5...90) {
                    model.relativeDensity = $0 / 100
                    model.touched(.thickness)
                    rebuild()
                }
            case .cellSize:
                segmentRow(["Auto", "Fixed", "Swept"], selected: cellModeIndex) { i in
                    model.setCellSizeMode([.auto, .fixed, .swept][i])
                }
                // ★ THE CELL DIMENSION LIVES HERE AND NOWHERE ELSE (maintainer,
                // 2026-08-14): *"Auto needs no cell size, fixed needs one, and
                // swept needs a range."* One row, three shapes, decided by the
                // mode directly above it.
                switch model.cellSizeMode {
                case .auto, .fit:
                    // Core picks it. Nothing to enter, so nothing is offered —
                    // a field the user cannot set would be the readout-that-looks-
                    // like-a-picker defect again.
                    EmptyView()
                case .fixed:
                    scrubRow("size", value: model.cellMM, unit: "mm", step: 0.05,
                             range: 1...20) {
                        model.cellMM = $0
                        model.touched(.size)
                        rebuild()
                    }
                case .swept:
                    sweptRange
                }
            case .density:
                // ★ §8 — THREE MODES. Auto is the default and must never refuse.
                segmentRow([LatticeDensityMode.auto.title,
                            LatticeDensityMode.uniform.title,
                            LatticeDensityMode.perRegion.title],
                           selected: densityModeIndex) { i in
                    model.setDensityMode([.auto, .uniform, .perRegion][i])
                }
                if model.densityMode == .perRegion {
                    // ★ §8(e) — THE GAP, SURFACED. PR 331 landed the region layer
                    // but NOT the per-sector density override in the grading law,
                    // so a number typed here is captured and not yet consumed.
                    // Saying so beats a control that silently does nothing — the
                    // Diagrid-readout defect, which this project has already paid
                    // for once.
                    Text("Set each region's density in its drawer. Core still "
                         + "derives density from the cell — these are saved, not "
                         + "yet run.")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.warning.color)
                        .accessibilityIdentifier("wizard-per-region-gap")
                }
            case .finish:
                segmentRow(["None", "Rim", "Skin"], selected: boundaryIndex) { i in
                    model.setBoundary([.none, .rim, .fullSkin][i])
                }
                // ★ §10(b) — A STATED FACT, NOT A PICKER. Core implements exactly
                // ONE skin, and the old "Skin pattern — Diagrid" readout looked
                // like an unselected control. It is presented as what it is until
                // a second pattern exists.
                if model.boundary == .fullSkin {
                    Text("Skin pattern: Diagrid — the only one core builds.")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                        .accessibilityIdentifier("wizard-skin-pattern-fact")
                }
            }
        }
    }

    /// ★ §11(b) — EVERY LATTICE TYPE MUST BE REACHABLE. His screenshot shows the
    /// picker clipped at the modal's right edge with a chip reading "F…". A
    /// horizontal `ScrollView` was already here; what was missing is
    /// `fixedSize()` on the chips, so SwiftUI compressed the row to the modal's
    /// 348 pt instead of letting it overflow and scroll. A truncated chip is a
    /// lattice the user cannot pick.
    /// ★ THE SELECTED TYPE IS THE FIRST ONE VISIBLE (maintainer, 2026-08-14):
    /// *"If starting with Octet Truss it should be the first one visible."*
    ///
    /// His screenshot opens on "Octet truss" with the row showing "…entred cubic",
    /// "FCC + Z", "Diamond" — four chips, none of them the one that is selected,
    /// and the leading one cut off mid-word.
    ///
    /// ★ SCROLLING CANNOT DO THIS, AND I TRIED IT FIRST. Octet truss was the LAST
    /// entry in `LatticeType.family`, so `scrollTo(anchor: .leading)` clamps at the
    /// end of the content and parks it at the RIGHT edge — exactly where it
    /// already was. A selection that is last can never be scrolled to the front.
    ///
    /// ★ SO THE LIST ITSELF WAS REORDERED — see `LatticeType.family`, where octet
    /// now leads. That is what he asked for ("place it on the far left of the
    /// list"), and it makes this row a plain stable list again: no snapshot, no
    /// per-appearance shuffling, nothing that moves a chip out from under a finger.
    /// The row still SCROLLS — there are more types than fit 348 pt — it just
    /// starts from the selected one instead of from whatever happens to be first.
    private var typeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs) {
                ForEach(LatticeType.family, id: \.id) { t in typeChip(t) }
            }
            .padding(.trailing, DS.Space.xs)
        }
    }

    private func typeChip(_ t: LatticeType) -> some View {
        let on: Bool = (model.topologyID == t.id)
        let ink: Color = (on ? DS.Color.textPrimary : DS.Color.textTertiary).color
        let fill: Color = on ? DS.Color.fillSelected.color : Color.clear
        return Button { model.setTopology(t.id) } label: {
            Text(t.displayName)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
                .fixedSize()                     // ★ §11(b): never truncate a type
                .foregroundStyle(ink)
                .padding(.vertical, 6)
                .padding(.horizontal, DS.Space.sm)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wizard-type-\(t.id)")
    }

    /// ★ §9(a) — THE SWEEP WINDOW: two ends, both typed, plus what the sweep
    /// actually keys on and what a too-narrow window will do.
    @ViewBuilder private var sweptRange: some View {
        HStack(spacing: DS.Space.s) {
            scrubRow("cellMin", value: model.cellMinMM, unit: "mm", step: 0.05,
                     range: 0.1...20) { model.cellMinMM = $0; rebuild() }
            Text("–").dsStyle(DS.TypeScale.headline)
                .foregroundStyle(DS.Color.textTertiary.color)
            scrubRow("cellMax", value: model.cellMaxMM, unit: "mm", step: 0.05,
                     range: 0.1...20) { model.cellMaxMM = $0; rebuild() }
        }
        // ★ §9(d) — WHICH FIELD DRIVES THE SWEEP, said plainly. Not stress:
        // `plan_cell_sizes` reads each block's thinnest DENSITY (printability)
        // and thinnest MEMBER WIDTH (the cells-per-member ceiling).
        Text("Core picks a cell per block from its density and member width.")
            .dsStyle(DS.TypeScale.caption2)
            .foregroundStyle(DS.Color.textQuaternary.color)
        if let warn = model.sweptWindowWarning {
            Text(warn)
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.warning.color)
                .accessibilityIdentifier("wizard-swept-narrow")
        }
    }

    private var cellModeIndex: Int {
        switch model.cellSizeMode {
        case .auto: return 0
        case .fixed: return 1
        default: return 2
        }
    }
    private var densityModeIndex: Int {
        switch model.densityMode {
        case .auto: return 0
        case .uniform: return 1
        case .perRegion: return 2
        }
    }
    private var boundaryIndex: Int {
        switch model.boundary {
        case .none: return 0
        case .rim: return 1
        case .fullSkin: return 2
        }
    }

    /// ★ AS LOW AS POSSIBLE, WITHOUT HIDING ANYTHING.
    ///
    /// His words: *"drop it as low as possible without making anything hidden."*
    /// So the panel is BOTTOM-anchored in the band rather than centred in it, and
    /// the band still starts below the identity rows (`PageChrome.noteTop`) and
    /// still stops clear of the Save & Exit cluster — a panel that reached the
    /// bottom edge would sit under that button, which is "hidden".
    ///
    /// `maxHeight` on the band is what keeps it honest: the panel hugs its content
    /// (it has no `ScrollView` any more) and can only be as tall as the band, so
    /// "as low as possible" can never become "off the bottom".
    private struct WizardModalPlacement: ViewModifier {
        let canvasHeight: CGFloat
        func body(content: Content) -> some View {
            content
                .frame(maxHeight: PageChrome.sidePanelBand(canvasHeight: canvasHeight),
                       alignment: .bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                // ★ "make the entire modal in-line with the bottom of the
                // screen… make the padding equal on both sides". One inset,
                // leading and bottom, so the panel's corner mirrors Save & Exit's.
                .padding(.leading, PageChrome.edge)
                .padding(.bottom, PageChrome.edge)
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
            // ★ §10 — AND PULL THE CAMERA BACK OUT TO SEE IT.
            //
            // The Auto-density cinematic ends with `dive()`, which pans to the
            // densest point and zooms to 0.45 — INSIDE the lattice. A boundary
            // swap used to only cross-fade the mesh, so a rim or a skin was being
            // built correctly and drawn from a viewpoint buried inside the struts.
            // That is the second half of "there is no skin or rim visible": a
            // FINISH is a thing you look at from OUTSIDE, so showing one re-frames.
            withAnimation(.easeInOut(duration: c.duration)) { rebuild() }
            withAnimation(.easeInOut(duration: c.duration)) { frameSample() }
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

    /// ★ §5 — EVERY NUMERIC FIELD IS TAPPABLE AND OPENS THE NUMERIC KEYPAD.
    ///
    /// ★ HIS RULE, STATED TWICE: "Any input MUST be selectable and a small numeric
    /// keyboard pop-up to input the number — NOT just touch inputs." He reports
    /// the drag-only fields made it "all but impossible to actually input a round
    /// number into most of the values for lattices" — which is exactly true of a
    /// 0.05-mm-per-point scrub: landing on 3.00 mm by finger is luck.
    ///
    /// Drag REMAINS, as the coarse adjustment. Typing is now always available, and
    /// both write through the SAME `set` closure, so there is no parallel entry
    /// path and no second clamp.
    private func scrubRow(_ id: String, value: Double, unit: String, step: Double,
                          range: ClosedRange<Double>,
                          set: @escaping (Double) -> Void) -> some View {
        Text(String(format: "%.2f %@", value, unit))
            .dsStyle(DS.TypeScale.bodyStrong).monospacedDigit()
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, 7).padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.pill)
                .fill(DS.Color.fillSelected.color))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                let next = value + Double(v.translation.width) * step
                set(Swift.min(range.upperBound, Swift.max(range.lowerBound, next)))
            })
            .onTapGesture { numberPadField = id }
            .numberPad(Binding(get: { numberPadField == id },
                               set: { if !$0 { numberPadField = nil } }),
                       config: .init(title: "", unit: unit, allowsDecimal: true),
                       seed: value) { v in
                guard let v else { return }
                set(Swift.min(range.upperBound, Swift.max(range.lowerBound, v)))
            }
            .accessibilityIdentifier("wizard-field-\(id)")
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

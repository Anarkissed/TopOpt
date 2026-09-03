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

    /// ★★★ THE ORGANIC SAMPLE IS THE PR 353 TEST CUBE, AS PRINTED (maintainer,
    /// 2026-09-03) — its real emitted spans, rendered through the SAME path a run's
    /// spans take (`OrganicSpanIndex` bake + the march, `LatticeSDFScene`), at the
    /// radius in the span file, free tips kept, no rescale. The box mesh is drawn at
    /// alpha 0: it only clips the march to the part, exactly as a run's part does.
    @State private var organicScene: LatticeSDFScene?
    @State private var organicSceneToken = 0
    /// What the sample bake indexed against the receipt bundled beside the spans —
    /// the same §10 check a run gets. Shown in the banner; nil when not organic.
    @State private var organicSampleMeasurement: String?
    private var organicSampleShown: Bool { model.cellTransition == .organicGrade }

    private var stageView: some View {
        MetalMeshView(mesh: mesh, camera: camera,
                      stressTints: model.stage != .cell && model.densityMode == .sim
                          ? sampleTints : nil,
                      // ★ §7 — ONE input, and it is the cinematic's own progress.
                      // It was `densityMode == .sim ? wipe : 1`, with `wipe`
                      // starting at 0 and `.auto` the default: the page opened
                      // with every fragment discarded.
                      reveal: Float(reveal.value),
                      bodyAlpha: organicSampleShown ? 0 : 1,
                      latticeLayer: organicScene.map {
                          LatticeLayerInputs(scene: $0, params: LatticeProxyParams(),
                                             sceneToken: organicSceneToken, faceTints: [:])
                      })
            .ignoresSafeArea()
            // ★ The cube re-traces off the main thread whenever a pick changes.
            .task(id: organicSamplePicks) { await loadOrganicSample(organicSamplePicks) }
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
                    Text(organicSampleShown && model.stage == .cell ? "Sample" : model.stage.title)
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
            // ★ ABOVE THE TYPE, ON EVERY VIEW (maintainer, 2026-08-17: "a dark
            // glass on/off check with a 'Simulate Stresses' at the top of the
            // 'Lattice Settings' modal (above the 'type')"). It is not one
            // stage's setting — it decides what the OTHER settings may offer —
            // so it sits outside the stage list rather than inside it.
            simulateStressesSwitch
            // ★ ORGANIC IS A DIFFERENT "IN THE PART" (his ruling, 2026-09-02, and the
            // on-device screenshot of 21:12 that showed both): the stage's Cell size /
            // Density / Finish rows are the OCTET's — a traced lattice has no cell to
            // size, its density is the strut width, and its finish is fixed. Under
            // Organic `organicRow` carries all three; showing the octet rows above it
            // was the "same section" he asked to replace.
            ForEach(model.stage.settings.filter {
                        !$0.isRenderedByCellSize && !(organicPaneOwns($0)) },
                    id: \.rawValue) { s in
                settingControl(s, titled: true)
            }
            // ★★ SUB-FLOOR RETENTION, HERE AND NOT ONLY ON THE RESULTS PAGE
            // (maintainer, 2026-08-20: "Add it to the settings of the lattice
            // stage"). It decides whether thin members are lattice or solid, which
            // is a lattice SETTING; requiring a completed run and a variant to
            // reach it was untenable and is fixed.
            //
            // ★ AND ONLY ON THE PART (maintainer, same day: "you have put the
            // 'unloaded wall' checkbox in both sections … Please remove them from
            // the 'One cell' sub-menu"). It is a question about the PART's members —
            // whether this region's material is too thin to certify — and a single
            // cell has no members to be thin. On the cell view it was a control
            // about something not on screen.
            // ★★ THE SECONDARY QUESTION AUTO RAISES (maintainer, 2026-08-20). Only
            // under Auto: Fit and Swept each carry their own answer already, and
            // Manual has no transition to make.
            // ★★★ THE GRADING QUESTION, IN HIS ORDER (2026-08-25: "make it so it
            // first asks IF you want to grade, then offer the type of grading
            // (full = stress+shape/shape/stress) and then the grade style
            // (stepped/default/organic). If full/shape is selected, add the grade
            // to shape band below it. Then at the very end, you add the
            // single-cell/member option").
            //
            // ★ AND NOTHING HIDES BEHIND ONE ALGORITHM ANY MORE. The band and the
            // grading options used to appear only under Stepped — "a mess right
            // now with settings only available in the Stepped section" — which
            // made the grade look like a property of that algorithm rather than a
            // question asked of all three.
            // ★★★ ORGANIC HAS ITS OWN "IN THE PART" (his ruling, 2026-09-02): the octet
            // ladder below is about cells, transitions and finishes that a traced or
            // grown lattice does not have. Nothing here is shared by accident.
            if model.stage == .lattice, model.cellTransition == .organicGrade {
                organicRow
            } else if model.stage == .lattice {
                gradeToggleRow
                if model.gradingMode != LatticeGradingMode.none { gradeTypeRow }
                gradeStyleRow
                if model.gradingMode.fitsShape { shapeBandRow }
                singleCellSwitch
            }
            // ★ NOT IN AESTHETIC (his ruling, 2026-08-24 late: "we should REMOVE
            // the 'too thin to certify' button from the aesthetic mode"). The
            // switch's whole sentence is about the strength certificate; the
            // aesthetic stage makes no such claim, and arming it there dropped
            // every floor and shredded the lattice (his img 8). Structural keeps
            // it exactly as it was.
            if model.stage == .lattice,
               (project.lattice.stageMode ?? .structural) == .structural {
                subfloorRetentionSwitch
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

    /// ★ 1 — DO YOU WANT TO GRADE AT ALL? The first question, above everything.
    @ViewBuilder private var gradeToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { model.gradingMode != LatticeGradingMode.none },
                set: { on in
                    model.gradingMode = on ? .full : LatticeGradingMode.none
                    rebuild()
                })) {
                Text("Grade the lattice")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            .toggleStyle(SwitchToggleStyle(tint: DS.Color.accent.color))
            .accessibilityIdentifier("wizard-grade-toggle")
            Text(model.gradingMode == LatticeGradingMode.none
                 ? "One cell, one density, everywhere."
                 : "The lattice varies across the part — how, below.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ★ 2 — WHAT VARIES: the stress, the shape, or both.
    @ViewBuilder private var gradeTypeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Grade")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.textTertiary.color)
            HStack(spacing: DS.Space.xs) {
                ForEach([LatticeGradingMode.full, .fitShape, .stressOnly],
                        id: \.rawValue) { m in
                    Button {
                        model.gradingMode = m
                        rebuild()
                    } label: {
                        Text(m == .full ? "Stress + shape"
                             : m == .fitShape ? "Shape" : "Stress")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .padding(.vertical, 6).padding(.horizontal, DS.Space.s)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.pill)
                                .fill((model.gradingMode == m
                                       ? DS.Color.accent.opacity(0.85)
                                       : DS.Color.background.opacity(0.35)).color))
                            .foregroundStyle(DS.Color.textPrimary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wizard-grade-type-\(m.rawValue)")
                }
            }
            Text(model.gradingMode == .full
                 ? "The density follows the solve and the cells fit the outline."
                 : model.gradingMode == .fitShape
                 ? "The cells fit the outline; one density everywhere."
                 : "The density follows the solve; one cell size everywhere.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ★ THE VIEW SWITCH — the whole of what the floating card is now. Two views,
    /// switchable in EITHER direction ("make it so you can go back and forth"),
    /// and no third tab for Finish.
    private var viewSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(LatticeWizardStage.allCases, id: \.rawValue) { s in
                let on: Bool = (model.stage == s)
                Button { model.jump(to: s); rebuild(); frameSample() } label: {
                    // ★ "One cell" has no meaning for organic (maintainer, 2026-09-03):
                    // the first tab is the printed cube — "Sample".
                    Text(organicSampleShown && s == .cell ? "Sample" : s.title)
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

    // MARK: ★ THE SIM PERMISSION

    /// ★★ "SIMULATE STRESSES" — a dark-glass on/off at the top of the modal.
    ///
    /// ★ IT IS A PERMISSION, NOT A MODE (his: "if the SIM option is selected,
    /// you can offer any variable for the AI to use, but can set some values
    /// yourself and keep them hard coded"). Turning it on does not grade
    /// anything by itself; it makes the Sim option AVAILABLE to the axes below,
    /// each of which still chooses for itself.
    ///
    /// ★ IT SAYS WHAT IT WILL COST, because the answer is "a finite-element
    /// solve". The sub-line is not decoration: it is the difference between a
    /// checkbox and an informed choice.
    private var simulateStressesSwitch: some View {
        // ★ AN ON/OFF SWITCH, NOT A CHECKBOX (maintainer, 2026-08-19). The row is
        // no longer one big Button: the SWITCH is the control, so the label is
        // plain text and the tap target is the switch itself — a checkmark that
        // toggled when you tapped anywhere on a paragraph was the old behaviour
        // and is not what a switch does.
        HStack(spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                    Text("Simulate Stresses")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                    Text(model.simulateStresses
                         ? "An FEA decides every setting left on Sim."
                         : "Every setting is yours to enter.")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
            Spacer(minLength: DS.Space.s)
            GlassToggle(isOn: model.simulateStresses) {
                model.setSimulateStresses(!model.simulateStresses)
                rebuild()
            }
            .accessibilityLabel("Simulate Stresses")
            .accessibilityIdentifier("wizard-simulate-stresses")
        }
        .padding(.vertical, DS.Space.s)
        .padding(.horizontal, DS.Space.sm)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(DS.Color.background.opacity(0.35).color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .strokeBorder((model.simulateStresses
                               ? DS.Color.accent.opacity(0.5)
                               : DS.Color.strokeSubtle).color, lineWidth: 1)))
    }

    /// ★★ STEPPED · DEFAULT GRADE · ORGANIC GRADE — how Auto changes the cell from
    /// place to place.
    ///
    /// ★ TWO OF THE THREE ARE REFUSED, VISIBLY, and refused with the geometric
    /// reason rather than "coming soon" — because the reason is the interesting part
    /// and because a user told "advanced" learns nothing about their part. Selecting
    /// one leaves the setting where it was; nothing silently runs `defaultGrade`
    /// under another name.
    private static let cellTransitions: [LatticeCellTransition] =
        [.stepped, .defaultGrade, .organicGrade]

    /// How many distinct cell sizes the shape fit can use here. The walk lives in
    /// `LatticeShapeFitLadder` — inline in this property it TRAPPED on an `Int`
    /// overflow and took the app down every time the sample switched from "One cell"
    /// to "In the part". See that file for the mechanism.
    private var shapeFitSteps: Int? {
        LatticeShapeFitLadder.steps(cellMM: model.cellMM,
                                    lineWidthMM: project.printParams.strutLineWidthMM,
                                    topologyID: model.topologyID,
                                    densityCeiling: model.relativeDensity)
    }

    /// ★ 3 — HOW the cells change: the algorithm. Always asked, whatever the
    /// grade, because it is what is laid down rather than how it varies.
    @ViewBuilder private var gradeStyleRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Grade style")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.textTertiary.color)
            HStack(spacing: DS.Space.xs) {
                ForEach(Self.cellTransitions, id: \.rawValue) { t in
                    let off = t.unavailableReason != nil
                    Button {
                        guard !off else { return }
                        model.cellTransition = t
                        rebuild()
                    } label: {
                        Text(t.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .padding(.vertical, 6).padding(.horizontal, DS.Space.s)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.pill)
                                .fill((model.cellTransition == t
                                       ? DS.Color.accent.opacity(0.85)
                                       : DS.Color.background.opacity(0.35)).color))
                            .foregroundStyle((off ? DS.Color.textTertiary
                                             : DS.Color.textPrimary).color)
                    }
                    .buttonStyle(.plain)
                    .disabled(off)
                    .accessibilityIdentifier("wizard-cell-transition-\(t.rawValue)")
                }
            }
            Text(model.cellTransition.unavailableReason ?? model.cellTransition.body)
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)

            // ★★★ GRADE TO SHAPE BAND — directly under the transition it belongs to
            // (his placement, 2026-08-23). It is a property of HOW the cells change
            // across a face, so it sits with Stepped/Default/Organic and not with the
            // cell-size mode, where the first cut put it.
            //
            // The lattice ALWAYS subdivides where a cell will not fit inside the face's
            // outline — geometry, not a preference, and this cannot switch it off. What
            // this sets is how far in from the outline the stepping continues.
        }
    }

    /// ★ 4 — HOW FAR IN the shape grade reaches. Only when the grade fits the
    /// shape at all; a stress-only grade has no outline to step toward.
    // ══════════════════════════════════════════════════════════════════════════
    // ★★★ ORGANIC (2026-09-02). Shown only under the Organic grade style; every
    // control here maps to ONE `organic_*` job key, and `gradingDictionary()` is
    // the only place that decides whether a key is written — this row never gates
    // the document, it only tells the user what will happen.
    //
    // ★ NOT A TOPOLOGY. Organic is chosen by `grading.algorithm`; the topology stays
    // "octet" (core refuses any other) and that is correct, not a leftover.
    // ══════════════════════════════════════════════════════════════════════════
    /// ★ HONEST INDEX: a swept/fit mode inherited from the lattice types lights
    /// NOTHING here (−1) — it is not one of these three choices, and lighting
    /// "Auto · grade" over a job that carried the octet's 5.5–6 mm window was the
    /// 2026-09-02 defect. The chip and the row reset such a mode to Auto out loud.
    private var organicCellIndex: Int {
        switch model.cellSizeMode {
        case .auto: return 0
        case .fit: return 1
        default: return -1      // an inherited octet mode lights nothing (D2)
        }
    }
    /// True once this sheet reset an inherited swept/fit window to Auto for organic,
    /// so the pane can SAY it happened instead of the job quietly changing.
    @State private var organicWindowReset = false
    private var organicDensityIndex: Int {
        if model.organicStrutWidthMM > 0 { return model.simulateStresses ? 2 : 1 }
        return (model.simulateStresses && model.densityMode == .sim) ? 1 : 0
    }

    @ViewBuilder private var organicRow: some View {
        let layerH = project.printParams.layerHeightMM
        let growthRefusal = LatticeSettings.organicGrowthRefusalReason(layerHeightMM: layerH)
        VStack(alignment: .leading, spacing: 5) {
            Text("Organic lattice")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.textTertiary.color)
                .padding(.top, DS.Space.s)
                // ★ FORCED ON LOAD TOO — a project saved with organic before this rule
                // existed must not keep an un-fitted outline.
                .onAppear {
                    if !model.organicShapeFit { model.organicShapeFit = true }
                    // ★ A project SAVED with organic over an inherited swept/fit
                    // window gets the same reset as the chip tap, and says so.
                    if model.cellSizeMode != .auto && model.cellSizeMode != .fit {
                        model.setCellSizeMode(.auto); organicWindowReset = true
                    }
                }
            // ★ TRACED vs GROWN — two ARCHITECTURES, not a parameter (§1B).
            HStack(spacing: DS.Space.xs) {
                organicPill("Traced", on: !model.organicGrowth, enabled: true) {
                    model.organicGrowth = false; rebuild()
                }
                organicPill("Grown", on: model.organicGrowth, enabled: growthRefusal == nil) {
                    guard growthRefusal == nil else { return }
                    model.organicGrowth = true; rebuild()
                }
            }
            if let why = growthRefusal {
                // ★ SAY WHY IT IS DISABLED (§2A) — a greyed control with no sentence is
                // the failure the refusal reason exists to avoid.
                Text(why).dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.organicGrowth
                     ? "Laid down in printed-layer order; every step refuses an unsupported underside."
                     : "Struts traced along the stress field.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ★★★ CELL SIZE (his item 1): Auto (grade) / Fit (one size) / a size picked
            // from the list of sizes that CAN FIT the selected regions. For organic the
            // cell is the SEPARATION field; a graded window is what makes a graded lattice.
            // ★ D1: under Structural the controls stay live but the run will be refused
            // by core until its organic certification is wired — say so HERE, in
            // core's words, before he reaches the run button that carries the same.
            if organicStructuralGateClosed {
                Text(TopOptKit.organicStructuralGateMessage)
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Cell size").font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.textTertiary.color).padding(.top, DS.Space.xs)
            // ★★ ORGANIC CELL MODES ARE AUTO AND FIT (maintainer D2, 2026-09-03) — no
            // octet notion here: no sizes, no candidate list, no "fits" computed in
            // the app.
            //   AUTO: the largest grade possible, made entirely from the FEA — a
            //         separation window from the smallest fitting to the largest
            //         fitting, FEA-driven within it.
            //   FIT:  one separation, no grade (except grade-to-shape) — the middle of
            //         what fits; of exactly two, the larger.
            // CORE decides what fits and what it chose; the run's receipt is what the
            // app displays (window/separation and the fitting set). Under Structural,
            // core confirms each Auto option structurally sound — displayed from the
            // receipt, never inferred here.
            if organicWindowReset {
                Text("Reset to Auto: the lattice types' cell setting is not an organic mode.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Core refuses `fit` on a job that declares no region to fit into
            // (job.cpp: "a job that declares none states no requirement to fit").
            let fitPossible = project.latticeJobRegions().regions.contains(where: { $0.role == .include })
            // ★ OFFER, NEVER SUBSTITUTE (maintainer ruling, Aug 5; re-stated 2026-09-03):
            // Fit is DISABLED with its reason when no region is declared — the app never
            // sends Auto for a Fit the user chose.
            HStack(spacing: DS.Space.xs) {
                organicPill("Auto", on: organicCellIndex == 0, enabled: true) {
                    model.setCellSizeMode(.auto); rebuild()
                }
                organicPill("Fit", on: organicCellIndex == 1, enabled: fitPossible) {
                    model.setCellSizeMode(.fit); rebuild()
                }
            }
            Text(model.cellSizeMode == .fit
                 ? "One separation, no grade beyond grade-to-shape: the middle of what "
                   + "fits (of two, the larger). Core picks it; the run's receipt shows it."
                 : "The largest grade the FEA allows: a window from the smallest fitting "
                   + "separation to the largest, FEA-driven within it. Core picks the "
                   + "window; the run's receipt shows it.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textQuaternary.color)
                .fixedSize(horizontal: false, vertical: true)
            if !fitPossible {
                Text("Fit is unavailable: no lattice region is declared, and core refuses "
                     + "a fit with none to fit into.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ★ THE SEPARATIONS CERTIFICATION FOUND (maintainer, 2026-09-03): after a
            // run, the receipt's fitting set is stored on the project and offered here
            // as the factored choices — core's numbers, displayed, never computed in
            // the app. The pick travels as `organic_separation_mm` once core's schema
            // accepts it; until then it is kept and shown.
            let found = project.lattice.organicFittingSeparationsMM
            if !found.isEmpty {
                Text("Certification found these spacings work on this part:")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textTertiary.color)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(found, id: \.self) { s in
                            organicPill(String(format: "%g mm", s),
                                        on: abs(model.organicPickedSeparationMM - s) < 1e-6,
                                        enabled: fitPossible) {
                                model.organicPickedSeparationMM = s
                                model.setCellSizeMode(.fit); rebuild()
                            }
                        }
                        organicPill("Let core pick", on: model.organicPickedSeparationMM == 0, enabled: true) {
                            model.organicPickedSeparationMM = 0; rebuild()
                        }
                    }
                }
                if !TopOptKit.gradingSchemaAccepts(key: "organic_separation_mm") {
                    Text("Your pick is kept and shown; it reaches the run once core accepts "
                         + "`organic_separation_mm`.")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // ★ D2 IS AHEAD OF CORE (reviewer, 2026-09-03): core's organic auto/fit
            // semantics are a pending core item. Said here until the receipt writes
            // `fitting_separations_mm`; the reader shows it the moment it does.
            Text("Note: core's organic Auto/Fit is still being wired. Today an organic "
                 + "Fit runs core's existing fit path (one cell per region, job.cpp), and "
                 + "the receipt does not yet report the fitting set.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textQuaternary.color)
                .fixedSize(horizontal: false, vertical: true)
            // ★★★ DENSITY (his item 2): from the print parameters, thickened on request,
            // or left to the solve. Auto and Sim both leave `organic_strut_width_mm` at
            // 0 (core derives it from the band and the cell); Manual states a width.
            Text("Density").font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.textTertiary.color).padding(.top, DS.Space.xs)
            segmentRow(model.simulateStresses ? ["Auto", "Sim", "Thicker"] : ["Auto", "Thicker"],
                       selected: organicDensityIndex) { i in
                if model.simulateStresses {
                    switch i {
                    case 0: model.organicStrutWidthMM = 0; model.setDensityMode(.uniform)
                    case 1: model.organicStrutWidthMM = 0; model.setDensityMode(.sim)
                    default: if model.organicStrutWidthMM <= 0 {
                                 model.organicStrutWidthMM = 2 * project.printParams.strutLineWidthMM }
                    }
                } else if i == 0 { model.organicStrutWidthMM = 0 }
                else if model.organicStrutWidthMM <= 0 {
                    model.organicStrutWidthMM = 2 * project.printParams.strutLineWidthMM }
                rebuild()
            }
            if model.organicStrutWidthMM > 0,
               TopOptKit.gradingSchemaAccepts(key: "organic_strut_width_mm") {
                scrubRow("organicStrut", value: model.organicStrutWidthMM, unit: " mm",
                         step: 0.1, range: 0.2...5) { model.organicStrutWidthMM = $0; rebuild() }
                Text("Stated strut width; the run holds it.")
                    .dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textQuaternary.color)
            } else {
                Text(model.densityMode == .sim
                     ? "A finite-element solve sets the strut width from the stress."
                     : "Derived from the print parameters, the density band and the cell.")
                    .dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textQuaternary.color)
            }
            // ★★★ FINISH IS ALWAYS "GRADE TO FIT SHAPE" (his ruling, 2026-09-02, item 3):
            // the cells are pulled to the face-prism's OUTLINE and that is the whole
            // finish — there is no rim or skin on the faces of an organic lattice. So
            // there is no picker here: `organic_shape_fit` is forced on when Organic is
            // chosen (and below, on load), and the sentence says so.
            Text("Finish").font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.textTertiary.color).padding(.top, DS.Space.xs)
            Text("Grade to fit the shape — the lattice follows the outline of the "
                 + "face-prism. There is no finish on the faces.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textQuaternary.color)
                .fixedSize(horizontal: false, vertical: true)
            if TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit_only") {
                Toggle(isOn: Binding(get: { model.organicShapeFitOnly },
                                     set: { model.organicShapeFitOnly = $0; rebuild() })) {
                    Text("Shape fit only — no stress grading").dsStyle(DS.TypeScale.caption)
                }
            }
            // ★ OVERHANG IS TRACE-ONLY (§2C). Grown clamps to a compile-time 30 deg that
            // no job key reaches, so under growth the slider is a dead knob — hidden,
            // and the reason said.
            if TopOptKit.gradingSchemaAccepts(key: "organic_overhang_angle_deg") {
                Text("Overhang limit").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textTertiary.color).padding(.top, DS.Space.xs)
                if model.organicGrowth {
                    Text("Grown organic holds a fixed 30° overhang; the limit is not "
                         + "adjustable there.")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                } else {
                    scrubRow("organicOverhang", value: model.organicOverhangDeg, unit: "°",
                             step: 5, range: 0...90) {
                        model.organicOverhangDeg = $0; rebuild()
                    }
                    Text("0 leaves it to core.").dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                }
            }
            if TopOptKit.gradingSchemaAccepts(key: "organic_scale") {
                Text("Spacing scale").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textTertiary.color).padding(.top, DS.Space.xs)
                scrubRow("organicScale", value: model.organicScale, unit: "×",
                         step: 0.05, range: 0.5...2) {
                    model.organicScale = $0; rebuild()
                }
                // ★ ADVISORY ONLY (§6) — never a filter. Two DIFFERENT datasets, not
                // merged: traced measured on the M2, grown on a 12x12x24 fixture.
                // ★ NO THRESHOLDS HERE (addendum, 2026-09-03): the "5 mm left 40 % dust /
                // 6 mm left 85 %" figures were gc2's tracer (section 6(i), struck), and
                // the fixture sweep (6(ii)) is one 12×12×24 fixture, not this part. The
                // control is exposed; what a spacing did is the run's receipt to say.
                Text("Scales the spacing the solve derives. Coarser spacing can fragment "
                     + "the lattice; the run's receipt reports survival and pieces.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One pill of an organic segment — the same look as `gradeStyleRow`'s.
    private func organicPill(_ title: String, on: Bool, enabled: Bool,
                             _ pick: @escaping () -> Void) -> some View {
        Button { if enabled { pick() } } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.vertical, 6).padding(.horizontal, DS.Space.s)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: DS.Radius.pill)
                    .fill((on ? DS.Color.accent.opacity(0.85)
                              : DS.Color.background.opacity(0.35)).color))
                .foregroundStyle((!enabled ? DS.Color.textTertiary
                                  : on ? DS.Color.textPrimary : DS.Color.textSecondary).color)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var shapeBandRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Grade to shape band")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.textTertiary.color)
                .padding(.top, DS.Space.s)
            scrubRow("shapeFitBand", value: model.shapeFitBandMM, unit: " mm",
                     step: 1, range: 0...60) {
                model.shapeFitBandMM = $0
                rebuild()
            }
            Text("How far in from the face's outline the cells keep stepping down, "
                 + "in millimetres. 0 grades only where a cell will not fit.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textQuaternary.color)
                .fixedSize(horizontal: false, vertical: true)
            // ★★★ HOW MANY STEPS THIS PART CAN ACTUALLY GRADE (maintainer, 2026-08-23:
            // the band offered 0–60 mm while his settings allowed exactly ONE step, and
            // nothing said so).
            //
            // ★ THE LADDER'S DEPTH IS `cell / finest printable cell`, and the floor moves
            // with the SQUARE of the bead: at 0.45 mm a 4.5 mm cell can only halve once
            // before a strut is under one extrusion at any density in the band. A control
            // that implies a gradient the printer cannot lay is the decorative-control
            // defect this page has paid for before.
            if let steps = shapeFitSteps, steps <= 1 {
                Text("At this cell and bead there is no room to step down — a finer cell "
                     + "would need struts under one extrusion. Use a coarser cell, or a "
                     + "finer nozzle, to grade.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wizard-shape-fit-no-room")
            } else if let steps = shapeFitSteps {
                Text("\(steps) cell sizes available at this cell and bead.")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wizard-shape-fit-band-note")
            }
        }
    }

    /// ★★★ "ALLOW SINGLE-CELL MEMBERS" — the one-cell floor, asked for explicitly.
    ///
    /// ★ IT WRITES THE FINISH RATHER THAN REFUSING. Core lets the aesthetic floor reach
    /// ONE cell only where a boundary finish re-ties the struts a one-cell-wide member
    /// severs, so the dependency is real and one-way. Greying the finish out and making
    /// the user go and find it teaches them nothing; the switch simply satisfies its own
    /// requirement and SAYS it has, which is the same posture the rest of this panel
    /// takes. Turning it off leaves the finish alone — he may want the skin for its own
    /// sake.
    @ViewBuilder private var singleCellSwitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { model.singleCellMembers },
                                 set: { model.singleCellMembers = $0; rebuild() })) {
                Text("Allow single-cell members")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            .toggleStyle(SwitchToggleStyle(tint: DS.Color.accent.color))
            .accessibilityIdentifier("wizard-single-cell-members")
            Text(model.singleCellMembers
                 ? "One cell across a member. Needs the Skin finish to re-tie the struts "
                   + "a single cell severs — it has been set."
                 : "Two cells across a member. Turn this on for one, which needs the "
                   + "Skin finish and will set it.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ★★ "KEEP THE LATTICE WHERE THE PART IS TOO THIN TO CERTIFY IT."
    ///
    /// ★ THE COPY AND THE GATE ARE SHARED WITH THE RESULTS PAGE, through
    /// `LatticeRetentionControl` — one switch in two places must not grow two
    /// explanations or two sets of rules about when it may be operated. The
    /// exposure figures are the page's alone: they come from core's pre-flight
    /// forecast, which does not exist until there is a job to forecast.
    ///
    /// ★ AND IT REFUSES ALONGSIDE "fit", because core does (grading.cpp:66-70).
    /// Two mechanisms deciding the same material would produce two receipts, so
    /// the disabled copy says WHICH TO USE WHEN rather than only that they clash.
    private var retentionControl: LatticeRetentionControl {
        LatticeRetentionControl.compute(
            armed: model.retainSubfloor,
            graded: model.densityMode == .sim,
            capability: LatticeRetentionCapability.fromCore,
            belowFloorVoxels: nil,          // no forecast on the settings page
            regionVoxels: nil,
            ceilingFraction: nil,           // core's own number
            coreCeilingFraction: LatticeRetentionCapability.coreStressFractionDefault,
            cellMode: model.cellSizeMode)
    }

    private var subfloorRetentionSwitch: some View {
        let c = retentionControl
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DS.Space.s) {
                Text(c.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle((c.enabled ? DS.Color.textPrimary
                                               : DS.Color.textTertiary).color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                GlassToggle(isOn: model.retainSubfloor && c.enabled) {
                    guard c.enabled else { return }
                    model.retainSubfloor.toggle()
                    rebuild()
                }
                .opacity(c.enabled ? 1 : 0.4)
                .allowsHitTesting(c.enabled)
                .accessibilityLabel(LatticeRetentionControl.titleText)
                .accessibilityIdentifier("wizard-subfloor-retention")
            }
            // ★ WHY IT CANNOT BE OPERATED, said as the fact it is. Greying a row in
            // silence is the defect this page has already paid for.
            Text(c.disabledReason ?? c.body)
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle((c.disabledReason == nil
                                  ? DS.Color.textTertiary
                                  : DS.Color.warning).color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wizard-subfloor-retention-note")
        }
        .padding(.vertical, DS.Space.s)
        .padding(.horizontal, DS.Space.sm)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(DS.Color.background.opacity(0.35).color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .strokeBorder(((model.retainSubfloor && c.enabled)
                               ? DS.Color.accent.opacity(0.5)
                               : DS.Color.strokeSubtle).color, lineWidth: 1)))
    }

    /// ★ WHAT A SIM AXIS SAYS INSTEAD OF OFFERING A FIELD. A number the user
    /// cannot set must not look like one they can — the readout-that-looks-like-
    /// a-picker defect this page has already paid for twice.
    private func simDerivedNote(_ what: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 9, weight: .bold))
            Text(what)
                .dsStyle(DS.TypeScale.caption2)
        }
        .foregroundStyle(DS.Color.accent.opacity(0.85).color)
    }

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
            case .type:
                typeRow
                organicTypeRow
            case .size:
                // ★ NEVER RENDERED HERE. `isRenderedByCellSize` filters it out of
                // the list; the cell dimension is drawn by `.cellSize` below, as
                // whatever that mode needs. Asking for it twice is the duplication
                // the maintainer removed.
                EmptyView()
            case .thickness:
                // ★★ THICKNESS IS NOT AN INDEPENDENT AXIS UNDER SIM, and this is
                // core's rule, not a UI choice (maintainer asked: "Is there any
                // way that thickness could be *manually* enforced?").
                //
                // `job.cpp` REJECTS `strut_radius_mm` outright alongside a
                // `grading` block, and the graded run derives the radius per
                // position from the graded density:
                //   0.5 · octet_strut_diameter_mm(rho, cell)
                // So a thickness box offered here under Sim would be a control
                // core would refuse — the decorative-control defect, again.
                //
                // ★ BUT IT *CAN* BE PINNED, INDIRECTLY, and the note says how:
                // thickness is f(density, cell). Pin BOTH and the thickness is
                // determined. That is the honest mechanism, and it is the one
                // the Density and Cell size rows below already offer.
                if model.densityMode.needsSimulation, model.simulateStresses {
                    simDerivedNote("Derived from the simulated density. "
                                   + "To pin it, pin Density and Cell size.")
                        .accessibilityIdentifier("wizard-thickness-derived")
                } else {
                    // ★★ A THICKNESS IN MILLIMETRES (maintainer, 2026-08-19: "Off
                    // makes a sliding number value visible; controlling the
                    // thickness of the cell on screen").
                    //
                    // ★ IT USED TO SCRUB A PERCENTAGE. The row was labelled
                    // "thickness" and moved `relativeDensity` in %, so the number
                    // on screen was not the quantity the label named and could not
                    // be compared with a nozzle or a wall. It now moves the strut
                    // DIAMETER, and the density the renderer needs is derived from
                    // it (`LatticeSettings.manualThicknessDensity`) — one
                    // mechanism, entered the way the user thinks about it.
                    //
                    // ★ AND THE RANGE IS THE PRINTABLE ONE, not 5…90 of something.
                    // The bottom is one extruded bead; the top is the thickness at
                    // core's certifiable density ceiling. A slider that could ask
                    // for a strut the machine cannot lay is the decorative-control
                    // defect wearing a different hat.
                    let range = thicknessRangeMM
                    scrubRow("thickness", value: currentThicknessMM, unit: "mm",
                             step: 0.02, range: range) {
                        model.manualStrutThicknessMM = $0
                        model.touched(.thickness)
                        rebuild()
                    }
                    Text("One extrusion is \(mmText(range.lowerBound)) — the thinnest "
                         + "strut this printer can lay at a \(mmText(model.cellMM)) cell.")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                        .accessibilityIdentifier("wizard-thickness-floor-note")
                }
            case .cellSize:
                // ★ "cell size could be auto or swept or manually input"
                // (maintainer, 2026-08-17) — all three already exist in core
                // (`cell_mode` = auto / swept / absent-means-fixed). SWEPT is the
                // stress-graded one: core builds a dyadic ladder and picks the
                // level per block from the demand field. So it is offered ONLY
                // under the Sim permission, and labelled so.
                // ★★ AUTO IS THE GRADED ONE NOW, AND "FIXED" IS CALLED MANUAL
                // (maintainer, 2026-08-19: "Cell size = Auto should absolutely be
                // *any* number - as needed based on the stress map … and only
                // *manual* should force a single number through the entire
                // lattice").
                //
                // ★ AUTO NEEDS THE SIM, because it grades from the stress field —
                // so with the permission off it is not offered, exactly as the
                // sweep is not. Manual and Fit stand alone. See
                // `LatticeSettings.resolvedCellPlan` for what each one emits.
                segmentRow(model.simulateStresses
                           ? ["Auto · Sim", "Swept · Sim", "Manual", "Fit"]
                           : ["Manual", "Fit"],
                           selected: cellModeIndex) { i in
                    let modes: [LatticeCellSizeMode] = model.simulateStresses
                        ? [.auto, .swept, .fixed, .fit]
                        : [.fixed, .fit]
                    model.setCellSizeMode(modes[i])
                }
                if model.simulateStresses, model.cellSizeMode == .auto {
                    Text(autoCellNote)
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                        .accessibilityIdentifier("wizard-auto-cell-note")
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
                // ★ SIM IS OFFERED ONLY UNDER THE PERMISSION. With the switch
                // off there is no field, and a mode that grades by a field that
                // does not exist is not a mode — `setSimulateStresses` has
                // already moved this axis to Uniform, so the segment cannot show
                // a selection it no longer holds.
                segmentRow(model.simulateStresses
                           ? [LatticeDensityMode.sim.title,
                              LatticeDensityMode.uniform.title,
                              LatticeDensityMode.perRegion.title]
                           : [LatticeDensityMode.uniform.title,
                              LatticeDensityMode.perRegion.title],
                           selected: densityModeIndex) { i in
                    let modes: [LatticeDensityMode] = model.simulateStresses
                        ? [.sim, .uniform, .perRegion] : [.uniform, .perRegion]
                    model.setDensityMode(modes[i])
                }
                if model.densityMode.needsSimulation {
                    simDerivedNote("A finite-element solve grades every region "
                                   + "from its own stress.")
                        .accessibilityIdentifier("wizard-density-sim-note")
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
                // ★ FOUR NOW — "Covered" is the solid outer shell.
                segmentRow(["None", "Rim", "Skin", "Covered"],
                           selected: boundaryIndex) { i in
                    model.setBoundary([.none, .rim, .fullSkin, .covered][i])
                }
                if model.boundary == .covered {
                    Text("A solid outer wall over the lattice, at the printer's "
                         + "own wall thickness. The lattice is still there — "
                         + "just not on show.")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                        .accessibilityIdentifier("wizard-covered-fact")
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

    /// ★★★ ORGANIC, ITS OWN ROW BELOW THE LATTICE TYPES (his ruling, 2026-09-02: "add an
    /// Organic option BELOW the lattice selection"). Not a fourth chip inside the
    /// scrolling Type row — there it was clipped off the sheet's right edge and could
    /// not be discovered, and it is not a topology anyway.
    @ViewBuilder private var organicTypeRow: some View {
        HStack(spacing: DS.Space.s) {
            organicTypeChip
            // ★ CORE'S LAW, SHOWN HERE RATHER THAN AFTER THE SOLVE: organic is
            // aesthetic-only (run_job.cpp `refuse_organic_structural` — one CUBIC
            // tensor per topology, none measured for traced struts). Under a
            // Structural stage the chip is disabled and this caption says why; the
            // house rule is a control that never opens a page that then apologises.
            Text(organicRefusedByStage
                 ? "Organic is aesthetic-only: the certificate has no tensor for traced struts (core). Switch the stage to Aesthetic."
                 : model.cellTransition == .organicGrade
                 ? "Struts grown or traced along the stress field — not a repeating cell."
                 : "Or an organic lattice: struts traced along the stress field.")
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textQuaternary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DS.Space.xs)
    }

    /// ★★★ ORGANIC, AT THE TYPE LEVEL (his ruling, 2026-09-02): a fourth choice below
    /// the lattice types. It is NOT a topology — core selects organic by
    /// `grading.algorithm` and refuses any `grading.topology` but "octet" — so this
    /// chip sets the algorithm and leaves the topology alone. One mechanism:
    /// `cellTransition == .organicGrade` IS `algorithm == "organic"`.
    /// Under Organic on the lattice stage, its own pane owns these three rows.
    private func organicPaneOwns(_ s: LatticeWizardSetting) -> Bool {
        guard model.stage == .lattice, model.cellTransition == .organicGrade else { return false }
        return s == .cellSize || s == .density || s == .finish
    }

    /// ★ D1 (maintainer, 2026-09-03): organic is NOT aesthetic-only — the chip is
    /// selectable under Structural with the same controls. Core still refuses the
    /// job at runtime until its structural certification for organic is wired, so
    /// the EMISSION is gated (the run button carries core's message), never the
    /// chip. The mechanism stays as one `false` for a future core rule.
    private var organicRefusedByStage: Bool { false }
    /// True while an organic + Structural job would be refused by core at runtime.
    private var organicStructuralGateClosed: Bool {
        (project.lattice.stageMode ?? .structural) == .structural
            && !TopOptKit.organicStructuralCertificationWired
    }

    private var organicTypeChip: some View {
        let on = model.cellTransition == .organicGrade
        let refused = organicRefusedByStage
        let ink: Color = (refused ? DS.Color.textQuaternary
                          : on ? DS.Color.textPrimary : DS.Color.textTertiary).color
        let fill: Color = on ? DS.Color.fillSelected.color : Color.clear
        return Button {
            model.cellTransition = .organicGrade
            // ★ FINISH IS ALWAYS "GRADE TO FIT SHAPE" for organic (his item 3): the
            // cells are pulled to the face-prism's OUTLINE. Forced here, not offered.
            model.organicShapeFit = true
            // ★★ THE OCTET WINDOW MUST NOT RIDE INTO ORGANIC UNTESTED (reviewer,
            // 2026-09-03): for organic the cell window IS the separation field, and
            // the M2's cliff has not been measured. A swept/fit mode inherited from
            // the lattice types is reset to Auto HERE, out loud (the pane says so),
            // never carried silently — measured 2026-09-02: the pane lit "Auto ·
            // grade" while the job carried the octet's swept 5.5–6 mm.
            if model.cellSizeMode != .auto && model.cellSizeMode != .fit {
                model.setCellSizeMode(.auto); organicWindowReset = true
            }
            rebuild()
        } label: {
            Text("Organic")
                .font(.system(size: 11, weight: .bold)).lineLimit(1).fixedSize()
                .foregroundStyle(ink)
                .padding(.vertical, 6).padding(.horizontal, DS.Space.sm)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(refused)
        .accessibilityIdentifier("wizard-type-organic")
    }

    private func typeChip(_ t: LatticeType) -> some View {
        // ★ ONE selection in the Type group. Under Organic the topology is still
        // octet by core's law, but that is not the user's pick — showing "Octet
        // truss" lit beside a lit "Organic" read as two selections (on-device,
        // 2026-09-02 21:11). Tapping any type chip still leaves organic.
        let on: Bool = (model.topologyID == t.id) && model.cellTransition != .organicGrade
        let ink: Color = (on ? DS.Color.textPrimary : DS.Color.textTertiary).color
        let fill: Color = on ? DS.Color.fillSelected.color : Color.clear
        return Button {
            model.setTopology(t.id)
            // ★ TAPPING A LATTICE TYPE LEAVES ORGANIC — back to the grade style the
            // user last had, so the octet pane comes back exactly as it was.
            if model.cellTransition == .organicGrade {
                model.cellTransition = model.gradeStepStyle == .dyadic ? .defaultGrade : .stepped
            }
        } label: {
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

    /// What Auto will actually do, in the objective the project is set to — split
    /// out because inlining it in the view body defeated the type-checker.
    private var autoCellNote: String {
        let head = "The solve picks the cell everywhere — coarse where there is no "
            + "stress, fine where there is. "
        let tail = project.minimizePlastic
            ? "Minimising plastic, so it coarsens as far as the certification allows."
            : "Strength first, so it holds the finest printable cell and grades the "
                + "density instead."
        return head + tail
    }

    private var cellModeIndex: Int {
        // ★ The order the row is BUILT in — two shapes, because Auto and Swept
        // both need the sim permission.
        let modes: [LatticeCellSizeMode] = model.simulateStresses
            ? [.auto, .swept, .fixed, .fit]
            : [.fixed, .fit]
        return modes.firstIndex(of: model.cellSizeMode) ?? 0
    }
    private var densityModeIndex: Int {
        // ★ THE INDEX FOLLOWS THE LIST THE SEGMENT ACTUALLY SHOWS. With the Sim
        // permission off, Sim is not in it and everything shifts down one — an
        // index into a list that is not on screen is how a segment lights the
        // wrong cell.
        guard model.simulateStresses else {
            return model.densityMode == .perRegion ? 1 : 0
        }
        switch model.densityMode {
        case .sim: return 0
        case .uniform: return 1
        case .perRegion: return 2
        }
    }
    /// The printable thickness range for the CURRENT topology and cell — see
    /// `LatticeSettings.manualThicknessRangeMM`.
    private var thicknessRangeMM: ClosedRange<Double> {
        var probe = LatticeSettings(enabled: true)
        probe.topologyID = model.topologyID
        probe.cellMM = model.cellMM
        // Core's own band for this topology — the same accessor the page and the
        // run spec use, so the slider's ceiling is core's ceiling.
        return probe.manualThicknessRangeMM(
            limits: TopOptKit.latticeLimits(topology: model.topologyID),
            lineWidthMM: project.printParams.strutLineWidthMM)
    }

    /// The thickness the slider should show: the hand-set one, or — the first time
    /// the sim is switched off — the thickness the CURRENT density already
    /// produces, so the control opens on the lattice that is on screen rather than
    /// jumping to an arbitrary default.
    private var currentThicknessMM: Double {
        if let mm = model.manualStrutThicknessMM { return mm }
        let topo = LatticeType.named(model.topologyID)
        let derived = 2 * topo.strutRadiusMM(relativeDensity: model.relativeDensity,
                                             cellMM: model.cellMM)
        let r = thicknessRangeMM
        return Swift.min(r.upperBound, Swift.max(r.lowerBound, derived))
    }

    private func mmText(_ v: Double) -> String { String(format: "%.2f mm", v) }

    private var boundaryIndex: Int {
        switch model.boundary {
        case .none: return 0
        case .rim: return 1
        case .fullSkin: return 2
        case .covered: return 3
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
            // ★ THE MESH ON SCREEN, not the uniform-block PREDICTION — the
            // prediction ignores the transition, so it read 118,920 whatever the
            // stepped sample drew and cost an hour of "nothing changed" (2026-08-25).
            Text("\((mesh?.indices.count ?? 0) / 3) tris")
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
                    // ★ Organic: the truth about the sample, with its measurement
                    // (maintainer, 2026-09-03: "The PR 353 test cube, as printed. Your
                    // part will differ." — and the count/length the bake indexed
                    // against the receipt, the same check a run gets).
                    Text(organicSampleShown
                         ? (organicSampleMeasurement ?? OrganicSampleCube.label)
                         : LatticeWizardSample.provenanceNote)
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
        mesh = model.stageMesh(progress: tileProgress,
                               derivedCellMM: derivedSampleCellMM,
                               // The floor decides how many derived cells fill the
                               // stepped sample's coarse half: single-cell ⇒ ONE.
                               steppedCoarsePerHalf: model.cellTransition == .stepped
                                   ? (model.singleCellMembers ? 1 : 2) : nil,
                               dyadicSteps: model.cellTransition == .defaultGrade)
        // ★★★ ORGANIC: the printed cube, through the run's own preview path. Built
        // ONCE per sheet (the spans do not change with any control here — they are
        // what core built for that job; the controls describe what the user's run
        // will ask for), and MEASURED: what the bake indexed against the receipt.
        // The bake itself is OFF the main thread and cached (`OrganicSampleCube.baked`,
        // kicked by `.task` on the stage view); here we only show what has landed.
        if organicSampleShown {
            if let scene = organicScene { mesh = scene.mesh }
        } else if organicScene != nil {
            organicScene = nil; organicSampleMeasurement = nil
        }
        lastLatencyMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    /// ★ EVERYTHING THE SAMPLE'S TRACE DEPENDS ON, from the sheet's current picks. The
    /// `.task(id:)` below re-traces exactly when this changes (maintainer, 2026-09-03:
    /// the sample must follow every permutation of the user's settings).
    private var organicSamplePicks: OrganicSampleCube.Picks? {
        guard organicSampleShown else { return nil }
        return OrganicSampleCube.Picks(settings: model.applied(to: project.lattice),
                                       layerHeightMM: project.printParams.layerHeightMM)
    }

    /// Re-traces the PR 353 cube's 20 mm corner with the current picks, off the main
    /// thread (the cube's FEA is solved once per launch and cached), then publishes the
    /// scene. Cancels cleanly if the picks change again meanwhile.
    private func loadOrganicSample(_ picks: OrganicSampleCube.Picks?) async {
        guard let picks else {
            if organicScene != nil { organicScene = nil; organicSampleMeasurement = nil }
            return
        }
        organicSampleMeasurement = organicScene == nil
            ? "Solving the PR 353 cube with the app's own FEA, then tracing it with your settings…"
            : "Re-tracing the PR 353 cube with your settings…"
        let baked = await OrganicSampleCube.baked(picks: picks, latticeID: model.topologyID)
        guard !Task.isCancelled, organicSamplePicks == picks else { return }
        if let b = baked {
            let first = organicScene == nil
            organicScene = b.scene; organicSceneToken += 1
            organicSampleMeasurement = b.measurement
            mesh = b.mesh
            if first { frameSample() }
        } else {
            organicSampleMeasurement = "The cube could not be traced with these settings (core refused, or the "
                + "sample's model/materials are not bundled in this build)."
        }
    }

    /// ★★★ THE CELL THE SAMPLE SHOWS, DERIVED — so the single-cell/member toggle
    /// moves the sample (his backlog, 2026-08-24). The chain is the BAKE's own:
    /// core's `latticeRegionDerivation` at the mode's floor, then the
    /// whole-number-of-cells fit against the declared depth — no law re-derived
    /// here. The member is the smallest declared include depth, which is exactly
    /// the pre-measurement fallback the bake itself uses before a scene exists.
    /// nil (no auto mode, no bead, nothing declared) ⇒ the stored cell, as before.
    private var derivedSampleCellMM: Double? {
        guard model.cellSizeMode == .auto else { return nil }
        let bead = project.printParams.strutLineWidthMM
        guard bead > 0 else { return nil }
        let depths = project.lattice.selectableRoles.compactMap {
            key, role -> Double? in
            guard role == .include, let d = project.lattice.selectableDepthMM[key],
                  d > 0 else { return nil }
            return d
        }
        guard let member = depths.min() else { return nil }
        // The MODEL's live toggles, not the saved settings — the sample must answer
        // the switch as it moves, before Save & Exit writes anything.
        let floor = (project.lattice.stageMode ?? .structural).cellsPerMemberFloor(
            topology: model.topologyID, utilisation: .nan,
            boundaryFinishWritten: model.singleCellMembers
                && model.boundary != .none)
        let d = TopOptKit.latticeRegionDerivation(
            topology: model.topologyID, memberWidthMM: member,
            minExtrudableWidthMM: bead, cellsPerMemberFloor: floor)
        guard d.valid, d.cellMM > 0 else { return nil }
        let n = Swift.max(1, (member / d.cellMM).rounded())
        return member / n
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

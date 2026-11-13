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
// ★ B8 (his answer 2026-10-24): THE FULL-SCREEN PAGE IS DELETED. Since B4 every presentation was the lattice stage's
// CELLS page (`.cellsPage`), so the full-screen settings page — the sample cube in the centre, its cinematics (morph,
// tile, stress wipe and dive, boundary swap), the disclaimer, the top-left Save & Exit and the Refresh cube button — was
// unreachable. What is left is the one panel: every selection, grouped under the two views (One cell / In the part,
// `viewSwitcher`), with the Cells page's header, tabs and added rows. A setting still has ONE way in and ONE way to the
// job: Save (the header) or the capsule's Regions (`closeToken`) runs `saveAndClose`.

import SwiftUI
import TopOptDesign
import TopOptKit

public struct LatticeSetupWizard: View {

    @ObservedObject var project: ProjectModel
    let onExit: () -> Void

    @State private var model: LatticeWizardModel
    /// ★ §5 — which numeric field has the keypad open. One at a time, keyed by the
    /// field's id, so every number on this page types as well as drags.
    @State private var numberPadField: String?
    /// ★ lattice types U1: a greyed type chip, tapped, says why it can't be picked (core's facts)
    @State private var typeReason: String?
    /// ★ B7 slice 2: a type picked on this visit (two or more offered: a new lattice starts with none picked); nil = not
    /// yet, which counts as picked for a lattice already saved.
    @State private var typePicked: Bool? = nil

    /// ★ "Check sizes" (final contract 2026-09-05): submits the re-lattice job with the
    /// candidate list and returns core's `organic_probe.json` answer. nil ⇒ no worker
    /// or nothing to re-lattice; the button says so.
    public typealias ProbeDriver = @MainActor (_ cellsMM: [Double], _ gradesMM: [[Double]],
                                               _ recommend: RelatticeRun.Recommend?) async throws -> OrganicForecast
    private var probeDriver: ProbeDriver? = nil
    private enum ProbeState: Equatable { case idle, running, failed(String) }
    @State private var organicProbeState: ProbeState = .idle

    /// The driver is attached AFTER construction so the call site keeps the literal
    /// `LatticeSetupWizard(project: project)` the solve-trigger test pins.
    public func organicProbeDriver(_ driver: ProbeDriver?) -> LatticeSetupWizard {
        var copy = self
        copy.probeDriver = driver
        return copy
    }

    /// ★★ RULING 4 (item 6, 2026-09-30): wherever "nothing set to lattice" shows here, one tap
    /// takes him to where walls are marked. The wizard leaves by its ONE exit (Save & Exit —
    /// "your settings are saved whether or not you refresh") and then this runs. nil ⇒ no tap.
    private var markWalls: (() -> Void)? = nil
    public func wallMarking(_ go: (() -> Void)?) -> LatticeSetupWizard {
        var copy = self
        copy.markWalls = go
        return copy
    }
    private func exitToWallMarking() {
        saveAndClose()
        markWalls?()
    }

    public init(project: ProjectModel, onExit: @escaping () -> Void) {
        self.project = project
        self.onExit = onExit
        _model = State(initialValue: LatticeWizardModel(settings: project.lattice))
    }

    // MARK: ★ B4 — THE CELLS PAGE (the redesign's Lattice stage, 2026-10-24)
    //
    // The settings this page asks (One cell / In the part: Type, Thickness, Cell size, Density, Finish, the grade rows,
    // Organic) ARE the Cells page's rows: re-homed, not copied. In the `.cellsPage` presentation the page draws only its
    // panel — no sample cube, no cinematics, no full-screen background — over the live part, under the stage's capsule
    // (● <Type> ⌄ | Regions | Cells | ✂), with a tab per region on top and the rows the design adds at the end
    // (Grade from → to, Along, Strength / Ties / Overhangs: LatticeCellsRow). The commit is today's: Save (here) or the
    // capsule's Regions (`closeToken`) runs `saveAndClose`, so a setting has ONE way in and ONE way to the job.

    /// RED CONTROL for LatticePageParityHostedTests (B7): hides the Simulate stresses switch, so the parity must name it.
    nonisolated(unsafe) static var controlHideSimulateStresses = false

    struct CellsPageContext: Equatable {
        var regions: [String]
        var closeToken: Int
    }
    private var cellsPage: CellsPageContext? = nil
    @State private var cellsTab = 0

    /// Present this page as the lattice stage's Cells page.
    public func cellsPage(regions: [String], closeToken: Int) -> LatticeSetupWizard {
        var v = self
        v.cellsPage = CellsPageContext(regions: regions, closeToken: closeToken)
        return v
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // ★ ONE MODAL (maintainer, 2026-08-14): *"Combine the two modals
                // together. Place the one on the right at the very bottom of the
                // one on the left."* The floating wizard card is gone; its view
                // switch is the last row inside this panel.
                if let c = cellsPage {
                    latticePage(c, size: geo.size)
                } else {
                    selectionsModal
                        .modifier(WizardModalPlacement(canvasHeight: geo.size.height))
                }
            }
        }
        .onAppear { rebuild() }
        // ★ B4: the capsule's Regions leaves the Cells page through today's Save
        .onChange(of: cellsPage?.closeToken) { _ in saveAndClose() }
        .background(GeometryReader { g in
            Color.clear.onAppear { canvasHeight = g.size.height }
                .onChange(of: g.size.height) { canvasHeight = $0 }
        })
        // ★ item 3.2 — presented from the page's root, where an alert always can be
        .alert("Grading needs a stress simulation", isPresented: $showGradeNeedsSimAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on Simulate Stresses to grade the lattice by stress. Without it, "
                 + "the lattice fits the shape only.")
        }
        // ★ THE ORGANIC NOTICES (his items 2 and 6, 2026-09-05), presented from the
        // page's root like the one above: a Structural size that is not expected to
        // certify, and the shape-fit switch that cannot turn off without a simulation.
        .alert(organicNotice?.title ?? "", isPresented: Binding(
            get: { organicNotice != nil }, set: { if !$0 { organicNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(organicNotice?.message ?? "")
        }
        .onChange(of: model.stage) { _ in rebuild() }
        .onAppear { if openedLattice == nil { openedLattice = project.lattice } }
    }

    /// Which (i) popover is open, by id — one at a time.
    @State private var infoShown: String?
    /// the settings as they were when the page opened — "Exit" until they differ
    @State private var openedLattice: LatticeSettings? = nil
    @State private var panelRowsHeight: CGFloat = 0
    @State private var canvasHeight: CGFloat = 0
    /// ★ The small pop-up for the single-cell ⇄ finish rule (2026-09-18): which one is
    /// showing — "skin-required" when the switch turns on, "finish-locked" when a locked
    /// finish is tapped.
    @State private var finishRuleNotice: String?
    /// The grown path's print fine-tuning, folded away until asked for (item 2.2).
    @State private var showPrintTuning = false
    /// "Grading needs a stress simulation" — shown when shape-fit-only is turned off
    /// with the simulation off (item 3.2).
    @State private var showGradeNeedsSimAlert = false
    private struct OrganicNotice: Equatable { let title: String; let message: String }
    @State private var organicNotice: OrganicNotice?
    /// The last verdict on a typed organic size or grade (checked after entry),
    /// with the label it was computed for — shown only while that is the value.
    @State private var organicSizeVerdict: OrganicSizeCheck.Verdict?
    @State private var organicSizeVerdictLabel: String = ""
    private var organicCurrentSizeLabel: String {
        model.simulateStresses
            ? String(format: "%g–%g mm", organicGradeLo, organicGradeHi)
            : String(format: "%g mm", model.organicPickedSeparationMM)
    }
    private var organicVerdictCurrent: OrganicSizeCheck.Verdict? {
        organicSizeVerdictLabel == organicCurrentSizeLabel ? organicSizeVerdict : nil
    }
    /// ★ "Show without repairs" (maintainer, 2026-09-05): the sample shows the traced
    /// curves instead of the file's repaired spans. A preview option, not a setting —
    /// the file always has the repairs, and the banner says which is shown.
    private var organicSampleShown: Bool { model.cellTransition == .organicGrade }

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
            if let c = cellsPage { cellsHeader(c) }
            // ★ ABOVE THE TYPE, ON EVERY VIEW (maintainer, 2026-08-17: "a dark
            // glass on/off check with a 'Simulate Stresses' at the top of the
            // 'Lattice Settings' modal (above the 'type')"). It is not one
            // stage's setting — it decides what the OTHER settings may offer —
            // so it sits outside the stage list rather than inside it.
            if !Self.controlHideSimulateStresses { simulateStressesSwitch }
            // ★ ORGANIC IS A DIFFERENT "IN THE PART" (his ruling, 2026-09-02, and the
            // on-device screenshot of 21:12 that showed both): the stage's Cell size /
            // Density / Finish rows are the OCTET's — a traced lattice has no cell to
            // size, its density is the strut width, and its finish is fixed. Under
            // Organic `organicRow` carries all three; showing the octet rows above it
            // was the "same section" he asked to replace.
            ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
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
                // ★ NOT IN STRUCTURAL (his 2026-09-20: "this is 'structural' and that
                // should NOT be an option that is visible"). The switch lowers the
                // AESTHETIC cells-per-member floor to one; the structural floor is
                // core's own and never reads it, so the control would be decorative.
                if (project.lattice.stageMode ?? .structural) == .aesthetic {
                    singleCellSwitch
                }
                smallCellsSwitch   // ★ his ask 11-13: per part, every mode
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
            // ★ B4: the rows the Cells page adds (Grade, Along, and the type's own rows)
            if cellsPage != nil, model.stage == .lattice { cellsAddedRows }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: WizardPanelRowsHeightKey.self, value: g.size.height)
            })
            }
            .frame(height: panelRowsFrameHeight)
            .onPreferenceChange(WizardPanelRowsHeightKey.self) { h in panelRowsHeight = h }
            // ★ THE CARD, MOVED HERE: "place the one on the right at the very
            // bottom of the one on the left."
            viewSwitcher
        }
        .padding(DS.Space.ml)
        .frame(width: PageChrome.widePanelWidth, alignment: .leading)   // ★ B2 (U14): the wide panel
        .background(CornerPairStyle.publish("latticeSettingsPanel"))
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
            .toggleStyle(SwitchToggleStyle(tint: DS.Color.okGreen.color))   // ★ B7: the panel's switch green (DSSwitch)
            .latticeID("wizard-grade-toggle")
            captionLine(model.gradingMode == LatticeGradingMode.none
                        ? "One cell, one density, everywhere."
                        : "The lattice varies across the part.",
                        info: "grade-toggle")
        }
    }

    /// ★ 2 — WHAT VARIES: the stress, the shape, or both.
    @ViewBuilder private var gradeTypeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Grade")
                .font(.system(size: 10.5, weight: .bold)).tracking(0.8).textCase(.uppercase)   // ★ B7: the panel's overline (DSPanelSection)
                .foregroundStyle(DS.Color.textTertiary.color)
            HStack(spacing: 4) {
                ForEach([LatticeGradingMode.full, .fitShape, .stressOnly],
                        id: \.rawValue) { m in
                    Button {
                        model.gradingMode = m
                        rebuild()
                    } label: {
                        // ★ B7: the Squish look's segment (FlexChips): the pick in the selected fill on a dark track
                        Text(m == .full ? "Stress + shape"
                             : m == .fitShape ? "Shape" : "Stress")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .padding(.vertical, 7).padding(.horizontal, DS.Space.s)
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(model.gradingMode == m ? DS.Color.fillSelected.color : Color.clear))
                            .foregroundStyle((model.gradingMode == m ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                    }
                    .buttonStyle(.plain)
                    .latticeID("wizard-grade-type-\(m.rawValue)")
                }
            }
            .modifier(LatticeSegmentTrack())
            captionLine(model.gradingMode == .full ? "Density by stress, cells fit the outline."
                        : model.gradingMode == .fitShape ? "Cells fit the outline, one density."
                        : "Density by stress, one cell size.",
                        info: "grade-type",
                        "Stress + shape: the density follows the solve and the cells fit the "
                        + "outline. Shape: the cells fit the outline; one density everywhere. "
                        + "Stress: the density follows the solve; one cell size everywhere.")
        }
    }

    /// ★ THE VIEW SWITCH — the whole of what the floating card is now. Two views,
    /// switchable in EITHER direction ("make it so you can go back and forth"),
    /// and no third tab for Finish.
    private var viewSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(LatticeWizardStage.allCases, id: \.rawValue) { s in
                let on: Bool = (model.stage == s)
                Button { model.jump(to: s); rebuild() } label: {
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
                .latticeID("wizard-stage-\(s.rawValue)")
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
                    captionLine(model.simulateStresses ? "An FEA decides the Sim settings."
                                                       : "Every setting is yours.",
                                info: "sim")
                }
            Spacer(minLength: DS.Space.s)
            latticeSwitch(isOn: model.simulateStresses) {
                model.setSimulateStresses(!model.simulateStresses)
                rebuild()
            }
            .accessibilityLabel("Simulate Stresses")
            .latticeID("wizard-simulate-stresses")
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
    /// ★ TWO CHIPS, NOT THREE (his 2026-09-17: "please remove 'organic gradient'
    /// from the gradient style area of the menu. It should only be accessible from
    /// the 'cell' section"). Organic is the `organicTypeRow` switch under the lattice
    /// types; while it is on this row is not shown at all (`organicRow` replaces it).
    private static let cellTransitions: [LatticeCellTransition] =
        [.stepped, .defaultGrade]

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
    /// ★ ruling (c): whether the job carries an include wall (ruling 4's one definition), from
    /// the SAME emission as the cache above (one per change, never one per read); nil until the
    /// first rebuild
    @State private var hasIncludeWallCache: Bool? = nil
    /// ★ THE ROWS' HEIGHT IS THEIR CONTENT'S — never more than the sim-on height once
    /// the sim switch is off, never more than the page leaves (his 02:04: "the lattice
    /// settings should adjust the size as long as it's below the set amount … it is
    /// STUCK at the max-length"). A greedy ScrollView took the whole band; this pins it.
    private var panelRowsFrameHeight: CGFloat? {
        guard panelRowsHeight > 0 else { return nil }
        var cap = canvasHeight > 0 ? max(160, canvasHeight - 330) : .greatestFiniteMagnitude
        return min(panelRowsHeight, cap)
    }

    @ViewBuilder private var gradeStyleRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Grade style")
                .font(.system(size: 10.5, weight: .bold)).tracking(0.8).textCase(.uppercase)   // ★ B7: the panel's overline (DSPanelSection)
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
                    .latticeID("wizard-cell-transition-\(t.rawValue)")
                }
            }
            if let blocked = LatticeStructuralSteppedGate.refusal(
                latticeEnabled: true, algorithm: model.cellTransition.coreAlgorithm,
                stageMode: project.lattice.stageMode) {
                // ★★ STRUCTURAL STEPPED IS BLOCKED (reviewer, 2026-10-08): the gate's line, and the
                // fix is the line itself — one tap puts Default Grade back
                HStack(spacing: DS.Space.xs) {
                    Button {
                        model.cellTransition = .defaultGrade
                        rebuild()
                    } label: {
                        Self.tapNote(blocked + " · " + LatticeStructuralSteppedGate.fixLabel)
                    }
                    .buttonStyle(.plain)
                    .latticeID("wizard-stepped-structural-blocked")
                    infoButton("grade-style-blocked", LatticeStructuralSteppedGate.detail)
                }
            } else {
                captionLine(model.cellTransition.unavailableReason
                            ?? (model.cellTransition == .stepped ? "Any printable step, packed to the outline."
                                                                  : "Cells halve on core's ladder."),
                            info: "grade-style", model.cellTransition.body)
            }

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

    // ══════════════════════════════════════════════════════════════════════════
    // ★★★ ORGANIC (2026-09-02). Shown only under the Organic grade style; every
    // control here maps to ONE `organic_*` job key, and `gradingDictionary()` is
    // the only place that decides whether a key is written — this row never gates
    // the document, it only tells the user what will happen.
    //
    // ★ NOT A TOPOLOGY. Organic is chosen by `grading.algorithm`; the topology stays
    // "octet" (core refuses any other) and that is correct, not a leftover.
    // ══════════════════════════════════════════════════════════════════════════
    /// True once this sheet reset an inherited swept/fit window to Auto for organic,
    /// so the pane can SAY it happened instead of the job quietly changing.
    @State private var organicWindowReset = false
    private var organicDensityIndex: Int {
        if model.organicStrutWidthMM > 0 { return model.simulateStresses ? 2 : 1 }
        return (model.simulateStresses && model.densityMode == .sim) ? 1 : 0
    }

    // MARK: the (i) texts — the explanations that used to sit under every row (item 2)

    static let infoOrganic = "Struts grown or traced along the part's stress field instead of a repeating "
        + "cell. With Simulate Stresses on, the spacing and strut width are graded by that "
        + "stress (the waves); with it off the struts still follow the field, but nothing is "
        + "graded by it — one spacing, fitted to the shape."
    static let infoTracedGrown = "Traced: struts follow the field wherever it leads, so a strut can overhang "
        + "and printing may need supports there. Grown: struts are laid down in printed-layer "
        + "order and every step refuses an unsupported underside (a fixed 30° overhang), so "
        + "the lattice prints without supports; it comes out denser at the base and sparser "
        + "near the top. The sample shows both."
    static let infoCellSize = "Auto: the largest grade the simulation allows — a window from the smallest "
        + "fitting separation to the largest, driven by the stress within it. Fit: one "
        + "separation, no grade beyond fitting the shape — core picks the middle of what "
        + "fits. Manual: one size (or one grade) you pick from what certification approved. "
        + "Core decides what fits; the run's receipt shows what it chose. Note: core's "
        + "organic Auto/Fit is still being wired — today an organic Fit runs core's existing "
        + "fit path, and the receipt does not yet report the fitting set."
    static let infoDensity = "Auto: derived from the print parameters, the density band and the cell. "
        + "Sim: the stress simulation sets the strut width. Thicker: a strut width you "
        + "state; the run holds it. The sample shows it live on the same struts, up to "
        + "about 2 mm wide (core's tracer may re-space slightly at the run for a stated "
        + "width; the run's receipt says what it did)."
    static let infoFitToShape = "The lattice follows the outline of the face-prism, and there is no finish on "
        + "the faces — no shell, no skin, only lattice. \"Shape fit only\" drops the stress "
        + "grading of the cell: one separation everywhere (Fit), pulled in at the walls to "
        + "fit the shape. Off, the cell is graded by core's own stress solve (Auto)."
    static let infoSpacingScale = "Scales the spacing the solve derives. Coarser spacing can fragment the "
        + "lattice; the run's receipt reports survival and pieces. Grown organic holds a "
        + "fixed 30° overhang, so there is no overhang limit to tune there."
    static let infoRepairs = "Core's export repairs the traced lattice for printing: it merges nodes, cuts "
        + "the base and ties free ends. A span that crosses open air is printed as drawn, with "
        + "nothing underneath, and the run's receipt counts them. Those repairs are in the file. "
        + "Turn this off to see the traced curves alone — a way to judge the topology, not what will print."
    // ★ HIS WORDS, 2026-09-29 (ruling B): say what is applied — core's own rule, the
    // wall's p99 at or under max(2 % of the peak, 0.005 MPa). The old "median under 5 %"
    // matched neither core nor the app.
    static let infoSynthetic = "A wall the load barely reaches can be given a made-up load so it still gets a "
        + "pattern. It's only applied where the wall's real stress is tiny — at or under 2 % of the "
        + "part's peak, or 0.005 MPa. A wall that carries load is left alone. The made-up load is a "
        + "few focal points, alternating pull and push, so the struts sweep between them. Each "
        + "wall chooses its own number of foci (1–5) in its row under Selections; a wall that "
        + "carries load takes none. "
        // ★ HIS INSTRUCTION, 2026-09-08: say what the stress map does with this on.
        + "The stress map reads each declared face on its OWN range, apart from the rest "
        + "of the body — so a wall carrying a thousandth of the part's peak still shows "
        + "where its foci are. Colours are comparable within a face, never between two."
    static let infoDepthStagger = "A TEST, not a setting. The preview calls core's own "
        + "tracer, so its curves are the ones the run builds — and the tracer lays every "
        + "depth layer on the same tracks, which is why a window in the front layer is a "
        + "window all the way through. With this on the preview OFFSETS each layer after "
        + "tracing, so the weave interleaves. It is here to judge a proposed change to "
        + "the tracer before it is made. The run builds the un-staggered weave, and the "
        + "banner says so while it is on."
    static let infoSizeCheck = " A typed size is checked once you finish entering it, against the "
        + "printable cell at this bead, whether one cell fits the thinnest wall, and the probe's "
        + "verdict when it has that size. Your pick is kept and shown; it reaches the run once "
        + "core accepts it."
    static let infoNoSimulation = " Without a simulation the run still traces core's own solved "
        + "field; the switch only takes Sim off the Density row. Auto grades the cell by the "
        + "simulated stress, so it is offered only with a simulation; Fit lets core choose one "
        + "size that fits the shape; Manual is your grade (with a simulation) or your one size."
    static let infoTransferTies = "On the grown lattice, ties run across the pillars along the second "
        + "stress family, welded at each pillar. Off leaves the pillars alone."
    static let infoSolidRim = "A solid ring inside each face outline — the width you type, or the "
        + "printability floor (about one and a half beads, never less than a solve voxel) — drawn as a "
        + "beam around the lattice; the struts run into it and weld there. Off removes the ring."
    static let infoLook = "How many cells the eye should read across the shortest face. The size "
        + "check uses it to pick the look under Aesthetic; larger means finer."
    static let infoManualSizes = "Sizes certification approved: at each, the lattice ties to the part "
        + "(at least 95 % of its length rooted). Under an Aesthetic stage every size is offered; one marked * was "
        + "not approved: certification predicts it will not tie to the part (more than 5 % of "
        + "its length unrooted). A lattice is many rooted pieces by design; one piece is not the bar."
    static let infoManualGrades = "Grades certification approved: at each window the lattice ties to the "
        + "part (at least 95 % of its length rooted). Core does not report them yet; the list fills in the "
        + "moment a run's receipt carries them."

    /// A section title with its (i).
    private func sectionTitle(_ title: String, info id: String, _ text: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(title).font(.system(size: 10.5, weight: .bold)).tracking(0.8).textCase(.uppercase)   // ★ B7: the panel's overline (DSPanelSection)
                .foregroundStyle(DS.Color.textTertiary.color)
            infoButton(id, text)
        }
        .padding(.top, DS.Space.xs)
    }

    /// ★★ ONE LINE, AND THE REST BEHIND THE (i) (his 2026-09-18: "get rid of most
    /// of the text in the settings. Have a single line of text with an (i) in it for
    /// more details if absolutely necessary"). `brief` is the line — never wrapped —
    /// and `detail`, when given, is the popover the (i) opens. No detail ⇒ no (i).
    /// `probe`: an id the brief's frame is published under while a test records (11-10: the band's lines are measured).
    private func captionLine(_ brief: String, info id: String, _ detail: String? = nil,
                             tint: Color? = nil, probe: String? = nil) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(brief)
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(tint ?? DS.Color.textTertiary.color)
                .latticeID(ifGiven: probe)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let detail { infoButton(id, detail) }
        }
    }

    /// ★ His iPad note 11-10 (img04/05): each slider's caption sits right under it, Band's under Band and Strength's under
    /// Strength, as ONE SHORT LINE drawn at full size, with the rest behind its (i). Both used to sit under Strength, Band's
    /// last, so his (i) on Band opened two rows below its slider, and Strength's line was shrunk to fit.
    struct BandCaption { let brief: String; let info: String; let detail: String }
    static let strengthBrief = "0 is today's grade; + more, − less."
    static let strengthDetail = "+ thickens the struts and shrinks the cells further; − does less. "
        + "A multiplier on how much the grade does at every point of the band: at +1 "
        + "the struts thicken and the cells shrink twice as far, at −1 half as far. "
        + "The band's length is set above and is not changed by this."
    static let shapeBand = BandCaption(
        brief: "How far in the cells grade down.", info: "band",
        detail: "How far in from the face's outline the cells grade down toward the "
            + "solid outline, in millimetres. A cell stands where its centre is far "
            + "enough in for its size; the smallest cells always reach the outline. "
            + "From 25 mm the solid outline also thickens inward.")
    static let organicBand = BandCaption(
        brief: "How far in the cells shrink.", info: "organic-band",
        detail: "Within this many millimetres of a face outline the strut spacing runs "
            + "down to the printable floor at the outline, and the struts thicken with "
            + "it. 0 turns the grade off. The tint on the lattice shows the same band.")

    /// ★ THE BAND AND ITS STRENGTH AS SLIDERS (his 2026-09-18: "add the grade band
    /// slider in the settings … the default is really not visible … a multiplier for the
    /// gradient too … a slider with 0 at the middle"). One view for both panes.
    @ViewBuilder private func gradeBandSliders(idPrefix: String, band: BandCaption) -> some View {
        HStack(spacing: DS.Space.s) {
            Text("Band").dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textTertiary.color)
                .frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { model.shapeFitBandMM },
                                  set: { model.shapeFitBandMM = ($0).rounded(); rebuild() }),
                   in: 0...60, step: 1)
                .tint(DS.Color.accent.color)
                .latticeID("\(idPrefix)-band-slider")
            Text(String(format: "%.0f mm", model.shapeFitBandMM))
                .dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 52, alignment: .trailing)
        }
        captionLine(band.brief, info: band.info, band.detail, tint: DS.Color.textQuaternary.color,
                    probe: "\(idPrefix)-band-note")
        HStack(spacing: DS.Space.s) {
            Text("Strength").dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textTertiary.color)
                .frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { model.shapeFitGradeStrength },
                                  set: { model.shapeFitGradeStrength = ($0 * 10).rounded() / 10; rebuild() }),
                   in: -1...1, step: 0.1)
                .tint(DS.Color.accent.color)
                .latticeID("\(idPrefix)-strength-slider")
            Text(model.shapeFitGradeStrength == 0 ? "0" : String(format: "%+.1f", model.shapeFitGradeStrength))
                .dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 52, alignment: .trailing)
        }
        captionLine(Self.strengthBrief, info: "\(idPrefix)-strength", Self.strengthDetail,
                    tint: DS.Color.textQuaternary.color, probe: "\(idPrefix)-strength-note")
    }

    /// The (i): a popover with the explanation, one open at a time.
    private func infoButton(_ id: String, _ text: String) -> some View {
        Button { infoShown = id } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Color.textTertiary.color)
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { infoShown == id },
                                      set: { if !$0 { infoShown = nil } })) {
            // ★ SIZED TO ITS TEXT, NEVER SCROLLED (his 2026-09-18: "ensure that in any of
            // the (i) the pop-ups are the required size to fit the text. There should be
            // no need to scroll. Just make it bigger").
            Text(text)
                .dsStyle(DS.TypeScale.footnote)
                .foregroundStyle(DS.Color.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(16)
                .frame(width: 380)
        }
        .latticeID("wizard-info-\(id)")
    }

    private var organicAesthetic: Bool { (project.lattice.stageMode ?? .structural) == .aesthetic }
    /// Manual = a Fit with a stated size or grade (D2: the modes core knows are Auto
    /// and Fit; Manual is the user's pick among what certification approved).
    private var organicManual: Bool {
        model.cellSizeMode == .fit
            && (model.organicPickedSeparationMM > 0 || model.organicPickedGradeMM.count == 2)
    }

    @ViewBuilder private var organicRow: some View {
        let layerH = project.printParams.layerHeightMM
        let growthRefusal = LatticeSettings.organicGrowthRefusalReason(layerHeightMM: layerH)
        VStack(alignment: .leading, spacing: 5) {
            // ★ NO CAPTIONS LONGER THAN A FEW WORDS (his item 8, 2026-09-05, said
            // before): every explanation lives behind its (i).
            sectionTitle("Organic lattice", info: "traced-grown",
                         Self.infoTracedGrown + (growthRefusal.map { " Grown: " + $0 } ?? "")
                         + (organicStructuralGateClosed ? " " + TopOptKit.organicStructuralGateMessage : ""))
                .padding(.top, DS.Space.s)
                .onAppear {
                    if model.selectOrganic() { organicWindowReset = true }
                    model.enforceOrganicSimOffRules()
                }
            HStack(spacing: DS.Space.xs) {
                organicPill("Traced", on: !model.organicGrowth, enabled: true) {
                    model.organicGrowth = false; rebuild()
                }
                organicPill("Grown", on: model.organicGrowth, enabled: growthRefusal == nil) {
                    guard growthRefusal == nil else { return }
                    model.organicGrowth = true; rebuild()
                }
            }
            if growthRefusal != nil { shortNote("Needs a layer height", warning: true) }
            if model.organicGrowth, TopOptKit.gradingSchemaAccepts(key: "organic_scale") {
                Button { showPrintTuning.toggle() } label: {
                    Text(showPrintTuning ? "Hide fine-tuning" : "Fine-tune for printing…")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.accent.color)
                }
                .buttonStyle(.plain)
                .latticeID("wizard-organic-fine-tune")
                if showPrintTuning {
                    sectionTitle("Spacing scale", info: "spacing-scale", Self.infoSpacingScale)
                    scrubRow("organicScale", value: model.organicScale, unit: "×",
                             step: 0.05, range: 0.5...2) {
                        model.organicScale = $0; rebuild()
                    }
                    shortNote("Overhang fixed 30°")
                    // ★ PR 355: Michell second-family ties across the pillars (default
                    // on) and how much they wander (0 = straight).
                    HStack(spacing: DS.Space.s) {
                        HStack(spacing: DS.Space.xs) {
                            Text("Transfer ties").dsStyle(DS.TypeScale.caption)
                                .foregroundStyle(DS.Color.textPrimary.color)
                            infoButton("transfer-ties", Self.infoTransferTies)
                        }
                        Spacer(minLength: DS.Space.s)
                        latticeSwitch(isOn: model.organicTransferTies) {
                            model.organicTransferTies.toggle(); rebuild()
                        }
                        .accessibilityLabel("Transfer ties")
                        .latticeID("wizard-organic-transfer-ties")
                    }
                    if model.organicTransferTies {
                        shortNote("Tie swirl")
                        scrubRow("organicTieSwirl", value: model.organicTieSwirl, unit: "",
                                 step: 0.02, range: 0...1) {
                            model.organicTieSwirl = $0; rebuild()
                        }
                    }
                }
            }
            if organicStructuralGateClosed { shortNote("Aesthetic only for now", warning: true) }

            // ── Cell size (items 1, 3): Auto only WITH a simulation, Fit only WITHOUT ──
            sectionTitle("Cell size", info: "cell-size", Self.infoCellSize + Self.infoNoSimulation)
            let fitPossible = LatticeJobIncludeGate.hasIncludeWall(project.latticeJobRegions().regions)
            HStack(spacing: DS.Space.xs) {
                if model.simulateStresses {
                    organicPill("Auto", on: model.cellSizeMode == .auto, enabled: true) {
                        model.organicPickedSeparationMM = 0; model.organicPickedGradeMM = []
                        organicSizeVerdict = nil
                        model.setCellSizeMode(.auto); rebuild()
                    }
                } else {
                    organicPill("Fit", on: model.cellSizeMode == .fit && !organicManual, enabled: fitPossible) {
                        model.organicPickedSeparationMM = 0; model.organicPickedGradeMM = []
                        organicSizeVerdict = nil
                        model.setCellSizeMode(.fit); rebuild()
                    }
                }
                organicPill("Manual", on: organicManual, enabled: fitPossible) {
                    if model.simulateStresses {
                        if model.organicPickedGradeMM.count != 2 {
                            // ★ ruling V3: never seed an unselectable (unchecked) grade
                            model.organicPickedGradeMM = organicManualGrades.first(where: { $0.selectable })?.grade
                                ?? LatticeSettings.organicProbeGradesMM[0]
                        }
                        model.organicPickedSeparationMM = 0
                    } else {
                        if model.organicPickedSeparationMM <= 0 {
                            model.organicPickedSeparationMM = organicManualSizes.first?.size ?? 4
                        }
                        model.organicPickedGradeMM = []
                    }
                    model.setCellSizeMode(.fit); rebuild()
                }
            }
            // ★★ ROUND 3 RULING (b) (maintainer, 2026-10-01): one gate, one sentence. With lattice
            // ON this line reports exactly the gate's condition (no include wall), so it says the
            // gate's words with the one tap to the walls. With lattice OFF it reports a different
            // condition (the job's emission is empty because the mode is off; the gate says
            // "lattice mode is off"), so it keeps its own words.
            if !fitPossible {
                let why = LatticeJobIncludeGate.refusal(latticeEnabled: project.lattice.enabled, hasIncludeWall: false)
                if let why, LatticeJobIncludeGate.opensWallMarking(why) {
                    refusalNote(why, marksWalls: markWalls != nil)
                        .latticeID("wizard-organic-fit-nothing-set")
                } else {
                    shortNote("Needs a lattice region")
                }
            }
            if organicManual { organicManualLists(fitPossible: fitPossible) }
            // ★★ RULING 4 (item 8, 2026-09-30): under Auto a stale Check-sizes answer stops
            // steering the preview (its window and floor are read only from a current answer) —
            // say so here too. The line itself is the one tap: it runs Check sizes.
            if !organicManual, model.simulateStresses, model.cellSizeMode == .auto,
               project.lattice.organicSizesNeedRecheck {
                organicAutoRecheck
            }

            // ── Density (item 5: "Manual", not "Thicker") ──
            sectionTitle("Density", info: "density", Self.infoDensity)
            segmentRow(model.simulateStresses ? ["Auto", "Sim", "Manual"] : ["Auto", "Manual"],
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
                // ★★★ NEVER THINNER THAN ONE BEAD (his walk, 2026-09-07: setting Manual
                // density dropped the part preview out of Organic and back to the
                // regular ladder). A strut narrower than one extrusion is not printable
                // and core refuses the trace; the preview then had no curves, fell
                // through to the doubled ladder, and said so only in the caption's (i).
                // The control simply cannot ask for it now.
                let beadMM = Swift.max(0.05, project.printParams.strutLineWidthMM)
                scrubRow("organicStrut", value: Swift.max(model.organicStrutWidthMM, beadMM),
                         unit: " mm", step: 0.1, range: beadMM...5) {
                    model.organicStrutWidthMM = Swift.max($0, beadMM); rebuild()
                }
            }

            // ★★★ THE DEPTH-STAGGER TEST — AFTER DENSITY, AND FOR BOTH PATHS (his
            // correction, 2026-09-08: "The depth variation is only available in Grown
            // Lattice mode. NOT in Traced. Please move it OUTSIDE of the 'Print
            // fine-tuning' section and place it after the density selection").
            //
            // ★ IT WAS BESIDE THE TIES, which sit inside `if model.organicGrowth` and
            // behind the fine-tuning disclosure — so a traced lattice, the one he was
            // looking at, could not reach it at all. The deformation has nothing to do
            // with growth: it bins whatever the tracer returned by depth and offsets the
            // layers, which is the same operation on either path.
            // ★ THE DEPTH-VARIATION EXPERIMENT IS OFF THE PAGE (his 2026-09-18: "remove
            // the 'depth variation test' selection"). The model keeps the flag (off) so an
            // old snapshot decodes; nothing here can turn it on.

            // (the "Flare overhangs" row is gone, 2026-09-28: core #358 removed the stage)

            // ── Preview repairs: HIDDEN (B7 slice 2; his LS-12: "Keep it hidden for now - if required in the future I will
            // ask for it."). No row, no (i), no note; the stored `organicShowRepairs` still decides what the preview draws,
            // so a project keeps the picture it had (his 102117B9 keeps repairs hidden).

            // ── Fit to shape (item 6): ALWAYS ON without a simulation ──
            sectionTitle("Fit to shape", info: "fit-to-shape", Self.infoFitToShape
                         + " Without a simulation there is no stress to grade by, so Shape fit only stays on.")
            if TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit_only") {
                let locked = !model.simulateStresses
                HStack(spacing: DS.Space.s) {
                    Text("Shape fit only — no stress grading").dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textPrimary.color)
                    Spacer(minLength: DS.Space.s)
                    latticeSwitch(isOn: locked || model.organicShapeFitOnly) {
                        if locked {
                            model.enforceOrganicSimOffRules()
                            organicNotice = OrganicNotice(
                                title: "Shape fit only stays on",
                                message: "With Simulate Stresses off there is no stress field to "
                                    + "grade by, so the lattice can only fit the shape. Turn "
                                    + "Simulate Stresses on to grade it.")
                            return
                        }
                        // ★ ITS OWN SETTING (his correction, 2026-09-05: "Remove that
                        // association entirely. They have nothing in common"): the
                        // switch never touches the cell-size mode.
                        model.organicShapeFitOnly.toggle(); rebuild()
                    }
                    .opacity(locked ? 0.6 : 1)
                    .accessibilityLabel("Shape fit only")
                    .latticeID("wizard-organic-shape-fit-only")
                }
                if locked { shortNote("Locked while simulation is off") }
            }
            // ★ PR 355: the grade-to-solid ring inside the face outline (−1 = one
            // base cell, core's default; 0 = none).
            HStack(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.xs) {
                    Text("Solid rim at edges").dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textPrimary.color)
                    infoButton("solid-rim", Self.infoSolidRim)
                }
                Spacer(minLength: DS.Space.s)
                latticeSwitch(isOn: model.organicSolidRimMM != 0) {
                    model.organicSolidRimMM = model.organicSolidRimMM != 0 ? 0 : -1; rebuild()
                }
                .accessibilityLabel("Solid rim at edges")
                .latticeID("wizard-organic-solid-rim")
            }
            // ★ THE GRADE-TO-SHAPE BAND, HERE TOO (his 2026-09-18: "include the gradient
            // amount in Organic"). The same millimetres the octet grades over.
            VStack(alignment: .leading, spacing: 5) {
                Text("Grade to shape band")
                    .font(.system(size: 10.5, weight: .bold)).tracking(0.8).textCase(.uppercase)   // ★ B7: the panel's overline (DSPanelSection)
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .padding(.top, DS.Space.xs)
                gradeBandSliders(idPrefix: "wizard-organic-band", band: Self.organicBand)
            }
            .latticeID("wizard-organic-shape-band")
            // ★ THE LOOK (Aesthetic): cells the eye reads across the shortest face —
            // the recommendation's target when sizes are checked.
            if organicAesthetic {
                HStack(spacing: DS.Space.xs) {
                    Text("Look").dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textTertiary.color)
                    infoButton("look", Self.infoLook)
                }
                // ★★★ A PERCENTAGE, AND IT SETS THE CELL (his instruction, 2026-09-07).
                // 1 % = the largest cell the wall can hold, 100 % = the smallest core
                // will print. The slider maps into core's own band and writes the window
                // it picks, so the run builds what is shown; the cells-across value it
                // replaced was clamped by the member ceiling on his part and moved
                // nothing at all between 4 and 8.
                // ★ A SLIDER, WITH SOMETHING TO HOLD (his walk, 2026-09-07: "Look needs
                // to be a slider, I don't see anything to hold"). The scrub row it
                // replaced was a drag-anywhere field with no thumb and no track.
                HStack(spacing: DS.Space.s) {
                    Text("1%").dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                    Slider(value: Binding(
                        get: { project.lattice.organicLookPercent },
                        set: { pct in
                            project.lattice.organicLookPercent = pct
                            applyLookPercent(pct)
                        }), in: 1...100, step: 1) { editing in
                        if !editing { rebuild() }
                    }
                    .tint(DS.Color.accent.color)
                    .latticeID("wizard-organic-look")
                    Text("100%").dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                    Text(String(format: "%.0f%%", project.lattice.organicLookPercent))
                        .dsStyle(DS.TypeScale.caption).monospacedDigit()
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .frame(minWidth: 38, alignment: .trailing)
                }
                if let w = lookWindowMM {
                    shortNote(String(format: "%.2f–%.2f mm cells", w.lo, w.hi))
                } else {
                    shortNote("Mark a wall to size the cells", warning: true)
                }
            }

            // ── Unloaded walls (item 7): Aesthetic AND simulation only ──
            if organicAesthetic, model.simulateStresses {
                sectionTitle("Unloaded walls", info: "synthetic", Self.infoSynthetic)
                let synthKeyAccepted = TopOptKit.organicSyntheticStressWired
                HStack(spacing: DS.Space.s) {
                    Text("Synthetic stresses on unloaded walls").dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textPrimary.color)
                    // ★ The (i) he asked for: the stress map reads each face on its own
                    // range with this on, and that is not derivable from the row's words.
                    infoButton("synthetic-map", Self.infoSynthetic)
                    Spacer(minLength: DS.Space.s)
                    latticeSwitch(isOn: model.organicSyntheticStresses) {
                        model.organicSyntheticStresses.toggle(); rebuild()
                    }
                    .accessibilityLabel("Synthetic stresses on unloaded walls")
                    .latticeID("wizard-organic-synthetic")
                }
                if model.organicSyntheticStresses {
                    shortNote("Per wall, in Selections")
                    if !synthKeyAccepted { shortNote("Not available yet", warning: true) }
                }
            }
        }
    }

    /// ★ A caption of a few words (his item 8). Anything longer belongs in an (i).
    private func shortNote(_ text: String, warning: Bool = false) -> some View {
        Self.note(text, warning: warning)
    }
    static func note(_ text: String, warning: Bool = false) -> some View {
        Text(text).dsStyle(DS.TypeScale.caption2)
            .foregroundStyle((warning ? DS.Color.warning : DS.Color.textQuaternary).color)
            .fixedSize(horizontal: false, vertical: true)
    }
    /// ★ ruling 4: a warning note that is itself a tap — the note's own look, and a chevron.
    static func tapNote(_ text: String) -> some View {
        WallMarkingSubline(text: text, marks: true, style: DS.TypeScale.caption2)
            .foregroundStyle(DS.Color.warning.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One Manual choice: a size, whether it is approved for the stage, whether it
    /// may be selected, and the probe's refusals (verbatim, shown on hover /
    /// long-press).
    private struct ManualSize: Hashable {
        let size: Double; let approved: Bool; let selectable: Bool; let refusals: [String]
        var tint: OrganicForecast.Tint? = nil; var margin: String? = nil; var hover: String = ""
    }
    private struct ManualGrade: Hashable {
        let grade: [Double]; let approved: Bool; let selectable: Bool; let refusals: [String]
        var tint: OrganicForecast.Tint? = nil; var margin: String? = nil; var hover: String = ""
        /// ★ the pill's words (ruling V3): "Not checked" under Structural where the stress
        /// bar was never computed, else the size with "*" when unapproved and the margin
        var label: String = ""
    }
    /// ★ THE MANUAL SIZE LIST. With the organic cell-size probe present (contract
    /// 2026-09-05): its candidates — Structural offers only `approved_structural`,
    /// Aesthetic offers all and badges the unapproved. Without it: the separations
    /// certification found (item 3) and, under Aesthetic, the ladder with a "*".
    private var organicManualSizes: [ManualSize] {
        let structural = !organicAesthetic
        if let probe = project.lattice.currentOrganicForecast, !probe.sizes.isEmpty {
            return probe.sizes.map { c in
                ManualSize(size: c.cellMinMM,
                           approved: structural ? c.approvedStructural : c.approvedAesthetic,
                           selectable: OrganicForecast.selectable(c, structural: structural),
                           refusals: c.refusals, tint: OrganicForecast.tint(c, structural: structural),
                           margin: c.marginText, hover: c.hoverText(structural: structural, probedIntent: probe.probedIntent))
            }.sorted { $0.size < $1.size }
        }
        let approved = project.lattice.organicFittingSeparationsMM
        var out = approved.map { ManualSize(size: $0, approved: true, selectable: true, refusals: []) }
        if organicAesthetic {
            for s in LatticeSettings.organicManualSizeLadderMM
            where !approved.contains(where: { abs($0 - s) < 1e-6 }) {
                out.append(ManualSize(size: s, approved: false, selectable: true, refusals: []))
            }
        }
        return out.sorted { $0.size < $1.size }
    }
    /// The grades likewise: the probe's when present, else certification's.
    private var organicManualGrades: [ManualGrade] {
        let structural = !organicAesthetic
        if let probe = project.lattice.currentOrganicForecast, !probe.grades.isEmpty {
            return probe.grades.map { c in
                ManualGrade(grade: c.gradeMM,
                            approved: structural ? c.approvedStructural : c.approvedAesthetic,
                            selectable: OrganicForecast.selectable(c, structural: structural),
                            refusals: c.refusals, tint: OrganicForecast.tint(c, structural: structural),
                            margin: c.marginText, hover: c.hoverText(structural: structural, probedIntent: probe.probedIntent),
                            label: c.pillText(structural: structural))
            }
        }
        return project.lattice.organicApprovedGradesMM.filter { $0.count == 2 }
            .map { ManualGrade(grade: $0, approved: true, selectable: true, refusals: [],
                               label: String(format: "%g–%g mm", $0[0], $0[1])) }
    }
    private var organicProbePresent: Bool { project.lattice.currentOrganicForecast != nil }

    /// ★ "CHECK SIZES" (final contract 2026-09-05, UI 1): the window presets plus the
    /// user's current choice, submitted with the re-lattice job; the menu fills from
    /// `organic_probe.json`. Disabled with its reason when the linked core's schema
    /// lacks the keys or there is no worker / no variant to re-lattice.
    private var organicProbeRefusal: String? {
        if !TopOptKit.organicProbeWired { return "Size checking is not available in this build." }
        if probeDriver == nil { return "Size checking needs a worker and a finished optimization." }
        if let why = organicIncludeRefusal { return why }
        return nil
    }
    /// ★ RULING (c) (2026-09-30): a variant's job with no include wall is never written — core
    /// would lattice the whole variant — so Check sizes refuses, in the stage's words. Asked only
    /// when there IS a variant to check (the driver exists only then).
    private var organicIncludeRefusal: String? {
        organicIncludeWhy.map { "Can’t check sizes: \($0)." }
    }
    /// The gate's own words (ruling 4's one definition), before "Can’t check sizes" is put on them.
    private var organicIncludeWhy: String? {
        guard probeDriver != nil else { return nil }
        let has = hasIncludeWallCache
            ?? LatticeJobIncludeGate.hasIncludeWall(project.variantLatticeJobRegions().regions)
        return LatticeJobIncludeGate.refusal(latticeEnabled: project.lattice.enabled, hasIncludeWall: has || project.latticeStartsWhole)
    }
    /// ★ ruling 4 (item 6): Check sizes is refused for want of an include wall — every line that
    /// says so is one tap from the walls.
    private var organicRefusalMarksWalls: Bool {
        markWalls != nil && organicIncludeRefusal != nil && organicProbeRefusal == organicIncludeRefusal
            && LatticeJobIncludeGate.opensWallMarking(organicIncludeWhy)
    }
    /// A warning note; when a wall is what it lacks, its tap leaves by Save & Exit for the walls.
    @ViewBuilder private func refusalNote(_ text: String, marksWalls: Bool) -> some View {
        if marksWalls {
            Button { exitToWallMarking() } label: { Self.tapNote(text) }
            .buttonStyle(.plain)
            .accessibilityHint(WallMarkingSubline.hint)
        } else {
            shortNote(text, warning: true)
        }
    }
    /// ★ THE ONE Check-sizes submission — the button's, and under Auto the re-check line's
    /// (ruling 4, item 8). Refused, running or without a driver, it does nothing.
    private func runCheckSizes() {
        guard organicProbeRefusal == nil, organicProbeState != .running, let drive = probeDriver else { return }
        var cells = LatticeSettings.organicProbeCellsMM
        if model.organicPickedSeparationMM > 0,
           !cells.contains(where: { abs($0 - model.organicPickedSeparationMM) < 1e-6 }) {
            cells.append(model.organicPickedSeparationMM)
        }
        var grades = LatticeSettings.organicProbeGradesMM
        if model.organicPickedGradeMM.count == 2, !grades.contains(model.organicPickedGradeMM) {
            grades.append(model.organicPickedGradeMM)
        }
        organicProbeState = .running
        // ★ AND THE RECOMMENDATION (brief 2026-09-06): core generates its own
        // candidates across the band and returns FIT and AUTO picks; the look
        // target is the Aesthetic lever, the margin the Structural one.
        let recommend = RelatticeRun.Recommend(
            mode: "auto", lookCellsAcross: model.organicLookCellsAcross,
            margin: LatticeSettings.organicRecommendMargin,
            steps: LatticeSettings.organicRecommendSteps)
        Task { @MainActor in
            do {
                let probe = try await drive(cells.sorted(), grades, recommend)
                project.lattice.organicForecast = probe
                organicProbeState = .idle
            } catch {
                organicProbeState = .failed("\(error)")
            }
        }
    }
    private var organicCheckSizesButton: some View {
        let refusal = organicProbeRefusal
        let running = organicProbeState == .running
        return Button {
            runCheckSizes()
        } label: {
            HStack(spacing: 4) {
                if running { ProgressView().controlSize(.mini) }
                Text(running ? "Checking…" : OrganicForecast.checkSizesTitle)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.vertical, 4).padding(.horizontal, DS.Space.s)
            .background(Capsule().fill(DS.Color.fillSelected.color))
            .foregroundStyle((refusal == nil ? DS.Color.textPrimary : DS.Color.textQuaternary).color)
        }
        .buttonStyle(.plain)
        .disabled(refusal != nil || running)
        .help(refusal ?? OrganicForecast.checkSizesHelp)
        .latticeID("wizard-organic-check-sizes")
    }

    @ViewBuilder private func organicManualLists(fitPossible: Bool) -> some View {
        let structural = !organicAesthetic
        if model.simulateStresses {
            // ── item 2: a GRADE, "## mm to ## mm", never single values ──
            HStack(spacing: DS.Space.xs) {
                Text(organicProbePresent && structural && organicAnyChecked ? "Likely to certify" : "Grade")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textTertiary.color)
                infoButton("manual-grades", (organicProbePresent
                    ? OrganicForecast.meaning(structural: structural)
                    : Self.infoManualGrades) + Self.infoSizeCheck)
            }
            let lo = organicGradeLo, hi = organicGradeHi
            // ★ centred (his request, 2026-09-05)
            HStack(spacing: DS.Space.xs) {
                organicSizeField("organicGradeLo", value: lo) { v in commitOrganicGrade(lo: v, hi: hi) }
                Text("to").dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textTertiary.color)
                organicSizeField("organicGradeHi", value: hi) { v in commitOrganicGrade(lo: lo, hi: v) }
                organicVerdictStar
                // ★ "Check sizes" to the RIGHT of the numbers, same line (his
                // 2026-09-05), and only when it can act.
                if organicProbeRefusal == nil { organicCheckSizesButton }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            organicRecommendationRow(structural: structural)
            let grades = organicManualGrades
            if !grades.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(grades, id: \.self) { m in
                            let g = m.grade
                            organicPill(m.label,
                                        on: model.organicPickedGradeMM == g,
                                        enabled: fitPossible && m.selectable) {
                                commitOrganicGrade(lo: g[0], hi: g[1])
                            }
                            .opacity(m.selectable ? 1 : 0.4)
                            .modifier(OrganicProbeTintModifier(tint: m.tint))
                            .modifier(OrganicRefusalsModifier(refusals: m.hover.isEmpty ? m.refusals : [m.hover]))
                        }
                    }
                }
            }
        } else {
            // ── item 4: ONE size, "## mm", checked after the number is complete ──
            HStack(spacing: DS.Space.xs) {
                Text(organicProbePresent && structural && organicAnyChecked ? "Likely to certify" : "Size")
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textTertiary.color)
                infoButton("manual-sizes", (organicProbePresent
                    ? OrganicForecast.meaning(structural: structural)
                    : Self.infoManualSizes) + Self.infoSizeCheck)
            }
            HStack(spacing: DS.Space.xs) {
                organicSizeField("organicSize",
                                 value: model.organicPickedSeparationMM > 0
                                     ? model.organicPickedSeparationMM
                                     : (organicManualSizes.first?.size ?? LatticeSettings.organicProbeCellsMM[0])) { v in
                    commitOrganicSize(v)
                }
                organicVerdictStar
                if organicProbeRefusal == nil { organicCheckSizesButton }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            organicRecommendationRow(structural: structural)
            // ★ ONE field, nothing else (his 2026-09-05: "The numbers appear under
            // Manual when simulate stress = off"). The field's check consults the
            // size probe when there is one; no list of sizes is offered.
        }
        if case let .failed(why) = organicProbeState {
            HStack(spacing: DS.Space.xs) {
                shortNote("Check failed", warning: true)
                infoButton("check-failed", why)
            }
        }
        // ★ RULING (d) (2026-09-30): an answer measured on an older job route is kept but not
        // used — one line says so, and what checks the sizes again (or why nothing can)
        if project.lattice.organicSizesNeedRecheck, organicProbeState != .running {
            refusalNote(OrganicForecast.recheckLine(checkRefusal: organicProbeRefusal),
                        marksWalls: organicRefusalMarksWalls)
                .latticeID("wizard-organic-sizes-recheck")
        }
        // ★ RULING (c) (2026-09-30): Check sizes shows only when it can act, so a job with no
        // include wall is SAID — unless the re-check line above or the none-checked line below
        // already carries the refusal
        if let why = organicIncludeRefusal, !project.lattice.organicSizesNeedRecheck,
           project.lattice.currentOrganicForecast?.uncheckedSummary(
               structural: structural, grades: model.simulateStresses, checkRefusal: why) == nil {
            refusalNote(why, marksWalls: organicRefusalMarksWalls)
                .latticeID("wizard-organic-check-refused")
        }
        // ★ ruling V3 (2026-09-29): not one size's stress bar was computed — say so, and
        // what would get them checked; each size's reason behind the (i)
        if let none = project.lattice.currentOrganicForecast?.uncheckedSummary(
            structural: structural, grades: model.simulateStresses, checkRefusal: organicProbeRefusal) {
            HStack(spacing: DS.Space.xs) {
                refusalNote(none.line, marksWalls: organicRefusalMarksWalls)
                infoButton("none-checked", none.info)
            }
            .latticeID("wizard-organic-none-checked")
        }
        // ★ ruling V1 (2026-09-29): a variant's Check sizes left a face wall out — say so
        if let line = LatticeVariantFaceWalls.line(withoutShape: project.lattice.currentOrganicForecast?.facesWithoutShape ?? 0,
                                                   regions: project.lattice.currentOrganicForecast?.regionsWithoutShape ?? []) {
            shortNote(line, warning: true)
                .latticeID("wizard-organic-face-walls-left-out")
        }
    }

    /// ★★ RULING 4 (item 8): the Auto re-check line. Tapping it runs Check sizes (the button's
    /// own path); while it runs it says so; where Check sizes cannot act it says why instead —
    /// and when the reason is a missing wall, that line is the tap to the walls.
    @ViewBuilder private var organicAutoRecheck: some View {
        if organicProbeState == .running {
            HStack(spacing: DS.Space.xs) {
                ProgressView().controlSize(.mini)
                shortNote("Checking…")
            }
            .latticeID("wizard-organic-auto-recheck")
        } else if organicProbeRefusal == nil {
            Button { runCheckSizes() } label: { Self.tapNote(OrganicForecast.recheckTapLine) }
            .buttonStyle(.plain)
            .accessibilityHint(OrganicForecast.checkSizesHelp)
            .latticeID("wizard-organic-auto-recheck")
        } else {
            refusalNote(OrganicForecast.recheckLine(checkRefusal: organicProbeRefusal),
                        marksWalls: organicRefusalMarksWalls)
                .latticeID("wizard-organic-auto-recheck")
        }
        if case let .failed(why) = organicProbeState {
            HStack(spacing: DS.Space.xs) {
                shortNote("Check failed", warning: true)
                infoButton("check-failed", why)
            }
        }
    }

    /// Any size IN THE LIST SHOWN whose stress bar the probe computed (ruling V3).
    private var organicAnyChecked: Bool {
        project.lattice.currentOrganicForecast?.anyChecked(grades: model.simulateStresses) ?? false
    }

    /// ★ THE RECOMMENDATION (brief 2026-09-06, §3 menu wiring): with a simulation the
    /// AUTO pick (a graded window → swept min/max); without one the FIT pick (one size →
    /// a one-size swept window, min = max: ruling 5, 2026-10-03). Fit is never offered with a
    /// simulation (his item 1) and Auto never without (item 3). Collapsed ⇒ "no cell
    /// fits this wall — solid", with the bounds behind the (i).
    @ViewBuilder private func organicRecommendationRow(structural: Bool) -> some View {
        if let rec = project.lattice.currentOrganicForecast?.recommendation, rec.ran {
            if rec.collapsed {
                HStack(spacing: DS.Space.xs) {
                    shortNote("No cell fits: solid", warning: true)
                    infoButton("rec-collapsed", String(format: "No cell size fits this wall, so it stays solid. Band %.2f–%.2f mm; %@.",
                                                       rec.bandLoMM, rec.bandHiMM, rec.boundsText))
                }
            } else if model.simulateStresses, let a = rec.auto, a.found {
                HStack(spacing: DS.Space.xs) {
                    shortNote("Recommended")
                    // ★ ruling V3: under Structural only a CHECKED pick may be taken — one from
                    // a probe that ran on Aesthetic was never checked (2026-09-03)
                    organicPill(rec.pillText(a) + (structural && !rec.showsMargin ? " · " + OrganicSizeCheck.notCheckedTitle : ""),
                                on: model.organicPickedGradeMM == [a.cellMinMM, a.cellMaxMM],
                                enabled: !structural || rec.showsMargin) {
                        commitOrganicGrade(lo: a.cellMinMM, hi: a.cellMaxMM)
                    }
                    .modifier(OrganicProbeTintModifier(tint: rec.tint))
                    infoButton("rec-auto", rec.infoText(a))
                }
            } else if !model.simulateStresses, let f = rec.fit, f.found {
                HStack(spacing: DS.Space.xs) {
                    shortNote("Recommended")
                    organicPill(rec.pillText(f) + (structural && !rec.showsMargin ? " · " + OrganicSizeCheck.notCheckedTitle : ""),
                                on: abs(model.organicPickedSeparationMM - f.cellMM) < 1e-6,
                                enabled: !structural || rec.showsMargin) {
                        commitOrganicSize(f.cellMM)
                    }
                    .modifier(OrganicProbeTintModifier(tint: rec.tint))
                    infoButton("rec-fit", rec.infoText(f))
                }
            }
        }
    }

    // MARK: the typed size / grade (items 2 and 4)

    private var organicGradeLo: Double {
        model.organicPickedGradeMM.count == 2 ? model.organicPickedGradeMM[0] : LatticeSettings.organicProbeGradesMM[0][0]
    }
    private var organicGradeHi: Double {
        model.organicPickedGradeMM.count == 2 ? model.organicPickedGradeMM[1] : LatticeSettings.organicProbeGradesMM[0][1]
    }

    /// A number pill: tap to type; the value is committed ONCE, when the pad
    /// closes — never per digit (his item 4).
    private func organicSizeField(_ id: String, value: Double,
                                  set: @escaping (Double) -> Void) -> some View {
        Text(String(format: "%.2f mm", value))
            .dsStyle(DS.TypeScale.bodyStrong).monospacedDigit()
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, 7).padding(.horizontal, DS.Space.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.pill)
                .fill(DS.Color.fillSelected.color))
            .contentShape(Rectangle())
            .onTapGesture { numberPadField = id }
            .numberPad(Binding(get: { numberPadField == id },
                               set: { if !$0 { numberPadField = nil } }),
                       config: .init(title: "", unit: "mm", allowsDecimal: true),
                       seed: value) { v in
                guard let v else { return }
                set(v)
            }
            .latticeID("wizard-field-\(id)")
    }

    private var organicWalls: [OrganicSizeCheck.Wall] {
        project.latticeJobRegions().regions
            .filter { $0.role == .include }
            .map { OrganicSizeCheck.Wall(key: $0.selectableKey ?? "", depthMM: $0.depthMM) }
    }

    private func organicVerdict(lo: Double, hi: Double) -> OrganicSizeCheck.Verdict {
        // ★ THE ORGANIC FLOOR (brief §0): max(1.535 × bead, one voxel) — never the
        // octet cell bound. From the probe once it has run.
        OrganicSizeCheck.evaluate(cellMinMM: lo, cellMaxMM: hi, walls: organicWalls,
                                  floor: project.organicFloor,
                                  probe: project.lattice.currentOrganicForecast)
    }

    /// Checked AFTER the full number: Aesthetic ⇒ a red * with the reasons below;
    /// Structural ⇒ a pop-up when it is not expected to certify. The pick is kept
    /// either way — the run's certificate is the verdict.
    private func commitOrganicGrade(lo: Double, hi: Double) {
        guard lo > 0, hi > 0 else { return }
        if hi <= lo {
            model.organicPickedGradeMM = [lo, hi]; model.organicPickedSeparationMM = 0
            let v = OrganicSizeCheck.Verdict(
                allowed: false, likely: false,
                reasons: ["The upper size must be larger than the lower size."], advice: [])
            organicSizeVerdict = v
            organicSizeVerdictLabel = organicCurrentSizeLabel
            organicNoticeFor(label: String(format: "%g–%g mm", lo, hi), verdict: v)
            return
        }
        model.organicPickedGradeMM = [lo, hi]; model.organicPickedSeparationMM = 0
        model.setCellSizeMode(.fit)
        let v = organicVerdict(lo: lo, hi: hi)
        organicSizeVerdict = v
        organicSizeVerdictLabel = organicCurrentSizeLabel
        organicNoticeFor(label: String(format: "%g–%g mm", lo, hi), verdict: v)
        rebuild()
    }

    private func commitOrganicSize(_ mm: Double) {
        guard mm > 0 else { return }
        model.organicPickedSeparationMM = mm; model.organicPickedGradeMM = []
        model.setCellSizeMode(.fit)
        let v = organicVerdict(lo: mm, hi: mm)
        organicSizeVerdict = v
        organicSizeVerdictLabel = organicCurrentSizeLabel
        organicNoticeFor(label: String(format: "%g mm", mm), verdict: v)
        rebuild()
    }

    /// The verdict as a POP-UP in both modes (his request, 2026-09-05: "make the red
    /// notice a pop-up instead"). Aesthetic: what refused it; Structural: that core
    /// settles it at build time and it is not expected to certify.
    private func organicNoticeFor(label: String, verdict v: OrganicSizeCheck.Verdict) {
        if organicAesthetic {
            guard !v.allowed || !v.reasons.isEmpty else { return }
            organicNotice = OrganicNotice(
                title: v.allowed ? "About \(label)" : "\(label) cannot form a lattice",
                message: v.text + (v.allowed ? "\nYou can keep this size." : ""))
        } else if v.likely == false || !v.reasons.isEmpty || v.notChecked != nil {
            // ★ ruling 3 (2026-09-29): "Not checked" where the candidate's prediction did
            // not run — the title is the size check's, so its words are tested there
            organicNotice = OrganicNotice(
                title: OrganicSizeCheck.structuralTitle(label: label, verdict: v),
                message: OrganicSizeCheck.structuralNotice(label: label, verdict: v))
        }
    }

    /// The red * (Aesthetic, item 2) — shown when the typed size is refused or
    /// carries a reason; Structural says it in the pop-up instead.
    @ViewBuilder private var organicVerdictStar: some View {
        if organicAesthetic, let v = organicVerdictCurrent, !v.allowed || !v.reasons.isEmpty {
            Text("*").font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Color.red)
                .latticeID("wizard-organic-size-refused")
        }
    }

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
                .font(.system(size: 10.5, weight: .bold)).tracking(0.8).textCase(.uppercase)   // ★ B7: the panel's overline (DSPanelSection)
                .foregroundStyle(DS.Color.textTertiary.color)
                .padding(.top, DS.Space.s)
            gradeBandSliders(idPrefix: "wizard-shape-band", band: Self.shapeBand)
            // ★ the reviewer's ruling (2), 2026-11-06: one plain line until core builds the real band (LatticeTypes, after
            // its queue: grading.shape_grade_strength); it goes by itself the day the linked core takes that key
            if !TopOptKit.gradingSchemaAccepts(key: "shape_grade_strength") {
                shortNote(Self.shapeGradeRunLine).latticeID("wizard-shape-grade-run-line")
            }
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
                captionLine("No room to step down at this cell and bead.",
                            info: "band-no-room",
                            "A finer cell would need struts under one extrusion. Use a coarser "
                            + "cell, or a finer nozzle, to grade.",
                            tint: DS.Color.warning.color)
                    .latticeID("wizard-shape-fit-no-room")
            } else if let steps = shapeFitSteps {
                captionLine("\(steps) cell sizes available.", info: "band-steps",
                            tint: DS.Color.textQuaternary.color)
                    .latticeID("wizard-shape-fit-band-note")
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
    /// ★ SMALL CELLS IN THIN WALLS (his ask 11-13: "I definitely want it as a per-part choice. Especially in the app itself."):
    /// a wall too thin for an open cell takes small, denser cells at the thinnest strut instead of going solid. Off by default.
    @ViewBuilder private var smallCellsSwitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { model.smallCellsInThinWalls },
                                 set: { model.smallCellsInThinWalls = $0; rebuild() })) {
                Text("Small cells in thin walls")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            .toggleStyle(SwitchToggleStyle(tint: DS.Color.okGreen.color))
            .latticeID("wizard-small-cells-thin-walls")
            captionLine(model.smallCellsInThinWalls ? "Thin walls get small, denser cells instead of going solid."
                                                    : "A wall too thin for an open cell stays solid.",
                        info: "small-cells",
                        "New engine only. A wall too thin for an open cell at two-line struts takes small, denser cells "
                        + "(never touching) instead of going solid.")
        }
    }

    @ViewBuilder private var singleCellSwitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { model.singleCellMembers },
                                 set: { on in
                                     let hadSkin = model.boundary == .fullSkin
                                     model.setSingleCellMembers(on)
                                     // ★ SKIN IS SET AND SAID (his 2026-09-18): the pop-up
                                     // names the change the switch just made.
                                     if on, !hadSkin { finishRuleNotice = "skin-required" }
                                     rebuild()
                                 })) {
                Text("Allow single-cell members")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            .toggleStyle(SwitchToggleStyle(tint: DS.Color.okGreen.color))   // ★ B7: the panel's switch green (DSSwitch)
            .latticeID("wizard-single-cell-members")
            .popover(isPresented: Binding(get: { finishRuleNotice == "skin-required" },
                                          set: { if !$0 { finishRuleNotice = nil } })) {
                Text("The finish is now Skin: it must be on while single-cell members is on.")
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: 300)
            }
            // ★ SAID, NOT HIDDEN (his 2026-09-18): a one-cell member's struts are
            // severed at the face caps and a skin re-ties them — core's rule — so when
            // the finish chosen above would not, the line says the run adds one.
            captionLine(model.singleCellMembers ? "One cell across a member; finish locked to Skin."
                                                : "Two cells across a member.",
                        info: "single-cell",
                        "A member one cell wide has its struts cut at the face caps with no "
                        + "node to end on; the Skin finish re-ties them, so it is required "
                        + "and locked while this is on. Off, two cells across a member.")
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
                latticeSwitch(isOn: model.retainSubfloor && c.enabled) {
                    guard c.enabled else { return }
                    model.retainSubfloor.toggle()
                    rebuild()
                }
                .opacity(c.enabled ? 1 : 0.4)
                .allowsHitTesting(c.enabled)
                .accessibilityLabel(LatticeRetentionControl.titleText)
                .latticeID("wizard-subfloor-retention")
            }
            // ★ WHY IT CANNOT BE OPERATED, said as the fact it is. Greying a row in
            // silence is the defect this page has already paid for.
            captionLine(c.disabledReason == nil ? "Lattice kept where the part is too thin to certify."
                                                : "Not available on this job.",
                        info: "subfloor", c.disabledReason ?? c.body,
                        tint: (c.disabledReason == nil ? DS.Color.textTertiary : DS.Color.warning).color)
                .latticeID("wizard-subfloor-retention-note")
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
                    .font(.system(size: 10.5, weight: .bold)).tracking(0.8).textCase(.uppercase)   // ★ B7: the panel's overline (DSPanelSection)
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
                        .latticeID("wizard-thickness-derived")
                } else if let why = LatticeTypeCatalog.selectionRefusal(model.topologyID) {
                    // ★ Q2 (2026-10-05): a saved type core does not call live has no band, so
                    // no printable range to scrub — core's readiness words where it was.
                    shortNote(why, warning: true)
                        .latticeID("wizard-thickness-no-band")
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
                        .latticeID("wizard-thickness-floor-note")
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
                    captionLine("The solve picks the cell everywhere.", info: "auto-cell",
                                autoCellNote, tint: DS.Color.textQuaternary.color)
                        .latticeID("wizard-auto-cell-note")
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
                // ★ B8 (his answer 2026-10-24) put "Sim" under Along's "By stress"; B7 slice 2 removes Along (round 2,
                // N5c), so the same setting (`densityMode = .sim`) is this row's "By stress" again.
                // ★ B7 slice 2: Along is gone (round 2, N5c), so "By stress" is here again, under the permission.
                let choices = LatticeCellsRow.densityChoices(simulate: model.simulateStresses)
                segmentRow(choices.map(LatticeCellsRow.densityTitle), selected: densityModeIndex) { i in
                    model.setDensityMode(choices[i])
                }
                if model.densityMode.needsSimulation {
                    simDerivedNote("Each region graded from its own stress.")
                        .latticeID("wizard-density-sim-note")
                }
                if model.densityMode == .perRegion {
                    // ★ §8(e) — THE GAP, SURFACED. PR 331 landed the region layer
                    // but NOT the per-sector density override in the grading law,
                    // so a number typed here is captured and not yet consumed.
                    // Saying so beats a control that silently does nothing — the
                    // Diagrid-readout defect, which this project has already paid
                    // for once.
                    captionLine("Saved per region, not yet run.", info: "per-region",
                                "Set each region's density in its drawer. Core still derives "
                                + "density from the cell — these are saved, not yet run.",
                                tint: DS.Color.warning.color)
                        .latticeID("wizard-per-region-gap")
                }
                // ★★★ ALLOW QUILT (his ruling, 2026-09-12) — octet only. Off, every
                // density is held under the aesthetic ceiling (strut a fifth of the
                // cell). On, the manual methods may go past it; simulated ones never.
                if LatticeType.named(model.topologyID)?.hasAestheticCeiling == true {
                    HStack(spacing: DS.Space.s) {
                        Text("Allow quilt").dsStyle(DS.TypeScale.caption)
                            .foregroundStyle(DS.Color.textPrimary.color)
                        Spacer(minLength: DS.Space.s)
                        latticeSwitch(isOn: project.lattice.allowQuilt) {
                            project.lattice.allowQuilt.toggle(); rebuild()
                        }
                        .accessibilityLabel("Allow quilt")
                        .latticeID("wizard-allow-quilt")
                    }
                    captionLine(project.lattice.allowQuilt ? "Manual densities may fuse the struts."
                                                           : "Densities stay under the fusing point.",
                                info: "quilt",
                                "Octet struts fuse into a quilt once a strut is about a fifth of "
                                + "the cell. Off, every density stays under that point. On, the "
                                + "manual density methods may pass it; simulated ones never do.")
                }
            case .finish:
                // ★ FOUR NOW — "Covered" is the solid outer shell.
                segmentRow(["None", "Rim", "Skin", "Covered"],
                           selected: boundaryIndex, greyed: Self.rimNeedsEngineWork ? [1] : []) { i in
                    // ★ LOCKED TO SKIN while single-cell members is on: the tap is
                    // refused and the pop-up says how to unlock it (his 2026-09-18).
                    if !model.setBoundary([.none, .rim, .fullSkin, .covered][i]) {
                        finishRuleNotice = "finish-locked"
                    }
                }
                .opacity(model.finishLockedBySingleCell ? 0.55 : 1)
                .popover(isPresented: Binding(get: { finishRuleNotice == "finish-locked" },
                                              set: { if !$0 { finishRuleNotice = nil } })) {
                    Text("To change the finish, turn off single-cell members.")
                        .dsStyle(DS.TypeScale.footnote)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(maxWidth: 300)
                }
                .latticeID("wizard-finish-row")
                if model.finishLockedBySingleCell {
                    captionLine("Skin is required while single-cell members is on.",
                                info: "finish-locked",
                                "A member one cell wide has its struts cut at the face caps "
                                + "with no node to end on; the skin re-ties them. Turn off "
                                + "single-cell members to change the finish.",
                                tint: DS.Color.textQuaternary.color)
                        .latticeID("wizard-finish-locked-note")
                }
                // ★ B7 slice 2b (the reviewer 11-08 21:32Z, ruling 4): Rim greyed, said in one line, until the engine builds it
                if Self.rimNeedsEngineWork {
                    captionLine(model.boundary == .rim ? Self.rimStoredLine : Self.rimGreyedLine, info: "rim",
                                "Rim thickens the struts along the part's edges. Today's engine finds those edges only "
                                + "where two flat CAD faces meet, so it refuses Rim on a real part. Rim comes back "
                                + "when that engine work lands.",
                                tint: DS.Color.textQuaternary.color)
                        .latticeID("wizard-rim-greyed-note")
                }
                // ★ RELEASE (4): None and Rim run open — the faces beside a prism too; the preview draws their skin
                if model.boundary.jobOuterFinish == "none", !model.finishLockedBySingleCell {
                    captionLine(Self.openFacesPreviewLine, info: "open-faces",
                                "The faces beside a Lattice prism, the ones you didn't set to Lattice. Under None and Rim the "
                                + "run leaves the lattice open there; the preview still draws a thin skin over them.",
                                tint: DS.Color.textQuaternary.color)
                        .latticeID("wizard-open-faces-note")
                }
                if model.boundary == .covered {
                    captionLine("A solid outer wall over the lattice.", info: "covered",
                                "At the printer's own wall thickness. The lattice is still "
                                + "there — just not on show.",
                                tint: DS.Color.textQuaternary.color)
                        .latticeID("wizard-covered-fact")
                }
                // ★ §10(b) — A STATED FACT, NOT A PICKER. Core implements exactly
                // ONE skin, and the old "Skin pattern — Diagrid" readout looked
                // like an unselected control. It is presented as what it is until
                // a second pattern exists.
                if model.boundary == .fullSkin {
                    captionLine("Skin pattern: Diagrid.", info: "skin",
                                "The only skin pattern core builds.",
                                tint: DS.Color.textQuaternary.color)
                        .latticeID("wizard-skin-pattern-fact")
                    // ★ B7 slice 2b: Skin runs as core's "skin" — the woven skin with no solid shell — which core does not
                    // certify yet (run_job.cpp finish_certified); said here, before the run, not found in Results
                    captionLine(Self.skinNotCertifiedLine, info: "skin-cert",
                                "The woven skin replaces the solid shell. The engine's strength check doesn't credit a "
                                + "part without its shell yet, so Results shows this lattice as not accepted and "
                                + "recommends the solid. Covered keeps the shell and is certified.",
                                tint: DS.Color.textQuaternary.color)
                        .latticeID("wizard-skin-not-certified-note")
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
    /// ★★ LATTICE TYPES (U1/U2 2026-10-01, B7 slice 2): the offered types from core's facts (`LatticeTypeCatalog`),
    /// as a label card or big cards; a saved type core can't run says why in a line under the row.
    private var typeRow: some View {
        // ★ B7 slice 2 (plan.md §B7 Type, LS-1 / LS-19, R3.1): the offered types only (core's facts behind the type gate);
        // one is a LABEL card with its (i), two or more are big cards with nothing pre-picked on a new lattice (Save waits
        // for a pick). Unready types are hidden. Under Organic the cards hide (the switch below is the way back) — but a
        // saved type core can't run still shows its fix, as before.
        let entries = LatticeTypeCatalog.entriesFromCore()
        let offered = entries.filter(\.offered)
        let stale = LatticeTypeCatalog.selectionRefusal(model.topologyID, in: entries)
        let organicOn = model.cellTransition == .organicGrade
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            if !organicOn || stale != nil {
                if offered.count <= 1 {
                    if let one = offered.first { typeLabelCard(one, fixesStale: stale != nil) }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.xs), GridItem(.flexible())],
                              spacing: DS.Space.xs) {
                        ForEach(offered) { e in typeCard(e, fixesStale: stale != nil) }
                    }
                    if typePickNeeded { shortNote(Self.typePickLine).latticeID("wizard-type-pick-note") }
                }
            }
            if let why = typeReason ?? stale {
                shortNote(why).latticeID("wizard-type-reason")
            }
        }
    }

    static let typePickLine = "Pick a lattice type to save."
    static func typeInfo(_ name: String) -> String {
        "The lattice's cell shape. \(name) is the type the app offers today; more types arrive one update at a time, "
            + "each once its settings and pictures are in."
    }

    /// Two or more types offered, and none picked yet on a new lattice: Save waits.
    var typePickNeeded: Bool {
        LatticeTypeCatalog.entriesFromCore().filter(\.offered).count >= 2
            && model.cellTransition != .organicGrade && !(typePicked ?? project.lattice.enabled)
    }

    /// ★ One type: a label card, its name and an (i) — nothing to pick. A tap only fixes a saved type core can't run.
    private func typeLabelCard(_ e: LatticeTypeEntry, fixesStale: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            Button {
                guard fixesStale else { return }
                typeReason = nil
                if model.cellTransition == .organicGrade { model.topologyID = e.id } else { model.setTopology(e.id) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.displayName).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                    Text(fixesStale ? "Tap to use it" : "The lattice type").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .latticeID("wizard-type-\(e.id)")
            infoButton("type", Self.typeInfo(e.displayName))
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Color.fillSelected.color))
        .latticeID("wizard-type-label")
    }

    /// ★ Two or more types: a big card each; lit only once picked (a saved lattice's type counts as picked).
    private func typeCard(_ e: LatticeTypeEntry, fixesStale: Bool) -> some View {
        let on = model.topologyID == e.id && (typePicked ?? project.lattice.enabled)
        return Button {
            typeReason = nil
            typePicked = true
            if model.cellTransition == .organicGrade { model.topologyID = e.id } else { model.setTopology(e.id) }
        } label: {
            Text(e.displayName).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center)
                .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill((on ? DS.Color.fillSelected : DS.Color.fillSubtle).color))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(on ? DS.Color.accent.color : Color.clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .latticeID("wizard-type-\(e.id)")
    }

    /// ★★★ ORGANIC, ITS OWN ROW BELOW THE LATTICE TYPES (his ruling, 2026-09-02: "add an
    /// Organic option BELOW the lattice selection"). Not a fourth chip inside the
    /// scrolling Type row — there it was clipped off the sheet's right edge and could
    /// not be discovered, and it is not a topology anyway.
    @ViewBuilder private var organicTypeRow: some View {
        // ★ AN ON/OFF SWITCH, FULL WIDTH (maintainer, 2026-09-03, item 5): not a
        // smaller fourth chip. On, the lattice types above grey out; the explanation
        // sits behind the (i).
        let on = model.cellTransition == .organicGrade
        HStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Text("Organic lattice")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                infoButton("organic", Self.infoOrganic)
            }
            Spacer(minLength: DS.Space.s)
            latticeSwitch(isOn: on) {
                if on {
                    // back to the grade style the user last had, so the octet pane
                    // comes back exactly as it was
                    model.cellTransition = model.gradeStepStyle == .dyadic ? .defaultGrade : .stepped
                } else if model.selectOrganic() {
                    organicWindowReset = true
                }
                rebuild()
            }
            .accessibilityLabel("Organic lattice")
            .latticeID("wizard-type-organic")
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
        guard model.cellTransition == .organicGrade else { return false }
        // ★ The octet's Thickness row has no meaning for organic on EITHER tab — the
        // organic pane's Density row is the strut-width control (seen leaking on the
        // Sample tab, 2026-09-03 22:37: "3.07 mm … at a 8.00 mm cell").
        if s == .thickness { return true }
        guard model.stage == .lattice else { return false }
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

    /// One type chip's look — the app's own view, so the evidence renders exactly it.
    static func typeChipLabel(_ name: String, on: Bool, greyed: Bool) -> some View {
        Text(name)
            .font(.system(size: 11, weight: .bold))
            .lineLimit(1)
            .fixedSize()                     // ★ §11(b): never truncate a type
            .foregroundStyle((greyed ? DS.Color.textQuaternary : on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
            .padding(.vertical, 6)
            .padding(.horizontal, DS.Space.sm)
            .background(Capsule().fill(on ? DS.Color.fillSelected.color : Color.clear))
            .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
    }
    /// The lattice types a user may pick today — core's (`LatticeTypeCatalog`). The rest stay
    /// visible and greyed, with core's reason.
    static var offeredTypeIDs: Set<String> { LatticeTypeCatalog.offeredIDs }

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
                .latticeID("wizard-swept-narrow")
        }
    }

    /// What Auto will actually do, in the objective the project is set to — split
    /// out because inlining it in the view body defeated the type-checker.
    private var autoCellNote: String {
        let head = "The solve picks the cell everywhere — coarse where there is no "
            + "stress, fine where there is. "
        // ★ no longer a function of Minimize plastic (his ruling, 2026-09-12)
        let tail = "It coarsens as far as the certification allows."
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
        // ★ THE INDEX FOLLOWS THE LIST THE SEGMENT ACTUALLY SHOWS (Uniform, Per region, and By stress under the simulation).
        // A mode not on screen lights nothing (-1): an index into a list that is not shown is how a segment lights the wrong cell.
        LatticeCellsRow.densityChoices(simulate: model.simulateStresses).firstIndex(of: model.densityMode) ?? -1
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
        let r = thicknessRangeMM
        // ★ no strut law for the id (item a): the range's own lower end, never octet's strut
        guard let topo = LatticeType.named(model.topologyID) else { return r.lowerBound }
        let derived = 2 * topo.strutRadiusMM(relativeDensity: model.relativeDensity,
                                             cellMM: model.cellMM)
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

    // MARK: chrome

    /// ★ "Done" when nothing changed since the page opened, "Save" when something did — and that save starts the bake
    /// (his 2026-09-21 22:40; B4's Cells header).
    private var settingsChangedSinceOpen: Bool {
        guard let opened = openedLattice else { return true }
        return model.applied(to: project.lattice).previewBakeInputs != opened.previewBakeInputs
    }
    /// The window the Look slider is asking for, from the part's declared walls, the
    /// bead and the solve grid — core's band, mapped by the percentage.
    private var lookWindowMM: (lo: Double, hi: Double)? {
        OrganicAutoWindow.lookWindow(
            percent: project.lattice.organicLookPercent,
            regions: project.latticeJobRegions().regions,
            beadMM: project.printParams.strutLineWidthMM,
            voxelMM: project.solveVoxelMM,
            lookCellsAcross: Double(model.organicLookCellsAcross))
    }

    /// ★ THE SLIDER WRITES THE JOB'S OWN CELL KEYS. Anything else would be a preview
    /// that shows a lattice the run will not build — under Auto the job carries no cell
    /// numbers at all and core picks for itself.
    private func applyLookPercent(_ pct: Double) {
        guard let w = OrganicAutoWindow.lookWindow(
            percent: pct, regions: project.latticeJobRegions().regions,
            beadMM: project.printParams.strutLineWidthMM,
            voxelMM: project.solveVoxelMM,
            lookCellsAcross: Double(model.organicLookCellsAcross)) else { return }
        // ★ A DEGENERATE WINDOW IS A SINGLE SIZE, AND MUST BE WRITTEN AS ONE. The band's
        // grading spread comes from the stress range; with none it is 1 and lo == hi.
        // `gradingDictionary` refuses a grade whose ends are equal, so writing it as a
        // grade left the job with NO cell keys at all and core chose for itself — the
        // preview would then show a lattice the run does not build. A single size is the
        // one-size window `cell_min_mm` = `cell_max_mm` under swept (ruling 5, 2026-10-03:
        // core refuses `cell_mode fit` + `cell_mm`).
        if w.hi > w.lo + 1e-9 {
            model.organicPickedSeparationMM = 0
            model.organicPickedGradeMM = [w.lo, w.hi]
        } else {
            model.organicPickedGradeMM = []
            model.organicPickedSeparationMM = w.lo
        }
    }

    private func saveAndClose() {
        leaveLatticeArea()   // ★ B7 (E3): an open area's grade goes to its own store; the model is the Part tab's again
        // ★ B4: Along's display pick is not a bake input, so it is saved on its own test
        if settingsChangedSinceOpen || model.gradeAlong != project.lattice.gradeAlong {
            project.lattice = model.applied(to: project.lattice)
        }
        if let edits = latticeAreaEdits {
            var s = project.lattice
            s.saveAreaGrading(edits, areas: project.latticeAreaGroups.map(\.id))
            if s != project.lattice { project.lattice = s }
        }
        onExit()
    }

    // MARK: ★ B7 — THE LATTICE PAGE IN THE SQUISH LOOK
    //
    // His picks 2026-11-04 ("I build the Lattice page", "Ship the look first"); plan.md §B7; mockup v5 #lat-page. The panel is
    // the Squish one's: "Lattice settings" with the type in use, the folder tabs on the left (Part, then one per lattice
    // group), the open tab's [Auto │ Manual] and Reset all, its rows, and a pinned Cancel │ Save. Every row is today's
    // control, re-homed and never copied: the Part tab holds the type, an area's tab its finish and grading, and Manual adds
    // the rest under "Manual · this area". ★ E3 (reviewer 2026-11-06 09:41Z): an area's grade — on or off, what varies, and
    // the shape band — is its own (`LatticeSettings.areaGrading`), sent on its regions; the other rows on its tab are the
    // whole part's, and the tab says so. The view switch (One cell │ In the part) moved over the canvas; it sets nothing.

    @State private var latticeTab = "part"
    /// ★ His iPad note 11-10 (img08): his [Auto │ Manual] pick is the part's, kept every visit until Reset all. It was this
    /// page's own `@State` (false on every open), and Reset all never touched it.
    private var latticeManual: Bool {
        get { project.latticePageManual }
        nonmutating set { project.latticePageManual = newValue }
    }
    @State private var latticeResetAsk = false
    @State private var latticePanelOpen = true
    @State private var latticePanelHeight: CGFloat = 0
    /// ★ B7 (E3): each area's grade this visit (nil until the page first opens an area; saved by Save, dropped by Cancel)
    @State private var latticeAreaEdits: [UUID: LatticeAreaGrading]? = nil
    /// The Part tab's grade, held while an area's tab has the model (nil on Part).
    @State private var latticePartGrade: LatticeAreaGrading? = nil

    static let latticePanelTitle = "Lattice settings"
    static let latticeTabsKey = "lattice-page-tab"
    static let latticeManualSection = "Manual · this area"
    static let latticePerAreaLine = "Each area's tab sets its own grade and finish; the look is the whole part's."
    /// ★ B7 slice 2 (release (3)): Rim and Skin per zone wait for core (`regions[].skin`); a zone tab says whose they are.
    /// ★ B7 slice 2b: under the part's Skin (or Rim) a zone can't have its own finish (core's (1b2)): its row is greyed.
    static func zoneRimSkinLine(_ part: String) -> String {
        "A zone's own finish needs the part on None or Covered; the part is on \(part), so every zone is too."
    }
    /// ★ RELEASE (4) (reviewer 11-09 19:42Z item 4, LatticeTypes 19:32Z): the zone Finish choices core refuses, greyed,
    /// each said in one line.
    static let zoneCoveredUnderSkinLine = "The part is on Skin: its woven finish covers every zone, so a zone can't be Covered."
    static let zoneSkinOnSheetLine = "Skin weaves struts over the surface; this type is a sheet with no struts, so a zone can't take it."
    static let zoneRimSkinNeedEngineLine = "Rim and Skin per zone need engine work: this engine takes only None or Covered per zone."
    /// ★ B7 slice 2b (the reviewer 11-08 21:32Z, ruling 4): Rim greyed until LatticeTypes' rim on a real part lands.
    /// ★ RELEASE (4) (reviewer 11-09 18:31Z, "un-grey Rim"): it has (4d928a75 + a38af0c6) — greyed only on a core that
    /// builds no rim on a real part (`LatticeBoundaryTreatment.rimBuilt`).
    static var rimNeedsEngineWork: Bool { !LatticeBoundaryTreatment.rimBuilt }
    /// ★ RELEASE (4) (reviewer 11-09 18:31Z, the 03:05Z question): under None and Rim the run is the open lattice, so the
    /// faces beside a Lattice prism stay open (ruling 11-06 (1)); the preview still draws their skin until B7 slice 3.
    static let openFacesPreviewLine = "The preview shows a skin on these faces; the run leaves them open."
    static let rimGreyedLine = "Rim needs engine work: the engine builds no rim on a real part yet."
    static let rimStoredLine = "This part is on Rim, which the engine refuses today. Pick another finish."
    static let skinNotCertifiedLine = "Not certified yet: with no solid shell, Results shows this lattice as not accepted."
    /// ★ B7 slice 2 (the reviewer 11-08 21:32Z, ruling 3): while a zone's finish differs from the part's, the preview
    /// (one finish for the whole part) and the run differ — said in one line. `zones`: "Zone 1 runs open", …
    static func zoneFinishPreviewLine(_ zones: [String]) -> String {
        "The preview shows the part's finish; \(zones.joined(separator: ", ")) (see Results)."
    }
    /// ★ E3: on an area's tab, which rows are its own (it replaces "These settings apply to every region today.")
    static let latticeAreaOwnLine = "The grade, its band and the finish are this area's; the other rows are the whole part's."
    /// ★ The reviewer's words (ruling (2), 2026-11-06), under the shape grade until core's band is real.
    static let shapeGradeRunLine = "The run's shape grade is a solid outline; the band and Strength are preview only."
    /// Where an area's grade differs from the part's: the preview draws one grade, the run grades this area its own way.
    static let latticeAreaPreviewLine = "The preview draws one grade for the whole part; the run grades this area as set here."

    /// The open area's lattice group, nil on Part (the tabs are `ProjectModel.latticeAreaGroups`, in order).
    private func latticeAreaGroupID(_ c: CellsPageContext) -> UUID? {
        guard latticeArea(c) != nil, let i = Int(latticeTab.dropFirst(5)) else { return nil }
        let groups = project.latticeAreaGroups
        return groups.indices.contains(i) && groups[i].name == c.regions[i] ? groups[i].id : nil
    }

    /// ★ B7 (E3): open a tab. Leaving an area stores its grade (only what differs from the Part tab) and gives the model
    /// back the Part tab's; opening one holds the Part tab's grade and shows the area's own over it.
    private func openLatticeTab(_ id: String, _ c: CellsPageContext) {
        leaveLatticeArea()
        latticeTab = id
        guard let gid = latticeAreaGroupID(c) else { return }
        let edits = latticeAreaEdits ?? project.lattice.areaGrading
        latticeAreaEdits = edits
        latticePartGrade = LatticeAreaGrading(gradingMode: model.gradingMode, shapeFitBandMM: model.shapeFitBandMM,
                                              shapeGradeStrength: model.shapeFitGradeStrength)
        if let m = edits[gid]?.gradingMode { model.gradingMode = m }
        if let b = edits[gid]?.shapeFitBandMM { model.shapeFitBandMM = b }
        if let st = edits[gid]?.shapeGradeStrength { model.shapeFitGradeStrength = st }
        rebuild()
    }

    private func leaveLatticeArea() {
        guard let part = latticePartGrade, let c = cellsPage, let gid = latticeAreaGroupID(c) else { return }
        let mode = part.gradingMode ?? model.gradingMode, band = part.shapeFitBandMM ?? model.shapeFitBandMM
        let strength = part.shapeGradeStrength ?? model.shapeFitGradeStrength
        let own = LatticeAreaGrading(gradingMode: model.gradingMode != mode ? model.gradingMode : nil,
                                     shapeFitBandMM: model.shapeFitBandMM != band ? model.shapeFitBandMM : nil,
                                     shapeGradeStrength: model.shapeFitGradeStrength != strength ? model.shapeFitGradeStrength : nil,
                                     outerFinish: latticeAreaEdits?[gid]?.outerFinish)
        latticeAreaEdits?[gid] = own.isEmpty ? nil : own
        model.gradingMode = mode
        model.shapeFitBandMM = band
        model.shapeFitGradeStrength = strength
        latticePartGrade = nil
        rebuild()
    }

    private func latticeTabs(_ c: CellsPageContext) -> [DSFolderTabs.Tab] {
        [DSFolderTabs.Tab(id: "part", title: "Part")]
            + c.regions.enumerated().map { DSFolderTabs.Tab(id: "area-\($0.offset)", title: $0.element, colour: DS.Color.Role.lattice) }
    }

    /// The open area's name; nil on Part. With no lattice group yet the Part tab holds the area rows too.
    private func latticeArea(_ c: CellsPageContext) -> String? {
        guard latticeTab.hasPrefix("area-"), let i = Int(latticeTab.dropFirst(5)), c.regions.indices.contains(i) else { return nil }
        return c.regions[i]
    }

    /// The panel from under the stage row (design-system §4.1, PageChrome.panelTop). Landscape: to the hint band, the view
    /// switch over the canvas beside it, level with the panel's header. Portrait (mockup 11P): the panel hugs its rows (at most
    /// 62 % of the page, as Squish's) and the canvas, its view switch on top, is under it.
    /// AnyView: the iPad's Release build (whole-module) found `body`'s opaque type defined in terms of itself through this
    /// tree (the Mac's debug build did not); erasing it here ends the chain.
    private func latticePage(_ c: CellsPageContext, size: CGSize) -> AnyView {
        let portrait = size.width < size.height
        let band = max(DSParts.headerHeight, size.height - PageChrome.panelTop - PageChrome.panelBottom)
        return AnyView(ZStack {
            // ★ B7 (his iPad notes 11-08, design note 30), ★ his 11-10 (later): Cells is core's chunk of cells; In a part is
            // core's sample part with the settings on it — never his own part (the workspace covers it on this page)
            AnyView(LatticeSampleView(inputs: latticeSampleInputs, notInSample: latticeNotInSample)
                .id(model.stage)   // each view its own camera: the chunk and the part frame differently
                .padding(.leading, portrait ? 0 : PageChrome.edge + PageChrome.widePanelWidth)
                .padding(.top, portrait ? PageChrome.panelTop + latticePanelHeight : PageChrome.panelTop)
                .latticeID(model.stage == .cell ? "lattice-sample-cells" : "lattice-sample-part"))
            latticePanel(c, hug: portrait)
                .frame(height: portrait ? nil : band)
                .frame(maxHeight: portrait ? min(band, size.height * 0.62) : nil, alignment: .top)
                .padding(.leading, PageChrome.edge).padding(.top, PageChrome.panelTop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            latticeViewSwitch
                .frame(maxWidth: .infinity)
                .padding(.leading, portrait ? PageChrome.edge : PageChrome.edge + PageChrome.widePanelWidth + DS.Space.l)
                .padding(.trailing, PageChrome.edge)
                .padding(.top, portrait ? PageChrome.panelTop + latticePanelHeight + DS.Space.l + 14 : PageChrome.panelTop + 14)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        // ★ his iPad notes 11-10 (img 3) + (later): a sample is always up — the workspace covers his part (LatticeSampleShowingKey)
        .preference(key: LatticeSampleShowingKey.self, value: true))
    }

    /// The sample's inputs: which view, the page's type, its cell when Cell size is Manual (else core's own), the printer's
    /// bead, and (★ his iPad notes 11-10, img 6) the Grade's ends — graded from "to" up to "from", or one density when not
    /// graded (the chunk of cells shows "from").
    private var latticeSampleInputs: LatticeSampleView.Inputs {
        Self.sampleInputs(model, beadMM: project.printParams.strutLineWidthMM)
    }

    static func sampleInputs(_ model: LatticeWizardModel, beadMM: Double) -> LatticeSampleView.Inputs {
        let graded = model.gradingMode != LatticeGradingMode.none
        return LatticeSampleView.Inputs(shape: model.stage == .cell ? .cells : .part,
                                        topology: model.topologyID,
                                        typeName: LatticeType.displayName(forID: model.topologyID),
                                        cellMM: model.cellSizeMode == .fixed ? model.cellMM : 0,
                                        beadMM: beadMM,
                                        rhoLo: graded ? model.minRelativeDensity : model.relativeDensity,
                                        rhoHi: model.relativeDensity)
    }

    /// ★ his iPad notes 11-10 (img 6): what he has on that the engine's sample block can't show yet.
    private var latticeNotInSample: [String] {
        LatticeSampleView.notInSample(organic: model.cellTransition == .organicGrade, finish: model.boundary,
                                      shapeBand: model.gradingMode.fitsShape,
                                      singleCell: model.singleCellMembers && (project.lattice.stageMode ?? .structural) == .aesthetic)
    }

    private func latticePanel(_ c: CellsPageContext, hug: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            latticePanelHeader
            if latticePanelOpen {
                latticePanelBody(c, hug: hug)
                    .overlay(alignment: .top) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
                latticeFoot
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
                    .overlay(alignment: .top) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
            }
        }
        .frame(width: PageChrome.widePanelWidth, alignment: .leading)
        .frame(maxHeight: latticePanelOpen && !hug ? .infinity : nil, alignment: .top)
        .background(CornerPairStyle.publish("latticeSettingsPanel"))
        .background(latticePanelShape.fill(DS.Surface.panel.color))
        .overlay(latticePanelShape.strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .clipShape(latticePanelShape)
        .dsShadow(DS.Shadow.panel)
        .background(GeometryReader { g in Color.clear.preference(key: LatticePanelHeightKey.self, value: g.size.height) })
        .onPreferenceChange(LatticePanelHeightKey.self) { h in if abs(h - latticePanelHeight) > 0.5 { latticePanelHeight = h } }
        .frame(maxHeight: .infinity, alignment: .top)   // folded, the header's pill stays under the stage row
    }

    /// The folder tabs beside the open tab's scrolling rows. Landscape: the panel's whole height. Portrait: as tall as the
    /// rows (FlexibleHugHeight, the Squish panel's), then scrolling.
    @ViewBuilder private func latticePanelBody(_ c: CellsPageContext, hug: Bool) -> some View {
        if hug {
            FlexibleHugHeight { latticeTabsAndRows(c) }
        } else {
            latticeTabsAndRows(c).frame(maxHeight: .infinity)
        }
    }

    private func latticeTabsAndRows(_ c: CellsPageContext) -> some View {
        HStack(alignment: .top, spacing: 0) {
            DSFolderTabs(latticeTabs(c), selected: latticeArea(c) == nil ? "part" : latticeTab, key: Self.latticeTabsKey,
                         pick: { id in withAnimation(.easeInOut(duration: 0.15)) { openLatticeTab(id, c) } })
                .frame(maxHeight: .infinity, alignment: .top)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    latticeTopRow
                    latticeTabBody(c)
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A switch on this page: the panel's (DSSwitch, green when on), as the mockup draws every row's switch.
    private func latticeSwitch(isOn: Bool, action: @escaping () -> Void) -> some View {
        DSSwitch(isOn: isOn, key: "latticePageSwitch", toggle: action)
    }

    private var latticePanelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: latticePanelOpen ? DSParts.panelRadius : DSParts.headerHeight / 2, style: .continuous)
    }

    /// Chevron + "Lattice settings" + the type in use (design-system §4.3: nothing else). A tap folds it to this line.
    private var latticePanelHeader: some View {
        Button { withAnimation(DS.Motion.sheetIn) { latticePanelOpen.toggle() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .rotationEffect(.degrees(latticePanelOpen ? 0 : -90))
                    .frame(width: 18)
                Text(Self.latticePanelTitle).font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                Spacer(minLength: 8)
                Text((project.lattice.stageMode ?? .structural).title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Color.textTertiary.color).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: DSParts.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .latticeID("lattice-page-header")
    }

    /// [Auto │ Manual] and Reset all, at the top of every tab (as the Squish panel's). Reset all asks once, in place.
    private var latticeTopRow: some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 4) {
                ForEach([(false, "Auto"), (true, "Manual")], id: \.0) { manual, word in
                    let on = latticeManual == manual
                    Button { withAnimation(.easeInOut(duration: 0.15)) { latticeManual = manual } } label: {
                        Text(word).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                            .lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Capsule().fill(on ? DS.Color.fillSelected.color : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .latticeID("lattice-page-mode-\(manual ? "manual" : "auto")")
                }
            }
            .padding(2)
            .background(Capsule().fill(DS.Color.background.opacity(0.35).color)
                .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
            .fixedSize()
            .opacity(latticeResetAsk ? 0 : 1).allowsHitTesting(!latticeResetAsk)
            Spacer(minLength: 0)
            Button { latticeResetAsk = true } label: {
                Text(FlexibleSettingsExit.resetButton)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                    .padding(.horizontal, 6).frame(height: 30)
                    .frame(minWidth: FlexibleTargets.least, minHeight: FlexibleTargets.least)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(FlexibleConfirmInPlace(asking: latticeResetAsk, question: FlexibleSettingsExit.resetAsk,
                                             destructive: FlexibleSettingsExit.resetConfirm, keep: FlexibleSettingsExit.resetCancel,
                                             confirmKey: "latticeResetConfirm", keepKey: "latticeResetCancel",
                                             questionID: "lattice-page-reset-ask",
                                             confirm: { latticeResetAsk = false; resetLatticeSettings() },
                                             cancel: { latticeResetAsk = false }))
            .latticeID("lattice-page-reset-all")
        }
    }

    /// Reset all: every setting this page asks back to a brand-new lattice of this type (the regions, their roles and
    /// depths are the Setup step's and stay). Nothing is saved until Save; Cancel still leaves as the page opened.
    private func resetLatticeSettings() {
        latticeManual = false   // ★ 11-10 (img08): Reset all is the one thing that puts Auto back
        var fresh = LatticeSettings(enabled: true)
        fresh.stageMode = project.lattice.stageMode
        let stage = model.stage
        model = LatticeWizardModel(settings: fresh)
        model.jump(to: stage)
        // ★ B7 (E3): every area's own grade goes too; an open area's tab now shows the fresh part's
        latticeAreaEdits = [:]
        if latticePartGrade != nil {
            latticePartGrade = LatticeAreaGrading(gradingMode: model.gradingMode, shapeFitBandMM: model.shapeFitBandMM,
                                                  shapeGradeStrength: model.shapeFitGradeStrength)
        }
        rebuild()
    }

    /// The open tab's rows. Part: the type (and, with no lattice group yet, the area rows). An area: its finish and grading,
    /// and in Manual the rest. Organic keeps its own pane (a traced lattice has no cell, no finish ladder).
    /// AnyView here and in each row below: the whole page in one opaque type crashed the iPad's Release compiler (SILGen, 11-05).
    private func latticeTabBody(_ c: CellsPageContext) -> AnyView {
        let area = latticeArea(c)
        let organic = model.cellTransition == .organicGrade
        let structural = (project.lattice.stageMode ?? .structural) == .structural
        return AnyView(Group {
        if area == nil {
            AnyView(settingControl(.type, titled: true))
            if latticeManual, !Self.controlHideSimulateStresses { AnyView(simulateStressesSwitch) }
            if c.regions.isEmpty {
                latticeAreaRows(organic: organic, structural: structural)
            } else {
                shortNote(Self.latticePerAreaLine).latticeID("lattice-page-per-area-note")
                // ★ B7 slice 2: the part's finish is set here once an area can have its own (Rim / Skin stay the part's)
                if !organic, TopOptKit.regionOuterFinishWired { AnyView(settingControl(.finish, titled: true)) }
                zoneFinishPreviewNote
            }
        } else if let area {
            Text(area.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.8)
                .foregroundStyle(DS.Color.textTertiary.color)
            // ★ E3 (reviewer 2026-11-06): the grade is this area's own now; "These settings apply to every region today" goes
            shortNote(Self.latticeAreaOwnLine).latticeID("lattice-page-area-own-note")
            if let part = latticePartGrade, c.regions.count > 1,
               part.gradingMode != model.gradingMode
                || (model.gradingMode.fitsShape && part.shapeFitBandMM != model.shapeFitBandMM) {
                shortNote(Self.latticeAreaPreviewLine).latticeID("lattice-page-area-preview-note")
            }
            zoneFinishPreviewNote
            latticeAreaRows(organic: organic, structural: structural, zone: latticeAreaGroupID(c))
        }
        })
    }

    /// ★ B7 slice 2 (release (3), E2.4 per region): a zone's own finish, [None │ Covered] in core's words "none" / "shell";
    /// until set, the part's (Covered when the part is covered, else None). Rim and Skin are the part's, said in one line.
    /// ★ RELEASE (4) (ruling 11-08 (1), (A); LatticeTypes 19:32Z; reviewer 19:42Z item 4): a zone's Finish is the part's four
    /// — [None │ Rim │ Skin │ Covered] — sent as the pair core reads (`LatticeAreaGrading.ZoneFinish.words`). Core's refusals
    /// are greyed and said: Covered under the part's Skin (its woven finish is part-wide), Skin on a sheet type (R8), and
    /// Rim / Skin on an engine that takes no `regions[].skin`. Organic zones show the organic row instead (no zone skin).
    private func zoneFinishRow(_ gid: UUID) -> AnyView {
        let own = (latticeAreaEdits ?? project.lattice.areaGrading)[gid] ?? LatticeAreaGrading()
        let partOuter = model.boundary.zoneFinishWord   // nil: the part is on Skin (or Rim on an engine without it)
        let partSkin = model.boundary.jobSkinValue
        let skinWired = TopOptKit.regionSkinWired && LatticeBoundaryTreatment.rimBuilt
        let sheet = LatticeSettings.sheetTopologies.contains(model.topologyID)
        let partOnSkin = model.boundary == .fullSkin
        let shown = (partOuter == nil && !partOnSkin) ? nil : own.zoneFinish(partOuter: partOuter, partSkin: partSkin)
        func greyed(_ f: LatticeAreaGrading.ZoneFinish) -> Bool {
            switch f {
            case .none: return partOuter == nil && !partOnSkin
            case .covered: return partOuter == nil
            case .rim: return !skinWired
            case .skin: return !skinWired || sheet
            }
        }
        let partName = ["None", "Rim", "Skin", "Covered"][boundaryIndex]
        return AnyView(VStack(alignment: .leading, spacing: 5) {
            Text("Finish").font(.system(size: 10.5, weight: .bold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(DS.Color.textTertiary.color)
            HStack(spacing: 4) {
                ForEach(LatticeAreaGrading.ZoneFinish.allCases, id: \.self) { f in
                    segmentButton(f.title, on: shown == f, greyed: greyed(f)) {
                        if latticeAreaEdits == nil { latticeAreaEdits = project.lattice.areaGrading }
                        var g = latticeAreaEdits?[gid] ?? LatticeAreaGrading()
                        // under the part's Skin a zone sets its skin only (core refuses its own outer_finish there)
                        g.outerFinish = partOuter == nil ? nil : f.words.outer
                        g.skin = f.words.skin
                        latticeAreaEdits?[gid] = g
                        rebuild()
                    }
                    .latticeID("lattice-zone-finish-\(f.rawValue)")
                }
            }
            .modifier(LatticeSegmentTrack())
            if partOuter == nil && !partOnSkin {
                shortNote(Self.zoneRimSkinLine(partName)).latticeID("lattice-zone-rim-skin-note")
            } else if partOnSkin {
                shortNote(Self.zoneCoveredUnderSkinLine).latticeID("lattice-zone-covered-under-skin-note")
            }
            if !skinWired {
                shortNote(Self.zoneRimSkinNeedEngineLine).latticeID("lattice-zone-rim-skin-engine-note")
            } else if sheet {
                shortNote(Self.zoneSkinOnSheetLine).latticeID("lattice-zone-skin-sheet-note")
            }
        })
    }

    /// ★ B7 slice 2 (the reviewer 11-08 21:32Z, ruling 3): the zones whose finish the run gives differently from the part's
    /// — "Zone 1 runs open" — in tab order; empty under Skin / Rim (no zone sends its own) and when core takes none.
    var zonesRunningAnotherFinish: [String] {
        guard TopOptKit.regionOuterFinishWired, model.cellTransition != .organicGrade else { return [] }
        let partOuter = model.boundary.zoneFinishWord, partSkin = model.boundary.jobSkinValue
        guard partOuter != nil || model.boundary == .fullSkin else { return [] }
        // ★ release (4): Rim and Skin per zone too — the zone's four against the part's own
        let part = LatticeAreaGrading().zoneFinish(partOuter: partOuter, partSkin: partSkin)
        let edits = latticeAreaEdits ?? project.lattice.areaGrading
        return project.latticeAreaGroups.compactMap { g in
            guard let e = edits[g.id], e.outerFinish != nil || e.skin != nil else { return nil }
            let f = e.zoneFinish(partOuter: partOuter, partSkin: partSkin)
            guard f != part else { return nil }
            switch f {
            case .none: return "\(g.name) runs open"
            case .rim: return "\(g.name) runs with Rim"
            case .skin: return "\(g.name) runs with Skin"
            case .covered: return "\(g.name) runs covered"
            }
        }
    }
    @ViewBuilder private var zoneFinishPreviewNote: some View {
        let zones = zonesRunningAnotherFinish
        if !zones.isEmpty {
            shortNote(Self.zoneFinishPreviewLine(zones)).latticeID("lattice-page-zone-finish-preview-note")
        }
    }

    private func latticeAreaRows(organic: Bool, structural: Bool, zone: UUID? = nil) -> AnyView {
        AnyView(Group {
        if organic {
            AnyView(organicRow)
        } else {
            if let zone, TopOptKit.regionOuterFinishWired { zoneFinishRow(zone) }
            else { AnyView(settingControl(.finish, titled: true)) }
            AnyView(gradeToggleRow)
            if model.gradingMode != LatticeGradingMode.none { AnyView(gradeTypeRow) }
        }
        if latticeManual {
            Text(Self.latticeManualSection.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.8)
                .foregroundStyle(DS.Color.accent.color)
                .padding(.top, 4)
            if !organic {
                ForEach([LatticeWizardSetting.cellSize, .density, .thickness], id: \.rawValue) { s in
                    AnyView(settingControl(s, titled: true))
                }
                AnyView(gradeStyleRow)
                if model.gradingMode.fitsShape { AnyView(shapeBandRow) }
                if !structural { AnyView(singleCellSwitch) }
                AnyView(smallCellsSwitch)
            }
            if structural { AnyView(subfloorRetentionSwitch) }
            if !organic { AnyView(cellsAddedRows) }
        }
        })
    }

    /// Cancel │ Save, pinned (the Squish panel's foot). Save is today's (it saves what changed, then builds the preview);
    /// Cancel leaves as the page opened.
    private var latticeFoot: some View {
        HStack(spacing: DS.Space.s) {
            Spacer(minLength: 0)
            latticeFootButton(FlexibleSettingsExit.cancel, primary: false, id: "lattice-page-cancel") { cancelAndClose() }
            latticeFootButton(FlexibleSettingsExit.save, primary: true, id: "lattice-cells-save", enabled: !typePickNeeded) {
                saveAndClose()
            }
        }
    }

    private func latticeFootButton(_ title: String, primary: Bool, id: String, enabled: Bool = true,
                                   action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.l).frame(minWidth: 84, minHeight: FlexibleTargets.least)
                .background(Capsule().fill((primary ? DS.Color.accent : DS.Color.fillSubtle).color))
                .opacity(enabled ? 1 : 0.45)   // ★ B7 slice 2: grey until a type is picked (two or more offered)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .latticeID(id)
    }

    /// Cancel: no setting this page changed is kept — the one it writes as it changes (the organic Look) goes back, the rest
    /// was never applied — then it leaves as Save does with nothing changed. (A Check sizes answer is a measurement, not a
    /// setting: it stays, stamped with what it was measured for.)
    private func cancelAndClose() {
        if let o = openedLattice { project.lattice.organicLookPercent = o.organicLookPercent }
        onExit()
    }

    /// One cell │ In the part, over the canvas: what the canvas shows (its settings are on the panel's tabs).
    private var latticeViewSwitch: some View {
        HStack(spacing: 2) {
            ForEach(LatticeWizardStage.allCases, id: \.rawValue) { s in
                let on = model.stage == s
                Button { model.jump(to: s); rebuild() } label: {
                    Text(s.title)   // ★ his 11-10: Cells │ In a part
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                        .padding(.horizontal, DS.Space.l).frame(minWidth: 120, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? DS.Color.fillSelected.color : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .latticeID("wizard-stage-\(s.rawValue)")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .fixedSize()
        .background(CornerPairStyle.publish("latticeViewSwitch"))
    }

    // MARK: ★ B4 — the Cells page's header and added rows

    /// "Cells" · Save / Done, and a tab per region (the rows apply to every region today, and say so).
    @ViewBuilder private func cellsHeader(_ c: CellsPageContext) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(LatticeStagePage.cells.title).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                Button { saveAndClose() } label: {
                    Text(settingsChangedSinceOpen || model.gradeAlong != project.lattice.gradeAlong ? "Save" : "Done")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, DS.Space.m).frame(height: 32)
                        .background(Capsule().fill(DS.Color.accent.color))
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .latticeID("lattice-cells-save")
            }
            if !c.regions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(Array(c.regions.enumerated()), id: \.offset) { i, name in
                            Button { cellsTab = i } label: {
                                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    .padding(.vertical, 6).padding(.horizontal, DS.Space.m)
                                    .background(Capsule().fill((cellsTab == i ? DS.Color.accent.opacity(0.85)
                                                                 : DS.Color.background.opacity(0.35)).color))
                                    .foregroundStyle(DS.Color.textPrimary.color)
                                    .frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .latticeID("lattice-cells-tab-\(i)")
                        }
                    }
                }
                shortNote(LatticeCellsRow.tabsNote)
            }
        }
    }

    /// Grade from → to (today's density band: `maxRelativeDensity` → `minRelativeDensity`), then Strength (Structural), its
    /// line saying what backs it. ★ B7 slice 2: Along, Ties and Overhangs are off the page (`LatticeCellsRow.rows`).
    @ViewBuilder private var cellsAddedRows: some View {
        let mode = project.lattice.stageMode
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(LatticeCellsRow.rows(mode), id: \.rawValue) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.system(size: 10.5, weight: .bold)).tracking(0.8).textCase(.uppercase)   // ★ B7: the panel's overline (DSPanelSection)
                        .foregroundStyle(DS.Color.textTertiary.color)
                    switch row {
                    case .grade:
                        HStack(spacing: DS.Space.s) {
                            cellsPercentBox("cells-grade-from", title: "Grade from", value: model.relativeDensity) { v in
                                model.relativeDensity = Swift.min(1, Swift.max(v, Swift.max(0.05, model.minRelativeDensity + 0.02)))
                                rebuild()
                            }
                            Text("\u{2192}").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.Color.textTertiary.color)
                            cellsPercentBox("cells-grade-to", title: "Grade to", value: model.minRelativeDensity) { v in
                                model.minRelativeDensity = Swift.max(0, Swift.min(v, model.relativeDensity - 0.02))
                                rebuild()
                            }
                            Text("density").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
                        }
                    case .strength:
                        shortNote(LatticeCellsRow.strengthLine)
                    case .along, .ties, .overhangs:
                        EmptyView()   // ★ B7 slice 2: off the page (`LatticeCellsRow.rows` never lists them)
                    }
                }
                .latticeID("lattice-cells-row-\(row.rawValue)")
            }
        }
    }

    /// A percent box that types (his rule: every number takes the keypad).
    private func cellsPercentBox(_ key: String, title: String, value: Double,
                                 write: @escaping (Double) -> Void) -> some View {
        Text("\(Int((value * 100).rounded())) %")
            .font(.system(size: 12, weight: .bold)).monospacedDigit()
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, 6).padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Color.fillSelected.color))
            .frame(minHeight: 44).contentShape(Rectangle())
            .onTapGesture { numberPadField = key }
            .numberPad(Binding(get: { numberPadField == key }, set: { if !$0 { numberPadField = nil } }),
                       config: .init(title: title, unit: "%", allowsDecimal: false),
                       seed: (value * 100).rounded()) { v in
                guard let v else { return }
                write(v / 100)
            }
            .latticeID(key)
    }

    // MARK: the moves

    /// What a settings change refreshes on this page: whether any region latticed is an include wall (the refusal lines
    /// read it). B8: the sample cube this used to rebuild is gone with the full-screen page.
    private func rebuild() {
        let regions = project.latticeJobRegions().regions
        hasIncludeWallCache = LatticeJobIncludeGate.hasIncludeWall(regions)
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
                       config: .init(title: "", unit: unit, allowsDecimal: true, range: NumberRange(range)),
                       seed: value) { v in
                guard let v else { return }
                set(Swift.min(range.upperBound, Swift.max(range.lowerBound, v)))
            }
            .latticeID("wizard-field-\(id)")
    }

    /// `greyed`: choices drawn faded that a tap does not pick (B7 slice 2b: Rim until the engine builds it).
    private func segmentRow(_ names: [String], selected: Int, greyed: Set<Int> = [],
                            tap: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                segmentButton(n, on: selected == i, greyed: greyed.contains(i)) { tap(i) }
            }
        }
        .modifier(LatticeSegmentTrack())
    }

    private func segmentButton(_ name: String, on: Bool, greyed: Bool = false,
                               tap: @escaping () -> Void) -> some View {
        let ink: Color = (on ? DS.Color.textPrimary : DS.Color.textTertiary).color
        let fill: Color = on ? DS.Color.fillSelected.color : Color.clear
        return Button(action: tap) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
        .disabled(greyed)
        .opacity(greyed ? 0.35 : 1)
        .latticeID("wizard-seg-\(name.lowercased())")
    }
}


/// ★ B7: the Lattice settings panel's drawn height (portrait: the canvas's view switch sits under it).
private struct LatticePanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// ★ B7: the Squish look's segment track (FlexChips): 2 pt inside a dark capsule with a hairline.
private struct LatticeSegmentTrack: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(2)
            .background(Capsule().fill(DS.Color.background.opacity(0.35).color)
                .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
    }
}

/// ★ THE PROBE'S REFUSALS, VERBATIM (contract 2026-09-05: "they are written to be
/// read"): a pointer hover shows them as help; a long-press shows them as a menu.
private struct OrganicRefusalsModifier: ViewModifier {
    let refusals: [String]
    func body(content: Content) -> some View {
        if refusals.isEmpty {
            content
        } else {
            content
                .help(refusals.joined(separator: "\n"))
                .contextMenu {
                    ForEach(refusals, id: \.self) { Text($0) }
                }
        }
    }
}


/// ★ green = likely to certify · amber = ties only · grey = refused (UI 1): a dot on
/// the pill's corner, so the pill's own on/off state stays legible. STRUCTURAL ONLY, and
/// only where the prediction ran: otherwise the tint is nil and no dot is drawn
/// (maintainer, 2026-09-29, rulings A and 3).
private struct OrganicProbeTintModifier: ViewModifier {
    let tint: OrganicForecast.Tint?
    func body(content: Content) -> some View {
        if let tint {
            content.overlay(alignment: .topTrailing) {
                Circle()
                    .fill(color(tint))
                    .frame(width: 7, height: 7)
                    .offset(x: 2, y: -2)
                    .accessibilityLabel(tint.rawValue)
            }
        } else {
            content
        }
    }
    private func color(_ t: OrganicForecast.Tint) -> Color {
        switch t {
        case .green: return DS.Color.okGreen.color
        case .amber: return DS.Color.warning.color
        case .grey: return DS.Color.textQuaternary.color
        }
    }
}


/// The measured height of the settings panel's scrolling rows.
struct WizardPanelRowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}


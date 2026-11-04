// FlexiblePrintPlanPage — B9 (#362), the Print plan page of the main Flexible stage (app-map §3.7 "Print plan page", flow §4.8;
// the mockup's #flex-plan; design-system §4.3 Panel, §4.21 SettingRow, §4.29 clear-all confirm, §4.30 seam row).
//
// A plan is about the WHOLE model: how it is cut into pieces and how each seam is held. The page swaps the Setup page's left
// panel (FlexibleSelectionsList draws this one while `main.page == .plan`) and its corner's main button
// (FlexibleCornerPair: Build Plan A, grey with one fix chip while a seam has no joint); the view, the views row and the top-left
// block stay the stage's own.
//   * Plan ⌄: the plans (a check on the current one), + New plan (from the app's cut), Rename, Duplicate.
//   * 1 · Pieces: the app's cut — one material: the whole part (+ Second material for the solid areas); two: the lattice
//     (TPU) apart from the body (its plastic ⌄).
//   * 2 · Seams: one row per seam with its own joint; the open seam's card — Held by ⌄ per seam kind, then the joint's rows
//     (TPU plate, the two-head line, print order, the pause line…).
//   * 3 · Add-ons: what the joints call for, a switch each.
//   * Skin and rim: TPU │ Rigid (two materials).
//   * Foot: Reset (bottom-left) — its confirm opens at the top middle (FlexiblePrintPlanOverlays).
// ★ FRONT END FIRST (his 11-03 answer): + Cut, the places on the part and the per-plan rebuild need the engine (E5); the job
// sent to core stays as today, and where a result would show the page says so in one plain line (`main.planNote`). Nothing
// here is ever shown built that the engine has not built.

import SwiftUI
import TopOptDesign
import TopOptKit

/// The main Flexible stage's pages (the Squish page is its own full page).
public enum FlexibleMainPage: Equatable, Sendable { case setup, plan }

/// The page's words (U4: one word per thing; labels 3–5 words, the rest behind (i)).
enum FlexiblePrintPlanCopy {
    static let title = "Print plan"
    static let planInfo = "A print plan says how the whole part is cut into pieces and how each seam is held. A part can have several; Export asks which one."
    static let pieces = "1 \u{00B7} Pieces"
    static let seams = "2 \u{00B7} Seams"
    static let addOns = "3 \u{00B7} Add-ons"
    static let addOnsInfo = "Extra pieces printed in the rigid plastic. The Play view shows them apart, each with a line to its place."
    static let oneMaterial = "One material: the solid areas print in TPU too."
    static let secondMaterial = "Second material for the solid areas"
    static let appCut = "The app cut the lattice from the solid."
    static let pickJoint = "Pick a joint"
    static let pickJointLine = "Pick how it\u{2019}s held. Its places then come from the engine."
    static let heldBy = "Held by"
    static func heldInfo(_ k: FlexibleSeamKind) -> String {
        switch k {
        case .tpuRigid: return "T-slot holds best: in pull tests a T held until the plastic broke, while dovetails slid apart. Only PLA has tested joint data with TPU; other plastics are estimates until the joint coupons are printed."
        case .rigidRigid: return "Two rigid pieces. A keyed cut lines them up by itself; pins and screw bosses are printed with the pieces."
        case .tpuTpu: return "Two TPU pieces."
        }
    }
    static let plate = "TPU plate"
    static let plateInfo = "The lattice ends on a solid TPU plate where it meets the rigid part. Every joint grips the plate, never the lattice walls."
    static let together = "Needs a dual-nozzle or tool-changer printer: varioShore can\u{2019}t go through the AMS."
    static let printOrder = "Print order"
    static let printOrderValue = "Rigid first \u{00B7} solid below"
    static let slidePlaces = "Its places come from the engine with the joint geometry."
    static let flange = "One TPU lip all round, clamped under a rigid lip by a screwed ring."
    static func pause(_ j: String) -> String {
        j == "Insert" ? "The TPU print pauses: drop the insert in, then resume. The pause goes in the 3MF."
            : "The rigid print pauses: drop the TPU piece in, then resume. The pause goes in the 3MF."
    }
    static let skin = "Skin and rim"
    static let skinInfo = "What the Covered skin and the Rim are printed in."
    static let reset = "Reset"
    static let resetLine = "clears every plan, add-on and place"
    static let resetAsk = "Clear every print plan?"
    static let resetDetail = "Every plan, add-on and joint place goes. The app\u{2019}s own cut comes back as a fresh Plan A."
    static let newPlan = "New plan"
    static let rename = "Rename"
    static let duplicate = "Duplicate"
    /// The one plain line where a result needs the engine (his rule: a plain line, never a fake result).
    static let buildNeedsEngine = "Building with joints comes with the engine update: the lattice builds without them for now."
    static func noJoint(_ seam: String) -> String { "\(seam): no joint yet" }
    static let pickOne = "Pick one"
}

// MARK: - the plan's edits (one undo step each, through the Flexible settings)

extension FlexibleMainStage {
    /// The saved plans (nil: none yet — the page shows a fresh Plan A from the app's cut).
    var printPlans: FlexiblePrintPlans? { model?.settings.printPlans }
    /// The plans as the page shows them.
    var shownPlans: FlexiblePrintPlans { printPlans ?? .fresh() }

    /// One change to the plans (made from a fresh Plan A when there are none), never a rebuild of the squish.
    func editPlans(_ change: (inout FlexiblePrintPlans) -> Void) {
        guard let m = model else { return }
        m.edit({ s in
            var p = s.printPlans ?? .fresh()
            change(&p)
            s.printPlans = p
        }, recompute: false)
    }

    /// ★ R8.1 (round 2: it comes last): the Print plan shows for two materials, or for solid areas outside the flexible lattice.
    /// Every Flexible lattice today is face prisms in a solid part, so any face set up has solid areas round it.
    static func showsPrintPlan(_ m: FlexibleStageModel?) -> Bool {
        guard let m else { return false }
        return m.settings.printPlans?.rigidMaterial != nil || !m.settings.faces.isEmpty
    }

    /// Reset (J-5): every plan, add-on and place goes; a fresh Plan A from the app's cut (the rigid plastic stays: it is the
    /// part's, not a plan's).
    func clearPlans() {
        editPlans { p in p = .fresh(rigidMaterial: p.rigidMaterial) }
        planSeam = nil
        planResetAsk = false
        planNote = nil
    }
}

// MARK: - the panel

/// The Print plan's left panel (the wide panel, U14): header · Plan · Pieces · Seams · Add-ons · Skin and rim · Reset.
struct FlexiblePrintPlanPanel: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var model: FlexibleStageModel
    /// The plans live in the project (`project.lattice.flexible`): an edit republishes the project, not always the model.
    @ObservedObject private var project: ProjectModel
    @State private var open = true
    @State private var renaming: String?

    init(main: FlexibleMainStage, model: FlexibleStageModel) {
        self.main = main; self.model = model; self._project = ObservedObject(wrappedValue: model.project)
    }

    /// ★ LOOK PER SCREEN (his ruling 11-03; the mockup's #flex-plan): the panel is the shared wide DSPanel — its header "Print
    /// plan · Plan A", sections with overlines, DSRow rows, the pinned Reset foot. It ends where the free column does.
    static let maxHeight: CGFloat = 680

    private var plans: FlexiblePrintPlans { main.shownPlans }
    private var tpuName: String { model.material?.displayName ?? "varioShore TPU" }

    var body: some View {
        DSPanel(key: "plan", title: FlexiblePrintPlanCopy.title, count: nil, width: DSParts.widePanelWidth,
                maxHeight: Self.maxHeight, open: $open) {
            planRow
            piecesSection
            seamsSection
            addOnsSection
            if plans.rigidMaterial != nil { skinRow }
        } footer: {
            foot
        }
        .overlay(alignment: .topTrailing) {
            // the header's count slot: the current plan's name ("Plan A"), as the mockup's
            Text(plans.plan.name).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.textTertiary.color)
                .padding(.trailing, 14).frame(height: DSParts.headerHeight).allowsHitTesting(false)
        }
        .background(publish("selectionsList"))   // the left panel's place: the chips and the corner keep clear of it
        .background(publish("planPanel"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-plan-panel")
    }

    // MARK: Plan ⌄ — the plans, + New plan, Rename, Duplicate (a setting row)

    private var planRow: some View {
        Group {
            if let draft = renaming {
                HStack(spacing: DS.Space.s) {
                    Text("Plan").dsStyle(DS.TypeScale.caption).fontWeight(.bold).foregroundStyle(DS.Color.textPrimary.color)
                    TextField("Plan name", text: Binding(get: { draft }, set: { renaming = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                        .onSubmit(commitRename)
                        .accessibilityIdentifier("flexible-plan-rename-field")
                    Button("Done", action: commitRename).buttonStyle(.plain).foregroundStyle(DS.Color.accent.color)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("flexible-plan-rename-done")
                }
                .frame(minHeight: 44)
            } else {
                SettingRow(key: "planMenu", id: "flexible-plan-menu", label: "Plan",
                           value: plans.plan.name + (plans.plan.built ? " \u{00B7} built" : ""), info: FlexiblePrintPlanCopy.planInfo) {
                    ForEach(plans.plans) { p in
                        Button { main.editPlans { $0.current = p.id }; main.planSeam = nil } label: {
                            if p.id == plans.current { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                    Divider()
                    Button("+ \(FlexiblePrintPlanCopy.newPlan)") {
                        main.editPlans { p in
                            let n = FlexiblePrintPlan(name: FlexiblePrintPlanRules.nextName(p.plans))
                            p.plans.append(n); p.current = n.id
                        }
                        main.planSeam = nil
                    }
                    Button(FlexiblePrintPlanCopy.rename) { renaming = plans.plan.name }
                    Button(FlexiblePrintPlanCopy.duplicate) {
                        main.editPlans { p in
                            var d = p.plan
                            d.id = UUID(); d.name = FlexiblePrintPlanRules.nextName(p.plans); d.built = false
                            p.plans.append(d); p.current = d.id
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func commitRename() {
        let name = (renaming ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty else { return }
        main.editPlans { $0.plan.name = name }
    }

    // MARK: 1 · Pieces

    @ViewBuilder private var piecesSection: some View {
        let pieces = FlexiblePrintPlanRules.pieces(plans, tpuName: tpuName)
        DSPanelSection(FlexiblePrintPlanCopy.pieces, count: pieces.count, key: "plan-pieces")
            .overlay(alignment: .trailing) {
                // ★ B9 slice 3 (round 3: six ways): + Cut ⌄ — with two materials, as the mockup's
                if plans.rigidMaterial != nil {
                    Menu {
                        ForEach(FlexibleCutWay.allCases, id: \.self) { w in
                            Button { main.startCut(w) } label: { Text(w.title); Text(w.sub) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("+ Cut")
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                        .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .menuIndicator(.hidden).menuStyle(.button).buttonStyle(.plain).fixedSize()
                    .background(publish("planCutMenu"))
                    .accessibilityIdentifier("flexible-plan-cut-menu")
                }
            }
        ForEach(pieces, id: \.key) { pc in
            DSRow(.group, key: "plan-piece-\(pc.key)", mark: .colour(pc.tpu ? DS.Color.accentGreen : RGBA(hex: 0xC7C7CC)),
                  name: pc.name, value: pc.tpu ? pc.material : nil) {
                if !pc.tpu { rigidMenu(pc) }
            }
        }
        // ★ B9 slice 3: the cuts he placed — kept, their pieces from the engine's cut; Join undoes one
        ForEach(Array((plans.plan.cuts ?? []).enumerated()), id: \.offset) { i, c in
            DSRow(.group, key: "plan-cut-\(i)", name: FlexiblePlanCutCopy.row(c),
                  line: DSRowLine(FlexiblePlanCutCopy.rowSub)) {
                Button { main.joinCut(i) } label: {
                    Text("Join").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(publish("planCutJoin-\(i)"))
                .accessibilityLabel("Join: undo this cut")
                .accessibilityIdentifier("flexible-plan-cut-join-\(i)")
            }
            .background(publish("planCutRow-\(i)"))
        }
        line(plans.rigidMaterial == nil ? FlexiblePrintPlanCopy.oneMaterial : FlexiblePrintPlanCopy.appCut)
        if plans.rigidMaterial == nil {
            Button { main.editPlans { $0.rigidMaterial = FlexiblePrintPlanRules.rigidMaterials[0] } } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text(FlexiblePrintPlanCopy.secondMaterial).font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(DS.Color.accent.color)
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(publish("planSecondMaterial"))
            .accessibilityIdentifier("flexible-plan-second-material")
        }
    }

    /// A rigid piece's plastic: "PLA · from New part ⌄" (J-2), its menu the plastics and "One material".
    private func rigidMenu(_ pc: FlexiblePlanPiece) -> some View {
        Menu {
            ForEach(FlexiblePrintPlanRules.rigidMaterials, id: \.self) { mat in
                Button { main.editPlans { $0.rigidMaterial = mat } } label: {
                    if mat == pc.material { Label(mat, systemImage: "checkmark") } else { Text(mat) }
                }
            }
            Divider()
            Button("One material (TPU)") { main.editPlans { $0.rigidMaterial = nil }; main.planSeam = nil }
        } label: {
            HStack(spacing: 6) {
                Text("\(pc.material) \u{00B7} from New part").font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Color.textSecondary.color)
            }
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .menuIndicator(.hidden).menuStyle(.button).buttonStyle(.plain).fixedSize()
        .background(publish("planRigid"))
        .accessibilityIdentifier("flexible-plan-rigid")
    }

    // MARK: 2 · Seams

    @ViewBuilder private var seamsSection: some View {
        let seams = FlexiblePrintPlanRules.seams(plans)
        if !seams.isEmpty {
            DSPanelSection(FlexiblePrintPlanCopy.seams, count: seams.count, key: "plan-seams")
            ForEach(seams, id: \.key) { s in
                let joint = plans.plan.joints[s.key]
                let open = main.planSeam == s.key
                DSRow(.group, key: "plan-seam-\(s.key)", name: s.name, selected: open,
                      tap: { main.planSeam = open ? nil : s.key }) {
                    Text(joint ?? FlexiblePrintPlanCopy.pickJoint).font(.system(size: 13, weight: joint == nil ? .semibold : .regular))
                        .foregroundStyle((joint == nil ? DS.Color.warning : DS.Color.textSecondary).color).lineLimit(1)
                        .padding(.trailing, 4).allowsHitTesting(false)
                }
                .background(publish("planSeam-\(s.key)"))
                .accessibilityIdentifier("flexible-plan-seam-\(s.key)")
                if open { seamCard(s) }
            }
        }
    }

    @ViewBuilder private func seamCard(_ s: FlexiblePlanSeam) -> some View {
        let jointName = plans.plan.joints[s.key]
        let joint = FlexiblePrintPlanRules.joint(jointName, kind: s.kind)
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(key: "planHeld-\(s.key)", id: "flexible-plan-held", label: FlexiblePrintPlanCopy.heldBy,
                       value: jointName ?? FlexiblePrintPlanCopy.pickJoint, info: FlexiblePrintPlanCopy.heldInfo(s.kind)) {
                ForEach(FlexiblePrintPlanRules.joints(s.kind), id: \.name) { j in
                    Button { main.editPlans { $0.plan.joints[s.key] = j.name; $0.plan.built = false }; main.planNote = nil } label: {
                        let t = "\(j.name) \u{00B7} \(j.what)"
                        if j.name == jointName { Label(t, systemImage: "checkmark") } else { Text(t) }
                    }
                }
            }
            if let joint {
                if s.kind == .tpuRigid {
                    HStack(spacing: DS.Space.s) {
                        Text(FlexiblePrintPlanCopy.plate).dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                            .foregroundStyle(DS.Color.textPrimary.color)
                        InfoTip(key: "planPlate-\(s.key)", text: FlexiblePrintPlanCopy.plateInfo)
                        Spacer(minLength: 0)
                        NumberField(key: "planPlate-\(s.key)", title: FlexiblePrintPlanCopy.plate,
                                    spec: FlexNumberSpec(value: plans.plan.plateMM[s.key] ?? FlexiblePrintPlanRules.defaultPlateMM, unit: "mm",
                                                         step: 0.5, range: FlexiblePrintPlanRules.plateRange, decimals: 1)) { v in
                            main.editPlans { $0.plan.plateMM[s.key] = v; $0.plan.built = false }
                        }
                    }
                    .frame(minHeight: 44)
                }
                switch joint.family {
                case .together:
                    cardLine(FlexiblePrintPlanCopy.together)
                    valueRow(FlexiblePrintPlanCopy.printOrder, FlexiblePrintPlanCopy.printOrderValue)
                case .slide: cardLine(FlexiblePrintPlanCopy.slidePlaces)
                case .flange: cardLine(FlexiblePrintPlanCopy.flange)
                case .pause: cardLine(FlexiblePrintPlanCopy.pause(joint.name))
                case .fixed, .one: EmptyView()
                }
            } else {
                cardLine(FlexiblePrintPlanCopy.pickJointLine)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        // the mockup's .card2: an inset card under its seam row
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Color.fillSubtle.color)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .accessibilityIdentifier("flexible-plan-seam-card")
    }

    // MARK: 3 · Add-ons

    @ViewBuilder private var addOnsSection: some View {
        let adds = FlexiblePrintPlanRules.addOns(plans)
        if !adds.isEmpty {
            DSPanelSection(FlexiblePrintPlanCopy.addOns, count: adds.count, key: "plan-addons")
                .overlay(alignment: .leading) {
                    InfoTip(key: "planAddOns", text: FlexiblePrintPlanCopy.addOnsInfo).padding(.leading, 112).padding(.top, 8)
                }
            ForEach(adds, id: \.key) { a in
                let on = !plans.plan.addOnsOff.contains(a.key)
                DSRow(.group, key: "plan-addon-\(a.key.replacingOccurrences(of: "/", with: "_"))", name: a.name, value: a.what) {
                    DSSwitch(isOn: on, key: "planAddOnSwitch-\(a.key)") {
                        main.editPlans { p in
                            p.plan.addOnsOff.removeAll { $0 == a.key }
                            if on { p.plan.addOnsOff.append(a.key) }
                            p.plan.built = false
                        }
                    }
                }
                .background(publish("planAddOn-\(a.key)"))
                .accessibilityIdentifier("flexible-plan-addon-\(a.key)")
            }
        }
    }

    // MARK: Skin and rim

    private var skinRow: some View {
        HStack(spacing: DS.Space.s) {
            Text(FlexiblePrintPlanCopy.skin).dsStyle(DS.TypeScale.caption).fontWeight(.bold).foregroundStyle(DS.Color.textPrimary.color)
            InfoTip(key: "planSkin", text: FlexiblePrintPlanCopy.skinInfo)
            Spacer(minLength: 0)
            FlexChips(options: [("tpu", "TPU"), ("rigid", "Rigid")], selection: plans.skinRigid ? "rigid" : "tpu",
                      id: "flexible-plan-skin", equalWidths: false) { v in main.editPlans { $0.skinRigid = v == "rigid" } }
                .fixedSize()
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 14)
    }

    // MARK: foot — Reset at the bottom-left (its confirm opens at the top middle)

    private var foot: some View {
        HStack(spacing: DS.Space.s) {
            Button { main.planResetAsk = true } label: {
                Text(FlexiblePrintPlanCopy.reset).font(.system(size: 14, weight: .bold)).foregroundStyle(DS.Color.danger.color)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(publish("planReset"))
            .accessibilityIdentifier("flexible-plan-reset")
            Text(FlexiblePrintPlanCopy.resetLine).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: parts

    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(DS.Color.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardLine(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(DS.Color.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).dsStyle(DS.TypeScale.caption).fontWeight(.bold).foregroundStyle(DS.Color.textPrimary.color)
            Spacer(minLength: DS.Space.s)
            DSValueBox(value)
        }
        .frame(minHeight: 44)
    }

    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

// MARK: - the corner's main button on the Print plan

/// ★ J-A (app-map §3.7 Corner), on the shared DSRunButton: "Build Plan A" — grey, "every seam needs a joint", with ONE fix chip
/// while a seam has no joint (U6: ≤ 5 words + the chip; the chip opens that seam). Every seam held: it asks the engine to rebuild
/// the lattice with the plan's joints — engine work (E5), so its tap says so in one plain line and the plan is never marked built.
struct FlexiblePlanBuildButton: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var model: FlexibleStageModel
    /// The plans live in the project: a joint picked republishes it (the fix chip must go at once).
    @ObservedObject private var project: ProjectModel
    let width: CGFloat

    init(main: FlexibleMainStage, model: FlexibleStageModel, width: CGFloat) {
        self.main = main; self.model = model; self._project = ObservedObject(wrappedValue: model.project); self.width = width
    }

    var body: some View {
        let plans = main.shownPlans
        let need = FlexiblePrintPlanRules.needing(plans)
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            if let first = need.first {
                // the corner's fix line (the mockup's): what blocks it, in words, above the button
                Text(FlexiblePrintPlanCopy.noJoint(first.name)).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.warning.color).lineLimit(1)
            } else if let note = main.planNote {
                Text(note).font(.system(size: 12.5)).foregroundStyle(DS.Color.textSecondary.color)
                    .multilineTextAlignment(.trailing).frame(maxWidth: width + 120, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("flexible-plan-note")
            }
            DSRunButton("Build \(plans.plan.name)", subtitle: "rebuilds the lattice with its joints",
                        state: need.isEmpty ? .ready : .blocked(words: "every seam needs a joint", fix: FlexiblePrintPlanCopy.pickOne),
                        key: "planBuild", action: { if need.isEmpty { main.planNote = FlexiblePrintPlanCopy.buildNeedsEngine } },
                        fix: need.first.map { first in { main.planSeam = first.key } })
        }
    }
}

// MARK: - the page-wide parts: Reset's confirm (top middle, over a dim)

/// The Print plan's page-wide parts: the cut layer (its plane card and bar; the camera turns with them) and Reset's
/// clear-all confirm (U13: its yes ≥ 300 pt from the Reset button), over the whole page while asked.
public struct FlexiblePrintPlanOverlays: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    let camera: OrbitCameraModel?
    public init(main: FlexibleMainStage, project: ProjectModel, camera: OrbitCameraModel?) {
        self.main = main; self.project = project; self.camera = camera
    }

    public var body: some View {
        ZStack {
            if main.page == .plan { FlexiblePlanCutLayer(main: main, project: project, camera: camera) }
            if main.page == .plan, main.planResetAsk {
                ClearAllConfirm(question: FlexiblePrintPlanCopy.resetAsk, detail: FlexiblePrintPlanCopy.resetDetail,
                                keep: { main.planResetAsk = false }, clear: { main.clearPlans() })
                    .transition(.opacity)
            }
        }
    }
}

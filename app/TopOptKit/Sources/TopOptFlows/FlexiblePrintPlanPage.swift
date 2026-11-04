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
    @State private var collapsed = false
    @State private var renaming: String?
    @State private var contentHeight: CGFloat = 0

    static let maxListHeight: CGFloat = 520

    private var plans: FlexiblePrintPlans { main.shownPlans }
    private var tpuName: String { model.material?.displayName ?? "varioShore TPU" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                Divider().overlay(DS.Color.strokeSubtle.color)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        planRow
                        piecesSection
                        seamsSection
                        addOnsSection
                        if plans.rigidMaterial != nil { skinRow }
                    }
                    .padding(.vertical, DS.Space.xs)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { contentHeight = g.size.height }
                            .onChange(of: g.size.height) { contentHeight = $0 }
                    })
                }
                .frame(height: min(Self.maxListHeight, max(contentHeight, SelectionsList.lineHeight)))
                Divider().overlay(DS.Color.strokeSubtle.color)
                foot
            }
        }
        .frame(width: collapsed ? nil : PageChrome.widePanelWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .background(publish("selectionsList"))   // the left panel's place: the chips and the corner keep clear of it
        .background(publish("planPanel"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-plan-panel")
    }

    // MARK: header — chevron, "Print plan", the plan's name

    private var header: some View {
        Button { collapsed.toggle() } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Color.textPrimary.opacity(0.7).color)
                Text(FlexiblePrintPlanCopy.title).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                    .foregroundStyle(DS.Color.textPrimary.color)
                if !collapsed { Spacer(minLength: DS.Space.s) }
                Text(plans.plan.name).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: SelectionsList.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(publish("planHeader"))
        .accessibilityLabel(collapsed ? "Print plan. Open" : "Minimise the Print plan")
        .accessibilityIdentifier("flexible-plan-header")
    }

    // MARK: Plan ⌄ — the plans, + New plan, Rename, Duplicate

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
        .padding(.horizontal, DS.Space.l)
    }

    private func commitRename() {
        let name = (renaming ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty else { return }
        main.editPlans { $0.plan.name = name }
    }

    // MARK: 1 · Pieces

    private var piecesSection: some View {
        let pieces = FlexiblePrintPlanRules.pieces(plans, tpuName: tpuName)
        return VStack(alignment: .leading, spacing: 0) {
            overline(FlexiblePrintPlanCopy.pieces, count: pieces.count)
            ForEach(pieces, id: \.key) { pc in
                HStack(spacing: DS.Space.s) {
                    RoundedRectangle(cornerRadius: 3).fill(pc.tpu ? FlexibleStageStyle.accent : DS.Color.textTertiary.color)
                        .frame(width: 12, height: 12)
                    Text(pc.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    if pc.tpu {
                        Text(pc.material).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                    } else {
                        Menu {
                            ForEach(FlexiblePrintPlanRules.rigidMaterials, id: \.self) { mat in
                                Button { main.editPlans { $0.rigidMaterial = mat } } label: {
                                    if mat == pc.material { Label(mat, systemImage: "checkmark") } else { Text(mat) }
                                }
                            }
                            Divider()
                            Button("One material (TPU)") { main.editPlans { $0.rigidMaterial = nil }; main.planSeam = nil }
                        } label: {
                            HStack(spacing: 4) {
                                Text(pc.material).font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(DS.Color.accent.color)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .menuIndicator(.hidden).menuStyle(.button).buttonStyle(.plain).fixedSize()
                        .background(publish("planRigid"))
                        .accessibilityIdentifier("flexible-plan-rigid")
                    }
                }
                .frame(minHeight: 48)
                .padding(.horizontal, DS.Space.l)
                .accessibilityIdentifier("flexible-plan-piece-\(pc.key)")
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
                .padding(.horizontal, DS.Space.l)
                .background(publish("planSecondMaterial"))
                .accessibilityIdentifier("flexible-plan-second-material")
            }
        }
    }

    // MARK: 2 · Seams

    @ViewBuilder private var seamsSection: some View {
        let seams = FlexiblePrintPlanRules.seams(plans)
        if !seams.isEmpty {
            overline(FlexiblePrintPlanCopy.seams, count: seams.count)
            ForEach(seams, id: \.key) { s in
                let joint = plans.plan.joints[s.key]
                let open = main.planSeam == s.key
                Button { main.planSeam = open ? nil : s.key } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "link").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                        Text(s.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                        Spacer(minLength: DS.Space.s)
                        Text(joint ?? FlexiblePrintPlanCopy.pickJoint).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle((joint == nil ? DS.Color.warning : DS.Color.textSecondary).color).lineLimit(1)
                    }
                    .padding(.horizontal, DS.Space.l)
                    .frame(minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(open ? DS.Color.accent.color : .clear, lineWidth: 1.5)
                        .padding(.horizontal, DS.Space.xs))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                    line(FlexiblePrintPlanCopy.together)
                    valueRow(FlexiblePrintPlanCopy.printOrder, FlexiblePrintPlanCopy.printOrderValue)
                case .slide: line(FlexiblePrintPlanCopy.slidePlaces)
                case .flange: line(FlexiblePrintPlanCopy.flange)
                case .pause: line(FlexiblePrintPlanCopy.pause(joint.name))
                case .fixed, .one: EmptyView()
                }
            } else {
                line(FlexiblePrintPlanCopy.pickJointLine)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.xs)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.fillSubtle.color).padding(.horizontal, DS.Space.s))
        .accessibilityIdentifier("flexible-plan-seam-card")
    }

    // MARK: 3 · Add-ons

    @ViewBuilder private var addOnsSection: some View {
        let adds = FlexiblePrintPlanRules.addOns(plans)
        if !adds.isEmpty {
            HStack(spacing: DS.Space.xs) {
                overline(FlexiblePrintPlanCopy.addOns, count: adds.count)
                InfoTip(key: "planAddOns", text: FlexiblePrintPlanCopy.addOnsInfo)
            }
            ForEach(adds, id: \.key) { a in
                let on = !plans.plan.addOnsOff.contains(a.key)
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "key.horizontal").font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        Text(a.what).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.s)
                    Toggle("", isOn: Binding(get: { on }, set: { v in
                        main.editPlans { p in
                            p.plan.addOnsOff.removeAll { $0 == a.key }
                            if !v { p.plan.addOnsOff.append(a.key) }
                            p.plan.built = false
                        }
                    }))
                    .labelsHidden().toggleStyle(.switch)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("flexible-plan-addon-\(a.key)")
                }
                .frame(minHeight: 48)
                .padding(.horizontal, DS.Space.l)
                .background(publish("planAddOn-\(a.key)"))
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
        .padding(.horizontal, DS.Space.l)
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
        .padding(.horizontal, DS.Space.l)
    }

    // MARK: parts

    private func overline(_ text: String, count: Int) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(text.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.6)
                .foregroundStyle(DS.Color.textTertiary.color)
            Text("\(count)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(DS.Color.textTertiary.color)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.m).padding(.bottom, DS.Space.xs)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(DS.Color.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.xs)
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).dsStyle(DS.TypeScale.caption).fontWeight(.bold).foregroundStyle(DS.Color.textPrimary.color)
            Spacer(minLength: DS.Space.s)
            Text(value).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
        }
        .frame(minHeight: 44)
    }

    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

// MARK: - the corner's main button on the Print plan

/// ★ J-A (app-map §3.7 Corner): "Build Plan A" — grey with ONE fix chip while a seam has no joint (U6: a blocked action stays
/// visible, says why in ≤ 5 words, and the chip is the one-tap fix: it opens that seam). Every seam held: it asks the engine
/// to rebuild the lattice with the plan's joints — engine work (E5), so for now its tap says so in one plain line and the plan
/// is never marked built.
struct FlexiblePlanBuildButton: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var model: FlexibleStageModel
    let width: CGFloat

    var body: some View {
        let plans = main.shownPlans
        let need = FlexiblePrintPlanRules.needing(plans)
        let blocked = !need.isEmpty
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            if let first = need.first {
                HStack(spacing: DS.Space.s) {
                    Text(FlexiblePrintPlanCopy.noJoint(first.name)).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.warning.color).lineLimit(1)
                    Button { main.planSeam = first.key } label: {
                        Text(FlexiblePrintPlanCopy.pickOne).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Color.accent.color)
                            .padding(.horizontal, DS.Space.m).frame(height: 30)
                            .background(Capsule().fill(DS.Color.accent.opacity(0.16).color))
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(FlexibleCornerPairStyle.publish("planFix"))
                    .accessibilityIdentifier("flexible-plan-fix")
                }
            } else if let note = main.planNote {
                Text(note).font(.system(size: 12.5)).foregroundStyle(DS.Color.textSecondary.color)
                    .multilineTextAlignment(.trailing).frame(maxWidth: width + 120, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("flexible-plan-note")
            }
            Button { main.planNote = FlexiblePrintPlanCopy.buildNeedsEngine } label: {
                VStack(spacing: 2) {
                    Text("Build \(plans.plan.name)").font(.system(size: 17, weight: .semibold))
                    Text(blocked ? "every seam needs a joint" : "rebuilds the lattice with its joints")
                        .font(.system(size: 12)).opacity(0.8).lineLimit(1)
                }
                .foregroundStyle(DS.Color.textPrimary.opacity(blocked ? 0.45 : 1).color)
                .frame(width: width, height: PageChrome.actionButton)
                .background(Capsule().fill((blocked ? DS.Color.fillSubtle : DS.Color.accent).color))
                .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: blocked ? 1 : 0))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(blocked)
            .background(FlexibleCornerPairStyle.publish("planBuild"))
            .accessibilityIdentifier("flexible-plan-build")
        }
    }
}

// MARK: - the page-wide parts: Reset's confirm (top middle, over a dim)

/// Reset's clear-all confirm (U13: its yes ≥ 300 pt from the Reset button), over the whole page while asked.
public struct FlexiblePrintPlanOverlays: View {
    @ObservedObject var main: FlexibleMainStage
    public init(main: FlexibleMainStage) { self.main = main }

    public var body: some View {
        if main.page == .plan, main.planResetAsk {
            ClearAllConfirm(question: FlexiblePrintPlanCopy.resetAsk, detail: FlexiblePrintPlanCopy.resetDetail,
                            keep: { main.planResetAsk = false }, clear: { main.clearPlans() })
                .transition(.opacity)
        }
    }
}

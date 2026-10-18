// FlexibleSelectionsList — the main Flexible page's Selections (task 2026-09-29-flexible-screens, round 7, batch R7-D2: his
// mockup pick 2, B1 "on the face", with his three changes). Hook H25 mounts it INSIDE #354's selections panel on this stage
// only, so #354's slot, its WorkspacePanelPlacement and its minimise rule are unchanged — there is still exactly one
// selections panel.
//
// ★ HIS WORDS (img6, 2026-10-14): "We need to figure out a fix of the selections modal. Remove regions … Remove "Keep Clear"
// at the top … Figure out a better designed way to set each face to be latticed/solid/off and have its depth/expand value.
// Currently, you have to click "all" then select "lattice" then open up the face then set a depth and expand value. This is
// waaayyyyy too much work".
//   * the header: chevron + "Selections" + the count, and nothing else (no Regions, no Keep clear, no kg | lbs, no eye, no
//     All / Some / None, no drawer, no badge); a tap minimises it to the pill "› Selections 3" (#354's own binding);
//   * one quiet line per group (44 pt): swatch, name, role glyph (a Load adds its weight, read-only), the summary
//     ("▦ 2 · 25 mm", "▦ 2 · 20–25 mm", "▦ 1 ■ 1", "■ 1 · 10 mm", "—"), a lock only when locked, and the TRASH (his answer:
//     "Main-page groups get a TRASH icon too", "Group trash should confirm deletion"); a tap = the whole group picked;
//   * ONLY the picked group opens: a tinted bar, the captions "Depth mm" / "Expand mm", an "All N" line when it has two or
//     more faces (its boxes show the common value or "mixed"), and one line per face — its state glyph, "Face 3", its (i)
//     (his change b), its depth box and its expand box (Off: "—"). A box edits AND picks its face.
//   * empty: "Tap a face on the model to start."
// The squeeze groups of the Squish page never appear here (the two lists stay separate — his 2026-10-10 reversal; squish
// names are squish only — his answer of 2026-10-14).

import SwiftUI
import TopOptDesign

public enum FlexibleSelectionsSummary {
    /// The group line's summary: what its faces are (Lattice ▦ / Solid ■) and how deep.
    @MainActor
    public static func summary(project p: ProjectModel, group g: SelectionGroup) -> String {
        var lat: [Double] = [], sol: [Double] = []
        for r in p.latticeSelectableRefs(g) {
            switch p.latticeSelectableRole(r, in: g.id) {
            case .include: lat.append(p.latticeSlabDepthMM(r, in: g.id))
            case .exclude: sol.append(p.latticeSlabDepthMM(r, in: g.id))
            case nil: break
            }
        }
        func range(_ v: [Double]) -> String {
            let lo = v.min() ?? 0, hi = v.max() ?? 0
            let a = FlexNumberSpec.format((lo * 10).rounded() / 10, decimals: 1), b = FlexNumberSpec.format((hi * 10).rounded() / 10, decimals: 1)
            return a == b ? "\(a) mm" : "\(a)–\(b) mm"
        }
        if !lat.isEmpty, !sol.isEmpty { return "▦ \(lat.count) ■ \(sol.count)" }
        if !lat.isEmpty { return "▦ \(lat.count) · \(range(lat))" }
        if !sol.isEmpty { return "■ \(sol.count) · \(range(sol))" }
        return "—"
    }

    /// One value when every face agrees (to 0.1 mm), else nil ("mixed").
    public static func common(_ v: [Double]) -> Double? {
        guard let f = v.first else { return nil }
        return v.allSatisfy { abs($0 - f) < 0.05 } ? f : nil
    }

}

/// H25: the list, in #354's panel slot.
public struct FlexibleSelectionsList: View {
    @ObservedObject var project: ProjectModel
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject private var ui: FlexibleFaceChipState
    @Binding var collapsed: Bool
    let cards: [String: LatticeFaceCard]
    let groupCards: [UUID: LatticeFaceCard]
    let cardsChanged: () -> Void

    public init(project: ProjectModel, main: FlexibleMainStage, collapsed: Binding<Bool>, cards: [String: LatticeFaceCard],
                groupCards: [UUID: LatticeFaceCard], cardsChanged: @escaping () -> Void) {
        self.project = project
        self.main = main
        self._ui = ObservedObject(wrappedValue: main.faceUI)
        self._collapsed = collapsed
        self.cards = cards
        self.groupCards = groupCards
        self.cardsChanged = cardsChanged
    }

    static let lineHeight: CGFloat = 44
    static let captionsHeight: CGFloat = 20
    static let maxListHeight: CGFloat = 420
    /// ★ R7-D3: the most the open list draws (its header, the divider, 420 pt of lines) — the face chip's second tier keeps out
    /// of the list's whole reach (FlexibleFaceChipLayout.listReach).
    static let maxDrawnHeight: CGFloat = lineHeight + 1 + maxListHeight + 4
    @State private var contentHeight: CGFloat = 0

    private var groups: [SelectionGroup] { project.selection.groups }
    private var picked: UUID? { FlexibleFacePick.validated(main.facePick, project: project).scope.groupID }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                Divider().overlay(DS.Color.strokeSubtle.color)
                if groups.isEmpty {
                    Text(FlexibleSelectionsCopy.empty)
                        .font(.system(size: 13)).foregroundStyle(DS.Color.textTertiary.color)
                        .padding(DS.Space.l)
                        .accessibilityIdentifier("flexible-sel-empty")
                } else {
                    // ★ LOOKED AT (13" portrait, the first pictures): the scroll view took all 420 pt with three short lines —
                    // a tall empty panel. It is as tall as its rows now, scrolling past 420.
                    ScrollView {
                        VStack(spacing: 0) { ForEach(groups) { g in section(g) } }
                            .padding(.vertical, DS.Space.xs)
                            .background(GeometryReader { g in
                                Color.clear.onAppear { contentHeight = g.size.height }
                                    .onChange(of: g.size.height) { contentHeight = $0 }
                            })
                    }
                    .frame(height: min(Self.maxListHeight, max(contentHeight, Self.lineHeight)))
                }
            }
        }
        .frame(width: collapsed ? nil : PageChrome.panelWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .background(GeometryReader { g in
            Color.clear
                .preference(key: FlexibleKeepOutKey.self, value: ["selectionsList": g.frame(in: .global)])
                .onAppear { main.chromeGeometry.noteSelections(g.frame(in: .global)) }
                .onChange(of: g.frame(in: .global)) { main.chromeGeometry.noteSelections($0) }
        }.allowsHitTesting(false))
        .onDisappear { main.chromeGeometry.noteSelections(nil) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-selections-list")
    }

    // MARK: the header — the chevron, "Selections", the count; nothing else

    private var header: some View {
        Button { collapsed.toggle() } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Color.textPrimary.opacity(0.7).color)
                Text("Selections").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold).foregroundStyle(DS.Color.textPrimary.color)
                if collapsed || !groups.isEmpty {
                    if !collapsed { Spacer(minLength: DS.Space.s) }
                    Text("\(groups.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textTertiary.color)
                        .accessibilityIdentifier("flexible-sel-count")
                } else if !collapsed { Spacer(minLength: 0) }
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: Self.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(publish("selHeader"))
        .accessibilityLabel(collapsed ? "Selections, \(groups.count). Open" : "Minimise Selections")
        .accessibilityIdentifier(collapsed ? "flexible-sel-pill" : "flexible-sel-header")
    }

    // MARK: one group

    @ViewBuilder private func section(_ g: SelectionGroup) -> some View {
        let isPicked = picked == g.id
        VStack(alignment: .leading, spacing: 0) {
            groupLine(g, picked: isPicked)
            if ui.deleteAsk == g.id, !ui.deleteAskInChip { deleteConfirm(g) }
            if isPicked { openRows(g) }
        }
        .background(isPicked ? DS.Color.fillSubtle.color : Color.clear)
        .overlay(alignment: .leading) {
            if isPicked { Rectangle().fill(g.color.color).frame(width: 3).padding(.vertical, 2) }
        }
    }

    private func groupLine(_ g: SelectionGroup, picked isPicked: Bool) -> some View {
        let locked = FlexibleFaceCommits.isLocked(g.id, project)
        return HStack(spacing: DS.Space.s) {
            Button { main.pickGroup(g.id, project: project) } label: {
                HStack(spacing: DS.Space.s) {
                    RoundedRectangle(cornerRadius: 3).fill(g.color.color).frame(width: 12, height: 12)
                    Text(g.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1)
                    FlexibleRoleGlyphs(project: project, group: g.id, size: 13)
                    if let w = FlexibleFaceChip.loadWeight(project, g.id, ui: ui) {
                        Text(w).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.xs)
                    FlexibleSummaryLabel(summary: FlexibleSelectionsSummary.summary(project: project, group: g))
                        .accessibilityIdentifier("flexible-sel-summary-\(g.id.uuidString)")
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textTertiary.color)
                    }
                }
                .frame(height: Self.lineHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flexible-sel-group-\(g.id.uuidString)")
            if !locked {
                Button { main.askDelete(g.id) } label: {
                    Image(systemName: "trash").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(publish("selTrash-\(g.id.uuidString)"))
                .accessibilityLabel("Delete \(g.name), here and in Topology")
                .accessibilityIdentifier("flexible-sel-trash-\(g.id.uuidString)")
            }
        }
        .padding(.leading, DS.Space.l).padding(.trailing, DS.Space.xs)
        .background(publish("selGroup-\(g.id.uuidString)"))
    }

    /// "Delete Group C here and in Topology?" [Delete] [Cancel] — his answer: the trash confirms.
    private func deleteConfirm(_ g: SelectionGroup) -> some View {
        FlexibleDeleteConfirm(name: g.name, delete: { main.confirmDelete(project: project, cardsChanged: cardsChanged) },
                              cancel: { ui.deleteAsk = nil })
            .padding(.horizontal, DS.Space.m).padding(.bottom, DS.Space.s)
    }

    // MARK: the picked group's rows

    @ViewBuilder private func openRows(_ g: SelectionGroup) -> some View {
        let refs = project.latticeSelectableRefs(g)
        let scope = FlexibleFacePick.validated(main.facePick, project: project).scope
        let locked = FlexibleFaceCommits.isLocked(g.id, project)
        HStack(spacing: Self.rowSpacing) {
            Spacer(minLength: 0)
            Text(FlexibleSelectionsCopy.depthCaption).frame(width: FlexibleSelectionsList.boxWidth, alignment: .center)
            Text(FlexibleSelectionsCopy.expandCaption).frame(width: FlexibleSelectionsList.boxWidth, alignment: .center)
            Color.clear.frame(width: 44, height: 1)
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textTertiary.color)
        .padding(.leading, Self.rowLeading).padding(.trailing, Self.rowTrailing)
        .frame(height: Self.captionsHeight)
        if refs.count >= 2 { allLine(g, refs: refs, selected: scope == .group(g.id), locked: locked) }
        ForEach(refs, id: \.key) { r in
            faceLine(g, r, selected: scope == .face(group: g.id, ref: r), locked: locked)
        }
    }

    /// ★ LOOKED AT (the first pictures: "Face 3" cut to "…", "All 2" on two lines): the face lines' columns, measured to
    /// fit the 348 pt panel — 24 in, the glyph, the name (never cut), two 80 pt boxes, the 44 pt (i), 12 out.
    static let boxWidth: CGFloat = 80
    static let rowSpacing: CGFloat = 6
    static let rowLeading: CGFloat = 24
    static let rowTrailing: CGFloat = 12

    private func allLine(_ g: SelectionGroup, refs: [LatticeSelectableRef], selected: Bool, locked: Bool) -> some View {
        let live = refs.filter { project.latticeSelectableRole($0, in: g.id) != nil }
        let depth = FlexibleSelectionsSummary.common(live.map { project.latticeSlabDepthMM($0, in: g.id) })
        let expand = FlexibleSelectionsSummary.common(live.map { project.latticeExpandMM($0) })
        return HStack(spacing: Self.rowSpacing) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                .frame(width: 18)
            Text(FlexibleSelectionsCopy.allFaces(refs.count)).font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            if live.isEmpty || locked {
                dash; dash
            } else {
                box(key: "list-gdepth-\(g.id.uuidString)", twin: "handle-gdepth-\(g.id.uuidString)", title: "Depth",
                    value: depth ?? project.latticeSlabDepthMM(g.id), mixed: depth == nil, spec: FlexibleSelectionsList.depthSpec) { v in
                    main.pickGroup(g.id, project: project)
                    var s = main.facePick
                    FlexibleFaceCommits.setDepth(v, ref: nil, group: g.id, project: project, session: &s)
                    main.facePick = s
                    cardsChanged()
                }
                box(key: "list-gexpand-\(g.id.uuidString)", twin: nil, title: "Expand", value: expand ?? 0, mixed: expand == nil,
                    spec: FlexibleSelectionsList.expandSpec, negative: true) { v in
                    main.pickGroup(g.id, project: project)
                    FlexibleFaceCommits.setExpand(v, ref: nil, group: g.id, project: project)
                    cardsChanged()
                }
            }
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.leading, Self.rowLeading).padding(.trailing, Self.rowTrailing)
        .frame(height: Self.lineHeight)
        .background(selected ? DS.Color.fillSelected.color : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { main.pickGroup(g.id, project: project) }
        .background(publish("selAll-\(g.id.uuidString)"))
        .accessibilityIdentifier("flexible-sel-all-\(g.id.uuidString)")
    }

    private func faceLine(_ g: SelectionGroup, _ r: LatticeSelectableRef, selected: Bool, locked: Bool) -> some View {
        let role = project.latticeSelectableRole(r, in: g.id)
        return HStack(spacing: Self.rowSpacing) {
            FlexibleStateGlyph(role: role).frame(width: 18)
            Text(project.latticeSelectableName(r)).font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            if role == nil || locked {
                dash; dash
            } else {
                box(key: "list-depth-\(r.key)", twin: "handle-depth-\(r.key)", title: "Depth",
                    value: project.latticeSlabDepthMM(r, in: g.id), mixed: false, spec: FlexibleSelectionsList.depthSpec) { v in
                    main.pickFace(r, group: g.id, project: project)
                    var s = main.facePick
                    FlexibleFaceCommits.setDepth(v, ref: r, group: g.id, project: project, session: &s)
                    main.facePick = s
                    cardsChanged()
                }
                box(key: "list-expand-\(r.key)", twin: "handle-expand-\(r.key)", title: "Expand",
                    value: project.latticeExpandMM(r), mixed: false, spec: FlexibleSelectionsList.expandSpec, negative: true) { v in
                    main.pickFace(r, group: g.id, project: project)
                    FlexibleFaceCommits.setExpand(v, ref: r, group: g.id, project: project)
                    cardsChanged()
                }
            }
            if role != nil {
                FlexibleInfoButton(main: main, key: "l-" + r.key, group: g.id, ref: r)
            } else {
                Color.clear.frame(width: 44, height: 1)
            }
        }
        .padding(.leading, Self.rowLeading).padding(.trailing, Self.rowTrailing)
        .frame(height: Self.lineHeight)
        .background(selected ? DS.Color.fillSelected.color : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { main.pickFace(r, group: g.id, project: project) }
        .background(publish("selFace-\(r.key)"))
        .accessibilityIdentifier("flexible-sel-face-\(r.key)")
    }

    private var dash: some View {
        Text("—").font(.system(size: 13)).foregroundStyle(DS.Color.textQuaternary.color)
            .frame(width: Self.boxWidth)
    }

    static func spec(_ base: FlexNumberSpec, _ value: Double) -> FlexNumberSpec {
        var s = base
        s.value = value
        return s
    }

    static let depthSpec = FlexNumberSpec(value: 0, unit: "mm", step: 0.5, range: LatticeSlabDepth.minMM...LatticeSlabDepth.maxMM, decimals: 1)
    static let expandSpec = FlexNumberSpec(value: 0, unit: "mm", step: 0.5, range: -50...50, decimals: 1)

    @ViewBuilder private func box(key: String, twin: String?, title: String, value: Double, mixed: Bool, spec: FlexNumberSpec,
                                  negative: Bool = false, commit: @escaping (Double) -> Void) -> some View {
        FlexNumberBox(key: key, title: title, spec: Self.spec(spec, value), padTarget: $ui.padTarget, allowsNegative: negative, twin: twin,
                      shownOverride: mixed ? FlexibleSelectionsCopy.mixed : FlexibleLatticeHandles.boxNumber(value, signed: negative),
                      compact: true, unitShown: !mixed, hitHeight: FlexNumberBox.target, onCommit: commit)
            .frame(width: Self.boxWidth)
    }

    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

// MARK: - small shared pieces (the list and the chip)

/// A face's state glyph: ▦ Lattice (violet), ■ Solid (white), ⬚ Off.
struct FlexibleStateGlyph: View {
    let role: LatticeGroupRole?
    var body: some View {
        switch role {
        case .include:
            Image(systemName: "square.grid.3x3.fill").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlexibleStageStyle.facePrismToken.color)
        case .exclude:
            Image(systemName: "square.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
        case nil:
            Image(systemName: "square.dashed").font(.system(size: 13)).foregroundStyle(DS.Color.textTertiary.color)
        }
    }
}

/// The group's role glyphs: Anchor (lock, green), Load (arrow, blue), Protect (shield, teal), Keep clear (no-sign, red).
struct FlexibleRoleGlyphs: View {
    @ObservedObject var project: ProjectModel
    let group: UUID
    let size: CGFloat

    /// The group line's role glyphs, in order (symbol, tint). ★ His ruling 2026-10-18: a group that reads "Lattice" (protected,
    /// a Lattice face) shows the lattice glyph first, its shield beside it.
    @MainActor
    static func glyphs(_ project: ProjectModel, _ group: UUID) -> [(symbol: String, tint: RGBA)] {
        let k = project.force.kind(for: group)
        var out: [(symbol: String, tint: RGBA)] = []
        if FlexibleFaceCommits.readsLattice(group, project) { out.append(("square.grid.3x3.fill", FlexibleStageStyle.facePrismToken)) }
        if k.isAnchor { out.append(("lock.fill", DS.Color.okGreen)) }
        if k.isLoad { out.append(("arrow.down", DS.Color.accent)) }
        if project.force.isProtected(group) { out.append(("shield.lefthalf.filled", FlexibleFaceChip.protectTint)) }
        if project.force.keepClearAffix(for: group) == .on { out.append(("nosign", DS.Color.clearance)) }
        return out
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.glyphs(project, group).enumerated()), id: \.offset) { _, g in
                Image(systemName: g.symbol).foregroundStyle(g.tint.color)
            }
        }
        .font(.system(size: size, weight: .semibold))
    }
}

/// The (i): it opens the face's four numbers beside itself (drawn by the on-model layer, over everything).
struct FlexibleInfoButton: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject private var ui: FlexibleFaceChipState
    let key: String
    let group: UUID
    let ref: LatticeSelectableRef
    init(main: FlexibleMainStage, key: String, group: UUID, ref: LatticeSelectableRef) {
        self.main = main; self._ui = ObservedObject(wrappedValue: main.faceUI); self.key = key; self.group = group; self.ref = ref
    }
    @State private var frame: CGRect = .zero
    var body: some View {
        let on = ui.info?.key == key
        Button {
            ui.roleOpen = nil
            ui.info = on ? nil : FlexibleFaceChipState.Info(key: key, group: group, ref: ref, anchor: frame)
        } label: {
            Image(systemName: on ? "info.circle.fill" : "info.circle").font(.system(size: 17, weight: .regular))
                .foregroundStyle((on ? DS.Color.accent : DS.Color.textSecondary).color)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear
                .preference(key: FlexibleKeepOutKey.self, value: ["info-\(key)": g.frame(in: .global)])
                .onAppear { frame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { frame = $0 }
        }.allowsHitTesting(false))
        .accessibilityLabel("\(main.model?.project.latticeSelectableName(ref) ?? "This face"): its lattice numbers")
        .accessibilityIdentifier("flexible-face-info-\(ref.key)")
    }
}

/// The trash's confirm, one line: the question and [Delete] [Cancel].
struct FlexibleDeleteConfirm: View {
    let name: String
    let delete: () -> Void
    let cancel: () -> Void
    // ★ LOOKED AT (13" portrait: "Delete Group C here and…" cut in the list, "…in Topolog…" in the chip): the question on its
    // own line, whole; [Cancel] [Delete] under it
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ★ the review of R7-D2: never fixed-size (a 50-character question widened the 348 pt list and cut every trash)
            Text(FlexibleSelectionsCopy.deleteAsk(name)).font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DS.Space.s).padding(.horizontal, DS.Space.xs)
                .accessibilityIdentifier("flexible-delete-question")
        HStack(spacing: DS.Space.s) {
            Spacer(minLength: DS.Space.xs)
            Button(action: cancel) {
                Text(FlexibleSelectionsCopy.cancel).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .padding(.horizontal, DS.Space.m).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flexible-delete-cancel")
            Button(action: delete) {
                Text(FlexibleSelectionsCopy.delete).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.m).frame(height: 36)
                    .background(Capsule().fill(DS.Color.danger.color))
                    .frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["deleteConfirm": g.frame(in: .global)]) }
                .allowsHitTesting(false))
            .accessibilityIdentifier("flexible-delete-confirm")
        }
        }
        .padding(.horizontal, DS.Space.s)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.danger.opacity(0.12).color))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-delete-ask")
    }
}

/// The group line's summary drawn with the state glyphs (▦ Lattice, ■ Solid) in place of the characters.
struct FlexibleSummaryLabel: View {
    let summary: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(summary.split(separator: " ", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, w in
                if w == "▦" { FlexibleStateGlyph(role: .include) }
                else if w == "■" { FlexibleStateGlyph(role: .exclude) }
                else { Text(String(w)) }
            }
        }
        .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
        .foregroundStyle(DS.Color.textSecondary.color).lineLimit(1).fixedSize()
    }
}

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
// ★ B9 SETUP (ledger 39, R2-Q2, N2; the reviewer's ruling 11-10 21:38Z, (C): "Flexible keeps its one list"): the picked
//   group's faces are Lattice Setup's face rows — one 48 pt row per face (its name, its depth or "No lattice · 25 mm" / "Off",
//   its eye, its (i)); a tap opens it a little: the depth becomes the NumberField (tap to type, drag; its prism's handle on
//   the part drags the same number), its own Expand line ("+ Expand mm", his Img6 icon) and "This face [Lattice │ No lattice
//   │ Off]". The eye shows or hides that face's prism and so its handle (`FlexibleMainStage.prismEye`, never saved). The
//   group's "All N" line keeps its two numbers. The list stays Topology's (his 10-14 and 10-18 rules); no Protect skin row.
// The squeeze groups of the Squish page never appear here (the two lists stay separate — his 2026-10-10 reversal; squish
// names are squish only — his answer of 2026-10-14).

import SwiftUI
import TopOptDesign

/// ★ P2 (the redesign, point 5): the shared SelectionsSummary's (#354's B2 lift of this one — the same words, the same number
/// format: FlexNumberSpec.format is FlexibleWeightUnit.number, which SelectionsSummary.format copies).
public enum FlexibleSelectionsSummary {
    /// The group line's summary: what its faces are (Lattice ▦ / Solid ■) and how deep.
    @MainActor
    public static func summary(project p: ProjectModel, group g: SelectionGroup) -> String { SelectionsSummary.summary(project: p, group: g) }

    /// One value when every face agrees (to 0.1 mm), else nil ("mixed").
    public static func common(_ v: [Double]) -> Double? { SelectionsSummary.common(v) }
}

/// H25: the list, in #354's panel slot. (★ P2: still Flexible's own view, not the shared SelectionsList — FlexibleSelectionsListTests
/// reads its header ("Selections", the pill's id) and its trash (`main.askDelete(g.id)`) from this file, so the swap is a re-pin
/// for the reviewer; its small pieces below are the shared ones.)
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

    /// ★ B9 (app-map §3.7): the main stage's left panel is the page's — the Selections on Setup, the plan's panel on the Print
    /// plan (H25's mount line is unchanged).
    public var body: some View {
        if main.page == .plan, let m = main.model {
            FlexiblePrintPlanPanel(main: main, model: m)
        } else {
            selections
        }
    }

    private var selections: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ★ U21 (DEL-CONFIRM): a trash's ask takes the header's line — the same height, so nothing moves and [Cancel] stays
            // exactly where the trash was
            if !collapsed, let id = ui.deleteAsk, !ui.deleteAskInChip, let g = groups.first(where: { $0.id == id }),
               !FlexibleConfirmInPlace.controlOldPlacement {
                FlexibleDeleteConfirm(name: g.name, delete: { main.confirmDelete(project: project, cardsChanged: cardsChanged) },
                                      oneLine: true)
                    .frame(height: DSParts.headerHeight)   // (the header's own height: nothing moves)
            } else {
                header
            }
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
        // ★ B9 LOOK (his "look per screen", §4.3 — DSPanel's outline): radius 22 open, the header's pill folded
        .background(FlexibleSettingsPanel.shape(collapsed).fill(DS.Surface.panel.color))
        .overlay(FlexibleSettingsPanel.shape(collapsed).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .clipShape(FlexibleSettingsPanel.shape(collapsed))
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
            // ★ B9 LOOK: DSPanel's header — the chevron (turned while folded), the name, the count; 48 pt
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Color.textSecondary.color)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 18)
                Text("Selections").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                if collapsed || !groups.isEmpty {
                    if !collapsed { Spacer(minLength: 8) }
                    Text("\(groups.count)").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Color.textTertiary.color)
                        .accessibilityIdentifier("flexible-sel-count")
                } else if !collapsed { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 14)
            .frame(height: DSParts.headerHeight)
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
            if ui.deleteAsk == g.id, !ui.deleteAskInChip, FlexibleConfirmInPlace.controlOldPlacement { deleteConfirm(g) }   // (red control)
            if isPicked { openRows(g) }
        }
        .background(isPicked ? DS.Color.fillSubtle.color : Color.clear)
        .overlay(alignment: .leading) {
            if isPicked { RoundedRectangle(cornerRadius: 2).fill(g.color.color).frame(width: 3).padding(.vertical, 6) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }   // §4.4: each row its line
    }

    private func groupLine(_ g: SelectionGroup, picked isPicked: Bool) -> some View {
        let locked = FlexibleFaceCommits.isLocked(g.id, project)
        return HStack(spacing: DS.Space.s) {
            Button { main.pickGroup(g.id, project: project) } label: {
                // ★ B9 LOOK (§4.4's group row, DSRow's measures): 48 pt, the 14 pt colour square, the name in 14 medium
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(g.color.color).frame(width: 14, height: 14)
                    Text(g.name).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Color.textPrimary.color)
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
                .frame(height: DSParts.rowHeight)
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
                // ★ U21 (DEL-CONFIRM, his Img13): [Cancel] takes the trash's place; the question and [Delete] go under it
                .modifier(FlexibleCancelInPlace(asking: ui.deleteAsk == g.id && !ui.deleteAskInChip, keepKey: "deleteCancel",
                                                cancel: { ui.deleteAsk = nil }))
                .background(publish("selTrash-\(g.id.uuidString)"))
                .accessibilityLabel(FlexibleSelectionsCopy.deleteAsk(g.name))   // ★ P3: the question it asks
                .accessibilityIdentifier("flexible-sel-trash-\(g.id.uuidString)")
            }
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .background(publish("selGroup-\(g.id.uuidString)"))
    }

    /// "Delete ‘Group C’ from every stage?" [Delete] — his answer: the trash confirms (★ U21: [Cancel] on the trash itself).
    private func deleteConfirm(_ g: SelectionGroup) -> some View {
        FlexibleDeleteConfirm(name: g.name, delete: { main.confirmDelete(project: project, cardsChanged: cardsChanged) })
            .padding(.horizontal, DS.Space.m).padding(.bottom, DS.Space.s)
    }

    // MARK: the picked group's rows

    @ViewBuilder private func openRows(_ g: SelectionGroup) -> some View {
        let refs = project.latticeSelectableRefs(g)
        let scope = FlexibleFacePick.validated(main.facePick, project: project).scope
        let locked = FlexibleFaceCommits.isLocked(g.id, project)
        if refs.count >= 2 { allRow(g, refs: refs, selected: scope == .group(g.id), locked: locked) }
        ForEach(refs, id: \.key) { r in
            faceRow(g, r, picked: scope == .face(group: g.id, ref: r), locked: locked)
            // ★ U21 batch I (I2): its links, live or stale (never dormant), each with a trash that asks in place
            ForEach(main.listedLinks(project, key: r.key), id: \.link.id) { e in
                FlexibleLinkRow(main: main, project: project, ui: ui, link: e.link, state: e.state, group: g.id, ref: r,
                                cardsChanged: cardsChanged)
            }
        }
    }

    /// ★ LOOKED AT (the first pictures: "Face 3" cut to "…", "All 2" on two lines): the face lines' columns, measured to
    /// fit the 348 pt panel — 24 in, the glyph, the name (never cut), two 80 pt boxes, the 44 pt (i), 12 out.
    static let boxWidth: CGFloat = 80
    static let rowSpacing: CGFloat = 6
    static let rowLeading: CGFloat = 24
    static let rowTrailing: CGFloat = 12

    /// ★ B9 Setup: the group's "All N" row — every face's depth and expand at once (their common value, or "mixed"). A tap
    /// picks the whole group; its numbers are NumberFields, the depth's twin the group handle's box on the part.
    private func allRow(_ g: SelectionGroup, refs: [LatticeSelectableRef], selected: Bool, locked: Bool) -> some View {
        let live = refs.filter { project.latticeSelectableRole($0, in: g.id) != nil }
        let depth = FlexibleSelectionsSummary.common(live.map { project.latticeSlabDepthMM($0, in: g.id) })
        let expand = FlexibleSelectionsSummary.common(live.map { project.latticeExpandMM($0) })
        let dKey = "list-gdepth-\(g.id.uuidString)", eKey = "list-gexpand-\(g.id.uuidString)"
        return DSRow(.face, key: "flexSetupAll-\(g.id.uuidString)", name: FlexibleSelectionsCopy.allFaces(refs.count),
                     value: live.isEmpty ? "\u{2014}" : nil, selected: selected, locked: locked && !live.isEmpty,
                     tap: { main.pickGroup(g.id, project: project) }) {
            if !live.isEmpty, !locked {
                number(dKey, twin: "handle-gdepth-\(g.id.uuidString)", title: "Depth", value: depth ?? project.latticeSlabDepthMM(g.id),
                       mixed: depth == nil, spec: Self.depthSpec, size: .withHandle) { v in
                    main.pickGroup(g.id, project: project)
                    var s = main.facePick
                    FlexibleFaceCommits.setDepth(v, ref: nil, group: g.id, project: project, session: &s)
                    main.facePick = s
                    cardsChanged()
                }
                number(eKey, twin: nil, title: LatticeSetupCopy.expand, value: expand ?? 0, mixed: expand == nil,
                       spec: Self.expandSpec, negative: true) { v in
                    main.pickGroup(g.id, project: project)
                    FlexibleFaceCommits.setExpand(v, ref: nil, group: g.id, project: project)
                    cardsChanged()
                }
            }
        }
        .modifier(FlexibleKeepOutBridge())
        .background(publish("selAll-\(g.id.uuidString)"))
    }

    /// ★ B9 Setup (R2-Q2, N2; Lattice Setup's face row): one face — its name, its depth or what it is ("No lattice · 25 mm",
    /// "Off"), its eye (its prism and handle on the part), its (i). A tap opens it a little: the depth becomes the NumberField
    /// (its prism's handle drags the same number), then its Expand line and "This face [Lattice │ No lattice │ Off]"; a tap on
    /// the open row closes it to the group. Locked on Topology: it reads, nothing edits.
    private func faceRow(_ g: SelectionGroup, _ r: LatticeSelectableRef, picked: Bool, locked: Bool) -> some View {
        let role = project.latticeSelectableRole(r, in: g.id)
        let depth = project.latticeSlabDepthMM(r, in: g.id)
        let mm = SelectionsSummary.format((depth * 10).rounded() / 10, decimals: 1) + " mm"
        let value = LatticeSetupCopy.faceValue(role: role, groupHasRole: project.lattice.groupRoles[g.id] != nil, skin: false, mm: mm)
        let shown = main.prismShown(r.key)
        let opens = picked && !locked
        let dKey = "list-depth-\(r.key)", eKey = "list-expand-\(r.key)"
        return VStack(alignment: .leading, spacing: 0) {
            DSRow(.face, key: "flexSetupFace-\(r.key)", name: project.latticeSelectableName(r),
                  value: opens && role != nil ? nil : value, selected: picked, locked: locked,
                  line: opens && role != nil && shown ? DSRowLine(LatticeSetupCopy.dragItsHandle) : nil,
                  tap: { picked ? main.pickGroup(g.id, project: project) : main.pickFace(r, group: g.id, project: project) }) {
                if opens, role != nil {
                    number(dKey, twin: "handle-depth-\(r.key)", title: "Depth", value: depth, mixed: false, spec: Self.depthSpec,
                           size: .withHandle) { v in
                        main.pickFace(r, group: g.id, project: project)
                        var s = main.facePick
                        FlexibleFaceCommits.setDepth(v, ref: r, group: g.id, project: project, session: &s)
                        main.facePick = s
                        cardsChanged()
                    }
                }
                // ★ N2: the eye shows or hides THIS face's prism (and so its handle); an Off face has no prism, so no eye
                if role != nil {
                    DSRowEye(hidden: !shown, key: "flexSetupFaceEye-\(r.key)") { main.togglePrismEye(r.key) }
                    FlexibleInfoButton(main: main, key: "l-" + r.key, group: g.id, ref: r)
                }
            }
            if opens, role != nil {
                // the Expand number its + handle on the part drags (his Img6: the handle's own icon beside it)
                HStack(spacing: DS.Space.s) {
                    FlexibleHandleCaption(kind: .expand).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                    Spacer(minLength: DS.Space.s)
                    number(eKey, twin: "handle-expand-\(r.key)", title: LatticeSetupCopy.expand, value: project.latticeExpandMM(r),
                           mixed: false, spec: Self.expandSpec, negative: true) { v in
                        main.pickFace(r, group: g.id, project: project)
                        FlexibleFaceCommits.setExpand(v, ref: r, group: g.id, project: project)
                        cardsChanged()
                    }
                }
                .padding(.leading, DSParts.faceIndent).padding(.trailing, 12).frame(minHeight: 44)
                .background(publish("flexSetupFaceExpand-\(r.key)"))
            }
            if opens {
                HStack(spacing: DS.Space.s) {
                    Text(LatticeSetupCopy.thisFace).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                    Spacer(minLength: DS.Space.s)
                    SegmentedGlass([.init(LatticeSelectableRole.include, LatticeSetupCopy.lattice),
                                    .init(LatticeSelectableRole.exclude, LatticeSetupCopy.noLattice),
                                    .init(LatticeSelectableRole.off, LatticeSetupCopy.off)],
                                   selection: Binding(get: { role.map(LatticeSelectableRole.init) ?? .off },
                                                      set: { FlexibleFaceCommits.setState($0, ref: r, group: g.id, project: project); cardsChanged() }),
                                   small: true)
                        .background(publish("flexSetupFaceRole-\(r.key)"))
                }
                .padding(.leading, DSParts.faceIndent).padding(.trailing, 12).frame(minHeight: 44)
            }
        }
        .modifier(FlexibleKeepOutBridge())
        .background(publish("selFace-\(r.key)"))
    }

    static func spec(_ base: FlexNumberSpec, _ value: Double) -> FlexNumberSpec {
        var s = base
        s.value = value
        return s
    }

    static let depthSpec = FlexNumberSpec(value: 0, unit: "mm", step: 0.5, range: LatticeSlabDepth.minMM...LatticeSlabDepth.maxMM, decimals: 1)
    static let expandSpec = FlexNumberSpec(value: 0, unit: "mm", step: 0.5, range: -50...50, decimals: 1)

    /// ★ B9 Setup: the list's numbers are the app's one NumberField (B2, U11). Its pad is the page's one keypad slot
    /// (`padTarget`, so one pad at a time), and it wears the accent while its twin's pad is open — the handle's box on the
    /// part names this key as its twin, as before. "mixed" when the faces differ (the pad then starts from the group's).
    @ViewBuilder private func number(_ key: String, twin: String?, title: String, value: Double, mixed: Bool, spec: FlexNumberSpec,
                                     size: NumberField.Size = .setting, negative: Bool = false,
                                     commit: @escaping (Double) -> Void) -> some View {
        let open = Binding(get: { ui.padTarget == key }, set: { v in
            if v { ui.padTarget = key } else if ui.padTarget == key { ui.padTarget = nil }
        })
        NumberField(key: key, title: title, spec: Self.spec(spec, value), size: size, allowsNegative: negative, unitShown: !mixed,
                    open: open, alsoLit: twin.map { ui.padTarget == $0 } ?? false, word: mixed ? FlexibleSelectionsCopy.mixed : nil,
                    onCommit: commit)
    }

    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

// MARK: - small shared pieces (the list and the chip)

/// A face's state glyph: ▦ Lattice (violet), ■ Solid (white), ⬚ Off. ★ P2: the shared StateGlyph (its violet is
/// FlexibleStageStyle.facePrismToken's RGBA).
struct FlexibleStateGlyph: View {
    let role: LatticeGroupRole?
    var body: some View { StateGlyph(role: role) }
}

/// The group's role glyphs: Anchor (lock, green), Load (arrow, blue), Protect (shield, teal), Keep clear (no-sign, red).
/// ★ P2: the shared RoleGlyphs; whether the group reads "Lattice" is Flexible's rule (FlexibleFaceCommits.readsLattice).
struct FlexibleRoleGlyphs: View {
    @ObservedObject var project: ProjectModel
    let group: UUID
    let size: CGFloat

    /// The group line's role glyphs, in order (symbol, tint). ★ His ruling 2026-10-18: a group that reads "Lattice" (protected,
    /// a Lattice face) shows the lattice glyph first, its shield beside it.
    @MainActor
    static func glyphs(_ project: ProjectModel, _ group: UUID) -> [(symbol: String, tint: RGBA)] {
        RoleGlyphs.glyphs(project, group, readsLattice: FlexibleFaceCommits.readsLattice(group, project))
    }

    var body: some View {
        RoleGlyphs(project: project, group: group, readsLattice: FlexibleFaceCommits.readsLattice(group, project), size: size)
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

/// The trash's confirm: the question on its own line, whole, and [Delete] under it on the LEFT (the chip); in the Selections list
/// one line in the header's place (`oneLine`). ★ U21 (DEL-CONFIRM, his Img13: "is
/// the 'cancel' button where the delete button was and the OK button somewhere else so it requires a move to confirm?"): [Cancel]
/// is on the trash itself (FlexibleCancelInPlace) — a second tap on the trash only cancels; [Delete] is a line down and to the left.
struct FlexibleDeleteConfirm: View {
    let name: String
    let delete: () -> Void
    /// ★ U21: the Selections list's ask — [Delete] then the question on ONE line, in the list header's place (the list never
    /// grows, so the trash's spot — now [Cancel] — never moves).
    var oneLine = false
    // ★ LOOKED AT (13" portrait: "Delete Group C here and…" cut in the list, "…in Topolog…" in the chip): the question on its
    // own line, whole
    var body: some View {
        if oneLine { line } else { stacked }
    }

    private var deleteButton: some View {
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

    private var line: some View {
        HStack(spacing: DS.Space.s) {
            deleteButton
            Text(FlexibleSelectionsCopy.deleteAsk(name)).font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("flexible-delete-question")
        }
        .padding(.horizontal, DS.Space.m)
        .background(DS.Color.danger.opacity(0.12).color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-delete-ask")
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ★ the review of R7-D2: never fixed-size (a 50-character question widened the 348 pt list and cut every trash)
            Text(FlexibleSelectionsCopy.deleteAsk(name)).font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DS.Space.s).padding(.horizontal, DS.Space.xs)
                .accessibilityIdentifier("flexible-delete-question")
            HStack(spacing: DS.Space.s) {
                deleteButton
                Spacer(minLength: DS.Space.xs)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.danger.opacity(0.12).color))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-delete-ask")
    }
}

/// The group line's summary drawn with the state glyphs (▦ Lattice, ■ Solid) in place of the characters. ★ P2: the shared
/// SummaryLabel.
struct FlexibleSummaryLabel: View {
    let summary: String
    var body: some View { SummaryLabel(summary: summary) }
}

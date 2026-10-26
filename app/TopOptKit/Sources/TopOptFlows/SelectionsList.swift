// SelectionsList — the quiet Selections list (B1 "on the face"): a header, one line per group, the picked group open.
//
// Lifted from #362 (claude/flexible-screens) at b472880b, app/TopOptKit/Sources/TopOptFlows/FlexibleSelectionsList.swift, as a
// neutral shared component (reviewer ruling 2026-10-24 07:30). #362 swaps its Flexible* copy for this one on its next sync of
// #354.
//
// Copied, not redesigned. What changed from the source, and only that:
//   * FlexibleSelectionsSummary → SelectionsSummary, FlexibleSelectionsList → SelectionsList, FlexibleStateGlyph → StateGlyph,
//     FlexibleRoleGlyphs → RoleGlyphs, FlexibleInfoButton → InfoButton, FlexibleDeleteConfirm → DeleteConfirm,
//     FlexibleSummaryLabel → SummaryLabel, FlexibleKeepOutKey → ChromeKeepOutKey, FlexibleCancelInPlace → CancelInPlace;
//   * what the list asked of FlexibleMainStage is parameters: the picked group, the trash's ask, pick / ask / confirm /
//     cancel, a group's lock, whether it reads "Lattice", a Load's weight line, and the frame note (the source:
//     main.facePick, main.faceUI.deleteAsk, main.pickGroup, main.askDelete, main.confirmDelete, FlexibleFaceCommits.isLocked
//     / .readsLattice, FlexibleFaceChip.loadWeight, main.chromeGeometry.noteSelections);
//   * the picked group's rows are the caller's (`rows`) — the source drew them with FlexNumberBox, FlexibleFacePick,
//     FlexibleFaceCommits.setDepth / setExpand, FlexibleLinkRow, FlexibleHandleCaption and the (i), all Flexible's; so
//     `depthSpec` / `expandSpec` / `spec` / `box` (FlexNumberSpec) are not lifted; the rows' column numbers are;
//   * InfoButton takes the face's name and the chip state (the source read them through FlexibleMainStage);
//   * the words are SelectionsCopy's (copied from FlexibleSelectionsCopy); the number format is SelectionsSummary.format
//     (copied from FlexibleWeightUnit.number, which FlexNumberSpec.format called); the lattice tint is StateGlyph.latticeTint
//     (FlexibleStageStyle.facePrismToken's RGBA — #354's own ramp mid violet, WorkspacePlaceholder.latticeRegionTint(.include));
//   * the accessibility ids take `idPrefix` (the source's "flexible" gives its ids back).
//
// ★ HIS WORDS (img6, 2026-10-14): "We need to figure out a fix of the selections modal. Remove regions … Remove "Keep Clear"
// at the top … Figure out a better designed way to set each face to be latticed/solid/off and have its depth/expand value."
//   * the header: chevron + "Selections" + the count, and nothing else; a tap minimises it to the pill "› Selections 3";
//   * one quiet line per group (44 pt): swatch, name, role glyph (a Load adds its weight, read-only), the summary
//     ("▦ 2 · 25 mm", "▦ 2 · 20–25 mm", "▦ 1 ■ 1", "■ 1 · 10 mm", "—"), a lock only when locked, and the TRASH (it confirms:
//     [Cancel] on the trash, the question with [Delete] in the header's place); a tap = the whole group picked;
//   * ONLY the picked group opens (its rows: the caller's);
//   * empty: "Tap a face on the model to start."
//
// B3 (Topology, 2026-10-24) — ADDITIONS ONLY, defaulted so the list draws as lifted: `summary` (the line's text — Topology's
// role / weight / mm instead of the lattice ▦ / ■ summary), the EYE (`isHidden` + `toggleEye`; view-only, GroupViewState) and
// the trash's question (`ask`; Topology deletes "from every stage").

import SwiftUI
import TopOptDesign

/// The list's and the chip's words (copied from FlexibleSelectionsCopy at b472880b, unchanged).
public enum SelectionsCopy {
    public static func joinLabel(_ group: String) -> String { "Add to \(group) as lattice" }
    /// ONE line of ≤ 44 characters whatever name he typed — the name stays on the group's line right above the question.
    public static func deleteAsk(_ name: String) -> String {
        let s = "Delete \(name) here and in Topology?"
        return s.count <= 44 ? s : "Delete this group here and in Topology?"
    }
    public static let delete = "Delete"
    public static let cancel = "Cancel"
    public static let mixed = "mixed"
    public static let empty = "Tap a face on the model to start."
    public static func kindWord(_ k: NewFaceKind) -> String {
        switch k {
        case .lattice: return "Lattice"
        case .anchor: return "Anchor"
        case .load: return "Load"
        case .protect: return "Protect"
        case .keepClear: return "Keep clear"
        }
    }
}

public enum SelectionsSummary {
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
            let a = format((lo * 10).rounded() / 10, decimals: 1), b = format((hi * 10).rounded() / 10, decimals: 1)
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

    /// A number with at most `decimals` places, its trailing zeros dropped ("25", "20.5"). (Copied from FlexibleWeightUnit.number.)
    public static func format(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "—" }
        let p = pow(10, Double(max(0, decimals)))
        let r = (v * p).rounded() / p
        if decimals <= 0 || abs(r - r.rounded()) < 0.5 / p { return String(Int(r.rounded())) }
        var s = String(format: "%.\(decimals)f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// ★ load scenarios (reviewer 2026-10-26 13:22): a folder of lines — its header row, the groups listed under it, and a tail
/// (lines under its groups). The list draws folders in place of the plain list when it is handed them.
public struct SelectionsFolder: Identifiable {
    public let id: UUID
    public let header: AnyView
    public let groups: [SelectionGroup]
    public let tail: AnyView?
    /// A control at the end of a group's line IN THIS FOLDER (an anchor's switch for this scenario).
    public let accessory: (SelectionGroup) -> AnyView?
    public init(id: UUID, header: AnyView, groups: [SelectionGroup], tail: AnyView? = nil,
                accessory: @escaping (SelectionGroup) -> AnyView? = { _ in nil }) {
        self.id = id; self.header = header; self.groups = groups; self.tail = tail; self.accessory = accessory
    }
}

/// ★ HOW TALL THE OPEN LIST MAY GROW (his iPad 2026-10-26: "make the Selections modal get much bigger than its maximum").
/// The workspace sets it from the screen (WorkspacePanelPlacement); a list that is not told keeps 420 pt.
private struct SelectionsListMaxHeightKey: EnvironmentKey { static let defaultValue: CGFloat = SelectionsList.maxListHeight }
extension EnvironmentValues {
    var selectionsListMaxHeight: CGFloat {
        get { self[SelectionsListMaxHeightKey.self] }
        set { self[SelectionsListMaxHeightKey.self] = newValue }
    }
}

public struct SelectionsList: View {
    @ObservedObject var project: ProjectModel
    @Binding var collapsed: Bool
    /// The picked group (its line tinted, its rows open).
    let picked: UUID?
    /// The trash's ask in the list (nil: none).
    let deleteAsk: UUID?
    let isLocked: (UUID) -> Bool
    let readsLattice: (UUID) -> Bool
    let loadWeight: (UUID) -> String?
    let pick: (UUID) -> Void
    let askDelete: (UUID) -> Void
    let confirmDelete: () -> Void
    let cancelDelete: () -> Void
    let noteFrame: (CGRect?) -> Void
    let idPrefix: String
    /// The picked group's rows, under its line.
    let rows: (SelectionGroup) -> AnyView
    let summary: ((SelectionGroup) -> String)?
    let isHidden: (UUID) -> Bool
    let toggleEye: ((UUID) -> Void)?
    let ask: ((String) -> String)?
    /// ★ Folders (nil: the plain list), a control at the end of a group's line (nil: none), and a footer PINNED under the
    /// scroll — never scrolled away — while the list is open (reviewer 2026-10-26 13:22: "+ Add a load scenario").
    var folders: [SelectionsFolder]? = nil
    var lineAccessory: (SelectionGroup) -> AnyView? = { _ in nil }
    var footer: AnyView? = nil
    /// ★ his iPad 14:13: an open/close button on each group's line; an open group shows its rows without being picked.
    /// nil: no button (the picked group alone shows its rows, as before).
    var isOpen: ((UUID) -> Bool)? = nil
    var toggleOpen: ((UUID) -> Void)? = nil
    /// ★ his ask: the list's height, set by dragging the grip under it (nil: as tall as its rows, up to the screen).
    /// No binding: no grip.
    var chosenHeight: Binding<CGFloat?>? = nil
    @Environment(\.selectionsListMaxHeight) private var maxHeight
    @State private var dragFrom: CGFloat? = nil

    public init(project: ProjectModel, collapsed: Binding<Bool>, picked: UUID?, deleteAsk: UUID?,
                isLocked: @escaping (UUID) -> Bool = { _ in false }, readsLattice: @escaping (UUID) -> Bool = { _ in false },
                loadWeight: @escaping (UUID) -> String? = { _ in nil }, pick: @escaping (UUID) -> Void,
                askDelete: @escaping (UUID) -> Void, confirmDelete: @escaping () -> Void, cancelDelete: @escaping () -> Void,
                noteFrame: @escaping (CGRect?) -> Void = { _ in }, idPrefix: String = "stage",
                rows: @escaping (SelectionGroup) -> AnyView = { _ in AnyView(EmptyView()) },
                summary: ((SelectionGroup) -> String)? = nil, isHidden: @escaping (UUID) -> Bool = { _ in false },
                toggleEye: ((UUID) -> Void)? = nil, ask: ((String) -> String)? = nil) {
        self.project = project; self._collapsed = collapsed; self.picked = picked; self.deleteAsk = deleteAsk
        self.isLocked = isLocked; self.readsLattice = readsLattice; self.loadWeight = loadWeight
        self.pick = pick; self.askDelete = askDelete; self.confirmDelete = confirmDelete; self.cancelDelete = cancelDelete
        self.noteFrame = noteFrame; self.idPrefix = idPrefix; self.rows = rows
        self.summary = summary; self.isHidden = isHidden; self.toggleEye = toggleEye; self.ask = ask
    }

    /// The same list with folders, a line accessory and a pinned footer (load scenarios on Topology).
    func scenarioHooks(folders: [SelectionsFolder]?, lineAccessory: @escaping (SelectionGroup) -> AnyView?,
                       footer: AnyView?) -> SelectionsList {
        var copy = self
        copy.folders = folders; copy.lineAccessory = lineAccessory; copy.footer = footer
        return copy
    }

    /// The same list with an open/close button per group and a resize grip (Topology, his iPad 2026-10-26).
    func openAndResize(isOpen: @escaping (UUID) -> Bool, toggleOpen: @escaping (UUID) -> Void,
                       height: Binding<CGFloat?>) -> SelectionsList {
        var copy = self
        copy.isOpen = isOpen; copy.toggleOpen = toggleOpen; copy.chosenHeight = height
        return copy
    }

    /// How far a scenario folder's groups sit in from the folder row.
    static let folderIndent: CGFloat = 20
    static let lineHeight: CGFloat = 44
    static let captionsHeight: CGFloat = 20
    static let maxListHeight: CGFloat = 420
    /// The most the open list draws (its header, the divider, 420 pt of lines) — a face chip's second tier keeps out of the
    /// list's whole reach (FaceChipLayout.listReach).
    /// (The Flexible list keeps 420 pt; Topology's taller list is kept out by its MEASURED frame, which the chip reads too.)
    static let maxDrawnHeight: CGFloat = lineHeight + 1 + maxListHeight + 4
    /// The open rows' columns, measured to fit the 348 pt panel — 24 in, the glyph, the name (never cut), two 80 pt boxes,
    /// the 44 pt (i), 12 out.
    static let boxWidth: CGFloat = 80
    static let rowSpacing: CGFloat = 6
    static let rowLeading: CGFloat = 24
    static let rowTrailing: CGFloat = 12
    @State private var contentHeight: CGFloat = 0

    private var groups: [SelectionGroup] { project.selection.groups }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // a trash's ask takes the header's line — the same height, so nothing moves and [Cancel] stays exactly where the
            // trash was
            if !collapsed, let id = deleteAsk, let g = groups.first(where: { $0.id == id }), !ConfirmInPlace.controlOldPlacement {
                DeleteConfirm(name: g.name, delete: confirmDelete, oneLine: true, idPrefix: idPrefix, ask: ask)
                    .frame(height: Self.lineHeight)
            } else {
                header
            }
            if !collapsed {
                Divider().overlay(DS.Color.strokeSubtle.color)
                if groups.isEmpty, folders == nil {
                    Text(SelectionsCopy.empty)
                        .font(.system(size: 13)).foregroundStyle(DS.Color.textTertiary.color)
                        .padding(DS.Space.l)
                        .accessibilityIdentifier("\(idPrefix)-sel-empty")
                } else {
                    // as tall as its rows, scrolling past 420 (a 420 pt scroll view with three short lines was a tall empty panel)
                    ScrollView {
                        VStack(spacing: 0) {
                            if let folders {
                                ForEach(folders) { f in
                                    f.header
                                    // ★ his iPad 14:13: the folder's contents sit tabbed in, a guide line down their edge
                                    VStack(spacing: 0) {
                                        ForEach(f.groups) { g in section(g, accessory: f.accessory) }
                                        if let t = f.tail { t }
                                    }
                                    .padding(.leading, Self.folderIndent)
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(DS.Color.strokeSubtle.color).frame(width: 1)
                                            .padding(.leading, Self.folderIndent / 2 + 6).padding(.vertical, 4)
                                    }
                                }
                            } else {
                                ForEach(groups) { g in section(g) }
                            }
                        }
                            .padding(.vertical, DS.Space.xs)
                            .background(GeometryReader { g in
                                Color.clear.onAppear { contentHeight = g.size.height }
                                    .onChange(of: g.size.height) { contentHeight = $0 }
                            })
                    }
                    .frame(height: listHeight)
                }
                if chosenHeight != nil, !groups.isEmpty { grip }
                if let footer {
                    Divider().overlay(DS.Color.strokeSubtle.color)
                    footer
                }
            }
        }
        .frame(width: collapsed ? nil : PageChrome.panelWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .background(GeometryReader { g in
            Color.clear
                .preference(key: ChromeKeepOutKey.self, value: ["selectionsList": g.frame(in: .global)])
                .onAppear { noteFrame(g.frame(in: .global)) }
                .onChange(of: g.frame(in: .global)) { noteFrame($0) }
        }.allowsHitTesting(false))
        .onDisappear { noteFrame(nil) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(idPrefix)-selections-list")
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
                        .accessibilityIdentifier("\(idPrefix)-sel-count")
                } else if !collapsed { Spacer(minLength: 0) }
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: Self.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(publish("selHeader"))
        .accessibilityLabel(collapsed ? "Selections, \(groups.count). Open" : "Minimise Selections")
        .accessibilityIdentifier(collapsed ? "\(idPrefix)-sel-pill" : "\(idPrefix)-sel-header")
    }

    // MARK: one group

    @ViewBuilder private func section(_ g: SelectionGroup, accessory: ((SelectionGroup) -> AnyView?)? = nil) -> some View {
        let isPicked = picked == g.id
        VStack(alignment: .leading, spacing: 0) {
            groupLine(g, picked: isPicked, accessory: accessory)
            if deleteAsk == g.id, ConfirmInPlace.controlOldPlacement { deleteConfirm(g) }   // (red control)
            if isPicked || isOpen?(g.id) == true { rows(g) }
        }
        .background(isPicked ? DS.Color.fillSubtle.color : Color.clear)
        .overlay(alignment: .leading) {
            if isPicked { Rectangle().fill(g.color.color).frame(width: 3).padding(.vertical, 2) }
        }
    }

    private func groupLine(_ g: SelectionGroup, picked isPicked: Bool,
                           accessory folderAccessory: ((SelectionGroup) -> AnyView?)? = nil) -> some View {
        let locked = isLocked(g.id)
        let accessory = folderAccessory.map { $0(g) } ?? lineAccessory(g)
        return HStack(spacing: DS.Space.s) {
            if let toggleOpen, let isOpen {
                let open = isOpen(g.id) || isPicked
                Button { toggleOpen(g.id) } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Color.textTertiary.color)
                        .frame(width: 22, height: Self.lineHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(publish("selOpen-\(g.id.uuidString)"))
                .accessibilityLabel(open ? "Close \(g.name)" : "Open \(g.name)")
                .accessibilityIdentifier("\(idPrefix)-sel-open-\(g.id.uuidString)")
            }
            Button { pick(g.id) } label: {
                HStack(spacing: DS.Space.s) {
                    RoundedRectangle(cornerRadius: 3).fill(g.color.color).frame(width: 12, height: 12)
                    Text(g.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1).layoutPriority(1)
                    RoleGlyphs(project: project, group: g.id, readsLattice: readsLattice(g.id), size: 13)
                    if let w = loadWeight(g.id) {
                        Text(w).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.xs)
                    // ★ his iPad 14:13: a line with its own control (an anchor's scenario switch) gives the name the room
                    if accessory == nil {
                        SummaryLabel(summary: summary?(g) ?? SelectionsSummary.summary(project: project, group: g))
                            .accessibilityIdentifier("\(idPrefix)-sel-summary-\(g.id.uuidString)")
                    }
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textTertiary.color)
                    }
                }
                .frame(height: Self.lineHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(idPrefix)-sel-group-\(g.id.uuidString)")
            if let accessory { accessory }
            if let toggleEye {
                let hidden = isHidden(g.id)
                Button { toggleEye(g.id) } label: {
                    Image(systemName: GroupViewState.eyeSymbol(hidden: hidden)).font(.system(size: 14, weight: .medium))
                        .foregroundStyle((hidden ? DS.Color.textQuaternary : DS.Color.textSecondary).color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hidden ? "Show \(g.name)" : "Hide \(g.name) (it still counts in the run)")
                .accessibilityIdentifier("\(idPrefix)-sel-eye-\(g.id.uuidString)")
            }
            if !locked {
                Button { askDelete(g.id) } label: {
                    Image(systemName: "trash").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // [Cancel] takes the trash's place; the question and [Delete] go in the header's
                .modifier(CancelInPlace(asking: deleteAsk == g.id, keepKey: "deleteCancel", idPrefix: idPrefix,
                                        cancel: cancelDelete))
                .background(publish("selTrash-\(g.id.uuidString)"))
                .accessibilityLabel(ask?(g.name) ?? "Delete \(g.name), here and in Topology")
                .accessibilityIdentifier("\(idPrefix)-sel-trash-\(g.id.uuidString)")
            }
        }
        .padding(.leading, toggleOpen == nil ? DS.Space.l : DS.Space.xs).padding(.trailing, DS.Space.xs)
        .background(publish("selGroup-\(g.id.uuidString)"))
    }

    /// "Delete Group C here and in Topology?" [Delete] — the red control's old place, under the group's line.
    private func deleteConfirm(_ g: SelectionGroup) -> some View {
        DeleteConfirm(name: g.name, delete: confirmDelete, idPrefix: idPrefix, ask: ask)
            .padding(.horizontal, DS.Space.m).padding(.bottom, DS.Space.s)
    }

    /// The grip's height for a drag: the panel grows about its centre, so twice the finger; never under two lines, never past
    /// the screen's room.
    static func resized(from: CGFloat, drag: CGFloat, max cap: CGFloat) -> CGFloat {
        Swift.min(cap, Swift.max(lineHeight * 2, from + 2 * drag))
    }

    /// The most the open list may be on a canvas this tall: PageLeftModal keeps `noteTop` above it twice (its spacer and its
    /// padding) and `edge` below it twice; then the header and the pinned footer. Never under the old 420 pt.
    static func screenMax(canvasHeight: CGFloat, footerReserve: CGFloat) -> CGFloat {
        Swift.max(maxListHeight, canvasHeight - 2 * PageChrome.noteTop - 2 * PageChrome.edge - lineHeight - 2 - footerReserve)
    }

    /// As tall as its rows, up to the screen (or to the height he dragged it to).
    private var listHeight: CGFloat {
        let cap = max(Self.lineHeight, min(chosenHeight?.wrappedValue ?? maxHeight, maxHeight))
        return min(cap, max(contentHeight, Self.lineHeight))
    }

    /// ★ his ask (14:3x): "make it resizeable" — a grip under the list; drag it down for more rows, up for fewer. The panel
    /// grows about its centre, so the height moves twice the finger and the grip stays under it.
    private var grip: some View {
        Capsule().fill(DS.Color.textTertiary.color).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity).frame(height: 22).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    let from = dragFrom ?? listHeight
                    if dragFrom == nil { dragFrom = from }
                    chosenHeight?.wrappedValue = Self.resized(from: from, drag: v.translation.height, max: maxHeight)
                }
                .onEnded { _ in dragFrom = nil })
            .background(publish("selectionsGrip"))
            .accessibilityLabel("Resize Selections")
            .accessibilityIdentifier("\(idPrefix)-sel-grip")
    }

    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: ChromeKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}

// MARK: - small shared pieces (the list and the chip)

/// A face's state glyph: ▦ Lattice (violet), ■ Solid (white), ⬚ Off.
struct StateGlyph: View {
    /// The lattice stage's face-prism violet (#354's density ramp mid violet).
    static let latticeTint = RGBA(124, 111, 214)
    let role: LatticeGroupRole?
    var body: some View {
        switch role {
        case .include:
            Image(systemName: "square.grid.3x3.fill").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.latticeTint.color)
        case .exclude:
            Image(systemName: "square.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
        case nil:
            Image(systemName: "square.dashed").font(.system(size: 13)).foregroundStyle(DS.Color.textTertiary.color)
        }
    }
}

/// The group's role glyphs: Anchor (lock, green), Load (arrow, blue), Protect (shield, teal), Keep clear (no-sign, red).
struct RoleGlyphs: View {
    @ObservedObject var project: ProjectModel
    let group: UUID
    /// The group reads "Lattice" (protected, a Lattice face): the lattice glyph first, its shield beside it.
    let readsLattice: Bool
    let size: CGFloat

    /// The group line's role glyphs, in order (symbol, tint).
    @MainActor
    static func glyphs(_ project: ProjectModel, _ group: UUID, readsLattice: Bool) -> [(symbol: String, tint: RGBA)] {
        let k = project.force.kind(for: group)
        var out: [(symbol: String, tint: RGBA)] = []
        if readsLattice { out.append(("square.grid.3x3.fill", StateGlyph.latticeTint)) }
        if k.isAnchor { out.append(("lock.fill", DS.Color.okGreen)) }
        if k.isLoad { out.append(("arrow.down", DS.Color.accent)) }
        if project.force.isProtected(group) { out.append(("shield.lefthalf.filled", FaceChip.protectTint)) }
        if project.force.keepClearAffix(for: group) == .on { out.append(("nosign", DS.Color.clearance)) }
        return out
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.glyphs(project, group, readsLattice: readsLattice).enumerated()), id: \.offset) { _, g in
                Image(systemName: g.symbol).foregroundStyle(g.tint.color)
            }
        }
        .font(.system(size: size, weight: .semibold))
    }
}

/// The (i): it opens the face's numbers beside itself (drawn by the caller's on-model layer, over everything).
struct InfoButton: View {
    @ObservedObject private var ui: FaceChipState
    let key: String
    let group: UUID
    let ref: LatticeSelectableRef
    /// The face's name, for VoiceOver.
    let name: String
    var idPrefix: String = "stage"
    init(ui: FaceChipState, key: String, group: UUID, ref: LatticeSelectableRef, name: String, idPrefix: String = "stage") {
        self._ui = ObservedObject(wrappedValue: ui); self.key = key; self.group = group; self.ref = ref; self.name = name
        self.idPrefix = idPrefix
    }
    @State private var frame: CGRect = .zero
    var body: some View {
        let on = ui.info?.key == key
        Button {
            ui.roleOpen = nil
            ui.info = on ? nil : FaceChipState.Info(key: key, group: group, ref: ref, anchor: frame)
        } label: {
            Image(systemName: on ? "info.circle.fill" : "info.circle").font(.system(size: 17, weight: .regular))
                .foregroundStyle((on ? DS.Color.accent : DS.Color.textSecondary).color)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear
                .preference(key: ChromeKeepOutKey.self, value: ["info-\(key)": g.frame(in: .global)])
                .onAppear { frame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { frame = $0 }
        }.allowsHitTesting(false))
        .accessibilityLabel("\(name): its lattice numbers")
        .accessibilityIdentifier("\(idPrefix)-face-info-\(ref.key)")
    }
}

/// The trash's confirm: the question on its own line, whole, and [Delete] under it on the LEFT (the chip); in the Selections list
/// one line in the header's place (`oneLine`). [Cancel] is on the trash itself (CancelInPlace) — a second tap on the trash only
/// cancels; [Delete] is a line down and to the left.
struct DeleteConfirm: View {
    let name: String
    let delete: () -> Void
    /// The Selections list's ask — [Delete] then the question on ONE line, in the list header's place (the list never grows,
    /// so the trash's spot — now [Cancel] — never moves).
    var oneLine = false
    var idPrefix: String = "stage"
    /// The question (B3: Topology's "from every stage"); nil: SelectionsCopy.deleteAsk.
    var ask: ((String) -> String)? = nil
    var body: some View {
        if oneLine { line } else { stacked }
    }

    private var deleteButton: some View {
        Button(action: delete) {
            Text(SelectionsCopy.delete).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, DS.Space.m).frame(height: 36)
                .background(Capsule().fill(DS.Color.danger.color))
                .frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in Color.clear.preference(key: ChromeKeepOutKey.self, value: ["deleteConfirm": g.frame(in: .global)]) }
            .allowsHitTesting(false))
        .accessibilityIdentifier("\(idPrefix)-delete-confirm")
    }

    private var line: some View {
        HStack(spacing: DS.Space.s) {
            deleteButton
            Text(ask?(name) ?? SelectionsCopy.deleteAsk(name)).font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(idPrefix)-delete-question")
        }
        .padding(.horizontal, DS.Space.m)
        .background(DS.Color.danger.opacity(0.12).color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(idPrefix)-delete-ask")
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            // never fixed-size (a 50-character question widened the 348 pt list and cut every trash)
            Text(ask?(name) ?? SelectionsCopy.deleteAsk(name)).font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DS.Space.s).padding(.horizontal, DS.Space.xs)
                .accessibilityIdentifier("\(idPrefix)-delete-question")
            HStack(spacing: DS.Space.s) {
                deleteButton
                Spacer(minLength: DS.Space.xs)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.danger.opacity(0.12).color))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(idPrefix)-delete-ask")
    }
}

/// The group line's summary drawn with the state glyphs (▦ Lattice, ■ Solid) in place of the characters.
struct SummaryLabel: View {
    let summary: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(summary.split(separator: " ", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, w in
                if w == "▦" { StateGlyph(role: .include) }
                else if w == "■" { StateGlyph(role: .exclude) }
                else { Text(String(w)) }
            }
        }
        .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
        .foregroundStyle(DS.Color.textSecondary.color).lineLimit(1).fixedSize()
    }
}

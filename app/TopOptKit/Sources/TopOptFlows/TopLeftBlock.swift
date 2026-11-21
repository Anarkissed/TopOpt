// TopLeftBlock.swift — ★ B2, U1: THE ONE TOP-LEFT BLOCK (approved design 2026-11-02, design-system §4.1; ledger notes 8,
// 16, 17, 18).
//
// Row 1, in the same place on every page: ‹ where Back goes (the part's project, or the Library) · the part's name and its
// version · material · undo · redo. Row 2, 8 pt under it, is the page's own stage row (the capsule). Results adds
// "Optimized ✓" and nothing else (note 18: no run time, no machine on the name row). The workspace and Results draw this
// one view, so it cannot drift or vanish between them (notes 16, 17).

import SwiftUI
import TopOptDesign

public struct TopLeftBlock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    let projectID: UUID
    let name: String
    let material: String
    let process: ProcessKind
    var optimized = false
    let back: () -> Void
    let rename: (() -> Void)?
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void

    public init(model: AppModel, projectID: UUID, name: String, material: String, process: ProcessKind, optimized: Bool = false,
                back: @escaping () -> Void, rename: (() -> Void)? = nil,
                canUndo: Bool, canRedo: Bool, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        self.model = model; self.library = model.library; self.projectID = projectID; self.name = name; self.material = material
        self.process = process; self.optimized = optimized; self.back = back; self.rename = rename
        self.canUndo = canUndo; self.canRedo = canRedo; self.undo = undo; self.redo = redo
    }

    /// The row's top and leading inset (the capsule sits `StageCapsuleLayout.capsuleTop` down, 8 pt under it).
    public static let top: CGFloat = DS.Space.xl3
    public static let leading: CGFloat = DS.Space.xl4
    public static let height: CGFloat = 42
    /// ★ 11-12: every tap target in the row is 44 tall (the pills are still drawn `height`).
    public static let target: CGFloat = 44
    /// ★ 11-12: how far the material's target reaches either side of its word (into the gap after "·" and the pill's end).
    static let materialReach: CGFloat = 10

    /// Where Back goes, in his words: the part's project, else the Library (note 8).
    static func backTitle(_ library: LibraryModel, folder: UUID) -> String {
        guard library.mode == .library, let part = library.index.part(containing: folder),
              let project = library.projectOf(part: part.id) else { return "Library" }
        return project.name
    }

    /// "v8 draft" for a version in his Library; nil before he groups.
    static func versionLabel(_ library: LibraryModel, folder: UUID) -> String? {
        guard library.mode == .library, let v = library.index.part(containing: folder)?.version(folderID: folder) else { return nil }
        return "v\(v.number)" + (library.isDraft(v) ? " draft" : "")
    }

    /// ★ R-a2 (U1): the room the view corner takes at the page's right — the gizmo, the gap, the projection column — and 12 pt.
    public static var viewCornerReserve: CGFloat {
        PageChrome.gizmoInset + OrientationGizmoView.standardSize + DS.Space.s + ViewProjectionPair.width + 12
    }

    public var body: some View {
        // ★ R-a2: laid out in the page's width less the view corner's room; a long name gives way first (…)
        TopLeftRowLayout(reserve: Self.viewCornerReserve) { row }
    }

    private var row: some View {
        HStack(spacing: DS.Space.m) {
            Button(action: back) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    Text(Self.backTitle(library, folder: projectID)).dsStyle(DS.TypeScale.bodyStrong).lineLimit(1)
                }
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.l)
                .frame(minWidth: 44, minHeight: Self.height)
                .background(Capsule().fill(DS.Surface.bar.color)
                    .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
                // ★ 11-12 (Touch, design-system §1: every target ≥ 44 × 44; #362's B10 census): the pill is drawn 42, as it
                // always was; its target is 44, the row's own height
                .frame(minHeight: Self.target)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(Self.backTitle(library, folder: projectID))")
            .background(CornerPairStyle.publish("backButton"))

            HStack(spacing: DS.Space.sm) {
                Button { rename?() } label: {
                    Text(name).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        // ★ 11-12: the name is a 44 × 44 target (it was the bare words, 18 tall)
                        .frame(minWidth: Self.target, minHeight: Self.target, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(rename == nil)
                .background(CornerPairStyle.publish("topLeftRename"))
                .layoutPriority(-1)   // ★ R-a2: the name gives way before anything else in the pill
                Rectangle().fill(DS.Color.textPrimary.opacity(0.15).color).frame(width: 1, height: 14)
                if let v = Self.versionLabel(library, folder: projectID) {
                    Text(v).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textPrimary.opacity(0.5).color).fixedSize()
                    Text("\u{00B7}").dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textPrimary.opacity(0.35).color)
                }
                // Tap the material to switch it: only same-category materials
                Menu {
                    ForEach(model.materials(for: process)) { opt in
                        Button(opt.name) { model.setCurrentProjectMaterial(opt.name) }
                    }
                } label: {
                    Text(material).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textPrimary.opacity(0.5).color)
                        // ★ 11-12: the material is a 44 × 44 target (it was the bare word, 15 tall and ~25 wide): 10 pt
                        // either side of the word and the row's 44 tall, published here; the pill does not grow (below)
                        .padding(.horizontal, Self.materialReach)
                        .frame(minWidth: Self.target, minHeight: Self.target)
                        .contentShape(Rectangle())
                        .background(CornerPairStyle.publish("topLeftMaterial"))
                }
                // ★ LOOK PER SCREEN (11-04, §4.1: "Carriage Arms · v7 draft · PA12"): drawn as plain words — still the menu (no
                // bordered pop-up or ⌄); Settings › Material is the design's place to change it
                .menuIndicator(.hidden).menuStyle(.button).buttonStyle(.plain)
                .fixedSize()
                .padding(.horizontal, -Self.materialReach)   // ★ 11-12: the word sits where it always sat
                if optimized {
                    Text("Optimized \u{2713}").dsStyle(DS.TypeScale.callout).foregroundStyle(DS.Color.okGreen.color).fixedSize()
                }
            }
            .padding(.horizontal, DS.Space.l)
            // ★ 11-12: the name and the material are 44 tall targets, so the row is 44; the pill is drawn 42 in it, as it
            // always was (it was 9 pt over and under 18 pt words, at least 42), and "topLeftName" is the pill as drawn
            .frame(minHeight: Self.target)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1))
                .background(CornerPairStyle.publish("topLeftName"))
                .padding(.vertical, (Self.target - Self.height) / 2))
            .layoutPriority(-1)   // ★ R-a2: … and the pill before the back pill and undo / redo

            HStack(spacing: DS.Space.xs) {
                icon("arrow.uturn.backward", label: "Undo", enabled: canUndo, key: "topLeftUndo", action: undo)
                icon("arrow.uturn.forward", label: "Redo", enabled: canRedo, key: "topLeftRedo", action: redo)
            }
        }
        .padding(.top, Self.top)
        .padding(.leading, Self.leading)
    }

    private func icon(_ system: String, label: String, enabled: Bool, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .opacity(enabled ? 1 : 0.35)
                .frame(width: 44, height: 44)
                .background(Circle().fill(DS.Surface.bar.color)
                    .overlay(Circle().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .background(CornerPairStyle.publish(key))
    }
}

/// ★ R-a2 (U1): lays its row out in the offered width less `reserve` (the view corner's room) and is exactly as wide as the
/// row then is — so a long name gives way before the row runs under the view corner, and the row still reports its own
/// trailing edge (TopClusterEdgeKey).
struct TopLeftRowLayout: Layout {
    let reserve: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let row = subviews.first else { return .zero }
        return row.sizeThatFits(ProposedViewSize(width: proposal.width.map { Swift.max(0, $0 - reserve) }, height: proposal.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// StageCapsule — "● <Stage> ⌄ | <Page> | <Page>", one way between the stages and a stage's two pages.
//
// Lifted from #362 (claude/flexible-screens) at b472880b, app/TopOptKit/Sources/TopOptFlows/FlexibleStageCapsule.swift, as a
// neutral shared component (reviewer ruling 2026-10-24 07:30). #362 swaps its Flexible* copy for this one on its next sync of
// #354.
//
// Copied, not redesigned. What changed from the source, and only that:
//   * FlexibleStageCapsule → StageCapsule; its Page `.lattice / .squish` → `.primary / .secondary`, the segments' words and the
//     stage's title and accent are parameters (the source drew "Lattice", "Squish", FlexibleStageStyle.title / .accent);
//   * the accessibility ids take `idPrefix` and the segments' words (the source's "flexible", "Lattice", "Squish" give its ids
//     and its frame keys back);
//   * the cards' fold is a closure, `fold` (the source: FlexibleMainStage.chrome.foldAll(), on the primary page only);
//   * the fix dot is a Bool, `fixDot` (the source observed FlexibleMainStage / FlexibleStageModel and read FlexibleMainStatus);
//   * FlexibleSquishLeave (the Squish page's Save & Exit check) and `squishDot(_:)` are not lifted — Flexible-only;
//   * FlexibleChromeLayout's capsule numbers are StageCapsuleLayout's (the same values); FlexibleKeepOutKey is ChromeKeepOutKey.
//
// The rules the source kept: one capsule under the project name; the menu is a native menu (‹ Topology with its anchors and
// loads, ● <Stage> ✓ where he is, Edit faces… (B5; was Surface ›), then About <Stage>…); every target is 44 pt tall, the segments drawn 36 tall inside
// it; never greyed. A 6 pt amber dot on the secondary segment while the one thing to fix lives there; a 6 pt white dot while the
// secondary page holds unsaved changes.
//
// B3 (Topology, 2026-10-24) — ADDITIONS ONLY, every one defaulted so the two-page capsule above draws and behaves exactly as
// lifted: a third page (`tertiaryTitle` / `tertiary`, Topology's Setup | Results | Smooth), `greyed` pages (T2: Results and
// Smooth stay grey until a run), an accent `noticeDot` on the secondary segment (a run landed: Results never opens by itself),
// the menu's rows as a parameter (`menuRows`, Topology's ● menu) with two more actions (`.lattice`, `.editFaces`), and the greyed
// ✂ set apart after the last page (`editFaces`, S3 amended).
//
// B4 (Lattice, 2026-10-24) — ONE MORE ADDITION, defaulted: the `.changeType` action and its `changeType` closure (the lattice
// ● menu's "Change lattice type…", which asks in place).
//
// B8 (his answer 2026-10-24) — ONE MORE ADDITION, defaulted: `hidden` pages are not drawn at all (Topology's Results and Smooth
// while the project has no results). `[]` draws every page, as before.

import SwiftUI
import TopOptDesign

/// The capsule's numbers (copied from FlexibleChromeLayout at b472880b, unchanged).
public enum StageCapsuleLayout {
    /// Under the name row.
    public static let capsuleTop: CGFloat = DS.Space.xl3 + 42 + PageChrome.gap
    public static let capsuleLeft: CGFloat = DS.Space.xl4
    public static let capsuleHeight: CGFloat = 44
    public static let capsuleMaxWidth: CGFloat = 300
    public static let segmentHeight: CGFloat = 36
    public static let segmentInset: CGFloat = 4
}

public struct StageCapsule: View {
    public enum Page: Equatable, Sendable { case primary, secondary, tertiary }
    /// B5: `.surface` is gone with the Surface stage — the menu's "Edit faces…" row is `.editFaces`.
    public enum Action: Equatable, Sendable { case topology, about, none, lattice, editFaces, changeType }
    /// One row of the ● <Stage> menu.
    public struct Item: Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String?
        public let enabled: Bool
        public let checked: Bool
        public let action: Action
        public init(id: String, title: String, detail: String?, enabled: Bool, checked: Bool, action: Action) {
            self.id = id; self.title = title; self.detail = detail; self.enabled = enabled; self.checked = checked
            self.action = action
        }
    }

    @ObservedObject var project: ProjectModel
    let title: String
    let accent: Color
    let primaryTitle: String
    let secondaryTitle: String
    let idPrefix: String
    let page: Page
    let go: (WorkspaceStage) -> Void
    let primary: () -> Void
    let secondary: () -> Void
    let about: () -> Void
    /// The secondary page has unsaved changes (its white dot).
    let modified: Bool
    /// The one thing to fix lives on the secondary page (its amber dot).
    let fixDot: Bool
    /// Folds every card of the page (a stage change, the sheet, the secondary page opening).
    let fold: (() -> Void)?
    // B3 additions (defaulted: nil / empty / false draws the lifted capsule)
    let tertiaryTitle: String?
    let tertiary: () -> Void
    let greyed: Set<Page>
    let noticeDot: Bool
    let menuRows: [Item]?
    let editFaces: (() -> Void)?
    /// B4: the lattice stage's "Change lattice type…" row (asks in place). nil ⇒ no such row acts.
    let changeType: (() -> Void)?
    /// B8: pages not drawn (no segment at all). The ✂ is not a page and always draws.
    let hidden: Set<Page>

    public init(project: ProjectModel, title: String, accent: Color, primaryTitle: String, secondaryTitle: String,
                idPrefix: String = "stage", page: Page, go: @escaping (WorkspaceStage) -> Void, primary: @escaping () -> Void = {},
                secondary: @escaping () -> Void, about: @escaping () -> Void, modified: Bool = false, fixDot: Bool = false,
                fold: (() -> Void)? = nil, tertiaryTitle: String? = nil, tertiary: @escaping () -> Void = {},
                greyed: Set<Page> = [], noticeDot: Bool = false, menuRows: [Item]? = nil, editFaces: (() -> Void)? = nil,
                changeType: (() -> Void)? = nil, hidden: Set<Page> = []) {
        self.project = project; self.title = title; self.accent = accent
        self.primaryTitle = primaryTitle; self.secondaryTitle = secondaryTitle; self.idPrefix = idPrefix
        self.page = page; self.go = go; self.primary = primary; self.secondary = secondary; self.about = about
        self.modified = modified; self.fixDot = fixDot; self.fold = fold
        self.tertiaryTitle = tertiaryTitle; self.tertiary = tertiary; self.greyed = greyed; self.noticeDot = noticeDot
        self.menuRows = menuRows; self.editFaces = editFaces; self.changeType = changeType; self.hidden = hidden
    }

    // MARK: the rules, as values

    /// The menu's rows: ‹ Topology (its anchors and loads), ● <title> ✓, Edit faces… (B5: was "Surface ›"), About <title>….
    public static func menuItems(title: String, idPrefix: String = "stage", anchors: Int, loads: Int) -> [Item] {
        func count(_ n: Int, _ w: String) -> String { n == 0 ? "no \(w)" : "\(n) \(w)\(n == 1 ? "" : "s")" }
        return [
            Item(id: "\(idPrefix)-menu-topology", title: "\u{2039} Topology", detail: "\(count(anchors, "anchor")) \u{00B7} \(count(loads, "load"))",
                 enabled: true, checked: false, action: .topology),
            Item(id: "\(idPrefix)-menu-\(idPrefix)", title: title, detail: "You are here", enabled: false, checked: true, action: .none),
            Item(id: "\(idPrefix)-menu-edit-faces", title: TopologyStageMenu.editFacesTitle,
                 detail: "cuts \u{00B7} unions \u{00B7} patterns", enabled: true, checked: false, action: .editFaces),
            Item(id: "\(idPrefix)-menu-about", title: "About \(title)\u{2026}", detail: "limits \u{00B7} delete", enabled: true, checked: false, action: .about),
        ]
    }

    /// The pages drawn, in order: primary, secondary, the tertiary when there is one, less the hidden ones.
    public static func drawnPages(hasTertiary: Bool, hidden: Set<Page>) -> [Page] {
        ([.primary, .secondary] + (hasTertiary ? [.tertiary] : [])).filter { !hidden.contains($0) }
    }

    /// The white dot on the secondary segment: the secondary page holds unsaved changes.
    public static func unsavedDot(page: Page, modified: Bool) -> Bool { page == .secondary && modified }

    /// A menu row: a stage change or the sheet folds every card first.
    @MainActor static func perform(_ a: Action, fold: (() -> Void)?, go: (WorkspaceStage) -> Void, about: () -> Void,
                                   editFaces: (() -> Void)? = nil, changeType: (() -> Void)? = nil) {
        guard a != .none else { return }
        fold?()
        switch a {
        case .topology: go(.topology)
        case .about: about()
        case .none: break
        case .lattice: go(.lattice)
        case .editFaces: editFaces?()
        case .changeType: changeType?()
        }
    }

    /// A segment: the lit one does nothing; the other changes page (the secondary page opening folds every card).
    @MainActor static func tapSegment(_ target: Page, on page: Page, fold: (() -> Void)?, primary: () -> Void, secondary: () -> Void,
                                      tertiary: () -> Void = {}, greyed: Set<Page> = []) {
        guard target != page, !greyed.contains(target) else { return }
        fold?()
        switch target {
        case .secondary: secondary()
        case .tertiary: tertiary()
        case .primary: primary()
        }
    }

    // MARK: the view

    private var pageFold: (() -> Void)? { page == .primary ? fold : nil }

    public var body: some View {
        HStack(spacing: 2) {
            menu
            Rectangle().fill(DS.Color.strokeStrong.color).frame(width: 1, height: 22)
            HStack(spacing: 0) {
                ForEach(Self.drawnPages(hasTertiary: tertiaryTitle != nil, hidden: hidden), id: \.self) { p in
                    let t = pageTitle(p)
                    segment(p, t, id: "\(idPrefix)-capsule-\(t.lowercased())")
                }
            }
            .padding(.horizontal, 0)
            .frame(height: StageCapsuleLayout.segmentHeight)
            .background(Capsule().fill(DS.Color.background.opacity(0.35).color))
            if let editFaces { scissors(editFaces) }
        }
        .padding(.horizontal, StageCapsuleLayout.segmentInset)
        .frame(height: StageCapsuleLayout.capsuleHeight)
        .background(Capsule().fill(DS.Surface.bar.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear.preference(key: ChromeKeepOutKey.self, value: ["capsule": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .frame(maxWidth: StageCapsuleLayout.capsuleMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(idPrefix)-capsule")
    }

    private var menu: some View {
        let items = menuRows ?? Self.menuItems(title: title, idPrefix: idPrefix,
                                   anchors: project.force.anchorCount(in: project.selection.groups),
                                   loads: project.force.loadCount(in: project.selection.groups))
        return Menu {
            ForEach(items, id: \.id) { item in
                if item.id == "\(idPrefix)-menu-about" { Divider() }
                Button {
                    Self.perform(item.action, fold: pageFold, go: go, about: about, editFaces: editFaces, changeType: changeType)
                } label: {
                    if item.checked {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                    if let d = item.detail { Text(d) }
                }
                .disabled(!item.enabled)
                .accessibilityIdentifier(item.id)
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary.color)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: StageCapsuleLayout.capsuleHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(CornerPairStyle.publish("capsuleMenu"))
        .accessibilityLabel("\(title): Topology, Edit faces and About \(title)")
        .accessibilityIdentifier("\(idPrefix)-capsule-menu")
    }

    @ViewBuilder private var dots: some View {
        HStack(spacing: 3) {
            if noticeDot {
                Circle().fill(DS.Color.accent.color).frame(width: 6, height: 6)
                    .accessibilityLabel("New results on the \(secondaryTitle) page")
                    .accessibilityIdentifier("\(idPrefix)-capsule-notice-dot")
            }
            if fixDot {
                Circle().fill(DS.Color.warning.color).frame(width: 6, height: 6)
                    .accessibilityLabel("A fix waits on the \(secondaryTitle) page")
                    .accessibilityIdentifier("\(idPrefix)-capsule-fix-dot")
            }
            if Self.unsavedDot(page: page, modified: modified) {
                Circle().fill(DS.Color.textPrimary.color).frame(width: 6, height: 6)
                    .accessibilityLabel("Unsaved changes")
                    .accessibilityIdentifier("\(idPrefix)-capsule-unsaved-dot")
            }
        }
        .allowsHitTesting(false)
    }

    private func pageTitle(_ p: Page) -> String {
        switch p {
        case .primary: return primaryTitle
        case .secondary: return secondaryTitle
        case .tertiary: return tertiaryTitle ?? ""
        }
    }

    private func segment(_ target: Page, _ title: String, id: String) -> some View {
        let lit = page == target
        let grey = greyed.contains(target)
        return Button {
            Self.tapSegment(target, on: page, fold: pageFold, primary: primary, secondary: secondary, tertiary: tertiary,
                            greyed: greyed)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle((grey ? DS.Color.textDisabled : lit ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                .padding(.horizontal, DS.Space.m)
                .frame(minWidth: 44)
                .frame(height: StageCapsuleLayout.segmentHeight)
                .background(Capsule().fill(lit ? DS.Color.accentDeep.color : Color.clear)
                    .overlay(Capsule().strokeBorder(lit ? DS.Color.accentDeepEdge.color : Color.clear, lineWidth: 1)))
                .overlay(alignment: .topTrailing) {
                    if target == .secondary { dots.offset(x: -5, y: 6) }
                }
                .frame(height: StageCapsuleLayout.capsuleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(grey)
        .background(CornerPairStyle.publish("capsule" + title))
        .accessibilityAddTraits(lit ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// The greyed ✂ set apart after the last page by a thin divider: Edit faces (S3 amended). Greyed in LOOK only — it always
    /// opens.
    private func scissors(_ action: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Rectangle().fill(DS.Color.strokeStrong.color).frame(width: 1, height: 22)
            Button {
                fold?()
                action()
            } label: {
                Image(systemName: "scissors")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .opacity(0.55)
                    .frame(width: 44, height: StageCapsuleLayout.capsuleHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(CornerPairStyle.publish("capsuleScissors"))
            .accessibilityLabel("Edit faces")
            .accessibilityIdentifier("\(idPrefix)-capsule-edit-faces")
        }
    }
}

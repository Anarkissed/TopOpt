// FlexibleStageCapsule — "● Flexible ⌄ | Lattice | Squish", the ONE way between the stages and the Flexible pages (task
// 2026-09-29-flexible-screens, round 7, batch R7-D1: his pick 1, A2's capsule).
//
// His words (2026-10-14, img5): "We also really need to clean up the menu at the top. Having Setting/Topology/Flexible/
// Surfaces all in different places, feels like it wasn't pre-planned. Please take time to reconsider how to design the
// entire screen to make it simple - with expanding areas to show more options". His pick: "I like A2 but with the corner
// pair from A1 on the main Lattice screen … Otherwise, everything from A2 is great!" — and "The Settings page is renamed
// 'Squish': [Lattice | Squish] under ● Flexible."
//
// ★ ONE CAPSULE under the project name, on BOTH Flexible pages (H27 mounts it on the main page with #354's own
// StageNavPlacement; FlexibleStagePage draws it on the Squish page at the same place):
//   * "● Flexible ⌄" — a native menu (press, slide and release picks on the iPad): ‹ Topology (its anchors and loads),
//     ● Flexible ✓ (where he is), Surface › (cuts · unions · patterns), then About Flexible… (limits · delete — the sheet
//     whose delete keeps its own two taps). Topology keeps today's screen; so does Surface.
//   * [Lattice | Squish] — the two pages, his two separate lists (never merged: r6 tasks): the main page's lattice
//     selection, and the Squish page (today's Settings). A 6 pt amber dot on Squish while the one thing to fix lives there;
//     a 6 pt white dot while the Squish page holds unsaved changes.
// ★ ON THE SQUISH PAGE every way out runs Save & Exit's own check first (FlexibleSquishLeave): a blocked readiness never
// leaves; it opens the fix.
// Every target is 44 pt tall (his rule); the segments are drawn 36 tall inside it. Never greyed.

import SwiftUI
import TopOptDesign

public struct FlexibleStageCapsule: View {
    public enum Page: Equatable, Sendable { case lattice, squish }
    public enum Action: Equatable, Sendable { case topology, surface, about, none }
    /// One row of the ● Flexible menu.
    public struct Item: Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String?
        public let enabled: Bool
        public let checked: Bool
        public let action: Action
    }

    /// The main stage (the main page: its cards fold on a hop; its model's fix dot) — nil on the Squish page.
    let main: FlexibleMainStage?
    /// The Squish page's model (its fix dot) when there is no main stage at hand.
    let squishModel: FlexibleStageModel?
    @ObservedObject var project: ProjectModel
    let page: Page
    let go: (WorkspaceStage) -> Void
    let lattice: () -> Void
    let squish: () -> Void
    let about: () -> Void
    /// The Squish page has unsaved changes (its white dot).
    let modified: Bool

    public init(main: FlexibleMainStage?, model: FlexibleStageModel? = nil, project: ProjectModel, page: Page,
                go: @escaping (WorkspaceStage) -> Void, lattice: @escaping () -> Void = {}, squish: @escaping () -> Void,
                about: @escaping () -> Void, modified: Bool = false) {
        self.main = main; self.squishModel = model; self.project = project; self.page = page; self.go = go
        self.lattice = lattice; self.squish = squish; self.about = about; self.modified = modified
    }

    // MARK: the rules, as values

    /// The menu's rows: ‹ Topology (its anchors and loads), ● Flexible ✓, Surface ›, About Flexible….
    public static func menuItems(anchors: Int, loads: Int) -> [Item] {
        func count(_ n: Int, _ w: String) -> String { n == 0 ? "no \(w)" : "\(n) \(w)\(n == 1 ? "" : "s")" }
        return [
            Item(id: "flexible-menu-topology", title: "\u{2039} Topology", detail: "\(count(anchors, "anchor")) \u{00B7} \(count(loads, "load"))",
                 enabled: true, checked: false, action: .topology),
            Item(id: "flexible-menu-flexible", title: FlexibleStageStyle.title, detail: "You are here", enabled: false, checked: true, action: .none),
            Item(id: "flexible-menu-surface", title: "Surface \u{203A}", detail: "cuts \u{00B7} unions \u{00B7} patterns", enabled: true, checked: false,
                 action: .surface),
            Item(id: "flexible-menu-about", title: "About Flexible\u{2026}", detail: "limits \u{00B7} delete", enabled: true, checked: false, action: .about),
        ]
    }

    /// The amber dot on Squish: the one thing to fix lives on the Squish page (a fix tone WITH its issue).
    public static func squishDot(_ s: FlexibleMainStatus) -> Bool { s.tone == .fix && s.fix != nil }
    /// The white dot on Squish: the Squish page holds unsaved changes.
    public static func unsavedDot(page: Page, modified: Bool) -> Bool { page == .squish && modified }

    /// A menu row: a stage change or the sheet folds every card on the main page first.
    @MainActor static func perform(_ a: Action, chrome: FlexibleChromeState?, go: (WorkspaceStage) -> Void, about: () -> Void) {
        guard a != .none else { return }
        chrome?.foldAll()
        switch a {
        case .topology: go(.topology)
        case .surface: go(.surface)
        case .about: about()
        case .none: break
        }
    }

    /// A segment: the lit one does nothing; the other changes page (the Squish page opening folds every card).
    @MainActor static func tapSegment(_ target: Page, on page: Page, chrome: FlexibleChromeState?, lattice: () -> Void, squish: () -> Void) {
        guard target != page else { return }
        chrome?.foldAll()
        if target == .squish { squish() } else { lattice() }
    }

    // MARK: the view

    private var chrome: FlexibleChromeState? { page == .lattice ? main?.chrome : nil }

    public var body: some View {
        HStack(spacing: 2) {
            menu
            Rectangle().fill(DS.Color.strokeStrong.color).frame(width: 1, height: 22)
            HStack(spacing: 0) {
                segment(.lattice, "Lattice", id: "flexible-capsule-lattice")
                segment(.squish, "Squish", id: "flexible-capsule-squish")
            }
            .padding(.horizontal, 0)
            .frame(height: FlexibleChromeLayout.segmentHeight)
            .background(Capsule().fill(DS.Color.background.opacity(0.35).color))
        }
        .padding(.horizontal, FlexibleChromeLayout.segmentInset)
        .frame(height: FlexibleChromeLayout.capsuleHeight)
        .background(Capsule().fill(DS.Surface.bar.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["capsule": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .frame(maxWidth: FlexibleChromeLayout.capsuleMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-capsule")
    }

    private var menu: some View {
        let items = Self.menuItems(anchors: project.force.anchorCount(in: project.selection.groups),
                                   loads: project.force.loadCount(in: project.selection.groups))
        return Menu {
            ForEach(items, id: \.id) { item in
                if item.id == "flexible-menu-about" { Divider() }
                Button {
                    Self.perform(item.action, chrome: chrome, go: go, about: about)
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
                Circle().fill(FlexibleStageStyle.accent).frame(width: 8, height: 8)
                Text(FlexibleStageStyle.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlexibleStageStyle.accent)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary.color)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: FlexibleChromeLayout.capsuleHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(FlexibleCornerPairStyle.publish("capsuleMenu"))
        .accessibilityLabel("Flexible: Topology, Surface and About Flexible")
        .accessibilityIdentifier("flexible-capsule-menu")
    }

    @ViewBuilder private var dots: some View {
        HStack(spacing: 3) {
            if let main { FlexibleCapsuleMainDot(main: main) } else if let m = squishModel { FlexibleCapsuleFixDot(model: m) }
            if Self.unsavedDot(page: page, modified: modified) {
                Circle().fill(DS.Color.textPrimary.color).frame(width: 6, height: 6)
                    .accessibilityLabel("Unsaved changes")
                    .accessibilityIdentifier("flexible-capsule-unsaved-dot")
            }
        }
        .allowsHitTesting(false)
    }

    private func segment(_ target: Page, _ title: String, id: String) -> some View {
        let lit = page == target
        return Button {
            Self.tapSegment(target, on: page, chrome: chrome, lattice: lattice, squish: squish)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle((lit ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                .padding(.horizontal, DS.Space.m)
                .frame(minWidth: 44)
                .frame(height: FlexibleChromeLayout.segmentHeight)
                .background(Capsule().fill(lit ? DS.Color.accentDeep.color : Color.clear)
                    .overlay(Capsule().strokeBorder(lit ? DS.Color.accentDeepEdge.color : Color.clear, lineWidth: 1)))
                .overlay(alignment: .topTrailing) {
                    if target == .squish { dots.offset(x: -5, y: 6) }
                }
                .frame(height: FlexibleChromeLayout.capsuleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(FlexibleCornerPairStyle.publish(target == .lattice ? "capsuleLattice" : "capsuleSquish"))
        .accessibilityAddTraits(lit ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// The main page's fix dot: it waits for the stage's model, then observes it (the capsule redraws only the dot).
private struct FlexibleCapsuleMainDot: View {
    @ObservedObject var main: FlexibleMainStage
    var body: some View {
        if let m = main.model { FlexibleCapsuleFixDot(model: m) }
    }
}

private struct FlexibleCapsuleFixDot: View {
    @ObservedObject var model: FlexibleStageModel
    var body: some View {
        if FlexibleStageCapsule.squishDot(FlexibleMainStatus.of(model: model)) {
            Circle().fill(DS.Color.warning.color).frame(width: 6, height: 6)
                .accessibilityLabel("A fix waits on the Squish page")
                .accessibilityIdentifier("flexible-capsule-fix-dot")
        }
    }
}

/// The Squish page's way out, as a value (FlexibleStagePage.leave(then:) runs it): Save & Exit's own check first —
/// `.exit` saves (or leaves unchanged), calls onExit, then the follow-up (the menu's Topology / Surface); `.fix` opens the
/// fix and never leaves.
public enum FlexibleSquishLeave {
    public enum Outcome: Equatable { case left(saved: Bool), fix(FlexibleIssue) }
    /// Test control only: a hop that skips the check (leaves while blocked).
    @MainActor static var controlSkipsDecide = false

    @MainActor static func run(_ r: FlexibleReadiness, modified: Bool, empty: Bool, save: () -> Void, exitUnchanged: () -> Void,
                               onExit: () -> Void, present: (FlexibleIssue) -> Void, then: (() -> Void)?) -> Outcome {
        let decision: FlexibleExitDecision = controlSkipsDecide ? .exit : FlexibleSettingsExit.decide(r, modified: modified, empty: empty)
        switch decision {
        case .exit:
            if modified { save() } else { exitUnchanged() }
            onExit()
            then?()
            return .left(saved: modified)
        case .fix(let issue):
            present(issue)
            return .fix(issue)
        }
    }
}

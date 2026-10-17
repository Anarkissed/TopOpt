// FlexibleStageCapsule — STUB (R7-D1 tests first). Replaced in the code commit.

import SwiftUI
import TopOptDesign

public struct FlexibleStageCapsule: View {
    public enum Page: Equatable, Sendable { case lattice, squish }
    public enum Action: Equatable, Sendable { case topology, surface, about, none }
    public struct Item: Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String?
        public let enabled: Bool
        public let checked: Bool
        public let action: Action
    }

    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    let page: Page
    let go: (WorkspaceStage) -> Void
    let lattice: () -> Void
    let squish: () -> Void
    let about: () -> Void
    let modified: Bool

    public init(main: FlexibleMainStage, project: ProjectModel, page: Page, go: @escaping (WorkspaceStage) -> Void,
                lattice: @escaping () -> Void = {}, squish: @escaping () -> Void, about: @escaping () -> Void, modified: Bool = false) {
        self.main = main; self.project = project; self.page = page; self.go = go
        self.lattice = lattice; self.squish = squish; self.about = about; self.modified = modified
    }

    public static func menuItems(anchors: Int, loads: Int) -> [Item] { [] }
    public static func squishDot(_ s: FlexibleMainStatus) -> Bool { false }
    public static func unsavedDot(page: Page, modified: Bool) -> Bool { false }
    /// What a menu row does.
    @MainActor static func perform(_ a: Action, chrome: FlexibleChromeState?, go: (WorkspaceStage) -> Void, about: () -> Void) {}
    /// What a segment does.
    @MainActor static func tapSegment(_ target: Page, on page: Page, chrome: FlexibleChromeState?, lattice: () -> Void, squish: () -> Void) {}

    public var body: some View { EmptyView() }
}

/// The Squish page's way out — STUB.
public enum FlexibleSquishLeave {
    public enum Outcome: Equatable { case left(saved: Bool), fix(FlexibleIssue) }
    @MainActor static var controlSkipsDecide = false
    @MainActor static func run(_ r: FlexibleReadiness, modified: Bool, empty: Bool, save: () -> Void, exitUnchanged: () -> Void,
                               onExit: () -> Void, present: (FlexibleIssue) -> Void, then: (() -> Void)?) -> Outcome {
        .left(saved: false)
    }
}

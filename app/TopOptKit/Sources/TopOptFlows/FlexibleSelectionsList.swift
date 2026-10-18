// FlexibleSelectionsList — STUB (round 7, batch R7-D2: tests first).
import SwiftUI
import TopOptDesign

public enum FlexibleSelectionsSummary {
    @MainActor
    public static func summary(project p: ProjectModel, group g: SelectionGroup) -> String { "" }
    public static func common(_ v: [Double]) -> Double? { nil }
}

public struct FlexibleSelectionsList: View {
    static let lineHeight: CGFloat = 0
    public init(project: ProjectModel, main: FlexibleMainStage, collapsed: Binding<Bool>, cards: [String: LatticeFaceCard],
                groupCards: [UUID: LatticeFaceCard], cardsChanged: @escaping () -> Void) {}
    public var body: some View { EmptyView() }
}

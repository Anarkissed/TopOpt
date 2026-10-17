// FlexibleCornerPair — STUB (R7-D1 tests first).

import SwiftUI
import TopOptDesign

public struct FlexibleCornerPair: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    let app: AppModel
    let openSquish: () -> Void
    let changeGravity: () -> Void

    public init(main: FlexibleMainStage, project: ProjectModel, app: AppModel, openSquish: @escaping () -> Void,
                changeGravity: @escaping () -> Void) {
        self.main = main; self.project = project; self.app = app; self.openSquish = openSquish; self.changeGravity = changeGravity
    }

    /// Test control only: the panels placed IN layout (the bar would measure them).
    @MainActor static var controlPanelInLayout = false

    public var body: some View { EmptyView() }
}

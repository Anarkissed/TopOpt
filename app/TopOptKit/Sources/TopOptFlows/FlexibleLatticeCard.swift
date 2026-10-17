// FlexibleLatticeCard — STUB (R7-D1 tests first).

import SwiftUI
import TopOptDesign

public enum FlexibleLatticeCard {
    public enum Marker: Equatable, Sendable { case done, current, blocked, future }
    public struct Step: Equatable, Sendable {
        public let id: String
        public let title: String
        public let marker: Marker
        public let line: String?
    }
    @MainActor static func steps(state: FlexibleLatticeButton.State, status: FlexibleMainStatus, run: FlexibleCoreRun, preview: String) -> [Step] { [] }
    @MainActor static func coreSends(state: FlexibleLatticeButton.State, status: FlexibleMainStatus, run: FlexibleCoreRun) -> [FlexibleCoreFix] { [] }
    @MainActor static func exportsDisabled(run: FlexibleCoreRun) -> Bool { false }
    @MainActor static var controlDropsHoldNote = false
}

/// The card's view — STUB.
struct FlexibleLatticeCardView: View {
    @ObservedObject var run: FlexibleCoreRun
    let status: FlexibleMainStatus
    let state: FlexibleLatticeButton.State
    let preview: String
    var width: CGFloat = 420
    var maxHeight: CGFloat = 800
    var close: () -> Void = {}
    var send: () -> Void = {}
    var showFix: () -> Void = {}
    var body: some View { EmptyView() }
}

// FlexibleLatticeButton — STUB (R7-D1 tests first).

import SwiftUI
import TopOptDesign

public enum FlexibleLatticeButton {
    public enum State: String, CaseIterable, Sendable { case opening, fix, building, viewOff, preview, ready, sending, sent, refused, exports, blocked, idle }
    public enum MainAction: Equatable, Sendable { case note(FlexibleMainNote.Kind), callout, showLattice, card, sendAndCard, openSquish, none }
    public struct Hooks {
        let send: () -> Void
        let showCard: () -> Void
        let showLattice: () -> Void
        let note: (FlexibleMainNote.Kind) -> Void
        let openSquish: () -> Void
        let callout: () -> Void
    }
    public static let title = ""
    public static func state(_ s: FlexibleMainStatus, phase: FlexibleCoreRun.Phase, answerIsCurrent: Bool) -> State { .idle }
    public static func line(_ s: FlexibleMainStatus, state: State, runLine: String) -> String { "" }
    public static func action(_ st: State) -> MainAction { .none }
    @MainActor static func perform(_ a: MainAction, chrome: FlexibleChromeState, hooks: Hooks) {}
    @MainActor static func caret(chrome: FlexibleChromeState, hooks: Hooks) {}
}

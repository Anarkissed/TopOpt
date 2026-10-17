// FlexibleBlockerCallout — STUB (R7-D1 tests first).

import SwiftUI
import TopOptDesign

public struct FlexibleCalloutRule: Equatable, Sendable {
    public private(set) var seen: Set<String> = []
    var controlEveryRecompute = false
    public init() {}
    public mutating func next(_ s: FlexibleMainStatus) -> FlexibleIssue? { nil }
}

public enum FlexibleBlockerCallout {
    public enum Button: Equatable, Sendable { case apply(FlexibleFix), squish }
    public static let squishTitle = ""
    static func buttons(_ issue: FlexibleIssue, pressNeedsWeight: (Int) -> Bool) -> [Button] { [] }
    static func goToSquish(openFix: () -> Void, openSquish: () -> Void) {}
}

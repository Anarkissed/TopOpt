// FlexibleFaceStatsPopover — STUB (round 7, batch R7-D2: tests first).
import SwiftUI
import TopOptDesign

public enum FlexibleFaceStats {
    public struct Rows: Equatable, Sendable {
        public let rows: [LatticeDrawerRow]
        public let note: String?
    }
    public static func rows(card: LatticeFaceCard?, depthMM: Double, held: Bool, reaches: Bool = true) -> Rows? { nil }
    public static func card(_ ref: LatticeSelectableRef, group: UUID, cards: [String: LatticeFaceCard],
                            groupCards: [UUID: LatticeFaceCard]) -> LatticeFaceCard? { nil }
}

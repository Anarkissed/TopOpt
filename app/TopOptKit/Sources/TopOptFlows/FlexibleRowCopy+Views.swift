// FlexibleRowCopy+Views — the words of round 7's views (batch R7-V): one line each, ≤ 44 characters (his rule). In
// their own file so the Settings batch's copy (R7-S) never meets them.

import Foundation

extension FlexibleRowCopy {
    /// ★ R7-V: an edges/corners group has no stacks until core builds press stacks (AP9) — nothing to bend or heat yet.
    public static let noBendYet = "No bend yet · core support pending"
    public static let noHeatYet = "No heat yet · core support pending"
    /// The Heat icon's spoken value (his tap: the current group; his 3 s hold: every group).
    public static let heatGroup = "This group"
    public static let heatAll = "Every group"
    public static let heatHint = "Tap: this group's heat, or hide it. Hold 3 seconds: every group's."
}

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
    /// ★ R7-V review: the Play icon's spoken status while its bar is hidden (the ring / the dot are what he sees).
    public static let playWorking = "Simulating"
    public static let playFailed = "A sim failed · turn Play on to see why"

    /// ★ R7-V REVIEW (the verify at 11" portrait, Play on: "Column preview · no lattic…" in a 143 pt note): the Settings
    /// player's lines in SHORTER forms, longest first — the player draws the first that fits beside its picker, so the line
    /// is always whole. [] for a line with no shorter form.
    public static func shortForms(_ note: String) -> [String] {
        switch note {
        case settingsSimNote: return ["3D sim"]
        case settingsColumnEdited: return ["Columns · Save & Exit for 3D", "Column preview", "Columns"]
        case settingsColumnNoLattice: return ["Columns · no lattice yet", "Column preview", "Columns"]
        case settingsColumnRunning: return ["Columns · 3D sim running", "Column preview", "Columns"]
        case settingsColumnFailed: return ["Columns · 3D sim failed", "Column preview", "Columns"]
        default: return []
        }
    }
}

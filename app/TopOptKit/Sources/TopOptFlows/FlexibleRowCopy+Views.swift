// FlexibleRowCopy+Views — the words of round 7's views (batch R7-V): one line each, ≤ 44 characters (his rule). In
// their own file so the Settings batch's copy (R7-S) never meets them.

import Foundation

extension FlexibleRowCopy {
    /// ★ R7-V: an edges/corners group has no stacks until core builds press stacks (AP9) — nothing to bend or heat yet.
    public static let noBendYet = "No bend yet · core support pending"
    public static let noHeatYet = "No heat yet · core support pending"
    /// ★ R7-E3 (the reviewer's interim-sim conditions): an edges group plays the app's interim sim along its arrow on the current
    /// lattice — said while it shows, so nobody reads its depths as tuned.
    public static let latticeNotTunedForPress = "Lattice not tuned for this press yet"
    /// ★ X20b: an edges group's squish held back ONLY because deeper would turn a cell of the part inside out (≤ 44).
    public static func pressFoldCut(percent: Int) -> String { "Shown at \(percent)% of core's depth: deeper folds" }
    /// ★ R7-E5: the legend's line over an edges group's heat (the interim sim's squish along each arrow).
    public static let pressHeatLine = "Squish along the arrow · interim sim"
    /// ★ U21 (BEND-EDGES): the legend follows the sim — calibrated to core's design of every press, or the interim sim.
    public static let pressHeatTunedLine = "Squish along the arrow · core's design"
    public static func pressHeatLine(tuned: Bool) -> String { tuned ? pressHeatTunedLine : pressHeatLine }
    /// ★ U21 (BEND-EDGES): the edge preview's notes (an edges group with no sim to show: the drawn push in its flat prisms). ≤ 44.
    public static let edgePreviewNoLattice = "Edge preview · no lattice built yet"
    public static let edgePreviewRunning = "Edge preview · 3D sim running"
    public static let edgePreviewFailed = "Edge preview · the 3D sim failed"
    public static let edgePreviewEdited = "Edge preview · Save & Exit for the 3D sim"
    /// ★ R7-E3: the main page's group selector — its first entry, and the card's tab when it is the card's only row.
    public static let selectorAll = "All (one after another)"
    public static let selectorTab = "SQUEEZE GROUP"
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
        case settingsEdgesLastSaved: return ["Last saved lattice", "Last saved"]
        case edgePreviewNoLattice: return ["Edge preview · no lattice", "Edge preview"]
        case edgePreviewRunning: return ["Edge preview · sim running", "Edge preview"]
        case edgePreviewFailed: return ["Edge preview · sim failed", "Edge preview"]
        case edgePreviewEdited: return ["Edge preview · Save & Exit", "Edge preview"]
        default: return []
        }
    }
}

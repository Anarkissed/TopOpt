// LatticeThinWallPrompt.swift — ★ his 11-09: the pop-up that comes with the glow when Structural can't lattice somewhere.
//
// His rules, as he gave them:
// - two buttons: "Switch to Aesthetic" (the mode changes, nothing else does) and "Continue with Structural" — "There would
//   be no reason for 'OK', it would do the same as 'Continue with structural'";
// - once per project: the first time; quiet after Continue (`LatticeSettings.thinWallsNoticeSeen`); the one-line note stays
//   and a tap on it re-opens the glow and the pop-up; choosing Structural again (Aesthetic → Structural) shows it once more;
// - the cell-size hint ONLY in a Manual cell mode — "If in auto, then the cell would have gone as small as possible to fit".
// Pure, so it is headless-testable (`LatticeThinWallGlowTests`).

import Foundation

public enum LatticeThinWallPrompt {
    public static let title = "Structural can't lattice the glowing walls"
    public static let switchTitle = "Switch to Aesthetic"
    public static let continueTitle = "Continue with Structural"

    /// Opens by itself on a bake that finds walls: Structural, Lattice Setup up, and not answered for this project.
    public static func opensByItself(finding: LatticeStructuralThinWalls.Finding?, structural: Bool,
                                     setupUp: Bool, seen: Bool) -> Bool {
        finding != nil && structural && setupUp && !seen
    }

    /// The body: why, in his words — and the cell-size hint only where he set the cell himself.
    public static func body(_ f: LatticeStructuralThinWalls.Finding, cellsPerMember nStar: Double, manualCell: Bool) -> String {
        var s = "These walls are thinner than \(LatticeStructuralThinWalls.Finding.mm(f.minWallMM)) — Structural needs room "
            + "for \(Int(nStar.rounded())) cells across a wall to count its strength, so the run leaves them solid. "
            + "Aesthetic lattices thin walls."
        if manualCell {
            s += " Your cell size is set by hand: a smaller cell may lattice some of them."
        }
        return s
    }
}

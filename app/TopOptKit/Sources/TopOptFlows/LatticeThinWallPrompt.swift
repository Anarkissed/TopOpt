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

    // ★ notes25 (D8, his 11-23 on this pop-up): "I think there should be an explanation on WHY structurally speaking you cannot
    // lattice the area requested and why you recommend switching to Aesthetic ... Don't assume they know anything about
    // lattices. Give small sentences of information like "A lattice requires 5 cells across" and add an (i) to explain WHY
    // that is a requirement. Give 3 reasons and have a "Learn more" link that opens up a page explaining the differences of
    // Structural and Aesthetic." The body (one paragraph) became three short reasons, each with its (i); one line on what
    // Aesthetic does instead; the cell hint (Manual cells only, his 11-09); and "Learn more". Every claim is the app's or
    // core's own: the cells-across rule and its measured error curve (core lattice.hpp, `lattice_cells_per_member_min`), cut
    // struts carrying no load (lattice.hpp's phase sweep), solid where Structural can't check (LatticeStageModeSheet), and
    // Aesthetic's print file carrying no strength check (LatticeFileJob.checksStrength, U9). The numbers of cells come from
    // the engine's one rule (`LatticeLayoutPreview.minCellsAcross`), the wall from the finding (`minWallText`).

    /// One reason: its short sentence, and its (i)'s title and words.
    public struct Reason: Equatable, Sendable {
        public let line: String
        public let whyTitle: String
        public let why: String
    }

    /// The three reasons Structural leaves these walls solid. `cellsAcross`: the engine's number for this lattice.
    public static func reasons(_ f: LatticeStructuralThinWalls.Finding, cellsAcross n: Int) -> [Reason] {
        [
            Reason(line: "A lattice needs \(n) cells across a wall.",
                   whyTitle: "Why \(n) cells across",
                   why: "Structural checks your part's strength by treating each lattice as an even material, judged by how "
                    + "dense it is. That only matches the real lattice when enough whole cells sit side by side across a wall. "
                    + "Measured on a wall that bends: with 5 cells across, the check is within 2 % of the real stiffness; with "
                    + "2 cells it is 8.5 % off; with 1 cell, almost 50 %. Here, \(n) cells of the smallest size the run may use "
                    + "need a wall at least \(f.minWallText) thick."),
            Reason(line: "A thin wall cuts its cells into pieces.",
                   whyTitle: "Why cut cells are weak",
                   why: "Where a wall's face slices through a cell, the struts it cuts end in mid-air. A cut strut weighs just "
                    + "as much but carries almost no load when the wall bends. In a thin wall most cells are cut, and its "
                    + "strength then depends on exactly where its faces fall in the cells: measured at the same density, a "
                    + "wall one cell thick came out up to 18 times softer. The check can't predict that."),
            Reason(line: "Structural leaves solid what it can't check.",
                   whyTitle: "Why solid",
                   why: "Structural promises that the strength it reports is the strength you print. Where it can't check a "
                    + "wall's lattice, it fills that wall with solid plastic instead of guessing. Solid is at least as strong "
                    + "as any lattice in the same space, so the promise holds: those walls cost weight, not strength."),
        ]
    }

    /// What Aesthetic does instead, and what that means for strength. `cellsAcross`: Aesthetic's number for this lattice.
    public static func aestheticLine(cellsAcross a: Int) -> String {
        "Aesthetic needs only \(a) cell\(a == 1 ? "" : "s") across, so it can lattice thinner walls. It runs no strength check on "
            + "the lattice: it is for looks, and promises no strength."
    }

    /// ★ his 11-09: the cell-size hint ONLY in a Manual cell mode ("If in auto, then the cell would have gone as small as
    /// possible to fit").
    public static let manualHint = "Your cell size is set by hand: a smaller cell may lattice some of them."
    /// ★ notes25 (D10): the cell is set by hand in Fixed (one size he typed) and Swept (a range he typed) — never in Auto or
    /// Fit, where the app sizes it.
    public static func cellSetByHand(_ l: LatticeSettings) -> Bool { l.cellSizeMode == .fixed || l.cellSizeMode == .swept }

    /// ★ notes30 X2 (cell advice): the cell line under the reasons — the hint only where a smaller cell can lay (a Swept range
    /// whose smallest is above the smallest cell the lay may use: core divides a wall down to that, whatever cell is typed);
    /// where none can, the "This needs … cells" pop-up's own fix where it lays here (Allow quilt); else none. `cells`: the
    /// smallest cell laid and what the walls hold (the solid reason's depth ask; nil: release 21's rule).
    public static func cellLine(_ l: LatticeSettings, cells: SolidReason.Depth?) -> String? {
        guard let d = cells, !SolidReason.controlSmallerCellsAlways else { return cellSetByHand(l) ? manualHint : nil }
        if l.cellSizeMode == .swept, l.cellMinMM > d.floorCellMM * (1 + 1e-6) { return manualHint }
        if d.depthMM > 0, d.smallCellsHelp, !SolidReason.controlThreeOffers { return smallCellsHint(d) }   // ★ his yes: first
        if d.depthMM > 0, d.quiltHelps { return quiltHint(d) }
        return nil
    }
    /// ★ notes30 X2 (his yes, 11-26): the pop-up's first fix, said where it lays these walls.
    public static func smallCellsHint(_ d: SolidReason.Depth) -> String {
        "With Small cells in thin walls on (Manual), these walls get cells down to \(SolidPopUp.mm(d.thinFloorCellMM))."
    }
    /// The pop-up's Allow quilt, said where it lays these walls.
    public static func quiltHint(_ d: SolidReason.Depth) -> String {
        "With Allow quilt on (Manual), cells go down to \(SolidPopUp.mm(d.quiltFloorCellMM)), small enough for these walls."
    }

    /// The link to the page (at most 5 words, his help rule), and the page.
    public static let learnMore = "Learn more"
    public static let pageTitle = "Structural or Aesthetic"

    /// The page: what each is for, what each does at thin walls, how strength is judged in each, when to pick which. The
    /// numbers are the engine's rule for a lattice with no minimum of his own.
    public static func page() -> String {
        var st = LatticeSettings(); st.stageMode = .structural
        var ae = LatticeSettings(); ae.stageMode = .aesthetic
        var one = ae; one.singleCellMembers = true
        let s = LatticeLayoutPreview.minCellsAcross(st), a = LatticeLayoutPreview.minCellsAcross(ae)
        let o = LatticeLayoutPreview.minCellsAcross(one)
        return [
            "WHAT EACH IS FOR\nStructural is for parts that must carry a load. Aesthetic is for parts where the look comes first.",
            "AT THIN WALLS\nStructural needs \(s) cells across a wall; a thinner wall is left solid: heavier, never weaker. "
                + "Aesthetic needs only \(a) cells across (\(o) with \u{201C}Allow single-cell members\u{201D} on), so it can "
                + "lattice thinner walls.",
            "HOW STRENGTH IS JUDGED\nStructural checks the lattice against your material's strength, with your safety "
                + "margin. Aesthetic runs no strength check on the lattice: its lattice follows the stress for looks, and its "
                + "density is not a strength promise.",
            "WHICH TO PICK\nPick Structural when the part must hold a load you rely on. Pick Aesthetic when looks come "
                + "first, or when the walls are too thin for Structural and the part has strength to spare.",
        ].joined(separator: "\n\n")
    }
}

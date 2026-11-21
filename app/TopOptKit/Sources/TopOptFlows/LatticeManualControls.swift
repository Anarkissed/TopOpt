// LatticeManualControls — Install 2: the Manual controls of docs/design/lattice-rebuild/00-proposal.md ("Manual controls for
// engineers — DECIDED") that the new engine takes, his pick 11-14: 1 strut width from -> to, 2 cells across a wall, 4 never skip
// a cell size, 5 grade response and target stress, 7 skin bars, 8 rim width; each for the part (LatticeSettings) or an area
// (LatticeAreaGrading). 6, which loads drive the grade, is Lattice Setup's load switches: the quick check solves each scenario
// switched on and takes the worst at each place (AppModel.makeLatticeSimContexts). 3, 9 and 10 are on the v2 list.
// Which rows Manual shows is decided here, in one place, so the rule is testable without the page.
import Foundation

public enum LatticeManualControl: String, CaseIterable, Sendable {
    case strutWidth, cellsAcross, neverSkip, response, target, skinBars, rimWidth

    /// The part's Finish as an area's four, where it has a rim or a skin (nil: None or Covered).
    public static func partFinish(_ l: LatticeSettings) -> LatticeAreaGrading.ZoneFinish? {
        switch l.boundary {
        case .rim: return .rim
        case .fullSkin: return .skin
        default: return nil
        }
    }

    /// The rows Manual shows for these settings, in order. `areaFinish`: an area's own Finish (nil: the part's), which decides
    /// its Skin bars and Rim width rows. Each row is shown only where the engine reads it: strut widths under By stress, the
    /// response and target where anything follows the stress, the size step on Default Grade, the skin's bars under Skin, the
    /// rim's width under Rim.
    @MainActor public static func shown(_ l: LatticeSettings, areaFinish: LatticeAreaGrading.ZoneFinish? = nil) -> [LatticeManualControl] {
        guard !l.isOrganic else { return [] }
        let stress = LatticeLayoutPreview.settings(l)
        var out: [LatticeManualControl] = []
        if stress.byStress { out.append(.strutWidth) }
        out.append(.cellsAcross)
        if l.gradingMode != .none, l.resolvedAlgorithm != "stepped" { out.append(.neverSkip) }
        if stress.byStress || stress.cellsByStress { out += [.response, .target] }
        switch areaFinish ?? partFinish(l) {
        case .skin?: out.append(.skinBars)
        case .rim?: out.append(.rimWidth)
        default: break
        }
        return out
    }

    /// The page's own count when none is typed (C3-C5): Structural five; Aesthetic two, or one with Allow single-cell members.
    public static func autoCellsAcross(_ l: LatticeSettings) -> Int {
        (l.stageMode ?? .structural) == .aesthetic ? (l.singleCellMembers ? 1 : 2) : 5
    }

    /// One plain line under a typed count below the page's own (nil: nothing to say).
    public static func cellsAcrossWarning(_ n: Int, _ l: LatticeSettings) -> String? {
        guard n < autoCellsAcross(l) else { return nil }
        if (l.stageMode ?? .structural) == .structural { return structuralBelowLine }
        return n == 1 ? oneAcrossLine : nil
    }
    public static let structuralBelowLine = "Under 5 cells across is below the Structural rule: these walls are weaker."
    public static let oneAcrossLine = "One cell across: its struts end cut at the faces; Skin ties them."
}

// LatticeSolidReason — his ruling 2026-11-14 on "Walls should never take the place of the empty or too little lattice! Ever!":
// where lattice was asked for and came out solid, the preview says why in ONE plain line and offers one to three fixes he can
// take with a tap. The why is core's (SolidAt::why, NoCell), weighted by the solid's volume on the engine's own map; the fixes
// are chosen by rule from LatticeReview's tests (which fix opens which reason).
import Foundation
import SwiftUI
import TopOptDesign

public struct SolidReason: Equatable, Sendable {
    public enum Cause: Int, Sendable { case other = 0, wallNarrow, tooFewAcross, sliver, regionShallow }
    public enum Fix: String, CaseIterable, Sendable {
        case letWallsCutCells, aestheticCutCells, oneCellAcross, smallCells
        public var title: String {
            switch self {
            case .letWallsCutCells: return "Let walls cut cells"
            case .aestheticCutCells: return "Aesthetic, walls cut cells"
            case .oneCellAcross: return "One cell across"
            case .smallCells: return "Small cells in thin walls"
            }
        }
    }
    public var cause: Cause
    public var share: Double
    public var line: String
    public var fixes: [Fix]

    /// Said only when this much of the asked-for lattice is solid.
    public static let worthSaying = 0.05

    /// The share as the line says it ("100% of the lattice you asked for is solid").
    public static func percent(_ share: Double) -> Int { Int((100 * share).rounded()) }

    /// The line and its fixes, or nil when too little is solid to say.
    public static func of(share: Double, nocell: [Int], lattice l: LatticeSettings) -> SolidReason? {
        guard share >= worthSaying, nocell.count >= 5 else { return nil }
        // the main reason by volume (ties keep this order); Sliver is P8 (f)'s thin cut piece against solid (LatticeReview
        // c3b4f855); Other only when nothing else is
        let ranked = [Cause.wallNarrow, .tooFewAcross, .regionShallow, .sliver].sorted { nocell[$0.rawValue] > nocell[$1.rawValue] }
        let cause: Cause = nocell[ranked[0].rawValue] > 0 ? ranked[0] : .other
        let pct = percent(share)   // ★ notes25 (D4): the one rounding the notice and "Cannot Lattice" share
        let why: String
        switch cause {
        case .wallNarrow: why = "the walls there are too thin for a whole cell"
        case .tooFewAcross: why = "too narrow for the cells across it needs"
        case .regionShallow: why = "the region is too shallow for a cell"
        case .sliver: why = "cut pieces there are too thin to hold a strut"
        case .other: why = "no cell fits there"
        }
        let aesthetic = (l.stageMode ?? .structural) == .aesthetic
        var fixes: [Fix] = []
        if cause == .wallNarrow || cause == .tooFewAcross {
            if aesthetic, !l.letWallsCutCells { fixes.append(.letWallsCutCells) }
            if !aesthetic { fixes.append(.aestheticCutCells) }
        }
        if cause == .tooFewAcross, aesthetic, !l.singleCellMembers { fixes.append(.oneCellAcross) }
        if cause == .wallNarrow, !l.allowQuilt, !l.smallCellsInThinWalls { fixes.append(.smallCells) }
        return SolidReason(cause: cause, share: share, line: "\(pct)% of the lattice you asked for is solid: \(why)",
                           fixes: Array(fixes.prefix(3)))
    }

    /// The fix, applied to the part's lattice settings (the preview lays again on the change).
    public static func apply(_ f: Fix, to l: inout LatticeSettings) {
        switch f {
        case .letWallsCutCells: l.letWallsCutCells = true
        case .aestheticCutCells: l.stageMode = .aesthetic; l.letWallsCutCells = true
        case .oneCellAcross: l.singleCellMembers = true
        case .smallCells: l.smallCellsInThinWalls = true
        }
    }
}

/// ★ notes28 (his iPad notes on release 18, img 76: a Structural regular lattice on "Solid + Lattice faces" that could not be
/// laid). The pop-up said "No lattice fits these settings: try larger cells or thinner struts" — the wrong reason — while a box
/// at the BOTTOM-CENTRE said the right one ("100% of the lattice you asked for is solid: the region is too shallow for a cell")
/// with "Check a 0.2 mm nozzle". His standing rule (11-21): "never show the bottom note! ... Remove it from the UI entirely!!";
/// errors are centred pop-ups only. HIS DECISION (11-24): "Glow them too" — every place he asked to lattice that stayed solid
/// glows while the pop-up says why, and the pop-up names the REAL reason with the fix that fits it. That box is gone
/// (LatticeSolidReasonBar, its notice's lane); its words, its fix taps and its nozzle offer are this centred pop-up's
/// (AppPopups), raised by the new engine after a lay whose reason is new (LatticeLayoutPreview.raiseSolidPopUp). The Structural
/// thin-wall pop-up (LatticeThinWallPrompt) keeps its own case: walls too thin for Structural's cells.
@MainActor public enum SolidPopUp {
    /// The title: nothing of it can be laid ("Cannot Lattice"), or some of it stays solid.
    public static func title(_ r: SolidReason) -> String {
        SolidReason.percent(r.share) >= 100 ? "This lattice can't be laid" : "Some of the lattice stays solid"
    }

    /// What is solid and why (the notice's own line), then the fix that fits that reason — every cause has its own.
    public static func text(_ r: SolidReason, lattice l: LatticeSettings) -> String {
        "\(r.line).\n\n" + fixLine(r.cause, structural: (l.stageMode ?? .structural) == .structural)
    }

    /// The fix that fits each of core's reasons (SolidAt's NoCell), in plain words.
    public static func fixLine(_ c: SolidReason.Cause, structural: Bool) -> String {
        switch c {
        case .regionShallow:   // his words, 11-24: "the depth is less than one cell; deepen it or use smaller cells"
            return "Its depth is less than one cell. Make it deeper, or use smaller cells."
        case .wallNarrow:
            return structural
                ? "A wall there is thinner than one whole cell. Use smaller cells, or switch to Aesthetic, where walls cut cells."
                : "A wall there is thinner than one whole cell. Use smaller cells, or let walls cut cells."
        case .tooFewAcross:
            return structural
                ? "It is narrower than the cells it needs side by side. Use smaller cells, or switch to Aesthetic, which needs fewer."
                : "It is narrower than the cells it needs side by side. Use smaller cells, or let walls cut cells."
        case .sliver:
            return "Where a wall cuts a cell, the piece left is thinner than a strut. A slightly different cell size moves the cuts."
        case .other:
            return "No cell fits there with these settings. Try larger cells or thinner struts."
        }
    }

    /// The 0.2 mm nozzle check's answer (his 11-14 rule), said in the pop-up: how much of what is solid now it would lattice.
    public static let nozzleTitle = "Checked a 0.2 mm nozzle"
    public static func nozzleAnswer(cure: Double?) -> String {
        guard let c = cure, c >= LatticeLayoutPreview.worthSaying else {
            return "A 0.2 mm nozzle would not lattice much more of it."
        }
        return String(format: "A 0.2 mm nozzle would lattice %.0f%% of what is solid now.", 100 * c)
    }
}

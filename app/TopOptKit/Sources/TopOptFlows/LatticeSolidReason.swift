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
        /// ★ notes30 X2 (his answer, 11-26, on his 20 mm pad under Structural): where smaller cells cannot help — the cell the
        /// depth needs is under the smallest cell laid with Allow quilt off — his three: Allow quilt on, Aesthetic, or solid.
        case allowQuilt, switchToAesthetic, leaveSolid
        public var title: String {
            switch self {
            case .letWallsCutCells: return "Let walls cut cells"
            case .aestheticCutCells: return "Aesthetic, walls cut cells"
            case .oneCellAcross: return "One cell across"
            case .smallCells: return "Small cells in thin walls"
            case .allowQuilt: return "Turn Allow quilt on"
            case .switchToAesthetic: return "Switch to Aesthetic"
            case .leaveSolid: return "Leave it solid"
            }
        }
    }
    public var cause: Cause
    public var share: Double
    public var line: String
    public var fixes: [Fix]
    /// ★ notes30 X2: what the depth of his flat regions asks of the cells, when the app read it (nil: the plain words).
    public var depth: Depth? = nil

    /// ★ notes30 X2: what a region's depth asks of the cells, read off the settings and the lay. Core lays a flat region's depth
    /// in `cellsAcross` cells or more (cells.cpp `divide`: depth / cells across), never in a cell under the lay's smallest
    /// (core's floor_cell_mm: with Allow quilt off, the thinnest strut's open look; with it on, the quilt's cell, strut / touch).
    public struct Depth: Equatable, Sendable {
        /// The deepest flat region asked to lattice (mm).
        public var depthMM: Double
        /// The cells across a depth the lattice asks for (Structural five; core's min_cells_across).
        public var cellsAcross: Int
        /// The smallest cell the lay may lay (core's floor_cell_mm, or the page's smallest cell where that is larger).
        public var floorCellMM: Double
        /// The smallest cell with Allow quilt on (the thinnest strut / the type's touch); 0: no quilt is known for the type.
        public var quiltFloorCellMM: Double
        /// Aesthetic's cells across (two; one with Allow single-cell members).
        public var aestheticCellsAcross: Int
        /// Allow quilt as the engine read it (Auto never quilts).
        public var allowQuiltOn: Bool
        /// ★ notes30 X2 (his yes, 11-26, Small cells first): the smallest cell Small cells in thin walls lays in a wall that
        /// needs it, with Allow quilt off (core's thin_floor_cell_mm, lattice_quilt_off_cell_mm: the thinnest strut and one
        /// printed line of air over the type's touch; octet 3.82 mm at two 0.45 mm lines); 0: none for the type.
        public var thinFloorCellMM: Double
        /// Small cells in thin walls as the engine read it (Auto never lays it).
        public var smallCellsOn: Bool
        public init(depthMM: Double, cellsAcross: Int, floorCellMM: Double, quiltFloorCellMM: Double,
                    aestheticCellsAcross: Int, allowQuiltOn: Bool, thinFloorCellMM: Double = 0, smallCellsOn: Bool = false) {
            self.depthMM = depthMM; self.cellsAcross = cellsAcross; self.floorCellMM = floorCellMM
            self.quiltFloorCellMM = quiltFloorCellMM; self.aestheticCellsAcross = aestheticCellsAcross
            self.allowQuiltOn = allowQuiltOn
            self.thinFloorCellMM = thinFloorCellMM; self.smallCellsOn = smallCellsOn
        }
        /// ★ notes30 X2: Small cells in thin walls helps — off, Allow quilt off (core lays it only then), and the cell this
        /// place needs is at least its smallest (his pad: 4 mm against 3.82 mm; measured, it lays 4 mm cells of 0.90 mm struts).
        public var smallCellsHelp: Bool {
            !smallCellsOn && !allowQuiltOn && thinFloorCellMM > 0 && neededCellMM >= thinFloorCellMM * (1 - 1e-6)
        }
        /// The cell the depth needs: the depth over its cells across (his pad: 20 / 5 = 4 mm).
        public var neededCellMM: Double { depthMM / Double(Swift.max(1, cellsAcross)) }
        /// Smaller cells help: the cell the depth needs is one the lay may lay.
        public var smallerCellsHelp: Bool { neededCellMM >= floorCellMM * (1 - 1e-6) }
        /// Allow quilt on helps: it is off, and the cell the depth needs is at least the quilt's smallest.
        public var quiltHelps: Bool { !allowQuiltOn && quiltFloorCellMM > 0 && neededCellMM >= quiltFloorCellMM * (1 - 1e-6) }
        /// Aesthetic's cell for this depth, and whether it is one the lay may lay.
        public var aestheticCellMM: Double { depthMM / Double(Swift.max(1, aestheticCellsAcross)) }
        public var aestheticHelps: Bool { aestheticCellMM >= floorCellMM * (1 - 1e-6) }
    }

    /// Said only when this much of the asked-for lattice is solid.
    public static let worthSaying = 0.05

    /// The share as the line says it ("100% of the lattice you asked for is solid").
    public static func percent(_ share: Double) -> Int { Int((100 * share).rounded()) }

    /// The line and its fixes, or nil when too little is solid to say. ★ notes30 X2: `depth` — what the flat regions' depth asks
    /// of the cells (`LatticeLayoutPreview.depthAsk`); where smaller cells cannot help a too shallow region, his three offers.
    /// ★ notes30 X2 (cell advice): `haveMM` — core's own "what is there" per reason (the widest wall, the deepest region, at
    /// any of its solid places: the map's SolidWhy::have_mm), which makes `depth` the reason's own: the cell that place needs is
    /// what is there over the cells across it asks (one for a wall thinner than a cell). Advice never names a cell under the
    /// lay's smallest: where none fits, the walls get the same fixes as the depth (Allow quilt where it lays, Leave it solid).
    public static func of(share: Double, nocell: [Int], lattice l: LatticeSettings, depth template: Depth? = nil,
                          haveMM: [Double] = []) -> SolidReason? {
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
        // ★ notes29b (his question on release 20: "Are you saying that no matter what happens, all Small cells in thin walls are
        // going to be quilted?" -- no): offered again. With Allow quilt off it lays a thin wall's own small cells, never fused.
        if cause == .wallNarrow, !l.allowQuilt, !l.smallCellsInThinWalls { fixes.append(.smallCells) }
        // ★ notes30 X2 (his answer, 11-26): a too shallow region whose cell is under the smallest one laid — smaller cells
        // cannot help — offers exactly what does: Allow quilt on (where its smaller cell fits the depth), Aesthetic (where its
        // fewer cells fit), or leaving it solid. Where neither fits, the depth is the fix and the words say so.
        var line = "\(pct)% of the lattice you asked for is solid: \(why)"
        let depth = Self.ask(template, cause: cause, haveMM: haveMM)
        // ★ notes30 X2 (his yes, 11-26): Small cells in thin walls FIRST where it lays here (with Allow quilt off it lays his
        // pad's 4 mm cells of 0.90 mm struts, never touching, only where a wall needs it)
        let smallFirst = !Self.controlThreeOffers
        if cause == .regionShallow, let d = depth, d.depthMM > 0, !Self.controlSmallerCellsAlways, !d.smallerCellsHelp {
            var three: [Fix] = []
            if smallFirst, d.smallCellsHelp { three.append(.smallCells) }
            if d.quiltHelps { three.append(.allowQuilt) }
            if !aesthetic, d.aestheticHelps { three.append(.switchToAesthetic) }
            if !three.isEmpty {
                fixes = three + [.leaveSolid]
                line = "\(pct)% of the lattice you asked for is solid: its depth needs \(SolidPopUp.mm(d.neededCellMM)) cells"
            }
        }
        // ★ notes30 X2 (cell advice): a wall no cell laid fits — the wall's own fixes first (as before), then the depth's that
        // lay here (Allow quilt, Aesthetic), then Leave it solid; never "use smaller cells"
        if cause == .wallNarrow || cause == .tooFewAcross, let d = depth, d.depthMM > 0, !Self.controlSmallerCellsAlways,
           !d.smallerCellsHelp {
            var others = fixes
            if smallFirst {   // ★ notes30 X2: first where it lays these walls, never where it does not
                others.removeAll { $0 == .smallCells }
                if d.smallCellsHelp { others.insert(.smallCells, at: 0) }
            }
            if d.quiltHelps, !others.contains(.allowQuilt) { others.append(.allowQuilt) }
            if !aesthetic, d.aestheticHelps, !others.contains(.aestheticCutCells) { others.append(.switchToAesthetic) }
            fixes = Array(others.prefix(smallFirst ? 3 : 2)) + [.leaveSolid]
        }
        // the offers: up to three and Leave it solid (the pop-up's dismiss word); else three at most, as ever
        return SolidReason(cause: cause, share: share, line: line, fixes: Array(fixes.prefix(fixes.contains(.leaveSolid) ? 4 : 3)),
                           depth: depth)
    }

    /// RED CONTROL (tests): release 22's offers — no Small cells in thin walls among them.
    nonisolated(unsafe) public static var controlThreeOffers = false

    /// ★ notes30 X2 (cell advice): the depth ask made the reason's own — core's "what is there" for it, over the cells across
    /// it asks (a wall thinner than one cell: one; Aesthetic likewise). The template's floors stay.
    static func ask(_ template: Depth?, cause: Cause, haveMM: [Double]) -> Depth? {
        guard var d = template else { return nil }
        let have = haveMM.count == 5 ? haveMM[cause.rawValue] : 0
        switch cause {
        case .wallNarrow:   // ★ notes30 X2: core divides a wall into the cells across its lattice asks (cells.cpp divide)
            d.depthMM = have
        case .tooFewAcross:
            d.depthMM = have
        case .regionShallow:
            if have > 0 { d.depthMM = have }
        default:
            break
        }
        return d
    }

    /// His three offers are up (smaller cells cannot help; ★ notes30 X2).
    public var offersThree: Bool { fixes.contains(.leaveSolid) }
    /// RED CONTROL (tests): the advice before notes30 X2 — "use smaller cells" whatever the smallest cell.
    nonisolated(unsafe) public static var controlSmallerCellsAlways = false

    /// The fix, applied to the part's lattice settings (the preview lays again on the change).
    public static func apply(_ f: Fix, to l: inout LatticeSettings) {
        switch f {
        case .letWallsCutCells: l.letWallsCutCells = true
        case .aestheticCutCells: l.stageMode = .aesthetic; l.letWallsCutCells = true
        case .oneCellAcross: l.singleCellMembers = true
        case .smallCells: l.smallCellsInThinWalls = true
        case .allowQuilt: l.allowQuilt = true
        case .switchToAesthetic: l.stageMode = .aesthetic
        case .leaveSolid: break   // it stays solid; nothing changes
        }
    }

    /// ★ notes30 X2: a fix taken on the part. Allow quilt is Manual's switch (Auto never quilts, his 11-25), so turning it on
    /// opens the Lattice page's Manual with it on; Aesthetic is the thin-wall pop-up's own switch (the mode changes, nothing
    /// else does, one Undo step); Leave it solid changes nothing. The rest as `apply`.
    @MainActor public static func take(_ f: Fix, on p: ProjectModel) {
        switch f {
        case .allowQuilt:
            p.latticePageManual = true   // first: the lay the change starts reads Manual
            p.lattice.allowQuilt = true
        case .smallCells:   // ★ notes30 X2: its own switch, Manual's too (Auto lays none: LatticeLayoutPreview.settings)
            p.latticePageManual = true
            p.lattice.smallCellsInThinWalls = true
        case .switchToAesthetic:
            p.switchLatticeStageMode(to: .aesthetic)
        case .leaveSolid:
            break
        default:
            apply(f, to: &p.lattice)
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
    /// The title: nothing of it can be laid ("Cannot Lattice"), or some of it stays solid. ★ notes30 X2: with his three offers,
    /// what the depth needs (five words: "This needs 4 mm cells", positive).
    public static func title(_ r: SolidReason) -> String {
        if r.offersThree, let d = r.depth { return "This needs \(mm(d.neededCellMM)) cells" }
        return SolidReason.percent(r.share) >= 100 ? "This lattice can't be laid" : "Some of the lattice stays solid"
    }

    /// What is solid and why (the notice's own line), then the fix that fits that reason — every cause has its own.
    /// ★ notes30 X2: a too shallow region says "smaller cells" only where they help; with his three offers, the numbers.
    public static func text(_ r: SolidReason, lattice l: LatticeSettings) -> String {
        let structural = (l.stageMode ?? .structural) == .structural
        let start = { (d: SolidReason.Depth) in
            (d.allowQuiltOn ? "With these settings" : "With Allow quilt off") + ", cells start at \(mm(d.floorCellMM))."
        }
        if r.cause == .regionShallow, let d = r.depth, d.depthMM > 0, !SolidReason.controlSmallerCellsAlways,
           !d.smallerCellsHelp {
            guard r.offersThree else { return "\(r.line).\n\n" + deeperLine(d) }
            return "\(r.line).\n\n" + (structural ? "Structural" : "This lattice")
                + " fits \(Swift.max(1, d.cellsAcross)) cells across \(mm(d.depthMM)), so each cell is \(mm(d.neededCellMM)). "
                + start(d) + " Pick a way below."
        }
        // ★ notes30 X2 (cell advice): a wall no cell laid fits — what it holds against the smallest cell, never "smaller cells"
        if r.cause == .wallNarrow || r.cause == .tooFewAcross, let d = r.depth, d.depthMM > 0,
           !SolidReason.controlSmallerCellsAlways, !d.smallerCellsHelp {
            let k = Swift.max(1, d.cellsAcross)
            let holds = r.cause == .wallNarrow ? "A wall there is \(mm(d.depthMM)) thick."
                : "It is \(mm(d.depthMM)) across, room for \(k) cells of \(mm(d.neededCellMM))."
            return "\(r.line).\n\n" + holds + " " + start(d) + " Pick a way below."
        }
        return "\(r.line).\n\n" + fixLine(r.cause, structural: structural)
    }

    /// ★ notes30 X2: a too shallow region that no cell laid fits — the depth it needs (his words, 11-24, where the depth is
    /// less than one cell: "the depth is less than one cell; deepen it").
    static func deeperLine(_ d: SolidReason.Depth) -> String {
        let k = Swift.max(1, d.cellsAcross)
        let need = "Make it at least \(mm((Double(k) * d.floorCellMM * 10).rounded(.up) / 10)) deep."   // up: enough
        return d.depthMM < d.floorCellMM * (1 - 1e-6) ? "Its depth is less than one cell. " + need
            : "Its depth holds fewer than \(k) cell\(k == 1 ? "" : "s"). " + need
    }

    /// ★ notes30 X2: the (i) beside his three offers — what each one does, with the numbers. The Allow quilt line is what core
    /// measured (Notes30A1OffersTests, his pad and a 40 mm block): on this depth the cells it needs and no smaller, struts as
    /// thin as before; the switch is the whole part's, and on a deeper face Default Grade then halves the cells along the face
    /// and its band thickens their struts until they touch.
    public static let offersWhyTitle = "What each choice does"
    public static func offersWhy(_ r: SolidReason) -> String? {
        guard r.offersThree, let d = r.depth else { return nil }
        var parts: [String] = []
        if r.fixes.contains(.smallCells), d.thinFloorCellMM > 0 {   // ★ notes30 X2: first, as it is offered
            parts.append("Small cells in thin walls: the Lattice page goes to Manual with it on. Only where a wall needs it, its "
                + "cells shrink, here to the \(mm(d.neededCellMM)) cells it needs (never under \(mm(d.thinFloorCellMM))), with "
                + "struts as thin as before and always a printed line apart, so they never touch. Allow quilt stays off.")
        }
        if r.fixes.contains(.allowQuilt) {
            parts.append("Turn Allow quilt on: the Lattice page goes to Manual with Allow quilt on. Cells may then be as small as "
                + "\(mm(d.quiltFloorCellMM)), so this place gets the \(mm(d.neededCellMM)) cells it needs, and no smaller, with "
                + "struts as thin as before. Allow quilt is for the whole part: on a deeper face, the cells along the face may "
                + "halve and their struts thicken until they touch.")
        }
        if r.fixes.contains(.switchToAesthetic) {
            parts.append("Switch to Aesthetic: Aesthetic needs \(Swift.max(1, d.aestheticCellsAcross)) cells across, so "
                + "\(mm(d.aestheticCellMM)) cells fit here. Aesthetic is for looks and runs no strength check.")
        }
        // ★ notes30 X2 (cell advice): a wall's own fixes, when they share the pop-up
        if r.fixes.contains(.letWallsCutCells) {
            parts.append("Let walls cut cells: cells run on through a thin wall and are cut where it ends.")
        }
        if r.fixes.contains(.aestheticCutCells) {
            parts.append("Aesthetic, walls cut cells: Aesthetic lets cells run on through a thin wall, cut where it ends. It is "
                + "for looks and runs no strength check.")
        }
        if r.fixes.contains(.oneCellAcross) {
            parts.append("One cell across: a member one cell wide is latticed, with a skin tying its cut struts.")
        }
        if r.fixes.contains(.smallCells), !(d.thinFloorCellMM > 0) {
            parts.append("Small cells in thin walls: a thin wall gets its own smaller cells, down to the smallest whose struts "
                + "stay a printed line apart.")
        }
        parts.append("Leave it solid: this region prints as solid plastic. It weighs more, and is at least as strong as any "
            + "lattice there.")
        return parts.joined(separator: "\n\n")
    }

    /// A length as the pop-up says it: whole millimetres as they are ("20 mm"), else at most two decimals ("4.74 mm").
    nonisolated static func mm(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return "\(Int(r)) mm" }
        var t = String(format: "%.2f", r)
        while t.hasSuffix("0") { t.removeLast() }
        return t + " mm"
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

// LatticeRegionDrawer.swift — ★ KEEP THE DATA, MOVE IT TO A DRAWER
// (task 2026-08-14-lattice-separation §4).
//
// ★ HIS QUESTION about the numbers on the group card was: what are those, do they
// matter, are they modifiable.
//
// ★ THE ANSWER DECIDES THE DESIGN: THEY MATTER, AND THEY ARE THE MOST VALUABLE
// THING ON THE CARD. `4.0 mm` depth · `held` · `72.5 g` handed to the lattice ·
// `4.93 mm` derived cell · `5%` density · `0.32 mm` strut · an orange
// OUT-OF-REGIME flag. A 4.0 mm depth against a 4.93 mm cell IS out of regime —
// that is precisely the failure that produced empty lattices for weeks, reported
// CORRECTLY, BEFORE the run, and rendered as unreadable vertical text.
//
// So nothing is removed. The arrangement changes:
//
//   COLLAPSED   ONE thing (§4d): the grams handed over, and the verdict as
//               COLOUR. Everything else is behind the drawer.
//   OPEN        the out-of-regime flag as the HEADLINE (§4c) — it is the one line
//               that predicts a wasted run — then the depth, then the derived
//               facts.
//
// ★ AND WHICH ONES ARE CONTROLS IS STATED IN THE TYPE (§4b). The depth is
// MODIFIABLE (it is the drag). The rest are DERIVED and READ-ONLY, presented as
// facts rather than as controls — the lesson of backlog item (1)'s Diagrid picker
// that was not a picker. A row that is not `modifiable` is not given a gesture.
//
// R7: every string here is a number and a one- or two-word label. The longest
// this file can render is 4 words.

import Foundation

/// One line in the drawer.
public struct LatticeDrawerRow: Equatable, Sendable {
    /// One or two words.
    public let label: String
    /// The value, already formatted.
    public let value: String
    /// ★ §4b — TRUE only for the depth. Everything else is a FACT, not a control.
    public let modifiable: Bool

    public init(label: String, value: String, modifiable: Bool = false) {
        self.label = label
        self.value = value
        self.modifiable = modifiable
    }
}

/// The whole drawer for one region, derived from the card the barrier preview
/// already produces. A pure value: the view renders it and adds no numbers.
public struct LatticeRegionDrawer: Equatable, Sendable {

    /// ★ §4c — THE HEADLINE. Non-nil ONLY when the region is out of regime or
    /// holds nothing: the drawer opens with the reason a run would be wasted, not
    /// with a sideways orange strip beside six other numbers.
    public struct Headline: Equatable, Sendable {
        /// ★ Four words at most (R7).
        public let text: String
        public let verdict: LatticeFaceCard.Verdict
    }

    public let headline: Headline?
    /// ★ §4d — the COLLAPSED row: the grams handed over. The verdict rides as
    /// colour, which is `verdict`, not a second string.
    public let collapsedValue: String
    public let verdict: LatticeFaceCard.Verdict
    /// The depth first (the one control), then the derived facts.
    public let rows: [LatticeDrawerRow]
    /// Whether this group is also HELD against the optimizer — the lock chip.
    public let held: Bool

    public init(headline: Headline?, collapsedValue: String,
                verdict: LatticeFaceCard.Verdict, rows: [LatticeDrawerRow],
                held: Bool) {
        self.headline = headline
        self.collapsedValue = collapsedValue
        self.verdict = verdict
        self.rows = rows
        self.held = held
    }

    /// Build the drawer for one face card.
    ///
    /// ★ THE OUT-OF-REGIME SENTENCE IS THE CARD'S OWN VERDICT, NOT A NEW CLAIM.
    /// `LatticeFaceCard.Verdict.outOfRegime` already means "it prints, but no cell
    /// is coarse enough to homogenize across this slab" — core's two-bound
    /// crossing. The headline states the crossing in the two numbers that produced
    /// it (the depth and the cell) because those are the two the user can move.
    ///
    /// ★ `latticeReachesTheRun == false` OUTRANKS IT (the interrupt's §3). For a
    /// REGION the lattice half of the choice cannot reach the run at all — core's
    /// `lattice.regions` are geometry predicates and a region is a voxel set
    /// (PR 331 §6) — so no cell verdict is worth leading with. The depth still is:
    /// it is PR 331's per-sector protection depth and the run consumes it.
    /// `perRegionDensity` — ★ THE DENSITY IS ALREADY DECIDED ON THE LATTICE
    /// SETTINGS PAGE, and the drawer FOLLOWS that choice rather than duplicating
    /// it. Only the per-region mode says "I will state it myself", so only then
    /// does the density row become a control. Every other mode leaves this false
    /// and the drawer is exactly what PR 331 shipped.
    ///
    /// ★ A Bool, not `LatticeDensityMode`, and deliberately: that enum has no
    /// per-region case yet (`uniform` / `auto` only), and adding one would touch
    /// a Codable enum and three switch sites outside this change — past the scope
    /// stop. When the per-region mode lands it sets this flag; nothing else moves.
    ///
    /// ★ NOTHING CAN SET IT TRUE TODAY. See the three gaps recorded beside the
    /// property test in FrozenRegionAsMaterialTests: the mode does not exist, the
    /// view cannot render a second control, and the override does not reach core.
    public static func make(card: LatticeFaceCard?, depthMM: Double,
                            held: Bool,
                            latticeReachesTheRun: Bool = true,
                            perRegionDensity: Bool = false) -> LatticeRegionDrawer {
        guard latticeReachesTheRun else {
            return LatticeRegionDrawer(
                headline: Headline(text: "Frozen, not latticed", verdict: .outOfRegime),
                collapsedValue: card?.heldText ?? "—",
                verdict: .outOfRegime,
                rows: [LatticeDrawerRow(label: "Depth",
                                        value: String(format: "%.1f mm", depthMM),
                                        modifiable: true),
                       LatticeDrawerRow(label: "Hands over", value: card?.heldText ?? "—")],
                held: held)
        }
        guard let c = card else {
            // No preview yet (no B-rep, or the voxelization has not landed). Say
            // so with the depth, which is known, and invent nothing else.
            return LatticeRegionDrawer(
                headline: nil, collapsedValue: "—", verdict: .noMaterial,
                rows: [LatticeDrawerRow(label: "Depth",
                                        value: String(format: "%.1f mm", depthMM),
                                        modifiable: true)],
                held: held)
        }
        var head: Headline?
        switch c.verdict {
        case .outOfRegime:
            // ★ The failure that produced empty lattices for weeks, named before
            // the run: the slab is thinner than the cells the certifier needs.
            head = Headline(text: String(format: "%.1f cells across", c.cellsPerMember),
                            verdict: .outOfRegime)
        case .noMaterial:
            head = Headline(text: "Holds no material", verdict: .noMaterial)
        case .certified:
            head = nil
        }
        let rows = [
            // ★ THE DEPTH ROW PRINTS THE DEPTH IT WAS HANDED, NOT THE CARD'S
            // (task 2026-08-17-lattice-stage-repair §2). `depthMM` is the value
            // `ProjectModel.latticeSlabDepthMM(ref:in:)` resolves for the thing
            // this drawer is about — the SAME number the 3D handle drags and the
            // row chip shows. The card carries a depth too, and until this task
            // the row printed THAT one: the cards were derived per GROUP, so a
            // face or region dragged to its own depth kept showing its group's.
            // One value, one source; the card's copy is checked against it by
            // `depthDivergence` rather than trusted.
            LatticeDrawerRow(label: "Depth", value: String(format: "%.1f mm", depthMM),
                             modifiable: true),
            LatticeDrawerRow(label: "Hands over", value: c.heldText),
            // ★ WHAT IT WILL WEIGH, AND THE DIFFERENCE (task 2026-08-13-lattice-
            // as-a-material §7b). "Hands over" alone is half a sentence: the
            // reason to hand material to a lattice is what comes back lighter,
            // and that number was one multiplication away and not on screen.
            LatticeDrawerRow(label: "As lattice", value: c.latticedText),
            LatticeDrawerRow(label: "Saved", value: c.savedText),
            LatticeDrawerRow(label: "Cell", value: c.cellText),
            // ★ A FACT in every mode but one. Under per-region the user states
            // this number, so there it is the second control — and ONLY there.
            LatticeDrawerRow(label: "Density", value: c.densityText,
                             modifiable: perRegionDensity),
            LatticeDrawerRow(label: "Strut", value: c.strutText),
            LatticeDrawerRow(label: "Cells across", value: c.cellsText),
        ]
        return LatticeRegionDrawer(headline: head, collapsedValue: c.heldText,
                                   verdict: c.verdict, rows: rows, held: held)
    }

    /// ★ THE "THEY CANNOT DIVERGE" CHECK, AS A FUNCTION RATHER THAN A COMMENT
    /// (task 2026-08-17-lattice-stage-repair §2 / bar R3) — the same shape
    /// `LatticeSlabDepth.mismatches` already uses for the protection/region pair.
    ///
    /// A card is DERIVED at some depth: its cell, its cells-across, its strut and
    /// its mass are all functions of that depth. The drawer is LABELLED with the
    /// depth in force for the thing it is about. If those two are not the same
    /// number the drawer is showing arithmetic from one depth under a label from
    /// another — which is exactly what it did before this task, and what made a
    /// dragged handle look like it had done nothing.
    ///
    /// Returns nil when they agree. Non-nil is a programming error at the CALL
    /// SITE, never something a user can cause, so it is asserted in tests rather
    /// than rendered.
    public static func depthDivergence(card: LatticeFaceCard?, depthMM: Double)
        -> (cardMM: Double, shownMM: Double)? {
        guard let c = card else { return nil }
        return abs(c.depthMM - depthMM) > 1e-9 ? (c.depthMM, depthMM) : nil
    }

    /// ★ §4b, as a property rather than a convention. TWO EXACT CASES, never
    /// relaxed to "one or more" — the invariant's job is to stop a readout being
    /// mistaken for a control, and a loose bound does not do that job:
    ///   * not per-region → EXACTLY ["Depth"]
    ///   * per-region     → EXACTLY ["Depth", "Density"]
    public var modifiableRows: [LatticeDrawerRow] { rows.filter(\.modifiable) }
}

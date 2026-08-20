// LatticeFaceDiagnosis.swift — ★ WHAT IS WRONG, AND THE FIX WITH ITS VALUE
// (task 2026-08-15-lattice-and-face-ui §3).
//
// ★ THE BAR, AND IT IS NOT A STYLE NOTE: "HE IS THE PERSON WHO DESIGNED THIS
// PROJECT AND HE COULD NOT TELL WHAT 'Out of regime · 3.0 cells across' MEANT OR
// HOW TO FIX IT."
//
// ── THE ARITHMETIC THE UI NEVER SHOWED HIM ────────────────────────────────────
//
// Core's `cells_per_member_floor` is 5. His region was 14.7 mm through the thin
// part with a 4.93 mm cell:
//
//     14.7 / 4.93  =  2.98  ≈  "3.0 cells across"
//
// Both ways out are computable from numbers already ON THAT CARD:
//
//     DEEPER        5 × 4.93  =  24.65 mm
//     SMALLER CELL  14.7 / 5  =   2.94 mm
//
// Face 24 at 24.7 mm already clears it; face 16 at 20.0 mm gives 4.06 and does
// not. The panel had every one of those numbers and printed none of them.
//
// ── AND THE SECOND FAILURE ON THE SAME CARD, WHICH WAS NOT FLAGGED AT ALL ─────
//
// ★ STRUT 0.32 mm AGAINST HIS 0.45 mm NOZZLE. That lattice cannot be printed and
// the panel said nothing. §3(c): EVERY failure, not the first. "A panel that
// flags one problem and hides another is worse than one that flags none."
//
// ── WHY THIS IS A VALUE TYPE ──────────────────────────────────────────────────
//
// The exact strings are a BAR (R7 asks them to be pasted into the handoff) and
// their length is a bar too (R14). Both are properties of a pure function of the
// card, so both are asserted in `LatticeFaceDiagnosisTests` rather than read off
// a screenshot. No view, no model.
//
// R14: the BADGE is capped at 25 words and the cap is ENFORCED here, not hoped
// for — `badge` is built from a template whose longest instantiation is counted
// by the test. The pop-up may be longer but LEADS WITH THE FIX.

import Foundation

/// Everything wrong with one region's lattice, and what to do about each.
public struct LatticeFaceDiagnosis: Equatable, Sendable {

    /// One thing that is wrong.
    public struct Problem: Equatable, Sendable {
        /// ★ WHAT IS WRONG, in plain words. No jargon — §3(d): "Out of regime"
        /// means nothing to him.
        public let what: String
        /// ★ THE NUMBER AND THE TARGET, as one short phrase.
        public let measured: String
        /// ★ THE FIX WITH ITS VALUE. One or two, each already a number.
        public let fixes: [String]
    }

    /// ★ §3(a) — WHAT RIDES THE COLLAPSED ROW, visible WITHOUT expanding the
    /// drawer. Nil when nothing is wrong.
    public let badge: String?
    /// The verdict colour the badge rides.
    public let severity: LatticeFaceCard.Verdict
    /// ★ §3(b)/§3(c) — EVERY failure, in the (i) pop-up. Empty iff `badge == nil`.
    public let problems: [Problem]

    public init(badge: String?, severity: LatticeFaceCard.Verdict,
                problems: [Problem]) {
        self.badge = badge
        self.severity = severity
        self.problems = problems
    }

    public var isClean: Bool { badge == nil }

    /// ★ THE POP-UP'S BODY — the fix FIRST (§3e), then the number it came from.
    /// One paragraph per problem, joined by a blank line.
    public var popoverText: String {
        problems.map { p in
            ([p.what] + p.fixes + [p.measured]).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - the derivation

    /// ★ THE ONE BUILDER. Everything is arithmetic on numbers the card already
    /// holds plus two core-owned floors, so nothing here is authored:
    ///
    ///   `cellsPerMemberFloor`  `TopOptKit.latticeLimits(topology:).minCellsPerMember`
    ///   `nozzleWidthMM`        the run's own extrusion width (`strutLineWidthMM`)
    public static func of(card: LatticeFaceCard,
                          cellsPerMemberFloor: Double,
                          nozzleWidthMM: Double) -> LatticeFaceDiagnosis {
        var problems: [Problem] = []

        // ── 1. NOTHING TO LATTICE ────────────────────────────────────────────
        if card.verdict == .noMaterial || card.heldVoxels == 0 {
            problems.append(Problem(
                what: "This region holds no material to lighten.",
                measured: "It hands the lattice 0 g.",
                fixes: ["Make it deeper, or move it onto solid material."]))
            return LatticeFaceDiagnosis(
                badge: "Holds nothing — nothing to lattice",
                severity: .noMaterial, problems: problems)
        }

        // ── 2. TOO FEW STRUTS ACROSS THE WALL ────────────────────────────────
        // ★ THE ONE HE COULD NOT READ. `cellsPerMember` is thickness / cell, so
        // the thickness is recoverable and BOTH fixes fall straight out of it.
        if card.cellsPerMember > 0, card.cellsPerMember < cellsPerMemberFloor,
           card.cellMM > 0 {
            let thicknessMM = card.cellsPerMember * card.cellMM
            problems.append(Problem(
                what: "Not certifiable — too few struts across this wall.",
                measured: String(format: "%.1f struts across, needs %.0f.",
                                 card.cellsPerMember, cellsPerMemberFloor),
                fixes: [String(format: "Make it deeper: %.1f mm.",
                               roundedUp(cellsPerMemberFloor * card.cellMM)),
                        String(format: "Or use a smaller cell: %.1f mm.",
                               roundedDown(thicknessMM / cellsPerMemberFloor))]))
        }

        // ── 3. THE STRUT IS THINNER THAN THE NOZZLE ──────────────────────────
        // ★ §3(c) — THE FAILURE HIS PANEL NEVER MENTIONED. 0.32 mm of strut
        // against a 0.45 mm nozzle does not print, and it is a SEPARATE fault
        // from the one above: a region can clear the strut count and still be
        // unprintable, or the reverse.
        if nozzleWidthMM > 0, card.strutDiameterMM > 0,
           card.strutDiameterMM < nozzleWidthMM - 1e-9 {
            // The strut scales with the cell at fixed density, so the cell that
            // would reach the nozzle is the current one scaled by the shortfall.
            let neededCellMM = card.cellMM > 0
                ? card.cellMM * (nozzleWidthMM / card.strutDiameterMM) : 0
            var fixes = [String(format: "Raise the density above %.0f%%.",
                                card.relativeDensity * 100)]
            if neededCellMM > 0 {
                fixes.append(String(format: "Or use a bigger cell: %.1f mm.",
                                    roundedUp(neededCellMM)))
            }
            problems.append(Problem(
                what: "Too thin to print — the struts are finer than the nozzle.",
                measured: String(format: "%.2f mm strut, nozzle is %.2f mm.",
                                 card.strutDiameterMM, nozzleWidthMM),
                fixes: fixes))
        }

        guard !problems.isEmpty else {
            return LatticeFaceDiagnosis(badge: nil, severity: .certified,
                                        problems: [])
        }
        return LatticeFaceDiagnosis(badge: badgeText(problems),
                                    severity: .outOfRegime, problems: problems)
    }

    /// ★ A PRINTED FIX MUST ACTUALLY FIX IT — WHICH MAKES THE ROUNDING DIRECTION
    /// A CORRECTNESS QUESTION, NOT A FORMATTING ONE.
    ///
    /// His case: the depth that clears a floor of 5 at a 4.93 mm cell is
    /// 5 × 4.93 = 24.65 mm. Nearest-rounded to one decimal that prints "24.6 mm"
    /// — and 24.6 / 4.93 = **4.99**, which STILL FAILS. A panel that hands the
    /// user a number that does not work is worse than one that hands them none.
    ///
    /// So a fix that must be BIGGER rounds UP and one that must be SMALLER rounds
    /// DOWN, always to the side that satisfies the bound.
    /// `testTheCellsAcrossFailureNamesBothFixesWithTheirValues` pins both.
    static func roundedUp(_ v: Double) -> Double { (v * 10).rounded(.up) / 10 }
    static func roundedDown(_ v: Double) -> Double { (v * 10).rounded(.down) / 10 }

    /// ★ §3(a)/§3(d)/§3(e) — THE BADGE. Plain language, no jargon, and it names
    /// the COUNT when there is more than one fault, so a second problem can never
    /// hide behind the first (§3c) even before the pop-up is opened.
    ///
    /// ★ Longest instantiation is 11 words; the bar is 25. Counted by
    /// `LatticeFaceDiagnosisTests.testTheBadgeStaysUnderTwentyFiveWords`.
    static func badgeText(_ problems: [Problem]) -> String {
        let lead: String
        if problems.contains(where: { $0.what.hasPrefix("Not certifiable") }) {
            lead = "Won't certify"
        } else {
            lead = "Won't print"
        }
        // ★ THE REAL COUNT, NOT A LITERAL "2" (task
        // 2026-08-17-lattice-stage-repair). This read `"2 problems"` for ANY
        // count above one — correct for the two-fault card it was written
        // against, and a lie the moment a third appeared. It could not appear
        // while the badge described ONE card (there are only two fault kinds);
        // it can now, because the badge describes a GROUP of faces. Fixing it
        // here rather than letting the merge expose it.
        return problems.count > 1
            ? "\(lead) — \(problems.count) problems, tap for the fix"
            : "\(lead) — tap for the fix"
    }

    // MARK: - ★ THE GROUP'S BADGE IS THE UNION OF ITS FACES'

    /// ★ WHY THIS EXISTS (maintainer, 2026-08-17): "There is a 'per Group' set of
    /// notes regarding the lattice that doesn't make sense. It should be per face
    /// *only*. The group does *not* have its own primitive to expand therefore
    /// making it impossible to ever be *IN* regime."
    ///
    /// He is right, and the badge was standing on exactly that fabrication: it
    /// was built from a card derived at `g.faces.first` — ONE arbitrary face
    /// speaking for the whole group, at a depth no handle drags. The group's
    /// per-lattice numbers are gone; the badge is not, because "see the problem
    /// without expanding the drawer" is a separate requirement (§3a of the
    /// 2026-08-15 task) and still stands.
    ///
    /// So the group badge is now the UNION of its faces' diagnoses:
    ///
    ///   * problems are merged BY KIND (`what`), because three faces that are all
    ///     too thin are ONE thing to fix, not three lines of the same sentence.
    ///     The first face's numbers are kept — they are a real face's real
    ///     measurement, which is the whole point.
    ///   * severity is the WORST present: any face out of regime makes the group
    ///     out of regime. A group is clean only when every face is.
    ///   * an EMPTY list is clean, not broken — a group whose faces are all
    ///     certified has no badge, exactly as before.
    public static func merged(_ each: [LatticeFaceDiagnosis]) -> LatticeFaceDiagnosis {
        var problems: [Problem] = []
        var seen = Set<String>()
        for d in each {
            for p in d.problems where !seen.contains(p.what) {
                seen.insert(p.what)
                problems.append(p)
            }
        }
        guard !problems.isEmpty else {
            return LatticeFaceDiagnosis(badge: nil, severity: .certified,
                                        problems: [])
        }
        // `noMaterial` only when EVERY diagnosis said so — one face holding
        // nothing beside a face that is merely out of regime is the latter.
        let allEmpty = !each.isEmpty
            && each.allSatisfy { $0.severity == .noMaterial }
        return LatticeFaceDiagnosis(badge: badgeText(problems),
                                    severity: allEmpty ? .noMaterial : .outOfRegime,
                                    problems: problems)
    }
}

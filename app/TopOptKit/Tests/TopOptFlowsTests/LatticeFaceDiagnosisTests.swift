// LatticeFaceDiagnosisTests.swift — task 2026-08-15-lattice-and-face-ui §3.
//
//   R7  ★ THE BADGE AND (i) DEMONSTRATED ON HIS OWN FAILING CARD — the
//       3.0-cells-across case — with the exact text, INCLUDING the un-flagged
//       strut failure.
//   R14 ★ NO WALL OF TEXT. The badge's word count is asserted, not hoped for.
//
// ★ HIS CARD, AS REPORTED. Region 14.7 mm through the thin part, cell 4.93 mm,
// strut 0.32 mm, nozzle 0.45 mm, `cells_per_member_floor` 5:
//
//     14.7 / 4.93  =  2.98  ->  "Out of regime · 3.0 cells across"
//
// He could not tell what that meant or how to fix it, and the SECOND failure on
// the same card — a strut finer than his nozzle — was not flagged at all.

import XCTest
@testable import TopOptFlows

final class LatticeFaceDiagnosisTests: XCTestCase {

    /// ★ HIS CARD. Built from the numbers in his own screenshot so the strings
    /// this test prints are the strings he would have seen.
    private func hisFailingCard() -> LatticeFaceCard {
        // cellsPerMember 2.98 = 14.7 mm / 4.93 mm.
        LatticeFaceCard(faceID: 16, depthMM: 14.7, heldVoxels: 10_554,
                        heldVolumeMM3: 52_345, heldMassG: 64.9,
                        cellMM: 4.93, relativeDensity: 0.05,
                        strutDiameterMM: 0.32, cellsPerMember: 2.98,
                        verdict: .outOfRegime)
    }

    private func diagnose(_ c: LatticeFaceCard) -> LatticeFaceDiagnosis {
        LatticeFaceDiagnosis.of(card: c, cellsPerMemberFloor: 5, nozzleWidthMM: 0.45)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §3(b) — the arithmetic, and BOTH ways out

    /// ★ THE FIX AND ITS VALUE. Deeper: 5 × 4.93 = 24.65 mm. Smaller cell:
    /// 14.7 / 5 = 2.94 mm. Both were computable from the card and neither was
    /// on screen.
    func testTheCellsAcrossFailureNamesBothFixesWithTheirValues() throws {
        let d = diagnose(hisFailingCard())
        let p = try XCTUnwrap(d.problems.first { $0.what.hasPrefix("Not certifiable") },
                              "§3: the cells-across failure must be reported")
        XCTAssertEqual(p.what, "Not certifiable — too few struts across this wall.")
        XCTAssertEqual(p.measured, "3.0 struts across, needs 5.")
        XCTAssertEqual(p.fixes, ["Make it deeper: 24.7 mm.",
                                 "Or use a smaller cell: 2.9 mm."])
    }

    /// ★ A PRINTED FIX MUST ACTUALLY FIX IT. Nearest-rounding 5 × 4.93 = 24.65
    /// gives "24.6 mm", and 24.6 / 4.93 = 4.99 — still under the floor of 5. The
    /// number on screen has to be one that WORKS, so the rounding goes to the
    /// satisfying side. Asserted by re-running the floor test on the printed
    /// values rather than by trusting the format string.
    func testEveryPrintedFixActuallyClearsTheFloor() throws {
        let floor = 5.0
        let card = hisFailingCard()
        let thicknessMM = card.cellsPerMember * card.cellMM
        let p = try XCTUnwrap(diagnose(card).problems
            .first { $0.what.hasPrefix("Not certifiable") })

        let deeper = try XCTUnwrap(number(in: p.fixes[0]))
        XCTAssertGreaterThanOrEqual(deeper / card.cellMM, floor,
                                    "\(deeper) mm deep at a \(card.cellMM) mm cell "
                                    + "is \(deeper / card.cellMM) across — still fails")

        let finer = try XCTUnwrap(number(in: p.fixes[1]))
        XCTAssertGreaterThanOrEqual(thicknessMM / finer, floor,
                                    "a \(finer) mm cell across \(thicknessMM) mm "
                                    + "is \(thicknessMM / finer) — still fails")
    }

    /// The first decimal number in a fix string.
    private func number(in s: String) -> Double? {
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: "0123456789.").inverted
        return scanner.scanDouble()
    }

    /// ★ §3(c) — EVERY FAILURE, NOT THE FIRST. The strut is 0.32 mm against a
    /// 0.45 mm nozzle: that lattice cannot be printed, and his panel said nothing.
    /// "A panel that flags one problem and hides another is worse than one that
    /// flags none."
    func testTheStrutBelowTheNozzleIsALSOReported() throws {
        let d = diagnose(hisFailingCard())
        XCTAssertEqual(d.problems.count, 2,
                       "§3(c): TWO failures on this card, not one")
        let p = try XCTUnwrap(d.problems.first { $0.what.hasPrefix("Too thin") })
        XCTAssertEqual(p.what, "Too thin to print — the struts are finer than the nozzle.")
        XCTAssertEqual(p.measured, "0.32 mm strut, nozzle is 0.45 mm.")
        XCTAssertEqual(p.fixes.first, "Raise the density above 5%.")
    }

    /// The badge SAYS there are two, so the second cannot hide behind the first
    /// even before the pop-up is opened.
    func testTheBadgeCountsTheProblems() {
        XCTAssertEqual(diagnose(hisFailingCard()).badge,
                       "Won't certify — 2 problems, tap for the fix")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §3(d)/§3(e)/R14 — plain language, short

    /// ★ NO JARGON ON THE BADGE. "Out of regime" meant nothing to the person who
    /// designed the project.
    func testTheBadgeCarriesNoJargon() {
        for card in [hisFailingCard(),
                     LatticeFaceCard(faceID: 1, depthMM: 4, heldVoxels: 0,
                                     heldVolumeMM3: 0, heldMassG: 0, cellMM: 0,
                                     relativeDensity: 0, strutDiameterMM: 0,
                                     cellsPerMember: 0, verdict: .noMaterial)] {
            let badge = diagnose(card).badge ?? ""
            for jargon in ["regime", "homogeniz", "homogenis", "cells per member",
                           "scale separation", "certifiable band"] {
                XCTAssertFalse(badge.lowercased().contains(jargon),
                               "§3(d): the badge must not say \"\(jargon)\"")
            }
        }
    }

    /// ★ R14 — OVER ~25 WORDS ON THE BADGE IS A FAILURE. Asserted over every
    /// badge this type can produce, not just the one in the fixture.
    func testTheBadgeStaysUnderTwentyFiveWords() {
        let cards = [
            hisFailingCard(),
            LatticeFaceCard(faceID: 2, depthMM: 4, heldVoxels: 0, heldVolumeMM3: 0,
                            heldMassG: 0, cellMM: 0, relativeDensity: 0,
                            strutDiameterMM: 0, cellsPerMember: 0,
                            verdict: .noMaterial),
            // strut-only failure
            LatticeFaceCard(faceID: 3, depthMM: 30, heldVoxels: 900,
                            heldVolumeMM3: 100, heldMassG: 10, cellMM: 5,
                            relativeDensity: 0.05, strutDiameterMM: 0.30,
                            cellsPerMember: 6, verdict: .outOfRegime),
        ]
        for c in cards {
            let words = (diagnose(c).badge ?? "")
                .split(whereSeparator: { $0 == " " }).count
            XCTAssertLessThanOrEqual(words, 25,
                                     "R14: the badge is \(words) words")
        }
    }

    /// ★ §3(e) — THE POP-UP LEADS WITH THE FIX. The line after the problem
    /// statement is the fix, not the measurement.
    func testThePopoverLeadsWithTheFix() {
        let lines = diagnose(hisFailingCard()).popoverText
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(String(lines[0]),
                       "Not certifiable — too few struts across this wall.")
        XCTAssertEqual(String(lines[1]), "Make it deeper: 24.7 mm.",
                       "§3(e): the FIX comes before the number it came from")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: the cases that must stay silent

    /// ★ A CLEAN CARD GETS NO BADGE. A panel that cries wolf is the other half of
    /// the same defect.
    func testACertifiableCardIsSilent() {
        // Face 24 at 24.7 mm — his own card that already clears the floor.
        let ok = LatticeFaceCard(faceID: 24, depthMM: 24.7, heldVoxels: 5_000,
                                 heldVolumeMM3: 24_000, heldMassG: 30,
                                 cellMM: 4.93, relativeDensity: 0.35,
                                 strutDiameterMM: 0.9, cellsPerMember: 5.01,
                                 verdict: .certified)
        let d = diagnose(ok)
        XCTAssertTrue(d.isClean, "a certifiable card must carry no badge")
        XCTAssertTrue(d.problems.isEmpty)
    }

    /// ★ AND FACE 16 AT 20.0 mm GIVES 4.06 AND STILL DOES NOT CLEAR IT — the
    /// borderline case §3 names, which a "close enough" rule would have passed.
    func testTheBorderlineCaseStillFails() {
        let near = LatticeFaceCard(faceID: 16, depthMM: 20.0, heldVoxels: 9_000,
                                   heldVolumeMM3: 44_000, heldMassG: 55,
                                   cellMM: 4.93, relativeDensity: 0.35,
                                   strutDiameterMM: 0.9, cellsPerMember: 4.06,
                                   verdict: .outOfRegime)
        let d = diagnose(near)
        XCTAssertFalse(d.isClean, "4.06 is under the floor of 5 and must fail")
        XCTAssertEqual(d.problems.first?.measured, "4.1 struts across, needs 5.")
    }

    /// Nothing to lattice reads as nothing to lattice — not as a cell failure.
    func testNoMaterialSaysSo() {
        let empty = LatticeFaceCard(faceID: 9, depthMM: 2, heldVoxels: 0,
                                    heldVolumeMM3: 0, heldMassG: 0, cellMM: 0,
                                    relativeDensity: 0, strutDiameterMM: 0,
                                    cellsPerMember: 0, verdict: .noMaterial)
        let d = diagnose(empty)
        XCTAssertEqual(d.badge, "Holds nothing — nothing to lattice")
        XCTAssertEqual(d.problems.count, 1)
    }
}

// LatticeStageModeTests — ★★★ THE MODE MUST BE CORE'S DISTINCTION, NOT THE APP'S
// (maintainer, 2026-08-21: "If structural is selected, use as normal. If aesthetic is
// selected then the floor number of cells can go down to 2 and no need for
// certification").
//
// ★ WHY THESE ASSERTIONS AND NOT SNAPSHOT TESTS OF THE MODAL. What can actually go wrong
// here is not layout — it is the app quietly authoring a number or a claim that core
// already owns. The strut-diameter law was re-derived in Swift once and came out 1.4-1.7x
// adrift; the caveat sentence was paraphrased in Swift for one build on this very branch.
// So every bar below pins an app-side value to a CORE-side one and fails if they part.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeStageModeTests: XCTestCase {

    private let topology = "octet"

    /// Core's accuracy floor — the fixed 5 the structural path must always take.
    private var accuracyFloor: Double {
        TopOptKit.latticeLimits(topology: topology).minCellsPerMember
    }

    /// ★★★ THERE IS NO DEFAULT. He asked for a modal that "cannot be changed again
    /// afterwards"; the other half of that is that it is never answered FOR him. A
    /// default would let a part be graded under one claim and read under the other with
    /// nothing on screen saying which.
    func testAFreshLatticeHasNoModeSoTheStageMustAsk() {
        XCTAssertNil(LatticeSettings().stageMode,
                     "★ a default mode would mean the modal never appears and the "
                     + "receipt's claim was chosen by us, not by him")
    }

    /// ★ The mode reaches core as core's own enum, not as a presentation flag.
    /// `GradingIntent`: 0 structural, 1 aesthetic.
    func testTheModeMapsOntoCoresGradingIntent() {
        XCTAssertEqual(LatticeStageMode.structural.coreIntent, 0)
        XCTAssertEqual(LatticeStageMode.aesthetic.coreIntent, 1)
    }

    /// ★★ STRUCTURAL NEVER RELAXES, whatever the material is doing. The certificate has
    /// to hold over the whole part, so the utilisation is irrelevant to it.
    func testStructuralAlwaysTakesCoresAccuracyFloor() {
        for u in [0.0, 0.01, 0.25, 0.5, 0.99, 1.0] {
            XCTAssertEqual(
                LatticeStageMode.structural.cellsPerMemberFloor(
                    topology: topology, utilisation: u),
                accuracyFloor, accuracy: 1e-12,
                "★ structural relaxed at utilisation \(u) — the certificate covers the "
                + "whole part, so there is nothing for it to relax against")
        }
    }

    /// ★★★ THE THING HE ASKED FOR: aesthetic may go down to 2, and NOT below it.
    ///
    /// 2 rather than 1 because 2 is the lowest cell count MEASURED under the same bending
    /// case the accuracy floor uses (+8.5 %). The percolation floor of 1.0 was measured
    /// axially at rho ~= 0.199 and its own declaration warns it "must not be quoted
    /// unconditionally" — so it is not what this rule bottoms out at.
    func testAestheticReachesTwoOnAnUnworkedMemberAndNeverGoesBelowIt() {
        let hard = TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: topology)
        XCTAssertEqual(hard, 2.0, accuracy: 1e-12,
                       "★ core's hard floor is the number he named")

        let unworked = LatticeStageMode.aesthetic.cellsPerMemberFloor(
            topology: topology, utilisation: 0.0)
        XCTAssertEqual(unworked, hard, accuracy: 1e-12,
                       "★ a member carrying nothing should reach the hard floor — that "
                       + "is the whole point of the mode on his thin back wall")

        for u in stride(from: 0.0, through: 1.0, by: 0.05) {
            let f = LatticeStageMode.aesthetic.cellsPerMemberFloor(
                topology: topology, utilisation: u)
            XCTAssertGreaterThanOrEqual(f, hard, "★ below core's hard floor at u=\(u)")
            XCTAssertLessThanOrEqual(f, accuracyFloor,
                                     "★ aesthetic must never ask for MORE than the "
                                     + "accuracy floor — it relaxes, it does not tighten")
        }
    }

    /// ★ AND IT IS MONOTONE. A member working harder may never be allowed a coarser cell
    /// than one working less hard; a non-monotone rule would put the coarsest lattice
    /// exactly where the stress is.
    func testTheAestheticFloorRisesWithUtilisation() {
        var previous = -Double.infinity
        for u in stride(from: 0.0, through: 1.0, by: 0.05) {
            let f = LatticeStageMode.aesthetic.cellsPerMemberFloor(
                topology: topology, utilisation: u)
            XCTAssertGreaterThanOrEqual(
                f, previous - 1e-12,
                "★ the floor FELL going from a lesser utilisation to \(u) — that would "
                + "coarsen the lattice as the load rises")
            previous = f
        }
        // The curve itself, printed rather than described — it is steeper than "down to
        // 2" suggests and anyone reading this file should see where it actually bends.
        let curve = stride(from: 0.0, through: 1.0, by: 0.1).map {
            String(format: "%.0f%%:%.2g", $0 * 100,
                   LatticeStageMode.aesthetic.cellsPerMemberFloor(
                    topology: topology, utilisation: $0))
        }
        print("aesthetic floor vs utilisation — " + curve.joined(separator: "  "))
    }

    /// ★★ ABSENCE OF MEASUREMENT IS NOT PERMISSION TO RELAX. A voxel whose utilisation
    /// we could not compute takes the accuracy floor, and that rule lives in CORE — this
    /// bar exists to catch an app-side "0 means unloaded" shortcut being added later.
    func testAnUnmeasurableUtilisationTakesTheAccuracyFloor() {
        for u in [Double.nan, -1.0, -Double.infinity] {
            XCTAssertEqual(
                LatticeStageMode.aesthetic.cellsPerMemberFloor(
                    topology: topology, utilisation: u),
                accuracyFloor, accuracy: 1e-12,
                "★ utilisation \(u) is not a measurement; it must not buy a relaxation")
        }
    }

    /// ★★★ THE CLAIM IS CORE'S, WORD FOR WORD. It was paraphrased in Swift for one build
    /// on this branch. If someone retypes it, this fails.
    func testTheAestheticCaveatIsCoresOwnSentence() {
        let caveat = try? XCTUnwrap(LatticeStageMode.aesthetic.receiptCaveat)
        let core = TopOptKit.latticeAestheticDensityMeaning
        XCTAssertFalse(core.isEmpty, "★ core's sentence did not cross the bridge")
        XCTAssertTrue(core.contains(caveat ?? "\u{0}"),
                      "★ the modal is paraphrasing core rather than quoting it.\n"
                      + "  core says: \(core)\n"
                      + "  modal says: \(caveat ?? "nil")")
    }

    /// ★ Structural claims nothing extra, so it carries no caveat — an empty grey line
    /// under the structural card would read as a hedge on the certificate.
    func testStructuralCarriesNoCaveat() {
        XCTAssertNil(LatticeStageMode.structural.receiptCaveat)
    }

    /// ★★ AND THE ANSWER SURVIVES THE SAVE. Settings that vanished on save is a defect
    /// this branch has already paid for once (see LatticeSettingsPersistTests); the mode
    /// is the one field where losing it silently changes what the receipt claims.
    func testTheChosenModeSurvivesEncodingAndDecoding() throws {
        for mode in LatticeStageMode.allCases {
            var s = LatticeSettings()
            s.stageMode = mode
            let back = try JSONDecoder().decode(
                LatticeSettings.self, from: JSONEncoder().encode(s))
            XCTAssertEqual(back.stageMode, mode,
                           "★ the mode was lost on the round trip — the stage would ask "
                           + "again and could be answered the other way")
        }
    }

    /// ★ A pre-mode project.json has no `stageMode` key. It must decode, and it must
    /// decode as UNANSWERED rather than as structural-by-omission.
    func testAProjectSavedBeforeTheModeExistedDecodesAsUnanswered() throws {
        let data = try JSONEncoder().encode(LatticeSettings())
        var obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "stageMode")
        let back = try JSONDecoder().decode(
            LatticeSettings.self,
            from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(back.stageMode,
                     "★ an old project must be ASKED, not assumed structural")
    }
}

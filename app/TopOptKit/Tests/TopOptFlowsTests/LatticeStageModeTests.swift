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

    /// ★★★ SUPERSEDED, NOT DELETED — AND THE ASSERTION IS NOW THE OPPOSITE ONE.
    ///
    /// This bar used to require the aesthetic floor to RISE with utilisation, and it
    /// passed: the adaptive rule is an accuracy rule, so it gave 2 cells only below
    /// 11.8 % utilisation, 3 below 24.4 %, and the accuracy floor of 5 above that. That
    /// is exactly why his declared walls kept going solid, and on 2026-08-21 he ruled it
    /// out: "wire the Aesthetic lattice to *always* lattice at 2 cells/member max … The
    /// rule is we lattice *WHEREVER* it is asked of us."
    ///
    /// So the floor is FLAT now, and this measures the flatness — a re-armed adaptive
    /// rule would fail here rather than quietly refuse a wall again.
    func testTheAestheticFloorIsFlatWhateverTheMemberIsCarrying() {
        let hard = TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: topology)
        for u in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(
                LatticeStageMode.aesthetic.cellsPerMemberFloor(
                    topology: topology, utilisation: u),
                hard, accuracy: 1e-12,
                "★ the floor moved at u=\(u) — aesthetic must not ration on accuracy")
        }
        // Printed, so the curve that used to bend here is visibly a line.
        let curve = stride(from: 0.0, through: 1.0, by: 0.1).map {
            String(format: "%.0f%%:%.2g", $0 * 100,
                   LatticeStageMode.aesthetic.cellsPerMemberFloor(
                    topology: topology, utilisation: $0))
        }
        print("aesthetic floor vs utilisation — " + curve.joined(separator: "  "))
    }

    /// ★ THE POSITIVE CONTROL FOR THE BAR ABOVE. A flat-line assertion is worth nothing
    /// unless something on this machine is NOT flat — core's adaptive rule still exists
    /// and still bends, it is simply no longer what the mode asks for.
    func testCoresAdaptiveRuleStillBendsSoTheFlatnessBarMeansSomething() {
        let budget = TopOptKit.latticeAestheticErrorBudgetDefault
        let low = TopOptKit.latticeAestheticCellsPerMemberFloor(
            topology: topology, utilisation: 0.0, errorBudget: budget)
        let high = TopOptKit.latticeAestheticCellsPerMemberFloor(
            topology: topology, utilisation: 1.0, errorBudget: budget)
        XCTAssertGreaterThan(high, low,
            "★ core's adaptive rule is flat too — then the bar above proves nothing")
    }

    /// ★★★ ALSO SUPERSEDED, AND THIS ONE MATTERED MOST IN PRACTICE. It used to require
    /// that an unmeasurable utilisation take the ACCURACY floor — "absence of
    /// measurement is not permission to relax". Sound for a mode making a strength
    /// claim; aesthetic makes none, and the consequence on his part was that whether a
    /// wall latticed depended on whether the FEA had landed yet.
    ///
    /// The floor no longer reads utilisation at all, so there is nothing for a missing
    /// measurement to change. That is the bar now: a solve arriving must not move it.
    func testAMissingMeasurementChangesNothing() {
        let hard = TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: topology)
        for u in [Double.nan, -1.0, -Double.infinity, 0.0, 0.5, 1.0] {
            XCTAssertEqual(
                LatticeStageMode.aesthetic.cellsPerMemberFloor(
                    topology: topology, utilisation: u),
                hard, accuracy: 1e-12,
                "★ utilisation \(u) moved the aesthetic floor")
        }
        XCTAssertLessThan(hard, accuracyFloor,
                          "★ the relaxation must still BE one — 2 below the accuracy 5")
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

// RecommendThePrintedObjectTests — the recommendation ranks the object that
// would actually come off the printer (task 2026-08-08-lattice-variant-margin-
// tolerance, S2).
//
// THE RULING BEING IMPLEMENTED. PR 311 measured that "the last accepted rung" —
// the lightest SOLID — is the HEAVIEST of the maintainer's four latticed objects,
// and pinned that behaviour rather than change it, because which object the
// recommendation should rank was his call. He ruled: rank by mass, because the
// point is dropping mass and more lattice is lighter. So the rule becomes "the
// lightest object that would actually be EXPORTED", where a rung's exported
// object is its ACCEPTED lattice when it has one and its solid otherwise.
//
// DRIVEN BY HIS OWN RUN, like every test in LatticeVariantsOnScreenTests: worker
// job ca62f91cba4b422d replayed through the real `RemoteRun` against a real HTTP
// socket, off the captured receipts and checkpoint lines under
// evidence/2026-08-07-lattice-variants-on-screen/run_his/.
//
//   rung   solid (g)   latticed (g)   would print
//   0.68     543.73        215.16       215.16   ← LIGHTEST, and now RECOMMENDED
//   0.52     473.32        239.93       239.93
//   0.38     412.47        244.78       244.78
//   0.26     360.30        246.38       246.38   ← what the old rule recommended
//
// 31.22 g / 12.7 % is what the old rule cost him.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class RecommendThePrintedObjectTests: XCTestCase {

    // MARK: - his run

    /// The same replay `LatticeVariantsOnScreenTests` uses. Kept as its own helper
    /// so this file states its own fixture rather than depending on another test
    /// case's private one.
    @MainActor
    private func hisResultsModel() throws -> ResultsModel {
        try HisRunReplay.resultsModel()
    }

    // ══════════════════════════════════════════════════════════════════════
    // R2 — THE FAILING TEST
    // ══════════════════════════════════════════════════════════════════════

    /// *** THE FAILING TEST (bar R2). ***
    ///
    /// Before this task the recommendation was `variants.count - 1` and landed on
    /// the vf=0.26 SOLID tab at 360.30 g, whose lattice — the object he would print
    /// if he tapped Export on the recommendation's own rung — is the heaviest of
    /// the four at 246.38 g. It must land on the vf=0.68 rung's LATTICED tab, at
    /// 215.16 g.
    @MainActor
    func testTheRecommendationIsTheLightestObjectThatWouldBePrinted() throws {
        let model = try hisResultsModel()
        let recommended = try XCTUnwrap(model.tabs.first { $0.isRecommended },
                                        "exactly one tab carries the recommendation")
        XCTAssertEqual(model.tabs.filter(\.isRecommended).count, 1,
                       "exactly one recommendation, still")

        XCTAssertTrue(recommended.isLatticed,
                      "the object he would print on his run is a LATTICE — the rule "
                      + "ranks the exported object, and every rung of this run has "
                      + "an accepted one")
        XCTAssertEqual(recommended.massGrams, 215.16, accuracy: 0.01,
                       "…the lightest of the four latticed objects, on the vf=0.68 "
                       + "rung — not the 246.38 g lattice of the rung the old "
                       + "'last accepted rung' rule pointed at")
        XCTAssertEqual(recommended.variantIndex, 0,
                       "which is the FIRST rung of the ladder, the heaviest solid — "
                       + "the direction the two masses run is opposite")
    }

    /// The recommendation is the minimum over the printed objects, not a preference
    /// for lattices: whatever weighs least wins, checked against every rung.
    @MainActor
    func testTheRecommendationIsTheMinimumOverEveryRungsPrintedObject() throws {
        let model = try hisResultsModel()
        let recommended = try XCTUnwrap(model.tabs.first { $0.isRecommended })
        let printed = model.printedObjectPerRung
        XCTAssertEqual(printed.count, 4, "one printed object per accepted rung")
        for p in printed {
            XCTAssertGreaterThanOrEqual(
                p.massGrams, recommended.massGrams - 0.001,
                "no rung would print anything lighter than the recommendation")
        }
        XCTAssertEqual(printed.map { $0.massGrams }.min() ?? 0, 215.16, accuracy: 0.01)
    }

    // ══════════════════════════════════════════════════════════════════════
    // S2(b) — the acceptance condition is not optional
    // ══════════════════════════════════════════════════════════════════════

    /// A rung whose LATTICE was refused falls back to its SOLID for ranking. The
    /// verdict read is the latticed object's OWN — core's `lattice_accepted`
    /// (`core/src/cli/run_job.cpp:2171`, the composite certification's `accepted`
    /// AND a certifiable outer finish), carried to the app on the receipt
    /// (`LatticeVariantAlternative.receiptFacts`) and on the `LATTICE …`
    /// checkpoint line, never the RUNG's `accepted`.
    @MainActor
    func testARefusedLatticeFallsBackToItsSolidForRanking() throws {
        // His run, with the lightest lattice (vf=0.68, 215.16 g) marked NOT
        // certified. Its rung must now be ranked on its 543.73 g solid, so the
        // recommendation moves to the next-lightest printed object — the vf=0.52
        // rung's 239.93 g lattice.
        let model = try HisRunReplay.resultsModel(refusingLatticeOnRungs: [0.68])
        let recommended = try XCTUnwrap(model.tabs.first { $0.isRecommended })
        XCTAssertTrue(recommended.isLatticed)
        XCTAssertEqual(recommended.massGrams, 239.93, accuracy: 0.01,
                       "the refused 215.16 g lattice is not a printable object, so "
                       + "it cannot be recommended")
        XCTAssertEqual(recommended.variantIndex, 1)

        // …and the refused lattice's tab is still THERE, with its own mass and its
        // NOT CERTIFIED badge. Falling back for RANKING must not hide the object.
        let refused = try XCTUnwrap(
            model.tabs.first { $0.isLatticed && $0.variantIndex == 0 })
        XCTAssertEqual(refused.massGrams, 215.16, accuracy: 0.01)
        XCTAssertEqual(refused.latticeAccepted, false)
        XCTAssertFalse(refused.isRecommended)
    }

    /// With EVERY lattice refused, the rule collapses to what it always was: the
    /// lightest solid, i.e. the last accepted rung.
    @MainActor
    func testWithNoCertifiedLatticeTheRuleIsTheOldOne() throws {
        let model = try HisRunReplay.resultsModel(
            refusingLatticeOnRungs: [0.68, 0.52, 0.38, 0.26])
        let recommended = try XCTUnwrap(model.tabs.first { $0.isRecommended })
        XCTAssertFalse(recommended.isLatticed)
        XCTAssertEqual(recommended.massGrams, 360.304, accuracy: 0.01,
                       "the lightest solid — the vf=0.26 rung, exactly as before")
        XCTAssertEqual(recommended.variantIndex, 3)
    }

    // ══════════════════════════════════════════════════════════════════════
    // S2(c) — the recommendation says WHICH OBJECT
    // ══════════════════════════════════════════════════════════════════════

    /// "−47%, 360 g" and "−47%, 215 g lattice" are different recommendations. The
    /// line the screen shows must name the object, its mass, and — when the two
    /// disagree — what following the OTHER one would have cost.
    @MainActor
    func testTheRecommendationLineNamesTheObjectItRecommends() throws {
        let model = try hisResultsModel()
        let line = try XCTUnwrap(model.recommendationLine)
        XCTAssertTrue(line.contains("latticed"),
                      "it says which of the rung's two objects: \(line)")
        XCTAssertTrue(line.contains("215 g"), line)
        XCTAssertTrue(line.contains("−20%") || line.contains("-20%"),
                      "…and which rung it came off: \(line)")
        // The rung's OTHER object is named as the other object, so 544 g can never
        // be read as the thing being recommended. This is the distinction S2(c)
        // asks for: "−47%, 360 g" and "−20%, 215 g latticed" are two different
        // recommendations, and the line has to be able to tell them apart.
        XCTAssertTrue(line.contains("the same rung's solid is 544 g"),
                      "…and it says what the rung's other object weighs: \(line)")
        XCTAssertTrue(line.range(of: "215 g")!.lowerBound
                        < line.range(of: "544 g")!.lowerBound,
                      "the RECOMMENDED object's mass comes first: \(line)")
    }

    /// On a run with no lattice at all the line still names the object — a solid —
    /// and never says "latticed".
    @MainActor
    func testTheRecommendationLineOnASolidOnlyRun() throws {
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5,
            massGrams: 100, supportVolumeVoxels: 0, meshTriangleCount: 1,
            worstCaseMargin: 2, accepted: true, v3Passes: true)
        let model = ResultsModel(
            projectName: "P",
            outcome: OptimizeOutcome(variants: [v], stoppedOnMargin: false,
                                     cancelled: false, acceptedCount: 1))
        let line = try XCTUnwrap(model.recommendationLine)
        XCTAssertTrue(line.contains("solid"), line)
        XCTAssertFalse(line.contains("latticed"), line)
        XCTAssertTrue(line.contains("100 g"), line)
    }

    // ══════════════════════════════════════════════════════════════════════
    // The guard rails
    // ══════════════════════════════════════════════════════════════════════

    /// A run whose masses never arrived (a remote run with no `fields.bin` scalars:
    /// `massGrams == 0`) cannot be ranked by mass, and must NOT be — 0 g would win
    /// every comparison and recommend the variant we know least about. It falls
    /// back to the ladder rule.
    @MainActor
    func testAMasslessRunFallsBackToTheLadderRule() throws {
        let vs = (0..<3).map { i in
            OptimizeVariant(
                requestedVolumeFraction: 0.7 - 0.2 * Double(i),
                achievedVolumeFraction: 0.7 - 0.2 * Double(i),
                massGrams: 0, supportVolumeVoxels: 0, meshTriangleCount: 1,
                worstCaseMargin: 2, accepted: true, v3Passes: true)
        }
        let model = ResultsModel(
            projectName: "P",
            outcome: OptimizeOutcome(variants: vs, stoppedOnMargin: false,
                                     cancelled: false, acceptedCount: 3))
        XCTAssertEqual(model.tabs.filter(\.isRecommended).count, 1)
        XCTAssertEqual(try XCTUnwrap(model.tabs.firstIndex(where: \.isRecommended)), 2,
                       "the last accepted rung, as before — no mass, no ranking")
    }

    /// A lattice whose receipt could not be read carries mass 0, which the UI
    /// renders as "n/a". It is not a 0 g object and must not win the ranking.
    @MainActor
    func testALatticeWithNoReadableMassCannotBeRecommended() throws {
        let alt = LatticeVariantAlternative(
            requestedVolumeFraction: 0.7, meshName: "variant_070_lattice.stl",
            massGrams: 0, accepted: true, margin: 900, triangleCount: 10,
            meshBytes: 1_000, receiptJSON: nil)
        let heavy = OptimizeVariant(
            requestedVolumeFraction: 0.7, achievedVolumeFraction: 0.7,
            massGrams: 500, supportVolumeVoxels: 0, meshTriangleCount: 1,
            worstCaseMargin: 2, accepted: true, v3Passes: true,
            latticeAlternative: alt)
        let light = OptimizeVariant(
            requestedVolumeFraction: 0.3, achievedVolumeFraction: 0.3,
            massGrams: 300, supportVolumeVoxels: 0, meshTriangleCount: 1,
            worstCaseMargin: 2, accepted: true, v3Passes: true)
        let model = ResultsModel(
            projectName: "P",
            outcome: OptimizeOutcome(variants: [heavy, light], stoppedOnMargin: false,
                                     cancelled: false, acceptedCount: 2))
        let recommended = try XCTUnwrap(model.tabs.first { $0.isRecommended })
        XCTAssertFalse(recommended.isLatticed,
                       "a lattice with no readable mass is not a 0 g object")
        XCTAssertEqual(recommended.massGrams, 300, accuracy: 0.01)
    }
}

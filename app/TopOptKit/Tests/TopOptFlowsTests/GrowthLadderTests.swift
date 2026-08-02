// Headless tests for the APP surface of the GROWTH LADDER (task
// 2026-08-03-growth-ladder). "Minimize plastic" OFF is no longer one un-searched
// 0.9 variant — it is a ladder that ADDS as little plastic as possible and
// recommends the smallest addition that passes.
//
// WHAT THIS PINS:
//
//   A1  *** NO SILENT MODE SWITCH (bar G7). *** Both modes are nameable in ONE
//       LINE, from ONE source (LadderMode), the two lines are different, and
//       neither is empty. The mapping from the checkbox is the ONE mapping.
//
//   A2  THE HEADLINE FLIPS WITH THE MODE. A growth variant (achieved > 1) reads
//       "+48%" ADDED, not the savings scale's "−−48%". A reduction variant is
//       untouched: same percent, same U+2212 label, same noun.
//
//   A3  THE ADDED-MATERIAL ACCOUNTING IS SURFACED (item 5): how much plastic was
//       added and how much of what prints was never in the model — and the
//       box-saturation caveat when the rung could not reach its ask.
//
//   A4  THE RESULTS SCREEN NAMES ITS LADDER, from the RUN's recorded flag (not the
//       project's current setting), and says what its recommendation means.
//
//   A5  THE FILENAME does not carry a negative saving. A growth export is
//       "…-plus48pct.stl", never "…--48pct.stl".
//
//   A6  A REDUCTION RUN IS UNTOUCHED end to end: no added-material line, the
//       reduction mode line, and the savings headline exactly as before.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class GrowthLadderTests: XCTestCase {

    // A stub variant. `added` non-nil marks it as coming off the GROWTH ladder —
    // the same signal the core uses (it measures added material only there).
    private func variant(vf: Double, mass: Double = 100,
                         added: AddedMaterial? = nil) -> OptimizeVariant {
        OptimizeVariant(
            requestedVolumeFraction: vf, achievedVolumeFraction: vf, massGrams: mass,
            supportVolumeVoxels: 0, meshTriangleCount: 100, worstCaseMargin: 2,
            accepted: true, v3Passes: true,
            orientation: SIMD3(0, 0, 1), maxStressMPa: 10,
            maxInterlayerTensionMPa: 5, inPlaneMargin: 2, interlayerMargin: 3,
            addedMaterial: added)
    }

    private func added(outsideFraction: Double = 0.677, netMass: Double = 0.397,
                       saturated: Bool = false) -> AddedMaterial {
        AddedMaterial(printedVoxels: 124, insidePart: 40, outsidePart: 84,
                      partSolidVoxels: 84, outsideFraction: outsideFraction,
                      outsideVolumeMM3: 672, netAddedVolumeMM3: 320,
                      outsideMassGrams: 0.833, netAddedMassGrams: netMass,
                      targetSaturated: saturated)
    }

    private func outcome(_ variants: [OptimizeVariant], growth: Bool) -> OptimizeOutcome {
        OptimizeOutcome(variants: variants, stoppedOnMargin: false, cancelled: false,
                        acceptedCount: variants.count, voxelVolumeMM3: 1,
                        growthLadder: growth)
    }

    // MARK: A1 — the two modes, one line each

    func testBothModesAreNameableInOneLine() {
        let reduce = LadderMode.of(minimizePlastic: true)
        let grow = LadderMode.of(minimizePlastic: false)
        XCTAssertEqual(reduce, .reduction)
        XCTAssertEqual(grow, .growth)

        for mode in LadderMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, "\(mode) has a name")
            XCTAssertFalse(mode.oneLine.isEmpty, "\(mode) is nameable in one line")
            XCTAssertFalse(mode.summaryToken.isEmpty)
            XCTAssertFalse(mode.resultsLine.isEmpty)
            // One LINE means one line.
            XCTAssertFalse(mode.oneLine.contains("\n"))
        }
        // The two lines say DIFFERENT things — the failure mode this bar exists for
        // is a mode change nobody can see.
        XCTAssertNotEqual(reduce.oneLine, grow.oneLine)
        XCTAssertNotEqual(reduce.title, grow.title)
        XCTAssertNotEqual(reduce.summaryToken, grow.summaryToken)
        XCTAssertNotEqual(reduce.resultsLine, grow.resultsLine)
        // Each names its direction in its own words.
        XCTAssertTrue(reduce.oneLine.lowercased().contains("remove"))
        XCTAssertTrue(grow.oneLine.lowercased().contains("add"))
        XCTAssertEqual(reduce.headlineNoun, "saved")
        XCTAssertEqual(grow.headlineNoun, "added")
    }

    // MARK: A2 — the headline flips with the mode

    func testGrowthHeadlineIsAddedNotNegativeSavings() {
        let m = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 1.4762, mass: 1.230, added: added()),
            variant(vf: 1.1905, mass: 0.992, added: added(outsideFraction: 0.63,
                                                          netMass: 0.159)),
        ], growth: true))
        XCTAssertEqual(m.tabs.count, 2)
        for tab in m.tabs { XCTAssertTrue(tab.isGrowth) }
        // +48% ADDED — not "−−48%", which is what the savings scale renders.
        XCTAssertEqual(m.tabs[0].growthPercent, 48)
        XCTAssertEqual(m.tabs[0].headlineLabel, "+48%")
        XCTAssertEqual(m.tabs[0].headlineNoun, "added")
        XCTAssertFalse(m.tabs[0].headlineLabel.contains("\u{2212}"))
        XCTAssertEqual(m.tabs[1].growthPercent, 19)
        XCTAssertEqual(m.tabs[1].headlineLabel, "+19%")
        // The RECOMMENDATION is still the last rung — which on a descending growth
        // ladder is the SMALLEST addition that passed.
        XCTAssertTrue(m.tabs.last?.isRecommended == true)
        XCTAssertFalse(m.tabs.first?.isRecommended == true)
    }

    func testReductionHeadlineIsUnchanged() {
        let m = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 0.7, mass: 199), variant(vf: 0.3, mass: 85),
        ], growth: false))
        for tab in m.tabs { XCTAssertFalse(tab.isGrowth) }
        XCTAssertEqual(m.tabs[0].savingsPercent, 30)
        XCTAssertEqual(m.tabs[0].headlineLabel, "\u{2212}30%")   // U+2212, per design
        XCTAssertEqual(m.tabs[0].headlineLabel, m.tabs[0].savingsLabel)
        XCTAssertEqual(m.tabs[0].headlineNoun, "saved")
        XCTAssertNil(m.tabs[0].addedMaterialLine)
    }

    // MARK: A3 — the added-material accounting is the headline

    func testAddedMaterialLineStatesHowMuchAndWhere() {
        let m = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 1.4762, mass: 1.230, added: added()),
        ], growth: true))
        let line = try? XCTUnwrap(m.addedMaterialLine)
        let text = line ?? ""
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("0.4 g"), "the mass ADDED is stated: \(text)")
        XCTAssertTrue(text.contains("68%"),
                      "the share printed OUTSIDE the model is stated: \(text)")
        XCTAssertTrue(text.lowercased().contains("outside your model"))
        // Nothing about saturation when the box held the ask.
        XCTAssertFalse(text.lowercased().contains("design box could not hold"))
    }

    func testSaturatedRungSaysSo() {
        let m = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 1.2, mass: 1.0, added: added(saturated: true)),
        ], growth: true))
        let text = m.addedMaterialLine ?? ""
        XCTAssertTrue(text.lowercased().contains("design box could not hold"),
                      "a rung that could not reach its ask must SAY so: \(text)")
    }

    // MARK: A4 — the results screen names its ladder, from the RUN

    func testResultsNamesTheLadderFromTheRun() {
        let grow = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 1.1, mass: 0.9, added: added()),
        ], growth: true))
        XCTAssertEqual(grow.ladderMode, .growth)
        XCTAssertEqual(grow.ladderModeLine, LadderMode.growth.resultsLine)
        XCTAssertTrue(grow.ladderModeLine.uppercased().contains("SMALLEST"),
                      "the growth line says what its recommendation MEANS")

        let reduce = ResultsModel(projectName: "P", outcome: outcome([
            variant(vf: 0.5, mass: 90),
        ], growth: false))
        XCTAssertEqual(reduce.ladderMode, .reduction)
        XCTAssertTrue(reduce.ladderModeLine.uppercased().contains("LIGHTEST"))
        XCTAssertNotEqual(grow.ladderModeLine, reduce.ladderModeLine)
    }

    // MARK: A5 — the export filename carries no negative saving

    func testGrowthExportFilename() {
        let grow = ResultsModel(projectName: "Bracket", outcome: outcome([
            variant(vf: 1.4762, mass: 1.230, added: added()),
        ], growth: true))
        XCTAssertEqual(grow.exportFilename, "Bracket-material-plus48pct.stl")
        XCTAssertFalse(grow.exportFilename.contains("--"))

        let reduce = ResultsModel(projectName: "Bracket", outcome: outcome([
            variant(vf: 0.7, mass: 199),
        ], growth: false))
        XCTAssertEqual(reduce.exportFilename, "Bracket-material-30pct.stl")
    }

    // MARK: A6 — persistence keeps the mode and the accounting

    func testOutcomeRoundTripKeepsGrowthFacts() throws {
        let o = outcome([variant(vf: 1.4762, mass: 1.230, added: added())], growth: true)
        let data = try OutcomeCodec.encode(OutcomeCodec.dto(from: o))
        let back = try OutcomeCodec.decode(data)
        XCTAssertTrue(back.growthLadder,
                      "a reopened growth run must not present itself as a reduction run")
        let a = try XCTUnwrap(back.variants.first?.addedMaterial)
        XCTAssertEqual(a.printedVoxels, 124)
        XCTAssertEqual(a.insidePart, 40)
        XCTAssertEqual(a.outsidePart, 84)
        XCTAssertEqual(a.partSolidVoxels, 84)
        XCTAssertEqual(a.netAddedMassGrams, 0.397, accuracy: 1e-12)
        XCTAssertEqual(a.outsideFraction, 0.677, accuracy: 1e-12)
        XCTAssertFalse(a.targetSaturated)
    }

    func testReductionOutcomeRoundTripsAsReduction() throws {
        let o = outcome([variant(vf: 0.7, mass: 199)], growth: false)
        let data = try OutcomeCodec.encode(OutcomeCodec.dto(from: o))
        let back = try OutcomeCodec.decode(data)
        XCTAssertFalse(back.growthLadder)
        XCTAssertNil(back.variants.first?.addedMaterial)
    }
}

import XCTest
@testable import TopOptFlows
@testable import TopOptKit

/// ★ THE RESULTS REDESIGN (his mockup, approved 2026-10-27): the versions, the checks, the details and Compare's rules.
@MainActor
final class ResultsRedesignTests: XCTestCase {

    /// His Carriage Arms strengthen run in miniature: Version 1 (just safe), Version 2 (+10%), Version 3 unreachable, the
    /// strongest possible limited at an anchor; three scenarios; built for 300%.
    static func strengthenOutcome() throws -> OptimizeOutcome {
        func sc(_ m1: Double, _ m3: Double, governs1: Bool) -> [[String: Any]] {
            [["name": "Scenario 1", "margin": m1, "governs": governs1, "unheld": false, "peak_mpa": 4.18, "peak_mm": [-18.2, 50.0, 103.9]],
             ["name": "Scenario 2", "margin": 6.39, "governs": false, "unheld": false],
             ["name": "Scenario 3", "margin": m3, "governs": !governs1, "unheld": false]]
        }
        let report: [String: Any] = [
            "safety_margin": 3.0,
            "scenarios": sc(7.86, 7.85, governs1: false),
            "variants": [["volume_fraction": 0.1264, "printed_fraction": 0.1264, "accepted": true],
                         ["volume_fraction": 0.2629, "printed_fraction": 0.2629, "accepted": true]],
            "strengthen": [
                "as_drawn_margin": 4.0, "margin_required": 3.0, "ceiling_margin": 8.338, "original_mass_g": 116.7,
                "coarse_resolution": 32,
                "cap": ["face_id": 12, "point": [0, 0, 0], "at_anchor_face": true, "at_load_face": false, "note": "x"],
                "versions": [
                    ["version": 1, "stress_cut": 0, "status": "verified", "volume_fraction": 0.1264, "verified_margin": 5.07,
                     "mass_g": 92.2, "mass_fraction_of_original": 0.79, "note": "", "target_margin": 3.0, "scenarios": sc(5.07, 7.36, governs1: true)],
                    ["version": 2, "stress_cut": 0, "status": "verified", "volume_fraction": 0.2629, "verified_margin": 7.83,
                     "mass_g": 120.9, "mass_fraction_of_original": 1.04, "note": "", "target_margin": 5.6, "scenarios": sc(7.91, 7.83, governs1: false)],
                    ["version": 3, "stress_cut": 0, "status": "unreachable", "volume_fraction": 0, "verified_margin": 0,
                     "mass_g": 0, "mass_fraction_of_original": 0, "note": "above 0.95 x the box filled solid", "target_margin": 8.6]]]]
        func v(_ vf: Double, _ g: Double, _ m: Double) -> OptimizeVariant {
            OptimizeVariant(requestedVolumeFraction: vf, achievedVolumeFraction: vf, massGrams: g, supportVolumeVoxels: 10,
                            meshTriangleCount: 100, worstCaseMargin: m, accepted: true, v3Passes: true,
                            minFeatureViolations: vf < 0.2 ? 1061 : 0, minFeatureWarning: "1061 regions may be thinner",
                            maxStressMPa: 6.3,   // a real run's report always carries its peak (the scale's top without a yield)
                            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
                            vonMisesField: (0..<64).map { Float($0) / 10 },            // a stress field → Stress
                            displacementField: (0..<375).map { _ in Float(0.01) })     // a displacement field → Load paths
        }
        return OptimizeOutcome(variants: [v(0.1264, 92.2, 14.4), v(0.2629, 120.9, 22.2)], stoppedOnMargin: false, cancelled: false,
                               acceptedCount: 2, gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1,
                               reportJSON: try JSONSerialization.data(withJSONObject: report))
    }

    func testTheVersionsAreCoresWithTheImpossibleOneGreyedAndItsReason() throws {
        let m = ResultsModel(projectName: "Arms", outcome: try Self.strengthenOutcome())
        let rows = ResultsVersions.rows(tabs: m.tabs, blocks: m.reportBlocks, requestedVF: { m.requestedVolumeFraction(of: $0) })
        XCTAssertEqual(rows.map(\.title), ["Version 1 · just safe", "Version 2 · +10%", "Version 3 · +10%"])
        XCTAssertEqual(rows.map(\.margin), [5.07, 7.83, nil], "★ the VERIFIED margin, never the tab's 14.4 / 22.2")
        XCTAssertNil(rows[2].tabIndex, "Version 3 cannot be picked")
        XCTAssertEqual(rows[2].subtitle, "Not possible — limited at an anchor")
        XCTAssertTrue(rows[0].subtitle.contains("5.1× ✓"), rows[0].subtitle)
        XCTAssertEqual(rows[0].headline, "79% of the original", "★ a strengthen version weighs against the part as drawn")
    }

    func testTheChecksAreOneLineEachInHisOrder() throws {
        let m = ResultsModel(projectName: "Arms", outcome: try Self.strengthenOutcome())
        let c = ResultsChecks.checks(tab: m.selected, margin: 5.07, required: 3, safetyMargin: 3,
                                     scenarios: m.scenarios(for: m.selected), thinJoints: 0, bridged: false)
        XCTAssertEqual(c.first?.title, "Strong enough")
        XCTAssertEqual(c.first?.detail, "5.1× your load · built for 300%")
        XCTAssertTrue(c.contains { $0.title == "Every scenario holds" && $0.detail.hasSuffix(m.scenarios(for: m.selected).first { $0.governs }!.name) })
        XCTAssertTrue(c.contains { $0.title.hasPrefix("Print it") })
        XCTAssertFalse(c.contains { $0.title.lowercased().contains("smooth") })
        XCTAssertEqual(ResultsChecks.checks(tab: m.selected, margin: 2.2, required: 3, safetyMargin: 3, scenarios: [],
                                            thinJoints: 2, bridged: true).map(\.title).first, "Not strong enough")
    }

    func testEachVersionCarriesItsOwnScenariosAndPeaks() throws {
        let m = ResultsModel(projectName: "Arms", outcome: try Self.strengthenOutcome())
        let v1 = try XCTUnwrap(m.tabs.first { m.requestedVolumeFraction(of: $0) == 0.1264 })
        let s = m.scenarios(for: v1)
        XCTAssertEqual(s.first { $0.governs }?.name, "Scenario 1", "★ Version 1's own worst case, not the run's")
        XCTAssertEqual(s[0].peakMPa, 4.18)
        XCTAssertEqual(s[0].peakMM, SIMD3(-18.2, 50.0, 103.9))
    }

    func testDetailsHoldWhatTheScreenUsedToStack() throws {
        let m = ResultsModel(projectName: "Arms", outcome: try Self.strengthenOutcome())
        let row = ResultsVersions.rows(tabs: m.tabs, blocks: m.reportBlocks, requestedVF: { m.requestedVolumeFraction(of: $0) })
            .first { $0.tabIndex == m.selectedIndex }
        let strength = m.detailRows(.strength, version: row)
        XCTAssertTrue(strength.contains { $0.label == "Verified margin" }, "\(strength)")
        XCTAssertTrue(strength.contains { $0.label == "Strongest possible" && $0.value.contains("anchor") })
        XCTAssertTrue(strength.contains { $0.label == "Built for" })
        XCTAssertEqual(m.detailRows(.scenarios, version: row).count, 3)
        XCTAssertTrue(m.detailRows(.run, version: row).contains { $0.label == "Ladder" })
        for t in ResultsDetailsTab.allCases {
            XCTAssertFalse(m.detailRows(t, version: row).contains { ($0.label + $0.value).lowercased().contains("smooth") },
                           "★ nothing mentions smoothing")
        }
    }

    /// His Compare rules (note 2026-10-27).
    func testCompareTwoVersionsReturnsOnTheFirstPick() {
        var s = ResultsCompareSession(candidates: [0, 1])
        XCTAssertFalse(s.offersLayouts, "two versions: no layout switch")
        s.use(1)
        XCTAssertEqual(s.chosen, 1, "★ Use this returns to Results on it")
    }

    func testCompareOnePairAtATimeBringsTheNextInTheLosersPlace() {
        var s = ResultsCompareSession(candidates: [0, 1, 2])
        XCTAssertTrue(s.offersLayouts)
        XCTAssertEqual(s.shown, [0, 1])
        s.use(1)
        XCTAssertNil(s.chosen, "not done: one more to compare")
        XCTAssertEqual(s.shown, [2, 1], "★ the next one pops up where the unused one was; the pick stays")
        s.use(2)
        XCTAssertEqual(s.chosen, 2, "the last pick returns")
    }

    func testCompareAllAtOnceReturnsOnASinglePick() {
        var s = ResultsCompareSession(candidates: [0, 1, 2])
        s.setLayout(.all)
        XCTAssertEqual(s.shown, [0, 1, 2])
        s.use(0)
        XCTAssertEqual(s.chosen, 0)
    }

    /// Smooth is gone from the Topology capsule (his note 2026-10-27).
    func testTheSmoothPageIsGone() {
        XCTAssertFalse(TopologyPage.shown(hasResults: true).contains(.smooth))
        XCTAssertTrue(TopologyPage.hiddenSegments(hasResults: true).contains(.tertiary))
    }
}

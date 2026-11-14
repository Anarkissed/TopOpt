import XCTest
@testable import TopOptFlows
@testable import TopOptKit

/// ★ His ruling 2026-10-28: a version core exports as 2+ bodies is ACCEPTED WITH A FLAG — "Prints in 2 pieces", one line per
/// bridge that couldn't hold — and never "joined into one part". (Seen on his iPad: a version with a 17 mm bridge that did
/// not hold printed in 2 pieces while the app said its two pieces were joined.) A lookalike report: never his job files.
@MainActor
final class PiecesFlagTests: XCTestCase {
    static func bodies(exported: Int, holds: [(Double, Bool)]) -> [String: Any] {
        ["exported": exported, "bridges": holds.count, "bridge_voxels": 10 * holds.count,
         "bridge_holds": holds.map { ["size_mm": $0.0, "hold_margin": $0.1 ? 2.0 : 0.6, "thickenings": 0, "held": $0.1] }]
    }

    /// V1 in two pieces (a 17 mm bridge that couldn't hold beside two that did), V2 one body joined by a bridge that held,
    /// V3 one body with no bridge.
    static func outcome() throws -> OptimizeOutcome {
        let report: [String: Any] = [
            "safety_margin": 1.5,
            "variants": [["volume_fraction": 0.02, "printed_fraction": 0.02, "accepted": true,
                          "bodies": bodies(exported: 2, holds: [(5.7, true), (17.2, false), (5.7, true)])],
                         ["volume_fraction": 0.07, "printed_fraction": 0.07, "accepted": true,
                          "bodies": bodies(exported: 1, holds: [(13.4, true)])],
                         ["volume_fraction": 0.11, "printed_fraction": 0.11, "accepted": true,
                          "bodies": bodies(exported: 1, holds: [])]],
            "strengthen": [
                "as_drawn_margin": 2.0, "margin_required": 1.5, "ceiling_margin": 8.0, "original_mass_g": 116.7,
                "coarse_resolution": 32,
                "versions": [
                    ["version": 1, "stress_cut": 0, "status": "verified", "volume_fraction": 0.02, "verified_margin": 3.08,
                     "mass_g": 80, "mass_fraction_of_original": 0.69, "note": "", "target_margin": 1.5],
                    ["version": 2, "stress_cut": 0, "status": "verified", "volume_fraction": 0.07, "verified_margin": 4.57,
                     "mass_g": 95, "mass_fraction_of_original": 0.81, "note": "", "target_margin": 1.65],
                    ["version": 3, "stress_cut": 0, "status": "verified", "volume_fraction": 0.11, "verified_margin": 5.1,
                     "mass_g": 110, "mass_fraction_of_original": 0.94, "note": "", "target_margin": 1.8]]]]
        func v(_ vf: Double) -> OptimizeVariant {
            OptimizeVariant(requestedVolumeFraction: vf, achievedVolumeFraction: vf, massGrams: 80, supportVolumeVoxels: 0,
                            meshTriangleCount: 1, worstCaseMargin: 3, accepted: true, v3Passes: true,
                            minFeatureViolations: 0, minFeatureWarning: "", maxStressMPa: 5,
                            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
                            vonMisesField: [], displacementField: [])
        }
        return OptimizeOutcome(variants: [v(0.02), v(0.07), v(0.11)], stoppedOnMargin: false, cancelled: false,
                               acceptedCount: 3, gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1,
                               reportJSON: try JSONSerialization.data(withJSONObject: report))
    }

    func testAVersionInPiecesIsFlaggedEverywhereAndNeverCalledJoined() throws {
        let m = ResultsModel(projectName: "Arms", outcome: try Self.outcome())
        let b = try XCTUnwrap(m.reportBlocks)
        let tabs = m.tabs.filter { !$0.isLatticed }
        XCTAssertEqual(tabs.count, 3)

        // V1: two pieces, the 17 mm bridge named
        let f1 = try XCTUnwrap(m.piecesFlag(tabs[0]))
        XCTAssertEqual(f1.title, "Prints in 2 pieces")
        XCTAssertEqual(f1.lines, ["A 17 mm bridge between them couldn’t hold its load, so it was left out."])
        XCTAssertFalse(m.isBridged(tabs[0]), "★ never 'joined' when it prints in pieces")
        let checks1 = ResultsChecks.checks(tab: tabs[0], margin: 3.08, required: 1.5, safetyMargin: 1.5, scenarios: [],
                                           thinJoints: 0, bridged: m.isBridged(tabs[0]), pieces: m.piecesFlag(tabs[0]))
        let flag = try XCTUnwrap(checks1.first { $0.title == "Prints in 2 pieces" })
        XCTAssertEqual(flag.kind, .warn)
        XCTAssertTrue(flag.detail.contains("17 mm"))
        XCTAssertFalse(checks1.contains { $0.detail.contains("joined into one part") }, "★ the false line is gone")
        XCTAssertTrue(checks1.contains { $0.title == "Strong enough" }, "accepted: its certified margin stands (his ruling)")

        let cards = StrengthenText.cards(b)
        XCTAssertFalse(cards[0].bridged, "no BRIDGED badge on a version in pieces")
        XCTAssertTrue(cards[0].lines.contains("Prints in 2 pieces"))
        XCTAssertEqual(cards[0].status, "Verified", "accepted with a flag, not refused")
        let rows = ResultsVersions.rows(tabs: m.tabs, blocks: b, requestedVF: { m.requestedVolumeFraction(of: $0) })
        XCTAssertTrue(rows[0].subtitle.hasSuffix(" · in 2 pieces"), rows[0].subtitle)
        m.select(tabs[0].index)
        let details = m.detailRows(.strength, version: rows[0])
        XCTAssertTrue(details.contains { $0.label == "Pieces" && $0.value.hasPrefix("Prints in 2 pieces") })
        XCTAssertFalse(details.contains { $0.label == "Split joined" })

        // V2: one body, every bridge held → joined (the old line, still true here)
        XCTAssertNil(m.piecesFlag(tabs[1]))
        XCTAssertTrue(m.isBridged(tabs[1]))
        XCTAssertTrue(cards[1].bridged)
        XCTAssertFalse(rows[1].subtitle.contains("pieces"))
        // V3: nothing to say
        XCTAssertNil(m.piecesFlag(tabs[2])); XCTAssertFalse(m.isBridged(tabs[2])); XCTAssertFalse(cards[2].bridged)
    }

    func testThreePiecesAndPiecesWithNoFailedBridge() {
        let three = StrengthenText.piecesFlag(VariantBodies.decode(Self.bodies(exported: 3, holds: [(9, false), (12, false)])))
        XCTAssertEqual(three?.title, "Prints in 3 pieces")
        XCTAssertEqual(three?.lines.count, 2, "one line per bridge that couldn't hold")
        let own = StrengthenText.piecesFlag(VariantBodies.decode(Self.bodies(exported: 2, holds: [])))
        XCTAssertEqual(own?.lines, ["Each piece holds on its own anchors."])
        XCTAssertNil(StrengthenText.piecesFlag(VariantBodies.decode(Self.bodies(exported: 1, holds: [(5, true)]))))
    }
}

#if canImport(AppKit) && canImport(MetalKit)
import SwiftUI

@MainActor
final class PiecesFlagHostedTests: XCTestCase {
    private let ui = LoadScenarioHostedTests()

    /// ★ The flag is on his screen: Version 1's Checks say "Prints in 2 pieces", its Versions line says "in 2 pieces", and
    /// picking Version 2 (one body, its bridge held) takes the flag away.
    func testThePiecesFlagIsOnHisScreen() throws {
        let o = try PiecesFlagTests.outcome()
        let rm = ResultsModel(projectName: "Arms", outcome: o)
        let size = CGSize(width: 1032, height: 1376)
        let h = ui.host(ResultsScreen(projectName: "Arms", outcome: o, resultsModel: rm).frame(width: size.width, height: size.height),
                        size: size)
        ui.pump(2)
        let v1 = try XCTUnwrap(rm.tabs.first { !$0.isLatticed })
        rm.select(v1.index); ui.pump(1)
        let flag = try XCTUnwrap(h.frames.all["resultsCheck-Prints in 2 pieces"], "★ the flag is not in Checks; frames: \(h.frames.all.keys.sorted())")
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(flag))
        XCTAssertNil(h.frames.all["resultsCheck-Joined by a bridge"], "★ never 'joined' for a version in pieces")
        try ui.picture(h, "results_prints_in_2_pieces.png")
        let row2 = try XCTUnwrap(h.frames.all["resultsVersion-t\(rm.tabs.filter { !$0.isLatticed }[1].index)"])
        ui.click(h, CGPoint(x: row2.midX, y: row2.midY))
        XCTAssertNil(h.frames.all["resultsCheck-Prints in 2 pieces"], "Version 2 is one body")
        XCTAssertNotNil(h.frames.all["resultsCheck-Joined by a bridge"], "control: its bridge held, so it IS joined")
    }
}
#endif

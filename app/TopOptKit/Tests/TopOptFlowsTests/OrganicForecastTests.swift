import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ CELL-SIZE APPROVAL FOR ORGANIC (contract 2026-09-05). The core half is not
/// built; the UI is coded against the contract and gated on the block's presence.
final class OrganicForecastTests: XCTestCase {

    /// The contract's own example, verbatim in shape.
    private static let organicBlock: [String: Any] = [
        "organic_probe_version": 1,
        "algorithm": "organic", "growth": true,
        "candidates": [
            ["cell_mm": 4.5, "trace_seconds": 2.1,
             "regions": [
                ["face_id": 2, "region_id": 1, "cells_across": 2.7,
                 "curves_per_family": [14, 9, 6], "rooted_length_fraction": 0.97,
                 "traced_length_mm": 26100, "dead_fraction": 0.057,
                 "approved_structural": false, "approved_aesthetic": true,
                 "refusals": ["cells_across 2.7 < 4"]]],
             "approved_structural": false, "approved_aesthetic": true],
            ["cell_mm": 3.0, "trace_seconds": 3.4, "regions": [],
             "approved_structural": true, "approved_aesthetic": true],
            ["grade_mm": [3, 5], "trace_seconds": 2.8,
             "regions": [
                ["face_id": 2, "region_id": 1, "cells_across": 4.2,
                 "curves_per_family": [12, 8, 5], "rooted_length_fraction": 0.91,
                 "traced_length_mm": 24000, "dead_fraction": 0.06,
                 "approved_structural": false, "approved_aesthetic": true,
                 "refusals": ["rooted_length_fraction 0.91 < 0.95"]]],
             "approved_structural": false, "approved_aesthetic": true],
        ],
    ]

    private static let octetForecast: [String: Any] = [
        "region_voxels": 1000, "would_lattice_voxels": 800, "would_stay_solid_voxels": 200,
    ]

    private func forecastData(organic: Any?) throws -> Data {
        var o = Self.octetForecast
        if let organic { o["organic"] = organic }
        return try JSONSerialization.data(withJSONObject: o)
    }

    func testTheBlockParsesPerTheContract() throws {
        let f = try XCTUnwrap(LatticeForecast.parse(try forecastData(organic: Self.organicBlock)))
        let o = try XCTUnwrap(f.organic)
        XCTAssertEqual(o.probeVersion, 1)
        XCTAssertTrue(o.growth)
        XCTAssertEqual(o.candidates.count, 3)
        XCTAssertEqual(o.sizes.map { $0.cellMM }, [4.5, 3.0])
        XCTAssertEqual(o.grades.count, 1)
        XCTAssertEqual(o.grades[0].gradeMM, [3, 5])
        let c = o.sizes[0]
        XCTAssertEqual(c.traceSeconds, 2.1)
        XCTAssertEqual(c.regions.count, 1)
        XCTAssertEqual(c.regions[0].faceID, 2)
        XCTAssertEqual(c.regions[0].cellsAcross, 2.7)
        XCTAssertEqual(c.regions[0].curvesPerFamily, [14, 9, 6])
        XCTAssertEqual(c.regions[0].rootedLengthFraction, 0.97)
        XCTAssertEqual(c.refusals, ["cells_across 2.7 < 4"], "verbatim")
        XCTAssertFalse(c.approvedStructural)
        XCTAssertTrue(c.approvedAesthetic)
        XCTAssertEqual(c.label, "4.5 mm")
        XCTAssertEqual(o.grades[0].label, "3–5 mm")
    }

    /// Absent, malformed, or a version this build does not understand ⇒ nil, and
    /// the octet forecast itself still parses — "show the octet forecast alone".
    func testAbsentOrUnknownVersionMeansNoOrganicApprovals() throws {
        let plain = try XCTUnwrap(LatticeForecast.parse(try forecastData(organic: nil)))
        XCTAssertNil(plain.organic)
        XCTAssertEqual(plain.wouldLatticeVoxels, 800)
        var v2 = Self.organicBlock; v2["organic_probe_version"] = 2
        let future = try XCTUnwrap(LatticeForecast.parse(try forecastData(organic: v2)))
        XCTAssertNil(future.organic, "version-gated: no guessing at a contract we do not know")
        var noVersion = Self.organicBlock; noVersion.removeValue(forKey: "organic_probe_version")
        XCTAssertNil(try XCTUnwrap(LatticeForecast.parse(try forecastData(organic: noVersion))).organic)
        XCTAssertNil(try XCTUnwrap(LatticeForecast.parse(try forecastData(organic: "nonsense"))).organic)
    }

    /// Structural offers only approved_structural; Aesthetic offers all and badges.
    func testTheMenusLaw() throws {
        let o = try XCTUnwrap(OrganicForecast.parse(Self.organicBlock))
        let unapproved = o.sizes[0], approved = o.sizes[1]
        XCTAssertFalse(OrganicForecast.selectable(unapproved, structural: true))
        XCTAssertTrue(OrganicForecast.selectable(approved, structural: true))
        XCTAssertTrue(OrganicForecast.selectable(unapproved, structural: false), "Aesthetic allows all")
        XCTAssertTrue(OrganicForecast.badged(unapproved, structural: true))
        XCTAssertFalse(OrganicForecast.badged(unapproved, structural: false), "aesthetic-approved: no badge")
        XCTAssertFalse(OrganicForecast.badged(approved, structural: true))
    }

    /// The copy never promises a single piece, never says "certified", and says
    /// what structural approval means (ties, not margin).
    func testTheCopyKeepsTheContractsPromises() {
        for text in [OrganicForecast.structuralMeaning, OrganicForecast.aestheticMeaning,
                     OrganicForecast.notCertified] {
            XCTAssertFalse(text.lowercased().contains("contiguous"), text)
            XCTAssertFalse(text.lowercased().contains("single piece"), text)
            XCTAssertFalse(text.contains("certified") && !text.contains("Likely to certify"),
                           "never 'certified': \(text)")
        }
        XCTAssertTrue(OrganicForecast.structuralMeaning.contains("Likely to certify"))
        XCTAssertTrue(OrganicForecast.structuralMeaning.contains("will not be refused for disconnection"))
        XCTAssertTrue(OrganicForecast.structuralMeaning.contains("Stress margin needs the run"))
    }

    func testTheAnswerPersistsOnTheSettings() throws {
        var l = LatticeSettings()
        XCTAssertNil(l.organicForecast)
        l.organicForecast = try XCTUnwrap(OrganicForecast.parse(Self.organicBlock))
        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertEqual(back.organicForecast, l.organicForecast)
        // An untouched settings file carries no key for it.
        let plain = try JSONEncoder().encode(LatticeSettings())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(obj["organicForecast"])
    }

    /// The forecast request carries the candidate lists only for organic and only
    /// when the linked core's schema accepts them; this worktree's core does not.
    func testTheRequestIsProbeGated() {
        XCTAssertEqual(LatticeSettings.organicForecastCellsMM, [3, 3.5, 4, 4.5, 5, 6])
        XCTAssertEqual(LatticeSettings.organicForecastGradesMM, [[3, 5], [4, 6]])
        // The probe's verdict is a fact about the linked core; whichever it is, the
        // control must have passed for a true (a false control cannot be "wired").
        if TopOptKit.organicForecastProbeWired {
            XCTAssertTrue(TopOptKit.latticeSchemaAccepts(key: "forecast_only"))
        }
    }
}

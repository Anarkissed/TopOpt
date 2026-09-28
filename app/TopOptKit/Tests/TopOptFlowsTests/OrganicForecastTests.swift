import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE ORGANIC CELL-SIZE PROBE (final contract 2026-09-05): `organic_probe.json`
/// written inside a lattice-variant run; the UI is gated on the file.
final class OrganicForecastTests: XCTestCase {

    /// The contract's document, in shape.
    private static let probe: [String: Any] = [
        "organic_probe_version": 1, "algorithm": "organic", "growth": true,
        "transfer_ties": true,
        "rooted_gate": 0.95, "curves_per_family_gate": 2, "cells_across_advisory": 4.0,
        "candidates": [
            ["cell_min_mm": 4.5, "cell_max_mm": 4.5, "trace_seconds": 31.2, "curves": 412,
             "components": 79, "traced_length_mm": 26100, "rooted_length_fraction": 0.97,
             "candidate_voxels": 12480,
             "regions": [
                ["face_id": 2, "region_id": 1, "depth_mm": 12, "cells_across": 2.7,
                 "curves_per_family": [14, 9, 6], "components": 40,
                 "traced_length_mm": 26100, "rooted_length_fraction": 0.97,
                 "approved_structural": true, "approved_aesthetic": true,
                 "refusals": "", "advice": "2.7 cells across; the lattice behaves as one material past ~4"]],
             "predicted": ["ran": true, "verdict": "certified", "margin": 1.84,
                           "p99_mpa": 12.1, "max_mpa": 19.3, "allowable_mpa": 31.0,
                           "segments": 26773, "seconds": 41.0, "refusal": ""],
             "approved_structural": true, "approved_aesthetic": true],
            ["cell_min_mm": 6.5, "cell_max_mm": 6.5, "trace_seconds": 18.0, "curves": 120,
             "components": 30, "traced_length_mm": 9000, "rooted_length_fraction": 0.96,
             "candidate_voxels": 12480,
             "regions": [
                ["face_id": 2, "region_id": 1, "depth_mm": 12, "cells_across": 1.8,
                 "curves_per_family": [6, 3, 2], "components": 30,
                 "traced_length_mm": 9000, "rooted_length_fraction": 0.96,
                 "approved_structural": false, "approved_aesthetic": true,
                 "refusals": "predicted refused: p99 34.0 MPa > allowable 31.0", "advice": ""]],
             "predicted": ["ran": true, "verdict": "refused", "margin": 0.91,
                           "p99_mpa": 34.0, "max_mpa": 40.2, "allowable_mpa": 31.0,
                           "segments": 8000, "seconds": 20.0,
                           "refusal": "p99 34.0 MPa exceeds the allowable 31.0 MPa"],
             "approved_structural": false, "approved_aesthetic": true],
            ["cell_min_mm": 3.0, "cell_max_mm": 5.0, "trace_seconds": 44.0, "curves": 600,
             "components": 120, "traced_length_mm": 30000, "rooted_length_fraction": 0.91,
             "candidate_voxels": 12480,
             "regions": [
                ["face_id": 2, "region_id": 1, "depth_mm": 12, "cells_across": 3.1,
                 "curves_per_family": [20, 12, 8], "components": 120,
                 "traced_length_mm": 30000, "rooted_length_fraction": 0.91,
                 "approved_structural": false, "approved_aesthetic": false,
                 "refusals": "rooted_length_fraction 0.91 < 0.95", "advice": ""]],
             "predicted": ["ran": false, "reason": "segment cap hit"],
             "approved_structural": false, "approved_aesthetic": false],
        ],
    ]

    private func data(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o) }

    func testTheFileParsesPerTheContract() throws {
        let p = try XCTUnwrap(OrganicForecast.parse(try data(Self.probe)))
        XCTAssertEqual(p.probeVersion, 1)
        XCTAssertTrue(p.growth); XCTAssertTrue(p.transferTies)
        XCTAssertEqual(p.rootedGate, 0.95); XCTAssertEqual(p.curvesPerFamilyGate, 2)
        XCTAssertEqual(p.cellsAcrossAdvisory, 4.0)
        XCTAssertEqual(p.candidates.count, 3)
        XCTAssertEqual(p.sizes.map(\.cellMinMM), [4.5, 6.5])
        XCTAssertEqual(p.grades.map(\.gradeMM), [[3.0, 5.0]])
        let good = p.sizes[0]
        XCTAssertEqual(good.label, "4.5 mm")
        XCTAssertEqual(good.curves, 412); XCTAssertEqual(good.components, 79)
        XCTAssertEqual(good.regions[0].faceID, 2)
        XCTAssertEqual(good.regions[0].curvesPerFamily, [14, 9, 6])
        XCTAssertEqual(good.regions[0].advice.prefix(3), "2.7")
        XCTAssertEqual(good.predicted?.certified, true)
        XCTAssertEqual(good.marginText, "1.84")
        XCTAssertTrue(good.hoverText.contains("margin 1.84"), good.hoverText)
        let refused = p.sizes[1]
        XCTAssertEqual(refused.refusals, ["predicted refused: p99 34.0 MPa > allowable 31.0"], "verbatim")
        XCTAssertTrue(refused.hoverText.contains("p99 34.0 MPa exceeds"), refused.hoverText)
        let grade = p.grades[0]
        XCTAssertEqual(grade.label, "3–5 mm")
        XCTAssertNil(grade.marginText, "the prediction did not run")
        XCTAssertTrue(grade.hoverText.contains("segment cap hit"), grade.hoverText)
    }

    /// Absent, malformed, or a version this build does not understand ⇒ nil —
    /// "fall back to today's octet forecast; no organic approvals shown".
    func testUnknownVersionOrGarbageMeansNoApprovals() throws {
        var v2 = Self.probe; v2["organic_probe_version"] = 2
        XCTAssertNil(OrganicForecast.parse(try data(v2)))
        var none = Self.probe; none.removeValue(forKey: "organic_probe_version")
        XCTAssertNil(OrganicForecast.parse(try data(none)))
        XCTAssertNil(OrganicForecast.parse(Data("not json".utf8)))
        XCTAssertNil(OrganicForecast.parse(try data(["organic_probe_version": 1])), "no candidates")
    }

    /// green = approved_structural; amber = aesthetic only; grey = refused.
    /// Structural selects only green; Aesthetic selects all.
    func testTheMenusLaw() throws {
        let p = try XCTUnwrap(OrganicForecast.parse(try data(Self.probe)))
        let green = p.sizes[0], amber = p.sizes[1], grey = p.grades[0]
        XCTAssertEqual(OrganicForecast.tint(green), .green)
        XCTAssertEqual(OrganicForecast.tint(amber), .amber)
        XCTAssertEqual(OrganicForecast.tint(grey), .grey)
        XCTAssertTrue(OrganicForecast.selectable(green, structural: true))
        XCTAssertFalse(OrganicForecast.selectable(amber, structural: true))
        XCTAssertFalse(OrganicForecast.selectable(grey, structural: true))
        for c in p.candidates { XCTAssertTrue(OrganicForecast.selectable(c, structural: false)) }
    }

    /// The copy: "likely to certify", ~20 % conservative, predicted margin, never the
    /// certificate, never one piece; cells_across is advice, not a gate.
    func testTheCopyKeepsTheContractsPromises() {
        let all = [OrganicForecast.structuralMeaning, OrganicForecast.aestheticMeaning,
                   OrganicForecast.notCertified, OrganicForecast.checkSizesHelp]
        for t in all {
            XCTAssertFalse(t.lowercased().contains("contiguous"), t)
            XCTAssertFalse(t.lowercased().contains("single piece"), t)
            XCTAssertFalse(t.lowercased().contains("cells across"), "advisory only, never in the approval copy: \(t)")
        }
        XCTAssertTrue(OrganicForecast.structuralMeaning.hasPrefix("Likely to certify"))
        XCTAssertTrue(OrganicForecast.structuralMeaning.contains("20 % conservative"))
        XCTAssertTrue(OrganicForecast.structuralMeaning.contains("margin shown is predicted"))
        XCTAssertTrue(OrganicForecast.structuralMeaning.contains("certificate is the verdict"))
    }

    func testTheAnswerPersistsOnTheSettings() throws {
        var l = LatticeSettings()
        XCTAssertNil(l.organicForecast)
        l.organicForecast = try XCTUnwrap(OrganicForecast.parse(try data(Self.probe)))
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(l))
        XCTAssertEqual(back.organicForecast, l.organicForecast)
        let plain = try JSONEncoder().encode(LatticeSettings())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(obj["organicForecast"], "an untouched file carries no key")
    }

    /// The probe job: the re-lattice job plus the two lattice keys, organic only.
    func testTheProbeJobCarriesTheKeysAndRefusesNonOrganic() throws {
        let organic: [String: Any] = [
            "grading": ["algorithm": "organic", "intent": "aesthetic"],
            "lattice": ["topology": "octet", "regions": []],
        ]
        let out = try RelatticeRun.probeJob(try data(organic), cellsMM: [4.5, 0, 3.5],
                                            gradesMM: [[3, 5], [5, 3], [4]])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        let lat = try XCTUnwrap(obj["lattice"] as? [String: Any])
        XCTAssertEqual(lat["organic_probe_cells_mm"] as? [Double], [4.5, 3.5], "non-positive dropped")
        XCTAssertEqual(lat["organic_probe_grades_mm"] as? [[Double]], [[3, 5]], "lo < hi only")
        XCTAssertNil(lat["forecast_only"], "the probe is NOT a forecast")
        XCTAssertEqual(lat["topology"] as? String, "octet", "the rest of the job untouched")
        let octet: [String: Any] = ["grading": ["algorithm": "doubled"], "lattice": ["topology": "octet"]]
        XCTAssertThrowsError(try RelatticeRun.probeJob(try data(octet), cellsMM: [4], gradesMM: []))
        XCTAssertThrowsError(try RelatticeRun.probeJob(try data(organic), cellsMM: [], gradesMM: []),
                             "no candidates")
        XCTAssertEqual(LatticeSettings.organicProbeCellsMM, [3.5, 4.5, 5.5, 6.5])
        XCTAssertEqual(LatticeSettings.organicProbeGradesMM, [[3, 5], [4.5, 5.5]])
    }

    /// The forecast document no longer carries an organic block (old contract).
    func testTheForecastParserIgnoresAnOrganicBlock() throws {
        let f = try XCTUnwrap(LatticeForecast.parse(try data([
            "region_voxels": 10, "would_lattice_voxels": 8, "would_stay_solid_voxels": 2,
            "organic": Self.probe,
        ])))
        XCTAssertEqual(f.wouldLatticeVoxels, 8)
    }
}

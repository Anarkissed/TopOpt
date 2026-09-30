import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ RULING (d) (maintainer, 2026-09-30): a Check-sizes answer stored before the face-prism
/// route was measured on a different job (placed shapes only), so it is invalid: keyed to the
/// route, kept on disk, never used, and the wizard says sizes need re-checking.
@MainActor
final class OrganicForecastRouteTests: XCTestCase {

    /// An answer with a recommendation whose floor (9.9 mm) no project would derive locally.
    private func answer() throws -> OrganicForecast {
        let doc: [String: Any] = [
            "organic_probe_version": 1,
            "candidates": [
                ["cell_min_mm": 4.5, "cell_max_mm": 4.5, "trace_seconds": 30.0, "curves": 400,
                 "components": 1, "traced_length_mm": 26000, "rooted_length_fraction": 0.97,
                 "candidate_voxels": 12000, "regions": [],
                 "predicted": ["ran": true, "verdict": "certified", "margin": 1.8,
                               "p99_mpa": 12, "max_mpa": 19, "allowable_mpa": 31,
                               "segments": 26000, "seconds": 40, "refusal": ""],
                 "approved_structural": true, "approved_aesthetic": true]],
            "recommendation": [
                "ran": true, "mode": "aesthetic", "band_lo_mm": 3.0, "band_hi_mm": 8.0, "collapsed": false,
                "printability_floor_mm": 9.9, "resolution_floor_mm": 0.5,
                "member_ceiling_mm": 8.0, "extent_ceiling_mm": 12.0, "look_cell_mm": 5.0,
                "grade_ratio": 1.6, "look_cells_across": 8, "target_margin": 1.5,
                "fit": ["found": true, "cell_mm": 5.0, "margin": 0, "traced_mm": 26000, "source": "look"],
                "auto": ["found": true, "cell_min_mm": 3.5, "cell_max_mm": 6.5, "margin": 0,
                         "traced_mm": 24000, "source": "look_pair"],
                "rejected": [],
            ],
        ]
        return try XCTUnwrap(OrganicForecast.parse(try JSONSerialization.data(withJSONObject: doc)))
    }

    /// A settings file as it would be read back, with the answer's JSON edited.
    private func decoded(_ l: LatticeSettings, edit: (inout [String: Any]) -> Void) throws -> LatticeSettings {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(l)) as? [String: Any])
        var f = try XCTUnwrap(obj["organicForecast"] as? [String: Any])
        edit(&f)
        obj["organicForecast"] = f
        return try JSONDecoder().decode(LatticeSettings.self, from: try JSONSerialization.data(withJSONObject: obj))
    }

    func testAPreRouteAnswerIsKeptButNeverUsed() throws {
        var l = LatticeSettings()
        XCTAssertFalse(l.organicSizesNeedRecheck, "no answer ⇒ no line")
        var f = try answer()
        f.jobRoute = OrganicForecast.currentJobRoute
        l.organicForecast = f
        // control: stamped with today's route ⇒ used, no line
        XCTAssertEqual(l.currentOrganicForecast, f)
        XCTAssertFalse(l.organicSizesNeedRecheck)
        // a file written before the key (every pre-route answer) ⇒ kept, never used, line shown
        let old = try decoded(l) { $0["jobRoute"] = nil }
        XCTAssertNotNil(old.organicForecast, "★ kept on disk")
        XCTAssertNil(old.organicForecast?.jobRoute)
        XCTAssertNil(old.currentOrganicForecast, "★ never used")
        XCTAssertTrue(old.organicSizesNeedRecheck, "★ and the wizard says so")
        // V1's era (its count meant every face wall) is stale too
        let v1 = try decoded(l) { $0["jobRoute"] = nil; $0["faceWallsLeftOut"] = 2 }
        XCTAssertNil(v1.currentOrganicForecast)
        XCTAssertTrue(v1.organicSizesNeedRecheck)
        // the gate is EQUALITY, not "any key": an older or a newer route is stale
        for r in [OrganicForecast.currentJobRoute - 1, OrganicForecast.currentJobRoute + 1] {
            let other = try decoded(l) { $0["jobRoute"] = r }
            XCTAssertNil(other.currentOrganicForecast, "route \(r)")
            XCTAssertTrue(other.organicSizesNeedRecheck, "route \(r)")
        }
        // a round trip neither drops nor revives it
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(old))
        XCTAssertEqual(back.organicForecast, old.organicForecast)
        XCTAssertNil(back.currentOrganicForecast)
    }

    /// A CALL SITE, not the value type: the project's floor (the wizard's verdict and the
    /// preview's rim) ignores a pre-route answer's recommendation.
    func testTheFloorIgnoresAPreRouteAnswer() throws {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        let local = p.organicFloor.mm
        XCTAssertGreaterThan(abs(local - 9.9), 1e-3, "control: the answer's floor differs from the local one")
        p.lattice.organicForecast = try answer()                   // unstamped: pre-route
        XCTAssertEqual(p.organicFloor.mm, local, "★ a pre-route answer sets no floor")
        p.lattice.organicForecast?.jobRoute = OrganicForecast.currentJobRoute
        XCTAssertEqual(p.organicFloor.mm, 9.9, accuracy: 1e-9, "control: a current one does")
    }

    func testTheRecheckLine() {
        XCTAssertEqual(OrganicForecast.recheckLine(), "Sizes need re-checking — tap Check sizes.")
        let why = "Size checking needs a worker and a finished optimization."
        XCTAssertEqual(OrganicForecast.recheckLine(checkRefusal: why), "Sizes need re-checking. " + why)
        XCTAssertFalse(OrganicForecast.recheckLine(checkRefusal: why).contains("tap Check sizes"),
                       "never points at a button that is not there")
    }

    /// Every reader goes through the gate — a new direct reader of the stored answer fails here.
    func testEveryReaderGoesThroughTheRouteGate() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("Sources/TopOptFlows")
        let allowed: [String: Set<String>] = [
            "LatticeSettings.swift": [
                "s.organicForecast = nil",
                "public var organicForecast: OrganicForecast? = nil",
                "guard let f = organicForecast, f.isCurrent else { return nil }",
                "organicForecast.map { !$0.isCurrent } ?? false",
                "case organicForecast",
                "organicForecast = try c.decodeIfPresent(OrganicForecast.self, forKey: .organicForecast)",
                "try c.encodeIfPresent(organicForecast, forKey: .organicForecast)",
            ],
            "LatticeSetupWizard.swift": ["project.lattice.organicForecast = probe"],
        ]
        let re = try NSRegularExpression(pattern: #"\borganicForecast\b"#)
        var found: [String] = []
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                guard re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil else { continue }
                if !(allowed[f]?.contains(t) ?? false) { found.append("\(f): \(t)") }
            }
        }
        XCTAssertEqual(found, [], "★ read the answer through `currentOrganicForecast`")
        // the wiring: the stamp, and the wizard's one line
        let ws = try String(contentsOf: dir.appendingPathComponent("WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("probe.jobRoute = OrganicForecast.currentJobRoute"), "Check sizes stamps the route")
        let wz = try String(contentsOf: dir.appendingPathComponent("LatticeSetupWizard.swift"), encoding: .utf8)
        XCTAssertTrue(wz.contains("if project.lattice.organicSizesNeedRecheck, organicProbeState != .running {"))
        // ★ ruling 4 (2026-09-30): the same line; where a missing wall is the reason it is one tap
        // from the walls
        XCTAssertTrue(wz.contains("refusalNote(OrganicForecast.recheckLine(checkRefusal: organicProbeRefusal),"))
    }
}

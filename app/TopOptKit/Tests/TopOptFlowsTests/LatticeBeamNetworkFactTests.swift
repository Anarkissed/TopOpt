import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ MAINTAINER, 2026-10-02 — RULINGS 1 AND 3: the preview's floor and the job's
/// `structural_certification` follow what core actually CERTIFIES, not what its schema accepts.
/// Core's run calls the beam-network certificate only for organic + structural
/// (run_job.cpp:7488); Stepped and Default Grade are certified by the homogenised tensor
/// whatever the job says. Until the linked core publishes the set
/// (`lattice_beam_network_certified_algorithms()`, #358), the app holds ONE named constant.
final class LatticeBeamNetworkFactTests: XCTestCase {

    private func src(_ f: String, in dir: String = "Sources/TopOptFlows") throws -> String {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        return try String(contentsOf: u.appendingPathComponent("\(dir)/\(f)"), encoding: .utf8)
    }

    /// The one constant: organic only — what core runs today.
    func testTheConstantIsWhatCoreRunsToday() throws {
        XCTAssertEqual(TopOptKit.latticeBeamNetworkCertifiedAlgorithms, ["organic"])
        XCTAssertTrue(try src("TopOptKit.swift", in: "Sources/TopOptKit")
            .contains("`lattice_beam_network_certified_algorithms()`"), "the comment names core's function to swap to")
    }

    /// Ruling 1: Stepped and Default Grade under Structural are back on the homogenised floor
    /// (5); they relax only when core's set holds them; organic stays at 5 (U8) whatever the set
    /// says; Aesthetic is untouched.
    func testTheRegionFloorFollowsTheSet() throws {
        let homog = LatticeStageMode.structural.cellsPerMemberFloor(topology: "octet", utilisation: .nan)
        let aesthetic = LatticeStageMode.aesthetic.cellsPerMemberFloor(topology: "octet", utilisation: .nan)
        guard homog > 0, aesthetic > 0 else { throw XCTSkip("no octet law in this core") }
        XCTAssertEqual(homog, 5, "core's homogenised accuracy floor")
        for alg in ["stepped", "doubled"] {
            XCTAssertEqual(LatticeStageMode.structural.regionCellsPerMemberFloor(
                topology: "octet", boundaryFinishWritten: false, algorithm: alg), homog,
                "★ \(alg) under Structural, core today: the tensor certificate's floor")
            XCTAssertEqual(LatticeStageMode.structural.regionCellsPerMemberFloor(
                topology: "octet", boundaryFinishWritten: false, algorithm: alg,
                beamNetworkAlgorithms: ["organic", "stepped", "doubled"]), aesthetic,
                "\(alg) relaxes by itself once core certifies it by the beam network")
        }
        XCTAssertEqual(LatticeStageMode.structural.regionCellsPerMemberFloor(
            topology: "octet", boundaryFinishWritten: false, algorithm: "organic"), homog, "★ organic untouched")
        XCTAssertEqual(LatticeStageMode.aesthetic.regionCellsPerMemberFloor(
            topology: "octet", boundaryFinishWritten: false, algorithm: "stepped"), aesthetic)
    }

    /// The bake, the drawer card and the badge read ONE floor (they drifted when only the bake
    /// moved, 4fdcdc59 — his "Cell 2.40 mm" drawer beside a ~12 mm preview cell).
    func testTheBakeTheCardAndTheBadgeReadOneFloor() throws {
        XCTAssertFalse(try src("LatticeRegionCells.swift").contains("steppedStructuralCertificationWired"),
                       "★ the schema probe is no longer the floor's source")
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertEqual(ws.components(separatedBy: ".regionCellsPerMemberFloor(topology: project.lattice.topologyID,").count - 1, 2,
                       "the badge and the card")
        XCTAssertFalse(ws.contains(".cellsPerMemberFloor(topology: project.lattice.topologyID,"),
                       "no display site left on the stage floor")
    }

    /// Ruling 3: a Stepped + Structural job no longer names an instrument core does not run.
    /// The intent still travels (core reads it), and so does the tile floor.
    func testAStructuralSteppedJobNamesNoBeamNetwork() throws {
        var lat = LatticeSettings(enabled: true)
        lat.algorithm = "stepped"
        lat.stageMode = .structural
        lat.densityMode = .sim
        let spec = try XCTUnwrap(lat.runSpec(limits: TopOptKit.latticeLimits(topology: "octet"),
                                             generatable: true, lineWidthMM: 0.45))
        let g = try XCTUnwrap(spec.gradingDictionary())
        XCTAssertNil(g["structural_certification"], "★ core accepts the key but never runs it on Stepped")
        if TopOptKit.gradingSchemaAccepts(key: "intent") {
            XCTAssertEqual(g["intent"] as? String, "structural", "the intent still travels")
        }
        XCTAssertTrue(TopOptKit.steppedStructuralCertificationWired, "the schema still ACCEPTS it — accepting is not running")
        // organic's own certificate key is a different key and is untouched
        XCTAssertTrue(try src("LatticeSettings.swift")
            .contains("if TopOptKit.latticeBeamNetworkCertifiedAlgorithms.contains(\"stepped\"),"),
                      "★ it comes back keyed on core's fact")
    }
}

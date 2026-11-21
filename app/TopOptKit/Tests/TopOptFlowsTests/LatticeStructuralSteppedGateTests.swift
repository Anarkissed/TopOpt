import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ REVIEWER, 2026-10-08 (approved by the maintainer): "Structural Stepped: BLOCK the run (no
/// fallback), saying it waits on core's strength check for mixed cell sizes." Every run path
/// refuses it in one sentence; Settings says so with a one-tap Default Grade; it lifts by itself
/// the day core's beam-network set (the app's `latticeBeamNetworkCertifiedAlgorithms`) holds
/// "stepped".
final class LatticeStructuralSteppedGateTests: XCTestCase {

    /// T1 — the rule, as a pure function: only Stepped, only Structural (an unstated intent reads
    /// as Structural, as core reads it), only while the beam network does not certify Stepped.
    func testOnlyStructuralSteppedIsBlocked() {
        let gate = LatticeStructuralSteppedGate.self
        XCTAssertEqual(gate.refusal(latticeEnabled: true, algorithm: "stepped", stageMode: .structural),
                       "Stepped waits on a strength check", "★ the ruling's words")
        XCTAssertEqual(gate.refusal(latticeEnabled: true, algorithm: "stepped", stageMode: nil), gate.line,
                       "an unstated intent is not Aesthetic (run_job.cpp:5166)")
        XCTAssertNil(gate.refusal(latticeEnabled: true, algorithm: "stepped", stageMode: .aesthetic), "Aesthetic Stepped runs")
        XCTAssertNil(gate.refusal(latticeEnabled: true, algorithm: "doubled", stageMode: .structural), "Default Grade runs")
        XCTAssertNil(gate.refusal(latticeEnabled: true, algorithm: "", stageMode: .structural), "unstated = doubled")
        XCTAssertNil(gate.refusal(latticeEnabled: true, algorithm: "organic", stageMode: .structural),
                     "organic has its own gate")
        XCTAssertNil(gate.refusal(latticeEnabled: false, algorithm: "stepped", stageMode: .structural), "lattice off")
        XCTAssertNil(gate.refusal(latticeEnabled: true, algorithm: "stepped", stageMode: .structural,
                                  beamNetworkAlgorithms: ["organic", "stepped"]),
                     "★ it lifts by itself when the beam network certifies Stepped")
        XCTAssertFalse(TopOptKit.latticeBeamNetworkCertifiedAlgorithms.contains("stepped"),
                       "today's set: the run routes the beam network only for organic (run_job.cpp:7581)")
    }

    /// T2 — the project's paths: the stage's Lattice button and a variant's job are refused, in
    /// the gate's words; Aesthetic Stepped and Structural Default Grade are not (controls).
    @MainActor
    func testTheStageAndAVariantRefuseItInTheGatesWords() {
        let m = AppModel(materialsPath: nil)
        func project(_ algorithm: String, _ mode: LatticeStageMode) -> ProjectModel {
            let (p, _, _) = VariantFacePrismFixture.project()
            p.lattice.algorithm = algorithm
            p.lattice.stageMode = mode
            return p
        }
        let blocked = project("stepped", .structural)
        XCTAssertEqual(blocked.variantLatticeJobRefusal(), LatticeStructuralSteppedGate.line, "★ a variant")
        XCTAssertFalse(WorkspacePlaceholder(model: m, project: blocked).canLatticeThis, "★ the stage")
        for (a, mode) in [("stepped", LatticeStageMode.aesthetic), ("doubled", .structural)] {
            let ok = project(a, mode)
            XCTAssertNil(ok.variantLatticeJobRefusal(), "control: \(a) \(mode)")
            XCTAssertTrue(WorkspacePlaceholder(model: m, project: ok).canLatticeThis, "control: \(a) \(mode)")
        }
    }

    /// T3 — every other run path asks the same gate, and Settings carries the line with the
    /// one-tap fix (pinned on the sources: these are view bodies and private members).
    func testEveryRunPathAndSettingsAskTheGate() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/" + f), encoding: .utf8)
        }
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("latticeTypeRefusal ?? LatticeStructuralSteppedGate.refusal(project.lattice)"),
                      "the settings refusal: type, then Structural Stepped")
        XCTAssertEqual(ws.components(separatedBy: "?? latticeSettingsRefusal").count - 1, 2, "★ the stage and Optimize")
        XCTAssertTrue(ws.contains("!ok && summary == latticeSettingsRefusal"), "★ its tap opens Settings")
        XCTAssertTrue(ws.contains("regions: e.regions)\n                ?? LatticeStructuralSteppedGate.refusal(project.lattice))"),
                      "★ the variant page's pass")
        XCTAssertTrue(ws.contains("guard LatticeStructuralSteppedGate.refusal(project.lattice) == nil else { return nil }"),
                      "★ the variant job's backstop")
        XCTAssertTrue(try src("LatticePage.swift").contains("?? LatticeStructuralSteppedGate.refusal(project.lattice))"),
                      "★ the page's Optimize")
        XCTAssertTrue(try src("ProjectModel.swift").contains("?? LatticeStructuralSteppedGate.refusal(lattice)"),
                      "★ a variant's job")
        let wiz = try src("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains("wizard-stepped-structural-blocked"), "★ Settings says so")
        XCTAssertTrue(wiz.contains("model.cellTransition = .defaultGrade\n                        rebuild()"),
                      "★ and the fix is one tap")
        XCTAssertEqual(LatticeStructuralSteppedGate.fixLabel, "Use Default Grade")
        XCTAssertLessThanOrEqual((LatticeStructuralSteppedGate.line + " · " + LatticeStructuralSteppedGate.fixLabel).count, 56,
                                 "one short line in the Settings column (the note wraps rather than truncate)")
    }
}

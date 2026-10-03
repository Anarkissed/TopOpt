import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ MAINTAINER, 2026-10-02 — RULING 4, the Default Grade (doubled) plan. App-side causes first:
/// R4 — the preview packed ANY-STEP sizes under doubled, because it read `gradeStepStyle`, which
/// only the wizard's save syncs (570B38E2: doubled, no gradeStepStyle ⇒ `.stepped`).
final class LatticeDefaultGradePlanTests: XCTestCase {

    private func src(_ f: String) throws -> String {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        return try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
    }

    /// R4: halves follow the ALGORITHM, whatever `gradeStepStyle` says.
    func testDefaultGradeIsHalvesByItsAlgorithm() throws {
        var lat = LatticeSettings(enabled: true)
        lat.algorithm = "doubled"
        lat.gradeStepStyle = .stepped                  // 570B38E2's decoded state (key absent)
        XCTAssertTrue(lat.gradeStepsAreHalves, "★ Default Grade packs halves")
        lat.algorithm = "stepped"
        lat.gradeStepStyle = .dyadic                   // a stale memory from the wizard
        XCTAssertFalse(lat.gradeStepsAreHalves, "Stepped packs any step")
        for a in ["organic", ""] { lat.algorithm = a; XCTAssertFalse(lat.gradeStepsAreHalves, a) }
        // the preview reads the one rule
        XCTAssertTrue(try src("WorkspacePlaceholder.swift").contains("project.lattice.gradeStepsAreHalves,"))
        XCTAssertFalse(try src("WorkspacePlaceholder.swift").contains("project.lattice.gradeStepStyle == .dyadic"))
    }
}

/// ★ Ruling 4: the probe is fixed, but SENDING stays off until the CLI proof passes; Stepped plans
/// never go. Through the relattice builder (the stage job's builder has the same seam).
final class LatticeDefaultGradePlanSwitchTests: XCTestCase {
    func testPlansAreOffAndStepppedNeverSendsOne() throws {
        XCTAssertFalse(LatticeSteppedCellWire.defaultGradePlansEnabled, "★ off until every plan is accepted")
        var spec = LatticeSpec(topologyID: "octet", cellMM: 12, strutRadiusMM: 0.5,
                               generateRelativeDensity: 0.3, minRelativeDensity: 0.1, maxRelativeDensity: 0.5)
        spec.algorithm = "doubled"
        spec.steppedCells = [LatticeSteppedCellWire(regionID: 1, originMM: .zero, sizeMM: 12)]
        let original = try JSONSerialization.data(withJSONObject: ["model": "p.step"])
        func cells(_ s: LatticeSpec, plans: Bool) throws -> Any? {
            let data = try RelatticeJobBuilder.build(original: original, designFingerprint: 1,
                                                     achievedVolumeFraction: 0.3, designFileName: "d.3mf",
                                                     lattice: s, steppedCellsWired: TopOptKit.steppedCellsWired,
                                                     steppedPlans: plans)
            let job = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (job["lattice"] as? [String: Any])?["stepped_cells"]
        }
        XCTAssertNil(try cells(spec, plans: LatticeSteppedCellWire.defaultGradePlansEnabled), "★ production: no plan")
        XCTAssertNotNil(try cells(spec, plans: true), "the proof's seam: the plan rides")
        var stepped = spec; stepped.algorithm = "stepped"
        XCTAssertNil(try cells(stepped, plans: true), "★ never for Stepped")
    }
}

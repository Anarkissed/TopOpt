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

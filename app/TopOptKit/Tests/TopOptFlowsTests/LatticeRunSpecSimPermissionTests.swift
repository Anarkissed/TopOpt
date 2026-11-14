// LatticeReview 2026-11-10 (review finding J4): a project whose Density is still "By stress" while Simulate stresses is off
// crashed the app in `runSpec` (a `precondition`). The page can write that pair (LatticePage's Density segment writes
// `densityMode` alone) and a stored project can hold it (the decoder reads the two fields independently).
// The job for that pair is the job `setSimulateStresses(false)` would have left: the switch wins, nothing is simulated.
import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeRunSpecSimPermissionTests: XCTestCase {

    private func spec(_ s: LatticeSettings) -> LatticeSpec? { s.runSpec(lineWidthMM: 0.45) }

    func testSimDensityWithTheSimSwitchOffRunsAsTheSwitchSays() throws {
        var consistent = LatticeSettings(enabled: true)
        consistent.densityMode = .sim
        consistent.setSimulateStresses(false)          // the setter moves Density to Uniform
        XCTAssertFalse(consistent.densityMode.needsSimulation, "premise: the setter leaves a consistent pair")
        let want = try XCTUnwrap(spec(consistent), "control: the consistent pair writes a job")
        XCTAssertFalse(want.graded, "control: with the switch off the job is not graded by stress")

        var stale = LatticeSettings(enabled: true)
        stale.setSimulateStresses(false)
        stale.densityMode = .sim                       // what the page's Density segment and an old file can leave
        XCTAssertTrue(stale.densityMode.needsSimulation && !stale.simulateStresses, "premise: the pair that crashed")
        let got = try XCTUnwrap(spec(stale), "★ the stale pair writes a job instead of stopping the app")
        XCTAssertEqual(got, want, "★ and it is the job the switch asks for: nothing simulated")
    }
}

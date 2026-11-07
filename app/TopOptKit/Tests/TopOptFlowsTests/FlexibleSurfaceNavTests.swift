// FlexibleSurfaceNavTests — the Surface button on the main Flexible page (task
// 2026-09-29-flexible-screens, round 3 batch C, item S; his ask). Hook H9 in #354's
// WorkspacePlaceholder: [‹ Topology] [Surface] on the Flexible lattice stage, [‹ Flexible] on
// Surface, through #354's own `stageNavButton` (identical chrome; an optional title).
// RED CONTROL: #354's Surface stage reaches the lattice only through Topology.
// ★ SYNC #354 (89af86dd) A4: B5 (3f293974) deleted the Surface stage, and with it H9's subject (the [Surface] button beside
// [‹ Topology] and the [‹ Flexible] way back). testTheHookIsInPlace and
// testTheSurfaceButtonSitsBesideTopologyAndSurfaceComesBackToFlexible are RETIRED; the one test whose lines are still
// there (re-entering the lattice stage never re-pops Settings) stays.
import XCTest
@testable import TopOptFlows

final class FlexibleSurfaceNavTests: XCTestCase {

    /// The return from Surface does not re-pop Settings: re-entering the lattice stage opens
    /// Settings only while nothing was saved this session, and Settings' Exit says it was.
    func testTheSurfaceRoundTripDoesNotRePopSettings() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let open = try XCTUnwrap(ws.range(of: "private func openLatticeSettingsIfUnconfigured() {"))
        XCTAssertTrue(ws[open.upperBound...].prefix(900).contains("guard !latticeSettingsSavedThisSession, !showLatticeWizard else { return }"))
        XCTAssertTrue(ws.contains("onExit: { showFlexiblePage = false; latticeSettingsSavedThisSession = true; flexibleMain.didExitSettings(solver: FlexibleStressSolver(app: model, sim: latticeSim)) })"))
        // the way back is #354's one door (goToStage) — the Surface snapshot / discard rule holds
        XCTAssertTrue(ws.contains("guard enabled else { return }\n            goToStage(dest)"))
    }
}

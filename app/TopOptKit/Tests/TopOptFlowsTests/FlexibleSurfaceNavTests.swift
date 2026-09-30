// FlexibleSurfaceNavTests — the Surface button on the main Flexible page (task
// 2026-09-29-flexible-screens, round 3 batch C, item S; his ask). Hook H9 in #354's
// WorkspacePlaceholder: [‹ Topology] [Surface] on the Flexible lattice stage, [‹ Flexible] on
// Surface, through #354's own `stageNavButton` (identical chrome; an optional title).
// RED CONTROL: #354's Surface stage reaches the lattice only through Topology.
import XCTest
@testable import TopOptFlows

final class FlexibleSurfaceNavTests: XCTestCase {

    func testTheHookIsInPlace() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        for pin in ["HStack(spacing: PageChrome.gap) { stageNavButton(to: back, icon: \"chevron.left\"); if let x = FlexibleStageNav.extra(stage, flexible: project.lattice.flexible != nil) { stageNavButton(to: x.dest, icon: x.icon, title: x.title) } }",
                    "private func stageNavButton(to dest: WorkspaceStage, icon: String, title: String? = nil) -> some View {",
                    "Text(title ?? dest.title)"] {
            XCTAssertEqual(ws.components(separatedBy: pin).count - 1, 1, "H9 must appear exactly once: \(pin)")
        }
        // the HStack keeps the back button's keep-out and placement
        let h = try XCTUnwrap(ws.range(of: "HStack(spacing: PageChrome.gap) { stageNavButton(to: back,"))
        let after = String(ws[h.upperBound...].prefix(600))
        XCTAssertTrue(after.contains(".latticeBandChipKeepOut()\n                .modifier(StageNavPlacement(stage: stage))"))
    }

    // MARK: H9 — the Surface button on the main Flexible page, and the way back

    func testTheSurfaceButtonSitsBesideTopologyAndSurfaceComesBackToFlexible() {
        let s = FlexibleStageNav.extra(.lattice, flexible: true)
        XCTAssertEqual(s?.dest, .surface)
        XCTAssertEqual(s?.icon, WorkspacePlaceholder.stageIcon(.surface), "identical chrome: the stage's own glyph")
        XCTAssertEqual(s?.title, "Surface")
        let back = FlexibleStageNav.extra(.surface, flexible: true)
        XCTAssertEqual(back?.dest, .lattice)
        XCTAssertEqual(back?.icon, "chevron.left")
        XCTAssertEqual(back?.title, "Flexible")
        XCTAssertNil(FlexibleStageNav.extra(.topology, flexible: true))
        XCTAssertNil(FlexibleStageNav.extra(.lattice, flexible: false), "Structural / Aesthetic keep #354's row")
        XCTAssertNil(FlexibleStageNav.extra(.surface, flexible: false))
        // #354's enum is untouched (SurfaceStageTests pins it too)
        XCTAssertEqual(WorkspaceStage.lattice.forward, [.surface])
        XCTAssertEqual(WorkspaceStage.surface.back, .topology)
        // ★ RED CONTROL: without the extra, Surface has no one-tap way back to Flexible
        XCTAssertTrue(WorkspaceStage.surface.forward.isEmpty && WorkspaceStage.surface.back != .lattice,
                      "control: #354's Surface stage reaches the lattice only through Topology")
    }

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

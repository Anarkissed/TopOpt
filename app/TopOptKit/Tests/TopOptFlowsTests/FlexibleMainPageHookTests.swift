// FlexibleMainPageHookTests — the hooks batch B lays in #354's files, pinned by text (task
// 2026-09-29-flexible-screens, round 3 batch B). Each is one line (or a one-line edit) whose
// logic lives in a track file; the handoff lists every one with its anchor and ± lines.
//   H1  WorkspacePlaceholder: `@StateObject flexibleMain` (the ONE model per project)
//   H2  WorkspacePlaceholder: FlexibleStagePage over the shared model; onExit builds
//   H3  WorkspacePlaceholder: `flexibleLattice:` on the main MetalMeshView
//   H4  WorkspacePlaceholder: mesh / vertexTints / settle / stressTints / dents / bodyAlpha
//   H5  WorkspacePlaceholder: the Flexible view toggles replace viewModeToggles under Flexible
//   H10 WorkspacePlaceholder: the status pill replaces the octet Lattice run under Flexible
//   P   WorkspacePlaceholder: the squish player slot (inside `!fullScreenPageUp`)
//   H12 LatticeSettings.previewBakeInputs drops `flexible`
// The strings other suites pin in the same lines stay (LatticePreviewBodyAlphaTests'
// `latticeLayer: latticeLayerIsDrawn`, the viewModeToggles cube, SmoothingPageRound2Tests'
// fullScreenPageUp predicate) — asserted here too, so a hook cannot eat them.
import XCTest
@testable import TopOptFlows

final class FlexibleMainPageHookTests: XCTestCase {

    func testTheWorkspaceHooksAreInPlace() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        let pins: [(String, String)] = [
            ("H1", "@StateObject private var flexibleMain = FlexibleMainStage()"),
            ("H2", "FlexibleStagePage(project: project, model: flexibleMain.model(for: project, materialsPath: FlexibleResources.materialsPath,"),
            ("H2", "onExit: { showFlexiblePage = false; latticeSettingsSavedThisSession = true; flexibleMain.didExitSettings() })"),
            ("H3", "flexibleLattice: flexibleMain.layer(project, stage: stage, pageUp: fullScreenPageUp))"),
            ("H4", "MetalMeshView(mesh: flexibleMain.mesh(project, on: stage) ?? stageMesh,"),
            ("H4", "vertexTints: visible.surfaceEditing ? surfaceVertexTints : flexibleMain.tints(project, on: stage),"),
            ("H4", "settleAnimated: !reduceMotion && !flexibleMain.owns(project, stage),"),
            ("H4", "stressTints: flexibleMain.owns(project, stage) ? nil : stageSurfaceTints,"),
            ("H4", "flexDisplacements: flexibleMain.dents(project, on: stage), flexScale: flexibleMain.dentScale(project, on: stage),"),
            ("H4", "bodyAlpha: flexibleMain.bodyAlpha(project, on: stage) ?? latticePreviewBodyAlpha,"),
            ("H5", "if flexibleMain.owns(project, stage) { FlexibleMainViewToggles(main: flexibleMain) }"),
            ("H10", "if project.lattice.flexible == nil { latticeThisButton } else { FlexibleMainStatusPill(main: flexibleMain, open: { showFlexiblePage = true }) }"),
            ("P", "if flexibleMain.owns(project, stage) { FlexibleMainPlayerSlot(main: flexibleMain, bottomClearance: bottomBarClearance) }"),
        ]
        for (h, pin) in pins {
            XCTAssertEqual(ws.components(separatedBy: pin).count - 1, 1, "\(h) must appear exactly once: \(pin)")
        }
        // H5's else keeps #354's viewModeToggles exactly as it was
        XCTAssertTrue(ws.contains("\n                else if viewerMesh != nil, visible.wireframe, !visible.surfaceEditing {\n                    viewModeToggles"),
                      "H5: every other stage keeps viewModeToggles")
        // the strings other suites pin in the same lines are untouched
        XCTAssertTrue(ws.contains("latticeLayer: latticeLayerIsDrawn"))
        XCTAssertTrue(ws.contains("latticeLayerDrawn: latticeLayerIsDrawn"))
        XCTAssertTrue(ws.contains("if visible.latticeControls {\n                viewModeButton(\"cube.transparent\""))
        XCTAssertTrue(ws.contains("private var fullScreenPageUp: Bool { showLatticePage || showSmoothingPage || showLatticeWizard || showFlexiblePage }"))
        // ★ the player slot sits inside a `!fullScreenPageUp` scope (no chrome under a page)
        let slot = try XCTUnwrap(ws.range(of: "FlexibleMainPlayerSlot(main: flexibleMain"))
        let before = String(ws[..<slot.lowerBound].suffix(1400))
        XCTAssertTrue(before.contains("if !fullScreenPageUp {\n                bottomBar"), "the player hides under a full-screen page (the bottom bar's scope)")
    }

    /// ★ The Settings page's Exit consults the readiness (item 9.3), a new blocking issue opens
    /// the pop-up, and the page never builds (Save & Exit does, on the main page).
    func testTheExitButtonAndThePageConsultTheReadiness() throws {
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("switch FlexibleExitDecision.decide(model.readiness) {"), "Exit consults the readiness")
        XCTAssertTrue(page.contains("Text(FlexibleExitDecision.title(r))"), "Exit says \"Fix 1 thing\" while blocked")
        XCTAssertTrue(page.contains("prompt.next(r, actionSerial: model.actionSerial, settled: !r.designing)"),
                      "a new blocking issue opens the pop-up at once")
        XCTAssertFalse(page.contains("flexible-generate"), "no Generate button (item 7.1)")
        XCTAssertFalse(page.contains("model.generateLattice()"), "the page never builds — Save & Exit does, on the main page")
    }

    func testPreviewBakeInputsDropFlexible() throws {
        let ls = try FlexibleSource.code("LatticeSettings.swift")
        let body = try XCTUnwrap(ls.range(of: "public var previewBakeInputs: LatticeSettings {"))
        let text = String(ls[body.upperBound...].prefix(260))
        XCTAssertTrue(text.contains("s.flexible = nil"), "H12: a Flexible edit never re-keys the octet bake")
    }
}

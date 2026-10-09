// FlexibleBatchCHookTests — the hooks batch C lays in #354's files, pinned by text, and the one
// renderer hook proven on the GPU (task 2026-09-29-flexible-screens, round 3 batch C: items
// 1.4, T, S). Each hook is one line (or a one-line edit); the logic lives in track files
// (FlexibleMainStage, FlexibleMainLegends, FlexibleProbe). The handoff lists every one.
//   H4' WorkspacePlaceholder: vertexTints composes roles + stress into the ONE tint array
//   H5' WorkspacePlaceholder: the Flexible toggles gain Stress (solved directly, never through
//       startStressSolveIfNeeded — LatticeSimSolveTriggerTests reads its first 900 characters)
//   H6  WorkspacePlaceholder: the legends, inside `else if !fullScreenPageUp`
//   H7  WorkspacePlaceholder: a surface tap reads while a Flexible legend is drilled in
//   H8  WorkspacePlaceholder: the wall probe armed only for the lattice legend; a wall read first
//   M4  MetalMeshView: `latticeProbe` finds a Flexible wall
// (H9, the Surface button: FlexibleSurfaceNavTests. H13, never violet, was REVERTED in round 4
// D1 at his request — one purple for every face prism: FlexibleSettingsRound4Tests.)
import XCTest
import simd
@testable import TopOptFlows

final class FlexibleBatchCHookTests: XCTestCase {

    func testTheWorkspaceHooksAreInPlace() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        let pins: [(String, String)] = [
            ("H4'", "vertexTints: visible.surfaceEditing ? surfaceVertexTints : flexibleMain.tints(project, on: stage, roles: roleTints, stress: latticeStressField),"),
            // ★ RE-PINNED (batch C verification): the toggles take the workspace's solver
            // (FlexibleStressSolve.swift — the regions the load case reaches, the sim's state said)
            // ★ RE-PINNED (round 4, C2 — his answer 2): the Lattice button, with nothing to show, opens Settings
            ("H5'", "if flexibleMain.owns(project, stage) { FlexibleMainViewToggles(main: flexibleMain, solver: FlexibleStressSolver(app: model, sim: latticeSim), openSettings: { showFlexiblePage = true }) }"),
            // ★ and Settings' Save & Exit hands it over too (the first Exit, before the toggles rendered)
            ("H2'", "flexibleMain.didExitSettings(solver: FlexibleStressSolver(app: model, sim: latticeSim)) })"),
            // ★ #354's "grading your lattice" banner stands down under Flexible (it grades nothing there)
            ("B1", "if latticeSimIsRunning, !simBannerDismissed, !flexibleMain.owns(project, stage) { simRunningBanner }"),
            ("H6", "if flexibleMain.owns(project, stage) { FlexibleMainLegends(main: flexibleMain, mode: $latticeLegendMode, projection: projection, settle: settleQuat, bottomClearance: bottomBarClearance, chipColumnWidth: force.gravityIsSet ? (settingsChipWidths.values.max() ?? 0) : 0) }"),
            ("H7", "if flexibleMain.read(project, mode: latticeLegendMode, face: fid, point: pt) { return true }"),
            // ★ RE-PINNED (S1, the #361 sync — the reviewer's ruling of 2026-10-08 19:13 (i)): H7/H8 ride #354's
            // `legendDrilledIn` (the key's drill-in only counts while the key is on screen), never a raw
            // `latticeLegendMode.drilledIn` read (LatticeStructuralViewStateTests: its one raw read is the definition)
            ("H8", "onLatticeProbe: legendDrilledIn && flexibleMain.wantsWallProbe(latticeLegendMode)"),
            ("H8", "if flexibleMain.readLattice(project, mode: latticeLegendMode, model: model) { return }"),
        ]
        for (h, pin) in pins {
            XCTAssertEqual(ws.components(separatedBy: pin).count - 1, 1, "\(h) must appear exactly once: \(pin)")
        }
        // H7 sits right before the pinned consumption; H8's read before the octet's reading
        XCTAssertTrue(ws.contains("if flexibleMain.read(project, mode: latticeLegendMode, face: fid, point: pt) { return true }   // Flexible (PR #362) H7: a surface tap reads the drilled-in Flexible legend\n                              if legendDrilledIn { return true }"),
                      "H7 comes first, and #354's consumption line stays")
        let h8 = try XCTUnwrap(ws.range(of: "if flexibleMain.readLattice(project, mode: latticeLegendMode, model: model) { return }"))
        XCTAssertTrue(ws[h8.upperBound...].prefix(260).contains("setLatticeProbe(at: model, world: world,"), "H8 reads before setLatticeProbe")
        // H6 inside the chrome that hides under a full-screen page, before the bottom bar's own scope
        let h6 = try XCTUnwrap(ws.range(of: "FlexibleMainLegends(main: flexibleMain"))
        let chrome = try XCTUnwrap(ws.range(of: "} else if !fullScreenPageUp {\n                // The Design Box drawer now lives INSIDE"))
        let bar = try XCTUnwrap(ws.range(of: "if !fullScreenPageUp {\n                bottomBar"))
        XCTAssertTrue(chrome.upperBound < h6.lowerBound && h6.upperBound < bar.lowerBound,
                      "H6 is chrome: inside `else if !fullScreenPageUp` (hidden under a full-screen page), before the bottom bar's scope")
        // the strings other suites pin in the same lines stay
        XCTAssertTrue(ws.contains("if legendDrilledIn { return true }"))
        XCTAssertTrue(ws.contains("onLatticeProbe: legendDrilledIn"))
        XCTAssertTrue(ws.contains("onLatticeProbeExit: legendDrilledIn"))
        // ★ S1: the old raw reads are gone from the hooks (#354's pin: one raw read, its definition)
        XCTAssertEqual(ws.components(separatedBy: "latticeLegendMode.drilledIn").count - 1, 1,
                       "the one raw `latticeLegendMode.drilledIn` is legendDrilledIn's definition")
        XCTAssertTrue(ws.contains("setLatticeProbe(at: model, world: world,"))
        XCTAssertTrue(ws.contains("!(showStrutPreview && strutScene != nil) {\n                    stressLegend"))
        XCTAssertTrue(ws.contains("latticeLayer: latticeLayerIsDrawn"))
        XCTAssertTrue(ws.contains("private var fullScreenPageUp: Bool { showLatticePage || showSmoothingPage || showLatticeWizard || showFlexiblePage }"))
        XCTAssertTrue(ws.contains("\n                else if viewerMesh != nil, visible.wireframe, !visible.surfaceEditing {\n                    viewModeToggles"))
    }

    /// ★ STRESS UNDER FLEXIBLE IS SOLVED DIRECTLY. startStressSolveIfNeeded is gated on
    /// `lattice.enabled && needsStressSolve`, which a fresh Flexible part never passes; it is not
    /// edited (LatticeSimSolveTriggerTests reads its first 900 characters).
    func testStressIsSolvedDirectlyAndTheOctetTriggerIsUntouched() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let body = try XCTUnwrap(ws.range(of: "private func startStressSolveIfNeeded() {"))
        let first = String(ws[body.upperBound...].prefix(900))
        XCTAssertFalse(first.contains("flexible"), "the octet's trigger is not edited")
        XCTAssertTrue(first.contains("guard project.lattice.enabled, project.lattice.needsStressSolve else {"))
        let h5 = try XCTUnwrap(ws.range(of: "FlexibleMainViewToggles(main: flexibleMain,"))
        let line = String(ws[h5.lowerBound...].prefix(while: { $0 != "\n" }))
        XCTAssertTrue(line.contains("FlexibleStressSolver(app: model, sim: latticeSim)"))
        XCTAssertFalse(line.contains("startStressSolveIfNeeded"), "not through the octet's gate")
        let solver = try FlexibleSource.code("FlexibleStressSolve.swift")
        XCTAssertTrue(solver.contains("sim.run(ctx)"), "the solver runs the workspace's own sim")
        XCTAssertFalse(solver.contains("startStressSolveIfNeeded()"), "…never through the octet's gate")
        // the banner keeps its pinned parts; the Flexible gate is ONE extra clause on its line
        XCTAssertTrue(ws.contains("if latticeSimIsRunning, !simBannerDismissed, !flexibleMain.owns(project, stage) { simRunningBanner }"))
        XCTAssertTrue(ws.contains("!(latticeSimIsRunning && !simBannerDismissed) { strutBakingBanner }"), "#354's rebake banner rule is untouched")
    }

    // MARK: the Settings page's legend reads too

    func testTheSettingsPageLegendDrillsInAndTapsDoNotSelect() throws {
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        let pick = try XCTUnwrap(page.range(of: "onPickPoint: { fid, pt in"))
        let body = String(page[pick.upperBound...].prefix(400))
        let drilled = try XCTUnwrap(body.range(of: "if legendDrilled {"))
        let select = try XCTUnwrap(body.range(of: "model.tapFace("))
        XCTAssertLessThan(drilled.lowerBound, select.lowerBound, "while drilled in, a tap reads — it never reaches tapFace")
        XCTAssertTrue(page.contains("onLatticeProbeExit: legendDrilled ?"), "a double tap anywhere comes back out")
        XCTAssertTrue(page.contains("FlexibleProbe.dentReading(model: model,"), "the page reads through the one dent probe")
        // ★ RE-PINNED (batch C verification): the legend's BODY lets every touch through — the
        // curve points and the curve line under it stay live (his img 9: the Y curve's end point
        // sat inside the legend box) — and only its tab row takes the tap that drills in and out
        let legend = try XCTUnwrap(page.range(of: "struct FlexibleLegend: View {"))
        let callout = try XCTUnwrap(page.range(of: "struct FlexibleReadingCallout: View {"))
        XCTAssertTrue(page[legend.upperBound..<callout.lowerBound].contains(".allowsHitTesting(false)"),
                      "the legend's body passes touches through")
        XCTAssertEqual(page.components(separatedBy: ".onTapGesture { legendDrilled.toggle(); reading = nil }").count - 1, 1,
                       "one tap target drills in (and out)")
        let placed = try XCTUnwrap(page.range(of: "@ViewBuilder private func legend(in size: CGSize) -> some View {"))
        let legendBody = String(page[placed.upperBound...].prefix(1400))
        let tab = try XCTUnwrap(legendBody.range(of: ".frame(height: FlexibleLegend.tabHeight)"))
        let tap = try XCTUnwrap(legendBody.range(of: ".onTapGesture { legendDrilled.toggle(); reading = nil }"))
        XCTAssertLessThan(tab.lowerBound, tap.lowerBound, "the tap target is the tab row's height")
        XCTAssertTrue(legendBody.contains(".overlay(alignment: .top) {"), "…laid over the top of the legend")
        // ★ RED CONTROL: batch C's whole-legend tap target is gone
        XCTAssertFalse(legendBody.contains(".contentShape(Rectangle())\n            .onTapGesture { legendDrilled.toggle(); reading = nil }"),
                       "control: the whole legend no longer takes the tap")
        XCTAssertLessThanOrEqual(FlexibleLegend.tabHeight, 34, "a strip, not the legend")
    }

    // MARK: M4 — the probe finds a Flexible wall (GPU)

    #if canImport(Metal) && canImport(MetalKit)
    @MainActor
    func testTheProbeFindsAFlexibleWall() throws {
        let mv = try FlexibleSource.code("MetalMeshView.swift")
        XCTAssertTrue(mv.contains("guard vertexDrawCount > 0, latticeInFrame || flexibleLatticeInFrame, width > 0, height > 0 else { return nil }"),
                      "M4: latticeProbe answers for the Flexible pass")
        typealias Fx = FlexibleLatticeFixtures
        let device = try Fx.device()
        let box = Fx.boxMesh()
        let r = try Fx.renderer(device: device, box: box)
        r.setVertexTints(Fx.xrayTints(box, ghost: FlexibleColours.ghost, dent: nil))
        r.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        let inputs = Fx.boxInputs(.gyroid)
        r.applyFlexibleLattice(Fx.layer(inputs, token: 1), device: device)
        let size = 256
        let dump = try XCTUnwrap(r.latticeMaskDump(size: size))
        // the covered texel nearest the frame's centre
        var best = -1, bestD = Int.max
        for i in dump.mask.indices where dump.mask[i] {
            let x = i % dump.width - dump.width / 2, y = i / dump.width - dump.height / 2
            if x * x + y * y < bestD { bestD = x * x + y * y; best = i }
        }
        XCTAssertGreaterThanOrEqual(best, 0, "premise: walls in the frame")
        let p = CGPoint(x: (CGFloat(best % dump.width) + 0.5) / CGFloat(dump.width),
                        y: (CGFloat(best / dump.width) + 0.5) / CGFloat(dump.height))
        let hit = r.latticeProbe(atNormalizedPoint: p, width: size, height: size)
        let onWall = hit.map { abs(FlexibleLatticeField.lattice(at: $0.model, inputs)) } ?? .infinity
        print("FLEX-PROBE wall: covered \(dump.covered) px; probe at \(p) ⇒ \(hit.map { "\($0.model)" } ?? "nil") · |F| \(onWall)")
        XCTAssertNotNil(hit, "a tap on a Flexible wall is found (it was gated on the octet's latticeInFrame alone)")
        XCTAssertLessThan(onWall, 0.35, "…at a point ON the wall")
        // control: a hidden pass is a miss (the probe does not invent a wall)
        r.applyFlexibleLattice(Fx.layer(inputs, token: 1, hidden: true), device: device)
        XCTAssertNil(r.latticeProbe(atNormalizedPoint: p, width: size, height: size), "control: no wall drawn, no reading")
    }
    #endif
}

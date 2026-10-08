// FlexibleS1VerifyTests — the S1 sync's verification (angled presses, batch S1; the #361 / #358 / #354
// merges). The verifier's confirmed major: the reviewer's ruling (i) put H7/H8 on #354's
// `legendDrilledIn`, and #354 defines that as `latticeLegendMounted && !latticeLegendMinimized &&
// latticeLegendMode.drilledIn` with `latticeLegendMounted = showStrutPreview && strutScene != nil` —
// the OCTET key. On the Flexible lattice stage the octet key is never mounted (`showStrutPreview` is
// set only by the octet's view toggles, which H5 replaces, and by LatticePage, which Flexible does not
// open), so with the Flexible key (FlexibleMainLegends, H6) drilled in:
//   - the wall probe (H8, `onLatticeProbe`) was never armed: a tap on a wall read "—" through H7;
//   - the double tap out (`onLatticeProbeExit`) was off, though the key's header promises it;
//   - #354's drilled-in hides (clearance volumes, depth-plane handles, gizmos, band chips) no longer
//     applied — FlexibleMainLegends' header relies on "#354's own gates hold".
// Before S1 every one of those read `latticeLegendMode.drilledIn`, which the Flexible key writes.
//
// THE FIX (H14): #354's definition gains ONE disjunct, the Flexible key's own drill-in
// (`FlexibleMainStage.keyDrilledIn`): the stage owns the page (H6 mounts the key exactly then, and the
// key resets the mode when it goes — onDisappear, or a drilled view turned off) and the mode is one of
// the Flexible key's kinds. The ruled H7/H8 text is unchanged, #354's own expression is unchanged
// (its pins: the expression, one raw `latticeLegendMode.drilledIn` read), and every one of #354's
// gates reads the one value again.
import XCTest
import simd
@testable import TopOptFlows

final class FlexibleS1VerifyTests: XCTestCase {

    private func member(_ text: String, _ decl: String) throws -> String {
        let r = try XCTUnwrap(text.range(of: decl), "missing \(decl)")
        let rest = text[r.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "unterminated \(decl)")
        return String(rest[..<end.upperBound])
    }

    /// The Flexible key's drill-in counts on the Flexible lattice stage, with NO octet preview —
    /// the state the main page is always in under Flexible — and the wall probe is armed for the
    /// lattice reading (H8's whole gate: `legendDrilledIn && wantsWallProbe`).
    @MainActor
    func testTheFlexibleKeysDrillInCountsWithoutTheOctetPreview() throws {
        let project = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let stage = FlexibleMainStage()
        for k in FlexibleReadKind.allCases {
            XCTAssertTrue(stage.keyDrilledIn(project, .lattice, mode: k.mode),
                          "★ \(k): the Flexible key drilled in is drilled in (the octet key is never mounted here)")
        }
        let lattice = FlexibleReadKind.lattice.mode
        XCTAssertTrue(stage.keyDrilledIn(project, .lattice, mode: lattice) && stage.wantsWallProbe(lattice),
                      "★ H8's gate: the wall probe is armed for the lattice reading")
        // not drilled in: the face path decides
        XCTAssertFalse(stage.keyDrilledIn(project, .lattice, mode: .groups))
        // the octet key's own colour is the octet's gate (its mount + minimised rule), never the Flexible key's
        let octet = LatticeLegendMode.colour(LatticeStructureClass.allCases[0].id)
        XCTAssertFalse(stage.keyDrilledIn(project, .lattice, mode: octet))
        // off the Flexible stage — another stage, or an octet project — the Flexible key is not on screen
        for s in WorkspaceStage.allCases where s != .lattice {
            XCTAssertFalse(stage.keyDrilledIn(project, s, mode: lattice), "\(s): the Flexible key is not mounted")
        }
        project.lattice.flexible = nil
        XCTAssertFalse(stage.keyDrilledIn(project, .lattice, mode: lattice), "an octet project: #354's own gate only")
    }

    /// The call site: #354's `legendDrilledIn` carries the Flexible disjunct, #354's own expression is
    /// intact, its one raw read stays, and the ruled H7/H8 lines read `legendDrilledIn` unchanged —
    /// so the probe, the double tap out and every drilled-in hide read one value again.
    func testLegendDrilledInCarriesTheFlexibleKey() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        let def = try member(ws, "private var legendDrilledIn: Bool")
        XCTAssertTrue(def.contains("latticeLegendMounted && !latticeLegendMinimized && latticeLegendMode.drilledIn"),
                      "#354's expression, unchanged")
        XCTAssertTrue(def.contains("|| flexibleMain.keyDrilledIn(project, stage, mode: latticeLegendMode)"),
                      "★ H14: the Flexible key's drill-in is a drill-in")
        XCTAssertEqual(ws.components(separatedBy: "latticeLegendMode.drilledIn").count - 1, 1,
                       "#354's pin: one raw read, its definition")
        XCTAssertEqual(ws.components(separatedBy: "flexibleMain.keyDrilledIn(").count - 1, 1, "H14 is one line")
        // the ruled lines (reviewer's ruling (i), 2026-10-08 19:13), verbatim
        XCTAssertTrue(ws.contains("onLatticeProbe: legendDrilledIn && flexibleMain.wantsWallProbe(latticeLegendMode)"))
        XCTAssertTrue(ws.contains("onLatticeProbeExit: legendDrilledIn\n"))
        XCTAssertTrue(ws.contains("if legendDrilledIn { return true }"))
        // the key H14 trusts: mounted exactly while the stage owns the page, and it resets the mode when it goes
        XCTAssertTrue(ws.contains("if flexibleMain.owns(project, stage) { FlexibleMainLegends(main: flexibleMain, mode: $latticeLegendMode,"))
        let legends = try FlexibleSource.text("FlexibleMainLegends.swift")
        XCTAssertTrue(legends.contains(".onDisappear {\n            if drilled != nil { mode = .groups }"))
        XCTAssertTrue(legends.contains("if let k = drilled, !now.contains(k) { mode = .groups }"))
        // the definition reads no stage mode (#354's pin: the prism and lattice-only carry over by construction)
        XCTAssertFalse(def.contains("stageMode"))
    }
}

import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE ORGANIC CHIP'S ACTION, END TO END — because the simulator harness cannot drive
/// the sheet's capsule chips at all (a pre-existing one, "Simple cubic", does not select
/// under it either), the chip is verified by doing exactly what its closure does and
/// following the value through `apply` into the job document.
final class LatticeWizardOrganicChipTests: XCTestCase {
    func testTheChipSelectsOrganicAndForcesShapeFitThroughToTheJob() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit") else { throw XCTSkip("no organic in core") }
        var settings = LatticeSettings(); settings.enabled = true
        settings.stageMode = .aesthetic
        var model = LatticeWizardModel(settings: settings)
        XCTAssertNotEqual(model.cellTransition, .organicGrade)
        // — what `organicTypeChip`'s Button does —
        model.cellTransition = .organicGrade
        model.organicShapeFit = true
        XCTAssertEqual(model.cellTransition, .organicGrade, "★ the chip's own `on` state")
        let out = model.applied(to: settings)
        XCTAssertEqual(out.algorithm, "organic")
        XCTAssertTrue(out.isOrganic)
        XCTAssertTrue(out.organicShapeFit, "★ finish is always grade-to-fit-shape (his item 3)")
        // — and the job the run is built from states the intent core demands —
        let lim = TopOptKit.LatticeLimits(rhoMin: 0.1, rhoMax: 0.6, certifiable: true, minCellsPerMember: 1)
        let spec = out.runSpec(limits: lim, generatable: true, memberMM: 8, lineWidthMM: 0.42)
        let g = spec?.gradingDictionary() ?? [:]
        XCTAssertEqual(g["algorithm"] as? String, "organic")
        XCTAssertEqual(g["intent"] as? String, "aesthetic",
                       "★ core refuses organic without an explicit aesthetic intent (measured on-device 2026-09-02)")
        // — Structural is the stage's own word, so core's refusal stays faithful —
        var structural = out; structural.stageMode = LatticeStageMode.structural
        let g2 = structural.runSpec(limits: lim, generatable: true, memberMM: 8, lineWidthMM: 0.42)?.gradingDictionary() ?? [:]
        XCTAssertEqual(g2["intent"] as? String, "structural")
        // — and no intent key ever appears on a non-organic job (bar U1: byte-identical) —
        var octet = settings; octet.algorithm = ""
        XCTAssertNil((octet.runSpec(limits: lim, generatable: true, memberMM: 8, lineWidthMM: 0.42)?.gradingDictionary() ?? [:])["intent"])
        // — and a lattice-type chip leaves organic again —
        var back = model; back.cellTransition = .defaultGrade
        XCTAssertNotEqual(back.applied(to: settings).algorithm, "organic")
    }

    /// ★ THE OCTET WINDOW MUST NOT RIDE INTO ORGANIC (reviewer, 2026-09-03). Measured
    /// on-device 2026-09-02: `cellSizeMode: auto` on disk, "Auto · grade" lit, and the
    /// organic job carried `cell_mode: swept, 5.5–6 mm` — the octet ladder's derived
    /// window, which for organic IS the separation field. Under organic an Auto pick
    /// now travels as core's own `auto` with no window; the octet path is the control
    /// and still derives its window (bar U1: byte-identical).
    func testOrganicAutoDoesNotInheritTheOctetsDerivedWindow() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_shape_fit") else { throw XCTSkip("no organic in core") }
        var s = LatticeSettings(); s.enabled = true; s.stageMode = .aesthetic
        s.densityMode = .sim; s.cellSizeMode = .auto
        let lim = TopOptKit.LatticeLimits(rhoMin: 0.1, rhoMax: 0.6, certifiable: true, minCellsPerMember: 1)
        // control: octet Auto derives a window (the PR 310 plan)
        let octet = s.runSpec(limits: lim, generatable: true, memberMM: 12, lineWidthMM: 0.42)?.gradingDictionary() ?? [:]
        XCTAssertNotEqual(octet["cell_mode"] as? String, "auto",
                          "control: the octet ladder still turns Auto into its own plan")
        // organic Auto: core's auto, no window
        var o = s; o.algorithm = "organic"
        let g = o.runSpec(limits: lim, generatable: true, memberMM: 12, lineWidthMM: 0.42)?.gradingDictionary() ?? [:]
        XCTAssertEqual(g["cell_mode"] as? String, "auto")
        XCTAssertNil(g["cell_min_mm"]); XCTAssertNil(g["cell_max_mm"])
        XCTAssertEqual(g["algorithm"] as? String, "organic")
    }
}

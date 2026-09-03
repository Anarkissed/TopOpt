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
}

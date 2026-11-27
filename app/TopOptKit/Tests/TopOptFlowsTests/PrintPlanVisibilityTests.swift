// PrintPlanVisibilityTests — B9 Flexible Setup (R8.1, plan.md §B9 tests): "Joints should only become visible if multiple
// filaments are selected and/or if there are areas not part of the flexible lattice." The stage row reads Setup │ Squish │
// Print plan only then (FlexibleStageCapsule.showsPlan reads FlexibleMainStage.showsPrintPlan).
//   * nothing set, one material: no Print plan (a part straight from Import);
//   * a face latticed in Selections: a lattice in a solid part — solid areas round it — the Print plan shows, before any
//     squish face (★ the gap: it waited for a squish face);
//   * a second material: the Print plan shows.
// The plan's "one material and all lattice → no Print plan" waits for E5's whole-part lattice: every Flexible lattice today is
// face prisms in a solid part.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintPlanVisibilityTests: XCTestCase {

    func model(facePrism: Bool, rigid: String? = nil) throws -> FlexibleStageModel {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        if let rigid { s.printPlans = .fresh(rigidMaterial: rigid) }
        let pm = try FlexibleHisProject.padProject(s, facePrism: facePrism)
        return FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
    }

    func testNothingSetOneMaterialHasNoPrintPlan() throws {
        let m = try model(facePrism: false)
        XCTAssertTrue(m.settings.faces.isEmpty && m.project.latticeAreaGroups.isEmpty, "premise: nothing set")
        XCTAssertFalse(FlexibleMainStage.showsPrintPlan(m), "Setup │ Squish only")
    }

    func testAFaceLatticedInSelectionsShowsThePrintPlan() throws {
        let m = try model(facePrism: true)
        XCTAssertTrue(m.settings.faces.isEmpty, "premise: no squish face yet")
        XCTAssertFalse(m.project.latticeAreaGroups.isEmpty, "premise: the Top is latticed in Selections")
        XCTAssertTrue(FlexibleMainStage.showsPrintPlan(m), "★ a lattice in a solid part: solid areas round it")
    }

    func testASecondMaterialShowsThePrintPlan() throws {
        let m = try model(facePrism: false, rigid: "PLA")
        XCTAssertTrue(FlexibleMainStage.showsPrintPlan(m), "two materials")
    }

    func testTheStageRowReadsTheRule() throws {
        let src = try String(contentsOf: FlexibleHisProject.repoRoot
            .appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleStageCapsule.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("private var showsPlan: Bool { FlexibleMainStage.showsPrintPlan("), "the capsule asks the one rule")
        XCTAssertTrue(src.contains("if showsPlan { segment(.plan"), "and shows its Print plan segment only then")
    }
}

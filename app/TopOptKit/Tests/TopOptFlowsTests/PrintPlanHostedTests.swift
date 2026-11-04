// PrintPlanHostedTests — B9 (#362), the Print plan page (app-map §3.7, flow §4.8; plan.md B9 › Hosted tests: PrintPlanHostedTests,
// PrintPlanResetHostedTests, PrintPlanVisibilityTests). The main stage's left panel and corner are hosted as the workspace
// mounts them (FlexibleSelectionsList, FlexibleCornerPair, FlexiblePrintPlanOverlays) with the stage on its Print plan page,
// on the A1 pad lookalike; every step is a real click through the window, a native menu driven while it tracks.
//   * first open: one material — the whole part, no seams, no add-ons; "+ Second material" → two pieces (the lattice in TPU,
//     the body in PLA) and one seam with no joint;
//   * Build Plan A is grey with ONE fix chip while a seam has no joint; the chip opens that seam's card;
//   * Held by › T-slot: the seam reads T-slot, the two lock keys appear as add-ons (each a switch), Build turns blue, and its
//     tap says in one plain line that building with joints needs the engine — the plan is never marked built (RED: a build
//     that marks it built is what the plain-line rule forbids);
//   * Plan ⌄ › + New plan: Plan B is current and starts from the app's cut (no joints);
//   * Reset: its confirm opens at the top middle, its yes ≥ 300 pt from Reset (U13); Clear all leaves a fresh Plan A (the
//     rigid plastic stays: it is the part's);
//   * the panel is the 440 pt wide panel (U14), its controls 44 pt and inside the window;
//   * old projects: no plan in the settings encodes byte-identical (nil = today's bytes).
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintPlanHostedTests: XCTestCase {
    static let size = CGSize(width: 1376, height: 1032)

    func appModel() throws -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("print-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AppModel(materialsPath: "/no/such/materials.json", store: ProjectStore(rootDir: dir))
    }

    /// The main stage's Print plan page as the workspace mounts its parts: the left panel at the panels' place, the corner pair
    /// bottom-right, the Reset confirm over the page.
    struct PlanPage: View {
        @ObservedObject var main: FlexibleMainStage
        @ObservedObject var project: ProjectModel
        let app: AppModel
        @State private var collapsed = false
        var body: some View {
            ZStack {
                DS.Color.background.color
                FlexibleSelectionsList(project: project, main: main, collapsed: $collapsed, cards: [:], groupCards: [:], cardsChanged: {})
                    .padding(.leading, PageChrome.edge).padding(.top, PageChrome.panelTop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                FlexibleCornerPair(main: main, project: project, app: app, openSquish: {}, changeGravity: {})
                    .padding(PageChrome.edge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                FlexiblePrintPlanOverlays(main: main)
            }
        }
    }

    func planPage() throws -> (SquishHost, FlexibleMainStage, FlexibleStageModel) {
        let stage = FlexibleMainStage()
        let (r, m) = try SquishHost.pad(self, edges: false, stage: stage)
        stage.page = .plan
        let h = SquishHost(PlanPage(main: stage, project: r.project, app: try appModel()), size: Self.size, test: self)
        SquishHost.pump(1.5)
        return (h, stage, m)
    }

    func testFirstOpenSecondMaterialAndTheFixChip() throws {
        let (h, stage, m) = try planPage()
        XCTAssertNil(m.settings.printPlans, "nothing saved until he changes the plan")
        let panel = try XCTUnwrap(h.frame("planPanel"), "★ the Print plan's panel is the stage's left panel")
        XCTAssertEqual(panel.width, PageChrome.widePanelWidth, accuracy: 0.5, "U14: the wide panel")
        // one material: the whole part, no seam — Build has nothing to wait for
        XCTAssertNil(h.frame("planSeam-lattice-body"), "one material: no seam")
        try h.probe("planSecondMaterial", "+ Second material", covers: ["planBuild"])
        try h.tap("planSecondMaterial", "+ Second material")
        XCTAssertEqual(m.settings.printPlans?.rigidMaterial, "PLA", "★ the solid areas take PLA")
        let seam = try h.probe("planSeam-lattice-body", "the seam row")
        XCTAssertGreaterThanOrEqual(seam.height, 47.5, "U3: a seam row is 48 pt")
        // Build is grey with ONE fix chip
        let fix = try h.probe("planFix", "the fix chip")
        XCTAssertNotNil(h.frame("planBuild"), "Build Plan A is drawn")
        XCTAssertTrue(FlexiblePrintPlanRules.needing(stage.shownPlans).count == 1, "one seam needs a joint")
        try h.tap("planFix", "the fix chip")
        XCTAssertEqual(stage.planSeam, "lattice-body", "★ the chip opens that seam")
        XCTAssertNotNil(h.frame("planHeld-lattice-body"), "its card shows Held by")
        print("PRINT-PLAN first open: panel \(panel) · seam \(seam) · fix \(fix)")
    }

    func testHeldByTSlotCallsForLockKeysAndBuildSaysItNeedsTheEngine() throws {
        let (h, stage, m) = try planPage()
        try h.tap("planSecondMaterial", "+ Second material")
        try h.tap("planSeam-lattice-body", "the seam row")
        let offered = try h.pickFromMenu("planHeld-lattice-body", "T-slot", what: "Held by ⌄")
        XCTAssertTrue(offered.contains { $0.hasPrefix("Printed together") } && offered.contains { $0.hasPrefix("Capture") },
                      "TPU ↔ rigid offers the six joints: \(offered)")
        XCTAssertEqual(m.settings.printPlans?.plan.joints["lattice-body"], "T-slot", "★ the seam is held by a T-slot")
        XCTAssertNil(h.frame("planFix"), "every seam held: no fix chip")
        try h.probe("planAddOn-lattice-body/lock-1", "Lock key 1")
        try h.probe("planAddOn-lattice-body/lock-2", "Lock key 2")
        try h.probe("numberField-planPlate-lattice-body", "the TPU plate", covers: [])
        try h.tap("planBuild", "Build Plan A")
        XCTAssertEqual(stage.planNote, FlexiblePrintPlanCopy.buildNeedsEngine, "★ one plain line: the engine builds joints")
        XCTAssertEqual(m.settings.printPlans?.plan.built, false, "★ never shown built before the engine builds it")
    }

    func testANewPlanStartsFromTheAppsCut() throws {
        let (h, stage, m) = try planPage()
        try h.tap("planSecondMaterial", "+ Second material")
        stage.editPlans { $0.plan.joints["lattice-body"] = "Flange" }
        SquishHost.pump(0.5)
        try h.pickFromMenu("planMenu", "New plan", what: "Plan ⌄")
        let p = try XCTUnwrap(m.settings.printPlans)
        XCTAssertEqual(p.plans.map(\.name), ["Plan A", "Plan B"], "★ + New plan adds Plan B")
        XCTAssertEqual(p.plan.name, "Plan B", "…and it is the current plan")
        XCTAssertTrue(p.plan.joints.isEmpty, "★ it starts from the app's cut: no joints")
        XCTAssertNotNil(h.frame("planFix"), "Plan B's seam needs a joint")
    }

    func testResetAsksAtTheTopMiddleAndLeavesAFreshPlanA() throws {
        let (h, stage, m) = try planPage()
        try h.tap("planSecondMaterial", "+ Second material")
        stage.editPlans { p in p.plan.joints["lattice-body"] = "T-slot"; p.plans.append(FlexiblePrintPlan(name: "Plan B")) }
        SquishHost.pump(0.5)
        let reset = try h.probe("planReset", "Reset")
        try h.tap("planReset", "Reset")
        XCTAssertTrue(stage.planResetAsk, "Reset asks")
        let yes = try XCTUnwrap(h.frame("clearAllYes"), "Clear all")
        let card = try XCTUnwrap(h.frame("clearAllCard"), "the confirm")
        XCTAssertEqual(card.midX, Self.size.width / 2, accuracy: 1, "★ the confirm opens at the top middle")
        let d = hypot(yes.midX - reset.midX, yes.midY - reset.midY)
        XCTAssertGreaterThanOrEqual(d, 300, "★ U13: Clear all is \(Int(d)) pt from Reset")
        try h.tap("clearAllYes", "Clear all")
        let p = try XCTUnwrap(m.settings.printPlans)
        XCTAssertEqual(p.plans.map(\.name), ["Plan A"], "★ a fresh Plan A")
        XCTAssertTrue(p.plan.joints.isEmpty, "…from the app's cut")
        XCTAssertEqual(p.rigidMaterial, "PLA", "the rigid plastic is the part's: it stays")
        XCTAssertFalse(stage.planResetAsk)
    }

    func testOldProjectsReadAsNoPlanAndEncodeByteIdentical() throws {
        let s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let bytes = try JSONEncoder().encode(s)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("printPlans"), "★ nil is omitted: today's bytes")
        let back = try JSONDecoder().decode(FlexibleStageSettings.self, from: bytes)
        XCTAssertNil(back.printPlans, "an old project reads as no plan")
        var withPlan = s
        withPlan.printPlans = .fresh(rigidMaterial: "PLA")
        XCTAssertEqual(withPlan.designInputs, s.designInputs, "★ a plan is never part of the lattice's key")
    }

    func testThePrintPlanShowsOnlyWhereAPlanApplies() throws {
        XCTAssertFalse(FlexibleMainStage.showsPrintPlan(nil))
        let (_, m) = try SquishHost.pad(self, edges: false)
        XCTAssertTrue(FlexibleMainStage.showsPrintPlan(m), "faces set up in a solid part: solid areas round them")
    }
}
#endif

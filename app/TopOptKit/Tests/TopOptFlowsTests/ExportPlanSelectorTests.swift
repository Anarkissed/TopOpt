// ExportPlanSelectorTests — B9 (#362), Export part's plan (P4, J-8): a plain selector, one segment per plan saying built or
// not; what the picked plan needs said INSIDE the card; "Build Plan B, then export", dim while a seam has no joint.
import XCTest
import SwiftUI
@testable import TopOptFlows

final class ExportPlanSelectorTests: XCTestCase {
    /// Two materials (the app's cut: Lattice ↔ Body), Plan A with its joint, Plan B with none.
    static func twoPlans(builtA: Bool = false) -> FlexiblePrintPlans {
        var p = FlexiblePrintPlans.fresh(rigidMaterial: "PLA")
        p.plans[0].joints["lattice-body"] = "T-slot"
        p.plans[0].built = builtA
        p.plans.append(FlexiblePrintPlan(name: "Plan B"))
        return p
    }

    func testEachPlanSaysWhatItNeedsAndTheButtonSaysWhatItDoes() {
        let p = Self.twoPlans()
        let a = p.plans[0].id, b = p.plans[1].id
        XCTAssertEqual(FlexibleExportPlan.segments(p).map(\.title), ["Plan A \u{00B7} not built yet", "Plan B \u{00B7} not built yet"])
        XCTAssertEqual(FlexibleExportPlan.need(p, chosen: a), .notBuilt("Plan A isn't built yet. Export builds it first."))
        XCTAssertEqual(FlexibleExportPlan.button(p, chosen: a), "Build Plan A, then export", "★ J-8")
        XCTAssertTrue(FlexibleExportPlan.live(FlexibleExportPlan.need(p, chosen: a)))
        XCTAssertEqual(FlexibleExportPlan.need(p, chosen: b), .noJoint("Plan B: Lattice \u{2194} Body has no joint yet"),
                       "★ the picked plan's own seam, not the open plan's")
        XCTAssertFalse(FlexibleExportPlan.live(FlexibleExportPlan.need(p, chosen: b)), "★ dim while a seam has no joint")
        XCTAssertEqual(FlexibleExportPlan.need(p, chosen: nil), FlexibleExportPlan.need(p, chosen: a), "nothing picked: the open plan")
        let built = Self.twoPlans(builtA: true)
        XCTAssertEqual(FlexibleExportPlan.need(built, chosen: built.plans[0].id), .ready)
        XCTAssertEqual(FlexibleExportPlan.button(built, chosen: built.plans[0].id), "Export Plan A")
        XCTAssertEqual(FlexibleExportPlan.segments(built).first?.title, "Plan A \u{00B7} built")
    }

    /// CONTROL: one material has no seam, so no plan can lack a joint.
    func testOneMaterialNeedsNoJoint() {
        var p = FlexiblePrintPlans.fresh()
        p.plans.append(FlexiblePrintPlan(name: "Plan B"))
        XCTAssertEqual(FlexibleExportPlan.need(p, chosen: p.plans[1].id), .notBuilt("Plan B isn't built yet. Export builds it first."))
    }
}

#if canImport(AppKit)
@MainActor
final class ExportPlanSelectorHostedTests: XCTestCase {
    final class Opened { var count = 0 }

    func testRealClicksPickAPlanSayItsNeedAndOpenThePrintPlan() throws {
        let p = ExportPlanSelectorTests.twoPlans()
        let opened = Opened()
        let v = FlexibleExportPlanSelector(plans: p, openPrintPlan: { opened.count += 1 })
            .frame(width: 400).padding(24)
        let h = AppBuildHost(v, size: CGSize(width: 480, height: 360), test: self)
        h.pump(1)
        let a = try h.probe("exportPlan-Plan A", "Plan A's segment")
        _ = try h.probe("exportPlan-Plan B", "Plan B's segment")
        XCTAssertNotNil(h.frames.all["exportPlanNeed"], "★ the open plan's need, said in the card")
        XCTAssertNil(h.frames.all["exportPlanOpen"], "Plan A has its joint: no [Open Print plan]")
        let b = try XCTUnwrap(h.frames.all["exportPlan-Plan B"])
        h.click(CGPoint(x: b.midX, y: b.midY))
        let open = try h.probe("exportPlanOpen", "★ Plan B: [Open Print plan] beside its need")
        try h.probe("exportPlanBuild", "the main button")
        h.click(CGPoint(x: open.midX, y: open.midY))
        XCTAssertEqual(opened.count, 1, "★ a real click opens the Print plan")
        h.click(CGPoint(x: a.midX, y: a.midY))
        XCTAssertNil(h.frames.all["exportPlanOpen"], "back on Plan A: no seam lacks a joint")
        let build = try XCTUnwrap(h.frames.all["exportPlanBuild"])
        h.click(CGPoint(x: build.midX, y: build.midY))
        XCTAssertNotNil(h.frames.all["exportPlanNote"], "★ Build, then export says, in the card, that building with joints waits")
        let link = try h.probe("exportPlanLink", "★ J-1: Print plan › from the card")
        h.click(CGPoint(x: link.midX, y: link.midY))
        XCTAssertEqual(opened.count, 2, "the link opens the Print plan")
    }
}
#endif

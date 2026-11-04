// PlanCutHostedTests — B9 (#362) slice 3, + Cut on the Print plan (plan.md B9 › Hosted tests: PlanCutHostedTests and
// PlaneFirstHostedTests; design-system U18, U19). The Print plan page hosted as the workspace mounts it (PrintPlanHostedTests'
// PlanPage) with a real camera model; real clicks through the window, native menus driven while they track.
//   * + Cut ⌄ offers the six ways;
//   * A plane opens the plane card FIRST (Top · Front · Side · A face), the camera untouched; Side → the bar: the plane chip,
//     Move, Tilt ↺ ↻ and Rotate ↺ ↻ (U18), ✓; the plane is drawn on the part; the camera sees it EDGE-ON;
//   * Tilt ↻ leans the plane 15° (its normal moves);
//   * ✓ keeps the cut (a row under Pieces, one plain line on the engine) and brings HIS view back; ✕ adds nothing and brings
//     his view back;
//   * Draw on a plane › Top: the camera faces the plane; ✓ waits for a stroke (the next slice);
//   * Join removes the cut.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PlanCutHostedTests: XCTestCase {
    let plans = PrintPlanHostedTests()

    func page() throws -> (SquishHost, FlexibleMainStage, FlexibleStageModel, OrbitCameraModel) {
        let camera = OrbitCameraModel()
        let (h, stage, m) = try plans.planPageFor(self, camera: camera)
        try h.tap("planSecondMaterial", "+ Second material")   // + Cut is a two-material plan's
        return (h, stage, m, camera)
    }

    /// The world normal of the cut's plane.
    func worldNormal(_ c: FlexiblePlanCut, _ project: ProjectModel) -> SIMD3<Float> {
        let settle = project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let b = try! XCTUnwrap(project.viewerMesh?.bounds)
        return simd_normalize(settle.act(FlexiblePlaneFrame.frame(c, bounds: b).n))
    }

    func testAPlaneStartsFromItsPlaneTurnsTheViewEdgeOnAndComesBack() throws {
        let (h, stage, m, camera) = try page()
        let mine = camera.camera
        let offered = try h.pickFromMenu("planCutMenu", "A plane", what: "+ Cut ⌄")
        for w in FlexibleCutWay.allCases { XCTAssertTrue(offered.contains { $0.hasPrefix(w.title) }, "★ + Cut offers \(w.title): \(offered)") }
        // the plane card first, the view untouched
        XCTAssertEqual(stage.planCut?.step, .pick, "★ U19: the plane card first")
        for b in ["top", "front", "side", "face"] { try h.probe("planPlane-\(b)", "the plane card's \(b)") }
        XCTAssertEqual(camera.camera, mine, "the view waits for a plane")
        XCTAssertTrue(stage.planeItems(m.project).isEmpty, "no plane drawn yet")
        // Side → the bar; the plane on the part; the view edge-on
        try h.tap("planPlane-side", "Side")
        XCTAssertEqual(stage.planCut?.step, .place)
        let bar = try XCTUnwrap(h.frame("planCutBar"), "★ the cut bar")
        XCTAssertGreaterThanOrEqual(bar.minX, PageChrome.edge + PageChrome.widePanelWidth, "the bar clears the panel")
        XCTAssertLessThanOrEqual(bar.maxX, h.size.width - PageChrome.gizmoClearance + 1, "the bar clears the view corner")
        for k in ["planCutPlane", "planCutTiltMinus", "planCutTiltPlus", "planCutRotateMinus", "planCutRotatePlus", "planCutOK", "planCutCancel"] {
            try h.probe(k, "the bar's \(k)")
        }
        XCTAssertNotNil(h.frame("numberField-planCutMove"), "Move is a number field")
        XCTAssertNotNil(h.frame("numberField-planCutTilt"), "★ U18: Tilt…")
        XCTAssertNotNil(h.frame("numberField-planCutRotate"), "★ …and its Rotate in the same bar")
        XCTAssertEqual(stage.planeItems(m.project).count, 1, "★ the plane is drawn on the part")
        let cut = try XCTUnwrap(stage.planCut?.cut)
        XCTAssertLessThan(abs(simd_dot(camera.camera.direction, worldNormal(cut, m.project))), 0.15,
                          "★ U19: the camera sees the plane edge-on")
        // Tilt ↻: the plane leans 15°
        let n0 = worldNormal(cut, m.project)
        try h.tap("planCutTiltPlus", "Tilt ↻")
        XCTAssertEqual(stage.planCut?.cut.tiltDeg, 15)
        let n1 = worldNormal(try XCTUnwrap(stage.planCut?.cut), m.project)
        XCTAssertEqual(acos(min(1, simd_dot(n0, n1))) * 180 / .pi, 15, accuracy: 0.5, "★ the job's normal leans 15°")
        // ✓: kept, a row, one plain line; his view back
        try h.tap("planCutOK", "✓")
        XCTAssertNil(stage.planCut)
        XCTAssertEqual(m.settings.printPlans?.plan.cuts?.count, 1, "★ the cut is kept in the plan")
        XCTAssertEqual(m.settings.printPlans?.plan.cuts?.first?.tiltDeg, 15)
        XCTAssertNotNil(h.frame("planCutRow-0"), "a row under Pieces")
        XCTAssertEqual(stage.planNote, FlexiblePlanCutCopy.kept(.plane), "one plain line: its pieces come with the engine")
        XCTAssertEqual(camera.camera, mine, "★ U19: his own view comes back after ✓")
        // Join removes it
        try h.tap("planCutJoin-0", "Join")
        XCTAssertNil(m.settings.printPlans?.plan.cuts, "★ Join undoes the cut")
    }

    func testCancelAddsNothingAndBringsTheViewBack() throws {
        let (h, stage, m, camera) = try page()
        let mine = camera.camera
        try h.pickFromMenu("planCutMenu", "Keyed step cut", what: "+ Cut ⌄")
        try h.tap("planPlane-front", "Front")
        XCTAssertNotEqual(camera.camera, mine, "the view turned to the plane")
        XCTAssertNotNil(h.frame("numberField-planCutKey"), "a keyed cut has its Key size")
        try h.tap("planCutCancel", "✕")
        XCTAssertNil(stage.planCut)
        XCTAssertNil(m.settings.printPlans?.plan.cuts, "✕ adds nothing")
        XCTAssertEqual(camera.camera, mine, "★ U19: his own view comes back after ✕")
    }

    func testDrawOnAPlaneFacesThePlane() throws {
        let (h, stage, m, camera) = try page()
        try h.pickFromMenu("planCutMenu", "Draw on a plane", what: "+ Cut ⌄")
        XCTAssertEqual(stage.planCut?.step, .pick, "★ U19: drawing starts from a plane too")
        try h.tap("planPlane-top", "Top")
        let cut = try XCTUnwrap(stage.planCut?.cut)
        XCTAssertGreaterThan(abs(simd_dot(camera.camera.direction, worldNormal(cut, m.project))), 0.95,
                             "★ U19: to draw, the camera faces the plane")
        XCTAssertNotNil(h.frame("planCutPencil"), "✎ Pencil")
        XCTAssertNotNil(h.frame("planCutSpline"), "〰 Spline")
        try h.tap("planCutOK", "✓ before a stroke")
        XCTAssertNotNil(stage.planCut, "✓ waits for a stroke")
    }
}
#endif

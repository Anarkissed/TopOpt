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

    /// The main page's view frame, as the workspace hands it each render (H6): the camera's projection and the part's settle.
    func view(_ camera: OrbitCameraModel, _ project: ProjectModel, size: CGSize) throws -> LatticeBandChipFrame {
        let settle = project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let b = try XCTUnwrap(project.viewerMesh?.bounds)
        return LatticeBandChipFrame(projection: CameraProjection(camera: camera.camera, viewportSize: size),
                                    modelCentre: (b.min + b.max) * 0.5, modelRotation: settle)
    }

    func testDrawOnAPlaneFacesThePlaneAndKeepsThePencilStrokeOnIt() throws {
        let (h, stage, m, camera) = try page()
        try h.pickFromMenu("planCutMenu", "Draw on a plane", what: "+ Cut ⌄")
        XCTAssertEqual(stage.planCut?.step, .pick, "★ U19: drawing starts from a plane too")
        try h.tap("planPlane-top", "Top")
        let cut = try XCTUnwrap(stage.planCut?.cut)
        XCTAssertGreaterThan(abs(simd_dot(camera.camera.direction, worldNormal(cut, m.project))), 0.95,
                             "★ U19: to draw, the camera faces the plane")
        try h.probe("planCutPencil", "✎ Pencil")
        try h.probe("planCutSpline", "〰 Spline")
        try h.tap("planCutOK", "✓ before a stroke")
        XCTAssertNotNil(stage.planCut, "✓ waits for a stroke")
        // ✎ and a real drag across the drawing area
        try h.tap("planCutPencil", "✎ Pencil")
        XCTAssertEqual(stage.planCut?.tool, .pencil)
        let area = try XCTUnwrap(h.frame("planCutCanvas"), "the drawing area")
        let line = (0...20).map { i in CGPoint(x: area.minX + 40 + CGFloat(i) * (area.width - 80) / 20, y: area.midY + CGFloat(i % 3) * 6) }
        h.drag(line)
        XCTAssertGreaterThanOrEqual(stage.planCut?.stroke.count ?? 0, 10, "★ the drag draws the stroke")
        stage.viewFrame = try view(camera, m.project, size: h.size)
        try h.tap("planCutOK", "✓")
        let kept = try XCTUnwrap(m.settings.printPlans?.plan.cuts?.first, "★ the drawing is kept")
        XCTAssertEqual(kept.way, .curve)
        XCTAssertEqual(kept.curveTool, "pencil")
        let uv = try XCTUnwrap(kept.curveUV)
        XCTAssertGreaterThanOrEqual(uv.count, 10, "the stroke on the plane")
        let b = try XCTUnwrap(m.project.viewerMesh?.bounds)
        let half = Double(simd_reduce_max(b.max - b.min))
        XCTAssertTrue(uv.allSatisfy { abs($0[0]) < half && abs($0[1]) < half }, "★ every point lands on the plane, inside the part's reach")
        XCTAssertNil(stage.planCut)
    }

    func testTheSplineTakesTappedPointsAndATapAgainRemovesOne() throws {
        let (h, stage, _, _) = try page()
        try h.pickFromMenu("planCutMenu", "Draw on a plane", what: "+ Cut ⌄")
        try h.tap("planPlane-front", "Front")
        try h.tap("planCutSpline", "〰 Spline")
        let area = try XCTUnwrap(h.frame("planCutCanvas"))
        let pts = [0.2, 0.5, 0.8].map { CGPoint(x: area.minX + area.width * $0, y: area.midY) }
        for p in pts { h.click(p, settle: 0.3) }
        XCTAssertEqual(stage.planCut?.stroke.count, 3, "★ three taps, three points")
        h.click(pts[1], settle: 0.3)
        XCTAssertEqual(stage.planCut?.stroke.count, 2, "★ a tap on a point removes it")
        XCTAssertNotNil(h.frame("planCutOK"))
    }

    func testAFaceLaysThePlaneOnTheTappedFlatFace() throws {
        let (h, stage, m, camera) = try page()
        try h.pickFromMenu("planCutMenu", "A plane", what: "+ Cut ⌄")
        try h.tap("planPlane-face", "A face")
        XCTAssertEqual(stage.planCut?.step, .face, "★ the bar waits for a tap on a flat face")
        XCTAssertNotNil(h.frame("planCutFaceLine"), "it says so")
        let mesh = try XCTUnwrap(m.project.viewerMesh)
        // a face with no triangles (not flat, not there): it says so and keeps waiting
        stage.tapFace(m.project, face: 99_999, point: nil, mesh: mesh)
        XCTAssertEqual(stage.planCut?.step, .face)
        XCTAssertEqual(stage.planCut?.faceMiss, true, "★ not a flat face: the bar says so")
        // the pad's top face (flat): the plane lies on it, and the view sees it edge-on
        let top = FlexibleHisProject.topFace(mesh)
        stage.tapFace(m.project, face: FaceID(top), point: nil, mesh: mesh)
        SquishHost.pump(0.5)
        let cut = try XCTUnwrap(stage.planCut?.cut)
        XCTAssertEqual(stage.planCut?.step, .place)
        XCTAssertEqual(cut.base, .face)
        let fp = try XCTUnwrap(FlexiblePlaneFrame.facePlane(Int32(top), mesh: mesh))
        let n = try XCTUnwrap(cut.faceNormal)
        XCTAssertGreaterThan(simd_dot(SIMD3<Float>(Float(n[0]), Float(n[1]), Float(n[2])), fp.normal), 0.999, "★ the plane takes the face's normal")
        XCTAssertLessThan(abs(simd_dot(camera.camera.direction, worldNormal(cut, m.project))), 0.15, "★ U19: edge-on to place it")
        try h.tap("planCutOK", "✓")
        XCTAssertEqual(m.settings.printPlans?.plan.cuts?.first?.base, .face, "kept on the face")
    }
}
#endif

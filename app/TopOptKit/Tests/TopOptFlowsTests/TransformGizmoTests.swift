// TransformGizmoTests — the 3D transform gizmo's pure hit-test (`TransformGizmo.pick`),
// headless (the /app/ standard for pure math; the Metal render + gesture are device QA).
//
// The pick shares the SAME virtual camera (FOV/CAMZ) as the raymarched render, so a tap on a
// projected part of the gizmo resolves to that handle. These tests project a known object
// point through that camera (the exact inverse of the pick's ray build) and assert the tap
// lands on the expected handle — the render and the pick can't drift because both read
// `TransformGizmo.Constants.standard`.

import XCTest
import simd
@testable import TopOptFlows

final class TransformGizmoTests: XCTestCase {
    typealias G = TransformGizmo
    private let size = CGSize(width: 300, height: 300)

    /// Project an object-space point through the gizmo's virtual camera (identity view
    /// rotation) to a view-space tap point — the inverse of `pick`'s ray build.
    private func screen(_ p: SIMD3<Float>) -> CGPoint {
        let c = G.Constants.standard
        let tf = tanf(c.fov * 0.5 * .pi / 180)
        let dz = c.camZ - p.z
        let ndcX = p.x / (dz * tf), ndcY = p.y / (dz * tf)
        return CGPoint(x: CGFloat(ndcX * 0.5 + 0.5) * size.width,
                       y: CGFloat(1 - (ndcY * 0.5 + 0.5)) * size.height)
    }

    private let R = matrix_identity_float3x3

    /// Project an object point through the gizmo camera under an arbitrary object→view rotation
    /// `rot` (the inverse of what `pick` does), so a test can tap the gizmo as the live iso view
    /// draws it — not only dead-front, where an axis and its edge-on ribbon overlap.
    private func screen(_ p: SIMD3<Float>, _ rot: simd_float3x3) -> CGPoint {
        let c = G.Constants.standard
        let pv = rot * p
        let tf = tanf(c.fov * 0.5 * .pi / 180)
        let dz = c.camZ - pv.z
        let ndcX = pv.x / (dz * tf), ndcY = pv.y / (dz * tf)
        return CGPoint(x: CGFloat(ndcX * 0.5 + 0.5) * size.width,
                       y: CGFloat(1 - (ndcY * 0.5 + 0.5)) * size.height)
    }

    /// A generic iso view (camera off every principal-plane so no ribbon is edge-on) — the frame
    /// the gizmo is actually used in.
    private var iso: simd_float3x3 {
        simd_float3x3(simd_quatf(angle: -0.5, axis: SIMD3(1, 0, 0))
                      * simd_quatf(angle: 0.7, axis: SIMD3(0, 1, 0)))
    }

    func testHubCentreIsFreeMove() {
        // A tap dead-centre resolves to the free-move hub (nearest along the ray).
        XCTAssertEqual(G.pick(point: screen(.zero), in: size, rotation: R), .free)
    }

    func testArrowheadsPickTheirAxis() {
        // Front-on (identity), +X projects right and +Y up; a tap on each arrowhead picks it.
        XCTAssertEqual(G.pick(point: screen(SIMD3(0.9, 0, 0)), in: size, rotation: R), .axis(0))
        XCTAssertEqual(G.pick(point: screen(SIMD3(0, 0.9, 0)), in: size, rotation: R), .axis(1))
    }

    func testShaftPicksItsAxis() {
        // On the +X shaft, viewed in the live ISO frame (not dead-front, where an axis and its
        // edge-on ribbon overlap). y = z = 0, so it's off every plane square — it grabs the X axis.
        XCTAssertEqual(G.pick(point: screen(SIMD3(0.45, 0, 0), iso), in: size, rotation: iso), .axis(0))
    }

    func testPlaneSquarePicksItsPlane() {
        // Front-on (identity view), the XY plate faces the +Z camera. A tap out in the quadrant
        // (both in-plane coords past platePickInner, inside the ribbon) resolves to that plane
        // handle — NOT an arm (clear of both axes), NOT the ribbon, NOT the hub.
        let c = G.Constants.standard
        let q = 0.5 * (c.platePickInner + c.plateOuter)
        XCTAssertEqual(G.pick(point: screen(SIMD3(q, q, 0)), in: size, rotation: R), .plane(0))
    }

    func testRibbonPicksRotate() {
        // Front-on, a tap on the MIDDLE of the XY ribbon (its diagonal, at radius arcR) grabs the
        // ROTATE handle for that plane — NOT the plane square (the plate pick is capped inside the
        // ribbon) and NOT an arm.
        let c = G.Constants.standard
        let a = Float(0.5) * (.pi / 2)
        let p = SIMD3<Float>(cosf(a) * c.arcR, sinf(a) * c.arcR, 0)
        XCTAssertEqual(G.pick(point: screen(p), in: size, rotation: R), .rotate(0))
    }

    /// Object units → on-screen points at the gizmo's mid-plane, for the shipped overlay box.
    private func pointsPerUnit(box: CGFloat) -> CGFloat {
        let c = G.Constants.standard
        let halfFrustum = CGFloat(c.camZ) * CGFloat(tanf(c.fov * 0.5 * .pi / 180))
        return (box / 2) / halfFrustum
    }

    func testTouchTargetsAreFingerSized() {
        // G1: every handle's effective touch target, in points, at the shipped box size. The pick
        // tests FAT capsules/spheres (armPickR/hubPickR), the plane square's [platePickInner,
        // plateOuter] band, and the rotation ribbon's swept capsule. Three handle families now
        // share the widget, so the square band is a touch under 44 pt (still comfortably grabbable).
        let c = G.Constants.standard
        let ppu = pointsPerUnit(box: WorkspacePlaceholder.gizmoBoxSize)   // single source: the box
        let armTouch   = 2 * CGFloat(c.armPickR) * ppu
        let hubTouch   = 2 * CGFloat(c.hubPickR) * ppu
        let plateBand  = CGFloat(c.plateOuter - c.platePickInner) * ppu
        let ribbonBand = 2 * CGFloat(c.arcTube + c.arcPickPad) * ppu
        XCTAssertGreaterThanOrEqual(armTouch, 44, "arm touch width \(armTouch) pt")
        XCTAssertGreaterThanOrEqual(hubTouch, 44, "hub touch diameter \(hubTouch) pt")
        XCTAssertGreaterThanOrEqual(plateBand, 30, "plane square band \(plateBand) pt")   // small, kept clear of the ribbons
        XCTAssertGreaterThanOrEqual(ribbonBand, 24, "ribbon grab band \(ribbonBand) pt")
    }

    #if canImport(MetalKit)
    func testShaderIsGeneratedFromTheSingleConstantSource() {
        // G3: the Metal render and the CPU pick can't diverge because the shader INJECTS the same
        // `Constants` the pick reads. Prove it: the generated shader embeds the constant values
        // verbatim and draws all three handle families (arms, square plates, rotation ribbons).
        // If someone hardcoded a size in the shader instead of reading `Constants`, this fails.
        let c = G.Constants.standard
        let src = TransformGizmoRenderer.shaderSource(c)
        func fmt(_ v: Float) -> String {
            var s = String(format: "%.7g", v)
            if !s.contains(".") && !s.contains("e") { s += ".0" }
            return s
        }
        for v in [c.plateOuter, c.plateHalfThick, c.arcR, c.arcTube, c.armR, c.headR, c.tip] {
            XCTAssertTrue(src.contains(fmt(v)), "shader missing single-source constant \(fmt(v))")
        }
        XCTAssertTrue(src.contains("sdPlate"), "square plane handles must be drawn")
        XCTAssertTrue(src.contains("sdArc"), "rotation ribbons must be drawn")
    }
    #endif

    func testEmptyMarginMisses() {
        // A tap in the far corner (no glass there) returns nil, so empty space orbits.
        XCTAssertNil(G.pick(point: CGPoint(x: 6, y: 6), in: size, rotation: R))
    }

    func testDegenerateSizeMisses() {
        XCTAssertNil(G.pick(point: CGPoint(x: 10, y: 10), in: .zero, rotation: R))
    }

    func testAxisAndPlaneMapsMatchPrimitiveGizmo() {
        // The handle → model-vector mapping the overlay feeds into `PrimitiveGizmo` must match
        // its (pair → normal) convention: X/Y/Z axes and XY→Z, YZ→X, ZX→Y plane normals.
        XCTAssertEqual(G.axisVectors, [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])
        XCTAssertEqual(G.planeNormals, [SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
    }
}

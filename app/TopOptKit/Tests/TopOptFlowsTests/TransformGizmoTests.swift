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
        // Partway out along the +X shaft, BEYOND the arc radius (0.52) so the arc — which
        // bulges toward the camera — doesn't occlude it, still grabs the X axis.
        XCTAssertEqual(G.pick(point: screen(SIMD3(0.62, 0, 0)), in: size, rotation: R), .axis(0))
    }

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

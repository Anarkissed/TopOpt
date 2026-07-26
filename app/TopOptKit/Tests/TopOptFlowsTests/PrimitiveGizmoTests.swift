// PrimitiveGizmoTests — the transform-gizmo PURE math (DEFECT 2). Translate (single
// axis / plane / free), rotate-about-axis, and the ring-angle + ray primitives, all in
// model space with no camera or SwiftUI. The gesture that supplies the model-space ray
// and the Metal/SwiftUI knobs are the device-QA'd layers (G8 is the maintainer's step).

import XCTest
import simd
@testable import TopOptFlows

final class PrimitiveGizmoTests: XCTestCase {
    typealias G = PrimitiveGizmo

    private func ray(_ o: SIMD3<Double>, _ d: SIMD3<Double>) -> G.Ray { G.Ray(origin: o, dir: d) }

    // MARK: - no jump at grab (every handle)

    /// Resolving the grab ray itself returns the primitive unchanged — no teleport when a
    /// handle is first touched (the grab offset is preserved).
    func testGrabRayIsIdentity() {
        for handle in [G.Handle.axis(SIMD3(0,0,1)), .plane(SIMD3(0,0,1)), .free, .rotate(SIMD3(0,0,1))] {
            let g = ray(SIMD3(1, 2, 10), SIMD3(0, 0, -1))
            let d = G.Drag(handle: handle, startCenter: SIMD3(0.5, 0.5, 0), startAxis: SIMD3(1, 0, 0),
                           grab: g, viewDir: SIMD3(0, 0, -1))
            let r = d.resolve(currentRay: g)
            XCTAssertEqual(r.center, SIMD3(0.5, 0.5, 0), "grab ray must not move the centre")
            XCTAssertLessThan(simd_distance(simd_normalize(r.axis), SIMD3(1, 0, 0)), 1e-9,
                              "grab ray must not turn the axis")
        }
    }

    // MARK: - translate along a single axis

    func testTranslateAlongAxisMovesOnlyOnThatAxis() {
        let d = G.Drag(handle: .axis(SIMD3(0, 0, 1)), startCenter: .zero, startAxis: SIMD3(0, 0, 1),
                       grab: ray(SIMD3(5, 0, 3), SIMD3(-1, 0, 0)))
        let r = d.resolve(currentRay: ray(SIMD3(5, 0, 8), SIMD3(-1, 0, 0)))
        XCTAssertEqual(r.center.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.center.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r.center.z, 5, accuracy: 1e-9, "moved +5 mm along the Z axis only")
        XCTAssertEqual(simd_normalize(r.axis), SIMD3(0, 0, 1), "axis fixed during a translate")
    }

    // MARK: - translate in a plane (two axes)

    func testTranslateInPlaneIgnoresTheNormalComponent() {
        let d = G.Drag(handle: .plane(SIMD3(0, 0, 1)), startCenter: .zero, startAxis: SIMD3(1, 0, 0),
                       grab: ray(SIMD3(0, 0, 10), SIMD3(0, 0, -1)))
        // Current ray hits the z=0 plane at (2,3,0) regardless of its z origin.
        let r = d.resolve(currentRay: ray(SIMD3(2, 3, 42), SIMD3(0, 0, -1)))
        XCTAssertEqual(r.center.x, 2, accuracy: 1e-9)
        XCTAssertEqual(r.center.y, 3, accuracy: 1e-9)
        XCTAssertEqual(r.center.z, 0, accuracy: 1e-9, "stays in the drag plane")
    }

    // MARK: - free translate (camera-facing plane)

    func testFreeTranslateUsesTheViewFacingPlane() {
        // viewDir +X ⇒ the drag plane is x = startCenter.x; a ray along -X lands on it.
        let d = G.Drag(handle: .free, startCenter: .zero, startAxis: SIMD3(0, 0, 1),
                       grab: ray(SIMD3(10, 0, 0), SIMD3(-1, 0, 0)), viewDir: SIMD3(1, 0, 0))
        let r = d.resolve(currentRay: ray(SIMD3(10, 4, -6), SIMD3(-1, 0, 0)))
        XCTAssertEqual(r.center.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.center.y, 4, accuracy: 1e-9)
        XCTAssertEqual(r.center.z, -6, accuracy: 1e-9)
    }

    // MARK: - rotate about an axis

    func testRotateVectorAboutAxis() {
        let r = G.rotate(SIMD3(0, 0, 1), about: SIMD3(1, 0, 0), radians: .pi / 2)
        XCTAssertEqual(r.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.y, -1, accuracy: 1e-9, "+90° about X: z → −y")
        XCTAssertEqual(r.z, 0, accuracy: 1e-9)
    }

    func testRingAngleIsSignedRightHanded() {
        let a = G.ringAngle(from: SIMD3(1, 0, 0), to: SIMD3(0, 1, 0),
                            about: SIMD3(0, 0, 1), pivot: .zero)
        XCTAssertEqual(try XCTUnwrap(a), .pi / 2, accuracy: 1e-9, "+X→+Y about +Z is +90°")
        let b = G.ringAngle(from: SIMD3(1, 0, 0), to: SIMD3(0, -1, 0),
                            about: SIMD3(0, 0, 1), pivot: .zero)
        XCTAssertEqual(try XCTUnwrap(b), -.pi / 2, accuracy: 1e-9, "+X→−Y about +Z is −90°")
    }

    func testRotateHandleTurnsAxisAboutTheRing() {
        // Ring about Z; grab arm points +X, drag arm points +Y ⇒ +90° ⇒ axis +X → +Y.
        let d = G.Drag(handle: .rotate(SIMD3(0, 0, 1)), startCenter: .zero, startAxis: SIMD3(1, 0, 0),
                       grab: ray(SIMD3(1, 0, 10), SIMD3(0, 0, -1)))
        let r = d.resolve(currentRay: ray(SIMD3(0, 1, 10), SIMD3(0, 0, -1)))
        XCTAssertEqual(r.center, .zero, "rotation is in place — centre fixed")
        XCTAssertEqual(simd_normalize(r.axis).x, 0, accuracy: 1e-9)
        XCTAssertEqual(simd_normalize(r.axis).y, 1, accuracy: 1e-9, "axis turned +90° to +Y")
    }

    // MARK: - degenerate geometry is a safe no-op

    func testParallelRayLeavesThePrimitivePut() {
        // A ray PARALLEL to the drag plane never hits it → the primitive holds still.
        let d = G.Drag(handle: .plane(SIMD3(0, 0, 1)), startCenter: SIMD3(1, 1, 1), startAxis: SIMD3(1, 0, 0),
                       grab: ray(SIMD3(0, 0, 5), SIMD3(1, 0, 0)))   // dir ⟂ normal ⇒ parallel
        let r = d.resolve(currentRay: ray(SIMD3(9, 9, 5), SIMD3(1, 0, 0)))
        XCTAssertEqual(r.center, SIMD3(1, 1, 1), "a parallel/degenerate drag keeps the finger in control")
    }
}

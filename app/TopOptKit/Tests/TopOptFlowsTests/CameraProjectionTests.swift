// Headless macOS tests for the M7.6 camera→screen projection seam
// (CameraProjection). The floating force overlays (chip / snap row / weight pill /
// arrows) position themselves at 3D points via this; the GPU/gesture plumbing that
// publishes it is device QA, but the projection math is pure and pinned here — a
// known world point + known camera lands at the expected view-space coordinate.

import XCTest
import CoreGraphics
import simd
@testable import TopOptFlows

final class CameraProjectionTests: XCTestCase {

    /// A camera framed on the unit cube centred at the origin.
    private func framedCamera() -> OrbitCamera {
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3<Float>(-1, -1, -1),
                             max: SIMD3<Float>(1, 1, 1), isEmpty: false))
        return cam
    }

    func testTargetProjectsToViewportCentre() {
        let cam = framedCamera()
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 800, height: 600))
        // The camera looks straight at its target, so the target lands at the centre.
        let p = try! XCTUnwrap(proj.project(cam.target))
        XCTAssertEqual(p.x, 400, accuracy: 0.5)
        XCTAssertEqual(p.y, 300, accuracy: 0.5)
    }

    func testPointBehindCameraProjectsToNil() {
        let cam = framedCamera()
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 800, height: 600))
        // A point beyond the eye, away from the target, is behind the camera.
        let behind = cam.eye + cam.direction * cam.distance
        XCTAssertNil(proj.project(behind))
    }

    func testMovingRightInCameraSpaceIncreasesScreenX() {
        let cam = framedCamera()
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 800, height: 600))
        // lookAt's right axis is cross(worldUp, direction); a world point along it
        // must land to the right of centre (screen x grows).
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), cam.direction))
        let p = try! XCTUnwrap(proj.project(cam.target + right * cam.distance * 0.1))
        XCTAssertGreaterThan(p.x, 400.5)
        XCTAssertEqual(p.y, 300, accuracy: 5)   // roughly the same height
    }

    func testMovingUpInCameraSpaceDecreasesScreenY() {
        let cam = framedCamera()
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 800, height: 600))
        // The camera up axis; moving along it must move the point UP the screen
        // (smaller y in the top-left-origin space).
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), cam.direction))
        let up = simd_cross(cam.direction, right)   // view up = z × x per lookAt basis
        let p = try! XCTUnwrap(proj.project(cam.target + up * cam.distance * 0.1))
        XCTAssertLessThan(p.y, 299.5)
    }

    func testDegenerateViewportIsUnusable() {
        let cam = framedCamera()
        let proj = CameraProjection(camera: cam, viewportSize: .zero)
        XCTAssertFalse(proj.isUsable)
        XCTAssertNil(proj.project(cam.target))
    }
}

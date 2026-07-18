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

    // MARK: - Full-orbit rotation (shared viewer camera — Stress / Flex / Load-path)

    /// A vertical drag (dy) must change ELEVATION, and elevation must move the view
    /// matrix — i.e. the orbit is not yaw-only. This pins the shared-camera behaviour all
    /// three result viewers rely on (they render through the same `OrbitCamera`).
    func testElevationOrbitChangesViewMatrix() {
        var cam = framedCamera()
        let before = cam.viewMatrix()
        let eyeBefore = cam.eye
        cam.orbit(dx: 0, dy: 60)                 // pure vertical drag → pitch only
        XCTAssertNotEqual(cam.viewMatrix(), before, "elevation drag did not move the view")
        // The eye actually climbed the sphere (pitch applied, not just yaw): its height
        // above the target changed while the distance is preserved.
        XCTAssertNotEqual(cam.eye.y, eyeBefore.y, accuracy: 0)
        XCTAssertEqual(simd_distance(cam.eye, cam.target),
                       simd_distance(eyeBefore, cam.target), accuracy: 1e-3)
    }

    /// Azimuth and elevation are independent axes — a horizontal drag yaws without
    /// touching pitch, a vertical drag pitches without touching yaw.
    func testAzimuthAndElevationAreIndependent() {
        var cam = framedCamera()
        let az0 = cam.azimuth, el0 = cam.elevation
        cam.orbit(dx: 40, dy: 0)                 // horizontal only
        XCTAssertNotEqual(cam.azimuth, az0)
        XCTAssertEqual(cam.elevation, el0, accuracy: 1e-6)
        let az1 = cam.azimuth
        cam.orbit(dx: 0, dy: 40)                 // vertical only
        XCTAssertEqual(cam.azimuth, az1, accuracy: 1e-6)
        XCTAssertNotEqual(cam.elevation, el0)
    }

    /// Elevation is clamped just shy of the poles (no gimbal flip): driving the pitch
    /// hard past vertical in either direction lands exactly on ±maxElevation and the up
    /// vector never degenerates.
    func testElevationClampsAtPoles() {
        var cam = framedCamera()
        cam.orbit(dx: 0, dy: 100_000)            // slam toward the top pole
        XCTAssertEqual(cam.elevation, OrbitCamera.maxElevation, accuracy: 1e-5)
        XCTAssertLessThan(cam.elevation, .pi / 2)    // strictly under 90° → no flip
        cam.orbit(dx: 0, dy: -200_000)           // slam toward the bottom pole
        XCTAssertEqual(cam.elevation, -OrbitCamera.maxElevation, accuracy: 1e-5)
        XCTAssertGreaterThan(cam.elevation, -(.pi / 2))
    }

    // MARK: - Screen → world ray (keep-clear Phase B drag inverse of `project`)

    /// The distance from a point to the line `origin + t·dir` (dir unit).
    private func distance(_ p: SIMD3<Float>, toRayOrigin o: SIMD3<Float>, dir: SIMD3<Float>) -> Float {
        let w = p - o
        let along = simd_dot(w, dir)
        return simd_length(w - dir * along)
    }

    func testRayThroughProjectedPointHitsThatPoint() {
        let cam = framedCamera()
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 800, height: 600))
        // Take a world point in front of the camera, project it, then unproject a ray
        // through that pixel — the ray must pass (essentially) through the world point.
        let world = cam.target + simd_normalize(SIMD3<Float>(0.4, 0.3, -0.2)) * 0.5
        let screen = try! XCTUnwrap(proj.project(world))
        let ray = try! XCTUnwrap(proj.ray(throughViewPoint: screen))
        XCTAssertEqual(simd_length(ray.dir), 1, accuracy: 1e-4)         // unit direction
        XCTAssertLessThan(distance(world, toRayOrigin: ray.origin, dir: ray.dir), 1e-2)
    }

    func testRayThroughViewportCentreLooksAtTarget() {
        let cam = framedCamera()
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 800, height: 600))
        // The centre pixel's ray is the camera's view direction, so the target lies on it.
        let ray = try! XCTUnwrap(proj.ray(throughViewPoint: CGPoint(x: 400, y: 300)))
        XCTAssertLessThan(distance(cam.target, toRayOrigin: ray.origin, dir: ray.dir), 1e-2)
        // It points from the eye toward the scene (roughly opposite the eye direction).
        XCTAssertLessThan(simd_dot(ray.dir, cam.direction), 0)
    }

    func testRayNilOnDegenerateViewport() {
        let proj = CameraProjection(camera: framedCamera(), viewportSize: .zero)
        XCTAssertNil(proj.ray(throughViewPoint: CGPoint(x: 1, y: 1)))
    }
}

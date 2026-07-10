// Headless macOS tests for the M7.6-ring constrained single-DOF rotation ring
// (MOD-F1 D4 v2: "a single-DOF rotation ring at the arrow base for custom
// directions, 15° detents, haptic ticks, second ring appears only after the
// first commits. Never a freehand drag.").
//
// The gizmo (drawn ring, drag gesture, CoreHaptics ticks) is a SwiftUI/GPU
// surface and is maintainer device QA; its *math and sequencing* — the one
// degree of freedom, the 15° detent snap, the detent-crossing tick edges, the
// direction produced by rotating a base vector about the fixed ring axis, and
// the "second ring only after the first commits" two-stage aiming — live in
// RotationRing / RingAiming and are pinned here.

import XCTest
import simd
@testable import TopOptFlows

final class RotationRingTests: XCTestCase {

    private let down = SIMD3<Float>(0, -1, 0)
    private let zAxis = SIMD3<Float>(0, 0, 1)

    // MARK: detent geometry (15°, 24 detents)

    func testDetentConstants() {
        XCTAssertEqual(RotationRing.detentDegrees, 15)
        XCTAssertEqual(RotationRing.detentCount, 24)                       // 360 / 15
        XCTAssertEqual(RotationRing.detentRadians, .pi / 12, accuracy: 1e-6)
    }

    func testNearestDetentAngleSnapsToFifteenDegrees() {
        let d = Float.pi / 180
        // 20° rounds down to 15°, 23° rounds up to 30° (nearest 15° detent).
        XCTAssertEqual(RotationRing.nearestDetentAngle(to: 20 * d), 15 * d, accuracy: 1e-5)
        XCTAssertEqual(RotationRing.nearestDetentAngle(to: 23 * d), 30 * d, accuracy: 1e-5)
        XCTAssertEqual(RotationRing.nearestDetentAngle(to: 7 * d), 0, accuracy: 1e-5)
        // Negative angles snap symmetrically.
        XCTAssertEqual(RotationRing.nearestDetentAngle(to: -8 * d), -15 * d, accuracy: 1e-5)
    }

    func testDetentIndexAndCrossingDetection() {
        let d = Float.pi / 180
        XCTAssertEqual(RotationRing.detentIndex(forRadians: 0), 0)
        XCTAssertEqual(RotationRing.detentIndex(forRadians: 15 * d), 1)
        XCTAssertEqual(RotationRing.detentIndex(forRadians: -15 * d), -1)
        // 7° and 8° straddle the 7.5° midpoint between detent 0 and detent 1, so a
        // drag through them fires one haptic tick.
        XCTAssertTrue(RotationRing.didCrossDetent(fromRadians: 7 * d, toRadians: 8 * d))
        // 2°→5° stays inside detent 0, no tick.
        XCTAssertFalse(RotationRing.didCrossDetent(fromRadians: 2 * d, toRadians: 5 * d))
    }

    // MARK: single-DOF rotation about the fixed axis

    func testBasePreservedAtZeroAngle() {
        let ring = RotationRing(base: down, axis: zAxis)
        XCTAssertEqual(ring.angle, 0)
        assertClose(ring.liveDirection, down)
        assertClose(ring.snappedDirection, down)
    }

    func testRotatesBaseAboutAxis() {
        // (0,-1,0) rotated +90° about +Z → (1,0,0) (right-handed).
        var ring = RotationRing(base: down, axis: zAxis)
        ring.rotate(toRadians: .pi / 2)
        assertClose(ring.liveDirection, SIMD3<Float>(1, 0, 0))
        // The produced direction is always a unit vector.
        XCTAssertEqual(simd_length(ring.liveDirection), 1, accuracy: 1e-5)
    }

    func testLiveVsSnappedDirectionDiffer() {
        // An off-detent angle: live tracks the drag, snapped lands on the detent.
        var ring = RotationRing(base: down, axis: zAxis)
        ring.rotate(toRadians: 20 * .pi / 180)
        XCTAssertNotEqual(ring.angle, ring.snappedAngle)
        assertClose(ring.snappedDirection, ring.direction(atRadians: 15 * .pi / 180))
    }

    // MARK: axis is orthonormalized to the base (a proper single DOF)

    func testAxisProjectedOntoPlanePerpendicularToBase() {
        // A supplied axis with a component along the base must be projected onto the
        // plane ⟂ base so the rotation stays a genuine single degree of freedom.
        let ring = RotationRing(base: down, axis: SIMD3<Float>(0, 1, 1))
        assertClose(ring.axis, zAxis)                                     // (0,1,1) → (0,0,1)
        XCTAssertEqual(simd_dot(ring.axis, ring.base), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(ring.axis), 1, accuracy: 1e-5)
    }

    func testDegenerateAxisFallsBackToAPerpendicular() {
        // An axis parallel to the base is unusable; the ring picks some unit axis ⟂
        // base rather than producing NaNs.
        let ring = RotationRing(base: down, axis: down)
        XCTAssertTrue(ring.axis.x.isFinite && ring.axis.y.isFinite && ring.axis.z.isFinite)
        XCTAssertEqual(simd_length(ring.axis), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(ring.axis, ring.base), 0, accuracy: 1e-5)
    }

    // MARK: drag → single angle (constrained, never a freehand vector)

    func testAngleForDragIsTheAngleAboutTheRingCentre() {
        let c = CGPoint(x: 100, y: 100)
        // A point directly to the right of centre is angle 0.
        XCTAssertEqual(RotationRing.angleForDrag(center: c, location: CGPoint(x: 150, y: 100)),
                       0, accuracy: 1e-5)
        // Directly below (screen +y) is +90°.
        XCTAssertEqual(RotationRing.angleForDrag(center: c, location: CGPoint(x: 100, y: 150)),
                       .pi / 2, accuracy: 1e-5)
    }

    // MARK: two-ring aiming (second ring only after the first commits)

    func testSecondRingIsNilUntilFirstCommits() {
        var aim = RingAiming(base: down, primaryAxis: zAxis)
        XCTAssertFalse(aim.isOnSecondRing)
        XCTAssertNil(aim.second)
        aim.rotateActive(toRadians: .pi / 2)      // rotating the first ring does not reveal the second
        XCTAssertFalse(aim.isOnSecondRing)
    }

    func testCommitFirstRevealsAnOrthogonalSecondRingBasedOnTheSnappedDirection() {
        var aim = RingAiming(base: down, primaryAxis: zAxis)
        aim.rotateActive(toRadians: .pi / 2)      // first ring → +X (a detent)
        aim.commitFirst()
        XCTAssertTrue(aim.isOnSecondRing)
        let second = try! XCTUnwrap(aim.second)
        assertClose(second.base, SIMD3<Float>(1, 0, 0))                   // committed dir of ring 1
        XCTAssertEqual(simd_dot(second.axis, second.base), 0, accuracy: 1e-5)  // ⟂ its base
        XCTAssertEqual(simd_dot(second.axis, aim.first.axis), 0, accuracy: 1e-5) // ⟂ ring-1 axis → new DOF
    }

    func testTwoRingsComposeToAnOutOfPlaneDirection() {
        // Ring 1: (0,-1,0) about +Z by 90° → (1,0,0). Ring 2 axis = cross(+Z,+X)=+Y;
        // rotating (1,0,0) about +Y by 90° → (0,0,-1). Two single-DOF rotations reach
        // a direction outside ring 1's plane.
        var aim = RingAiming(base: down, primaryAxis: zAxis)
        aim.rotateActive(toRadians: .pi / 2)
        aim.commitFirst()
        aim.rotateActive(toRadians: .pi / 2)
        assertClose(aim.committedDirection, SIMD3<Float>(0, 0, -1))
    }

    func testCommitFirstIsNoOpOnceOnSecondRing() {
        // Only two rings exist; committing again must not throw away the second ring.
        var aim = RingAiming(base: down, primaryAxis: zAxis)
        aim.rotateActive(toRadians: .pi / 2)
        aim.commitFirst()
        let secondBefore = aim.second
        aim.rotateActive(toRadians: .pi / 4)
        aim.commitFirst()                          // no-op
        XCTAssertEqual(aim.second?.base, secondBefore?.base)
    }

    // MARK: helper

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                             _ tol: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: tol, file: file, line: line)
    }
}

// Headless macOS tests for the keep-clear v2 pure geometry: the Auto-label
// suggestion derivation (mirrors clearance.hpp), the true swept-cylinder /
// bounded-slab ClearanceVolume built from the exact B-rep geometry, and the
// drag-handle math (screen-ray → mm parameter). These are the value types the
// SwiftUI/GPU volume render and the gesture layer consume; pinning them here is
// what makes "the picture uses the SAME numbers the run freezes" a tested claim,
// not a hope. The Metal draw + gesture wiring are device QA.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class ClearanceGeometryTests: XCTestCase {

    // MARK: - Auto-label suggestions match the core defaults (clearance.hpp)

    func testSuggestionsMirrorCoreDefaults() {
        // default_bolt_clearance(bore_r): margin = bore_r, axial = 2*bore_r.
        XCTAssertEqual(ClearanceSuggestion.boltMarginMM(boreRadiusMM: 2.5), 2.5, accuracy: 1e-9)
        XCTAssertEqual(ClearanceSuggestion.boltAxialMM(boreRadiusMM: 2.5), 5.0, accuracy: 1e-9)
        // kClearanceFaceSlabDepthDefaultMm = 3.0.
        XCTAssertEqual(ClearanceSuggestion.faceSlabDepthMM, 3.0, accuracy: 1e-9)
    }

    // MARK: - ClearanceVolume.bolt

    private func cylinderFace(radius: Double, axisPoint: SIMD3<Double>,
                              axisDir: SIMD3<Double>) -> StepFaceGeometry {
        StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: radius,
                         axisPoint: axisPoint, axisDir: axisDir)
    }

    func testBoltVolumeUsesExactRadiusAndTessellationSpan() {
        // Bore r=2.5 along +Z, tessellation span t∈[0,10]. Auto margin=2.5, axial=5.
        let geo = cylinderFace(radius: 2.5, axisPoint: .zero, axisDir: SIMD3(0, 0, 1))
        let vol = ClearanceVolume.bolt(faceID: 3, geometry: geo, axialSpan: (lo: 0, hi: 10),
                                       marginMM: 2.5, axialMM: 5.0)
        guard case let .cylinder(axisPoint, axisDir, radius, tLo, tHi) = vol.shape else {
            return XCTFail("expected a cylinder, got \(vol.shape)")
        }
        XCTAssertEqual(radius, 5.0, accuracy: 1e-5)     // bore 2.5 + margin 2.5
        XCTAssertEqual(tLo, -5.0, accuracy: 1e-5)       // span lo 0 − axial 5
        XCTAssertEqual(tHi, 15.0, accuracy: 1e-5)       // span hi 10 + axial 5
        XCTAssertEqual(axisPoint, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(axisDir, SIMD3<Float>(0, 0, 1))
        XCTAssertFalse(vol.isDegenerate)
        XCTAssertEqual(vol.kind, .bolt)
    }

    func testBoltVolumeDegenerateOnNonCylinder() {
        // A Bolt on a plane face marks nothing (the core rasterizer also no-ops) →
        // hollow/dashed "no effect" render (degenerate honesty).
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1))
        let vol = ClearanceVolume.bolt(faceID: 1, geometry: plane, axialSpan: (0, 5),
                                       marginMM: 1, axialMM: 1)
        XCTAssertTrue(vol.isDegenerate)
    }

    func testBoltVolumeDegenerateWhenSpanMissing() {
        let geo = cylinderFace(radius: 2.5, axisPoint: .zero, axisDir: SIMD3(0, 0, 1))
        let vol = ClearanceVolume.bolt(faceID: 1, geometry: geo, axialSpan: nil,
                                       marginMM: 1, axialMM: 1)
        XCTAssertTrue(vol.isDegenerate)
    }

    // MARK: - ClearanceVolume.slab

    func testSlabVolumeExtrudesOutlineAlongNormal() {
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1),
                                     planeOrigin: SIMD3(0, 0, 4))
        let outline = PlaneOutline(center: SIMD3(0, 0, 4), uAxis: SIMD3(1, 0, 0),
                                   vAxis: SIMD3(0, 1, 0), halfU: 3, halfV: 2)
        let vol = ClearanceVolume.slab(faceID: 7, geometry: plane, outline: outline, depthMM: 3.0)
        guard case let .slab(center, normal, _, _, halfU, halfV, depth) = vol.shape else {
            return XCTFail("expected a slab, got \(vol.shape)")
        }
        XCTAssertEqual(center, SIMD3<Float>(0, 0, 4))
        XCTAssertEqual(normal, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(halfU, 3, accuracy: 1e-5)
        XCTAssertEqual(halfV, 2, accuracy: 1e-5)
        XCTAssertEqual(depth, 3.0, accuracy: 1e-5)
        XCTAssertEqual(vol.kind, .face)
    }

    func testSlabVolumeDegenerateOnNonPlane() {
        let geo = cylinderFace(radius: 2.5, axisPoint: .zero, axisDir: SIMD3(0, 0, 1))
        let vol = ClearanceVolume.slab(faceID: 1, geometry: geo, outline: nil, depthMM: 3)
        XCTAssertTrue(vol.isDegenerate)
    }

    // MARK: - PlaneOutline.fit

    func testPlaneOutlineFitsBoundingRectangle() {
        // Four corners of a 6×4 rectangle on the z=4 plane, centred at (1, 1, 4).
        let pts: [SIMD3<Float>] = [
            SIMD3(-2, -1, 4), SIMD3(4, -1, 4), SIMD3(4, 3, 4), SIMD3(-2, 3, 4)]
        let o = PlaneOutline.fit(points: pts, normal: SIMD3(0, 0, 1), origin: SIMD3(0, 0, 4))
        guard let outline = o else { return XCTFail("expected an outline") }
        XCTAssertEqual(outline.halfU, 3, accuracy: 1e-4)     // (4 − −2)/2
        XCTAssertEqual(outline.halfV, 2, accuracy: 1e-4)     // (3 − −1)/2
        XCTAssertEqual(outline.center.x, 1, accuracy: 1e-4)
        XCTAssertEqual(outline.center.y, 1, accuracy: 1e-4)
        XCTAssertEqual(outline.center.z, 4, accuracy: 1e-4)
    }

    // MARK: - Drag-handle math

    func testRadialMarginFromWallDrag() {
        // Bore r=2.5 along +Z at origin. A ray parallel to +X at height z=5, offset so
        // its closest approach to the axis is exactly 6 mm → margin = 6 − 2.5 = 3.5.
        let m = ClearanceDragMath.radialMargin(
            rayOrigin: SIMD3(-10, 6, 5), rayDir: SIMD3(1, 0, 0),
            axisPoint: .zero, axisDir: SIMD3(0, 0, 1), boreRadiusMM: 2.5)
        XCTAssertNotNil(m)
        XCTAssertEqual(m!, 3.5, accuracy: 1e-4)
    }

    func testRadialMarginClampsAtZeroInsideBore() {
        // A ray grazing 1 mm from the axis, inside a 2.5 bore → margin clamps to 0.
        let m = ClearanceDragMath.radialMargin(
            rayOrigin: SIMD3(-10, 1, 5), rayDir: SIMD3(1, 0, 0),
            axisPoint: .zero, axisDir: SIMD3(0, 0, 1), boreRadiusMM: 2.5)
        XCTAssertEqual(m!, 0, accuracy: 1e-4)
    }

    func testAxialClearanceFromCapDrag() {
        // Bore end (+cap) at t=10 along +Z. Drag lands at z=14 (the ray crosses the
        // axis there) → axial = 14 − 10 = 4 on the +axis side.
        let a = ClearanceDragMath.axialClearance(
            rayOrigin: SIMD3(-10, 0, 14), rayDir: SIMD3(1, 0, 0),
            axisPoint: .zero, axisDir: SIMD3(0, 0, 1), boreEndT: 10, outward: 1)
        XCTAssertNotNil(a)
        XCTAssertEqual(a!, 4, accuracy: 1e-4)
    }

    func testAxialClearanceLowCapSignAndClamp() {
        // −cap at t=0; a drag landing at z=+3 is INWARD for the low cap → clamps to 0.
        let a = ClearanceDragMath.axialClearance(
            rayOrigin: SIMD3(-10, 0, 3), rayDir: SIMD3(1, 0, 0),
            axisPoint: .zero, axisDir: SIMD3(0, 0, 1), boreEndT: 0, outward: -1)
        XCTAssertEqual(a!, 0, accuracy: 1e-4)
        // A drag landing at z=−2 is OUTWARD for the low cap → axial = 2.
        let b = ClearanceDragMath.axialClearance(
            rayOrigin: SIMD3(-10, 0, -2), rayDir: SIMD3(1, 0, 0),
            axisPoint: .zero, axisDir: SIMD3(0, 0, 1), boreEndT: 0, outward: -1)
        XCTAssertEqual(b!, 2, accuracy: 1e-4)
    }

    func testSlabDepthFromNormalDrag() {
        // Plane at origin, outward normal +Z. Drag lands at z=3 → depth 3.
        let d = ClearanceDragMath.slabDepth(
            rayOrigin: SIMD3(-10, 0, 3), rayDir: SIMD3(1, 0, 0),
            planeOrigin: .zero, planeNormal: SIMD3(0, 0, 1))
        XCTAssertNotNil(d)
        XCTAssertEqual(d!, 3, accuracy: 1e-4)
    }

    func testSlabDepthClampsBehindPlane() {
        // Drag behind the face (z=−2) → clamps to 0 (a slab never extrudes inward).
        let d = ClearanceDragMath.slabDepth(
            rayOrigin: SIMD3(-10, 0, -2), rayDir: SIMD3(1, 0, 0),
            planeOrigin: .zero, planeNormal: SIMD3(0, 0, 1))
        XCTAssertEqual(d!, 0, accuracy: 1e-4)
    }

    func testDragMathNilOnZeroDirection() {
        XCTAssertNil(ClearanceDragMath.radialMargin(
            rayOrigin: .zero, rayDir: .zero, axisPoint: .zero,
            axisDir: SIMD3(0, 0, 1), boreRadiusMM: 1))
    }
}

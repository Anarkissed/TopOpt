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

    // MARK: - Handle anchors (Phase B)

    /// A resolved bore volume (r=2.5, span 0–10, auto margin 2.5, auto axial 5).
    private func boreVolume() -> ClearanceVolume {
        let geo = cylinderFace(radius: 2.5, axisPoint: .zero, axisDir: SIMD3(0, 0, 1))
        return .bolt(faceID: 1, geometry: geo, axialSpan: (0, 10), marginMM: 2.5, axialMM: 5)
    }

    func testCylinderHandlesAnchorsAndGeometry() {
        let handles = ClearanceHandles.handles(for: boreVolume(), boreRadiusMM: 2.5,
                                               axialSpan: (0, 10))
        XCTAssertEqual(handles.count, 3)   // wall + two caps

        let margin = try! XCTUnwrap(handles.first { $0.role == .margin })
        // Wall handle at mid-length (z=5), out along +X by the drawn radius (5).
        XCTAssertEqual(margin.anchor, SIMD3<Float>(5, 0, 5))
        XCTAssertEqual(margin.boreRadiusMM, 2.5, accuracy: 1e-5)
        XCTAssertEqual(margin.axisDir, SIMD3<Float>(0, 0, 1))

        let hi = try! XCTUnwrap(handles.first { $0.role == .axialHi })
        XCTAssertEqual(hi.anchor, SIMD3<Float>(0, 0, 15))   // outer +cap (tHi)
        XCTAssertEqual(hi.boreEndT, 10, accuracy: 1e-5)     // FIXED bore end (span.hi)
        XCTAssertEqual(hi.outward, 1, accuracy: 1e-5)

        let lo = try! XCTUnwrap(handles.first { $0.role == .axialLo })
        XCTAssertEqual(lo.anchor, SIMD3<Float>(0, 0, -5))   // outer −cap (tLo)
        XCTAssertEqual(lo.boreEndT, 0, accuracy: 1e-5)      // span.lo
        XCTAssertEqual(lo.outward, -1, accuracy: 1e-5)
    }

    func testSlabHandleAnchorAndGeometry() {
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1),
                                     planeOrigin: SIMD3(0, 0, 4))
        let outline = PlaneOutline(center: SIMD3(0, 0, 4), uAxis: SIMD3(1, 0, 0),
                                   vAxis: SIMD3(0, 1, 0), halfU: 3, halfV: 2)
        let vol = ClearanceVolume.slab(faceID: 7, geometry: plane, outline: outline, depthMM: 3)
        let handles = ClearanceHandles.handles(for: vol, boreRadiusMM: 0, axialSpan: nil)
        XCTAssertEqual(handles.count, 1)
        let d = handles[0]
        XCTAssertEqual(d.role, .slabDepth)
        XCTAssertEqual(d.anchor, SIMD3<Float>(0, 0, 7))     // outer face = plane + depth·n
        XCTAssertEqual(d.planeOrigin, SIMD3<Float>(0, 0, 4))
        XCTAssertEqual(d.planeNormal, SIMD3<Float>(0, 0, 1))
    }

    func testDegenerateVolumeHasNoHandles() {
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1))
        let degen = ClearanceVolume.bolt(faceID: 1, geometry: plane, axialSpan: (0, 5),
                                         marginMM: 1, axialMM: 1)   // bolt on a plane → degenerate
        XCTAssertTrue(degen.isDegenerate)
        XCTAssertTrue(ClearanceHandles.handles(for: degen, boreRadiusMM: 0, axialSpan: nil).isEmpty)
    }

    // MARK: - Value-write path (drag simulated as a ray sequence)

    func testMarginValueWritePathFromRaySequence() {
        let margin = try! XCTUnwrap(
            ClearanceHandles.handles(for: boreVolume(), boreRadiusMM: 2.5, axialSpan: (0, 10))
                .first { $0.role == .margin })
        // A sequence of drag rays, each grazing a known distance from the +Z axis; the
        // written margin = grazing distance − bore radius (2.5), clamped ≥ 0.
        let grazes: [(Float, Float)] = [(6, 3.5), (4, 1.5), (2, 0)]   // (graze, expected margin)
        for (graze, expected) in grazes {
            let v = margin.value(rayOrigin: SIMD3(-10, graze, 5), rayDir: SIMD3(1, 0, 0))
            XCTAssertEqual(try! XCTUnwrap(v), expected, accuracy: 1e-4)
        }
    }

    func testAxialAndSlabValueWritePath() {
        let handles = ClearanceHandles.handles(for: boreVolume(), boreRadiusMM: 2.5, axialSpan: (0, 10))
        let hi = try! XCTUnwrap(handles.first { $0.role == .axialHi })
        // Drag the +cap out to z=14 → axial = 14 − boreEnd(10) = 4.
        XCTAssertEqual(try! XCTUnwrap(hi.value(rayOrigin: SIMD3(-10, 0, 14), rayDir: SIMD3(1, 0, 0))),
                       4, accuracy: 1e-4)
        // Slab depth handle: drag to z=3 from a plane at origin → depth 3.
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1), planeOrigin: .zero)
        let outline = PlaneOutline(center: .zero, uAxis: SIMD3(1, 0, 0), vAxis: SIMD3(0, 1, 0),
                                   halfU: 1, halfV: 1)
        let slab = ClearanceVolume.slab(faceID: 2, geometry: plane, outline: outline, depthMM: 1)
        let d = try! XCTUnwrap(ClearanceHandles.handles(for: slab, boreRadiusMM: 0, axialSpan: nil).first)
        XCTAssertEqual(try! XCTUnwrap(d.value(rayOrigin: SIMD3(-10, 0, 3), rayDir: SIMD3(1, 0, 0))),
                       3, accuracy: 1e-4)
    }

    /// A handle re-posed into settled-world space, and the drag ray rigidly re-posed the
    /// same way, must write the SAME mm — the invariance that lets the view compute in
    /// world space against a world-space camera ray.
    func testSettledHandlePreservesValueUnderRigidTransform() {
        let margin = try! XCTUnwrap(
            ClearanceHandles.handles(for: boreVolume(), boreRadiusMM: 2.5, axialSpan: (0, 10))
                .first { $0.role == .margin })
        let center = SIMD3<Float>(3, -2, 7)
        let q = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2)))
        func p(_ x: SIMD3<Float>) -> SIMD3<Float> { center + q.act(x - center) }
        func d(_ x: SIMD3<Float>) -> SIMD3<Float> { q.act(x) }

        let o = SIMD3<Float>(-10, 6, 5), dir = SIMD3<Float>(1, 0, 0)
        let vModel = try! XCTUnwrap(margin.value(rayOrigin: o, rayDir: dir))
        let world = margin.settled(center: center, rotation: q)
        let vWorld = try! XCTUnwrap(world.value(rayOrigin: p(o), rayDir: d(dir)))
        XCTAssertEqual(vWorld, vModel, accuracy: 1e-3)
        XCTAssertEqual(vModel, 3.5, accuracy: 1e-3)
    }

    // MARK: - Precision scrub (slower finger → finer steps)

    func testScrubStepIsFinerWhenSlow() {
        // Per-point step at a slow drag (|dx| = 0.5) is smaller than at a fast flick.
        let slowPerPoint = ClearanceScrub.increment(deltaPoints: 0.5) / 0.5
        let fastPerPoint = ClearanceScrub.increment(deltaPoints: 16) / 16
        XCTAssertLessThan(slowPerPoint, fastPerPoint)
        XCTAssertEqual(fastPerPoint, ClearanceScrub.coarseStepMMPerPoint, accuracy: 1e-4)
        XCTAssertGreaterThanOrEqual(slowPerPoint, ClearanceScrub.fineStepMMPerPoint)
    }

    func testScrubDirectionAndClampAtZero() {
        // Positive delta grows the value; a big negative delta clamps at 0.
        XCTAssertGreaterThan(ClearanceScrub.scrub(value: 1, deltaPoints: 4), 1)
        XCTAssertEqual(ClearanceScrub.scrub(value: 0.1, deltaPoints: -50), 0, accuracy: 1e-6)
    }
}

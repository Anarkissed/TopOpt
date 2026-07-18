// Headless tests for the orientation gizmo + shared orbit camera (the
// 3d-gizmo-orbit-camera task). Everything here is pure value/state math (the M7 /app/
// standard); the SwiftUI drawing + gestures are maintainer device QA.
//
// Coverage mirrors the task's test checklist:
//   * shared camera — azimuth AND elevation both move the view, elevation is clamped;
//   * a finite free-drag can reach a clean, exactly-level front view (the STEP 0
//     complaint, proven reachable — the "single-axis / unclamped" hypothesis denied);
//   * snap — Front / Top / a corner land on the expected canonical orientation;
//   * home — after arbitrary rotation, Home restores the exact default;
//   * the gizmo's transform is the camera's, so the two can never diverge;
//   * region hit-testing resolves a tap to the correct face / edge / corner.

import XCTest
import simd
@testable import TopOptFlows

final class OrientationGizmoTests: XCTestCase {

    private let unitCube = MeshBounds(min: SIMD3<Float>(-1, -1, -1),
                                      max: SIMD3<Float>(1, 1, 1), isEmpty: false)
    private let tol: Float = 1e-4

    // MARK: - Shared camera: both axes move the view; elevation is clamped

    func testAzimuthAndElevationBothChangeTheView() {
        var cam = OrbitCamera(azimuth: 0, elevation: 0)
        cam.frame(unitCube)

        let eye0 = cam.eye
        cam.orbit(dx: 60, dy: 0)                 // horizontal drag → azimuth
        let eyeAz = cam.eye
        XCTAssertGreaterThan(simd_distance(eye0, eyeAz), 1e-3, "azimuth must move the eye")

        var cam2 = OrbitCamera(azimuth: 0, elevation: 0)
        cam2.frame(unitCube)
        let e0 = cam2.eye
        cam2.orbit(dx: 0, dy: 60)                // vertical drag → elevation
        XCTAssertGreaterThan(simd_distance(e0, cam2.eye), 1e-3, "elevation must move the eye")
        XCTAssertGreaterThan(cam2.elevation, 0, "downward drag raises elevation")
    }

    func testElevationCannotFlipPastVertical() {
        var cam = OrbitCamera(elevation: 0)
        cam.orbit(dx: 0, dy: 1_000_000)          // slam toward the pole
        XCTAssertEqual(cam.elevation, OrbitCamera.maxElevation, accuracy: tol)
        XCTAssertLessThan(cam.elevation, .pi / 2, "stays just under vertical — never flips")
        cam.orbit(dx: 0, dy: -2_000_000)
        XCTAssertEqual(cam.elevation, -OrbitCamera.maxElevation, accuracy: tol)
        XCTAssertGreaterThan(cam.elevation, -.pi / 2)
    }

    /// STEP 0 instrumentation: a finite drag from the default 3/4 view reaches an
    /// EXACTLY level, straight-on front view. Proves the orbit is neither single-axis
    /// nor unclamped-unusable — the maintainer's "can't reach a front view" is a
    /// no-snap/precision problem, not a broken orbit.
    func testAFreeDragCanReachACleanFrontView() {
        var cam = OrbitCamera()                   // default azimuth π/4, elevation π/6
        cam.frame(unitCube)
        let sens = OrbitCamera.orbitSensitivity
        // Drag exactly enough to null both angles.
        cam.orbit(dx: (.pi / 4) / sens, dy: -(.pi / 6) / sens)
        XCTAssertEqual(cam.azimuth, 0, accuracy: 1e-3)
        XCTAssertEqual(cam.elevation, 0, accuracy: 1e-3)
        // The eye is now straight in front, on +Z.
        XCTAssertEqual(cam.direction.z, 1, accuracy: 1e-3)
        XCTAssertEqual(cam.direction.x, 0, accuracy: 1e-3)
        XCTAssertEqual(cam.direction.y, 0, accuracy: 1e-3)
    }

    @MainActor
    func testModelOrbitRoutesAndClamps() {
        let m = OrbitCameraModel()
        m.reframe(unitCube)
        m.orbit(dx: 0, dy: 1_000_000)
        XCTAssertEqual(m.camera.elevation, OrbitCamera.maxElevation, accuracy: tol)
    }

    // MARK: - Snap to canonical views

    @MainActor
    func testSnapFront() {
        let m = OrbitCameraModel(); m.reframe(unitCube)
        m.orbit(dx: 33, dy: 21)                   // somewhere arbitrary first
        m.snap(toID: "Front", animated: false)
        XCTAssertEqual(m.camera.azimuth, 0, accuracy: tol)
        XCTAssertEqual(m.camera.elevation, 0, accuracy: tol)
        assertDirection(m.camera.direction, SIMD3<Float>(0, 0, 1))
    }

    @MainActor
    func testSnapTopLooksStraightDown() {
        let m = OrbitCameraModel(); m.reframe(unitCube)
        m.snap(toID: "Top", animated: false)
        // Top is a pole: elevation pinned just under +90°, eye almost straight above.
        XCTAssertEqual(m.camera.elevation, OrbitCamera.maxElevation, accuracy: tol)
        XCTAssertGreaterThan(m.camera.direction.y, 0.99, "eye is essentially overhead")
    }

    @MainActor
    func testSnapCorner() {
        let m = OrbitCameraModel(); m.reframe(unitCube)
        m.snap(toID: "Top-Front-Right", animated: false)
        // Looking from the (+1,+1,+1) corner.
        assertDirection(m.camera.direction, simd_normalize(SIMD3<Float>(1, 1, 1)))
    }

    // MARK: - Home

    @MainActor
    func testHomeRestoresExactDefault() {
        let m = OrbitCameraModel(); m.reframe(unitCube)
        let da = m.defaultAzimuth, de = m.defaultElevation
        m.snap(toID: "Back", animated: false)
        m.orbit(dx: 41, dy: -17)
        m.zoom(0.7)
        m.home(animated: false)
        XCTAssertEqual(m.camera.azimuth, da, accuracy: tol)
        XCTAssertEqual(m.camera.elevation, de, accuracy: tol)
    }

    // MARK: - Gizmo tracks the camera (never diverges)

    @MainActor
    func testGizmoRotationIsTheCameraRotation() {
        let cam = OrbitCamera(azimuth: 0.7, elevation: 0.3)
        let m = OrbitCameraModel(camera: cam)
        XCTAssertEqual(m.viewRotation, cam.viewRotation(), "gizmo draws with the camera's own rotation")
    }

    func testFrontFaceFacesViewerAtFrontView() {
        let cam = OrbitCamera(azimuth: 0, elevation: 0)
        let r = cam.viewRotation()
        // The +Z (Front) face normal maps toward the viewer (view-space +Z).
        let n = r * SIMD3<Float>(0, 0, 1)
        XCTAssertGreaterThan(n.z, 0.99)
    }

    // MARK: - Region hit-testing (tap → correct view)

    /// Snapping to a region puts that region dead-centre of the gizmo, so a tap at the
    /// centre must resolve back to the same region — the strongest round-trip check.
    private func rotation(forID id: String) -> simd_float3x3 {
        var cam = OrbitCamera(); cam.frame(unitCube)
        let region = OrientationGizmo.region(id)!
        let o = region.orientation(currentAzimuth: cam.azimuth)
        cam.setOrientation(azimuth: o.azimuth, elevation: o.elevation)
        return cam.viewRotation()
    }

    private func hitCentre(_ id: String) -> GizmoRegion? {
        let s = CGSize(width: 74, height: 74)
        return OrientationGizmo.hitTest(point: CGPoint(x: 37, y: 37), in: s, rotation: rotation(forID: id))
    }

    func testHitTestFaceCentresResolveToThatFace() {
        for id in ["Front", "Back", "Right", "Left", "Top", "Bottom"] {
            XCTAssertEqual(hitCentre(id)?.id, id, "centre of the \(id) view should hit \(id)")
        }
    }

    func testHitTestCornerAndEdgeCentresResolve() {
        XCTAssertEqual(hitCentre("Top-Front-Right")?.id, "Top-Front-Right")
        XCTAssertEqual(hitCentre("Front-Right")?.id, "Front-Right")
        XCTAssertEqual(hitCentre("Top-Front")?.kind, .edge)
    }

    /// Synthetic rays on the FRONT view (rotation ≈ identity): a tap above centre lands on the
    /// Top-Front edge, up-and-right on the Top-Front-Right corner, dead-centre on Front. The
    /// exact (point, id) values are the ground truth from the C++ SDF oracle
    /// (Testing/gizmo_pick_oracle.cpp), which mirrors the design mock byte-for-byte.
    func testSyntheticRaysOnFrontViewResolveFaceEdgeCorner() {
        let r = rotation(forID: "Front")
        let s = CGSize(width: 200, height: 200)
        func hit(_ x: CGFloat, _ y: CGFloat) -> GizmoRegion? {
            OrientationGizmo.hitTest(point: CGPoint(x: x, y: y), in: s, rotation: r)
        }
        XCTAssertEqual(hit(100, 100)?.id, "Front", "dead-centre is the Front face")
        let edge = hit(100, 70)
        XCTAssertEqual(edge?.kind, .edge)
        XCTAssertTrue(edge?.id.contains("Top") ?? false, "the upper band is the Top-Front edge, got \(edge?.id ?? "nil")")
        let corner = hit(130, 70)
        XCTAssertEqual(corner?.id, "Top-Front-Right")
        XCTAssertEqual(corner?.kind, .corner)
    }

    func testTapOutsideGlassMisses() {
        let r = rotation(forID: "Front")
        // The glass fills the central ~38% of the frame (FOV 38 / CAMZ 9.25 — it renders with
        // a deliberate margin), so a tap far into the margin hits nothing.
        XCTAssertNil(OrientationGizmo.hitTest(point: CGPoint(x: 100, y: 10),
                                              in: CGSize(width: 200, height: 200), rotation: r),
                     "a tap in the margin above the floating glass hits nothing")
        XCTAssertNil(OrientationGizmo.hitTest(point: CGPoint(x: 2, y: 2),
                                              in: CGSize(width: 74, height: 74), rotation: r),
                     "a corner tap outside the silhouette hits nothing")
    }

    /// The picker and the Metal shader must agree on the numeric cell id (the mock's
    /// `globalId`), or the hover glow would light the wrong cell. This pins the shared scheme.
    func testNumericIdMatchesSharedGlobalIdScheme() {
        func nid(_ id: String) -> Float { OrientationGizmo.numericId(anchor: OrientationGizmo.region(id)!.anchor) }
        XCTAssertEqual(nid("Right"), 1);  XCTAssertEqual(nid("Left"), 2)
        XCTAssertEqual(nid("Top"), 3);    XCTAssertEqual(nid("Bottom"), 4)
        XCTAssertEqual(nid("Front"), 5);  XCTAssertEqual(nid("Back"), 6)
        XCTAssertEqual(nid("Top-Front"), 11, "Y+Z+ edge is globalId 11")
        XCTAssertEqual(nid("Top-Front-Right"), 19, "the +++ corner is globalId 19")
        XCTAssertEqual(OrientationGizmo.homeNumericId, 0)
    }

    /// `pick` distinguishes a region from a margin miss (the view routes `.home` and `.miss`
    /// differently, so the enum must be exact — not collapsed to nil like `hitTest`).
    func testPickReturnsRegionOrMiss() {
        let r = rotation(forID: "Front")
        let s = CGSize(width: 200, height: 200)
        XCTAssertEqual(OrientationGizmo.pick(point: CGPoint(x: 100, y: 100), in: s, rotation: r),
                       .region(OrientationGizmo.region("Front")!))
        XCTAssertEqual(OrientationGizmo.pick(point: CGPoint(x: 100, y: 10), in: s, rotation: r), .miss)
    }

    func testAllTwentySixRegionsExist() {
        XCTAssertEqual(OrientationGizmo.regions.count, 26)
        XCTAssertEqual(OrientationGizmo.regions.filter { $0.kind == .face }.count, 6)
        XCTAssertEqual(OrientationGizmo.regions.filter { $0.kind == .edge }.count, 12)
        XCTAssertEqual(OrientationGizmo.regions.filter { $0.kind == .corner }.count, 8)
    }

    /// The reskin (gizmo-liquid-glass-reskin) draws a clickable BUBBLE at every anchor's
    /// projected position, but keeps the band-based `hitTest` so the snap targets are
    /// unchanged. This proves no region was lost when the targets became bubbles: for each
    /// of the 26 regions, when the camera looks from its canonical direction its bubble
    /// projects to the gizmo centre, and a tap there must resolve back to that SAME region.
    func testEveryAnchorHasAReachableClickableTarget() {
        let s = CGSize(width: 74, height: 74)
        for region in OrientationGizmo.regions {
            let r = rotation(forID: region.id)
            let hit = OrientationGizmo.hitTest(point: CGPoint(x: 37, y: 37), in: s, rotation: r)
            XCTAssertEqual(hit?.id, region.id,
                           "region \(region.id) must stay reachable at its bubble (view centre)")
        }
    }

    // MARK: helpers

    private func assertDirection(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-3, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-3, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: 1e-3, file: file, line: line)
    }
}

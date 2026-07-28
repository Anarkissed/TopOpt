// RibbonRotationTests — the regression the 2026-07-27 ribbon-rotation fix is built around.
//
// PR 215 shipped the transform gizmo with tests that assert the shader and the pick share one
// constant source — but NOTHING asserted that grabbing a rotation RIBBON actually CHANGES the
// primitive's stored orientation. It didn't: `ManualPrimitiveDetent`'s 8° world-axis magnet
// snapped every sub-8° turn straight back to the axis the primitive already sat on, so all
// three ribbons read as dead on device.
//
// These tests drive the SAME path the gesture does — `PrimitiveGizmo.Drag(.rotate)` → resolve →
// `ProjectModel.rotateManualPrimitive` — for a small ribbon drag, and assert the STORED (and
// SERIALIZED) orientation moved, and moved the right way. `testSmallRibbonDragChangesStoredOrientation`
// FAILS on the pre-fix behaviour (the detent snaps it back to the start) and passes after.
//
// Pure model layer + serialization (the /app/ headless standard); the Metal draw + touch are
// the device-QA'd layers, captured separately in the handoff evidence.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RibbonRotationTests: XCTestCase {

    // MARK: - a project with one group + a viewer mesh (addManualPrimitive needs the mesh)

    private func miniProject() -> (ProjectModel, UUID) {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        let verts: [Float] = [-10, -10, 0,  10, -10, 0,  10, 10, 0,  -10, 10, 0]
        let indices: [Int32] = [0, 1, 2, 0, 2, 3]
        let faceIDs: [Int32] = [1, 1]
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1), planeOrigin: .zero)
        p.viewerMesh = ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs,
                                  faceGeometry: [StepFaceGeometry(kind: .other), plane])
        var sel = SelectionModel()
        sel.addGroup(); sel.pickFaces([1])
        p.selection = sel
        let gid = sel.groups[0].id
        p.seedUndoBaseline()
        return (p, gid)
    }

    /// Simulate ONE ribbon drag exactly as `WorkspacePlaceholder.gizmoBoxGesture` does: grab the
    /// ribbon whose rotation axis is `about`, drag it through `degrees`, and commit via the real
    /// `rotateManualPrimitive` (snap ON, start axis threaded through — the shipped call). Returns
    /// the primitive's stored axis afterwards.
    @discardableResult
    private func dragRibbon(_ p: ProjectModel, _ gid: UUID, id: UUID,
                            about k: SIMD3<Double>, degrees: Double, snap: Bool = true) -> SIMD3<Double> {
        let start = p.force.manualPrimitives(for: gid).first { $0.id == id }!.axis
        // A clean grab→current pair in the plane ⟂ k that sweeps exactly `degrees` about k.
        let ref: SIMD3<Double> = abs(k.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let a = simd_normalize(simd_cross(k, ref))
        let b = PrimitiveGizmo.rotate(a, about: k, radians: degrees * .pi / 180)
        let center = p.force.manualPrimitives(for: gid).first { $0.id == id }!.center
        let drag = PrimitiveGizmo.Drag(handle: .rotate(k), startCenter: center, startAxis: start,
                                       grab: .init(origin: center + a + k * 10, dir: -k))
        let out = drag.resolve(currentRay: .init(origin: center + b + k * 10, dir: -k))
        p.rotateManualPrimitive(id: id, in: gid, to: out.axis, from: start, snap: snap)
        return p.force.manualPrimitives(for: gid).first { $0.id == id }!.axis
    }

    private func angleDeg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(simd_clamp(simd_dot(simd_normalize(a), simd_normalize(b)), -1, 1)) * 180 / .pi
    }

    // MARK: - THE regression (fails on pre-fix behaviour, passes after)

    func testSmallRibbonDragChangesStoredOrientation() {
        let (p, gid) = miniProject()
        let id = p.addManualPrimitive(.bolt, to: gid)!          // default axis +Z
        let before = p.force.manualPrimitives(for: gid).first { $0.id == id }!

        // Grab the ribbon that rotates about +X and turn it a SMALL 5° — inside the old 8°
        // snap-back dead-zone. Pre-fix this stored +Z unchanged; post-fix it tilts 5°.
        let stored = dragRibbon(p, gid, id: id, about: SIMD3(1, 0, 0), degrees: 5)
        let after = p.force.manualPrimitives(for: gid).first { $0.id == id }!

        XCTAssertNotEqual(after.axis, before.axis,
                          "grabbing a ribbon must CHANGE the stored orientation (it was snapped back)")
        XCTAssertEqual(angleDeg(before.axis, stored), 5, accuracy: 0.2, "should turn by the dragged 5°")
        // Expected DIRECTION: +Z rotated about +X by +5° → (0, -sin5°, cos5°), i.e. tilts toward −Y.
        XCTAssertLessThan(stored.y, 0, "a +X-axis turn tilts +Z toward −Y")
        XCTAssertGreaterThan(stored.z, 0.99, "a 5° turn barely lowers the Z component")
    }

    /// The change must SERIALIZE — it is what the sidecar persists and the run reads. Encode the
    /// post-drag primitive, decode it back, and assert the rotated axis survived the round-trip.
    func testRotatedOrientationSurvivesSerialization() throws {
        let (p, gid) = miniProject()
        let id = p.addManualPrimitive(.bolt, to: gid)!
        let stored = dragRibbon(p, gid, id: id, about: SIMD3(1, 0, 0), degrees: 5)
        let mp = p.force.manualPrimitives(for: gid).first { $0.id == id }!

        let data = try JSONEncoder().encode(mp)
        let round = try JSONDecoder().decode(ManualPrimitive.self, from: data)
        XCTAssertEqual(round.axis, stored, "the serialized primitive carries the rotated axis")
        XCTAssertNotEqual(round.axis, SIMD3(0, 0, 1), "serialized orientation is no longer the default +Z")
    }

    // MARK: - all the ribbons that CAN rotate, do (both a bolt and a face)

    func testTiltingRibbonsRotateBoltAndFace() {
        for kind in [ManualPrimitive.Kind.bolt, .face] {
            // The two ribbons whose axis is ⟂ the default +Z primitive both tilt it visibly.
            for about in [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0)] {
                let (p, gid) = miniProject()
                let id = p.addManualPrimitive(kind, to: gid)!
                let stored = dragRibbon(p, gid, id: id, about: about, degrees: 20)
                XCTAssertEqual(angleDeg(SIMD3(0, 0, 1), stored), 20, accuracy: 0.5,
                               "\(kind) ribbon about \(about) should rotate 20°")
            }
        }
    }

    /// The detent must still snap the axis onto a DIFFERENT principal axis as the drag approaches
    /// it — the fix only drops the orientation being LEFT, not all snapping (R4: detents intact).
    func testRotationStillSnapsToADifferentAxis() {
        let (p, gid) = miniProject()
        let id = p.addManualPrimitive(.bolt, to: gid)!
        // Turn about +X almost all the way to +Y (85°); it should snap onto the world Y axis
        // LINE (a bolt axis has no polarity, so ±Y both count).
        let stored = dragRibbon(p, gid, id: id, about: SIMD3(1, 0, 0), degrees: 85)
        XCTAssertGreaterThan(abs(stored.y), 1 - 1e-4, "should snap onto the world Y axis (±Y)")
    }

    /// The KNOWN STRUCTURAL LIMIT (candidate 3): a `ManualPrimitive` stores an axis vector and no
    /// roll, so the ribbon that rotates about the primitive's OWN axis is a mathematical no-op.
    /// For a bolt this is physically correct (a cylinder is symmetric about its axis — there is
    /// nothing to see). Documented here so the limit is asserted, not forgotten: lifting it needs
    /// a roll term in the schema + rasterizer (maintainer-gated; see the handoff).
    func testOwnAxisRibbonIsANoOpByConstruction() {
        let (p, gid) = miniProject()
        let id = p.addManualPrimitive(.bolt, to: gid)!         // axis +Z
        let stored = dragRibbon(p, gid, id: id, about: SIMD3(0, 0, 1), degrees: 30, snap: false)
        XCTAssertEqual(stored, SIMD3(0, 0, 1),
                       "rotating about the primitive's own axis cannot change an axis-only orientation")
    }

    /// Translate is untouched (R4): grabbing an AXIS handle still moves the centre, not the axis.
    func testTranslateHandleStillMovesCentreNotAxis() {
        let (p, gid) = miniProject()
        let id = p.addManualPrimitive(.bolt, to: gid)!
        let a0 = p.force.manualPrimitives(for: gid).first { $0.id == id }!
        p.moveManualPrimitive(id: id, in: gid, to: a0.center + SIMD3(50, 0, 0), snap: false)
        let a1 = p.force.manualPrimitives(for: gid).first { $0.id == id }!
        XCTAssertEqual(a1.axis, a0.axis, "a translate leaves the axis alone")
        XCTAssertNotEqual(a1.center, a0.center, "a translate moves the centre")
    }
}

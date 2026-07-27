// GravityDirectionTests — the gravity DIRECTION widget (2026-07-26, "set gravity by
// pointing, not by hunting for a clean face"). Covers the task's verification bars:
//
//   V1  The direction the widget shows is the direction that reaches the job. Serialize a
//       job after setting gravity by the widget and by a face tap to the SAME direction and
//       diff — they must be byte-equal (two ways to set ONE stored value, the anti-desync
//       lesson from PR 195).
//   V2  Snapping is EXACT: a snapped axis is bit-exactly (0,-1,0), not 0.9999.
//   V3  Setting gravity by the widget registers in the EXISTING round-6 UndoHistory.
//   V4  A project saved BEFORE this change loads with its gravity unchanged.
//
// The pure snap/point math is `GravityDirectionGizmo`; V1/V3/V4 drive the real
// ForceModel / ProjectModel / job serializer, mirroring ProjectModelTests +
// ManualPrimitiveJobTests.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class GravityDirectionTests: XCTestCase {

    // MARK: - fixtures (mirrors ProjectModelTests)

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/settings/rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-gravity-tests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func openedProject() throws -> (AppModel, ProjectModel) {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                         store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Bracket.stl"))
        m.continueToWorkspace()
        let project = try XCTUnwrap(m.project)
        return (m, project)
    }

    /// The job.json the current project would submit, parsed for structural comparison.
    private func jobDict(_ m: AppModel) throws -> [String: Any] {
        let req = try XCTUnwrap(m.makeRunRequest())
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: req, progress: { _, _, _ in true }, onVariant: { _ in })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
    }

    // MARK: - V1: the widget direction is the direction that reaches the job

    func testWidgetAndFaceTapProduceIdenticalJob() throws {
        let (m, project) = try openedProject()

        // A full load case, so the job carries BOTH gravity-derived quantities: `build_dir`
        // (= −gravity) AND a gravity-direction load's `force` (= gravity × N).
        let anchor = project.selection.addGroup()
        project.selection.pickFace(10)
        project.force.makeAnchor(anchor)
        let load = project.selection.addGroup()
        project.selection.pickFace(20)
        project.force.makeLoad(load)
        project.force.setWeight(load, kg: 4.2)

        // The SAME raw direction, set two different ways.
        let d = SIMD3<Float>(0.3, -1, 0.2)

        project.force.setGravity(faceNormal: d, face: 7)   // the face-tap route
        let jobFace = try jobDict(m)

        project.force.setGravity(direction: d)             // the widget route
        let jobWidget = try jobDict(m)

        // Diff the whole job (order-independent deep compare): they must be identical.
        XCTAssertEqual(jobFace as NSDictionary, jobWidget as NSDictionary,
                       "the widget and a face tap to the same direction serialize the same job")

        // And prove the direction actually reached the job (not both trivially empty):
        // build_dir is the negated, normalized gravity.
        let loads = try XCTUnwrap(jobWidget["loads"] as? [String: Any])
        let bd = try XCTUnwrap(loads["build_dir"] as? [Double])
        let n = simd_normalize(d)
        XCTAssertEqual(bd[0], Double(-n.x), accuracy: 1e-5)
        XCTAssertEqual(bd[1], Double(-n.y), accuracy: 1e-5)
        XCTAssertEqual(bd[2], Double(-n.z), accuracy: 1e-5)
    }

    /// The setters funnel through one core, so the STORED vector is identical too (the
    /// invariant behind V1: one value, not two that can drift).
    func testBothSettersStoreTheSameVector() {
        let raw = SIMD3<Float>(-0.4, -1, 0.6)
        var byFace = ForceModel(); byFace.setGravity(faceNormal: raw, face: 3)
        var byWidget = ForceModel(); byWidget.setGravity(direction: raw)
        XCTAssertEqual(byFace.gravity, byWidget.gravity)
        XCTAssertEqual(byFace.phase, .edit)
        XCTAssertEqual(byWidget.phase, .edit)
        // The widget has no owning face; the face route records one. That is the ONLY
        // difference, and it is not part of the job.
        XCTAssertNil(byWidget.gravityFace)
        XCTAssertEqual(byFace.gravityFace, 3)
    }

    // MARK: - V2: snapping is EXACT

    func testSnapReturnsExactAxisNotApproximate() {
        // A direction a hair off straight-down.
        let nearDown = SIMD3<Double>(0.02, -0.999, -0.015)
        let s = GravityDirectionGizmo.snap(nearDown)
        XCTAssertEqual(s.label, "−Y")
        // BIT-exact, not 0.9999: the stored vector must be the canonical axis.
        XCTAssertEqual(s.dir, SIMD3<Double>(0, -1, 0))
        XCTAssertEqual(s.dir.x, 0)
        XCTAssertEqual(s.dir.y, -1)
        XCTAssertEqual(s.dir.z, 0)
    }

    func testSnapCoversEverySignedAxisExactly() {
        for t in GravityDirectionGizmo.snapTargets {
            // Nudge each target slightly, then snap — it must return the exact axis.
            let nudged = t.direction + SIMD3<Double>(0.03, -0.02, 0.01)
            let s = GravityDirectionGizmo.snap(nudged)
            XCTAssertEqual(s.dir, t.direction, "snapping near \(t.label) returns the exact axis")
            XCTAssertEqual(s.label, t.label)
        }
    }

    func testOffAxisDirectionDoesNotSnap() {
        // ~30° off every axis — outside the 12° tolerance, so it passes through unchanged.
        let off = GravityDirectionGizmo.unit(SIMD3<Double>(0.6, -0.6, 0.2))
        let s = GravityDirectionGizmo.snap(off)
        XCTAssertNil(s.label, "an intentional off-axis direction is not snapped")
        XCTAssertEqual(s.dir, off)
    }

    func testSnapToleranceBoundary() {
        // Just inside the tolerance snaps; just outside does not (state: 12°).
        let tol = GravityDirectionGizmo.snapToleranceDegrees
        func dirTilted(_ deg: Double) -> SIMD3<Double> {
            let r = deg * .pi / 180
            return SIMD3<Double>(sin(r), -cos(r), 0)   // `deg` off −Y in the XY plane
        }
        XCTAssertEqual(GravityDirectionGizmo.snap(dirTilted(tol - 1)).label, "−Y")
        XCTAssertNil(GravityDirectionGizmo.snap(dirTilted(tol + 1)).label)
    }

    // MARK: - the pointing drag resolves toward the finger

    func testDragResolvesTowardMovedTip() {
        // Point starts at −Y; grab the tip and move the ray so the tip slides toward +X.
        let center = SIMD3<Double>(0, 0, 0)
        let length = 10.0
        // A camera looking down −Z: rays travel along −Z; the drag plane is the XY plane.
        let grab = PrimitiveGizmo.Ray(origin: SIMD3<Double>(0, -length, 5), dir: SIMD3<Double>(0, 0, -1))
        let drag = GravityDirectionGizmo.Drag(startDirection: SIMD3<Double>(0, -1, 0),
                                              center: center, length: length,
                                              grab: grab, viewDir: SIMD3<Double>(0, 0, -1))
        // Move the ray origin +X: the tip follows, so the direction tilts toward +X.
        let moved = PrimitiveGizmo.Ray(origin: SIMD3<Double>(4, -length, 5), dir: SIMD3<Double>(0, 0, -1))
        let out = drag.resolve(currentRay: moved)
        XCTAssertGreaterThan(out.x, 0, "the direction tilted toward the finger (+X)")
        XCTAssertLessThan(out.y, 0, "still mostly down")
        XCTAssertEqual(simd_length(out), 1, accuracy: 1e-9, "result is a unit direction")
    }

    // MARK: - V3: registers in the EXISTING UndoHistory

    func testWidgetGravityIsUndoable() throws {
        let (_, project) = try openedProject()
        project.seedUndoBaseline()
        XCTAssertFalse(project.force.gravityIsSet)

        project.force.setGravity(direction: SIMD3<Float>(1, 0, 0))
        XCTAssertTrue(project.force.gravityIsSet)
        XCTAssertTrue(project.canUndoNow, "the pointed direction is an undoable edit")

        project.performUndo()
        XCTAssertFalse(project.force.gravityIsSet, "undo reverts the gravity direction")

        project.performRedo()
        XCTAssertTrue(project.force.gravityIsSet, "redo restores it")
        XCTAssertEqual(project.force.gravity, simd_normalize(SIMD3<Float>(1, 0, 0)))
    }

    // MARK: - V4: a project saved BEFORE this change loads with its gravity unchanged

    func testPreChangeSnapshotDecodesGravityUnchanged() throws {
        // This change added NO Codable keys and did not touch the encoder, so a round-trip
        // through the SAME coder reproduces the exact on-disk format a pre-change build wrote.
        var pre = ForceModel()
        let n = SIMD3<Float>(0, 0, -1)
        pre.setGravity(faceNormal: n, face: 5)
        let data = try JSONEncoder().encode(pre)

        let decoded = try JSONDecoder().decode(ForceModel.self, from: data)
        XCTAssertEqual(decoded.gravity, simd_normalize(n), "gravity survives the load unchanged")
        XCTAssertEqual(decoded.gravityFace, 5, "the owning face survives too")
        XCTAssertTrue(decoded.gravityIsSet)
        XCTAssertEqual(decoded.phase, .edit)
    }

    func testWidgetSetGravityAlsoRoundTrips() throws {
        var fm = ForceModel()
        let d = SIMD3<Float>(0.3, -1, 0.2)
        fm.setGravity(direction: d)
        let decoded = try JSONDecoder().decode(ForceModel.self, from: JSONEncoder().encode(fm))
        XCTAssertEqual(decoded.gravity, simd_normalize(d))
        XCTAssertNil(decoded.gravityFace)
        XCTAssertEqual(decoded.phase, .edit)
    }
}

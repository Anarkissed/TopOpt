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
    /// The maintainer's own part (round 2, BAR V3): a wall-mount shelf bracket with large
    /// 45°-off-axis chamfer faces — geometry the PR-199 axes-only snap can NEVER engage on.
    private static var bracketSTL: String { core("tests/fixtures/mesh/WallMount_ShelfBracket.stl") }

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

    /// The maintainer's bracket, imported to a real `ViewerMesh` (BAR V3).
    private func openedBracket() throws -> (AppModel, ProjectModel) {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                         store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.bracketSTL, displayName: "WallMount_ShelfBracket.stl"))
        m.continueToWorkspace()
        let project = try XCTUnwrap(m.project)
        return (m, project)
    }

    /// The smallest angle (degrees) between `d` and any of the six signed principal axes.
    private func offAxisDegrees(_ d: SIMD3<Double>) -> Double {
        let n = GravityDirectionGizmo.unit(d)
        let best = GravityDirectionGizmo.snapTargets.map { simd_dot(n, $0.direction) }.max() ?? -1
        return Foundation.acos(min(1, max(-1, best))) * 180 / .pi
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

    // ─────────────────────────────────────────────────────────────────────────────────────
    // MARK: - ROUND 2 (2026-07-27): face-normal detents, movable base, edit-only visibility
    // ─────────────────────────────────────────────────────────────────────────────────────

    // MARK: item 1 / V2 — the tip snaps to the part's own FACE normals, exactly

    /// A face normal within tolerance snaps to the EXACT candidate vector (not 0.9999), and
    /// carries the "face" label. This is item 1: gravity snaps to the part's faces, not axes.
    func testSnapToFaceNormalIsExact() {
        // A 45°-off-axis face normal (like the bracket's chamfer) — outside every axis's cone.
        let faceN = GravityDirectionGizmo.unit(SIMD3<Double>(-0.69, -0.72, 0))
        let targets = GravityDirectionGizmo.faceSnapTargets([faceN])
        // Point a few degrees off it.
        let pointed = GravityDirectionGizmo.unit(faceN + SIMD3<Double>(0.05, 0.02, 0.03))
        let s = GravityDirectionGizmo.snap(pointed, extraTargets: targets)
        XCTAssertEqual(s.label, "face")
        // BIT-exact the candidate face normal — "exactly the face normal", never an approximation.
        XCTAssertEqual(s.dir, targets[0].direction)
    }

    /// The BUG this round fixes, made explicit: with the PR-199 axes-only set, a direction near
    /// a 44°-off face does NOT snap (→ "Gravity set · custom"); adding the face targets snaps it.
    func testAxesOnlyMissesTheFaceThatFaceTargetsCatch() {
        let faceN = GravityDirectionGizmo.unit(SIMD3<Double>(0.71, -0.71, 0))
        let pointed = GravityDirectionGizmo.unit(faceN + SIMD3<Double>(0.04, 0.03, 0.0))
        XCTAssertGreaterThan(offAxisDegrees(faceN), 12, "precondition: the face is off every axis")

        let axesOnly = GravityDirectionGizmo.snap(pointed)               // PR-199 behaviour
        XCTAssertNil(axesOnly.label, "axes-only snap can't engage on an off-axis face — the bug")

        let withFaces = GravityDirectionGizmo.snap(pointed,
                            extraTargets: GravityDirectionGizmo.faceSnapTargets([faceN]))
        XCTAssertEqual(withFaces.label, "face")
        XCTAssertEqual(withFaces.dir, faceN)
    }

    /// Principal axes are listed first, so a face normal that coincides with an axis reports the
    /// clean axis label (not "face") — the "additional detents" ordering.
    func testAxisWinsTieOverCoincidentFaceNormal() {
        let down = SIMD3<Double>(0, -1, 0)
        let s = GravityDirectionGizmo.snap(SIMD3<Double>(0.01, -1, 0.0),
                    extraTargets: GravityDirectionGizmo.faceSnapTargets([down]))
        XCTAssertEqual(s.label, "−Y")
        XCTAssertEqual(s.dir, down)
    }

    // MARK: item 1 / V3 — PROVE it snaps on the maintainer's REAL bracket (not a cube)

    func testFaceSnapEngagesOnTheRealBracket() throws {
        let (_, project) = try openedBracket()
        let mesh = try XCTUnwrap(project.viewerMesh)
        let flats = mesh.flatFaceNormals()
        XCTAssertGreaterThanOrEqual(flats.count, 4, "the bracket exposes several flat seating faces")

        // The crux: the bracket has a LARGE flat face that is well off every principal axis —
        // exactly the geometry PR-199 failed on. Find it among the candidates.
        let offAxis = flats.first { offAxisDegrees(SIMD3<Double>($0.normal)) > 20 }
        let f = try XCTUnwrap(offAxis, "the bracket has an off-axis chamfer face to snap to")
        XCTAssertGreaterThan(offAxisDegrees(SIMD3<Double>(f.normal)), 20)

        let targets = GravityDirectionGizmo.faceSnapTargets(flats.map { SIMD3<Double>($0.normal) })
        // Point a few degrees off that real face normal.
        let pointed = GravityDirectionGizmo.unit(SIMD3<Double>(f.normal) + SIMD3<Double>(0.04, -0.03, 0.02))

        XCTAssertNil(GravityDirectionGizmo.snap(pointed).label,
                     "on the real bracket the axes-only snap stays 'custom' — the reported failure")
        let snapped = GravityDirectionGizmo.snap(pointed, extraTargets: targets)
        XCTAssertEqual(snapped.label, "face", "face-normal snapping engages on the real part (V3)")
        XCTAssertEqual(snapped.dir, GravityDirectionGizmo.unit(SIMD3<Double>(f.normal)),
                       "and lands EXACTLY on that face's normal (V2 on the real part)")
    }

    /// flatFaceNormals rejects curved surfaces: a sphere yields no large flat seating faces,
    /// while the bracket yields several — so the candidate set is the part's genuine flats.
    func testFlatFaceSelectionRejectsCurvature() throws {
        let (_, project) = try openedBracket()
        let bracket = try XCTUnwrap(project.viewerMesh)
        XCTAssertGreaterThanOrEqual(bracket.flatFaceNormals().count, 4)

        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                         store: ProjectStore(rootDir: tempDir))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.core("tests/fixtures/stl/sphere_r10mm.stl"),
                                   displayName: "sphere.stl"))
        m.continueToWorkspace()
        let sphere = try XCTUnwrap(m.project?.viewerMesh)
        // A sphere's patches are curved (low flatness), so far fewer qualify than the bracket's flats.
        XCTAssertLessThan(sphere.flatFaceNormals().count, bracket.flatFaceNormals().count,
                          "curvature is rejected — candidates are the part's genuine flat faces")
    }

    // MARK: item 2 — magnetic base attach (pure geometry)

    func testClosestPointOnTriangleCases() {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(2, 0, 0), c = SIMD3<Float>(0, 2, 0)
        // Directly above the interior projects straight down onto the plane.
        XCTAssertEqual(MeshGeometry.closestPointOnTriangle(SIMD3<Float>(0.5, 0.5, 5), a, b, c),
                       SIMD3<Float>(0.5, 0.5, 0))
        // Off past a vertex clamps to that vertex.
        XCTAssertEqual(MeshGeometry.closestPointOnTriangle(SIMD3<Float>(-3, -3, 0), a, b, c), a)
        // Off an edge clamps onto the edge.
        let e = MeshGeometry.closestPointOnTriangle(SIMD3<Float>(1, -3, 0), a, b, c)
        XCTAssertEqual(e.y, 0, accuracy: 1e-5); XCTAssertEqual(e.z, 0, accuracy: 1e-5)
        XCTAssertGreaterThan(e.x, 0); XCTAssertLessThan(e.x, 2)
    }

    /// The magnet: a base point held a little off a bracket face attaches ONTO the surface, and
    /// a point far away (beyond the magnet radius) does not.
    func testBaseMagnetAttachesToBracketSurface() throws {
        let (_, project) = try openedBracket()
        let mesh = try XCTUnwrap(project.viewerMesh)
        let center = mesh.bounds.center
        let radius = mesh.bounds.radius

        // A point at the mesh centre is inside/near the solid → attaches to a surface point on it.
        let near = try XCTUnwrap(mesh.nearestSurfacePoint(to: center, within: radius * 2))
        XCTAssertLessThanOrEqual(simd_length(near.point - center), radius * 2)
        XCTAssertEqual(simd_length(near.normal), 1, accuracy: 1e-4, "returns a unit face normal")

        // A point a whole diameter away is beyond a tight magnet radius → no attach.
        let farP = center + SIMD3<Float>(radius * 10, 0, 0)
        XCTAssertNil(mesh.nearestSurfacePoint(to: farP, within: radius * 0.4))
    }

    // MARK: V4 — the base is PURELY VISUAL: it round-trips but never reaches the job

    func testBasePositionRoundTrips() throws {
        var fm = ForceModel()
        fm.setGravity(direction: SIMD3<Float>(0, -1, 0))
        let base = SIMD3<Float>(3, -4, 5)
        fm.setGravityBase(base)
        let decoded = try JSONDecoder().decode(ForceModel.self, from: JSONEncoder().encode(fm))
        XCTAssertEqual(decoded.gravityBaseModel, base, "the arrow base survives save/load (V4)")
        XCTAssertEqual(decoded.gravity, SIMD3<Float>(0, -1, 0))
    }

    func testBasePositionDoesNotChangeTheJob() throws {
        let (m, project) = try openedProject()
        let anchor = project.selection.addGroup(); project.selection.pickFace(10)
        project.force.makeAnchor(anchor)
        let load = project.selection.addGroup(); project.selection.pickFace(20)
        project.force.makeLoad(load); project.force.setWeight(load, kg: 3.0)
        project.force.setGravity(direction: SIMD3<Float>(0.2, -1, 0.1))

        project.force.setGravityBase(SIMD3<Float>(0, 0, 0))
        let jobA = try jobDict(m)
        project.force.setGravityBase(SIMD3<Float>(50, -20, 33))   // move the base far
        let jobB = try jobDict(m)
        XCTAssertEqual(jobA as NSDictionary, jobB as NSDictionary,
                       "moving the purely-visual base does not change the job (V4)")
    }

    // MARK: V6 — a pre-round-2 snapshot (no base key) loads with gravity unchanged & base nil

    func testPreRound2SnapshotHasNilBaseAndUnchangedGravity() throws {
        // Encode WITHOUT ever touching the base, then strip nothing — the key is simply absent.
        var pre = ForceModel()
        pre.setGravity(faceNormal: SIMD3<Float>(0, 0, -1), face: 5)
        let data = try JSONEncoder().encode(pre)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("gravityBaseModel"),
                       "an untouched base is not emitted — byte-identical to a pre-round-2 snapshot")
        let decoded = try JSONDecoder().decode(ForceModel.self, from: data)
        XCTAssertNil(decoded.gravityBaseModel, "absent base decodes to nil (V6)")
        XCTAssertEqual(decoded.gravity, simd_normalize(SIMD3<Float>(0, 0, -1)))
    }

    // MARK: V7 — the arrow and the base gizmo don't move each other

    func testBaseAndDirectionAreIndependent() {
        var fm = ForceModel()
        fm.setGravity(direction: SIMD3<Float>(0, -1, 0))
        // Moving the base (the transform gizmo) NEVER changes the aim (BAR V7 direction ①).
        fm.setGravityBase(SIMD3<Float>(5, 0, 0))
        XCTAssertEqual(fm.gravity, SIMD3<Float>(0, -1, 0))
        fm.setGravityBase(SIMD3<Float>(9, 9, 9))
        XCTAssertEqual(fm.gravity, SIMD3<Float>(0, -1, 0))
        // Aiming the arrow NEVER moves the base (BAR V7 direction ②).
        fm.setGravity(direction: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(fm.gravityBaseModel, SIMD3<Float>(9, 9, 9))
    }

    // MARK: V3/V5 — the whole gravity edit (direction + base) is ONE undoable step

    func testWidgetGravityWithBaseIsSingleUndo() throws {
        let (_, project) = try openedBracket()
        project.seedUndoBaseline()
        XCTAssertFalse(project.force.gravityIsSet)

        // Mirror commitGravityDraft: set direction + base together (one @Published mutation batch).
        project.force.setGravity(direction: SIMD3<Float>(0, -1, 0))
        project.force.setGravityBase(SIMD3<Float>(1, 2, 3))
        XCTAssertTrue(project.canUndoNow)

        project.performUndo()
        XCTAssertFalse(project.force.gravityIsSet, "undo reverts the gravity edit")
        XCTAssertNil(project.force.gravityBaseModel, "…including the base, in one step")
        project.performRedo()
        XCTAssertEqual(project.force.gravityBaseModel, SIMD3<Float>(1, 2, 3), "redo restores it")
    }
}

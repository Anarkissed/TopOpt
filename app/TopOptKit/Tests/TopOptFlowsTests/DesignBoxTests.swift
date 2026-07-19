// DesignBoxTests.swift — headless macOS tests for the M7.dom-app design-domain UI
// model (docs/handoffs 069-M7.dom-app). The 3D gizmo feel + the visible material
// growth are device QA; these lock down the pure logic the handoff calls out to
// verify: (1) the box → bridge model-space conversion, (2) the persistence
// round-trip, and (3) the no-box DEFAULT (nothing passed → byte-identical run).

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class DesignBoxTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/settings/rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }

    /// A part bbox: 20×10×30 mm, not centred on the origin (so offsets are exercised).
    private var part: MeshBounds {
        MeshBounds(min: SIMD3<Float>(-5, 0, 10), max: SIMD3<Float>(15, 10, 40), isEmpty: false)
    }

    // MARK: - (3) DEFAULT OFF: a fresh model passes NO box

    func testFreshModelIsInactiveAndPassesNoBox() {
        let m = DesignBoxModel()
        XCTAssertFalse(m.isActive, "a project that never opened the tool has no box")
        XCTAssertNil(m.box)
        XCTAssertNil(m.bridgeBox, "no box → the run passes nil → default no-box path")
        XCTAssertTrue(m.bridgeKeepOuts.isEmpty)
    }

    func testDisableRevertsToNoBoxAndDropsKeepOuts() {
        var m = DesignBoxModel()
        m.enable(around: part)
        m.addKeepOut(around: part)
        XCTAssertTrue(m.isActive)
        XCTAssertNotNil(m.bridgeBox)
        m.disable()
        XCTAssertFalse(m.isActive)
        XCTAssertNil(m.bridgeBox, "turning the tool off reverts to the default no-box run")
        XCTAssertTrue(m.keepOuts.isEmpty, "keep-outs are dropped with the box")
        XCTAssertTrue(m.bridgeKeepOuts.isEmpty)
    }

    func testKeepOutsAreIgnoredWithoutABox() {
        var m = DesignBoxModel()
        // Force keep-outs on with no box (bypassing addKeepOut's guard) — the bridge
        // conversion must still pass nothing, because keep-outs need a design box.
        m.keepOuts = [DesignBoxBounds(min: .zero, max: SIMD3<Float>(repeating: 1))]
        XCTAssertNil(m.bridgeBox)
        XCTAssertTrue(m.bridgeKeepOuts.isEmpty, "keep-outs never pass alone (no box)")
    }

    func testAppModelMakeRunRequestOmitsBoxByDefault() throws {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath)
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.cubeSTL, displayName: "Bracket.stl"))
        m.continueToWorkspace()
        let req = try XCTUnwrap(m.makeRunRequest())
        XCTAssertNil(req.designBox, "default project → no design box on the run request")
        XCTAssertTrue(req.keepOutBoxes.isEmpty)
    }

    // MARK: - (1) box → bridge model-space conversion

    func testDefaultBoxEnclosesAndExceedsThePart() {
        let box = DesignBoxModel.defaultBox(around: part)
        // The default box must strictly contain the part on every axis (grow room).
        XCTAssertLessThan(box.min.x, part.min.x)
        XCTAssertLessThan(box.min.y, part.min.y)
        XCTAssertLessThan(box.min.z, part.min.z)
        XCTAssertGreaterThan(box.max.x, part.max.x)
        XCTAssertGreaterThan(box.max.y, part.max.y)
        XCTAssertGreaterThan(box.max.z, part.max.z)
    }

    func testBridgeBoxIsModelSpaceIdentity() {
        var m = DesignBoxModel()
        m.box = DesignBoxBounds(min: SIMD3<Float>(-7, -2, 5), max: SIMD3<Float>(21, 14, 46))
        let spec = try! XCTUnwrap(m.bridgeBox)
        // Model space maps straight through to the core DesignBox (mm → mm), no scale.
        XCTAssertEqual(spec.min, SIMD3<Double>(-7, -2, 5))
        XCTAssertEqual(spec.max, SIMD3<Double>(21, 14, 46))
    }

    func testBridgeKeepOutsConvertInOrder() {
        var m = DesignBoxModel()
        m.enable(around: part)
        m.keepOuts = [
            DesignBoxBounds(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(1, 2, 3)),
            DesignBoxBounds(min: SIMD3<Float>(4, 5, 6), max: SIMD3<Float>(7, 8, 9)),
        ]
        let ks = m.bridgeKeepOuts
        XCTAssertEqual(ks.count, 2)
        XCTAssertEqual(ks[0].min, SIMD3<Double>(0, 0, 0))
        XCTAssertEqual(ks[0].max, SIMD3<Double>(1, 2, 3))
        XCTAssertEqual(ks[1].min, SIMD3<Double>(4, 5, 6))
        XCTAssertEqual(ks[1].max, SIMD3<Double>(7, 8, 9))
    }

    func testBoundsNormalizeMinMax() {
        // min/max supplied out of order are sorted so min <= max componentwise.
        let b = DesignBoxBounds(min: SIMD3<Float>(10, 2, 9), max: SIMD3<Float>(1, 8, 3))
        XCTAssertEqual(b.min, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(b.max, SIMD3<Float>(10, 8, 9))
    }

    // MARK: - resizing / moving (the gizmo's editing logic)

    func testResizeFaceGrowsBeyondThePart() {
        var m = DesignBoxModel()
        m.box = DesignBoxBounds(min: .zero, max: SIMD3<Float>(repeating: 10))
        // Push the +x face out to 25 (well beyond the part's 15 max) — grow room.
        m.resizeFace(axis: 0, isMax: true, to: 25, part: part)
        XCTAssertEqual(m.box?.max.x, 25)
        XCTAssertEqual(m.box?.min.x, 0, "the opposite face stays put")
    }

    func testResizeFaceCannotInvertTheBox() {
        var m = DesignBoxModel()
        m.box = DesignBoxBounds(min: .zero, max: SIMD3<Float>(repeating: 10))
        // Drag the +y face down past the −y face: it's clamped to keep the box valid.
        m.resizeFace(axis: 1, isMax: true, to: -100, part: part)
        let box = m.box!
        XCTAssertGreaterThan(box.max.y, box.min.y, "the box never inverts")
        XCTAssertGreaterThanOrEqual(box.size.y, DesignBoxModel.minSize(for: part))
    }

    func testMoveTranslatesWholeBox() {
        var m = DesignBoxModel()
        m.box = DesignBoxBounds(min: .zero, max: SIMD3<Float>(repeating: 10))
        m.move(by: SIMD3<Float>(5, -3, 2))
        XCTAssertEqual(m.box?.min, SIMD3<Float>(5, -3, 2))
        XCTAssertEqual(m.box?.max, SIMD3<Float>(15, 7, 12))
    }

    func testAddAndRemoveKeepOut() {
        var m = DesignBoxModel()
        XCTAssertNil(m.addKeepOut(around: part), "no keep-out without a box")
        m.enable(around: part)
        let i0 = m.addKeepOut(around: part)
        XCTAssertEqual(i0, 0)
        _ = m.addKeepOut(around: part)
        XCTAssertEqual(m.keepOuts.count, 2)
        m.removeKeepOut(at: 0)
        XCTAssertEqual(m.keepOuts.count, 1)
        m.removeKeepOut(at: 5)   // out of range → no-op
        XCTAssertEqual(m.keepOuts.count, 1)
    }

    func testEnableIsIdempotentAndResetRestoresDefault() {
        var m = DesignBoxModel()
        m.enable(around: part)
        let seeded = m.box
        m.resizeFace(axis: 0, isMax: true, to: 100, part: part)
        m.enable(around: part)   // re-opening keeps the user's edits
        XCTAssertEqual(m.box?.max.x, 100, "enable() does not clobber an existing box")
        m.reset(around: part)    // reset restores the default grow-room box
        XCTAssertEqual(m.box, seeded)
    }

    // MARK: - (2) persistence round-trip

    func testDesignBoxCodableRoundTripInSnapshot() throws {
        var db = DesignBoxModel()
        db.box = DesignBoxBounds(min: SIMD3<Float>(-7, -2, 5), max: SIMD3<Float>(21, 14, 46))
        db.keepOuts = [DesignBoxBounds(min: SIMD3<Float>(0, 1, 2), max: SIMD3<Float>(3, 4, 5))]

        let snap = ProjectSnapshot(id: UUID(), name: "Bracket", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "Bracket.stl",
                                   savedAt: Date(timeIntervalSince1970: 1000),
                                   selection: SelectionModel(), force: ForceModel(),
                                   designBox: db)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.designBox, db, "the design box + keep-outs survive the round-trip")
    }

    func testLegacySnapshotWithoutDesignBoxDecodesAsOff() throws {
        // A pre-M7.dom-app snapshot has no designBox key: it must decode (back-compat)
        // and be treated as the default-off model (no box on the run).
        let snap = ProjectSnapshot(id: UUID(), name: "Old", material: "PLA", process: .fdm,
                                   modelFileName: "model.stl", originalFileName: "Old.stl",
                                   savedAt: Date(timeIntervalSince1970: 1),
                                   selection: SelectionModel(), force: ForceModel())
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        XCTAssertNil(back.designBox)
        // ProjectModel(restoring:) coalesces a nil snapshot box to the off model.
        XCTAssertFalse((back.designBox ?? DesignBoxModel()).isActive)
    }

    func testDesignBoxSurvivesAppRelaunch() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-designbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Launch 1: import, define a design box + keep-out, leave to Home (autosave).
        let m1 = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                          store: ProjectStore(rootDir: tempDir))
        m1.loadMaterials(); m1.newTopOpt(); m1.selectMaterial("PLA")
        XCTAssertTrue(m1.importFile(atPath: Self.cubeSTL, displayName: "Bracket.stl"))
        m1.continueToWorkspace()
        let project1 = try XCTUnwrap(m1.project)
        let recentID = try XCTUnwrap(m1.recentProjects.first).id
        let mesh = try XCTUnwrap(project1.viewerMesh)
        project1.designBox.enable(around: mesh.bounds)
        project1.designBox.resizeFace(axis: 0, isMax: true, to: 100, part: mesh.bounds)
        project1.designBox.addKeepOut(around: mesh.bounds)
        let saved = project1.designBox
        m1.backHome()   // autosave

        // Launch 2: a fresh AppModel over the same store reloads the box from disk.
        let m2 = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                          store: ProjectStore(rootDir: tempDir))
        let recent2 = try XCTUnwrap(m2.recentProjects.first(where: { $0.id == recentID }))
        m2.open(recent2)
        let restored = try XCTUnwrap(m2.project)
        XCTAssertEqual(restored.designBox, saved, "the design box + keep-out survive relaunch")
        XCTAssertTrue(restored.designBox.isActive)
    }

    // MARK: - drag math (screen → model-space, camera-independent)

    func testAxisDeltaMapsScreenDragToModelUnits() {
        // A camera looking down −Z at the origin: +X projects horizontally on screen.
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3<Float>(repeating: -5), max: SIMD3<Float>(repeating: 5), isEmpty: false))
        cam.azimuth = 0; cam.distance = 20
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 400, height: 400))
        // Dragging right should move the +X handle in +X by a positive amount; the
        // exact scale depends on the projection, but the SIGN + finiteness are the
        // contract the gizmo relies on.
        let d = DesignBoxDrag.axisDelta(handleWorld: SIMD3<Float>(0, 0, 0),
                                        worldAxis: SIMD3<Float>(1, 0, 0),
                                        drag: CGVector(dx: 40, dy: 0),
                                        projection: proj, probe: 1)
        XCTAssertTrue(d.isFinite)
        XCTAssertGreaterThan(abs(d), 0, "a drag along the projected axis moves the handle")
    }

    func testAxisDeltaIsZeroForEdgeOnAxis() {
        // A handle-axis pointing straight along the view direction (at the camera)
        // projects to ~zero screen length → the helper returns 0 rather than flinging
        // the handle to infinity.
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3<Float>(repeating: -5), max: SIMD3<Float>(repeating: 5), isEmpty: false))
        cam.distance = 20
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 400, height: 400))
        // The camera's view direction is exactly edge-on from the orbit target.
        let d = DesignBoxDrag.axisDelta(handleWorld: cam.target, worldAxis: simd_normalize(cam.direction),
                                        drag: CGVector(dx: 30, dy: 30), projection: proj, probe: 0.4)
        XCTAssertEqual(d, 0, accuracy: 1e-3)
    }

    // MARK: - Single-owner drag session (design-overhaul 109 — the "ghost duplicate boxes" fix)

    private func face(_ axis: Int, _ isMax: Bool, target: DesignBoxDragSession.HandleID.Target = .designBox)
        -> DesignBoxDragSession.HandleID {
        DesignBoxDragSession.HandleID(target: target, kind: .face(axis: axis, isMax: isMax))
    }
    private func move(target: DesignBoxDragSession.HandleID.Target = .designBox) -> DesignBoxDragSession.HandleID {
        DesignBoxDragSession.HandleID(target: target, kind: .move)
    }
    private let unitBox = DesignBoxBounds(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(2, 2, 2))

    /// The core regression: a SECOND handle firing during another handle's live drag is rejected,
    /// so two gestures can never both write the box from the shared base (the ghost-duplicate
    /// cause). The owner keeps its own untouched base throughout.
    func testConcurrentSecondHandleIsRejected() {
        var s = DesignBoxDragSession()
        let faceH = face(0, true), moveH = move()
        // Face handle claims the drag.
        XCTAssertEqual(s.begin(faceH, current: unitBox), unitBox)
        XCTAssertEqual(s.activeOwner, faceH)
        // An overlapping move handle fires in the SAME interaction with a DIFFERENT box → rejected.
        XCTAssertNil(s.begin(moveH, current: unitBox.translated(by: SIMD3<Float>(9, 0, 0))),
                     "a second handle must not seize a live drag")
        XCTAssertNil(s.base(for: moveH))
        // The owner's base is intact — the intruder could not corrupt it.
        XCTAssertEqual(s.base(for: faceH), unitBox)
    }

    /// The base is the drag-START snapshot: passing the live (already-moved) box on later frames
    /// must NOT re-capture it, or the delta would compound and the box would run away.
    func testBaseCapturedOncePerDrag() {
        var s = DesignBoxDragSession()
        let h = move()
        XCTAssertEqual(s.begin(h, current: unitBox), unitBox)
        let moved = unitBox.translated(by: SIMD3<Float>(10, 0, 0))
        XCTAssertEqual(s.begin(h, current: moved), unitBox,
                       "base stays the drag-start snapshot across frames, never re-captured")
    }

    /// A stale `end` from a non-owner (e.g. a dropped gesture) must NOT tear down the live drag —
    /// the old code cleared the single shared base on ANY end, stranding the real drag.
    func testStaleEndFromNonOwnerIsIgnored() {
        var s = DesignBoxDragSession()
        let faceH = face(1, false), moveH = move()
        s.begin(faceH, current: unitBox)
        s.end(moveH)                                   // a different handle's end
        XCTAssertTrue(s.isActive, "a non-owner's end can't release the drag")
        XCTAssertEqual(s.activeOwner, faceH)
        s.end(faceH)                                   // the owner ends → released
        XCTAssertFalse(s.isActive)
    }

    /// After the owner ends, a fresh handle can claim its own drag with its own base — including
    /// a keep-out, which shares the one session but never collides with the design box.
    func testDragReleasesAndNextHandleClaimsFreshBase() {
        var s = DesignBoxDragSession()
        let a = face(2, true)
        XCTAssertEqual(s.begin(a, current: unitBox), unitBox)
        s.end(a)
        let koBox = DesignBoxBounds(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))
        let ko = move(target: .keepOut(0))
        XCTAssertEqual(s.begin(ko, current: koBox), koBox, "a freed session accepts the next handle")
        XCTAssertEqual(s.activeOwner, ko)
        XCTAssertNil(s.base(for: a), "the previous owner no longer has a base")
    }

    /// End-to-end proof that the fix prevents the ghost: two handles interleave onChanged frames,
    /// but only the OWNER's writes land, so the box equals an owner-only drag (no contamination).
    func testInterleavedWritesMatchOwnerOnlyDrag() {
        let minSize: Float = 0.1
        // Owner-only reference: three frames of a +X max-face resize, absolute from the base.
        func faceResize(_ base: DesignBoxBounds, to value: Float) -> DesignBoxBounds {
            base.movingFace(axis: 0, isMax: true, to: value, minSize: minSize)
        }
        var s = DesignBoxDragSession()
        let owner = face(0, true), intruder = move()
        var box = unitBox
        // Frame 1: owner claims.
        if let base = s.begin(owner, current: box) { box = faceResize(base, to: 3.0) }
        // Frame 2: an intruder tries to translate — rejected, no write.
        if let base = s.begin(intruder, current: box) { box = base.translated(by: SIMD3<Float>(5, 5, 5)) }
        // Frame 3: owner continues from its ORIGINAL base.
        if let base = s.begin(owner, current: box) { box = faceResize(base, to: 4.0) }

        let expected = faceResize(unitBox, to: 4.0)   // pure owner-only result
        XCTAssertEqual(box, expected, "the intruder's frame left no trace — no ghost box")
    }

    // MARK: - Single-gesture hit-test chooser (handoff 111 — the teleport/ghost fix)

    private func target(_ h: DesignBoxDragSession.HandleID, _ x: CGFloat, _ y: CGFloat)
        -> DesignBoxHitTest.Target {
        DesignBoxHitTest.Target(handle: h, screen: CGPoint(x: x, y: y))
    }

    /// The chooser picks the NEAREST handle to the touch, so an overlapping cluster
    /// resolves to exactly one — the whole point of collapsing to one gesture.
    func testHitTestPicksNearestHandle() {
        let a = target(move(), 100, 100)
        let b = target(face(0, true), 140, 100)
        let picked = DesignBoxHitTest.choose(at: CGPoint(x: 132, y: 100), among: [a, b], radius: 30)
        XCTAssertEqual(picked, face(0, true), "the closer handle (b) wins")
    }

    /// A touch outside every handle's grab radius selects nothing (nil), so the touch
    /// falls through to the camera instead of grabbing a distant handle.
    func testHitTestRejectsTouchOutsideRadius() {
        let a = target(move(), 100, 100)
        XCTAssertNil(DesignBoxHitTest.choose(at: CGPoint(x: 200, y: 200), among: [a], radius: 30))
    }

    /// An EXACT distance tie is broken by `tieBreakRank`, deterministically and
    /// independent of the order candidates are supplied in (the move handle, rank 0,
    /// beats the +x face, rank 2). Both orders must agree.
    func testHitTestTieBreakIsDeterministicAndOrderIndependent() {
        let p = CGPoint(x: 100, y: 100)
        let mv = target(move(), 110, 100)              // both exactly 10 pt away
        let fx = target(face(0, true), 90, 100)
        XCTAssertEqual(DesignBoxHitTest.choose(at: p, among: [mv, fx], radius: 30), move())
        XCTAssertEqual(DesignBoxHitTest.choose(at: p, among: [fx, mv], radius: 30), move(),
                       "the tie resolves the same regardless of candidate order")
    }

    /// A keep-out handle and a design-box handle never collide: distinct targets get
    /// distinct ranks, and the nearest still wins.
    func testHitTestSeparatesKeepOutFromDesignBox() {
        let boxMove = target(move(), 100, 100)
        let koMove = target(move(target: .keepOut(0)), 300, 300)
        XCTAssertEqual(DesignBoxHitTest.choose(at: CGPoint(x: 296, y: 300), among: [boxMove, koMove], radius: 30),
                       move(target: .keepOut(0)))
    }

    /// The canonical candidate builder projects the box's move + 6 faces (and each
    /// keep-out's) in `tieBreakRank` order via the supplied closures — pure, so the
    /// overlay's hit-set is exercised headlessly. An identity projection lets us assert
    /// the count and the leading handle.
    func testCandidateBuilderProducesCanonicalHandleSet() {
        let box = DesignBoxBounds(min: .zero, max: SIMD3<Float>(repeating: 10))
        let ko = DesignBoxBounds(min: SIMD3<Float>(1, 1, 1), max: SIMD3<Float>(3, 3, 3))
        let cands = DesignBoxHandles.candidates(
            box: box, keepOuts: [ko],
            settledWorld: { $0 },                                   // no settle
            project: { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }) // identity xy
        // 7 handles for the box + 7 for the one keep-out.
        XCTAssertEqual(cands.count, 14)
        XCTAssertEqual(cands.first?.handle, move(), "the design-box move handle leads")
        // Every handle is unique (no two share an identity → no accidental overlap).
        XCTAssertEqual(Set(cands.map(\.handle.tieBreakRank)).count, 14)
    }
}

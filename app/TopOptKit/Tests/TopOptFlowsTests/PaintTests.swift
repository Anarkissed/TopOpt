// Headless macOS tests for paint mode — the face-selection safety net (handoff
// 2026-07-24). Pure value-type logic (PaintModel / PaintHistory) plus the GPU-free
// brush + pre-highlight geometry (BrushHitTest / TapSelection), the /app/
// verification standard. The final test drives the WHOLE data path (paint →
// sidecar → resolved re-import) through the real bridge, proving a painted face
// survives to the mesh optimize path exactly like a tapped one.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class PaintTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    // MARK: - PaintModel

    func testApplyAddOverridesEffectiveFaceIDs() {
        let base: [Int32] = [0, 0, 1, 1, 2, 2]  // 3 native faces, 2 triangles each
        var m = PaintModel(baseFaceCount: 3)
        let p = m.mintFace()
        XCTAssertEqual(p, 3, "first painted id is baseFaceCount")
        XCTAssertTrue(m.isPainted(p))
        XCTAssertFalse(m.isPainted(2))

        let edit = m.apply(.add, target: p, triangles: [4, 2])
        XCTAssertEqual(edit.changes.map(\.triangle), [2, 4], "changes are ascending")
        let eff = m.effectiveFaceIDs(base: base)
        XCTAssertEqual(eff, [0, 0, 3, 1, 3, 2], "painted triangles 2 and 4 read as face 3")
        XCTAssertEqual(m.triangles(ofPaintedFace: p), [2, 4])
    }

    func testEraseRevertsToNative() {
        var m = PaintModel(baseFaceCount: 3)
        let p = m.mintFace()
        m.apply(.add, target: p, triangles: [0, 1, 2])
        let erased = m.apply(.erase, target: p, triangles: [1])
        XCTAssertEqual(erased.changes.count, 1)
        XCTAssertEqual(m.effectiveFaceIDs(base: [0, 0, 0]), [3, 0, 3],
                       "erased triangle 1 is back on its native face")
    }

    func testReapplyingSameStrokeIsNoOp() {
        var m = PaintModel(baseFaceCount: 1)
        let p = m.mintFace()
        m.apply(.add, target: p, triangles: [0, 1])
        let again = m.apply(.add, target: p, triangles: [0, 1])
        XCTAssertTrue(again.isEmpty, "re-painting already-painted triangles changes nothing")
    }

    func testDeterministicRegardlessOfStrokeOrder() {
        // The same triangles painted in different sub-stroke orders yield the same
        // assignments and the same persisted sets (the determinism bar).
        var a = PaintModel(baseFaceCount: 2); let pa = a.mintFace()
        a.apply(.add, target: pa, triangles: [5, 1, 3])
        var b = PaintModel(baseFaceCount: 2); let pb = b.mintFace()
        b.apply(.add, target: pb, triangles: [3])
        b.apply(.add, target: pb, triangles: [1, 5])
        XCTAssertEqual(a.assignments, b.assignments)
        XCTAssertEqual(a.paintFaceSets(), b.paintFaceSets())
        XCTAssertEqual(a.paintFaceSets(), [[1, 3, 5]])
    }

    func testUndoRedoRestoreExactly() {
        var m = PaintModel(baseFaceCount: 2)
        let p = m.mintFace()
        let e1 = m.apply(.add, target: p, triangles: [0, 1])
        let before = m.assignments
        let e2 = m.apply(.erase, target: p, triangles: [0])
        m.undo(e2)
        XCTAssertEqual(m.assignments, before, "undo of erase restores the painted state")
        m.redo(e2)
        XCTAssertEqual(m.effectiveFaceIDs(base: [0, 0]), [0, 2])
        m.undo(e2); m.undo(e1)
        XCTAssertTrue(m.assignments.isEmpty, "undo to the start clears all paint")
    }

    func testExportRemapPacksPaintedIdsDensely() {
        // Mint two painted faces, fully erase the first: a gap opens (ids 3 gone, 4
        // live). A resolved re-import packs from baseFaceCount, so face 4 must map
        // to 3. A native id passes through unchanged.
        var m = PaintModel(baseFaceCount: 3)
        let p0 = m.mintFace(); let p1 = m.mintFace()
        m.apply(.add, target: p0, triangles: [0])
        m.apply(.add, target: p1, triangles: [1])
        m.apply(.erase, target: p0, triangles: [0])  // p0 (id 3) now empty
        XCTAssertEqual(m.activePaintedFaces, [4])
        XCTAssertEqual(m.resolvedFaceID(4), 3, "the surviving painted face packs to base+0")
        XCTAssertEqual(m.resolvedFaceID(1), 1, "a native face id is unchanged")
    }

    // MARK: - PaintHistory

    func testHistoryUndoRedoAndRedoBranchDrop() {
        var m = PaintModel(baseFaceCount: 1)
        var h = PaintHistory()
        let p = m.mintFace()
        h.record(m.apply(.add, target: p, triangles: [0]))
        h.record(m.apply(.add, target: p, triangles: [1]))
        XCTAssertTrue(h.canUndo); XCTAssertFalse(h.canRedo)
        h.undo(&m)
        XCTAssertTrue(h.canRedo)
        XCTAssertEqual(m.effectiveFaceIDs(base: [0, 0]), [1, 0])
        // A NEW stroke after an undo drops the redo branch.
        h.record(m.apply(.add, target: p, triangles: [1]))
        XCTAssertFalse(h.canRedo, "recording a new stroke clears the redo branch")
    }

    func testHistoryIgnoresNoOpEdits() {
        var m = PaintModel(baseFaceCount: 1)
        var h = PaintHistory()
        let p = m.mintFace()
        h.record(m.apply(.add, target: p, triangles: [0]))
        h.record(m.apply(.add, target: p, triangles: [0]))  // no-op
        h.undo(&m)
        XCTAssertTrue(m.assignments.isEmpty, "a no-op stroke was never a separate undo step")
    }

    // MARK: - BrushHitTest (a flat quad seen straight down −Z)

    private func quad() -> ViewerMesh {
        let verts: [Float] = [-1, -1, 0,  1, -1, 0,  1, 1, 0,  -1, 1, 0]
        let indices: [Int32] = [0, 1, 2,  0, 2, 3]
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: [7, 7])
    }
    private func topDownCamera(_ mesh: ViewerMesh) -> OrbitCamera {
        var cam = OrbitCamera(target: .zero, distance: 6, azimuth: 0, elevation: 0)
        cam.frame(mesh.bounds)
        return cam
    }

    func testBrushFollowsTheSettledModel() {
        // Two separated triangles: #0 on the left (x≈-2), #1 on the right (x≈+2), both in z=0.
        // The viewer may SETTLE-rotate the model (gravity → floor); the brush must project the
        // settled positions the user sees. A 180° spin about the view axis swaps the two on screen,
        // so a brush fixed at the RIGHT triangle's screen point must switch from #1 (un-settled) to
        // #0 (settled) — the fix for "painting the other wall".
        let verts: [Float] = [-2.2, -0.2, 0,  -1.8, -0.2, 0,  -2, 0.2, 0,
                               1.8, -0.2, 0,   2.2, -0.2, 0,   2, 0.2, 0]
        let mesh = ViewerMesh(vertices: verts, indices: [0, 1, 2, 3, 4, 5], faceIDs: [0, 1])
        let cam = topDownCamera(mesh)
        let size = CGSize(width: 100, height: 100)
        let proj = CameraProjection(camera: cam, viewportSize: size)
        let spin = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))   // 180° about the view axis

        // The right triangle's screen point when un-settled.
        let rightPoint = proj.project(SIMD3<Float>(2, -0.067, 0))!
        let unsettled = BrushHitTest.triangles(under: rightPoint, radiusPoints: 12,
                                               mesh: mesh, projection: proj)
        XCTAssertEqual(unsettled, [1], "un-settled, the right screen point hits the right triangle")

        let settled = BrushHitTest.triangles(under: rightPoint, radiusPoints: 12,
                                             mesh: mesh, projection: proj,
                                             modelRotation: spin, modelCenter: mesh.bounds.center)
        XCTAssertEqual(settled, [0],
                       "settled, the SAME screen point hits the triangle that rotated under it")
    }

    func testBrushCoversTrianglesUnderIt() {
        let mesh = quad()
        let cam = topDownCamera(mesh)
        let size = CGSize(width: 100, height: 100)
        let proj = CameraProjection(camera: cam, viewportSize: size)
        // A generous brush over the centre covers both triangles of the quad.
        let all = BrushHitTest.triangles(under: CGPoint(x: 50, y: 50), radiusPoints: 90,
                                         mesh: mesh, projection: proj)
        XCTAssertEqual(all, [0, 1])
        // A tiny brush at the centre catches only whichever centroid is nearest;
        // whatever it returns must be a subset, ascending, and deterministic.
        let a = BrushHitTest.triangles(under: CGPoint(x: 50, y: 50), radiusPoints: 4,
                                       mesh: mesh, projection: proj)
        let b = BrushHitTest.triangles(under: CGPoint(x: 50, y: 50), radiusPoints: 4,
                                       mesh: mesh, projection: proj)
        XCTAssertEqual(a, b, "the brush hit-test is deterministic")
        XCTAssertEqual(a, a.sorted())
        XCTAssertTrue(Set(a).isSubset(of: [0, 1]))
    }

    func testBrushFrontFaceCullSkipsBackSide() {
        // The quad winds +Z. Viewed from BELOW (−Z), it is back-facing, so a
        // front-facing brush paints nothing.
        let mesh = quad()
        var cam = OrbitCamera(target: .zero, distance: 6, azimuth: 0, elevation: 0)
        cam.setOrientation(azimuth: .pi, elevation: 0)  // look from −Z toward +Z
        cam.frame(mesh.bounds)
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 100, height: 100))
        let hit = BrushHitTest.triangles(under: CGPoint(x: 50, y: 50), radiusPoints: 90,
                                         mesh: mesh, projection: proj, frontFacing: true)
        XCTAssertTrue(hit.isEmpty, "front-facing brush does not paint the back of the part")
    }

    // MARK: - TapSelection pre-highlight

    func testTapPreviewResolvesFaceAndTriangles() {
        // Two faces on one plane: left (id 10) and right (id 20). The preview a tap
        // resolves must match what a commit would select, and its triangles cover
        // exactly that face.
        let verts: [Float] = [-1, -1, 0,  0, -1, 0,  0, 1, 0,  -1, 1, 0,  1, -1, 0,  1, 1, 0]
        let indices: [Int32] = [0, 1, 2,  0, 2, 3,   1, 4, 5,  1, 5, 2]
        let mesh = ViewerMesh(vertices: verts, indices: indices, faceIDs: [10, 10, 20, 20])
        let cam = topDownCamera(mesh)
        let preview = TapSelection.preview(mesh: mesh, camera: cam, aspect: 1,
                                           point: CGPoint(x: 0.75, y: 0.5))
        XCTAssertEqual(preview, [20], "tapping the right face pre-highlights exactly it")
        XCTAssertEqual(TapSelection.triangles(forFaces: preview, in: mesh), [2, 3])
    }

    // MARK: - WorkspacePaint routing (paint into the active group)

    func testStrokeAddsToActiveGroupAndMintsOnePaintedFace() {
        var paint = PaintModel(baseFaceCount: 5)
        var sel = SelectionModel()
        var hist = PaintHistory()
        WorkspacePaint.stroke(.add, triangles: [0, 1], paint: &paint,
                              selection: &sel, history: &hist)
        XCTAssertEqual(sel.groups.count, 1, "painting with no group creates one")
        let target = WorkspacePaint.paintedFace(of: sel.activeGroup!, in: paint)
        XCTAssertEqual(target, 5, "the group's painted face is the first minted id")
        XCTAssertEqual(paint.triangles(ofPaintedFace: 5), [0, 1])

        // A second stroke into the SAME active group reuses its painted face (no
        // new mint, no toggle-off).
        WorkspacePaint.stroke(.add, triangles: [2], paint: &paint,
                              selection: &sel, history: &hist)
        XCTAssertEqual(paint.triangles(ofPaintedFace: 5), [0, 1, 2])
        XCTAssertEqual(sel.groups.first?.faces, [5], "still one painted face on the group")
    }

    func testEraseEmptyingPaintedFaceRemovesItFromGroup() {
        var paint = PaintModel(baseFaceCount: 3)
        var sel = SelectionModel()
        var hist = PaintHistory()
        WorkspacePaint.stroke(.add, triangles: [0, 1], paint: &paint,
                              selection: &sel, history: &hist)
        WorkspacePaint.stroke(.erase, triangles: [0, 1], paint: &paint,
                              selection: &sel, history: &hist)
        XCTAssertTrue(paint.assignments.isEmpty, "all painted triangles erased")
        XCTAssertFalse(sel.groups.first?.faces.contains(3) ?? false,
                       "the emptied painted face leaves the group")
    }

    // MARK: - end-to-end through the real bridge (paint → sidecar → re-import)

    func testPaintedFaceSurvivesResolvedReimport() throws {
        // Copy a fixture STL to a temp dir, paint a face via the sidecar, and prove
        // a resolved re-import (the SAME path the run takes) grows exactly one new
        // pseudo-face carrying the painted triangles.
        let fixture = Self.repoRoot.appendingPathComponent(
            "core/tests/fixtures/stl/cube_10mm.stl")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("paint_e2e_\(UUID().uuidString).stl")
        try FileManager.default.copyItem(at: fixture, to: tmp)
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: tmp.path + ".faces"))
        }

        let plain = try TopOptKit.importMesh(path: tmp.path)
        XCTAssertFalse(plain.faceIDs.isEmpty, "the cube imports with pseudo-faces")
        let baseCount = Int(plain.faceCount)

        // Paint triangles 0 and 1 into one new face, persist, re-import resolved.
        try TopOptKit.writeFaceOverrides(modelPath: tmp.path, paintFaces: [[0, 1]])
        let painted = try TopOptKit.importMesh(path: tmp.path)
        XCTAssertEqual(Int(painted.faceCount), baseCount + 1,
                       "one painted pseudo-face was appended")
        let newID = Int32(baseCount)
        XCTAssertEqual(painted.faceIDs[0], newID)
        XCTAssertEqual(painted.faceIDs[1], newID)

        // Clearing the paint deletes the sidecar: the re-import is native again.
        try TopOptKit.writeFaceOverrides(modelPath: tmp.path, paintFaces: [])
        let cleared = try TopOptKit.importMesh(path: tmp.path)
        XCTAssertEqual(Int(cleared.faceCount), baseCount, "cleared paint restores the native faces")
    }
}

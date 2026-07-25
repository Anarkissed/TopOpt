// Headless macOS tests for the paint-mode UI WIRING (handoff 2026-07-25) — the layer that turns
// the shipped paint engine into a usable workspace control. Where PaintTests covers the pure
// engine (PaintModel / BrushHitTest / WorkspacePaint) and the core sidecar round-trip, these tests
// cover the app integration the UI depends on:
//
//   * a brush stroke on a `ProjectModel` adds a painted pseudo-face to the ACTIVE group and shows
//     up in the run's load case exactly like a tapped face ("painted == tapped", surfaced through
//     the real bridge re-import — the same path the run takes);
//   * painted strokes register on the ROUND-6 UndoHistory (no second undo stack): undo/redo revert
//     and restore the painted triangles, INCLUDING a stroke that only extends an already-painted
//     face (which leaves `selection` unchanged, so a selection-only snapshot would silently drop
//     it — the reason `PaintModel` is folded into `EditSnapshot`).
//
// All @MainActor because `ProjectModel` (the undo debounce + published slice) is main-actor bound.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class PaintModeUITests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    /// A `ProjectModel` backed by a REAL fixture STL copied to a temp path, so the paint sidecar +
    /// resolved re-import round-trip through the bridge exactly as the run does. Returns the project,
    /// the temp model URL (for the sidecar), and the imported mesh.
    private func makeProject() throws -> (ProjectModel, URL, ImportedMesh) {
        let fixture = Self.repoRoot.appendingPathComponent("core/tests/fixtures/stl/cube_10mm.stl")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("paintui_\(UUID().uuidString).stl")
        try FileManager.default.copyItem(at: fixture, to: tmp)
        let mesh = try TopOptKit.importMesh(path: tmp.path)
        let file = ImportedFile(name: "cube.stl", path: tmp.path,
                                triangleCount: mesh.triangleCount, faceCount: mesh.faceCount,
                                watertight: mesh.watertight, pseudoFaces: mesh.pseudoFaces)
        let p = ProjectModel(id: UUID(), name: "T", material: "PLA", process: .fdm,
                             importedFile: file, importedMesh: mesh)
        return (p, tmp, mesh)
    }

    private func cleanup(_ tmp: URL) {
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: tmp.path + ".faces"))
    }

    /// The triangle indices carrying native face `id` (ascending).
    private func triangles(ofFace id: Int32, in mesh: ImportedMesh) -> [Int] {
        mesh.faceIDs.enumerated().compactMap { $0.element == id ? $0.offset : nil }
    }

    /// Spin the main run loop past the 400 ms undo settle window so the debounced auto-commit fires
    /// — the real on-device path that turns a settled stroke into a committed undo baseline.
    private func settleUndo() {
        let done = expectation(description: "undo settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: - painted == tapped, through the project + the real bridge

    func testPaintStrokeAddsPaintedFaceToActiveGroup() throws {
        let (p, tmp, mesh) = try makeProject()
        defer { cleanup(tmp) }
        XCTAssertNotNil(p.paint, "an imported mesh seeds a paint overlay")
        let base = Int32(mesh.faceCount)

        // Paint every triangle of native face 0 — the escape a user takes when a tap over-selects.
        let tris = triangles(ofFace: 0, in: mesh)
        XCTAssertFalse(tris.isEmpty)
        p.paintStroke(.add, triangles: tris)

        // The stroke minted ONE painted pseudo-face (id == baseFaceCount) onto a fresh active group.
        let group = try XCTUnwrap(p.selection.activeGroup, "the stroke created/activated a group")
        let painted = group.faces.filter { p.paint!.isPainted($0) }
        XCTAssertEqual(painted, [base], "exactly one painted face, minted at baseFaceCount")
        XCTAssertEqual(Set(p.paint!.triangles(ofPaintedFace: base)), Set(tris.map(Int32.init)))

        // The live-highlight overlay re-labels those triangles to the painted id.
        let eff = try XCTUnwrap(p.effectivePaintFaceIDs())
        for t in tris { XCTAssertEqual(eff[t], base, "painted triangle reads as the painted face") }
    }

    func testPaintedAnchorMatchesTappedSelectionThroughReimport() throws {
        let (p, tmp, mesh) = try makeProject()
        defer { cleanup(tmp) }
        let base = mesh.faceCount

        // 1) PAINT native face 0's triangles, mark the group Anchor — the BAR flow.
        let tris = triangles(ofFace: 0, in: mesh)
        p.paintStroke(.add, triangles: tris)
        let group = try XCTUnwrap(p.selection.activeGroup)
        p.force.makeAnchor(group.id)

        // 2) The run's load case anchors the RESOLVED (dense re-import) painted id — the first
        //    painted face packs to baseFaceCount, so the app id and the run id agree here.
        let lc = p.loadCase()
        XCTAssertEqual(lc.anchorFaceIDs, [base], "the painted face reaches the run as one anchor id")

        // 3) Persist + resolved re-import (the exact path the run takes) and prove the painted anchor
        //    covers EXACTLY the triangles a TAP on native face 0 would have — painted == tapped.
        p.persistPaint()
        let reimported = try TopOptKit.importMesh(path: tmp.path)
        XCTAssertEqual(reimported.faceCount, base + 1, "one painted pseudo-face was appended")
        let paintedTris = triangles(ofFace: Int32(base), in: reimported)
        XCTAssertEqual(Set(paintedTris), Set(tris),
                       "the painted anchor's triangles equal the tapped face's triangles")
    }

    /// The BAR fixture end-to-end: on the committed WallMount_ShelfBracket.stl, enter paint mode,
    /// paint ONLY the back (wall) face, assign Anchor, and prove the painted anchor reaches the run
    /// as the same triangle set a tap would — through the real bridge re-import.
    func testShelfBracketBackFacePaintedAnchorMatchesTap() throws {
        let fixture = Self.repoRoot.appendingPathComponent(
            "core/tests/fixtures/mesh/WallMount_ShelfBracket.stl")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bracket_\(UUID().uuidString).stl")
        try FileManager.default.copyItem(at: fixture, to: tmp)
        defer { cleanup(tmp) }

        let mesh = try TopOptKit.importMesh(path: tmp.path)
        XCTAssertTrue(mesh.watertight, "the shelf bracket imports watertight")
        XCTAssertGreaterThan(mesh.faceCount, 1, "the segmenter finds distinct faces (incl. the back)")
        let file = ImportedFile(name: "WallMount_ShelfBracket.stl", path: tmp.path,
                                triangleCount: mesh.triangleCount, faceCount: mesh.faceCount,
                                watertight: mesh.watertight, pseudoFaces: mesh.pseudoFaces)
        let p = ProjectModel(id: UUID(), name: "Bracket", material: "PLA", process: .fdm,
                             importedFile: file, importedMesh: mesh)
        let base = mesh.faceCount

        // The back/wall face is the plane y == 0: paint exactly its triangles (the two facets at
        // the minimum-y bound of the L extrusion). Front-face culling is irrelevant here — we
        // resolve the triangle set directly, the same set BrushHitTest would cover face-on.
        let backTris = (0..<mesh.triangleCount).filter { t in
            (0..<3).allSatisfy { c in
                mesh.vertices[Int(mesh.indices[t * 3 + c]) * 3 + 1] == 0   // y == 0
            }
        }
        XCTAssertFalse(backTris.isEmpty, "the wall face has triangles")

        p.paintStroke(.add, triangles: backTris)
        let group = try XCTUnwrap(p.selection.activeGroup)
        p.force.makeAnchor(group.id)
        XCTAssertEqual(p.loadCase().anchorFaceIDs, [base], "the painted back face is the run's anchor")

        p.persistPaint()
        let reimported = try TopOptKit.importMesh(path: tmp.path)
        XCTAssertEqual(reimported.faceCount, base + 1)
        XCTAssertEqual(Set(triangles(ofFace: Int32(base), in: reimported)), Set(backTris),
                       "painted == tapped: the anchor covers exactly the back-face triangles")
    }

    // MARK: - undo/redo registers on the round-6 UndoHistory (no fork)

    func testUndoRedoRevertsAndRestoresAStroke() throws {
        let (p, tmp, mesh) = try makeProject()
        defer { cleanup(tmp) }
        let base = Int32(mesh.faceCount)
        let tris = triangles(ofFace: 0, in: mesh)

        p.paintStroke(.add, triangles: tris)
        XCTAssertEqual(Set(p.paint!.triangles(ofPaintedFace: base)), Set(tris.map(Int32.init)))
        XCTAssertTrue(p.canUndoNow, "a stroke enables undo immediately (round-6 in-flight flag)")

        p.performUndo()
        XCTAssertTrue(p.paint!.assignments.isEmpty, "undo reverted the painted triangles")
        XCTAssertTrue(p.selection.groups.isEmpty, "and the group the stroke created")

        p.performRedo()
        XCTAssertEqual(Set(p.paint!.triangles(ofPaintedFace: base)), Set(tris.map(Int32.init)),
                       "redo restored the exact painted triangles")
    }

    func testUndoRevertsAFaceExtendingStrokeSelectionDidNotChange() throws {
        // The reason paint is folded INTO the snapshot: a second stroke that only grows an
        // already-painted face leaves `selection` unchanged, so a selection-only undo would drop it.
        let (p, tmp, mesh) = try makeProject()
        defer { cleanup(tmp) }
        let base = Int32(mesh.faceCount)
        let tris = triangles(ofFace: 0, in: mesh)
        XCTAssertGreaterThanOrEqual(tris.count, 2, "need two triangles to paint in separate strokes")
        let t0 = tris[0], t1 = tris[1]

        // Stroke 1, then LET IT SETTLE as a committed undo baseline.
        p.paintStroke(.add, triangles: [t0])
        settleUndo()
        let selectionAfterStroke1 = p.selection

        // Stroke 2 extends the SAME painted face — selection is untouched (the painted id is already
        // on the group), so only the paint overlay differs from the baseline.
        p.paintStroke(.add, triangles: [t1])
        XCTAssertEqual(p.selection, selectionAfterStroke1, "extending a face does not change selection")
        XCTAssertEqual(Set(p.paint!.triangles(ofPaintedFace: base)), Set([t0, t1].map(Int32.init)))

        // Undo must still peel off stroke 2 — proof the stroke registered on the round-6 history via
        // the paint field, not via a selection delta.
        p.performUndo()
        XCTAssertEqual(Set(p.paint!.triangles(ofPaintedFace: base)), Set([Int32(t0)]),
                       "undo reverted the extending stroke even though selection was unchanged")
    }
}

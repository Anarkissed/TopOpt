// Headless tests for round-6 item 4 — the workspace undo/redo.
//
// Two layers:
//   * `UndoHistory` PURE stack mechanics (seed / coalesce / undo / redo / branch / depth), no
//     ProjectModel, no SwiftUI.
//   * `ProjectModel` integration: `performUndo`/`performRedo` restore the real edit slice, and the
//     debounced auto-commit folds a settled edit into one step (the on-device gesture path).

import XCTest
import Combine
import simd
import TopOptKit
@testable import TopOptFlows

final class UndoHistoryTests: XCTestCase {

    /// A snapshot tagged with a distinct face id, so equality is stable across reuse (a fresh
    /// `addGroup()` would mint a new UUID and break value-equality — build each once, reuse it).
    private func snap(_ tag: Int) -> EditSnapshot {
        var s = SelectionModel()
        if tag != 0 { _ = s.addGroup(); s.pickFace(FaceID(tag)) }
        return EditSnapshot(selection: s, force: ForceModel(), designBox: DesignBoxModel())
    }

    func testResetSeedsBaselineWithNoHistory() {
        let s0 = snap(0)
        var h = UndoHistory()
        h.reset(to: s0)
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
        XCTAssertEqual(h.baseline, s0)
    }

    func testCommitRecordsOnlyRealChanges() {
        let s0 = snap(0), s1 = snap(1)
        var h = UndoHistory()
        h.reset(to: s0)
        XCTAssertFalse(h.commit(s0), "an equal snapshot is not a step")
        XCTAssertFalse(h.canUndo)
        XCTAssertTrue(h.commit(s1), "a changed snapshot is a step")
        XCTAssertTrue(h.canUndo)
        XCTAssertFalse(h.commit(s1), "re-committing the settled state is a no-op")
    }

    func testUndoRedoRoundTrip() {
        let s0 = snap(0), s1 = snap(1), s2 = snap(2)
        var h = UndoHistory()
        h.reset(to: s0)
        h.commit(s1)
        h.commit(s2)

        XCTAssertEqual(h.undo(), s1)
        XCTAssertEqual(h.undo(), s0)
        XCTAssertNil(h.undo(), "nothing left to undo")
        XCTAssertTrue(h.canRedo)

        XCTAssertEqual(h.redo(), s1)
        XCTAssertEqual(h.redo(), s2)
        XCTAssertNil(h.redo(), "nothing left to redo")
    }

    func testNewCommitClearsRedo() {
        let s0 = snap(0), s1 = snap(1), s3 = snap(3)
        var h = UndoHistory()
        h.reset(to: s0)
        h.commit(s1)
        _ = h.undo()                       // baseline back to s0, redo has {s1}
        XCTAssertTrue(h.canRedo)
        h.commit(s3)                       // a fresh edit forks the timeline
        XCTAssertFalse(h.canRedo, "a new edit clears the redo stack")
        XCTAssertEqual(h.undo(), s0, "undo returns to the pre-fork state")
    }

    func testDepthBoundDropsOldest() {
        let s0 = snap(0), s1 = snap(1), s2 = snap(2), s3 = snap(3)
        var h = UndoHistory(depth: 2)
        h.reset(to: s0)
        h.commit(s1)
        h.commit(s2)
        h.commit(s3)                       // depth 2 → the s0 step falls off the bottom
        XCTAssertEqual(h.undo(), s2)
        XCTAssertEqual(h.undo(), s1)
        XCTAssertNil(h.undo(), "only two steps are retained")
    }

    // MARK: - ProjectModel integration

    @MainActor
    private func emptyProject() -> ProjectModel {
        ProjectModel(id: UUID(), name: "T", material: "PLA", process: .fdm,
                     importedFile: nil, importedMesh: nil)
    }

    @MainActor
    func testPerformUndoRedoRestoresSelection() {
        let p = emptyProject()
        XCTAssertFalse(p.undo.canUndo)

        _ = p.selection.addGroup()
        p.selection.pickFace(7)
        XCTAssertEqual(p.selection.groups.count, 1)

        // performUndo folds the in-flight edit into a step, then reverts it — no debounce wait.
        p.performUndo()
        XCTAssertTrue(p.selection.groups.isEmpty, "undo removed the freshly added group")
        XCTAssertTrue(p.undo.canRedo)

        p.performRedo()
        XCTAssertEqual(p.selection.groups.count, 1, "redo restored the group")
        XCTAssertEqual(p.selection.groups.first?.faces, [7])
    }

    @MainActor
    func testCanUndoNowEnablesImmediatelyOnEditBeforeDebounce() {
        let p = emptyProject()
        XCTAssertFalse(p.canUndoNow, "nothing edited yet")
        _ = p.selection.addGroup()          // an in-flight edit, not yet debounce-committed
        XCTAssertTrue(p.canUndoNow, "the header Undo enables the instant an edit lands")
        XCTAssertFalse(p.canRedoNow)
        p.performUndo()
        XCTAssertFalse(p.canUndoNow, "after undoing the only edit, nothing is undoable")
        XCTAssertTrue(p.canRedoNow)
    }

    @MainActor
    func testPerformUndoRestoresDesignBoxAndForce() {
        let p = emptyProject()
        p.force.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 1)
        p.designBox = DesignBoxModel(box: DesignBoxBounds(min: .init(0, 0, 0), max: .init(1, 1, 1)))
        XCTAssertTrue(p.force.gravityIsSet)
        XCTAssertNotNil(p.designBox.box)

        p.performUndo()
        // The undo floor is the seeded empty state (init seeded before either edit).
        XCTAssertFalse(p.force.gravityIsSet, "undo reverted the gravity edit")
        XCTAssertNil(p.designBox.box, "undo reverted the design-box edit")

        p.performRedo()
        XCTAssertTrue(p.force.gravityIsSet)
        XCTAssertNotNil(p.designBox.box)
    }

    @MainActor
    func testDebouncedAutoCommitRecordsSettledEdit() {
        let p = emptyProject()
        XCTAssertFalse(p.undo.canUndo)

        _ = p.selection.addGroup()
        p.selection.pickFace(3)

        // Let the main run loop spin past the 400 ms settle window so the auto-commit fires — the
        // real on-device path (no explicit commit call).
        let settled = expectation(description: "auto-commit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertTrue(p.undo.canUndo, "a settled edit auto-commits one undo step")

        p.performUndo()
        XCTAssertTrue(p.selection.groups.isEmpty, "undo after auto-commit reverts the edit")
    }

    @MainActor
    func testUndoBaselineIsRestoredStateNotEmpty() {
        // A restored project's undo floor must be the RESTORED slice, not the transient empty state
        // the designated init seeds before `restoring` installs the persisted slice.
        var restored = SelectionModel()
        _ = restored.addGroup(); restored.pickFace(42)
        var force = ForceModel()
        force.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 2)
        let snapshot = ProjectSnapshot(id: UUID(), name: "R", material: "PLA", process: .fdm,
                                       modelFileName: "model.stl", originalFileName: "R.stl",
                                       savedAt: Date(timeIntervalSince1970: 0),
                                       selection: restored, force: force)
        let file = ImportedFile(name: "R.stl", path: "/tmp/does-not-exist.stl",
                                triangleCount: 0, faceCount: 0, watertight: true)
        let mesh = ImportedMesh(vertices: [], indices: [], faceIDs: [],
                                vertexCount: 0, triangleCount: 0, faceCount: 0, watertight: true)
        let p = ProjectModel(restoring: snapshot, importedFile: file, importedMesh: mesh)

        XCTAssertFalse(p.undo.canUndo, "a freshly restored project has nothing to undo")
        XCTAssertEqual(p.selection.groups.count, 1)
        // An undo attempt is a no-op; the restored slice stays put.
        p.performUndo()
        XCTAssertEqual(p.selection.groups.first?.faces, [42], "the restored state is the undo floor")
    }
}

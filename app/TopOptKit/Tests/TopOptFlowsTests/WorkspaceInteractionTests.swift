// Headless tests for the M7.6 tap-routing rule (WorkspaceTap.route): a tap on the
// model re-selects a set group, grows only a pending selection, and NEVER removes
// or steals — removal is the panel trash only. The SwiftUI wiring is device QA, but
// this decision layer is pinned here.

import XCTest
@testable import TopOptFlows

final class WorkspaceInteractionTests: XCTestCase {

    private func tap(_ faceID: FaceID, _ selection: inout SelectionModel, _ force: ForceModel) {
        WorkspaceTap.route(faceID: faceID, loop: [faceID], selection: &selection, force: force)
    }

    func testTapNewFaceWithNothingActiveStartsAGroup() {
        var sel = SelectionModel()
        tap(5, &sel, ForceModel())
        XCTAssertEqual(sel.groups.count, 1)
        XCTAssertEqual(sel.groups[0].faces, [5])
        XCTAssertEqual(sel.activeGroupID, sel.groups[0].id)
    }

    func testTapNewFaceGrowsAPendingSelection() {
        var sel = SelectionModel()
        let force = ForceModel()          // the new group is pending (no role)
        tap(5, &sel, force)
        tap(6, &sel, force)
        XCTAssertEqual(sel.groups.count, 1, "a pending selection grows in place")
        XCTAssertEqual(sel.groups[0].faces, [5, 6])
    }

    func testTapNewFaceAfterCommitStartsAFreshGroup() {
        var sel = SelectionModel()
        var force = ForceModel()
        tap(5, &sel, force)               // Group A, pending
        force.makeLoad(sel.groups[0].id)  // commit A as a load
        tap(6, &sel, force)               // a new face → a NEW group, A untouched
        XCTAssertEqual(sel.groups.count, 2)
        XCTAssertEqual(sel.groups[0].faces, [5], "the committed load is not grown")
        XCTAssertEqual(sel.groups[1].faces, [6])
        XCTAssertEqual(sel.activeGroupID, sel.groups[1].id)
    }

    func testTapAnotherGroupsFaceReselectsItWithoutStealing() {
        var sel = SelectionModel()
        var force = ForceModel()
        tap(5, &sel, force); force.makeLoad(sel.groups[0].id)   // A = load {5}
        tap(6, &sel, force); force.makeAnchor(sel.groups[1].id) // B = anchor {6}, active
        let a = sel.groups[0].id
        tap(5, &sel, force)               // tap A's face while B is active
        XCTAssertEqual(sel.activeGroupID, a, "re-selects A")
        XCTAssertEqual(sel.groups[0].faces, [5], "A keeps its face — no steal")
        XCTAssertEqual(sel.groups[1].faces, [6], "B keeps its face — no steal")
        XCTAssertEqual(sel.groups.count, 2)
    }

    func testTapAFaceInTheActiveGroupChangesNothing() {
        var sel = SelectionModel()
        var force = ForceModel()
        tap(5, &sel, force); tap(6, &sel, force)   // one pending group {5,6}, active
        let id = sel.groups[0].id
        tap(5, &sel, force)               // tapping a face already in the active group
        XCTAssertEqual(sel.groups.count, 1)
        XCTAssertEqual(sel.groups[0].faces, [5, 6], "no face is toggled off / removed")
        XCTAssertEqual(sel.activeGroupID, id)
    }

    func testMultiFaceLoopNeverPullsFacesFromASetGroup() {
        var sel = SelectionModel()
        var force = ForceModel()
        tap(5, &sel, force); force.makeLoad(sel.groups[0].id)   // A = load {5}
        // A new tap whose loop also mentions A's face 5: only the fresh face 7 is added.
        WorkspaceTap.route(faceID: 7, loop: [7, 5], selection: &sel, force: force)
        XCTAssertEqual(sel.groups[0].faces, [5], "A untouched")
        XCTAssertEqual(sel.groups[1].faces, [7], "only the unowned face joins the new group")
    }
}

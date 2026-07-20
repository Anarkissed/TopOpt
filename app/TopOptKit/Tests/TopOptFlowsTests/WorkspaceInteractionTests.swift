// Headless tests for the M7.6 tap-routing rule (WorkspaceTap.route): a tap on the
// model re-selects an INACTIVE set group, grows only a pending selection, never steals,
// and — round-4 item 1 — DESELECTS a face tapped in the ACTIVE group (dropping the group
// when it empties). The SwiftUI wiring is device QA, but this decision layer is pinned here.

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

    // Item 1: tapping a face already in the ACTIVE group DESELECTS it (tap-toggle).
    func testTapAFaceInTheActiveGroupDeselectsIt() {
        var sel = SelectionModel()
        var force = ForceModel()
        tap(5, &sel, force); tap(6, &sel, force)   // one pending group {5,6}, active
        let id = sel.groups[0].id
        tap(5, &sel, force)               // tapping a face already in the active group toggles it off
        XCTAssertEqual(sel.groups.count, 1)
        XCTAssertEqual(sel.groups[0].faces, [6], "the tapped face is removed; the rest stay")
        XCTAssertEqual(sel.activeGroupID, id, "the group stays active while it still has faces")
    }

    // Item 1: deselecting the LAST face empties the group, so it is dropped (existing cleanup).
    func testTapTheOnlyFaceInTheActiveGroupDropsTheGroup() {
        var sel = SelectionModel()
        var force = ForceModel()
        tap(5, &sel, force)               // one pending group {5}, active
        tap(5, &sel, force)               // deselect the only face → group empties → dropped
        XCTAssertTrue(sel.groups.isEmpty, "an emptied active group is cleaned up")
        XCTAssertNil(sel.activeGroupID)
    }

    // Item 1: deselect is confined to the ACTIVE group — a face in another group re-selects it.
    func testTapDeselectDoesNotTouchInactiveGroups() {
        var sel = SelectionModel()
        var force = ForceModel()
        tap(5, &sel, force); force.makeAnchor(sel.groups[0].id)  // A = anchor {5}
        tap(6, &sel, force)                                      // B = pending {6}, active
        let a = sel.groups[0].id
        tap(5, &sel, force)               // A is INACTIVE → re-select it, don't deselect
        XCTAssertEqual(sel.activeGroupID, a, "an inactive group's face re-selects the group")
        XCTAssertEqual(sel.groups[0].faces, [5], "A keeps its face — deselect is active-only")
        XCTAssertEqual(sel.groups[1].faces, [6], "B untouched")
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

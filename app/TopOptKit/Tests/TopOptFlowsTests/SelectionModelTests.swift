// Headless macOS tests for the M7.5 selection-groups state machine
// (SelectionModel) — the design's Selections-panel logic ported to Swift. Pure
// value-type logic, GPU-free; the M7 /app/ verification standard is `xcodebuild
// test` on this package. They fail if create/pick/steal/rename/remove/colour were
// stubbed (see the handoff's test-honesty check).

import XCTest
import TopOptDesign
@testable import TopOptFlows

final class SelectionModelTests: XCTestCase {

    private var palette: [RGBA] { DS.Color.groupPalette }

    // MARK: creation, naming, colour

    func testEmptyInitially() {
        let m = SelectionModel()
        XCTAssertTrue(m.isEmpty)
        XCTAssertTrue(m.groups.isEmpty)
        XCTAssertNil(m.activeGroup)
        XCTAssertNil(m.activeGroupID)
    }

    func testAddGroupAutoNamesAndColours() {
        var m = SelectionModel()
        m.addGroup()
        m.addGroup()
        XCTAssertEqual(m.groups.count, 2)
        XCTAssertEqual(m.groups[0].name, "Group A")
        XCTAssertEqual(m.groups[1].name, "Group B")
        XCTAssertEqual(m.groups[0].colorIndex, 0)
        XCTAssertEqual(m.groups[1].colorIndex, 1)
        XCTAssertEqual(m.groups[0].color, palette[0])   // red
        XCTAssertEqual(m.groups[1].color, palette[1])   // blue
        // The newest group is active.
        XCTAssertEqual(m.activeGroupID, m.groups[1].id)
    }

    func testColoursCycleThroughPalette() {
        var m = SelectionModel()
        for _ in 0..<(palette.count + 1) { m.addGroup() }
        // The (palette.count+1)-th group wraps back to palette slot 0.
        XCTAssertEqual(m.groups.last?.colorIndex, 0)
        XCTAssertEqual(m.groups.last?.color, palette[0])
    }

    func testNamesWrapAfterZ() {
        var m = SelectionModel()
        for _ in 0..<27 { m.addGroup() }
        XCTAssertEqual(m.groups[25].name, "Group Z")
        XCTAssertEqual(m.groups[26].name, "Group A")   // 26 % 26 == 0 → 'A'
    }

    // MARK: picking

    func testPickWithNoActiveCreatesGroup() {
        var m = SelectionModel()
        m.pickFace(7)
        XCTAssertEqual(m.groups.count, 1)
        XCTAssertEqual(m.groups[0].name, "Group A")
        XCTAssertEqual(m.activeGroup?.faces, [7])
        XCTAssertEqual(m.activeGroup?.faceLabel, "1 face")
    }

    func testPickAddsAndDedups() {
        var m = SelectionModel()
        m.pickFaces([1, 2])
        m.pickFaces([2, 3])   // 2 already present → only 3 is new
        XCTAssertEqual(m.activeGroup?.faces, [1, 2, 3])
        XCTAssertEqual(m.activeGroup?.faceLabel, "3 faces")
    }

    func testTapAgainDeselects() {
        var m = SelectionModel()
        m.pickFaces([1, 2])
        m.pickFaces([1, 2])   // all already in active → remove them
        XCTAssertEqual(m.groups.count, 1)             // active kept even when empty
        XCTAssertEqual(m.activeGroup?.faces, [])
    }

    func testDeselectSubset() {
        var m = SelectionModel()
        m.pickFaces([1, 2, 3])
        m.pickFace(2)         // 2 is in active → removed
        XCTAssertEqual(m.activeGroup?.faces, [1, 3])
    }

    func testStealMovesFaceBetweenGroups() {
        var m = SelectionModel()
        let a = m.addGroup()
        m.pickFaces([1, 2])           // A = [1,2]
        let b = m.addGroup()          // B active
        m.pickFaces([2, 3])           // B steals 2 from A
        XCTAssertEqual(m.groups.first { $0.id == a }?.faces, [1])
        XCTAssertEqual(m.groups.first { $0.id == b }?.faces, [2, 3])
    }

    func testStealEmptyingOtherGroupRemovesIt() {
        var m = SelectionModel()
        let a = m.addGroup()
        m.pickFace(1)                 // A = [1]
        m.addGroup()                  // B active
        m.pickFace(1)                 // B steals 1 → A now empty (non-active) → dropped
        XCTAssertNil(m.groups.first { $0.id == a })
        XCTAssertEqual(m.groups.count, 1)
        XCTAssertEqual(m.activeGroup?.faces, [1])
    }

    func testPickEmptyIsNoOp() {
        var m = SelectionModel()
        m.pickFaces([])
        XCTAssertTrue(m.groups.isEmpty)
    }

    // MARK: rename / active / remove

    func testRename() {
        var m = SelectionModel()
        let id = m.addGroup()
        m.rename(id, to: "Mount")
        XCTAssertEqual(m.groups[0].name, "Mount")
        m.rename(UUID(), to: "ghost")   // unknown id → no-op
        XCTAssertEqual(m.groups[0].name, "Mount")
    }

    func testSetActive() {
        var m = SelectionModel()
        let a = m.addGroup()
        m.addGroup()                    // B becomes active
        m.setActive(a)
        XCTAssertEqual(m.activeGroupID, a)
    }

    func testRemoveActiveClearsActive() {
        var m = SelectionModel()
        let a = m.addGroup()
        m.pickFace(1)
        let b = m.addGroup()
        m.pickFace(2)
        m.remove(b)                     // remove the active group
        XCTAssertNil(m.activeGroupID)
        XCTAssertNotNil(m.groups.first { $0.id == a })
        XCTAssertEqual(m.groups.count, 1)
    }

    func testRemoveNonActiveKeepsActive() {
        var m = SelectionModel()
        let a = m.addGroup()
        m.pickFace(1)
        let b = m.addGroup()
        m.pickFace(2)
        m.remove(a)                     // remove a non-active group
        XCTAssertEqual(m.activeGroupID, b)
        XCTAssertEqual(m.groups.count, 1)
    }

    // MARK: highlight lookups

    func testColourAndGroupForFace() {
        var m = SelectionModel()
        m.pickFaces([4, 5])             // Group A (red)
        XCTAssertEqual(m.color(forFace: 4), palette[0])
        XCTAssertEqual(m.group(forFace: 5)?.id, m.groups[0].id)
        XCTAssertNil(m.color(forFace: 99))
    }

    func testFaceToGroupMap() {
        var m = SelectionModel()
        let a = m.addGroup(); m.pickFaces([1, 2])
        let b = m.addGroup(); m.pickFaces([3])
        let map = m.faceToGroup
        XCTAssertEqual(map[1], a)
        XCTAssertEqual(map[2], a)
        XCTAssertEqual(map[3], b)
        XCTAssertNil(map[9])
    }
}

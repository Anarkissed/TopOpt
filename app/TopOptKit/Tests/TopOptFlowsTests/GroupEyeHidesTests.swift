// GroupEyeHidesTests.swift — Flexible (PR #362) round 9: the eye hides a group's PRIMITIVES too.
//
// His words (2026-10-24): "When I click the eyeball the primitives of a group don't disappear.
// it's impossible to actually touch anything when it's as full as this one is."

import XCTest
@testable import TopOptFlows

final class GroupEyeHidesTests: XCTestCase {

    private struct Item: Equatable { let group: UUID; let n: Int }

    func testAHiddenGroupsItemsAreDropped() {
        let a = UUID(), b = UUID()
        var view = GroupViewState()
        view.toggleHidden(a)
        let items = [Item(group: a, n: 1), Item(group: b, n: 2), Item(group: a, n: 3)]
        XCTAssertEqual(view.showing(items) { $0.group }, [Item(group: b, n: 2)])
    }

    func testNothingHiddenKeepsEveryItemInOrder() {
        let a = UUID(), b = UUID()
        let items = [Item(group: b, n: 1), Item(group: a, n: 2)]
        XCTAssertEqual(GroupViewState().showing(items) { $0.group }, items)
    }

    func testAHiddenActiveGroupDrawsNoMoveKnobs() {
        let a = UUID()
        var view = GroupViewState()
        XCTAssertTrue(view.drawsPrimitiveKnobs(forActive: a))
        view.toggleHidden(a)
        XCTAssertFalse(view.drawsPrimitiveKnobs(forActive: a))
        XCTAssertFalse(view.drawsPrimitiveKnobs(forActive: nil))
    }

    /// Locking is not hiding: a locked, visible group keeps its primitives on screen.
    func testLockingDoesNotHide() {
        let a = UUID()
        var view = GroupViewState()
        view.toggleLocked(a)
        XCTAssertEqual(view.showing([a]) { $0 }, [a])
        XCTAssertTrue(view.drawsPrimitiveKnobs(forActive: a))
    }
}

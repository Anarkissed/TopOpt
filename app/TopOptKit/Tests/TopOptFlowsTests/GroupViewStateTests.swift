// GroupViewStateTests.swift — ★ HIDE AND LOCK (maintainer, 2026-08-18).

import XCTest
import TopOptKit
@testable import TopOptFlows

final class GroupViewStateTests: XCTestCase {

    private let a = UUID(), b = UUID()

    /// ★ NEITHER IS ON BY DEFAULT. A group you have just made is visible and
    /// editable, or the controls would be undoing a state nobody chose.
    func testNothingIsHiddenOrLockedToStartWith() {
        let s = GroupViewState()
        XCTAssertFalse(s.isHidden(a))
        XCTAssertFalse(s.isLocked(a))
        XCTAssertTrue(s.canEdit(a))
    }

    /// "One tap to lock, another to unlock" — and the same for the eye.
    func testOneTapEachWayForBoth() {
        var s = GroupViewState()
        s.toggleHidden(a); XCTAssertTrue(s.isHidden(a))
        s.toggleHidden(a); XCTAssertFalse(s.isHidden(a))
        s.toggleLocked(a); XCTAssertTrue(s.isLocked(a))
        s.toggleLocked(a); XCTAssertFalse(s.isLocked(a))
    }

    /// ★★ THE TWO ARE INDEPENDENT, DELIBERATELY. Tying them would make one
    /// control do two jobs and leave no way to say the common thing: "keep this
    /// out of my way but leave it editable", or "I can see it, I just don't
    /// want to change it".
    func testHidingDoesNotLockAndLockingDoesNotHide() {
        var s = GroupViewState()
        s.toggleHidden(a)
        XCTAssertTrue(s.canEdit(a), "★ hidden is about the PICTURE")
        s = GroupViewState()
        s.toggleLocked(a)
        XCTAssertFalse(s.isHidden(a), "★ locked is about the STATE")
    }

    /// Each group carries its own state — one lock must not lock the panel.
    func testTheStateIsPerGroup() {
        var s = GroupViewState()
        s.toggleLocked(a); s.toggleHidden(b)
        XCTAssertFalse(s.canEdit(a)); XCTAssertTrue(s.canEdit(b))
        XCTAssertTrue(s.isHidden(b)); XCTAssertFalse(s.isHidden(a))
    }

    /// ★ `canEdit` IS THE ONE QUESTION every mutation path asks — named for what
    /// it decides rather than for the flag it reads, so a call site cannot
    /// half-answer it.
    func testCanEditIsTheNegationOfLocked() {
        var s = GroupViewState()
        for _ in 0..<2 {
            XCTAssertEqual(s.canEdit(a), !s.isLocked(a))
            s.toggleLocked(a)
        }
    }

    /// ★ A DELETED GROUP'S STATE GOES WITH IT. Left behind, a stale entry would
    /// silently lock or hide whichever group later took the id.
    func testForgetClearsBoth() {
        var s = GroupViewState()
        s.toggleHidden(a); s.toggleLocked(a)
        s.forget(a)
        XCTAssertFalse(s.isHidden(a))
        XCTAssertTrue(s.canEdit(a))
    }

    /// The symbols are the ones he named: "eye or crossed eye", "lock and unlock".
    func testTheSymbolsAreTheOnesHeAskedFor() {
        XCTAssertEqual(GroupViewState.eyeSymbol(hidden: false), "eye")
        XCTAssertEqual(GroupViewState.eyeSymbol(hidden: true), "eye.slash")
        XCTAssertEqual(GroupViewState.lockSymbol(locked: false), "lock.open")
        XCTAssertEqual(GroupViewState.lockSymbol(locked: true), "lock.fill")
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: ★ THE LOCK ACTUALLY BITES, AND THE EYE ACTUALLY HIDES

final class GroupViewEnforcementTests: XCTestCase {

    private func source() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"),
            encoding: .utf8)
    }

    /// ★★ A PADLOCK THAT DOES NOT LOCK IS THE WORST CONTROL ON THE PAGE. These
    /// are the paths that change a group, and each must ask `canEdit` first.
    /// The gates live on a SwiftUI view so a value test cannot reach them — but
    /// the failure they prevent (a lock that is a picture of a lock) is exactly
    /// what a careless edit produces, and it is invisible to every other test.
    func testEveryMutationPathAsksCanEdit() throws {
        let src = try source()
        XCTAssertTrue(src.contains("stage == .topology,\n                   project.groupView.canEdit(g.id)"),
                      "★ a locked group cannot be DELETED — the largest change of all")
        XCTAssertTrue(src.contains("visible.groupPrimitives,\n                   project.groupView.canEdit(g.id)"),
                      "★ …and gains no new primitive")
        XCTAssertTrue(src.contains("project.groupView.canEdit(plane.groupID)"),
                      "★ …and casts no draggable handle: a knob that is drawn "
                      + "and refuses the drag is worse than one that is absent")
    }

    /// ★ HIDDEN REMOVES THE PICTURE AND NOTHING ELSE — the primitives, the role
    /// colours, and the protect crosshatch that rides on them.
    func testHidingSuppressesPrimitivesAndColours() throws {
        let src = try source()
        XCTAssertTrue(src.contains(".filter { !project.groupView.isHidden($0.groupID) }"),
                      "★ no primitive is drawn for a hidden group")
        XCTAssertTrue(src.contains("for g in selection.groups where !project.groupView.isHidden(g.id)"),
                      "★ and no role colour")
        XCTAssertTrue(src.contains("&& !project.groupView.isHidden(g.id) {"),
                      "★ …including the protect crosshatch, which rides on them")
    }

    /// ★ THE STRESS VIEW READS THROUGH THE GROUP COLOURS. An opaque role tint
    /// covered the field over exactly the faces that matter most — the anchored
    /// and loaded ones.
    func testTheGroupColoursGoHalfOpaqueUnderTheStressView() throws {
        let src = try source()
        XCTAssertTrue(src.contains("stressViewOn ? Self.stressUnderlayAlpha : 1"),
                      "★ the roles dim so the measurement reads through")
        XCTAssertGreaterThan(WorkspacePlaceholder.stressUnderlayAlpha, 0.3,
                             "★ below this the role colours stop being identifiable")
        XCTAssertLessThan(WorkspacePlaceholder.stressUnderlayAlpha, 0.55,
                          "★ above this the field underneath stops reading")
    }
}

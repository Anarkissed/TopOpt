import XCTest
@testable import TopOptFlows

/// ★ His iPad, 2026-10-26 (Topology > Setup, "CarriageArms repaired2 copy 5"): problems 2-5.
final class SelectionArrowRuleTests: XCTestCase {
    private let a = UUID(), b = UUID()

    /// (2)(4): nothing selected ⇒ no group's arrows or chips; a selected group ⇒ only its own.
    func testNothingSelectedShowsNoArrowsAndASelectedGroupOnlyItsOwn() {
        XCTAssertFalse(SelectionArrowRule.groupShows(a, selectedGroup: nil), "★ nothing selected: no arrows, no chips")
        XCTAssertTrue(SelectionArrowRule.groupShows(a, selectedGroup: a))
        XCTAssertFalse(SelectionArrowRule.groupShows(b, selectedGroup: a), "★ another group's arrows and load chip hide")
    }

    /// (3): a picked piece shows only its own arrows; no piece picked ⇒ the whole selected group's.
    func testAPickedPieceShowsOnlyItsOwnArrows() {
        XCTAssertTrue(SelectionArrowRule.pieceShows(group: a, piece: 7, selectedGroup: a, selectedPiece: nil))
        XCTAssertTrue(SelectionArrowRule.pieceShows(group: a, piece: 8, selectedGroup: a, selectedPiece: nil))
        XCTAssertTrue(SelectionArrowRule.pieceShows(group: a, piece: 7, selectedGroup: a, selectedPiece: 7))
        XCTAssertFalse(SelectionArrowRule.pieceShows(group: a, piece: 8, selectedGroup: a, selectedPiece: 7), "★ only the picked piece")
        XCTAssertFalse(SelectionArrowRule.pieceShows(group: a, piece: 7, selectedGroup: nil, selectedPiece: 7), "nothing selected")
    }

    /// (5): only a tap on empty space clears; the model, a control or an orbit drag never does.
    func testOnlyATapOnEmptySpaceClears() {
        XCTAssertTrue(SelectionArrowRule.tapClearsSelection(hitModel: false, hitControl: false, wasDrag: false))
        XCTAssertFalse(SelectionArrowRule.tapClearsSelection(hitModel: true, hitControl: false, wasDrag: false))
        XCTAssertFalse(SelectionArrowRule.tapClearsSelection(hitModel: false, hitControl: true, wasDrag: false))
        XCTAssertFalse(SelectionArrowRule.tapClearsSelection(hitModel: false, hitControl: false, wasDrag: true))
    }

    /// (5): clearing drops the active group and keeps every group with faces.
    func testClearingKeepsTheGroups() {
        var s = SelectionModel()
        s.pickFaces([1, 2])
        let id = s.activeGroupID
        XCTAssertNotNil(id)
        s.clearActive()
        XCTAssertNil(s.activeGroupID, "★ nothing selected after a tap on empty space")
        XCTAssertEqual(s.groups.count, 1, "the group itself stays")
    }

    /// The workspace wiring (source pins): arrows, chips and clearance handles go through the rule; a piece row picks; a 3D
    /// tap on a piece picks its row; an empty tap clears outside Flexible and Edit faces.
    func testTheWorkspaceUsesTheRule() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let src = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("for g in loadGroups where SelectionArrowRule.groupShows(g.id, selectedGroup: selection.activeGroupID) {   // ★ his iPad 10-26 (2)"), "load arrows")
        XCTAssertTrue(src.contains("SelectionArrowRule.groupShows($0.id, selectedGroup: selection.activeGroupID) }) { g in   // ★ his iPad 10-26 (2)(4)"), "load chips")
        XCTAssertTrue(src.contains("guard SelectionArrowRule.pieceShows(group: entry.groupID, piece: entry.faceID"), "clearance arrows + mm chips")
        XCTAssertTrue(src.contains("pickPiece(g.id, Int(p.id))"), "auto piece rows pick")
        XCTAssertTrue(src.contains("pickPiece(g.id, ProjectModel.manualFaceKey(mp.id))"), "manual piece rows pick")
        XCTAssertTrue(src.contains("selectedPiece = SelectionArrowRule.PieceRef(group: g.id, key: Int(faceID))"), "a 3D tap picks the row")
        XCTAssertTrue(src.contains("selection.clearActive(); selectedPiece = nil; chipsRevealedGroup = nil"), "an empty tap clears")
    }
}

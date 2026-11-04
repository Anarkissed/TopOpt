// InlineConfirmHostedTests — B2, ledger note 6 (approved design 2026-11-02, design-system §4.13, mockup #topo-delete).
//
// His words: "Delete group's confirmation … is not filleted and instead has hard corners that pass the modal's round corners."
// The ask is a card under its group's line, inside the panel's padding: its radius the panel's minus the inset (22 − 8 = 14),
// never wider than its row, the question then [Cancel] [Delete] at its right. Checked on the real page with real clicks:
// every point of the card's drawn outline must lie inside the panel's rounded outline.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class InlineConfirmHostedTests: XCTestCase {

    /// Whether `p` lies inside `r` with its corners rounded at `radius` (a small tolerance for pixel rounding).
    func inside(_ p: CGPoint, _ r: CGRect, radius: CGFloat, tol: CGFloat = 0.75) -> Bool {
        guard r.insetBy(dx: -tol, dy: -tol).contains(p) else { return false }
        let cx = min(max(p.x, r.minX + radius), r.maxX - radius), cy = min(max(p.y, r.minY + radius), r.maxY - radius)
        return hypot(p.x - cx, p.y - cy) <= radius + tol
    }

    /// Points along a rounded rectangle's outline.
    func outline(_ r: CGRect, radius: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        let corners = [(r.minX + radius, r.minY + radius, CGFloat.pi), (r.maxX - radius, r.minY + radius, CGFloat.pi * 1.5),
                       (r.maxX - radius, r.maxY - radius, 0), (r.minX + radius, r.maxY - radius, CGFloat.pi * 0.5)]
        for (cx, cy, a0) in corners {
            for k in 0...8 { let a = a0 + CGFloat(k) / 8 * .pi / 2; out.append(CGPoint(x: cx + radius * cos(a), y: cy + radius * sin(a))) }
        }
        return out
    }

    /// Topology Setup on the Structural lookalike.
    func host(_ size: CGSize) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p)
    }

    /// The LAST group: its card is the panel's lowest line, where a square tint would pass the bottom corners.
    func lastGroup(_ p: ProjectModel) throws -> SelectionGroup { try XCTUnwrap(p.selection.groups.last, "a group") }

    /// The points of the ask's drawn outline that pass the panel's rounded corners.
    func passing(_ h: AppBuildHost, _ what: String) throws -> [CGPoint] {
        // (the panel's own frame, whole: at 11" its foot runs under the window's edge — reported apart, not this test's)
        let panel = try XCTUnwrap(h.frames.all["selectionsList"], "\(what): the Selections panel")
        let shape = try h.onScreen("deleteAskShape", "\(what): the delete ask")
        let radius = DeleteConfirm.controlOldHeaderLine ? 0 : DeleteConfirm.cardCornerRadius
        return outline(shape, radius: radius).filter { !inside($0, panel, radius: DS.Radius.panel) }
    }

    func testTheDeleteAskStaysInsideThePanelsRoundedCorners() throws {
        addTeardownBlock { @MainActor in DeleteConfirm.controlOldHeaderLine = false }
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            // ★ RED CONTROL: the old ask — a square tint across the header's line; its corners pass the panel's
            DeleteConfirm.controlOldHeaderLine = true
            let (hc, pc) = try host(size)
            try hc.tap("selTrash-\(try lastGroup(pc).id.uuidString)", "\(size) control: the last group's trash")
            XCTAssertFalse(try passing(hc, "\(size) control").isEmpty, "\(size): the control — the old line's corners pass the panel's")
            DeleteConfirm.controlOldHeaderLine = false

            let (h, p) = try host(size)
            try h.tap("selTrash-\(try lastGroup(p).id.uuidString)", "\(size): the last group's trash")
            let bad = try passing(h, "\(size)")
            XCTAssertTrue(bad.isEmpty, "\(size): ★ the ask's corners pass the panel's rounded corners at \(bad.prefix(3))")
        }
    }

    /// The card: under its row, 8 pt in from its sides, the panel's radius minus that inset, never wider than the row; [Cancel]
    /// then [Delete] at its right, never under the trash; a second tap on the trash only cancels; [Delete] deletes.
    func testTheAskIsACardUnderItsRow() throws {
        XCTAssertEqual(DeleteConfirm.cardInset, 8)
        XCTAssertEqual(DeleteConfirm.cardCornerRadius, DS.Radius.panel - DeleteConfirm.cardInset, "★ its radius follows the panel's")
        let (h, p) = try host(AppBuildHost.landscape13)
        let g = try lastGroup(p)
        let trashKey = "selTrash-\(g.id.uuidString)"
        try h.tap(trashKey, "the group's trash")
        let row = try h.onScreen("selGroup-\(g.id.uuidString)", "the group's line")
        let card = try h.onScreen("deleteAskShape", "★ the ask")
        XCTAssertEqual(card.minY - row.maxY, 4, accuracy: 1, "★ the card sits under its row: row \(row), card \(card)")
        XCTAssertEqual(card.minX - row.minX, DeleteConfirm.cardInset, accuracy: 1, "★ in from the row's left: row \(row), card \(card)")
        XCTAssertEqual(row.maxX - card.maxX, DeleteConfirm.cardInset, accuracy: 1, "★ …and its right")
        XCTAssertLessThanOrEqual(card.width, row.width, "never wider than its row")
        let cancel = try h.probe("deleteCancel", "the ask's Cancel")
        let delete = try h.probe("deleteConfirm", "the ask's Delete")
        XCTAssertLessThan(cancel.maxX, delete.minX + 0.5, "[Cancel] then [Delete]")
        XCTAssertGreaterThan(cancel.minX, card.midX, "both at the card's right")
        for (f, n) in [(cancel, "Cancel"), (delete, "Delete")] {
            XCTAssertTrue(card.contains(CGPoint(x: f.midX, y: f.midY)), "\(n) is inside the card: \(f) in \(card)")
        }
        let trash = try h.onScreen(trashKey, "the trash while it asks")
        XCTAssertFalse(trash.intersects(delete), "★ [Delete] is never under the trash: \(trash) / \(delete)")

        try h.tap("deleteCancel", "Cancel")
        XCTAssertNil(h.frames.all["deleteAskShape"], "★ Cancel closes the ask")
        XCTAssertNotNil(p.selection.groups.first { $0.id == g.id }, "…and keeps the group")
        try h.tap(trashKey, "the trash")
        XCTAssertNotNil(h.frames.all["deleteAskShape"], "the trash asks")
        try h.tap(trashKey, "the trash again")
        XCTAssertNil(h.frames.all["deleteAskShape"], "★ a second tap on the trash only cancels")
        XCTAssertNotNil(p.selection.groups.first { $0.id == g.id })
        try h.tap(trashKey, "the trash")
        try h.tap("deleteConfirm", "Delete")
        XCTAssertNil(p.selection.groups.first { $0.id == g.id }, "★ [Delete] deletes the group")
    }
}
#endif

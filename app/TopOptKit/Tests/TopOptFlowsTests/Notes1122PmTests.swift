// Notes1122PmTests — ★ his iPad notes 2026-11-22 afternoon (on release 13), 362's two: the rename box (img 42-43: "There
// should only be a single textbox, with no words behind it, and the row line should expand to include the full height of the
// textbox. The icons next to the name should be hidden during the name update.") and the Skin density row (img 46: "It takes a
// number of taps to actually register a change in the skin density number").
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class Notes1122PmTests: XCTestCase {

    override func tearDown() { RenameInPlace.shared.key = nil; SelectionsLayout.shared.reset(); super.tearDown() }

    /// His A1 pad on Structural, Group 1 (the Lattice stage's own) holding three faces as Lattice (SelectionsNotes1122Tests').
    private func stage(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, SelectionGroup) {
        SelectionsLayout.shared.reset()
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" }, "his Top")
        let others = p.selection.groups.filter { $0.id != top.id }.compactMap(\.faces.first)
        for f in [try XCTUnwrap(top.faces.first)] + others.prefix(2) {
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID { p.lattice.groupRoles[g] = .include }
        }
        p.lattice.enabled = true
        h.pump(1)
        let g = try XCTUnwrap(p.latticeGroups.first, "Group 1")
        return (h, p, g)
    }

    /// ★ One box over the whole line: as tall as a touch target, inside its row (the row grows to hold it, its line under it),
    /// as wide as the line (the name's icons, the eye and the trash hidden under it), gone once the name is kept.
    /// RED CONTROL: no box before the hold.
    func testOneRenameBoxOverTheWholeLine() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, p, g) = try stage(size)
            p.latticeList.setActive(g.id)
            h.pump(1)
            let key = "lattice-sel-group-\(g.id.uuidString)"
            let before = try h.onScreen("selGroup-\(g.id.uuidString)", "\(size): the group's line")
            XCTAssertNil(h.frames.all[key + "-field"], "\(size): RED CONTROL: no box before the hold")
            RenameInPlace.shared.start(key, name: g.name)
            h.pump(1)
            let box = try h.onScreen(key + "-field", "\(size): ★ the rename box")
            let line = try h.onScreen("selGroup-\(g.id.uuidString)", "\(size): the line while renaming")
            XCTAssertGreaterThanOrEqual(box.height, RenameField.boxHeight - 0.5, "\(size): ★ a full touch-target box")
            XCTAssertTrue(line.insetBy(dx: -0.5, dy: -0.5).contains(box), "\(size): ★ the row holds the whole box: \(box) in \(line)")
            XCTAssertGreaterThanOrEqual(line.height, before.height - 0.5, "\(size): the row only grows")
            XCTAssertEqual(box.width, line.width, accuracy: 1, "\(size): ★ one box over the whole line (eye and trash hidden)")
            XCTAssertEqual(RenameInPlace.shared.draft, g.name, "the box starts with the name")
            RenameInPlace.shared.key = nil
            h.pump(1)
        }
        let src = try FlexibleSource.code("SelectionsLayout.swift")
        XCTAssertTrue(src.contains(".opacity(editing ? 0 : 1)"), "★ nothing behind the box: the row's words and icons hidden")
        XCTAssertTrue(src.contains("blue: 38 / 255, opacity: 1))"), "★ the box is opaque")
    }

    /// ★ Every segment in the Lattice settings takes the tap on its whole shape, not only on its glyph (a plain button with a
    /// clear background is hit only where it draws: the digit "4" of Skin density). The Cells │ In a part switch already did.
    func testEverySegmentTakesTheTapOnItsWholeShape() throws {
        let w = try FlexibleSource.code("LatticeSetupWizard.swift").components(separatedBy: "\n")
        var clearFills = 0
        for (i, l) in w.enumerated() where l.contains(": Color.clear))") || l.contains(".background(Capsule().fill(fill))") {
            clearFills += 1
            let next = w[(i + 1)...Swift.min(i + 3, w.count - 1)].joined(separator: "\n")
            XCTAssertTrue(next.contains(".contentShape("), "★ LatticeSetupWizard.swift:\(i + 1) a clear segment with no tap shape: \(l)")
        }
        XCTAssertGreaterThanOrEqual(clearFills, 6, "the segments are all found (Skin density's segmentButton among them)")
        let seg = try XCTUnwrap(w.firstIndex { $0.contains("private func segmentButton(") })
        XCTAssertTrue(w[seg..<(seg + 16)].joined().contains(".contentShape(Capsule())"), "★ segmentButton: Skin density, Finish, Organic…")
    }
}
#endif

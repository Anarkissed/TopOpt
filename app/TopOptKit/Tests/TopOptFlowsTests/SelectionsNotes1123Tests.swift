// SelectionsNotes1123Tests — ★ his iPad notes 2026-11-23 on the Selections panel (img 1, 2):
//   "the horizontal line below the "Zone 1" is meant to change the height, however, dragging it around does nothing UNTIL I tap
//    the corner icon with the two diagonal arrows. This makes it completely useless. Remove it."
//   "double tapping the corner icon should set it to automatically expand/contract to fill whatever is in the Selections modal
//    (as it expands or contracts when Groups/zones are opened)."
//   "When I attempted to rename a group, it didn't even show. The asset being named should be front and centre - the only one
//    forced to be visible when the full keyboard is on the screen."
// Hosted at his two iPad sizes (13" landscape, 11" portrait).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class SelectionsNotes1123Tests: XCTestCase {

    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    override func tearDown() {
        SelectionsLayout.shared.reset()
        SelectionsList.controlRenameHidden = false
        RenameInPlace.shared.key = nil
        super.tearDown()
    }

    /// His A1 pad on Structural with FOUR lattice groups (one face each, Lattice), so a short list holds some below its fold.
    private func stage(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, [SelectionGroup]) {
        SelectionsLayout.shared.reset()
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        let faces = p.selection.groups.compactMap(\.faces.first)
        for f in faces.prefix(4) {
            var l = p.latticeList
            l.clearActive()
            p.latticeList = l
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID { p.lattice.groupRoles[g] = .include }
        }
        var l = p.latticeList
        l.clearActive()
        p.latticeList = l
        p.lattice.enabled = true
        h.pump(1)
        XCTAssertGreaterThanOrEqual(p.latticeGroups.count, 3, "\(size): several lattice groups")
        return (h, p, p.latticeGroups)
    }

    /// ★ "Remove it": no grip under the list, on Lattice Setup or on Topology, at either size; the corner grip stays.
    func testTheGripUnderTheListIsGone() throws {
        for size in Self.sizes {
            let (h, _, _) = try stage(size)
            _ = try h.onScreen("selectionsList", "\(size): the Lattice Setup panel")
            XCTAssertNil(h.frames.all["selectionsGrip"], "\(size): ★ no grip under the list (Lattice Setup)")
            _ = try h.probe("selectionsCornerGrip", "\(size): the corner grip stays")
            // Topology's list
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let t = AppBuildHost(WorkspacePlaceholder(model: r.app, project: r.project), size: size, test: self)
            t.pump(3)
            _ = try t.onScreen("selectionsList", "\(size): Topology's panel")
            XCTAssertNil(t.frames.all["selectionsGrip"], "\(size): ★ no grip under the list (Topology)")
            _ = try t.probe("selectionsCornerGrip", "\(size): Topology's corner grip")
        }
        let code = try FlexibleSource.code("SelectionsList.swift")
        XCTAssertFalse(code.contains("if chosenHeight != nil, !groups.isEmpty { grip }"), "★ the grip is never drawn")
    }

    /// ★ A double tap on the corner: the panel fits what it holds, and keeps fitting as a group opens (its height follows its
    /// rows); a drag of the corner (a height of his) leaves it. The double tap is the corner's own (a synthetic double click does
    /// not reach SwiftUI's count-2 tap on the Mac host): its action is called here, then the page is read at both sizes.
    /// RED CONTROL: a height of his — the list holds it (read where it is kept: before 11-23 the page's binding held the last
    /// draw's height, so a drag drew nothing until the page redrew — "dragging it around does nothing UNTIL I tap the corner").
    func testADoubleTapOnTheCornerFitsThePanelToItsRows() throws {
        // the corner's double tap is wired to the fit, and the fit clears his height (either list's)
        let code = try FlexibleSource.code("SelectionsList.swift")
        XCTAssertTrue(code.contains(".simultaneousGesture(TapGesture(count: 2).onEnded { fitToContents() })"), "★ the double tap")
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        final class Box { var h: CGFloat? = 300 }
        let box = Box()
        let topology = SelectionsList(project: r.project, collapsed: .constant(false), picked: nil, deleteAsk: nil, pick: { _ in },
                                      askDelete: { _ in }, confirmDelete: {}, cancelDelete: {})
            .openAndResize(isOpen: { _ in false }, toggleOpen: { _ in }, height: Binding(get: { box.h }, set: { box.h = $0 }))
        XCTAssertFalse(topology.followsContents, "RED CONTROL: a height of his")
        topology.fitToContents()
        XCTAssertNil(box.h, "★ Topology's list: fitted")
        SelectionsLayout.shared.latticeHeight = 200
        let lattice = SelectionsList(project: r.project, collapsed: .constant(false), picked: nil, deleteAsk: nil, pick: { _ in },
                                     askDelete: { _ in }, confirmDelete: {}, cancelDelete: {})
            .resizable(height: Binding(get: { SelectionsLayout.shared.latticeHeight }, set: { SelectionsLayout.shared.latticeHeight = $0 }))
        XCTAssertFalse(lattice.followsContents)
        lattice.fitToContents()
        XCTAssertNil(SelectionsLayout.shared.latticeHeight, "★ Lattice Setup's list: fitted")
        XCTAssertTrue(lattice.followsContents)

        for size in Self.sizes {
            let (h, p, groups) = try stage(size)
            // his height: two lines (RED CONTROL: the rows run past it, and the list holds it at once)
            SelectionsLayout.shared.latticeHeight = SelectionsList.lineHeight * 2
            h.pump(1)
            let short = try h.onScreen("selectionsRows", "\(size): the rows' window, at his height")
            XCTAssertEqual(short.height, SelectionsList.lineHeight * 2, accuracy: 1, "\(size): RED CONTROL: his height holds at once")
            XCTAssertNotNil(h.frames.all.first { $0.key.hasPrefix("selectionsMore-") }, "\(size): RED CONTROL: rows below the fold")
            _ = try h.probe("selectionsCornerGrip", "\(size): the corner grip, a 44 pt target")
            // the double tap's fit
            SelectionsLayout.shared.latticeHeight = nil
            h.pump(1)
            let fitted = try h.onScreen("selectionsRows", "\(size): the rows' window, fitted")
            XCTAssertGreaterThan(fitted.height, short.height + SelectionsList.lineHeight - 1, "\(size): ★ every row shown")
            XCTAssertNil(h.frames.all.first { $0.key.hasPrefix("selectionsMore-") }, "\(size): ★ nothing below the fold")
            // a group opened: the panel grows with it
            let g = try XCTUnwrap(groups.first)
            p.latticeList.setActive(g.id)
            h.pump(1.2)
            let grown = try h.onScreen("selectionsRows", "\(size): the rows' window, a group open")
            if h.frames.all["selRows-\(g.id.uuidString)"] != nil {
                XCTAssertGreaterThan(grown.height, fitted.height + 1, "\(size): ★ the panel follows its rows as a group opens")
            }
            XCTAssertNil(h.frames.all.first { $0.key.hasPrefix("selectionsMore-") }, "\(size): ★ still fitted")
        }
    }

    /// ★ Renaming a group: the keyboard shortens the list to its floor; the row being renamed is brought into the list's window
    /// (its field wholly shown, nothing over it). RED CONTROL: left where it was, the field lies under the fold.
    func testTheRowBeingRenamedIsAlwaysInView() throws {
        for size in Self.sizes {
            for control in [true, false] {
                SelectionsList.controlRenameHidden = control
                let (h, _, groups) = try stage(size)
                // the keyboard's shortened list: two lines
                SelectionsLayout.shared.latticeHeight = SelectionsList.lineHeight * 2
                h.pump(1)
                let last = try XCTUnwrap(groups.last)
                let key = "lattice-sel-group-\(last.id.uuidString)"
                _ = try h.onScreen(key + "-renames", "\(size): the last group's line renames")
                RenameInPlace.shared.start(key, name: last.name)
                h.pump(1.2)
                let rows = try h.onScreen("selectionsRows", "\(size): the rows' window")
                let field = try XCTUnwrap(h.frames.all[key + "-field"], "\(size): the rename box is drawn")
                let shown = rows.insetBy(dx: -1, dy: -1).contains(field)
                if control {
                    XCTAssertFalse(shown, "\(size): RED CONTROL: the box under the fold (\(field) outside \(rows))")
                } else {
                    XCTAssertTrue(shown, "\(size): ★ the box being renamed is in view: \(field) in \(rows)")
                    XCTAssertNil(h.frames.all.first { $0.key.hasPrefix("selectionsMore-") }, "\(size): ★ nothing over it")
                    XCTAssertEqual(field.midY, rows.midY, accuracy: rows.height / 2, "\(size): ★ front and centre")
                }
                RenameInPlace.shared.key = nil
                SelectionsLayout.shared.reset()
                h.pump(0.3)
            }
        }
        SelectionsList.controlRenameHidden = false
    }
}
#endif

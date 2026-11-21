// SelectedRowHostedTests — B2, round 1 (his R2.3: "Each row in the selections modal should be obviously selected and separated
// out into its own row line", R4: "Each row should be obviously selectable and outlined like in Topology"; design-system §4.4).
//
// On the Lattice stage's Selections panel, at three sizes, with real clicks: a tapped group is outlined — a 1.5 pt accent
// outline 4 pt inside its row — and no other row is. RED control: today's look (a faint fill and the group-colour bar, no
// outline).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SelectedRowHostedTests: XCTestCase {

    func host(_ size: CGSize) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p)
    }

    func outlines(_ h: AppBuildHost) -> [String] { h.frames.all.keys.filter { $0.hasPrefix("selOutline-") }.sorted() }

    func testATappedRowIsOutlinedAndNoOtherIs() throws {
        addTeardownBlock { @MainActor in SelectionsList.controlOldSelectedLook = false }
        // ★ RED CONTROL: today's look — nothing outlines the picked row
        SelectionsList.controlOldSelectedLook = true
        let (hc, pc) = try host(AppBuildHost.landscape13)
        let gc = try XCTUnwrap(pc.selection.groups.dropFirst().first)
        try hc.tap("selName-\(gc.id.uuidString)", "the control: the second group's name")
        XCTAssertEqual(outlines(hc), [], "the control: no outline")
        SelectionsList.controlOldSelectedLook = false

        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let (h, p) = try host(size)
            let g = try XCTUnwrap(p.selection.groups.dropFirst().first)
            try h.tap("selName-\(g.id.uuidString)", "\(size): the second group's name")
            XCTAssertEqual(outlines(h), ["selOutline-\(g.id.uuidString)"], "\(size): ★ the tapped row is outlined, and only it")
            let o = try h.onScreen("selOutline-\(g.id.uuidString)", "\(size): its outline")
            let line = try h.onScreen("selGroup-\(g.id.uuidString)", "\(size): its line")
            XCTAssertEqual(o.minY, line.minY + SelectionsList.outlineInset, accuracy: 1, "\(size): 4 pt inside its row's top")
            XCTAssertEqual(o.minX, line.minX + SelectionsList.outlineInset, accuracy: 1, "\(size): 4 pt inside its row's side")
            let list = try h.onScreen("selectionsList", "\(size): the panel")
            XCTAssertTrue(list.contains(o), "\(size): inside the panel")
        }
    }
}
#endif

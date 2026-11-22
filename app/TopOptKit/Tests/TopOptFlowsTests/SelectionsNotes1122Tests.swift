// SelectionsNotes1122Tests — ★ his iPad notes 2026-11-22 on the Selections panel ("this should be done in EVERY stage, not just
// Lattice but also Topology"): no "4mm" / "4mm deep" on the rows; handles for the columns; the whole panel resizable; hold a name
// to rename it with the full keyboard; nothing cuts into the panel (captions of five words); no "Tap a face · drag to turn"
// (Lattice's and, his yes, Topology's); no "Union of 8 removed · Undo brings it back" banner (his yes).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class SelectionsNotes1122Tests: XCTestCase {

    override func tearDown() { SelectionsLayout.shared.reset(); super.tearDown() }

    /// His A1 pad on Structural, Group 1 (the Lattice stage's own) holding three faces as Lattice, open; a zone.
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

    /// ★ "get rid of the words '4mm' and '4mm deep'": a face row says its role only; a group's line says no depth; Topology's
    /// says "Protect", never "Protect 1 mm" (a load keeps its weight). RED CONTROL: the old words.
    func testNoDepthWordsOnTheRows() throws {
        XCTAssertEqual(LatticeSetupCopy.faceValue(role: .exclude, groupHasRole: true, skin: true, mm: "4 mm"), "Protect skin")
        XCTAssertEqual(LatticeSetupCopy.faceValue(role: .exclude, groupHasRole: true, skin: false, mm: "4 mm"), "No lattice")
        XCTAssertEqual(LatticeSetupCopy.faceValue(role: .include, groupHasRole: true, skin: false, mm: "4 mm"), "", "★ no depth")
        XCTAssertEqual(LatticeSetupCopy.deep(lo: 4, hi: 4), "4 mm deep", "RED CONTROL: the words that were on every group line")
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let summary = try XCTUnwrap(ws.range(of: "private func topologyGroupSummary(_ g: SelectionGroup) -> String {"))
        XCTAssertFalse(String(ws[summary.upperBound...].prefix(400)).contains("faceProtectDepthMM"), "★ Topology's line: no depth")
        let value = try XCTUnwrap(ws.range(of: "private func latticeGroupValue(_ g: SelectionGroup) -> String {"))
        XCTAssertFalse(String(ws[value.upperBound...].prefix(600)).contains("LatticeSetupCopy.deep("), "★ the group line: no depth")
        XCTAssertTrue(ws.contains(": value.isEmpty ? nil : value,"), "★ a latticed face row draws no value at all")
    }

    /// ★ Nothing cuts into the panel: its captions are five words at most (his 11-20 rule).
    func testThePanelsCaptionsAreFiveWords() {
        for c in [LatticeSetupCopy.zoneHandlesLine, LatticeSetupCopy.dragItsHandle] {
            XCTAssertLessThanOrEqual(c.split(separator: " ").count, 5, "★ \(c)")
        }
    }

    /// ★ Hold a name to rename it — a group (either list), a face, a piece or union, a zone. The model side, and the rows that
    /// carry the hold (a hold cannot be synthesised on the Mac host: each renamable row marks itself "-renames").
    func testHoldANameToRenameIt() throws {
        XCTAssertEqual(RenameCopy.accepted("  Left wall ", was: "Group 2"), "Left wall")
        XCTAssertNil(RenameCopy.accepted("   ", was: "Group 2"), "★ empty keeps the name")
        XCTAssertNil(RenameCopy.accepted("Group 2", was: "Group 2"), "unchanged: nothing to do")
        let (h, p, g) = try stage(AppBuildHost.landscape13)
        p.latticeList.setActive(g.id)
        h.pump(1)
        _ = try h.onScreen("lattice-sel-group-\(g.id.uuidString)-renames", "★ the group's line renames")
        let ref = try XCTUnwrap(p.latticeSelectableRefs(g).first { if case .face = $0 { return true }; return false })
        _ = try h.onScreen("latticeFace-\(ref.key)-renames", "★ a face row renames")
        guard case let .face(_, f) = ref else { return XCTFail("a face row") }
        let before = p.faceName(f)
        p.renameSelectable(ref, to: "Left wall")
        XCTAssertEqual(p.faceName(f), "Left wall", "★ the face keeps the name he gave it (both stages read it)")
        XCTAssertNotEqual(before, "Left wall")
        // kept with the part's regions, and older bytes still read
        let data = try JSONEncoder().encode(p.faceRegions)
        XCTAssertEqual(try JSONDecoder().decode(FaceRegionModel.self, from: data).faceNames[Int32(f)], "Left wall", "★ saved")
        XCTAssertTrue(try JSONDecoder().decode(FaceRegionModel.self, from: Data(#"{"regions": [], "nextID": 100}"#.utf8)).faceNames.isEmpty,
                      "an older project reads with no names")
        // a lattice group renamed in its own list (Topology's twin, if any, keeps its name)
        var l = p.latticeList
        l.rename(g.id, to: "Ribs")
        p.latticeList = l
        XCTAssertEqual(p.latticeGroups.first { $0.id == g.id }?.name, "Ribs")
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("rename: { project.renameSelectable(ref, to: $0) }"), "★ a face row's hold renames the face")
        XCTAssertTrue(ws.contains("rename: { n in var l = project.latticeList; l.rename(z.id, to: n); project.latticeList = l }"),
                      "★ a zone's hold renames the zone")
    }

    /// ★ "a way to expand/shrink the width/height of the entire Selections modal" and "handles to expand or shrink the
    /// different columns": the corner grip and the column handle are on the panel, the width follows his drag (clamped) and is
    /// remembered. RED CONTROL: untouched, the panel is the 348 pt it always was.
    func testThePanelAndItsColumnsResize() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "SelectionsNotes1122-\(UUID().uuidString)"))
        let a = SelectionsLayout(defaults: d)
        XCTAssertEqual(a.extraWidth, 0, "RED CONTROL: untouched, as wide as before")
        a.extraWidth = SelectionsLayout.clampExtra(900)
        a.valueWidth = SelectionsLayout.clampValue(5)
        let b = SelectionsLayout(defaults: d)
        XCTAssertEqual(b.extraWidth, SelectionsLayout.maxExtra, "★ remembered, clamped")
        XCTAssertEqual(b.valueWidth, SelectionsLayout.valueRange.lowerBound, "★ the column remembered, clamped")
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, p, g) = try stage(size)
            p.latticeList.setActive(g.id)
            h.pump(1)
            let panel = try h.onScreen("selectionsList", "\(size): the panel")
            XCTAssertEqual(panel.width, PageChrome.panelWidth, accuracy: 0.5, "\(size): RED CONTROL: 348 pt untouched")
            let corner = try h.probe("selectionsCornerGrip", "\(size): ★ the corner grip, a 44 pt target")
            XCTAssertEqual(corner.maxX, panel.maxX, accuracy: 1, "\(size): ★ in the panel's right corner")
            XCTAssertEqual(corner.maxY, panel.maxY, accuracy: 1, "\(size): ★ at its foot")
            _ = try h.probe("selectionsColumnHandle", "\(size): ★ the column handle, a 44 pt target")
            SelectionsLayout.shared.extraWidth = 120
            h.pump(1)
            let wide = try h.onScreen("selectionsList", "\(size): the panel, widened")
            XCTAssertEqual(wide.width, PageChrome.panelWidth + 120, accuracy: 0.5, "\(size): ★ as wide as he dragged it")
            SelectionsLayout.shared.reset()
            h.pump(1)
        }
    }

    /// ★ No "Tap a face · drag to turn" on Topology (his yes 11-22) and no "… removed · Undo brings it back" banner.
    func testNoHintAndNoRemovedBanner() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertFalse(ws.contains("return \"Tap a face \\u{00B7} drag to turn\""), "★ no Topology hint")
        XCTAssertFalse(ws.contains("model.toast = LatticeSetupCopy.removed("), "★ no removed banner")
    }
}
#endif

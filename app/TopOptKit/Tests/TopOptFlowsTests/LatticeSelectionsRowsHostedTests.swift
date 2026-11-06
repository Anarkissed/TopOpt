// LatticeSelectionsRowsHostedTests — B6 s1b (his go 11-05; ledger notes 22, 25a, 28, R2.3 / R4, design-system §4.3 / §4.4; mockup
// #lat-setup, #lat-setup-face-row, #lat-face-prism). His note 28: "each face should be selectable like each bore/prism has its
// own row in Topology and should not be as small and as difficult to see as in the lattice section." Lattice Setup's
// Selections is the §4.3 panel: a "Faces N · + New group" section; each lattice group one 48 pt line ("12–31 mm deep");
// an open group lists ONE full-size row per face (its name, "also in Top" when a Topology group holds it too — note 22 —
// its depth, its trash), then the group's Role [Lattice │ No lattice]; a tapped face row opens with its depth (tap to type,
// drag) and its own role.
//
// RED before (saved: scratchpad b2red/LatticeRows_build.txt): the open group drew today's tall row (Pending…, the Keep clear
// and Protect affixes, the lock, the All / Some pill, the grams) and its faces as 10 pt chips "Face 104 · Lattice Solid Off".
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LatticeSelectionsRowsHostedTests: XCTestCase {

    /// His A1 pad on Structural; Group 1 (the Lattice stage's own) holds three faces — his Top's, and two of other Topology
    /// groups — as Lattice, open.
    func stage(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, SelectionGroup) {
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
        XCTAssertEqual(g.faces.count, 3, "premise: three faces")
        return (h, p, g)
    }

    /// ★ The Faces section ("+ New group", 44 pt), the group's one 48 pt line and its depth summary.
    func testTheFacesSectionAndTheGroupLine() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, p, g) = try stage(size)
            let section = try h.onScreen("latticeFacesSection", "\(size): ★ the FACES section")
            let add = try h.probe("latticeFacesSectionAction", "\(size): ★ + New group, a 44 pt target")
            let line = try h.onScreen("selGroup-\(g.id.uuidString)", "\(size): Group 1's line")
            XCTAssertLessThan(section.minY, line.minY, "\(size): the section heads the groups")
            XCTAssertEqual(line.height, 48, accuracy: 0.5, "\(size): ★ U3 — a group line is 48 pt")
            XCTAssertGreaterThan(add.minX, line.midX, "\(size): + New group at the section's right")
            // + New group: the next tap starts a new group (nothing active)
            try h.tap("latticeFacesSectionAction", "+ New group")
            XCTAssertNil(p.latticeList.activeGroupID, "\(size): ★ + New group — the next tap starts Group 2")
        }
        XCTAssertEqual(LatticeSetupCopy.deep(lo: 12, hi: 31), "12\u{2013}31 mm deep")
        XCTAssertEqual(LatticeSetupCopy.deep(lo: 31, hi: 31), "31 mm deep")
    }

    /// ★ Note 28: the open group lists one full-size row per face, with the "also in" tag (note 22), its depth and trash; then
    /// the group's Role row. Today's tall row is gone.
    func testAnOpenGroupListsOneFullSizeRowPerFace() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, p, g) = try stage(size)
            p.latticeList.setActive(g.id)
            h.pump(1)
            let panel = try h.onScreen("selectionsList", "\(size): the panel")
            XCTAssertEqual(panel.width, PageChrome.panelWidth, accuracy: 0.5, "\(size): U2 — one panel width")
            let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
            for ref in p.latticeSelectableRefs(g) {
                let row = try h.onScreen("latticeFace-\(ref.key)", "\(size): ★ \(ref.key)'s own row")
                XCTAssertEqual(row.height, 48, accuracy: 0.5, "\(size): ★ U3 — a face row is 48 pt")
                XCTAssertGreaterThanOrEqual(row.minX, panel.minX - 0.5); XCTAssertLessThanOrEqual(row.maxX, panel.maxX + 0.5)
                _ = try h.probe("latticeFaceTrash-\(ref.key)", "\(size): its trash, a 44 pt target")
                if case let .face(_, f) = ref, top.faces.contains(f) {
                    _ = try h.onScreen("latticeFace-\(ref.key)-tag", "\(size): ★ note 22 — also in Top")
                }
            }
            _ = try h.onScreen("latticeRoleRow-\(g.id.uuidString)", "\(size): ★ the group's Role row")
        }
        XCTAssertEqual(LatticeSetupCopy.alsoIn("Top"), "also in Top")
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("rows: { g in AnyView(latticeGroupRows(g)) }"), "★ the open group's rows are the new face rows")
    }

    /// ★ A tapped face row opens a little: its depth becomes a number field (tap to type, drag), and its own role.
    func testATappedFaceRowOpensWithItsDepthAndItsRole() throws {
        let (h, p, g) = try stage(AppBuildHost.landscape13)
        p.latticeList.setActive(g.id)
        h.pump(1)
        let ref = try XCTUnwrap(p.latticeSelectableRefs(g).first)
        XCTAssertNil(h.frames.all["numberField-latticeFaceDepth-\(ref.key)"], "closed: the depth is the row's value")
        try h.tap("latticeFace-\(ref.key)", "the face's row", settle: 1)
        _ = try h.onScreen("numberField-latticeFaceDepth-\(ref.key)", "★ its depth, the number field (tap to type, drag)")
        let role = try h.onScreen("latticeFaceRole-\(ref.key)", "★ its own role")
        XCTAssertEqual(p.latticeSelectableRole(ref, in: g.id), .include, "premise: Lattice")
        h.click(CGPoint(x: role.maxX - role.width / 4, y: role.midY), settle: 1)   // No lattice, the second of two
        XCTAssertEqual(p.latticeSelectableRole(ref, in: g.id), .exclude, "★ No lattice, this face only")
        for other in p.latticeSelectableRefs(g) where other != ref {
            XCTAssertEqual(p.latticeSelectableRole(other, in: g.id), .include, "★ setting one face never moves another")
        }
    }

    /// ★ The trash takes the face out of the lattice group (never out of its Topology group); Undo brings it back.
    func testTheTrashRemovesTheFaceAndUndoBringsItBack() throws {
        let (h, p, g) = try stage(AppBuildHost.landscape13)
        p.latticeList.setActive(g.id)
        h.pump(1)
        let ref = try XCTUnwrap(p.latticeSelectableRefs(g).first)
        guard case let .face(_, f) = ref else { return XCTFail("a face") }
        let topology = p.selection.groups.filter { $0.faces.contains(f) }.map(\.id)
        try h.tap("latticeFaceTrash-\(ref.key)", "its trash", settle: 1)
        XCTAssertFalse(p.latticeGroups.first { $0.id == g.id }?.faces.contains(f) ?? true, "★ out of Group 1")
        XCTAssertEqual(p.selection.groups.filter { $0.faces.contains(f) }.map(\.id), topology, "★ still in its Topology group")
        p.performUndo()
        h.pump(1)
        XCTAssertTrue(p.latticeGroups.first { $0.id == g.id }?.faces.contains(f) ?? false, "★ Undo brings it back")
    }

    /// #362's seam (11-05 19:12Z): the Lattice page's tabs are the Lattice stage's own groups.
    func testTheLatticePagesTabsAreTheStagesOwnGroups() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let r = try XCTUnwrap(ws.range(of: "var latticeRegionTabNames: [String] {"))
        // ★ B7 (E3, #362 11-06): the tabs and each tab's own grade read ONE list, ProjectModel.latticeAreaGroups
        XCTAssertTrue(String(ws[r.upperBound...].prefix(200)).contains("project.latticeAreaGroups"), "★ the areas' one list")
        let list = try FlexibleSource.code("LatticeList.swift")
        let a = try XCTUnwrap(list.range(of: "public var latticeAreaGroups: [SelectionGroup] {"))
        XCTAssertTrue(String(list[a.upperBound...].prefix(200)).contains("latticeGroups.filter"), "★ the stage's own groups")
    }
}
#endif

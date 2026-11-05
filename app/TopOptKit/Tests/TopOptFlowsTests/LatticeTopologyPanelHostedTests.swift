// LatticeTopologyPanelHostedTests — B6 s2a (his go 11-05; ledger notes 19, 23, 23a, 23b, R2.1; design-system §4.3; mockup #lat-setup,
// #lat-setup-topo-open). His words: "a 'Topology' selections modal on TOP of the Selections modal" (23a), "switches next to each
// topology group to include them into this optimization/lattice structure" (23b), and R2.1: "opening Topology selections
// automatically closes the lattice one and vice-versa". On Lattice Setup the Topology panel sits on top, closed by default;
// open, it lists the Topology scenarios and groups with an include switch each, and Selections folds to its pill. A switch
// is stored with the lattice; the job stays as today until the engine takes the include list (E2, his 11-03 rule: a plain
// line says so).
//
// RED before (saved: scratchpad b2red/LatticeTopologyPanel_build.txt): Lattice Setup had no Topology panel.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LatticeTopologyPanelHostedTests: XCTestCase {

    /// ParityTopologyShots' pad (three scenarios, two anchors, the 51 kg push, Protect) on Structural, a lattice group made.
    func stage(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, AppModel) {
        let (h, p, app) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        if let f = p.selection.groups.first?.faces.first {
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID { p.lattice.groupRoles[g] = .include }
        }
        p.lattice.enabled = true   // as Save on the Lattice page leaves it: the lattice run can be asked for
        h.pump(1)
        return (h, p, app)
    }

    /// ★ 23a + R2.1: the Topology panel on top, closed; opening it folds Selections to its pill; opening Selections closes it.
    func testTheTopologyPanelSitsOnTopAndTheTwoAreAnAccordion() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, _, _) = try stage(size)
            let header = try h.onScreen("latticeTopologyPanel", "\(size): ★ the Topology panel")
            let sel = try h.onScreen("selectionsList", "\(size): Selections")
            XCTAssertEqual(header.height, DSParts.headerHeight, accuracy: 1, "\(size): ★ closed by default: its header alone")
            XCTAssertEqual(header.width, PageChrome.panelWidth, accuracy: 0.5, "\(size): U2 — one panel width")
            XCTAssertEqual(header.minX, sel.minX, accuracy: 0.5, "\(size): one left edge")
            XCTAssertLessThan(header.maxY, sel.minY, "\(size): ★ on top of Selections")
            XCTAssertNil(h.frames.all["latticeTopologyLine"], "\(size): closed: no rows")

            try h.tap("latticeTopologyPanelHeader", "\(size): Topology's header", settle: 1)
            let open = try h.onScreen("latticeTopologyPanel", "\(size): ★ open")
            XCTAssertGreaterThan(open.height, 3 * DSParts.rowHeight, "\(size): its rows")
            _ = try h.onScreen("latticeTopologyLine", "\(size): ★ \"Switched-off groups are left out of this lattice.\"")
            let pill = try h.onScreen("selectionsList", "\(size): ★ Selections, folded to its pill")
            XCTAssertLessThan(pill.height, 60, "\(size): ★ R2.1 — one open at a time")
            XCTAssertGreaterThan(pill.minY, open.maxY, "\(size): the pill below the open panel")

            try h.tap("selHeader", "\(size): Selections' pill", settle: 1)
            XCTAssertEqual(try h.onScreen("latticeTopologyPanel", "\(size): Topology").height, DSParts.headerHeight, accuracy: 1,
                           "\(size): ★ opening Selections folds Topology")
            XCTAssertGreaterThan(try h.onScreen("selectionsList", "\(size): Selections, open").height, 60)
        }
        XCTAssertEqual(LatticeSetupCopy.includeLine, "Switched-off groups are left out of this lattice.")
    }

    /// ★ 23b: every scenario folder and group has an include switch, on; off is stored with the lattice, the job stays as
    /// today, and one plain line says it waits on the engine.
    func testEachFolderAndGroupHasAnIncludeSwitchStoredWithTheLattice() throws {
        let (h, p, app) = try stage(AppBuildHost.landscape13)
        try h.tap("latticeTopologyPanelHeader", "Topology's header", settle: 1)
        let held = try XCTUnwrap(p.force.scenarioList.first { $0.name == "Held by right plate" }, "the fixture's third scenario")
        for s in p.force.scenarioList {
            _ = try h.probe("latticeInclude-\(s.id.uuidString)", "★ \(s.name)'s include switch")
        }
        let loose = p.selection.groups.filter { g in !p.force.scenarioList.contains { p.force.group(g.id, isIn: $0.id) } }
        for g in loose { _ = try h.probe("latticeInclude-\(g.id.uuidString)", "★ \(g.name)'s include switch") }
        XCTAssertTrue(p.lattice.topologyExcluded.isEmpty, "every switch on")
        XCTAssertNil(h.frames.all["latticeIncludeWaits"], "all on: nothing to say")
        let before = try XCTUnwrap(app.makeLatticeRunRequest())
        try h.tap("latticeInclude-\(held.id.uuidString)", "★ Held by right plate's switch", settle: 1)
        XCTAssertEqual(p.lattice.topologyExcluded, [held.id], "★ stored with the lattice")
        _ = try h.onScreen("latticeIncludeWaits", "★ the plain line: it waits on the engine")
        let after = try XCTUnwrap(app.makeLatticeRunRequest())
        XCTAssertEqual(after, before, "★ the job stays as today until the engine takes the include list")
        XCTAssertEqual(LatticeSetupCopy.includeWaits, "The run still uses them until the engine update")
    }

    /// The switches are saved with the lattice, and a project saved before them reads as all on (and writes the same bytes).
    func testTheSwitchesSaveAndAnOlderProjectReadsAllOn() throws {
        var s = LatticeSettings()
        let old = try JSONEncoder().encode(s)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("topologyExcluded"), "★ all on: the key is not written")
        XCTAssertEqual(try JSONDecoder().decode(LatticeSettings.self, from: old).topologyExcluded, [])
        let id = UUID()
        s.topologyExcluded = [id]
        XCTAssertEqual(try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(s)).topologyExcluded, [id])
    }
}
#endif

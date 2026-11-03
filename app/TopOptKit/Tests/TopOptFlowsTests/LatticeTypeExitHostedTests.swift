// LatticeTypeExitHostedTests — B3 (his answers on the lattice type, 11-03, relayed by #362 at 20:22Z).
//
// (a) "there's no way to select 'No lattice' in the type picker. And no other way to just delete the Lattice stage entirely …
// add a 'Exit without selection' button … Also, a way to delete the Lattice stage entirely straight from the page."
//   * the selector's "Exit without selection" leaves with no type and no lattice, back to Topology (no type is picked for him);
//   * the ● menu's "Delete lattice stage" asks with the clear-all confirm (design-system §4.29: yes apart from no), then clears
//     the lattice as one undo step and lands on Topology, where its one Undo puts it back.
// (b) "Change lattice type…" with nothing latticed just switches: the selector asks, no card.
// RED before B3 (saved: scratchpad b2red/LatticeTypeExit.txt): the selector had no way out, the menu no Delete, and Change type
// asked duplicate-or-lose-all with nothing latticed.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeTypeExitHostedTests: XCTestCase {

    /// His A1 pad on Topology, with no group left pending; `facePrism`: his Top latticed (a region), or nothing latticed.
    func page(facePrism: Bool, type: LatticeStageMode?, size: CGSize = AppBuildHost.landscape13) throws
        -> (AppBuildHost, ProjectModel, AppModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: facePrism)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        if let type { p.lattice.chooseLatticeType(type) }
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p, r.app)
    }

    func onTopology(_ h: AppBuildHost) -> Bool { h.frames.all["optimizeSplit"] != nil }

    func testTheSelectorsExitLeavesWithNoLatticeBackToTopology() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let (h, p, app) = try page(facePrism: false, type: nil, size: size)
            try h.pickFromMenu("capsuleMenu", "Lattice", what: "\(size): Topology's ● menu")
            _ = try h.onScreen("latticeModeModal", "\(size): the type selector")
            XCTAssertFalse(onTopology(h))
            let exit = try h.probe("latticeModeExit", "\(size): ★ Exit without selection", minHit: 44)
            h.click(CGPoint(x: exit.midX, y: exit.midY))
            XCTAssertNil(h.frames.all["latticeModeModal"], "\(size): ★ the selector is gone")
            XCTAssertTrue(onTopology(h), "\(size): ★ back on Topology")
            XCTAssertNil(p.lattice.stageMode, "\(size): ★ no type is picked for him (LS-19)")
            XCTAssertFalse(p.lattice.enabled, "\(size): ★ no lattice")
            XCTAssertNil(try XCTUnwrap(app.makeRunRequest()).lattice, "\(size): ★ no run carries a lattice")
        }
    }

    func testDeleteLatticeStageAsksApartThenClearsAsOneUndo() throws {
        let (h, p, _) = try page(facePrism: true, type: .structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "Topology's ● menu")
        XCTAssertFalse(onTopology(h), "on the Lattice stage")
        let offered = try h.pickFromMenu("capsuleMenu", LatticeStageMenu.deleteStageTitle, what: "the Lattice stage's ● menu")
        XCTAssertTrue(offered.contains(LatticeStageMenu.deleteStageTitle), "★ the menu offers it: \(offered)")
        // ★ the clear-all confirm: yes apart from no (§4.29)
        let keep = try h.probe("clearAllKeep", "Keep it", minHit: 44)
        let yes = try h.probe("clearAllYes", "Delete", minHit: 44)
        XCTAssertGreaterThan(yes.minX - keep.maxX, 100, "★ the yes is far from the no")
        XCTAssertEqual(p.lattice.stageMode, .structural, "nothing goes until he says yes")
        h.click(CGPoint(x: keep.midX, y: keep.midY))
        XCTAssertNil(h.frames.all["clearAllYes"]); XCTAssertEqual(p.lattice.stageMode, .structural, "Keep it keeps it")

        try h.pickFromMenu("capsuleMenu", LatticeStageMenu.deleteStageTitle, what: "the ● menu again")
        let yes2 = try h.onScreen("clearAllYes", "Delete")
        h.click(CGPoint(x: yes2.midX, y: yes2.midY))
        XCTAssertTrue(onTopology(h), "★ it lands on Topology")
        XCTAssertNil(p.lattice.stageMode, "★ the lattice stage is gone")
        XCTAssertFalse(p.lattice.enabled, "★ the lattice is off")
        XCTAssertTrue(p.lattice.groupRoles.isEmpty, "★ its regions go with it")
        // ★ one Undo puts it back
        let undo = try h.probe("latticeStageUndo", "the one Undo", minHit: 44)
        h.click(CGPoint(x: undo.midX, y: undo.midY))
        XCTAssertEqual(p.lattice.stageMode, .structural, "★ Undo brings the Structural lattice back")
        XCTAssertTrue(p.lattice.enabled)
        XCTAssertFalse(p.lattice.groupRoles.isEmpty)
        XCTAssertNil(h.frames.all["latticeStageUndo"], "the Undo is spent")
    }

    func testChangeTypeWithNothingLatticedJustSwitches() throws {
        // nothing latticed: no card, the selector asks
        let (h, p, _) = try page(facePrism: false, type: .aesthetic)
        try h.pickFromMenu("capsuleMenu", "Aesthetic", what: "Topology's ● menu")
        try h.pickFromMenu("capsuleMenu", LatticeStageMenu.changeTypeTitle, what: "the Lattice stage's ● menu")
        XCTAssertNil(h.frames.all["changeTypeCard"], "★ nothing latticed: no card")
        XCTAssertNil(p.lattice.stageMode, "★ the type clears")
        _ = try h.onScreen("latticeModeModal", "★ the selector asks for the new type")

        // a region latticed: the card asks, as before
        let (h2, p2, _) = try page(facePrism: true, type: .aesthetic)
        try h2.pickFromMenu("capsuleMenu", "Aesthetic", what: "Topology's ● menu")
        try h2.pickFromMenu("capsuleMenu", LatticeStageMenu.changeTypeTitle, what: "the Lattice stage's ● menu")
        _ = try h2.onScreen("changeTypeCard", "★ with a region, the card asks")
        XCTAssertEqual(p2.lattice.stageMode, .aesthetic, "nothing changes until he chooses")
    }
}
#endif

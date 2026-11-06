// LatticeRolePickerHostedTests — B6 s2b (his go 11-05; ledger notes 23c, 24, 27; design-system §4.16; mockup #lat-setup-face-pick,
// #lat-setup-face-pick-topo). His words: "When I select a face here, a modal doesn't come up asking what kind of face it will be
// … It should be like the one in Topology but with a 'Lattice' option" (24), "When selecting a face it should say '(No) Lattice
// | Protect skin'" (27), and 23c: "When the Topology selections is closed … any tap on a face should create/update a group in
// the 'Lattice' selections modal." Closed: a tap that starts a lattice group with no role shows the picker at the face — the
// join "+ Add to Group 1 as lattice" when there is a group to join, and Lattice · No lattice · Protect skin. Open: taps go to
// Topology's groups, with Topology's own picker (Anchor · Load · Keep clear · Protect).
//
// RED before (saved: scratchpad b2red/LatticeRolePicker_build.txt): a tap made a role-less lattice group and nothing asked.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LatticeRolePickerHostedTests: XCTestCase {

    func stage(_ size: CGSize = AppBuildHost.landscape13) throws -> (AppBuildHost, ProjectModel) {
        let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        return (h, p)
    }

    /// The tap the 3D view hands the stage (a synthesised click cannot reach the Metal view's pick; FaceInTwoGroupsHostedTests
    /// pins that handlePick goes through `latticeStageTap`).
    func tap(_ p: ProjectModel, _ f: FaceID) { _ = p.latticeStageTap(face: f, loop: [f]) }

    /// ★ 24 / 27: a tap that starts a lattice group with no role asks — Lattice · No lattice · Protect skin; a choice sets it.
    func testATapThatStartsAGroupAsksForItsRole() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, p) = try stage(size)
            let f = try XCTUnwrap(p.selection.groups.first?.faces.first)
            tap(p, f)
            h.pump(1)
            let g = try XCTUnwrap(p.latticeList.activeGroup, "\(size): Group 1, active")
            XCTAssertNil(p.lattice.groupRoles[g.id], "premise: no role yet")
            let picker = try h.onScreen("latticeRolePicker", "\(size): ★ the picker at the face")
            let panel = try h.onScreen("selectionsList", "\(size): Selections")
            XCTAssertGreaterThan(picker.minX, panel.maxX, "\(size): ★ §4.16 — never under a panel")
            for k in ["lattice", "noLattice", "skin"] { _ = try h.probe("latticeRole-\(k)", "\(size): ★ \(k), a 44 pt target") }
            XCTAssertNil(h.frames.all["chipJoin"], "\(size): nothing to join yet")
            try h.tap("latticeRole-lattice", "\(size): Lattice", settle: 1)
            XCTAssertEqual(p.lattice.groupRoles[g.id], .include, "\(size): ★ Lattice")
            XCTAssertNil(h.frames.all["latticeRolePicker"], "\(size): ★ answered: the picker goes")
        }
        XCTAssertEqual([LatticeSetupCopy.lattice, LatticeSetupCopy.noLattice, LatticeSetupCopy.protectSkin],
                       ["Lattice", "No lattice", "Protect skin"])
    }

    /// ★ The join: with Group 1 set, a tap that starts Group 2 offers "+ Add to Group 1 as lattice"; it moves the face there.
    func testTheJoinAddsTheFaceToTheLastGroup() throws {
        let (h, p) = try stage()
        let faces = p.selection.groups.compactMap(\.faces.first)
        tap(p, faces[0])
        let g1 = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g1] = .include
        p.latticeList.clearActive()   // + New group
        tap(p, faces[1])
        h.pump(1)
        let g2 = try XCTUnwrap(p.latticeList.activeGroupID)
        XCTAssertNotEqual(g1, g2, "premise: a new group")
        _ = try h.onScreen("chipJoin", "★ + Add to Group 1 as lattice")
        try h.tap("chipJoin", "the join", settle: 1)
        XCTAssertTrue(p.latticeGroups.first { $0.id == g1 }?.faces.contains(faces[1]) ?? false, "★ the face joins Group 1")
        XCTAssertNil(p.latticeGroups.first { $0.id == g2 }, "★ the empty new group goes")
    }

    /// ★ Protect skin is stored; until the engine has a per-region skin (E2.4) the run keeps the face solid, and a plain line
    /// says so.
    func testProtectSkinIsStoredAndSaysItRunsAsNoLattice() throws {
        let (h, p) = try stage()
        let f = try XCTUnwrap(p.selection.groups.first?.faces.first)
        tap(p, f)
        h.pump(1)
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        try h.tap("latticeRole-skin", "Protect skin", settle: 1)
        XCTAssertTrue(p.lattice.skinGroups.contains(g), "★ stored")
        XCTAssertEqual(p.lattice.groupRoles[g], .exclude, "★ the run keeps it solid (No lattice) until E2.4")
        p.latticeList.setActive(g)
        h.pump(1)
        _ = try h.onScreen("latticeSkinWaits-\(g.uuidString)", "★ the plain line on its Role row")
        XCTAssertEqual(LatticeSetupCopy.skinWaits, "Runs as No lattice until the engine update")
    }

    /// ★ 23c: with the Topology panel open, a tap goes to Topology's groups and Topology's own picker shows; closed, it does
    /// not.
    func testWithTopologyOpenTapsGoToTopology() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let pick = try XCTUnwrap(ws.range(of: "private func handlePick(_ faceID: FaceID) {"))
        XCTAssertTrue(String(ws[pick.lowerBound...].prefix(3_400)).contains("if stage == .lattice, !latticeTopologyOpen {"),
                      "★ only with Topology closed does the Lattice stage's tap grow the lattice list")
        let (h, p) = try stage()
        try h.tap("latticeTopologyPanelHeader", "Topology's header", settle: 1)
        // a Topology tap: a pending group (no role) on Topology's list
        let free = (0..<64).map { FaceID($0) }.first { f in !p.selection.groups.contains { $0.faces.contains(f) } }
        let pend = p.selection.addGroup()
        p.selection.addFaces([try XCTUnwrap(free)], to: pend)
        p.selection.setActive(pend)
        p.syncForceGroups()
        h.pump(1)
        _ = try h.onScreen("topologyPendingChip", "★ open: Topology's picker (Anchor · Load …)")
        XCTAssertNil(h.frames.all["latticeRolePicker"], "★ not the lattice one")
        XCTAssertEqual(LatticeSetupCopy.topologyHint, "Taps go to Topology groups")
        try h.tap("latticeTopologyPanelHeader", "Topology's header again", settle: 1)
        XCTAssertNil(h.frames.all["topologyPendingChip"], "★ closed: Topology's picker is not on the Lattice stage")
    }
}
#endif

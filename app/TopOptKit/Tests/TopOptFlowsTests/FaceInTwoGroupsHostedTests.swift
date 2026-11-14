// FaceInTwoGroupsHostedTests — B6 slice 1 (approved design 2026-11-02, ledger notes 22, 23; plan.md §B6's hosted test).
//
// His words: "Does not allow for a face to be part of multiple groups. This needs to be fixed." On the Lattice stage a tap on
// a face that is already in a Topology group (his Top) makes a lattice group ("Group 1") holding it — and the face stays in
// its Topology group. The Lattice stage's Selections lists the lattice groups, not Topology's. RED before B6 (saved: scratchpad
// b2red/FaceInTwoGroups.txt): the stage had Topology's one list, so the tap only re-selected the Topology group.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FaceInTwoGroupsHostedTests: XCTestCase {

    /// His A1 pad, Structural, nothing latticed yet; every face of the part in a Topology group (so whatever the tap hits
    /// is a Topology face).
    func latticeStage(size: CGSize) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let mesh = try XCTUnwrap(p.viewerMesh)
        let loose = Set(mesh.faceIDs).subtracting(p.selection.groups.flatMap(\.faces))
        if !loose.isEmpty {
            let a = p.selection.addGroup()
            p.selection.addFaces(Array(loose).sorted(), to: a)
            p.force.makeAnchor(a)
            p.syncForceGroups()
        }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): Topology's ● menu")
        XCTAssertNil(h.frames.all["optimizeSplit"], "\(size): on the Lattice stage")
        return (h, p)
    }

    func testATapOnATopologyFaceMakesALatticeGroupAndTheFaceStays() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13] {
            let (h, p) = try latticeStage(size: size)
            let what = "\(size)"
            let topology = p.selection.groups
            XCTAssertTrue(p.latticeGroups.isEmpty, "\(what): nothing latticed yet")
            // the part sits in the middle of the stage
            // the tap the 3D view hands the stage (handlePick → latticeStageTap; a synthesised click cannot reach the
            // Metal view's own pick, so the test hands it the face — and pins below that handlePick goes through here)
            let mesh = try XCTUnwrap(p.viewerMesh)
            let face = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" }?.faces.first, "his Top")
            _ = p.latticeStageTap(face: face,
                                  loop: p.surfaceLoopRespectingRegions(FaceTopology.loop(fromFace: face, in: mesh), from: face))
            h.pump(1)
            let list = try XCTUnwrap(p.lattice.latticeList, "\(what): ★ the tap made the Lattice stage's own list")
            let g = try XCTUnwrap(list.groups.first, "\(what): ★ a lattice group")
            XCTAssertEqual(g.name, "Group 1", "\(what): ★ the lattice list numbers its groups")
            let f = try XCTUnwrap(g.faces.first, "\(what): it holds the tapped face")
            let owners = topology.filter { $0.faces.contains(f) }
            XCTAssertFalse(owners.isEmpty, "\(what): control — the tapped face was in a Topology group")
            for o in owners {
                XCTAssertTrue(p.selection.groups.first { $0.id == o.id }?.faces.contains(f) == true,
                              "\(what): ★ face \(f) stays in Topology's \(o.name)")
            }
            XCTAssertEqual(p.selection.groups.map(\.id), topology.map(\.id), "\(what): ★ Topology's groups are untouched")
            // the Lattice stage's Selections lists the lattice group, not Topology's
            XCTAssertNotNil(h.frames.all["selGroup-\(g.id.uuidString)"], "\(what): ★ Group 1 is in the stage's Selections")
            for t in topology { XCTAssertNil(h.frames.all["selGroup-\(t.id.uuidString)"], "\(what): ★ not Topology's \(t.name)") }
            // a second tap on the same face selects Group 1; nothing moves
            _ = p.latticeStageTap(face: f, loop: [f])
            XCTAssertEqual(p.latticeGroups.count, 1)
            XCTAssertEqual(p.selection.groups.map(\.id), topology.map(\.id), "\(what): Topology's groups still untouched")
        }
    }

    /// The 3D view's tap on the Lattice stage goes through the model's one call.
    func testTheStagesTapGoesThroughTheLatticeList() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let pick = try XCTUnwrap(ws.range(of: "private func handlePick(_ faceID: FaceID) {"))
        let body = String(ws[pick.lowerBound...].prefix(3_200))
        // ★ RE-PINNED (B6 s2b, note 23c): with the Topology panel open the tap goes on to Topology's groups
        let lattice = try XCTUnwrap(body.range(of: "if stage == .lattice, !latticeTopologyOpen {"))
        // ★ RE-PINNED (his iPad 11-09 (1)): the branch hands the tap to latticeSetupTap, the one Lattice Setup tap (the 3D
        // view's point pick calls it too), which grows the lattice list by the face — or by the piece under it
        XCTAssertTrue(String(body[lattice.lowerBound...].prefix(500)).contains("latticeSetupTap(faceID, at: nil, mesh: mesh)"),
                      "★ the Lattice stage's tap goes to the Lattice Setup tap")
        let setup = try XCTUnwrap(ws.range(of: "private func latticeSetupTap("))
        let tap = String(ws[setup.lowerBound...].prefix(1_400))
        XCTAssertTrue(tap.contains("project.latticeStageTap(face: faceID, loop: loop)") && tap.contains("project.latticeStageTap(piece: piece)"),
                      "★ the Lattice stage's tap grows the lattice list, never Topology's")
    }
}
#endif

// FlexibleFacePickTests — round 7, batch R7-D2, THE PICK (pure), written BEFORE the code (red run: round7/batch_d2/
// d2_red_run.txt). His img1 (2026-10-14): "When a new face is selected, the pop-up to ask whether it's a load, anchor,
// protected, etc. does not show up. It must always show up with a new face-selection." B1: a face never joins a group by
// itself. On HIS pad (A1_0003 + his live lattice: Group C = Face 3 + Face 5 at 25 mm; Bottom anchors Face 0; Top Face 1).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleFacePickTests: XCTestCase {

    func hisPad() throws -> (FlexibleHisProject.Restored, ProjectModel, ViewerMesh, UUID) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        return (r, r.project, try XCTUnwrap(r.project.viewerMesh), c)
    }

    func testAFreeFaceIsPendingAndNothingIsWritten() throws {
        let (_, p, mesh, c) = try hisPad()
        let before = p.selection
        let s = FlexibleFacePick.tap(.init(), face: 4, point: nil, project: p, mesh: mesh)
        XCTAssertEqual(s.scope, .pending([.face(4)]), "★ Face 4 (no group holds it) waits for the chip's answer")
        XCTAssertEqual(p.selection, before, "★ a tap never writes a group")
        // ★ RED CONTROL: #354's LatticeLibraryTap.route on the same tap — it GROWS the active group (img1's Group C [3, 5])
        var sel = p.selection
        sel.setActive(c)
        let loop = p.surfaceLoopRespectingRegions(FaceTopology.loop(fromFace: 4, in: mesh), from: 4)
        _ = LatticeLibraryTap.route(faceID: 4, loop: loop, selection: &sel)
        XCTAssertEqual(sel.groups.first { $0.id == c }?.faces.sorted(), [3, 4, 5], "★ RED CONTROL: today's router adds Face 4 to Group C")
    }

    func testASecondFreeFaceJoinsThePendingSetAndATapAgainDropsIt() throws {
        let (_, p, mesh, _) = try hisPad()
        var s = FlexibleFacePick.tap(.init(), face: 4, point: nil, project: p, mesh: mesh)
        s = FlexibleFacePick.tap(s, face: 2, point: nil, project: p, mesh: mesh)
        XCTAssertEqual(s.scope, .pending([.face(4), .face(2)]))
        XCTAssertEqual(FlexibleFacePick.pendingTitle([.face(4), .face(2)], project: p), "Face 4 + Face 2 · new")
        s = FlexibleFacePick.tap(s, face: 4, point: nil, project: p, mesh: mesh)
        XCTAssertEqual(s.scope, .pending([.face(2)]), "the same face again leaves the set")
        s = FlexibleFacePick.tap(s, face: 2, point: nil, project: p, mesh: mesh)
        XCTAssertEqual(s.scope, .none, "the last one out: nothing pending")
    }

    func testAnOwnedFacePicksItselfInItsGroup() throws {
        let (_, p, mesh, c) = try hisPad()
        let s = FlexibleFacePick.tap(.init(), face: 3, point: nil, project: p, mesh: mesh)
        XCTAssertEqual(s.scope, .face(group: c, ref: .face(group: c, face: 3)), "★ Face 3 of Group C")
        XCTAssertEqual(s.lastGroup, c, "★ the join's target from now on")
        let bottom = try XCTUnwrap(p.selection.groups.first { $0.name == "Bottom" })
        XCTAssertEqual(FlexibleFacePick.tap(s, face: 0, point: nil, project: p, mesh: mesh).scope,
                       .face(group: bottom.id, ref: .face(group: bottom.id, face: 0)), "an owned face while another is picked: that one")
    }

    /// A face a region covers resolves to its outermost piece, and the piece is never moved or removed. RED CONTROL: #354's
    /// handleTopologyPiecePick would MOVE an unowned piece into the active group.
    func testARegionCoveredFaceIsItsPieceAndThePieceIsNeverMoved() throws {
        let (_, p, mesh, c) = try hisPad()
        // a union of Face 2 and Face 4 (the Surface stage's tool), held by no group
        let u = p.faceRegions.union(faces: [2, 4], named: "Sides")
        let before = (p.selection, p.faceRegions)
        let s = FlexibleFacePick.tap(.init(), face: 4, point: nil, project: p, mesh: mesh)
        XCTAssertEqual(s.scope, .pending([.region(u)]), "★ the tap is the union (its outermost piece)")
        XCTAssertEqual(p.selection, before.0, "nothing moved")
        XCTAssertEqual(p.faceRegions, before.1, "the region is untouched")
        // held by a group → that group's region ref
        p.selection.addRegions([u], to: c)
        XCTAssertEqual(FlexibleFacePick.tap(.init(), face: 2, point: nil, project: p, mesh: mesh).scope,
                       .face(group: c, ref: .region(group: c, region: u)))
        p.selection.removeRegions([u])
        // ★ RED CONTROL: TopologyPieceTap with a group active moves the free piece into it
        XCTAssertEqual(TopologyPieceTap.route(owner: nil, active: c), .moveToActive, "★ RED CONTROL: today's piece router moves it")
    }

    func testAnUnheldIdentityRegionIsTheFaceItself() throws {
        let (_, p, mesh, _) = try hisPad()
        let id = p.faceRegions.union(faces: [4], named: "Face 4")   // an identity region (I2's edge strips left these)
        XCTAssertTrue(p.faceRegions.region(id)?.isIdentity == true, "premise: an identity region")
        XCTAssertEqual(FlexibleFacePick.target(face: 4, point: nil, project: p, mesh: mesh), .face(4), "★ skipped: the face itself")
    }

    func testAMissDropsThePendingSetAndLeavesNoOrphanGroup() throws {
        let (_, p, mesh, _) = try hisPad()
        let groups = p.selection.groups.count
        let s = FlexibleFacePick.miss(FlexibleFacePick.tap(.init(), face: 4, point: nil, project: p, mesh: mesh))
        XCTAssertEqual(s.scope, .none)
        XCTAssertEqual(p.selection.groups.count, groups, "★ no 'Pending' group is ever made")
    }

    func testThePickSurvivesACommitAndAnUndoThatRemovesItsGroupReadsAsNone() throws {
        let (_, p, mesh, _) = try hisPad()
        var s = FlexibleFacePick.tap(.init(), face: 4, point: nil, project: p, mesh: mesh)
        p.seedUndoBaseline()
        let gid = try XCTUnwrap(FlexibleFaceCommits.newGroup(.anchor, faces: [.face(4)], project: p, session: &s), "a new Anchor group")
        s.scope = .face(group: gid, ref: .face(group: gid, face: 4))
        XCTAssertEqual(FlexibleFacePick.validated(s, project: p).scope, s.scope, "★ the pick survives its own commit")
        p.performUndo()
        let v = FlexibleFacePick.validated(s, project: p)
        XCTAssertEqual(v.scope, .none, "★ the Undo took the group away: no pick")
        XCTAssertNil(v.lastGroup, "and no join target")
    }
}

// FlexibleFaceCommitTests — round 7, batch R7-D2, THE COMMITS, written BEFORE the code (red run: round7/batch_d2/
// d2_red_run.txt). Each commit is ONE sealed undo step through #354's public setters. His answers (r7/tasks.md, 2026-10-14):
// "Lattice picked for a new face in the pop-up = a LATTICE-ONLY role … (no Protect set behind it)" (★ HELD: condition (d));
// after Load "NO weight pill … reword the Load toast"; "Main-page groups get a TRASH icon too … one Undo brings it back";
// "Group trash should confirm deletion"; (c) "'Add to Group C as lattice' is an obvious button" — it writes what it says.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleFaceCommitTests: XCTestCase {

    func hisPad() throws -> (FlexibleHisProject.Restored, ProjectModel, UUID) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        r.project.seedUndoBaseline()
        return (r, r.project, c)
    }

    /// ★ HELD (condition d): [▦ Lattice] on a new face refuses — no group, nothing written — until the reviewer rules.
    /// RED CONTROL: FlexibleLatticeUnder's .newGroup recipe (today's one-tap Lattice) sets Protect behind the lattice.
    func testLatticeOnANewFaceIsHeldAndTodaysRecipeSetsProtect() throws {
        let (_, p, _) = try hisPad()
        var s = FlexibleFacePickSession(scope: .pending([.face(4)]))
        let before = p.editSnapshot
        XCTAssertNil(FlexibleFaceCommits.newGroup(.lattice, faces: [.face(4)], project: p, session: &s), "★ held: no lattice-only group")
        XCTAssertEqual(p.editSnapshot, before, "★ nothing written")
        XCTAssertNil(p.lattice.flexible?.latticeOnlyGroups, "nothing writes the lattice-only set")
        // ★ RED CONTROL: today's recipe behind [Lattice under it] — Protect + Lattice
        p.flexibleLatticeUnder(.newGroup(face: 4, region: nil, name: "Face 4", depthMM: 25))
        let g = try XCTUnwrap(p.selection.groups.first { $0.name == "Face 4" })
        XCTAssertTrue(p.force.isProtected(g.id), "★ RED CONTROL: today's one-tap lattice sets Protect (his answer: it must not)")
    }

    func testAnchorLoadProtectKeepClearMakeAGroupWithTheFaceOff() throws {
        let (_, p, _) = try hisPad()
        for kind in [FlexibleNewFaceKind.anchor, .load, .protect, .keepClear] {
            var s = FlexibleFacePickSession(scope: .pending([.face(4)]))
            let past = p.undo.past.count
            let gid = try XCTUnwrap(FlexibleFaceCommits.newGroup(kind, faces: [.face(4)], project: p, session: &s), "\(kind)")
            let k = p.force.kind(for: gid)
            switch kind {
            case .anchor: XCTAssertTrue(k.isAnchor)
            case .load: XCTAssertTrue(k.isLoad)
            case .protect: XCTAssertTrue(p.force.isProtected(gid))
            case .keepClear: XCTAssertEqual(p.force.keepClearAffix(for: gid), .on)
            case .lattice: break
            }
            XCTAssertNil(p.latticeSelectableRole(.face(group: gid, face: 4), in: gid), "★ \(kind): the face is Off (no lattice role)")
            XCTAssertEqual(p.undo.past.count, past + 1, "★ \(kind): ONE undo step")
            XCTAssertEqual(s.lastGroup, gid)
            XCTAssertNotEqual(p.selection.groups.first { $0.id == gid }.map { (($0.colorIndex % 5) + 5) % 5 }, 4, "never the face-prism violet")
            p.performUndo()
            XCTAssertNil(p.selection.groups.first { $0.id == gid }, "\(kind): the Undo removes it")
        }
        XCTAssertEqual(FlexibleSelectionsCopy.loadToast("Face 4"), "Face 4 is a Load. Set its weight on the Squish page.")
    }

    /// (c) "Add to Group C as lattice" writes exactly its label: Lattice, at the group's common depth and expand.
    func testJoinWritesTheGroupsCommonDepthAndExpand() throws {
        let (_, p, c) = try hisPad()
        p.writeLatticeExpandMM(.face(group: c, face: 3), mm: 2)
        p.writeLatticeExpandMM(.face(group: c, face: 5), mm: 2)
        var s = FlexibleFacePickSession(scope: .pending([.face(4)]), lastGroup: c)
        XCTAssertTrue(FlexibleFaceCommits.canJoin(c, p), "Group C (Protect) may carry a lattice role")
        let v = FlexibleFaceCommits.joinValues(c, p, session: s)
        XCTAssertEqual(v.depth, 25, accuracy: 1e-9)
        XCTAssertEqual(v.expand, 2, accuracy: 1e-9)
        XCTAssertEqual(FlexibleSelectionsCopy.joinLabel("Group C"), "Add to Group C as lattice")
        XCTAssertEqual(FlexibleSelectionsCopy.joinNote(depthMM: v.depth, like: v.like), "25.0 mm deep, the same as Face 3 + Face 5")
        let past = p.undo.past.count
        XCTAssertTrue(FlexibleFaceCommits.join(c, faces: [.face(4)], project: p, session: &s))
        let r4 = LatticeSelectableRef.face(group: c, face: 4)
        XCTAssertEqual(p.latticeSelectableRole(r4, in: c), .include, "★ as lattice")
        XCTAssertEqual(p.latticeSlabDepthMM(r4, in: c), 25, accuracy: 1e-9, "★ the group's depth")
        XCTAssertEqual(p.latticeExpandMM(r4), 2, accuracy: 1e-9, "★ the group's expand")
        XCTAssertEqual(p.latticeSelectableRole(.face(group: c, face: 3), in: c), .include, "the others did not move")
        XCTAssertEqual(p.undo.past.count, past + 1, "ONE undo step")
        // a group that may not carry a role (Pending) is never offered
        let pend = p.selection.addGroup()
        XCTAssertFalse(FlexibleFaceCommits.canJoin(pend, p), "a Pending group is not a join target")
        XCTAssertFalse(FlexibleFaceCommits.canJoin(nil, p), "no group picked earlier: no join")
    }

    func testTheSegmentDeclaresSeedsAndOffKeepsTheDepth() throws {
        let (_, p, c) = try hisPad()
        let r3 = LatticeSelectableRef.face(group: c, face: 3), r5 = LatticeSelectableRef.face(group: c, face: 5)
        p.writeLatticeDepthMM(r3, mm: 17)
        FlexibleFaceCommits.setState(.off, ref: r3, group: c, project: p)
        XCTAssertNil(p.latticeSelectableRole(r3, in: c), "Off")
        XCTAssertEqual(p.latticeSelectableRole(r5, in: c), .include, "★ the sibling pinned (it did not move)")
        XCTAssertEqual(p.lattice.selectableDepthMM[r3.key] ?? -1, 17, accuracy: 1e-9, "★ Off keeps the stored depth")
        FlexibleFaceCommits.setState(.include, ref: r3, group: c, project: p)
        XCTAssertEqual(p.latticeSlabDepthMM(r3, in: c), 17, accuracy: 1e-9, "back to Lattice: its depth is back")
        FlexibleFaceCommits.setState(.exclude, ref: r3, group: c, project: p)
        XCTAssertEqual(p.latticeSelectableRole(r3, in: c), .exclude, "Solid")
        FlexibleFaceCommits.setAll(.off, group: c, project: p)
        XCTAssertNil(p.latticeSelectableRole(r3, in: c)); XCTAssertNil(p.latticeSelectableRole(r5, in: c))
        // the first non-Off seeds the group's role and depth (#354's row chip) — on a fresh Protect group
        var s = FlexibleFacePickSession(scope: .pending([.face(4)]))
        let g = try XCTUnwrap(FlexibleFaceCommits.newGroup(.protect, faces: [.face(4)], project: p, session: &s))
        XCTAssertNil(p.lattice.groupRoles[g])
        FlexibleFaceCommits.setState(.include, ref: .face(group: g, face: 4), group: g, project: p)
        XCTAssertEqual(p.lattice.groupRoles[g], .include, "★ seeded")
        XCTAssertNotNil(p.lattice.groupDepthMM[g], "★ seeded")
        XCTAssertTrue(p.lattice.enabled)
    }

    func testKeepClearAsksFirstThenBlocksAndLatticeInsteadClearsIt() throws {
        let (_, p, c) = try hisPad()
        XCTAssertEqual(FlexibleFaceCommits.setRole(.keepClear, group: c, project: p), .asksFirst, "★ 'Keep clear removes this lattice'")
        XCTAssertNotEqual(p.force.keepClearAffix(for: c), .on, "nothing written before he says so")
        FlexibleFaceCommits.confirmKeepClear(group: c, project: p)
        XCTAssertTrue(FlexibleFaceCommits.blockedByKeepClear(c, p), "★ state B: Keep clear blocks lattice")
        FlexibleFaceCommits.latticeInstead(group: c, project: p)
        XCTAssertFalse(FlexibleFaceCommits.blockedByKeepClear(c, p), "[Lattice instead]")
        XCTAssertEqual(p.latticeSelectableRole(.face(group: c, face: 3), in: c), .include, "the lattice is back")
        // Anchor and Load are exclusive; Protect toggles
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(FlexibleFaceCommits.setRole(.anchor, group: top.id, project: p), .done)
        XCTAssertTrue(p.force.kind(for: top.id).isAnchor, "★ Load → Anchor")
        FlexibleFaceCommits.setRole(.protect, group: top.id, project: p)
        XCTAssertTrue(p.force.isProtected(top.id))
        FlexibleFaceCommits.setRole(.protect, group: top.id, project: p)
        XCTAssertFalse(p.force.isProtected(top.id))
    }

    func testALockedGroupTakesNoWrite() throws {
        let (_, p, c) = try hisPad()
        p.groupView.toggleLocked(c)
        let before = p.editSnapshot
        FlexibleFaceCommits.setState(.off, ref: .face(group: c, face: 3), group: c, project: p)
        FlexibleFaceCommits.rename(c, to: "Pads", project: p)
        XCTAssertNil(FlexibleFaceCommits.delete(c, project: p))
        XCTAssertEqual(FlexibleFaceCommits.setRole(.anchor, group: c, project: p), .refused)
        XCTAssertEqual(p.editSnapshot, before, "★ locked on Topology: nothing")
    }

    func testRenameCommitsAndAnEmptyNameKeepsTheOld() throws {
        let (_, p, c) = try hisPad()
        FlexibleFaceCommits.rename(c, to: "  ", project: p)
        XCTAssertEqual(p.selection.groups.first { $0.id == c }?.name, "Group C", "★ empty keeps the old")
        FlexibleFaceCommits.rename(c, to: "Pads", project: p)
        XCTAssertEqual(p.selection.groups.first { $0.id == c }?.name, "Pads")
    }

    /// The trash, after its confirm: one undo step; Undo brings back the group, its faces, its role, its depths.
    func testDeleteIsOneUndoStepAndUndoRestoresEverything() throws {
        let (_, p, c) = try hisPad()
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        let snap = p.editSnapshot
        let past = p.undo.past.count
        XCTAssertEqual(FlexibleFaceCommits.delete(c, project: p), "Group C")
        XCTAssertNil(p.selection.groups.first { $0.id == c }, "★ gone (here and for Topology: one selection model)")
        XCTAssertNil(p.lattice.groupRoles[c]); XCTAssertNil(p.lattice.selectableDepthMM[r3.key]); XCTAssertFalse(p.force.isProtected(c))
        XCTAssertEqual(p.undo.past.count, past + 1, "★ ONE undo step")
        XCTAssertEqual(FlexibleSelectionsCopy.deleteAsk("Group C"), "Delete Group C here and in Topology?")
        XCTAssertLessThanOrEqual(FlexibleSelectionsCopy.deleteAsk("Group C").count, 44)
        p.performUndo()
        XCTAssertEqual(p.editSnapshot, snap, "★ Undo: the group, its faces, its role, its depths — everything back")
        XCTAssertEqual(p.latticeSlabDepthMM(r3, in: c), 25, accuracy: 1e-9)
    }

    /// His rule: one visible line per setting, ≤ 44 characters.
    func testEveryLineFits44() {
        for s in [FlexibleSelectionsCopy.latticeHeld, FlexibleSelectionsCopy.statsCaption, FlexibleSelectionsCopy.noNumbers,
                  FlexibleSelectionsCopy.empty, FlexibleSelectionsCopy.keepClearAsk, FlexibleSelectionsCopy.keepClearBlocks,
                  FlexibleSelectionsCopy.locked, FlexibleSelectionsCopy.orNew, FlexibleSelectionsCopy.joinLabel("Group C"),
                  FlexibleSelectionsCopy.joinNote(depthMM: 25, like: ["Face 3", "Face 5"]), FlexibleSelectionsCopy.deleted("Group C")] {
            XCTAssertLessThanOrEqual(s.count, 44, s)
        }
    }
}

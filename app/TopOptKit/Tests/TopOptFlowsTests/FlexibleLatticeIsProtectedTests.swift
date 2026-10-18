// FlexibleLatticeIsProtectedTests — round 7, HIS RULING of 2026-10-18 (chat, binding; it SUPERSEDES his 2026-10-14 answer
// "Lattice on a new face = lattice-only (no Protect)"):
//   "We do not want any lattices to be affected by topology optimization. This is why I set it within 'protect' in the first
//    place. These two things should behave the same way."
// So a lattice face is ALWAYS protected from Topology: chip N's [▦ Lattice] on a new face makes the group Lattice WITH Protect
// underneath — exactly what "Protect, then Lattice" gives today — and the group reads "Lattice" (the shield beside it). The
// lattice-only role (H35, `latticeOnlyGroups`) is WITHDRAWN; the reviewer's condition (d) is moot.
// Written BEFORE the code, against stubs (red run: round7/batch_lp/lp_red_run.txt).
//
// ★ RE-PINNED (our own tests — this file was FlexibleLatticeOnlyGateTests, R7-D2): its three tests pinned the HELD role —
//   (1) an old project without `latticeOnlyGroups` decodes and the field round-trips → now: the field is gone; an old project
//       decodes and re-encodes as before, and a project.json carrying the withdrawn key still opens (the key is dropped);
//   (2) Reset all keeps the lattice-only set → gone with the field;
//   (3) "a lattice-role-only group BLOCKS Topology's Run" (the STOP's evidence) → kept below as the RED CONTROL of the
//       withdrawn role, beside the ruling's test.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleLatticeIsProtectedTests: XCTestCase {

    override func tearDown() {
        FlexibleFaceCommits.controlLatticeHeld = false
        super.tearDown()
    }

    /// Topology's job as Optimize would send it (AppModel.makeRunRequest → RemoteRun.buildJobJSON), pretty and sorted.
    func topologyJob(_ app: AppModel) throws -> String {
        let req = try XCTUnwrap(app.makeRunRequest(), "the Topology run request")
        let d = try RemoteRun.buildJobJSON(req)
        let pretty = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: d), options: [.prettyPrinted, .sortedKeys])
        return String(decoding: pretty, as: UTF8.self)
    }

    func canRun(_ p: ProjectModel) -> Bool {
        p.force.canOptimize(in: p.selection.groups, minimizePlastic: p.minimizePlastic, latticeRoleGroups: Set(p.latticeEligibleRoles().keys))
    }

    /// His pad (A1_0003 as he saved it) + his live lattice (Group C = Face 3 + Face 5, Protect + Lattice, 25 mm).
    func hisPad() throws -> (FlexibleHisProject.Restored, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        r.project.seedUndoBaseline()
        return (r, r.project)
    }

    /// TODAY'S two taps on a fresh copy of his pad: [Protect] on the new face(s), then [▦ Lattice] on the face's chip (one face)
    /// or on the group's "All N" (several) — Topology's job afterwards, with the new group's id written as a token.
    func protectThenLatticeJob(_ faces: [Int]) throws -> String {
        let (r, p) = try hisPad()
        var s = FlexibleFacePickSession(scope: .pending(faces.map { .face(FaceID($0)) }))
        let g = try XCTUnwrap(FlexibleFaceCommits.newGroup(.protect, faces: faces.map { .face(FaceID($0)) }, project: p, session: &s), "[Protect]")
        if faces.count == 1 {
            FlexibleFaceCommits.setState(.include, ref: .face(group: g, face: FaceID(faces[0])), group: g, project: p)
        } else {
            FlexibleFaceCommits.setAll(.include, group: g, project: p)
        }
        XCTAssertTrue(canRun(p), "premise: today's route leaves Optimize allowed")
        return tokenised(try topologyJob(r.app), g)
    }

    func tokenised(_ job: String, _ g: UUID) -> String {
        job.replacingOccurrences(of: g.uuidString, with: "<new group>").replacingOccurrences(of: g.uuidString.lowercased(), with: "<new group>")
    }

    /// What [▦ Lattice] on new face(s) must give, as a list of what is wrong (empty = right) — so the red control runs the
    /// very same check on the held button.
    func latticeOnNewFaces(_ faces: [Int], reference: String) throws -> (gid: UUID?, wrong: [String]) {
        let (r, p) = try hisPad()
        let free = faces.map { FlexibleFreeFace.face(FaceID($0)) }
        var s = FlexibleFacePickSession(scope: .pending(free))
        let past = p.undo.past.count
        guard let gid = FlexibleFaceCommits.newGroup(.lattice, faces: free, project: p, session: &s) else {
            return (nil, ["[▦ Lattice] made no group (held)"])
        }
        var wrong: [String] = []
        if !p.force.isProtected(gid) { wrong.append("not protected (Topology would touch the lattice)") }
        let k = p.force.kind(for: gid)
        if k.isLoad || k.isAnchor { wrong.append("loaded or anchored") }
        if p.force.keepClearAffix(for: gid) == .on { wrong.append("Keep clear") }
        for f in faces where p.latticeSelectableRole(.face(group: gid, face: FaceID(f)), in: gid) != .include {
            wrong.append("Face \(f) is not Lattice")
        }
        if p.latticeEligibleRoles()[gid] == nil { wrong.append("the lattice role is dropped (#354's gate)") }
        if !p.lattice.enabled { wrong.append("lattice not enabled") }
        if !canRun(p) { wrong.append("Topology's Optimize is BLOCKED") }
        if p.undo.past.count != past + 1 { wrong.append("not ONE undo step (\(p.undo.past.count - past))") }
        if s.lastGroup != gid { wrong.append("the pick's last group is not the new group") }
        if !FlexibleFaceCommits.readsLattice(gid, p) { wrong.append("the group does not read Lattice") }
        let job = tokenised(try topologyJob(r.app), gid)
        if job != reference { wrong.append("Topology's job differs from Protect + Lattice (\(job.utf8.count) vs \(reference.utf8.count) bytes)") }
        p.performUndo()
        if p.selection.groups.contains(where: { $0.id == gid }) { wrong.append("the Undo did not remove it") }
        return (gid, wrong)
    }

    // MARK: 1 — the ruling: [▦ Lattice] on a new face = Lattice + Protect; Topology not blocked; the job = today's two taps

    func testLatticeOnANewFaceIsLatticeAndProtectedAndTopologysJobIsTodays() throws {
        let (r0, p0) = try hisPad()
        XCTAssertTrue(canRun(p0), "premise: his pad's Topology Run is allowed")
        let plain = try topologyJob(r0.app)
        let reference = try protectThenLatticeJob([4])
        XCTAssertNotEqual(reference, plain, "premise: a protected lattice face-prism rides Topology's lattice block (as Group C's)")
        let one = try latticeOnNewFaces([4], reference: reference)
        XCTAssertNotNil(one.gid, "★ [▦ Lattice] on a new face makes a group")
        XCTAssertEqual(one.wrong, [], "★ his ruling: Lattice with Protect underneath, Optimize allowed, the job byte-identical to Protect + Lattice")
        // two new faces at once ("Face 2 + Face 4 · new") — the same as [Protect] then "All 2" → Lattice
        let two = try latticeOnNewFaces([2, 4], reference: try protectThenLatticeJob([2, 4]))
        XCTAssertEqual(two.wrong, [], "★ two new faces: the same")
        // ★ RED CONTROL: the held [▦ Lattice] (R7-D2's hold, put back) fails the very same check
        FlexibleFaceCommits.controlLatticeHeld = true
        let held = try latticeOnNewFaces([4], reference: reference)
        XCTAssertNil(held.gid, "★ RED CONTROL: the held button makes nothing")
        XCTAssertFalse(held.wrong.isEmpty, "★ RED CONTROL: the check catches the held [Lattice]")
    }

    /// ★ RED CONTROL of the WITHDRAWN role (the R7-D2 STOP's evidence, kept): a lattice role with no Protect behind it — what
    /// the lattice-only role would have written without H35 — is Pending, BLOCKS Topology's Optimize, and its slab never
    /// reaches the job. That is why Protect stays under every lattice face.
    func testTheWithdrawnLatticeOnlyRoleWouldBlockTopology() throws {
        let (r, p) = try hisPad()
        let before = try topologyJob(r.app)
        let gid = p.selection.addGroup()
        p.selection.addFaces([4], to: gid)
        p.force.sync(groups: p.selection.groups)
        p.lattice.groupRoles[gid] = .include
        p.lattice.groupDepthMM[gid] = 25
        p.lattice.selectableRoles[LatticeSelectableRef.face(group: gid, face: 4).key] = .include
        XCTAssertTrue(p.force.kind(for: gid).isPending, "not loaded, not anchored")
        XCTAssertFalse(p.force.isProtected(gid), "not protected")
        XCTAssertFalse(canRun(p), "★ a lattice role with no Protect is Pending and BLOCKS Topology's Run")
        XCTAssertEqual(try topologyJob(r.app), before, "★ its role is pruned: the job is unchanged")
        XCTAssertFalse(FlexibleFaceCommits.readsLattice(gid, p), "★ and it never reads Lattice")
        p.force.setProtected(gid, true)
        XCTAssertTrue(canRun(p), "Protect underneath: Run allowed")
        XCTAssertTrue(FlexibleFaceCommits.readsLattice(gid, p), "★ … and it reads Lattice — his two routes are one")
    }

    // MARK: 2 — "These two things should behave the same way": both routes read "Lattice"

    func testBothRoutesReadLatticeWithTheShieldBesideIt() throws {
        let (_, p) = try hisPad()
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        // his Group C — Protect, then Lattice (the route he has always used)
        XCTAssertTrue(FlexibleFaceCommits.readsLattice(c.id, p), "★ Group C (Protect + Lattice) reads Lattice")
        let rc = FlexibleFaceChip.roleReading(p, c.id, ui: nil)
        XCTAssertEqual(rc.word, "Lattice", "★ the chip's role reads Lattice")
        XCTAssertEqual(rc.symbol, "square.grid.3x3.fill")
        XCTAssertTrue(rc.shield, "★ the shield beside it (protected from Topology)")
        XCTAssertEqual(FlexibleRoleGlyphs.glyphs(p, c.id).map { $0.symbol }, ["square.grid.3x3.fill", "shield.lefthalf.filled"],
                       "★ the list's line: the lattice glyph, the shield beside it")
        // [▦ Lattice] on a new face reads the same
        var s = FlexibleFacePickSession(scope: .pending([.face(4)]))
        let g = try XCTUnwrap(FlexibleFaceCommits.newGroup(.lattice, faces: [.face(4)], project: p, session: &s), "[▦ Lattice]")
        XCTAssertEqual(FlexibleFaceChip.roleReading(p, g, ui: nil), rc, "★ the two routes read the same")
        XCTAssertEqual(FlexibleRoleGlyphs.glyphs(p, g).map { $0.symbol }, FlexibleRoleGlyphs.glyphs(p, c.id).map { $0.symbol })
        // a Protect group with no lattice face still reads Protect; Solid only too
        var s2 = FlexibleFacePickSession(scope: .pending([.face(2)]))
        let pr = try XCTUnwrap(FlexibleFaceCommits.newGroup(.protect, faces: [.face(2)], project: p, session: &s2))
        XCTAssertEqual(FlexibleFaceChip.roleReading(p, pr, ui: nil).word, "Protect", "a Protect group with its face Off")
        FlexibleFaceCommits.setState(.exclude, ref: .face(group: pr, face: 2), group: pr, project: p)
        XCTAssertEqual(FlexibleFaceChip.roleReading(p, pr, ui: nil).word, "Protect", "a Protect group with its face Solid")
        XCTAssertEqual(FlexibleRoleGlyphs.glyphs(p, pr).map { $0.symbol }, ["shield.lefthalf.filled"])
        // the face set Lattice → it reads Lattice; Protect off → it no longer does (the lattice role drops: Pending)
        FlexibleFaceCommits.setState(.include, ref: .face(group: pr, face: 2), group: pr, project: p)
        XCTAssertEqual(FlexibleFaceChip.roleReading(p, pr, ui: nil).word, "Lattice", "★ Protect then Lattice reads Lattice")
        // a Load or an Anchor with lattice faces reads its force (the Top, his Load)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        FlexibleFaceCommits.setState(.include, ref: .face(group: top.id, face: 1), group: top.id, project: p)
        XCTAssertFalse(FlexibleFaceCommits.readsLattice(top.id, p), "a Load with a lattice face reads Load")
        XCTAssertTrue(FlexibleFaceChip.roleReading(p, top.id, ui: nil).word.hasPrefix("Load") || FlexibleFaceChip.roleReading(p, top.id, ui: nil).word == FlexibleSelectionsCopy.weightUnset)
        // ★ RED CONTROL: R7-D2's reading — a protected group read "Protect" whatever its faces were
        XCTAssertTrue(p.force.isProtected(c.id) && FlexibleFaceCommits.hasLattice(c.id, p), "★ RED CONTROL premise: R7-D2 read this group as 'Protect'")
    }

    // MARK: 3 — [▦ Lattice] through the stage: the chip stays on the new group's face

    func testTheChipsLatticeButtonCommitsThroughTheStage() throws {
        let (_, p) = try hisPad()
        let s = FlexibleMainStage()
        s.facePick = FlexibleFacePickSession(scope: .pending([.face(4)]))
        var changed = 0
        s.commitNew(.lattice, project: p) { changed += 1 }
        let g = try XCTUnwrap(s.facePick.scope.groupID, "★ the new Lattice group")
        XCTAssertEqual(s.facePick.scope, .face(group: g, ref: .face(group: g, face: 4)), "★ the chip stays, on the new group's face")
        XCTAssertEqual(p.selection.activeGroupID, g)
        XCTAssertTrue(p.force.isProtected(g), "★ Protect underneath")
        XCTAssertEqual(p.latticeSelectableRole(.face(group: g, face: 4), in: g), .include)
        XCTAssertEqual(changed, 1, "the face cards refresh")
        XCTAssertNil(s.faceUI.toast, "no toast (the Load's only)")
        XCTAssertEqual(FlexibleFaceChip.kind(.pending([.face(2)]), project: p, lastGroup: nil), FlexibleFaceChipLayout.Kind.new(join: false),
                       "★ chip N's kind carries no held line")
    }

    // MARK: 4 — the withdrawn field: old projects open as before

    func testAnOldProjectOpensAndAProjectWithTheWithdrawnKeyStillOpens() throws {
        let src = FlexiblePressFixtures.a1Dir(3).appendingPathComponent("project.json")
        let data = try Data(contentsOf: src)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("latticeOnlyGroups"), "premise: an old project, no key")
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let s = try XCTUnwrap(r.project.lattice.flexible, "his Flexible pad opened")
        let enc = try JSONEncoder().encode(s)
        XCTAssertFalse(String(decoding: enc, as: UTF8.self).contains("latticeOnlyGroups"), "★ never encoded")
        XCTAssertEqual(try JSONDecoder().decode(FlexibleStageSettings.self, from: enc), s, "round-trips")
        // a settings value carrying the withdrawn key (no build ever wrote it — nil was never encoded — but if one did)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: enc) as? [String: Any])
        obj["latticeOnlyGroups"] = ["A1000001-AAAA-4000-8000-000000000009"]
        let stale = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(FlexibleStageSettings.self, from: stale)
        XCTAssertEqual(back, s, "★ the withdrawn key is ignored: the same settings")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(back), as: UTF8.self).contains("latticeOnlyGroups"), "★ and dropped on save")
        // ★ the field is gone from the source (withdrawn — his ruling)
        let src2 = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleSettings.swift"), encoding: .utf8)
        XCTAssertFalse(src2.contains("latticeOnlyGroups"), "★ FlexibleStageSettings has no lattice-only field")
    }
}

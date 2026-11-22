// UnionNotes1122Tests — ★ his iPad notes 2026-11-22 (img 7-10): on the Lattice stage he unioned faces of his lattice Group 2
// (blue); the union turned Protect's green, could not be added to Group 2, and stayed green when its row was removed. "It
// should have automatically added the unioned faces to the group if the rest of the faces were part of the group. They
// shouldn't be a completely different colour, randomly." Found: the union joined TOPOLOGY's group that held a piece (Group C,
// Protect), never the lattice list; and any group holding a piece read as holding the whole union, so Topology's Protect
// would have grown to every face of it. On his l bracket's bolt holes.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class UnionNotes1122Tests: XCTestCase {

    /// The bracket on Structural, its bolt holes as pieces; Topology's "Group C" holds the first hole's piece; the lattice
    /// "Group 2" holds every hole by face.
    private func scene(_ test: String) throws -> (p: ProjectModel, pieces: [RegionID], holes: [FaceID], c: UUID, two: UUID) {
        let p = try FlexiblePressFixtures.lBracketProject(test)
        let m = try XCTUnwrap(p.viewerMesh, "the bracket's mesh")
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        XCTAssertTrue(p.usesLatticeList, "premise: Structural edits the lattice list")
        let holes = FaceTopology.faceIDs(in: m).filter {
            m.faceGeometry($0)?.kind == .cylinder && (m.faceGeometry($0)?.cylinderRadiusMM ?? 0) > 0
        }.sorted()
        XCTAssertGreaterThanOrEqual(holes.count, 2, "premise: the bracket has bolt holes")
        let pieces = try holes.map { try XCTUnwrap(p.surfaceEnsureRegion(for: $0), "a piece for hole \($0)") }
        var s = p.selection
        let c = s.addGroup()
        s.addRegions([pieces[0]], to: c)
        p.selection = s
        var l = p.latticeList
        let two = l.addGroup()
        l.addFaces(holes, to: two)
        p.latticeList = l
        return (p, pieces, holes, c, two)
    }

    private func union(_ p: ProjectModel, _ pieces: [RegionID], lattice: Bool) throws -> RegionID {
        var u = SurfaceUnion()
        for x in pieces { u.toggle(x) }
        return try XCTUnwrap(p.commitSurfaceUnion(u, latticeStage: lattice), "the holes combine")
    }

    private func faces(_ p: ProjectModel, _ g: SelectionGroup, among list: [SelectionGroup]) -> Set<FaceID> {
        Set(g.faces).union(p.surfaceEffectiveRegions(of: g, among: list).flatMap { p.surfaceResolvedFaces($0) })
    }

    /// ★ On the Lattice stage the union joins the lattice group its faces were in (Group 2 keeps its colour), and Topology's
    /// groups are exactly as they were (Group C still protects its one hole, not the union). RED CONTROL: the old path
    /// (Topology's list) puts the union in Group C, which then covers every hole.
    func testAUnionOnTheLatticeStageJoinsTheLatticeGroupItsFacesWereIn() throws {
        let t = try scene(#function)
        let p = t.p
        let cBefore = faces(p, try XCTUnwrap(p.selection.groups.first { $0.id == t.c }), among: p.selection.groups)
        XCTAssertEqual(cBefore, [t.holes[0]], "premise: Group C protects one hole")
        let rid = try union(p, t.pieces, lattice: true)
        let two = try XCTUnwrap(p.latticeGroups.first { $0.id == t.two })
        XCTAssertTrue(two.regionIDs.contains(rid), "★ the union is in Group 2")
        XCTAssertTrue(p.surfaceEffectiveRegions(of: two).contains(rid), "★ Group 2 holds it (it can be given a role)")
        XCTAssertEqual(faces(p, two, among: p.latticeGroups), Set(t.holes), "★ Group 2 still covers every hole")
        let c = try XCTUnwrap(p.selection.groups.first { $0.id == t.c })
        XCTAssertFalse(c.regionIDs.contains(rid), "★ Topology's Group C did not take the union")
        XCTAssertEqual(faces(p, c, among: p.selection.groups), cBefore, "★ Group C protects exactly its one hole still")
        XCTAssertEqual(Set(p.keepClearFaces(c)), cBefore, "★ and the run reads the same")

        // RED CONTROL: the same union through Topology's list (the old path) — it lands in Group C and covers every hole
        let r = try scene(#function + "-red")
        let old = try union(r.p, r.pieces, lattice: false)
        let cOld = try XCTUnwrap(r.p.selection.groups.first { $0.id == r.c })
        XCTAssertTrue(cOld.regionIDs.contains(old), "RED CONTROL: Topology's list puts the union in its group")
        XCTAssertEqual(faces(r.p, cOld, among: r.p.selection.groups), Set(r.holes), "RED CONTROL: and Group C covers every hole")
    }

    /// ★ Pieces from two groups of one list: the union goes to the group most of them were in (his yes 11-22), and that group
    /// alone holds it.
    func testAMixedUnionGoesToTheGroupMostPiecesWereIn() throws {
        let t = try scene(#function)
        let p = t.p
        guard t.holes.count >= 3 else { throw XCTSkip("needs three bolt holes") }
        var l = p.latticeList
        let one = l.addGroup()
        l.addFaces([t.holes[0]], to: one)   // one hole moves to Group 1; the rest stay in Group 2
        p.latticeList = l
        let rid = try union(p, t.pieces, lattice: true)
        let two = try XCTUnwrap(p.latticeGroups.first { $0.id == t.two })
        XCTAssertTrue(two.regionIDs.contains(rid), "★ the union goes where most of its pieces were (Group 2)")
        if let g1 = p.latticeGroups.first(where: { $0.id == one }) {
            XCTAssertFalse(p.surfaceEffectiveRegions(of: g1).contains(rid), "★ Group 1 does not also claim it")
        }
    }

    /// ★ The cut-face card says what happened, what it does and what its button does, in plain words, never a face number.
    func testTheCutFaceCardSaysWhatItMeans() {
        XCTAssertEqual(EditFacesCopy.orphanLine(1),
                       "The lit piece was cut from a face whose other half is gone, so tapping there picks the wrong piece. Make it whole joins it back.")
        XCTAssertTrue(EditFacesCopy.orphanLine(3).hasPrefix("The lit piece and 2 more were"))
        XCTAssertFalse(EditFacesCopy.orphanLine(1).contains(where: \.isNumber), "never a face number")
    }
}

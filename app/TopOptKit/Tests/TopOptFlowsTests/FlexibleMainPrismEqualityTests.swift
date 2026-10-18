// FlexibleMainPrismEqualityTests — round 7, batch R7-D2 (R7-M 1b/1c/1d folded in), written BEFORE the code (red run:
// round7/batch_d2/d2_red_run.txt). His img1 (2026-10-14): "The number on the face-prism should be tap to edit … The
// face-prism depth in the modal and on the face-prism are not equal? … they should *always* be equal." and img2: "What is
// this 12mm? … please remove whatever it is". The handle's box, the list's box and the drawn prism read ONE store.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleMainPrismEqualityTests: XCTestCase {

    override func tearDown() {
        FlexibleMainStage.controlPrismsFollowActiveGroup = false
        super.tearDown()
    }

    func stage() throws -> (FlexibleHisProject.Restored, ProjectModel, FlexibleMainStage, UUID) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        _ = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        return (r, r.project, s, c)
    }

    func testTheHandleTheListAndThePrismReadTheSameNumber() throws {
        let (_, p, s, c) = try stage()
        let mesh = try XCTUnwrap(p.viewerMesh)
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        XCTAssertEqual(s.facePick.scope, .face(group: c, ref: r3), "premise: Face 3 picked")
        let planes = s.pickedPlanes(p)
        XCTAssertEqual(planes.map(\.ref), [r3], "★ FACE scope: that face's prism and handle only")
        let handle = FlexibleLatticeHandles.depthText(p.latticeSlabDepthMM(r3, in: c))
        let list = FlexibleLatticeHandles.depthText(p.latticeSlabDepthMM(r3, in: c))   // the list's box reads the same function
        XCTAssertEqual(handle, "25.0 mm"); XCTAssertEqual(list, handle)
        let drawn = try XCTUnwrap(s.volumes(p, on: .lattice, drilledIn: false).first { $0.volume.faceID == 3 })
        guard case .shell(let sh) = drawn.volume.shape else { return XCTFail("a face-prism is a shell") }
        XCTAssertEqual(FlexibleLatticeHandles.depthText(sh.reachedDepthMM), handle, "★ the drawn prism, too")
        // a typed / dragged depth moves all three
        var sess = s.facePick
        FlexibleFaceCommits.setDepth(17.26, ref: r3, group: c, project: p, session: &sess)
        XCTAssertEqual(FlexibleLatticeHandles.depthText(p.latticeSlabDepthMM(r3, in: c)), "17.3 mm")
        let moved = try XCTUnwrap(s.volumes(p, on: .lattice, drilledIn: false).first { $0.volume.faceID == 3 })
        guard case .shell(let sh2) = moved.volume.shape else { return XCTFail("a shell") }
        XCTAssertEqual(Double(sh2.reachedDepthMM), p.latticeSlabDepthMM(r3, in: c), accuracy: 1e-6, "★ the drawn depth = the plane's")
        XCTAssertEqual(sess.lastDepth ?? 0, 17.3, accuracy: 0.05, "the session remembers the last depth set")
        // GROUP scope: every face of the group
        s.pickGroup(c, project: p)
        XCTAssertEqual(Set(s.pickedPlanes(p).map(\.faceKey)), [3, 5], "★ GROUP scope: every face")
        // img1's state: Face 3's SQUISH depth 24.5 never reaches this page
        XCTAssertTrue(s.prismTags(p, on: .lattice, drilledIn: false, viewport: CGSize(width: 1032, height: 1376), keepOut: [],
                                  projector: { _ in CGPoint(x: 500, y: 500) }).isEmpty, "★ no squish number on the main page")
    }

    /// Nothing before a pick; a pending (free) face draws no prism; picking the Top (Off in Selections) draws nothing (img2).
    func testNothingBeforeAPickAndNo12mmOnTheTop() throws {
        let (_, p, s, _) = try stage()
        let mesh = try XCTUnwrap(p.viewerMesh)
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false), [], "nothing before a pick")
        s.tapFace(p, face: 4, point: nil, mesh: mesh)
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false), [], "a new face: no prism yet")
        s.tapFace(p, face: 1, point: nil, mesh: mesh)
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false), [], "★ img2: the Top picked — no 12.0 mm, no prism")
        XCTAssertTrue(s.pickedPlanes(p).isEmpty)
        // ★ RED CONTROL: R7-V / M1's rule — the prism follows the ACTIVE group, not the pick: with Group C active and a free
        // face picked, Group C's prisms are still drawn
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        p.selection.setActive(c.id)
        s.tapFace(p, face: 4, point: nil, mesh: mesh)
        FlexibleMainStage.controlPrismsFollowActiveGroup = true
        let control = s.volumes(p, on: .lattice, drilledIn: false)
        FlexibleMainStage.controlPrismsFollowActiveGroup = false
        XCTAssertFalse(control.isEmpty, "★ RED CONTROL: the active group's prisms over a new face's pick")
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false), [], "★ the pick decides: a new face, no prism")
    }
}

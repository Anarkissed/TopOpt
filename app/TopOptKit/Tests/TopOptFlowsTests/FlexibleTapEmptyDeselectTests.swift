// FlexibleTapEmptyDeselectTests — the reviewer's overnight release ruling (2026-10-26 07:42 UTC), item 3: TAP-EMPTY-DESELECT.
// On the main Flexible page a tap that hits no face (H23 → FlexibleMainStage.missTap; the chip's ✕ too) deselects: the face
// pick and the chip close, and the Selections group the face router had made active goes too — so the picked group's
// face-prisms and numbers (drawn for the active group once he has picked: H15') leave with it. Before: the chip closed but the
// group stayed active, its prisms and numbers still drawn. Written before the code (red on today's missTap). His pad A1_0003
// with his live lattice (Group C = Face 3 + Face 5).
#if canImport(AppKit)
import XCTest
@testable import TopOptFlows

@MainActor
final class FlexibleTapEmptyDeselectTests: XCTestCase {

    override func tearDown() {
        FlexibleMainStage.controlMissKeepsActive = false
        super.tearDown()
    }

    func testATapOnNothingDeselectsTheGroupAsWellAsTheChip() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        _ = s.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        p.selection.clearActive()
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        XCTAssertEqual(s.facePick.scope, .face(group: c, ref: .face(group: c, face: 3)), "premise: Face 3 picked")
        XCTAssertEqual(p.selection.activeGroupID, c, "premise: the router made Group C active (its prisms and numbers drawn)")
        s.missTap()
        XCTAssertTrue(s.facePick.scope.isNone, "the chip closes")
        XCTAssertNil(p.selection.activeGroupID, "★ a tap on nothing deselects: no group stays active")
        XCTAssertEqual(s.facePick.lastGroup, c, "the join still remembers Group C (a new face can be added to it)")
        // the chip's ✕ is the same miss
        s.tapFace(p, face: 5, point: nil, mesh: mesh)
        XCTAssertEqual(p.selection.activeGroupID, c)
        s.missTap()
        XCTAssertNil(p.selection.activeGroupID)
        // ★ RED CONTROL: today's miss — the chip closes, the group stays active
        FlexibleMainStage.controlMissKeepsActive = true
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        s.missTap()
        XCTAssertTrue(s.facePick.scope.isNone)
        XCTAssertEqual(p.selection.activeGroupID, c, "★ RED CONTROL: the old miss leaves Group C active")
        await_idle(s)
    }

    private func await_idle(_ s: FlexibleMainStage) {
        if let m = s.model { addTeardownBlock { @MainActor in await m.waitForIdle() } }
    }
}
#endif

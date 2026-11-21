// FlexibleLatticeHandlesTests — round 7, batch R7-D2, the picked prism's NUMBERED handles (H20 takes #354's numberless knobs
// off the stage), written BEFORE the code (red run: round7/batch_d2/d2_red_run.txt). His img1: "The number on the face-prism
// should be tap to edit (bringing up a numeric keyboard for input)".
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleLatticeHandlesTests: XCTestCase {

    let cands = LatticeDepthDetent.candidates(topology: "octet", minExtrudableWidthMM: 0.45)

    func testTheDepthDragFollowsTheProjectedNormalWithTheDetents() {
        // the normal projects 60 pt per 10 mm, straight down the screen
        let floor = CGPoint(x: 500, y: 500), deeper = CGPoint(x: 500, y: 560)
        let d = FlexibleLatticeHandles.depthDelta(translation: CGSize(width: 0, height: 30), floor: floor, deeper: deeper)
        XCTAssertEqual(d.mm, 5, accuracy: 1e-9, "★ 30 pt along a 60 pt-per-10 mm normal = 5 mm deeper")
        XCTAssertFalse(d.vertical)
        let sideways = FlexibleLatticeHandles.depthDelta(translation: CGSize(width: 40, height: 0), floor: floor, deeper: deeper)
        XCTAssertEqual(sideways.mm, 0, accuracy: 1e-9, "a drag across the normal moves nothing")
        // the magnet: 19.8 mm raw snaps to the round 20
        let r = FlexibleLatticeHandles.dragDepth(seed: 15, translation: CGSize(width: 0, height: 28.8), floor: floor, deeper: deeper,
                                                 candidates: cands, held: nil)
        XCTAssertEqual(r.mm, 20, accuracy: 1e-9, "★ #354's LatticeDepthDetent magnet (round mm)")
        XCTAssertNotNil(r.held)
        // ★ RED CONTROL: today's numberless #354 knob has no number and no keypad (H20 takes it off the stage)
        XCTAssertFalse(FlexibleLatticeHandles.depthText(20).isEmpty)
    }

    func testTheScreenVerticalFallbackUnder30PointsPer10mm() {
        // the face seen almost edge-on along its normal: 12 pt per 10 mm
        let d = FlexibleLatticeHandles.depthDelta(translation: CGSize(width: 0, height: 40), floor: CGPoint(x: 0, y: 0),
                                                  deeper: CGPoint(x: 12, y: 0))
        XCTAssertTrue(d.vertical, "★ under 30 pt per 10 mm: screen-vertical")
        XCTAssertEqual(d.mm, 4, accuracy: 1e-9, "down = deeper, 0.1 mm per point")
        XCTAssertTrue(FlexibleLatticeHandles.depthDelta(translation: .zero, floor: nil, deeper: nil).vertical, "no projection: vertical")
    }

    func testClampedOneToFifty() {
        let up = FlexibleLatticeHandles.dragDepth(seed: 3, translation: CGSize(width: 0, height: -400), floor: nil, deeper: nil,
                                                  candidates: [], held: nil)
        XCTAssertEqual(up.mm, LatticeSlabDepth.minMM, accuracy: 1e-9)
        let down = FlexibleLatticeHandles.dragDepth(seed: 45, translation: CGSize(width: 0, height: 900), floor: nil, deeper: nil,
                                                    candidates: [], held: nil)
        XCTAssertEqual(down.mm, LatticeSlabDepth.maxMM, accuracy: 1e-9)
    }

    func testTheExpandSnapsToZeroAndGoesNegative() {
        XCTAssertEqual(FlexibleLatticeHandles.dragExpand(seed: 0, translation: CGSize(width: 4, height: 0), knob: nil, outward: nil), 0,
                       accuracy: 1e-9, "★ within the snap: 0")
        let neg = FlexibleLatticeHandles.dragExpand(seed: 0, translation: CGSize(width: -100, height: 0), knob: nil, outward: nil)
        XCTAssertLessThan(neg, 0, "★ it shrinks below 0")
        XCTAssertEqual(FlexibleLatticeHandles.dragExpand(seed: 49, translation: CGSize(width: 900, height: 0), knob: nil, outward: nil), 50,
                       accuracy: 1e-9, "−50…+50")
        // along the knob's projected outward direction (60 pt per 10 mm, to the right)
        let along = FlexibleLatticeHandles.dragExpand(seed: 0, translation: CGSize(width: 60, height: 0), knob: CGPoint(x: 0, y: 0),
                                                      outward: CGPoint(x: 60, y: 0))
        XCTAssertEqual(along, 10, accuracy: 1e-9)
        XCTAssertEqual(FlexibleLatticeHandles.expandText(0), "+0.0 mm")
        XCTAssertEqual(FlexibleLatticeHandles.expandText(-2), "−2.0 mm")
    }

    func testTargetsAre44() {
        XCTAssertEqual(FlexibleLatticeHandles.hit, 44)
        XCTAssertEqual(FlexibleLatticeHandles.disc, 32)
    }

    /// One undo step per drag; X-ray on during it and put back after; the cards refreshed once on release.
    func testOneUndoStepPerDragXrayDuringItCardsOnce() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        p.seedUndoBaseline()
        let s = FlexibleMainStage()
        _ = s.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        XCTAssertFalse(s.xrayOn, "premise: X-ray off")
        let past = p.undo.past.count
        var cards = 0
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        s.beginHandleDrag(p, key: "handle-depth-\(r3.key)")
        XCTAssertTrue(s.xrayOn, "★ X-ray on while it drags")
        var sess = s.facePick
        for mm in [24.0, 22.0, 20.5, 19.0] { FlexibleFaceCommits.writeDepth(mm, ref: r3, group: c, project: p, session: &sess) }
        s.endHandleDrag(p) { cards += 1 }
        XCTAssertFalse(s.xrayOn, "★ put back as it was")
        XCTAssertEqual(p.undo.past.count, past + 1, "★ ONE undo step for the whole drag")
        XCTAssertEqual(cards, 1, "★ the cards refreshed once, on release")
        XCTAssertEqual(p.latticeSlabDepthMM(r3, in: c), 19, accuracy: 1e-9)
        p.performUndo()
        XCTAssertEqual(p.latticeSlabDepthMM(r3, in: c), 25, accuracy: 1e-9, "one Undo: back to 25")
    }
}

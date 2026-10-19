// FlexiblePressStampTests — round 7, batch R7-E4 (his words of 2026-10-14: "A stamp should work as on any face - except from the
// edge/corner and aligned to it alone."). FRONT-END only (his ruling of 2026-10-19 ~14:50): placed, drawn and edited here; nothing
// reaches core (no design_stamp, no check_stamp until the back-end phase). RED CONTROL inside the test, asserted red. His pad.
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePressStampTests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias S = FlexiblePressStamp

    override func tearDown() {
        S.controlFreeDrag = false
        FlexibleBackend.sendsPresses = false
        super.tearDown()
    }

    func distanceToLine(_ p: SIMD3<Double>, _ o: SIMD3<Double>, _ dir: SIMD3<Double>) -> Double {
        simd_length(simd_cross(p - o, dir))
    }

    func testTheStampSitsOnTheEdge() async throws {
        let (_, m) = try await F.hisPad(self)
        let e = try await F.edge16(m)
        let st = e.strip, d = try XCTUnwrap(st.halfway)
        let c = FlexibleFlatPrism.cut(st, direction: d, depthMM: 6)
        let l = try XCTUnwrap(FlexibleFlatPrism.line(st))
        let seed = try XCTUnwrap(S.seed(st, c, library: m.library, weightKg: 5), "a default stamp")
        let fp = S.footprint(st, c)
        print("FLEX-E4-S Edge 16 h 6: footprint \(fp) · seed \(m.stampName(seed)) \(seed.widthMM) × \(seed.lengthMM) turn \(seed.rotationDeg) at \(seed.centreU)")
        // the centre on the edge line
        let centre = try XCTUnwrap(S.centre(st, seed))
        XCTAssertLessThan(distanceToLine(centre, l.origin, l.dir), 1e-6, "★ the centre is on the edge line")
        XCTAssertEqual(seed.centreU, (l.s0 + l.s1) / 2, accuracy: 1e-9, "★ at the edge's middle")
        // the long axis ∥ the edge seen down the arrow; it fits 90 % of the footprint
        let f = try XCTUnwrap(S.frame(st, direction: d))
        let th = seed.rotationDeg * .pi / 180
        let long = seed.widthMM >= seed.lengthMM ? f.x * cos(th) + f.y * sin(th) : f.y * cos(th) - f.x * sin(th)
        XCTAssertGreaterThan(abs(simd_dot(long, f.x)), 1 - 1e-9, "★ the long axis ∥ the edge's projection")
        XCTAssertLessThanOrEqual(max(seed.widthMM, seed.lengthMM), 0.9 * fp.along + 1e-9)
        XCTAssertLessThanOrEqual(min(seed.widthMM, seed.lengthMM), 0.9 * fp.across + 1e-9)
        // the outline lies on the part: every point on a member's face, none outside both
        for q in S.outline(st, seed, direction: d) {
            let dist = st.members.map { mb in abs(simd_dot(q - mb.origin, FlexibleFlatPrism.planeNormal(mb)!)) }.min()!
            XCTAssertLessThan(dist, 1e-6, "★ the outline folds onto the faces")
        }
        // a perpendicular drag leaves the across offset at 0 (and the centre where it was); along, it slides within the span
        let across = simd_normalize(simd_cross(d, l.dir))
        let perp = S.dragged(st, seed, by: across * 7)
        XCTAssertEqual(perp.centreV, 0, "★ a perpendicular drag leaves the across offset at 0")
        XCTAssertEqual(perp.centreU, seed.centreU, accuracy: 1e-9)
        let slid = S.dragged(st, seed, by: l.dir * 100)
        XCTAssertEqual(slid.centreU, try XCTUnwrap(S.range(st, seed)).upperBound, accuracy: 1e-9, "★ it stops at the span's end")
        XCTAssertLessThan(distanceToLine(try XCTUnwrap(S.centre(st, slid)), l.origin, l.dir), 1e-6)
        // a corner stamp sits on the vertex and does not move
        let pick = try await FlexibleM2Fixtures.pickMode(m)
        let cand = try XCTUnwrap(F.corner(m, pick))
        let cs = try XCTUnwrap(pick.strips[cand.number])
        let cc = FlexibleFlatPrism.cut(cs, direction: try XCTUnwrap(cs.halfway), depthMM: 4)
        let cseed = try XCTUnwrap(S.seed(cs, cc, library: m.library, weightKg: 5))
        XCTAssertEqual(try XCTUnwrap(S.centre(cs, cseed)), cs.members[0].origin, "★ a corner stamp's centre == the vertex")
        XCTAssertEqual(S.dragged(cs, cseed, by: SIMD3(5, 5, 5)), cseed, "★ a corner stamp only resizes and turns")
        // front-end only: with the switch off nothing of the press reaches core (E2 PARKED's gate)
        XCTAssertFalse(FlexibleBackend.sendsPresses, "★ his ruling: the stamp waits for the back-end phase")
        // RED CONTROL: the face handle's free (u, v) drag moves it off the edge
        S.controlFreeDrag = true
        let red = S.dragged(st, seed, by: across * 7)
        S.controlFreeDrag = false
        print("FLEX-E4-S RED CONTROL (free drag): across offset \(red.centreV) mm")
        XCTAssertGreaterThan(red.centreV, 1, "RED CONTROL: the free drag leaves the edge")
    }

    /// The model's writes: Shape Stamp seeds ONE stamp on the edge; a slide is clamped to the span; Curves keeps it stored.
    func testShapeStampSeedsOnTheEdgeAndCurvesKeepsIt() async throws {
        let (_, m) = try await F.hisPad(self)
        let e = try await F.edge16(m)
        let p = try await F.commit(m, e.c)
        XCTAssertNil(p.foldCurves, "premise: a new press reads as the flat prism")
        m.setPressShape(p.id, "stamp")
        let q = try XCTUnwrap(m.press(p.id))
        XCTAssertTrue(q.settings.isStampShape)
        XCTAssertEqual(q.foldCurves, true)
        let s = try XCTUnwrap(q.settings.designStamp, "★ one stamp landed")
        let l = try XCTUnwrap(FlexibleFlatPrism.line(try XCTUnwrap(q.strip)))
        XCTAssertLessThan(distanceToLine(try XCTUnwrap(S.centre(q.strip!, s)), l.origin, l.dir), 1e-6)
        m.updatePressStamp(p.id, save: false) { $0.centreU += 1000; $0.centreV = 9 }
        let moved = try XCTUnwrap(m.press(p.id)?.settings.designStamp)
        XCTAssertEqual(moved.centreV, 0, "★ the model keeps it on the edge")
        XCTAssertEqual(moved.centreU, try XCTUnwrap(S.range(q.strip!, moved)).upperBound, accuracy: 1e-9)
        m.setPressShape(p.id, "curves")
        XCTAssertFalse(try XCTUnwrap(m.press(p.id)).settings.isStampShape)
        XCTAssertNotNil(m.press(p.id)?.settings.designStamp, "★ Curves keeps the stamp stored for a switch back")
    }
}

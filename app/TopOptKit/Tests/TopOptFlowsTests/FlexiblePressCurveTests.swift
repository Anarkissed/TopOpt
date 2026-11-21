// FlexiblePressCurveTests — round 7, batch R7-E4 (his words of 2026-10-14: "create two sides of a curve/add a stamp. The curve should
// be viewable from the top and from a 45 degree angle on the side of the body."; his default of 2026-10-18 ~16:50: the two-sided
// curve starts as the flat prism's own straight lines, never past it, seen from [Top] and [45°]). FRONT-END only (his ruling of
// 2026-10-19 ~14:50): nothing here reaches core. Each RED CONTROL runs inside its test and is asserted red. On HIS pad (A1_0003).
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePressCurveTests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias B = FlexiblePressCurveBaselines

    override func tearDown() {
        B.controlAbsolute = false
        B.controlFaceBaselines = false
        B.controlThreeCornerSides = false
        FlexiblePress.controlReframeFlat = false
        super.tearDown()
    }

    /// Edge 16's area and its halfway arrow on his pad.
    func edge16(_ m: FlexibleStageModel) async throws -> (FlexibleStrip, SIMD3<Double>) {
        let e = try await F.edge16(m)
        return (e.strip, try XCTUnwrap(e.strip.halfway, "core's halfway"))
    }

    func press(_ st: FlexibleStrip, _ d: SIMD3<Double>, _ h: Double) -> FlexiblePress {
        FlexiblePress(regions: st.members.map(\.root), direction: d, settings: FlexibleFaceSettings(faceRegionID: 0, deepestMM: h), strip: st)
    }

    /// The editor's drawn point for a stored y (FlexibleCurveEditor: height 1 − y above its baseline).
    func drawn(_ b: FlexibleCurveBaseline, _ t: Double, _ y: Double) -> SIMD3<Double> { b.world(t, FlexibleCurveEditor.displayHeight(y)) }

    func onPlane(_ m: FlexibleStrip.Member, _ p: SIMD3<Double>) -> Double {
        abs(simd_dot(p - m.origin, FlexibleFlatPrism.planeNormal(m)!))
    }

    // MARK: - the default is the flat prism

    func testTheTwoSidedCurveStartsAsTheFlatPrism() async throws {
        let (_, m) = try await F.hisPad(self)
        let (st, d) = try await edge16(m)
        // untwisted and twisted (8° along the edge), 3 and 9 mm
        let twisted = FlexiblePressAim.unit(d + FlexibleFlatPrism.line(st)!.dir * tan(8 * .pi / 180))!
        for (dir, h) in [(d, 3.0), (d, 9.0), (twisted, 6.0)] {
            let c = FlexibleFlatPrism.cut(st, direction: dir, depthMM: h)
            let p = press(st, dir, h)
            let across = try XCTUnwrap(B.across(st, c)), along = try XCTUnwrap(B.along(st, c))
            var worst = 0.0
            for (b, axis) in [(across, B.Axis.across), (along, .along)] {
                let mult = B.multipliers(p, axis)
                XCTAssertEqual(mult, B.ones, "★ a press never edited reads as the flat prism (all ones)")
                for i in 0...40 {
                    let t = Double(i) / 40
                    let y = try XCTUnwrap(FlexibleCore.penCurveValues(x: mult.x, y: mult.y, t: [t]).first)
                    worst = max(worst, abs(c.height(drawn(b, t, y)) - h))
                }
            }
            print("FLEX-E4-1 Edge 16 h \(h) twisted \(dir != d): the default curves' worst distance off P = \(worst) mm")
            XCTAssertLessThan(worst, 1e-9, "★ every drawn point of the default across and along curves lies on the flat face")
            // the fold: ½ under the edge along the arrow, 0 and 1 on the two faces' traces
            let l = FlexibleFlatPrism.line(st)!
            let e = l.origin + l.dir * ((l.s0 + l.s1) / 2)
            XCTAssertLessThan(simd_length(simd_cross(across.at(0.5) - e, dir)), 1e-9, "★ the fold's ½ is on the edge (along the arrow)")
            XCTAssertLessThan(onPlane(st.members[0], across.at(0)), 1e-9, "★ 0 on the first face's trace")
            XCTAssertLessThan(onPlane(st.members[1], across.at(1)), 1e-9, "★ 1 on the second face's trace")
            XCTAssertLessThan(abs(c.height(across.at(0)) - h) + abs(c.height(across.at(1)) - h), 1e-9)
        }
        // RED CONTROL: the face's X / Y baseline on one member's rim
        B.controlFaceBaselines = true
        let c = FlexibleFlatPrism.cut(st, direction: d, depthMM: 3)
        let red = try XCTUnwrap(B.across(st, c))
        B.controlFaceBaselines = false
        let off = abs(c.height(red.at(0)) - 3)
        print("FLEX-E4-1 RED CONTROL (a face's baseline on one rim): \(off) mm off P at 0")
        XCTAssertGreaterThan(off, 1, "RED CONTROL: the face rule's baseline is not the flat prism")
    }

    // MARK: - never past it; it follows the prism; no reframe

    func testACurveNeverPassesTheFlatPrism() async throws {
        let (_, m) = try await F.hisPad(self)
        let (st, d) = try await edge16(m)
        var p = press(st, d, 3)
        // he drags points past the plate line (y > 1 means past the flat face); the stored multipliers clamp to 1
        let asked = FlexCurve(x: [0, 0.3, 0.5, 0.8, 1], y: [1.4, 0.4, 1.2, 0.6, 1])
        B.set(&p, .across, asked)
        let stored = B.multipliers(p, .across)
        XCTAssertEqual(p.foldCurves, true)
        XCTAssertEqual(stored.y, [1, 0.4, 1, 0.6, 1], "★ a drag past the plate line clamps (stored M ≤ 1)")
        XCTAssertEqual(B.multipliers(p, .along), B.ones, "the other curve stays the flat prism")
        func worstPast(_ h: Double) throws -> Double {
            let c = FlexibleFlatPrism.cut(st, direction: p.direction, depthMM: h)
            let b = try XCTUnwrap(B.across(st, c))
            var past = -Double.infinity
            for i in 0...60 {
                let t = Double(i) / 60
                let y = try XCTUnwrap(FlexibleCore.penCurveValues(x: stored.x, y: stored.y, t: [t]).first)
                past = max(past, c.height(drawn(b, t, y)) - h)   // > 0: deeper than the flat face
            }
            return past
        }
        XCTAssertLessThanOrEqual(try worstPast(3), 1e-9, "★ no point passes the flat face")
        // a depth or angle change keeps the stored multipliers, and the drawn curve follows (its ones on the new P)
        p.settings.deepestMM = 9
        let tipped = FlexiblePressAim.unit(d + FlexibleFlatPrism.planeNormal(st.members[0])! * 0.2)!
        XCTAssertTrue(p.aim(tipped, snap: nil))
        XCTAssertEqual(B.multipliers(p, .across), stored, "★ a depth / angle change keeps his shape")
        XCTAssertNil(p.drawnIn, "★ a flat press's curves are never in a frame of record (no reframe)")
        XCTAssertLessThanOrEqual(try worstPast(9), 1e-9)
        let c9 = FlexibleFlatPrism.cut(st, direction: tipped, depthMM: 9)
        let b9 = try XCTUnwrap(B.across(st, c9))
        XCTAssertLessThan(abs(c9.height(drawn(b9, 0.5, 1)) - 9), 1e-9, "★ the drawn curve follows the deeper, tipped prism")
        // RED CONTROLS: absolute squish stored (× the flat prism's fraction) — not what he drew; a flat press reframed
        var q = press(st, d, 3)
        B.controlAbsolute = true
        B.set(&q, .across, asked) { x in 1 - abs(2 * x - 1) }
        B.controlAbsolute = false
        print("FLEX-E4-2 RED CONTROL (absolute stored): \(B.multipliers(q, .across).y) vs \(stored.y)")
        XCTAssertNotEqual(B.multipliers(q, .across).y, stored.y, "RED CONTROL: absolute S leaves his drawing behind")
        FlexiblePress.controlReframeFlat = true
        var r = press(st, d, 3)
        _ = r.aim(tipped, snap: nil)
        FlexiblePress.controlReframeFlat = false
        XCTAssertNotNil(r.drawnIn, "RED CONTROL: a flat press re-aimed gets a frame of record")
    }

    // MARK: - [Top] and [45°]

    func testTheTwoViewsShowTheCurve() async throws {
        let (r, m) = try await F.hisPad(self)
        let (st, d) = try await edge16(m)
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let arrow = settle.act(SIMD3<Float>(d))
        XCTAssertEqual(B.eye(.top, arrow: arrow), OrientationGizmo.region("Top")!.direction, "★ [Top] = the gizmo's top region")
        let e45 = B.eye(.deg45, arrow: arrow)
        XCTAssertEqual(Double(asin(min(1, e45.y))) * 180 / .pi, 45, accuracy: 1e-4, "★ [45°] is 45° up")
        let horiz = simd_normalize(SIMD3<Float>(-arrow.x, 0, -arrow.z))
        XCTAssertGreaterThan(simd_dot(simd_normalize(SIMD3<Float>(e45.x, 0, e45.z)), horiz), 0.9999, "★ from the side the arrow comes from")
        let top = B.heightOnScreen(eye: B.eye(.top, arrow: arrow), arrow: arrow)
        let deg45 = B.heightOnScreen(eye: e45, arrow: arrow)
        // the across baseline itself is seen too (not edge-on)
        let c = FlexibleFlatPrism.cut(st, direction: d, depthMM: 3)
        let b = try XCTUnwrap(B.across(st, c))
        let span = settle.act(SIMD3<Float>(simd_normalize(b.at(1) - b.at(0))))
        let spanTop = B.heightOnScreen(eye: B.eye(.top, arrow: arrow), arrow: span), span45 = B.heightOnScreen(eye: e45, arrow: span)
        print("FLEX-E4-3 Edge 16: the curve's height on screen [Top] \(top) · [45°] \(deg45); its baseline [Top] \(spanTop) · [45°] \(span45)")
        XCTAssertGreaterThanOrEqual(top, 0.95, "★ [Top] sees Edge 16's across curve whole")
        XCTAssertGreaterThanOrEqual(deg45, 0.7, "★ [45°] shows it at ≥ 0.7 of its height")
        XCTAssertGreaterThanOrEqual(min(spanTop, span45), 0.7, "★ the baseline is not edge-on in either view")
        // RED CONTROL (why it is never an editing view): down the arrow the curve has no height
        let down = B.heightOnScreen(eye: SIMD3<Float>.zero - arrow, arrow: arrow)
        print("FLEX-E4-3 RED CONTROL (down the arrow): \(down)")
        XCTAssertLessThan(down, 0.01, "RED CONTROL: down the arrow ≈ 0")
    }

    // MARK: - a corner: one curve

    func testACornerCurveMovesAllThreeSidesAndSaysSo() async throws {
        let (_, m) = try await F.hisPad(self)
        let pick = try await FlexibleM2Fixtures.pickMode(m)
        let cand = try XCTUnwrap(F.corner(m, pick), "a corner of his pad")
        let st = try XCTUnwrap(pick.strips[cand.number])
        let d = try XCTUnwrap(st.halfway)
        let c = FlexibleFlatPrism.cut(st, direction: d, depthMM: 3)
        XCTAssertEqual(B.axes(st), [.corner], "★ one curve (core holds one: centre_edge)")
        let sides = B.cornerSides(st, c)
        XCTAssertEqual(sides.count, 2, "★ drawn two-sided, on two faces")
        for k in sides {
            let b = try XCTUnwrap(B.cornerSide(st, member: k, c))
            XCTAssertLessThan(abs(c.height(b.at(0)) - 3) + abs(c.height(b.at(1)) - 3), 1e-9, "★ on the flat face, rim → over the vertex")
            XCTAssertLessThan(onPlane(st.members[k], b.at(0)), 1e-9, "★ its rim on member \(k)'s face")
        }
        var p = press(st, d, 3)
        let bent = FlexCurve(x: [0, 0.5, 1], y: [1, 0.5, 1])
        B.set(&p, .corner, bent)
        XCTAssertEqual(p.settings.curveCentreEdge, bent, "★ the one curve core holds for the corner")
        XCTAssertEqual(B.multipliers(p, .corner), bent, "★ both drawn sides read the same curve")
        let line = FlexibleRowCopy.cornerOneCurve
        XCTAssertEqual(line, "Corner \u{00B7} one curve for all 3 sides")
        XCTAssertLessThanOrEqual(line.count, 44)
        let src = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleEdgePickViews.swift"), encoding: .utf8)
        XCTAssertEqual(src.components(separatedBy: "FlexibleRowCopy.cornerOneCurve").count - 1, 1, "★ the line is shown once")
        B.controlThreeCornerSides = true
        let red = B.cornerSides(st, c).count
        B.controlThreeCornerSides = false
        XCTAssertEqual(red, 3, "RED CONTROL: three independent sides drawn where core holds one curve")
    }
}

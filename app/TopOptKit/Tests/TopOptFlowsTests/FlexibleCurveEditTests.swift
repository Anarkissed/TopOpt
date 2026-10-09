// FlexibleCurveEditTests — the curve reads the right way round, a tap adds a point where
// you tap, and a tapped point shows an × that deletes it (task 2026-09-29-flexible-screens,
// round 3, items 1.3 and 8).
//   * 1.3: a point dragged onto the FACE line stores y = 1 (the squishiest), onto the dashed
//     guide y = 0. RED control: the old mapping stored 0 on the face line.
//   * 8: a tap at t inserts a point AT t, on the curve (the shape stays); x stays strictly
//     increasing with core's 0.01 gap; a tap too near a point selects it instead. RED
//     control: the old "+ point" inserted at the widest gap's middle, not at the tap.
//   * 8: no × on an end point; × on k removes k; the double-tap and "+ point" are gone.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleCurveEditTests: XCTestCase {

    func testTheFaceLineIsTheSquishiest() {
        // the finger at height 0 (on the face line) and at height 1 (on the dashed guide)
        XCTAssertEqual(FlexibleCurveEditor.storedY(height: 0), 1)
        XCTAssertEqual(FlexibleCurveEditor.storedY(height: 1), 0)
        XCTAssertEqual(FlexibleCurveEditor.storedY(height: -0.3), 1, "clamped below the face line")
        XCTAssertEqual(FlexibleCurveEditor.storedY(height: 1.7), 0, "clamped above the guide")
        // ★ RED CONTROL: the old mapping (stored y = the height) put 0 on the face line
        let old: (Double) -> Double = { max(0, min(1, $0)) }
        XCTAssertEqual(old(0), 0)
        XCTAssertNotEqual(old(0), FlexibleCurveEditor.storedY(height: 0))
        // the default dome now draws as a VALLEY touching the face in the middle
        let d = FlexibleFaceSettings.defaultCurve
        XCTAssertEqual(FlexibleCurveEditor.displayHeight(d.y[1]), 0, "the middle sits on the face")
        XCTAssertEqual(FlexibleCurveEditor.displayHeight(d.y[0]), 0.7, accuracy: 1e-12)
    }

    func testDisplayAndStorageRoundTripAtEveryPoint() {
        for c in [FlexibleFaceSettings.defaultCurve, FlexCurve(x: [0, 0.27, 0.49, 0.73, 1], y: [0, 0, 1, 0, 0]),
                  FlexCurve(x: [0, 0.4, 1], y: [0.2, 1, 0.3])] {
            for y in c.y {
                XCTAssertEqual(FlexibleCurveEditor.storedY(height: FlexibleCurveEditor.displayHeight(y)), y, accuracy: 1e-12)
            }
        }
    }

    /// ★ A tap at t lands AT t, on the curve.
    func testATapAddsAPointWhereYouTapKeepingTheShape() throws {
        let c = FlexibleFaceSettings.defaultCurve          // x 0, 0.5, 1
        let t = 0.2
        let (out, k) = try XCTUnwrap(FlexibleCurveEditor.inserting(at: t, into: c))
        XCTAssertEqual(out.x.count, c.x.count + 1)
        XCTAssertEqual(out.x[k], t, accuracy: 1e-12, "the point lands where he tapped")
        let onCurve = try FlexibleCore.penCurveValues(x: c.x, y: c.y, t: [t])[0]
        XCTAssertEqual(out.y[k], onCurve, accuracy: 1e-12, "on the curve")
        // the shape: core's curve through the new points, printed as a distribution
        let ts = (0..<20).map { (Double($0) + 0.5) / 20 }
        let a = try FlexibleCore.penCurveValues(x: c.x, y: c.y, t: ts)
        let b = try FlexibleCore.penCurveValues(x: out.x, y: out.y, t: ts)
        let dev = zip(a, b).map { abs($0 - $1) }
        print(String(format: "FLEX-CURVE insert at t 0.2 on the default dome: |Δ curve| over 20 t's max %.4f mean %.4f (Fritsch–Carlson re-derives its slopes)",
                     dev.max() ?? 0, dev.reduce(0, +) / Double(dev.count)))
        XCTAssertLessThan(dev.max() ?? 1, 0.05, "the shape stays (within the monotone cubic's slope change)")
        XCTAssertEqual(try FlexibleCore.penCurveValues(x: out.x, y: out.y, t: [t])[0], onCurve, accuracy: 1e-9,
                       "exactly unchanged AT the tap")
        XCTAssertEqual(FlexibleCore.penCurveError(x: out.x, y: out.y), "")
        // ★ RED CONTROL: the old "+ point" put the point in the widest gap's middle (0.25 here)
        var best = 0
        for i in 0..<(c.x.count - 1) where c.x[i + 1] - c.x[i] > c.x[best + 1] - c.x[best] { best = i }
        let oldT = (c.x[best] + c.x[best + 1]) / 2
        XCTAssertEqual(oldT, 0.25)
        XCTAssertNotEqual(oldT, out.x[k], "control: the old rule ignores where he tapped")
    }

    func testInsertKeepsXStrictlyIncreasingAndANearTapSelects() throws {
        let c = FlexCurve(x: [0, 0.3, 0.6, 1], y: [0.3, 0.8, 0.9, 0.3])
        // right next to a neighbour: pushed to core's 0.01 gap
        let (a, ka) = try XCTUnwrap(FlexibleCurveEditor.inserting(at: 0.312, into: c))
        XCTAssertGreaterThanOrEqual(a.x[ka] - a.x[ka - 1], 0.01 - 1e-12)
        XCTAssertGreaterThanOrEqual(a.x[ka + 1] - a.x[ka], 0.01 - 1e-12)
        XCTAssertTrue(zip(a.x, a.x.dropFirst()).allSatisfy { $0 < $1 })
        // on a point (or an end): no new point — the tap selects that point instead
        XCTAssertNil(FlexibleCurveEditor.inserting(at: 0.305, into: c))
        XCTAssertNil(FlexibleCurveEditor.inserting(at: 0.004, into: c))
        XCTAssertNil(FlexibleCurveEditor.inserting(at: 0.999, into: c))
        XCTAssertEqual(FlexibleCurveEditor.pointNear(t: 0.305, in: c), 1)
        XCTAssertEqual(FlexibleCurveEditor.pointNear(t: 0.004, in: c), 0)
        XCTAssertNil(FlexibleCurveEditor.pointNear(t: 0.45, in: c))
    }

    func testTheXDeletesThatPointAndNeverAnEnd() throws {
        let c = FlexCurve(x: [0, 0.3, 0.6, 1], y: [0.3, 0.8, 0.9, 0.3])
        XCTAssertFalse(FlexibleCurveEditor.deletable(0, in: c))
        XCTAssertFalse(FlexibleCurveEditor.deletable(3, in: c))
        XCTAssertNil(FlexibleCurveEditor.removing(0, from: c))
        XCTAssertNil(FlexibleCurveEditor.removing(3, from: c))
        let r = try XCTUnwrap(FlexibleCurveEditor.removing(2, from: c))
        XCTAssertEqual(r, FlexCurve(x: [0, 0.3, 1], y: [0.3, 0.8, 0.3]))
    }

    /// ★ CALL SITES (memory: value-type tests miss call sites): the editor taps through
    /// SpatialTapGesture on the named stage space (iOS 16 has no onTapGesture(coordinateSpace:)),
    /// and the double-tap delete and the "+ point" button are gone.
    func testTheEditorTapsOnTheLineAndTheOldGesturesAreGone() throws {
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let editor = try String(contentsOf: root.appendingPathComponent("FlexibleCurveEditor.swift"), encoding: .utf8)
        let page = try String(contentsOf: root.appendingPathComponent("FlexibleStagePage.swift"), encoding: .utf8)
        XCTAssertTrue(editor.contains("SpatialTapGesture(coordinateSpace: .named(FlexibleStageSpace.name))"))
        XCTAssertTrue(editor.contains("\"flexible-curve-line\""))
        XCTAssertTrue(editor.contains("\"flexible-curve-point-delete-\\(k)\""))
        XCTAssertTrue(editor.contains("displayHeight("), "the editor draws through the round-3 reading")
        XCTAssertFalse(editor.contains("TapGesture(count: 2)"), "the double-tap delete is gone")
        XCTAssertFalse(page.contains("flexible-add-point"), "the + point button is gone")
        XCTAssertFalse(page.contains("Up = softer"), "the backwards caption is gone")
    }

    /// ★ A TAP IS NOT A DRAG (verification of round 3): a tap that wobbles 1–2 pt must not
    /// move the point, and a drag moves it WITH the finger from where it was grabbed.
    /// RED CONTROL: the old absolute rule put the point under the finger — 11 pt off here.
    func testATapDoesNotMoveAPointAndADragIsRelative() throws {
        XCTAssertGreaterThanOrEqual(FlexibleCurveEditor.dragStartPoints, 6, "a 1–2 pt wobble stays a tap")
        let grab = CGSize(width: 10, height: 5)                 // grabbed 10 pt right, 5 pt below its centre
        let p = FlexibleCurveEditor.dragged(location: CGPoint(x: 110, y: 205), grab: grab)
        XCTAssertEqual(p, CGPoint(x: 100, y: 200), "the point stays where it was grabbed from")
        let old = CGPoint(x: 110, y: 205)                        // the finger itself
        XCTAssertGreaterThan(hypot(old.x - 100, old.y - 200), 10, "control: the old rule jumped it to the finger")
        let editor = try String(contentsOf: FlexibleHisProject.repoRoot
            .appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleCurveEditor.swift"), encoding: .utf8)
        XCTAssertTrue(editor.contains("DragGesture(minimumDistance: Self.dragStartPoints"))
        XCTAssertTrue(editor.contains("param(at: Self.dragged(location: g.location, grab: grab)"))
    }
}

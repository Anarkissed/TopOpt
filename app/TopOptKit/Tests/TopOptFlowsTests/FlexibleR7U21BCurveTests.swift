// FlexibleR7U21BCurveTests — round 7 · U21 batch B, CURVE-MIRROR (the maths and the model). His notes of 2026-10-21, "Img16
// finally" (27.png): "in the curves should have some buttons available to make things a little easier for the user … Copy the
// left side of the curve and paste to thee right side · Copy the right side and paste to the left side · Copy the top curve and
// paste to the bottom curve · Copy the bottom curve and paste to the top curve."
// On HIS projects of 10-21: the l-bracket's Face 6 (his 27.png window; round7/batch_u21_c/his_live_1021_lbracket) and the pad's
// Face 3 (round7/batch_u21_b/his_live_1021_pad). Each RED control is asserted red inside its test. The window's layout (80 %,
// the legend column) is pinned hosted in FlexibleR7U21BCurveHostedTests.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7U21BCurveTests: XCTestCase {
    typealias Axis = FlexiblePressCurveBaselines.Axis
    static var padDir: URL {
        FlexibleHisProject.repoRoot.appendingPathComponent(
            "docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_u21_b/his_live_1021_pad", isDirectory: true)
    }
    static let lbrFace6 = 2000008, padFace3 = 3
    var log: [String] = []

    override func tearDown() {
        FlexibleCurveMirror.controlNaiveFlip = false
        FlexibleStageModel.controlActionWritesAtOnce = false
        super.tearDown()
    }

    /// A face's saved curves straight from his project file.
    func savedFace(_ dir: URL, _ region: Int) throws -> FlexibleFaceSettings {
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: dir.appendingPathComponent("project.json")))
        return try XCTUnwrap(snap.lattice?.flexible?.face(region), "his face \(region)")
    }
    func fmt(_ c: FlexCurve) -> String {
        "x [" + c.x.map { String(format: "%.5f", $0) }.joined(separator: ", ") + "] y [" + c.y.map { String(format: "%.5f", $0) }.joined(separator: ", ") + "]"
    }
    func flush() { print("FLEX-U21B " + log.joined(separator: "\n  ")) }

    // MARK: his l-bracket Face 6 (27.png): Left → Right exact

    func testHisLBracketFace6MirrorsExactly() throws {
        let f = try savedFace(FlexibleR7U21CHandlesHostedTests.liveDir, Self.lbrFace6)
        let x = f.curveX
        XCTAssertEqual(x.x.count, 5, "premise: his 27.png X curve, 5 points")
        XCTAssertGreaterThan(FlexibleCurveMirror.curveAsymmetry(x), 0.02, "premise: his X curve is not symmetric today")
        let lr = FlexibleCurveMirror.mirrored(x, .leftToRight)
        log.append("Face 6 X \(fmt(x)) · asym today \(String(format: "%.5f", FlexibleCurveMirror.curveAsymmetry(x)))")
        log.append("  Left → Right \(fmt(lr)) · asym \(FlexibleCurveMirror.curveAsymmetry(lr)) · core error '\(FlexibleCore.penCurveError(x: lr.x, y: lr.y))'")
        // the left half and his own middle bit-exact, the right half their reflection
        XCTAssertEqual(lr.x, [x.x[0], x.x[1], x.x[2], 1 - x.x[1], 1 - x.x[0]], "★ x: left half kept, reflected right")
        XCTAssertEqual(lr.y, [x.y[0], x.y[1], x.y[2], x.y[1], x.y[0]], "★ y: left half kept, reflected right")
        XCTAssertEqual(lr.x.map { ($0 * 1e5).rounded() / 1e5 }, [0, 0.04724, 0.5, 0.95276, 1])
        XCTAssertEqual(lr.y.map { ($0 * 1e5).rounded() / 1e5 }, [0, 0.78134, 1, 0.78134, 0])
        XCTAssertLessThan(FlexibleCurveMirror.curveAsymmetry(lr), 1e-12, "★ core's curve is symmetric")
        XCTAssertEqual(FlexibleCore.penCurveError(x: lr.x, y: lr.y), "", "core takes it")
        XCTAssertEqual(FlexibleCurveMirror.keptHalfMoved(x, lr, .leftToRight), 0, accuracy: 1e-12, "the kept half's curve unchanged")
        // Right → Left: the right half kept
        let rl = FlexibleCurveMirror.mirrored(x, .rightToLeft)
        XCTAssertEqual(rl.x, [1 - x.x[4], 1 - x.x[3], x.x[2], x.x[3], x.x[4]])
        XCTAssertEqual(rl.y, [x.y[4], x.y[3], x.y[2], x.y[3], x.y[4]])
        XCTAssertLessThan(FlexibleCurveMirror.curveAsymmetry(rl), 1e-12)
        log.append("  Right → Left \(fmt(rl))")
        // a symmetric result changes nothing more (the button greys)
        XCTAssertFalse(FlexibleCurveMirror.changes(lr, .leftToRight), "★ greyed once symmetric")
        XCTAssertTrue(FlexibleCurveMirror.changes(x, .leftToRight) && FlexibleCurveMirror.changes(x, .rightToLeft), "offered on his curve")
        // RED CONTROL: a naive flip (y read backwards on the same x) leaves it asymmetric
        FlexibleCurveMirror.controlNaiveFlip = true
        let red = FlexibleCurveMirror.mirrored(x, .leftToRight)
        FlexibleCurveMirror.controlNaiveFlip = false
        let ra = FlexibleCurveMirror.curveAsymmetry(red)
        log.append("  RED naive flip: asym \(String(format: "%.5f", ra))")
        XCTAssertGreaterThan(ra, 1e-4, "RED CONTROL: the naive flip is not symmetric")
        flush()
    }

    // MARK: the gap: a point within 0.01 of the middle

    func testAPointWithinTheGapOfTheMiddleIsDropped() throws {
        // his middle at ½ kept; a point at 0.495 is within core's gap of it: dropped
        let c = FlexCurve(x: [0, 0.3, 0.495, 0.5, 1], y: [0.2, 0.6, 0.9, 1, 0.4])
        let lr = FlexibleCurveMirror.mirrored(c, .leftToRight)
        XCTAssertEqual(lr.x, [0, 0.3, 0.5, 1 - 0.3, 1], "★ 0.495 dropped")
        XCTAssertEqual(lr.y, [0.2, 0.6, 1, 0.6, 0.2])
        XCTAssertEqual(FlexibleCore.penCurveError(x: lr.x, y: lr.y), "")
        // no point at ½: one within the gap IS his middle (its y kept, placed at ½)
        let c2 = FlexCurve(x: [0, 0.3, 0.495, 1], y: [0.2, 0.6, 0.9, 0.4])
        let lr2 = FlexibleCurveMirror.mirrored(c2, .leftToRight)
        XCTAssertEqual(lr2.x, [0, 0.3, 0.5, 1 - 0.3, 1])
        XCTAssertEqual(lr2.y, [0.2, 0.6, 0.9, 0.6, 0.2], "his 0.495 point is the middle")
        // a kept point exactly one gap from ½ stays (core's gap is met)
        let c3 = FlexCurve(x: [0, 0.49, 1], y: [0.5, 0.8, 0.5])
        let lr3 = FlexibleCurveMirror.mirrored(c3, .leftToRight)
        XCTAssertEqual(lr3.x.count, 5)
        XCTAssertEqual(FlexibleCore.penCurveError(x: lr3.x, y: lr3.y), "", "core takes 0.49 / 0.5 / 0.51")
        log.append("gap: \(fmt(lr)) · \(fmt(lr2)) · \(fmt(lr3))")
        flush()
    }

    // MARK: his pad's Face 3 X (no middle point): core's value at ½

    func testHisPadFace3XHasNoMiddlePointAndKeepsItsHalf() throws {
        let x = try savedFace(Self.padDir, Self.padFace3).curveX
        XCTAssertEqual(x.x.count, 4, "premise: his Face 3 X, 4 points")
        XCTAssertNil(FlexibleCurveMirror.ownMiddle(x), "premise: no point within 0.01 of ½")
        let mid = FlexibleCurveMirror.coreValue(x, at: 0.5)
        for (side, want) in [(FlexibleCurveMirror.Side.leftToRight, 9.1e-3), (.rightToLeft, 0.106)] {
            let m = FlexibleCurveMirror.mirrored(x, side)
            let moved = FlexibleCurveMirror.keptHalfMoved(x, m, side)
            log.append("pad Face 3 X \(side.rawValue): \(fmt(m)) · asym \(FlexibleCurveMirror.curveAsymmetry(m)) · kept half moved \(String(format: "%.4f", moved)) · core ½ \(String(format: "%.5f", mid))")
            XCTAssertLessThan(FlexibleCurveMirror.curveAsymmetry(m), 1e-12, "★ \(side): symmetric")
            XCTAssertEqual(FlexibleCore.penCurveError(x: m.x, y: m.y), "", "core takes it")
            let k = m.x.firstIndex(of: 0.5)
            XCTAssertNotNil(k, "a middle point")
            XCTAssertEqual(m.y[k ?? 0], mid, "★ the middle is core's own value at ½")
            // kept points bit-exact
            let kept = x.x.indices.filter { side == .leftToRight ? x.x[$0] < 0.49 : x.x[$0] > 0.51 }
            for i in kept {
                let j = try XCTUnwrap(m.x.firstIndex(of: x.x[i]), "kept x \(x.x[i])")
                XCTAssertEqual(m.y[j], x.y[i], "★ kept point bit-exact")
            }
            XCTAssertLessThanOrEqual(moved, 0.11, "★ the kept half moves at most 0.11")
            XCTAssertEqual(moved, want, accuracy: want * 0.1, "★ \(side): the kept half moves \(want) (measured, not 'slight')")
        }
        XCTAssertEqual(mid, 0.59348, accuracy: 1e-5, "core's ½ on his Face 3 X")
        flush()
    }

    // MARK: copy; corner none

    func testCopyIsExactAndACornerHasNoButtons() throws {
        let f = try savedFace(FlexibleR7U21CHandlesHostedTests.liveDir, Self.lbrFace6)
        XCTAssertNotEqual(f.curveX, f.curveY, "premise: his X and Y differ")
        let face = try XCTUnwrap(FlexibleCurveMirror.copyPair(face: true, strip: nil))
        XCTAssertEqual(face.top, .along, "a face: X on top"); XCTAssertEqual(face.bottom, .across, "Y below")
        let edge = try XCTUnwrap(FlexibleCurveMirror.copyPair(face: false, strip: FlexibleStrip(kind: .edge, label: "Edge 9", order: 0, members: [])))
        XCTAssertEqual(edge.top, .across); XCTAssertEqual(edge.bottom, .along)
        let corner = FlexibleStrip(kind: .corner, label: "Corner 1", order: 0, members: [])
        XCTAssertNil(FlexibleCurveMirror.copyPair(face: false, strip: corner), "★ a corner: no Copy")
        XCTAssertTrue(FlexibleCurveMirror.mirrorAxes(face: false, strip: corner).isEmpty, "★ a corner: no Mirror")
        XCTAssertEqual(FlexibleRowCopy.curveCopyXY, "X \u{2192} Y \u{2193}")
        XCTAssertEqual(FlexibleRowCopy.curveCopyAcrossAlong, "Across \u{2192} Along")
        for s in [FlexibleRowCopy.curveMirrorLR, FlexibleRowCopy.curveMirrorRL, FlexibleRowCopy.curveCopyXY, FlexibleRowCopy.curveCopyYX,
                  FlexibleRowCopy.curveCopyAcrossAlong, FlexibleRowCopy.curveCopyAlongAcross] {
            XCTAssertLessThanOrEqual(s.count, 16, "short labels: \(s)")
        }
    }

    // MARK: the model on his pad: draft only; OK + one Undo restores; Cancel reverts

    func hisPad() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(Self.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad of 10-21")
        return (r, m)
    }
    func faceCurves(_ m: FlexibleStageModel, _ r: Int) -> (FlexCurve, FlexCurve)? {
        m.settings.face(r).map { ($0.curveX, $0.curveY) }
    }

    func testOnHisPadMirrorAndCopyAreDraftOnly() async throws {
        let (r, m) = try await hisPad()
        let face = Self.padFace3
        let before = try XCTUnwrap(faceCurves(m, face), "his Face 3")
        // Cancel: nothing written
        m.openFaceCurveModal(face, .flat2D)
        let r0 = m.curveDraft?.resets ?? -1
        m.mirrorDraftCurve(.along, .rightToLeft)
        XCTAssertEqual(m.curveDraft?.curves[.along], FlexibleCurveMirror.mirrored(before.0, .rightToLeft), "the draft mirrored")
        XCTAssertEqual(m.curveDraft?.resets, r0 + 1, "★ the tables' selection reset token bumped")
        m.copyDraftCurve(from: .along, to: .across)
        XCTAssertEqual(m.curveDraft?.curves[.across], m.curveDraft?.curves[.along], "★ copy X → Y exact")
        XCTAssertEqual(m.curveDraft?.resets, r0 + 2)
        let same = m.curveDraft
        m.copyDraftCurve(from: .along, to: .across)
        XCTAssertEqual(m.curveDraft, same, "a copy that changes nothing does nothing (greyed)")
        XCTAssertTrue(faceCurves(m, face)! == before, "★ nothing reaches the face while the window is open")
        m.closeCurveModal(keep: false)
        XCTAssertTrue(faceCurves(m, face)! == before, "★ Cancel: as before")
        // OK: kept; ONE undo returns both
        m.openFaceCurveModal(face, .table3D)
        m.mirrorDraftCurve(.along, .leftToRight)
        m.copyDraftCurve(from: .along, to: .across)
        let want = FlexibleCurveMirror.mirrored(before.0, .leftToRight)
        m.closeCurveModal(keep: true)
        let after = try XCTUnwrap(faceCurves(m, face))
        XCTAssertEqual(after.0, want, "★ OK keeps X mirrored"); XCTAssertEqual(after.1, want, "★ OK keeps Y = X")
        r.project.performUndo()
        XCTAssertTrue(faceCurves(m, face)! == before, "★ one Undo restores both curves")
        log.append("pad Face 3: before X \(fmt(before.0)) · OK X=Y \(fmt(want)) · one undo → X \(fmt(faceCurves(m, face)!.0))")
        // RED CONTROL: the actions written at once — Cancel keeps them
        FlexibleStageModel.controlActionWritesAtOnce = true
        m.openFaceCurveModal(face, .flat2D)
        m.mirrorDraftCurve(.along, .rightToLeft)
        m.closeCurveModal(keep: false)
        let red = try XCTUnwrap(faceCurves(m, face))
        FlexibleStageModel.controlActionWritesAtOnce = false
        log.append("RED written at once: after Cancel X \(fmt(red.0))")
        XCTAssertNotEqual(red.0, before.0, "RED CONTROL: Cancel kept the mirror")
        flush()
    }
}

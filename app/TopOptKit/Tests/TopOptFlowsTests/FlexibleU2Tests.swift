// FlexibleU2Tests — round 7, step U2: his notes of 2026-10-20, item 5 (img_1020_9) — the [↓] / [45°] buttons go; [2D] / [3D]
// open an edge's curves in a WINDOW OVER EVERYTHING: 2D = two tables, one above the other; 3D = both curves on one table, crossing
// as on the part, without the part, with the gizmo (Front: the across curve head-on; Top: the along curve); OK keeps, Cancel
// reverts (one undo step on OK). On HIS pad of 10-20 (round7/batch_u1/his_live_1020). Each RED control is asserted red inside
// its test. Pictures (13" portrait) only with FLEX_U2_DIR=<dir>.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class U2Win: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleU2Tests: XCTestCase {
    typealias Axis = FlexiblePressCurveBaselines.Axis
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_U2_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376)
    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }   // ★ U21 batch F: + what the layers drew
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    func hisPad() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel, FlexibleSqueezeGroup, [FlexiblePress]) {
        let r = try FlexibleHisProject.restore(FlexibleU1Tests.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad of 10-20")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges && $0.presses.count >= 2 }, "his edges group")
        let presses = g.presses.compactMap { m.press($0) }.filter { $0.strip?.kind == .edge }
        XCTAssertGreaterThanOrEqual(presses.count, 1, "an edge press")
        for p in presses { m.setPressShape(p.id, "curves") }
        m.save()
        return (r, m, g, presses)
    }
    func curves(_ m: FlexibleStageModel, _ id: UUID) -> [Axis: FlexCurve] {
        guard let p = m.press(id), let st = p.strip else { return [:] }
        var out: [Axis: FlexCurve] = [:]
        for a in FlexiblePressCurveBaselines.axes(st) { out[a] = FlexiblePressCurveBaselines.multipliers(p, a) }
        return out
    }
    static let bentAcross = FlexCurve(x: [0, 0.5, 1], y: [1, 0.4, 1])
    static let bentAlong = FlexCurve(x: [0, 0.3, 1], y: [1, 0.6, 1])

    // MARK: OK keeps (one undo step), Cancel reverts

    func testOKKeepsAndCancelReverts() async throws {
        let (r, m, _, presses) = try await hisPad()
        let id = presses[0].id
        let before = curves(m, id)
        XCTAssertEqual(Set(before.keys), [.across, .along])
        // Cancel: what it was before the window opened
        m.openCurveModal(id, .flat2D)
        XCTAssertEqual(m.curveDraft?.curves, before, "the window opens on the press's curves")
        m.setDraftCurve(.across, Self.bentAcross)
        m.setDraftCurve(.along, Self.bentAlong)
        XCTAssertEqual(curves(m, id), before, "nothing reaches the press while the window is open")
        m.closeCurveModal(keep: false)
        XCTAssertNil(m.curveDraft, "closed")
        XCTAssertEqual(curves(m, id), before, "Cancel: as before")
        // OK: both kept, ONE undo step returns both
        m.openCurveModal(id, .table3D)
        m.setDraftCurve(.across, Self.bentAcross)
        m.setDraftCurve(.along, Self.bentAlong)
        m.closeCurveModal(keep: true)
        XCTAssertNil(m.curveDraft)
        XCTAssertEqual(curves(m, id)[.across], Self.bentAcross, "OK keeps across")
        XCTAssertEqual(curves(m, id)[.along], Self.bentAlong, "OK keeps along")
        r.project.performUndo()
        XCTAssertEqual(curves(m, id), before, "one undo returns both curves (one step)")
        log.append("before \(before.mapValues(\.y)) · OK \(Self.bentAcross.y) \(Self.bentAlong.y) · one undo → \(curves(m, id).mapValues(\.y))")
        // RED CONTROL: every drag written at once (R7-E4's editing on the part)
        FlexiblePressCurveModal.controlLiveEdits = true
        m.openCurveModal(id, .flat2D)
        m.setDraftCurve(.across, Self.bentAcross)
        m.closeCurveModal(keep: false)
        let redCancel = curves(m, id)
        m.openCurveModal(id, .flat2D)
        m.setDraftCurve(.along, Self.bentAlong)
        m.closeCurveModal(keep: true)
        r.project.performUndo()
        let redUndo = curves(m, id)
        FlexiblePressCurveModal.controlLiveEdits = false
        XCTAssertNotEqual(redCancel[.across], before[.across], "RED CONTROL: Cancel kept the drag")
        XCTAssertNotEqual(redUndo, before, "RED CONTROL: one undo did not return everything")
        log.append("RED live edits: after Cancel across \(redCancel[.across]!.y); after OK + one undo \(redUndo.mapValues(\.y))")
        flush("U2_lines_ok_cancel.txt")
    }

    // MARK: 3D — one table, both curves crossing; the gizmo's Front / Top show each head-on

    func testThreeDIsOneTableAndTheGizmoShowsEachCurveHeadOn() async throws {
        let (_, m, _, presses) = try await hisPad()
        let p = presses[0]
        let st = try XCTUnwrap(p.strip)
        func check(_ cs: [FlexiblePressCurveModal.Curve3D]) -> (front: Bool, top: Bool, lines: String) {
            let cam = OrbitCameraModel(camera: FlexiblePressCurveModal.homeCamera(corner: false))
            func view(_ id: String) -> SIMD3<Double> {
                cam.snap(toID: id, animated: false)
                let d = cam.camera.direction
                return simd_normalize(SIMD3<Double>(Double(d.x), Double(d.y), Double(d.z)))
            }
            func dots(_ c: FlexiblePressCurveModal.Curve3D, _ v: SIMD3<Double>) -> (span: Double, up: Double) {
                let s = simd_normalize(c.baseline.at(1) - c.baseline.at(0))
                return (abs(simd_dot(s, v)), abs(simd_dot(simd_normalize(c.baseline.up), v)))
            }
            guard let across = cs.first(where: { $0.axis == .across }), let along = cs.first(where: { $0.axis == .along }) else { return (false, false, "-") }
            let f = view("Front"), t = view("Top")
            let fa = dots(across, f), fl = dots(along, f), ta = dots(across, t), tl = dots(along, t)
            let headOn: ((span: Double, up: Double)) -> Bool = { $0.span < 0.06 && $0.up < 0.06 }
            return (headOn(fa) && fl.span > 0.99, headOn(tl) && ta.span > 0.99,
                    String(format: "Front: across span·view %.3f up·view %.3f, along span·view %.3f · Top: along %.3f %.3f, across span·view %.3f",
                           fa.span, fa.up, fl.span, tl.span, tl.up, ta.span))
        }
        let cs = FlexiblePressCurveModal.curves3D(st, cut: m.flatCut(p.id))
        XCTAssertEqual(cs.map(\.axis), [.across, .along], "both curves on the one table")
        XCTAssertLessThan(simd_distance(cs[0].baseline.at(0.5), cs[1].baseline.at(0.5)), 1e-9, "they cross at their middles, as on the part")
        XCTAssertEqual(simd_dot(cs[0].baseline.up, cs[1].baseline.up), 1, accuracy: 1e-12, "both rise the same way (as on the part)")
        let ok = check(cs)
        log.append("U2 3D: " + ok.lines)
        XCTAssertTrue(ok.front, "Front shows the across curve head-on (the along curve edge-on)")
        XCTAssertTrue(ok.top, "Top shows the along curve head-on (the across curve edge-on)")
        // RED CONTROL: the part's own angle
        FlexiblePressCurveModal.controlModelAngle = true
        let red = check(FlexiblePressCurveModal.curves3D(st, cut: m.flatCut(p.id)))
        FlexiblePressCurveModal.controlModelAngle = false
        log.append("RED model angle: " + red.lines)
        XCTAssertFalse(red.front && red.top, "RED CONTROL: at the part's angle Front / Top do not show them head-on")
        flush("U2_lines_3d.txt")
    }

    // MARK: the Shape row's [2D] / [3D]; the window over the page (hosted, 13" portrait)

    func testTheShapeRowAndTheWindow() async throws {
        let (r, m, g, presses) = try await hisPad()
        let a = presses[0]
        let label = try XCTUnwrap(a.strip?.label)
        let loop = FlexibleSquishLoop()
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)
        m.rail = .group(g.id)
        m.selectedPress = a.id
        pump(2)
        func row() -> String {
            let f = h.frames.all
            return "shape \(f["pressShape-\(label)"].map { "\(Int($0.minY))-\(Int($0.maxY))" } ?? "-") · 2D \(f["pressCurves-2d"].map { "\(Int($0.midX)),\(Int($0.midY))" } ?? "-") · 3D \(f["pressCurves-3d"].map { "\(Int($0.midX)),\(Int($0.midY))" } ?? "-") · [↓] \(f["pressView-top"] != nil) · [45°] \(f["pressView-deg45"] != nil)"
        }
        log.append("U2 row: " + row())
        let shape = try XCTUnwrap(h.frames.all["pressShape-\(label)"], "the Shape row")
        let b2 = try XCTUnwrap(h.frames.all["pressCurves-2d"], "[2D]"), b3 = try XCTUnwrap(h.frames.all["pressCurves-3d"], "[3D]")
        XCTAssertNil(h.frames.all["pressView-top"], "no [↓]"); XCTAssertNil(h.frames.all["pressView-deg45"], "no [45°]")
        for b in [b2, b3] { XCTAssertTrue(shape.minY - 1 <= b.midY && b.midY <= shape.maxY + 1, "on the Shape row's one line") }
        if let panel = h.frames.all["panel"] { XCTAssertLessThanOrEqual(b3.maxX, panel.maxX + 1, "inside the panel") }
        // RED CONTROL: R7-E4's buttons
        FlexiblePressCurveModal.controlOldViewButtons = true
        m.selectedPress = presses.count > 1 ? presses[1].id : nil
        pump(1.5)
        m.selectedPress = a.id
        pump(1.5)
        let redRow = row()
        FlexiblePressCurveModal.controlOldViewButtons = false
        log.append("RED old buttons: " + redRow)
        XCTAssertTrue(h.frames.all["pressView-top"] != nil && h.frames.all["pressCurves-2d"] == nil, "RED CONTROL: [↓] / [45°] back")
        m.selectedPress = presses.count > 1 ? presses[1].id : nil
        pump(1.5)
        m.selectedPress = a.id
        pump(1.5)
        // 2D: two tables, one above the other, in the window over everything
        m.openCurveModal(a.id, .flat2D)
        m.setDraftCurve(.across, Self.bentAcross)   // (bent, so the pictures show the curves' shapes)
        m.setDraftCurve(.along, Self.bentAlong)
        pump(1.5)
        let f2 = h.frames.all
        let modal = try XCTUnwrap(f2["curveModal"], "the window")
        let ta = try XCTUnwrap(f2["curveTable-across"], "the across table"), tl = try XCTUnwrap(f2["curveTable-along"], "the along table")
        log.append("U2 2D: window \(modal.integral) · across \(ta.integral) · along \(tl.integral) · 3D table \(f2["curveTable3D"] != nil)")
        XCTAssertLessThanOrEqual(ta.maxY, tl.minY + 1, "across above along (two tables)")
        XCTAssertTrue(modal.insetBy(dx: -1, dy: -1).contains(ta) && modal.insetBy(dx: -1, dy: -1).contains(tl), "both in the window")
        XCTAssertNil(f2["curveTable3D"], "no 3D table in 2D")
        if let pg = f2["page"] { XCTAssertTrue(pg.insetBy(dx: -1, dy: -1).contains(modal), "on the page") }
        try shot("U2_01_13p_2d_two_tables.png", h, settle: 1)
        // RED CONTROL: both curves on one table
        FlexiblePressCurveModal.controlOneTable = true
        m.setCurveModalMode(.table3D); pump(0.8); m.setCurveModalMode(.flat2D); pump(1.2)
        let redTables = h.frames.all.keys.filter { $0.hasPrefix("curveTable-") }.sorted()
        FlexiblePressCurveModal.controlOneTable = false
        log.append("RED one table: \(redTables)")
        XCTAssertEqual(redTables, ["curveTable-both"], "RED CONTROL: one table")
        // 3D: one table with both curves, and the gizmo
        m.setCurveModalMode(.table3D)
        pump(1.5)
        let f3 = h.frames.all
        let t3 = try XCTUnwrap(f3["curveTable3D"], "the 3D table")
        let gz = try XCTUnwrap(f3["curveGizmo"], "the gizmo")
        XCTAssertTrue(f3.keys.filter { $0.hasPrefix("curveTable-") }.isEmpty, "no 2D tables in 3D")
        XCTAssertTrue(t3.insetBy(dx: -1, dy: -1).contains(gz), "the gizmo on the table")
        try shot("U2_02_13p_3d_one_table.png", h, settle: 1)
        let cam = try XCTUnwrap(FlexiblePressCurveModalView.shownCamera, "the window's camera")
        let cs = FlexiblePressCurveModal.curves3D(try XCTUnwrap(a.strip), cut: m.flatCut(a.id))
        let size = CGSize(width: t3.width, height: t3.height - 24)
        func onScreen(_ c: FlexiblePressCurveModal.Curve3D) -> (span: CGFloat, rise: CGFloat) {
            let pr = CameraProjection(camera: cam.camera, viewportSize: size)
            func d(_ u: SIMD3<Double>, _ v: SIMD3<Double>) -> CGFloat {
                guard let p = pr.project(SIMD3<Float>(u)), let q = pr.project(SIMD3<Float>(v)) else { return -1 }
                return hypot(p.x - q.x, p.y - q.y)
            }
            return (d(c.baseline.at(0), c.baseline.at(1)), d(c.baseline.at(0.5), c.baseline.world(0.5, 1)))
        }
        for (view, headOn, edgeOn, file) in [("Front", Axis.across, Axis.along, "U2_03_13p_3d_front_across_head_on.png"),
                                              ("Top", Axis.along, Axis.across, "U2_04_13p_3d_top_along_head_on.png")] {
            cam.snap(toID: view, animated: false)
            pump(0.8)
            let hc = try XCTUnwrap(cs.first { $0.axis == headOn }), ec = try XCTUnwrap(cs.first { $0.axis == edgeOn })
            let a1 = onScreen(hc), e1 = onScreen(ec)
            log.append(String(format: "%@: %@ span %.1f pt rise %.1f pt · %@ span %.1f pt", view, headOn.rawValue, a1.span, a1.rise, edgeOn.rawValue, e1.span))
            XCTAssertGreaterThan(a1.span, 100, "\(view): \(headOn) seen at full length")
            XCTAssertGreaterThan(a1.rise, 0.4 * a1.span * CGFloat(FlexiblePressCurveModal.rise / FlexiblePressCurveModal.span), "\(view): its height seen")
            XCTAssertLessThan(e1.span, 0.08 * a1.span, "\(view): \(edgeOn) edge-on")
            let pr = CameraProjection(camera: cam.camera, viewportSize: size)
            XCTAssertTrue(FlexiblePressCurveModal.editable(hc, pr), "\(view): \(headOn) is edited here")
            XCTAssertFalse(FlexiblePressCurveModal.editable(ec, pr), "\(view): \(edgeOn)'s handles do not sit on it")
            try shot(file, h, settle: 0.6)
        }
        m.closeCurveModal(keep: true)
        pump(1)
        XCTAssertNil(h.frames.all["curveModal"], "OK closes the window")
        XCTAssertEqual(curves(m, a.id)[.across], Self.bentAcross, "OK kept the window's curves")
        flush("U2_lines_row_window.txt")
    }

    // MARK: ★ U21 (DEL-CONFIRM, his Img13) — [Keep] sits on the tapped control; the red button a move away (his 10-21 pad)

    func click(_ h: Host, _ p: CGPoint) {
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
        pump(0.6)
    }

    struct Asked { let control: CGRect; let keep: CGRect?; let confirm: CGRect?
        var keepOnSpot: Bool { keep.map { abs($0.midX - control.midX) <= 1 && abs($0.midY - control.midY) <= 1 } ?? false }
        var clear: Bool { if let k = keep, let c = confirm { return c.maxX <= k.minX - FlexibleConfirmLayout.gap + 0.5 }; return false }
        /// ★ U21 fix round 2 (the check): the red button ≥ 24 pt clear of the control he TAPPED (its own frame, not Keep's).
        var clearOfControl: Bool {
            guard let c = confirm else { return false }
            return c.maxX <= control.minX - FlexibleConfirmLayout.gap + 0.5 || c.minX >= control.maxX + FlexibleConfirmLayout.gap - 0.5
        }
        var line: String { "control \(control.integral) · keep \(keep.map { "\($0.integral)" } ?? "-") · red \(confirm.map { "\($0.integral)" } ?? "-") · on spot \(keepOnSpot) · ≥24 pt clear \(clear) · ≥24 pt clear of the tapped control \(clearOfControl)" }
    }

    /// Click `controlKey`, measure the ask, then click the SAME spot again (a double tap): it only cancels.
    func ask(_ h: Host, _ controlKey: String, keep: String, confirm: String, secondTap: Bool = true, picture: String? = nil,
             asking: () -> Bool, kept: () -> Bool) throws -> Asked {
        let c = try XCTUnwrap(h.frames.all[controlKey], "the control \(controlKey)")
        click(h, CGPoint(x: c.midX, y: c.midY))
        XCTAssertTrue(pumpUntil(3, asking), "★ \(controlKey) asks first")
        pump(0.4)
        let a = Asked(control: c, keep: h.frames.all[keep], confirm: h.frames.all[confirm])
        if let picture { try shot(picture, h, settle: 0.2) }
        XCTAssertTrue(kept(), "★ \(controlKey): nothing removed before the confirm")
        guard secondTap else { return a }
        click(h, CGPoint(x: c.midX, y: c.midY))   // the same spot again
        XCTAssertTrue(pumpUntil(3) { !asking() }, "★ \(controlKey): a second tap on the spot only cancels")
        XCTAssertTrue(kept(), "★ \(controlKey): still there")
        return a
    }

    func testU21ConfirmKeepSitsOnTheTappedControl() async throws {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle(); FlexibleConfirmInPlace.controlOldPlacement = false }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad of 10-21")
        let faces = try XCTUnwrap(m.squeezeGroups.first { $0.regions.contains(5) }, "premise: Faces 5 + 3")
        let edges = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges }, "premise: his edges group")
        let e12 = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" })
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: FlexibleSquishLoop(), onExit: {}), size: Self.p13)
        pump(3)
        m.rail = .group(faces.id); m.select(5); pump(1.5)
        var lines: [String] = []
        let face = try ask(h, "faceRemove-5", keep: "faceRemoveKeep", confirm: "faceRemoveConfirm", picture: "U21_D1_13p_face_take_out_asks.png",
                           asking: { m.faceRemoveAsk == 5 }, kept: { m.settings.face(5) != nil })
        lines.append("face ⊖: " + face.line)
        let group = try ask(h, "groupRemove-\(faces.number)", keep: "groupDeleteKeep", confirm: "groupDeleteConfirm", picture: "U21_D2_13p_group_trash_asks.png",
                            asking: { m.groupDeleteAsk == faces.id }, kept: { m.railGroup(faces.id) != nil })
        lines.append("group trash: " + group.line)
        let reset = try ask(h, "resetAll", keep: "resetCancel", confirm: "resetConfirm", picture: "U21_D3_13p_reset_all_asks.png",
                            asking: { m.resetAsk }, kept: { m.settings.face(5) != nil })
        lines.append("Reset all: " + reset.line)
        m.rail = .group(edges.id); m.selectedPress = e12.id; pump(1.5)
        let press = try ask(h, "pressRemove-Edge 12", keep: "pressRemoveKeep", confirm: "pressRemoveConfirm", picture: "U21_D4_13p_edge_trash_asks.png",
                            asking: { m.pressRemoveAsk == e12.id }, kept: { m.settings.press(e12.id) != nil })
        lines.append("edge trash: " + press.line)
        for (name, a) in [("face ⊖", face), ("group trash", group), ("Reset all", reset), ("edge trash", press)] {
            XCTAssertTrue(a.keepOnSpot, "★ \(name): [Keep] centred on the tapped control ±1 pt (\(a.line))")
            XCTAssertTrue(a.clear, "★ \(name): the red button ≥ 24 pt left of [Keep] (\(a.line))")
            XCTAssertTrue(a.clearOfControl, "★ \(name): the red button ≥ 24 pt clear of the tapped control (\(a.line))")
            if let k = a.keep { XCTAssertGreaterThanOrEqual(k.height, 44 - 0.5, "\(name): a 44 pt target") }
        }
        // the confirm itself: [Take out] removes Face 5
        m.rail = .group(faces.id); m.select(5); pump(1.5)
        let c5 = try XCTUnwrap(h.frames.all["faceRemove-5"])
        click(h, CGPoint(x: c5.midX, y: c5.midY))
        let red5 = try XCTUnwrap(h.frames.all["faceRemoveConfirm"], "[Take out]")
        click(h, CGPoint(x: red5.midX, y: red5.midY))
        XCTAssertTrue(pumpUntil(3) { m.settings.face(5) == nil }, "★ [Take out]: Face 5 leaves the squish")
        try shot("U21_D5_13p_after_take_out.png", h, settle: 0.2)   // (Face 3's card now)
        // RED CONTROL: the old placement — Keep past the red button, off the tapped spot
        FlexibleConfirmInPlace.controlOldPlacement = true
        m.select(3); pump(1.2)
        let red = try ask(h, "faceRemove-3", keep: "faceRemoveKeep", confirm: "faceRemoveConfirm", secondTap: false,
                          asking: { m.faceRemoveAsk == 3 }, kept: { m.settings.face(3) != nil })
        m.keepFace()
        FlexibleConfirmInPlace.controlOldPlacement = false
        lines.append("RED old placement (face ⊖): " + red.line)
        XCTAssertFalse(red.keepOnSpot, "RED CONTROL: [Keep] off the tapped spot")
        log = lines
        flush("u21_d_confirm_lines.txt")
    }

    // MARK: ★ U21 FIX ROUND 1 — the check's blocker and should-fix items, hosted (13" portrait, his projects of 10-21)

    func padModel() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in
            await m.waitForIdle()
            FlexibleStageModel.controlRemoveAtOnce = false
            FlexibleConfirmInPlace.controlRedAlwaysLeading = false
            FlexibleConfirmInPlace.controlGapFromKeepOnly = false
            FlexibleStageModel.controlTakeOutFullName = false
            FlexibleStageSheet.controlBlankBlock = false
        }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad of 10-21")
        return (r, m)
    }

    /// The Lattice page's callout (and the card's Core row: the same view), the Squish page's pop-up and the edges card's warning
    /// row: a Remove fix asks in place — [Keep] on the button, the red [Remove] ≥ 24 pt away and INSIDE its row (to the right for
    /// the row's first fix). RED: the code before (removed at once); the red always on the left (a first fix's leaves its row).
    func testU21FixRowsRemoveAskInPlace() async throws {
        let (_, m) = try await padModel()
        let e12 = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" }, "premise: his Edge 12")
        let pf = FlexiblePressFix.remove(e12.id, label: "Edge 12")
        let second = FlexibleIssue(id: "u21-a", kind: .refused, region: 5, oneLine: "Face 5 can't be squished here", blocking: true,
                                   fixes: [.rest(5), .remove(5)])
        let first = FlexibleIssue(id: "u21-b", kind: .pressKeptOut, region: nil, oneLine: "Edge 12 is kept out of the job", blocking: true,
                                  fixes: [.pressFix(pf)])
        let popupFirst = FlexibleIssue(id: "u21-c", kind: .refused, region: 5, oneLine: "Face 5 can't be squished here", blocking: true,
                                       fixes: [.remove(5), .rest(5)])
        var pad: String? = nil
        let padBinding = Binding<String?>(get: { pad }, set: { pad = $0 })
        let view = VStack(alignment: .leading, spacing: 40) {
            FlexibleCalloutButtons(model: m, issue: second, close: {}, squish: {})
                .background(FlexibleConfirmInPlace.publish("rowCalloutSecond"))
            FlexibleCalloutButtons(model: m, issue: first, scope: "card", close: {}, squish: {})
                .background(FlexibleConfirmInPlace.publish("rowCardFirst"))
            FlexibleFixPopup(model: m, issue: popupFirst, padTarget: padBinding, onDone: {})
                .background(FlexibleConfirmInPlace.publish("rowPopup"))
            FlexiblePressFixButtons(model: m, fixes: [pf])
                .background(FlexibleConfirmInPlace.publish("rowPress"))
        }
        .padding(40).frame(width: 600, alignment: .topLeading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Color.background.color)
        let h = host(view, size: Self.p13)
        pump(1.5)
        struct Case { let name, control, row, scope: String; let first: Bool; let asking: String; let kept: () -> Bool }
        let cases: [Case] = [
            Case(name: "callout [Remove Face 5] (second)", control: "callout-remove-5", row: "rowCalloutSecond", scope: "callout", first: false,
                 asking: FlexibleFixAsk.key("callout", "remove-5"), kept: { m.settings.face(5) != nil }),
            Case(name: "card [Remove Edge 12] (first)", control: "card-press-fix-" + pf.id, row: "rowCardFirst", scope: "card", first: true,
                 asking: FlexibleFixAsk.key("card", "press-fix-" + pf.id), kept: { m.settings.press(e12.id) != nil }),
            Case(name: "pop-up [Remove Face 5] (first)", control: "fix-remove-5", row: "rowPopup", scope: "popup", first: true,
                 asking: FlexibleFixAsk.key("popup", "remove-5"), kept: { m.settings.face(5) != nil }),
            Case(name: "warning row [Remove Edge 12] (first)", control: "press-" + pf.id, row: "rowPress", scope: "pressFix", first: true,
                 asking: FlexibleFixAsk.key("pressFix", pf.id), kept: { m.settings.press(e12.id) != nil }),
        ]
        var lines: [String] = []
        func run(_ c: Case) throws -> (Asked, CGRect) {
            let row = try XCTUnwrap(h.frames.all[c.row], c.row)
            let a = try ask(h, c.control, keep: c.scope + "RemoveKeep", confirm: c.scope + "RemoveConfirm",
                            asking: { m.fixRemoveAsk == c.asking }, kept: c.kept)
            return (a, row)
        }
        for c in cases {
            let (a, row) = try run(c)
            let red = a.confirm ?? .zero
            let side = c.first ? (red.minX >= (a.keep?.maxX ?? 0) + FlexibleConfirmLayout.gap - 0.5) : a.clear
            // (the row's own frame hugs its buttons: a first fix's red [Remove] starts inside it and runs past its trailing end
            // into the card's free width — recorded, not claimed as "inside")
            let inside = red.minX >= row.minX - 0.5
            lines.append("\(c.name): \(a.line) · row x \(Int(row.minX))…\(Int(row.maxX)) · red \(c.first ? "right" : "left") clear \(side) · starts in the row \(inside) · red ends \(Int(red.maxX - row.minX)) pt from the row's start")
            XCTAssertTrue(a.keepOnSpot, "★ \(c.name): [Keep] on the tapped button (\(a.line))")
            XCTAssertTrue(side, "★ \(c.name): the red button ≥ 24 pt from [Keep] (\(a.line))")
            XCTAssertTrue(a.clearOfControl, "★ \(c.name): the red button ≥ 24 pt clear of the button he tapped (\(a.line))")
            XCTAssertFalse(red.intersects(a.control), "★ \(c.name): the red button off the tapped button (red \(red.integral), button \(a.control.integral))")
            XCTAssertGreaterThanOrEqual((a.keep ?? .zero).width, a.control.width - 0.5, "★ \(c.name): [Keep] covers the whole button")
            XCTAssertTrue(inside, "★ \(c.name): the red button starts inside its row (red \(red.integral), row \(row.integral))")
            // (the narrowest panel these rows sit in: the mini's 336 pt less its 14 pt sides — the red's end must fit it)
            let narrowest = FlexibleChromeLayout.panelWidth(CGSize(width: 744, height: 1133)) - 2 * DS.Space.ml
            XCTAssertLessThanOrEqual(red.maxX - row.minX, narrowest, "★ \(c.name): the red button ends within the narrowest panel's \(Int(narrowest)) pt")
        }
        // the confirm itself (the warning row): [Remove] removes Edge 12
        let pc = try XCTUnwrap(h.frames.all["press-" + pf.id])
        click(h, CGPoint(x: pc.midX, y: pc.midY))
        let rr = try XCTUnwrap(h.frames.all["pressFixRemoveConfirm"], "[Remove]")
        try shot("U21_D6_13p_fix_rows_remove_asks.png", h, settle: 0.2)
        click(h, CGPoint(x: rr.midX, y: rr.midY))
        lines.append("after the [Remove] click at \(rr.integral): ask \(m.fixRemoveAsk ?? "nil")")
        XCTAssertNil(m.fixRemoveAsk, "★ the [Remove] click lands (the ask closes)")
        // (the strip removal is an async main-actor task: awaited, not pumped — a nested run loop never runs the main actor's jobs)
        try await FlexibleHisProject.waitFor(60, "★ [Remove]: Edge 12 goes") { m.settings.press(e12.id) == nil }
        XCTAssertNil(m.settings.press(e12.id), "★ [Remove]: Edge 12 goes")
        pump(0.5)
        // RED CONTROL 0 (fix round 2): [Keep] 64 pt wide, the gap measured from Keep — the red [Remove] over the wide button
        FlexibleConfirmInPlace.controlGapFromKeepOnly = true
        for i in [0, 2] {
            let (ga, _) = try run(cases[i])
            lines.append("RED gap from Keep only (\(cases[i].name)): \(ga.line)")
            XCTAssertTrue((ga.confirm ?? .zero).intersects(ga.control), "RED CONTROL: the red [Remove] over the button he tapped (\(ga.line))")
            XCTAssertFalse(ga.clearOfControl, "RED CONTROL: not 24 pt clear of the tapped button")
        }
        FlexibleConfirmInPlace.controlGapFromKeepOnly = false
        // RED CONTROL 1: a first fix's red button on the left leaves its row
        FlexibleConfirmInPlace.controlRedAlwaysLeading = true
        let (ra, rrow) = try run(cases[2])
        FlexibleConfirmInPlace.controlRedAlwaysLeading = false
        lines.append("RED red always left (pop-up first fix): \(ra.line) · row x \(Int(rrow.minX))")
        XCTAssertLessThan(ra.confirm?.minX ?? 0, rrow.minX, "RED CONTROL: the red [Remove] outside the pop-up's row")
        // RED CONTROL 2: the code before this round — the callout's [Remove Face 5] on one tap
        FlexibleStageModel.controlRemoveAtOnce = true
        let c5 = try XCTUnwrap(h.frames.all["callout-remove-5"])
        click(h, CGPoint(x: c5.midX, y: c5.midY))
        FlexibleStageModel.controlRemoveAtOnce = false
        XCTAssertNil(m.settings.face(5), "RED CONTROL: the callout's [Remove Face 5] removed at once")
        lines.append("RED one tap (callout): Face 5 removed at once \(m.settings.face(5) == nil)")
        log = lines
        flush("u21_d_fix_rows_lines.txt")
    }

    /// His screenshot's state (22.png): the l-bracket, Group 1 = Face 6 (its section "Face 6 · lattice"), the ⊖ tapped — the
    /// question stays inside the panel (the check: it likely drew over the Group tab). RED: the whole section name in the question.
    func testU21TakeOutAskFitsThePanelOnHisLBracket() async throws {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle(); FlexibleStageModel.controlTakeOutFullName = false }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his l-bracket of 10-21")
        let face = 2000008
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.regions == [face] }, "premise: Group 1 = Face 6")
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: FlexibleSquishLoop(), onExit: {}), size: Self.p13)
        pump(3)
        m.rail = .group(g.id); m.select(face); pump(1.5)
        var lines: [String] = ["row name: \(m.displayName(face))"]
        func measure(_ picture: String?) throws -> (q: CGRect, panel: CGRect, rail: CGRect?) {
            let a = try ask(h, "faceRemove-\(face)", keep: "faceRemoveKeep", confirm: "faceRemoveConfirm", secondTap: false, picture: picture,
                            asking: { m.faceRemoveAsk == face }, kept: { m.settings.face(face) != nil })
            let q = try XCTUnwrap(h.frames.all["faceRemoveConfirmQuestion"], "the question")
            let panel = try XCTUnwrap(h.frames.all["panel"], "the panel")
            lines.append("\(a.line) · question \(q.integral) · panel \(panel.integral) · rail \(h.frames.all["rail"].map { "\($0.integral)" } ?? "-")")
            m.keepFace(); pump(0.6)
            return (q, panel, h.frames.all["rail"])
        }
        let a = try measure("U21_D7_13p_lbracket_take_out_asks.png")
        XCTAssertGreaterThanOrEqual(a.q.minX, a.panel.minX + 4, "★ the question inside the panel (question \(a.q.integral), panel \(a.panel.integral))")
        let rail = try XCTUnwrap(a.rail, "the rail")
        XCTAssertGreaterThanOrEqual(a.q.minX, rail.maxX + 8, "★ clear of the rail's tabs (question x \(Int(a.q.minX)), rail ends \(Int(rail.maxX)))")
        // RED CONTROL: the whole section name
        FlexibleStageModel.controlTakeOutFullName = true
        let red = try measure(nil)
        FlexibleStageModel.controlTakeOutFullName = false
        lines.append("RED whole name: question x \(Int(red.q.minX)) vs panel x \(Int(red.panel.minX))")
        XCTAssertLessThan(red.q.minX, a.q.minX - 30, "RED CONTROL: the whole name reaches \(Int(a.q.minX - red.q.minX)) pt further left")
        XCTAssertLessThan(red.q.minX, (red.rail ?? rail).maxX + 8, "RED CONTROL: the whole name runs into the rail's tabs (his 22.png state)")
        log = lines
        flush("u21_d_lbracket_take_out_lines.txt")
    }

    /// ★ U21 BATCH E (his Img11/12/14): the one no-lattice notice ON THE PAGE, in the fix pop-up's place, on his l-bracket —
    /// a tap on Face 5, on Face 1, on Face 2's solid rim, and Face 5 once pressed (its card: "No lattice under it" + [Go to
    /// Lattice]). Pictures only with FLEX_U2_DIR (13" portrait).
    func testU21NoLatticeNoticeOnThePage() async throws {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his l-bracket of 10-21")
        var left = 0
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: FlexibleSquishLoop(), onExit: { left += 1 }), size: Self.p13)
        pump(3)
        var lines: [String] = []
        let T = FlexibleU21OneLatticeRuleTests.self
        for (face, p, pic) in [(5, T.face5, "U21_E1_13p_tap_face5_notice.png"), (1, T.face1, "U21_E2_13p_tap_face1_notice.png"),
                               (2, T.face2Rim, "U21_E3_13p_tap_face2_rim_notice.png")] {
            m.tapFace(face, point: p)
            XCTAssertTrue(pumpUntil(3) { h.frames.all["popup"] != nil }, "★ Face \(face): the notice shows in the pop-up's place")
            try shot(pic, h, settle: 0.4)
            lines.append("tap Face \(face): popup \(h.frames.all["popup"].map { "\($0.integral)" } ?? "-") · '\(m.noLatticeTap?.oneLine ?? "-")' · fixes \(h.frames.all.keys.filter { $0.hasPrefix("fix-") }.sorted()) · toast \(m.toast ?? "-")")
            XCTAssertNil(h.frames.all["toastFix"], "★ never the old toast's [Go to Lattice]")
        }
        // the [Go to Lattice] button on the page leaves (the page's Exit: saved, no bake)
        let go = try XCTUnwrap(h.frames.all["fix-go-to-lattice"], "the [Go to Lattice] button")
        click(h, CGPoint(x: go.midX, y: go.midY))
        XCTAssertTrue(pumpUntil(3) { left == 1 }, "★ [Go to Lattice] leaves for the Lattice page")
        lines.append("[Go to Lattice] clicked at \(go.integral): left \(left), exitUnchanged \(m.exitUnchanged)")
        // Face 5 pressed (an old save's state): the card's row and the same sentence
        XCTAssertTrue(m.press(5, kg: 4.5))
        try await FlexibleSquishFixture.settle(m, "Face 5 pressed")
        if let g = m.squeezeGroup(of: 5) { m.rail = .group(g.id) }
        m.select(5); pump(1.5)
        try shot("U21_E4_13p_face5_pressed_card.png", h, settle: 0.6)
        lines.append("Face 5 pressed: own lattice \(m.hasOwnLattice(5)) · deepest \(m.latticeMaxMM(5) ?? -1) · issue '\(FlexibleLatticeUnder.first(m.readiness)?.oneLine ?? "-")'")
        log = lines
        flush("u21_e_notice_lines.txt")
    }

    /// ★ U21 batch F (his Img9 / Img8 of 2026-10-21, his l-bracket, 13" portrait, Prisms + X-ray as in his 19.png): ONE number on
    /// the working face (its chip, "0.6 of 7.0 mm" where core builds short), no bend tag over it; with no face selected the tag
    /// reads true mm. RED (today's tag kept on the working face): the tag's frame on the chip's.
    func testU21OneDepthNumberOnThePage() async throws {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        addTeardownBlock { @MainActor in FlexibleBendPrism.controlTagOnWorkingFace = false }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his l-bracket of 10-21")
        let face = 2000008
        if let g = m.squeezeGroup(of: face) { m.rail = .group(g.id) }
        func depth(_ mm: Double) async throws {
            m.edit { st in guard var f = st.face(face) else { return }; f.deepestMM = mm; st.setFace(f) }
            try await FlexibleSquishFixture.settle(m, "\(mm) mm")
            try await FlexibleHisProject.waitFor(120, "Auto") { !m.autoInFlight && !m.designsInFlight && !m.readiness.designing }
        }
        try await depth(7)
        m.views = [.heatOff, .prisms, .xray]
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: FlexibleSquishLoop(), onExit: {}), size: Self.p13)
        pump(3)
        // his 19.png's camera: the LEFT view, a little from above (the plate's top and its prism in sight)
        func leftView() throws {
            let cm = try XCTUnwrap(cameraModel(h), "the page's camera")
            cm.snap(toID: "Left", animated: false)
            var cam = cm.camera
            cam.setOrientation(azimuth: cam.azimuth, elevation: 0.2)
            cm.adopt(cam)
            pump(1.5)
        }
        try leftView()
        var lines: [String] = []
        func state(_ name: String) -> String {
            let chip = h.frames.marks["depthChip-\(face)"], tag = h.frames.marks["bendTag"]
            let over = chip.flatMap { c in tag.map { $0.intersects(c.insetBy(dx: -12, dy: -12)) } } ?? false
            return "\(name): chip \(chip.map { "\($0.integral)" } ?? "-") '\(FlexibleDepthChips.chipText(m.settings.face(face)?.deepestMM ?? 0, reached: m.reached(region: face)))' · bend tag \(tag.map { "\($0.integral)" } ?? "none") · within 12 pt of the chip \(over) · card '\(FlexibleFaceRows.warning(model: m, region: face) ?? "-")' · prisms tag \(h.frames.marks["tag-\(face)"].map { "\($0.integral)" } ?? "-")"
        }
        XCTAssertTrue(pumpUntil(5) { h.frames.marks["depthChip-\(face)"] != nil }, "★ the chip's frame is collected")
        try shot("U21_F1_13p_img9_7mm_prisms_xray.png", h, settle: 0.6)
        lines.append(state("Img9 7 mm"))
        XCTAssertNil(h.frames.marks["bendTag"], "★ no bend tag over the working face's chip (Img9's 14)")
        // RED CONTROL: today's tag on the working face, on the chip
        FlexibleBendPrism.controlTagOnWorkingFace = true
        m.views = [.heatOff, .prisms, .xray, .bend]; pump(0.6); m.views = [.heatOff, .prisms, .xray]   // (re-run the page's channels)
        XCTAssertTrue(pumpUntil(4) { h.frames.marks["bendTag"] != nil }, "RED CONTROL: today's tag shows")
        let redChip = try XCTUnwrap(h.frames.marks["depthChip-\(face)"]), redTag = try XCTUnwrap(h.frames.marks["bendTag"])
        lines.append("RED (today) " + state("7 mm"))
        XCTAssertTrue(redTag.intersects(redChip.insetBy(dx: -12, dy: -12)), "RED CONTROL: the tag on the chip (the drag handle)")
        FlexibleBendPrism.controlTagOnWorkingFace = false
        m.views = [.heatOff, .prisms, .xray, .bend]; pump(0.6); m.views = [.heatOff, .prisms, .xray]
        XCTAssertTrue(pumpUntil(4) { h.frames.marks["bendTag"] == nil }, "★ gone again")
        try await depth(3)
        pump(1)
        try leftView()   // (the edit's re-settle turned the camera back)
        try shot("U21_F2_13p_img8_3mm_prisms_xray.png", h, settle: 0.6)
        lines.append(state("Img8 3 mm"))
        XCTAssertNotNil(h.frames.marks["depthChip-\(face)"], "★ the chip (the drag handle) shows")
        XCTAssertNil(h.frames.marks["bendTag"], "★ nothing over it (Img8)")
        // no face selected, X-ray alone: the prism keeps its number, in true mm
        m.selectedRegion = nil
        m.views = [.heatOff, .xray]
        pump(1.5)
        try leftView()
        try shot("U21_F3_13p_3mm_no_face_selected.png", h, settle: 0.6)
        lines.append(state("3 mm, no face selected"))
        log = lines
        flush("u21_f_depth_lines.txt")
    }

    /// "Delete Flexible lattice" (the Lattice page's sheet): [Cancel] centred on the button; the glass ends under the button until
    /// it asks (the check: a blank block). RED: the blank block (the glass reaching the hidden lines).
    func testU21DeleteLatticeSheetCancelOnTheButton() throws {
        var deleted = 0
        // (the sheet's own window: the page's full-screen size, as the app presents it)
        let h = host(FlexibleStageSheet(onDelete: { deleted += 1 }, onClose: {}).frame(width: Self.p13.width, height: Self.p13.height), size: Self.p13)
        addTeardownBlock { @MainActor in FlexibleStageSheet.controlBlankBlock = false; FlexibleStageSheet.controlOffCentre = false }
        pump(1.2)
        let b = try XCTUnwrap(h.frames.all["latticeModeDelete"], "the button")
        let glass = try XCTUnwrap(h.frames.all["stageSheetGlass"], "the glass")
        var lines = ["button \(b.integral) · glass \(glass.integral) (not asking) · window height \(Int(Self.p13.height))"]
        // ★ U21 fix round 2 (the check: the visible sheet sat above centre, glass 319-955 in 1376): the glass is centred
        XCTAssertEqual(glass.midY, Self.p13.height / 2, accuracy: 2, "★ the glass shown before the ask is centred on the page (\(glass.integral))")
        XCTAssertLessThanOrEqual(glass.maxY - b.maxY, DS.Space.xl4 + 1, "★ the glass ends under the button (no blank block)")
        XCTAssertGreaterThanOrEqual(glass.maxY - b.maxY, DS.Space.xl4 - 1)
        try shot("U21_D8_13p_delete_sheet_before.png", h, settle: 0.2)
        click(h, CGPoint(x: b.midX, y: b.midY))
        pump(0.4)
        let c = try XCTUnwrap(h.frames.all["latticeModeDeleteCancel"], "[Cancel]")
        let red = try XCTUnwrap(h.frames.all["latticeModeDeleteConfirm"], "[Delete Flexible lattice]")
        let g2 = try XCTUnwrap(h.frames.all["stageSheetGlass"])
        let b2 = try XCTUnwrap(h.frames.all["latticeModeDelete"])
        lines.append("asking: button \(b2.integral) · cancel \(c.integral) · red \(red.integral) · glass \(g2.integral)")
        try shot("U21_D9_13p_delete_sheet_asks.png", h, settle: 0.2)
        XCTAssertEqual(b2.midY, b.midY, accuracy: 1, "★ the button did not move")
        XCTAssertEqual(c.midX, b.midX, accuracy: 1, "★ [Cancel] centred on the button (x)")
        XCTAssertEqual(c.midY, b.midY, accuracy: 1, "★ [Cancel] centred on the button (y)")
        XCTAssertGreaterThanOrEqual(red.minY, c.maxY, "★ the red button on a line under it (a move)")
        XCTAssertGreaterThanOrEqual(g2.maxY, red.maxY, "★ the glass reaches the red button while asking")
        XCTAssertEqual(deleted, 0, "nothing deleted yet")
        click(h, CGPoint(x: c.midX, y: c.midY))   // the same spot again: Cancel
        pump(0.4)
        XCTAssertNil(h.frames.all["latticeModeDeleteCancel"], "★ a second tap on the spot only cancels")
        XCTAssertEqual(deleted, 0)
        // RED CONTROL: the blank block
        FlexibleStageSheet.controlBlankBlock = true
        let h2 = host(FlexibleStageSheet(onDelete: {}, onClose: {}).frame(width: Self.p13.width, height: Self.p13.height), size: Self.p13)
        pump(1.2)
        let rb = try XCTUnwrap(h2.frames.all["latticeModeDelete"]), rg = try XCTUnwrap(h2.frames.all["stageSheetGlass"])
        lines.append("RED blank block: glass bottom \(Int(rg.maxY - rb.maxY)) pt under the button")
        XCTAssertGreaterThan(rg.maxY - rb.maxY, DS.Space.xl4 + 40, "RED CONTROL: the blank block under the button")
        FlexibleStageSheet.controlBlankBlock = false
        // RED CONTROL (fix round 2): no centring — the shortened glass above the page's centre
        FlexibleStageSheet.controlOffCentre = true
        let h3 = host(FlexibleStageSheet(onDelete: {}, onClose: {}).frame(width: Self.p13.width, height: Self.p13.height), size: Self.p13)
        pump(1.2)
        let og = try XCTUnwrap(h3.frames.all["stageSheetGlass"])
        FlexibleStageSheet.controlOffCentre = false
        lines.append("RED off centre: glass \(og.integral), its middle \(Int(Self.p13.height / 2 - og.midY)) pt above the page's")
        XCTAssertLessThan(og.midY, Self.p13.height / 2 - 40, "RED CONTROL: the glass above centre")
        log = lines
        flush("u21_d_sheet_lines.txt")
    }

    // MARK: the harness (the R7-E5 probe's)

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func pumpUntil(_ t: Double, _ c: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t)
        while !c() { if Date() > end { return false }; _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return true
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleViewMarksKey.self) { frames.marks = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = U2Win(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, frames: frames)
    }
    func mtkViews(_ v: NSView) -> [MTKView] {
        var out: [MTKView] = []
        if let m = v as? MTKView { out.append(m) }
        for s in v.subviews { out += mtkViews(s) }
        return out
    }
    func stageMTK(_ h: Host) -> MTKView? {
        mtkViews(h.view).filter { $0.delegate is MeshRenderer }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
    func cameraModel(_ h: Host) -> OrbitCameraModel? {
        guard let mtk = stageMTK(h) else { return nil }
        for g in mtk.gestureRecognizers {
            guard let t = g.target else { continue }
            for c in Mirror(reflecting: t).children where c.label == "cameraModel" {
                if let cm = c.value as? OrbitCameraModel { return cm }
            }
        }
        return nil
    }
    func writePNG(_ img: CGImage, _ name: String) throws {
        guard let dir = Self.dir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    func flush(_ file: String) {
        print("FLEX-U2 " + log.joined(separator: "\n  "))
        if let d = Self.dir { try? (log.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }

    /// The page as he sees it: its renderer offscreen (its camera, its viewport) under the hosted chrome.
    func shot(_ name: String, _ h: Host, settle: Double = 0.8) throws {
        pump(settle)
        guard Self.dir != nil else { return }
        let hv = h.view
        hv.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hv.bitmapImageRepForCachingDisplay(in: hv.bounds))
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let PW = cg.width, PH = cg.height
        let scale = CGFloat(PW) / h.size.width
        var chrome = [UInt8](repeating: 0, count: PW * PH * 4)
        let cctx0 = try XCTUnwrap(CGContext(data: &chrome, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cctx0.draw(cg, in: CGRect(x: 0, y: 0, width: PW, height: PH))
        let bg = DS.Color.background
        let gr = Int((bg.r * 255).rounded()), gg = Int((bg.g * 255).rounded()), gb = Int((bg.b * 255).rounded())
        var probe = (0, 0, 0, 0)
        var modelImg: CGImage?
        var placed = CGRect.zero
        if let mtk = stageMTK(h), let r = mtk.delegate as? MeshRenderer {
            var vf = mtk.convert(mtk.bounds, to: hv)
            if !hv.isFlipped { vf.origin.y = hv.bounds.height - vf.maxY }
            let cx = Int(vf.midX * scale), cy = Int(vf.midY * scale)
            let i = (cy * PW + cx) * 4
            probe = (Int(chrome[i]), Int(chrome[i + 1]), Int(chrome[i + 2]), Int(chrome[i + 3]))
            if probe.0 + probe.1 + probe.2 > 60 { probe = (0, 0, 0, 0) }
            let saved = r.camera
            var cam = saved
            let W = vf.width, H = vf.height
            let side: CGFloat
            if W > H { cam.fovY = 2 * atan(tan(saved.fovY / 2) * Float(W / H)); side = W } else { side = H }
            r.camera = cam
            let n = Int((side * scale).rounded())
            let px = r.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
            r.camera = saved
            if var m = px {
                for k in stride(from: 0, to: m.count, by: 4) { m.swapAt(k, k + 2); m[k + 3] = 255 }
                let mctx = try XCTUnwrap(CGContext(data: &m, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                modelImg = mctx.makeImage()
                placed = CGRect(x: (vf.midX - side / 2) * scale, y: (h.size.height - vf.midY - side / 2) * scale, width: side * scale, height: side * scale)
            }
        }
        for k in stride(from: 0, to: chrome.count, by: 4) {
            let a = chrome[k + 3]
            let isBG = abs(Int(chrome[k]) - gr) <= 3 && abs(Int(chrome[k + 1]) - gg) <= 3 && abs(Int(chrome[k + 2]) - gb) <= 3 && a == 255
            let isProbe = probe.3 > 0 && abs(Int(chrome[k]) - probe.0) <= 2 && abs(Int(chrome[k + 1]) - probe.1) <= 2 && abs(Int(chrome[k + 2]) - probe.2) <= 2 && Int(a) == probe.3
            if isBG || isProbe { chrome[k] = 0; chrome[k + 1] = 0; chrome[k + 2] = 0; chrome[k + 3] = 0 }
        }
        let cctx = try XCTUnwrap(CGContext(data: &chrome, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cimg = try XCTUnwrap(cctx.makeImage())
        let out = try XCTUnwrap(CGContext(data: nil, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        out.setFillColor(CGColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: PW, height: PH))
        if let mi = modelImg { out.draw(mi, in: placed) }
        out.draw(cimg, in: CGRect(x: 0, y: 0, width: PW, height: PH))
        try writePNG(try XCTUnwrap(out.makeImage()), name)
    }
}
#endif

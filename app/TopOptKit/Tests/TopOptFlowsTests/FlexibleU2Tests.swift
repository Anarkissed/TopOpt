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
    final class Frames { var all: [String: CGRect] = [:] }
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
        var line: String { "control \(control.integral) · keep \(keep.map { "\($0.integral)" } ?? "-") · red \(confirm.map { "\($0.integral)" } ?? "-") · on spot \(keepOnSpot) · ≥24 pt clear \(clear)" }
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
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
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

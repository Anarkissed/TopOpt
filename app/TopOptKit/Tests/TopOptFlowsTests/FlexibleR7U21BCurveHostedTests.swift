// FlexibleR7U21BCurveHostedTests — round 7 · U21 batch B, hosted (the U2 harness: an extension of FlexibleU2Tests, so filter
// "FlexibleU2Tests/testU21B"). His notes of 2026-10-21, "Img16 finally" (27.png): "Place them to the side like a legend. Please
// also expand the modal to fill 80% of the screen, going overtop most assets. This is especially required for the 3D view."
// On HIS l-bracket of 10-21 (round7/batch_u21_c/his_live_1021_lbracket), Face 6's window as in his 27.png. Pictures (13" portrait,
// 2D and 3D) only with FLEX_U2_DIR=<dir> (U21B_*.png). Each RED control is asserted red inside its test.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleU2Tests {
    static let p13l = CGSize(width: 1376, height: 1032)
    /// The smallest iPad's landscape screen (iPad mini, 1133 × 744 pt).
    static let miniL = CGSize(width: 1133, height: 744)
    static let lbrFace6 = 2000008

    /// His l-bracket on the Squish page, Group 1 open with Face 6 selected (his 27.png), hosted at `size`.
    func u21bHisLBracket(_ size: CGSize) async throws -> (FlexibleStageModel, Host) {
        let r = try FlexibleHisProject.restore(FlexibleR7U21CHandlesHostedTests.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his l-bracket of 10-21")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.regions.contains(Self.lbrFace6) }, "his Group 1 (Face 6)")
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: FlexibleSquishLoop(), onExit: {}), size: size)
        pump(3)
        m.rail = .group(g.id)
        m.tab = .face
        m.select(Self.lbrFace6)
        pump(1.5)
        return (m, h)
    }

    func u21bClick(_ h: Host, _ p: CGPoint) {
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
        pump(0.8)
    }

    func u21bWindowIsEightyPercent(_ h: Host, _ tag: String) throws -> CGRect {
        let modal = try XCTUnwrap(h.frames.all["curveModal"], "\(tag): the window")
        let want = CGRect(x: 0.1 * h.size.width, y: 0.1 * h.size.height, width: 0.8 * h.size.width, height: 0.8 * h.size.height)
        log.append("U21B \(tag): window \(modal.integral) (want \(want.integral)) = \(String(format: "%.1f%% × %.1f%%", 100 * modal.width / h.size.width, 100 * modal.height / h.size.height))")
        XCTAssertEqual(modal.width, want.width, accuracy: 2, "★ \(tag): 0.8 × the screen's width")
        XCTAssertEqual(modal.height, want.height, accuracy: 2, "★ \(tag): 0.8 × the screen's height")
        XCTAssertEqual(modal.midX, want.midX, accuracy: 2, "★ \(tag): centred")
        XCTAssertEqual(modal.midY, want.midY, accuracy: 2, "★ \(tag): centred")
        return modal
    }

    // MARK: 80 % at 13" portrait and landscape; the legend column beside the charts (his l-bracket Face 6, 27.png)

    func testU21BTheWindowIsEightyPercentWithTheLegendBesideTheCharts() async throws {
        let (m, h) = try await u21bHisLBracket(Self.p13)
        m.openFaceCurveModal(Self.lbrFace6, .flat2D)
        pump(1.5)
        let f = h.frames.all
        let modal = try u21bWindowIsEightyPercent(h, "13p 2D")
        let tx = try XCTUnwrap(f["curveTable-x"]), ty = try XCTUnwrap(f["curveTable-y"])
        let cx = try XCTUnwrap(f["curveChart-x"]), cy = try XCTUnwrap(f["curveChart-y"])
        let col = try XCTUnwrap(f["curveLegend"], "★ the legend column")
        log.append("U21B 13p 2D: X table \(tx.integral) chart \(cx.integral) · Y table \(ty.integral) chart \(cy.integral) · legend \(col.integral)")
        XCTAssertGreaterThanOrEqual(tx.height, 0.25 * Self.p13.height, "★ the X table ≥ 25 % of the screen's height")
        XCTAssertGreaterThanOrEqual(ty.height, 0.25 * Self.p13.height, "★ the Y table ≥ 25 % of the screen's height")
        XCTAssertLessThanOrEqual(tx.maxY, ty.minY + 1, "X above Y")
        XCTAssertGreaterThanOrEqual(col.minX, Swift.max(tx.maxX, ty.maxX) - 0.5, "★ the column to the side of the charts")
        XCTAssertTrue(modal.insetBy(dx: -1, dy: -1).contains(col), "the column in the window")
        // buttons: 44 pt, 8 pt apart, each Mirror beside its own chart, Copy between them
        let ids = ["mirror-along-lr", "mirror-along-rl", "copy-down", "copy-up", "mirror-across-lr", "mirror-across-rl"]
        let bs = try ids.map { try XCTUnwrap(f["curveAction-\($0)"], "★ [\($0)]") }
        for (i, b) in bs.enumerated() {
            XCTAssertGreaterThanOrEqual(b.height, 44 - 0.5, "★ \(ids[i]) ≥ 44 pt tall")
            XCTAssertTrue(col.insetBy(dx: -1, dy: -1).contains(b), "\(ids[i]) in the column")
        }
        let gaps = zip(bs, bs.dropFirst()).map { $1.minY - $0.maxY }
        log.append("U21B buttons: " + zip(ids, bs).map { "\($0) \(Int($1.minY))-\(Int($1.maxY))" }.joined(separator: " · ") + " · gaps \(gaps.map { Int($0) })")
        for g in gaps { XCTAssertGreaterThanOrEqual(g, 8 - 0.5, "★ buttons ≥ 8 pt apart") }
        XCTAssertTrue(bs[0].midY >= cx.minY && bs[1].midY <= cx.maxY, "★ the X curve's Mirror beside the X chart")
        XCTAssertTrue(bs[4].midY >= cy.minY && bs[5].midY <= cy.maxY, "★ the Y curve's Mirror beside the Y chart")
        XCTAssertTrue(bs[2].midY > cx.midY && bs[3].midY < cy.midY, "★ Copy between the two charts")
        try shot("U21B_01_13p_lbracket_face6_2d.png", h, settle: 1)
        // a click on [Left → Right] mirrors the draft's X curve (the button, end to end) and nothing reaches the face
        let x0 = try XCTUnwrap(m.curveDraft?.curves[.along])
        u21bClick(h, CGPoint(x: bs[0].midX, y: bs[0].midY))
        XCTAssertEqual(m.curveDraft?.curves[.along], FlexibleCurveMirror.mirrored(x0, .leftToRight), "★ the click mirrored X (draft)")
        XCTAssertEqual(m.settings.face(Self.lbrFace6)?.curveX, x0, "★ the face is untouched until OK")
        log.append("U21B click [Left → Right]: X \(x0.y) → \(m.curveDraft?.curves[.along]?.y ?? [])")
        try shot("U21B_02_13p_lbracket_face6_2d_after_left_to_right.png", h, settle: 0.6)
        // 3D: the table fills the window's rest, the column beside it, the gizmo on it
        m.setCurveModalMode(.table3D)
        pump(1.5)
        let f3 = h.frames.all
        _ = try u21bWindowIsEightyPercent(h, "13p 3D")
        let v3 = try XCTUnwrap(f3["curveView3D"]), gz = try XCTUnwrap(f3["curveGizmo"]), col3 = try XCTUnwrap(f3["curveLegend"])
        log.append("U21B 13p 3D: table \(v3.integral) = \(String(format: "%.1f%% × %.1f%%", 100 * v3.width / Self.p13.width, 100 * v3.height / Self.p13.height)) · gizmo \(gz.integral) · legend \(col3.integral)")
        XCTAssertGreaterThanOrEqual(v3.height, 0.55 * Self.p13.height, "★ the 3D table fills the window (was 35 %)")
        XCTAssertGreaterThanOrEqual(col3.minX, v3.maxX - 0.5, "the column beside the 3D table")
        XCTAssertTrue(v3.insetBy(dx: -1, dy: -1).contains(gz), "the gizmo on the table")
        try shot("U21B_03_13p_lbracket_face6_3d.png", h, settle: 1)
        // RED CONTROL: the window before U21
        FlexibleCurveWindowLayout.controlOldWindowSize = true
        m.setCurveModalMode(.flat2D); pump(1.2)
        let red = try XCTUnwrap(h.frames.all["curveModal"])
        FlexibleCurveWindowLayout.controlOldWindowSize = false
        log.append("RED old window: \(red.integral) = \(String(format: "%.1f%% × %.1f%%", 100 * red.width / Self.p13.width, 100 * red.height / Self.p13.height))")
        XCTAssertGreaterThan(abs(red.width - 0.8 * Self.p13.width), 2, "RED CONTROL: not 0.8 × the width")
        m.closeCurveModal(keep: false)
        pump(0.8)
        // 13" landscape
        let (m2, h2) = try await u21bHisLBracket(Self.p13l)
        m2.openFaceCurveModal(Self.lbrFace6, .flat2D)
        pump(1.5)
        _ = try u21bWindowIsEightyPercent(h2, "13l 2D")
        m2.setCurveModalMode(.table3D)
        pump(1.2)
        _ = try u21bWindowIsEightyPercent(h2, "13l 3D")
        m2.closeCurveModal(keep: false)
        flush("U21B_lines_window.txt")
    }

    // MARK: the smallest iPad in landscape: charts ≥ 140 pt, Cancel / OK inside

    func testU21BOnTheSmallestIPadLandscapeTheChartsAndButtonsFit() async throws {
        let (m, h) = try await u21bHisLBracket(Self.miniL)
        m.openFaceCurveModal(Self.lbrFace6, .flat2D)
        pump(1.5)
        let f = h.frames.all
        let modal = try u21bWindowIsEightyPercent(h, "mini landscape 2D")
        let cx = try XCTUnwrap(f["curveChart-x"]), cy = try XCTUnwrap(f["curveChart-y"])
        let ok = try XCTUnwrap(f["curveOK"]), cancel = try XCTUnwrap(f["curveCancel"])
        log.append("U21B mini landscape: X chart \(cx.integral) · Y chart \(cy.integral) · Cancel \(cancel.integral) · OK \(ok.integral)")
        XCTAssertGreaterThanOrEqual(cx.height, 140 - 0.5, "★ X chart ≥ 140 pt"); XCTAssertGreaterThanOrEqual(cy.height, 140 - 0.5, "★ Y chart ≥ 140 pt")
        XCTAssertTrue(modal.insetBy(dx: -1, dy: -1).contains(ok) && modal.insetBy(dx: -1, dy: -1).contains(cancel), "★ Cancel / OK inside the window")
        let ids = ["mirror-along-lr", "mirror-along-rl", "copy-down", "copy-up", "mirror-across-lr", "mirror-across-rl"]
        let bs = try ids.map { try XCTUnwrap(f["curveAction-\($0)"], "[\($0)]") }
        for g in zip(bs, bs.dropFirst()).map({ $1.minY - $0.maxY }) { XCTAssertGreaterThanOrEqual(g, 8 - 0.5, "buttons ≥ 8 pt apart") }
        XCTAssertLessThanOrEqual(bs.last!.maxY, ok.minY, "the column above Cancel / OK")
        m.setCurveModalMode(.table3D)
        pump(1.2)
        let ok3 = try XCTUnwrap(h.frames.all["curveOK"])
        XCTAssertTrue(modal.insetBy(dx: -1, dy: -1).contains(ok3), "3D: OK inside")
        m.closeCurveModal(keep: false)
        flush("U21B_lines_mini.txt")
    }

    // MARK: 3D at 13" portrait: turned 45°, the table stays inside its view and clear of the gizmo

    func testU21BThe3DTableFitsByAspectAndClearsTheGizmoWhenTurned() async throws {
        let (m, h) = try await u21bHisLBracket(Self.p13)
        m.openFaceCurveModal(Self.lbrFace6, .table3D)
        pump(1.5)
        let cam = try XCTUnwrap(FlexiblePressCurveModalView.shownCamera, "the window's camera")
        let cs = FlexiblePressCurveModal.faceCurves3D()
        var pts = FlexibleCurveTable3D.tableCorners(cs)
        for c in cs { for i in 0...10 { let t = Double(i) / 10; pts.append(c.baseline.world(t, 0)); pts.append(c.baseline.world(t, 1)) } }
        func check(_ yaw: Float, _ tag: String) throws -> (inside: Bool, clear: Bool, line: String) {
            let v3 = try XCTUnwrap(h.frames.all["curveView3D"]), gz = try XCTUnwrap(h.frames.all["curveGizmo"])
            var c = cam.camera
            c.setOrientation(azimuth: FlexiblePressCurveModal.homeCamera(corner: false).azimuth + yaw, elevation: c.elevation)
            cam.adopt(c)
            pump(0.5)
            let pr = FlexibleCurveTable3D.projection(cam.camera, v3.size)
            let gzLocal = gz.offsetBy(dx: -v3.minX, dy: -v3.minY)
            let sp = pts.compactMap { pr.project(SIMD3<Float>($0)) }
            let inside = sp.count == pts.count && sp.allSatisfy { $0.x >= 0 && $0.x <= v3.width && $0.y >= 0 && $0.y <= v3.height }
            let clear = sp.allSatisfy { !gzLocal.contains($0) }
            let xs = sp.map(\.x), ys = sp.map(\.y)
            let line = String(format: "%@ yaw %.0f°: view %.0f×%.0f · drawn x %.0f…%.0f y %.0f…%.0f · gizmo %@ · inside %@ clear %@", tag, yaw * 180 / .pi,
                              v3.width, v3.height, xs.min() ?? -1, xs.max() ?? -1, ys.min() ?? -1, ys.max() ?? -1, "\(gzLocal.integral)",
                              inside ? "yes" : "NO", clear ? "yes" : "NO")
            log.append(line)
            return (inside, clear, line)
        }
        let at45 = try check(.pi / 4, "13p 3D")
        XCTAssertTrue(at45.inside, "★ turned 45°, the table's corners and the curves inside the table's view")
        XCTAssertTrue(at45.clear, "★ turned 45°, clear of the gizmo")
        try shot("U21B_04_13p_lbracket_face6_3d_turned_45.png", h, settle: 0.8)
        for k in 0..<8 where k != 1 {
            let r = try check(Float(k) * .pi / 4, "13p 3D sweep")
            XCTAssertTrue(r.inside && r.clear, "every 45° turn: \(r.line)")
        }
        // RED CONTROL: the camera keeps its vertical lens in this taller-than-wide table
        FlexibleCurveWindowLayout.controlNoAspectFit = true
        let red = try check(.pi / 4, "RED no aspect fit")
        FlexibleCurveWindowLayout.controlNoAspectFit = false
        XCTAssertFalse(red.inside, "RED CONTROL: without the fit the square table runs out of its view")
        m.closeCurveModal(keep: false)
        flush("U21B_lines_3d.txt")
    }
}
#endif

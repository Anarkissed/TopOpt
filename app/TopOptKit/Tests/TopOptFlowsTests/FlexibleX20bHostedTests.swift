// FlexibleX20bHostedTests — round 7, step X20b, hosted at 13" portrait on HIS pad of 10-20 (the U2 harness: an extension of
// FlexibleU2Tests, so filter "FlexibleU2Tests/testX20b"). His answers of 2026-10-20 ~19:10 (binding): "FACE presses use the SAME
// 2D/3D curve window" and "On-part curves: REMOVE them from the part, but show the indent when selected like the stamp". Pictures
// only with FLEX_U2_DIR=<dir> (X20b_*.png). Each RED control is asserted red inside the test.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import simd
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleU2Tests {
    /// For the pictures only: he turns the camera himself (the page never does, U1) — `p` brought right of the panel, at (x, y) pt.
    func x20bFrame(_ h: Host, _ p: SIMD3<Double>, at want: CGPoint = CGPoint(x: 770, y: 560)) {
        guard let cm = cameraModel(h), let mtk = stageMTK(h) else { return }
        for _ in 0..<3 {
            let pr = CameraProjection(camera: cm.camera, viewportSize: mtk.bounds.size)
            let q = SIMD3<Float>(p)
            guard let s0 = pr.project(q) else { return }
            var gx = SIMD3<Float>.zero, gy = SIMD3<Float>.zero
            for i in 0..<3 {
                var e = SIMD3<Float>.zero; e[i] = 1
                guard let s1 = pr.project(q + e) else { return }
                gx[i] = Float(s1.x - s0.x); gy[i] = Float(s1.y - s0.y)
            }
            // moving the target by v moves every point on screen by −(gx·v, gy·v): solve for the shift want − s0 (least norm)
            let dx = Float(want.x - s0.x), dy = Float(want.y - s0.y)
            let a = simd_dot(gx, gx), b = simd_dot(gx, gy), c = simd_dot(gy, gy), det = a * c - b * b
            guard abs(det) > 1e-9 else { return }
            let l1 = (c * dx - b * dy) / det, l2 = (a * dy - b * dx) / det
            var cam = cm.camera
            cam.target -= gx * l1 + gy * l2
            cm.adopt(cam)
        }
        pump(0.6)
    }

    func testX20bAFacesShapeRowOpensTheWindow() async throws {
        let (r, m, edges, presses) = try await hisPad()
        let faceGroup = try XCTUnwrap(m.squeezeGroups.first { $0.kind != .edges && !$0.regions.isEmpty }, "his face group")
        let loaded = faceGroup.regions.filter { m.settings.face($0)?.isLoaded == true }
        XCTAssertFalse(loaded.isEmpty, "a pressed face")
        for r0 in loaded {
            m.setShape(r0, "curves")
            // his path: the window's [OK] (one edit, the drawn map at once) — before the page is up (in this harness the
            // hosted page's designs never settle and the scene's queue holds the drawn map back)
            m.openFaceCurveModal(r0, .flat2D)
            m.setDraftCurve(.along, FlexCurve(x: [0, 0.5, 1], y: [0.2, 1, 0.2]))
            m.closeCurveModal(keep: true)
        }
        m.save()
        try await FlexibleHisProject.waitFor(60, "the drawn maps") { loaded.allSatisfy { r0 in (m.key(r0).flatMap { m.liveS[$0] }?.min() ?? 1) < 0.5 } }
        let loop = FlexibleSquishLoop()
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)
        // the pressed face he sees best (its indent's middle furthest right of the panel, on screen)
        func seen(_ r0: Int) -> CGFloat {
            guard let cm = cameraModel(h), let mtk = stageMTK(h) else { return -1 }
            let pr = CameraProjection(camera: cm.camera, viewportSize: mtk.bounds.size)
            let pts = FlexibleIndent.face(model: m, region: r0).compactMap { pr.project(SIMD3<Float>($0.a)) }
            guard !pts.isEmpty else { return -1 }
            return pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
        }
        let face = loaded.max { seen($0) < seen($1) }!
        log.append("X20b faces seen (indent middle x): " + loaded.map { "\(m.displayName($0)) \(Int(seen($0)))" }.joined(separator: " · "))
        pump(1)
        m.rail = .group(faceGroup.id)
        m.tab = .face
        m.select(face)
        pumpUntil(30) { m.key(face).map { m.liveS[$0] != nil } ?? false }
        pump(2)
        let f = h.frames.all
        let b2 = try XCTUnwrap(f["faceCurves-2d"], "★ the face's [2D]"), b3 = try XCTUnwrap(f["faceCurves-3d"], "★ the face's [3D]")
        XCTAssertEqual(b2.midY, b3.midY, accuracy: 1, "★ on one line (the Shape row)")
        if let panel = f["panel"] { XCTAssertLessThanOrEqual(b3.maxX, panel.maxX + 1, "inside the panel") }
        log.append("X20b face \(m.displayName(face)): [2D] \(b2.integral) [3D] \(b3.integral) · indent \(FlexibleIndent.face(model: m, region: face).count) segments · editors on the part \(FlexibleStageOverlays.curveEditorsOnPart(try XCTUnwrap(m.settings.face(face))))")
        XCTAssertFalse(FlexibleIndent.face(model: m, region: face).isEmpty, "★ its indent on the part")
        XCTAssertEqual(FlexibleStageOverlays.workingFace(model: m)?.region, face, "★ the overlays draw on it (the working face)")
        if let k = m.key(face), let st = m.stacks[k], let g = m.geometry[k] {
            x20bFrame(h, g.corner + st.xAxis * (st.uExtentMM / 2) + st.yAxis * (st.vExtentMM / 2))
        }
        if let k = m.key(face), let st = m.stacks[k], let g = m.geometry[k], let sv = m.liveS[k] {
            let ls = FlexibleIndent.face(model: m, region: face)
            func uv(_ l: Double) -> String {
                let ps = ls.filter { $0.level == l }.map { $0.a - g.corner }
                let us = ps.map { simd_dot($0, st.xAxis) }, vs = ps.map { simd_dot($0, st.yAxis) }
                return String(format: "u %.1f…%.1f v %.1f…%.1f", us.min() ?? -1, us.max() ?? -1, vs.min() ?? -1, vs.max() ?? -1)
            }
            log.append("X20b face S \(sv.min() ?? -1)…\(sv.max() ?? -1) · extents \(st.uExtentMM)×\(st.vExtentMM) · curveX \(m.settings.face(face)?.curveX.y ?? []) curveY \(m.settings.face(face)?.curveY.y ?? []) mode \(m.settings.face(face)?.mode ?? "-") ce \(m.settings.face(face)?.curveCentreEdge.y ?? []) · 10% \(uv(0.1)) · 50% \(uv(0.5)) · 90% \(uv(0.9))")
        }
        try shot("X20b_01_13p_face_indent_and_shape_row.png", h, settle: 1)
        // RED CONTROL: no window buttons on a face (before X20b)
        FlexibleCurveModalButton.controlNoFaceWindow = true
        m.select(face == faceGroup.regions.last ? faceGroup.regions.first! : faceGroup.regions.last!); pump(1); m.select(face); pump(1.5)
        let red = h.frames.all["faceCurves-2d"]
        FlexibleCurveModalButton.controlNoFaceWindow = false
        XCTAssertNil(red, "RED CONTROL: no [2D] on the face")
        m.select(face == faceGroup.regions.last ? faceGroup.regions.first! : faceGroup.regions.last!); pump(1); m.select(face); pump(1.5)
        // the window: 2D = X above Y
        m.openFaceCurveModal(face, .flat2D)
        m.setDraftCurve(.across, FlexCurve(x: [0, 0.6, 1], y: [0.4, 1, 0.4]))
        pump(1.5)
        let w = h.frames.all
        let modal = try XCTUnwrap(w["curveModal"], "★ the window")
        let tx = try XCTUnwrap(w["curveTable-x"], "★ the X table"), ty = try XCTUnwrap(w["curveTable-y"], "★ the Y table")
        XCTAssertLessThanOrEqual(tx.maxY, ty.minY + 1, "★ X above Y (two tables)")
        XCTAssertTrue(modal.insetBy(dx: -1, dy: -1).contains(tx) && modal.insetBy(dx: -1, dy: -1).contains(ty), "both in the window")
        log.append("X20b face window 2D: \(modal.integral) · X \(tx.integral) · Y \(ty.integral)")
        try shot("X20b_02_13p_face_window_2d.png", h, settle: 1)
        m.setCurveModalMode(.table3D)
        pump(1.5)
        XCTAssertNotNil(h.frames.all["curveTable3D"], "★ 3D: one table")
        XCTAssertNotNil(h.frames.all["curveGizmo"], "★ with the gizmo")
        m.closeCurveModal(keep: false)
        pump(1)
        XCTAssertNil(h.frames.all["curveModal"], "Cancel closes")
        // an edge press: its indent, no handles on the part
        let a = presses[0]
        // bent in the window (so the picture shows a shaped indent, not only the footprint's outline)
        m.openCurveModal(a.id, .flat2D)
        m.setDraftCurve(.across, FlexCurve(x: [0, 0.5, 1], y: [0.1, 1, 0.1]))
        m.setDraftCurve(.along, FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]))
        m.closeCurveModal(keep: true)
        m.rail = .group(edges.id)
        m.selectedPress = a.id
        pump(2.5)
        let edgeLines = FlexibleIndent.press(model: m, id: a.id)
        XCTAssertFalse(edgeLines.isEmpty, "★ the edge's indent")
        XCTAssertTrue(FlexiblePressCurveLayer.editorsOnPart(model: m, press: a.id, projection: nil).isEmpty, "★ no handles on the part")
        log.append("X20b \(a.strip?.label ?? "-"): indent \(edgeLines.count) segments")
        if let c = m.flatCut(a.id), let p = m.press(a.id) {
            let smp = FlexiblePressPush.samples(p, c)
            var mid = SIMD3<Double>.zero
            for i in 0..<smp.count { mid += SIMD3(smp.xyz[3 * i], smp.xyz[3 * i + 1], smp.xyz[3 * i + 2]) }
            if smp.count > 0, let cm = cameraModel(h) {
                // the three-quarter view that looks most along the press's arrow (the edge in front)
                let d = SIMD3<Float>(c.direction)
                let ids = ["Front-Top-Right", "Front-Top-Left", "Back-Top-Right", "Back-Top-Left"]
                var best = ids[0], score = -Float.infinity
                for id in ids {
                    cm.snap(toID: id, animated: false)
                    let v = simd_dot(simd_normalize(cm.camera.direction), d)
                    if v > score { score = v; best = id }
                }
                cm.snap(toID: best, animated: false)
                pump(0.4)
                x20bFrame(h, mid / Double(smp.count), at: CGPoint(x: 770, y: 420))
                log.append("X20b picture view: \(best)")
            }
        }
        try shot("X20b_03_13p_edge_indent.png", h, settle: 1)
        flush("X20b_lines_hosted.txt")
    }
}
#endif

// FlexibleR7E1ReviewEvidenceProbe — round 7, the review of R7-E1: what he will see, as the PAGE draws it — the whole Squish page
// hosted offscreen (its own chrome and overlays, its own camera projection) over the page's OWN MeshRenderer rendered offscreen
// with the page's camera (the harness the UX verifier built; never device screenshots). Opt-in: FLEX_E1R_DIR=<dir> (else skipped,
// counted). Pictures for round7/batch_e1r/look/.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class E1RWin: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7E1ReviewEvidenceProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_E1R_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376), l11 = CGSize(width: 1194, height: 834)
    static var hisShot: String { FlexibleHisProject.repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_e1r/look/img_edges_1018.png").path }
    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []
    var toastNow: String?

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
        let w = E1RWin(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func mouse(_ h: Host, _ t: NSEvent.EventType, _ p: CGPoint) {
        let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.window.sendEvent(e)
    }
    func click(_ h: Host, _ p: CGPoint) {
        mouse(h, .leftMouseDown, p); pump(0.06); mouse(h, .leftMouseUp, p); pump(0.8)
    }

    // MARK: the page's Metal view, its renderer and its camera

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
    func setCam(_ h: Host, az: Float, el: Float) {
        guard let cm = cameraModel(h) else { log.append("!! no camera model"); return }
        cm.snap(toID: "Front", animated: false)   // stops a turn still easing in (the offscreen host's display link is slow)
        var c = cm.camera
        c.setOrientation(azimuth: az, elevation: el)
        cm.adopt(c)
        pump(1.0)
    }
    func camLine(_ h: Host) -> String {
        guard let cm = cameraModel(h) else { return "cam ?" }
        return String(format: "cam az %.3f el %.3f dist %.1f", cm.camera.azimuth, cm.camera.elevation, cm.camera.distance)
    }

    func writePNG(_ img: CGImage, _ name: String) throws {
        guard let dir = Self.dir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// The page as he sees it: the page's renderer offscreen (its camera, the page's viewport) under the hosted chrome.
    @discardableResult
    func shot(_ name: String, _ h: Host, settle: Double = 0.8) throws -> CGImage? {
        pump(settle)
        guard Self.dir != nil else { return nil }
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
        // the colour the Metal view's place reads in the chrome (sampled at its centre)
        var probe = (0, 0, 0, 0)
        var modelImg: CGImage?
        var placed = CGRect.zero
        if let mtk = stageMTK(h), let r = mtk.delegate as? MeshRenderer {
            var vf = mtk.convert(mtk.bounds, to: hv)
            if !hv.isFlipped { vf.origin.y = hv.bounds.height - vf.maxY }
            let cx = Int(vf.midX * scale), cy = Int(vf.midY * scale)
            let i = (cy * PW + cx) * 4
            probe = (Int(chrome[i]), Int(chrome[i + 1]), Int(chrome[i + 2]), Int(chrome[i + 3]))
            if probe.0 + probe.1 + probe.2 > 60 { probe = (0, 0, 0, 0) }   // only a near-black ground is the Metal view's place
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
            } else { log.append("!! \(name): renderOffscreen nil") }
        } else { log.append("!! \(name): no stage Metal view") }
        // the chrome's own ground (and the Metal view's place) made clear
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
        let img = try XCTUnwrap(out.makeImage())
        try writePNG(img, name)
        let mk = h.frames.marks
        let keys = mk.keys.filter { $0.hasPrefix("flat") }.sorted().map { "\($0) \(mk[$0]!.integral)" }
        log.append("\(name): \(camLine(h)) · probe \(probe) · marks \(keys) · toast \(toastNow ?? "-")")
        return img
    }

    func beside(_ mine: CGImage, _ name: String) throws {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: Self.hisShot) as CFURL, nil),
              let his = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let h = mine.height, hw = Int(Double(his.width) * Double(h) / Double(his.height))
        let W = hw + mine.width + 24
        let ctx = try XCTUnwrap(CGContext(data: nil, width: W, height: h, bitsPerComponent: 8, bytesPerRow: W * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: h))
        ctx.draw(his, in: CGRect(x: 0, y: 0, width: hw, height: h))
        ctx.draw(mine, in: CGRect(x: hw + 24, y: 0, width: mine.width, height: h))
        try writePNG(try XCTUnwrap(ctx.makeImage()), name)
    }

    func flush(_ file: String) {
        print("FLEX-E1UX " + log.joined(separator: "\n  "))
        if let d = Self.dir { try? (log.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }

    // MARK: fixtures

    func open(_ p: ProjectModel) -> FlexibleStageModel {
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "scene")
        return m
    }
    func pick(_ m: FlexibleStageModel) -> FlexibleEdgePick? {
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "listed")
        return m.edgePick
    }
    func done(_ m: FlexibleStageModel, kg: Double = 5) -> String? {
        m.setEdgePickWeight(kg)
        var fin = false
        var why: String?
        Task { @MainActor in why = await m.finishEdgePick(); fin = true }
        XCTAssertTrue(pumpUntil(240) { fin && m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "after Done")
        return why
    }
    func run(_ body: @escaping () async -> String?) -> String? {
        var fin = false
        var why: String?
        Task { @MainActor in why = await body(); fin = true }
        pumpUntil(240) { fin }
        pump(0.5)
        return why
    }

    // MARK: - the pictures

    func edge(_ m: FlexibleStageModel, faces: Set<Int>) throws -> FlexiblePress {
        let pk = try XCTUnwrap(pick(m))
        let c = try XCTUnwrap(FlexibleM2Fixtures.edge(m, pk, faces: faces), "edge \(faces.sorted())")
        m.toggleEdgePick(c.number)
        let why = done(m)
        log.append("[Done] \(FlexibleRowCopy.candidateLabel(c)) \(faces.sorted()): \(why ?? "stored") · toast \(m.toast ?? "-")")
        toastNow = m.toast
        let press = try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(c) })
        pumpUntil(120) { m.pressStack(press.id) != nil }
        return press
    }

    /// His pad: [Done] on Face 3 + Face 2 — the camera stays on the press when the pop-up fires; then his working views at 13" and
    /// 11": the knob and its boxes on the screen, the chip clear of the panel, the lines out of the chip.
    func testA_HisPadEdge() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E1R_DIR") }
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = open(r.project)
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        let press = try edge(m, faces: [3, 2])
        pumpUntil(60) { h.frames.all["popup"] != nil }
        pump(2)
        log.append("pop-up shown: \(h.frames.all["popup"] != nil)")
        let a = try shot("A01_13p_after_done_popup_camera_kept.png", h)
        if let a { try beside(a, "A01b_his_img_edges_1018_beside_after_done.png") }
        setCam(h, az: .pi / 4, el: .pi / 6)
        try shot("A02_13p_home_3mm_knob_on_screen.png", h)
        m.previewFlatCut(press.id, depthMM: 10.6, direction: nil)
        try shot("A03_13p_home_10.6mm.png", h)
        if let f = FlexibleFlatPrismUI.frame(m, press.id) {
            m.previewFlatCut(press.id, depthMM: 10.6, direction: FlexibleFlatPrismAngles.compose(f, theta: 0, phi: 10))
            try shot("A04_13p_home_twist+10.png", h)
        }
        m.flatPreview = nil
        setCam(h, az: .pi / 4, el: Float(55 * Double.pi / 180))
        try shot("A05_13p_55deg_3mm.png", h)
        flush("A_lines.txt")
        let h11 = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.l11)
        pump(2.5)
        setCam(h11, az: .pi / 4, el: .pi / 6)
        try shot("A06_11l_home_3mm.png", h11)
        setCam(h11, az: .pi / 4, el: Float(55 * Double.pi / 180))
        try shot("A07_11l_55deg_3mm.png", h11)
        flush("A_lines.txt")
    }

    /// His live form (Face 3's face-prism 25 mm, Fast): a release at 20 mm lands on core's stop, the card says it.
    func testB_LatticeStopLands() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E1R_DIR") }
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        let m = open(r.project)
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        let press = try edge(m, faces: [3, 2])
        setCam(h, az: .pi / 4, el: .pi / 6)
        let why = run { await m.setFlatCut(press.id, depthMM: 20, direction: press.direction, snap: press.snap) }
        pumpUntil(120) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        pump(2)
        toastNow = m.toast
        log.append("release at 20 → \(why ?? "stored") · depth \(m.press(press.id)?.settings.deepestMM ?? -1) · card \(m.lastFlatStop?.line ?? "-") · toast \(m.toast ?? "-") · drag cap \(m.flatDragCap(press.id) ?? -1)")
        try shot("B01_13p_released_at_20_landed.png", h)
        flush("B_lines.txt")
    }

    /// His live project (Balanced): the Face 3 + Face 2 edge 10 mm deep, a typed twist of 5° lands where the lattice allows.
    func testC_AngleStopLands() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E1R_DIR") }
        let r = try FlexibleHisProject.restore(FlexibleTopLayerFixtures.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = open(r.project)
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        let press = try edge(m, faces: [3, 2])
        pump(4)   // (the [Done] turn's animation ends before the view is set)
        _ = run { await m.setFlatCut(press.id, depthMM: 10, direction: press.direction, snap: press.snap) }
        pumpUntil(120) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        setCam(h, az: .pi / 4, el: .pi / 6)
        pump(2)
        log.append("before the twist: \(camLine(h))")
        let why = run { await m.setFlatAngle(press.id, degrees: 5, tilt: false) }
        log.append("right after the twist: \(camLine(h))")
        pumpUntil(120) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        pump(2)
        toastNow = m.toast
        let f = FlexibleFlatPrismUI.frame(m, press.id)
        let a = f.map { FlexibleFlatPrismAngles.decompose($0, m.press(press.id)?.direction ?? .zero) }
        log.append("typed twist 5° at 10 mm → \(why ?? "stored") · now twist \(a?.phi ?? -1) · card \(m.lastFlatStop?.line ?? "-")")
        try shot("C01_13p_twist_landed.png", h)
        flush("C_lines.txt")
    }

    /// His pad: the corner (Faces 1 + 2 + 3) at Fast and at Balanced — no sawtooth along the Top's edges (and the RED CONTROL's
    /// picture beside); the Top + Face 2 edge stored at Balanced.
    func testD_CornerAndBalanced() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E1R_DIR") }
        for q in [RunQuality.fast, .balanced] {
            let r = try FlexiblePressFixtures.a1Project(3, self)
            r.project.quality = q
            let m = open(r.project)
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
            pump(3)
            let pk = try XCTUnwrap(pick(m))
            let c = try XCTUnwrap(FlexibleFlatPrismFixtures.corner(m, pk, faces: [1, 2, 3]), "the corner")
            m.toggleEdgePick(c.number)
            log.append("[Done] corner \(q.rawValue): \(done(m) ?? "stored") · toast \(m.toast ?? "-")")
            toastNow = m.toast
            pump(2)
            setCam(h, az: .pi / 4, el: .pi / 6)
            m.rail = .model
            pump(1.5)
            try shot("D01_13p_corner_\(q.rawValue)_model_tab_edges.png", h)
            // the RED CONTROL's picture: a fresh page builds its overlay with the quads as they come
            FlexibleOverlayMesh.controlNoEdgeFill = true
            let hr = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
            pump(3)
            setCam(hr, az: .pi / 4, el: .pi / 6)
            try shot("D02_13p_corner_\(q.rawValue)_RED_CONTROL_sawtooth.png", hr)
            FlexibleOverlayMesh.controlNoEdgeFill = false
            flush("D_lines.txt")
        }
        // the Top + Face 2 edge at Balanced
        let r = try FlexiblePressFixtures.a1Project(3, self)
        r.project.quality = .balanced
        let m = open(r.project)
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        let press = try edge(m, faces: [1, 2])
        setCam(h, az: .pi / 4, el: .pi / 6)
        log.append("Top + Face 2 at Balanced: depth \(press.settings.deepestMM) · cap \(m.flatLatticeCap(press.id) ?? -1)")
        try shot("D03_13p_top_face2_edge_balanced_stored.png", h)
        flush("D_lines.txt")
    }

    /// His pad: two flat prisms on Face 3 — the second held where Face 3 keeps the rest.
    func testE_TwoPressesOnOneFace() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E1R_DIR") }
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = open(r.project)
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        let pk = try XCTUnwrap(pick(m))
        let e1 = try XCTUnwrap(FlexibleM2Fixtures.edge(m, pk, faces: [3, 2])), e2 = try XCTUnwrap(FlexibleM2Fixtures.edge(m, pk, faces: [3, 4]))
        m.toggleEdgePick(e1.number); m.toggleEdgePick(e2.number)
        log.append("[Done] both: \(done(m) ?? "stored")")
        let p1 = try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(e1) })
        let p2 = try XCTUnwrap(m.presses.last { $0.strip?.label == FlexibleRowCopy.candidateLabel(e2) })
        _ = run { await m.setFlatCut(p1.id, depthMM: 40, direction: p1.direction, snap: p1.snap) }
        pumpUntil(120) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        let q2 = try XCTUnwrap(m.press(p2.id))
        let w = run { await m.setFlatCut(p2.id, depthMM: 40, direction: q2.direction, snap: q2.snap) }
        pumpUntil(120) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        toastNow = m.toast
        log.append("second typed 40 → \(w ?? "stored") at \(m.press(p2.id)?.settings.deepestMM ?? -1) · toast \(m.toast ?? "-")")
        m.selectedPress = p2.id
        pump(4)   // (selecting the press turns the camera to it — D-AP-13; its animation ends first)
        setCam(h, az: .pi / 4, el: Float(1.2))
        pump(2)
        try shot("E01_13p_two_presses_face3_keeps_rest.png", h)
        flush("E_lines.txt")
    }
}
#endif

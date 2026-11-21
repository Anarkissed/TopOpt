// FlexibleR7E4EvidenceProbe — round 7, batch R7-E3: what he will see, as the PAGES draw it (the Squish page hosted offscreen over its
// own MeshRenderer — the E1b probe's harness; the main page's legend card hosted), on HIS live pad as he saved it (Group 3 = Edge 16 +
// Edge 18). Opt-in: FLEX_E4_DIR=<dir> (else skipped). Pictures for round7/batch_e3/look/ (13" portrait).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class E4Win: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7E4EvidenceProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_E4_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376), l11 = CGSize(width: 1194, height: 834)
    static var hisShot: String { FlexibleHisProject.repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_e1r/look/img_edges_1018.png").path }
    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []


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
        let w = E4Win(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    // MARK: the page's Metal view, its renderer and its camera (the R7-E1 review's harness)

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
        cm.snap(toID: "Front", animated: false)
        var c = cm.camera
        c.setOrientation(azimuth: az, elevation: el)
        cm.adopt(c)
        pump(1.0)
    }

    func writePNG(_ img: CGImage, _ name: String) throws {
        guard let dir = Self.dir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// A hosted view alone (no Metal), as it draws.
    @discardableResult
    func viewShot(_ name: String, _ h: Host) throws -> CGImage? {
        pump(0.8)
        guard Self.dir != nil else { return nil }
        let hv = h.view
        hv.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hv.bitmapImageRepForCachingDisplay(in: hv.bounds))
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        try writePNG(cg, name)
        return cg
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
            } else { log.append("!! \(name): renderOffscreen nil") }
        } else { log.append("!! \(name): no stage Metal view") }
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
        log.append("\(name): marks \(mk.keys.filter { $0.hasPrefix("flat") }.sorted()) · solid \(FlexibleFlatPrismUI.lastArrowSolid) · toast \(h.frames.all.keys.first { $0.hasPrefix("toastLine:") } ?? "-")")
        return img
    }

    func beside(_ mine: CGImage, _ name: String) throws {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: Self.hisShot) as CFURL, nil),
              let his = CGImageSourceCreateImageAtIndex(src, 0, nil) else { log.append("!! his screenshot not found"); return }
        let h = mine.height, hw = Int(Double(his.width) * Double(h) / Double(his.height))
        let W = hw + mine.width + 24
        let ctx = try XCTUnwrap(CGContext(data: nil, width: W, height: h, bitsPerComponent: 8, bytesPerRow: W * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: h))
        ctx.draw(his, in: CGRect(x: 0, y: 0, width: hw, height: h))
        ctx.draw(mine, in: CGRect(x: hw + 24, y: 0, width: mine.width, height: h))
        try writePNG(try XCTUnwrap(ctx.makeImage()), name)
    }

    /// Two pictures side by side (at rest | at the full squish).
    func pair(_ l: CGImage, _ r: CGImage, _ name: String) throws {
        let W = l.width + r.width + 24, H = max(l.height, r.height)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.draw(l, in: CGRect(x: 0, y: 0, width: l.width, height: l.height))
        ctx.draw(r, in: CGRect(x: l.width + 24, y: 0, width: r.width, height: r.height))
        try writePNG(try XCTUnwrap(ctx.makeImage()), name)
    }

    func flush(_ file: String) {
        print("FLEX-E4UX " + log.joined(separator: "\n  "))
        if let d = Self.dir { try? (log.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }

    // MARK: - the pictures (front-end only: presses NOT sent)

    /// 1 [Top]: Edge 16's across curve with its first side lifted (softer) beside the second straight on the flat face; 2 the same from
    /// [45°]; 3 Stamp: the default stamp slid along Edge 16 ([45°]); 4 picture 2 beside his img_edges_1018.
    func testE4_HisLivePad() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E4_DIR") }
        FlexibleBackend.sendsPresses = false   // ★ C1: these pictures are of the interim sim (the switch off; on by default now)
        defer { FlexibleBackend.sendsPresses = true }
        let r = try FlexibleHisProject.restore(FlexibleTopLayerFixtures.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }, "scene")
        pumpUntil(60) { !m.readiness.designing }
        if !m.squeezeGroups.contains(where: { $0.kind == .edges }) {
            m.rail = .newGroup
            m.startEdgePick()
            XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "listed")
            let pk = try XCTUnwrap(m.edgePick)
            for f in [Set([3, 2]), Set([3, 4])] {
                m.toggleEdgePick(try XCTUnwrap(FlexibleM2Fixtures.edge(m, pk, faces: f), "edge \(f.sorted())").number)
            }
            m.setEdgePickWeight(5)
            var fin = false
            Task { @MainActor in _ = await m.finishEdgePick(); fin = true }
            XCTAssertTrue(pumpUntil(240) { fin && m.sceneState == .ready && m.openedKey == m.currentSceneKey }, "after Done")
            pump(2)
        }
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges }, "his edges group")
        let e16 = try XCTUnwrap(g.presses.first { m.press($0)?.strip?.label == "Edge 16" } ?? g.presses.first, "Edge 16")
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: FlexibleSquishLoop(), onExit: {}), size: Self.p13)
        pump(3)
        m.rail = .group(g.id)
        m.selectedPress = e16
        pump(2)
        // his first side bent softer (the across curve's first half lifted toward the part), the second side straight
        m.setPressCurve(e16, .across, FlexCurve(x: [0, 0.25, 0.5, 1], y: [1, 0.35, 1, 1]))
        m.showPressCurve(e16, .top)
        pump(3)
        let p = try XCTUnwrap(m.press(e16))
        log.append("Edge 16: \(p.strip?.label ?? "-") depth \(FlexibleFlatPrism.depth(of: p) ?? -1) mm · legacy \(FlexibleFlatPrism.isLegacy(p)) · across \(FlexiblePressCurveBaselines.multipliers(p, .across).y) · drawn \(FlexiblePressCurveLayer.drawn(model: m, press: e16, projection: nil).map(\.id)) · rows \(h.frames.all.keys.filter { $0.hasPrefix("pressShape") }.sorted()) · sent \(m.sentPresses.count)")
        try shot("E4_01_13p_edge16_two_sided_curve_top.png", h, settle: 2)
        m.showPressCurve(e16, .deg45)
        pump(3)
        let deg45 = try shot("E4_02_13p_edge16_two_sided_curve_45.png", h, settle: 2)
        if let deg45 { try beside(deg45, "E4_04_his_img_edges_1018_beside.png") }
        m.setPressShape(e16, "stamp")
        pump(1)
        if let st = m.press(e16)?.strip, let sp = m.press(e16)?.settings.designStamp, let rg = FlexiblePressStamp.range(st, sp) {
            m.updatePressStamp(e16, save: false) { $0.centreU = rg.lowerBound + (rg.upperBound - rg.lowerBound) * 0.8 }
            log.append("stamp: \(m.stampName(sp)) \(sp.widthMM) × \(sp.lengthMM) turn \(sp.rotationDeg) · slid to \(m.press(e16)?.settings.designStamp?.centreU ?? -1) of \(rg)")
        } else { log.append("!! no stamp seeded") }
        try shot("E4_03_13p_edge16_stamp_slid_along_edge_45.png", h, settle: 2)
        flush("E4_lines.txt")
    }
}
#endif

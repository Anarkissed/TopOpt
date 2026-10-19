// FlexibleR7E1bEvidenceProbe — round 7, batch R7-E1b: what he will see after his notes of 2026-10-19, as the PAGE draws it (the whole
// Squish page hosted offscreen over the page's own MeshRenderer — the E2 probe's harness), on HIS live pad as he saved it. Opt-in:
// FLEX_E1B_DIR=<dir> (else skipped). Pictures for round7/batch_e1b/look/ (13" portrait).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class E1bWin: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7E1bEvidenceProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_E1B_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376), l11 = CGSize(width: 1194, height: 834)
    static var hisShot: String { FlexibleHisProject.repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_e1b/look/img_1019_5.png").path }
    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    override func tearDown() {
        FlexiblePressSupport.apiVersion = { FlexibleScene.pressApiVersion }
        FlexibleStageModel.controlStripPresses = false
        super.tearDown()
    }

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
        let w = E1bWin(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    func flush(_ file: String) {
        print("FLEX-E1BUX " + log.joined(separator: "\n  "))
        if let d = Self.dir { try? (log.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }

    // MARK: fixtures

    /// His pad on the main stage's shared model (the Top's 20 mm face-prism; `rest`: faces resting first), the scene settled.
    func open(rest: [Int]) throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepCombinedField = true
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "scene")
        for f in rest { m.rest(f) }
        pumpUntil(60) { m.loadedKeys.allSatisfy { m.stacks[$0] != nil } && !m.readiness.designing }
        return (r, stage, m)
    }
    /// `edges` picked at 5 kg ([Done]), each in the job.
    func pick(_ m: FlexibleStageModel, _ edges: [Set<Int>]) throws -> [FlexiblePress] {
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "listed")
        let pk = try XCTUnwrap(m.edgePick)
        var labels: [String] = []
        for f in edges {
            let c = try XCTUnwrap(FlexibleM2Fixtures.edge(m, pk, faces: f), "edge \(f.sorted())")
            m.toggleEdgePick(c.number)
            labels.append(FlexibleRowCopy.candidateLabel(c))
        }
        m.setEdgePickWeight(5)
        var fin = false
        var why: String?
        Task { @MainActor in why = await m.finishEdgePick(); fin = true }
        XCTAssertTrue(pumpUntil(240) { fin && m.sceneState == .ready && m.openedKey == m.currentSceneKey }, "after Done")
        log.append("[Done] \(labels): \(why ?? "stored")")
        let ps = labels.compactMap { l in m.presses.last { $0.strip?.label == l } }
        pumpUntil(240) { ps.allSatisfy { m.pressSupport[$0.id]?.inJob == true } }
        log.append("sent: \(ps.map { "\($0.strip?.label ?? "") \(m.pressSupport[$0.id].map { $0.inJob ? "in the job" : ($0.line ?? "-") } ?? "-")" })")
        return ps
    }
    func run(_ body: @escaping () async -> String?) -> String? {
        var fin = false
        var why: String?
        Task { @MainActor in why = await body(); fin = true }
        pumpUntil(240) { fin }
        pump(0.5)
        return why
    }
    /// An async call's value, the run loop pumped meanwhile (nil on a throw).
    func awaitValue<T>(_ body: @escaping () async throws -> T) -> T? {
        var out: T?
        var fin = false
        Task { @MainActor in out = try? await body(); fin = true }
        pumpUntil(120) { fin }
        return out
    }
    func reopened(_ m: FlexibleStageModel) { pumpUntil(180) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }; pump(1) }


    // MARK: - the pictures

    /// His live pad as saved (his 11 deleted faces) on a main stage's shared model, the scene settled.
    func openLive() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleTopLayerFixtures.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "scene")
        pumpUntil(60) { !m.readiness.designing }
        return (r, m)
    }

    /// 1 the pick card with no list — only the pressable lit on the part (beside his img_1019_5); 2 his edges group (Edge 16 + Edge 18)
    /// open: the lit ones a tap adds, the purple prism, Tilt/Twist, a depth typed far past — the red line; 3 a second edges group: the
    /// chips that move a press.
    func testA_LivePad() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E1B_DIR") }
        let (r, m) = try openLive()
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        setCam(h, az: .pi / 4, el: .pi / 6)
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "listed")
        let pk = try XCTUnwrap(m.edgePick)
        log.append("pick: \(pk.candidates.count) candidates · drawn \(pk.drawn.count) · greyed \(pk.greyed.sorted { $0.key < $1.key }.map { "#\($0.key) \($0.value)" })")
        if let a = try shot("E1b_01_13p_live_pick_only_the_pressable_lit.png", h) { try beside(a, "E1b_02_his_img_1019_5_beside.png") }
        m.cancelEdgePick()
        let ps = try pick(m, [[3, 2], [3, 4]])
        let press = try XCTUnwrap(ps.first)
        if let g = m.squeezeGroup(ofPress: press.id) { m.rail = .group(g.id) }
        m.selectedPress = press.id
        pumpUntil(240) { m.edgeAdd.map { !$0.loading && !$0.checking } ?? false }
        _ = run { await m.setFlatCut(press.id, depthMM: 60, direction: press.direction, snap: press.snap) }
        reopened(m)
        pumpUntil(240) { m.edgeAdd.map { !$0.loading && !$0.checking } ?? false }
        setCam(h, az: .pi / 4, el: .pi / 6)
        log.append("edges group: depth \(m.press(press.id)?.settings.deepestMM ?? -1) · stop '\(m.lastFlatStop?.line ?? "-")' · prism fix \(m.lastFlatStop?.prismMM.map { String($0) } ?? "-") · add drawn \(m.edgeAdd?.drawn.map(\.number) ?? [])")
        try shot("E1b_03_13p_edges_group_red_stop_purple_lit_to_add.png", h)
        // a second edges group (a corner, 9 lb): the chips on Edge 16
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "listed again")
        let p2 = try XCTUnwrap(m.edgePick)
        let corner = try XCTUnwrap(p2.drawn.first { $0.kind == .corner }, "a pressable corner")
        m.toggleEdgePick(corner.number)
        m.setEdgePickWeight(9 * 0.45359237)
        _ = run { await m.finishEdgePick() }
        reopened(m)
        if let g = m.squeezeGroup(ofPress: press.id) { m.rail = .group(g.id) }
        m.selectedPress = press.id
        pump(2)
        setCam(h, az: .pi / 4, el: .pi / 6)
        log.append("groups: \(m.squeezeGroups.map { "\(m.groupName($0)) \($0.kind) \($0.presses.count)" }) · chips \(h.frames.all.keys.filter { $0.hasPrefix("edgeGroupChips") })")
        try shot("E1b_04_13p_chips_move_a_press_between_edges_groups.png", h)
        flush("E1b_lines.txt")
    }
}
#endif

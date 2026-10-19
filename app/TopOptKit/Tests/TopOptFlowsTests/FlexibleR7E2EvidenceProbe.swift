// FlexibleR7E2EvidenceProbe — round 7, batch R7-E2: what he will see once edges and corners are SENT to core, as the PAGE draws it —
// the whole Squish page hosted offscreen over the page's own MeshRenderer (the UX verifier's harness, R7-E1 review), the corner
// card's step ②, and the main Lattice page's lattice rendered by the shipping renderer with core's field over the press key beside
// E1's (presses stripped). Opt-in: FLEX_E2_DIR=<dir> (else skipped, counted). Pictures for round7/batch_e2/look/.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class E2Win: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7E2EvidenceProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_E2_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376), l11 = CGSize(width: 1194, height: 834)
    static var hisShot: String { FlexibleHisProject.repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_e1r/look/img_edges_1018.png").path }
    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    /// ★ R7-E2 PARKED (2026-10-19): E2's own tests run with the presses SENT (FlexibleBackend.sendsPresses on — off in the app
    /// until the back-end phase; FlexibleR7E2ParkTests proves the off side).
    override func setUp() {
        super.setUp()
        FlexibleBackend.sendsPresses = true
    }

    override func tearDown() {
        FlexiblePressSupport.apiVersion = { FlexibleScene.pressApiVersion }
        FlexibleStageModel.controlStripPresses = false
        FlexibleBackend.sendsPresses = false
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
        let w = E2Win(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        print("FLEX-E2UX " + log.joined(separator: "\n  "))
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

    // MARK: - R7-E2 PARKED (2026-10-19): the switch OFF, as the app ships

    /// P: his pad, the edges group (Edge 16 + Edge 18, 5 kg) with the switch OFF (the app as it ships now): the Squish page's card
    /// says "Shape only · core support comes later", the arrow dashed, the flat prism and its handles drawn; then the main Lattice
    /// page's lattice — the same as with the presses stripped (E1's rule), density field compared voxel for voxel.
    func testP_ParkedShapeOnly() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E2_DIR") }
        FlexibleBackend.sendsPresses = false
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (r, s, m) = try open(rest: [2, 3, 4, 5])
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "listed")
        let pk = try XCTUnwrap(m.edgePick)
        var labels: [String] = []
        for f in [Set([3, 2]), Set([3, 4])] {
            let c = try XCTUnwrap(FlexibleM2Fixtures.edge(m, pk, faces: f), "edge \(f.sorted())")
            m.toggleEdgePick(c.number)
            labels.append(FlexibleRowCopy.candidateLabel(c))
        }
        m.setEdgePickWeight(5)
        let why = run { await m.finishEdgePick() }
        reopened(m)
        let ps = labels.compactMap { l in m.presses.last { $0.strip?.label == l } }
        XCTAssertEqual(ps.count, 2)
        pumpUntil(120) { ps.allSatisfy { m.pressKey($0.id) != nil } }
        pump(2)
        let press = try XCTUnwrap(ps.first)
        if let g = m.squeezeGroup(ofPress: press.id) { m.rail = .group(g.id) }
        m.selectedPress = press.id
        pump(4)
        setCam(h, az: .pi / 4, el: .pi / 6)
        log.append("[Done] \(labels): \(why ?? "stored") · sent \(m.sentPresses.count) · designed by core \(m.pressDesignTargets.count) · lines \(ps.map { m.pressWarning($0.id).map { "\($0.line) warn \($0.warn)" } ?? "-" })")
        let a = try shot("P01_13p_edges_group_shape_only_dashed.png", h)
        if let a { try beside(a, "P02_his_img_edges_1018_beside_shape_only.png") }
        h.window.orderOut(nil)
        func build(_ tag: String) throws -> FlexDensityField? {
            m.discardLattice()
            s.didExitSettings()
            s.apply(r.project, owned: true, pageUp: false)
            pumpUntil(300) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
            s.heat = false
            s.refresh()
            pump(1)
            log.append("\(tag): lattice \(m.lattice != nil) · error \(m.latticeError ?? "-") · sent \(m.sentPresses.count) · \(m.lattice?.topology ?? "-") \(m.lattice?.tempC ?? 0) °C")
            return m.lastCombinedField
        }
        let off = try build("switch OFF")
        let offLayer = s.layer(r.project, stage: .lattice, pageUp: false)
        FlexibleStageModel.controlStripPresses = true
        let e1 = try build("E1's rule (presses stripped)")
        FlexibleStageModel.controlStripPresses = false
        if let off, let e1 {
            let differ = zip(off.density, e1.density).filter { $0 != $1 }.count
            log.append("density field switch OFF vs E1's rule: \(off.density.count) voxels, \(differ) differ · owner differ \(zip(off.owner, e1.owner).filter { $0 != $1 }.count)")
            XCTAssertEqual(differ, 0, "★ the lattice is E1's")
        }
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let cam = FlexibleRound6Tests.Cam(name: "front-right", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
        if let layer = offLayer {
            let mr = try FlexibleRound6EvidenceProbe().renderer(
                mesh: try XCTUnwrap(s.mesh(r.project, on: .lattice)), tints: s.tints(r.project, on: .lattice, roles: [:], stress: nil),
                dents: s.dents(r.project, on: .lattice), scale: s.dentScale(r.project, on: .lattice), bodyAlpha: s.bodyAlpha(r.project, on: .lattice) ?? 1,
                settle: settle, cam: cam, device: device, items: [], layer: layer)
            let bg = DS.Color.background
            if var px = mr.renderOffscreen(size: 1400, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)) {
                for k in stride(from: 0, to: px.count, by: 4) { px.swapAt(k, k + 2); px[k + 3] = 255 }
                let ctx = try XCTUnwrap(CGContext(data: &px, width: 1400, height: 1400, bitsPerComponent: 8, bytesPerRow: 1400 * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                try writePNG(try XCTUnwrap(ctx.makeImage()), "P03_lattice_switch_off_with_edges_group.png")
            }
        } else { log.append("!! no lattice layer") }
        flush("P_lines.txt")
    }

    // MARK: - the pictures

    /// A: his pad, Group 1 (the Top) beside the edges group (Edge 16 + Edge 18, 5 kg) — both sent: the Squish page's edges tab, the
    /// side label on the card, the arrow SOLID; then core's side closed (an API stub of 1): dashed, "Set up · core support pending".
    func testA_EdgesGroupSent() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E2_DIR") }
        let (r, _, m) = try open(rest: [2, 3, 4, 5])
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        let ps = try pick(m, [[3, 2], [3, 4]])
        let press = try XCTUnwrap(ps.first)
        if let g = m.squeezeGroup(ofPress: press.id) { m.rail = .group(g.id) }
        m.selectedPress = press.id
        pump(4)
        setCam(h, az: .pi / 4, el: .pi / 6)
        log.append("card line \(m.pressWarning(press.id)?.line ?? "-") · toast \(m.toast ?? "-") · side \(m.pressStack(press.id)?.side ?? false)")
        let a = try shot("A01_13p_edges_group_sent_side_label_solid_arrow.png", h)
        if let a { try beside(a, "A01b_his_img_edges_1018_beside_sent.png") }
        let h11 = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.l11)
        pump(2.5)
        setCam(h11, az: .pi / 4, el: .pi / 6)
        try shot("A02_11l_edges_group_sent.png", h11)
        FlexiblePressSupport.apiVersion = { 1 }
        m.pressSupportMemo = nil
        m.objectWillChange.send()
        m.selectedPress = nil; pump(0.3); m.selectedPress = press.id
        pump(1.5)
        log.append("gated: \(m.pressSupport[press.id]?.line ?? "-")")
        try shot("A03_13p_core_side_closed_dashed_pending.png", h)
        FlexiblePressSupport.apiVersion = { FlexibleScene.pressApiVersion }
        m.pressSupportMemo = nil
        m.objectWillChange.send()
        flush("A_lines.txt")
    }

    /// B: the corner card's step ② — Group 1 beside the edges group: the notice and a send per group; the edges group alone: its job
    /// named ("Group 2 · 11 lb · 2 edges · bead 0.45 mm").
    func testB_CardStepTwo() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E2_DIR") }
        let (r, stage, m) = try open(rest: [2, 3, 4, 5])
        _ = try pick(m, [[3, 2], [3, 4]])
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        pumpUntil(300) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        stage.refresh()
        pump(1)
        let run = stage.coreRun
        run.showHold(m.coreHold)
        let status = stage.cornerStatus(m)
        let st = FlexibleLatticeButton.state(status, phase: run.phase, answerIsCurrent: stage.answerIsCurrent(m))
        log.append("two groups: hold '\(m.coreHold?.line ?? "-")' · sends \(m.coreHold?.fixes.map(\.title) ?? []) · state \(st)")
        let h1 = host(FlexibleLatticeCardView(run: run, status: status, state: st, preview: "built", width: 420, maxHeight: 900)
            .padding(20).background(DS.Color.background.color), size: CGSize(width: 460, height: 640))
        try viewShot("B01_card_group1_beside_edges_group.png", h1)
        for r in m.squeezeGroups.first(where: { $0.number == 1 })?.regions ?? [] { m.rest(r) }
        pumpUntil(60) { m.sentSqueezeGroups.count == 1 }
        pumpUntil(300) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        stage.refresh()
        pump(1)
        run.showHold(m.coreHold)
        let status2 = stage.cornerStatus(m)
        let st2 = FlexibleLatticeButton.state(status2, phase: run.phase, answerIsCurrent: stage.answerIsCurrent(m))
        let summary = FlexibleLatticeCard.jobSummary(model: m)
        log.append("edges group alone: summary '\(summary ?? "-")' · state \(st2) · hold \(m.coreHold?.line ?? "none")")
        let h2 = host(FlexibleLatticeCardView(run: run, status: status2, state: st2, preview: "built", width: 420, maxHeight: 900,
                                              summary: FlexibleLatticeCard.shownSummary(state: st2, run: run, summary: { summary }) ?? summary)
            .padding(20).background(DS.Color.background.color), size: CGSize(width: 460, height: 640))
        try viewShot("B02_card_edges_group_alone_step2.png", h2)
        flush("B_lines.txt")
    }

    /// C: the main Lattice page's lattice, the shipping renderer, his pad's Finish None (the walls seen), Group 1 + the edges group
    /// sent — beside the same pad with the presses stripped (E1's lattice); and the density field's slice at mid-height, both.
    func testC_LatticeGradedAlongTheArrow() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E2_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (r, s, m) = try open(rest: [2, 3, 4, 5])
        let ps = try pick(m, [[3, 2], [3, 4]])
        func build(_ tag: String) throws -> FlexDensityField? {
            m.discardLattice()
            s.didExitSettings()
            s.apply(r.project, owned: true, pageUp: false)
            pumpUntil(300) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
            s.heat = false
            s.refresh()
            pump(1)
            log.append("\(tag): lattice \(m.lattice != nil) · error \(m.latticeError ?? "-") · sent \(m.sentPresses.count) · built with \(m.lattice?.topology ?? "-") \(m.lattice?.tempC ?? 0) °C · now \(m.designTopology) \(m.designTempC ?? 0) °C")
            return m.lastCombinedField
        }
        let e2 = try build("E2 (sent)")
        let e2Layer = s.layer(r.project, stage: .lattice, pageUp: false)
        s.xrayOn = true
        let e2X = s.layer(r.project, stage: .lattice, pageUp: false)
        s.xrayOn = false
        // core's own fields on this scene: the Top group's, and each press's over its key (what the firmer-wins combines)
        let b = m.build, top = m.loadedKeys
        var parts: [String] = []
        if let f = awaitValue({ try await m.frameWorker.withScene { try $0.densityField(faces: top.map(\.region), rotations: top.map(\.rotation), build: b) } }) {
            parts.append("the Top's field ρ \(f.density.filter { $0 > 0 }.min() ?? 0)…\(f.density.max() ?? 0)")
            let keys = ps.compactMap { m.pressKey($0.id) }
            if let pf = awaitValue({ try await m.frameWorker.withScene { try $0.densityField(faces: keys, rotations: keys.map { _ in 0 }, build: b) } }), let e2 {
                let expect = FlexibleGroupField.firmer([f, pf]).field
                let differ = expect.density.indices.filter { expect.density[$0] != e2.density[$0] }
                let topDiff = differ.filter { pf.density[$0] <= 0 }.count
                parts.append("the built E2 lattice vs firmer(the Top's field, the edges group's field) now: \(differ.count) voxels differ (\(topDiff) outside the presses' bands)")
            }
            if let c = FlexibleGroupField.sample(f, SIMD3(50, 50, 10)), let e = e2.flatMap({ FlexibleGroupField.sample($0, SIMD3(50, 50, 10)) }) {
                parts.append("at the pad's centre (50, 50, 10): the Top's field \(c) · the built E2 lattice \(e) · topology \(m.designTopology) \(m.designTempC ?? 0) °C")
            }
        }
        for p in ps {
            if let k = m.pressKey(p.id), let f = awaitValue({ try await m.frameWorker.withScene { try $0.densityField(faces: [k], rotations: [0], build: b) } }) {
                let assigned = f.density.filter { $0 > 0 }
                parts.append("\(p.strip?.label ?? "") (key \(k)) field ρ \(assigned.min() ?? 0)…\(assigned.max() ?? 0) over \(assigned.count) voxels")
            }
            if let st = m.pressStack(p.id) {
                let runs = st.columns.map { $0.exitT - $0.entryT }
                parts.append("\(p.strip?.label ?? "") stack: \(st.columns.count) columns, entry→exit \(String(format: "%.1f", runs.min() ?? 0))…\(String(format: "%.1f", runs.max() ?? 0)) mm, lattice \(String(format: "%.1f", st.latticeMMMin))…\(String(format: "%.1f", st.latticeMMMax)) mm")
            }
            if let d = m.pressDesign(p.id) {
                parts.append("\(p.strip?.label ?? "") design: ok \(d.ok) too firm \(d.tooFirm) too soft \(d.tooSoft) beyond \(d.beyondData) · ρ \(d.buildableDensityRange.map { "\($0.lowerBound)…\($0.upperBound)" } ?? "-")")
            }
        }
        log.append(parts.joined(separator: "\n  "))
        FlexibleStageModel.controlStripPresses = true
        let e1 = try build("E1 (presses stripped)")
        log.append("E1: topology \(m.designTopology) \(m.designTempC ?? 0) °C · at the centre \(e1.flatMap { FlexibleGroupField.sample($0, SIMD3(50, 50, 10)) } ?? -9)")
        let e1Layer = s.layer(r.project, stage: .lattice, pageUp: false)
        s.xrayOn = true
        let e1X = s.layer(r.project, stage: .lattice, pageUp: false)
        s.xrayOn = false
        FlexibleStageModel.controlStripPresses = false
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let cam = FlexibleRound6Tests.Cam(name: "front-right", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
        for (tag, layer) in [("C01_lattice_E2_graded_along_the_arrow", e2Layer), ("C02_lattice_E1_presses_stripped", e1Layer),
                             ("C05_lattice_E2_xray", e2X), ("C06_lattice_E1_xray", e1X)] {
            guard let layer else { log.append("!! \(tag): no layer"); continue }
            s.xrayOn = tag.hasSuffix("xray")   // (the ghost body with it)
            defer { s.xrayOn = false }
            let mr = try FlexibleRound6EvidenceProbe().renderer(
                mesh: try XCTUnwrap(s.mesh(r.project, on: .lattice)), tints: s.tints(r.project, on: .lattice, roles: [:], stress: nil),
                dents: s.dents(r.project, on: .lattice), scale: s.dentScale(r.project, on: .lattice), bodyAlpha: s.bodyAlpha(r.project, on: .lattice) ?? 1,
                settle: settle, cam: cam, device: device, items: [], layer: layer)
            let bg = DS.Color.background
            if var px = mr.renderOffscreen(size: 1400, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)) {
                for k in stride(from: 0, to: px.count, by: 4) { px.swapAt(k, k + 2); px[k + 3] = 255 }
                let ctx = try XCTUnwrap(CGContext(data: &px, width: 1400, height: 1400, bitsPerComponent: 8, bytesPerRow: 1400 * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                try writePNG(try XCTUnwrap(ctx.makeImage()), tag + ".png")
            }
        }
        // the field's slice at mid-height (z ≈ 10 mm): density as grey (−1 not lattice: black; 0 unassigned: dark red)
        // one scale for both slices (the lightest ρ of either to the densest of either)
        let both = (e2?.density ?? []) + (e1?.density ?? [])
        let lat0 = both.filter { $0 > 0 }
        let hi = Double(lat0.max() ?? 1), lo = Double(lat0.min() ?? 0)
        for (tag, f) in [("C03_density_slice_z10_E2", e2), ("C04_density_slice_z10_E1", e1)] {
            guard let f else { continue }
            let k = Swift.max(0, Swift.min(f.nz - 1, Int(((10 - f.origin.z) / f.spacing).rounded(.down))))
            let sc = 6
            let W = f.nx * sc, H = f.ny * sc
            var px = [UInt8](repeating: 0, count: W * H * 4)
            for j in 0..<f.ny { for i in 0..<f.nx {
                let d = Double(f.density[f.index(i, j, k)])
                var c: (UInt8, UInt8, UInt8) = (0, 0, 0)
                if d == 0 { c = (90, 20, 20) } else if d > 0 {
                    let t = hi > lo ? (d - lo) / (hi - lo) : 1
                    let g = UInt8(60 + 195 * t)
                    c = (g, g, g)
                }
                for dy in 0..<sc { for dx in 0..<sc {
                    let x = i * sc + dx, y = (f.ny - 1 - j) * sc + dy
                    let o = (y * W + x) * 4
                    px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2; px[o + 3] = 255
                } }
            } }
            let ctx = try XCTUnwrap(CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            try writePNG(try XCTUnwrap(ctx.makeImage()), tag + ".png")
            log.append("\(tag): layer k \(k) · ρ \(lo)…\(hi)")
        }
        if let e2, let e1 {
            let moved = e2.density.indices.filter { e2.density[$0] != e1.density[$0] }.count
            log.append("voxels whose density moved E1 → E2: \(moved) of \(e2.density.filter { $0 >= 0 }.count) lattice voxels")
        }
        _ = ps
        flush("C_lines.txt")
    }

    /// D: Edge 16 at 10.6 mm twisted 15° — the card's honest line "Twisted · squish shape up to N% off".
    func testD_TwistLine() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E2_DIR") }
        let (r, _, m) = try open(rest: [])
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        let press = try XCTUnwrap(try pick(m, [[3, 2]]).first)
        var old = m.pressKey(press.id)
        _ = run { await m.setFlatCut(press.id, depthMM: 10.6, direction: press.direction, snap: press.snap) }
        reopened(m)
        pumpUntil(240) { (m.pressKey(press.id) ?? old) != old && m.pressDesign(press.id) != nil }
        old = m.pressKey(press.id)
        let why = run { await m.setFlatAngle(press.id, degrees: 15, tilt: false) }
        reopened(m)
        let landed = pumpUntil(240) { (m.pressKey(press.id) ?? old) != old && m.pressDesign(press.id) != nil && m.pressSupport[press.id]?.inJob == true }
        log.append("after the twist: landed \(landed)")
        if let g = m.squeezeGroup(ofPress: press.id) { m.rail = .group(g.id) }
        m.selectedPress = press.id
        pump(2)
        setCam(h, az: .pi / 4, el: .pi / 6)
        log.append("twist 15° at 10.6 mm: \(why ?? "stored") · line \(m.pressWarning(press.id)?.line ?? "-") · N \(m.pressOffPercent(press.id) ?? -1)% · map \(m.pressMap(press.id).map { "\($0.mode)" } ?? "-")")
        try shot("D01_13p_twisted_15_line.png", h)
        flush("D_lines.txt")
    }

    /// E: Edge 16 beside Face 3 pressed WHOLE: the card says the shared surface in his words, with its fixes.
    func testE_SharedFootprintWords() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E2_DIR") }
        let (r, _, m) = try open(rest: [2, 3, 4, 5])
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.p13)
        pump(3)
        let press = try XCTUnwrap(try pick(m, [[3, 2]]).first)
        m.edit { s in var f = FlexibleFaceSettings(faceRegionID: 3); f.weightKg = 5; s.setFace(f) }
        pumpUntil(60) { m.pressSupport[press.id]?.inJob == false }
        if let g = m.squeezeGroup(ofPress: press.id) { m.rail = .group(g.id) }
        m.selectedPress = press.id
        pump(3)
        setCam(h, az: .pi / 4, el: .pi / 6)
        log.append("shared: \(m.pressWarning(press.id).map { "\($0.line) · fixes \($0.fixes.map(\.title))" } ?? "-")")
        try shot("E01_13p_shared_footprint_words_and_fixes.png", h)
        flush("E_lines.txt")
    }
}
#endif

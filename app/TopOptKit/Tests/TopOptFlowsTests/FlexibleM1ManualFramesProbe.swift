// FlexibleM1ManualFramesProbe — round 7 · MANUAL, part M1: the four renders at 13" portrait on HIS pad of 10-21.
//   (1) the Squish card in Auto (as today), (2) the same card in Manual (the toggle at the top, his four lines on [Model], Auto's
//   rows gone), (3) a group with its own lattice, (4) Bend on in Manual — the card's line says it is the app's estimate.
// Frames only with FLEX_M1_DIR=<dir>. The harness is FlexibleI1R2FramesProbe's (from FlexibleU1Tests).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class M1Win: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleM1ManualFramesProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_M1_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376)
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    func testManualFramesOnHisPad() throws {
        guard Self.dir != nil else { throw XCTSkip("frames only with FLEX_M1_DIR") }
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlNoRefine = true
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }, "scene")
        let strips = m.presses.filter { $0.strip != nil }
        pumpUntil(240) { strips.allSatisfy { m.pressKey($0.id) != nil } }
        pumpUntil(60) { !m.readiness.designing }
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(pumpUntil(400) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }, "lattice (Auto)")
        let groups = m.squeezeGroups
        let g = try XCTUnwrap(groups.first { $0.kind == .faces } ?? groups.first)
        let loop = FlexibleSquishLoop()
        m.views = [.heatOff]
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)

        // (1) Auto — the card as today
        m.rail = .model
        pump(1.5)
        XCTAssertNotNil(h.frames.all["manualToggle"], "the toggle drawn at the top of the card")
        log.append("(1) Auto: isManual \(m.isManual) · manual \(String(describing: m.settings.manual)) · toggle frame \(h.frames.all["manualToggle"].map { "\($0)" } ?? "-")")
        try shot("M1_01_13p_pad_squish_card_AUTO.png", h, settle: 1.5)

        // (2) Manual — a tap on [Manual]
        let t = try XCTUnwrap(h.frames.all["manualToggle"])
        click(h, CGPoint(x: t.minX + t.width * 0.22, y: t.midY))
        pump(1.5)
        XCTAssertTrue(m.isManual, "★ a tap on [Manual] turns Manual on")
        let part = try XCTUnwrap(m.manualLattice(group: nil))
        log.append(String(format: "(2) Manual: part %@ · cell %.2f mm · density %.4f · walls %.3f beads (seeded from Auto's lattice)",
                          part.topology, m.manualCellMM(group: nil) ?? -1, part.density, m.manualWalls(group: nil) ?? -1))
        try shot("M1_02_13p_pad_squish_card_MANUAL.png", h, settle: 1.5)

        // (3) a group with its own lattice: [Set its own], 2-bead walls
        m.rail = .group(g.id)
        if let r0 = g.regions.first { m.select(r0) }
        pump(1)
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualBeads(2, group: g.id)
        pump(1.5)
        let own = try XCTUnwrap(m.manualLattice(group: g.id))
        log.append(String(format: "(3) %@ own: %@ · cell %.2f mm · density %.4f · walls %.3f beads", m.groupName(g), own.topology, m.manualCellMM(group: g.id) ?? -1,
                          own.density, m.manualWalls(group: g.id) ?? -1))
        try shot("M1_03_13p_pad_group_own_lattice.png", h, settle: 1.5)

        // (4) Bend on in Manual — the lattice rebuilt from his values, the sims his lattice's estimate
        m.discardLattice()
        m.generateLattice()
        XCTAssertTrue(pumpUntil(400) { m.lattice != nil && !m.latticeBuilding }, "lattice (Manual)")
        let id = FlexibleSim.groupID(g.number)
        m.startSquishSims(first: id)
        XCTAssertTrue(pumpUntil(600) { m.squish[id] != nil && m.squish[id] != .pending }, "the sim (Manual)")
        if let f = m.squish[id]?.field {
            log.append(String(format: "(4) %@ sim: bc %@ · k %.3f · max|u| %.2f mm", m.groupName(g), f.bcMode, f.scale, f.maxDisplacement))
        } else { log.append("(4) sim: \(m.squish[id]?.failure ?? "none")") }
        m.views = [.bend, .heatOff]
        pump(2)
        log.append("(4) view line: '\(m.manualViewLine ?? "-")'")
        try shot("M1_04_13p_pad_bend_on_MANUAL.png", h, settle: 2.5)
        flush("M1_lines.txt")
    }

    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
    }

    func slug(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
    func waitScene(_ m: FlexibleStageModel) -> FlexibleScene? {
        var out: FlexibleScene?
        var done = false
        Task { @MainActor in out = await m.squishWorker.sceneRef(); done = true }
        pumpUntil(30) { done }
        return out
    }

    // MARK: the harness (FlexibleR7U21CHandlesHostedTests', from FlexibleU1Tests)

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
        let w = M1Win(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        print("FLEX-M1F " + log.joined(separator: "\n  "))
        if let d = Self.dir { try? (log.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }

    /// The page as he sees it: its renderer offscreen (its camera, its viewport) under the hosted chrome (FlexibleU1Tests.shot).
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

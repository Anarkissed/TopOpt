// FlexibleI1R2FramesProbe — round 7 · U21 batch I, part I1: the R2 FRAMES for his morning decision (NOT shipped).
//   His decision of 2026-10-22 ~02:50: "The Rest-gripping change (R2: a Rest bonded; far anvil removed for rest groups) waits:
//   render his pad's unbalanced groups under that rule beside today's and send the frames to him + the reviewer in the morning
//   for a separate yes/no." The reviewer's R2 (06:38): provisional, frames first.
// R2 is behind a TEST-ONLY switch: the solver's existing control bits 2048 (every Rest bonded) | 32768 (no far anvil) — the
// rule for an UNBALANCED group (a balanced one would keep its non-anvil Rests sliding); nothing of it is in the app.
// His live pad of 10-21 (Rests on the bottom sections), the Squish page at 13" portrait, Play held at FULL load at ×1, the SAME
// camera for every frame, refines off (the quick linear field in both, apples to apples). Frames only with FLEX_I1_DIR=<dir>.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class I1Win: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleI1R2FramesProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_I1_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376)
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    func testR2FramesOnHisPad() throws {
        guard Self.dir != nil else { throw XCTSkip("frames only with FLEX_I1_DIR") }
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.squishSolver.controlNoRefine = true
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }, "scene")
        let strips = m.presses.filter { $0.strip != nil }
        pumpUntil(240) { strips.allSatisfy { m.pressKey($0.id) != nil } }
        pumpUntil(60) { !m.readiness.designing }
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(pumpUntil(400) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }, "lattice")
        let groups = m.squeezeGroups
        log.append("his pad: groups \(groups.map { "\(m.groupName($0)) \($0.kind) regions \($0.regions) presses \($0.presses.count)" }) · rests \(m.holdResting)")
        func solveAll(_ what: String) throws {
            let ids = groups.map { FlexibleSim.groupID($0.number) }
            for id in ids { m.startSquishSims(first: id) }
            XCTAssertTrue(pumpUntil(600) { ids.allSatisfy { m.squish[$0] != nil && m.squish[$0] != .pending } }, "\(what): the sims")
            for g in groups {
                let id = FlexibleSim.groupID(g.number)
                if let f = m.squish[id]?.field {
                    log.append(String(format: "%@ %@: bc %@ · k %.3f (asked %.3f%@) · fold share %@ · s·gmax(part) %.3f · max|u| %.2f mm · line '%@'",
                                      what, m.groupName(g), f.bcMode, f.scale, f.coreRatio, f.clamped ? ", clamped" : "",
                                      f.foldShare.map { String(format: "%.3f", $0) } ?? "none", f.gmaxPart, f.maxDisplacement, m.holdLine(g)))
                } else { log.append("\(what) \(m.groupName(g)): \(m.squish[id]?.failure ?? "no sim")") }
            }
        }
        try solveAll("TODAY")
        // which groups are unbalanced (the bridge's own receipt)
        if let req = m.lastFERequest, let scene = waitScene(m) {
            for sim in req.sims {
                let q = try scene.squishSolve(req.request(sim))
                log.append(String(format: "balance %@: |Σf| %.2f of Σ|f| %.2f N (%.1f %%) · far anvils %d", sim.id, simd_length(q.appliedForceN),
                                  q.appliedForceAbsN, 100 * simd_length(q.appliedForceN) / max(q.appliedForceAbsN, 1e-9), q.farAnvils))
            }
            // the edges group's presses, each alone as its sim solves them (today vs R2's bits)
            if let base = m.feBase {
                for w in m.pressSimWants {
                    for (i, p) in w.presses.enumerated() {
                        let one = FlexibleFERequest.pressSim(id: w.sim.id, presses: [p], voxels: base.rho.count)
                        let a = try scene.squishSolve(base.request(one))
                        let b = try scene.squishSolve(base.request(one, control: FlexibleFE.bondedRests | 32768))
                        log.append(String(format: "%@ press %d: today bc %@ · far anvils %d · free modes %d · held nodes %d · |Σf| %.1f of %.1f N · R2 free modes %d · held nodes %d · fields identical %@",
                                          w.sim.id, i + 1, a.bcMode, a.farAnvils, a.freeModes, a.heldNodes.count, simd_length(a.appliedForceN), a.appliedForceAbsN,
                                          b.freeModes, b.heldNodes.count, "\(a.u == b.u)"))
                    }
                }
            }
        }
        let loop = FlexibleSquishLoop()
        m.views.insert(.play)
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)
        // ONE camera for every frame: from below and to the side (the Rests on the bottom, the pressed sides, the edge)
        var cam: OrbitCamera?
        if let cm = cameraModel(h) {
            var c = cm.camera
            let ae = OrbitCamera.azimuthElevation(forDirection: simd_normalize(SIMD3<Float>(-0.8, -1.1, -0.8)), currentAzimuth: c.azimuth)
            c.setOrientation(azimuth: ae.azimuth, elevation: ae.elevation)
            c.distance *= 2.0
            cm.adopt(c)
            cam = c
        }
        func frame(_ g: FlexibleSqueezeGroup, _ name: String) throws {
            m.rail = .group(g.id)
            if g.kind == .edges { m.selectedPress = g.presses.first } else if let r0 = g.regions.first { m.select(r0) }
            pump(1.5)   // (a pick may move the camera: the one camera is put back after it settles)
            if let c = cam, let cm = cameraModel(h) { cm.adopt(c) }
            loop.exaggeration = 1
            loop.hold(1)
            pump(0.5)
            if let c = cam, let cm = cameraModel(h) { cm.adopt(c); log.append("\(name): camera az \(cm.camera.azimuth) el \(cm.camera.elevation) d \(cm.camera.distance)") }
            log.append("\(name): playing \(m.playingGroup.map { m.groupName($0) } ?? "-") · ×\(loop.exaggeration) · held \(loop.held)")
            try shot(name, h, settle: 2.5)
        }
        let faceGroup = groups.first { $0.kind == .faces }
        let edges = groups.first { $0.kind == .edges }
        if let g = faceGroup { try frame(g, "I1_R2_01_13p_\(slug(m.groupName(g)))_TODAY.png") }
        if let g = edges { try frame(g, "I1_R2_03_13p_\(slug(m.groupName(g)))_TODAY.png") }
        // ★ the R2 rule (NOT shipped): every Rest bonded, the far anvil removed — the same lattice, the sims solved again
        m.squishSolver.controlBits = FlexibleFE.bondedRests | 32768
        m.latticeLanded(m.lastFERequest)
        try solveAll("R2")
        if let g = faceGroup { try frame(g, "I1_R2_02_13p_\(slug(m.groupName(g)))_R2.png") }
        if let g = edges { try frame(g, "I1_R2_04_13p_\(slug(m.groupName(g)))_R2.png") }
        m.squishSolver.controlBits = 0
        flush("I1_R2_lines.txt")
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
        let w = I1Win(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        print("FLEX-I1R2 " + log.joined(separator: "\n  "))
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

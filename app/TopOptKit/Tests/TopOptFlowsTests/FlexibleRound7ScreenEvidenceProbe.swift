// FlexibleRound7ScreenEvidenceProbe — round 7, batch R7-D1: the LOOK (opt-in: FLEX_R7D1_EVIDENCE_DIR=<dir>). The WHOLE app
// page hosted (WorkspacePlaceholder) on HIS pad (A1_0003, FlexiblePressFixtures.a1Project(3, self)), the part drawn by the
// page's own MeshRenderer offscreen under the hosted chrome (the shipping renderer, as every round-7 probe draws it), at
// 13" and 11", portrait and landscape, and the mini in portrait:
//   live   his live lattice (Group C = Face 3 + Face 5 face-prisms at 25 mm; his three squeeze groups): the main page at rest,
//          the Setup tray, the card on Preview ("core runs one group at a time"), the callout (a pressed face with no weight:
//          "How much weight presses Face 4?"), Selections minimised beside the pair, the Squish page with its capsule
//   ready  the Top's own face-prism (20 mm) and ONE squeeze group (Groups 2 and 3 removed on the copy): the card on Ready
// The capsule's ● Flexible menu is a native menu: it draws in its own window, which no view cache holds, so it has no
// frame here (its rows are pinned by FlexibleStageCapsuleTests).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7D1EvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7ScreenEvidenceProbe: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:]; var keepOuts: [CGRect] = [] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7D1_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var tag = ""
    var log: [String] = [] { didSet { if let l = log.last, log.count > oldValue.count { FileHandle.standardError.write(("R7D1-LOOK " + l + "\n").data(using: .utf8)!); writeLog() } } }

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
            .onPreferenceChange(LatticeBandChipKeepOutKey.self) { frames.keepOuts = $0 }
            .environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7D1EvidenceWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
        pump(0.8)
    }
    @discardableResult
    func press(_ h: Host, _ key: String, what: String) -> Bool {
        guard let f = h.frames.all[key], f.width > 0 else { log.append("  (no frame '\(key)' for \(what))"); return false }
        log.append("  tap \(what) [\(key) \(Self.f(f))]")
        click(h, CGPoint(x: f.midX, y: f.midY))
        return true
    }
    static func f(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }

    /// The page renderer (the largest visible MeshRenderer view; `last`: an overlay page's).
    func pageView(_ v: NSView, last: Bool) -> MTKView? {
        var all: [MTKView] = []
        func walk(_ v: NSView) {
            if let m = v as? MTKView, m.delegate is MeshRenderer, !m.isHidden { all.append(m) }
            for s in v.subviews { walk(s) }
        }
        walk(v)
        guard let maxA = all.map({ $0.bounds.width * $0.bounds.height }).max() else { return nil }
        let big = all.filter { $0.bounds.width * $0.bounds.height >= maxA - 1 }
        return last ? big.last : big.first
    }

    /// The page as he would see it: the shipping renderer's frame under the hosted chrome (the round-7 probes' composite).
    func shot(_ h: Host, _ name: String, last: Bool = false) {
        pump(0.8)
        guard let dir = Self.dir else { return }
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        guard let page = rep.cgImage else { return }
        let W = page.width, H = page.height
        var pg = [UInt8](repeating: 0, count: W * H * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let pctx = CGContext(data: &pg, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        pctx.draw(page, in: CGRect(x: 0, y: 0, width: W, height: H))
        let bgc = DS.Color.background
        let bg = (UInt8((bgc.r * 255).rounded()), UInt8((bgc.g * 255).rounded()), UInt8((bgc.b * 255).rounded()))
        var out = [UInt8](repeating: 0, count: W * H * 4)
        let n = max(W, H)
        if let mr = pageView(h.view, last: last)?.delegate as? MeshRenderer {
            let f0 = mr.camera.fovY
            if W > H { mr.camera.fovY = 2 * atan(tan(f0 / 2) * Float(W) / Float(H)) }
            defer { mr.camera.fovY = f0 }
            if var rgba = mr.renderOffscreen(size: n, clear: MTLClearColor(red: bgc.r, green: bgc.g, blue: bgc.b, alpha: 1)) {
                for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
                let x0 = (n - W) / 2, y0 = (n - H) / 2
                for y in 0..<H { for x in 0..<W {
                    let s = 4 * ((y + y0) * n + x + x0), d = 4 * (y * W + x)
                    out[d] = rgba[s]; out[d + 1] = rgba[s + 1]; out[d + 2] = rgba[s + 2]; out[d + 3] = 255
                } }
            }
        } else { log.append("  (\(name): no renderer image — chrome only)") }
        for i in stride(from: 0, to: pg.count, by: 4) {
            let isBg = abs(Int(pg[i]) - Int(bg.0)) <= 3 && abs(Int(pg[i + 1]) - Int(bg.1)) <= 3 && abs(Int(pg[i + 2]) - Int(bg.2)) <= 3
            if (!isBg && pg[i + 3] != 0) || out[i + 3] == 0 { out[i] = pg[i]; out[i + 1] = pg[i + 1]; out[i + 2] = pg[i + 2]; out[i + 3] = 255 }
        }
        guard let octx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let img = octx.makeImage() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("D1_\(tag)_\(name).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
        log.append("wrote D1_\(tag)_\(name).png")
    }
    func writeLog() {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("D1_\(tag)_log.txt"), atomically: true, encoding: .utf8)
    }
    func frames(_ h: Host) -> String {
        ["capsule", "setupChip", "latticeSplit", "mainViews", "setupTray", "latticeCard", "callout"].compactMap { k in
            h.frames.all[k].map { "\(k) \(Self.f($0))" }
        }.joined(separator: " · ")
    }

    func settle(_ s: FlexibleMainStage?, _ t: Double = 420) -> Bool {
        guard let s else { return false }
        return pumpUntil(t) {
            guard let m = s.model else { return false }
            return m.sceneState == .ready && !m.latticeBuilding && !m.readiness.designing && !m.designsInFlight
                && (m.lattice != nil || m.latticeFailure != nil || !m.facePrismsSet)
        }
    }

    // MARK: the runs

    func run(_ tagName: String, _ size: CGSize, ready: Bool) throws {
        tag = tagName + (ready ? "_ready" : "")
        log = []
        Bundle.r7m1vSwap   // the app's resources (the filament catalogue, the stamps) in the test process, as M1-verify's probe
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: ready)
        let p = r.project
        if !ready { try FlexibleR7M1Fixtures.hisLiveLattice(p) }
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        try FlexiblePressFixtures.enterLatticeStage(r.project, click: { click(h, $0) })   // ★ SYNC #354 (89af86dd): no forward buttons since B5 — the ● Topology menu's lattice row
        pump(4)
        let s = FlexibleMainStage.lastMade
        if let s { addTeardownBlock { @MainActor in await s.model?.waitForIdle() } }
        log.append("[\(tag)] the Squish page opened by itself: \(h.frames.all["exitRow"] != nil) (H37: never)")
        let settled = settle(s)
        guard let s, let m = s.model else { XCTFail("no stage"); return }
        if ready {
            // ONE squeeze group on the copy (Groups 2 and 3 removed): the card on Ready
            while m.squeezeGroups.count > 1, let last = m.squeezeGroups.last { m.removeGroup(last.id); pump(0.5) }
            pump(2)
            _ = settle(s)
            pump(3)
            log.append("status '\(s.status.line)' tone \(s.status.tone) · groups \(m.squeezeGroups.map(\.regions))")
            shot(h, "M10_main_ready")
            press(h, "latticeMore", what: "the ⌃ (look, never send)")
            pump(1.5)
            log.append("card: \(frames(h)) · sent \(s.coreRun.runs)")
            shot(h, "M11_card_ready")
            return
        }
        pump(4)
        log.append("settled \(settled) · status '\(s.status.line)' tone \(s.status.tone) · \(frames(h))")
        shot(h, "M01_main_rest")
        press(h, "setupChip", what: "the Setup chip")
        log.append("tray: \(frames(h))")
        shot(h, "M02_setup_tray")
        press(h, "latticeMore", what: "the ⌃")
        pump(1)
        log.append("card: \(frames(h)) · sent \(s.coreRun.runs)")
        shot(h, "M03_card_preview")
        press(h, "latticeMore", what: "the ⌃ again (folds)")
        // Selections minimised beside the pair (#354's panel: its header's chevron)
        if let panel = h.frames.keepOuts.first(where: { abs($0.minX - PageChrome.edge) < 1 && abs($0.width - PageChrome.panelWidth) < 2 }) {
            click(h, CGPoint(x: panel.minX + 73, y: panel.minY + 30))   // "⌄ Selections", its header's button
            pump(1.5)
            let pill = h.frames.keepOuts.filter { abs($0.minX - PageChrome.edge) < 1 && $0.maxY > size.height - 80 }.min { $0.width < $1.width }
            let setup = h.frames.all["setupChip"]
            log.append("Selections minimised: pill \(pill.map(Self.f) ?? "none") · Setup chip \(setup.map(Self.f) ?? "none") · gap \(pill.flatMap { p in setup.map { String(format: "%.1f pt", $0.minX - p.maxX) } } ?? "-")")
            shot(h, "M04_selections_minimised")
            click(h, CGPoint(x: (pill?.minX ?? 24) + 20, y: pill?.midY ?? size.height - 46))
            pump(1)
        } else { log.append("  (no Selections panel frame among \(h.frames.keepOuts.count) keep-outs)") }
        // the callout: a pressed face of his own weight with none ("How much weight presses Face 3?")
        let own = m.settings.loadedFaces.first { $0.weightFrom == nil && $0.faceRegionID < 1_000_000 }?.faceRegionID ?? 3
        m.edit { st in guard var f = st.face(own) else { return }; f.weightKg = 0; st.setFace(f) }
        pump(4)
        log.append("after \(m.displayName(own))'s weight → 0: status '\(s.status.line)' tone \(s.status.tone) · chrome \(String(describing: s.chrome.open)) · \(frames(h))")
        shot(h, "M05_callout")
        // the Squish page, from the capsule
        press(h, "capsuleSquish", what: "the capsule's Squish")
        _ = pumpUntil(10) { h.frames.all["exitRow"] != nil }
        pump(3)
        log.append("Squish page up \(h.frames.all["exitRow"] != nil) · capsule \(h.frames.all["capsule"].map(Self.f) ?? "none") · notice \(h.frames.all["notice"].map(Self.f) ?? "none")")
        shot(h, "S01_squish_page", last: true)
    }

    func test13p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_EVIDENCE_DIR") }; try run("13p", CGSize(width: 1032, height: 1376), ready: false) }
    func test13l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_EVIDENCE_DIR") }; try run("13l", CGSize(width: 1376, height: 1032), ready: false) }
    func test11p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_EVIDENCE_DIR") }; try run("11p", CGSize(width: 834, height: 1194), ready: false) }
    func test11l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_EVIDENCE_DIR") }; try run("11l", CGSize(width: 1194, height: 834), ready: false) }
    func testMiniP() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_EVIDENCE_DIR") }; try run("minip", CGSize(width: 744, height: 1133), ready: false) }
    func test13pReady() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_EVIDENCE_DIR") }; try run("13p", CGSize(width: 1032, height: 1376), ready: true) }
    func test11lReady() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1_EVIDENCE_DIR") }; try run("11l", CGSize(width: 1194, height: 834), ready: true) }
}
#endif

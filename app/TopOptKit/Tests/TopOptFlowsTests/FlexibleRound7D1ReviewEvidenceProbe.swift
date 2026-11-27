// FlexibleRound7D1ReviewEvidenceProbe — round 7, the review of batch R7-D1: the LOOK (opt-in: FLEX_R7D1R_EVIDENCE_DIR=<dir>).
// The WHOLE app page hosted (WorkspacePlaceholder) on HIS pad (FlexiblePressFixtures.a1Project(3, self): Bottom anchors, Top
// 22 lb, Group C's Face 3 + Face 5 face-prisms; his three squeeze groups), the part drawn by the page's own MeshRenderer
// offscreen under the hosted chrome (the shipping renderer, as every round-7 probe draws it), at 13" and 11", portrait and
// landscape, and the mini in portrait — what the review found, after the fixes:
//   R01 at rest (the legend under the views row) · R02 the Setup tray · R03 the plate page · R04 the card on Preview (the
//   hold's line on one line) · R05 Play on + the card (the blocker: the player above or beside the card, never on the cube)
//   · R06 Play on + the Setup tray · R07 a blocker by itself (the callout, its second fix outlined) · R08 the card with that
//   blocker (its fixes in the Core row, ① waits) · R09 the Squish page ("Flexible · Squish")
//   ready: R10 the button on Ready · R11 the card on Ready (what goes to core above [Send to core])
// Each step logs where the player, the legend and the open panel landed and whether any two touch (and the cube, the views
// row, the name row and capsule).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7D1REvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7D1ReviewEvidenceProbe: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7D1R_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var tag = ""
    var log: [String] = [] { didSet { if let l = log.last, log.count > oldValue.count { FileHandle.standardError.write(("R7D1R-LOOK " + l + "\n").data(using: .utf8)!); writeLog() } } }
    var touches = 0

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
        let w = R7D1REvidenceWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func press(_ h: Host, _ key: String, what: String, at: ((CGRect) -> CGPoint)? = nil) -> Bool {
        guard let f = h.frames.all[key], f.width > 0 else { log.append("  (no frame '\(key)' for \(what))"); return false }
        let p = at?(f) ?? CGPoint(x: f.midX, y: f.midY)
        log.append("  tap \(what) [\(key) \(Self.f(f)) at \(Int(p.x)),\(Int(p.y))]")
        click(h, p)
        return true
    }
    static func f(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }

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
        for (url, im) in [(dir.appendingPathComponent("R_\(tag)_\(name).png"), img), (dir.appendingPathComponent("R_\(tag)_\(name)_chrome.png"), page)] {
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, im, nil); CGImageDestinationFinalize(dest)
            }
        }
        log.append("wrote R_\(tag)_\(name).png")
    }
    func writeLog() {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("R_\(tag)_log.txt"), atomically: true, encoding: .utf8)
    }

    /// Where the player, the legend and the open panel are, and whether anything touches what it must not.
    func layout(_ h: Host, _ s: FlexibleMainStage, _ step: String) {
        let v = h.size
        let legend = s.legendCard(viewport: v, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)?.frame
        let panel = ["setupTray", "latticeCard", "callout"].compactMap { k in h.frames.all[k].map { (k, $0) } }.first
        let player = ["playerCapsule", "playerTopRow"].compactMap { h.frames.all[$0] }.filter { $0.width > 1 }
        var bad: [String] = []
        let fixed: [(String, CGRect)] = [("cube", FlexibleLegendPlacement.gizmoFrame(viewport: v)), ("views", FlexibleMainViewToggles.rowFrame(viewport: v)),
                                         ("name row + capsule", FlexibleChromeLayout.topLeftChrome(v))]
        for p in player {
            for (n, k) in fixed + (panel.map { [($0.0, $0.1)] } ?? []) + (legend.map { [("legend", $0)] } ?? []) where p.intersects(k) {
                bad.append("player \(Self.f(p)) on \(n) \(Self.f(k))")
            }
        }
        if let (n, p) = panel, let l = legend, p.intersects(l) { bad.append("\(n) \(Self.f(p)) on the legend \(Self.f(l))") }
        touches += bad.count
        log.append("  \(step): player \(player.map(Self.f).joined(separator: "+").isEmpty ? "none" : player.map(Self.f).joined(separator: "+")) · legend \(legend.map(Self.f) ?? "none") · panel \(panel.map { "\($0.0) \(Self.f($0.1))" } ?? "none") · \(bad.isEmpty ? "nothing touches" : "TOUCHES: " + bad.joined(separator: "; "))")
    }

    func settle(_ s: FlexibleMainStage?, _ t: Double = 420) -> Bool {
        guard let s else { return false }
        return pumpUntil(t) {
            guard let m = s.model else { return false }
            return m.sceneState == .ready && !m.latticeBuilding && !m.readiness.designing && !m.designsInFlight
                && (m.lattice != nil || m.latticeFailure != nil || !m.facePrismsSet)
        }
    }

    func run(_ tagName: String, _ size: CGSize, ready: Bool) throws {
        tag = tagName + (ready ? "_ready" : "")
        log = []
        touches = 0
        Bundle.r7m1vSwap
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
            while m.squeezeGroups.count > 1, let last = m.squeezeGroups.last { m.removeGroup(last.id); pump(0.5) }
            pump(2)
            _ = settle(s)
            pump(3)
            log.append("status '\(s.status.line)' tone \(s.status.tone) · groups \(m.squeezeGroups.map(\.regions))")
            shot(h, "R10_main_ready")
            press(h, "latticeMore", what: "the ⌃ (look, never send)")
            pump(1.5)
            layout(h, s, "R11")
            log.append("card on Ready · sent \(s.coreRun.runs) · job '\(FlexibleLatticeCard.jobSummary(model: m) ?? "none")'")
            shot(h, "R11_card_ready")
            log.append("touches: \(touches)")
            return
        }
        pump(4)
        log.append("settled \(settled) · status '\(s.status.line)' tone \(s.status.tone) · heat \(s.heat) · play \(s.playOn)")
        layout(h, s, "R01")
        shot(h, "R01_rest")
        press(h, "setupChip", what: "the Setup chip")
        layout(h, s, "R02")
        shot(h, "R02_setup")
        press(h, "setupRow-plateUp", what: "Plate up's [Change]", at: { CGPoint(x: $0.maxX - 36, y: $0.midY) })
        pump(1)
        let axes = h.frames.all.filter { $0.key.hasPrefix("plateAxis-") }.map { "\($0.key.dropFirst(10)) \(Int($0.value.width))x\(Int($0.value.height))" }.sorted()
        log.append("  plate page: \(axes.count) buttons [\(axes.joined(separator: ", "))]")
        layout(h, s, "R03")
        shot(h, "R03_plate")
        s.chrome.foldAll()
        pump(1)
        press(h, "latticeMore", what: "the ⌃")
        pump(1)
        log.append("  card: sent \(s.coreRun.runs)")
        layout(h, s, "R04")
        shot(h, "R04_card")
        if !s.playOn { s.togglePlay() }
        pump(3)
        log.append("  Play \(s.playOn) · the bar shown \(s.playerShown)")
        layout(h, s, "R05")
        shot(h, "R05_play_card")
        s.chrome.show(.setup)
        pump(2)
        layout(h, s, "R06")
        shot(h, "R06_play_setup")
        s.chrome.foldAll()
        s.togglePlay()
        pump(1.5)
        // a blocker: a pressed face of his own weight loses it
        let own = m.settings.loadedFaces.first { $0.weightFrom == nil && $0.faceRegionID < 1_000_000 }?.faceRegionID ?? 3
        let kg = m.settings.face(own)?.weightKg ?? 10
        m.edit { st in guard var f = st.face(own) else { return }; f.weightKg = 0; st.setFace(f) }
        pump(4)
        log.append("  weight of \(m.displayName(own)) → 0: status '\(s.status.line)' tone \(s.status.tone) · chrome \(String(describing: s.chrome.open))")
        layout(h, s, "R07")
        shot(h, "R07_callout")
        press(h, "latticeMore", what: "the ⌃ with the blocker")
        pump(1.5)
        layout(h, s, "R08")
        shot(h, "R08_card_blocker")
        s.chrome.foldAll()
        m.edit { st in guard var f = st.face(own) else { return }; f.weightKg = kg; st.setFace(f) }
        pump(3)
        press(h, "capsuleSquish", what: "the capsule's Squish")
        _ = pumpUntil(10) { h.frames.all["exitRow"] != nil }
        pump(3)
        log.append("  Squish page up \(h.frames.all["exitRow"] != nil) · panel '\(FlexibleSettingsPanel.title)'")
        shot(h, "R09_squish", last: true)
        log.append("touches: \(touches)")
    }

    /// The review's minor (d): thin vertical hairlines at the Setup chip's frame edges, outside its capsule — "possibly a macOS
    /// focus artifact". The chip alone, hosted in a KEY window and in a window that is not key: the columns just inside the
    /// frame, outside the capsule, read against the background.
    func testSetupChipEdgesKeyAndNotKey() throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_R7D1R_EVIDENCE_DIR") }
        tag = "chip"; log = []
        let p = ProjectModel(id: UUID(), name: "Pad", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.flexible = FlexibleStageSettings()
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        for key in [true, false] {
            let v = FlexibleSetupChipView(project: p, open: false, tap: {}).padding(20)
                .frame(width: 300, height: 90, alignment: .topLeading).background(DS.Color.background.color)
            let hv = NSHostingView(rootView: AnyView(v.environment(\.colorScheme, .dark)))
            hv.frame = CGRect(x: 0, y: 0, width: 300, height: 90)
            let w = R7D1REvidenceWindow(contentRect: CGRect(x: -20000, y: -20000, width: 300, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = hv
            w.orderFrontRegardless()
            if key { w.makeKey() } else { w.resignKey() }
            hv.layoutSubtreeIfNeeded()
            pump(0.5)
            guard let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { continue }
            hv.cacheDisplay(in: hv.bounds, to: rep)
            let fit = hv.fittingSize
            let scale = CGFloat(rep.pixelsWide) / hv.bounds.width
            var cols: [String] = []
            for x in [19, 20, 21, 22] {
                for y in [32, 58] {
                    if let c = rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale)) {
                        cols.append("(\(x),\(y)) \(String(format: "%.2f", c.brightnessComponent))")
                    }
                }
            }
            log.append("chip in a \(key ? "KEY" : "non-key") window (fits \(Int(fit.width))): " + cols.joined(separator: " · "))
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("R_chip_\(key ? "key" : "notkey").png"))
            }
            w.orderOut(nil); w.contentView = nil
        }
    }

    func test13p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1R_EVIDENCE_DIR") }; try run("13p", CGSize(width: 1032, height: 1376), ready: false) }
    func test13l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1R_EVIDENCE_DIR") }; try run("13l", CGSize(width: 1376, height: 1032), ready: false) }
    func test11p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1R_EVIDENCE_DIR") }; try run("11p", CGSize(width: 834, height: 1194), ready: false) }
    func test11l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1R_EVIDENCE_DIR") }; try run("11l", CGSize(width: 1194, height: 834), ready: false) }
    func testMiniP() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1R_EVIDENCE_DIR") }; try run("minip", CGSize(width: 744, height: 1133), ready: false) }
    func test13pReady() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1R_EVIDENCE_DIR") }; try run("13p", CGSize(width: 1032, height: 1376), ready: true) }
    func test11lReady() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D1R_EVIDENCE_DIR") }; try run("11l", CGSize(width: 1194, height: 834), ready: true) }
}
#endif

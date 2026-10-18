// FlexibleR7D2ReviewEvidenceProbe — round 7, the review of R7-D2: the LOOK after the fixes (opt-in:
// FLEX_R7D2R_EVIDENCE_DIR=<dir>). The WHOLE app page hosted on HIS pad (A1_0003 + his live lattice: Group C = Face 3 + Face 5 at
// 25 mm; Bottom anchors; Top 22 lb), the part drawn by the page's own MeshRenderer offscreen under the hosted chrome, at 13" and
// 11", portrait and landscape — the review's states, each beside the review's own picture of the same state:
//   R00 at rest · R01 the session's first new face (chip N: the held [Lattice] and its two-tap route) · R02 Face 3 tapped (chip
//   M's automatic spot, off the face) · R03 the chip's (i): below the chip, the drawn lattice's numbers · R04 the list's (i) in
//   group scope beside the legend · R05 the Top picked, then Face 2: no "Add to Top as lattice" · R06 Group C picked, then
//   Face 2: the join, its swatch on the blue · R07 [Load] on Face 2: "weight: Squish page", the list in lb · R08 a renamed group's
//   delete question in the list · R08b … in the chip · R09 Play on: the Load's message above the player · R10 Play on: the
//   delete's message and [Undo] above the player · R11 [Prisms] with nothing picked: both of Group C's numbers · R12 img2's
//   front camera, the Top picked.
// Each step logs the frames, the targets under 44 pt and the overlaps between the main chrome pieces.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7D2REvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7D2ReviewEvidenceProbe: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    typealias Cam = FlexibleRound6Tests.Cam
    static let img1 = Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
    static let img2 = Cam(name: "img2 (front)", azimuth: 0, elevation: 0.16, zoom: 1)

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7D2R_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var tag = ""
    var log: [String] = [] { didSet { if let l = log.last, log.count > oldValue.count { FileHandle.standardError.write(("R7D2R-LOOK " + l + "\n").data(using: .utf8)!); writeLog() } } }

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
        let w = R7D2REvidenceWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    func pageView(_ v: NSView) -> MTKView? {
        var all: [MTKView] = []
        func walk(_ v: NSView) {
            if let m = v as? MTKView, m.delegate is MeshRenderer, !m.isHidden { all.append(m) }
            for s in v.subviews { walk(s) }
        }
        walk(v)
        guard let maxA = all.map({ $0.bounds.width * $0.bounds.height }).max() else { return nil }
        return all.first { $0.bounds.width * $0.bounds.height >= maxA - 1 }
    }
    @discardableResult
    func setCam(_ h: Host, _ cam: Cam) -> Bool {
        guard let v = pageView(h.view) else { return false }
        for g in v.gestureRecognizers {
            guard let t = g.target else { continue }
            var mirror: Mirror? = Mirror(reflecting: t)
            while let mm = mirror {
                if let c = mm.children.first(where: { $0.label == "cameraModel" })?.value as? OrbitCameraModel {
                    var cc = c.camera
                    cc.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation)
                    c.adopt(cc)
                    pump(1.5)
                    return true
                }
                mirror = mm.superclassMirror
            }
        }
        log.append("  (no camera model found for \(cam.name))")
        return false
    }

    /// The page as he would see it: the shipping renderer's frame under the hosted chrome.
    func shot(_ h: Host, _ name: String) {
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
        if let mr = pageView(h.view)?.delegate as? MeshRenderer {
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
        let url = dir.appendingPathComponent("D2R_\(tag)_\(name).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
        log.append("wrote D2R_\(tag)_\(name).png")
    }
    func writeLog() {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("D2R_\(tag)_log.txt"), atomically: true, encoding: .utf8)
    }

    /// Every published frame — sizes of targets and overlaps between the main chrome pieces.
    func frames(_ h: Host, _ s: FlexibleMainStage, _ step: String) {
        let v = h.size
        var named = h.frames.all
        named["cube"] = FlexibleLegendPlacement.gizmoFrame(viewport: v)
        named["views"] = FlexibleChromeLayout.viewsRow(viewport: v)
        if let l = s.legendCard(viewport: v, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)?.frame { named["legend"] = l }
        let keys = named.keys.sorted()
        log.append("  [\(step)] frames: " + keys.map { "\($0) \(Self.f(named[$0]!))" }.joined(separator: " | "))
        let small = keys.filter { k in
            (k.hasPrefix("chipNew-") || k.hasPrefix("chipSeg-") || k.hasPrefix("selTrash-") || k == "chipTrash" || k.hasPrefix("info-") || k == "toastUndo" || k == "chipJoin")
                && (named[k]!.width < 43.5 || named[k]!.height < 43.5)
        }
        if !small.isEmpty { log.append("  [\(step)] UNDER 44: " + small.map { "\($0) \(Self.f(named[$0]!))" }.joined(separator: ", ")) }
        let big = ["faceChip", "selectionsList", "setupChip", "latticeSplit", "capsule", "playerCapsule", "playerTopRow", "statsCard", "cube", "views", "legend", "toast"]
        var hits: [String] = []
        for i in 0..<big.count { for j in (i + 1)..<big.count {
            guard let a = named[big[i]], let b = named[big[j]], a.width > 0, b.width > 0 else { continue }
            if a.intersects(b) { hits.append("\(big[i])×\(big[j])") }
        } }
        if let o = named["faceOutline"], let c = named["faceChip"], o.intersects(c) { hits.append("faceChip×faceOutline") }
        log.append("  [\(step)] overlaps: \(hits.isEmpty ? "none" : hits.joined(separator: ", "))")
    }

    func run(_ tagName: String, _ size: CGSize) throws {
        tag = tagName
        log = []
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        click(h, CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2))
        pump(4)
        guard let s = FlexibleMainStage.lastMade, let m = s.model else { XCTFail("no stage"); return }
        s.faceUI.toastSeconds = 120
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        let settled = pumpUntil(420) { m.sceneState == .ready && !m.latticeBuilding && !m.readiness.designing && !m.designsInFlight && (m.lattice != nil || m.latticeFailure != nil) }
        pump(3)
        setCam(h, Self.img1)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        log.append("[\(tag)] settled \(settled) · legend \(String(describing: s.latticeEnds().map { ($0.lo, $0.hi) }))")
        frames(h, s, "R00"); shot(h, "R00_rest")

        s.tapFace(p, face: 2, point: nil, mesh: mesh); pump(1.5)
        frames(h, s, "R01"); shot(h, "R01_chipN_first_new_face_route")

        s.missTap(); pump(0.6)
        s.tapFace(p, face: 3, point: nil, mesh: mesh); pump(1.5)
        frames(h, s, "R02"); shot(h, "R02_chipM_auto_spot_off_the_face")

        press(h, "info-c-" + r3.key, what: "Face 3's (i) on the chip"); pump(1)
        log.append("  R03 (i) rows \(String(describing: s.faceStats(r3, group: c, project: p)?.rows.map { "\($0.label) \($0.value)" }))")
        frames(h, s, "R03"); shot(h, "R03_chip_info_below_the_chip")
        s.faceUI.info = nil

        s.heat = false; pump(1.2)
        s.pickGroup(c, project: p); pump(1.2)
        press(h, "info-l-" + r3.key, what: "Face 3's (i) in the list"); pump(1)
        frames(h, s, "R04"); shot(h, "R04_list_info_beside_the_legend")
        s.faceUI.info = nil; s.heat = true; pump(1)

        s.pickGroup(top.id, project: p); pump(1.2)
        s.tapFace(p, face: 2, point: nil, mesh: mesh); pump(1.5)
        log.append("  R05 lastGroup \(String(describing: s.facePick.lastGroup)) canJoin(top) \(FlexibleFaceCommits.canJoin(top.id, p))")
        frames(h, s, "R05"); shot(h, "R05_top_then_face2_no_join")

        s.missTap(); pump(0.5)
        s.pickGroup(c, project: p); pump(1.2)
        s.tapFace(p, face: 2, point: nil, mesh: mesh); pump(1.5)
        frames(h, s, "R06"); shot(h, "R06_groupC_then_face2_join")

        s.commitNew(.load, project: p) {}; pump(1.5)
        log.append("  R07 toast \(String(describing: s.faceUI.toast?.text)) · groups \(p.selection.groups.map(\.name)) · weights \(p.selection.groups.map { FlexibleFaceChip.loadWeight(p, $0.id, ui: s.faceUI) ?? "-" })")
        frames(h, s, "R07"); shot(h, "R07_load_weight_on_squish_page_lb")
        s.faceUI.toast = nil

        FlexibleFaceCommits.rename(c, to: "Left side squeeze pad", project: p)
        s.tapFace(p, face: 3, point: nil, mesh: mesh); pump(1.2)
        s.askDelete(c); pump(1)
        frames(h, s, "R08"); shot(h, "R08_long_name_delete_ask_list")
        s.faceUI.deleteAsk = nil
        s.askDelete(c, inChip: true); pump(1)
        frames(h, s, "R08b"); shot(h, "R08b_long_name_delete_ask_chip")
        s.faceUI.deleteAsk = nil
        FlexibleFaceCommits.rename(c, to: "Group C", project: p)
        pump(0.5)

        s.togglePlay()
        _ = pumpUntil(90) { h.frames.all["playerCapsule"] != nil }
        pump(1)
        s.tapFace(p, face: 4, point: nil, mesh: mesh); pump(1.2)
        s.commitNew(.load, project: p) {}; pump(1.5)
        frames(h, s, "R09"); shot(h, "R09_play_on_load_message_above_player")
        s.faceUI.toast = nil
        s.askDelete(c)
        s.confirmDelete(project: p) {}; pump(1.2)
        frames(h, s, "R10"); shot(h, "R10_play_on_delete_message_above_player")
        s.undoDelete(project: p) {}; pump(1.5)
        s.togglePlay(); pump(1.2)

        s.missTap()
        m.views.insert(.prisms); pump(1.5)
        frames(h, s, "R11"); shot(h, "R11_prisms_view_both_numbers")
        m.views.remove(.prisms); pump(1)

        setCam(h, Self.img2)
        s.pickGroup(top.id, project: p); pump(1.5)
        frames(h, s, "R12"); shot(h, "R12_img2_front_top_picked")
        log.append("done")
    }

    func test13p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D2R_EVIDENCE_DIR") }; try run("13p", CGSize(width: 1032, height: 1376)) }
    func test13l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D2R_EVIDENCE_DIR") }; try run("13l", CGSize(width: 1376, height: 1032)) }
    func test11p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D2R_EVIDENCE_DIR") }; try run("11p", CGSize(width: 834, height: 1194)) }
    func test11l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D2R_EVIDENCE_DIR") }; try run("11l", CGSize(width: 1194, height: 834)) }
}
#endif

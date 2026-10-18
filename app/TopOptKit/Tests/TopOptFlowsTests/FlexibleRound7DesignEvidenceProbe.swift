// FlexibleRound7DesignEvidenceProbe — round 7, batch R7-D3: the WHOLE redesigned Flexible stage on HIS pad, every state the plan
// lists, for LOOKING (opt-in: FLEX_R7D_EVIDENCE_DIR=<dir>). The app page hosted (WorkspacePlaceholder) on A1_0003 + his live
// lattice (Group C = Face 3 + Face 5 at 25 mm; Bottom anchors; Top 22 lb), the part drawn by the page's own MeshRenderer
// offscreen under the hosted chrome (the shipping renderer, as every round-7 probe draws it), at 13" and 11" in both
// orientations and the mini in portrait:
//   D00 at rest (the capsule, the views row, the one legend, the corner pair, the quiet list) · D01 "Lattice ready" beside the
//   icons · D02 the Setup tray · D03 the plate page · D04 the card on Preview · D05 a blocker: the callout · D06 the card with
//   the blocker · D07 Group C picked: the list's boxes and the prism's numbers (25.0), the printed view (X-ray off) · D08 the
//   same in X-ray · D09 chip M with its (i) · D10 chip N with the filled join · D11 the chip dragged, then an orbit: its spot
//   kept, its leader re-aimed · D12 the depth handle mid-drag · D13 the trash's question · D14 the message with [Undo] ·
//   D15 after [Undo] · D16 Selections minimised with a chip open · D17 Play on (the player above the pair) · D18 Play on + the
//   card · D19 the Squish page (Squish lit)
//   ready (one squeeze group, his Top's face-prism): R20 the button on Ready · R21 the card on Ready (what goes to core)
// Each step logs every published frame, the targets under 44 pt, and every overlap between the main pieces of chrome.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7DEvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7DesignEvidenceProbe: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    typealias Cam = FlexibleRound6Tests.Cam
    static let img1 = Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
    static let orbit = Cam(name: "orbit", azimuth: .pi / 4 + 0.5, elevation: 0.5, zoom: 1)

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7D_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var tag = ""
    var touches = 0
    var log: [String] = [] { didSet { if let l = log.last, log.count > oldValue.count { FileHandle.standardError.write(("R7D-LOOK " + l + "\n").data(using: .utf8)!); writeLog() } } }

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
        let w = R7DEvidenceWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        log.append("  tap \(what) [\(key) \(Self.f(f))]")
        click(h, p)
        return true
    }
    static func f(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }

    func pageView(_ v: NSView, last: Bool = false) -> MTKView? {
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
        let url = dir.appendingPathComponent("D3_\(tag)_\(name).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
        log.append("wrote D3_\(tag)_\(name).png")
    }
    func writeLog() {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("D3_\(tag)_log.txt"), atomically: true, encoding: .utf8)
    }

    /// Every published frame, the targets under 44 pt, and the overlaps between the main pieces (the cube, the views row, the
    /// legend from the stage, the rest as published).
    func frames(_ h: Host, _ s: FlexibleMainStage, _ step: String) {
        let v = h.size
        var named = h.frames.all
        named["cube"] = FlexibleLegendPlacement.gizmoFrame(viewport: v)
        named["views"] = FlexibleChromeLayout.viewsRow(viewport: v)
        if let l = s.legendCard(viewport: v, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)?.frame { named["legend"] = l }
        let keys = named.keys.sorted()
        log.append("  [\(step)] frames: " + keys.map { "\($0) \(Self.f(named[$0]!))" }.joined(separator: " | "))
        let small = keys.filter { k in
            (k.hasPrefix("chipNew-") || k.hasPrefix("chipSeg-") || k.hasPrefix("selTrash-") || k == "chipTrash" || k.hasPrefix("info-")
             || k == "toastUndo" || k == "chipJoin" || k.hasPrefix("capsule") || k == "latticeMore" || k == "deleteConfirm")
                && (named[k]!.width < 43.5 || named[k]!.height < 43.5)
        }
        if !small.isEmpty { log.append("  [\(step)] UNDER 44: " + small.map { "\($0) \(Self.f(named[$0]!))" }.joined(separator: ", ")) }
        let big = ["faceChip", "selectionsList", "setupChip", "latticeSplit", "capsule", "playerCapsule", "playerTopRow", "playerNote",
                   "statsCard", "cube", "views", "legend", "toast", "mainNote", "setupTray", "latticeCard", "callout"]
        var hits: [String] = []
        for i in 0..<big.count { for j in (i + 1)..<big.count {
            guard let a = named[big[i]], let b = named[big[j]], a.width > 1, b.width > 1 else { continue }
            if a.intersects(b) { hits.append("\(big[i])×\(big[j])") }
        } }
        touches += hits.count
        log.append("  [\(step)] overlaps: \(hits.isEmpty ? "none" : hits.joined(separator: ", "))")
    }

    func settle(_ s: FlexibleMainStage?, _ t: Double = 420) -> Bool {
        guard let s else { return false }
        return pumpUntil(t) {
            guard let m = s.model else { return false }
            return m.sceneState == .ready && !m.latticeBuilding && !m.readiness.designing && !m.designsInFlight
                && (m.lattice != nil || m.latticeFailure != nil || !m.facePrismsSet)
        }
    }

    func run(_ tagName: String, _ size: CGSize) throws {
        tag = tagName
        log = []
        touches = 0
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
        s.note.seconds = 120
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        log.append("[\(tag)] the Squish page opened by itself: \(h.frames.all["exitRow"] != nil) (H37: never)")
        let settled = settle(s)
        pump(3)
        setCam(h, Self.img1)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        log.append("settled \(settled) · status '\(s.status.line)' · heat \(s.heat) · xray \(s.xrayOn) · legend \(String(describing: s.latticeEnds().map { ($0.lo, $0.hi) }))")
        frames(h, s, "D00"); shot(h, "D00_rest")

        s.note.post(.ready); pump(1.2)
        frames(h, s, "D01"); shot(h, "D01_lattice_ready_note")
        s.note.clear(); pump(0.6)

        press(h, "setupChip", what: "the Setup chip"); pump(0.8)
        frames(h, s, "D02"); shot(h, "D02_setup_tray")
        press(h, "setupRow-plateUp", what: "Plate up's [Change]", at: { CGPoint(x: $0.maxX - 36, y: $0.midY) }); pump(1)
        frames(h, s, "D03"); shot(h, "D03_plate_page")
        s.chrome.foldAll(); pump(0.8)

        press(h, "latticeMore", what: "the ⌃ (look; never a send)"); pump(1.2)
        log.append("  card on Preview: core runs \(s.coreRun.runs)")
        frames(h, s, "D04"); shot(h, "D04_card_preview")
        s.chrome.foldAll(); pump(0.6)

        // a blocker: a pressed face of his own weight loses it
        let own = m.settings.loadedFaces.first { $0.weightFrom == nil && $0.faceRegionID < 1_000_000 }?.faceRegionID ?? 3
        let kg = m.settings.face(own)?.weightKg ?? 10
        m.edit { st in guard var f = st.face(own) else { return }; f.weightKg = 0; st.setFace(f) }
        pump(4)
        log.append("  weight of \(m.displayName(own)) → 0: status '\(s.status.line)' · chrome \(String(describing: s.chrome.open))")
        frames(h, s, "D05"); shot(h, "D05_blocker_callout")
        press(h, "latticeMore", what: "the ⌃ with the blocker"); pump(1.2)
        frames(h, s, "D06"); shot(h, "D06_card_with_the_blocker")
        s.chrome.foldAll()
        m.edit { st in guard var f = st.face(own) else { return }; f.weightKg = kg; st.setFace(f) }
        _ = settle(s); pump(3)

        s.pickGroup(c, project: p); pump(1.5)
        let boxes = h.frames.all.keys.filter { $0.hasPrefix("numberBox-") }.sorted()
        log.append("  D07 Group C: depth \(FlexibleLatticeHandles.depthText(p.latticeSlabDepthMM(r3, in: c))) · boxes \(boxes)")
        frames(h, s, "D07"); shot(h, "D07_groupC_list_boxes_eq_prism_numbers_printed")
        s.toggleXray(); pump(1.5)
        frames(h, s, "D08"); shot(h, "D08_groupC_xray")
        s.toggleXray(); pump(1)

        s.tapFace(p, face: 3, point: nil, mesh: mesh); pump(1.5)
        press(h, "info-c-" + r3.key, what: "Face 3's (i) on the chip"); pump(1)
        log.append("  D09 (i) \(String(describing: s.faceStats(r3, group: c, project: p)?.rows.map { "\($0.label) \($0.value)" }))")
        frames(h, s, "D09"); shot(h, "D09_chipM_info")
        s.faceUI.info = nil

        s.tapFace(p, face: 2, point: nil, mesh: mesh); pump(1.5)
        frames(h, s, "D10"); shot(h, "D10_chipN_filled_join")

        if let key = s.facePick.scope.chipKey, let chip = h.frames.all["faceChip"] {
            let to = FlexibleFaceChipLayout.dragged(anchor: chip.origin, translation: CGSize(width: -60, height: -140), size: chip.size, viewport: size)
            // what the drag writes, then where its let-go leaves it (an offscreen test cannot drive a SwiftUI drag; the chrome as
            // published stands in for the layer's own keep-outs)
            let chrome = ["capsule", "setupChip", "latticeSplit", "selectionsList"].compactMap { h.frames.all[$0] }
                + [FlexibleLegendPlacement.gizmoFrame(viewport: size), FlexibleMainViewToggles.frame(viewport: size)]
                + [s.legendCard(viewport: size, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)?.frame].compactMap { $0 }
            s.faceUI.spots[key] = FlexibleFaceChipLayout.released(to, viewport: size, keepOut: chrome).origin
            pump(0.8)
            setCam(h, Self.orbit); pump(1)
            frames(h, s, "D11"); shot(h, "D11_chip_dragged_then_orbit_leader")
            setCam(h, Self.img1); pump(1)
            s.faceUI.spots[key] = nil
        }
        s.missTap(); pump(0.6)

        // the depth handle mid-drag (the drag's own calls: begin, live writes, end — one undo step)
        s.tapFace(p, face: 3, point: nil, mesh: mesh); pump(1.2)
        let key3 = "handle-depth-\(r3.key)"
        s.beginHandleDrag(p, key: key3)
        var sess = s.facePick
        FlexibleFaceCommits.writeDepth(19.0, ref: r3, group: c, project: p, session: &sess)
        pump(1.5)
        log.append("  D12 mid-drag: depth \(FlexibleLatticeHandles.depthText(p.latticeSlabDepthMM(r3, in: c))) · xray \(s.xrayOn)")
        frames(h, s, "D12"); shot(h, "D12_depth_handle_mid_drag")
        FlexibleFaceCommits.writeDepth(25.0, ref: r3, group: c, project: p, session: &sess)
        s.endHandleDrag(p) {}
        pump(1.2)

        s.askDelete(c); pump(1)
        frames(h, s, "D13"); shot(h, "D13_trash_asks")
        s.confirmDelete(project: p) {}; pump(1.2)
        frames(h, s, "D14"); shot(h, "D14_deleted_message_undo")
        s.undoDelete(project: p) {}; pump(1.5)
        log.append("  D15 after Undo: Group C \(p.selection.groups.contains { $0.id == c }) at \(FlexibleLatticeHandles.depthText(p.latticeSlabDepthMM(r3, in: c)))")
        frames(h, s, "D15"); shot(h, "D15_after_undo")
        s.faceUI.toast = nil

        s.tapFace(p, face: 3, point: nil, mesh: mesh); pump(1.2)
        press(h, "selHeader", what: "minimise Selections"); pump(1)
        frames(h, s, "D16"); shot(h, "D16_selections_minimised_chip_open")
        press(h, "selHeader", what: "open Selections"); pump(1)
        s.missTap(); pump(0.6)

        if !s.playOn { s.togglePlay() }
        _ = pumpUntil(90) { h.frames.all["playerCapsule"] != nil }
        pump(2)
        frames(h, s, "D17"); shot(h, "D17_play_on")
        press(h, "latticeMore", what: "the ⌃ with Play on"); pump(1.5)
        frames(h, s, "D18"); shot(h, "D18_play_on_card")
        s.chrome.foldAll(); s.togglePlay(); pump(1.2)

        press(h, "capsuleSquish", what: "the capsule's Squish")
        _ = pumpUntil(10) { h.frames.all["exitRow"] != nil }
        pump(3)
        log.append("  Squish page up \(h.frames.all["exitRow"] != nil)")
        shot(h, "D19_squish_page", last: true)
        log.append("touches: \(touches)")
    }

    func runReady(_ tagName: String, _ size: CGSize) throws {
        tag = tagName + "_ready"
        log = []
        touches = 0
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        click(h, CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2))
        pump(4)
        guard let s = FlexibleMainStage.lastMade, let m = s.model else { XCTFail("no stage"); return }
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        _ = settle(s)
        while m.squeezeGroups.count > 1, let last = m.squeezeGroups.last { m.removeGroup(last.id); pump(0.5) }
        pump(2)
        _ = settle(s)
        pump(3)
        setCam(h, Self.img1)
        log.append("status '\(s.status.line)' tone \(s.status.tone) · groups \(m.squeezeGroups.map(\.regions))")
        frames(h, s, "R20"); shot(h, "R20_main_ready")
        press(h, "latticeMore", what: "the ⌃ (look; never a send)"); pump(1.5)
        log.append("card on Ready · sent \(s.coreRun.runs) · job '\(FlexibleLatticeCard.jobSummary(model: m) ?? "none")'")
        frames(h, s, "R21"); shot(h, "R21_card_ready_what_goes_to_core")
        log.append("touches: \(touches)")
    }

    func test13p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D_EVIDENCE_DIR") }; try run("13p", CGSize(width: 1032, height: 1376)) }
    func test13l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D_EVIDENCE_DIR") }; try run("13l", CGSize(width: 1376, height: 1032)) }
    func test11p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D_EVIDENCE_DIR") }; try run("11p", CGSize(width: 834, height: 1194)) }
    func test11l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D_EVIDENCE_DIR") }; try run("11l", CGSize(width: 1194, height: 834)) }
    func testMiniP() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D_EVIDENCE_DIR") }; try run("minip", CGSize(width: 744, height: 1133)) }
    func test13pReady() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D_EVIDENCE_DIR") }; try runReady("13p", CGSize(width: 1032, height: 1376)) }
    func test11pReady() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D_EVIDENCE_DIR") }; try runReady("11p", CGSize(width: 834, height: 1194)) }
    func test11lReady() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D_EVIDENCE_DIR") }; try runReady("11l", CGSize(width: 1194, height: 834)) }
}
#endif

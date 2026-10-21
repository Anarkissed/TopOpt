// FlexibleR7U21CHandlesHostedTests — round 7 · U21 batch C, the hosted half: the WHOLE app page (WorkspacePlaceholder)
// offscreen at 13" portrait on HIS l-bracket ("l bracket large", DB254706, copied read-only from the simulator on 2026-10-21:
// round7/batch_u21_c/his_live_1021_lbracket), Group B · Face 6 at his Img6 numbers (Depth 9.0 mm, Expand −3.0 mm), the
// camera at the probe's worst view (az 1.57, el 0.25: the true expand knob LEFT of the depth floor, as in his 16.png, where
// a click on the depth disc opened the EXPAND keypad). Written before the code; the RED controls are asserted red inside.
// Pictures (13" portrait) only with FLEX_U21C_DIR=<dir>.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class U21CWin: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7U21CHandlesHostedTests: XCTestCase {
    static var liveDir: URL {
        FlexibleHisProject.repoRoot.appendingPathComponent(
            "docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_u21_c/his_live_1021_lbracket", isDirectory: true)
    }
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_U21C_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376)
    static let groupB = UUID(uuidString: "B91ED058-A180-4125-8E82-420B89D45B79")!
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    /// His l-bracket on the Flexible Lattice page, Face 6 picked at his Img6 numbers, the camera at the worst view.
    func hisLBracket() throws -> (FlexibleHisProject.Restored, Host, FlexibleMainStage, LatticeSelectableRef) {
        Bundle.r7m1vSwap
        let r = try FlexibleHisProject.restore(Self.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let p = r.project
        let ref = LatticeSelectableRef.face(group: Self.groupB, face: 6)
        XCTAssertEqual(p.latticeSelectableRole(ref, in: Self.groupB), .include, "premise: Face 6 is Group B's lattice face-prism")
        p.writeLatticeDepthMM(ref, mm: 9.0)     // his Img6 (13:06): Depth 9.0 mm, Expand −3.0 mm
        p.writeLatticeExpandMM(ref, mm: -3.0)
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: Self.p13)
        pump(4)
        if h.frames.all["capsule"] == nil {
            click(h, CGPoint(x: Self.p13.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2))
            pump(3)
        }
        let s = try XCTUnwrap(FlexibleMainStage.lastMade, "the page's stage")
        addTeardownBlock { @MainActor in await s.model?.waitForIdle() }
        XCTAssertNotNil(h.frames.all["capsule"], "premise: the Flexible stage")
        s.tapFace(p, face: 6, point: nil, mesh: try XCTUnwrap(p.viewerMesh))
        pump(1.2)
        let cm = try XCTUnwrap(cameraModel(h), "the page's camera")
        var c = cm.camera
        c.setOrientation(azimuth: 1.57, elevation: 0.25)
        cm.adopt(c)
        pump(2)
        return (r, h, s, ref)
    }

    func testOnHisLBracketTheTwoHandlesAreApartAndADepthTapOpensNothingElse() throws {
        let (_, h, s, ref) = try hisLBracket()
        let kD = "handle-depth-\(ref.key)", kE = "handle-expand-\(ref.key)"
        func frames() throws -> (dDisc: CGRect, eDisc: CGRect, dBox: CGRect, eBox: CGRect) {
            (try XCTUnwrap(h.frames.all["handleDisc-\(kD)"], "the depth disc"), try XCTUnwrap(h.frames.all["handleDisc-\(kE)"], "the expand disc"),
             try XCTUnwrap(h.frames.all["numberBox-\(kD)"], "the depth box"), try XCTUnwrap(h.frames.all["numberBox-\(kE)"], "the expand box"))
        }
        let f = try frames()
        // the box's 44 pt tap band: its published 32 pt look grown 6 pt top and bottom
        let uD = f.dDisc.union(f.dBox.insetBy(dx: 0, dy: -6)), uE = f.eDisc.union(f.eBox.insetBy(dx: 0, dy: -6))
        let g = FlexibleLatticeHandles.gap(uD, uE)
        log.append("worst view: depth disc \(f.dDisc) box \(f.dBox) · expand disc \(f.eDisc) box \(f.eBox) · units' gap \(g) pt")
        XCTAssertGreaterThanOrEqual(g, FlexibleLatticeHandles.unitGap - 0.5, "★ the two handles' units are ≥ 24 pt apart (\(g))")
        XCTAssertLessThan(f.eDisc.midX, f.dDisc.midX, "premise: the expand handle left of the depth floor (his Img6)")
        XCTAssertLessThan(f.eBox.midX, f.eDisc.midX, "★ the expand box on the side away from the depth handle (left)")
        XCTAssertGreaterThan(f.dBox.midX, f.dDisc.midX, "★ the depth box on the side away from the expand handle (right)")
        // a click on the depth disc opens nothing (a drag handle); each box opens its own keypad
        click(h, CGPoint(x: f.dDisc.midX, y: f.dDisc.midY))
        XCTAssertNil(s.faceUI.padTarget, "★ a tap on the depth disc opens no keypad (it opened Expand's)")
        click(h, CGPoint(x: f.dBox.midX, y: f.dBox.midY))
        XCTAssertEqual(s.faceUI.padTarget, kD, "positive control: the depth box opens the depth keypad")
        s.faceUI.padTarget = nil; pump(0.6)
        click(h, CGPoint(x: f.eBox.midX, y: f.eBox.midY))
        XCTAssertEqual(s.faceUI.padTarget, kE, "positive control: the expand box opens the expand keypad")
        s.faceUI.padTarget = nil; pump(0.6)
        // the icons beside the list's captions, each directly over its box
        for (kind, box) in [("depth", "numberBox-list-depth-\(ref.key)"), ("expand", "numberBox-list-expand-\(ref.key)")] {
            let icon = try XCTUnwrap(h.frames.all["selCaptionIcon-\(kind)"], "★ the \(kind) caption carries its handle's icon")
            let b = try XCTUnwrap(h.frames.all[box], "the list's \(kind) box")
            XCTAssertTrue(icon.midX > b.minX - 4 && icon.midX < b.maxX + 4, "★ the \(kind) icon over its box (\(icon) vs \(b))")
            XCTAssertLessThanOrEqual(icon.maxY, b.minY + 1, "★ the \(kind) icon above its box")
        }
        try shot("U21C_01_13p_lbracket_face6_img6_view_handles_apart.png", h, settle: 1)

        // ★ RED CONTROL: today's layout (72 pt floor, both boxes right, the expand drawn on top) — the depth disc's click opens Expand
        FlexibleLatticeHandles.controlOldLayout = true
        defer { FlexibleLatticeHandles.controlOldLayout = false }
        let cm = try XCTUnwrap(cameraModel(h))
        var c = cm.camera
        c.setOrientation(azimuth: 1.5701, elevation: 0.25)   // (a re-draw)
        cm.adopt(c)
        pump(2)
        let o = try frames()
        log.append("RED CONTROL today's layout: depth disc \(o.dDisc) · expand box \(o.eBox) · units' gap \(FlexibleLatticeHandles.gap(o.dDisc.union(o.dBox.insetBy(dx: 0, dy: -6)), o.eDisc.union(o.eBox.insetBy(dx: 0, dy: -6)))) pt")
        try shot("U21C_02_13p_lbracket_face6_img6_view_RED_todays_layout.png", h, settle: 1)
        click(h, CGPoint(x: o.dDisc.midX, y: o.dDisc.midY))
        log.append("RED CONTROL click on the depth disc → padTarget \(s.faceUI.padTarget ?? "nil")")
        XCTAssertEqual(s.faceUI.padTarget, kE, "★ RED CONTROL: today a tap on the depth disc opened the EXPAND keypad")
        s.faceUI.padTarget = nil
        flush("U21C_hosted_lines.txt")
    }

    /// ★ EXPAND-DRAG-DIR on his page (FIX ROUND 1, the checker's blocker: nothing pinned which point the page's drag reads).
    /// The "+" disc's OWN drag closure — the very one its DragGesture calls, as the page last built it
    /// (`FlexibleLatticeHandles.liveDrags`) — is driven 40 pt outward (along the true knob → 10 mm out, as projected) in 12
    /// steps with the page re-drawing between them, then released: the expand grows by what the TRUE knob predicts.
    /// (Synthetic mouse drags reach nothing in this offscreen window — neither SwiftUI's DragGesture nor the camera's pan —
    /// tried with NSEvent and CGEvent-built events; clicks do. So the closure is driven, not the mouse.)
    /// RED controls, both asserted: the wiring alone back on the DRAWN (pushed) disc (`controlDrawnDiscWiring`: the checker's
    /// mutation — the result leaves the true prediction), and today's code path (`controlOldDrag`: it shrank).
    func testOnHisLBracketDraggingThePlusOutwardGrowsTheExpand() throws {
        FlexibleLatticeHandles.recordLiveDrags = true
        defer { FlexibleLatticeHandles.recordLiveDrags = false; FlexibleLatticeHandles.liveDrags = [:] }
        let (r, h, s, ref) = try hisLBracket()
        let p = r.project
        let kE = "handle-expand-\(ref.key)"
        let seed = -3.0
        func dragOut(_ label: String) throws -> (mm: Double, truePred: Double, drawnPred: Double) {
            p.writeLatticeExpandMM(ref, mm: seed)
            let cm = try XCTUnwrap(cameraModel(h))
            var c = cm.camera
            c.setOrientation(azimuth: 1.57, elevation: 0.25)   // (a re-draw at the worst view)
            cm.adopt(c)
            pump(1.5)
            XCTAssertEqual(p.latticeExpandMM(ref), seed, accuracy: 1e-9, "premise: Expand back at his −3.0 mm")
            XCTAssertNil(s.faceUI.dragging, "premise: no drag in progress")
            let ax0 = try XCTUnwrap(FlexibleLatticeHandles.liveDrags[kE], "the expand disc's drag, as the page built it").axis
            let raw0 = try XCTUnwrap(ax0.raw, "the true knob"), out0 = try XCTUnwrap(ax0.out, "10 mm out")
            let v = CGVector(dx: out0.x - raw0.x, dy: out0.y - raw0.y)
            let len = hypot(v.dx, v.dy)
            XCTAssertGreaterThan(len, 1, "premise: the knob has a direction on screen")
            let T: CGFloat = 40
            let t = CGSize(width: v.dx / len * T, height: v.dy / len * T)
            var last = ax0
            for i in 1...12 {
                let f = CGFloat(i) / 12
                let live = try XCTUnwrap(FlexibleLatticeHandles.liveDrags[kE], "the drag closure at step \(i)")
                last = live.axis
                live.changed(CGSize(width: t.width * f, height: t.height * f))
                pump(0.08)
            }
            try XCTUnwrap(FlexibleLatticeHandles.liveDrags[kE]).ended()
            pump(0.5)
            XCTAssertNil(s.faceUI.dragging, "the drag ended (one undo step)")
            let mm = p.latticeExpandMM(ref)
            // the predictions from the axis the last step was built with (the knob moves out as the expand grows)
            let raw = try XCTUnwrap(last.raw), out = try XCTUnwrap(last.out)
            let truePred = FlexibleLatticeHandles.dragExpand(seed: seed, translation: t, knob: raw, outward: out)
            let drawnPred = FlexibleLatticeHandles.dragExpand(seed: seed, translation: t, knob: last.drawn, outward: out)
            log.append("\(label): at the start true knob \(raw0) · 10 mm out \(out0) (\(len) pt) · drawn disc \(ax0.drawn) · drag \(t); at the last step true knob \(raw) · out \(out) · drawn \(last.drawn) → Expand \(seed) → \(mm) mm (predicted: true knob \(truePred), drawn disc \(drawnPred))")
            return (mm, truePred, drawnPred)
        }
        let now = try dragOut("now")
        XCTAssertGreaterThan(now.mm, seed + 0.5, "★ a drag of the \"+\" outward grows the expand (\(now.mm))")
        XCTAssertEqual(now.mm, now.truePred, accuracy: 0.05, "★ by what the TRUE knob → out predicts")
        XCTAssertGreaterThan(abs(now.truePred - now.drawnPred), 1.0, "premise: this view tells the true knob from the drawn disc")

        // ★ RED CONTROL 1: the page's wiring alone back on the drawn (pushed) disc — the checker's mutation
        FlexibleLatticeHandles.controlDrawnDiscWiring = true
        let wired = try dragOut("RED CONTROL drawn-disc wiring")
        FlexibleLatticeHandles.controlDrawnDiscWiring = false
        XCTAssertGreaterThan(abs(wired.mm - wired.truePred), 1.0, "★ RED CONTROL: wired to the drawn disc it leaves the true prediction (\(wired.mm) vs \(wired.truePred))")

        // ★ RED CONTROL 2: today's code path (the drawn disc and today's formula) — the same outward drag shrank it
        FlexibleLatticeHandles.controlOldDrag = true
        let old = try dragOut("RED CONTROL today's drag")
        FlexibleLatticeHandles.controlOldDrag = false
        XCTAssertLessThan(old.mm, seed, "★ RED CONTROL: today the outward drag shrank the expand (\(old.mm))")
        flush("U21C_hosted_drag_lines.txt")
    }

    /// ★ RED CONTROL for the captions (a fresh page: the caption row is drawn once per page).
    func testRedControlTheCaptionsWereTextOnly() throws {
        FlexibleHandleCaption.controlTextOnly = true
        defer { FlexibleHandleCaption.controlTextOnly = false }
        let (_, h, _, ref) = try hisLBracket()
        XCTAssertNotNil(h.frames.all["numberBox-list-depth-\(ref.key)"], "premise: Face 6's line in the list")
        XCTAssertNil(h.frames.all["selCaptionIcon-depth"], "★ RED CONTROL: text-only captions carry no icon")
        XCTAssertNil(h.frames.all["selCaptionIcon-expand"], "★ RED CONTROL: text-only captions carry no icon")
    }

    // MARK: the harness (FlexibleU1Tests')

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = U21CWin(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func event(_ h: Host, _ t: NSEvent.EventType, _ p: CGPoint) {
        let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.window.sendEvent(e)
    }
    func click(_ h: Host, _ p: CGPoint) {
        event(h, .leftMouseDown, p); pump(0.06)
        event(h, .leftMouseUp, p); pump(0.8)
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
        print("FLEX-U21C " + log.joined(separator: "\n  "))
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

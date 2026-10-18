// FlexibleRound7SelectionsEvidenceProbe — round 7, batch R7-D2 (Selections, his pick 2): the LOOK (opt-in:
// FLEX_R7D2_EVIDENCE_DIR=<dir>). The WHOLE app page hosted (WorkspacePlaceholder) on HIS pad (A1_0003 + his live lattice:
// Group C = Face 3 + Face 5 at 25 mm; Bottom anchors; Top 22 lb), the part drawn by the page's own MeshRenderer offscreen under
// the hosted chrome (the shipping renderer, as every round-7 probe draws it), at 13" and 11", portrait and landscape:
//   E01 at rest · E02 Face 3 tapped: chip M, the depth / expand handles, the list with Group C open · E03 Face 4 tapped: chip N,
//   the FILLED "Add to Group C as lattice", the held [Lattice] · E04 joined: Face 4 in Group C, the chip stays · E05 the (i)'s
//   four numbers · E06 the trash's confirm · E07 deleted: the message with [Undo] · E08 [Undo]: Group C back · E09 a moved chip
//   and its leader · E10 X-ray, nothing picked: every face-prism faint · E11 the depth handle mid-drag (X-ray on) · E12 img2's
//   FRONT camera with the Top picked: no 12.0 mm.
// Each step logs where the chip landed and whether it touches a keep-out (the list, the capsule, the corner pair, the cube and
// views row, the legend).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7D2EvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7SelectionsEvidenceProbe: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    typealias Cam = FlexibleRound6Tests.Cam
    static let img1 = Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
    static let img2 = Cam(name: "img2 (front)", azimuth: 0, elevation: 0.16, zoom: 1)

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7D2_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var tag = ""
    var log: [String] = [] { didSet { if let l = log.last, log.count > oldValue.count { FileHandle.standardError.write(("R7D2-LOOK " + l + "\n").data(using: .utf8)!); writeLog() } } }
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
        let w = R7D2EvidenceWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        let url = dir.appendingPathComponent("D2_\(tag)_\(name).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
        log.append("wrote D2_\(tag)_\(name).png")
    }
    func writeLog() {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("D2_\(tag)_log.txt"), atomically: true, encoding: .utf8)
    }

    /// Where the chip is, and whether it touches what it must not.
    func layout(_ h: Host, _ s: FlexibleMainStage, _ step: String) {
        let v = h.size
        guard let chip = h.frames.all["faceChip"] else { log.append("  \(step): no chip"); return }
        var bad: [String] = []
        let fixed: [(String, CGRect)] = [("cube", FlexibleLegendPlacement.gizmoFrame(viewport: v)), ("views", FlexibleChromeLayout.viewsRow(viewport: v))]
        for (n, k) in fixed where chip.intersects(k) { bad.append("\(n) \(Self.f(k))") }
        for key in ["selectionsList", "capsule", "setupChip", "latticeSplit", "playerCapsule"] {
            if let k = h.frames.all[key], k.intersects(chip) { bad.append("\(key) \(Self.f(k))") }
        }
        if let l = s.legendCard(viewport: v, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)?.frame, l.intersects(chip) {
            bad.append("legend \(Self.f(l))")
        }
        touches += bad.count
        let boxes = h.frames.all.filter { $0.key.hasPrefix("numberBox-handle-") }.map { "\($0.key.dropFirst(10)) \(Self.f($0.value))" }.sorted()
        log.append("  \(step): chip \(Self.f(chip)) · handles \(boxes.isEmpty ? "none" : boxes.joined(separator: ", ")) · \(bad.isEmpty ? "nothing touches" : "TOUCHES: " + bad.joined(separator: "; "))")
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
        s.faceUI.toastSeconds = 120   // (a debug build's offscreen frame takes seconds; the message's 8 s dwell would end under it)
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        let settled = pumpUntil(420) { m.sceneState == .ready && !m.latticeBuilding && !m.readiness.designing && !m.designsInFlight && (m.lattice != nil || m.latticeFailure != nil) }
        pump(3)
        setCam(h, Self.img1)
        let mesh = try XCTUnwrap(p.viewerMesh)
        log.append("[\(tag)] settled \(settled) · status '\(s.status.line)' · list \(h.frames.all["selectionsList"].map(Self.f) ?? "none")")
        shot(h, "E01_rest")
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        pump(1.5)
        layout(h, s, "E02")
        shot(h, "E02_face3_chipM_handles_list")
        s.tapFace(p, face: 2, point: nil, mesh: mesh)   // Face 2: the free side his img1 camera sees
        pump(1.5)
        layout(h, s, "E03")
        log.append("  join \(h.frames.all["chipJoin"].map(Self.f) ?? "none") · held line: \(FlexibleSelectionsCopy.latticeHeld)")
        shot(h, "E03_face2_chipN_join")
        press(h, "chipJoin", what: "Add to Group C as lattice")
        pump(1.5)
        let r4 = LatticeSelectableRef.face(group: c, face: 2)
        log.append("  joined: Face 2 role \(String(describing: p.latticeSelectableRole(r4, in: c))) depth \(p.latticeSlabDepthMM(r4, in: c)) · pick \(s.facePick.scope)")
        layout(h, s, "E04")
        shot(h, "E04_joined_chip_stays")
        press(h, "info-l-" + LatticeSelectableRef.face(group: c, face: 3).key, what: "Face 3's (i) in the list")
        pump(1)
        log.append("  (i) card \(h.frames.all["statsCard"].map(Self.f) ?? "none")")
        shot(h, "E05_info_four_numbers")
        s.faceUI.info = nil
        press(h, "selTrash-\(c.uuidString)", what: "Group C's trash")
        shot(h, "E06_trash_confirm")
        press(h, "deleteConfirm", what: "[Delete]")
        pump(1)
        log.append("  deleted: Group C present \(p.selection.groups.contains { $0.id == c }) · message \(String(describing: s.faceUI.toast?.text)) · undo frame \(h.frames.all["toastUndo"].map(Self.f) ?? "none")")
        shot(h, "E07_deleted_undo_message")
        press(h, "toastUndo", what: "[Undo]")
        pump(2)
        log.append("  undone: Group C present \(p.selection.groups.contains { $0.id == c }) · Face 3 \(p.latticeSlabDepthMM(.face(group: c, face: 3), in: c)) mm")
        shot(h, "E08_undone_group_back")
        // a moved chip (what the drag writes) and its leader
        s.tapFace(p, face: 4, point: nil, mesh: mesh)
        pump(1.2)
        if let chip = h.frames.all["faceChip"], let key = s.facePick.scope.chipKey {
            let to = FlexibleFaceChipLayout.dragged(anchor: chip.origin, translation: CGSize(width: size.width * 0.08, height: size.height * 0.22),
                                                    size: chip.size, viewport: size)
            // (let go: the nearest clear spot, as the drag's end does — the page's keep-outs as the layer reads them)
            let keep = FlexibleFaceChipLayout.keepOuts(viewport: size, selections: FlexibleFaceChipLayout.selectionsColumn(viewport: size),
                                                       legend: s.legendCard(viewport: size, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)?.frame,
                                                       panel: nil, player: nil)
            s.faceUI.spots[key] = FlexibleFaceChipLayout.released(to, viewport: size, keepOut: keep).origin
            pump(1)
            layout(h, s, "E09")
            shot(h, "E09_moved_chip_leader")
        }
        s.missTap()
        s.xrayOn = true
        pump(1.5)
        log.append("  X-ray, nothing picked: prisms \(s.volumes(p, on: .lattice, drilledIn: false).map { "\($0.volume.faceID)\($0.selected ? "*" : "")" })")
        shot(h, "E10_xray_every_prism_faint")
        s.xrayOn = false
        pump(1)
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        pump(1.2)
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        s.beginHandleDrag(p, key: "handle-depth-\(r3.key)")
        var sess = s.facePick
        FlexibleFaceCommits.writeDepth(18, ref: r3, group: c, project: p, session: &sess)
        pump(1.5)
        layout(h, s, "E11")
        shot(h, "E11_depth_handle_mid_drag_xray")
        s.endHandleDrag(p) {}
        pump(1)
        setCam(h, Self.img2)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        s.pickGroup(top.id, project: p)
        pump(1.5)
        log.append("  img2 front, the Top picked: prisms \(s.volumes(p, on: .lattice, drilledIn: false).count) · handles \(s.pickedPlanes(p).count)")
        layout(h, s, "E12")
        shot(h, "E12_img2_front_top_picked_no_12mm")
        log.append("touches: \(touches)")
    }

    func test13p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D2_EVIDENCE_DIR") }; try run("13p", CGSize(width: 1032, height: 1376)) }
    func test13l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D2_EVIDENCE_DIR") }; try run("13l", CGSize(width: 1376, height: 1032)) }
    func test11p() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D2_EVIDENCE_DIR") }; try run("11p", CGSize(width: 834, height: 1194)) }
    func test11l() throws { guard Self.dir != nil else { throw XCTSkip("FLEX_R7D2_EVIDENCE_DIR") }; try run("11l", CGSize(width: 1194, height: 834)) }
}
#endif

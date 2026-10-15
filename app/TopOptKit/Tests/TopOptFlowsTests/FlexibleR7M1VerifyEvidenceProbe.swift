// FlexibleR7M1VerifyEvidenceProbe — round 7 batch M1's VERIFY fixes, pictured on HIS pad (A1_0003). Opt-in:
//     FLEX_R7M1V_EVIDENCE_DIR=<dir> swift test --filter FlexibleR7M1VerifyEvidenceProbe
// ★ THE WHOLE MAIN PAGE, HOSTED: WorkspacePlaceholder itself (#354's Selections card and depth knobs, the bottom-right chip
// column, the bottom bar, the Flexible chrome), the part drawn by the page's OWN MeshRenderer under it (the verify's harness,
// adopted). Offscreen frames, not device screenshots. State read back for the log beside the pictures.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import Combine
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

import ObjectiveC

extension Bundle {
    @objc func r7m1vPath(forResource name: String?, ofType ext: String?) -> String? {
        let root = FlexibleHisProject.repoRoot
        if name == "flexible_materials", ext == "json" { return root.appendingPathComponent("core/src/materials/flexible_materials.json").path }
        if name == "stamps", ext == "json" { return root.appendingPathComponent("docs/design/flexibles/data/stamps.json").path }
        return r7m1vPath(forResource: name, ofType: ext)
    }
    static let r7m1vSwap: Void = {
        if let o = class_getInstanceMethod(Bundle.self, #selector(Bundle.path(forResource:ofType:))),
           let n = class_getInstanceMethod(Bundle.self, #selector(Bundle.r7m1vPath(forResource:ofType:))) {
            method_exchangeImplementations(o, n)
        }
    }()
}

private final class R7M1VProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7M1VerifyEvidenceProbe: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    struct AX { let id: String; let label: String; let role: String; let frame: CGRect; let obj: AnyObject }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7M1V_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var log: [String] = [] { didSet { if let l = log.last, log.count > oldValue.count { FileHandle.standardError.write(("R7M1V " + l + "\n").data(using: .utf8)!); writeLog() } } }
    var logName = "log.txt"

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
        let w = R7M1VProbeWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func mouse(_ h: Host, _ p: CGPoint, _ t: NSEvent.EventType) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.window.sendEvent(e)
    }
    func click(_ h: Host, _ p: CGPoint, hold: Double = 0.06) {
        mouse(h, p, .leftMouseDown); pump(hold); mouse(h, p, .leftMouseUp); pump(0.4)
    }

    func axAll(_ h: Host) -> [AX] {
        var out: [AX] = []
        let wf = h.window.frame
        func walk(_ o: Any, _ d: Int) {
            guard d < 70, let e = o as? NSAccessibilityProtocol else { return }
            let f = e.accessibilityFrame()
            let lf = CGRect(x: f.minX - wf.minX, y: wf.maxY - f.maxY, width: f.width, height: f.height)
            let id: String = e.accessibilityIdentifier() ?? ""
            let ob = o as? NSObject
            func attr(_ a: NSAccessibility.Attribute) -> String? {
                let v = ob?.accessibilityAttributeValue(a) as? String
                return (v?.isEmpty ?? true) ? nil : v
            }
            let label = attr(.description) ?? attr(.title) ?? attr(.value) ?? ""
            let role = (ob?.accessibilityAttributeValue(.role) as? String) ?? ""
            if !(o is NSView) || !id.isEmpty { out.append(AX(id: id, label: label, role: role, frame: lf, obj: o as AnyObject)) }
            for c in (ob?.accessibilityAttributeValue(.children) as? [Any]) ?? [] { walk(c, d + 1) }
        }
        walk(h.view, 0)
        return out
    }
    @discardableResult
    func press(_ h: Host, id: String? = nil, where pred: ((AX) -> Bool)? = nil, what: String) -> Bool {
        let all = axAll(h)
        guard let a = all.first(where: { (id == nil || $0.id == id) && (pred?($0) ?? true) }) else {
            log.append("  (no AX element for \(what))"); return false
        }
        log.append("  tap \(what): [\(a.label)] id '\(a.id)' \(Self.f(a.frame))")
        if a.frame.width > 1 { click(h, CGPoint(x: a.frame.midX, y: a.frame.midY)); pump(0.8); return true }
        if let e = a.obj as? NSAccessibilityProtocol, e.accessibilityPerformPress() { pump(0.8); return true }
        return false
    }
    static func f(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }

    /// Every labelled element, in reading order (top to bottom, left to right), to a side file.
    func dumpAX(_ h: Host, _ name: String) {
        let all = axAll(h).filter { !$0.label.isEmpty || !$0.id.isEmpty }
            .filter { $0.frame.width > 0 && $0.frame.minX > -5 && $0.frame.minY > -5 && $0.frame.maxX < h.size.width + 5 && $0.frame.maxY < h.size.height + 5 }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        let lines = all.map { "\(Self.f($0.frame)) \($0.role) id='\($0.id)' '\($0.label)'" }
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(name + "_ax.txt"), atomically: true, encoding: .utf8)
        // buttons overlapped by other buttons (nothing covering a button)
        let btns = all.filter { ($0.role.contains("Button") || $0.role.contains("Radio") || $0.role.contains("PopUp")) && $0.frame.width > 4 && $0.frame.height > 4 }
        var over: [String] = []
        for (i, a) in btns.enumerated() { for b in btns[(i + 1)...] where a.frame.intersects(b.frame.insetBy(dx: 2, dy: 2)) && !a.frame.contains(b.frame) && !b.frame.contains(a.frame) {
            over.append("[\(a.label.isEmpty ? a.id : a.label)] \(Self.f(a.frame)) × [\(b.label.isEmpty ? b.id : b.label)] \(Self.f(b.frame))")
        } }
        log.append("  \(name): \(all.count) AX elements; overlapping buttons: \(over.isEmpty ? "none" : over.joined(separator: " | "))")
    }

    func renderer(_ v: NSView) -> MeshRenderer? {
        var best: (MeshRenderer, CGFloat)?
        func walk(_ v: NSView) {
            if let m = v as? MTKView, let r = m.delegate as? MeshRenderer {
                let a = m.bounds.width * m.bounds.height
                if best == nil || a > best!.1 { best = (r, a) }
            }
            for s in v.subviews { walk(s) }
        }
        walk(v)
        return best?.0
    }

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
        if let mr = renderer(h.view), var rgba = mr.renderOffscreen(size: n, clear: MTLClearColor(red: bgc.r, green: bgc.g, blue: bgc.b, alpha: 1)) {
            for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
            let x0 = (n - W) / 2, y0 = (n - H) / 2
            for y in 0..<H { for x in 0..<W {
                let s = 4 * ((y + y0) * n + x + x0), d = 4 * (y * W + x)
                out[d] = rgba[s]; out[d + 1] = rgba[s + 1]; out[d + 2] = rgba[s + 2]; out[d + 3] = 255
            } }
        } else { log.append("  (\(name): no renderer image — chrome only)") }
        for i in stride(from: 0, to: pg.count, by: 4) {
            let isBg = abs(Int(pg[i]) - Int(bg.0)) <= 3 && abs(Int(pg[i + 1]) - Int(bg.1)) <= 3 && abs(Int(pg[i + 2]) - Int(bg.2)) <= 3
            let clear = pg[i + 3] == 0
            if (!isBg && !clear) || out[i + 3] == 0 { out[i] = pg[i]; out[i + 1] = pg[i + 1]; out[i + 2] = pg[i + 2]; out[i + 3] = 255 }
        }
        guard let octx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let img = octx.makeImage() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
    }

    func writeLog() {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(logName), atomically: true, encoding: .utf8)
    }

    // MARK: - the whole main page on his pad

    func state(_ s: FlexibleMainStage?, _ p: ProjectModel, _ name: String) -> String {
        guard let s, let m = s.model else { return "\(name): (no model)" }
        let items = s.volumes(p, on: .lattice, drilledIn: false)
        let depths = items.map { i -> String in
            guard case .shell(let sh) = i.volume.shape else { return "Face \(i.volume.faceID) (?)" }
            return "Face \(i.volume.faceID) \(String(format: "%.1f mm", sh.reachedDepthMM))\(i.selected ? " bright" : "")"
        }
        let legend = s.legendKinds.map { k in k == .dent ? "\(s.legendTitle(.dent)) 0…\(String(format: "%.1f", s.dentMaxMM)) mm" : "\(k)" }
        return "\(name): scene \(m.sceneState) · facePrismsSet \(m.facePrismsSet) · lattice \(m.lattice != nil) building \(m.latticeBuilding) stale \(m.latticeIsStale) · prisms [\(depths.joined(separator: ", "))] · xray \(s.xrayOn) · views \(m.views.rawValue) available \(s.viewsAvailable) · pill '\(s.status.line)' tone \(s.status.tone) disabled \(FlexibleMainStatusPill.disabled(s.status, visible: s.visible)) · legend \(legend) row \(s.legendPrismsRow) · designs \(m.designs.count) · Squish line '\(m.readiness.oneLine)'"
    }

    static let pill13p = CGPoint(x: 647, y: 1325)
    static let settings13p = CGPoint(x: 735, y: 47)
    func mainIcon(_ size: CGSize, _ i: Int) -> CGPoint {
        let row = FlexibleMainViewToggles.rowFrame(viewport: size)
        let c = FlexibleMainViewToggles.columns(viewport: size)
        let col = i % c, line = i / c
        return CGPoint(x: row.minX + CGFloat(col) * (40 + DS.Space.s) + 20, y: row.minY + CGFloat(line) * (40 + DS.Space.s) + 20)
    }

    func openWhole(_ r: FlexibleHisProject.Restored, size: CGSize, tag: String) -> (Host, FlexibleMainStage?) {
        Bundle.r7m1vSwap
        let p = r.project
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        let s = FlexibleMainStage.lastMade
        log.append("[\(tag)] open: groups " + p.selection.groups.map { "\($0.name)=\(p.force.kind(for: $0.id))" }.joined(separator: ", ")
                   + " · finish \(String(describing: p.lattice.flexible?.finish)) · stage \(s != nil)")
        let toLattice = CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2)
        click(h, toLattice); pump(4)
        if h.frames.all["exitRow"] != nil || h.frames.all["panel"] != nil {
            log.append("[\(tag)] the Squish page opened by itself on arrival")
            let e = h.frames.all["exitRow"].map { CGPoint(x: $0.minX + 40, y: $0.midY) } ?? CGPoint(x: 62, y: 45)
            click(h, e); pump(3)
        }
        return (h, s)
    }

    func settleLattice(_ s: FlexibleMainStage?, _ t: Double = 420) -> Bool {
        guard let s else { return false }
        let ok1 = pumpUntil(t) { if let m = s.model { return m.sceneState == .ready && m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale } ; return false }
        let ok2 = pumpUntil(t) { if let m = s.model { return !m.squish.isEmpty && !m.squish.values.contains(.pending) } ; return false }
        pump(4)
        return ok1 && ok2
    }

    /// A: his pad AS SAVED (no face-prism) — the plain model, the pill disabled with its reason, the views unavailable; the
    /// pill's tap (nothing opens); the Squish page (its top line, no pop-up, no dent scale).
    func testA_AsSaved() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7M1V_EVIDENCE_DIR") }
        for (tag, size) in [("13p", CGSize(width: 1032, height: 1376)), ("11l", CGSize(width: 1194, height: 834))] {
            logName = "A_as_saved_log.txt"
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let p = r.project
            let (h, s) = openWhole(r, size: size, tag: "A\(tag)")
            _ = pumpUntil(90) { s?.model?.sceneState == .ready }
            pump(20)
            log.append(state(s, p, "A\(tag) 01 main, as saved"))
            shot(h, "R7M1V_A\(tag)_01_no_face_prism_main")
            guard tag == "13p" else { continue }
            click(h, Self.pill13p); pump(3)
            log.append(state(s, p, "A13p 02 after a tap on the pill") + " · Squish page up \(h.frames.all["exitRow"] != nil) · pendingFix \(String(describing: s?.model?.pendingFix?.kind))")
            shot(h, "R7M1V_A13p_02_after_pill_tap")
            click(h, Self.settings13p); pump(4)
            log.append(state(s, p, "A13p 03 the Squish page") + " · pop-up \(h.frames.all["popup"] != nil) · legend card \(h.frames.all["legend"] != nil) · shown max \(s?.model.map { FlexibleShownValues(model: $0).maxDepth } ?? -1)")
            shot(h, "R7M1V_A13p_03_squish_page_no_face_prism")
        }
    }

    /// B: his LIVE lattice — [Prisms] with nothing picked (every group's face-prisms), the Top picked + [Prisms], a depth typed
    /// in the list (the legend while it rebuilds), after the rebuild.
    func testB_Live13p() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7M1V_EVIDENCE_DIR") }
        logName = "B_live_13p_log.txt"
        let size = CGSize(width: 1032, height: 1376)
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let cID = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let (h, s) = openWhole(r, size: size, tag: "B13p")
        let settled = settleLattice(s)
        log.append(state(s, p, "B13p 01 live lattice, nothing picked (settled \(settled))"))
        shot(h, "R7M1V_B13p_01_live_nothing_picked")
        click(h, mainIcon(size, 3)); pump(2)
        log.append(state(s, p, "B13p 02 [Prisms] on, nothing picked"))
        shot(h, "R7M1V_B13p_02_prisms_nothing_picked")
        if let top = p.selection.groups.first(where: { $0.name == "Top" }) {
            p.selection.setActive(top.id); pump(2)
            log.append(state(s, p, "B13p 03 [Prisms] on, the Top picked"))
            shot(h, "R7M1V_B13p_03_prisms_top_picked")
            click(h, mainIcon(size, 3)); pump(2)
            log.append(state(s, p, "B13p 04 [Prisms] off, the Top picked"))
            shot(h, "R7M1V_B13p_04_top_picked_no_prisms")
        }
        p.selection.setActive(cID); pump(1.5)
        log.append(state(s, p, "B13p 05 Group C picked"))
        shot(h, "R7M1V_B13p_05_groupC_picked")
        p.writeLatticeDepthMM(.face(group: cID, face: 3), mm: 17.26)
        _ = pumpUntil(60) { (s?.model?.latticeIsStale ?? false) || (s?.model?.latticeBuilding ?? false) }
        pump(1)
        log.append(state(s, p, "B13p 06 Face 3 typed 17.26 in the list, while it rebuilds"))
        shot(h, "R7M1V_B13p_06_face3_17mm_rebuilding")
        _ = settleLattice(s, 300)
        log.append(state(s, p, "B13p 07 after the rebuild"))
        shot(h, "R7M1V_B13p_07_face3_17mm_rebuilt")
    }

    /// C: the Export step with an edges group beside face groups (his groups + an edges group; his img4 state): the squeeze
    /// groups named by number.
    func testC_ExportEdges13p() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7M1V_EVIDENCE_DIR") }
        logName = "C_export_13p_log.txt"
        let size = CGSize(width: 1032, height: 1376)
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let (h, s) = openWhole(r, size: size, tag: "C13p")
        _ = settleLattice(s)
        guard let s, let m = s.model else { XCTFail("no model"); return }
        s.coreRun.runner = { _, _, _, _ in FlexRunInfo(refusal: nil, receiptJSON: "{\"faces\":[{}],\"topology\":\"gyroid\"}", files: []) }   // never core for real
        let mesh = try XCTUnwrap(p.viewerMesh)
        let px = FlexibleSquishFixture.face(mesh, axis: 0, value: 100), py = FlexibleSquishFixture.face(mesh, axis: 1, value: 100)
        let next = (m.squeezeGroups.map(\.number).max() ?? 1) + 1
        _ = m.addPress(regions: [px, py], direction: simd_normalize(SIMD3(1, 1, 0)), snap: nil, group: next, kg: 5)
        if let g1 = m.squeezeGroups.first { m.setGroupName(g1.id, "Thumbs") }   // his Squish-page name: never on the Export step
        _ = pumpUntil(120) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        pump(6); s.refresh(); pump(1)
        click(h, Self.pill13p); pump(3)
        log.append("C01 Export step (his groups + an edges group): line '\(s.coreRun.line)' · note '\(s.coreRun.hold?.note ?? "-")' · buttons \(s.coreRun.hold?.fixes.map(\.title) ?? []) · why '\(s.coreRun.hold?.why ?? "-")' · runs \(s.coreRun.runs)")
        shot(h, "R7M1V_C13p_01_export_edges_beside_his_groups")
        s.coreRun.close(); pump(1.5)
        m.resetAll(); pump(2)
        let top = FlexibleHisProject.topFace(mesh)
        _ = m.press(top, kg: 10)
        let nx = FlexibleSquishFixture.face(mesh, axis: 0, value: 0)
        _ = m.addPress(regions: [px, py], direction: simd_normalize(SIMD3(1, 1, 0)), snap: nil, group: 2, kg: 1)
        _ = m.addPress(regions: [nx, py], direction: simd_normalize(SIMD3(-1, 1, 0)), snap: nil, group: 2, kg: 1)
        if let g1 = m.squeezeGroups.first { m.setGroupName(g1.id, "Thumbs") }
        _ = pumpUntil(120) { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        pump(8); s.refresh(); pump(1)
        click(h, Self.pill13p); pump(3)
        log.append("C02 Export step (img4: Group 1 = the Top, Group 2 = two edges): line '\(s.coreRun.line)' · note '\(s.coreRun.hold?.note ?? "-")' · buttons \(s.coreRun.hold?.fixes.map(\.title) ?? []) · runs \(s.coreRun.runs)")
        shot(h, "R7M1V_C13p_02_export_img4")
    }
}
#endif

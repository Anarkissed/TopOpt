// FlexibleGroupSyncWorkspaceEvidence — round 6 ITEM 4 VERIFICATION's evidence, opt-in (FLEX_I4V_EVIDENCE_DIR=<dir>): the
// REAL WorkspacePlaceholder hosted at his 13" portrait (1032 × 1376), driven by clicks to the Flexible (lattice) stage as
// he goes there — #354's REAL groupRow on screen (H16's tint, H17's caption, the 360 pt Selections list), the REAL
// MeshRenderer MetalMeshView configured (its tint buffer read back), then the real Settings page from the real Settings
// button. The method is the item-4 verifier's (its private probe, adopted here so the pictures can be re-made): the
// SwiftUI layer (cacheDisplay) and the renderer's own offscreen frame of the same state, composited by
// round6/item4_verify/comp.py. Writes <tag>_<step>_{ui,metal}.png, *_ocr.txt and log_<tag>.txt. Skipped otherwise.
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import ObjectiveC
import MetalKit
import simd
import Vision
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

// ★ THE APP BUNDLE'S TWO RESOURCES. In xctest, Bundle.main is the runner: FlexibleResources.materialsPath / stampsPath
// (Bundle.main.path(forResource:)) are nil, so the workspace's own Flexible model has no catalogue (no stacks, no
// prisms, no lattice). On the iPad the app bundle carries them; here the repo's copies stand in.
nonisolated(unsafe) var flexI4VPaths: [String: String] = [:]
nonisolated(unsafe) var flexI4VSwizzled = false
extension Bundle {
    @objc func flexI4V_path(forResource name: String?, ofType ext: String?) -> String? {
        if let name, let ext, let p = flexI4VPaths["\(name).\(ext)"] { return p }
        return self.flexI4V_path(forResource: name, ofType: ext)
    }
}
func flexI4VSwizzle(materials: String, stamps: String) {
    flexI4VPaths = ["flexible_materials.json": materials, "stamps.json": stamps]
    guard !flexI4VSwizzled else { return }
    flexI4VSwizzled = true
    let a = class_getInstanceMethod(Bundle.self, #selector(Bundle.path(forResource:ofType:)))!
    let b = class_getInstanceMethod(Bundle.self, #selector(Bundle.flexI4V_path(forResource:ofType:)))!
    method_exchangeImplementations(a, b)
}

private final class FlexI4VWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleGroupSyncWorkspaceEvidence: XCTestCase {
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLEX_I4V_EVIDENCE_DIR"] ?? "/tmp/flex-i4v-evidence", isDirectory: true)
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["FLEX_I4V_EVIDENCE_DIR"] != nil else { throw XCTSkip("FLEX_I4V_EVIDENCE_DIR") }
    }
    static let size = CGSize(width: 1032, height: 1376)
    var lines: [String] = []
    var tag = ""
    func say(_ s: String) { lines.append(s); print("FLEX-I4V-EV " + s) }
    func flush() {
        try? FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: Self.out.appendingPathComponent("log_\(tag).txt"), atomically: true, encoding: .utf8)
    }

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    struct Host { let w: NSWindow; let v: NSView }
    func host<V: View>(_ v: V) -> Host {
        let root = AnyView(v.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: Self.size)
        _ = NSApplication.shared
        let w = FlexI4VWindow(contentRect: CGRect(x: -20000, y: -20000, width: Self.size.width, height: Self.size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        return Host(w: w, v: hv)
    }

    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: Self.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.w.sendEvent(e)
            pump(0.08)
        }
    }

    // MARK: accessibility (to find what he would tap)

    struct AXI { let id: String; let text: String; let role: String; let frame: CGRect }
    func attr(_ o: NSObject, _ n: String) -> Any? { o.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: n)) }
    func ax(_ h: Host) -> [AXI] {
        var out: [AXI] = []
        var budget = 40000
        func walk(_ e: Any, _ d: Int) {
            guard d < 80, budget > 0, let o = e as? NSObject else { return }
            budget -= 1
            let id = (attr(o, "AXIdentifier") as? String) ?? ""
            let texts = ["AXTitle", "AXDescription", "AXValue", "AXLabel"].compactMap { k -> String? in
                guard let v = attr(o, k) else { return nil }
                let s = "\(v)"
                return s.isEmpty ? nil : s
            }
            let role = (attr(o, "AXRole") as? String) ?? ""
            var f = CGRect.zero
            if let el = o as? NSAccessibilityElementProtocol {
                let wr = h.w.convertFromScreen(el.accessibilityFrame())
                f = CGRect(x: wr.minX, y: Self.size.height - wr.maxY, width: wr.width, height: wr.height)
            }
            out.append(AXI(id: id, text: texts.joined(separator: " | "), role: role, frame: f))
            if let kids = attr(o, "AXChildren") as? [Any] { for k in kids { walk(k, d + 1) } }
        }
        walk(h.v, 0)
        return out
    }
    func dumpAX(_ h: Host, _ name: String) -> [AXI] {
        let items = ax(h)
        let txt = items.filter { !$0.text.isEmpty || !$0.id.isEmpty }
            .map { "\($0.role) [\($0.id)] \($0.text) @ \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
        try? txt.joined(separator: "\n").write(to: Self.out.appendingPathComponent("\(tag)_\(name)_ax.txt"), atomically: true, encoding: .utf8)
        return items
    }
    func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    // MARK: the renderer MetalMeshView configured

    func mtkViews(_ v: NSView) -> [MTKView] {
        var out: [MTKView] = []
        if let m = v as? MTKView { out.append(m) }
        for s in v.subviews { out += mtkViews(s) }
        return out
    }
    func renderer(_ h: Host) -> MeshRenderer? {
        mtkViews(h.v).filter { !$0.isHidden && $0.window != nil }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            .flatMap { $0.delegate as? MeshRenderer }
    }
    func field<T>(_ o: Any, _ name: String) -> T? {
        var m: Mirror? = Mirror(reflecting: o)
        while let mm = m {
            for c in mm.children where c.label == name { return c.value as? T }
            m = mm.superclassMirror
        }
        return nil
    }
    /// What the renderer DRAWS: #354's face tints it holds (roleTints via H4's faceTints), whether Flexible's per-vertex
    /// override is in force, and how many drawn vertices carry one of those role colours exactly.
    func tintReport(_ r: MeshRenderer) -> String {
        let n: Int = field(r, "vertexDrawCount") ?? -1
        let override: [Float]? = field(r, "vertexTintOverride")
        let lastFace: [FaceID: SIMD4<Float>] = field(r, "lastFaceTint") ?? [:]
        let buf: MTLBuffer? = field(r, "tintBuffer")
        let roles = Set(lastFace.values.map { SIMD3<Float>($0.x, $0.y, $0.z) })
        var tinted = 0, roleInk = 0
        if let b = buf {
            let cnt = b.length / 4 / 8
            let p = b.contents().bindMemory(to: Float.self, capacity: b.length / 4)
            for v in 0..<cnt where p[v * 8 + 3] > 0 {
                tinted += 1
                if roles.contains(SIMD3(p[v * 8], p[v * 8 + 1], p[v * 8 + 2])) { roleInk += 1 }
            }
        }
        let faceCount: Int = field(r, "clearanceFaceCount") ?? -1
        let faint: Int = field(r, "clearanceFaintCount") ?? -1
        let glass: Int = field(r, "clearanceGlassCount") ?? -1
        let line: Int = field(r, "clearanceLineCount") ?? -1
        let body: Float = field(r, "bodyAlpha") ?? -1
        let roleList = lastFace.keys.sorted().map { f -> String in
            let c = lastFace[f]!
            return "f\(f)=" + String(format: "#%02X%02X%02X", Int(c.x * 255), Int(c.y * 255), Int(c.z * 255))
        }.joined(separator: ",")
        var perFace = ""
        if let b = buf, n > 0, n <= 600 {
            let ids: [UInt32] = field(r, "flatFaceIDs") ?? []
            let p = b.contents().bindMemory(to: Float.self, capacity: b.length / 4)
            var seen: [UInt32: String] = [:]
            for v in 0..<min(n, ids.count) where seen[ids[v]] == nil {
                seen[ids[v]] = String(format: "#%02X%02X%02X@%.2f", Int(p[v * 8] * 255), Int(p[v * 8 + 1] * 255), Int(p[v * 8 + 2] * 255), p[v * 8 + 3])
            }
            perFace = " · per face {" + seen.keys.sorted().map { "f\($0)=\(seen[$0]!)" }.joined(separator: ",") + "}"
        }
        var hist = ""
        if let b = buf, n > 600 {
            let p = b.contents().bindMemory(to: Float.self, capacity: b.length / 4)
            var h: [String: Int] = [:]
            for v in 0..<(b.length / 32) where p[v * 8 + 3] > 0 {
                h[String(format: "#%02X%02X%02X", Int(p[v * 8] * 255), Int(p[v * 8 + 1] * 255), Int(p[v * 8 + 2] * 255)), default: 0] += 1
            }
            let roleHex = Set(lastFace.values.map { String(format: "#%02X%02X%02X", Int($0.x * 255), Int($0.y * 255), Int($0.z * 255)) })
            hist = " · top colours {" + h.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)\(roleHex.contains($0.key) ? "(=role)" : ""):\($0.value)" }.joined(separator: ",") + "}"
        }
        return perFace + hist + " · verts \(n) · override \(override.map { "\($0.count / 8)v" } ?? "nil") · #354 faceTints {\(roleList)} · "
            + "tinted verts \(tinted) · ROLE-COLOURED verts \(roleInk) · volumes face \(faceCount) faint \(faint) glass \(glass) line \(line) · bodyAlpha \(body)"
    }

    /// The SwiftUI page (what cacheDisplay can see) and the renderer's own frame of the same state.
    func capture(_ h: Host, _ name: String) {
        try? FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        h.v.layoutSubtreeIfNeeded()
        if let rep = h.v.bitmapImageRepForCachingDisplay(in: h.v.bounds) {
            h.v.cacheDisplay(in: h.v.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: Self.out.appendingPathComponent("\(tag)_\(name)_ui.png"))
            }
        }
        guard let r = renderer(h) else { say("\(name): no renderer"); return }
        say("\(name): " + tintReport(r))
        let side = 2752, cropW = 2064
        let bg = DS.Color.background
        guard let px = r.renderOffscreen(size: side, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)) else {
            say("\(name): renderOffscreen nil"); return
        }
        var rgba = [UInt8](repeating: 255, count: cropW * side * 4)
        let x0 = (side - cropW) / 2
        for y in 0..<side { for x in 0..<cropW {
            let s = (y * side + x + x0) * 4, d = (y * cropW + x) * 4
            rgba[d] = px[s + 2]; rgba[d + 1] = px[s + 1]; rgba[d + 2] = px[s]
        } }
        guard let ctx = CGContext(data: &rgba, width: cropW, height: side, bitsPerComponent: 8, bytesPerRow: cropW * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: Self.out.appendingPathComponent("\(tag)_\(name)_metal.png"))
        }
    }

    func groupsTable(_ p: ProjectModel) {
        for g in p.selection.groups {
            say("  · \(g.name) — faces \(g.faces) regions \(g.regionIDs) — '\(p.force.panelKindLabel(for: g.id))' — colorIndex \(g.colorIndex)"
                + " #354tint " + { let c = p.force.tint(for: g); return String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255)) }()
                + (g.id == p.selection.activeGroupID ? " — ACTIVE" : "") + (p.groupView.isHidden(g.id) ? " — hidden" : ""))
        }
        say("  unit \(p.force.unit) · phase \(p.force.phase) · gravity set \(p.force.gravityIsSet)")
    }

    func find(_ items: [AXI], _ pred: (AXI) -> Bool) -> AXI? {
        items.filter(pred).filter { $0.frame.width > 1 && $0.frame.height > 1 }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    // MARK: OCR (SwiftUI builds no AX tree offscreen): find what he would tap by its words on screen

    struct Hit { let text: String; let rect: CGRect }
    func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    func ocr(_ h: Host) -> [Hit] {
        h.v.layoutSubtreeIfNeeded()
        guard let rep = h.v.bitmapImageRepForCachingDisplay(in: h.v.bounds) else { return [] }
        h.v.cacheDisplay(in: h.v.bounds, to: rep)
        guard let cg = rep.cgImage else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        let W = Self.size.width, H = Self.size.height
        return (req.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox
            return Hit(text: t, rect: CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H))
        }
    }
    func dumpOCR(_ hits: [Hit], _ name: String) {
        let txt = hits.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
            .map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))  \($0.text)" }
        try? txt.joined(separator: "\n").write(to: Self.out.appendingPathComponent("\(tag)_\(name)_ocr.txt"), atomically: true, encoding: .utf8)
    }
    func hit(_ hits: [Hit], _ want: String, exact: Bool = false, in area: CGRect = .infinite) -> Hit? {
        let w = norm(want)
        return hits.filter { area.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
            .filter { exact ? norm($0.text) == w : norm($0.text).contains(w) }
            .min { $0.rect.minY < $1.rect.minY }
    }
    func shot(_ h: Host, _ name: String) -> [Hit] {
        capture(h, name)
        let hits = ocr(h)
        dumpOCR(hits, name)
        return hits
    }

    func scrollViews(_ v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = v as? NSScrollView { out.append(s) }
        for c in v.subviews { out += scrollViews(c) }
        return out
    }
    /// The Selections list scrolled to its end (what is under the fold of its 360 pt cap).
    func scrollSelections(_ h: Host, toEnd: Bool) -> String {
        let svs = scrollViews(h.v).map { sv -> (NSScrollView, CGRect) in
            let r = sv.convert(sv.bounds, to: nil)
            return (sv, CGRect(x: r.minX, y: Self.size.height - r.maxY, width: r.width, height: r.height))
        }
        let desc = svs.map { "\($0.1.integral) doc \(Int($0.0.documentView?.frame.height ?? -1))" }.joined(separator: " · ")
        guard let (sv, _) = svs.filter({ $0.1.minX < 60 && $0.1.width > 200 && $0.1.width < 420 && $0.1.minY > 500 }).first else { return "no Selections scroll view: " + desc }
        let docH = sv.documentView?.frame.height ?? 0, visH = sv.contentView.bounds.height
        let flipped = sv.documentView?.isFlipped ?? true
        let y: CGFloat = toEnd ? (flipped ? max(0, docH - visH) : 0) : (flipped ? 0 : max(0, docH - visH))
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
        pump(0.5)
        return "Selections list: visible \(Int(visH)) pt of \(Int(docH)) pt (all scroll views: \(desc))"
    }

    // MARK: one project, as he goes through it

    func run(_ tag: String, _ r: FlexibleHisProject.Restored, pick: String?, rail: [String], picksBefore: [String] = [], picksAfter: [String] = []) throws {
        self.tag = tag
        lines = []
        flexI4VSwizzle(materials: FlexibleHisProject.materialsPath, stamps: FlexibleHisProject.stampsPath)
        say("FlexibleResources: materials \(FlexibleResources.materialsPath ?? "nil") · stamps \(FlexibleResources.stampsPath ?? "nil")")
        let p = r.project
        say("[\(tag)] restored through AppModel.open (H18 inside):")
        groupsTable(p)
        let h = host(WorkspacePlaceholder(model: r.app, project: p))
        defer { h.w.orderOut(nil) }
        pump(3)
        let top = shot(h, "0_topology")
        guard let nav = hit(top, "Lattice", in: CGRect(x: 500, y: 0, width: 400, height: 80)) else {
            say("NO Lattice nav on screen"); flush(); return
        }
        say("nav '\(nav.text)' at \(nav.rect.integral)")
        click(h, center(nav.rect))
        pump(0.05)
        capture(h, "1_flex_first_frame")
        // ★ frame by frame after entering: does a role colour reach the model before Flexible's first refresh?
        let t0 = Date()
        var last = ""
        var early = false
        while Date().timeIntervalSince(t0) < 4 {
            if !early, Date().timeIntervalSince(t0) > 1.2 { early = true; _ = shot(h, "1a_flex_t1s") }
            pump(0.03)
            guard let rr = renderer(h) else { continue }
            let s = tintReport(rr)
            if s != last { say(String(format: "  t+%.2fs ", Date().timeIntervalSince(t0)) + s); last = s }
        }
        _ = shot(h, "1b_flex_t4s")
        var settled: [Hit] = []
        for i in 0..<9 {
            pump(20)
            if let rr = renderer(h) { let s = tintReport(rr); if s != last { say(String(format: "  t+%.0fs ", Date().timeIntervalSince(t0)) + s); last = s } }
            settled = ocr(h)
            let busy = settled.contains { norm($0.text).contains("simulating") || norm($0.text).contains("building") }
            say(String(format: "  t+%.0fs busy %@", Date().timeIntervalSince(t0), busy ? "yes" : "no"))
            if i == 0 { _ = shot(h, "2_flex_t25s") }
            if !busy && i >= 2 { break }
        }
        settled = shot(h, "3_flex_settled")
        groupsTable(p)
        for name in picksBefore {
            guard let g = p.selection.groups.first(where: { $0.name == name }) else { say("no group \(name)"); continue }
            p.selection.setActive(g.id)
            pump(4)
            if let rr = renderer(h) { say("PICK (before Settings) '\(name)': " + tintReport(rr)) }
            _ = shot(h, "3p_pick_" + name.filter { $0.isLetter || $0.isNumber })
        }
        say(scrollSelections(h, toEnd: true))
        _ = shot(h, "3b_flex_settled_list_scrolled_to_end")
        _ = scrollSelections(h, toEnd: false)
        // Settings, from the real Settings button — BEFORE any pick: its Exit must not draw a prism
        let now = ocr(h)
        if let s = hit(now, "Settings", in: CGRect(x: 400, y: 0, width: 700, height: 300)) {
            click(h, center(s.rect))
            pump(8)
            var sh = shot(h, "5_settings")
            for t in rail {
                if let tab = hit(sh, t, exact: true, in: CGRect(x: 0, y: 300, width: 200, height: 1100)) ?? hit(sh, t, in: CGRect(x: 0, y: 300, width: 200, height: 1100)) {
                    click(h, center(tab.rect))
                    pump(4)
                    sh = shot(h, "6_settings_" + t.replacingOccurrences(of: " ", with: ""))
                } else { say("rail tab '\(t)' not on screen") }
            }
            if let ex = hit(sh, "Exit", in: CGRect(x: 0, y: 0, width: 300, height: 150)) {
                click(h, center(ex.rect))
                pump(6)
                if let rr = renderer(h) { say("back from Settings, NO pick yet: " + tintReport(rr)) }
                _ = shot(h, "7_main_after_settings_exit_no_pick")
            } else { say("Exit NOT ON SCREEN") }
        } else { say("Settings button NOT ON SCREEN") }
        // a pick: #354's row tap is `selection.setActive(g.id)` (its onTapGesture; a hosted click does not reach a
        // gesture inside an NSScrollView offscreen) — the same write he makes
        for name in (picksAfter.isEmpty ? [pick].compactMap { $0 } : picksAfter) {
            guard let g = p.selection.groups.first(where: { $0.name == name }) else { say("no group \(name)"); continue }
            p.selection.setActive(g.id)
            pump(5)
            if let rr = renderer(h) { say("PICK (after Settings) '\(name)': " + tintReport(rr)) }
            say("active now: \(p.selection.activeGroup?.name ?? "-")")
            _ = shot(h, "8_pick_" + name.filter { $0.isLetter || $0.isNumber })
        }
        // ★ POSITIVE CONTROL of the prism measurement: the main page's [Prisms] button (every pressed face's prism)
        let mtks = mtkViews(h.v)
        say("MTKViews: " + mtks.map { "\($0.frame.integral) hidden \($0.isHidden) renderer \($0.delegate is MeshRenderer)" }.joined(separator: " · "))
        click(h, CGPoint(x: 987, y: 256))
        pump(5)
        for (i, m) in mtks.enumerated() { if let rr = m.delegate as? MeshRenderer { say("PRISMS ON, view \(i): " + tintReport(rr)) } }
        _ = shot(h, "9_prisms_on")
        click(h, CGPoint(x: 987, y: 256))
        pump(3)
        if let rr = renderer(h) { say("PRISMS OFF again (Top active): " + tintReport(rr)) }
        flush()
        h.w.contentView = nil
        pump(20)
    }

    func testA1_0003_unlinked_control() throws {
        FlexibleGroupMigration.controlSkip = true
        let r = try FlexiblePressFixtures.a1Project(3, self)
        FlexibleGroupMigration.controlSkip = false
        try run("A1_0003_unlinked", r, pick: "Group C", rail: [])
    }

    func testA1_0003() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        try run("A1_0003", r, pick: "Group 2 · Face 4", rail: ["Top", "Group 2", "Group 3", "Rests"])
    }

    func testA1_0003_picks() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        try run("A1_0003q", r, pick: nil, rail: ["Group 2"], picksBefore: ["Group C", "Group 2 · Face 4"], picksAfter: ["Top", "Group 2 · Face 2", "Group 3 · Face 5"])
    }

    func testR5() throws {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        try run("r5", r, pick: nil, rail: ["Top", "Group 1", "Group 2", "Rests", "Pending"])
    }

    func testHis0004() throws {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.dir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        try run("his0004", r, pick: nil, rail: ["Top", "Group 1", "Rests", "Pending"])
    }
}
#endif

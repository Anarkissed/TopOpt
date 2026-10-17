// FlexibleR7REvidenceProbe — round 7, "the review of M2 and F": the LOOK after the fixes (opt-in: FLEX_R7R_EVIDENCE_DIR=<dir>).
// The WHOLE app page hosted (WorkspacePlaceholder: the main Flexible page, then the Squish page opened by its own Settings
// button), drawn by the pages' own MeshRenderer offscreen under the hosted chrome, on HIS pad A1_0003 with his live lattice
// (Group C = Face 3 + Face 5 at 25 mm) — the review's own probe (a scratch clone's R7ReviewUXProbe), its helpers kept, its
// run cut to what the fixes change: Group 2's face card (the named chips, the take-out), the weights and hands, Bend on
// Group 2 and on Group 1 (the chip with the bend), the trash's line, Reset all, the empty Exit and the main page after it.
// (The helpers are the review-only probe's.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7RFixWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7REvidenceProbe: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    struct AX { let id: String; let label: String; let role: String; let frame: CGRect; let obj: AnyObject }
    typealias Cam = FlexibleRound6Tests.Cam

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7R_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var tag = ""
    var log: [String] = [] { didSet { if let l = log.last, log.count > oldValue.count { FileHandle.standardError.write(("R7R-FIX " + l + "\n").data(using: .utf8)!); writeLog() } } }

    static let img3 = Cam(name: "img3 (front, low)", azimuth: 0.0, elevation: 0.5, zoom: 1)
    static let img4 = Cam(name: "img4 (left-front)", azimuth: -0.8, elevation: 0.62, zoom: 1)

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
        let w = R7RFixWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func press(_ h: Host, id: String? = nil, where pred: ((AX) -> Bool)? = nil, hold: Double = 0.06, what: String) -> Bool {
        let all = axAll(h)
        guard let a = all.first(where: { (id == nil || $0.id == id) && (pred?($0) ?? true) && $0.frame.width > 1 }) ?? all.first(where: { (id == nil || $0.id == id) && (pred?($0) ?? true) }) else {
            log.append("  (no AX element for \(what))"); return false
        }
        log.append("  tap \(what): [\(a.label)] id '\(a.id)' \(Self.f(a.frame))\(hold > 1 ? " held \(hold) s" : "")")
        if a.frame.width > 1 { click(h, CGPoint(x: a.frame.midX, y: a.frame.midY), hold: hold); pump(0.8); return true }
        if let e = a.obj as? NSAccessibilityProtocol, e.accessibilityPerformPress() { pump(0.8); return true }
        return false
    }
    func text(_ h: Host, _ id: String) -> String {
        let all = axAll(h).filter { $0.id == id }
        return all.map { $0.label.isEmpty ? "(unlabelled)" : $0.label }.joined(separator: " | ")
    }

    func frame(_ h: Host, _ key: String) -> CGRect? {
        guard let f = h.frames.all[key], f.width > 0 else { return nil }
        return f
    }
    @discardableResult
    func pressAt(_ h: Host, _ p: CGPoint, hold: Double = 0.06, what: String) -> Bool {
        log.append("  tap \(what) at (\(Int(p.x)),\(Int(p.y)))\(hold > 1 ? " held \(hold) s" : "")")
        click(h, p, hold: hold); pump(0.8); return true
    }
    @discardableResult
    func pressKey(_ h: Host, _ key: String, dx: CGFloat? = nil, hold: Double = 0.06, what: String) -> Bool {
        guard let f = frame(h, key) else { log.append("  (no frame '\(key)' for \(what); keys: \(h.frames.all.keys.sorted().joined(separator: ",")))"); return false }
        return pressAt(h, CGPoint(x: dx.map { f.minX + $0 } ?? f.midX, y: f.midY), hold: hold, what: "\(what) [\(key) \(Self.f(f))]")
    }
    func mainIcon(_ size: CGSize, _ i: Int) -> CGPoint {
        let row = FlexibleMainViewToggles.rowFrame(viewport: size)
        let c = FlexibleMainViewToggles.columns(viewport: size)
        let col = i % c, line = i / c
        return CGPoint(x: row.minX + CGFloat(col) * (40 + DS.Space.s) + 20, y: row.minY + CGFloat(line) * (40 + DS.Space.s) + 20)
    }
    /// The Squish page's view button i: 0 Prisms, 1 Groups, 2 Heat, 3 Bend, 4 X-ray, 5 Play.
    @discardableResult
    func squishView(_ h: Host, _ i: Int, hold: Double = 0.06, what: String) -> Bool {
        guard let f = frame(h, "viewButtons") else { log.append("  (no viewButtons frame for \(what))"); return false }
        return pressAt(h, CGPoint(x: f.minX + CGFloat(i) * (40 + DS.Space.s) + 20, y: f.midY), hold: hold, what: what)
    }
    static func f(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }

    func dumpAX(_ h: Host, _ name: String) {
        let all = axAll(h).filter { !$0.label.isEmpty || !$0.id.isEmpty }
            .filter { $0.frame.width > 0 && $0.frame.minX > -5 && $0.frame.minY > -5 && $0.frame.maxX < h.size.width + 5 && $0.frame.maxY < h.size.height + 5 }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        let lines = all.map { "\(Self.f($0.frame)) \($0.role) id='\($0.id)' '\($0.label)'" }
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(name + "_ax.txt"), atomically: true, encoding: .utf8)
        let btns = all.filter { ($0.role.contains("Button") || $0.role.contains("Radio") || $0.role.contains("PopUp")) && $0.frame.width > 4 && $0.frame.height > 4 }
        var over: [String] = []
        for (i, a) in btns.enumerated() { for b in btns[(i + 1)...] where a.frame.intersects(b.frame.insetBy(dx: 2, dy: 2)) && !a.frame.contains(b.frame) && !b.frame.contains(a.frame) {
            over.append("[\(a.label.isEmpty ? a.id : a.label)] \(Self.f(a.frame)) × [\(b.label.isEmpty ? b.id : b.label)] \(Self.f(b.frame))")
        } }
        let small = btns.filter { ($0.frame.width < 43.5 || $0.frame.height < 43.5) }.map { "[\($0.label.isEmpty ? $0.id : $0.label)] \(Int($0.frame.width))x\(Int($0.frame.height))" }
        log.append("  \(name): \(all.count) AX; overlapping buttons: \(over.isEmpty ? "none" : over.joined(separator: " | ")); under 44 pt: \(small.count) \(small.prefix(14).joined(separator: ", "))")
    }

    func renderers(_ v: NSView) -> [(MeshRenderer, CGRect, Bool)] {
        var out: [(MeshRenderer, CGRect, Bool)] = []
        func walk(_ v: NSView) {
            if let m = v as? MTKView, let r = m.delegate as? MeshRenderer {
                out.append((r, m.convert(m.bounds, to: nil), m.isHidden || m.alphaValue == 0 || m.window == nil))
            }
            for s in v.subviews { walk(s) }
        }
        walk(v)
        return out
    }
    /// The page renderer: the largest visible one; `last` picks the last of the largest (an overlay page sits later).
    func renderer(_ v: NSView, last: Bool) -> MeshRenderer? { pageView(v, last: last).flatMap { $0.delegate as? MeshRenderer } }
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
    /// The page's OWN camera model (the viewer's coordinator, the gestures' target): set it as the gizmo would, so the
    /// renderer, the chrome's projected overlays and the gizmo all follow.
    @discardableResult
    func setCam(_ h: Host, last: Bool, _ cam: Cam) -> Bool {
        guard let v = pageView(h.view, last: last) else { return false }
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

    func shot(_ h: Host, _ name: String, last: Bool = false, cam: Cam? = nil) {
        if let cam { setCam(h, last: last, cam) }
        pump(0.8)
        guard let dir = Self.dir else { return }
        h.view.layoutSubtreeIfNeeded()
        let rs = renderers(h.view)
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
        if let mr = renderer(h.view, last: last) {
            // landscape: the screen's vertical fov spans H rows — widen fovY so a W-square render has the screen's scale
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
            let clear = pg[i + 3] == 0
            if (!isBg && !clear) || out[i + 3] == 0 { out[i] = pg[i]; out[i + 1] = pg[i + 1]; out[i + 2] = pg[i + 2]; out[i + 3] = 255 }
        }
        guard let octx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let img = octx.makeImage() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(tag)_\(name).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
        log.append("wrote \(tag)_\(name).png (renderers \(rs.count); cam \(cam?.name ?? "page") → az \(renderer(h.view, last: last).map { String(format: "%.2f el %.2f", $0.camera.azimuth, $0.camera.elevation) } ?? "-"))")
    }

    func writeLog() {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("\(tag)_log.txt"), atomically: true, encoding: .utf8)
    }

    func settleLattice(_ s: FlexibleMainStage?, _ t: Double = 420) -> Bool {
        guard let s else { return false }
        let ok1 = pumpUntil(t) { if let m = s.model { return m.sceneState == .ready && m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale } ; return false }
        let ok2 = pumpUntil(t) { if let m = s.model { return !m.squish.isEmpty && !m.squish.values.contains(.pending) } ; return false }
        pump(4)
        return ok1 && ok2
    }
    func settledSquish(_ m: FlexibleStageModel, _ t: Double = 240) -> Bool {
        pumpUntil(t) { m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { (m.stacks[$0] != nil && m.geometry[$0] != nil) || m.stackErrors[$0] != nil }
            && !m.readiness.designing && !m.designsInFlight }
    }

    func mainState(_ s: FlexibleMainStage?, _ name: String) -> String {
        guard let s, let m = s.model else { return "\(name): (no model)" }
        let legend = s.legendKinds.map { "\($0)=\(s.legendTitle($0))" }
        return "\(name): heat \(s.heat) heatAll \(s.heatAll) xray \(s.xrayOn) play \(s.playOn) · views \(m.views.rawValue) · tapped group \(s.tappedGroupNumber.map(String.init) ?? "none") · selectedSim \(s.selectedSim ?? "nil") shownSim \(s.shownSim ?? "nil") sims \(s.sims.map(\.id)) · pill '\(s.status.line)' · legend \(legend) · lattice \(m.lattice != nil) stale \(m.latticeIsStale)"
    }
    func squishState(_ m: FlexibleStageModel, _ h: Host, _ name: String) -> String {
        let sel = m.selectedRegion.map { "\(m.displayName($0)) [\($0)]" } ?? "none"
        let groups = m.squeezeGroups.map { g in "\(m.groupName(g)): " + g.regions.map { "\(m.displayName($0)) \(String(format: "%.2f lb", (m.settings.face($0)?.weightKg ?? 0) * 2.20462))" }.joined(separator: ", ") }
        return "\(name): views \(m.views.rawValue) heatScope \(m.views.heatScope) · rail \(m.rail) tab \(m.tab) · selected \(sel) · toast '\(m.toast ?? "")' fix \(m.toastFix.map(\.rawValue) ?? "none") · groupDeleteAsk \(m.groupDeleteAsk.map(String.init) ?? "nil") · empty \(m.isEmptySetup) · groups [\(groups.joined(separator: " | "))] · frames \(h.frames.all.keys.filter { !$0.hasPrefix("railTitle") }.sorted().joined(separator: ","))"
    }

    func top(_ p: ProjectModel, x: Double) -> SIMD3<Double> {
        let b = p.viewerMesh!.bounds
        return SIMD3(Double(b.min.x) + x, Double(b.min.y + b.max.y) / 2, Double(b.max.z))
    }
    func inside(_ p: ProjectModel, face: Int) -> SIMD3<Double>? {
        guard let t = FlexibleEdgeStrips.triangles(face: face, mesh: p.viewerMesh!).first else { return nil }
        return (t[0] + t[1] + t[2]) / 3
    }

    // MARK: - the run

    func run(_ tagName: String, _ size: CGSize) throws {
        tag = tagName
        log = []
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        let s = FlexibleMainStage.lastMade
        let toLattice = CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2)
        click(h, toLattice); pump(4)
        let autoOpened = h.frames.all["exitRow"] != nil || h.frames.all["panel"] != nil
        log.append("[\(tag)] arrival on the Flexible stage: the Squish page opened by itself: \(autoOpened)")
        if autoOpened { pressKey(h, "exitRow", dx: 40, what: "Exit (leave the auto-opened Squish page)"); pump(3) }
        let settled = settleLattice(s)
        guard let s, let m = s.model else { XCTFail("no stage"); return }
        log.append(mainState(s, "M01 main at open (settled \(settled))"))
        shot(h, "M01_main_open")
        // the weights and the hands (R1)
        let mesh = p.viewerMesh
        for f in m.settings.loadedFaces {
            log.append(String(format: "W %@ [%d] root faces %@ · %.3f kg (%.2f lb) · %@ · group %@", m.displayName(f.faceRegionID), f.faceRegionID,
                              "\(m.regions.faces(of: f.faceRegionID, mesh: mesh))", f.weightKg, f.weightKg * 2.20462,
                              f.weightFrom == nil ? "own" : "linked", f.squeezeGroup.map(String.init) ?? "1"))
        }
        for g in m.squeezeGroups {
            log.append("H \(m.groupName(g)) hands: " + m.groupHands(g).map { hh in String(format: "%.2f lb on %@", hh.kg * 2.20462, hh.regions.map { m.displayName($0) }.joined(separator: "+")) }.joined(separator: " | ")
                       + " · group force \(m.groupForce(g).map { String(format: "%.2f lb", $0.upperBound * 2.20462) } ?? "nil")")
        }
        // R7: a tap on Face 4's solid middle
        if let mid = midSolid(m, face: 4) {
            _ = s.read(p, mode: .groups, face: FaceID(4), point: SIMD3<Float>(mid))
            pump(2)
            log.append(mainState(s, "M02 a tap on Face 4's solid middle"))
        }
        // ── THE SQUISH PAGE, by its own button
        pressAt(h, toLattice, what: "Settings (the Squish page)")
        pump(4)
        guard frame(h, "exitRow") != nil else { log.append("  (the Squish page did not open)"); return }
        _ = settledSquish(m); pump(2)
        // S09: Group 2's face card — the named chips, the take-out, the weight
        if let g2 = m.squeezeGroups.first(where: { $0.number == 2 }) {
            m.rail = .group(g2.id)
            pump(1)
            if let r0 = g2.regions.first { m.select(r0) }
            m.tab = .face
            pump(1.5); _ = settledSquish(m); pump(1)
            log.append(squishState(m, h, "S09 Group 2's face card"))
            log.append("  rail tabs: " + FlexibleSettingsRailView.tabs(model: m).map { "\($0.title) \($0.detail ?? "")" }.joined(separator: " · "))
            log.append("  chips \(frame(h, "groupChips").map(Self.f) ?? "none") · menu \(frame(h, "groupMenu").map(Self.f) ?? "none") · take-out " + h.frames.all.filter { $0.key.hasPrefix("faceRemove-") }.map { "\($0.key) \(Self.f($0.value))" }.joined(separator: ", "))
            if let r0 = g2.regions.first { log.append("  pinch line: \(FlexibleFacePanel.pinchLine(model: m, region: r0) ?? "none") · weight line: \(FlexibleFaceRows.weightLine(model: m, region: r0) ?? "none (the group's force)")") }
            shot(h, "S09_group2_face_card_named_chips", last: true, cam: Self.img4)
            dumpAX(h, "\(tag)_S09")
            // S06b: Bend on Group 2 (the chip with the bend)
            squishView(h, 3, what: "Squish Bend (Group 2)")
            pump(2.5)
            log.append(squishState(m, h, "S06b Bend on, Group 2") + " · chip " + (h.frames.all.first { $0.key.hasPrefix("depthChip") }.map { "\($0.key) \(Self.f($0.value))" } ?? "none"))
            shot(h, "S06b_group2_bend_on_img4cam", last: true, cam: Self.img4)
            squishView(h, 3, what: "Squish Bend off")
            pump(1.5)
            log.append("  Bend off · chip " + (h.frames.all.first { $0.key.hasPrefix("depthChip") }.map { "\($0.key) \(Self.f($0.value))" } ?? "none"))
            shot(h, "S06c_group2_bend_off_img4cam", last: true, cam: Self.img4)
            // S10: the group trash asks (44 pt Delete / Keep)
            pressKey(h, "groupRemove-2", what: "Group 2's trash")
            pump(1)
            log.append(squishState(m, h, "S10 trash tapped") + " · Delete \(frame(h, "groupDeleteConfirm").map(Self.f) ?? "none") Keep \(frame(h, "groupDeleteKeep").map(Self.f) ?? "none")")
            shot(h, "S10_group2_trash_asks", last: true, cam: Self.img4)
            pressKey(h, "groupDeleteKeep", what: "Keep")
        }
        // S06a: Bend on Group 1 (his first try) — the review's 1.1 mm
        if let g1 = m.squeezeGroups.first {
            m.rail = .group(g1.id)
            if let r0 = g1.regions.first { m.select(r0) }
            m.tab = .face
            pump(1.5)
            squishView(h, 3, what: "Squish Bend (Group 1)")
            pump(2.5)
            log.append(squishState(m, h, "S06a Bend on, Group 1"))
            shot(h, "S06a_group1_bend_on_img3cam", last: true, cam: Self.img3)
            squishView(h, 3, what: "Squish Bend off")
        }
        // the 3 s hold on Heat, then Reset all (ask, confirm) → the empty setup
        squishView(h, 2, hold: 3.4, what: "Squish Heat 3.4 s hold")
        pump(1.5)
        pressKey(h, "resetAll", what: "Reset all")
        pump(1)
        log.append("  Reset all asks · Reset \(frame(h, "resetConfirm").map(Self.f) ?? "none")")
        pressKey(h, "resetConfirm", what: "Reset (confirm)")
        pump(3); _ = settledSquish(m); pump(2)
        log.append(squishState(m, h, "S11 after Reset all") + " · legend sections row \(FlexibleLegend.sectionRow(m))")
        shot(h, "S11_after_reset_all_empty_img3cam", last: true, cam: Self.img3)
        dumpAX(h, "\(tag)_S11")
        // the empty Exit → the main page's status line
        pressKey(h, "exitRow", dx: 40, what: "Exit after Reset all (empty)")
        pump(5)
        _ = pumpUntil(120) { s.model?.sceneState == .ready }
        pump(8)
        log.append(mainState(s, "M06 the main page after an empty Exit") + " · heat lit \(s.heatIconLit) · Squish page still up \(frame(h, "exitRow") != nil) · status line AX '\(text(h, "flexible-status-line"))'")
        shot(h, "M06_main_after_empty_exit")
        dumpAX(h, "\(tag)_M06")
    }

    /// A point on face `face`'s solid middle (nothing pressable there), nearest its area centroid.
    func midSolid(_ m: FlexibleStageModel, face: Int) -> SIMD3<Double>? {
        guard let mesh = m.project.viewerMesh else { return nil }
        let tris = FlexibleEdgeStrips.triangles(face: face, mesh: mesh)
        var c = SIMD3<Double>(repeating: 0), a = 0.0
        for t in tris { let w = simd_length(simd_cross(t[1] - t[0], t[2] - t[0])) / 2; c += w * (t[0] + t[1] + t[2]) / 3; a += w }
        c /= max(a, 1e-12)
        var best: (Double, SIMD3<Double>)?
        for t in tris { for i in 0...24 { for j in 0...(24 - i) {
            let q = t[0] + (t[1] - t[0]) * (Double(i) + 0.3) / 25 + (t[2] - t[0]) * (Double(j) + 0.3) / 25
            guard m.regions.pressable(at: q, face: face, mesh: mesh) == nil else { continue }
            let d = simd_length(q - c)
            if best == nil || d < best!.0 { best = (d, q) }
        } } }
        return best?.1
    }

    func test13p() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7R_EVIDENCE_DIR") }
        try run("13p", CGSize(width: 1032, height: 1376))
    }
    func test11l() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7R_EVIDENCE_DIR") }
        try run("11l", CGSize(width: 1194, height: 834))
    }
}
#endif

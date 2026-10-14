// FlexibleRound7ViewsEvidenceProbe — round 7 batch R7-V's pictures, on HIS pad (A1_0003 as he saved it). Opt-in:
//     FLEX_R7V_EVIDENCE_DIR=<dir> swift test --filter FlexibleRound7ViewsEvidenceProbe
// ★ THE PAGES' OWN PICTURE, BY THE SHIPPING RENDERER, UNDER THE PAGES' OWN CHROME: MeshRenderer's offscreen render of
// exactly what each page hands MetalMeshView (the main page: FlexibleMainStage's mesh / tints / dents / body alpha /
// lattice layer / prisms; Settings: composeTints with its views, its dent at the page's scale, FlexibleStageVolumes),
// with the page's SwiftUI chrome hosted offscreen over it (the hosted page's own ground made clear, so the model shows
// where the device's MetalMeshView would). Offscreen frames, not device screenshots; the camera is the probe's (his
// img1 / img5 views), not the page's own framing.
// Also the $playing trace across an edit while paused (r7v_playing_trace.txt).
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import AppKit
import Combine
import MetalKit
import SwiftUI
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7VProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7ViewsEvidenceProbe: XCTestCase {

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7V_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    typealias Cam = FlexibleRound6Tests.Cam
    static let img1 = Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
    static let img5 = Cam(name: "img5 (top)", azimuth: .pi / 9, elevation: 1.42, zoom: 1)

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func pumpUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// The hosted view's pixels (RGBA, premultiplied), its pixel size.
    func hostedPixels<V: View>(_ v: V, size: CGSize, settle: Double = 1.5) throws -> (px: [UInt8], w: Int, h: Int) {
        let hv = NSHostingView(rootView: AnyView(v.environment(\.colorScheme, .dark)))
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7VProbeWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.orderFrontRegardless()
        defer { w.orderOut(nil); w.contentView = nil }
        pump(settle)
        hv.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hv.bitmapImageRepForCachingDisplay(in: hv.bounds))
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (buf, cg.width, cg.height)
    }

    /// The model (BGRA, n × n, the renderer's) under the chrome (RGBA), written as `name`: the chrome's own ground colour
    /// is made clear so the model shows through it.
    /// `place`: where the model's square goes, as fractions of the page (x, y, side of the shorter page side); nil: centred,
    /// the shorter side.
    func composite(model px: [UInt8], n: Int, chrome: (px: [UInt8], w: Int, h: Int), name: String,
                   place: (x: CGFloat, y: CGFloat, side: CGFloat)? = nil) throws {
        guard let dir = Self.dir else { return }
        let bg = DS.Color.background
        let gr = UInt8((bg.r * 255).rounded()), gg = UInt8((bg.g * 255).rounded()), gb = UInt8((bg.b * 255).rounded())
        var model = px
        for i in stride(from: 0, to: model.count, by: 4) { model.swapAt(i, i + 2); model[i + 3] = 255 }
        let mctx = try XCTUnwrap(CGContext(data: &model, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let mimg = try XCTUnwrap(mctx.makeImage())
        var c = chrome.px
        for i in stride(from: 0, to: c.count, by: 4) where abs(Int(c[i]) - Int(gr)) <= 3 && abs(Int(c[i + 1]) - Int(gg)) <= 3
            && abs(Int(c[i + 2]) - Int(gb)) <= 3 && c[i + 3] == 255 {
            c[i] = 0; c[i + 1] = 0; c[i + 2] = 0; c[i + 3] = 0
        }
        let cctx = try XCTUnwrap(CGContext(data: &c, width: chrome.w, height: chrome.h, bitsPerComponent: 8, bytesPerRow: chrome.w * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cimg = try XCTUnwrap(cctx.makeImage())
        let out = try XCTUnwrap(CGContext(data: nil, width: chrome.w, height: chrome.h, bitsPerComponent: 8, bytesPerRow: chrome.w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        out.setFillColor(CGColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: chrome.w, height: chrome.h))
        let short = CGFloat(min(chrome.w, chrome.h))
        if let pl = place {
            let side = short * pl.side
            // (CG's y is up: the page's y-down fraction from the top)
            out.draw(mimg, in: CGRect(x: CGFloat(chrome.w) * pl.x, y: CGFloat(chrome.h) * (1 - pl.y) - side, width: side, height: side))
        } else {
            out.draw(mimg, in: CGRect(x: (CGFloat(chrome.w) - short) / 2, y: (CGFloat(chrome.h) - short) / 2, width: short, height: short))
        }
        out.draw(cimg, in: CGRect(x: 0, y: 0, width: chrome.w, height: chrome.h))
        let img = try XCTUnwrap(out.makeImage())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("FLEX-R7V-EVIDENCE wrote \(url.path)")
    }

    func render(mesh: ViewerMesh, tints: [Float]?, dents: [Float]?, scale: Float, bodyAlpha: Float, settle: simd_quatf, cam: Cam,
                items: [ClearanceRenderItem], layer: FlexibleLatticeLayerInputs?, n: Int) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try FlexibleRound6EvidenceProbe().renderer(mesh: mesh, tints: tints, dents: dents, scale: scale, bodyAlpha: bodyAlpha,
                                                             settle: settle, cam: cam, device: device, items: items, layer: layer)
        let bg = DS.Color.background
        return try XCTUnwrap(mr.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
    }

    /// The main page's chrome that R7-V touches: the icon row (and its note), the ONE legend card, the player slot.
    struct MainChrome: View {
        @ObservedObject var main: FlexibleMainStage
        var body: some View {
            ZStack {
                DS.Color.background.color.ignoresSafeArea()
                FlexibleMainViewToggles(main: main, openSettings: {})
                FlexibleMainLegends(main: main, mode: .constant(.groups), projection: nil, settle: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                                    bottomClearance: 94, chipColumnWidth: 0)
                FlexibleMainPlayerSlot(main: main, bottomClearance: 94, chipColumnWidth: 0)
            }
        }
    }

    func testTheMainPageOnHisPad() async throws {
        guard Self.dir != nil else { throw XCTSkip("opt-in: FLEX_R7V_EVIDENCE_DIR") }
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        s.didExitSettings()
        s.apply(p, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        s.refresh()
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        var lines: [String] = []
        func shot(_ name: String, cam: Cam, size: (String, CGSize)) throws {
            s.refresh()
            let mesh = try XCTUnwrap(s.mesh(p, on: .lattice))
            let n = Int(min(size.1.width, size.1.height) * 2)
            let model = try render(mesh: mesh, tints: s.tints(p, on: .lattice, roles: [:], stress: nil), dents: s.dents(p, on: .lattice),
                                   scale: s.dentScale(p, on: .lattice), bodyAlpha: s.bodyAlpha(p, on: .lattice) ?? 1, settle: settle, cam: cam,
                                   items: s.volumes(p, on: .lattice, drilledIn: false), layer: s.layer(p, stage: .lattice, pageUp: false), n: n)
            let chrome = try hostedPixels(MainChrome(main: s), size: size.1)
            try composite(model: model, n: n, chrome: chrome, name: name)
            lines.append("\(name): xray \(s.xrayOn) body \(s.bodyAlpha(p, on: .lattice) ?? -1) walls hidden \(s.layer(p, stage: .lattice, pageUp: false)?.hidden ?? true) · play \(s.playOn) bar \(s.playerShown) playing \(s.loop.playing) held \(s.loop.held) · legends \(s.legendKinds.map(\.rawValue))")
        }
        let p13 = ("13p", CGSize(width: 1032, height: 1376)), l11 = ("11l", CGSize(width: 1194, height: 834))
        // the default: X-ray off (the opaque model), Play off (no bar, at rest), Heat and the Lattice view on
        try shot("R7V_M_img1_default_xray_off_play_off_13p.png", cam: Self.img1, size: p13)
        try shot("R7V_M_img5_default_xray_off_play_off_13p.png", cam: Self.img5, size: p13)
        try shot("R7V_M_img1_default_xray_off_play_off_11l.png", cam: Self.img1, size: l11)
        // X-ray on: today's look (the ghost, the walls inside)
        s.toggleXray()
        try shot("R7V_M_img1_xray_on_13p.png", cam: Self.img1, size: p13)
        try shot("R7V_M_img5_xray_on_13p.png", cam: Self.img5, size: p13)
        // Play on: the bar, playing (the frame is the loop at rest — a still)
        s.togglePlay()
        try shot("R7V_M_img1_xray_on_play_on_13p.png", cam: Self.img1, size: p13)
        try shot("R7V_M_img1_xray_on_play_on_11l.png", cam: Self.img1, size: l11)
        s.togglePlay(); s.toggleXray()
        print("FLEX-R7V-EVIDENCE main\n  " + lines.joined(separator: "\n  "))
    }

    func testTheSettingsPageHeatAndBendOnHisPad() async throws {
        guard Self.dir != nil else { throw XCTSkip("opt-in: FLEX_R7V_EVIDENCE_DIR") }
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.regions == [4, 2] })
        m.rail = .group(g2.id)
        m.select(4)
        try await FlexibleSquishFixture.solve(m, first: FlexibleSim.groupID(g2.number), "his pad")
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let size = CGSize(width: 1032, height: 1376)
        var lines: [String] = []
        func shot(_ name: String, views: FlexibleStageViews, amount: Double = 0) throws {
            m.views = views
            let edge = FlexibleSettingsSquish.overlayEdge(model: m)
            let overlay = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0) } ?? FlexiblePageChannels.overlay(model: m))
            var cache: (key: String, dents: [Float])?
            var c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: views)
            let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
            c.dents = sq.dents
            let scale = FlexibleStagePage.dentScale(views: views, exaggeration: sq.exaggeration, amount: amount)
            let heat = FlexibleGroupWalls.heatSamples(tints: c.tints, overlay: overlay, model: m)
            var items = FlexibleStageVolumes.items(model: m, k: FlexibleStageVolumes.prismK(sq.exaggeration), part: p.viewerMesh, heat: heat,
                                                   heated: FlexibleStageHeat.shown(model: m, views: views))
            if views.contains(.bend), views.contains(.play), let g = FlexibleBendGhost.item(overlay: overlay, dents: sq.dents, k: sq.exaggeration) { items.append(g) }
            let n = 1600
            let cam = Cam(name: "iso", azimuth: .pi / 4, elevation: .pi / 6, zoom: 1.25)
            let model = try render(mesh: overlay.mesh, tints: c.tints, dents: sq.dents, scale: scale, bodyAlpha: FlexibleStagePage.xrayBodyAlpha,
                                   settle: settle, cam: cam, items: items, layer: nil, n: n)
            let chrome = try hostedPixels(FlexibleStagePage(project: p, model: m, onExit: {}), size: size, settle: 2.5)
            // the model where the page leaves room on his 13" portrait: above and right of the panel
            try composite(model: model, n: n, chrome: chrome, name: name, place: (x: 0.22, y: 0.05, side: 0.78))
            lines.append("\(name): heat \(views.heatScope) on \(FlexibleStageHeat.shown(model: m, views: views).sorted()) · bend \(views.contains(.bend)) scale \(scale) (k \(sq.exaggeration), fe \(sq.fe)) · glass \(items.filter(\.surfaceOnly).map(\.volume.faceID))")
        }
        try shot("R7V_S_13p_heat_group_default.png", views: [])
        try shot("R7V_S_13p_heat_off.png", views: [.heatOff])
        try shot("R7V_S_13p_heat_all.png", views: [.heatAll])
        try shot("R7V_S_13p_bend_alone.png", views: [.bend, .heatOff])
        try shot("R7V_S_13p_bend_heat.png", views: [.bend])
        try shot("R7V_S_13p_bend_play_ghost.png", views: [.bend, .play], amount: 0.35)
        m.views = []
        print("FLEX-R7V-EVIDENCE settings\n  " + lines.joined(separator: "\n  "))
    }

    /// The $playing trace across an edit while paused (his img1: "any action taken anywhere automatically re-starts the
    /// simulation"), the page driven only by its own debounced refresh.
    func testThePlayingTraceAcrossAnEditWhilePaused() async throws {
        guard let dir = Self.dir else { throw XCTSkip("opt-in: FLEX_R7V_EVIDENCE_DIR") }
        let r = try FlexibleHisProject.restore(nil)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { false }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.views.insert(.play)
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his")
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        var trace: [String] = []
        let t0 = Date()
        func note(_ what: String) {
            trace.append(String(format: "%6.2f s  %@ · playing %d held %.2f paused-by-him %d · lattice %d stale %d · sims %@",
                                Date().timeIntervalSince(t0), what, s.loop.playing ? 1 : 0, s.loop.held, s.loop.pausedByHim ? 1 : 0,
                                m.lattice?.generation ?? -1, m.latticeIsStale ? 1 : 0,
                                m.squish.values.map { $0 == .pending ? "p" : ($0.field != nil ? "r" : "f") }.sorted().joined()))
        }
        try await FlexibleHisProject.waitFor(400, "the sims") { m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        note("Play on, sims landed")
        s.loop.toggle()
        note("HIS PAUSE")
        let watch = s.loop.$playing.sink { v in trace.append(String(format: "%6.2f s  $playing → %d", Date().timeIntervalSince(t0), v ? 1 : 0)) }
        defer { watch.cancel() }
        let g1 = try XCTUnwrap(m.squeezeGroups.first)
        let gen = m.lattice?.generation ?? -1
        m.setGroupForce(g1.id, kg: (m.groupForce(g1)?.upperBound ?? 10) + 3)
        note("edit: Group 1's squeeze +3 kg")
        let start = Date()
        var last = ""
        while Date().timeIntervalSince(start) < 400 {
            let line = "\(m.lattice?.generation ?? -1)\(m.latticeIsStale)\(m.squish.values.map { $0 == .pending ? "p" : "r" }.sorted())"
            if line != last { note("…"); last = line }
            if let l = m.lattice, l.generation > gen, !m.latticeIsStale, !m.squish.values.contains(.pending), m.squishSolver.isIdle { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        note("rebuilt, every sim landed")
        s.loop.toggle()
        note("HIS PLAY (the player's ▶)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ("# R7-V: the main page's loop across an edit while he has paused (his 0004, Play on, the page's own refresh)\n"
             + trace.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("r7v_playing_trace.txt"), atomically: true, encoding: .utf8)
        print("FLEX-R7V-EVIDENCE trace\n  " + trace.joined(separator: "\n  "))
        XCTAssertEqual(trace.filter { $0.hasSuffix("$playing → 1") }.count, 1, "only his Play played")
    }
}
#endif

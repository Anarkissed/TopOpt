// FlexibleR7X1EvidenceProbe — round 7 batch X1's pictures (the X-ray rule, the printed view), on HIS pad (A1_0003). Opt-in:
//     FLEX_R7X1_EVIDENCE_DIR=<dir> swift test --filter FlexibleR7X1EvidenceProbe
// ★ THE PAGES' OWN PICTURE, BY THE SHIPPING RENDERER, UNDER THE PAGES' OWN CHROME: MeshRenderer's offscreen render of exactly
// what each page hands MetalMeshView (the main page: FlexibleMainStage's mesh / tints / dents / body alpha / lattice layer /
// prisms; the Squish page: composeTints with its views, its dent at the page's scale, FlexibleStageVolumes, and X1's bend
// prism), with the page's SwiftUI chrome hosted offscreen over it. Offscreen frames, not device screenshots; the camera is the
// probe's (his img1 / img5 views), not the page's own framing. His pad with HIS LIVE LATTICE (Group C's two 25 mm face-prisms,
// the two strips of his img5 — FlexibleR7M1Fixtures.hisLiveLattice), his pad as saved (no face-prism), and the fixture's Top
// face-prism (a1Project(3)).
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import AppKit
import MetalKit
import SwiftUI
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7X1ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7X1EvidenceProbe: XCTestCase {

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7X1_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    typealias Cam = FlexibleRound6Tests.Cam
    static let img1 = r7x1Img1
    static let img5 = r7x1Img5
    static let p13 = ("13p", CGSize(width: 1032, height: 1376)), l11 = ("11l", CGSize(width: 1194, height: 834))

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func hostedPixels<V: View>(_ v: V, size: CGSize, settle: Double = 1.5) throws -> (px: [UInt8], w: Int, h: Int) {
        let hv = NSHostingView(rootView: AnyView(v.environment(\.colorScheme, .dark)))
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7X1ProbeWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    /// The model (BGRA, n × n) under the chrome (RGBA), written as `name` (the chrome's own ground made clear).
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
        print("FLEX-R7X1-EVIDENCE wrote \(url.path)")
    }

    func render(mesh: ViewerMesh, tints: [Float]?, dents: [Float]?, scale: Float, bodyAlpha: Float, settle: simd_quatf, cam: Cam,
                items: [ClearanceRenderItem], layer: FlexibleLatticeLayerInputs?, n: Int) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try FlexibleRound6EvidenceProbe().renderer(mesh: mesh, tints: tints, dents: dents, scale: scale, bodyAlpha: bodyAlpha,
                                                             settle: settle, cam: cam, device: device, items: items, layer: layer)
        let bg = DS.Color.background
        return try XCTUnwrap(mr.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
    }

    /// The main page's chrome: the icon row, the ONE legend card, the player slot and the bottom pill.
    struct MainChrome: View {
        @ObservedObject var main: FlexibleMainStage
        var body: some View {
            ZStack {
                DS.Color.background.color.ignoresSafeArea()
                FlexibleMainViewToggles(main: main, openSettings: {})
                FlexibleMainLegends(main: main, mode: .constant(.groups), projection: nil, settle: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                                    bottomClearance: 94, chipColumnWidth: 0)
                FlexibleMainPlayerSlot(main: main, bottomClearance: 94, chipColumnWidth: 0)
                VStack { Spacer(); HStack { Spacer(); FlexibleMainStatusPill(main: main, open: {}) } }
                    .padding(.horizontal, DS.Space.xl4).padding(.bottom, 24)
            }
        }
    }

    func shot(_ s: FlexibleMainStage, _ p: ProjectModel, _ name: String, cam: Cam, size: (String, CGSize), lines: inout [String]) throws {
        s.refresh()
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let mesh = try XCTUnwrap(s.mesh(p, on: .lattice) ?? p.viewerMesh)
        let n = Int(min(size.1.width, size.1.height) * 2)
        let items = s.volumes(p, on: .lattice, drilledIn: false)
        let layer = s.layer(p, stage: .lattice, pageUp: false)
        let model = try render(mesh: mesh, tints: s.tints(p, on: .lattice, roles: [:], stress: nil), dents: s.dents(p, on: .lattice),
                               scale: s.dentScale(p, on: .lattice), bodyAlpha: s.bodyAlpha(p, on: .lattice) ?? 1, settle: settle, cam: cam,
                               items: items, layer: layer, n: n)
        let chrome = try hostedPixels(MainChrome(main: s), size: size.1)
        try composite(model: model, n: n, chrome: chrome, name: name)
        lines.append("\(name): finish \(s.model?.settings.finishMode.rawValue ?? "-") · X-ray \(s.xrayOn) · printed \(layer?.printed ?? false) · walls hidden \(layer?.hidden ?? true) · body alpha \(s.bodyAlpha(p, on: .lattice) ?? -1) · heat \(s.heat) · Lattice icon lit \(s.latticeIconLit) · legend \(s.legendKinds) · prisms \(items.count)")
    }

    func rebuild(_ s: FlexibleMainStage, _ m: FlexibleStageModel, finish f: FlexibleFinish) async throws {
        guard m.settings.finishMode != f else { return }
        m.edit { $0.finish = f.rawValue }
        s.buildIfReady()
        try await FlexibleHisProject.waitFor(240, "the lattice (\(f.rawValue))") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testTheMainPageOnHisPad() async throws {
        guard Self.dir != nil else { throw XCTSkip("opt-in: FLEX_R7X1_EVIDENCE_DIR") }
        var lines: [String] = []
        // ★ his pad AS SAVED: no face-prism — the plain model (M1), X-ray off
        do {
            let (r, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: false)
            let p = r.project
            s.didExitSettings()
            s.apply(p, owned: true, pageUp: false)
            try await Task.sleep(nanoseconds: 500_000_000)
            await m.waitForIdle()
            try shot(s, p, "R7X1_no_face_prism_plain_model_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        }
        // ★ his LIVE lattice (Group C's two strips), Finish None as he saved it
        let (r, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: true)
        let p = r.project
        s.didExitSettings()
        s.apply(p, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        // the default view: X-ray off, Heat on, the lattice on — the printed view
        try shot(s, p, "R7X1_default_none_img5_13p.png", cam: Self.img5, size: Self.p13, lines: &lines)
        try shot(s, p, "R7X1_default_none_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        try shot(s, p, "R7X1_default_none_img1_11l.png", cam: Self.img1, size: Self.l11, lines: &lines)
        s.heat = false
        try shot(s, p, "R7X1_default_none_heat_off_img5_13p.png", cam: Self.img5, size: Self.p13, lines: &lines)
        s.heat = true
        // the Lattice icon off: the plain model (X-ray stays off)
        s.toggleLatticeView()
        try shot(s, p, "R7X1_lattice_off_plain_model_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        s.toggleLatticeView()
        // X-ray ON: through the solid — the walls, the heat on the pressed Top (the bend amount), inside the part
        s.toggleXray()
        try shot(s, p, "R7X1_xray_on_img5_13p.png", cam: Self.img5, size: Self.p13, lines: &lines)
        try shot(s, p, "R7X1_xray_on_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        s.toggleXray()
        // [Prisms] does not turn X-ray on (X1)
        s.togglePrisms()
        try shot(s, p, "R7X1_prisms_view_xray_stays_off_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        s.togglePrisms()
        // Play on, mid-squish (the printed view squishes with the walls)
        s.togglePlay()
        s.loop.hold(0.6)
        try shot(s, p, "R7X1_default_none_play_at_0.6_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        s.togglePlay()
        // the finishes: Skin (perforated), Rim (bands at the edges), Covered (the plain model) — each rebuilt, its sims landed
        for f in [FlexibleFinish.skin, .rim, .covered] {
            try await rebuild(s, m, finish: f)
            try await FlexibleHisProject.waitFor(300, "the sims (\(f.rawValue))") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
            for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
            try shot(s, p, "R7X1_default_\(f.rawValue)_img5_13p.png", cam: Self.img5, size: Self.p13, lines: &lines)
            try shot(s, p, "R7X1_default_\(f.rawValue)_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        }
        // Covered in X-ray: the lattice inside the skin
        s.toggleXray()
        try shot(s, p, "R7X1_covered_xray_on_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        s.toggleXray()
        try await rebuild(s, m, finish: .none)
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        // Group C picked: its face-prisms (M1's — the list's depth), in X-ray (their extent inside the part) and out of it
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        p.selection.setActive(c.id)
        s.toggleXray()
        try shot(s, p, "R7X1_xray_on_groupC_picked_face_prisms_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        s.toggleXray()
        try shot(s, p, "R7X1_default_groupC_picked_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        // the fixture's Top face-prism (a1Project(3)): the whole pad under the Top latticed
        do {
            let r2 = try FlexiblePressFixtures.a1Project(3, self)
            let s2 = FlexibleMainStage()
            s2.reduceMotion = { true }
            let m2 = s2.model(for: r2.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
            addTeardownBlock { @MainActor in await m2.waitForIdle() }
            m2.openScene()
            try await FlexibleSquishFixture.settle(m2, "his pad (Top face-prism)")
            s2.didExitSettings()
            s2.apply(r2.project, owned: true, pageUp: false)
            try await FlexibleHisProject.waitFor(240, "the lattice") { m2.lattice != nil && !m2.latticeBuilding && !m2.latticeIsStale }
            for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
            try shot(s2, r2.project, "R7X1_top_face_prism_default_none_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        }
        print("FLEX-R7X1-EVIDENCE main\n  " + lines.joined(separator: "\n  "))
        if let dir = Self.dir {
            try ("# X1 evidence — the main page (FlexibleR7X1EvidenceProbe.testTheMainPageOnHisPad)\n" + lines.joined(separator: "\n") + "\n")
                .write(to: dir.appendingPathComponent("r7x1_evidence_main.txt"), atomically: true, encoding: .utf8)
        }
    }

    func testTheSquishPageXrayOnHisPad() async throws {
        guard Self.dir != nil else { throw XCTSkip("opt-in: FLEX_R7X1_EVIDENCE_DIR") }
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
            let xr = FlexibleStagePage.xrayItems(model: m, overlay: overlay, dents: sq.dents, k: sq.exaggeration, views: views)
            items += xr
            let n = 1600
            let cam = Cam(name: "iso", azimuth: .pi / 4, elevation: .pi / 6, zoom: 1.25)
            let alpha = FlexibleStagePage.bodyAlpha(views: views, edgePick: false, hasDent: sq.dents != nil)
            let model = try render(mesh: overlay.mesh, tints: c.tints, dents: sq.dents, scale: scale, bodyAlpha: alpha,
                                   settle: settle, cam: cam, items: items, layer: nil, n: n)
            let chrome = try hostedPixels(FlexibleStagePage(project: p, model: m, onExit: {}), size: size, settle: 2.5)
            try composite(model: model, n: n, chrome: chrome, name: name, place: (x: 0.22, y: 0.05, side: 0.78))
            let depth = xr.first.flatMap { i -> String? in
                guard case .shell(let sh) = i.volume.shape else { return nil }
                return String(format: "%.1f mm", sh.reachedDepthMM)
            } ?? "-"
            lines.append("\(name): views \(views.rawValue) · X-ray \(views.contains(.xray)) · body alpha \(alpha) · bend prism \(depth) (k \(sq.exaggeration), fe \(sq.fe)) · scale \(scale)")
        }
        try shot("R7X1_S_13p_default_xray_off.png", views: [])
        try shot("R7X1_S_13p_xray_on_bend_prism.png", views: [.xray])
        try shot("R7X1_S_13p_xray_on_bend_prism_with_bend.png", views: [.xray, .bend])
        try shot("R7X1_S_13p_prisms_xray_off.png", views: [.prisms])
        try shot("R7X1_S_13p_bend_alone_xray_off.png", views: [.bend, .heatOff])
        m.views = []
        print("FLEX-R7X1-EVIDENCE squish\n  " + lines.joined(separator: "\n  "))
        if let dir = Self.dir {
            try ("# X1 evidence — the Squish page (FlexibleR7X1EvidenceProbe.testTheSquishPageXrayOnHisPad)\n" + lines.joined(separator: "\n") + "\n")
                .write(to: dir.appendingPathComponent("r7x1_evidence_squish.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif

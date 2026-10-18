// FlexibleEdgeGroupsHostedTests — round 6 item 2 on the Settings page, HOSTED (offscreen, never the app), on HIS pad
// (A1_0003 as he saved it). Written BEFORE the code.
//   H1 the [+ New] tab asks [Faces] [Edges/corners] on one line; in pick mode the card lists EVERY candidate, one row
//      each, at least 44 pt tall, inside the panel; the card's lines are one line each; after [Done] the edges group's
//      tab shows its press and the face-keeps-the-rest line. RED: the stub card (no rows).
//      ★ RE-PINNED (round 7, R7-E1 — his 2026-10-18 words: "There shouldn't be a strip width."): the tab's "Strip width" row
//      is gone (its flat prism's rows are FlexibleFlatPrismHostedTests' H1); this test never clicked it.
//   EVIDENCE (FLEX_I2_EVIDENCE_DIR=<dir>): his pad at his img2 and img3 cameras in pick mode — every edge and corner in
//   its colour with its number, beside the panel's list; an edge picked with the "keeps the rest" lines; [Done]: the
//   strip taken (the new group's glass on its strips) beside the edges group's tab. The model by the shipping renderer
//   (MeshRenderer offscreen, the page's own tints and items), the strokes / dots / tags drawn at the points the page
//   projects them to (FlexibleEdgePickOverlay.marks); the panel hosted (NSHostingView). NOT device screenshots.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class I2HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleEdgeGroupsHostedTests: XCTestCase {
    typealias G = FlexibleAngledGoldens
    typealias Cam = FlexibleRound6Tests.Cam

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_I2_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let frames: Frames }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = I2HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, frames: frames)
    }

    func image(_ h: Host) -> CGImage? {
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return nil }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        return rep.cgImage
    }

    /// The Settings panel alone, as the page lays it (480 pt wide), dark.
    func panel(_ m: FlexibleStageModel, height: CGFloat = 1300) -> Host {
        let v = PanelHost(model: m)
            .frame(width: FlexibleSettingsPanel.width, height: height, alignment: .top)
            .background(DS.Color.background.color)
        return host(v, size: CGSize(width: FlexibleSettingsPanel.width, height: height))
    }

    struct PanelHost: View {
        @ObservedObject var model: FlexibleStageModel
        @State var pad: String?
        @State var minimized = false
        var body: some View { FlexibleSettingsPanel(model: model, padTarget: $pad, minimized: $minimized) }
    }

    func hisPad() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = try await G.openModel(self, r.project, "A1_0003")
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        return (r, m)
    }

    func pickMode(_ m: FlexibleStageModel) async throws {
        m.rail = .newGroup
        m.startEdgePick()
        try await FlexibleHisProject.waitFor(240, "the edges and corners listed") {
            m.edgePick.map { !$0.loading && !$0.checking } ?? false
        }
        await m.waitForIdle()
    }

    // MARK: - H1

    func testThePickCardListsEveryCandidateWithFingerSizedRowsAndTheEdgesTabItsWidth() async throws {
        let (_, m) = try await hisPad()
        m.rail = .newGroup
        let h = panel(m)
        pump(0.4)
        XCTAssertNotNil(h.frames.all["newKind"], "[+ New] asks [Faces] [Edges/corners]")
        if let k = h.frames.all["newKind"] { XCTAssertLessThanOrEqual(k.height, 44, "on one line") }
        try await pickMode(m)
        pump(0.6)
        let p = try XCTUnwrap(m.edgePick)
        let panelFrame = CGRect(x: 0, y: 0, width: FlexibleSettingsPanel.width, height: h.view.bounds.height)
        var rows: [String] = []
        for c in p.candidates {
            let f = try XCTUnwrap(h.frames.all["edgeRow-\(c.number)"], "#\(c.number) has its row")
            XCTAssertGreaterThanOrEqual(f.height, 44, "#\(c.number)'s row is a finger's target")
            XCTAssertLessThanOrEqual(f.maxX, panelFrame.maxX + 0.5, "#\(c.number)'s row inside the panel")
            rows.append("#\(c.number) \(Int(f.height))pt")
        }
        print("FLEX-I2-H1 rows: " + rows.joined(separator: " "))
        let c = try XCTUnwrap(p.candidates.first { $0.kind == .edge && Set($0.members) == [1, 2] })
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(5)
        pump(0.3)
        let why1 = await m.finishEdgePick()
        XCTAssertNil(why1)
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        pump(0.6)
        let label = FlexibleRowCopy.candidateLabel(c)
        XCTAssertNotNil(h.frames.all["edgePress-\(label)"], "the edges group's tab lists its press")
        XCTAssertFalse(m.keepsTheRest(press: try XCTUnwrap(m.presses.first { $0.strip != nil }).id).isEmpty,
                       "its row says which faces keep the rest")
    }

    // MARK: - evidence

    struct Mark { let point: CGPoint; let text: String; let fill: RGBA }

    func renderModel(_ m: FlexibleStageModel, _ r: FlexibleHisProject.Restored, cam: Cam, device: MTLDevice, size: Int = 900,
                     pick: Bool) throws -> CGImage {
        let part = try XCTUnwrap(r.project.viewerMesh)
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let c = FlexibleStagePage.composeTints(model: m, overlay: o)
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        let k = FlexibleStageVolumes.prismK(sq.exaggeration)
        let heat = FlexibleGroupWalls.heatSamples(tints: c.tints, overlay: o, model: m)
        let items = FlexibleStageVolumes.items(model: m, k: k, part: part, heat: heat)
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(o.mesh)
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation)
        mr.camera.distance *= cam.zoom
        if let t = c.tints { mr.setVertexTints(t) }
        mr.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        if let d = sq.dents { mr.setFlexDisplacements(d) }
        mr.setFlexScale(Float(sq.exaggeration))
        mr.setClearanceVolumes(items)
        let proj = CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: size, height: size))
        let bg = DS.Color.background
        var rgba = try XCTUnwrap(mr.renderOffscreen(size: size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
        let ctx = try XCTUnwrap(CGContext(data: &rgba, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        if pick {
            let marks = FlexibleEdgePickOverlay.marks(model: m, projection: proj)
            // as FlexibleEdgePickOverlay draws them: back-facing first, picked last
            for mk in marks.sorted(by: { ($0.picked ? 1 : 0, $0.front ? 1 : 0) < ($1.picked ? 1 : 0, $1.front ? 1 : 0) }) {
                let a: CGFloat = (mk.front ? 1 : CGFloat(FlexibleEdgePickRules.backFacingOpacity)) * (mk.greyed ? 0.5 : 1)
                let col = CGColor(red: mk.colour.r, green: mk.colour.g, blue: mk.colour.b, alpha: a)
                if mk.projected.kind == .corner, let q = mk.projected.point {
                    let d = mk.picked ? FlexibleEdgePickRules.pickedDotPt : FlexibleEdgePickRules.cornerDotPt
                    ctx.setFillColor(col)
                    ctx.fillEllipse(in: CGRect(x: q.x - d / 2, y: q.y - d / 2, width: d, height: d))
                } else {
                    ctx.setStrokeColor(col)
                    ctx.setLineWidth(mk.picked ? FlexibleEdgePickRules.pickedStrokePt : FlexibleEdgePickRules.edgeStrokePt)
                    ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    for pl in mk.projected.lines { ctx.addLines(between: pl) }
                    ctx.strokePath()
                }
            }
            for mk in marks { if let t = mk.target { tag(ctx, CGPoint(x: t.midX, y: t.midY), mk.text, mk.colour) } }
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(ctx.makeImage())
    }

    func tag(_ ctx: CGContext, _ p: CGPoint, _ text: String, _ fill: RGBA) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                                                    .foregroundColor: NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let r = CGRect(x: p.x - max(24, sz.width + 12) / 2, y: p.y - 11, width: max(24, sz.width + 12), height: 22)
        ctx.setFillColor(CGColor(red: fill.r, green: fill.g, blue: fill.b, alpha: 1))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil))
        ctx.fillPath()
        s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    /// The model and the panel side by side, the panel at the left as on the page.
    func write(_ name: String, model: CGImage, panel: CGImage?) throws {
        guard let dir = Self.dir else { return }
        // the panel at its own size (its words readable), the model scaled to the panel's height
        let ph = panel.map { CGFloat($0.height) } ?? CGFloat(model.height), pw = panel.map { CGFloat($0.width) } ?? 0
        let ms = ph / CGFloat(model.height)
        let w = Int(pw + CGFloat(model.width) * ms), h = Int(ph)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: DS.Color.background.r, green: DS.Color.background.g, blue: DS.Color.background.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let panel { ctx.draw(panel, in: CGRect(x: 0, y: 0, width: pw, height: ph)) }
        ctx.draw(model, in: CGRect(x: pw, y: 0, width: CGFloat(model.width) * ms, height: ph))
        let img = try XCTUnwrap(ctx.makeImage())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("FLEX-I2-EVIDENCE wrote \(url.path)")
    }

    func testEvidenceOnHisPad() async throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_I2_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (r, m) = try await hisPad()
        let iso = FlexibleRound6Tests.iso, top = FlexibleRound6Tests.topCam
        // pick mode, nothing picked: every edge and corner, numbered, in its colour
        try await pickMode(m)
        let h = panel(m)
        pump(0.6)
        try write("I2_A1_0003_pick_mode_iso.png", model: try renderModel(m, r, cam: iso, device: device, pick: true), panel: image(h))
        try write("I2_A1_0003_pick_mode_top.png", model: try renderModel(m, r, cam: top, device: device, pick: true), panel: image(h))
        // an edge (Top–Face 2) and a corner picked, the force typed: the "keeps the rest" lines on the card
        let p = try XCTUnwrap(m.edgePick)
        let edge = try XCTUnwrap(p.candidates.first { $0.kind == .edge && Set($0.members) == [1, 2] })
        m.toggleEdgePick(edge.number)
        m.setEdgePickWeight(5)
        pump(0.6)
        try write("I2_A1_0003_edge_picked_keeps_the_rest_iso.png", model: try renderModel(m, r, cam: iso, device: device, pick: true), panel: image(h))
        print("FLEX-I2-EVIDENCE lines: " + m.edgePickKeepsTheRest().joined(separator: " | "))
        // [Done]: the strip taken — the new group's tab, its glass on its strips
        let why2 = await m.finishEdgePick()
        XCTAssertNil(why2)
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        try await FlexibleSquishFixture.settle(m, "A1_0003 after the cut")
        pump(0.8)
        try write("I2_A1_0003_strip_taken_edges_group_tab_iso.png", model: try renderModel(m, r, cam: iso, device: device, pick: false), panel: image(h))
        try write("I2_A1_0003_strip_taken_edges_group_tab_top.png", model: try renderModel(m, r, cam: top, device: device, pick: false), panel: image(h))
        // Face 1's own group keeps the rest: Group 1's tab
        if let g1 = m.squeezeGroups.first(where: { $0.number == 1 }) {
            m.rail = .group(g1.id)
            pump(0.6)
            try write("I2_A1_0003_group1_keeps_the_rest_iso.png", model: try renderModel(m, r, cam: iso, device: device, pick: false), panel: image(h))
        }
        print("FLEX-I2-EVIDENCE presses: " + m.presses.map { "\($0.strip?.label ?? "-") \($0.regions) \($0.direction) w \($0.strip?.widthMM ?? 0)" }.joined(separator: " | "))
        print("FLEX-I2-EVIDENCE faces: " + m.settings.faces.map { "\($0.faceRegionID)·\(m.displayName($0.faceRegionID))·g\($0.squeezeGroup ?? 1)" }.joined(separator: " "))
    }
}
#endif

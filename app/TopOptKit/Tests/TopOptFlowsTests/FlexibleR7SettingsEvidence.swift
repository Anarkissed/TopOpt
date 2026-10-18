// FlexibleR7SettingsEvidence — round 7 batch S's pictures, on HIS pad (A1_0003 as he saved it: his img1–4 pad), written
// with FLEX_R7S_EVIDENCE_DIR=<dir> (skipped otherwise). NOT device screenshots: the model by the shipping renderer
// (MeshRenderer offscreen, the page's own tints and items), the page's own overlays (FlexibleStageOverlays — the curve
// editors, the depth chip, the stamp handle, the Prisms tags) hosted over it at the same projection, and the Settings panel
// hosted beside it (NSHostingView), both synchronous with the run loop pumped.
//   img4 reproduced (the red controls on: round 5's rule — the tab follows the selected face — and the gate on the
//   selection alone): his Group 2 edges tab (Edge 14 · Face 2 + Face 3, Edge 13 · Face 2 + Face 5) with Group 1's Face 1
//   (Curves, 3 mm) still selected — its "3.0 mm" chip and its curves over the edges tab; then a Strip width change opens
//   Group 1. The same steps fixed: the edges tab stays, no chip, no curves.
//   Reset all: [Model] and [New] only. Trash on every group and a renamed group ("Thumbs") in its tab, its header and the
//   Settings player's picker.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7SEvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7SettingsEvidence: XCTestCase {
    typealias Cam = FlexibleRound6Tests.Cam

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7S_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let frames: Frames }

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

    func host<V: View>(_ v: V, size: CGSize, clear: Bool = false) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        if clear { hv.wantsLayer = true; hv.layer?.backgroundColor = .clear }
        _ = NSApplication.shared
        let w = R7SEvidenceWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        if clear { w.isOpaque = false; w.backgroundColor = .clear }
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

    struct PanelHost: View {
        @ObservedObject var model: FlexibleStageModel
        @State var pad: String?
        @State var minimized = false
        var body: some View { FlexibleSettingsPanel(model: model, padTarget: $pad, minimized: $minimized) }
    }

    func panel(_ m: FlexibleStageModel, height: CGFloat = 900) -> Host {
        host(PanelHost(model: m).frame(width: FlexibleSettingsPanel.width, height: height, alignment: .bottom)
                .background(DS.Color.background.color),
             size: CGSize(width: FlexibleSettingsPanel.width, height: height))
    }

    /// The part by the shipping renderer, the page's overlays drawn over it at the same projection.
    func renderModel(_ m: FlexibleStageModel, _ r: FlexibleHisProject.Restored, cam: Cam, device: MTLDevice, size: Int = 900) throws -> CGImage {
        let part = try XCTUnwrap(r.project.viewerMesh)
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        var k = 1.0
        // nothing set (after Reset all): the part alone, as the page draws it with no overlay
        if let o = FlexiblePageChannels.overlay(model: m) {
            let c = FlexibleStagePage.composeTints(model: m, overlay: o)
            var cache: (key: String, dents: [Float])?
            let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
            k = FlexibleStageVolumes.prismK(sq.exaggeration)
            let heat = FlexibleGroupWalls.heatSamples(tints: c.tints, overlay: o, model: m)
            mr.setMesh(o.mesh)
            if let t = c.tints { mr.setVertexTints(t) }
            if let d = sq.dents { mr.setFlexDisplacements(d) }
            mr.setFlexScale(Float(sq.exaggeration))
            mr.setClearanceVolumes(FlexibleStageVolumes.items(model: m, k: k, part: part, heat: heat))
        } else {
            mr.setMesh(part)
        }
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation)
        mr.camera.distance *= cam.zoom
        mr.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        let proj = CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: size, height: size))
        let bg = DS.Color.background
        var rgba = try XCTUnwrap(mr.renderOffscreen(size: size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
        let ctx = try XCTUnwrap(CGContext(data: &rgba, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // the page's own overlays (curves, chip, stamp handle, tags), hosted at the same projection
        let box = FlexibleProjectionBox()
        box.projection = proj
        let ov = host(FlexibleStageOverlays(model: m, proj: box, exaggeration: k, keepOut: [], clip: [])
                        .frame(width: CGFloat(size), height: CGFloat(size))
                        .coordinateSpace(name: FlexibleStageSpace.name),
                      size: CGSize(width: size, height: size), clear: true)
        pump(0.6)
        if let img = image(ov) { ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size)) }
        ov.window.orderOut(nil); ov.window.contentView = nil
        return try XCTUnwrap(ctx.makeImage())
    }

    /// The panel at the left (as on the page), the model at its right, an optional strip under the model.
    func write(_ name: String, model: CGImage, panel: CGImage?, under: CGImage? = nil) throws {
        guard let dir = Self.dir else { return }
        let ph = panel.map { CGFloat($0.height) } ?? CGFloat(model.height), pw = panel.map { CGFloat($0.width) } ?? 0
        let uh = under.map { CGFloat($0.height) } ?? 0
        let mh = ph - uh
        let ms = mh / CGFloat(model.height)
        let w = Int(pw + CGFloat(model.width) * ms), h = Int(ph)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: DS.Color.background.r, green: DS.Color.background.g, blue: DS.Color.background.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let panel { ctx.draw(panel, in: CGRect(x: 0, y: 0, width: pw, height: ph)) }
        ctx.draw(model, in: CGRect(x: pw, y: uh, width: CGFloat(model.width) * ms, height: mh))
        if let under { ctx.draw(under, in: CGRect(x: pw + (CGFloat(model.width) * ms - CGFloat(under.width)) / 2, y: 0, width: CGFloat(under.width), height: uh)) }
        let img = try XCTUnwrap(ctx.makeImage())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("FLEX-R7S-EVIDENCE wrote \(url.lastPathComponent)")
    }

    /// His pad, opened the app's way (synchronously).
    func hisPad() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(settled(m), "the scene, stacks and designs")
        return (r, m)
    }

    func settled(_ m: FlexibleStageModel, _ t: Double = 240) -> Bool {
        pumpUntil(t) { m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } && !m.readiness.designing && !m.designsInFlight }
    }

    /// [+ New] → [Edges/corners] → the candidates over `members` → [Done], synchronously.
    func edgesGroup(_ m: FlexibleStageModel, _ members: [Set<Int>], kg: Double = 0.9072) throws {
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "the edges and corners listed")
        for set in members {
            let c = try XCTUnwrap(m.edgePick?.candidates.first { $0.kind == .edge && Set($0.members) == set }, "edge \(set)")
            m.toggleEdgePick(c.number)
        }
        m.setEdgePickWeight(kg)
        var done = false, why: String?
        Task { @MainActor in why = await m.finishEdgePick(); done = true }
        XCTAssertTrue(pumpUntil(240) { done } && settled(m), "the strips cut, the part open again")
        XCTAssertNil(why)
    }

    // ★ RE-PINNED (round 7, R7-E1 — his 2026-10-18 words: "There shouldn't be a strip width."): the evidence's edit was a Strip
    // width change; it is the flat prism's depth now (setFlatCut), the same one re-cut and one undo step.
    func reDepth(_ m: FlexibleStageModel, _ id: UUID) {
        var done = false
        Task { @MainActor in _ = await FlexibleFlatPrismFixtures.reDepth(m, id); done = true }
        XCTAssertTrue(pumpUntil(240) { done } && settled(m), "re-cut, the part open again")
    }

    /// His img4's state on his pad: Group 1 = the Top (Face 1, Curves, 3 mm — his img3's rows), Group 2 = an edges group
    /// (Edge 14 · Face 2 + Face 3, Edge 13 · Face 2 + Face 5), from a Reset all.
    func img4State(_ m: FlexibleStageModel) throws -> (top: Int, edges: Int, press: UUID) {
        m.resetAll()
        XCTAssertTrue(settled(m))
        m.rail = .newGroup
        if FlexibleStageModel.controlResetAdopts == false { m.tapFace(1) }
        XCTAssertTrue(settled(m))
        m.setShape(1, "curves")
        m.edit { s in guard var f = s.face(1) else { return }; f.deepestMM = 3; s.setFace(f) }
        XCTAssertTrue(settled(m))
        try edgesGroup(m, [[2, 3], [2, 5]])
        let e = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges })
        return (1, e.id, try XCTUnwrap(e.presses.first))
    }

    func testEvidenceOnHisPad() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R7S_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let iso = FlexibleRound6Tests.iso
        var lines: [String] = []

        // ── img4 reproduced: the red controls on (round 5's rule; the gate on the selection alone)
        do {
            let (r, m) = try hisPad()
            let st = try img4State(m)
            FlexibleStageModel.controlRailFollowsSelection = true
            FlexibleStageOverlays.controlGateOnSelectionOnly = true
            defer { FlexibleStageModel.controlRailFollowsSelection = false; FlexibleStageOverlays.controlGateOnSelectionOnly = false }
            m.selectedRegion = st.top          // (Face 1 selected — then the edges tab, as [Done] leaves it)
            m.rail = .group(st.edges)
            pump(0.6)
            let h = panel(m)
            pump(0.6)
            try write("R7S_img4_BEFORE_edges_tab_with_face1_chip_and_curves.png", model: try renderModel(m, r, cam: iso, device: device), panel: image(h))
            lines.append("before: tab \(m.rail) · selected \(m.selectedRegion.map(String.init) ?? "none") · chip \(FlexibleDepthChips.handle(model: m, k: 3) != nil) · curves \(FlexibleStageOverlays.curveEditors(model: m)?.axes ?? [])")
            reDepth(m, st.press)
            pump(0.6)
            try write("R7S_img4_BEFORE_after_strip_width_back_on_group1.png", model: try renderModel(m, r, cam: iso, device: device), panel: image(h))
            lines.append("before, after the depth re-cut: tab \(m.rail)")
        }
        // ── the same steps, fixed
        do {
            let (r, m) = try hisPad()
            let st = try img4State(m)
            m.selectedRegion = st.top
            m.rail = .group(st.edges)
            pump(0.6)
            let h = panel(m)
            pump(0.6)
            try write("R7S_img4_AFTER_edges_tab_no_chip_no_curves.png", model: try renderModel(m, r, cam: iso, device: device), panel: image(h))
            lines.append("after: tab \(m.rail) · selected \(m.selectedRegion.map(String.init) ?? "none") · chip \(FlexibleDepthChips.handle(model: m, k: 3) != nil) · curves \(FlexibleStageOverlays.curveEditors(model: m)?.axes ?? [])")
            let h0 = m.press(st.press).flatMap(FlexibleFlatPrism.depth(of:)) ?? 0
            reDepth(m, st.press)
            pump(0.6)
            try write("R7S_img4_AFTER_strip_width_stays_on_the_edges_group.png", model: try renderModel(m, r, cam: iso, device: device), panel: image(h))
            lines.append("after, depth \(h0) → \(m.press(st.press).flatMap(FlexibleFlatPrism.depth(of:)) ?? 0): tab \(m.rail) (edges group \(st.edges))")
            // Group 1 open: Face 1's own chip and curves (the numbers of what he works on)
            m.rail = .group(try XCTUnwrap(m.squeezeGroup(of: st.top)).id)
            pump(0.6)
            try write("R7S_group1_open_face1_chip_and_curves.png", model: try renderModel(m, r, cam: iso, device: device), panel: image(h))
        }
        // ── Reset all: [Model] and [New]
        do {
            let (r, m) = try hisPad()
            let h = panel(m)
            pump(0.6)
            try write("R7S_reset_BEFORE_his_pad.png", model: try renderModel(m, r, cam: iso, device: device), panel: image(h))
            m.resetAll()
            XCTAssertTrue(settled(m))
            pump(0.6)
            try write("R7S_reset_AFTER_model_and_new_only.png", model: try renderModel(m, r, cam: iso, device: device), panel: image(h))
            lines.append("reset: tabs \(FlexibleSettingsRailView.tabs(model: m).map(\.title))")
        }
        // ── a trash on every group; Group 2 renamed "Thumbs" (its tab, its header, the player's picker)
        do {
            let (r, m) = try hisPad()
            let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 })
            m.setGroupName(g2.id, "Thumbs")
            m.rail = .group(g2.id)
            pump(0.6)
            let h = panel(m)
            pump(0.6)
            let sims = FlexibleSettingsSquish.playerSims(model: m)
            let loop = FlexibleSquishLoop()
            let player = host(FlexibleSquishPlayer(loop: loop, fullLabel: FlexibleSettingsSquish.fullLabel(model: m), width: 520,
                                                   sims: sims, shown: sims.first { $0.short == "Thumbs" }, onPick: { _ in },
                                                   note: nil, colour: { m.groupColour(number: $0) })
                                .padding(8).background(DS.Color.background.color),
                              size: CGSize(width: 560, height: 120))
            pump(0.6)
            try write("R7S_trash_on_every_group_and_Group2_renamed_Thumbs.png", model: try renderModel(m, r, cam: iso, device: device),
                      panel: image(h), under: image(player))
            lines.append("renamed: tabs \(FlexibleSettingsRailView.tabs(model: m).map(\.title)) · picker \(sims.map(\.short))")
        }
        print("FLEX-R7S-EVIDENCE\n  " + lines.joined(separator: "\n  "))
    }
}
#endif

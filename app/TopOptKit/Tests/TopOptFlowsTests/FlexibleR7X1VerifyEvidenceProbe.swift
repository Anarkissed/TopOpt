// FlexibleR7X1VerifyEvidenceProbe — round 7 batch X1's VERIFY pictures, on HIS pad (A1_0003). Opt-in:
//     FLEX_R7X1_EVIDENCE_DIR=<dir> swift test --filter FlexibleR7X1VerifyEvidenceProbe
// The pages' own picture by the shipping renderer under the pages' own hosted chrome (FlexibleR7X1EvidenceProbe's helpers):
// offscreen frames, not device screenshots; the camera is the probe's (his img1 / img5 views, a low front view for the
// verify's img2 finding). The Squish page's bend-prism number is drawn where the page places it — the prism's floor,
// projected by the probe's own camera (the hosted chrome has no camera of its own, so its tag layer draws nothing there).
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import AppKit
import MetalKit
import SwiftUI
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7X1VerifyEvidenceProbe: XCTestCase {
    typealias E = FlexibleR7X1EvidenceProbe
    typealias Cam = FlexibleRound6Tests.Cam
    static let img2 = Cam(name: "img2 (front)", azimuth: 0.05, elevation: 0.12, zoom: 1)

    func wait(_ m: FlexibleStageModel) async throws {
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testTheMainPageVerifyOnHisPad() async throws {
        guard E.dir != nil else { throw XCTSkip("opt-in: FLEX_R7X1_EVIDENCE_DIR") }
        let e = E()
        var lines: [String] = []
        let (r, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: true)
        let p = r.project
        s.didExitSettings()
        s.apply(p, owned: true, pageUp: false)
        try await wait(m)
        func shot(_ name: String, _ cam: Cam) throws {
            try e.shot(s, p, name, cam: cam, size: E.p13, lines: &lines)
            lines[lines.count - 1] += " · walls carry the heat \(s.heatOnWalls) · top \(String(format: "%.2f", s.dentMaxMM)) mm"
        }
        // the default view: X-ray off, Heat on — the printed view, the heat on the walls, the solid part plain
        try shot("VX1V_default_none_heat_img5_13p.png", E.img5)
        try shot("VX1V_default_none_heat_img1_13p.png", E.img1)
        s.heat = false
        try shot("VX1V_default_none_heat_off_img5_13p.png", E.img5)
        s.heat = true
        // X-ray, Heat on: through the solid — the walls and their squish (the blocker's camera first)
        s.toggleXray()
        try shot("VX1V_xray_heat_img5_13p.png", E.img5)
        try shot("VX1V_xray_heat_img1_13p.png", E.img1)
        try shot("VX1V_xray_heat_img2_front_13p.png", Self.img2)
        s.togglePlay()
        s.loop.hold(0.6)
        try shot("VX1V_xray_heat_play_0.6_img1_13p.png", E.img1)
        s.togglePlay()
        s.heat = false
        try shot("VX1V_xray_heat_off_img5_13p.png", E.img5)
        s.heat = true
        s.toggleXray()
        // Group C picked (its face-prisms) — X-ray, Heat on
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        p.selection.setActive(c.id)
        try await Task.sleep(nanoseconds: 600_000_000)
        try await wait(m)
        s.toggleXray()
        try shot("VX1V_xray_heat_groupC_picked_img5_13p.png", E.img5)
        try shot("VX1V_xray_heat_groupC_picked_img1_13p.png", E.img1)
        s.toggleXray()
        try shot("VX1V_default_heat_groupC_picked_img1_13p.png", E.img1)
        // Covered: the Lattice icon turned on says why nothing changes; its tap is X-ray
        try await e.rebuild(s, m, finish: .covered)
        try await wait(m)
        s.note.clear()
        s.latticeOn = false
        s.toggleLatticeView()
        try shot("VX1V_covered_lattice_icon_note_img1_13p.png", E.img1)
        lines[lines.count - 1] += " · note \(String(describing: s.note.kind))"
        s.coveredNoteTapped()
        try shot("VX1V_covered_note_tapped_xray_img1_13p.png", E.img1)
        s.toggleXray()
        // the fixture's Top face-prism (the whole pad under the Top latticed)
        do {
            let r2 = try FlexiblePressFixtures.a1Project(3, self)
            let s2 = FlexibleMainStage()
            s2.reduceMotion = { true }
            let m2 = s2.model(for: r2.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
            addTeardownBlock { @MainActor in await m2.waitForIdle() }
            m2.openScene()
            try await FlexibleSquishFixture.settle(m2, "his pad (Top face-prism)")
            m2.edit({ $0.finish = FlexibleFinish.none.rawValue }, recompute: false)
            s2.didExitSettings()
            s2.apply(r2.project, owned: true, pageUp: false)
            try await wait(m2)
            try e.shot(s2, r2.project, "VX1V_top_face_prism_default_heat_img1_13p.png", cam: E.img1, size: E.p13, lines: &lines)
            s2.toggleXray()
            try e.shot(s2, r2.project, "VX1V_top_face_prism_xray_heat_img5_13p.png", cam: E.img5, size: E.p13, lines: &lines)
        }
        print("FLEX-R7X1V-EVIDENCE main\n  " + lines.joined(separator: "\n  "))
        if let dir = E.dir {
            try ("# X1 verify evidence — the main page (FlexibleR7X1VerifyEvidenceProbe.testTheMainPageVerifyOnHisPad)\n" + lines.joined(separator: "\n") + "\n")
                .write(to: dir.appendingPathComponent("r7x1v_evidence_main.txt"), atomically: true, encoding: .utf8)
        }
    }

    func testTheSquishPageVerifyOnHisPad() async throws {
        guard let dir = E.dir else { throw XCTSkip("opt-in: FLEX_R7X1_EVIDENCE_DIR") }
        let e = E()
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let size = CGSize(width: 1032, height: 1376)
        var lines: [String] = []
        func shot(_ name: String, views: FlexibleStageViews) throws {
            m.views = views
            let edge = FlexibleSettingsSquish.overlayEdge(model: m)
            let overlay = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0) } ?? FlexiblePageChannels.overlay(model: m))
            var cache: (key: String, dents: [Float])?
            var c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: views)
            let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
            c.dents = sq.dents
            let scale = FlexibleStagePage.dentScale(views: views, exaggeration: sq.exaggeration, amount: 0)
            let heat = FlexibleGroupWalls.heatSamples(tints: c.tints, overlay: overlay, model: m)
            var items = FlexibleStageVolumes.items(model: m, k: FlexibleStageVolumes.prismK(sq.exaggeration), part: p.viewerMesh, heat: heat,
                                                   heated: FlexibleStageHeat.shown(model: m, views: views))
            let xr = FlexibleStagePage.xrayItems(model: m, overlay: overlay, dents: sq.dents, k: sq.exaggeration, views: views)
            items += xr
            let n = 1600
            let cam = Cam(name: "iso", azimuth: .pi / 4, elevation: .pi / 6, zoom: 1.25)
            let alpha = FlexibleStagePage.bodyAlpha(views: views, edgePick: false, hasDent: sq.dents != nil)
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let mr = try FlexibleRound6EvidenceProbe().renderer(mesh: overlay.mesh, tints: c.tints, dents: sq.dents, scale: scale,
                                                                 bodyAlpha: alpha, settle: settle, cam: cam, device: device, items: items, layer: nil)
            let bg = DS.Color.background
            let model = try XCTUnwrap(mr.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
            // the prism's number where the page places it (its floor), by the probe's own camera
            let tag = FlexibleBendPrism.tag(xr.first)
            let proj = CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: n, height: n))
            let at = tag.flatMap { proj.project($0.anchor) }
            let chrome = try e.hostedPixels(FlexibleStagePage(project: p, model: m, onExit: {}), size: size, settle: 2.5)
            try composite(model: model, n: n, chrome: chrome, name: name, dir: dir, place: (x: 0.22, y: 0.05, side: 0.78),
                          tag: tag.flatMap { t in at.map { (t.text, $0) } })
            let short = tag.map { FlexibleBendPrism.shortOfDrawn(model: m, depthMM: $0.depthMM) } ?? false
            lines.append("\(name): views \(views.rawValue) · body alpha \(alpha) · bend prism \(tag?.text ?? "-") (k \(sq.exaggeration), fe \(sq.fe)) · tint \(xr.first?.tint.map { "\($0)" } ?? "-") · card row \(tag != nil ? "\"\(FlexibleRowCopy.legendBendRow(short: short))\"" : "-")")
        }
        for (regions, label) in [([1], "G1"), ([4, 2], "G2"), ([3, 5], "G3")] {
            let g = try XCTUnwrap(m.squeezeGroups.first { $0.regions == regions })
            m.rail = .group(g.id)
            m.select(regions[0])
            try await FlexibleSquishFixture.solve(m, first: FlexibleSim.groupID(g.number), "his pad")
            try shot("VX1V_S_\(label)_xray_heat_13p.png", views: [.xray])
            if label != "G3" { try shot("VX1V_S_\(label)_xray_heat_off_13p.png", views: [.xray, .heatOff]) }
        }
        m.views = []
        print("FLEX-R7X1V-EVIDENCE squish\n  " + lines.joined(separator: "\n  "))
        try ("# X1 verify evidence — the Squish page (FlexibleR7X1VerifyEvidenceProbe.testTheSquishPageVerifyOnHisPad)\n" + lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("r7x1v_evidence_squish.txt"), atomically: true, encoding: .utf8)
    }

    /// FlexibleR7X1EvidenceProbe.composite, plus the bend prism's number drawn at its point (model pixels, top-left origin).
    func composite(model px: [UInt8], n: Int, chrome: (px: [UInt8], w: Int, h: Int), name: String, dir: URL,
                   place pl: (x: CGFloat, y: CGFloat, side: CGFloat), tag: (String, CGPoint)?) throws {
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
        let side = CGFloat(min(chrome.w, chrome.h)) * pl.side
        let rect = CGRect(x: CGFloat(chrome.w) * pl.x, y: CGFloat(chrome.h) * (1 - pl.y) - side, width: side, height: side)
        out.draw(mimg, in: rect)
        out.draw(cimg, in: CGRect(x: 0, y: 0, width: chrome.w, height: chrome.h))
        if let (text, p) = tag {
            // the page's capsule: 12 pt semibold digits, 10 / 5 pt padding, the panel at 85 %, a white rim (pixels at 2×)
            let x = rect.minX + p.x / CGFloat(n) * side, y = rect.maxY - p.y / CGFloat(n) * side
            let font = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            let ts = s.size()
            let box = CGRect(x: x - ts.width / 2 - 20, y: y - ts.height / 2 - 10, width: ts.width + 40, height: ts.height + 20)
            let path = CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil)
            let panel = DS.Surface.panel
            out.setFillColor(CGColor(red: panel.r, green: panel.g, blue: panel.b, alpha: 0.85))
            out.addPath(path); out.fillPath()
            out.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.7)); out.setLineWidth(2)
            out.addPath(path); out.strokePath()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: out, flipped: false)
            s.draw(at: CGPoint(x: x - ts.width / 2, y: y - ts.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        let img = try XCTUnwrap(out.makeImage())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("FLEX-R7X1V-EVIDENCE wrote \(url.path)")
    }
}
#endif
